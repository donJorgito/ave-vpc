#!/bin/sh
# Validates ave-vpc.REQ-MAC-03: ruta /32 anti-loop con preferencia móvil.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-MAC-03_antiloop_route"
SCRIPT="$(dirname "$0")/../04-conectar.sh"
[ -f "${SCRIPT}" ] || { junit_fail "script_missing" "04-conectar.sh no existe"; junit_finalize; }
# Verifica preferencia móvil: GW_PIXEL > GW_IPHONE > GW_WIFI
if grep -q '${GW_PIXEL:-${GW_IPHONE:-${GW_WIFI}}}' "${SCRIPT}"; then
    junit_pass "vps_gw_mobile_first"
else
    junit_fail "vps_gw_priority_missing" "preferencia móvil para /32 anti-loop no encontrada"
fi
# Verifica que se añade ruta regular (no ifscope) al VPS
if grep -q 'route -n add -host "${VPS_IP}" "${VPS_GW}"' "${SCRIPT}"; then
    junit_pass "global_route_to_vps"
else
    junit_fail "global_route_missing" "ruta regular /32 al VPS no encontrada"
fi
junit_finalize
