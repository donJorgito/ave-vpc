#!/usr/bin/env bash
###############################################################################
# tools/seleccionar-mejor-enlace.sh
#
# Watcher en background para modo --failover dinámico (REQ-NET-11, 14, 15).
# Cada 30 s mide RTT y pérdida de cada enlace al RPi y rota cuál es el
# "activo" (sin fallback_only) al de mejor score sostenido. Solo modifica
# `fallback_only` per-link en mlvpn_active.conf — nunca toca pesos WRR ni
# bandwidth_upload (eso desestabiliza mlvpn). SIGHUP a mlvpn [priv] para
# recargar config sin tirar el túnel.
#
# Reglas adicionales:
# - **REQ-NET-14: rotación inmediata si current_active está en `!`**
#   (AUTH_PENDING). Caso real visto 2026-05-25: iPhone configurado como
#   "activo" pero mlvpn no autenticó ese link (UDP filtrado o operador
#   caído); Pixel sí autenticado. El selector rota inmediatamente sin
#   esperar al gap≥20.
# - **REQ-NET-15: detección de flapping**. Si un link pasa de `@` a `!`
#   más de FLAP_THRESHOLD veces en FLAP_WINDOW_S segundos, lo excluye
#   automáticamente del pool hasta que esté `@` estable durante
#   FLAP_RECOVERY_S segundos. Caso real (WiFi del AVE 2026-05-25):
#   autentica → fluye tráfico → DPI/firewall corta → `!` → reintento →
#   ciclo. Excluirlo evita gastar CPU + datos en re-handshakes inútiles.
#
# Coste en datos: 1 ping ICMP × N enlaces cada 5 s ≈ 1.5 MB/día.
###############################################################################

# Necesita bash >=4 por los arrays asociativos (declare -A). macOS trae
# bash 3.2 en /bin/bash por defecto. Si el bash actual es viejo,
# relanzamos con el de Homebrew automáticamente.
if (( BASH_VERSINFO[0] < 4 )); then
    for try_bash in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        if [[ -x "${try_bash}" ]]; then
            exec "${try_bash}" "$0" "$@"
        fi
    done
    echo "ERROR: necesita bash >=4. Instalar: brew install bash" >&2
    exit 1
fi
# -o pipefail mantiene fallos en pipes; quitamos -u porque bash con
# `declare -A` y `set -u` da false positives en algunos contextos.
set -o pipefail

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

# Estado para detección de flapping (REQ-NET-15)
declare -A LAST_AUTH_STATE=( ["iphone"]="" ["pixel"]="" ["wifi"]="" )
declare -A FLAP_TIMESTAMPS=( ["iphone"]="" ["pixel"]="" ["wifi"]="" )
declare -A FLAP_EXCLUDED=( ["iphone"]=0 ["pixel"]=0 ["wifi"]=0 )
declare -A STABLE_SINCE=( ["iphone"]=0 ["pixel"]=0 ["wifi"]=0 )

WINDOW_SIZE=12       # 12 muestras × 5 s = 60 s de ventana RTT
EVAL_EVERY=6         # evaluar y rotar cada 6 ticks = 30 s
TICK_INTERVAL=5
MIN_SCORE_GAP=20     # diferencia mínima de score para rotar (histeresis)

# Flapping (REQ-NET-15)
FLAP_WINDOW_S=60     # ventana en la que contar transiciones @↔!
FLAP_THRESHOLD=4     # nº de transiciones para considerar flapping
FLAP_RECOVERY_S=30   # tiempo en `@` estable para reintegrar

log() { logger -t mlvpn-selector "$*"; }

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
        rtt_avg=9999
    else
        rtt_avg="$(awk -v s="${sum_rtt}" -v n="${got}" 'BEGIN{printf "%.0f", s/n}')"
    fi
    echo "${loss_pct} ${rtt_avg}"
}

# Score: mayor = mejor enlace
score_link() {
    local loss_pct="$1"
    local rtt_avg="$2"
    awk -v l="${loss_pct}" -v r="${rtt_avg}" 'BEGIN{
        s = 1000 - r - l*10
        if (s < 0) s = 0
        printf "%d", s
    }'
}

current_active_link() {
    local link
    for link in iphone pixel wifi; do
        if ! grep -q "^\[links.${link}\]" "${ACTIVE_CONF}" 2>/dev/null; then
            continue
        fi
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

    local priv_pid
    priv_pid="$(pgrep -f 'mlvpn: mlvpn0 \[priv\]' | head -1 || true)"
    if [[ -n "${priv_pid}" ]]; then
        kill -HUP "${priv_pid}" 2>/dev/null || true
    fi
}

# Devuelve los nombres de links autenticados (`@links.X`) en mlvpn proc name
authenticated_links() {
    pgrep -af "mlvpn: mlvpn0 @" 2>/dev/null \
        | head -1 \
        | grep -oE '@links\.[a-z]+' \
        | sed 's/@links\.//' || true
}

# REQ-NET-15: actualiza estado de flapping. Detecta transiciones @↔! y
# decide cuándo excluir/reintegrar links basado en su frecuencia de cambio.
update_flap_state() {
    local now auth_set
    now="$(date +%s)"
    auth_set="$(authenticated_links)"

    local link
    for link in iphone pixel wifi; do
        # Estado actual de auth para este link
        local now_auth="!"
        if echo "${auth_set}" | grep -qx "${link}"; then
            now_auth="@"
        fi

        local last="${LAST_AUTH_STATE[$link]:-}"

        # Detectar transición (ignorando primer tick donde last="")
        if [[ -n "${last}" && "${last}" != "${now_auth}" ]]; then
            # Registrar timestamp de la transición
            local ts="${FLAP_TIMESTAMPS[$link]:-}"
            if [[ -n "${ts}" ]]; then
                FLAP_TIMESTAMPS[$link]="${ts},${now}"
            else
                FLAP_TIMESTAMPS[$link]="${now}"
            fi

            # Si volvió a @, reset contador estabilidad
            if [[ "${now_auth}" == "@" ]]; then
                STABLE_SINCE[$link]="${now}"
            else
                STABLE_SINCE[$link]=0
            fi
        elif [[ "${now_auth}" == "@" && "${STABLE_SINCE[$link]:-0}" -eq 0 ]]; then
            # Primera vez que vemos @ → marcar inicio de estabilidad
            STABLE_SINCE[$link]="${now}"
        fi

        LAST_AUTH_STATE[$link]="${now_auth}"

        # Limpiar timestamps fuera de FLAP_WINDOW_S
        local recent="" arr_old=()
        local IFS=','
        read -r -a arr_old <<< "${FLAP_TIMESTAMPS[$link]:-}"
        for t in "${arr_old[@]}"; do
            [[ -z "${t}" ]] && continue
            if [[ $((now - t)) -lt ${FLAP_WINDOW_S} ]]; then
                if [[ -n "${recent}" ]]; then
                    recent="${recent},${t}"
                else
                    recent="${t}"
                fi
            fi
        done
        FLAP_TIMESTAMPS[$link]="${recent}"

        # Contar transiciones recientes
        local count=0
        IFS=','
        local arr_recent=()
        read -r -a arr_recent <<< "${FLAP_TIMESTAMPS[$link]}"
        for t in "${arr_recent[@]}"; do
            [[ -n "${t}" ]] && count=$((count + 1))
        done

        # Decidir transiciones de estado flapping
        if [[ "${FLAP_EXCLUDED[$link]:-0}" -eq 0 ]]; then
            # No excluido — ¿es momento de excluirlo?
            if [[ ${count} -ge ${FLAP_THRESHOLD} ]]; then
                FLAP_EXCLUDED[$link]=1
                STABLE_SINCE[$link]=0
                log "${link} flapping (${count} transiciones en ${FLAP_WINDOW_S}s) → excluido"
            fi
        else
            # Excluido — ¿es momento de reintegrarlo?
            local stable="${STABLE_SINCE[$link]:-0}"
            if [[ "${now_auth}" == "@" \
                  && ${stable} -gt 0 \
                  && $((now - stable)) -ge ${FLAP_RECOVERY_S} ]]; then
                FLAP_EXCLUDED[$link]=0
                FLAP_TIMESTAMPS[$link]=""
                log "${link} estable durante ${FLAP_RECOVERY_S}s → reintegrado"
            fi
        fi
    done
}

evaluate_and_rotate() {
    local link
    declare -A SCORE LOSS RTT
    local best_link=""
    local best_score=-1

    local auth_list
    auth_list="$(authenticated_links)"
    local consider_all=0
    [[ -z "${auth_list}" ]] && consider_all=1

    # Calcular score de cada link presente en config, autenticado y NO flapping
    for link in iphone pixel wifi; do
        if ! grep -q "^\[links.${link}\]" "${ACTIVE_CONF}" 2>/dev/null; then
            continue
        fi
        # REQ-NET-15: excluir links flapping
        if [[ "${FLAP_EXCLUDED[$link]:-0}" -eq 1 ]]; then
            continue
        fi
        # Excluir links no autenticados (a no ser que ninguno lo esté aún)
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

    # REQ-NET-14: ¿el current_active está autenticado a nivel mlvpn?
    local current_authed=0
    if [[ -n "${current}" ]] && echo "${auth_list}" | grep -qx "${current}"; then
        current_authed=1
    fi

    # ¿Hay que rotar?
    if [[ "${current}" == "${best_link}" ]]; then
        return  # ya estamos en el mejor
    fi

    local current_score=0
    if [[ -n "${current}" && -n "${SCORE[$current]:-}" ]]; then
        current_score="${SCORE[$current]}"
    fi
    local gap=$((best_score - current_score))

    local should_rotate=0
    local reason=""
    if [[ -z "${current}" ]]; then
        should_rotate=1
        reason="no hay activo"
    elif [[ ${current_authed} -eq 0 ]]; then
        # REQ-NET-14: current no autenticado → rotación inmediata
        should_rotate=1
        reason="current=${current} en ! AUTH_PENDING (REQ-NET-14)"
    elif [[ "${gap}" -ge "${MIN_SCORE_GAP}" ]]; then
        should_rotate=1
        reason="gap=${gap}"
    fi

    if [[ ${should_rotate} -eq 1 ]]; then
        local summary=""
        for link in iphone pixel wifi; do
            local marker="@"
            [[ "${FLAP_EXCLUDED[$link]:-0}" -eq 1 ]] && marker="FLAP"
            if [[ -n "${SCORE[$link]:-}" ]]; then
                summary+="${link}(${marker}):rtt=${RTT[$link]}ms loss=${LOSS[$link]}% score=${SCORE[$link]}; "
            fi
        done
        log "rotando ${current:-ninguno} → ${best_link} (${reason}; ${summary})"
        apply_winner "${best_link}"
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
    # REQ-NET-15: actualizar estado de flapping cada tick (no solo en eval)
    update_flap_state
    tick=$((tick + 1))
    if [[ $((tick % EVAL_EVERY)) -eq 0 ]]; then
        evaluate_and_rotate
    fi
    sleep "${TICK_INTERVAL}"
done
