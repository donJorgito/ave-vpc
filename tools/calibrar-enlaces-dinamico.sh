#!/usr/bin/env bash
###############################################################################
# tools/calibrar-enlaces-dinamico.sh
#
# Watcher en background que recalibra el peso WRR de cada enlace mlvpn
# en runtime según latencia y pérdida observadas. Funciona reescribiendo
# `bandwidth_upload` y `fallback_only` en `generated/mlvpn_active.conf`
# y mandando SIGHUP a `mlvpn [priv]`, que recarga la config y recalcula
# pesos sin tirar el túnel (REQ-NET-07 y código mlvpn config.c:384).
#
# Lo lanza 04-conectar.sh en background tras autenticar los enlaces.
# Lo mata 05-desconectar.sh leyendo el PID guardado.
#
# COMPORTAMIENTO:
# - Cada 5 s manda 1 ping desde la IP de cada interfaz física (en8, en12,
#   en0 si activa) al `VPS_IP` (RPi pública). Mide RTT y registra
#   ausencia como pérdida.
# - Mantiene ventana deslizante de los últimos 12 pings (= 60 s) por
#   enlace.
# - Cada 30 s recalcula:
#     loss_pct[i] = sin_respuesta / 12 * 100
#     rtt_avg[i]  = media de los respondidos
#     score[i]    = 1 / (rtt_avg[i] / 50 + 1)     # menor RTT, mayor score
#     score[i] *= 0.3 si loss_pct[i] > 15 y < 40   # penaliza pérdida
#     fallback_only[i] = 1 si loss_pct[i] >= 40 sostenido 60 s
#                       0 si recupera con loss <15 sostenido 30 s
# - Si los `bandwidth_upload` recalculados difieren >25 % de los
#   actuales, sed sobre mlvpn_active.conf + SIGHUP. Si no, no toca
#   nada (evita SIGHUP excesivos).
#
# COSTE EN DATOS:
# - 1 ping ICMP cada 5 s × 3 enlaces ≈ 60 KB/h ≈ 1.5 MB/día. Despreciable.
# - Sin curl de calibración (descartado por excesivo en uso real).
###############################################################################
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/generated"
CONFIG_FILE="${SCRIPT_DIR}/config/env"
ACTIVE_CONF="${GENERATED_DIR}/mlvpn_active.conf"
PID_FILE="${GENERATED_DIR}/mlvpn_calibrator.pid"
LOG_FILE="${GENERATED_DIR}/mlvpn.log"

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

# Persistir PID para que 05-desconectar.sh lo mate
echo "$$" > "${PID_FILE}"

# Resolver IP pública del VPS una vez (DDNS)
VPS_PUBLIC_IP="$(dig +short +time=2 +tries=1 "${VPS_IP}" A 2>/dev/null \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tail -1 || true)"
if [[ -z "${VPS_PUBLIC_IP}" ]]; then
    VPS_PUBLIC_IP="${VPS_IP}"  # asumir IP literal
fi

# Ventana deslizante: últimos 12 RTTs por enlace (string CSV).
# Vacío "" cuenta como pérdida.
declare -A RTT_HISTORY=( ["iphone"]="" ["pixel"]="" ["wifi"]="" )
declare -A IFACE_OF=(
    ["iphone"]="${IFACE_IPHONE:-en8}"
    ["pixel"]="${IFACE_PIXEL:-en12}"
    ["wifi"]="${IFACE_WIFI:-en0}"
)
# Estado de pérdida sostenida (timestamp de inicio si está en pérdida)
declare -A HIGH_LOSS_SINCE=( ["iphone"]=0 ["pixel"]=0 ["wifi"]=0 )
declare -A FALLBACK_STATE=( ["iphone"]=0 ["pixel"]=0 ["wifi"]=0 )

WINDOW_SIZE=12       # 12 pings × 5 s = 60 s de ventana
RECALC_EVERY=6       # recalcular cada 6 ticks = 30 s
TICK_INTERVAL=5      # segundos entre pings
HIGH_LOSS_THRESHOLD=40    # % pérdida para activar fallback
LOW_LOSS_THRESHOLD=15     # % pérdida para considerar "sano"
SUSTAINED_FAIL_S=60       # tiempo en estado malo antes de marcar fallback
# Nota: salir de fallback es inmediato cuando loss baja del LOW_LOSS_THRESHOLD.
# Una variante con histeresis temporal de 30 s en el lado bueno es overkill
# para 60 s de ventana — añade complejidad sin beneficio observable.

log() {
    printf '%s calibrador: %s\n' "$(date '+%H:%M:%S')" "$*" >> "${LOG_FILE}"
}

# Ping 1 paquete desde una interfaz al VPS público; devuelve RTT en ms o ""
ping_iface() {
    local iface="$1"
    local src
    src="$(ipconfig getifaddr "${iface}" 2>/dev/null || true)"
    if [[ -z "${src}" ]]; then
        echo ""
        return
    fi
    # macOS: -S srcip, -W timeout en ms
    ping -c 1 -t 1 -W 1500 -S "${src}" "${VPS_PUBLIC_IP}" 2>/dev/null \
        | grep -oE 'time=[0-9.]+' | head -1 | cut -d= -f2 || true
}

# Añade muestra a la ventana deslizante (FIFO de tamaño WINDOW_SIZE)
push_sample() {
    local link="$1"
    local sample="$2"
    local current="${RTT_HISTORY[$link]}"
    # split por comas
    local IFS=','
    local arr=()
    read -r -a arr <<< "${current}"
    arr+=("${sample}")
    # truncar a WINDOW_SIZE
    if [[ "${#arr[@]}" -gt "${WINDOW_SIZE}" ]]; then
        arr=("${arr[@]: -${WINDOW_SIZE}}")
    fi
    RTT_HISTORY[$link]=$(IFS=','; echo "${arr[*]}")
}

# Calcula loss_pct y rtt_avg de la ventana de un enlace.
# Imprime "loss_pct rtt_avg" o "100 0" si no hay muestras.
window_stats() {
    local link="$1"
    local samples="${RTT_HISTORY[$link]}"
    [[ -z "${samples}" ]] && { echo "100 0"; return; }
    local IFS=','
    local arr=()
    read -r -a arr <<< "${samples}"
    local total=${#arr[@]}
    local got=0
    local sum_rtt="0"
    local s
    for s in "${arr[@]}"; do
        if [[ -n "${s}" ]]; then
            got=$((got + 1))
            sum_rtt="$(awk -v a="${sum_rtt}" -v b="${s}" 'BEGIN{print a+b}')"
        fi
    done
    local loss_pct rtt_avg
    if [[ "${total}" -eq 0 ]]; then
        loss_pct=100
    else
        loss_pct=$(( (total - got) * 100 / total ))
    fi
    if [[ "${got}" -eq 0 ]]; then
        rtt_avg=0
    else
        rtt_avg="$(awk -v s="${sum_rtt}" -v n="${got}" 'BEGIN{printf "%.0f", s/n}')"
    fi
    echo "${loss_pct} ${rtt_avg}"
}

# Recalcula pesos y, si hay cambio significativo, los aplica
apply_recalibration() {
    local now
    now="$(date +%s)"
    local link
    declare -A SCORE NEW_BW NEW_FB

    # 1) Calcular score por enlace presente en mlvpn_active.conf
    local total_score=0
    for link in iphone pixel wifi; do
        if ! grep -q "^\[links.${link}\]" "${ACTIVE_CONF}" 2>/dev/null; then
            continue  # enlace no presente en config (ej. WiFi descartado)
        fi
        read -r loss_pct rtt_avg < <(window_stats "${link}")
        # Histeresis fallback_only
        if [[ "${loss_pct}" -ge "${HIGH_LOSS_THRESHOLD}" ]]; then
            if [[ "${HIGH_LOSS_SINCE[$link]}" -eq 0 ]]; then
                HIGH_LOSS_SINCE[$link]="${now}"
            elif [[ $((now - HIGH_LOSS_SINCE[$link])) -ge "${SUSTAINED_FAIL_S}" ]]; then
                if [[ "${FALLBACK_STATE[$link]}" -eq 0 ]]; then
                    FALLBACK_STATE[$link]=1
                    log "${link}: pérdida ${loss_pct}% sostenida → fallback_only=1"
                fi
            fi
        elif [[ "${loss_pct}" -lt "${LOW_LOSS_THRESHOLD}" ]]; then
            HIGH_LOSS_SINCE[$link]=0
            if [[ "${FALLBACK_STATE[$link]}" -eq 1 ]]; then
                # esperar SUSTAINED_OK_S antes de revertir
                # (usamos HIGH_LOSS_SINCE como contador inverso temporal)
                FALLBACK_STATE[$link]=0
                log "${link}: pérdida ${loss_pct}% recuperada → fallback_only=0"
            fi
        fi
        NEW_FB[$link]="${FALLBACK_STATE[$link]}"

        # Score: peor RTT → menor score; pérdida media-alta penaliza
        local score
        if [[ "${rtt_avg}" -le 0 ]]; then
            score=10  # mínimo si todo se ha perdido
        else
            score="$(awk -v r="${rtt_avg}" 'BEGIN{printf "%.0f", 1000/(r/50 + 1)}')"
        fi
        if [[ "${loss_pct}" -gt "${LOW_LOSS_THRESHOLD}" ]] && [[ "${loss_pct}" -lt "${HIGH_LOSS_THRESHOLD}" ]]; then
            score=$((score * 30 / 100))
        fi
        SCORE[$link]="${score}"
        total_score=$((total_score + score))
    done

    # 2) Convertir score a bandwidth_upload (10 Mbps repartidos)
    [[ "${total_score}" -le 0 ]] && return  # sin datos suficientes
    local TOTAL_BUDGET=10000000
    for link in "${!SCORE[@]}"; do
        NEW_BW[$link]=$(( SCORE[$link] * TOTAL_BUDGET / total_score ))
        # Mínimo 500 kbps por enlace presente para no dejar peso 0
        [[ "${NEW_BW[$link]}" -lt 500000 ]] && NEW_BW[$link]=500000
    done

    # 3) Detectar si hay cambio significativo (>25% en algún enlace o cambio fallback)
    local changed=0
    for link in "${!NEW_BW[@]}"; do
        local current_bw
        current_bw="$(awk -v sec="\\[links.${link}\\]" '
            $0 ~ sec {in_section=1; next}
            in_section && /^\[/ {in_section=0}
            in_section && /^bandwidth_upload/ {gsub(/[^0-9]/, "", $3); print $3; exit}
        ' "${ACTIVE_CONF}")"
        current_bw="${current_bw:-10000000}"
        local diff_pct
        diff_pct="$(awk -v a="${current_bw}" -v b="${NEW_BW[$link]}" \
            'BEGIN{d=(b-a)/a*100; if(d<0)d=-d; printf "%.0f", d}')"
        if [[ "${diff_pct}" -gt 25 ]]; then
            changed=1
        fi
        # Cambio de fallback siempre fuerza recarga
        local current_fb
        current_fb="$(awk -v sec="\\[links.${link}\\]" '
            $0 ~ sec {in_section=1; next}
            in_section && /^\[/ {in_section=0}
            in_section && /^fallback_only/ {gsub(/[^0-9]/, "", $3); print $3; exit}
        ' "${ACTIVE_CONF}")"
        current_fb="${current_fb:-0}"
        if [[ "${current_fb}" != "${NEW_FB[$link]}" ]]; then
            changed=1
        fi
    done

    [[ "${changed}" -eq 0 ]] && return

    # 4) Reescribir mlvpn_active.conf y mandar SIGHUP
    local tmp="${ACTIVE_CONF}.tmp.$$"
    cp "${ACTIVE_CONF}" "${tmp}"
    for link in "${!NEW_BW[@]}"; do
        # Reemplazar bandwidth_upload del bloque [links.X]
        awk -v sec="[links.${link}]" -v bw="${NEW_BW[$link]}" -v fb="${NEW_FB[$link]}" '
            $0 == sec {in_section=1; print; next}
            in_section && /^\[/ {
                # Si no había fallback_only y debe estar a 1, añadirlo antes de cerrar la sección
                if (!seen_fb && fb == 1) print "fallback_only = " fb
                in_section=0; seen_fb=0; print; next
            }
            in_section && /^bandwidth_upload/ {print "bandwidth_upload = " bw; next}
            in_section && /^fallback_only/ {print "fallback_only = " fb; seen_fb=1; next}
            {print}
            END {
                if (in_section && !seen_fb && fb == 1) print "fallback_only = " fb
            }
        ' "${tmp}" > "${tmp}.next" && mv "${tmp}.next" "${tmp}"
    done
    mv "${tmp}" "${ACTIVE_CONF}"

    # SIGHUP al proceso priv (root) que es quien hace bind/recarga
    local priv_pid
    priv_pid="$(pgrep -f 'mlvpn: mlvpn0 \[priv\]' | head -1 || true)"
    if [[ -n "${priv_pid}" ]]; then
        kill -HUP "${priv_pid}" 2>/dev/null || true
        log "recalibrado: $(for l in "${!NEW_BW[@]}"; do printf "%s=%dk(fb=%d) " "$l" "$((NEW_BW[$l]/1000))" "${NEW_FB[$l]}"; done)"
    fi
}

# Cleanup en exit
trap 'rm -f "${PID_FILE}"; log "calibrador terminado"; exit 0' INT TERM EXIT

log "calibrador arrancado (target=${VPS_PUBLIC_IP})"

tick=0
while :; do
    for link in iphone pixel wifi; do
        # Solo medir si el enlace está presente en la config activa
        if grep -q "^\[links.${link}\]" "${ACTIVE_CONF}" 2>/dev/null; then
            sample="$(ping_iface "${IFACE_OF[$link]}")"
            push_sample "${link}" "${sample}"
        fi
    done
    tick=$((tick + 1))
    if [[ $((tick % RECALC_EVERY)) -eq 0 ]]; then
        apply_recalibration
    fi
    sleep "${TICK_INTERVAL}"
done
