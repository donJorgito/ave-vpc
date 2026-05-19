#!/bin/sh
# Validates ave-vpc.REQ-MAC-04: 04-conectar.sh configura utun directamente.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-MAC-04_utun_direct_config"
SCRIPT="$(dirname "$0")/../04-conectar.sh"
[ -f "${SCRIPT}" ] || { junit_fail "script_missing" "04-conectar.sh no existe"; junit_finalize; }
# Verifica detección de utun y configuración directa
if grep -q 'UTUN_IFACE' "${SCRIPT}" && grep -q 'ifconfig "${UTUN_IFACE}"' "${SCRIPT}"; then
    junit_pass "utun_detection_and_direct_config"
else
    junit_fail "utun_config_missing" "detección o configuración directa del utun ausente"
fi
# Verifica rutas 0.0.0.0/1 + 128.0.0.0/1 vía utun
if grep -q '0.0.0.0/1' "${SCRIPT}" && grep -q '128.0.0.0/1' "${SCRIPT}"; then
    junit_pass "split_default_routes_via_utun"
else
    junit_fail "default_routes_missing" "rutas 0/1 y 128/1 vía utun no encontradas"
fi
junit_finalize
