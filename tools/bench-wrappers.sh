#!/usr/bin/env bash
# tools/bench-wrappers.sh — REQ-NET-45 banco de medida (T4 del plan 13).
#
# Mide, a través del utun de ubond (UBOND_TUN_MAC_IP -> UBOND_TUN_VPS_IP):
#   - latencia: RTT min/avg/max/stddev (ping)
#   - jitter:   stddev del RTT (derivado del ping)
#   - loss:     % de pérdida de paquetes
#   - throughput: iperf3 contra la RPi si está disponible; si no, fallback a
#                 una transferencia bruta cronometrada por el túnel.
#
# El operador lo ejecuta UNA VEZ POR VÍA, pasando una etiqueta (direct /
# socat / udp2raw / wstunnel). Cada ejecución AÑADE una fila comparable a
# generated/bench-results.tsv → ranking coste/rendimiento (no "pasa/no pasa").
#
# Toda medida está acotada con timeouts: el banco NUNCA debe colgarse aunque
# el túnel esté caído o iperf3 no responda.
#
# Diseño house-style: set -uo pipefail, guard bash>=4, source config/env
# (sin hardcoding de IPs — Rule 4), logger -t, imprime el comando RPi-side
# iperf3 -s (NO hace ssh).
#
# Uso:
#   tools/bench-wrappers.sh direct        # mide y añade fila etiqueta=direct
#   tools/bench-wrappers.sh socat
#   tools/bench-wrappers.sh --server-cmd  # imprime el comando RPi iperf3 -s
#   tools/bench-wrappers.sh --check       # verifica herramientas (iperf3/ping)
#   tools/bench-wrappers.sh --show        # vuelca la tabla de resultados
#
# Variables override (default desde config/env):
#   BENCH_TARGET    IP destino dentro del túnel (default UBOND_TUN_VPS_IP)
#   BENCH_PINGS     nº de pings para latencia/jitter/loss (default 20)
#   BENCH_DUR_S     duración iperf3 / transferencia (default 10)
#   BENCH_TIMEOUT_S techo global por medida (default 30)

set -uo pipefail

# --- Guard bash >= 4 (coherencia repo; macOS trae 3.2). ---
if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: requiere bash >= 4 (tienes ${BASH_VERSION}). brew install bash" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/generated"
CONFIG_FILE="${SCRIPT_DIR}/config/env"
RESULTS_TSV="${GENERATED_DIR}/bench-results.tsv"
LOG="${GENERATED_DIR}/bench-wrappers.log"

# Versión PINNED (Rule 7 IDLC). iperf3 3.16+ es la rama estable actual.
IPERF3_PINNED_VERSION="3.21"

mkdir -p "${GENERATED_DIR}"

# Cargar config/env para UBOND_TUN_*_IP (sin hardcoding — Rule 4).
# shellcheck source=/dev/null
[[ -r "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}" 2>/dev/null || true

# Destino dentro del túnel: el gateway interno del lado VPS/RPi.
TARGET="${BENCH_TARGET:-${UBOND_TUN_VPS_IP:-10.10.20.1}}"
# IP del Mac dentro del túnel (para localizar el utun correcto, igual que
# hace ubond-watchdog.sh — la subnet 10.10.20.0/24 puede colisionar).
SELF_TUN_IP="${UBOND_TUN_MAC_IP:-10.10.20.2}"
PINGS="${BENCH_PINGS:-20}"
DUR_S="${BENCH_DUR_S:-10}"
TIMEOUT_S="${BENCH_TIMEOUT_S:-30}"

log() {
    local msg="$*"
    logger -t bench-wrappers "${msg}" 2>/dev/null || true
    printf '%s %s\n' "$(date -u +%FT%TZ)" "${msg}" | tee -a "${LOG}" >&2
}

# --- timeout portable: en macOS no hay coreutils `timeout` por defecto.
#     Usa gtimeout (brew coreutils) si existe; si no, un guardián con &/kill. ---
run_bounded() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "${secs}" "$@"
        return $?
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "${secs}" "$@"
        return $?
    fi
    # Fallback puro bash: lanza en background y mata al vencer el plazo.
    "$@" &
    local cmd_pid=$!
    ( sleep "${secs}"; kill -TERM "${cmd_pid}" 2>/dev/null || true ) &
    local killer_pid=$!
    local rc=0
    wait "${cmd_pid}" 2>/dev/null || rc=$?
    kill -TERM "${killer_pid}" 2>/dev/null || true
    wait "${killer_pid}" 2>/dev/null || true
    return "${rc}"
}

# --- Localizar el utun de ubond por su IP interna (igual que el watchdog).
#     Sin utun con SELF_TUN_IP el túnel está caído por definición. ---
find_ubond_utun() {
    local i
    for i in $(seq 0 15); do
        if ifconfig "utun${i}" 2>/dev/null \
                | awk '$1 == "inet" && $2 == "'"${SELF_TUN_IP}"'" {f=1} END {exit !f}'; then
            printf 'utun%s\n' "${i}"
            return 0
        fi
    done
    return 1
}

# --- Comando server-side (RPi): iperf3 en modo servidor. NO lo lanza este
#     script (solo lo imprime, como wrap-socat). ---
print_server_cmd() {
    cat <<EOF
# ---- Comando a ejecutar en la RPi (${VPS_IP:-VPS_IP}) — NO lo lanza este script ----
# Servidor iperf3 escuchando dentro del túnel ubond (IP interna lado VPS).
# Pin de versión: iperf3 ${IPERF3_PINNED_VERSION} (apt: iperf3=${IPERF3_PINNED_VERSION}-*).
# El -B liga el servidor a la IP del túnel para no medir por la red física.
iperf3 -s -B ${TARGET} -1
#
# (-1 = atiende UN cliente y sale; relánzalo por cada medida. Quita -1 para
#  dejarlo persistente si vas a medir varias vías seguidas.)
# ------------------------------------------------------------------------------
EOF
}

# --- --check: herramientas presentes. ---
do_check() {
    local ok=0
    if command -v iperf3 >/dev/null 2>&1; then
        local have
        have="$(iperf3 --version 2>&1 | grep -oE 'iperf [0-9.]+' | head -1 || true)"
        echo "OK: iperf3 presente (${have:-versión desconocida}; pin esperado ${IPERF3_PINNED_VERSION})"
    else
        echo "FALTA: iperf3 (brew install iperf3 / apt-get install iperf3=${IPERF3_PINNED_VERSION}-*)" >&2
        echo "       (el banco caerá a fallback de transferencia cronometrada)" >&2
        ok=1
    fi
    command -v ping >/dev/null 2>&1 || { echo "FALTA: ping" >&2; ok=1; }
    return "${ok}"
}

# --- Medir latencia/jitter/loss con ping forzado por el utun de ubond.
#     Devuelve: "loss_pct rtt_min rtt_avg rtt_max rtt_stddev" o "NA NA..". ---
measure_ping() {
    local utun="$1" out loss line
    # ping -b liga la salida al utun; -t es timeout total en macOS.
    out="$(run_bounded "${TIMEOUT_S}" \
        ping -c "${PINGS}" -b "${utun}" "${TARGET}" 2>/dev/null || true)"
    if [[ -z "${out}" ]]; then
        echo "NA NA NA NA NA"
        return 0
    fi
    # loss: "20 packets transmitted, 20 packets received, 0.0% packet loss"
    loss="$(printf '%s\n' "${out}" \
        | grep -oE '[0-9.]+% packet loss' | grep -oE '[0-9.]+' | head -1)"
    # rtt: "round-trip min/avg/max/stddev = 1.2/3.4/5.6/0.7 ms"
    line="$(printf '%s\n' "${out}" | grep -E 'min/avg/max' | head -1)"
    local stats
    stats="$(printf '%s\n' "${line}" \
        | sed -E 's#.*= ([0-9./]+) ms.*#\1#' | tr '/' ' ')"
    if [[ -z "${stats}" || "${line}" != *min/avg/max* ]]; then
        echo "${loss:-NA} NA NA NA NA"
        return 0
    fi
    echo "${loss:-NA} ${stats}"
}

# --- Medir throughput. iperf3 si está; si no, transferencia cronometrada. ---
measure_throughput() {
    local utun="$1"
    if command -v iperf3 >/dev/null 2>&1; then
        # -B liga el cliente al IP del túnel del Mac; -t duración; -J JSON.
        local out mbps
        out="$(run_bounded "${TIMEOUT_S}" \
            iperf3 -c "${TARGET}" -B "${SELF_TUN_IP}" -t "${DUR_S}" -J 2>/dev/null || true)"
        if [[ -n "${out}" ]]; then
            # bits_per_second del sumario sent. grep simple para no exigir jq.
            mbps="$(printf '%s\n' "${out}" \
                | grep -oE '"bits_per_second":[[:space:]]*[0-9.]+' \
                | tail -1 | grep -oE '[0-9.]+' \
                | awk '{ printf "%.2f", $1/1000000 }')"
            if [[ -n "${mbps}" ]]; then
                echo "${mbps} iperf3"
                return 0
            fi
        fi
        log "iperf3 no devolvió throughput (¿servidor RPi sin levantar?) — fallback transferencia"
    fi

    # Fallback: transferencia bruta cronometrada por el túnel. Envía un bloque
    # conocido por nc al TARGET:9999 (el operador debe levantar un sink allí)
    # y mide segundos. Acotado por run_bounded. Si nc no está o no conecta,
    # devuelve NA — nunca cuelga.
    if command -v nc >/dev/null 2>&1; then
        local bytes start end secs payload_mb=5
        bytes=$(( payload_mb * 1024 * 1024 ))
        start="$(date +%s)"
        # dd genera el bloque; nc lo manda. -G/-w acotan nc en macOS.
        if run_bounded "${TIMEOUT_S}" bash -c \
            "dd if=/dev/zero bs=1m count=${payload_mb} 2>/dev/null | nc -w 5 ${TARGET} 9999" \
            >/dev/null 2>&1; then
            end="$(date +%s)"
            secs=$(( end - start ))
            (( secs < 1 )) && secs=1
            awk -v b="${bytes}" -v s="${secs}" \
                'BEGIN { printf "%.2f fallback-nc\n", (b*8)/(s*1000000) }'
            return 0
        fi
    fi
    echo "NA none"
}

# --- Asegurar cabecera del TSV (una sola vez). ---
ensure_header() {
    if [[ ! -s "${RESULTS_TSV}" ]]; then
        printf 'timestamp\tlabel\tloss_pct\trtt_min_ms\trtt_avg_ms\trtt_max_ms\trtt_stddev_ms\tthroughput_mbps\ttp_method\n' \
            >"${RESULTS_TSV}"
    fi
}

do_show() {
    if [[ -s "${RESULTS_TSV}" ]]; then
        column -t -s "$(printf '\t')" "${RESULTS_TSV}" 2>/dev/null || cat "${RESULTS_TSV}"
    else
        echo "sin resultados aún (${RESULTS_TSV} vacío)" >&2
    fi
}

# --- Medida completa para una etiqueta. ---
do_bench() {
    local label="$1"
    do_check >/dev/null 2>&1 || true   # informativo; el fallback cubre faltas

    local utun
    if ! utun="$(find_ubond_utun)"; then
        log "ERROR: no encuentro utun de ubond con IP ${SELF_TUN_IP} — ¿túnel levantado? Abortando medida '${label}'"
        exit 1
    fi
    log "midiendo etiqueta='${label}' via ${utun} -> ${TARGET} (pings=${PINGS}, dur=${DUR_S}s, timeout=${TIMEOUT_S}s)"
    print_server_cmd

    local ping_stats tp
    read -r loss rmin ravg rmax rstd <<<"$(measure_ping "${utun}")"
    ping_stats="loss=${loss}% rtt(min/avg/max/stddev)=${rmin}/${ravg}/${rmax}/${rstd} ms"
    log "latencia: ${ping_stats}"

    read -r tp tp_method <<<"$(measure_throughput "${utun}")"
    log "throughput: ${tp} Mbps (método=${tp_method})"

    ensure_header
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date -u +%FT%TZ)" "${label}" \
        "${loss}" "${rmin}" "${ravg}" "${rmax}" "${rstd}" \
        "${tp}" "${tp_method}" >>"${RESULTS_TSV}"
    log "fila añadida a ${RESULTS_TSV} (etiqueta='${label}')"
    echo "OK: medida '${label}' registrada. Tabla actual:" >&2
    do_show
}

case "${1:-}" in
    --server-cmd) print_server_cmd; exit 0 ;;
    --check)      do_check; exit $? ;;
    --show)       do_show;  exit 0 ;;
    "")           echo "uso: $0 <label>|--check|--show|--server-cmd" >&2; exit 2 ;;
    --*)          echo "uso: $0 <label>|--check|--show|--server-cmd" >&2; exit 2 ;;
    *)            do_bench "$1"; exit 0 ;;
esac
