#!/usr/bin/env bash
# tools/ubond-watchdog.sh — daemon de salud del tunel ubond v2 (REQ-NET-26)
#
# Lanzado por 04b-conectar-ubond.sh en background tras configurar el utun.
# Vigila tres signals:
#   1. Proceso ubond muerto (pgrep "ubond: " sin PIDs).
#   2. Ping al gateway interno UBOND_TUN_VPS_IP falla repetidamente.
#   3. Flag-file generated/ubond_unhealthy tocado por el statuscommand
#      (rtun_down/tuntap_down) — señal más rápida que el ping.
#
# Cuando el threshold se cruza, invoca SOS.sh para restaurar conectividad
# automáticamente y notifica vía osascript. NO requiere intervención humana.
#
# Diseñado tras incidente AVE 2026-06-01 donde v2+replicación cayó dos
# veces y el usuario tuvo que ejecutar SOS.sh manualmente.
#
# Pide root al script padre (04b ya lo verifica con require_root). Aquí
# solo asumimos que ya somos root para invocar pkill / SOS.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/generated"
PID_FILE="${GENERATED_DIR}/ubond_watchdog.pid"
LOG="${GENERATED_DIR}/ubond_watchdog.log"
HEALTH_FLAG="${GENERATED_DIR}/ubond_unhealthy"

# Tunables — defaults para AVE noisy
TICK_S="${WATCHDOG_TICK_S:-5}"
FAIL_THRESHOLD="${WATCHDOG_FAIL_THRESHOLD:-4}"   # 4 × 5s = 20s sin red → SOS
PING_TIMEOUT_S="${WATCHDOG_PING_TIMEOUT_S:-2}"
SOS_COOLDOWN_S="${WATCHDOG_SOS_COOLDOWN_S:-60}"  # evitar spam SOS
TARGET="${UBOND_TUN_VPS_IP:-10.10.20.1}"
SOS_SCRIPT="${SCRIPT_DIR}/SOS.sh"

log() { printf '%s %s\n' "$(date -Iseconds)" "$*" >>"${LOG}"; }
notify() {
    osascript -e "display notification \"$1\" with title \"ubond-watchdog\"" \
        2>/dev/null || true
}

# Si ya hay un watchdog corriendo, salir (idempotencia).
if [[ -f "${PID_FILE}" ]]; then
    old_pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
    if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
        echo "watchdog ya corriendo (pid ${old_pid})" >&2
        exit 0
    fi
    rm -f "${PID_FILE}"
fi

echo "$$" >"${PID_FILE}"
trap 'rm -f "${PID_FILE}"; log "watchdog terminado"; exit 0' INT TERM EXIT

log "watchdog arrancado (target=${TARGET}, tick=${TICK_S}s, threshold=${FAIL_THRESHOLD}, cooldown=${SOS_COOLDOWN_S}s)"

fails=0
last_sos=0

trigger_sos() {
    local now reason="$1"
    now="$(date +%s)"
    if (( now - last_sos < SOS_COOLDOWN_S )); then
        log "SOS en cooldown (${SOS_COOLDOWN_S}s desde último) — esperando, motivo='${reason}'"
        return 1
    fi
    last_sos="${now}"
    log "TRIGGER SOS — motivo='${reason}'"
    notify "ubond ${reason} — restaurando red automáticamente"
    if [[ -x "${SOS_SCRIPT}" ]]; then
        bash "${SOS_SCRIPT}" >>"${LOG}" 2>&1 || true
    else
        log "ERROR: ${SOS_SCRIPT} no ejecutable — limpieza manual requerida"
    fi
    rm -f "${HEALTH_FLAG}"
    return 0
}

while :; do
    sleep "${TICK_S}"

    # 1) ¿Sigue vivo el binario? Sin él, el túnel está muerto.
    if ! pgrep -f "ubond: " >/dev/null 2>&1; then
        trigger_sos "proceso ubond ausente" || true
        # Tras SOS, no tiene sentido continuar — SOS habrá matado todo.
        exit 0
    fi

    # 2) Health flag tocado por updown handler.
    if [[ -f "${HEALTH_FLAG}" ]]; then
        flag_age=$(($(date +%s) - $(stat -f %m "${HEALTH_FLAG}" 2>/dev/null || echo 0)))
        if (( flag_age < TICK_S * 2 )); then
            log "health flag fresco (${flag_age}s) — link reportó down"
            fails=$((fails + 1))
        else
            # Flag viejo y stale, limpiarlo.
            rm -f "${HEALTH_FLAG}"
        fi
    fi

    # 3) Ping al gateway interno. Si falla, contar.
    if ping -c 1 -t "${PING_TIMEOUT_S}" "${TARGET}" >/dev/null 2>&1; then
        if (( fails > 0 )); then
            log "recuperado tras ${fails} fallos consecutivos"
        fi
        fails=0
        continue
    fi
    fails=$((fails + 1))
    log "health fail ${fails}/${FAIL_THRESHOLD} (ping ${TARGET})"

    if (( fails >= FAIL_THRESHOLD )); then
        if trigger_sos "sin respuesta ${TARGET} ${fails}×${TICK_S}s"; then
            exit 0
        fi
        # cooldown impide SOS — resetear contador para no logear spam
        fails=0
    fi
done
