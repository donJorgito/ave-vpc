#!/usr/bin/env bash
###############################################################################
# 07b-setup-rpi-ubond.sh
#
# DONDE SE EJECUTA: En tu Mac (conecta por SSH a la Raspberry Pi)
#
# QUE HACE:
#   Instala ubond (fork de mlvpn con replicación selectiva — REQ-NET-12)
#   en la RPi en paralelo a mlvpn. NO sustituye mlvpn — coexisten:
#
#     mlvpn  → /usr/local/sbin/mlvpn   ufw 5080/5081/5082/udp   mlvpn.service
#     ubond  → /usr/local/sbin/ubond   ufw 5083/5084/5085/udp   ubond.service
#
#   Puertos distintos para que ambos servidores puedan estar arriba a la
#   vez. El cliente elige cuál usar (mlvpn sin filter.replicate, ubond con).
#
# REQUISITOS:
#   - 03b-setup-mac-ubond.sh ejecutado antes (necesita keys/mlvpn.secret
#     compartido, mismo secret que mlvpn).
#   - RPi accesible vía SSH (mismo VPS_IP/RPi_USER que para mlvpn).
#   - patches/ubond_replicate_filter.patch en el repo local.
#
# QUE NO HACE:
#   - No toca mlvpn ni su servicio (sigue arriba).
#   - No aplica los patches macOS (REQ-NET-19) — Linux compila vanilla.
#   - Solo aplica patches/ubond_replicate_filter.patch (REQ-NET-12).
#
# FLAGS:
#   --host HOST   Sobrescribe RPi_IP del config (ej. usar DDNS público
#                 200bares.dedyn.io desde fuera de la LAN doméstica).
#   --user USER   Sobrescribe RPi_USER del config.
#   --port PORT   Sobrescribe RPi_SSH_PORT del config.
#
# EJEMPLO (desde la oficina, vía DDNS+puerto SSH externo):
#   ./07b-setup-rpi-ubond.sh --host 200bares.dedyn.io --user jorge --port 2222
###############################################################################
set -euo pipefail

# --- Parser de flags (antes de source) ---
CLI_HOST=""
CLI_USER=""
CLI_PORT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) CLI_HOST="$2"; shift 2 ;;
        --user) CLI_USER="$2"; shift 2 ;;
        --port) CLI_PORT="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^###/p' "$0" | grep -E "^# " | sed 's/^# //'
            exit 0
            ;;
        *)
            echo "ERROR: argumento desconocido: $1"
            echo "Uso: $0 [--host HOST] [--user USER] [--port PORT]"
            exit 1
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_DIR="${SCRIPT_DIR}/keys"
CONFIG_FILE="${SCRIPT_DIR}/config/env"
PATCHES_DIR="${SCRIPT_DIR}/patches"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: No existe config/env"
    exit 1
fi
if [[ ! -f "${KEYS_DIR}/mlvpn.secret" ]]; then
    echo "ERROR: keys/mlvpn.secret no existe. Ejecuta primero 01-generar-secreto.sh"
    exit 1
fi
if [[ ! -f "${PATCHES_DIR}/ubond_replicate_filter.patch" ]]; then
    echo "ERROR: patches/ubond_replicate_filter.patch no existe"
    exit 1
fi

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

# Precedencia: flag CLI > config/env > default literal.
RPi_IP="${CLI_HOST:-${RPi_IP:-}}"
RPi_USER="${CLI_USER:-${RPi_USER:-ubuntu}}"
RPi_SSH_PORT="${CLI_PORT:-${RPi_SSH_PORT:-22}}"

if [[ -z "${RPi_IP}" ]]; then
    echo "ERROR: RPi_IP no definido (ni en config/env ni vía --host)"
    exit 1
fi

# Puertos UDP de ubond — distintos a mlvpn para coexistir
UBOND_PORT_1="${UBOND_PORT_1:-5083}"
UBOND_PORT_2="${UBOND_PORT_2:-5084}"
UBOND_PORT_3="${UBOND_PORT_3:-5085}"

UBOND_SECRET="$(cat "${KEYS_DIR}/mlvpn.secret")"
# El patch va base64-encoded: SSH joins args con espacio y rompe newlines.
# Pasarlo crudo hizo que líneas como "--- a/src/ubond.c" se interpretasen
# como comandos remotos. base64 sin newlines (-w0 en GNU; en macOS sin
# argumento equivalente por defecto, pero `base64` de macOS NO inserta
# newlines automáticamente).
UBOND_PATCH_B64="$(base64 < "${PATCHES_DIR}/ubond_replicate_filter.patch" | tr -d '\n')"

echo "=> Conectando a la Raspberry Pi ${RPi_IP} (puerto SSH ${RPi_SSH_PORT})..."
echo "=> ubond escuchará en ${UBOND_PORT_1}/${UBOND_PORT_2}/${UBOND_PORT_3} UDP (paralelo a mlvpn 5080-5082)"

ssh -p "${RPi_SSH_PORT}" "${RPi_USER}@${RPi_IP}" \
    UBOND_PORT_1="${UBOND_PORT_1}" \
    UBOND_PORT_2="${UBOND_PORT_2}" \
    UBOND_PORT_3="${UBOND_PORT_3}" \
    UBOND_SECRET="${UBOND_SECRET}" \
    TUN_VPS_IP="${TUN_VPS_IP}" \
    TUN_MAC_IP="${TUN_MAC_IP}" \
    TUN_MTU="${TUN_MTU}" \
    UBOND_PATCH_B64="${UBOND_PATCH_B64}" \
    bash <<'REMOTE_SCRIPT'
set -euo pipefail

# =====================================================================
# Paso 1: Dependencias (las mismas que mlvpn — ya estarán si éste corre)
# =====================================================================
echo "  [RPi] Verificando dependencias..."
sudo apt-get update -qq >/dev/null 2>&1 || true
sudo apt-get install -y -qq \
    build-essential pkg-config autoconf automake libtool \
    libev-dev libsodium-dev libpcap-dev git \
    >/dev/null 2>&1 || true
echo "  [RPi] Dependencias OK"

# =====================================================================
# Paso 2: Compilar ubond con el patch de replicación
# Solo el patch REQ-NET-12 — los patches macOS (REQ-NET-19) NO aplican
# en Linux: SO_BINDTODEVICE existe, struct ifreq es completa, tuntap
# usa /dev/net/tun y no necesita el reemplazo utun-API.
# =====================================================================
if command -v ubond &>/dev/null; then
    echo "  [RPi] ubond ya instalado"
else
    echo "  [RPi] Compilando ubond desde fuente con patch REQ-NET-12..."
    cd /tmp
    rm -rf ubond-build
    git clone --depth 1 https://github.com/markfoodyburton/ubond.git ubond-build
    cd ubond-build

    # Volcar el patch (pasado base64-encoded por env var) y aplicarlo
    printf '%s' "${UBOND_PATCH_B64}" | base64 -d > /tmp/ubond_replicate_filter.patch
    if ! patch -p1 -N --reject-file=- < /tmp/ubond_replicate_filter.patch 2>&1 | head -10; then
        echo "  [RPi] (patch ya aplicado o no aplicable; continuando)"
    fi
    rm -f /tmp/ubond_replicate_filter.patch

    ./autogen.sh
    # --enable-filters: requerido para [filters.replicate]
    ./configure --sysconfdir=/etc --enable-filters
    make -j"$(nproc)"
    sudo make install
    echo "  [RPi] ubond instalado"
    cd /
    rm -rf /tmp/ubond-build
fi

# =====================================================================
# Paso 3: Config /etc/ubond/ubond.conf (servidor)
# Mismo secret que mlvpn, mismo TUN_*_IP/MTU. Puertos distintos.
# Sección [filters.replicate] presente pero VACÍA — el cliente decide
# qué replicar; el servidor solo necesita [filters.replicate] declarada
# para que el dedup LRU se active en protocol_read.
# =====================================================================
echo "  [RPi] Escribiendo /etc/ubond/ubond.conf..."
sudo mkdir -p /etc/ubond
sudo tee /etc/ubond/ubond.conf > /dev/null <<EOF
[general]
mode = "server"
tuntap = "tun"
interface_name = "ubond0"
ip4 = "${TUN_VPS_IP}"
ip4_gateway = "${TUN_MAC_IP}"
mtu = ${TUN_MTU}
password = "${UBOND_SECRET}"
timeout = 30
statuscommand = "/etc/ubond/ubond_updown.sh"

[filters]
[filters.fifo]

# REQ-NET-12: en el servidor la sección puede estar vacía. El dedup
# LRU se activa en protocol_read independiente del contenido de
# esta sección. Las reglas las define el cliente.
[filters.replicate]

[links.iphone]
bindhost = "0.0.0.0"
bindport = ${UBOND_PORT_1}
bandwidth_upload = 10000000

[links.pixel]
bindhost = "0.0.0.0"
bindport = ${UBOND_PORT_2}
bandwidth_upload = 10000000

[links.wifi]
bindhost = "0.0.0.0"
bindport = ${UBOND_PORT_3}
bandwidth_upload = 50000000
timeout = 8
EOF
sudo chmod 600 /etc/ubond/ubond.conf

# =====================================================================
# Paso 4: Updown script — IDÉNTICO al de mlvpn (firma compatible)
# =====================================================================
echo "  [RPi] Escribiendo /etc/ubond/ubond_updown.sh..."
sudo tee /etc/ubond/ubond_updown.sh > /dev/null <<'UPDOWN'
#!/bin/bash
# ubond statuscommand - firma: script <device> <evento> [link]
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
sudo chmod 700 /etc/ubond/ubond_updown.sh

# =====================================================================
# Paso 5: Usuario sistema 'ubond' (paralelo a 'mlvpn')
# =====================================================================
sudo useradd --system --no-create-home --home-dir /var/lib/ubond \
    --shell /usr/sbin/nologin ubond 2>/dev/null || true
sudo mkdir -p /var/lib/ubond
sudo chown ubond:ubond /var/lib/ubond
sudo chmod 750 /var/lib/ubond

# =====================================================================
# Paso 6: ufw — abrir los 3 puertos UDP nuevos
# =====================================================================
echo "  [RPi] Abriendo ufw ${UBOND_PORT_1}/${UBOND_PORT_2}/${UBOND_PORT_3} UDP..."
sudo ufw allow "${UBOND_PORT_1}/udp" >/dev/null
sudo ufw allow "${UBOND_PORT_2}/udp" >/dev/null
sudo ufw allow "${UBOND_PORT_3}/udp" >/dev/null
sudo ufw reload >/dev/null

# =====================================================================
# Paso 7: systemd unit ubond.service (paralelo a mlvpn.service)
# =====================================================================
echo "  [RPi] Creando servicio systemd ubond.service..."
sudo tee /etc/systemd/system/ubond.service > /dev/null <<EOF
[Unit]
Description=UBOND - Multi-Link VPN with selective packet replication
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/ubond --config /etc/ubond/ubond.conf --name ubond0 --user ubond
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable ubond
# NO arrancarlo automáticamente — el usuario decide cuándo activar v2.
# Para arrancar: sudo systemctl start ubond
echo "  [RPi] Servicio creado pero NO iniciado (decisión del usuario)"
echo "  [RPi] Para activar:    sudo systemctl start ubond"
echo "  [RPi] Para desactivar: sudo systemctl stop ubond"
echo ""
echo "  [RPi] Configuración completada."
REMOTE_SCRIPT

echo ""
echo "=== Raspberry Pi ubond configurada ==="
echo ""
echo "  Servidor mlvpn  → /etc/mlvpn/mlvpn.conf  (puertos 5080/5081/5082)"
echo "  Servidor ubond  → /etc/ubond/ubond.conf  (puertos ${UBOND_PORT_1}/${UBOND_PORT_2}/${UBOND_PORT_3})"
echo "  Coexisten — ambos pueden estar arriba simultáneamente."
echo ""
echo "  Para activar ubond servidor:"
echo "    ssh -p ${RPi_SSH_PORT} ${RPi_USER}@${RPi_IP} 'sudo systemctl start ubond'"
echo ""
echo "  Para validar el setup en el router:"
echo "    Añadir port forwarding ${UBOND_PORT_1}/${UBOND_PORT_2}/${UBOND_PORT_3} UDP → RPi:${UBOND_PORT_1}/${UBOND_PORT_2}/${UBOND_PORT_3}"
echo ""
echo "  Próximo: 04b-conectar-ubond.sh en el Mac (Fase 4 pendiente)."
