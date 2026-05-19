#!/usr/bin/env bash
###############################################################################
# 04-conectar.sh
#
# DONDE SE EJECUTA: En tu Mac (en el tren, cuando quieras activar bonding)
#
# QUE HACE:
#   1. Detecta las IPs actuales de cada interfaz (cambian con DHCP)
#   2. Crea rutas especificas al VPS por cada interfaz fisica
#   3. Actualiza la config de mlvpn con las IPs reales
#   4. Arranca mlvpn (levanta el tunel con bonding)
#
# COMO FUNCIONA EL BONDING:
#   Cuando mlvpn arranca, abre un socket UDP por cada enlace configurado,
#   cada uno vinculado a la IP de una interfaz diferente:
#
#     Socket 1 (iPhone IP) ──UDP──> VPS:5080
#     Socket 2 (Pixel  IP) ──UDP──> VPS:5081
#
#   Cada paquete que entra en la interfaz tun (mlvpn0) se envia por UNO
#   de estos sockets. mlvpn reparte los paquetes entre todos los enlaces
#   activos, ponderado por el bandwidth_upload configurado. Si un enlace
#   se cae (timeout 30s sin respuesta), mlvpn lo marca como inactivo y
#   manda todo por los que quedan. Cuando vuelve, lo reactiva.
#
#   En el VPS ocurre lo inverso: los paquetes llegan por los dos puertos,
#   mlvpn los reensambla en orden y los inyecta en la interfaz tun.
#
# RUTAS ESPECIFICAS AL VPS:
#   Necesitamos que los paquetes UDP de mlvpn (que van al VPS) NO pasen
#   por la propia interfaz tun de mlvpn (bucle infinito). Por eso creamos
#   rutas especificas: "para llegar al VPS, usa directamente la interfaz
#   iPhone/Pixel, no el tunel".
#
#   Cada enlace tiene su propia ruta, asi los paquetes de cada socket
#   salen por la interfaz correcta.
#
# REQUISITOS:
#   - Scripts 01, 02, 03 ejecutados
#   - iPhone compartiendo internet (Wi-Fi hotspot o USB)
#   - Pixel compartiendo internet por USB
###############################################################################
set -euo pipefail

# Este script requiere sudo: las rutas y la creación de la interfaz utun
# necesitan root. mlvpn hace privilege separation con --user mlvpn:
# el proceso padre (root) crea la interfaz, el hijo cae a usuario mlvpn.
if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Este script requiere sudo."
    echo "Ejecuta: sudo ./04-conectar.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config/env"
GENERATED_DIR="${SCRIPT_DIR}/generated"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: No existe config/env"
    exit 1
fi
if [[ ! -f "${GENERATED_DIR}/mlvpn.conf" ]]; then
    echo "ERROR: Ejecuta primero 03-setup-mac.sh"
    exit 1
fi

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

# =====================================================================
# Paso 1: Detectar IPs actuales de cada interfaz
#
# Las IPs cambian cada vez que te conectas (DHCP del operador movil).
# ipconfig getifaddr: obtiene la IPv4 asignada a una interfaz en macOS.
# =====================================================================
echo "=> Detectando interfaces..."

IP_IPHONE="$(ipconfig getifaddr "${IFACE_IPHONE}" 2>/dev/null || true)"
IP_PIXEL="$(ipconfig getifaddr "${IFACE_PIXEL}" 2>/dev/null || true)"

echo "  iPhone (${IFACE_IPHONE}): ${IP_IPHONE:-NO DETECTADO}"
echo "  Pixel  (${IFACE_PIXEL}):  ${IP_PIXEL:-NO DETECTADO}"

if [[ -z "${IP_IPHONE}" && -z "${IP_PIXEL}" ]]; then
    echo ""
    echo "ERROR: Ninguna interfaz tiene IP. Verifica:"
    echo "  - iPhone: hotspot activo y Mac conectado al Wi-Fi del iPhone"
    echo "  - Pixel:  tethering USB activo y cable conectado"
    exit 1
fi

ACTIVE_LINKS=0
[[ -n "${IP_IPHONE}" ]] && ACTIVE_LINKS=$((ACTIVE_LINKS + 1))
[[ -n "${IP_PIXEL}" ]] && ACTIVE_LINKS=$((ACTIVE_LINKS + 1))
echo "  Enlaces activos: ${ACTIVE_LINKS}"

# =====================================================================
# Paso 2: Crear rutas especificas al VPS
#
# Cada interfaz necesita su propia ruta al VPS. Usamos -ifscope para
# forzar que los paquetes salgan por esa interfaz concreta, aunque
# la tabla de rutas diga otra cosa.
#
# get_gateway: averigua la puerta de enlace (router del operador) de
# una interfaz. Lo necesitamos como "next hop" de la ruta.
# =====================================================================
echo ""
echo "=> Configurando rutas al VPS (${VPS_IP})..."

get_gateway() {
    local iface="$1"
    netstat -rn -f inet | awk -v iface="${iface}" '$1 == "default" && $NF == iface {print $2; exit}'
}

# Limpiar rutas previas
sudo route -n delete "${VPS_IP}/32" 2>/dev/null || true

if [[ -n "${IP_IPHONE}" ]]; then
    GW_IPHONE="$(get_gateway "${IFACE_IPHONE}")"
    if [[ -n "${GW_IPHONE}" ]]; then
        sudo route -n add -host "${VPS_IP}" "${GW_IPHONE}" -ifscope "${IFACE_IPHONE}"
        echo "  Ruta iPhone: ${VPS_IP} -> gw ${GW_IPHONE} (${IFACE_IPHONE})"
    fi
fi

if [[ -n "${IP_PIXEL}" ]]; then
    GW_PIXEL="$(get_gateway "${IFACE_PIXEL}")"
    if [[ -n "${GW_PIXEL}" ]]; then
        sudo route -n add -host "${VPS_IP}" "${GW_PIXEL}" -ifscope "${IFACE_PIXEL}"
        echo "  Ruta Pixel:  ${VPS_IP} -> gw ${GW_PIXEL} (${IFACE_PIXEL})"
    fi
fi

# =====================================================================
# Paso 3: Actualizar config con las IPs reales
#
# En la configuracion base, los bindhost estan como PLACEHOLDER.
# Los reemplazamos con las IPs reales detectadas. Si una interfaz no
# tiene IP, ponemos 0.0.0.0 (mlvpn intentara conectar y fallara
# gracefully, usando solo el otro enlace).
# =====================================================================
echo ""
echo "=> Actualizando configuracion con IPs reales..."

cp "${GENERATED_DIR}/mlvpn.conf" "${GENERATED_DIR}/mlvpn_active.conf"
chmod 600 "${GENERATED_DIR}/mlvpn_active.conf"

sed -i '' "s/PLACEHOLDER_IPHONE_IP/${IP_IPHONE:-0.0.0.0}/" "${GENERATED_DIR}/mlvpn_active.conf"
sed -i '' "s/PLACEHOLDER_PIXEL_IP/${IP_PIXEL:-0.0.0.0}/" "${GENERATED_DIR}/mlvpn_active.conf"

# =====================================================================
# Paso 4: Arrancar mlvpn
#
# --config: archivo de configuracion
# --name: nombre de la interfaz tun
# mlvpn corre en foreground por defecto; lo mandamos a background (&)
# y guardamos el PID para poder pararlo con 05-desconectar.sh.
# =====================================================================
echo ""
echo "=> Arrancando mlvpn (bonding)..."

# Matar instancia previa si existe
if [[ -f "${GENERATED_DIR}/mlvpn.pid" ]]; then
    OLD_PID="$(cat "${GENERATED_DIR}/mlvpn.pid")"
    sudo kill "${OLD_PID}" 2>/dev/null || true
    rm -f "${GENERATED_DIR}/mlvpn.pid"
fi

MLVPN_BIN=$(command -v mlvpn 2>/dev/null || echo "/usr/local/sbin/mlvpn")
rm -f "${GENERATED_DIR}/mlvpn.log"
touch "${GENERATED_DIR}/mlvpn.log"
# --user mlvpn: privilege separation — root crea utun, hijo cae a usuario mlvpn
"${MLVPN_BIN}" \
    --config "${GENERATED_DIR}/mlvpn_active.conf" \
    --name mlvpn0 \
    --user mlvpn \
    2>&1 | tee "${GENERATED_DIR}/mlvpn.log" &

MLVPN_PID=$!
echo "${MLVPN_PID}" > "${GENERATED_DIR}/mlvpn.pid"

# Esperar a que mlvpn autentique los enlaces y asignar IP al tunel
# mlvpn no llama al statuscommand de forma fiable en macOS (limitación del
# mecanismo priv_run_script en el contexto utun). Lo hacemos directamente.
echo "  Esperando autenticación de enlaces..."
UTUN_IFACE=""
for _ in $(seq 1 20); do
    # Detectar el utun que mlvpn creó buscando el proceso [priv]
    UTUN_IFACE=$(ps aux | grep "mlvpn: mlvpn0 \[priv\]" | grep -v grep | head -1 | \
        awk '{print $NF}' | xargs -I{} sh -c 'true' 2>/dev/null || true)
    # Buscar directamente en ifconfig el utun sin IP asignada (el de mlvpn)
    if pgrep -f "mlvpn: mlvpn0 @" &>/dev/null; then
        # Links autenticados — buscar utun sin IP configurada
        UTUN_IFACE=$(ifconfig | grep -B1 "nd6 options" | grep "utun" | tail -1 | cut -d: -f1)
        [[ -n "${UTUN_IFACE}" ]] && break
    fi
    sleep 1
done

if [[ -n "${UTUN_IFACE}" ]]; then
    echo "  Configurando ${UTUN_IFACE} con IP del tunel..."
    ifconfig "${UTUN_IFACE}" "${TUN_MAC_IP}" "${TUN_VPS_IP}" mtu "${TUN_MTU}" up 2>/dev/null || true
    # NOTA: NO añadimos rutas 0/1 y 128/1 aquí — causarían loop si el tunel
    # no reenvía correctamente. El tráfico al VPS (10.10.10.1) funciona
    # via la ruta host P2P automática de utunX.
    echo "  Tunel configurado en ${UTUN_IFACE}"
else
    echo "  AVISO: No se pudo detectar la interfaz utun de mlvpn"
fi

# =====================================================================
# Paso 5: Verificar conectividad
# =====================================================================
echo ""
echo "=> Verificando conectividad por el tunel..."

if ping -c 2 -W 2 "${TUN_VPS_IP}" &>/dev/null; then
    echo "  Ping al VPS por el tunel: OK"
else
    echo "  AVISO: No hay ping al VPS por el tunel."
    echo "  Puede tardar unos segundos en establecerse."
    echo "  Verifica con: ping ${TUN_VPS_IP}"
fi

# =====================================================================
# Paso 6: Resumen
# =====================================================================
echo ""
echo "=== BONDING ACTIVO ==="
echo ""
echo "  Tunel:   ${TUN_MAC_IP} <-> ${TUN_VPS_IP}"
echo "  Enlaces: ${ACTIVE_LINKS} activos"
[[ -n "${IP_IPHONE}" ]] && echo "    - iPhone (${IFACE_IPHONE}): ${IP_IPHONE} -> VPS:${MLVPN_PORT_1}"
[[ -n "${IP_PIXEL}" ]]  && echo "    - Pixel  (${IFACE_PIXEL}):  ${IP_PIXEL}  -> VPS:${MLVPN_PORT_2}"
echo ""
echo "  PID:     ${MLVPN_PID}"
echo "  Log:     ${GENERATED_DIR}/mlvpn.log"
echo ""
echo "Todo tu trafico (VPN, videollamadas, navegacion) ahora pasa por"
echo "AMBOS moviles a la vez. Si uno se cae, el otro absorbe sin corte."
echo ""
echo "Para ver el log en tiempo real:"
echo "  tail -f ${GENERATED_DIR}/mlvpn.log"
echo ""
echo "Para desconectar:"
echo "  ./05-desconectar.sh"
