#!/usr/bin/env bash
# tools/wrap-ptunnel.sh — REQ-NET-43 Vía E (ICMP tunneling, ptunnel-ng)
#
# Wrapper EXTERIOR a ubond como LINK DE VIDA (link de último recurso) para
# cruzar el firewall del WiFi del AVE cuando NADA más cruza. ICMP outbound
# está CONFIRMADO funcional en el AVE (2026-06-09: echo a 1.1.1.1, 1/3 replies,
# RTT 90-654ms) — lossy y de latencia alta, pero pasa. ptunnel-ng encapsula
# TCP/UDP dentro de ICMP echo request/reply.
#
#   ubond client --UDP--> 127.0.0.1:LOCAL_PORT (ptunnel-ng client)
#       == ICMP echo request/reply ==> RPi (ptunnel-ng server, raw ICMP)
#       --UDP--> 127.0.0.1:5085 (ubond server real)
#
# CAVEAT (lossy / alta latencia — sección 2 Vía E del plan 13):
#   - Throughput pésimo, RTT alto y variable, pérdidas notables (1/3 observado).
#   - El firewall puede rate-limitar ICMP en cualquier momento.
#   - NO es para ancho de banda. Suele servir SOLO para keepalive / señalización
#     de ubond o como prueba de "hay vida" cuando A/B/C/D están KO.
#   - ubond debe tolerar pérdida/latencia en ese link (degradación, no muerte).
#     Por eso es link de ÚLTIMO RECURSO, no path productivo.
#
# REQUIERE ROOT en AMBOS extremos: ptunnel-ng usa raw ICMP sockets. La RPi ya
# corre como root; el Mac ya pide root en 04b. Secreto compartido -x
# (password): se lee de PTUNNEL_PASSWORD/config o se genera y persiste en
# generated/ con chmod 600 (misma disciplina que la PSK de udp2raw). AMBOS
# extremos DEBEN usar el MISMO -x. NO se imprime en el log de arranque; solo se
# revela deliberadamente vía '--server-cmd'.
#
# Uso:
#   sudo tools/wrap-ptunnel.sh             # arranca (necesita root, raw ICMP)
#   tools/wrap-ptunnel.sh --check          # verifica binario (no requiere root)
#   tools/wrap-ptunnel.sh --stop           # mata la instancia activa
#   tools/wrap-ptunnel.sh --server-cmd     # imprime SOLO el comando RPi (con -x)
#
# Variables override (defaults sin hardcoding):
#   WRAP_LOCAL_PORT   puerto local que escucha ptunnel-ng client (default 5085)
#   WRAP_REMOTE_HOST  host RPi (proxy ICMP) (default VPS_IP)
#   PTUNNEL_PASSWORD  secreto compartido -x (si vacío, se genera y persiste)
#   UBOND_PORT_3      puerto UDP real de ubond en la RPi (default 5085)

set -uo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: requiere bash >= 4 (tienes ${BASH_VERSION}). brew install bash" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/generated"
CONFIG_FILE="${SCRIPT_DIR}/config/env"
PID_FILE="${GENERATED_DIR}/wrap_ptunnel.pid"
LOG="${GENERATED_DIR}/wrap_ptunnel.log"
PASS_FILE="${GENERATED_DIR}/wrap_ptunnel.pass"

# ATENCIÓN (verificado 2026-06-11): NO existe fórmula brew `ptunnel-ng`. brew
# solo tiene `ptunnel` 0.72 (proyecto original de Stødle, codebase DISTINTO al
# fork utoni/ptunnel-ng que este script asumía). Sus flags son OTROS:
#   ptunnel -p <proxy> -lp <listen_port> -da <dest_addr> -dp <dest_port> [-udp]
# (NO los -R/-P/-l de abajo). Para ptunnel-ng (utoni) hay que compilar del
# release o usar un tap. ADEMÁS ptunnel clásico tunela TCP por ICMP; para
# carry de UDP de ubond necesita el flag -udp (escucha en :53). Esta vía
# (link de vida) queda BLOQUEADA-PENDIENTE hasta decidir binario y reescribir
# los flags contra el --help real. Ver docs/v2-ubond/14-wrapper-integration-notes.md.
PTUNNEL_PINNED_VERSION="0.72"   # brew `ptunnel` clásico; ptunnel-ng requiere build manual

mkdir -p "${GENERATED_DIR}"

# shellcheck source=/dev/null
[[ -r "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}" 2>/dev/null || true

LOCAL_PORT="${WRAP_LOCAL_PORT:-${UBOND_PORT_3:-5085}}"
REMOTE_HOST="${WRAP_REMOTE_HOST:-${VPS_IP:-}}"
UBOND_REAL_PORT="${UBOND_PORT_3:-5085}"

log() {
    local msg="$*"
    logger -t wrap-ptunnel "${msg}" 2>/dev/null || true
    printf '%s %s\n' "$(date -u +%FT%TZ)" "${msg}" | tee -a "${LOG}" >&2
}

# --- Secreto compartido -x: el MISMO en cliente y server. Si no se pasa por
#     env ni existe en disco, generar y persistir (chmod 600). ---
resolve_pass() {
    if [[ -n "${PTUNNEL_PASSWORD:-}" ]]; then
        printf '%s' "${PTUNNEL_PASSWORD}"
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
# ---- Comando a ejecutar en la RPi (${REMOTE_HOST:-VPS_IP}) como ROOT — NO lo lanza este script ----
# Espejo server-side de la Vía E: ptunnel-ng en modo proxy ICMP.
# El -x DEBE ser IDÉNTICO en ambos extremos. Modo proxy = sin -p/-l/-r.
sudo ptunnel-ng \\
    -m 1 \\
    -x "${pass}"
# El cliente fija el destino final (-p RPi -l LOCAL -R 127.0.0.1 -P ${UBOND_REAL_PORT}),
# así que el proxy ICMP solo necesita -x (secreto) y -m (max tunnels). El proxy
# entrega el tráfico a 127.0.0.1:${UBOND_REAL_PORT} (ubond real) según lo que pida el cliente.
# ------------------------------------------------------------------------------
EOF
}

do_check() {
    if command -v ptunnel-ng >/dev/null 2>&1; then
        echo "OK: ptunnel-ng presente ($(command -v ptunnel-ng))"
        echo "    (versión pineada esperada: ${PTUNNEL_PINNED_VERSION} — verify tag)"
        return 0
    fi
    cat >&2 <<EOF
FALTA: ptunnel-ng no está instalado.
  macOS:  brew install ptunnel-ng     # pin: ptunnel-ng ${PTUNNEL_PINNED_VERSION} (verify tag)
  RPi:    sudo apt-get install -y ptunnel-ng   # o release ${PTUNNEL_PINNED_VERSION} de
          github.com/utoni/ptunnel-ng/releases si apt no lo trae
EOF
    return 1
}

do_stop() {
    if [[ -f "${PID_FILE}" ]]; then
        local pid
        pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            kill "${pid}" 2>/dev/null || true
            log "wrap-ptunnel detenido (pid ${pid})"
        fi
        rm -f "${PID_FILE}"
    else
        echo "wrap-ptunnel no estaba corriendo" >&2
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
        echo "wrap-ptunnel ya corriendo (pid ${old_pid}); exit" >&2
        exit 0
    fi
    rm -f "${PID_FILE}"
fi

# Raw ICMP sockets requieren root en ambos extremos.
if [[ "${EUID}" -ne 0 ]]; then
    log "ERROR: ptunnel-ng usa raw ICMP sockets — requiere root. Lanza con sudo."
    exit 1
fi

do_check >/dev/null 2>&1 || { do_check; exit 1; }
if [[ -z "${REMOTE_HOST}" ]]; then
    log "ERROR: WRAP_REMOTE_HOST/VPS_IP no definido — no sé a qué RPi conectar"
    exit 1
fi

PASS="$(resolve_pass)"
log "arrancando ptunnel-ng (ICMP, lossy/last-resort): UDP local ${LOCAL_PORT} <-> ICMP ${REMOTE_HOST} -> ubond ${UBOND_REAL_PORT}"
# NO imprimir el -x en el arranque (el log puede no ser 0600). El operador
# obtiene el comando server-side con el secreto real vía '--server-cmd'.
log "comando RPi: ejecuta './wrap-ptunnel.sh --server-cmd' para obtenerlo (incluye -x)"

# ptunnel-ng cliente: -p proxy (RPi), -l puerto local que escucha,
# -R/-P destino final detrás del proxy (ubond real en localhost de la RPi),
# -x secreto. Quoting estricto (sin inyección). -m 1 limita túneles.
#
# TODO VERIFICAR ON-DEVICE (revisión 2026-06-11): las letras de flag de
# ptunnel-ng 1.42 pueden diferir (algunas builds usan -r host / -R port en
# minúscula/mayúscula). Confirmar contra `ptunnel-ng --help` de la versión
# pineada ANTES de fiarse de este reenvío — si no reenvía a ubond, ajustar
# el par -R/-P aquí y en print_server_cmd (ambos lados deben coincidir).
ptunnel-ng \
    -p "${REMOTE_HOST}" \
    -l "${LOCAL_PORT}" \
    -R "127.0.0.1" \
    -P "${UBOND_REAL_PORT}" \
    -m 1 \
    -x "${PASS}" >>"${LOG}" 2>&1 &
child=$!
echo "${child}" >"${PID_FILE}"
log "ptunnel-ng lanzado (pid ${child}). PID file: ${PID_FILE}"

trap 'kill "${child}" 2>/dev/null || true; rm -f "${PID_FILE}"; log "wrap-ptunnel terminado"; exit 0' INT TERM

wait "${child}"
rm -f "${PID_FILE}"
