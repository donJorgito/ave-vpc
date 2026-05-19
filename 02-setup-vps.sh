#!/usr/bin/env bash
###############################################################################
# 02-setup-vps.sh
#
# DONDE SE EJECUTA: En tu Mac (conecta por SSH al VPS y lo configura)
#
# QUE HACE:
#   Instala y configura mlvpn en el VPS como servidor. Despues de este script,
#   el VPS estara escuchando en dos puertos UDP (uno para cada enlace del Mac)
#   y reenviara el trafico combinado hacia internet.
#
# QUE INSTALA/CONFIGURA EN EL VPS:
#   1. mlvpn (compilado desde fuente — no esta en los repos de Ubuntu/Debian)
#   2. /etc/mlvpn/mlvpn.conf (configuracion del servidor)
#   3. /etc/mlvpn/mlvpn.secret (el secreto compartido)
#   4. /etc/mlvpn/mlvpn_updown.sh (script que configura la red al conectar)
#   5. IP forwarding (para reenviar paquetes del tunel a internet)
#   6. NAT/Masquerading (para que el trafico salga con la IP publica del VPS)
#   7. Servicio systemd (para que mlvpn arranque con el servidor)
#
# COMO FUNCIONA MLVPN EN EL SERVIDOR:
#   mlvpn escucha en N puertos UDP (en nuestro caso, 2: uno para el enlace
#   iPhone y otro para el Pixel). Cada puerto recibe una parte de los paquetes
#   que el Mac envia. mlvpn los reensambla en orden y los inyecta en una
#   interfaz virtual (mlvpn0/tun0). Desde ahi, el kernel los reenvía a
#   internet como trafico normal (gracias a IP forwarding + NAT).
#
#   En sentido inverso: el trafico de respuesta llega al VPS, el kernel lo
#   envia a mlvpn0, mlvpn lo trocea y lo reparte por los dos puertos UDP
#   de vuelta al Mac.
#
# REQUISITOS:
#   - Haber ejecutado 01-generar-secreto.sh
#   - config/env rellenado con la IP y usuario del VPS
#   - Acceso SSH al VPS con clave (sin password)
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_DIR="${SCRIPT_DIR}/keys"
CONFIG_FILE="${SCRIPT_DIR}/config/env"

# --- Validaciones ---
if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: No existe config/env"
    echo "Copia config/env.example a config/env y rellena tus valores"
    exit 1
fi

if [[ ! -f "${KEYS_DIR}/mlvpn.secret" ]]; then
    echo "ERROR: No existe el secreto. Ejecuta primero 01-generar-secreto.sh"
    exit 1
fi

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

MLVPN_SECRET="$(cat "${KEYS_DIR}/mlvpn.secret")"

echo "=> Conectando al VPS ${VPS_IP} y configurando mlvpn..."
echo ""

# --- Copiar secreto al VPS ---
echo "=> Copiando secreto al VPS..."
ssh -p "${VPS_SSH_PORT}" "${VPS_USER}@${VPS_IP}" "sudo mkdir -p /etc/mlvpn && sudo chmod 700 /etc/mlvpn"
echo "${MLVPN_SECRET}" | ssh -p "${VPS_SSH_PORT}" "${VPS_USER}@${VPS_IP}" "sudo tee /etc/mlvpn/mlvpn.secret > /dev/null && sudo chmod 600 /etc/mlvpn/mlvpn.secret"

# --- Configurar el VPS ---
ssh -p "${VPS_SSH_PORT}" "${VPS_USER}@${VPS_IP}" \
    MLVPN_PORT_1="${MLVPN_PORT_1}" \
    MLVPN_PORT_2="${MLVPN_PORT_2}" \
    TUN_VPS_IP="${TUN_VPS_IP}" \
    TUN_MAC_IP="${TUN_MAC_IP}" \
    TUN_NETMASK="${TUN_NETMASK}" \
    TUN_MTU="${TUN_MTU}" \
    bash <<'REMOTE_SCRIPT'
set -euo pipefail

# =====================================================================
# Paso 1: Instalar dependencias de compilacion
# mlvpn no esta en los repos oficiales de Ubuntu/Debian, asi que lo
# compilamos. Necesita: libev (bucle de eventos), libsodium (crypto),
# autotools (sistema de build).
# =====================================================================
echo "  [VPS] Instalando dependencias de compilacion..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
    build-essential \
    pkg-config \
    autoconf \
    automake \
    libtool \
    libev-dev \
    libsodium-dev \
    git

# =====================================================================
# Paso 2: Compilar e instalar mlvpn
# Clonamos el repositorio oficial, compilamos y lo instalamos en
# /usr/local/sbin/mlvpn
# =====================================================================
if command -v mlvpn &>/dev/null; then
    echo "  [VPS] mlvpn ya esta instalado: $(mlvpn --version 2>&1 | head -1)"
else
    echo "  [VPS] Compilando mlvpn desde fuente..."
    cd /tmp
    rm -rf mlvpn-build
    git clone --depth 1 https://github.com/zehome/MLVPN.git mlvpn-build
    cd mlvpn-build
    ./autogen.sh
    ./configure --sysconfdir=/etc
    make -j"$(nproc)"
    sudo make install
    echo "  [VPS] mlvpn instalado: $(mlvpn --version 2>&1 | head -1)"
    cd /
    rm -rf /tmp/mlvpn-build
fi

# =====================================================================
# Paso 3: Crear configuracion de mlvpn
#
# Formato TOML. Secciones importantes:
# [general]: modo servidor, nombre de interfaz tun, secreto
# [links.X]: cada enlace es un puerto UDP que escucha conexiones del Mac
#
# Dos enlaces = dos puertos = dos caminos por los que el Mac envia
# paquetes. mlvpn los combina en uno solo (bonding).
# =====================================================================
echo "  [VPS] Escribiendo /etc/mlvpn/mlvpn.conf..."

sudo tee /etc/mlvpn/mlvpn.conf > /dev/null <<EOF
[general]
# "server" = escucha conexiones entrantes
mode = "server"

# Tipo de interfaz virtual y nombre
tuntap = "tun"
interface_name = "mlvpn0"

# IPs del tunel (este extremo y el otro)
ip4 = "${TUN_VPS_IP}"
ip4_gateway = "${TUN_MAC_IP}"
mtu = ${TUN_MTU}

# Secreto compartido (embebido directamente — file:// no implementado en mlvpn)
password = "${MLVPN_SECRET}"

# Timeout: si no recibe paquetes en 30s, considera el enlace caido
timeout = 30

# Script que mlvpn ejecuta al subir/bajar la interfaz
# Firma: script <device> <evento> — env: IP4, IP4_GATEWAY, MTU, DEVICE
statuscommand = "/etc/mlvpn/mlvpn_updown.sh"

[filters]
# Reorder buffer: mlvpn reordena los paquetes que llegan desordenados
# (porque viajan por caminos distintos con latencias distintas)
[filters.fifo]

# ---- Enlace 1: recibe paquetes que el Mac envia por el iPhone ----
[links.iphone]
bindport = ${MLVPN_PORT_1}

# ---- Enlace 2: recibe paquetes que el Mac envia por el Pixel ----
[links.pixel]
bindport = ${MLVPN_PORT_2}
EOF

sudo chmod 600 /etc/mlvpn/mlvpn.conf

# =====================================================================
# Paso 4: Script up/down
#
# mlvpn ejecuta este script cuando la interfaz tun se levanta (up) o
# se baja (down). Lo usamos para:
# - Configurar la IP de la interfaz tun
# - Activar NAT (masquerading) para que el trafico salga a internet
# - Limpiar todo al bajar
# =====================================================================
echo "  [VPS] Escribiendo /etc/mlvpn/mlvpn_updown.sh..."

sudo tee /etc/mlvpn/mlvpn_updown.sh > /dev/null <<'UPDOWN'
#!/bin/bash
# mlvpn statuscommand — firma: script <device> <evento> [link]
# Env: IP4, IP4_GATEWAY, MTU, DEVICE
IFACE="$1"
EVENT="$2"
DEFAULT_IFACE=$(ip route show default | awk '{print $5; exit}')

case "${EVENT}" in
    tuntap_up)
        ip addr add "${IP4}/24" dev "${IFACE}"
        ip link set "${IFACE}" up mtu "${MTU}"
        iptables -t nat -A POSTROUTING -s "${IP4%.*}.0/24" -o "${DEFAULT_IFACE}" -j MASQUERADE
        iptables -A FORWARD -i "${IFACE}" -j ACCEPT
        iptables -A FORWARD -o "${IFACE}" -j ACCEPT
        ;;
    tuntap_down)
        iptables -t nat -D POSTROUTING -s "${IP4%.*}.0/24" -o "${DEFAULT_IFACE}" -j MASQUERADE 2>/dev/null || true
        iptables -D FORWARD -i "${IFACE}" -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -o "${IFACE}" -j ACCEPT 2>/dev/null || true
        ;;
    rtun_up|rtun_down)
        ;;
esac
UPDOWN

# 700: mlvpn rechaza ejecutar scripts accesibles por grupo/otros
sudo chmod 700 /etc/mlvpn/mlvpn_updown.sh

# =====================================================================
# Paso 5: Activar IP forwarding
# Sin esto, el kernel descarta los paquetes en vez de reenviarlos
# =====================================================================
echo "  [VPS] Activando IP forwarding..."
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward = 1" | sudo tee /etc/sysctl.d/99-mlvpn.conf > /dev/null
sudo sysctl -p /etc/sysctl.d/99-mlvpn.conf 2>/dev/null || true

# =====================================================================
# Paso 6: Abrir puertos UDP en el firewall del SO
# (en Oracle Cloud tambien hay que abrir en las Security Lists de la VCN)
# =====================================================================
echo "  [VPS] Configurando firewall..."
if command -v ufw &>/dev/null; then
    sudo ufw allow "${MLVPN_PORT_1}/udp" 2>/dev/null || true
    sudo ufw allow "${MLVPN_PORT_2}/udp" 2>/dev/null || true
    sudo ufw reload 2>/dev/null || true
elif command -v firewall-cmd &>/dev/null; then
    sudo firewall-cmd --permanent --add-port="${MLVPN_PORT_1}/udp" 2>/dev/null || true
    sudo firewall-cmd --permanent --add-port="${MLVPN_PORT_2}/udp" 2>/dev/null || true
    sudo firewall-cmd --reload 2>/dev/null || true
fi

# =====================================================================
# Paso 7: Crear servicio systemd
# Para que mlvpn arranque automaticamente con el servidor
# =====================================================================
echo "  [VPS] Creando servicio systemd..."

sudo tee /etc/systemd/system/mlvpn.service > /dev/null <<EOF
[Unit]
Description=MLVPN - Multi-Link VPN (bonding)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/mlvpn --config /etc/mlvpn/mlvpn.conf --name mlvpn0
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable mlvpn
sudo systemctl restart mlvpn

echo ""
echo "  [VPS] Estado del servicio:"
sudo systemctl status mlvpn --no-pager -l || true

echo ""
echo "  [VPS] Configuracion completada."
REMOTE_SCRIPT

echo ""
echo "=== VPS configurado ==="
echo ""
echo "Siguiente paso: ejecuta ./03-setup-mac.sh"
