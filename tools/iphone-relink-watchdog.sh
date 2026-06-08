#!/usr/bin/env bash
# tools/iphone-relink-watchdog.sh — REQ-NET-34
# Detecta link ubond down >N segundos y fuerza un evento de
# desconexión-reconexión USB de la iface tethering. Esto provoca al
# modem del iPhone una renegociación PDP/CGNAT en el operador 4G,
# que crea un mapping NAT fresco al primer paquete post-up — sin que
# el sport efímero del Mac cambie.
#
# Mecanismo real (validado análisis pcap AVE 2026-06-05, sesión
# 2026-06-08): el `ifconfig en8 down` notifica vía USB-CDC al iPhone
# que su iface tethering se cierra; al `up`, el iPhone renegocia
# session PDP. Movistar (CGNAT) ve session-teardown, descarta el
# mapping muerto, y crea uno nuevo al primer paquete TX post-up.
# El sport del Mac (55478 en el trayecto observado) NO cambia —
# la "frescura" es carrier-side. Hipótesis original "ubond rebinda
# socket nuevo → sport fresco" descartada (los pcaps muestran sport
# idéntico antes y después de la actuación).
#
# Complementario a REQ-NET-35 (rebind socket en C, futuro): NET-35
# fuerza nuevo sport efímero local (caso "operador acepta nueva
# 5-tupla"); NET-34 fuerza PDP refresh carrier-side (caso "operador
# tiene PDP context muerto"). Ambos cubren escenarios distintos.
# Validado AVE 2026-06-05 — 3 actuaciones recuperaron el link sin
# intervención humana.
#
# Diseño: lee proctitle ubond ("ubond: ubond0 @links.X !links.Y ~links.Z").
# Si LINK_NAME aparece como `!` durante FAIL_THRESHOLD ticks consecutivos,
# bajo/subo IFACE. Cooldown evita re-flap loop.
#
# Lanzar como root (necesario para ifconfig down/up):
#   sudo RELINK_LINK_NAME=iphone RELINK_IFACE=en8 tools/iphone-relink-watchdog.sh
#
# Variables override:
#   RELINK_LINK_NAME    nombre tras "links." en proctitle (iphone, pixel, wifi)
#   RELINK_IFACE        iface física Mac (en8 iphone tethering, en12 pixel)
#   RELINK_TICK_S       intervalo poll (default 5)
#   RELINK_FAIL_THRESHOLD  fails antes de actuar (default 12 = 60s)
#   RELINK_COOLDOWN_S   tras acción no actuar de nuevo (default 90)
#   RELINK_GAP_S        sleep entre down y up (default 2)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/generated"
LOG="${GENERATED_DIR}/iphone_relink_watchdog.log"
PID_FILE="${GENERATED_DIR}/iphone_relink_watchdog.pid"
CONFIG_FILE="${SCRIPT_DIR}/config/env"

# Cargar config/env para defaults coherentes con resto de scripts
# (IFACE_IPHONE, etc.). Silenciar si no existe — fallback a defaults.
# shellcheck source=/dev/null
[[ -r "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}" 2>/dev/null || true

LINK_NAME="${RELINK_LINK_NAME:-iphone}"
# IDLC R4 (no hardcoding): usar IFACE_IPHONE de config/env si existe,
# fallback a en8 (default histórico para tethering iPhone via USB en
# este Mac). Override explícito vía RELINK_IFACE.
IFACE="${RELINK_IFACE:-${IFACE_IPHONE:-en8}}"
TICK_S="${RELINK_TICK_S:-5}"
FAIL_THRESHOLD="${RELINK_FAIL_THRESHOLD:-12}"
COOLDOWN_S="${RELINK_COOLDOWN_S:-90}"
DOWN_UP_GAP_S="${RELINK_GAP_S:-2}"

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG" >&2; }

cleanup() { rm -f "$PID_FILE"; exit 0; }
trap cleanup INT TERM

mkdir -p "$GENERATED_DIR"

# Anti doble-lanzamiento: si ya hay un watchdog activo (PID file fresco
# y proceso vivo), salir limpio. Evita que dos invocaciones de 04b
# (relaunch tras SOS, debug session, etc.) generen dos watchdogs
# pisándose en ifconfig down/up. Caveat C/network supervisor 2026-06-08.
if [[ -e "${PID_FILE}" ]]; then
    OLD_PID="$(cat "${PID_FILE}" 2>/dev/null || echo)"
    if [[ -n "${OLD_PID}" ]] && kill -0 "${OLD_PID}" 2>/dev/null; then
        echo "iphone-relink-watchdog ya corriendo (pid=${OLD_PID}); exit" >&2
        exit 0
    fi
fi

echo $$ > "$PID_FILE"
log "start link=$LINK_NAME iface=$IFACE threshold=${FAIL_THRESHOLD}x${TICK_S}s cooldown=${COOLDOWN_S}s"

if [[ "${EUID}" -ne 0 ]]; then
    log "ERROR: requiere root (ifconfig down/up). Lanza con sudo."
    exit 1
fi

fail_count=0
last_action_ts=0

while true; do
    sleep "$TICK_S"
    pid=$(pgrep -f '^ubond: ubond0 [@!~]' | head -1)
    if [[ -z "$pid" ]]; then
        if (( fail_count > 0 )); then
            log "ubond not running (fail_count=$fail_count → 0)"
            fail_count=0
        fi
        continue
    fi
    title="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    if [[ "$title" == *"!links.${LINK_NAME}"* ]]; then
        fail_count=$((fail_count + 1))
        log "link=$LINK_NAME DOWN ($fail_count/$FAIL_THRESHOLD)"
    else
        if (( fail_count > 0 )); then
            log "link=$LINK_NAME recovered (fail_count was $fail_count)"
        fi
        fail_count=0
        continue
    fi

    if (( fail_count >= FAIL_THRESHOLD )); then
        now=$(date +%s)
        if (( now - last_action_ts < COOLDOWN_S )); then
            log "cooldown active ($((COOLDOWN_S - (now - last_action_ts)))s), skip"
            continue
        fi
        log "ACTION: ifconfig $IFACE down → sleep ${DOWN_UP_GAP_S}s → up — refrescando NAT mapping"
        if ifconfig "$IFACE" down 2>>"$LOG"; then
            sleep "$DOWN_UP_GAP_S"
            if ifconfig "$IFACE" up 2>>"$LOG"; then
                log "ACTION done; ubond debería rebindar en <30s"
                osascript -e "display notification \"link $LINK_NAME relinked\" with title \"ubond watchdog\"" 2>/dev/null || true
            else
                log "ifconfig up FAILED"
            fi
        else
            log "ifconfig down FAILED"
        fi
        last_action_ts=$now
        fail_count=0
    fi
done
