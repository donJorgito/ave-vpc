#!/usr/bin/env bash
# tools/wrap-socat.sh — REQ-NET-39 Vía C (baseline UDP-over-TCP con socat)
#
# Wrapper EXTERIOR a ubond para cruzar el firewall del WiFi del AVE, que
# bloquea TODO el UDP outbound (confirmado 2026-06-09) y DNAT-ea tcp/80+443
# al portal cautivo. ubond es UDP-only por diseño (SOCK_DGRAM + crypto
# libsodium por datagrama) — NO SE TOCA. Este wrapper va por fuera:
#
#   ubond client  --UDP-->  127.0.0.1:LOCAL_PORT (socat) ==TCP==> RPi:WRAP_PORT
#   (socat RPi) --UDP--> 127.0.0.1:5085 (ubond server real)
#
# El cliente ubond apunta su [links.wifi] a 127.0.0.1:LOCAL_PORT en vez de
# a VPS_IP:443/udp. Esta vía es el BASELINE: la más simple de montar y
# diagnosticar. Sirve para confirmar que ubond TOLERA ir sobre TCP antes
# de pelear con sigilo (Vía A udp2raw / Vía B wstunnel). No es sigilosa:
# un TCP "de verdad" a un puerto random pasa solo si Renfe NO DNAT-ea todo
# el rango TCP (hipótesis sección 2 del plan 13).
#
# Diseño house-style: set -uo pipefail, bash>=4 guard, PID file en
# generated/, idempotente (rechaza doble lanzamiento), logger -t,
# imprime el comando server-side exacto a ejecutar en la RPi (NO hace ssh).
#
# Uso:
#   tools/wrap-socat.sh                 # arranca con defaults de config/env
#   tools/wrap-socat.sh --check         # solo verifica binario socat instalado
#   tools/wrap-socat.sh --stop          # mata la instancia activa
#   tools/wrap-socat.sh --server-cmd    # imprime SOLO el comando RPi y sale
#
# Variables override (todas con default desde config/env, sin hardcoding):
#   WRAP_LOCAL_PORT   puerto UDP local que escucha socat (default 5085)
#   WRAP_REMOTE_HOST  host del wrapper-server RPi (default VPS_IP)
#   WRAP_REMOTE_PORT  puerto TCP del wrapper-server RPi (default 5085)
#   UBOND_PORT_3      puerto UDP real de ubond en la RPi (default 5085)

set -uo pipefail

# --- Guard bash >= 4 (asociativos/`local -n` no usados aquí, pero el resto
#     del repo exige 4+; mantener coherencia). macOS trae bash 3.2 de fábrica;
#     este repo asume el bash de Homebrew. ---
if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: requiere bash >= 4 (tienes ${BASH_VERSION}). brew install bash" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/generated"
CONFIG_FILE="${SCRIPT_DIR}/config/env"
PID_FILE="${GENERATED_DIR}/wrap_socat.pid"
LOG="${GENERATED_DIR}/wrap_socat.log"

# Versión PINNED (Rule 7 IDLC). socat 1.8.x es la rama estable actual.
SOCAT_PINNED_VERSION="1.8.1.1"

mkdir -p "${GENERATED_DIR}"

# Cargar config/env para VPS_IP / UBOND_PORT_3 (sin hardcoding — Rule 4).
# shellcheck source=/dev/null
[[ -r "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}" 2>/dev/null || true

LOCAL_PORT="${WRAP_LOCAL_PORT:-${UBOND_PORT_3:-5085}}"
REMOTE_HOST="${WRAP_REMOTE_HOST:-${VPS_IP:-}}"
REMOTE_PORT="${WRAP_REMOTE_PORT:-${UBOND_PORT_3:-5085}}"
UBOND_REAL_PORT="${UBOND_PORT_3:-5085}"

log() {
    # logger -t para syslog + tee al log local (mismo patrón que el resto).
    local msg="$*"
    logger -t wrap-socat "${msg}" 2>/dev/null || true
    printf '%s %s\n' "$(date -u +%FT%TZ)" "${msg}" | tee -a "${LOG}" >&2
}

# --- Comando server-side (RPi): el espejo del cliente. socat acepta TCP en
#     WRAP_PORT y lo entrega como UDP a 127.0.0.1:5085 (ubond real). fork
#     permite múltiples conexiones; reuseaddr evita TIME_WAIT al reiniciar. ---
#
# CAVEAT camino de respuesta (revisión 2026-06-11): con `fork`, el lado RPi
# abre un puerto UDP origen EFÍMERO distinto por cada fork hacia ubond. Las
# respuestas de ubond vuelven a ese efímero; si la conexión TCP se recicla
# (re-handshake, flap de enlace en el tren), el nuevo fork no hereda el mapeo
# y las replies pueden quedar huérfanas → pérdida en UDP-stateful. Por eso C
# es solo BASELINE diagnóstico; A (faketcp) y B (WSS) son los candidatos
# reales. OBLIGATORIO al validar C: probar tráfico de VUELTA explícitamente
# (no asumir simetría), p.ej. ping por el utun de ubond tras levantar el wrap.
print_server_cmd() {
    cat <<EOF
# ---- Comando a ejecutar en la RPi (${REMOTE_HOST:-VPS_IP}) — NO lo lanza este script ----
# Espejo server-side de la Vía C: TCP-LISTEN <-> UDP a ubond real (5085).
socat -d -d \\
    TCP4-LISTEN:${REMOTE_PORT},reuseaddr,fork \\
    UDP4:127.0.0.1:${UBOND_REAL_PORT}
#
# Opcional TLS (envoltura stunnel, NO baseline): si se quiere cifrar el hop
# Mac<->RPi, anteponer stunnel en ambos extremos y dejar socat TCP en
# localhost. Baseline = socat solo (texto claro; ubond ya cifra el payload
# con libsodium, así que el wrapper no necesita cifrar para confidencialidad,
# solo si hiciera falta evadir DPI que mire "TCP sin TLS").
# ------------------------------------------------------------------------------
EOF
}

# --- --check: ¿está socat instalado? Si no, hint de instalación PINNED. ---
do_check() {
    if command -v socat >/dev/null 2>&1; then
        local have
        have="$(socat -V 2>&1 | grep -oE 'socat version [0-9.]+' | head -1 || true)"
        echo "OK: socat presente (${have:-versión desconocida})"
        echo "    (versión pineada esperada: ${SOCAT_PINNED_VERSION})"
        return 0
    fi
    cat >&2 <<EOF
FALTA: socat no está instalado.
  macOS:  brew install socat        # pin: socat ${SOCAT_PINNED_VERSION}
  RPi:    sudo apt-get install -y socat=${SOCAT_PINNED_VERSION}-*   # o la disponible en apt
EOF
    return 1
}

# --- --stop: matar instancia activa de forma limpia. ---
do_stop() {
    if [[ -f "${PID_FILE}" ]]; then
        local pid
        pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            kill "${pid}" 2>/dev/null || true
            log "wrap-socat detenido (pid ${pid})"
        fi
        rm -f "${PID_FILE}"
    else
        echo "wrap-socat no estaba corriendo" >&2
    fi
}

case "${1:-}" in
    --check)      do_check; exit $? ;;
    --stop)       do_stop;  exit 0 ;;
    --server-cmd) print_server_cmd; exit 0 ;;
    "")           : ;;  # arranque normal
    *) echo "uso: $0 [--check|--stop|--server-cmd]" >&2; exit 2 ;;
esac

# --- Idempotencia: rechazar doble lanzamiento. ---
if [[ -f "${PID_FILE}" ]]; then
    old_pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
    if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
        echo "wrap-socat ya corriendo (pid ${old_pid}); exit" >&2
        exit 0
    fi
    rm -f "${PID_FILE}"
fi

# --- Validar prerequisitos antes de arrancar. ---
do_check >/dev/null 2>&1 || { do_check; exit 1; }
if [[ -z "${REMOTE_HOST}" ]]; then
    log "ERROR: WRAP_REMOTE_HOST/VPS_IP no definido — no sé a qué RPi conectar"
    exit 1
fi

log "arrancando socat: UDP4-LISTEN:${LOCAL_PORT} <-> TCP:${REMOTE_HOST}:${REMOTE_PORT}"
print_server_cmd

# socat cliente: escucha UDP local de ubond, lo reenvía por TCP a la RPi.
# fork: una conexión TCP por flujo UDP. reuseaddr: reinicio limpio.
socat -d -d \
    "UDP4-LISTEN:${LOCAL_PORT},reuseaddr,fork" \
    "TCP4:${REMOTE_HOST}:${REMOTE_PORT}" >>"${LOG}" 2>&1 &
child=$!
echo "${child}" >"${PID_FILE}"
log "socat lanzado (pid ${child}). PID file: ${PID_FILE}"

# Limpieza: al recibir señal, matar socat y borrar PID file.
trap 'kill "${child}" 2>/dev/null || true; rm -f "${PID_FILE}"; log "wrap-socat terminado"; exit 0' INT TERM

wait "${child}"
rm -f "${PID_FILE}"
