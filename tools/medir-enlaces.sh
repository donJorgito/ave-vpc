#!/usr/bin/env bash
###############################################################################
# tools/medir-enlaces.sh
#
# Mide BW de bajada, latencia, jitter y pérdida de cada enlace físico
# (iPhone, Pixel, WiFi) por separado, y opcionalmente del túnel mlvpn
# si está activo. Etiqueta cada medición con un nombre libre (ubicación)
# para poder agregar después.
#
# Uso:
#   ./tools/medir-enlaces.sh <etiqueta>
#
# Ejemplos:
#   ./tools/medir-enlaces.sh estacion-orihuela
#   ./tools/medir-enlaces.sh ave-km150
#   ./tools/medir-enlaces.sh oficina-roche
#   ./tools/medir-enlaces.sh casa-salon
#
# Resultados:
#   generated/measurements/<timestamp>_<etiqueta>.csv  — datos crudos
#   generated/measurements/all.csv                     — agregado append-only
#
# Para resumen agregado tras N mediciones:
#   ./tools/medir-enlaces.sh --resumen
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${SCRIPT_DIR}/generated/measurements"
ALL_CSV="${OUT_DIR}/all.csv"
DOWN_URL="https://speed.cloudflare.com/__down?bytes=10000000"

mkdir -p "${OUT_DIR}"

# Crear cabecera del CSV agregado si no existe
if [[ ! -f "${ALL_CSV}" ]]; then
    echo "label,timestamp,iface,name,ip,down_bps,latency_avg_ms,latency_stddev_ms,loss_pct" > "${ALL_CSV}"
fi

# --- Modo resumen: promediar mediciones existentes ---
if [[ "${1:-}" == "--resumen" ]] || [[ "${1:-}" == "-r" ]]; then
    if [[ ! -s "${ALL_CSV}" ]] || [[ "$(wc -l <"${ALL_CSV}")" -lt 2 ]]; then
        echo "Sin mediciones todavía. Ejecuta primero ./tools/medir-enlaces.sh <etiqueta>"
        exit 0
    fi
    echo "=== Resumen de $(($(wc -l <"${ALL_CSV}") - 1)) mediciones en ${ALL_CSV} ==="
    echo ""
    awk -F',' 'NR > 1 && $4 != "" {
        n[$4]++
        sum_down[$4] += $6
        sum_lat[$4] += $7
        sum_loss[$4] += $9
        if ($6 > max_down[$4]) max_down[$4] = $6
        if (min_down[$4] == 0 || $6 < min_down[$4]) min_down[$4] = $6
    }
    END {
        printf "  %-10s %-10s %-10s %-10s %-10s %-10s\n", "Enlace", "n", "Down avg", "Down min", "Down max", "Loss avg"
        for (name in n) {
            printf "  %-10s %-10d %-10.0f %-10.0f %-10.0f %-9.1f%%\n",
                name, n[name],
                sum_down[name]/n[name]/1000,
                min_down[name]/1000,
                max_down[name]/1000,
                sum_loss[name]/n[name]
        }
    }' "${ALL_CSV}"
    echo ""
    echo "  (Down en KB/s)"
    echo ""
    echo "Sugerencia bandwidth_upload (75 % del avg) — copiar a 03-setup-mac.sh:"
    awk -F',' 'NR > 1 && $4 != "" {
        n[$4]++; sum[$4] += $6
    }
    END {
        for (name in n) {
            avg = sum[name]/n[name]
            # Convertir bajada a subida estimada (típico 4G: subida ~ bajada/2)
            up_est = avg * 0.5 * 0.75
            printf "  links.%-10s bandwidth_upload = %d   # 75%% de subida estimada (avg bajada %.0f KB/s)\n",
                tolower(name) ":", up_est, avg/1000
        }
    }' "${ALL_CSV}"
    exit 0
fi

LABEL="${1:-}"
if [[ -z "${LABEL}" ]]; then
    echo "Falta etiqueta. Ej: ./tools/medir-enlaces.sh estacion-orihuela"
    echo "       ./tools/medir-enlaces.sh --resumen   (promedio de mediciones)"
    exit 1
fi

# Sanear etiqueta para nombre de fichero
LABEL_SAFE="$(echo "${LABEL}" | tr '/ ' '__' | tr -cd '[:alnum:]._-')"
TIMESTAMP="$(date -u +"%Y%m%dT%H%M%SZ")"
OUT_FILE="${OUT_DIR}/${TIMESTAMP}_${LABEL_SAFE}.csv"
echo "label,timestamp,iface,name,ip,down_bps,latency_avg_ms,latency_stddev_ms,loss_pct" > "${OUT_FILE}"

# Cargar config para nombres de interfaz
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/config/env"

# --- Función: medir un enlace concreto ---
# Args: iface, name
measure_iface() {
    local iface="$1"
    local name="$2"
    local ip down_bps ping_out latency_avg latency_stddev loss_pct
    ip="$(ipconfig getifaddr "${iface}" 2>/dev/null || true)"
    if [[ -z "${ip}" ]]; then
        printf "  %-8s %-6s sin IP\n" "${name}" "${iface}"
        return
    fi

    # Bajada — 10 MB con timeout 10s
    down_bps="$(curl --interface "${iface}" -s --max-time 10 -o /dev/null \
        -w "%{speed_download}" "${DOWN_URL}" 2>/dev/null || echo "0")"
    down_bps="${down_bps%.*}"  # quitar parte decimal

    # Latencia + jitter (5 paquetes, intervalo 0.3s, timeout 1.5s c/u)
    ping_out="$(ping -c 5 -i 0.3 -W 1500 -b "${iface}" 1.1.1.1 2>&1 || true)"
    loss_pct="$(echo "${ping_out}" | grep -oE '[0-9.]+% packet loss' | grep -oE '^[0-9.]+' || echo "100")"
    if echo "${ping_out}" | grep -q "min/avg/max"; then
        latency_avg="$(echo "${ping_out}" | grep "min/avg" | awk -F'=' '{print $2}' | awk -F'/' '{print $2}' | tr -d ' ')"
        latency_stddev="$(echo "${ping_out}" | grep "min/avg" | awk -F'=' '{print $2}' | awk -F'/' '{print $5}' | awk '{print $1}' | tr -d ' ms')"
    else
        latency_avg=""
        latency_stddev=""
    fi

    printf "  %-8s %-6s %-15s  %5d KB/s  lat %s ms ±%s ms  loss %s%%\n" \
        "${name}" "${iface}" "${ip}" \
        "$((down_bps / 1000))" \
        "${latency_avg:-?}" "${latency_stddev:-?}" "${loss_pct}"

    echo "${LABEL},${TIMESTAMP},${iface},${name},${ip},${down_bps},${latency_avg},${latency_stddev},${loss_pct}" \
        | tee -a "${OUT_FILE}" >> "${ALL_CSV}"
}

echo "=== Medición de enlaces — ${LABEL} (${TIMESTAMP}) ==="
echo ""
measure_iface "${IFACE_IPHONE:-en8}" "iPhone"
measure_iface "${IFACE_PIXEL:-en12}" "Pixel"
measure_iface "${IFACE_WIFI:-en0}"  "WiFi"

# Si mlvpn está activo, medir también el túnel
if pgrep -f "mlvpn: mlvpn0 @" &>/dev/null; then
    echo ""
    echo "=== Túnel activo — midiendo throughput agregado ==="
    tunel_bps="$(curl -s --max-time 10 -o /dev/null \
        -w "%{speed_download}" "${DOWN_URL}" 2>/dev/null || echo "0")"
    tunel_bps="${tunel_bps%.*}"
    tunel_lat="$(ping -c 5 -W 2000 10.10.10.1 2>&1 | grep "min/avg" | awk -F'=' '{print $2}' | awk -F'/' '{print $2}' | tr -d ' ' || echo "?")"
    printf "  Túnel    bajada %5d KB/s  RPi RTT %s ms\n" \
        "$((tunel_bps / 1000))" "${tunel_lat:-?}"
    echo "${LABEL},${TIMESTAMP},mlvpn0,Tunel,10.10.10.2,${tunel_bps},${tunel_lat},," \
        | tee -a "${OUT_FILE}" >> "${ALL_CSV}"
fi

echo ""
echo "Guardado en: ${OUT_FILE}"
echo "Resumen agregado tras varias mediciones: ./tools/medir-enlaces.sh --resumen"
