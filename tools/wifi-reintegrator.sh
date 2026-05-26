#!/usr/bin/env bash
###############################################################################
# tools/wifi-reintegrator.sh — REQ-NET-13
#
# Watcher en background que reintenta los pre-flight checks del WiFi cada
# 30 s. Si pasan todos (captive autenticado, no es red de casa, sigue con
# IP), añade dinámicamente el bloque [links.wifi] al mlvpn_active.conf y
# manda SIGHUP a mlvpn — éste recarga la config y añade el nuevo link
# sin tirar el túnel (igual mecanismo que REQ-NET-07).
#
# Caso de uso real (visto en AVE 2026-05-25):
#   - Subes al tren, conectas WiFi → tienes IP pero captive sin autenticar
#   - Lanzas 04-conectar.sh → captive check falla → WiFi descartada
#   - En el navegador autenticas el captive → ya tienes internet por en0
#   - SIN este watcher, la WiFi quedaba fuera del bonding hasta
#     desconectar y reconectar todo el túnel
#
# Coste en datos: 1 curl https://captive.apple.com (~200 B) + 3 curls a
# servicios IP cada 30 s ≈ 80 KB/h. Se para automáticamente cuando el
# WiFi entra al bonding (no sigue pingando indefinidamente).
###############################################################################

# bash >=4 (consistencia con resto de watchers que usan arrays asociativos)
if (( BASH_VERSINFO[0] < 4 )); then
    for try_bash in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        if [[ -x "${try_bash}" ]]; then
            exec "${try_bash}" "$0" "$@"
        fi
    done
    echo "ERROR: necesita bash >=4. Instalar: brew install bash" >&2
    exit 1
fi
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/generated"
CONFIG_FILE="${SCRIPT_DIR}/config/env"
ACTIVE_CONF="${GENERATED_DIR}/mlvpn_active.conf"
PID_FILE="${GENERATED_DIR}/mlvpn_wifi_reintegrator.pid"

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

# MLVPN_PORT_3_REMOTE: si no está definido, usa el bindport interno
MLVPN_PORT_3_REMOTE="${MLVPN_PORT_3_REMOTE:-${MLVPN_PORT_3:-5082}}"

echo "$$" > "${PID_FILE}"

log() { logger -t mlvpn-wifi-reintegrator "$*"; }
trap 'rm -f "${PID_FILE}"; log "reintegrator terminado"; exit 0' INT TERM EXIT

CHECK_INTERVAL=30

# Mismas funciones de comprobación que en 04-conectar.sh — duplicadas
# aquí intencionalmente para que el watcher sea standalone (puede correr
# sin que 04-conectar.sh siga su scope).
get_public_ip_via_iface() {
    local iface="$1"
    local url ip
    for url in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
        ip="$(curl --interface "${iface}" -s --max-time 2 "${url}" 2>/dev/null | tr -d '[:space:]')"
        if [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "${ip}"
            return 0
        fi
    done
    return 1
}

resolve_vps_public_ip() {
    if [[ "${VPS_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "${VPS_IP}"
        return 0
    fi
    dig +short +time=2 +tries=1 "${VPS_IP}" A 2>/dev/null \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
        | tail -1
}

# Devuelve la IP de en0 si el WiFi pasa todos los pre-flight, vacío si no
wifi_passes_preflight() {
    local ip_wifi
    ip_wifi="$(ipconfig getifaddr "${IFACE_WIFI}" 2>/dev/null || true)"
    [[ -z "${ip_wifi}" ]] && return 1

    # 1) Captive portal autenticado
    if ! curl --interface "${IFACE_WIFI}" -s --max-time 2 \
            "http://captive.apple.com/hotspot-detect.html" 2>/dev/null \
            | grep -q "<TITLE>Success</TITLE>"; then
        return 1
    fi

    # 2) No es red de casa (REQ-NET-08)
    local wifi_pub rpi_pub
    wifi_pub="$(get_public_ip_via_iface "${IFACE_WIFI}" || true)"
    rpi_pub="$(resolve_vps_public_ip || true)"
    if [[ -n "${wifi_pub}" && -n "${rpi_pub}" && "${wifi_pub}" == "${rpi_pub}" ]]; then
        return 1
    fi

    echo "${ip_wifi}"
    return 0
}

log "reintegrator arrancado (intervalo=${CHECK_INTERVAL}s)"

while :; do
    sleep "${CHECK_INTERVAL}"

    # Si el WiFi YA está en la config activa, nothing to do (el watcher de
    # IP del WiFi de REQ-NET-07 ya gestiona cambios de IP)
    if grep -q "^\[links\.wifi\]" "${ACTIVE_CONF}" 2>/dev/null; then
        continue
    fi

    # ¿Pasa pre-flight ahora?
    new_ip="$(wifi_passes_preflight 2>/dev/null || true)"
    [[ -z "${new_ip}" ]] && continue

    # Pre-flight OK y WiFi NO está en config → añadir bloque.
    # Si el túnel está en modo --failover (algún otro link tiene
    # fallback_only=1 en config), el WiFi debe heredar ese modo
    # — si no, mlvpn lo trataría como activo y rompería el modelo
    # "1 activo, los demás backup" que pide REQ-NET-11.
    failover_active=0
    if grep -qE "^fallback_only = 1$" "${ACTIVE_CONF}" 2>/dev/null; then
        failover_active=1
    fi
    log "WiFi pasa pre-flight ahora (IP=${new_ip}) — añadiendo a bonding (failover=${failover_active})"

    cat >> "${ACTIVE_CONF}" <<EOF

[links.wifi]
bindhost = "${new_ip}"
remotehost = "${VPS_IP}"
remoteport = ${MLVPN_PORT_3_REMOTE}
bandwidth_upload = 50000000
timeout = 8
EOF
    # Si --failover activo, marcar WiFi como backup pasivo
    if [[ "${failover_active}" -eq 1 ]]; then
        echo "fallback_only = 1" >> "${ACTIVE_CONF}"
    fi

    # SIGHUP al proceso priv para que mlvpn recargue la config
    priv_pid="$(pgrep -f 'mlvpn: mlvpn0 \[priv\]' | head -1 || true)"
    if [[ -n "${priv_pid}" ]]; then
        if kill -HUP "${priv_pid}" 2>/dev/null; then
            log "SIGHUP enviado a mlvpn priv pid=${priv_pid}; WiFi añadida"
        else
            log "ERROR: SIGHUP a pid=${priv_pid} falló"
        fi
    else
        log "AVISO: no hay proceso mlvpn [priv] vivo, WiFi escrito en config pero sin SIGHUP"
    fi
done
