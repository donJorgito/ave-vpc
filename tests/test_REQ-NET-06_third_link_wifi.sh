#!/bin/sh
# Validates ave-vpc.REQ-NET-06: 3er enlace WiFi con pre-flight checks.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-06_third_link_wifi"
SCRIPT="$(dirname "$0")/../04-conectar.sh"
[ -f "${SCRIPT}" ] || { junit_fail "script_missing" "04-conectar.sh no existe"; junit_finalize; }
# Check 1: función check_wifi_eligibility presente
if grep -q "check_wifi_eligibility" "${SCRIPT}"; then
    junit_pass "function_check_wifi_eligibility"
else
    junit_fail "function_missing" "función check_wifi_eligibility ausente"
fi
# Check 2: flag --sin-wifi reconocido
if grep -q -- "--sin-wifi" "${SCRIPT}"; then
    junit_pass "flag_sin_wifi"
else
    junit_fail "flag_missing" "flag --sin-wifi no implementado"
fi
# Check 3: detección red de casa (compara subnet RPi)
if grep -q "RPi_IP" "${SCRIPT}" && grep -q "rpi_subnet" "${SCRIPT}"; then
    junit_pass "home_network_detection"
else
    junit_fail "home_network_missing" "detección de red de casa no implementada"
fi
# Check 4: detección captive portal
if grep -q "captive.apple.com" "${SCRIPT}"; then
    junit_pass "captive_portal_check"
else
    junit_fail "captive_portal_missing" "test contra captive.apple.com no implementado"
fi
# Check 5: append dinámico de [links.wifi]
if grep -q "\[links.wifi\]" "${SCRIPT}"; then
    junit_pass "dynamic_wifi_block_append"
else
    junit_fail "dynamic_wifi_block_missing" "append de [links.wifi] no encontrado"
fi
# Check 6: MLVPN_PORT_3 en config/env.example
ENV_EXAMPLE="$(dirname "$0")/../config/env.example"
if [ -f "${ENV_EXAMPLE}" ] && grep -q "^MLVPN_PORT_3=" "${ENV_EXAMPLE}"; then
    junit_pass "mlvpn_port_3_in_env_example"
else
    junit_fail "mlvpn_port_3_missing" "MLVPN_PORT_3 no en config/env.example"
fi
junit_finalize
