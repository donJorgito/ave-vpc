#!/bin/sh
# Validates ave-vpc.REQ-NET-12 unit test (Fase 3): la lógica del dedup
# LRU funciona como se diseñó. Compila tests/unit/test_replicate_dedup.c
# (test C standalone) y verifica que pasa todos los casos.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-12_unit_dedup"

UNIT_C="$(dirname "$0")/unit/test_replicate_dedup.c"
UNIT_BIN="$(dirname "$0")/unit/test_replicate_dedup"

# Check 1: el fuente del test C existe
if [ -f "${UNIT_C}" ]; then
    junit_pass "test_source_exists"
else
    junit_fail "no_source" "tests/unit/test_replicate_dedup.c no existe"
    junit_finalize
fi

# Check 2: clang disponible (CI Ubuntu trae gcc; macOS trae clang)
if command -v clang >/dev/null 2>&1; then
    CC=clang
elif command -v gcc >/dev/null 2>&1; then
    CC=gcc
else
    junit_skip "no_compiler" "ni clang ni gcc disponibles"
    junit_finalize
fi

# Check 3: compila sin errores
if ${CC} -O2 -Wall -Wextra -Werror -o "${UNIT_BIN}" "${UNIT_C}" 2>/dev/null; then
    junit_pass "compiles_clean"
else
    junit_fail "compile_failed" "no compila (con -Werror)"
    junit_finalize
fi

# Check 4: el test C ejecuta y reporta ALL_TESTS_PASSED
OUTPUT="$("${UNIT_BIN}" 2>&1)"
EXIT="$?"
if [ "${EXIT}" -eq 0 ] && echo "${OUTPUT}" | grep -q "^ALL_TESTS_PASSED$"; then
    junit_pass "all_unit_tests_pass"
else
    junit_fail "unit_tests_failed" "test C falló (exit=${EXIT})"
    echo "${OUTPUT}" | sed 's/^/      /' | tail -20
fi

# Check 5: cobertura — 7 grupos de test ejecutados (data_seq=0,
# nuevo, dup, secuencias distintas, wrap, evicción, valores grandes)
PASS_COUNT="$(echo "${OUTPUT}" | grep -c "^PASS:")"
if [ "${PASS_COUNT}" -ge 12 ]; then
    junit_pass "covers_all_test_groups"
else
    junit_fail "low_coverage" "solo ${PASS_COUNT} casos PASS (esperado ≥12)"
fi

# Limpiar binario
rm -f "${UNIT_BIN}"

junit_finalize
