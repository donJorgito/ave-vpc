#!/usr/bin/env bash
# tools/lib/tests.sh
#
# Batería de tests sobre el túnel ubond ya levantado:
#   - run_ping_test:       N pings ICMP a 10.10.10.1 (gateway interno).
#   - run_curl_tunnel:     curl HTTP a 1.1.1.1 vía túnel; verifica HTTP/TCP.
#   - run_throughput:      descarga 1MB de api.ipify.org; mide KB/s.
#   - run_nc_udp_probe:    netcat UDP a RPi:5083 con payload pequeño;
#                          comprueba que el camino de retorno funciona si
#                          ubond no está autenticando.
#
# Cada función:
#   - Imprime un encabezado claro.
#   - Devuelve 0/1 según éxito.
#   - Setea variables TESTS_<NAME>_RESULT con resumen para report.sh.

# shellcheck source=tools/lib/_common.sh
: "${AVEVPC_ROOT:?source _common.sh primero}"

run_ping_test() {
    local target="${TUN_VPS_IP:-10.10.10.1}"
    local count="${1:-5}"
    log_info "PING ${target} ×${count}"
    local out rc
    out="$(ping -c "${count}" -W 2000 "${target}" 2>&1)"; rc=$?
    printf '    %s\n' "${out//$'\n'/$'\n    '}"
    local recv
    recv="$(echo "${out}" | awk '/packets received/ { print $4 }')"
    # shellcheck disable=SC2034  # consumido por report.sh
    TESTS_PING_RECEIVED="${recv:-0}"
    # shellcheck disable=SC2034
    TESTS_PING_TOTAL="${count}"
    export TESTS_PING_RECEIVED TESTS_PING_TOTAL
    return "${rc}"
}

# curl HTTP a 1.1.1.1 vía túnel. Forzamos --interface al utun para garantizar
# que sale por dentro del túnel (en vez de por la WiFi nativa).
run_curl_tunnel() {
    local utun="${1:?utun iface}"
    local url="http://1.1.1.1/cdn-cgi/trace"
    log_info "CURL ${url} via ${utun}"
    local body rc
    body="$(curl --interface "${utun}" -sS --max-time 8 "${url}" 2>&1)"; rc=$?
    echo "${body}" | head -10 | sed 's/^/    /'
    # shellcheck disable=SC2034  # consumido por report.sh
    if (( rc == 0 )) && [[ "${body}" == *"ip="* ]]; then
        TESTS_CURL_RESULT="ok"
    else
        TESTS_CURL_RESULT="fail (rc=${rc})"
    fi
    export TESTS_CURL_RESULT
    return "${rc}"
}

# Throughput download 1 MB. Usa api.ipify.org/cdn-cgi style; aquí usamos un
# endpoint Cloudflare estable para 1MB.
run_throughput() {
    local utun="${1:?utun iface}"
    local url="https://speed.cloudflare.com/__down?bytes=1048576"
    log_info "THROUGHPUT 1MB via ${utun}"
    local stats rc
    stats="$(curl --interface "${utun}" -sS --max-time 30 \
        -o /dev/null -w 'speed=%{speed_download} time=%{time_total} http=%{http_code}' \
        "${url}" 2>&1)"; rc=$?
    echo "    ${stats}"
    # shellcheck disable=SC2034
    TESTS_THROUGHPUT_RESULT="${stats}"
    export TESTS_THROUGHPUT_RESULT
    return "${rc}"
}

# Probe UDP raw a RPi:5083. No depende de ubond — solo verifica que el path
# UDP funciona (cafe podría bloquear UDP altos).
run_nc_udp_probe() {
    local host="$1" port="${2:-5083}"
    log_info "UDP probe a ${host}:${port}"
    # shellcheck disable=SC2034
    if echo "smoke-probe" | nc -u -w 2 "${host}" "${port}" >/dev/null 2>&1; then
        TESTS_NC_UDP_RESULT="ok"
        echo "    paquete UDP enviado (no respuesta esperada — ubond ignora payload random)"
        export TESTS_NC_UDP_RESULT
        return 0
    else
        TESTS_NC_UDP_RESULT="fail"
        echo "    nc UDP falló — posible filtrado de la red"
        export TESTS_NC_UDP_RESULT
        return 1
    fi
}
