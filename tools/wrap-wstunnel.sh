#!/usr/bin/env bash
# tools/wrap-wstunnel.sh — REQ-NET-39 Vía B (UDP-over-WebSocket/TLS, wstunnel)
#
# Wrapper EXTERIOR a ubond para cruzar el firewall del WiFi del AVE. ubond es
# UDP-only por diseño (SOCK_DGRAM + libsodium por datagrama) — NO SE TOCA.
# Esta vía mete el UDP de ubond dentro de un WebSocket; con TLS (WSS) viaja
# como HTTPS legítimo por el puerto 443.
#
#   ubond client --UDP--> 127.0.0.1:LOCAL_PORT (wstunnel client)
#       ==WSS (wss://RPi:WS_PORT)==> RPi:WS_PORT (wstunnel server)
#       --UDP--> 127.0.0.1:5085 (ubond server real)
#
# POR QUÉ WSS-sobre-443 puede atravesar un proxy TLS-TERMINATING que faketcp
# (Vía A) NO puede:
#   - El DNAT :443 del AVE redirige el SYN al portal; si además TERMINA TLS
#     (proxy real que mira SNI/Host), solo deja pasar HTTPS bien formado. Un
#     faketcp (Vía A) no es TLS → lo descarta. Un WSS sí es TLS real con
#     handshake completo + Upgrade: websocket, indistinguible de un navegador
#     hablando HTTPS. Si el proxy reenvía por Host/SNI a un origin arbitrario
#     (no valida que el backend sea el portal), el WebSocket se establece a
#     través del propio proxy y tunelamos el UDP por dentro.
#   - Es la vía MÁS ROBUSTA frente a un MitM real: cuanto más "se parece a
#     HTTPS de navegador", más difícil de capar sin romper la web entera.
#
# CUÁNDO FALLA (límites — sección 2 plan 13):
#   - Si el proxy VALIDA que el backend es el portal cautivo y rechaza origins
#     arbitrarios, corta el Upgrade. Mitigación parcial: variante sin-TLS hacia
#     un puerto alto limpio (ws:// 8080) si el problema es solo la validación
#     TLS, no el DNAT.
#   - Necesita un endpoint TLS válido en la RPi (cert). Con --tls-* wstunnel
#     puede usar self-signed (cliente con -k/--tls-verify-certificate=false).
#
# Uso:
#   tools/wrap-wstunnel.sh                 # arranca WSS (TLS, default)
#   WRAP_WS_TLS=0 tools/wrap-wstunnel.sh   # variante ws:// sin TLS
#   tools/wrap-wstunnel.sh --check         # verifica binario instalado
#   tools/wrap-wstunnel.sh --stop          # mata la instancia activa
#   tools/wrap-wstunnel.sh --server-cmd    # imprime SOLO el comando RPi
#
# Variables override (defaults sin hardcoding):
#   WRAP_LOCAL_PORT   puerto UDP local que expone wstunnel (default 5085)
#   WRAP_REMOTE_HOST  host RPi (default VPS_IP)
#   WS_PORT           puerto del wstunnel server (default 443 TLS / 8080 sin TLS)
#   WRAP_WS_TLS       1 = WSS (default), 0 = ws:// sin TLS
#   UBOND_PORT_3      puerto UDP real de ubond en la RPi (default 5085)

set -uo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: requiere bash >= 4 (tienes ${BASH_VERSION}). brew install bash" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/generated"
CONFIG_FILE="${SCRIPT_DIR}/config/env"
PID_FILE="${GENERATED_DIR}/wrap_wstunnel.pid"
LOG="${GENERATED_DIR}/wrap_wstunnel.log"

# Versión PINNED (Rule 7 IDLC). wstunnel v10.x (Rust, erebe/wstunnel).
# OJO: la CLI de v10 (wss://... + 'client'/'server' subcomandos) difiere de
# la serie v6 antigua. Este script asume v10.
WSTUNNEL_PINNED_VERSION="10.5.5"

mkdir -p "${GENERATED_DIR}"

# shellcheck source=/dev/null
[[ -r "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}" 2>/dev/null || true

LOCAL_PORT="${WRAP_LOCAL_PORT:-${UBOND_PORT_3:-5085}}"
REMOTE_HOST="${WRAP_REMOTE_HOST:-${VPS_IP:-}}"
UBOND_REAL_PORT="${UBOND_PORT_3:-5085}"
USE_TLS="${WRAP_WS_TLS:-1}"

# Puerto y esquema según TLS. 443 para WSS (parece HTTPS, atraviesa proxy
# TLS-terminating). 8080 para ws:// sin TLS (puerto alto limpio).
if [[ "${USE_TLS}" == "1" ]]; then
    WS_PORT="${WS_PORT:-443}"
    WS_SCHEME="wss"
else
    WS_PORT="${WS_PORT:-8080}"
    WS_SCHEME="ws"
fi

log() {
    local msg="$*"
    logger -t wrap-wstunnel "${msg}" 2>/dev/null || true
    printf '%s %s\n' "$(date -u +%FT%TZ)" "${msg}" | tee -a "${LOG}" >&2
}

print_server_cmd() {
    cat <<EOF
# ---- Comando a ejecutar en la RPi (${REMOTE_HOST:-VPS_IP}) — NO lo lanza este script ----
# Espejo server-side de la Vía B (wstunnel v${WSTUNNEL_PINNED_VERSION}, CLI v10).
# El server acepta WebSocket y reenvía a destinos UDP restringidos a ubond.
EOF
    if [[ "${USE_TLS}" == "1" ]]; then
        cat <<EOF
# Variante WSS (TLS). Necesita cert; con --tls-certificate / --tls-private-key
# o cert self-signed. <443 requiere root o CAP_NET_BIND_SERVICE.
sudo wstunnel server \\
    --restrict-to 127.0.0.1:${UBOND_REAL_PORT} \\
    "wss://0.0.0.0:${WS_PORT}"
EOF
    else
        cat <<EOF
# Variante ws:// SIN TLS (puerto alto limpio, fallback de diagnóstico).
wstunnel server \\
    --restrict-to 127.0.0.1:${UBOND_REAL_PORT} \\
    "ws://0.0.0.0:${WS_PORT}"
EOF
    fi
    cat <<EOF
# --restrict-to limita los destinos que el server reenvía (no open-relay).
# ------------------------------------------------------------------------------
EOF
}

do_check() {
    if command -v wstunnel >/dev/null 2>&1; then
        local have
        have="$(wstunnel --version 2>/dev/null | head -1 || true)"
        echo "OK: wstunnel presente (${have:-versión desconocida})"
        echo "    (versión pineada esperada: ${WSTUNNEL_PINNED_VERSION}, CLI v10)"
        return 0
    fi
    cat >&2 <<EOF
FALTA: wstunnel no está instalado.
  macOS:  brew install wstunnel      # pin: wstunnel ${WSTUNNEL_PINNED_VERSION}
  RPi:    descargar binario release v${WSTUNNEL_PINNED_VERSION} de
          github.com/erebe/wstunnel/releases (arm64/armv7 según RPi)
EOF
    return 1
}

do_stop() {
    if [[ -f "${PID_FILE}" ]]; then
        local pid
        pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            kill "${pid}" 2>/dev/null || true
            log "wrap-wstunnel detenido (pid ${pid})"
        fi
        rm -f "${PID_FILE}"
    else
        echo "wrap-wstunnel no estaba corriendo" >&2
    fi
}

case "${1:-}" in
    --check)      do_check; exit $? ;;
    --stop)       do_stop;  exit 0 ;;
    --server-cmd) print_server_cmd; exit 0 ;;
    "")           : ;;
    *) echo "uso: $0 [--check|--stop|--server-cmd]" >&2; exit 2 ;;
esac

# Idempotencia.
if [[ -f "${PID_FILE}" ]]; then
    old_pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
    if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
        echo "wrap-wstunnel ya corriendo (pid ${old_pid}); exit" >&2
        exit 0
    fi
    rm -f "${PID_FILE}"
fi

do_check >/dev/null 2>&1 || { do_check; exit 1; }
if [[ -z "${REMOTE_HOST}" ]]; then
    log "ERROR: WRAP_REMOTE_HOST/VPS_IP no definido — no sé a qué RPi conectar"
    exit 1
fi

log "arrancando wstunnel ${WS_SCHEME}: UDP local ${LOCAL_PORT} <-> ${WS_SCHEME}://${REMOTE_HOST}:${WS_PORT}"
print_server_cmd

# wstunnel cliente (CLI v10): expone un listener UDP local que tunela hacia
# el destino UDP (ubond real) a través del WebSocket al server RPi.
# -L udp://LOCAL:127.0.0.1:DEST → escucha UDP local, entrega a DEST por el WS.
#
# CRÍTICO (revisión seguridad 2026-06-11): NO desactivar la verificación de
# cert por defecto. Renfe MitM-ea TODO TCP/443 con cert `playrenfe` (doc 12).
# Con --tls-verify-certificate=false el cliente completa el handshake CONTRA
# EL MitM de Renfe y reporta un FALSO PASS: justo la vía que debe SOBREVIVIR
# al MitM quedaría ciega a él. Para el test real a bordo hay que PINEAR el
# cert del RPi (rechazar el de Renfe). El skip-verify solo se permite como
# opt-in explícito para pruebas en WiFi controlada (oficina), nunca en tren.
#   WS_INSECURE_SKIP_VERIFY=1  → desactiva verify (SOLO lab)
# TODO REQ-NET-39 (a bordo): sustituir por pinning del cert RPi. Verificar el
# flag exacto de pinning en wstunnel ${WSTUNNEL_PINNED_VERSION} on-device.
WS_TLS_FLAGS=()
if [[ "${USE_TLS}" == "1" && "${WS_INSECURE_SKIP_VERIFY:-0}" == "1" ]]; then
    log "AVISO: TLS verify DESACTIVADO (WS_INSECURE_SKIP_VERIFY=1) — SOLO lab. En tren esto da FALSO PASS contra el MitM de Renfe."
    WS_TLS_FLAGS+=("--tls-verify-certificate=false")
fi

wstunnel client \
    -L "udp://${LOCAL_PORT}:127.0.0.1:${UBOND_REAL_PORT}" \
    "${WS_TLS_FLAGS[@]}" \
    "${WS_SCHEME}://${REMOTE_HOST}:${WS_PORT}" >>"${LOG}" 2>&1 &
child=$!
echo "${child}" >"${PID_FILE}"
log "wstunnel lanzado (pid ${child}). PID file: ${PID_FILE}"

trap 'kill "${child}" 2>/dev/null || true; rm -f "${PID_FILE}"; log "wrap-wstunnel terminado"; exit 0' INT TERM

wait "${child}"
rm -f "${PID_FILE}"
