#!/bin/sh
# Validates ave-vpc.REQ-VPS-07: Puertos UDP 5080-5082 abiertos.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-VPS-07_udp_5080_5082"
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
# Comprobar cada puerto en escucha UDP (sin requerir sudo: ss -uln basta)
PORT_1="${MLVPN_PORT_1:-5080}"
PORT_2="${MLVPN_PORT_2:-5081}"
PORT_3="${MLVPN_PORT_3:-5082}"
# shellcheck disable=SC2086
LISTEN="$(ssh ${SSH_OPTS} "${VPS_USER:-jorge}@${VPS_IP}" "ss -uln" 2>/dev/null || echo "")"
for p in "${PORT_1}" "${PORT_2}" "${PORT_3}"; do
    if echo "${LISTEN}" | grep -qE ":(${p})[[:space:]]"; then
        junit_pass "udp_port_${p}_listening"
    else
        junit_fail "udp_port_${p}_not_listening" "puerto ${p}/udp no en escucha"
    fi
done
junit_finalize
