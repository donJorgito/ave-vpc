#!/bin/sh
# Validates ave-vpc.REQ-NET-18: verificar-setup.sh exige bash 4+.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-18_bash_version_check"

VERIFY="$(dirname "$0")/verificar-setup.sh"

[ -f "${VERIFY}" ] || { junit_fail "verify_missing" "verificar-setup.sh no existe"; junit_finalize; }

# Check 1: el check itera por paths absolutos de bash conocidos
if grep -q "/opt/homebrew/bin/bash" "${VERIFY}" \
   && grep -q "/usr/local/bin/bash" "${VERIFY}" \
   && grep -q "/bin/bash" "${VERIFY}"; then
    junit_pass "checks_known_bash_paths"
else
    junit_fail "missing_bash_paths" "no se buscan los paths de bash conocidos"
fi

# Check 2: consulta BASH_VERSINFO[0] de cada bash encontrado
if grep -q "BASH_VERSINFO\[0\]" "${VERIFY}"; then
    junit_pass "queries_bash_version"
else
    junit_fail "no_version_query" "no se consulta BASH_VERSINFO[0]"
fi

# Check 3: requiere versión ≥4
if grep -qE 'v.*-ge.*4|"\${v}".*-ge.*"4"' "${VERIFY}" \
   || grep -q '\-ge 4 \]' "${VERIFY}"; then
    junit_pass "requires_v4_or_higher"
else
    junit_fail "no_v4_check" "no se exige versión ≥4"
fi

# Check 4: aborta con exit 1 y mensaje claro si no hay bash 4+
if grep -q "BASH4_PATH=\"\"" "${VERIFY}" \
   && grep -q '\[ -z "\${BASH4_PATH}" \]' "${VERIFY}" \
   && grep -q "exit 1" "${VERIFY}"; then
    junit_pass "aborts_if_not_found"
else
    junit_fail "no_abort_logic" "no se aborta correctamente si no hay bash 4+"
fi

# Check 5: mensaje incluye recomendación "brew install bash"
if grep -q "brew install bash" "${VERIFY}"; then
    junit_pass "suggests_brew_install"
else
    junit_fail "no_install_suggestion" "el mensaje no recomienda brew install bash"
fi

# Check 6: el check va ANTES de iterar tests (sino, los tests
# arrancarían con bash 3.2 ya y fallarían silenciosamente)
LINE_CHECK=$(grep -n "BASH4_PATH=\"\"" "${VERIFY}" | head -1 | cut -d: -f1)
LINE_LOOP=$(grep -n 'for t in.*test_REQ' "${VERIFY}" | head -1 | cut -d: -f1)
if [ -n "${LINE_CHECK}" ] && [ -n "${LINE_LOOP}" ] && [ "${LINE_CHECK}" -lt "${LINE_LOOP}" ]; then
    junit_pass "check_before_test_loop"
else
    junit_fail "check_after_loop" "el check de bash 4+ debe ir ANTES del loop de tests"
fi

# Check 7: NO se imprime ruido si todo va bien (no añadir mensaje
# innecesario al output normal)
if ! grep -q "✓.*bash.*[Oo][Kk]\|bash.*encontrado.*✓" "${VERIFY}"; then
    junit_pass "silent_when_ok"
else
    junit_fail "noisy_when_ok" "el check imprime ruido cuando todo va bien"
fi

junit_finalize
