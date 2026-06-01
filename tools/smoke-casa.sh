#!/usr/bin/env bash
# tools/smoke-casa.sh
#
# Smoke-test ubond client en entorno doméstico (LAN al RPi).
# Política:
#   - Target:  LAN (192.168.1.101) si alcanzable, sino aborta — la idea es
#              probar el dataplane sin internet de por medio.
#   - Links:   WiFi sí (target es LAN, no DDNS — no hay hairpin posible).
#              iPhone/Pixel si están tethered también se incluyen.
#   - Capt.:   Mac + RPi (vía SSH LAN).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LOG_PREFIX="smoke-casa"

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
# shellcheck source=tools/lib/tests.sh
source "${SCRIPT_DIR}/lib/tests.sh"
# shellcheck source=tools/lib/report.sh
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

if [[ "${DETECTED_RPI_LAN_OK}" != "1" ]]; then
    die 1 "RPi no alcanzable en LAN (${RPi_IP:-?}). ¿Estás en la WiFi de casa?"
fi

# Con target=LAN no hay hairpin — incluimos todos los links elegibles
# (WiFi, iPhone, Pixel). En LAN el WiFi suele ser la única ruta cuando
# no hay tethering activo.
env_detect_eligible_links
LINKS=("${ELIGIBLE_LINKS[@]:-}")
if (( ${#LINKS[@]} == 0 )); then
    die 1 "Sin links elegibles (WiFi/iPhone/Pixel). Conecta al menos uno."
fi

ubond_runner_cleanup_stale
conf_gen_write "${RPi_IP}" "${LINKS[@]}"

# Capturas: cada link en su iface + RPi.
for entry in "${LINKS[@]}"; do
    IFS='|' read -r _name iface _ip <<<"${entry}"
    tcpdump_start_mac "${iface}" "udp portrange 5083-5085"
done
tcpdump_start_rpi "eth"     "udp portrange 5083-5085" "any"
tcpdump_start_rpi "ubond0"  ""                         "ubond0"

ubond_runner_start_with_conf "$(conf_gen_path)"
sleep 2

UTUN=""
if ubond_runner_wait_auth 20; then
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

# Probe UDP raw — independiente de ubond.
run_nc_udp_probe "${RPi_IP}" 5083 || log_warn "UDP probe falló"

sleep 2
tcpdump_stop_all
ubond_runner_stop

REPORT="${SMOKE_TMPDIR}/report-casa.md"
report_render_markdown "casa" "${UTUN:-?}" | tee "${REPORT}"
log_info "Reporte: ${REPORT}"
