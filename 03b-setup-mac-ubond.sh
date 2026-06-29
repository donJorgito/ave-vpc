#!/usr/bin/env bash
###############################################################################
# 03b-setup-mac-ubond.sh
#
# DONDE SE EJECUTA: En tu Mac (Apple Silicon o Intel)
#
# QUE HACE:
#   Instala ubond (fork de mlvpn con replicación selectiva — REQ-NET-12)
#   en paralelo a mlvpn. NO sustituye mlvpn — coexisten:
#     - mlvpn  → /usr/local/sbin/mlvpn  (v1.x estable)
#     - ubond  → /usr/local/sbin/ubond  (v2 experimental)
#   El usuario puede arrancar uno u otro según el escenario.
#
# PASOS:
#   1. Verifica Xcode CLT + Homebrew + libs (libev, libsodium, libpcap)
#   2. Comprueba que existe bash 4+ (necesario para los watchers v2)
#   3. Clona markfoodyburton/ubond en build/ubond/ si no está
#   4. Aplica los 3 patches:
#        a) patches/ubond_macos_compile.patch  (REQ-NET-19, SO_BINDTODEVICE)
#        b) patches/tuntap_darwin_utun_ubond.c (REQ-NET-19, sustituye
#                                               tuntap_darwin.c con utun macOS)
#        c) patches/ubond_replicate_filter.patch (REQ-NET-12, replicación)
#   5. Compila con configure --enable-filters + make
#   6. Instala como /usr/local/sbin/ubond
#   7. Crea usuario de sistema 'ubond' (paralelo a 'mlvpn')
#   8. Genera config plantilla generated/ubond.conf con sección
#      [filters.replicate] vacía (el usuario añade sus propias reglas)
#
# LO QUE NO HACE:
#   - No toca mlvpn (sigue funcionando)
#   - No genera mlvpn_active.conf ni rutas de túnel — eso es 04b-conectar
#   - No configura RPi — eso es 07b-setup-rpi-ubond.sh
#
# REQUISITOS:
#   - Xcode CLT, Homebrew, bash 4+ (brew install bash si no)
#   - patches/ubond_macos_compile.patch + patches/tuntap_darwin_utun_ubond.c
#     + patches/ubond_replicate_filter.patch
#   - 01-generar-secreto.sh ejecutado (keys/ubond.secret = mlvpn.secret)
#   - config/env existente
###############################################################################
set -euo pipefail

if [[ "${EUID}" -eq 0 ]]; then
    echo "ERROR: No ejecutes este script con sudo."
    echo "Ejecuta: ./03b-setup-mac-ubond.sh"
    echo "(El script usa sudo internamente para lo que necesita permisos)"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_DIR="${SCRIPT_DIR}/keys"
CONFIG_FILE="${SCRIPT_DIR}/config/env"
GENERATED_DIR="${SCRIPT_DIR}/generated"
BUILD_DIR="${SCRIPT_DIR}/build"
PATCHES_DIR="${SCRIPT_DIR}/patches"

# --- Validaciones ---
if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: No existe config/env (copia config/env.example y rellena)"
    exit 1
fi
if [[ ! -f "${KEYS_DIR}/mlvpn.secret" ]]; then
    echo "ERROR: No existe keys/mlvpn.secret. Ejecuta primero 01-generar-secreto.sh"
    exit 1
fi
for p in ubond_macos_compile.patch tuntap_darwin_utun_ubond.c ubond_replicate_filter.patch ubond_per_link_tolerence.patch ubond_replicate_dedup_fix.patch ubond_filters_section_exclusion.patch ubond_dedup_gate_data_seq.patch ubond_rebind_on_silence.patch; do
    if [[ ! -f "${PATCHES_DIR}/${p}" ]]; then
        echo "ERROR: falta ${PATCHES_DIR}/${p}"
        exit 1
    fi
done

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

# Puertos UDP de ubond — distintos a mlvpn para coexistir.
# Default 5083/5084/5085 (mlvpn usa 5080-5082).
UBOND_PORT_1="${UBOND_PORT_1:-5083}"
UBOND_PORT_2="${UBOND_PORT_2:-5084}"
UBOND_PORT_3="${UBOND_PORT_3:-5085}"

# Subnet del túnel ubond — DISTINTA de mlvpn (REQ-NET-24). Default
# 10.10.20.x. Si config/env no la define todavía (se añadió en
# REQ-NET-24), caemos al default para no romper en migración.
UBOND_TUN_VPS_IP="${UBOND_TUN_VPS_IP:-10.10.20.1}"
UBOND_TUN_MAC_IP="${UBOND_TUN_MAC_IP:-10.10.20.2}"

# =====================================================================
# Paso 1: Verificar Xcode CLT
# =====================================================================
echo "=> Verificando Xcode Command Line Tools..."
if ! xcode-select -p &>/dev/null; then
    echo "  Xcode CLT no instalado. Instalando..."
    xcode-select --install
    echo "  *** Acepta el diálogo y vuelve a ejecutar este script ***"
    exit 1
fi
echo "  ✓ Xcode CLT: $(xcode-select -p)"

# =====================================================================
# Paso 2: Bash 4+ (los watchers usan declare -A)
# Si solo hay /bin/bash 3.2, instalamos bash de Homebrew.
# =====================================================================
echo "=> Verificando bash 4+..."
HAS_BASH4=0
for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$b" ]]; then
        v=$("$b" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null)
        if [[ "${v:-0}" -ge 4 ]]; then
            HAS_BASH4=1
            echo "  ✓ bash $v en $b"
            break
        fi
    fi
done
if [[ "${HAS_BASH4}" -eq 0 ]]; then
    echo "  bash 4+ no encontrado. Instalando..."
    brew install bash
fi

# =====================================================================
# Paso 3: Dependencias Homebrew (libev, libsodium, libpcap, autotools)
# =====================================================================
echo "=> Verificando dependencias Homebrew..."
if ! command -v brew &>/dev/null; then
    echo "  ERROR: Homebrew no instalado. https://brew.sh"
    exit 1
fi
for dep in libev libsodium libpcap autoconf automake libtool pkg-config; do
    if ! brew list "${dep}" &>/dev/null; then
        echo "  Instalando ${dep}..."
        brew install "${dep}"
    else
        echo "  ✓ ${dep}"
    fi
done

# =====================================================================
# Paso 4: Compilar ubond con los 3 patches
# =====================================================================
if command -v ubond &>/dev/null || [[ -x /usr/local/sbin/ubond ]]; then
    echo "=> ubond ya está instalado: $(/usr/local/sbin/ubond --help 2>&1 | head -1)"
    echo "   Para forzar recompilación: rm -rf build/ubond && relanzar este script"
else
    echo "=> Compilando ubond desde fuente..."
    mkdir -p "${BUILD_DIR}"
    cd "${BUILD_DIR}"

    if [[ ! -d "ubond" ]]; then
        git clone --depth 1 https://github.com/markfoodyburton/ubond.git
    fi

    cd ubond
    [[ -f Makefile ]] && make clean 2>/dev/null || true

    # Patch 1 (REQ-NET-19): SO_BINDTODEVICE bajo #ifdef __linux__
    echo "  Aplicando ubond_macos_compile.patch..."
    if ! patch -p1 -N --reject-file=- < "${PATCHES_DIR}/ubond_macos_compile.patch" 2>&1 | head -5; then
        echo "  (patch ya aplicado o no aplicable; continuando)"
    fi

    # Patch 2 (REQ-NET-19): tuntap_darwin reemplazado con versión utun-API
    echo "  Sustituyendo tuntap_darwin.c con utun-API..."
    cp "${PATCHES_DIR}/tuntap_darwin_utun_ubond.c" src/tuntap_darwin.c

    # Patch 3 (REQ-NET-12): replicación selectiva por 5-tupla
    echo "  Aplicando ubond_replicate_filter.patch..."
    if ! patch -p1 -N --reject-file=- < "${PATCHES_DIR}/ubond_replicate_filter.patch" 2>&1 | head -5; then
        echo "  (patch ya aplicado o no aplicable; continuando)"
    fi

    # Patch 4 (REQ-NET-25): per-link loss_tolerence/latency_tolerence
    echo "  Aplicando ubond_per_link_tolerence.patch..."
    if ! patch -p1 -N --reject-file=- < "${PATCHES_DIR}/ubond_per_link_tolerence.patch" 2>&1 | head -5; then
        echo "  (patch ya aplicado o no aplicable; continuando)"
    fi

    # Patch 5 (REQ-NET-27): fix H1+H2 — data_seq compartido entre clones
    # de replicate + dedup return contract. Resuelve el incidente AVE
    # 2026-06-01 donde v2+replicación caía a los pocos minutos.
    echo "  Aplicando ubond_replicate_dedup_fix.patch..."
    if ! patch -p1 -N --reject-file=- < "${PATCHES_DIR}/ubond_replicate_dedup_fix.patch" 2>&1 | head -5; then
        echo "  (patch ya aplicado o no aplicable; continuando)"
    fi

    # Patch 6 (REQ-NET-29): parser de [filters] excluye sub-secciones
    # filters.replicate / filters.fifo. Bug detectado oficina Roche
    # 2026-06-03 — sin esto, entries de filters.replicate también se
    # procesaban como filters stock con tun=NULL, cuelgue silencioso.
    echo "  Aplicando ubond_filters_section_exclusion.patch..."
    if ! patch -p1 -N --reject-file=- < "${PATCHES_DIR}/ubond_filters_section_exclusion.patch" 2>&1 | head -5; then
        echo "  (patch ya aplicado o no aplicable; continuando)"
    fi

    # Patch 7 (REQ-NET-30): gate dedup por wire signal data_seq!=0 en
    # vez de replicate_filters.count>0. Arregla cuelgue dataplane bajo
    # asimetría cliente/server (validado oficina 2026-06-03 con tcpdump
    # RPi: ping 0/N pre-patch, 10/10 post-simetría manual; el patch
    # elimina la dependencia de simetría en la config).
    echo "  Aplicando ubond_dedup_gate_data_seq.patch..."
    if ! patch -p1 -N --reject-file=- < "${PATCHES_DIR}/ubond_dedup_gate_data_seq.patch" 2>&1 | head -5; then
        echo "  (patch ya aplicado o no aplicable; continuando)"
    fi

    # Patch 8 (REQ-NET-35): rebind socket UDP en silencio inbound.
    # Fix C definitivo del NAT carrier expiry — supersede del watchdog
    # bash REQ-NET-34. Cliente cierra el socket y reabre con sport
    # efímero fresco tras UBOND_REBIND_THRESHOLD ticks (~750ms post
    # primer status_down) sin DATA/KEEPALIVE inbound. Server-mode
    # gated: el listener UDP del servidor NO se rebinda.
    echo "  Aplicando ubond_rebind_on_silence.patch..."
    if ! patch -p1 -N --reject-file=- < "${PATCHES_DIR}/ubond_rebind_on_silence.patch" 2>&1 | head -5; then
        echo "  (patch ya aplicado o no aplicable; continuando)"
    fi

    # Patch 9 (REQ-NET-36): purga del pool de replicación en SIGHUP.
    # Bug colateral descubierto durante DNS-investigation 2026-06-08:
    # ubond_replicate_filters.count crece sin límite en cada reload
    # exitoso porque ubond_config NO resetea el array antes de
    # re-añadir filtros. Memory leak (bpf_program no liberados via
    # pcap_freecode) + doble match en ubond_replicate_filter_match.
    # Inocuo en cold start, problemático bajo SIGHUP repetido (DNS
    # retry watchdog futuro).
    echo "  Aplicando ubond_filters_count_purge.patch..."
    if ! patch -p1 -N --reject-file=- < "${PATCHES_DIR}/ubond_filters_count_purge.patch" 2>&1 | head -5; then
        echo "  (patch ya aplicado o no aplicable; continuando)"
    fi

    ./autogen.sh

    PKG_CONFIG_PATH="$(brew --prefix libev)/lib/pkgconfig:$(brew --prefix libsodium)/lib/pkgconfig"
    export PKG_CONFIG_PATH
    CFLAGS="-I$(brew --prefix libev)/include -I$(brew --prefix libsodium)/include -I$(brew --prefix libpcap)/include"
    export CFLAGS
    LDFLAGS="-L$(brew --prefix libev)/lib -L$(brew --prefix libsodium)/lib -L$(brew --prefix libpcap)/lib"
    export LDFLAGS

    # ac_cv_func_strnvis=no: igual que en mlvpn
    # --enable-filters: requerido para [filters] y [filters.replicate]
    ac_cv_func_strnvis=no ./configure \
        --prefix=/usr/local \
        --sysconfdir=/etc \
        --enable-filters
    make -j"$(sysctl -n hw.ncpu)"
    sudo make install

    echo "  ✓ ubond instalado: $(/usr/local/sbin/ubond --help 2>&1 | head -1)"
    cd "${SCRIPT_DIR}"
fi

# =====================================================================
# Paso 5: Usuario de sistema 'ubond' (privsep)
# =====================================================================
echo "=> Verificando usuario de sistema ubond..."
if ! id ubond &>/dev/null; then
    echo "  Creando usuario de sistema ubond..."
    NEW_UID=501
    while dscl . -list /Users UniqueID 2>/dev/null | awk '{print $2}' | grep -q "^${NEW_UID}$"; do
        NEW_UID=$((NEW_UID + 1))
    done
    sudo dscl . -create /Users/ubond
    sudo dscl . -create /Users/ubond UserShell /usr/bin/false
    sudo dscl . -create /Users/ubond RealName "ubond"
    sudo dscl . -create /Users/ubond UniqueID "${NEW_UID}"
    sudo dscl . -create /Users/ubond PrimaryGroupID 99
    sudo dscl . -create /Users/ubond NFSHomeDirectory /var/empty
    echo "  ✓ Usuario ubond creado (UID ${NEW_UID})"
else
    echo "  ✓ Usuario ubond ya existe"
fi

# =====================================================================
# Paso 6: askpass helper (compartido con mlvpn — ya creado por 03-setup-mac.sh)
# =====================================================================
ASKPASS_SCRIPT="/tmp/sudo-askpass.sh"
if [[ ! -x "${ASKPASS_SCRIPT}" ]]; then
    cat > "${ASKPASS_SCRIPT}" << 'ASKPASS'
#!/bin/bash
osascript -e 'Tell application "System Events" to display dialog "Contraseña sudo (ave-vpc):" with hidden answer default answer ""' -e 'text returned of result'
ASKPASS
    chmod 700 "${ASKPASS_SCRIPT}"
    echo "=> sudo askpass creado: ${ASKPASS_SCRIPT}"
else
    echo "=> sudo askpass ya existe: ${ASKPASS_SCRIPT}"
fi

# =====================================================================
# Paso 7: Generar plantilla generated/ubond.conf
#
# Mismo formato que mlvpn.conf pero con sección [filters.replicate]
# inicialmente vacía. El usuario añade reglas BPF según su uso.
# =====================================================================
echo "=> Generando plantilla generated/ubond.conf..."
mkdir -p "${GENERATED_DIR}"
chmod 700 "${GENERATED_DIR}"

UBOND_SECRET="$(tr -d '\n' < "${KEYS_DIR}/mlvpn.secret")"

cat > "${GENERATED_DIR}/ubond.conf" <<EOF
# ubond.conf — generado por 03b-setup-mac-ubond.sh
# REQ-NET-12: sección [filters.replicate] activa
[general]
mode = "client"
tuntap = "tun"
interface_name = "ubond0"
ip4 = "${UBOND_TUN_MAC_IP}"
ip4_gateway = "${UBOND_TUN_VPS_IP}"
mtu = ${TUN_MTU}
password = "${UBOND_SECRET}"
timeout = 30
statuscommand = "${GENERATED_DIR}/ubond_updown_mac.sh"

[filters]
[filters.fifo]

# REQ-NET-12 — Replicación selectiva por 5-tupla.
# Cada regla es una expresión BPF; si un paquete matchea, se duplica
# por TODOS los túneles activos (excluyendo fallback_only=1). El
# receptor descarta duplicados via dedup LRU (data_seq).
#
# Ejemplos típicos para videoconf (descomentar las que apliquen):
#
# [filters.replicate]
# zoom_rtp        = "udp and (dst port 8801 or dst port 8802)"
# meet_stun_turn  = "udp and (dst port 3478 or dst port 19302 or dst port 19305)"
# rtp_generic     = "udp and portrange 16384-32767"
# anthropic_api   = "tcp and dst port 443 and dst host api.anthropic.com"

# REQ-NET-25: per-link tolerences. Defaults 0 = comportamiento histórico
# (LOSS_TOLERENCE 31% global + threshold keepalive 0.5s+2*RTT). Para
# enlaces 4G en AVE descomenta y ajusta — se observó cycling cada 1s
# en trayecto 2026-05-29 con threshold tight.
#
# Recomendación AVE Movistar/Yoigo (RTT ~150-300ms, jitter alto):
#   loss_tolerence    = 80
#   latency_tolerence = 2000
#
# Conservador (descarta link rápido, solo si v1 no soporta el ciclo):
#   loss_tolerence    = 50
#   latency_tolerence = 1000

[links.iphone]
bindhost = "PLACEHOLDER_IPHONE_IP"
remotehost = "${VPS_IP}"
remoteport = ${UBOND_PORT_1}
bandwidth_upload = 10000000
# loss_tolerence    = 80
# latency_tolerence = 2000

[links.pixel]
bindhost = "PLACEHOLDER_PIXEL_IP"
remotehost = "${VPS_IP}"
remoteport = ${UBOND_PORT_2}
bandwidth_upload = 10000000
# loss_tolerence    = 80
# latency_tolerence = 2000
EOF
chmod 600 "${GENERATED_DIR}/ubond.conf"

# ubond_updown_mac.sh: statuscommand propio (NO copia del de mlvpn).
# Diferencias críticas vs mlvpn_updown_mac.sh:
#   - Log a /tmp/ubond_updown.log (separado de v1 — incidente AVE
#     2026-06-01 mostró post-mortem confuso por log compartido).
#   - rtun_down/tuntap_down tocan generated/ubond_unhealthy → señal
#     temprana al watchdog (REQ-NET-26) para auto-recovery.
echo "=> Generando ubond_updown_mac.sh (REQ-NET-26 health flag)..."
cat > "${GENERATED_DIR}/ubond_updown_mac.sh" <<UPDOWN_EOF
#!/bin/bash
# Statuscommand de ubond — invocado por el binario en eventos de túnel.
#
# Firma: script <interfaz> <evento> [nombre_enlace]
#   \$1 = DEVICE   — utun asignado por kernel (ej. utun7)
#   \$2 = evento   — tuntap_up | tuntap_down | rtun_up | rtun_down
#   \$3 = (rtun_*) nombre del enlace
#
# Env vars: IP4, IP4_GATEWAY, MTU, DEVICE.

IFACE="\$1"
EVENT="\$2"
LOG="/tmp/ubond_updown.log"
HEALTH_FLAG="${GENERATED_DIR}/ubond_unhealthy"

echo "\$(date) called: iface=\$IFACE event=\$EVENT IP4=\$IP4 IP4_GW=\$IP4_GATEWAY MTU=\$MTU" >> "\$LOG"

case "\${EVENT}" in
    tuntap_up)
        # Asignar IP a la interfaz utun (las rutas /1 las gestiona 04b).
        ifconfig "\${IFACE}" "\${IP4}" "\${IP4_GATEWAY}" mtu "\${MTU}" up
        # Quitar flag por si quedó de un down anterior — túnel sano de nuevo.
        rm -f "\${HEALTH_FLAG}"
        ;;
    tuntap_down)
        # Túnel completo cae — señal al watchdog (REQ-NET-26).
        touch "\${HEALTH_FLAG}"
        ;;
    rtun_down)
        # Un enlace cayó. No es fatal por sí solo (otros pueden seguir up),
        # pero si TODOS caen el watchdog lo detectará por ping fail.
        # Tocamos flag igual — el watchdog lo descarta si está stale.
        touch "\${HEALTH_FLAG}"
        ;;
    rtun_up)
        # Enlace recuperado — si el flag estaba puesto, podría limpiarse.
        # Pero solo si TODOS los links están up; el watchdog lo evaluará
        # via ping. Aquí no tocamos el flag.
        ;;
esac
UPDOWN_EOF
chmod 755 "${GENERATED_DIR}/ubond_updown_mac.sh"
echo "  ✓ ubond_updown_mac.sh creado (log /tmp/ubond_updown.log + health flag)"

# =====================================================================
# Resumen
# =====================================================================
echo ""
echo "=== Setup ubond completado ==="
echo ""
echo "  Binario: /usr/local/sbin/ubond"
echo "  Config:  ${GENERATED_DIR}/ubond.conf"
echo "  Updown:  ${GENERATED_DIR}/ubond_updown_mac.sh"
echo ""
echo "Para activar replicación de tu meet/videoconf:"
echo "  1. Edita ${GENERATED_DIR}/ubond.conf y descomenta/edita [filters.replicate]"
echo "  2. Ejecuta 04b-conectar-ubond.sh (próxima sesión)"
echo ""
echo "mlvpn (v1.x) sigue intacto en /usr/local/sbin/mlvpn — coexisten."
