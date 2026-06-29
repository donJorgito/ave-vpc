#!/usr/bin/env bash
# tools/smoke-cafe.sh
#
# Smoke-test ubond client en entorno público (cafetería, hotel, oficina) —
# WiFi sale por internet hasta el RPi vía DDNS.
# Política:
#   - Target:  DDNS (200bares.dedyn.io) obligatorio.
#   - Links:   WiFi sí (sin hairpin porque sale a internet). iPhone/Pixel si
#              están enchufados se añaden — más realista.
#   - Captura: Mac (cada link) + RPi (UDP entrante + ubond0 saliente).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LOG_PREFIX="smoke-cafe"

source "${SCRIPT_DIR}/lib/_common.sh"
source "${SCRIPT_DIR}/lib/env-detect.sh"
source "${SCRIPT_DIR}/lib/conf-gen.sh"
source "${SCRIPT_DIR}/lib/ubond-runner.sh"
source "${SCRIPT_DIR}/lib/tcpdump.sh"
source "${SCRIPT_DIR}/lib/tests.sh"
source "${SCRIPT_DIR}/lib/report.sh"

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
    die 1 "RPi no alcanzable por DDNS (${VPS_IP}). ¿Internet OK? ¿UDP saliente?"
fi
if [[ "${DETECTED_CAPTIVE}" == "1" ]]; then
    die 1 "Captive portal en WiFi — autentica en el navegador y reintenta."
fi

env_detect_eligible_links
LINKS=("${ELIGIBLE_LINKS[@]:-}")
if (( ${#LINKS[@]} == 0 )); then
    die 1 "Sin links elegibles (WiFi, iPhone, Pixel)."
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
if ubond_runner_wait_auth 25; then
    UTUN="$(ubond_runner_find_utun_iface || true)"
    [[ -n "${UTUN}" ]] && tcpdump_start_mac "${UTUN}" ""
    sleep 1
    run_ping_test 5 || log_warn "ping falló"
    if [[ -n "${UTUN}" ]]; then
        run_curl_tunnel  "${UTUN}" || log_warn "curl falló"
        run_throughput   "${UTUN}" || log_warn "throughput falló"
    fi
else
    log_err "ubond no autenticó — saltando tests de tráfico"
fi

run_nc_udp_probe "${VPS_IP}" 5083 || log_warn "UDP probe falló"

sleep 2
tcpdump_stop_all
ubond_runner_stop

REPORT="${SMOKE_TMPDIR}/report-cafe.md"
report_render_markdown "cafe" "${UTUN:-?}" | tee "${REPORT}"
log_info "Reporte: ${REPORT}"
