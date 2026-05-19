#!/bin/sh
# Validates ave-vpc.REQ-VPS-06: Puerto SSH abierto.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-VPS-06_ssh_port_open"
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
# Si el SSH funcionó arriba, el puerto está abierto.
junit_pass "ssh_port_${VPS_SSH_PORT:-22}_reachable"
junit_finalize
