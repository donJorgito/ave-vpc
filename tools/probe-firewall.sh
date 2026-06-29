#!/usr/bin/env bash
###############################################################################
# tools/probe-firewall.sh — REQ-NET-38 (Task Vía F)
#
# Probe sistemático del firewall WiFi desde el Mac (cliente). Dado que el
# listener multipuerto (tools/rpi-multiport-listener.sh) está arriba en la
# RPi, mapea QUÉ puertos/protocolos llegan realmente al servidor SIN tumbar
# la asociación WiFi (timeouts acotados ~2-3s, secuencial, no flood).
#
# Para cada puerto del set prueba:
#   - TCP connect + eco: ¿llega el eco AVE-VPC-LISTENER del servidor?
#   - UDP send + recv:   ¿vuelve el datagrama de eco?
# Más dos sondas transversales:
#   - DNS-tunnel viability HINT (placeholder — necesita infra iodine).
#   - ICMP reachability (ping al RPi vía la iface WiFi).
#
# Salida: tabla `puerto/proto -> PASS | DNAT | SILENT`.
#
#   PASS   = respuesta == eco esperado del listener → el transporte cruza.
#   DNAT   = HAY respuesta pero NO es nuestro eco (HTML del captive, cert
#            equivocado, banner ajeno) → DNAT/proxy interceptó la conexión.
#            ESTA es la clave (doc 12: TCP/443 Renfe devuelve cert playrenfe).
#   SILENT = ninguna respuesta dentro del timeout → DROP del firewall.
#
# Toda la salida del Mac se fuerza por la iface WiFi (IFACE_WIFI de
# config/env, p.ej. en0) para no contaminar la medida con los links 4G:
#   - curl/HTTP: `curl --interface`
#   - TCP/UDP crudo: la IP de la iface como source (`nc -s` / bind explícito)
#   - ping: `ping -b <iface>` (macOS bound-to-interface)
#
# Sanity check: en WiFi de oficina se espera casi todo PASS.
#
# Uso:
#   ./probe-firewall.sh                 # usa IFACE_WIFI y VPS_IP de config/env
#   IFACE_WIFI=en0 ./probe-firewall.sh  # override de iface
#   PORTS_TCP="443 8443" ./probe-firewall.sh   # subset
###############################################################################

set -uo pipefail

# bash >=4 (consistencia con el resto de tooling del repo en el Mac)
if (( BASH_VERSINFO[0] < 4 )); then
    for try_bash in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        if [[ -x "${try_bash}" ]]; then
            exec "${try_bash}" "$0" "$@"
        fi
    done
    echo "ERROR: necesita bash >=4. Instalar: brew install bash" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config/env"

# shellcheck source=/dev/null
[[ -f "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}"

# --- Parámetros (sin IPs hardcodeadas: todo de config/env) ---
IFACE_WIFI="${IFACE_WIFI:-en0}"
TARGET_HOST="${VPS_IP:?VPS_IP no definido en config/env}"

# Set por defecto idéntico al del listener (excluye 22/SSH).
PORTS_TCP="${PORTS_TCP:-80 443 853 993 2222 8080 8443 9001 9999}"
PORTS_UDP="${PORTS_UDP:-80 443 853 993 2222 8080 8443 9001 9999}"

ECHO_TAG="${LISTENER_ECHO_TAG:-AVE-VPC-LISTENER}"
TIMEOUT_S="${PROBE_TIMEOUT_S:-3}"      # acotado: gentil con la WiFi del tren
# Subdominio delegado para test DNS-tunnel (placeholder; ver nota Vía D).
DNS_TUNNEL_FQDN="${DNS_TUNNEL_FQDN:-probe.${VPS_IP}}"

# --- Resolver la IP de la iface WiFi para forzar el source de las sondas ---
# macOS: ipconfig getifaddr da la IPv4 de la interfaz.
WIFI_SRC_IP="$(ipconfig getifaddr "${IFACE_WIFI}" 2>/dev/null || true)"
if [[ -z "${WIFI_SRC_IP}" ]]; then
    echo "ERROR: ${IFACE_WIFI} sin IPv4 — ¿WiFi conectada? abortando" >&2
    exit 1
fi

echo "=== probe-firewall.sh (REQ-NET-38) ==="
echo "iface WiFi : ${IFACE_WIFI} (src ${WIFI_SRC_IP})"
echo "target     : ${TARGET_HOST}"
echo "timeout    : ${TIMEOUT_S}s"
echo "eco esperado: '${ECHO_TAG} port=<p> proto=<tcp|udp>'"
echo

# --- Forzar el egress por la WiFi con ruta scoped (B3, revisión 2026-06-11) ---
# `nc -s <ip>` SOLO fija la IP origen; NO fuerza la interfaz de salida. Con
# iPhone/Pixel activos, el kernel enruta al RPi público por celular y la tabla
# PASS/DNAT/SILENT mediría la iface EQUIVOCADA. Igual que 04b-conectar-ubond.sh,
# instalamos una ruta -host -ifscope hacia el target por la WiFi y la retiramos
# al salir. Requiere root; sin él avisamos de que la medida no es fiable
# en estado multi-enlace.
TARGET_IP="$(dig +short +time=2 +tries=1 "${TARGET_HOST}" A 2>/dev/null \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tail -1)"
[[ -z "${TARGET_IP}" && "${TARGET_HOST}" =~ ^[0-9.]+$ ]] && TARGET_IP="${TARGET_HOST}"
GW_WIFI="$(route -n get -ifscope "${IFACE_WIFI}" default 2>/dev/null \
    | awk '/gateway:/{print $2}')"
SCOPED_ROUTE=0
if [[ "${EUID}" -eq 0 && -n "${TARGET_IP}" && -n "${GW_WIFI}" ]]; then
    route -n delete -host "${TARGET_IP}" -ifscope "${IFACE_WIFI}" 2>/dev/null || true
    if route -n add -host "${TARGET_IP}" "${GW_WIFI}" -ifscope "${IFACE_WIFI}" >/dev/null 2>&1; then
        SCOPED_ROUTE=1
        echo "egress pin : ${TARGET_IP} -> ${GW_WIFI} -ifscope ${IFACE_WIFI} (OK)"
    fi
else
    echo "AVISO: sin ruta scoped (root=${EUID}, target_ip='${TARGET_IP}', gw='${GW_WIFI}')."
    echo "       En estado multi-enlace la medida puede reflejar OTRA iface."
    echo "       Lanza con sudo para fijar el egress por ${IFACE_WIFI}."
fi
cleanup_route() {
    [[ "${SCOPED_ROUTE}" -eq 1 ]] && \
        route -n delete -host "${TARGET_IP}" -ifscope "${IFACE_WIFI}" 2>/dev/null || true
}
trap cleanup_route EXIT INT TERM
echo

# Clasificador común: compara la respuesta cruda contra el eco esperado.
#   $1 = respuesta recibida, $2 = puerto, $3 = proto
# Devuelve por stdout: PASS | DNAT | SILENT
classify() {
    local resp="$1" port="$2" proto="$3"
    if [[ -z "${resp}" ]]; then
        echo "SILENT"
    elif [[ "${resp}" == *"${ECHO_TAG} port=${port} proto=${proto}"* ]]; then
        echo "PASS"
    else
        # Hubo bytes de vuelta pero NO son nuestro eco → algo interceptó.
        echo "DNAT"
    fi
}

# --- Sonda TCP: connect + leer eco, source forzado a la iface WiFi ---
# nc de macOS (BSD nc) soporta -s <source-ip> y -G/-w timeouts.
probe_tcp() {
    local port="$1" resp
    resp="$(printf 'probe\n' \
        | nc -s "${WIFI_SRC_IP}" -G "${TIMEOUT_S}" -w "${TIMEOUT_S}" \
             "${TARGET_HOST}" "${port}" 2>/dev/null \
        | tr -d '\r')"
    classify "${resp}" "${port}" "tcp"
}

# --- Sonda UDP: send + recv, source forzado a la iface WiFi ---
# nc -u en BSD; sin tráfico de vuelta -w corta el read y devuelve vacío.
probe_udp() {
    local port="$1" resp
    resp="$(printf 'probe\n' \
        | nc -u -s "${WIFI_SRC_IP}" -w "${TIMEOUT_S}" \
             "${TARGET_HOST}" "${port}" 2>/dev/null \
        | tr -d '\r')"
    classify "${resp}" "${port}" "udp"
}

# --- Tabla principal ---
printf '%-10s %-8s %s\n' "PUERTO" "PROTO" "RESULTADO"
printf '%-10s %-8s %s\n' "------" "-----" "---------"

for p in ${PORTS_TCP}; do
    r="$(probe_tcp "${p}")"
    printf '%-10s %-8s %s\n' "${p}" "tcp" "${r}"
done

for p in ${PORTS_UDP}; do
    r="$(probe_udp "${p}")"
    printf '%-10s %-8s %s\n' "${p}" "udp" "${r}"
done

echo
echo "--- sondas transversales ---"

# --- ICMP reachability vía la iface WiFi ---
# macOS ping: -b <iface> fuerza bound-to-interface; -c cuenta, -t timeout.
if ping -c 2 -t "${TIMEOUT_S}" -b "${IFACE_WIFI}" "${TARGET_HOST}" >/dev/null 2>&1; then
    icmp="REACHABLE"
else
    icmp="NO-REPLY"
fi
printf '%-22s %s\n' "ICMP (ping RPi)" "${icmp}"

# --- DNS-tunnel viability HINT (placeholder) ---
# No es un túnel real: solo comprueba si el resolver de la WiFi responde a
# una consulta TXT bajo un subdominio que (en producción) estaría delegado
# al RPi vía iodine (Vía D). Si resuelve algo, la vía DNS MERECE montaje;
# si NACK/timeout, probablemente el walled garden filtra TXT no-propios.
# REQUIERE infra iodine + delegación NS para ser concluyente (doc 13 §2 D).
dns_txt="$(dig +short +time=2 +tries=1 TXT "${DNS_TUNNEL_FQDN}" 2>/dev/null | head -1)"
if [[ -n "${dns_txt}" ]]; then
    dns_hint="MAYBE (TXT resuelve: ${dns_txt}) — requiere infra iodine"
else
    dns_hint="UNKNOWN (sin TXT; placeholder, requiere infra iodine)"
fi
printf '%-22s %s\n' "DNS-tunnel hint" "${dns_hint}"

echo
echo "Leyenda: PASS=eco listener OK | DNAT=respuesta ajena (proxy/captive) | SILENT=sin respuesta (DROP)"
