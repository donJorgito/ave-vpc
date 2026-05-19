#!/bin/sh
# Validates ave-vpc.REQ-NET-04: IP pública sin CGNAT (no en 100.64.0.0/10).
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-04_no_cgnat"
ENV_FILE="$(dirname "$0")/../config/env"
[ -f "${ENV_FILE}" ] || { junit_skip "config_env" "config/env no existe"; junit_finalize; }
# shellcheck source=/dev/null
. "${ENV_FILE}"
[ -n "${VPS_IP:-}" ] || { junit_skip "vps_ip" "VPS_IP no definido"; junit_finalize; }
if ! command -v getent >/dev/null 2>&1 && ! command -v dig >/dev/null 2>&1 && ! command -v nslookup >/dev/null 2>&1; then
    junit_skip "no_resolver" "ni getent ni dig ni nslookup disponibles"
    junit_finalize
fi
# Resolver el VPS_IP
RESOLVED=""
if command -v dig >/dev/null 2>&1; then
    RESOLVED="$(dig +short "${VPS_IP}" 2>/dev/null | head -1)"
elif command -v getent >/dev/null 2>&1; then
    RESOLVED="$(getent hosts "${VPS_IP}" 2>/dev/null | awk '{print $1}' | head -1)"
fi
[ -z "${RESOLVED}" ] && RESOLVED="${VPS_IP}"
# Verificar que no es CGNAT (rango 100.64.0.0/10 = 100.64.x.x a 100.127.x.x)
FIRST="${RESOLVED%%.*}"
SECOND_REST="${RESOLVED#*.}"
SECOND="${SECOND_REST%%.*}"
if [ "${FIRST}" = "100" ] && [ "${SECOND}" -ge 64 ] 2>/dev/null && [ "${SECOND}" -le 127 ] 2>/dev/null; then
    junit_fail "cgnat_detected_${RESOLVED}" "${RESOLVED} está en 100.64.0.0/10 (CGNAT)"
else
    junit_pass "public_ip_${RESOLVED}_not_cgnat"
fi
junit_finalize
