#!/usr/bin/env bash
# tools/smoke-ave.sh
#
# Smoke-test ubond client en condiciones AVE (multi-link 4G + WiFi tren,
# cobertura oscilante).
# Política:
#   - Target:  DDNS obligatorio.
#   - Links:   iPhone Y Pixel obligatorios (si falta uno → warn pero sigue);
#              WiFi del tren opcional (suele tener captive — se evalúa).
#   - Duración: capturas de 60s (vs 10-15s en casa/cafe) para ver flapping
#               de cobertura. Tests repetidos en bucle ligero.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LOG_PREFIX="smoke-ave"

source "${SCRIPT_DIR}/lib/_common.sh"
source "${SCRIPT_DIR}/lib/env-detect.sh"
source "${SCRIPT_DIR}/lib/conf-gen.sh"
source "${SCRIPT_DIR}/lib/ubond-runner.sh"
source "${SCRIPT_DIR}/lib/tcpdump.sh"
source "${SCRIPT_DIR}/lib/tests.sh"
source "${SCRIPT_DIR}/lib/report.sh"

# Capturas más largas en AVE (oscilación dura más que el run base).
export CAP_PKT_LIMIT=2000

cleanup() {
    trap - EXIT INT TERM
    log_info "Cleanup: parando capturas y ubond"
    tcpdump_stop_all 2>/dev/null || true
    ubond_runner_stop 2>/dev/null || true
}
trap cleanup EXIT INT TERM

require_root "$@"
env_detect_all
env_detect_summary

if [[ "${DETECTED_RPI_DDNS_OK}" != "1" ]]; then
    die 1 "RPi no alcanzable por DDNS — sin túnel posible."
fi
[[ -z "${DETECTED_IPHONE_IP:-}" ]] && log_warn "iPhone NO conectado — bonding degradado"
[[ -z "${DETECTED_PIXEL_IP:-}"  ]] && log_warn "Pixel  NO conectado — bonding degradado"

env_detect_eligible_links
LINKS=()
# En AVE preferimos iPhone+Pixel; WiFi solo si NO hay captive (env_detect ya filtra).
for entry in "${ELIGIBLE_LINKS[@]:-}"; do
    case "${entry%%|*}" in
        iphone|pixel|wifi) LINKS+=("${entry}") ;;
    esac
done
if (( ${#LINKS[@]} == 0 )); then
    die 1 "Sin links elegibles."
fi

ubond_runner_cleanup_stale
conf_gen_write "${VPS_IP}" "${LINKS[@]}"

for entry in "${LINKS[@]}"; do
    IFS='|' read -r _name iface _ip <<<"${entry}"
    tcpdump_start_mac "${iface}" "udp portrange 5083-5085"
done
tcpdump_start_rpi "eth"     "udp portrange 5083-5085" "any"
tcpdump_start_rpi "ubond0"  ""                         "ubond0"

ubond_runner_start_with_conf "$(conf_gen_path)"
sleep 2

UTUN=""
if ubond_runner_wait_auth 30; then
    UTUN="$(ubond_runner_find_utun_iface || true)"
    [[ -n "${UTUN}" ]] && tcpdump_start_mac "${UTUN}" ""
    sleep 1
    # Bucle de 4 rondas de tests cada 15s para capturar oscilación.
    for i in 1 2 3 4; do
        log_info "=== ronda ${i}/4 ==="
        run_ping_test 5 || log_warn "ping ronda ${i} falló"
        if [[ -n "${UTUN}" ]]; then
            run_curl_tunnel  "${UTUN}" || log_warn "curl ronda ${i} falló"
        fi
        sleep 10
    done
    [[ -n "${UTUN}" ]] && run_throughput "${UTUN}" || log_warn "throughput falló"
else
    log_err "ubond no autenticó en 30s — saltando tests"
fi

run_nc_udp_probe "${VPS_IP}" 5083 || log_warn "UDP probe falló"

sleep 2
tcpdump_stop_all
ubond_runner_stop

REPORT="${SMOKE_TMPDIR}/report-ave-$(date +%Y%m%d-%H%M).md"
report_render_markdown "ave" "${UTUN:-?}" | tee "${REPORT}"
log_info "Reporte: ${REPORT}"
