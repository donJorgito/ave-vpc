#!/bin/sh
# Validates ave-vpc.REQ-VPS-02: CPU mínima 1 vCPU.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-VPS-02_cpu_min_1vcpu"
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
OUT="$(ssh ${SSH_OPTS} "${VPS_USER:-jorge}@${VPS_IP}" "nproc" 2>/dev/null || echo "")"
if [ -z "${OUT}" ]; then
    junit_fail "nproc_${OUT}" "comando remoto sin salida"
    junit_finalize
fi
if [ "${OUT}" -ge 1 ] 2>/dev/null; then
    junit_pass "nproc_${OUT}"
else
    junit_fail "nproc_${OUT}" "valor remoto inesperado: '${OUT}'"
fi
junit_finalize
