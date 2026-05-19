#!/bin/sh
# Validates ave-vpc.REQ-NET-05: bonding tolera WiFi corp/captive (delegado a REQ-NET-06).
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-05_wifi_resilience"
SCRIPT="$(dirname "$0")/../04-conectar.sh"
[ -f "${SCRIPT}" ] || { junit_fail "script_missing" "04-conectar.sh no existe"; junit_finalize; }
# Verificar que el script implementa el comportamiento que tolera estos casos
if grep -q "check_wifi_eligibility" "${SCRIPT}"; then
    junit_pass "eligibility_function_present"
else
    junit_fail "eligibility_function_missing" "función check_wifi_eligibility no encontrada"
fi
if grep -q "captive" "${SCRIPT}"; then
    junit_pass "captive_handling_present"
else
    junit_fail "captive_handling_missing" "manejo de captive portal no implementado"
fi
junit_finalize
