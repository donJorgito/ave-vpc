#!/usr/bin/env bash
# tools/lib/tcpdump.sh
#
# Captura tcpdump simultánea en Mac (varias interfaces) y RPi (vía SSH).
# Pcaps en ${SMOKE_TMPDIR}/cap_*.pcap. Convención de nombres:
#   cap_mac_<iface>.pcap     — Mac, una iface por archivo
#   cap_rpi_eth.pcap         — RPi, todas las UDP 5083-5085 entrantes
#   cap_rpi_ubond0.pcap      — RPi, tun device (output de ubond hacia kernel)
#
# Cada captura corre en background como tcpdump -c N -w file. Sus PIDs se
# guardan en ${SMOKE_TMPDIR}/cap_pids.txt para luego matarlos juntos.

# shellcheck source=tools/lib/_common.sh
: "${AVEVPC_ROOT:?source _common.sh primero}"

CAP_DIR="${SMOKE_TMPDIR}"
CAP_PIDS_FILE="${CAP_DIR}/cap_pids.txt"
CAP_RPI_REMOTE_PIDS="${CAP_DIR}/cap_rpi_remote_pids.txt"
CAP_PKT_LIMIT="${CAP_PKT_LIMIT:-200}"

# ---- Mac side ----------------------------------------------------------------

# Arranca captura en una interfaz Mac. Args: $1 iface, $2 filtro BPF (opcional).
tcpdump_start_mac() {
    local iface="$1"
    local filter="${2:-}"
    require_cmd tcpdump
    local out="${CAP_DIR}/cap_mac_${iface}.pcap"
    rm -f "${out}"
    tcpdump -i "${iface}" -nn -c "${CAP_PKT_LIMIT}" \
        -w "${out}" ${filter:+${filter}} >/dev/null 2>&1 &
    local pid="$!"
    echo "${pid}" >> "${CAP_PIDS_FILE}"
    log_info "tcpdump Mac (${iface}${filter:+ '${filter}'}) → ${out} pid=${pid}"
}

# ---- RPi side via SSH --------------------------------------------------------

_tcpdump_ssh() {
    : "${DETECTED_SSH_HOST:?env-detect debe ejecutarse antes}"
    : "${DETECTED_SSH_PORT:?env-detect debe ejecutarse antes}"
    : "${RPi_USER:?RPi_USER no definido}"
    # SSH como el usuario invocador — tiene las claves en ~/.ssh/, root no.
    as_invoker ssh -p "${DETECTED_SSH_PORT}" -o ConnectTimeout=5 \
        "${RPi_USER}@${DETECTED_SSH_HOST}" "$@"
}

# Arranca tcpdump en RPi para un filtro+nombre dado. Args:
#   $1 nombre (eth|ubond0)  — solo etiqueta del archivo
#   $2 filtro BPF para tcpdump (ej. "udp portrange 5083-5085" o "" para iface ubond0)
#   $3 iface tcpdump (ej. "any" o "ubond0")
tcpdump_start_rpi() {
    local label="$1" filter="$2" iface="$3"
    : "${CAP_PKT_LIMIT}"
    local local_out="${CAP_DIR}/cap_rpi_${label}.pcap"
    local remote_pcap="/tmp/cap_rpi_${label}.pcap"
    local remote_pidfile="/tmp/cap_rpi_${label}.pid"
    rm -f "${local_out}"

    # Lanzamos el tcpdump en RPi en background, anotamos su PID, dejamos
    # corriendo hasta que llamemos al stop. La captura quedará guardada en
    # /tmp del RPi y la traemos al final.
    _tcpdump_ssh "rm -f ${remote_pcap} ${remote_pidfile}; \
        sudo nohup tcpdump -i ${iface} -nn -c ${CAP_PKT_LIMIT} \
            -w ${remote_pcap} ${filter:+${filter}} >/dev/null 2>&1 & \
        echo \$! > ${remote_pidfile}" \
        || { log_warn "No pude arrancar tcpdump remoto ${label}"; return 1; }
    local rpid
    rpid="$(_tcpdump_ssh "cat ${remote_pidfile} 2>/dev/null || true")"
    echo "${label}|${rpid}|${remote_pcap}" >> "${CAP_RPI_REMOTE_PIDS}"
    log_info "tcpdump RPi (${iface}${filter:+ '${filter}'}) → ${remote_pcap} (pid ${rpid})"
}

# ---- Stop / collect ----------------------------------------------------------

# Para todas las capturas Mac y RPi y trae los pcaps de RPi por scp.
tcpdump_stop_all() {
    # Mac
    if [[ -r "${CAP_PIDS_FILE}" ]]; then
        while read -r pid; do
            [[ -z "${pid}" ]] && continue
            kill "${pid}" 2>/dev/null || true
        done < "${CAP_PIDS_FILE}"
        rm -f "${CAP_PIDS_FILE}"
    fi

    # RPi: kill remoto + scp del pcap a local
    if [[ -r "${CAP_RPI_REMOTE_PIDS}" ]]; then
        while IFS='|' read -r label rpid remote_pcap; do
            [[ -z "${label}" ]] && continue
            _tcpdump_ssh "sudo kill ${rpid} 2>/dev/null; sleep 0.5" || true
            local local_out="${CAP_DIR}/cap_rpi_${label}.pcap"
            as_invoker scp -q -P "${DETECTED_SSH_PORT}" \
                "${RPi_USER}@${DETECTED_SSH_HOST}:${remote_pcap}" \
                "${local_out}" 2>/dev/null \
                || log_warn "scp pcap remoto ${label} falló"
            _tcpdump_ssh "sudo rm -f ${remote_pcap}" || true
        done < "${CAP_RPI_REMOTE_PIDS}"
        rm -f "${CAP_RPI_REMOTE_PIDS}"
    fi
    log_info "Capturas paradas y recogidas"
}

# Cuenta paquetes de un pcap (Mac side). Args: $1 ruta pcap.
tcpdump_pcap_count() {
    local pcap="$1"
    [[ -r "${pcap}" ]] || { echo 0; return; }
    tcpdump -nn -r "${pcap}" 2>/dev/null | wc -l | tr -d ' '
}
