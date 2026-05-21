#!/bin/sh
# Validates ave-vpc.REQ-NET-08: detección de "red de casa" por IP pública.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-08_home_via_public_ip"

CONNECT="$(dirname "$0")/../04-conectar.sh"

[ -f "${CONNECT}" ] || { junit_fail "connect_missing" "04-conectar.sh no existe"; junit_finalize; }

# Check 1: helper get_public_ip_via_iface() definido
if grep -q "^get_public_ip_via_iface()" "${CONNECT}"; then
    junit_pass "helper_get_public_ip_defined"
else
    junit_fail "helper_get_public_ip_missing" "no se define get_public_ip_via_iface()"
fi

# Check 2: tres servicios HTTP de fallback con curl --interface
if grep -q "api.ipify.org" "${CONNECT}" \
   && grep -q "ifconfig.me/ip" "${CONNECT}" \
   && grep -q "icanhazip.com" "${CONNECT}" \
   && grep -q 'curl --interface "${iface}"' "${CONNECT}"; then
    junit_pass "three_public_ip_services_with_iface_curl"
else
    junit_fail "public_ip_services_missing" "faltan los 3 servicios HTTP o el curl --interface"
fi

# Check 3: timeout corto en la consulta de IP pública
if grep -q -- "--max-time 2" "${CONNECT}"; then
    junit_pass "public_ip_short_timeout"
else
    junit_fail "public_ip_timeout_missing" "no hay --max-time 2 en la consulta de IP pública"
fi

# Check 4: helper resolve_vps_public_ip() con dig y soporte de IP literal
if grep -q "^resolve_vps_public_ip()" "${CONNECT}" \
   && grep -q 'dig +short' "${CONNECT}"; then
    junit_pass "helper_resolve_vps_defined"
else
    junit_fail "helper_resolve_vps_missing" "no se define resolve_vps_public_ip() con dig"
fi

# Check 5: comparación wifi_public == rpi_public en check_wifi_eligibility
if grep -q 'wifi_public="\$(get_public_ip_via_iface' "${CONNECT}" \
   && grep -q 'rpi_public="\$(resolve_vps_public_ip' "${CONNECT}" \
   && grep -q '"\${wifi_public}" == "\${rpi_public}"' "${CONNECT}"; then
    junit_pass "compare_wifi_vs_rpi_public_ip"
else
    junit_fail "compare_missing" "no se comparan IPs públicas WiFi vs RPi"
fi

# Check 6: heurística antigua (subred + ping a RPi_IP) eliminada
if grep -q 'rpi_subnet' "${CONNECT}" \
   || grep -q 'wifi_subnet' "${CONNECT}" \
   || grep -q 'ping -c 1 -t 1 -S "\${IP_WIFI}" "\${RPi_IP}"' "${CONNECT}"; then
    junit_fail "old_heuristic_present" "la heurística subred+ping sigue presente"
else
    junit_pass "old_heuristic_removed"
fi

# Check 7: mensaje de aviso "red de casa" con IP pública
if grep -q "IP pública RPi" "${CONNECT}" \
   && grep -q "hairpin NAT" "${CONNECT}"; then
    junit_pass "home_warning_message"
else
    junit_fail "home_warning_missing" "no hay mensaje claro 'IP pública RPi → red de casa'"
fi

# Check 8: orden — la comparación va después del captive y antes del anti-bind-stale
# (extraemos los números de línea y verificamos)
LINE_CAPTIVE=$(grep -n "captive.apple.com" "${CONNECT}" | head -1 | cut -d: -f1)
LINE_HOME=$(grep -n "wifi_public.*rpi_public" "${CONNECT}" | head -1 | cut -d: -f1)
LINE_REVALIDATE=$(grep -n "tras autenticar el captive" "${CONNECT}" | head -1 | cut -d: -f1)
if [ -n "${LINE_CAPTIVE}" ] && [ -n "${LINE_HOME}" ] && [ -n "${LINE_REVALIDATE}" ] \
   && [ "${LINE_CAPTIVE}" -lt "${LINE_HOME}" ] \
   && [ "${LINE_HOME}" -lt "${LINE_REVALIDATE}" ]; then
    junit_pass "checks_order_correct"
else
    junit_fail "checks_order_wrong" "orden esperado: captive < home_via_public_ip < anti-bind-stale"
fi

junit_finalize
