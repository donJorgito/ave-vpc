#!/bin/sh
# Validates ave-vpc.REQ-NET-12 integration test (Fase 3): el filtro BPF
# del config [filters.replicate] funciona como espera ubond en runtime.
#
# Compila tests/integration/test_replicate_bpf_filter.c contra libpcap
# y verifica que las 15 aserciones pasan: matches positivos, negativos,
# protocolos cruzados (UDP/TCP), por host, por rango de puertos, y
# rechazo de sintaxis inválida sin crash.
#
# Sin libpcap → SKIP. En CI Ubuntu la lib viene con `apt-get install
# libpcap-dev`; en macOS con `brew install libpcap`.
#
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-12_integration_bpf"

SRC="$(dirname "$0")/integration/test_replicate_bpf_filter.c"
BIN="$(dirname "$0")/integration/test_replicate_bpf_filter"

# Check 1: fuente existe
if [ -f "${SRC}" ]; then
    junit_pass "test_source_exists"
else
    junit_fail "no_source" "tests/integration/test_replicate_bpf_filter.c no existe"
    junit_finalize
fi

# Check 2: compilador disponible
if command -v clang >/dev/null 2>&1; then
    CC=clang
elif command -v gcc >/dev/null 2>&1; then
    CC=gcc
else
    junit_skip "no_compiler" "ni clang ni gcc disponibles"
    junit_finalize
fi

# Check 3: detectar libpcap (varios paths posibles)
PCAP_INC=""
PCAP_LIB=""
for prefix in /opt/homebrew/opt/libpcap /usr/local/opt/libpcap /usr /opt/homebrew /usr/local; do
    if [ -f "${prefix}/include/pcap.h" ]; then
        PCAP_INC="-I${prefix}/include"
        PCAP_LIB="-L${prefix}/lib"
        break
    fi
done
# Si no encontramos header en paths estándar, probar pkg-config
if [ -z "${PCAP_INC}" ] && command -v pkg-config >/dev/null 2>&1; then
    if pkg-config --exists libpcap; then
        PCAP_INC="$(pkg-config --cflags libpcap)"
        PCAP_LIB="$(pkg-config --libs-only-L libpcap)"
    fi
fi
# Si seguimos sin header, intentar compile directo (libpcap puede estar en defaults del compilador, ej. macOS SDK)
if [ -z "${PCAP_INC}" ]; then
    echo "int main(){}" | ${CC} -x c - -lpcap -o /dev/null 2>/dev/null && PCAP_LIB="-lpcap"
fi

if [ -z "${PCAP_LIB}" ] && [ -z "${PCAP_INC}" ]; then
    junit_skip "no_libpcap" "libpcap no encontrada (apt-get install libpcap-dev | brew install libpcap)"
    junit_finalize
fi
junit_pass "libpcap_found"

# Check 4: compila limpio con -Werror
# shellcheck disable=SC2086
if ${CC} ${PCAP_INC} ${PCAP_LIB} -lpcap -O2 -Wall -Wextra -Werror -o "${BIN}" "${SRC}" 2>/dev/null; then
    junit_pass "compiles_clean"
else
    junit_fail "compile_failed" "no compila con -Werror"
    junit_finalize
fi

# Check 5: ejecuta y reporta ALL_TESTS_PASSED
OUTPUT="$("${BIN}" 2>&1)"
EXIT="$?"
if [ "${EXIT}" -eq 0 ] && echo "${OUTPUT}" | grep -q "^ALL_TESTS_PASSED$"; then
    junit_pass "all_integration_tests_pass"
else
    junit_fail "tests_failed" "test C falló (exit=${EXIT})"
    echo "${OUTPUT}" | sed 's/^/      /' | tail -20
fi

# Check 6: cobertura — al menos 15 aserciones PASS
PASS_COUNT="$(echo "${OUTPUT}" | grep -c "^PASS:")"
if [ "${PASS_COUNT}" -ge 15 ]; then
    junit_pass "covers_all_bpf_cases"
else
    junit_fail "low_coverage" "solo ${PASS_COUNT} casos PASS (esperado ≥15)"
fi

# Limpiar binario
rm -f "${BIN}"

junit_finalize
