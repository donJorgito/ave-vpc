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
# REQ-NET-30 follow-up (SOS investigator 2026-06-03): threshold de 4 (20s)
# era demasiado agresivo para móvil con expiración NAT en idle. Tras ~10
# min sin tráfico el operador 4G droppea el UDP mapping; recuperación por
# el primer paquete real tarda 5-15s, pero el watchdog ya cae a 20s y
# dispara SOS innecesario. Subido a 8 (40s) para dar margen. Override:
#   WATCHDOG_FAIL_THRESHOLD=12 ./tools/ubond-watchdog.sh   # 60s sin red
FAIL_THRESHOLD="${WATCHDOG_FAIL_THRESHOLD:-8}"   # 8 × 5s = 40s sin red → SOS
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

    # 3) Ping al gateway interno por dentro del utun de ubond.
    #
    # ATENCIÓN: NO usar `ping ${TARGET}` global. La subnet del túnel
    # (10.10.20.0/24) puede colisionar con redes corporativas reales —
    # observado en oficina Roche, donde un host random respondía a
    # 10.10.20.1 con ttl=239, dando falso "túnel sano" sin haberlo.
    # Bug detectado en test B 2026-06-02. El ping debe forzarse por
    # la utun del túnel; si no existe utun con UBOND_TUN_MAC_IP, el
    # túnel está caído por definición.
    UTUN=""
    for i in $(seq 0 15); do
        if ifconfig "utun${i}" 2>/dev/null \
                | awk '$1 == "inet" && $2 == "'"${UBOND_TUN_MAC_IP:-10.10.20.2}"'" {found=1} END {exit !found}'; then
            UTUN="utun${i}"
            break
        fi
    done

    if [[ -z "${UTUN}" ]]; then
        fails=$((fails + 1))
        log "health fail ${fails}/${FAIL_THRESHOLD} (sin utun ubond — túnel caído)"
    elif ping -c 1 -t "${PING_TIMEOUT_S}" -b "${UTUN}" "${TARGET}" >/dev/null 2>&1; then
        if (( fails > 0 )); then
            log "recuperado tras ${fails} fallos consecutivos"
        fi
        fails=0
        continue
    else
        fails=$((fails + 1))
        log "health fail ${fails}/${FAIL_THRESHOLD} (ping ${TARGET} via ${UTUN} KO)"
    fi

    if (( fails >= FAIL_THRESHOLD )); then
        if trigger_sos "sin respuesta ${TARGET} ${fails}×${TICK_S}s"; then
            exit 0
        fi
        # cooldown impide SOS — resetear contador para no logear spam
        fails=0
    fi
done
