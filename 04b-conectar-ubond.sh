#!/usr/bin/env bash
###############################################################################
# 04b-conectar-ubond.sh
#
# DONDE SE EJECUTA: En tu Mac (cuando quieras activar el túnel ubond v2)
#
# QUE HACE:
#   Igual que 04-conectar.sh pero arrancando ubond en lugar de mlvpn:
#     1. Detecta IPs actuales de cada interfaz
#     2. Crea rutas /32 al VPS por cada interfaz física
#     3. Genera generated/ubond_active.conf desde generated/ubond.conf
#     4. Arranca /usr/local/sbin/ubond (binario v2)
#     5. Configura el utun con la IP del túnel
#
#   Coexiste con mlvpn (puertos UDP distintos): 5083/5084/5085 vs 5080-5082.
#   Si quieres usar ambos a la vez, ejecuta primero 04-conectar.sh y luego
#   ESTE — los túneles utun serán independientes.
#
# DIFERENCIAS RESPECTO A 04-conectar.sh:
#   - Lee generated/ubond.conf (creado por 03b-setup-mac-ubond.sh).
#   - Arranca /usr/local/sbin/ubond con --user ubond (no mlvpn).
#   - Interfaz utun nombrada ubond0 (no mlvpn0).
#   - Sin watchers de failover/wifi-reintegrator de momento — la versión v2
#     se valida primero con bonding puro. Cuando funcione, se duplican
#     los watchers como tools/*_ubond.sh.
#
# REQUISITOS:
#   - 03b-setup-mac-ubond.sh ejecutado (genera generated/ubond.conf y
#     instala /usr/local/sbin/ubond).
#   - 07b-setup-rpi-ubond.sh ejecutado contra la RPi (servidor ubond
#     instalado y enabled). El servidor arranca con
#     `ssh RPi 'sudo systemctl start ubond'`.
#   - Port forwarding 5083/5084/5085 UDP en el router doméstico hacia
#     la RPi. El 07b solo abre la firewall de la RPi, NO el router.
###############################################################################
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Este script requiere sudo."
    echo ""
    echo "  sudo ./04b-conectar-ubond.sh [--sin-wifi]"
    exit 1
fi

SIN_WIFI=false
for arg in "$@"; do
    case "${arg}" in
        --sin-wifi) SIN_WIFI=true ;;
        *)
            echo "ERROR: argumento desconocido: ${arg}"
            echo "Uso: $0 [--sin-wifi]"
            exit 1
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config/env"
GENERATED_DIR="${SCRIPT_DIR}/generated"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: No existe config/env"
    exit 1
fi
if [[ ! -f "${GENERATED_DIR}/ubond.conf" ]]; then
    echo "ERROR: Ejecuta primero 03b-setup-mac-ubond.sh"
    exit 1
fi
if [[ ! -x /usr/local/sbin/ubond ]]; then
    echo "ERROR: /usr/local/sbin/ubond no existe. Ejecuta 03b-setup-mac-ubond.sh."
    exit 1
fi

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

IFACE_WIFI="${IFACE_WIFI:-en0}"
UBOND_PORT_1="${UBOND_PORT_1:-5083}"
UBOND_PORT_2="${UBOND_PORT_2:-5084}"
UBOND_PORT_3="${UBOND_PORT_3:-5085}"
UBOND_PORT_3_REMOTE="${UBOND_PORT_3_REMOTE:-${UBOND_PORT_3}}"

# Subnet del túnel ubond (REQ-NET-24) — distinta de mlvpn para
# evitar colisión de routing en el RPi (Bug #5).
UBOND_TUN_VPS_IP="${UBOND_TUN_VPS_IP:-10.10.20.1}"
UBOND_TUN_MAC_IP="${UBOND_TUN_MAC_IP:-10.10.20.2}"

# =====================================================================
# Paso 1: Detectar IPs actuales de cada interfaz (idéntico a 04-conectar)
# =====================================================================
echo "=> Detectando interfaces..."

IP_IPHONE="$(ipconfig getifaddr "${IFACE_IPHONE}" 2>/dev/null || true)"
IP_PIXEL="$(ipconfig getifaddr "${IFACE_PIXEL}" 2>/dev/null || true)"
IP_WIFI="$(ipconfig getifaddr "${IFACE_WIFI}" 2>/dev/null || true)"

echo "  iPhone (${IFACE_IPHONE}): ${IP_IPHONE:-NO DETECTADO}"
echo "  Pixel  (${IFACE_PIXEL}):  ${IP_PIXEL:-NO DETECTADO}"
echo "  WiFi   (${IFACE_WIFI}):   ${IP_WIFI:-sin IP}"

if [[ -z "${IP_IPHONE}" && -z "${IP_PIXEL}" && -z "${IP_WIFI}" ]]; then
    echo ""
    echo "ERROR: Ninguna interfaz tiene IP. Para smoke test ofi necesitas"
    echo "       al menos el WiFi conectado (o un móvil USB tethering)."
    exit 1
fi

# =====================================================================
# Paso 1b: ¿WiFi elegible? (mismo pre-flight que 04-conectar.sh)
# =====================================================================
WIFI_ELIGIBLE=false

get_public_ip_via_iface() {
    local iface="$1" url ip
    for url in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
        ip="$(curl --interface "${iface}" -s --max-time 2 "${url}" 2>/dev/null | tr -d '[:space:]')"
        if [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "${ip}"; return 0
        fi
    done
    return 1
}

resolve_vps_public_ip() {
    if [[ "${VPS_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "${VPS_IP}"; return 0
    fi
    dig +short +time=2 +tries=1 "${VPS_IP}" A 2>/dev/null \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tail -1
}

check_wifi_eligibility() {
    if "${SIN_WIFI}"; then
        echo "  WiFi descartado por --sin-wifi"; return 1
    fi
    if [[ -z "${IP_WIFI}" ]]; then
        echo "  WiFi sin IP en ${IFACE_WIFI}"; return 1
    fi
    if ! curl --interface "${IFACE_WIFI}" -s --max-time 2 \
            "http://captive.apple.com/hotspot-detect.html" 2>/dev/null | \
            grep -q "<TITLE>Success</TITLE>"; then
        echo "  WiFi en captive portal — autentica y reejecuta"; return 1
    fi
    local wifi_public rpi_public
    wifi_public="$(get_public_ip_via_iface "${IFACE_WIFI}" || true)"
    rpi_public="$(resolve_vps_public_ip || true)"
    if [[ -n "${wifi_public}" && -n "${rpi_public}" \
          && "${wifi_public}" == "${rpi_public}" ]]; then
        echo "  WiFi sale por ${wifi_public} = IP pública RPi → red de casa, hairpin NAT"
        return 1
    fi
    return 0
}

echo ""
echo "=> Evaluando WiFi como enlace..."
if check_wifi_eligibility; then
    WIFI_ELIGIBLE=true
    echo "  WiFi elegible: ${IP_WIFI} via ${IFACE_WIFI}"
fi

ACTIVE_LINKS=0
[[ -n "${IP_IPHONE}" ]] && ACTIVE_LINKS=$((ACTIVE_LINKS + 1))
[[ -n "${IP_PIXEL}" ]] && ACTIVE_LINKS=$((ACTIVE_LINKS + 1))
"${WIFI_ELIGIBLE}" && ACTIVE_LINKS=$((ACTIVE_LINKS + 1))
echo "  Enlaces activos: ${ACTIVE_LINKS}"

# =====================================================================
# Paso 2: Rutas /32 al VPS (idéntico a 04-conectar.sh — mismo VPS)
# =====================================================================
echo ""
echo "=> Configurando rutas al VPS (${VPS_IP})..."

get_gateway() {
    local iface="$1"
    netstat -rn -f inet | awk -v iface="${iface}" '$1 == "default" && $NF == iface {print $2; exit}'
}

# Limpiar rutas previas
sudo route -n delete "${VPS_IP}/32" 2>/dev/null || true
sudo route -n delete -host "${VPS_IP}" 2>/dev/null || true
sudo route -n delete -host "${VPS_IP}" -ifscope "${IFACE_IPHONE}" 2>/dev/null || true
sudo route -n delete -host "${VPS_IP}" -ifscope "${IFACE_PIXEL}" 2>/dev/null || true
sudo route -n delete -host "${VPS_IP}" -ifscope "${IFACE_WIFI}" 2>/dev/null || true

GW_IPHONE=""
GW_PIXEL=""
GW_WIFI=""
[[ -n "${IP_IPHONE}" ]] && GW_IPHONE="$(get_gateway "${IFACE_IPHONE}")"
[[ -n "${IP_PIXEL}" ]] && GW_PIXEL="$(get_gateway "${IFACE_PIXEL}")"
"${WIFI_ELIGIBLE}" && GW_WIFI="$(get_gateway "${IFACE_WIFI}")"

[[ -n "${GW_IPHONE}" ]] && sudo route -n add -host "${VPS_IP}" "${GW_IPHONE}" -ifscope "${IFACE_IPHONE}" && echo "  iPhone: ${VPS_IP} -> ${GW_IPHONE}"
[[ -n "${GW_PIXEL}" ]]  && sudo route -n add -host "${VPS_IP}" "${GW_PIXEL}"  -ifscope "${IFACE_PIXEL}"  && echo "  Pixel:  ${VPS_IP} -> ${GW_PIXEL}"
[[ -n "${GW_WIFI}" ]]   && sudo route -n add -host "${VPS_IP}" "${GW_WIFI}"   -ifscope "${IFACE_WIFI}"   && echo "  WiFi:   ${VPS_IP} -> ${GW_WIFI}"

VPS_GW="${GW_PIXEL:-${GW_IPHONE:-${GW_WIFI}}}"
if [[ -n "${VPS_GW}" ]]; then
    sudo route -n add -host "${VPS_IP}" "${VPS_GW}" 2>/dev/null || true
    echo "  Ruta global VPS: ${VPS_IP} -> ${VPS_GW} (anti-loop)"
fi

# =====================================================================
# Paso 3: Generar ubond_active.conf con IPs reales
# =====================================================================
echo ""
echo "=> Generando ubond_active.conf..."

cp "${GENERATED_DIR}/ubond.conf" "${GENERATED_DIR}/ubond_active.conf"
chmod 600 "${GENERATED_DIR}/ubond_active.conf"

sed -i '' "s/PLACEHOLDER_IPHONE_IP/${IP_IPHONE:-0.0.0.0}/" "${GENERATED_DIR}/ubond_active.conf"
sed -i '' "s/PLACEHOLDER_PIXEL_IP/${IP_PIXEL:-0.0.0.0}/" "${GENERATED_DIR}/ubond_active.conf"

if "${WIFI_ELIGIBLE}"; then
    cat >> "${GENERATED_DIR}/ubond_active.conf" <<EOF

[links.wifi]
bindhost = "${IP_WIFI}"
remotehost = "${VPS_IP}"
remoteport = ${UBOND_PORT_3_REMOTE}
bandwidth_upload = 50000000
timeout = 8
# REQ-NET-25: WiFi del AVE/hotel suele ser muy noisy.
# Descomentar si hay loss cycling en trayecto.
# loss_tolerence    = 80
# latency_tolerence = 2000
EOF
    if [[ "${UBOND_PORT_3_REMOTE}" != "${UBOND_PORT_3}" ]]; then
        echo "  WiFi añadido (cliente :${UBOND_PORT_3_REMOTE} → router → RPi:${UBOND_PORT_3})"
    else
        echo "  WiFi añadido (puerto ${UBOND_PORT_3})"
    fi
fi

# =====================================================================
# Paso 4: Arrancar ubond
# =====================================================================
echo ""
echo "=> Arrancando ubond..."

# Cleanup defensivo (mismo patrón que REQ-MAC-05 para mlvpn)
if pgrep -f "ubond: ubond0" &>/dev/null; then
    echo "  Detectadas instancias ubond previas — matando"
    pkill -f "ubond: ubond0" 2>/dev/null || true
    sleep 1
    pkill -9 -f "ubond: ubond0" 2>/dev/null || true
    sleep 1
fi

if [[ -f "${GENERATED_DIR}/ubond.pid" ]]; then
    OLD_PID="$(cat "${GENERATED_DIR}/ubond.pid")"
    sudo kill "${OLD_PID}" 2>/dev/null || true
    rm -f "${GENERATED_DIR}/ubond.pid"
fi

rm -f "${GENERATED_DIR}/ubond.log"
touch "${GENERATED_DIR}/ubond.log"

# Snapshot de utuns ANTES de arrancar ubond — el nuevo será el de ubond.
# Más robusto que parsear ifconfig con regex frágiles (bug AVE 2026-06-01:
# `grep -B1 "nd6 options" | cut -d: -f1` devolvía "inet6 fe80" en macOS
# moderno porque la línea anterior a "nd6 options" es ahora la inet6
# fe80::%utunN, no la cabecera utunN:).
UTUN_PRE=$(ifconfig -l | tr ' ' '\n' | grep -E '^utun[0-9]+$' | sort)

# --debug --verbose: imprescindibles para que generated/ubond.log tenga
# contenido (sin --debug, ubond va a syslog y macOS unified log filtra
# log_info por nivel, dejando ubond.log en 0 bytes — incidente AVE
# 2026-06-01).
/usr/local/sbin/ubond \
    --config "${GENERATED_DIR}/ubond_active.conf" \
    --name ubond0 \
    --user ubond \
    --debug --verbose \
    2>&1 | tee "${GENERATED_DIR}/ubond.log" &

# $! es el PID del subshell que ejecuta `tee`, NO del binario ubond.
# Capturamos el PID real con pgrep tras dar tiempo a setproctitle.
TEE_PID=$!
sleep 1
UBOND_PID="$(pgrep -f "ubond: ubond0 \[priv\]" | head -1)"
if [[ -n "${UBOND_PID}" ]]; then
    echo "${UBOND_PID}" > "${GENERATED_DIR}/ubond.pid"
else
    # Fallback al PID del tee (mejor que nada — bug AVE 2026-06-01).
    echo "${TEE_PID}" > "${GENERATED_DIR}/ubond.pid"
fi

# Detectar utun y configurar IP
echo "  Esperando autenticación de enlaces..."
UTUN_IFACE=""
for _ in $(seq 1 20); do
    if pgrep -f "ubond: ubond0 @" &>/dev/null; then
        UTUN_POST=$(ifconfig -l | tr ' ' '\n' | grep -E '^utun[0-9]+$' | sort)
        UTUN_IFACE=$(comm -13 <(echo "${UTUN_PRE}") <(echo "${UTUN_POST}") | head -1)
        [[ -n "${UTUN_IFACE}" ]] && break
    fi
    sleep 1
done

if [[ -n "${UTUN_IFACE}" ]]; then
    echo "  Configurando ${UTUN_IFACE} con IP del túnel..."
    ifconfig "${UTUN_IFACE}" "${UBOND_TUN_MAC_IP}" "${UBOND_TUN_VPS_IP}" mtu "${TUN_MTU}" up 2>/dev/null || true
    route -n add -net 0.0.0.0/1   -interface "${UTUN_IFACE}" 2>/dev/null || true
    route -n add -net 128.0.0.0/1 -interface "${UTUN_IFACE}" 2>/dev/null || true
    echo "  Túnel ubond activo en ${UTUN_IFACE}"

    # REQ-NET-26: arrancar watchdog de salud. Detecta pérdida del túnel
    # (ping gateway interno KO repetido o updown reportando rtun_down) y
    # dispara SOS.sh automáticamente. Sin él, el usuario tiene que
    # detectar el fallo manualmente — patrón observado en AVE 2026-06-01.
    if [[ -x "${SCRIPT_DIR}/tools/ubond-watchdog.sh" ]]; then
        echo "  Arrancando watchdog (auto-recovery via SOS.sh si pierde gateway)..."
        UBOND_TUN_VPS_IP="${UBOND_TUN_VPS_IP}" \
            "${SCRIPT_DIR}/tools/ubond-watchdog.sh" >/dev/null 2>&1 &
        echo "    watchdog pid=$!"
    fi
else
    echo "  AVISO: No se pudo detectar utun de ubond — ningún enlace autenticó"
    echo "  Comprueba: tail -f ${GENERATED_DIR}/ubond.log"
fi

# =====================================================================
# Paso 5: Verificar conectividad
# =====================================================================
echo ""
echo "=> Verificando conectividad por el túnel ubond..."
if ping -c 2 -W 2 "${UBOND_TUN_VPS_IP}" &>/dev/null; then
    echo "  Ping al VPS (${UBOND_TUN_VPS_IP}): OK"
else
    echo "  AVISO: No hay ping todavía. Comprobar:"
    echo "    1. ubond.service está iniciado en RPi: ssh ${VPS_USER}@${VPS_IP} 'systemctl is-active ubond'"
    echo "    2. Router doméstico tiene port forwarding ${UBOND_PORT_1}/${UBOND_PORT_2}/${UBOND_PORT_3} UDP → RPi"
    echo "    3. tail -f ${GENERATED_DIR}/ubond.log"
fi

# =====================================================================
# Paso 6: Resumen
# =====================================================================
echo ""
echo "=== UBOND ACTIVO (v2 experimental) ==="
echo ""
echo "  Túnel:   ${UBOND_TUN_MAC_IP} <-> ${UBOND_TUN_VPS_IP}"
echo "  Enlaces: ${ACTIVE_LINKS}"
[[ -n "${IP_IPHONE}" ]] && echo "    - iPhone (${IFACE_IPHONE}): ${IP_IPHONE} -> VPS:${UBOND_PORT_1}"
[[ -n "${IP_PIXEL}" ]]  && echo "    - Pixel  (${IFACE_PIXEL}):  ${IP_PIXEL}  -> VPS:${UBOND_PORT_2}"
"${WIFI_ELIGIBLE}"      && echo "    - WiFi   (${IFACE_WIFI}):   ${IP_WIFI}  -> VPS:${UBOND_PORT_3_REMOTE}"
echo ""
echo "  PID:     ${UBOND_PID}"
echo "  Log:     ${GENERATED_DIR}/ubond.log"
echo ""
echo "Para desconectar:"
echo "  sudo kill ${UBOND_PID}  # o: sudo pkill -f 'ubond: ubond0'"
echo ""
echo "NOTA: mlvpn v1 sigue disponible en paralelo (puertos 5080-5082)."
echo "      Para volver a v1: sudo ./05-desconectar.sh && sudo ./04-conectar.sh"
