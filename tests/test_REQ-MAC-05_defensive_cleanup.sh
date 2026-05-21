#!/bin/sh
# Validates ave-vpc.REQ-MAC-05: cleanup defensivo de instancias mlvpn previas.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-MAC-05_defensive_cleanup"

CONNECT="$(dirname "$0")/../04-conectar.sh"
DISCONNECT="$(dirname "$0")/../05-desconectar.sh"

[ -f "${CONNECT}" ] || { junit_fail "connect_missing" "04-conectar.sh no existe"; junit_finalize; }
[ -f "${DISCONNECT}" ] || { junit_fail "disconnect_missing" "05-desconectar.sh no existe"; junit_finalize; }

# Check 1: 04-conectar.sh detecta instancias previas con pgrep antes de arrancar
if grep -q 'Detectadas instancias mlvpn previas' "${CONNECT}"; then
    junit_pass "connect_detects_previous_instances"
else
    junit_fail "detection_missing" "no hay detección de instancias mlvpn previas en 04-conectar.sh"
fi

# Check 2: cleanup pkill defensivo en 04-conectar.sh
if grep -q 'pkill -f "mlvpn: mlvpn0"' "${CONNECT}" \
   && grep -q 'pkill -9 -f "mlvpn: mlvpn0"' "${CONNECT}" \
   && grep -q 'pkill -f "tee.*mlvpn.log"' "${CONNECT}"; then
    junit_pass "connect_defensive_pkill"
else
    junit_fail "pkill_missing" "cleanup pkill defensivo no encontrado en 04-conectar.sh"
fi

# Check 3: el cleanup va antes de arrancar el binario mlvpn
LINE_CLEANUP=$(grep -n 'Detectadas instancias mlvpn previas' "${CONNECT}" | head -1 | cut -d: -f1)
LINE_MLVPN_BIN=$(grep -n '"\${MLVPN_BIN}"' "${CONNECT}" | head -1 | cut -d: -f1)
if [ -n "${LINE_CLEANUP}" ] && [ -n "${LINE_MLVPN_BIN}" ] \
   && [ "${LINE_CLEANUP}" -lt "${LINE_MLVPN_BIN}" ]; then
    junit_pass "cleanup_before_mlvpn_start"
else
    junit_fail "cleanup_order_wrong" "el cleanup defensivo debe ir antes de arrancar mlvpn"
fi

# Check 4: 05-desconectar.sh verifica que ningún proceso sobrevivió al pkill -9
if grep -q 'AVISO: quedan procesos mlvpn vivos' "${DISCONNECT}" \
   && grep -q 'pgrep -f "mlvpn: mlvpn0"' "${DISCONNECT}"; then
    junit_pass "disconnect_verifies_no_survivors"
else
    junit_fail "verify_missing" "05-desconectar.sh no verifica supervivientes tras pkill -9"
fi

# Check 5: 05-desconectar.sh confirma "todas las instancias" cuando funciona
if grep -q "todas las instancias" "${DISCONNECT}"; then
    junit_pass "disconnect_success_message_explicit"
else
    junit_fail "success_message_missing" "no se confirma 'todas las instancias' en 05-desconectar.sh"
fi

junit_finalize
