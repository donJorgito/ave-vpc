#!/usr/bin/env bash
###############################################################################
# tools/seleccionar-mejor-enlace.sh
#
# Watcher en background para modo --failover dinámico (REQ-NET-11).
# Cada 30 s mide RTT y pérdida de cada enlace al RPi y rota cuál es
# el "activo" (sin fallback_only) al que tiene mejor score sostenido.
# Solo modifica `fallback_only` per-link en mlvpn_active.conf — nunca
# toca pesos WRR ni bandwidth_upload (eso desestabiliza mlvpn).
# SIGHUP a mlvpn [priv] para recargar config sin tirar el túnel.
#
# Diferencia con tools/calibrar-enlaces-dinamico.sh (REQ-NET-10,
# desactivado): aquel reescribía bandwidth_upload cada 30 s causando
# inestabilidad. Éste solo cambia el role activo↔backup, mucho menos
# agresivo y con histeresis fuerte.
#
# Coste en datos: 1 ping ICMP × N enlaces cada 5 s ≈ 1.5 MB/día.
###############################################################################
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/generated"
CONFIG_FILE="${SCRIPT_DIR}/config/env"
ACTIVE_CONF="${GENERATED_DIR}/mlvpn_active.conf"
PID_FILE="${GENERATED_DIR}/mlvpn_failover_selector.pid"

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

echo "$$" > "${PID_FILE}"

VPS_PUBLIC_IP="$(dig +short +time=2 +tries=1 "${VPS_IP}" A 2>/dev/null \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tail -1 || true)"
[[ -z "${VPS_PUBLIC_IP}" ]] && VPS_PUBLIC_IP="${VPS_IP}"

declare -A IFACE_OF=(
    ["iphone"]="${IFACE_IPHONE:-en8}"
    ["pixel"]="${IFACE_PIXEL:-en12}"
    ["wifi"]="${IFACE_WIFI:-en0}"
)
declare -A RTT_HISTORY=( ["iphone"]="" ["pixel"]="" ["wifi"]="" )

WINDOW_SIZE=12       # 12 muestras × 5 s = 60 s de ventana
EVAL_EVERY=6         # evaluar y rotar cada 6 ticks = 30 s
TICK_INTERVAL=5
MIN_SCORE_GAP=20     # diferencia mínima de score para rotar (histeresis)

log() {
    # Mandamos a syslog (Apple Unified Log) en lugar de a un fichero
    # propio. Consistencia: mlvpn ya manda sus logs ahí. Se ve con:
    #   log stream --predicate 'process == "mlvpn-selector"' --info
    logger -t mlvpn-selector "$*"
}

ping_iface() {
    local iface="$1"
    local src
    src="$(ipconfig getifaddr "${iface}" 2>/dev/null || true)"
    [[ -z "${src}" ]] && { echo ""; return; }
    ping -c 1 -t 1 -W 1500 -S "${src}" "${VPS_PUBLIC_IP}" 2>/dev/null \
        | grep -oE 'time=[0-9.]+' | head -1 | cut -d= -f2 || true
}

push_sample() {
    local link="$1"
    local sample="$2"
    local current="${RTT_HISTORY[$link]}"
    local IFS=','
    local arr=()
    read -r -a arr <<< "${current}"
    arr+=("${sample}")
    if [[ "${#arr[@]}" -gt "${WINDOW_SIZE}" ]]; then
        arr=("${arr[@]: -${WINDOW_SIZE}}")
    fi
    RTT_HISTORY[$link]=$(IFS=','; echo "${arr[*]}")
}

# Imprime "loss_pct rtt_avg" para un enlace
window_stats() {
    local link="$1"
    local samples="${RTT_HISTORY[$link]}"
    [[ -z "${samples}" ]] && { echo "100 9999"; return; }
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
        rtt_avg=9999  # peor caso si todo se perdió
    else
        rtt_avg="$(awk -v s="${sum_rtt}" -v n="${got}" 'BEGIN{printf "%.0f", s/n}')"
    fi
    echo "${loss_pct} ${rtt_avg}"
}

# Calcula score: mayor score = mejor enlace
# score = 1000 - rtt_avg - loss_pct*10  (penaliza pérdida fuerte)
score_link() {
    local loss_pct="$1"
    local rtt_avg="$2"
    awk -v l="${loss_pct}" -v r="${rtt_avg}" 'BEGIN{
        s = 1000 - r - l*10
        if (s < 0) s = 0
        printf "%d", s
    }'
}

# Identifica qué link es actualmente "activo" (sin fallback_only=1)
current_active_link() {
    local link
    for link in iphone pixel wifi; do
        if ! grep -q "^\[links.${link}\]" "${ACTIVE_CONF}" 2>/dev/null; then
            continue
        fi
        # ¿Tiene fallback_only=1 dentro de su bloque?
        local fb
        fb="$(awk -v sec="\\[links.${link}\\]" '
            $0 ~ sec {in_section=1; next}
            in_section && /^\[/ {in_section=0}
            in_section && /^fallback_only/ {gsub(/[^0-9]/, "", $3); print $3; exit}
        ' "${ACTIVE_CONF}")"
        if [[ "${fb:-0}" -eq 0 ]]; then
            echo "${link}"
            return 0
        fi
    done
    echo ""
}

# Reescribe la config: marca SOLO el link `winner` como activo
# (sin fallback_only) y los demás con fallback_only=1
apply_winner() {
    local winner="$1"
    local tmp="${ACTIVE_CONF}.tmp.$$"
    local link
    cp "${ACTIVE_CONF}" "${tmp}"
    for link in iphone pixel wifi; do
        if ! grep -q "^\[links.${link}\]" "${tmp}"; then
            continue
        fi
        local fb_target
        if [[ "${link}" == "${winner}" ]]; then
            fb_target=0
        else
            fb_target=1
        fi
        awk -v sec="[links.${link}]" -v fb="${fb_target}" '
            $0 == sec {in_section=1; print; seen_fb=0; next}
            in_section && /^\[/ {
                if (!seen_fb) print "fallback_only = " fb
                in_section=0; seen_fb=0; print; next
            }
            in_section && /^fallback_only/ {print "fallback_only = " fb; seen_fb=1; next}
            {print}
            END { if (in_section && !seen_fb) print "fallback_only = " fb }
        ' "${tmp}" > "${tmp}.next" && mv "${tmp}.next" "${tmp}"
    done
    mv "${tmp}" "${ACTIVE_CONF}"
    chmod 600 "${ACTIVE_CONF}"

    # SIGHUP a mlvpn [priv]
    local priv_pid
    priv_pid="$(pgrep -f 'mlvpn: mlvpn0 \[priv\]' | head -1 || true)"
    if [[ -n "${priv_pid}" ]]; then
        kill -HUP "${priv_pid}" 2>/dev/null || true
    fi
}

# Devuelve los nombres de los links autenticados a nivel mlvpn (UDP del
# túnel atraviesa y handshake OK). mlvpn pone el nombre del proceso así:
#   "mlvpn: mlvpn0 @links.iphone @links.pixel !links.wifi"
# @ = autenticado, ! = AUTH_PENDING. Los ! se EXCLUYEN del cómputo:
# pueden tener buen ping ICMP pero el UDP del túnel está filtrado
# (típico WiFi público restrictivo del AVE bloqueando el puerto 5082).
authenticated_links() {
    pgrep -af "mlvpn: mlvpn0 @" 2>/dev/null \
        | head -1 \
        | grep -oE '@links\.[a-z]+' \
        | sed 's/@links\.//' || true
}

evaluate_and_rotate() {
    local link
    declare -A SCORE
    declare -A LOSS
    declare -A RTT
    local best_link=""
    local best_score=-1

    # Set de links autenticados (mlvpn handshake OK). Si mlvpn aún no
    # los marcó (arranque temprano), aceptamos todos para no quedarnos
    # sin candidato.
    local auth_list
    auth_list="$(authenticated_links)"
    local consider_all=0
    [[ -z "${auth_list}" ]] && consider_all=1

    # Calcular score de cada link presente en config Y autenticado
    for link in iphone pixel wifi; do
        if ! grep -q "^\[links.${link}\]" "${ACTIVE_CONF}" 2>/dev/null; then
            continue
        fi
        # Excluir links no autenticados (ej. WiFi con UDP filtrado)
        if [[ "${consider_all}" -eq 0 ]] \
           && ! echo "${auth_list}" | grep -qx "${link}"; then
            continue
        fi
        read -r loss rtt < <(window_stats "${link}")
        SCORE[$link]="$(score_link "${loss}" "${rtt}")"
        LOSS[$link]="${loss}"
        RTT[$link]="${rtt}"
        if [[ "${SCORE[$link]}" -gt "${best_score}" ]]; then
            best_score="${SCORE[$link]}"
            best_link="${link}"
        fi
    done

    [[ -z "${best_link}" ]] && return

    local current
    current="$(current_active_link)"

    # Si no hay activo definido o cambia el ganador con margen suficiente
    if [[ -z "${current}" ]] || [[ "${current}" != "${best_link}" ]]; then
        local current_score=0
        if [[ -n "${current}" && -n "${SCORE[$current]:-}" ]]; then
            current_score="${SCORE[$current]}"
        fi
        local gap=$((best_score - current_score))
        if [[ "${gap}" -ge "${MIN_SCORE_GAP}" ]] || [[ -z "${current}" ]]; then
            local summary=""
            for link in iphone pixel wifi; do
                if [[ -n "${SCORE[$link]:-}" ]]; then
                    summary+="${link}:rtt=${RTT[$link]}ms loss=${LOSS[$link]}% score=${SCORE[$link]}; "
                fi
            done
            log "rotando activo ${current:-ninguno} → ${best_link} (${summary})"
            apply_winner "${best_link}"
        fi
    fi
}

trap 'rm -f "${PID_FILE}"; log "selector terminado"; exit 0' INT TERM EXIT

log "selector arrancado (target=${VPS_PUBLIC_IP}, eval cada $((TICK_INTERVAL * EVAL_EVERY))s)"

tick=0
while :; do
    for link in iphone pixel wifi; do
        if grep -q "^\[links.${link}\]" "${ACTIVE_CONF}" 2>/dev/null; then
            sample="$(ping_iface "${IFACE_OF[$link]}")"
            push_sample "${link}" "${sample}"
        fi
    done
    tick=$((tick + 1))
    if [[ $((tick % EVAL_EVERY)) -eq 0 ]]; then
        evaluate_and_rotate
    fi
    sleep "${TICK_INTERVAL}"
done
