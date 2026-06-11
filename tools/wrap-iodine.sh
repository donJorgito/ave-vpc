#!/usr/bin/env bash
# tools/wrap-iodine.sh — REQ-NET-42 Vía D (DNS tunneling, iodine)
#
# Wrapper EXTERIOR a ubond como LINK DE VIDA (link de último recurso) para
# cruzar el firewall del WiFi del AVE cuando NADA más cruza. El walled garden
# del portal cautivo DEBE resolver DNS pre-auth (lo necesita para mostrar el
# propio portal), así que un túnel DNS sale aunque no se haya pagado el captive.
#
#   ubond client --UDP--> dns0 (TUN de iodine, IP del túnel DNS)
#       == queries/responses DNS al resolver del WiFi ==> recursivo del operador
#       == delegación NS ==> RPi (iodined autoritativo de IODINE_SUBDOMAIN)
#       --UDP--> ubond server real (5085)
#
# THROUGHPUT BAJÍSIMO (decenas de kbps, RTT alto): esto NO es para ancho de
# banda. Sirve para señalización / keepalive de ubond, o como prueba de "hay
# vida" cuando el resto de vías (A faketcp, B WSS, C socat, E ICMP) están KO.
# El cliente ubond apuntaría su [links.wifi] a la IP del extremo del túnel DNS
# (dns0), NO a 127.0.0.1 — iodine levanta su propia interfaz TUN.
#
# ============================================================================
# PRERREQUISITO DE INFRA (lo hace el OPERADOR, NO este script):
#   DELEGACIÓN NS en deSEC. iodine necesita un subdominio cuyo NS apunte a la
#   RPi. Ejemplo para IODINE_SUBDOMAIN="t.200bares.dedyn.io":
#     1. La RPi debe ser alcanzable por UDP/53 desde Internet (port-forward
#        del router: 53/udp -> 192.168.1.101). iodined escucha en :53.
#     2. En el panel deSEC de 200bares.dedyn.io, crear:
#          t            IN NS   ns.t.200bares.dedyn.io.
#          ns.t         IN A    <IP pública del operador / RPi>
#        (registro "glue": ns.t.* apunta a la IP donde corre iodined).
#     3. Verificar la delegación: `dig NS t.200bares.dedyn.io` debe devolver
#        ns.t.200bares.dedyn.io ANTES de probar el túnel.
#   Sin esta delegación NS, iodine NO funciona: las queries del subdominio no
#   llegan a iodined. Este wrapper NO crea registros DNS; asume que ya existen.
# ============================================================================
#
# REQUIERE ROOT en AMBOS extremos: iodine/iodined abren un dispositivo TUN.
# Secreto compartido -P (password): se lee de IODINE_PASSWORD/config o se
# genera y persiste en generated/ con chmod 600 (igual que la PSK de udp2raw).
# AMBOS extremos DEBEN usar el MISMO -P. NO se imprime en el log de arranque;
# solo se revela deliberadamente vía '--server-cmd'.
#
# Uso:
#   sudo tools/wrap-iodine.sh             # arranca (necesita root para TUN)
#   tools/wrap-iodine.sh --check          # verifica binario (no requiere root)
#   tools/wrap-iodine.sh --stop           # mata la instancia activa
#   tools/wrap-iodine.sh --server-cmd     # imprime SOLO el comando RPi (con -P)
#
# Variables override (defaults sin hardcoding):
#   IODINE_SUBDOMAIN   subdominio delegado por NS a la RPi (OBLIGATORIO;
#                      sin default razonable — el operador define el suyo)
#   IODINE_DNS_SERVER  resolver DNS a usar (default: el del WiFi, auto = "")
#   IODINE_PASSWORD    secreto compartido -P (si vacío, se genera y persiste)
#   IODINE_TUN_NET     red interna del túnel DNS en el server (default 172.16.30.0/27)
#   UBOND_PORT_3       puerto UDP real de ubond en la RPi (default 5085)

set -uo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: requiere bash >= 4 (tienes ${BASH_VERSION}). brew install bash" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/generated"
CONFIG_FILE="${SCRIPT_DIR}/config/env"
PID_FILE="${GENERATED_DIR}/wrap_iodine.pid"
LOG="${GENERATED_DIR}/wrap_iodine.log"
PASS_FILE="${GENERATED_DIR}/wrap_iodine.pass"

# Versión PINNED (Rule 7 IDLC). iodine 0.7.0 es la última release estable
# (verify tag: github.com/yarrick/iodine/releases). brew formula "iodine".
IODINE_PINNED_VERSION="0.8.0"

mkdir -p "${GENERATED_DIR}"

# shellcheck source=/dev/null
[[ -r "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}" 2>/dev/null || true

SUBDOMAIN="${IODINE_SUBDOMAIN:-}"
# Resolver: "" = autodetección de iodine (usa el del sistema/WiFi). El operador
# puede forzar otro con IODINE_DNS_SERVER (p.ej. el gateway del captive).
DNS_SERVER="${IODINE_DNS_SERVER:-}"
TUN_NET="${IODINE_TUN_NET:-172.16.30.0/27}"
UBOND_REAL_PORT="${UBOND_PORT_3:-5085}"

log() {
    local msg="$*"
    logger -t wrap-iodine "${msg}" 2>/dev/null || true
    printf '%s %s\n' "$(date -u +%FT%TZ)" "${msg}" | tee -a "${LOG}" >&2
}

# --- Secreto compartido -P: el MISMO en cliente y server. Si no se pasa por
#     env ni existe en disco, generar y persistir (chmod 600). ---
resolve_pass() {
    if [[ -n "${IODINE_PASSWORD:-}" ]]; then
        printf '%s' "${IODINE_PASSWORD}"
        return 0
    fi
    if [[ -s "${PASS_FILE}" ]]; then
        cat "${PASS_FILE}"
        return 0
    fi
    local p
    p="$(openssl rand -hex 16 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    printf '%s' "${p}" >"${PASS_FILE}"
    chmod 600 "${PASS_FILE}"
    printf '%s' "${p}"
}

print_server_cmd() {
    local pass="$1"
    cat <<EOF
# ---- Comando a ejecutar en la RPi (${VPS_IP:-VPS_IP}) como ROOT — NO lo lanza este script ----
# Espejo server-side de la Vía D: iodined autoritativo del subdominio delegado.
# PRERREQUISITO: delegación NS de ${SUBDOMAIN:-<IODINE_SUBDOMAIN>} apuntando a esta RPi,
# y port-forward 53/udp del router -> esta RPi (ver cabecera de este script).
# El -P DEBE ser IDÉNTICO en ambos extremos.
sudo iodined -f \\
    -c \\
    -P "${pass}" \\
    "${TUN_NET%/*}.1" \\
    "${SUBDOMAIN:-<IODINE_SUBDOMAIN>}"
# Tras levantar, en la RPi reenviar el extremo del túnel DNS a ubond real:
#   socat UDP4-LISTEN:5085,reuseaddr,fork UDP4:127.0.0.1:${UBOND_REAL_PORT}
#   (o apuntar ubond server a escuchar también en la IP de dnsX del server).
# -f foreground, -c no comprobar IP del cliente (NAT del captive cambia la src).
# ------------------------------------------------------------------------------
EOF
}

do_check() {
    if command -v iodine >/dev/null 2>&1; then
        echo "OK: iodine presente ($(command -v iodine))"
        echo "    (versión pineada esperada: ${IODINE_PINNED_VERSION} — verify tag)"
        return 0
    fi
    cat >&2 <<EOF
FALTA: iodine no está instalado.
  macOS:  brew install iodine        # pin: iodine ${IODINE_PINNED_VERSION} (verify tag)
  RPi:    sudo apt-get install -y iodine    # o release ${IODINE_PINNED_VERSION} de
          github.com/yarrick/iodine/releases si apt trae una más vieja
EOF
    return 1
}

do_stop() {
    if [[ -f "${PID_FILE}" ]]; then
        local pid
        pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            kill "${pid}" 2>/dev/null || true
            log "wrap-iodine detenido (pid ${pid})"
        fi
        rm -f "${PID_FILE}"
    else
        echo "wrap-iodine no estaba corriendo" >&2
    fi
}

case "${1:-}" in
    --check)      do_check; exit $? ;;
    --stop)       do_stop;  exit 0 ;;
    --server-cmd) print_server_cmd "$(resolve_pass)"; exit 0 ;;
    "")           : ;;
    *) echo "uso: $0 [--check|--stop|--server-cmd]" >&2; exit 2 ;;
esac

# Idempotencia.
if [[ -f "${PID_FILE}" ]]; then
    old_pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
    if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
        echo "wrap-iodine ya corriendo (pid ${old_pid}); exit" >&2
        exit 0
    fi
    rm -f "${PID_FILE}"
fi

# TUN requiere root en ambos extremos.
if [[ "${EUID}" -ne 0 ]]; then
    log "ERROR: iodine abre un dispositivo TUN — requiere root. Lanza con sudo."
    exit 1
fi

do_check >/dev/null 2>&1 || { do_check; exit 1; }
if [[ -z "${SUBDOMAIN}" ]]; then
    log "ERROR: IODINE_SUBDOMAIN no definido. Define el subdominio delegado por NS"
    log "       a la RPi (p.ej. IODINE_SUBDOMAIN=t.200bares.dedyn.io). Ver cabecera."
    exit 1
fi

PASS="$(resolve_pass)"
if [[ -n "${DNS_SERVER}" ]]; then
    log "arrancando iodine: túnel DNS de ${SUBDOMAIN} vía resolver ${DNS_SERVER}"
else
    log "arrancando iodine: túnel DNS de ${SUBDOMAIN} vía resolver autodetectado (WiFi)"
fi
# NO imprimir el -P en el arranque (el log puede no ser 0600). El operador
# obtiene el comando server-side con el secreto real vía '--server-cmd'.
log "comando RPi: ejecuta './wrap-iodine.sh --server-cmd' para obtenerlo (incluye -P)"

# iodine cliente: -f foreground (lo gobierna este wrapper), -P secreto.
# El resolver es opcional posicional ANTES del subdominio: si DNS_SERVER está
# vacío, no se pasa y iodine autodetecta. Quoting estricto (sin inyección).
if [[ -n "${DNS_SERVER}" ]]; then
    iodine -f -P "${PASS}" "${DNS_SERVER}" "${SUBDOMAIN}" >>"${LOG}" 2>&1 &
else
    iodine -f -P "${PASS}" "${SUBDOMAIN}" >>"${LOG}" 2>&1 &
fi
child=$!
echo "${child}" >"${PID_FILE}"
log "iodine lanzado (pid ${child}). PID file: ${PID_FILE}"

trap 'kill "${child}" 2>/dev/null || true; rm -f "${PID_FILE}"; log "wrap-iodine terminado"; exit 0' INT TERM

wait "${child}"
rm -f "${PID_FILE}"
