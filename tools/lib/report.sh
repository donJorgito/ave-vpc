#!/usr/bin/env bash
# tools/lib/report.sh
#
# Analiza los pcaps y resultados de tests recolectados por las otras libs y
# emite un informe markdown a stdout y opcionalmente a un fichero.
#
# Diagnostica dónde muere el paquete contando paquetes en cada punto de
# captura. Lógica:
#   Mac out (en0/en8/en12 UDP 5083-5085) > 0  AND  RPi in 5083-5085 == 0
#       → cortado entre Mac y RPi (firewall/NAT operador)
#   RPi in > 0  AND  Mac utun in == 0
#       → ubond decrypta pero kernel no recibe / o RPi reply se pierde
#   Mac utun in > 0  AND ping 0/N
#       → respuesta llega al kernel pero no al socket ICMP (raro)
#
# Salida en markdown table format para ser pegable a docs/v2-ubond/.

# shellcheck source=tools/lib/_common.sh
: "${AVEVPC_ROOT:?source _common.sh primero}"

# Cuenta paquetes en un pcap. Acepta vacío y devuelve 0.
_report_pkt_count() {
    local pcap="$1"
    if [[ ! -r "${pcap}" || ! -s "${pcap}" ]]; then echo 0; return; fi
    tcpdump -nn -r "${pcap}" 2>/dev/null | wc -l | tr -d ' '
}

# Genera una tabla markdown con los conteos por iface. Args opcionales:
# $1 = nombre del orchestrator (casa/cafe/ave), $2 = utun usado.
report_render_markdown() {
    local label="${1:-smoke}"
    local utun="${2:-utun?}"

    {
        printf '## Reporte smoke-test (%s) — %s\n\n' \
            "${label}" "$(date '+%Y-%m-%d %H:%M:%S')"

        printf '### Entorno detectado\n\n'
        printf '| Item | Valor |\n|------|-------|\n'
        printf '| WiFi  (%s) | %s |\n' "${DETECTED_WIFI_IFACE:-}"   "${DETECTED_WIFI_IP:-<down>}"
        printf '| iPhone (%s) | %s |\n' "${DETECTED_IPHONE_IFACE:-}" "${DETECTED_IPHONE_IP:-<down>}"
        printf '| Pixel  (%s) | %s |\n' "${DETECTED_PIXEL_IFACE:-}"  "${DETECTED_PIXEL_IP:-<down>}"
        printf '| Captive | %s |\n' "$([[ ${DETECTED_CAPTIVE:-0} == 1 ]] && echo SI || echo no)"
        printf '| Target | %s (%s) |\n\n' "${DETECTED_RPI_TARGET:-?}" "${DETECTED_REMOTE_HOST:-?}"

        printf '### Capturas (paquetes)\n\n'
        printf '| Captura | Pcap | #pkts |\n|---------|------|-------|\n'
        local pcap n
        shopt -s nullglob
        for pcap in "${SMOKE_TMPDIR}"/cap_mac_*.pcap "${SMOKE_TMPDIR}"/cap_rpi_*.pcap; do
            n="$(_report_pkt_count "${pcap}")"
            printf '| %s | `%s` | %s |\n' \
                "$(basename "${pcap}" .pcap | sed 's/^cap_//')" \
                "${pcap}" "${n}"
        done
        shopt -u nullglob
        printf '\n'

        printf '### Tests\n\n'
        printf '| Test | Resultado |\n|------|-----------|\n'
        printf '| ping  | %s/%s recibidos |\n' "${TESTS_PING_RECEIVED:-?}" "${TESTS_PING_TOTAL:-?}"
        printf '| curl  | %s |\n' "${TESTS_CURL_RESULT:-no ejecutado}"
        printf '| throughput | %s |\n' "${TESTS_THROUGHPUT_RESULT:-no ejecutado}"
        printf '| nc UDP probe | %s |\n\n' "${TESTS_NC_UDP_RESULT:-no ejecutado}"

        printf '### utun usado\n\n%s\n\n' "${utun}"

        printf '### Diagnóstico automático\n\n'
        report_diagnose
    }
}

report_diagnose() {
    local mac_out=0 rpi_in=0 rpi_tun_out=0 mac_tun_in=0 pcap n
    shopt -s nullglob
    # Físicas Mac (en0/en8/en12 etc.) — explícito, evitando solapamiento
    # con utun*.
    for pcap in "${SMOKE_TMPDIR}"/cap_mac_en[0-9]*.pcap; do
        n="$(_report_pkt_count "${pcap}")"; mac_out=$((mac_out + n))
    done
    for pcap in "${SMOKE_TMPDIR}"/cap_rpi_eth*.pcap; do
        n="$(_report_pkt_count "${pcap}")"; rpi_in=$((rpi_in + n))
    done
    for pcap in "${SMOKE_TMPDIR}"/cap_rpi_ubond0*.pcap; do
        n="$(_report_pkt_count "${pcap}")"; rpi_tun_out=$((rpi_tun_out + n))
    done
    for pcap in "${SMOKE_TMPDIR}"/cap_mac_utun*.pcap; do
        n="$(_report_pkt_count "${pcap}")"; mac_tun_in=$((mac_tun_in + n))
    done
    shopt -u nullglob

    printf -- '- Mac UDP out (físicas): **%d** pkts\n' "${mac_out}"
    printf -- '- RPi UDP in  (5083-85): **%d** pkts\n' "${rpi_in}"
    printf -- '- RPi tun out (ubond0):  **%d** pkts\n' "${rpi_tun_out}"
    printf -- '- Mac utun in:           **%d** pkts\n\n' "${mac_tun_in}"

    if   (( mac_out == 0 ));        then printf '**Veredicto:** Mac no envía nada — ubond no autentica o socket no bind.\n'
    elif (( rpi_in == 0 ));         then printf '**Veredicto:** Mac envía pero RPi no recibe — filtrado en red (NAT/firewall) entre Mac y RPi.\n'
    elif (( rpi_tun_out == 0 ));    then printf '**Veredicto:** RPi recibe UDP pero NO escribe al tun — bug en ubond servidor (decrypt/dedup/reorder).\n'
    elif (( mac_tun_in == 0 ));     then printf '**Veredicto:** RPi escribe respuesta al tun pero Mac no la ve en utun — bug retorno (RPi→Mac).\n'
    else                                 printf '**Veredicto:** Paquetes fluyen en todas las capas — si ping falla aquí es kernel-side.\n'
    fi
}
