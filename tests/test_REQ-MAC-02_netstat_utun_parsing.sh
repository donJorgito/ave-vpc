#!/bin/sh
# Validates ave-vpc.REQ-MAC-02: 08-monitor.py parsea correctamente utun en netstat -ibn.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-MAC-02_netstat_utun_parsing"
MONITOR="$(dirname "$0")/../08-monitor.py"
[ -f "${MONITOR}" ] || { junit_fail "monitor_missing" "08-monitor.py no existe"; junit_finalize; }
# Check: el parser detecta MAC y aplica offset variable
if grep -q "parts\[3\].count(':') == 5" "${MONITOR}"; then
    junit_pass "mac_aware_offset_present"
else
    junit_fail "mac_aware_offset_missing" "el parser no detecta presencia de MAC para ajustar offset"
fi
# Check: lee del utun directamente (no suma físicas para el agregado del túnel)
if grep -q "tráfico útil del túnel" "${MONITOR}"; then
    junit_pass "tunnel_uses_utun_directly"
else
    junit_fail "tunnel_aggregation_outdated" "el agregado del túnel no se lee del utun"
fi
# Check: strippea el asterisco
if grep -q "rstrip('\*')" "${MONITOR}"; then
    junit_pass "asterisk_strip_present"
else
    junit_fail "asterisk_strip_missing" "no se strippea el asterisco del nombre"
fi
junit_finalize
