#!/bin/sh
# Validates ave-vpc.REQ-VPS-04: Disco mínimo 10 GB.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-VPS-04_disk_min_10gb"
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
# Comando remoto en una variable separada para evitar conflictos de quoting
REMOTE_CMD='df -BG / | awk "NR==2 {gsub(\"G\",\"\",\$2); print \$2}"'
# shellcheck disable=SC2086
OUT="$(ssh ${SSH_OPTS} "${VPS_USER:-jorge}@${VPS_IP}" "${REMOTE_CMD}" 2>/dev/null || echo "")"
if [ -z "${OUT}" ]; then
    junit_fail "disk_query_failed" "no se pudo leer el tamaño de disco"
    junit_finalize
fi
if [ "${OUT}" -ge 10 ] 2>/dev/null; then
    junit_pass "disk_${OUT}GB"
else
    junit_fail "disk_${OUT}GB" "disco ${OUT}GB < 10GB"
fi
junit_finalize
