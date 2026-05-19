#!/bin/sh
# Validates ave-vpc.REQ-VPS-01: Ubuntu 26.04 LTS en el servidor.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-VPS-01_ubuntu_2604"
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
VER=$(ssh ${SSH_OPTS} "${VPS_USER:-jorge}@${VPS_IP}" \
    "grep '^VERSION_ID=' /etc/os-release | tr -d '\"' | cut -d= -f2" 2>/dev/null || echo "")
if [ "${VER}" = "26.04" ]; then
    junit_pass "ubuntu_${VER}"
else
    junit_fail "ubuntu_version" "VERSION_ID='${VER}' (esperado 26.04)"
fi
junit_finalize
