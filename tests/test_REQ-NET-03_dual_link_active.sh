#!/bin/sh
# Validates ave-vpc.REQ-NET-03: 2 enlaces autenticados simultáneamente.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-03_dual_link_active"
if ! command -v ps >/dev/null 2>&1 || ! command -v grep >/dev/null 2>&1; then
    junit_skip "no_tools" "ps/grep no disponibles"
    junit_finalize
fi
PROC=$(ps aux 2>/dev/null | grep "mlvpn: mlvpn0" | grep -v grep | grep -v priv | head -1)
if [ -z "${PROC}" ]; then
    junit_skip "mlvpn_not_running" "mlvpn no está corriendo — ejecuta sudo ./04-conectar.sh"
    junit_finalize
fi
AUTH_COUNT=$(echo "${PROC}" | grep -o "@links\.[a-z]*" | wc -l | tr -d ' ')
if [ "${AUTH_COUNT}" -ge 2 ]; then
    junit_pass "two_or_more_links_authenticated_${AUTH_COUNT}"
else
    junit_fail "fewer_than_two_links" "solo ${AUTH_COUNT} enlace(s) autenticado(s)"
fi
junit_finalize
