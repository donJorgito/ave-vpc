#!/usr/bin/env bash
###############################################################################
# 07-setup-rpi.sh
#
# DONDE SE EJECUTA: En tu Mac (conecta por SSH a la Raspberry Pi y la configura)
#
# QUE HACE:
#   Instala y configura mlvpn en la Raspberry Pi como servidor. Es el
#   equivalente a 02-setup-vps.sh pero para una RPi en casa en lugar de
#   un VPS en la nube.
#
# QUE INSTALA/CONFIGURA EN LA RPi:
#   1. mlvpn (compilado desde fuente con libpcap-dev, libsodium-dev, libev-dev)
#   2. /etc/mlvpn/mlvpn.conf      — configuracion del servidor
#   3. /etc/mlvpn/mlvpn.secret    — secreto compartido
#   4. /etc/mlvpn/mlvpn_updown.sh — configura red al conectar/desconectar
#   5. usuario mlvpn (system) + /var/lib/mlvpn (chroot dir)
#   6. IP forwarding + NAT         — para reenviar trafico a internet
#   7. Servicio systemd            — mlvpn arranca con la RPi (--user mlvpn)
#
# LO QUE NO HACE ESTE SCRIPT (se configura fuera):
#   - DDNS: lo gestiona el router ZTE F6640 de forma nativa
#     (Internet -> DDNS). Ver docs/rpi-setup.md para instrucciones.
#   - Port Forwarding: se configura en el router
#     (Internet -> Security -> Port Forwarding)
#
# REQUISITOS PREVIOS:
#   - RPi con Ubuntu Server 26.04 LTS, SSH activado con tu clave publica
#   - RPi conectada por cable ethernet al router
#   - 01-generar-secreto.sh ejecutado
#   - config/env con RPi_IP, RPi_USER, RPi_SSH_PORT rellenados
#   - Port forwarding en router: UDP 5080 y 5081 -> RPi_IP
#   - DDNS configurado en el router con el hostname que usaras como VPS_IP
#
# DESPUES DE ESTE SCRIPT:
#   - Pon VPS_IP=tu-hostname.dedyn.io en config/env
#   - Ejecuta ./03-setup-mac.sh para regenerar la config del Mac
#   - Ejecuta ./04-conectar.sh en el AVE como siempre
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_DIR="${SCRIPT_DIR}/keys"
CONFIG_FILE="${SCRIPT_DIR}/config/env"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: No existe config/env"
    echo "Copia config/env.example a config/env y rellena RPi_IP, RPi_USER, etc."
    exit 1
fi

if [[ ! -f "${KEYS_DIR}/mlvpn.secret" ]]; then
    echo "ERROR: No existe el secreto. Ejecuta primero 01-generar-secreto.sh"
    exit 1
fi

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

RPi_IP="${RPi_IP:-}"
RPi_USER="${RPi_USER:-ubuntu}"
RPi_SSH_PORT="${RPi_SSH_PORT:-22}"

if [[ -z "${RPi_IP}" ]]; then
    echo "ERROR: RPi_IP no definido en config/env"
    echo "Busca la IP en el router: http://192.168.1.1 -> Home -> LAN Devices"
    exit 1
fi

MLVPN_SECRET="$(cat "${KEYS_DIR}/mlvpn.secret")"

echo "=> Conectando a la Raspberry Pi ${RPi_IP}..."
echo ""

echo "=> Copiando secreto..."
ssh -p "${RPi_SSH_PORT}" "${RPi_USER}@${RPi_IP}" \
    "sudo mkdir -p /etc/mlvpn && sudo chmod 700 /etc/mlvpn"
echo "${MLVPN_SECRET}" | ssh -p "${RPi_SSH_PORT}" "${RPi_USER}@${RPi_IP}" \
    "sudo tee /etc/mlvpn/mlvpn.secret > /dev/null && sudo chmod 600 /etc/mlvpn/mlvpn.secret"

ssh -p "${RPi_SSH_PORT}" "${RPi_USER}@${RPi_IP}" \
    MLVPN_PORT_1="${MLVPN_PORT_1}" \
    MLVPN_PORT_2="${MLVPN_PORT_2}" \
    TUN_VPS_IP="${TUN_VPS_IP}" \
    TUN_MAC_IP="${TUN_MAC_IP}" \
    TUN_MTU="${TUN_MTU}" \
    bash <<'REMOTE_SCRIPT'
set -euo pipefail

# =====================================================================
# Paso 1: Dependencias
# =====================================================================
echo "  [RPi] Instalando dependencias..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
    build-essential pkg-config autoconf automake libtool \
    libev-dev libsodium-dev libpcap-dev git

# =====================================================================
# Paso 2: Compilar mlvpn
# En ARM tarda unos 2-3 minutos la primera vez.
# =====================================================================
if command -v mlvpn &>/dev/null; then
    echo "  [RPi] mlvpn ya instalado: $(mlvpn --version 2>&1 | head -1)"
else
    echo "  [RPi] Compilando mlvpn desde fuente (2-3 min en ARM)..."
    cd /tmp
    rm -rf mlvpn-build
    git clone --depth 1 https://github.com/zehome/MLVPN.git mlvpn-build
    cd mlvpn-build
    ./autogen.sh
    ./configure --sysconfdir=/etc
    make -j"$(nproc)"
    sudo make install
    echo "  [RPi] mlvpn instalado: $(mlvpn --version 2>&1 | head -1)"
    cd /
    rm -rf /tmp/mlvpn-build
fi

# =====================================================================
# Paso 3: Configuracion de mlvpn
# Identica a la del VPS de Oracle Cloud: modo servidor, dos enlaces UDP.
# =====================================================================
echo "  [RPi] Escribiendo /etc/mlvpn/mlvpn.conf..."

sudo tee /etc/mlvpn/mlvpn.conf > /dev/null <<EOF
[general]
mode = "server"
tuntap = "tun"
interface_name = "mlvpn0"
ip4 = "${TUN_VPS_IP}"
ip4_gateway = "${TUN_MAC_IP}"
mtu = ${TUN_MTU}
password = "${MLVPN_SECRET}"
timeout = 30
ip4_updns = "/etc/mlvpn/mlvpn_updown.sh"

[filters]
[filters.fifo]

[links.iphone]
bindport = ${MLVPN_PORT_1}

[links.pixel]
bindport = ${MLVPN_PORT_2}
EOF

sudo chmod 600 /etc/mlvpn/mlvpn.conf

# =====================================================================
# Paso 4: Script up/down — configura IP del tunel y NAT al conectar
# =====================================================================
echo "  [RPi] Escribiendo /etc/mlvpn/mlvpn_updown.sh..."

sudo tee /etc/mlvpn/mlvpn_updown.sh > /dev/null <<'UPDOWN'
#!/bin/bash
DEFAULT_IFACE=$(ip route show default | awk '{print $5; exit}')

case "$1" in
    up)
        ip addr add "${MLVPN_IPADDR}/24" dev "${MLVPN_INTERFACE}"
        ip link set "${MLVPN_INTERFACE}" up mtu "${MLVPN_MTU}"
        iptables -t nat -A POSTROUTING -s "${MLVPN_IPADDR%.*}.0/24" -o "${DEFAULT_IFACE}" -j MASQUERADE
        iptables -A FORWARD -i "${MLVPN_INTERFACE}" -j ACCEPT
        iptables -A FORWARD -o "${MLVPN_INTERFACE}" -j ACCEPT
        ;;
    down)
        iptables -t nat -D POSTROUTING -s "${MLVPN_IPADDR%.*}.0/24" -o "${DEFAULT_IFACE}" -j MASQUERADE 2>/dev/null || true
        iptables -D FORWARD -i "${MLVPN_INTERFACE}" -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -o "${MLVPN_INTERFACE}" -j ACCEPT 2>/dev/null || true
        ;;
esac
UPDOWN

sudo chmod 755 /etc/mlvpn/mlvpn_updown.sh

# =====================================================================
# Paso 5: Usuario dedicado mlvpn y directorio de chroot
# mlvpn hace chroot al home del usuario con el que corre. Usar un usuario
# dedicado en lugar de nobody mejora la trazabilidad en logs y auditoría.
# =====================================================================
sudo useradd --system --no-create-home --home-dir /var/lib/mlvpn \
    --shell /usr/sbin/nologin mlvpn 2>/dev/null || true
sudo mkdir -p /var/lib/mlvpn
sudo chown mlvpn:mlvpn /var/lib/mlvpn
sudo chmod 750 /var/lib/mlvpn

# =====================================================================
# Paso 7: IP forwarding
# Sin esto el kernel descarta los paquetes en lugar de reenviarlos.
# =====================================================================
echo "  [RPi] Activando IP forwarding..."
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward = 1" | sudo tee /etc/sysctl.d/99-mlvpn.conf > /dev/null
sudo sysctl -p /etc/sysctl.d/99-mlvpn.conf 2>/dev/null || true

# =====================================================================
# Paso 8: Firewall — SSH + puertos mlvpn
# =====================================================================
echo "  [RPi] Configurando firewall (ufw)..."
sudo ufw --force enable
sudo ufw allow ssh
sudo ufw allow "${MLVPN_PORT_1}/udp"
sudo ufw allow "${MLVPN_PORT_2}/udp"
sudo ufw reload

# =====================================================================
# Paso 9: Servicio systemd — mlvpn arranca automaticamente con la RPi
# =====================================================================
echo "  [RPi] Creando servicio systemd..."

sudo tee /etc/systemd/system/mlvpn.service > /dev/null <<EOF
[Unit]
Description=MLVPN - Multi-Link VPN (bonding)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/mlvpn --config /etc/mlvpn/mlvpn.conf --name mlvpn0 --user mlvpn
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable mlvpn
sudo systemctl restart mlvpn

echo ""
echo "  [RPi] Estado del servicio:"
sudo systemctl status mlvpn --no-pager -l || true
echo ""
echo "  [RPi] Configuracion completada."
REMOTE_SCRIPT

echo ""
echo "=== Raspberry Pi configurada ==="
echo ""
echo "  Proximos pasos:"
echo "  1. Asegurate de que el DDNS esta configurado en el router ZTE"
echo "     (Internet -> DDNS) — ver docs/rpi-setup.md"
echo "  2. Actualiza VPS_IP en config/env con tu hostname DDNS:"
echo "     VPS_IP=\"tu-hostname.dedyn.io\""
echo "  3. Ejecuta ./03-setup-mac.sh para regenerar la config del Mac"
echo "  4. En el AVE: ./04-conectar.sh (igual que siempre)"
