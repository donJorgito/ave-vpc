#!/usr/bin/env bash
# tools/mac-rotate.sh — REQ-NET-44 rotación de MAC del WiFi para resetear la
# cuota de datos del portal Icomera/Nomad del AVE.
#
# El router onboard del tren (Icomera/Nomad) impone un `dataLimit` por
# DISPOSITIVO (~209 MB observados) y throttlea al superarlo. El identificador
# de "dispositivo" es la MAC del adaptador WiFi. Cambiar la MAC = identidad
# nueva = cuota reseteada. Es un mecanismo POST-auth (afecta a CUALQUIER vía
# de bypass; ver doc 13 sección 5.1).
#
# Mecánica macOS (la MAC NO persiste tras reboot — aceptable):
#   1. Desasociar el WiFi (airport -z) para soltar la asociación 802.11.
#   2. `ifconfig <iface> ether <newmac>` — el cambio SOLO prende con la
#      interfaz desasociada/down.
#   3. Re-asociar (subir la interfaz; el captive-watchdog reautentica luego).
#
# AVISO OPERATIVO: --rotate TIRA la asociación WiFi momentáneamente. Cualquier
# link ubond que vaya sobre WiFi parpadeará y el portal cautivo pedirá
# RE-AUTENTICACIÓN. Esto se acopla a tools/captive-watchdog.py, que detectará
# el estado offline y reintentará el re-login. Ejecutar mac-rotate ANTES de
# esperar que el watchdog estabilice, no en mitad de un flujo crítico.
#
# SEGURIDAD: una MAC inválida deja el WiFi inutilizable hasta --restore. Por
# eso (a) se genera SIEMPRE una MAC locally-administered unicast VÁLIDA (ver
# bit-math en gen_random_mac) y (b) se persiste la MAC HARDWARE original en
# generated/ ANTES de la primera rotación, de modo que --restore siempre
# recupere el original aunque se hayan encadenado varias rotaciones.
#
# Uso:
#   sudo tools/mac-rotate.sh --show      # MAC actual + MAC hardware original
#   sudo tools/mac-rotate.sh --rotate    # genera+aplica MAC aleatoria válida
#   sudo tools/mac-rotate.sh --restore   # vuelve a la MAC hardware original
#
# Variables override (default desde config/env, sin hardcoding — Rule 4):
#   IFACE_WIFI   interfaz WiFi del Mac (default en0 vía config/env)

set -uo pipefail

# --- Guard bash >= 4 (coherencia con el resto del repo; macOS trae 3.2). ---
if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: requiere bash >= 4 (tienes ${BASH_VERSION}). brew install bash" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/generated"
CONFIG_FILE="${SCRIPT_DIR}/config/env"

mkdir -p "${GENERATED_DIR}"

# Cargar config/env para IFACE_WIFI (sin hardcoding — Rule 4).
# shellcheck source=/dev/null
[[ -r "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}" 2>/dev/null || true

IFACE="${IFACE_WIFI:-en0}"
# Fichero donde se persiste la MAC hardware original. El nombre incluye la
# interfaz para no mezclar adaptadores si IFACE_WIFI cambiase.
ORIG_MAC_FILE="${GENERATED_DIR}/mac-rotate-original-${IFACE}.mac"

# airport(8) privado de Apple: necesario para desasociar (-z) sin bajar la
# interfaz por completo. Path estable en todas las versiones recientes.
AIRPORT="/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"

log() {
    local msg="$*"
    logger -t mac-rotate "${msg}" 2>/dev/null || true
    printf '%s %s\n' "$(date -u +%FT%TZ)" "${msg}" >&2
}

require_root() {
    if (( EUID != 0 )); then
        echo "ERROR: requiere root (sudo tools/mac-rotate.sh ...)" >&2
        exit 1
    fi
}

# --- MAC actual de la interfaz (campo 'ether' de ifconfig). ---
current_mac() {
    # Comillas en "${IFACE}" para evitar inyección vía nombre de interfaz.
    ifconfig "${IFACE}" 2>/dev/null \
        | awk '$1 == "ether" { print $2; exit }'
}

# --- MAC hardware original "de fábrica" reportada por el sistema.
#     networksetup -getmacaddress devuelve la MAC permanente del hardware
#     INCLUSO si la MAC efectiva (ifconfig ether) ya fue rotada. Fallback a
#     ioreg (IOMACAddress, 6 bytes) si networksetup no la diera. ---
hardware_mac() {
    local mac
    mac="$(networksetup -getmacaddress "${IFACE}" 2>/dev/null \
        | awk '/Ethernet Address/ { print $3; exit }')"
    if [[ -n "${mac}" && "${mac}" != "(null)" ]]; then
        printf '%s\n' "${mac}"
        return 0
    fi
    # Fallback ioreg: IOMACAddress como blob de 6 bytes → formatear a aa:bb:..
    ioreg -r -n "${IFACE}" -l 2>/dev/null \
        | awk -F'"' '/IOMACAddress/ { print $4; exit }' \
        | tr -d '<>' \
        | sed -E 's/(..)(..)(..)(..)(..)(..)/\1:\2:\3:\4:\5:\6/'
}

# --- Persistir la MAC ORIGINAL antes de la PRIMERA rotación. Idempotente:
#     si el fichero ya existe (rotación previa en esta sesión), NO se
#     sobrescribe — así --restore siempre apunta al hardware real aunque se
#     hayan encadenado varias rotaciones. ---
persist_original_once() {
    if [[ -s "${ORIG_MAC_FILE}" ]]; then
        return 0  # ya persistido; no machacar
    fi
    local hw
    hw="$(hardware_mac)"
    if [[ -z "${hw}" ]]; then
        log "ERROR: no pude leer la MAC hardware de ${IFACE} — abortando para no perder el original"
        exit 1
    fi
    printf '%s\n' "${hw}" >"${ORIG_MAC_FILE}"
    log "MAC hardware original persistida: ${hw} -> ${ORIG_MAC_FILE}"
}

# --- Generar una MAC aleatoria VÁLIDA: locally-administered unicast.
#
#     Bit-math sobre el PRIMER octeto (bits numerados desde 0 = LSB):
#       bit 0 (0x01) = I/G  : 0 -> unicast,  1 -> multicast/broadcast
#       bit 1 (0x02) = U/L  : 0 -> universal (asignada por OUI), 1 -> local
#
#     Queremos unicast + locally-administered:
#       - poner bit 1  (U/L = 1, localmente administrada) -> octeto |= 0x02
#       - limpiar bit 0 (I/G = 0, unicast)                -> octeto &= 0xFE
#
#     Aplicado: (rand & 0xFE) | 0x02. Esto FUERZA ambos bits sin importar el
#     valor aleatorio: garantiza que la MAC nunca sea multicast (rompería el
#     WiFi) ni colisione con un OUI real. Los otros 5 octetos son aleatorios.
gen_random_mac() {
    local o1 rest
    # Primer octeto: aleatorio 0-255, luego forzar unicast + local.
    o1=$(( (RANDOM & 0xFE) | 0x02 ))
    printf '%02x' "${o1}"
    for _ in 1 2 3 4 5; do
        printf ':%02x' $(( RANDOM & 0xFF ))
    done
    printf '\n'
}

# --- Validar que una MAC es locally-administered unicast (defensa en
#     profundidad: se valida lo que vamos a aplicar antes de tocar ifconfig). ---
is_valid_local_unicast() {
    local mac="$1" first
    # Formato aa:bb:cc:dd:ee:ff (hex, dos puntos).
    [[ "${mac}" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]] || return 1
    first=$(( 16#${mac%%:*} ))
    # bit0 (I/G) debe ser 0 (unicast) y bit1 (U/L) debe ser 1 (local).
    (( (first & 0x01) == 0 )) || return 1
    (( (first & 0x02) == 0x02 )) || return 1
    return 0
}

# --- Aplicar una MAC a la interfaz: desasociar -> ifconfig ether -> reasociar.
#     El cambio SOLO prende con la interfaz desasociada. ---
apply_mac() {
    local newmac="$1"
    if ! is_valid_local_unicast "${newmac}"; then
        log "ERROR: MAC '${newmac}' no es locally-administered unicast válida — abortando (no se toca ${IFACE})"
        exit 1
    fi

    log "AVISO: se va a soltar la asociación WiFi de ${IFACE} momentáneamente — el portal pedirá re-auth"

    # 1) Desasociar el 802.11. `airport -z` fue ELIMINADO por Apple en
    #    macOS 14+ (verificado ausente en macOS 26.5). El método vigente es
    #    apagar/encender la radio WiFi con networksetup, que sí fuerza una
    #    desasociación real y que el driver acepte el nuevo ether. Mantenemos
    #    airport como fallback para macOS viejas donde aún exista.
    if [[ -x "${AIRPORT}" ]]; then
        "${AIRPORT}" "${IFACE}" -z 2>/dev/null || true
    elif command -v networksetup >/dev/null 2>&1; then
        networksetup -setairportpower "${IFACE}" off 2>/dev/null || true
        sleep 1
    else
        log "WARN: ni airport ni networksetup disponibles; solo ifconfig down/up (el cambio de MAC puede no aplicarse)"
    fi

    # 2) Bajar la interfaz para garantizar que el driver acepte el cambio.
    ifconfig "${IFACE}" down 2>/dev/null || true

    # 3) Cambiar la MAC efectiva.
    if ! ifconfig "${IFACE}" ether "${newmac}" 2>/dev/null; then
        log "ERROR: ifconfig ether falló para ${newmac}; subiendo ${IFACE} de nuevo"
        ifconfig "${IFACE}" up 2>/dev/null || true
        exit 1
    fi

    # 4) Subir/re-asociar la interfaz. Si apagamos la radio con networksetup,
    #    hay que volver a encenderla (ifconfig up no reactiva el WiFi).
    ifconfig "${IFACE}" up 2>/dev/null || true
    if [[ ! -x "${AIRPORT}" ]] && command -v networksetup >/dev/null 2>&1; then
        networksetup -setairportpower "${IFACE}" on 2>/dev/null || true
    fi

    local applied
    applied="$(current_mac)"
    if [[ "${applied,,}" == "${newmac,,}" ]]; then
        log "MAC aplicada OK en ${IFACE}: ${applied}"
    else
        log "WARN: MAC tras aplicar = '${applied}', esperaba '${newmac}'. Reasociación del WiFi puede tardar; verifica con --show"
    fi
}

# --- Subcomandos ---
do_show() {
    local cur hw orig
    cur="$(current_mac)"
    hw="$(hardware_mac)"
    orig="$(cat "${ORIG_MAC_FILE}" 2>/dev/null || true)"
    echo "interfaz WiFi      : ${IFACE}"
    echo "MAC actual (ether) : ${cur:-<desconocida>}"
    echo "MAC hardware (sys) : ${hw:-<desconocida>}"
    if [[ -n "${orig}" ]]; then
        echo "MAC original persistida (pre-rotación) : ${orig}"
        echo "  fichero: ${ORIG_MAC_FILE}"
    else
        echo "MAC original persistida : <ninguna — aún no se ha rotado>"
    fi
    # Pista informativa: ¿la MAC actual es local (rotada) o universal?
    if [[ -n "${cur}" ]]; then
        if is_valid_local_unicast "${cur}"; then
            echo "estado             : MAC actual es locally-administered (probablemente ROTADA)"
        else
            echo "estado             : MAC actual es universal/OUI (probablemente HARDWARE)"
        fi
    fi
}

do_rotate() {
    require_root
    persist_original_once          # guarda el hardware ANTES de tocar nada
    local newmac
    newmac="$(gen_random_mac)"
    log "rotando MAC de ${IFACE} -> ${newmac} (locally-administered unicast)"
    apply_mac "${newmac}"
    do_show
}

do_restore() {
    require_root
    local orig
    orig="$(cat "${ORIG_MAC_FILE}" 2>/dev/null || true)"
    if [[ -z "${orig}" ]]; then
        # Sin fichero: usar la MAC hardware que reporta el sistema (sigue
        # siendo la permanente aunque la efectiva esté rotada).
        orig="$(hardware_mac)"
        log "sin MAC persistida; usando MAC hardware del sistema: ${orig:-<desconocida>}"
    fi
    if [[ -z "${orig}" ]]; then
        log "ERROR: no hay MAC original conocida ni persistida — no puedo restaurar"
        exit 1
    fi
    # La MAC hardware es universal (no local): se aplica directa con ifconfig.
    log "restaurando MAC hardware original en ${IFACE}: ${orig}"
    if [[ -x "${AIRPORT}" ]]; then
        "${AIRPORT}" "${IFACE}" -z 2>/dev/null || true
    fi
    ifconfig "${IFACE}" down 2>/dev/null || true
    if ! ifconfig "${IFACE}" ether "${orig}" 2>/dev/null; then
        log "ERROR: no pude restaurar ${orig} en ${IFACE}"
        ifconfig "${IFACE}" up 2>/dev/null || true
        exit 1
    fi
    ifconfig "${IFACE}" up 2>/dev/null || true
    log "MAC restaurada. El portal pedirá re-auth con la identidad original."
    do_show
}

case "${1:-}" in
    --show)    do_show;    exit 0 ;;
    --rotate)  do_rotate;  exit 0 ;;
    --restore) do_restore; exit 0 ;;
    *)
        cat >&2 <<EOF
uso: sudo $0 [--show|--rotate|--restore]
  --show     muestra MAC actual + hardware + original persistida
  --rotate   genera+aplica MAC aleatoria locally-administered (suelta el WiFi)
  --restore  vuelve a la MAC hardware original
EOF
        exit 2
        ;;
esac
