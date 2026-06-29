#!/bin/bash
# safe-bw-test.sh — mide throughput/CPU de ubond con DEAD-MAN'S SWITCH.
#
# Levanta ubond (captura la ruta por defecto), mide, y SIEMPRE revierte:
#   1. trap EXIT          -> desconecta pase lo que pase (fin/error/kill).
#   2. timeout duro       -> watchdog que mata todo a los MAX_SECONDS.
#   3. watchdog de red    -> si internet falla N veces seguidas, revierte ya.
#
# Resultados a /tmp/safe-bw-result.txt (persisten aunque caiga la conexión).
# Debe ejecutarse como root (un único sudo; sin askpass posterior).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESULT=/tmp/safe-bw-result.txt
MAX_SECONDS=90          # timeout duro global
NET_FAIL_LIMIT=4        # nº de fallos seguidos de internet -> revertir
RPI=192.168.1.101
TUN_VPS=10.10.20.1
: > "${RESULT}"

log(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "${RESULT}"; }

revert(){
  log "REVERT: desconectando ubond..."
  bash "${ROOT}/05b-desconectar-ubond.sh" >>"${RESULT}" 2>&1 || pkill -f "ubond: ubond0" 2>/dev/null
  # matar iperf3 remoto best-effort
  ssh -o ConnectTimeout=4 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -p 22 jorge@"${RPI}" 'pkill -f "iperf3 -s"' 2>/dev/null
  log "REVERT done."
}
trap revert EXIT

# --- timeout duro: proceso guardián que se autodestruye ---
SELF_PID=$$
( sleep "${MAX_SECONDS}"; echo "[GUARD] timeout ${MAX_SECONDS}s alcanzado, matando" >>"${RESULT}"; kill -TERM "${SELF_PID}" 2>/dev/null ) &
GUARD=$!
# si el script acaba antes, matar el guardián
trap 'kill "${GUARD}" 2>/dev/null; revert' EXIT

# --- watchdog de conectividad: revierte si internet cae ---
netwatch(){
  local fails=0
  while true; do
    if ping -c1 -t2 1.1.1.1 >/dev/null 2>&1; then
      fails=0
    else
      fails=$((fails+1))
      echo "[NETWATCH] internet KO ($fails/${NET_FAIL_LIMIT})" >>"${RESULT}"
      if [ "${fails}" -ge "${NET_FAIL_LIMIT}" ]; then
        echo "[NETWATCH] límite alcanzado -> kill script" >>"${RESULT}"
        kill -TERM "${SELF_PID}" 2>/dev/null
        return
      fi
    fi
    sleep 2
  done
}
netwatch & NETW=$!
trap 'kill "${GUARD}" "${NETW}" 2>/dev/null; revert' EXIT

# === 1. iperf3 server en RPi: se arranca FUERA (como usuario lazaromj, ver
#        wrapper). Aquí solo verificamos que escucha en 5201 vía LAN. ===
log "Verificando iperf3 server en RPi (5201)..."
if nc -G 4 -z "${RPI}" 5201 2>/dev/null; then
  log "  iperf3 server 5201 OK"
else
  log "  WARN: iperf3 server no responde en 5201 (throughput puede fallar)"
fi

# === 2. levantar ubond (1 link iPhone) ===
log "Levantando ubond (--sin-wifi)..."
bash "${ROOT}/04b-conectar-ubond.sh" --sin-wifi >>"${RESULT}" 2>&1 &
# esperar autenticación (máx 25s)
for _ in $(seq 1 25); do
  PID=$(pgrep -f "ubond: ubond0 @" | head -1)
  [ -n "${PID}" ] && break
  sleep 1
done
if [ -z "${PID:-}" ]; then log "ubond NO autenticó; abortando"; exit 1; fi
log "ubond UP pid=${PID}"

# === 3. medir ===
log "--- latencia/pérdida por túnel ---"
ping -c5 -t6 "${TUN_VPS}" 2>&1 | grep -E "loss|min/avg" | tee -a "${RESULT}"

log "--- CPU ubond (Mac) durante iperf, 6 muestras ---"
( for _ in 1 2 3 4 5 6; do ps -o %cpu= -p "${PID}" 2>/dev/null | tr -d ' '; sleep 1; done > /tmp/cpu_mac.txt ) &

log "--- throughput iperf3 (5s, túnel, -O1 omite warmup) ---"
timeout 12 iperf3 -c "${TUN_VPS}" -t 5 -O 1 2>&1 | grep -E "sender|receiver" | tee -a "${RESULT}"

# CPU del RPi se mide FUERA (wrapper como usuario lazaromj), en paralelo.

wait 2>/dev/null || true
log "--- CPU Mac (muestras) ---"
tr '\n' ' ' < /tmp/cpu_mac.txt | tee -a "${RESULT}"; echo "" | tee -a "${RESULT}"

log "MEDICIÓN COMPLETA."
# trap EXIT revierte ahora
