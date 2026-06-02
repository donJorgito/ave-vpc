#!/usr/bin/env bash
# tools/smoke-replicate.sh
#
# Validador runtime de replicación selectiva (REQ-NET-12) + dedup fix
# (REQ-NET-27). Runnable desde casa/oficina ANTES del trayecto AVE.
#
# Hipótesis a validar:
#   1. Con [filters.replicate] activa para "icmp", el cliente clona cada
#      ping y lo envía por TODOS los túneles autenticados (log local
#      "data_seq=N enviado a M tuneles", M ≥ 2).
#   2. El servidor (RPi) recibe N copias por data_seq y descarta N-1 vía
#      dedup LRU. Si REQ-NET-27 funciona → journal RPi muestra
#      "descartando duplicado data_seq=" con count > 0.
#
# Si dedup_hits == 0 pese a tráfico fluyendo, el bug `replicated`
# uninicializado (incidente AVE 2026-06-01) ha regresado.
#
# Política:
#   - NO arranca watchdog (smoke es diagnostic puro; ese loop solo aplica
#     a 04b producción).
#   - LAN preferida si disponible (más estable), DDNS como fallback.
#   - 30s de tráfico ICMP + 30s de tráfico UDP:9999 vía nc.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LOG_PREFIX="smoke-replicate"

# shellcheck source=tools/lib/_common.sh
source "${SCRIPT_DIR}/lib/_common.sh"
# shellcheck source=tools/lib/env-detect.sh
source "${SCRIPT_DIR}/lib/env-detect.sh"
# shellcheck source=tools/lib/conf-gen.sh
source "${SCRIPT_DIR}/lib/conf-gen.sh"
# shellcheck source=tools/lib/ubond-runner.sh
source "${SCRIPT_DIR}/lib/ubond-runner.sh"
# shellcheck source=tools/lib/tcpdump.sh
source "${SCRIPT_DIR}/lib/tcpdump.sh"

REPLICATE_UDP_PORT="${REPLICATE_UDP_PORT:-9999}"
TRAFFIC_DURATION="${TRAFFIC_DURATION:-30}"
NC_REMOTE_PIDFILE="/tmp/smoke_replicate_nc.pid"

cleanup() {
    trap - EXIT INT TERM
    log_info "Cleanup: parando capturas, ubond, nc remoto"
    tcpdump_stop_all 2>/dev/null || true
    ubond_runner_stop 2>/dev/null || true
    # Mata el listener nc en el RPi si quedó vivo.
    if [[ -n "${DETECTED_SSH_HOST:-}" ]]; then
        as_invoker ssh -p "${DETECTED_SSH_PORT}" -o ConnectTimeout=3 \
            "${RPi_USER:-ubuntu}@${DETECTED_SSH_HOST}" \
            "if [[ -r ${NC_REMOTE_PIDFILE} ]]; then \
                sudo kill \$(cat ${NC_REMOTE_PIDFILE}) 2>/dev/null || true; \
                rm -f ${NC_REMOTE_PIDFILE}; \
             fi" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

require_root "$@"
env_detect_all
env_detect_summary

if [[ "${DETECTED_RPI_TARGET}" == "none" ]]; then
    die 1 "RPi inalcanzable (LAN ni DDNS). ¿WiFi y/o tethering al menos uno UP?"
fi

env_detect_eligible_links
LINKS=("${ELIGIBLE_LINKS[@]:-}")
if (( ${#LINKS[@]} < 2 )); then
    die 1 "Necesito ≥2 links para que replicación sea observable; tengo: ${#LINKS[@]}"
fi
log_info "Validando replicación con ${#LINKS[@]} link(s) y target=${DETECTED_RPI_TARGET}"

ubond_runner_cleanup_stale

# Conf base con conf_gen_write — luego inyectamos [filters.replicate] no vacía.
# El generador stock crea [filters] [filters.fifo] al header; añadimos
# [filters.replicate] con dos reglas justo antes del primer [links.*].
conf_gen_write "${DETECTED_REMOTE_HOST}" "${LINKS[@]}"
CONF_PATH="$(conf_gen_path)"

REPLICATE_BLOCK="$(cat <<EOF

[filters.replicate]
icmp_all = "icmp"
udp_probe = "udp and port ${REPLICATE_UDP_PORT}"

EOF
)"
# Inserta el bloque ANTES de la primera línea "[links." preservando el resto.
# awk es portable; sed -i en macOS exige sufijo y es más frágil.
TMP_CONF="${CONF_PATH}.tmp"
awk -v block="${REPLICATE_BLOCK}" '
    !inserted && /^\[links\./ { print block; inserted=1 }
    { print }
' "${CONF_PATH}" > "${TMP_CONF}"
mv "${TMP_CONF}" "${CONF_PATH}"
chmod 600 "${CONF_PATH}"
log_info "Inyectado [filters.replicate] (icmp + udp:${REPLICATE_UDP_PORT}) en ${CONF_PATH}"

# Captura RPi: solo lo necesario para diagnóstico de paquetes — el grueso
# de la evidencia viene del journal, no del pcap.
tcpdump_start_rpi "eth"     "udp portrange 5083-5085" "any"
tcpdump_start_rpi "ubond0"  ""                         "ubond0"

# Timestamp ANTES de arrancar ubond — limita journalctl al run actual.
# Formato journalctl-friendly y compartido con SSH (UTC para evitar TZ skew).
START_TS="$(date -u '+%Y-%m-%d %H:%M:%S')"
log_info "Marca tiempo journal: ${START_TS} UTC"

ubond_runner_start_with_conf "${CONF_PATH}"
sleep 2

UTUN=""
if ! ubond_runner_wait_auth 25; then
    log_err "ubond no autenticó en 25s — abortando, sin tráfico nada que medir"
    ubond_runner_tail_log 30
    exit 1
fi
UTUN="$(ubond_runner_find_utun_iface || true)"
if [[ -z "${UTUN}" ]]; then
    log_err "No detecté utun con IP ${UBOND_TUN_MAC_IP:-10.10.20.2} — túnel no está UP"
    exit 1
fi
log_info "Túnel UP en ${UTUN}; lanzando tráfico de prueba (${TRAFFIC_DURATION}s)"

# --- Tráfico 1: ICMP al gateway interno (matchea filtro icmp_all) ---
PING_TARGET="${UBOND_TUN_VPS_IP:-10.10.20.1}"
log_info "PING ${PING_TARGET} ×${TRAFFIC_DURATION} (1pps)"
ping -c "${TRAFFIC_DURATION}" -i 1 "${PING_TARGET}" \
    > "${SMOKE_TMPDIR}/replicate_ping.log" 2>&1 &
PING_PID="$!"

# --- Tráfico 2: UDP a puerto 9999 vía túnel (matchea filtro udp_probe) ---
# Listener en RPi via SSH (background); luego enviamos paquetitos cada 0.5s.
log_info "Levantando nc -u -l ${REPLICATE_UDP_PORT} en RPi"
as_invoker ssh -p "${DETECTED_SSH_PORT}" -o ConnectTimeout=5 \
    "${RPi_USER:-ubuntu}@${DETECTED_SSH_HOST}" \
    "rm -f ${NC_REMOTE_PIDFILE}; \
     sudo nohup nc -u -l ${REPLICATE_UDP_PORT} >/dev/null 2>&1 & \
     echo \$! | sudo tee ${NC_REMOTE_PIDFILE} >/dev/null" \
    || log_warn "No pude lanzar nc remoto — el filtro UDP no se ejercitará"

# Envía paquetes UDP a través del túnel hacia 10.10.20.1:9999.
log_info "Enviando UDP probes a ${PING_TARGET}:${REPLICATE_UDP_PORT} cada 0.5s"
(
    end=$(( $(date +%s) + TRAFFIC_DURATION ))
    while (( $(date +%s) < end )); do
        echo "smoke-replicate $(date +%s%N)" \
            | nc -u -w 1 "${PING_TARGET}" "${REPLICATE_UDP_PORT}" 2>/dev/null || true
        sleep 0.5
    done
) &
UDP_PID="$!"

# Espera ambos generadores.
wait "${PING_PID}" 2>/dev/null || true
wait "${UDP_PID}"  2>/dev/null || true

log_info "Tráfico completado, dejando 3s para drenar buffers"
sleep 3

# --- Recolectar métricas del journal RPi ---
log_info "Cosechando journal RPi desde ${START_TS}..."
JOURNAL_RAW="${SMOKE_TMPDIR}/replicate_rpi_journal.log"
as_invoker ssh -p "${DETECTED_SSH_PORT}" -o ConnectTimeout=5 \
    "${RPi_USER:-ubuntu}@${DETECTED_SSH_HOST}" \
    "sudo journalctl -u ubond --since '${START_TS}' --no-pager 2>/dev/null" \
    > "${JOURNAL_RAW}" 2>/dev/null || log_warn "journalctl remoto vacío o falló"

# grep -c siempre imprime un número y sale 1 si 0 matches; sumar `|| echo 0`
# duplicaba la salida. Aceptamos la salida tal cual y normalizamos vacío.
count_in() {
    local n
    n="$(grep -cE "$1" "$2" 2>/dev/null || true)"
    echo "${n:-0}"
}

DEDUP_HITS=$(count_in "descartando duplicado data_seq=" "${JOURNAL_RAW}")
LOSS_EVENTS=$(count_in "packet loss reached threashold" "${JOURNAL_RAW}")
RESEND_EVENTS=$(count_in "resend|request_resend" "${JOURNAL_RAW}")

# Cliente (local) — log de ubond. Aquí cuentan los "enviado a N tuneles".
CLIENT_LOG="${UBOND_LOG}"
CLONES_SENT=$(count_in "enviado a [0-9]+ tuneles" "${CLIENT_LOG}")
# Suma de copies (tuneles) clonados — extrae el número y suma.
CLONES_TOTAL=$(grep -oE "enviado a [0-9]+ tuneles" "${CLIENT_LOG}" 2>/dev/null \
    | awk '{ s += $3 } END { print s+0 }')
[[ -z "${CLONES_TOTAL}" ]] && CLONES_TOTAL=0

PING_RECV=$(awk '/packets received/ { print $4; exit }' \
    "${SMOKE_TMPDIR}/replicate_ping.log" 2>/dev/null || true)
[[ -z "${PING_RECV}" ]] && PING_RECV=0

sleep 1
tcpdump_stop_all
ubond_runner_stop

# --- Reporte ---
REPORT="${SMOKE_TMPDIR}/report-replicate-$(date +%Y%m%d-%H%M).md"
{
    printf '## Reporte smoke-replicate — %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '### Configuración\n\n'
    printf '| Item | Valor |\n|------|-------|\n'
    printf '| Target | %s (%s) |\n' "${DETECTED_RPI_TARGET}" "${DETECTED_REMOTE_HOST}"
    printf '| Links | %d (%s) |\n' "${#LINKS[@]}" "$(printf '%s,' "${LINKS[@]%%|*}" | sed 's/,$//')"
    printf '| Filtros replicate | icmp_all + udp_probe (port %s) |\n' "${REPLICATE_UDP_PORT}"
    printf '| Tráfico | %ss ping@1pps + UDP@2pps |\n' "${TRAFFIC_DURATION}"
    printf '| utun cliente | %s |\n\n' "${UTUN}"

    printf '### Métricas\n\n'
    printf '| Métrica | Valor | Origen |\n|---------|-------|--------|\n'
    printf '| Ping recibidos / enviados | %s / %s | local ping |\n' "${PING_RECV}" "${TRAFFIC_DURATION}"
    printf '| Eventos "enviado a N tuneles" | %s | client log |\n' "${CLONES_SENT}"
    printf '| Σ clones enviados (todos los tuneles) | %s | client log |\n' "${CLONES_TOTAL}"
    printf '| Dedup hits ("descartando duplicado") | %s | RPi journal |\n' "${DEDUP_HITS}"
    printf '| Loss threshold events | %s | RPi journal |\n' "${LOSS_EVENTS}"
    printf '| Resend / request_resend | %s | RPi journal |\n\n' "${RESEND_EVENTS}"

    printf '### Veredicto REQ-NET-27\n\n'
    if (( DEDUP_HITS > 0 )) && (( LOSS_EVENTS < 5 )); then
        printf '**OK** — dedup hits=%s con loss bajo (%s). El fix `replicated`/`data_seq` compartido funciona: clones llegan al RPi con el mismo data_seq y el dedup LRU los descarta.\n' \
            "${DEDUP_HITS}" "${LOSS_EVENTS}"
    elif (( DEDUP_HITS == 0 )) && (( CLONES_SENT > 0 )) && (( PING_RECV > 0 )); then
        printf '**REGRESIÓN PROBABLE** — el cliente clona (%s eventos enviado a tuneles) y ping fluye (%s/%s), pero el RPi no descarta NADA. Suele ser:\n' \
            "${CLONES_SENT}" "${PING_RECV}" "${TRAFFIC_DURATION}"
        printf '  - `replicated` uninit en `ubond_pkt_get()` (regresión REQ-NET-27).\n'
        printf '  - Cada clone llega con data_seq distinto → LRU nunca matchea.\n'
        printf '  - Verificar: `grep -E "replicated\\s*=\\s*0" src/pkt.c` en el RPi.\n'
    elif (( CLONES_SENT == 0 )); then
        printf '**SIN REPLICACIÓN** — cliente no emitió "enviado a N tuneles". Posibles causas:\n'
        printf '  - `[filters.replicate]` no parseado (revisar client log: `grep "added replicate filter" %s`).\n' "${CLIENT_LOG}"
        printf '  - `--enable-filters` no compilado en el binario cliente.\n'
        printf '  - Filtros BPF no matchean el tráfico (poco probable con `icmp` puro).\n'
    elif (( DEDUP_HITS == 0 )) && (( LOSS_EVENTS > 5 )); then
        printf '**INCONCLUSO** — dedup=0 con loss alto (%s). Los clones probablemente se pierden antes de llegar al RPi por una pata mala; relanzar con cobertura estable.\n' \
            "${LOSS_EVENTS}"
    else
        printf '**INCONCLUSO** — dedup=%s, clones=%s, ping=%s/%s, loss=%s. Revisar logs manualmente:\n  - %s\n  - %s\n' \
            "${DEDUP_HITS}" "${CLONES_SENT}" "${PING_RECV}" "${TRAFFIC_DURATION}" "${LOSS_EVENTS}" \
            "${CLIENT_LOG}" "${JOURNAL_RAW}"
    fi
    printf '\n### Logs\n\n- Cliente ubond: `%s`\n- RPi journal: `%s`\n- Pcaps: `%s/cap_*.pcap`\n' \
        "${CLIENT_LOG}" "${JOURNAL_RAW}" "${SMOKE_TMPDIR}"
} | tee "${REPORT}"

log_info "Reporte: ${REPORT}"
