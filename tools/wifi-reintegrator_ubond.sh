#!/usr/bin/env bash
###############################################################################
# tools/wifi-reintegrator_ubond.sh — REQ-NET-13 (variante ubond v2)
#
# Port ubond-aware de tools/wifi-reintegrator.sh. Decisión "duplicar vs
# parametrizar" tomada en REQ-NET-22 (ubond-v2-roadmap): DUPLICAR es más
# seguro para v1.x — el original mlvpn lo consumen 04-conectar.sh, los tests
# REQ-NET-13/41, README y verificar-setup.sh; tocarlo arriesga regresión. Esta
# copia es el equivalente v2 que SOS.sh ya esperaba (pkill de
# "wifi-reintegrator_ubond", SOS.sh:64) y nunca existió hasta hoy.
#
# DIFERENCIAS RESPECTO A LA VERSIÓN mlvpn (todas y solo las necesarias):
#   - ACTIVE_CONF = generated/ubond_active.conf  (no mlvpn_active.conf)
#   - PID_FILE    = generated/ubond_wifi_reintegrator.pid
#   - Proceso priv buscado: "ubond: ubond0 [priv]"  (no "mlvpn: mlvpn0 [priv]")
#   - Puerto remoto directo: UBOND_PORT_3_REMOTE / UBOND_PORT_3 (no MLVPN_*)
#   - logger tag: ubond-wifi-reintegrator
#   - ubond v2 NO usa fallback_only (su failover/replicate se decide vía
#     [filters.replicate], no por marca de link) → se omite la lógica
#     failover_active del original mlvpn (REQ-NET-17 no aplica a v2).
#
# Watcher en background que reintenta los pre-flight checks del WiFi cada
# 30 s. Si pasan, añade dinámicamente el bloque [links.wifi] al
# ubond_active.conf y manda SIGHUP a ubond — éste recarga la config y añade
# el nuevo link sin tirar el túnel.
#
# REQ-NET-41 (2026-06-12): soporte OPT-IN WIFI_VIA_WRAPPER. Cuando =1, el
# WiFi NO va directo a la RPi: el [links.wifi] apunta a la boca local del
# wrapper (127.0.0.1:WRAP_LOCAL_PORT, p.ej. udp2raw faketcp) que cruza el
# firewall del AVE, y el pre-flight pasa a comprobar que el wrapper está vivo
# en vez de "captive limpio por en0" (que da falsos negativos a bordo — ver
# 04b-conectar-ubond.sh, misma decisión validada en tren el 2026-06-12).
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
ACTIVE_CONF="${GENERATED_DIR}/ubond_active.conf"
PID_FILE="${GENERATED_DIR}/ubond_wifi_reintegrator.pid"

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

IFACE_WIFI="${IFACE_WIFI:-en0}"
# UBOND_PORT_3_REMOTE: si no está definido, usa el bindport interno (igual
# default que 04b-conectar-ubond.sh, coherencia v2).
UBOND_PORT_3="${UBOND_PORT_3:-5085}"
UBOND_PORT_3_REMOTE="${UBOND_PORT_3_REMOTE:-${UBOND_PORT_3}}"

# REQ-NET-41 (2026-06-12): modo OPT-IN para tunelar el WiFi a través del
# wrapper local (tools/wrap-*.sh) en vez de apuntar directo a VPS_IP. Por
# defecto OFF → el bloque [links.wifi] se escribe EXACTAMENTE igual que
# siempre. Con WIFI_VIA_WRAPPER=1 se reescribe bindhost/remotehost a 127.0.0.1
# y remoteport al puerto local del wrapper (WRAP_LOCAL_PORT). El wrapper se
# arranca por separado — este watcher NO lo lanza.
WIFI_VIA_WRAPPER="${WIFI_VIA_WRAPPER:-0}"
WRAP_LOCAL_PORT="${WRAP_LOCAL_PORT:-${UBOND_PORT_3}}"

echo "$$" > "${PID_FILE}"

log() { logger -t ubond-wifi-reintegrator "$*"; }
trap 'rm -f "${PID_FILE}"; log "reintegrator terminado"; exit 0' INT TERM EXIT

CHECK_INTERVAL=30

# Mismas funciones de comprobación que en 04b-conectar-ubond.sh — duplicadas
# aquí intencionalmente para que el watcher sea standalone.
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

# REQ-NET-41 / 2026-06-12: en modo wrapper la elegibilidad NO depende de que
# en0 llegue limpio a captive.apple.com (falsos negativos a bordo del AVE por
# inestabilidad de la WiFi), sino de que el wrapper local esté vivo escuchando
# en 127.0.0.1:WRAP_LOCAL_PORT — que es a donde ubond manda el tráfico WiFi.
wrapper_listener_ready() {
    local pf pid
    for pf in "${GENERATED_DIR}"/wrap_*.pid; do
        [[ -f "${pf}" ]] || continue
        pid="$(cat "${pf}" 2>/dev/null || true)"
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            return 0
        fi
    done
    if lsof -nP -iUDP@127.0.0.1:"${WRAP_LOCAL_PORT}" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Devuelve la IP de en0 si el WiFi pasa todos los pre-flight, vacío si no
wifi_passes_preflight() {
    local ip_wifi
    ip_wifi="$(ipconfig getifaddr "${IFACE_WIFI}" 2>/dev/null || true)"
    [[ -z "${ip_wifi}" ]] && return 1

    # REQ-NET-41: rama wrapper-aware. Con WIFI_VIA_WRAPPER=1 basta en0 con IP
    # + wrapper vivo. Con =0 cae al gate clásico (captive + no-red-de-casa).
    if [[ "${WIFI_VIA_WRAPPER}" == "1" ]]; then
        if wrapper_listener_ready; then
            echo "${ip_wifi}"
            return 0
        fi
        return 1
    fi

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

log "reintegrator (ubond) arrancado (intervalo=${CHECK_INTERVAL}s, wrapper=${WIFI_VIA_WRAPPER})"

while :; do
    sleep "${CHECK_INTERVAL}"

    # Si el WiFi YA está en la config activa, nothing to do.
    if grep -q "^\[links\.wifi\]" "${ACTIVE_CONF}" 2>/dev/null; then
        continue
    fi

    # ¿Pasa pre-flight ahora?
    new_ip="$(wifi_passes_preflight 2>/dev/null || true)"
    [[ -z "${new_ip}" ]] && continue

    # Pre-flight OK y WiFi NO está en config → añadir bloque.
    # ubond v2 no usa fallback_only (REQ-NET-17 es solo mlvpn): no hay lógica
    # de modo failover por link aquí.
    log "WiFi pasa pre-flight ahora (IP=${new_ip}) — añadiendo a bonding ubond (wrapper=${WIFI_VIA_WRAPPER})"

    if [[ "${WIFI_VIA_WRAPPER}" == "1" ]]; then
        # REQ-NET-41 (OPT-IN): WiFi va a la boca local del wrapper, no a la
        # RPi. bindhost/remotehost = 127.0.0.1; el wrapper cruza el firewall.
        log "WIFI_VIA_WRAPPER=1 → WiFi apunta a 127.0.0.1:${WRAP_LOCAL_PORT} (REQ-NET-41)"
        cat >> "${ACTIVE_CONF}" <<EOF

[links.wifi]
bindhost = "127.0.0.1"
remotehost = "127.0.0.1"
remoteport = ${WRAP_LOCAL_PORT}
bandwidth_upload = 50000000
timeout = 8
EOF
    else
        cat >> "${ACTIVE_CONF}" <<EOF

[links.wifi]
bindhost = "${new_ip}"
remotehost = "${VPS_IP}"
remoteport = ${UBOND_PORT_3_REMOTE}
bandwidth_upload = 50000000
timeout = 8
EOF
    fi

    # SIGHUP al proceso priv para que ubond recargue la config
    priv_pid="$(pgrep -f 'ubond: ubond0 \[priv\]' | head -1 || true)"
    if [[ -n "${priv_pid}" ]]; then
        if kill -HUP "${priv_pid}" 2>/dev/null; then
            log "SIGHUP enviado a ubond priv pid=${priv_pid}; WiFi añadida"
        else
            log "ERROR: SIGHUP a pid=${priv_pid} falló"
        fi
    else
        log "AVISO: no hay proceso ubond [priv] vivo, WiFi escrito en config pero sin SIGHUP"
    fi
done
