#!/bin/sh
# Validates ave-vpc.REQ-VPS-08: IP forwarding.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-VPS-08_ip_forwarding"
ENV_FILE="$(dirname "$0")/../config/env"
[ -f "${ENV_FILE}" ] || { junit_skip "config_env" "config/env no existe"; junit_finalize; }
# shellcheck source=/dev/null
. "${ENV_FILE}"
[ -n "${VPS_IP:-}" ] || { junit_skip "vps_ip" "VPS_IP no definido"; junit_finalize; }
SSH_OPTS="-p ${VPS_SSH_PORT:-22} -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no"
# shellcheck disable=SC2086
if ! ssh ${SSH_OPTS} "${VPS_USER:-jorge}@${VPS_IP}" "exit" 2>/dev/null; then
    junit_skip "ssh_unreachable" "SSH al VPS no accesible (CI o red restringida)"
    junit_finalize
fi
# shellcheck disable=SC2086
OUT="$(ssh ${SSH_OPTS} "${VPS_USER:-jorge}@${VPS_IP}" "cat /proc/sys/net/ipv4/ip_forward 2>/dev/null" 2>/dev/null || echo "")"
if [ -z "${OUT}" ]; then
    junit_fail "ip_forward_${OUT}" "comando remoto sin salida"
    junit_finalize
fi
if [ "${OUT}" = "1" ]; then
    junit_pass "ip_forward_${OUT}"
else
    junit_fail "ip_forward_${OUT}" "valor remoto inesperado: '${OUT}'"
fi
junit_finalize
