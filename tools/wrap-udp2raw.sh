#!/usr/bin/env bash
# tools/wrap-udp2raw.sh — REQ-NET-39 Vía A (faketcp stealth, udp2raw)
#
# Wrapper EXTERIOR a ubond para cruzar el firewall del WiFi del AVE. ubond
# es UDP-only por diseño (SOCK_DGRAM + libsodium por datagrama) — NO SE TOCA.
# Esta vía usa udp2raw en modo --raw-mode faketcp sobre un puerto TCP NO
# estándar (default 8443/2222), evitando 80/443 que el AVE DNAT-ea al portal.
#
#   ubond client --UDP--> 127.0.0.1:LOCAL_PORT (udp2raw client)
#       ==faketcp(TCP:RAW_PORT)==> RPi:RAW_PORT (udp2raw server)
#       --UDP--> 127.0.0.1:5085 (ubond server real)
#
# POR QUÉ faketcp puede cruzar un firewall "solo-TCP" que un TCP real no:
#   - faketcp NO hace un handshake TCP completo ni mantiene estado de
#     congestión: fabrica paquetes que *parecen* TCP (flags SYN/ACK, seq/ack
#     plausibles) a ojos de un firewall stateful/NAT simple, que los deja
#     pasar como "tráfico TCP permitido". El kernel local no ve un socket TCP
#     real (udp2raw usa raw sockets).
#   - Por eso un puerto TCP random (8443) que NO esté DNAT-eado sale limpio:
#     el firewall ve "TCP saliente a 8443", lo permite, y udp2raw reconstruye
#     el UDP al otro lado.
#
# CUÁNDO FALLA (límites — sección 2 plan 13):
#   - Si Renfe hace DNAT de TODO el rango TCP (no solo 80/443): no hay puerto
#     limpio, faketcp no llega a la RPi.
#   - Si en 443 hay un PROXY TLS-TERMINATING real (no un simple DNAT): faketcp
#     NO es TLS, el proxy lo descarta. Para ese caso → Vía B (wstunnel/WSS).
#   - Stateful firewalls que validan el handshake TCP completo (seq tracking
#     estricto) pueden tirar los faketcp. Renfe Icomera no se ha probado aún.
#
# REQUIERE ROOT en AMBOS extremos (raw sockets). La RPi ya corre ubond como
# servicio root; el Mac ya pide root en 04b. Clave compartida -k (PSK): se lee
# de UDP2RAW_KEY/config o se genera y persiste en generated/ (ambos extremos
# DEBEN usar la MISMA clave — imprímela en el comando server-side).
#
# Uso:
#   sudo tools/wrap-udp2raw.sh             # arranca (necesita root)
#   tools/wrap-udp2raw.sh --check          # verifica binario (no requiere root)
#   tools/wrap-udp2raw.sh --stop           # mata la instancia activa
#   tools/wrap-udp2raw.sh --server-cmd     # imprime SOLO el comando RPi
#
# Variables override (defaults sin hardcoding):
#   WRAP_LOCAL_PORT   puerto UDP local que expone udp2raw (default 5085)
#   WRAP_REMOTE_HOST  host RPi (default VPS_IP)
#   UDP2RAW_PORT      puerto TCP faketcp no estándar (default 8443)
#   UDP2RAW_KEY       PSK compartida -k (si vacía, se genera y persiste)
#   UBOND_PORT_3      puerto UDP real de ubond en la RPi (default 5085)

set -uo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: requiere bash >= 4 (tienes ${BASH_VERSION}). brew install bash" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/generated"
CONFIG_FILE="${SCRIPT_DIR}/config/env"
PID_FILE="${GENERATED_DIR}/wrap_udp2raw.pid"
LOG="${GENERATED_DIR}/wrap_udp2raw.log"
KEY_FILE="${GENERATED_DIR}/wrap_udp2raw.key"

# Versión PINNED (Rule 7 IDLC). brew formula `udp2raw-multiplatform`.
UDP2RAW_PINNED_VERSION="20230206.0"

# El binario se llama `udp2raw` (release de wangyu-) o `udp2raw_mp` (brew
# udp2raw-multiplatform en macOS). Resolver el que exista.
UDP2RAW_BIN=""
for cand in udp2raw udp2raw_mp; do
    if command -v "${cand}" >/dev/null 2>&1; then UDP2RAW_BIN="${cand}"; break; fi
done

mkdir -p "${GENERATED_DIR}"

# shellcheck source=/dev/null
[[ -r "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}" 2>/dev/null || true

LOCAL_PORT="${WRAP_LOCAL_PORT:-${UBOND_PORT_3:-5085}}"
REMOTE_HOST="${WRAP_REMOTE_HOST:-${VPS_IP:-}}"
# Puerto TCP NO estándar para faketcp. 8443 default; 2222 alt razonable
# (ambos rara vez DNAT-eados). NO usar 80/443 (DNAT garantizado en AVE).
RAW_PORT="${UDP2RAW_PORT:-8443}"
UBOND_REAL_PORT="${UBOND_PORT_3:-5085}"

log() {
    local msg="$*"
    logger -t wrap-udp2raw "${msg}" 2>/dev/null || true
    printf '%s %s\n' "$(date -u +%FT%TZ)" "${msg}" | tee -a "${LOG}" >&2
}

# --- PSK compartida: la MISMA en cliente y server. Si no se pasa por env ni
#     existe en disco, generar una y persistir (chmod 600). ---
resolve_key() {
    if [[ -n "${UDP2RAW_KEY:-}" ]]; then
        printf '%s' "${UDP2RAW_KEY}"
        return 0
    fi
    if [[ -s "${KEY_FILE}" ]]; then
        cat "${KEY_FILE}"
        return 0
    fi
    # Generar PSK aleatoria y persistir. openssl está en macOS y RPi base.
    local k
    k="$(openssl rand -hex 16 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    printf '%s' "${k}" >"${KEY_FILE}"
    chmod 600 "${KEY_FILE}"
    printf '%s' "${k}"
}

print_server_cmd() {
    local key="$1"
    cat <<EOF
# ---- Comando a ejecutar en la RPi (${REMOTE_HOST:-VPS_IP}) como ROOT — NO lo lanza este script ----
# Espejo server-side de la Vía A: faketcp -> UDP a ubond real (5085).
# La clave -k DEBE ser IDÉNTICA en ambos extremos.
sudo udp2raw -s \\
    -l 0.0.0.0:${RAW_PORT} \\
    -r 127.0.0.1:${UBOND_REAL_PORT} \\
    --raw-mode faketcp \\
    -k "${key}" \\
    -a
# -s servidor, -l listen faketcp, -r destino UDP real (ubond), -a auto añade
# regla iptables para que el kernel no resetee los faketcp con RST.
# ------------------------------------------------------------------------------
EOF
}

do_check() {
    if [[ -n "${UDP2RAW_BIN}" ]]; then
        echo "OK: udp2raw presente como '${UDP2RAW_BIN}' ($(command -v "${UDP2RAW_BIN}"))"
        echo "    (versión pineada esperada: ${UDP2RAW_PINNED_VERSION})"
        return 0
    fi
    cat >&2 <<EOF
FALTA: udp2raw no está instalado.
  macOS:  brew install udp2raw-multiplatform   # binario: udp2raw_mp, pin ${UDP2RAW_PINNED_VERSION}
  RPi:    descargar binario release ${UDP2RAW_PINNED_VERSION} de
          github.com/wangyu-/udp2raw/releases (no está en apt estándar)
EOF
    return 1
}

do_stop() {
    if [[ -f "${PID_FILE}" ]]; then
        local pid
        pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            kill "${pid}" 2>/dev/null || true
            log "wrap-udp2raw detenido (pid ${pid})"
        fi
        rm -f "${PID_FILE}"
    else
        echo "wrap-udp2raw no estaba corriendo" >&2
    fi
}

case "${1:-}" in
    --check)      do_check; exit $? ;;
    --stop)       do_stop;  exit 0 ;;
    --server-cmd) print_server_cmd "$(resolve_key)"; exit 0 ;;
    "")           : ;;
    *) echo "uso: $0 [--check|--stop|--server-cmd]" >&2; exit 2 ;;
esac

# Idempotencia.
if [[ -f "${PID_FILE}" ]]; then
    old_pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
    if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
        echo "wrap-udp2raw ya corriendo (pid ${old_pid}); exit" >&2
        exit 0
    fi
    rm -f "${PID_FILE}"
fi

# Raw sockets requieren root en ambos extremos.
if [[ "${EUID}" -ne 0 ]]; then
    log "ERROR: faketcp usa raw sockets — requiere root. Lanza con sudo."
    exit 1
fi

do_check >/dev/null 2>&1 || { do_check; exit 1; }
if [[ -z "${REMOTE_HOST}" ]]; then
    log "ERROR: WRAP_REMOTE_HOST/VPS_IP no definido — no sé a qué RPi conectar"
    exit 1
fi

KEY="$(resolve_key)"
log "arrancando udp2raw faketcp: UDP local ${LOCAL_PORT} <-> faketcp ${REMOTE_HOST}:${RAW_PORT}"
# NO imprimir el PSK en el arranque (el log puede no ser 0600). El operador
# obtiene el comando server-side con la clave real vía './wrap-udp2raw.sh
# --server-cmd', que la revela deliberadamente.
log "comando RPi: ejecuta './wrap-udp2raw.sh --server-cmd' para obtenerlo (incluye la clave -k)"

# udp2raw cliente: -c cliente, -l UDP local que ubond usa, -r RPi faketcp.
"${UDP2RAW_BIN}" -c \
    -l "127.0.0.1:${LOCAL_PORT}" \
    -r "${REMOTE_HOST}:${RAW_PORT}" \
    --raw-mode faketcp \
    -k "${KEY}" \
    -a >>"${LOG}" 2>&1 &
child=$!
echo "${child}" >"${PID_FILE}"
log "udp2raw lanzado (pid ${child}). PID file: ${PID_FILE}"

trap 'kill "${child}" 2>/dev/null || true; rm -f "${PID_FILE}"; log "wrap-udp2raw terminado"; exit 0' INT TERM

wait "${child}"
rm -f "${PID_FILE}"
