#!/usr/bin/env bash
# tools/lib/env-detect.sh
#
# Detecta el entorno de red actual (IPs locales, captive portal, links 4G
# tetherados, alcance del RPi por LAN o DDNS). Sourceable.
#
# Variables que exporta tras llamar env_detect_all():
#   DETECTED_WIFI_IFACE      — nombre interfaz WiFi (config/env IFACE_WIFI)
#   DETECTED_WIFI_IP         — IP asignada al WiFi, o vacío si caído
#   DETECTED_IPHONE_IFACE    — nombre interfaz iPhone (IFACE_IPHONE)
#   DETECTED_IPHONE_IP       — IP del tethering iPhone, o vacío
#   DETECTED_PIXEL_IFACE     — nombre interfaz Pixel (IFACE_PIXEL)
#   DETECTED_PIXEL_IP        — IP del tethering Pixel, o vacío
#   DETECTED_CAPTIVE         — 1 si el WiFi está tras captive portal, 0 no
#   DETECTED_RPI_LAN_OK      — 1 si RPi alcanzable en LAN (RPi_IP), 0 no
#   DETECTED_RPI_DDNS_OK     — 1 si RPi alcanzable por DDNS (VPS_IP), 0 no
#   DETECTED_RPI_TARGET      — "lan" si LAN OK, "ddns" si DDNS OK, "none"
#   DETECTED_REMOTE_HOST     — host concreto a usar (RPi_IP o VPS_IP)
#
# Requiere haber sourceado _common.sh primero.

# shellcheck source=tools/lib/_common.sh
: "${AVEVPC_ROOT:?source _common.sh primero}"

env_detect_load_config() {
    local cfg="${AVEVPC_ROOT}/config/env"
    require_file "${cfg}"
    # shellcheck source=/dev/null
    source "${cfg}"
    : "${IFACE_WIFI:?IFACE_WIFI no definido en config/env}"
    : "${IFACE_IPHONE:?IFACE_IPHONE no definido en config/env}"
    : "${IFACE_PIXEL:?IFACE_PIXEL no definido en config/env}"
    : "${RPi_IP:?RPi_IP no definido en config/env}"
    : "${VPS_IP:?VPS_IP no definido en config/env}"
}

# Devuelve por stdout la IP de una interfaz, vacío si no tiene.
env_detect_iface_ip() {
    local iface="$1"
    ifconfig "${iface}" 2>/dev/null \
        | awk '$1 == "inet" { print $2; exit }'
}

# Resuelve hostname a IP. Sistema primero (rápido, normal) y fallback
# secuencial a los resolvers de ${FALLBACK_DNS_RESOLVERS} si el sistema
# falla. Casos donde fallback dispara:
#  - Split-DNS corp (ej. WiFi Roche bloquea lookup de dyn.io).
#  - WiFi tren AVE flapping → DNS sistema timeout.
# Si el input ya es IP literal, retorna tal cual.
# Salida por stdout. Exit 0 si resolvió, 1 si ambas fallaron.
#
# IMPORTANTE: NO modificar /etc/hosts (entries stale inducen errores
# muy difíciles de trazar). Esta función es la forma correcta de tener
# resolver resiliente.
env_detect_resolve_to_ip() {
    local host="$1" ip resolver
    local resolvers="${FALLBACK_DNS_RESOLVERS:?config/env debe definir FALLBACK_DNS_RESOLVERS}"
    if [[ "${host}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "${host}"
        return 0
    fi
    # 1) System resolver (rápido, normal).
    ip="$(dig +short +time=2 +tries=1 "${host}" 2>/dev/null \
            | grep -E '^[0-9.]+$' | head -1)"
    if [[ -n "${ip}" ]]; then
        echo "${ip}"
        return 0
    fi
    # 2) Fallbacks públicos en orden — Roche bloquea 1.1.1.1 pero
    #    deja 8.8.8.8; redes restrictivas pueden invertir esto. Probar
    #    cada uno hasta que responda.
    for resolver in ${resolvers}; do
        log_warn "DNS sistema KO, fallback @${resolver} para ${host}"
        ip="$(dig "@${resolver}" +short +time=2 +tries=1 "${host}" 2>/dev/null \
                | grep -E '^[0-9.]+$' | head -1)"
        if [[ -n "${ip}" ]]; then
            echo "${ip}"
            return 0
        fi
    done
    return 1
}

# Detecta captive portal en la WiFi. Devuelve 0 si NO captive (ok),
# 1 si captive presente. captive.apple.com responde con título "Success"
# cuando hay internet libre.
env_detect_captive_on_wifi() {
    local iface="${DETECTED_WIFI_IFACE:-}"
    [[ -z "${iface}" || -z "${DETECTED_WIFI_IP:-}" ]] && return 1
    local body
    body="$(curl --interface "${iface}" -s --max-time 3 \
        "http://captive.apple.com/hotspot-detect.html" 2>/dev/null || true)"
    [[ "${body}" == *"<TITLE>Success</TITLE>"* ]]
}

# RPi alcanzable por LAN: ICMP a RPi_IP en <1s.
env_detect_rpi_lan_reachable() {
    ping -c 1 -W 1000 "${RPi_IP}" >/dev/null 2>&1
}

# RPi alcanzable por DDNS: resuelve VPS_IP (puede ser hostname) a IP
# literal vía resolver resiliente y hace ICMP. Setea DETECTED_VPS_IP
# como side effect para que los callers (SSH, ubond.conf) usen IP
# directa, evitando depender del DNS sistema en runtime.
env_detect_rpi_ddns_reachable() {
    DETECTED_VPS_IP="$(env_detect_resolve_to_ip "${VPS_IP}")" || {
        DETECTED_VPS_IP=""
        return 1
    }
    ping -c 1 -W 2000 "${DETECTED_VPS_IP}" >/dev/null 2>&1
}

# Pipeline completa: rellena todas las DETECTED_*.
env_detect_all() {
    env_detect_load_config

    DETECTED_WIFI_IFACE="${IFACE_WIFI}"
    DETECTED_IPHONE_IFACE="${IFACE_IPHONE}"
    DETECTED_PIXEL_IFACE="${IFACE_PIXEL}"

    DETECTED_WIFI_IP="$(env_detect_iface_ip "${IFACE_WIFI}")"
    DETECTED_IPHONE_IP="$(env_detect_iface_ip "${IFACE_IPHONE}")"
    DETECTED_PIXEL_IP="$(env_detect_iface_ip "${IFACE_PIXEL}")"

    if env_detect_captive_on_wifi; then DETECTED_CAPTIVE=0; else DETECTED_CAPTIVE=1; fi
    # Nota: env_detect_captive_on_wifi devuelve 0 si NO captive; invertimos
    # para que DETECTED_CAPTIVE=1 signifique "hay captive" (más legible).

    if env_detect_rpi_lan_reachable;  then DETECTED_RPI_LAN_OK=1;  else DETECTED_RPI_LAN_OK=0;  fi
    if env_detect_rpi_ddns_reachable; then DETECTED_RPI_DDNS_OK=1; else DETECTED_RPI_DDNS_OK=0; fi

    if   [[ "${DETECTED_RPI_LAN_OK}"  == "1" ]]; then
        DETECTED_RPI_TARGET="lan"
        DETECTED_REMOTE_HOST="${RPi_IP}"
        DETECTED_SSH_HOST="${RPi_IP}"
        DETECTED_SSH_PORT="${RPi_SSH_PORT:-22}"
    elif [[ "${DETECTED_RPI_DDNS_OK}" == "1" ]]; then
        DETECTED_RPI_TARGET="ddns"
        # Usar la IP literal resuelta (DETECTED_VPS_IP), no el hostname.
        # Si DETECTED_VPS_IP no se setó (improbable, fallback resiliente),
        # caer al hostname original.
        DETECTED_REMOTE_HOST="${DETECTED_VPS_IP:-${VPS_IP}}"
        DETECTED_SSH_HOST="${DETECTED_VPS_IP:-${VPS_IP}}"
        DETECTED_SSH_PORT="${VPS_SSH_PORT:-2222}"
    else
        DETECTED_RPI_TARGET="none"
        DETECTED_REMOTE_HOST=""
        DETECTED_SSH_HOST=""
        DETECTED_SSH_PORT=""
    fi

    export DETECTED_WIFI_IFACE DETECTED_WIFI_IP \
           DETECTED_IPHONE_IFACE DETECTED_IPHONE_IP \
           DETECTED_PIXEL_IFACE DETECTED_PIXEL_IP \
           DETECTED_CAPTIVE \
           DETECTED_RPI_LAN_OK DETECTED_RPI_DDNS_OK \
           DETECTED_RPI_TARGET DETECTED_REMOTE_HOST \
           DETECTED_SSH_HOST DETECTED_SSH_PORT \
           DETECTED_VPS_IP
}

# Imprime resumen legible para el usuario.
env_detect_summary() {
    hr
    log_info "Entorno detectado:"
    printf '  %-22s %s\n' "WiFi  (${DETECTED_WIFI_IFACE}):"   "${DETECTED_WIFI_IP:-<down>}"
    printf '  %-22s %s\n' "iPhone (${DETECTED_IPHONE_IFACE}):" "${DETECTED_IPHONE_IP:-<down>}"
    printf '  %-22s %s\n' "Pixel  (${DETECTED_PIXEL_IFACE}):"  "${DETECTED_PIXEL_IP:-<down>}"
    printf '  %-22s %s\n' "Captive portal:" "$([[ ${DETECTED_CAPTIVE} == 1 ]] && echo "SI" || echo "no")"
    printf '  %-22s %s\n' "RPi LAN  (${RPi_IP}):"  "$([[ ${DETECTED_RPI_LAN_OK}  == 1 ]] && echo OK || echo NO)"
    printf '  %-22s %s\n' "RPi DDNS (${VPS_IP}):"  "$([[ ${DETECTED_RPI_DDNS_OK} == 1 ]] && echo OK || echo NO)"
    printf '  %-22s %s (%s)\n' "Target final:" "${DETECTED_RPI_TARGET}" "${DETECTED_REMOTE_HOST:-<no remote>}"
    hr
}

# Lista de links elegibles como array global ELIGIBLE_LINKS=(name iface ip).
# Cada entrada del array es una tupla "nombre|iface|ip" para parsing fácil.
# `wifi` se considera elegible solo si NO hay captive y si no estamos en LAN
# (porque LAN+DDNS por WiFi haría hairpin).
env_detect_eligible_links() {
    ELIGIBLE_LINKS=()
    if [[ -n "${DETECTED_IPHONE_IP}" ]]; then
        ELIGIBLE_LINKS+=("iphone|${DETECTED_IPHONE_IFACE}|${DETECTED_IPHONE_IP}")
    fi
    if [[ -n "${DETECTED_PIXEL_IP}" ]]; then
        ELIGIBLE_LINKS+=("pixel|${DETECTED_PIXEL_IFACE}|${DETECTED_PIXEL_IP}")
    fi
    if [[ -n "${DETECTED_WIFI_IP}" && "${DETECTED_CAPTIVE}" == "0" ]]; then
        # WiFi en LAN+DDNS hace hairpin; orchestrators que usan LAN evitan WiFi.
        # En "ddns" sí es válido. Aquí lo añadimos siempre que no haya captive
        # — el caller decide si excluirlo.
        ELIGIBLE_LINKS+=("wifi|${DETECTED_WIFI_IFACE}|${DETECTED_WIFI_IP}")
    fi
    export ELIGIBLE_LINKS
}
