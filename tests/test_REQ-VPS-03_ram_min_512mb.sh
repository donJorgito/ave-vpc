#!/bin/sh
# Validates ave-vpc.REQ-VPS-03: RAM mínima 512 MB.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-VPS-03_ram_min_512mb"
ENV_FILE="$(dirname "$0")/../config/env"
[ -f "${ENV_FILE}" ] || { junit_skip "config_env" "config/env no existe"; junit_finalize; }
# shellcheck source=/dev/null
. "${ENV_FILE}"
[ -n "${VPS_IP:-}" ] || { junit_skip "vps_ip" "VPS_IP no definido"; junit_finalize; }
SSH_OPTS="-p ${VPS_SSH_PORT:-22} -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no"
# shellcheck disable=SC2086
if ! ssh ${SSH_OPTS} "${VPS_USER:-jorge}@${VPS_IP}" "exit" 2>/dev/null; then
    junit_skip "ssh_unreachable" "SSH al VPS no accesible"
    junit_finalize
fi
# Leemos MemTotal en KB y dividimos por 1024 en local — más robusto que awk remoto
KB="$(ssh ${SSH_OPTS} "${VPS_USER:-jorge}@${VPS_IP}" "grep MemTotal /proc/meminfo" 2>/dev/null | grep -oE '[0-9]+' | head -1)"
if [ -z "${KB}" ]; then
    junit_fail "ram_query_failed" "no se pudo leer MemTotal"
    junit_finalize
fi
MB=$((KB / 1024))
if [ "${MB}" -ge 512 ] 2>/dev/null; then
    junit_pass "ram_${MB}MB"
else
    junit_fail "ram_${MB}MB" "RAM ${MB}MB < 512MB"
fi
junit_finalize
