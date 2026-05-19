#!/usr/bin/env bash
###############################################################################
# 03-setup-mac.sh
#
# DONDE SE EJECUTA: En tu Mac
#
# QUE HACE:
#   1. Compila e instala mlvpn en el Mac (si no esta instalado)
#   2. Genera la configuracion del cliente mlvpn
#
# COMO FUNCIONA MLVPN EN EL MAC (CLIENTE):
#   mlvpn abre N sockets UDP, cada uno vinculado (bound) a una interfaz
#   de red distinta. Cuando una app envia un paquete, el kernel lo pasa
#   a la interfaz virtual mlvpn0, y mlvpn lo envia por uno de los sockets
#   UDP. Reparte los paquetes entre todos los enlaces activos (round-robin
#   o ponderado por ancho de banda). El VPS los recibe por sus N puertos,
#   los reensambla en orden, y los envia a internet.
#
# BONDING VS FAILOVER:
#   - Failover: solo un enlace activo, el otro espera. Si cae, cambia.
#   - Bonding (lo que hace mlvpn): TODOS los enlaces activos a la vez.
#     Los paquetes se reparten entre todos. Ancho de banda = suma de todos.
#     Si un enlace cae, mlvpn lo detecta y redistribuye los paquetes
#     entre los que quedan. Sin cortes.
#
# INTERFACES FISICAS:
#   El script detecta las interfaces y sus IPs automaticamente.
#   Configuracion actual:
#     - iPhone: Wi-Fi tethering (Mac conectado al hotspot, interfaz en0)
#     - Pixel:  USB tethering (interfaz en5 o similar)
#
#   Se puede añadir un tercer enlace (ej: Wi-Fi del tren) si conectas
#   ambos moviles por USB y dejas en0 libre para el Wi-Fi del tren.
#   Ver README para instrucciones.
#
# REQUISITOS:
#   - Xcode Command Line Tools (xcode-select --install)
#   - Homebrew
#   - Haber ejecutado 01-generar-secreto.sh
#   - config/env rellenado
###############################################################################
set -euo pipefail

# No ejecutar como root — brew no funciona como root.
# El script usa sudo internamente donde hace falta.
if [[ "${EUID}" -eq 0 ]]; then
    echo "ERROR: No ejecutes este script con sudo."
    echo "Ejecuta: ./03-setup-mac.sh"
    echo "(El script usa sudo internamente para lo que necesita permisos)"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_DIR="${SCRIPT_DIR}/keys"
CONFIG_FILE="${SCRIPT_DIR}/config/env"
GENERATED_DIR="${SCRIPT_DIR}/generated"
BUILD_DIR="${SCRIPT_DIR}/build"

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

# =====================================================================
# Paso 1: Verificar Xcode Command Line Tools
# gcc, make y ld vienen de aquí — sin ellos no hay compilación posible.
# =====================================================================
echo "=> Verificando Xcode Command Line Tools..."
if ! xcode-select -p &>/dev/null; then
    echo "  Xcode CLT no instalado. Instalando..."
    xcode-select --install
    echo ""
    echo "  *** Acepta el diálogo de instalación y vuelve a ejecutar este script ***"
    exit 1
fi
echo "  ✓ Xcode CLT: $(xcode-select -p)"

# =====================================================================
# Paso 2: Instalar dependencias con Homebrew
# mlvpn necesita libev (event loop), libsodium (crypto) y autotools.
# libtool: Homebrew instala GNU libtool (glibtoolize) que autogen.sh necesita.
# =====================================================================
echo "=> Verificando dependencias Homebrew..."

if ! command -v brew &>/dev/null; then
    echo "  ERROR: Homebrew no está instalado."
    echo "  Instálalo desde https://brew.sh y vuelve a ejecutar este script."
    exit 1
fi

for dep in libev libsodium autoconf automake libtool pkg-config; do
    if ! brew list "${dep}" &>/dev/null; then
        echo "  Instalando ${dep}..."
        brew install "${dep}"
    else
        echo "  ✓ ${dep}"
    fi
done

# =====================================================================
# Paso 2: Compilar mlvpn
# No esta en Homebrew, asi que lo compilamos desde el repo oficial.
# Es un binario pequeño en C, tarda ~30 segundos.
# =====================================================================
if command -v mlvpn &>/dev/null || [[ -x /usr/local/sbin/mlvpn ]]; then
    echo "=> mlvpn ya esta instalado: $(/usr/local/sbin/mlvpn --version 2>&1 | head -1)"
else
    echo "=> Compilando mlvpn desde fuente..."
    mkdir -p "${BUILD_DIR}"
    cd "${BUILD_DIR}"

    if [[ ! -d "MLVPN" ]]; then
        git clone --depth 1 https://github.com/zehome/MLVPN.git
    fi

    cd MLVPN
    # Limpiar compilacion anterior si existe
    [[ -f Makefile ]] && make clean 2>/dev/null || true

    # Aplicar parche utun: sustituye la implementacion legacy /dev/tun por
    # la API nativa de macOS (SYSPROTO_CONTROL + UTUN_CONTROL_NAME).
    # Ver patches/tuntap_darwin_utun.c para documentacion detallada.
    cp "${SCRIPT_DIR}/patches/tuntap_darwin_utun.c" src/tuntap_darwin.c

    ./autogen.sh

    # En macOS, pkg-config necesita saber donde Homebrew instala las libs
    PKG_CONFIG_PATH="$(brew --prefix libev)/lib/pkgconfig:$(brew --prefix libsodium)/lib/pkgconfig"
    export PKG_CONFIG_PATH
    CFLAGS="-I$(brew --prefix libev)/include -I$(brew --prefix libsodium)/include"
    export CFLAGS
    LDFLAGS="-L$(brew --prefix libev)/lib -L$(brew --prefix libsodium)/lib"
    export LDFLAGS

    # ac_cv_func_strnvis=no: macOS tiene strnvis() pero con firma incompatible
    # con la que usa setproctitle.c de mlvpn — forzamos el fallback interno.
    ac_cv_func_strnvis=no ./configure --prefix=/usr/local --sysconfdir=/etc
    make -j"$(sysctl -n hw.ncpu)"
    sudo make install

    echo "  mlvpn instalado: $(/usr/local/sbin/mlvpn --version 2>&1 | head -1)"
    cd "${SCRIPT_DIR}"
fi

# =====================================================================
# Paso 3: Usuario de sistema mlvpn (privilege separation)
#
# mlvpn rechaza arrancar como root sin --user. Creamos un usuario de
# sistema dedicado igual que en la RPi. En macOS se usa dscl.
# /var/empty es el home (directorio de chroot de mlvpn).
# =====================================================================
echo "=> Verificando usuario de sistema mlvpn..."
if ! id mlvpn &>/dev/null; then
    echo "  Creando usuario de sistema mlvpn..."
    # Buscar un UniqueID libre a partir de 500
    NEW_UID=500
    while dscl . -list /Users UniqueID 2>/dev/null | awk '{print $2}' | grep -q "^${NEW_UID}$"; do
        NEW_UID=$((NEW_UID + 1))
    done
    sudo dscl . -create /Users/mlvpn
    sudo dscl . -create /Users/mlvpn UserShell /usr/bin/false
    sudo dscl . -create /Users/mlvpn RealName "mlvpn"
    sudo dscl . -create /Users/mlvpn UniqueID "${NEW_UID}"
    sudo dscl . -create /Users/mlvpn PrimaryGroupID 99
    sudo dscl . -create /Users/mlvpn NFSHomeDirectory /var/empty
    echo "  ✓ Usuario mlvpn creado (UID ${NEW_UID})"
else
    echo "  ✓ Usuario mlvpn ya existe"
fi

# =====================================================================
# Paso 4: Generar configuracion del cliente
#
# Cada [links.X] es un enlace fisico. mlvpn envia paquetes por TODOS
# los enlaces a la vez (bonding). Si uno se cae, redistribuye entre
# los demas automaticamente.
#
# bindhost: IP de la interfaz local por la que sale este enlace.
#   Se rellena dinamicamente en 04-conectar.sh (porque cambia con DHCP).
# remotehost/remoteport: IP y puerto del VPS para este enlace.
# bandwidth_upload: ancho de banda estimado en bps. mlvpn usa esto para
#   ponderar cuantos paquetes envia por cada enlace. Si un movil tiene
#   mas ancho de banda, le asigna mas paquetes.
# =====================================================================
echo "=> Generando configuracion del cliente..."

mkdir -p "${GENERATED_DIR}"
chmod 700 "${GENERATED_DIR}"

# Leer secreto (se incrusta directamente — file:// no está implementado en mlvpn)
MLVPN_SECRET="$(tr -d '\n' < "${KEYS_DIR}/mlvpn.secret")"

cat > "${GENERATED_DIR}/mlvpn.conf" <<EOF
[general]
# "client" = inicia conexiones hacia el servidor
mode = "client"

# Interfaz virtual del tunel
tuntap = "tun"
interface_name = "mlvpn0"

# IPs del tunel
ip4 = "${TUN_MAC_IP}"
ip4_gateway = "${TUN_VPS_IP}"
mtu = ${TUN_MTU}

# Secreto compartido (mismo que en el VPS)
password = "${MLVPN_SECRET}"

# Si no recibe nada en 30s, considera el enlace muerto
timeout = 30

# Script para configurar la interfaz tun y las rutas
statuscommand = "${GENERATED_DIR}/mlvpn_updown_mac.sh"

[filters]
[filters.fifo]

# ---- Enlace 1: iPhone (Wi-Fi hotspot / USB) ----
# bindhost se rellena en 04-conectar.sh con la IP real del momento
[links.iphone]
bindhost = "PLACEHOLDER_IPHONE_IP"
remotehost = "${VPS_IP}"
remoteport = ${MLVPN_PORT_1}
bandwidth_upload = 10000000

# ---- Enlace 2: Pixel (USB) ----
[links.pixel]
bindhost = "PLACEHOLDER_PIXEL_IP"
remotehost = "${VPS_IP}"
remoteport = ${MLVPN_PORT_2}
bandwidth_upload = 10000000
EOF

chmod 600 "${GENERATED_DIR}/mlvpn.conf"

# =====================================================================
# Paso 4: Generar script up/down para macOS
#
# mlvpn ejecuta este script cuando la interfaz tun se levanta o baja.
# En macOS la sintaxis de ifconfig y route es diferente a Linux.
# =====================================================================
cat > "${GENERATED_DIR}/mlvpn_updown_mac.sh" <<'UPDOWN'
#!/bin/bash
# Script que mlvpn ejecuta al cambiar el estado del tunel en macOS.
#
# Firma: script <interfaz> <evento> [nombre_enlace]
#   $1 = DEVICE   — nombre de interfaz utun asignado por el kernel (ej. utun7)
#   $2 = evento   — tuntap_up | tuntap_down | rtun_up | rtun_down
#   $3 = (solo en rtun_*) nombre del enlace
#
# Variables de entorno que mlvpn pasa:
#   IP4         — IP local del tunel (ej. 10.10.10.2)
#   IP4_GATEWAY — IP remota del tunel/gateway (ej. 10.10.10.1)
#   MTU         — MTU del tunel
#   DEVICE      — mismo que $1

IFACE="$1"
EVENT="$2"
LOG="/tmp/mlvpn_updown.log"
echo "$(date) called: iface=$IFACE event=$EVENT IP4=$IP4 IP4_GW=$IP4_GATEWAY MTU=$MTU" >> "$LOG"

case "${EVENT}" in
    tuntap_up)
        # Asignar IP a la interfaz utun
        # Las rutas 0/1 y 128/1 se gestionan desde 04-conectar.sh
        # solo cuando el tunel está realmente operativo.
        ifconfig "${IFACE}" "${IP4}" "${IP4_GATEWAY}" mtu "${MTU}" up
        ;;
    tuntap_down)
        ;;
    rtun_up|rtun_down)
        # Evento por enlace individual — no requiere accion en macOS
        ;;
esac
UPDOWN

chmod 755 "${GENERATED_DIR}/mlvpn_updown_mac.sh"

# --- Paso 5: Mostrar interfaces detectadas ---
echo ""
echo "=== Configuracion generada ==="
echo ""
echo "  ${GENERATED_DIR}/mlvpn.conf"
echo "  ${GENERATED_DIR}/mlvpn_updown_mac.sh"
echo ""
echo "=== Interfaces de red detectadas ==="
echo ""
networksetup -listallhardwareports | while IFS= read -r line; do
    if [[ "${line}" == *"Hardware Port:"* ]]; then
        port="${line#*: }"
    elif [[ "${line}" == *"Device:"* ]]; then
        dev="${line#*: }"
        ip=$(ipconfig getifaddr "${dev}" 2>/dev/null || echo "sin IP")
        printf "  %-24s %-8s %s\n" "${port}" "${dev}" "${ip}"
    fi
done

echo ""
echo "Verifica que IFACE_IPHONE y IFACE_PIXEL en config/env son correctos."
echo ""
echo "Siguiente paso: ejecuta 04-conectar.sh cuando estes en el tren"
