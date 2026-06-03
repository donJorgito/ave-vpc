#!/usr/bin/env bash
# tools/ave-monitor.sh — monitor continuo del cliente ubond v2 en AVE
#
# Observa estado de links, cobertura física, salud del túnel, tráfico real,
# throughput, eventos del binario ubond, watchdog y SOS, sistema. NO actúa
# (eso es trabajo del watchdog) — solo registra para diagnóstico ALCOA++.
#
# Uso:
#   sudo ./tools/ave-monitor.sh                  # foreground tty
#   sudo ./tools/ave-monitor.sh --background     # detached
#   sudo ./tools/ave-monitor.sh --tick 5         # override tick s
#   sudo ./tools/ave-monitor.sh --no-throughput  # desactiva muestras descarga
#
# Salidas (en generated/):
#   ave-monitor-<startISO>.ndjson  — una línea por tick (estructurado)
#   ave-monitor-<startISO>.log     — bloques expandidos + raw events
#   ave-monitor.ndjson             — symlink a la última .ndjson
#   ave-monitor.pid                — pid del proceso vivo
#
# Antipatrones evitados (lecciones project_session_lag_fix.md, watchdog):
#   - Ping siempre con `-b utunN` (subnet 10.10.20/24 colisiona en redes
#     corporativas). Verificación de TTL como cinturón de seguridad.
#   - DNS sólo a 1.1.1.1 con `dig @1.1.1.1`; system DNS prohibido en AVE.
#   - `--max-time` en cada curl para no bloquear el tick.
#   - Offsets persistidos en lugar de `tail -f`; append por línea con flush.

set -uo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)/_common.sh"
# shellcheck disable=SC1091
source "${AVEVPC_ROOT}/tools/lib/env-detect.sh"

_LOG_PREFIX="monitor"

# ----------------------------------------------------------------------------
# Configuración por defecto y CLI
# ----------------------------------------------------------------------------
TICK_S=10
THROUGHPUT_EVERY=6        # cada 6 ticks (~60s)
EXPANDED_EVERY=30         # bloque expandido cada 30 ticks (~5min)
DNS_REFRESH_S=60
ROTATE_BYTES=$((10*1024*1024))
ENABLE_THROUGHPUT=1
BACKGROUND=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tick)            TICK_S="${2:?}"; shift 2 ;;
        --background|-b)   BACKGROUND=1; shift ;;
        --no-throughput)   ENABLE_THROUGHPUT=0; shift ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) die 1 "argumento desconocido: $1" ;;
    esac
done

require_root "$@"
require_cmd ifconfig
require_cmd ipconfig
require_cmd ping
require_cmd curl
require_cmd awk
require_cmd pgrep

env_detect_load_config
: "${UBOND_TUN_MAC_IP:?}"; : "${UBOND_TUN_VPS_IP:?}"
: "${IFACE_IPHONE:?}"; : "${IFACE_PIXEL:?}"; : "${IFACE_WIFI:?}"
: "${VPS_IP:?}"

GEN_DIR="${AVEVPC_ROOT}/generated"
mkdir -p "${GEN_DIR}"

START_ISO="$(date +%Y%m%dT%H%M%S%z)"
NDJSON="${GEN_DIR}/ave-monitor-${START_ISO}.ndjson"
RAWLOG="${GEN_DIR}/ave-monitor-${START_ISO}.log"
NDJSON_LATEST="${GEN_DIR}/ave-monitor.ndjson"
PIDFILE="${GEN_DIR}/ave-monitor.pid"

UBOND_LOG="${GEN_DIR}/ubond.log"
WATCHDOG_LOG="${GEN_DIR}/ubond_watchdog.log"
HEALTH_FLAG="${GEN_DIR}/ubond_unhealthy"

# Re-exec en background sin mantener tty (modo --background).
if [[ "${BACKGROUND}" == "1" ]]; then
    log_info "lanzando en background, logs en ${NDJSON}"
    bg_args=(--tick "${TICK_S}")
    [[ "${ENABLE_THROUGHPUT}" == "0" ]] && bg_args+=(--no-throughput)
    nohup "$0" "${bg_args[@]}" >>"${RAWLOG}" 2>&1 &
    disown || true
    echo "$!" >"${PIDFILE}"
    exit 0
fi

# ----------------------------------------------------------------------------
# Ficheros de salida (append-only, chmod 600 por contenido sensible)
# ----------------------------------------------------------------------------
: >>"${NDJSON}"; chmod 600 "${NDJSON}"
: >>"${RAWLOG}"; chmod 600 "${RAWLOG}"
ln -sfn "$(basename "${NDJSON}")" "${NDJSON_LATEST}"
echo "$$" >"${PIDFILE}"

# Trap: cierra ficheros, borra pid, imprime resumen.
TICK_COUNT=0
ALERT_COUNT=0
on_exit() {
    local rc=$?
    rm -f "${PIDFILE}" 2>/dev/null || true
    hr
    log_info "monitor detenido tras ${TICK_COUNT} ticks, ${ALERT_COUNT} alertas"
    log_info "  ndjson: ${NDJSON}"
    log_info "  rawlog: ${RAWLOG}"
    exit "${rc}"
}
trap on_exit INT TERM EXIT

# ----------------------------------------------------------------------------
# Estado persistente entre ticks
# ----------------------------------------------------------------------------
# Globals modificados desde funciones — shellcheck SC2034 false positive
# (no detecta asignaciones via printf -v ni mutaciones desde subshells).
# shellcheck disable=SC2034
UBOND_OFFSET=0
# shellcheck disable=SC2034
WATCHDOG_OFFSET=0
PREV_IFACE_IP_IPHONE=""
PREV_IFACE_IP_PIXEL=""
PREV_IFACE_IP_WIFI=""
PREV_WIFI_BSSID=""
PREV_WIFI_SSID=""
BASELINE_PUBLIC_IP=""
DNS_LAST_RESOLVE_TS=0
VPS_BASELINE_IP=""
LAST_LINK_AUTH=99           # para detectar 0-auth dos ticks consecutivos
LOWTHR_STREAK=0
# shellcheck disable=SC2034
PREV_PING_OK=()             # ventana 6 ticks
WDUTIL_DISABLED=0           # latch si wdutil falla con permisos
PING_LOSS_HIST=()           # rates últimos 6 ticks

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
ts_now() { date -Iseconds; }

# JSON string escape mínimo (sin jq).
json_escape() {
    local s="${1-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "${s}"
}

# Append una línea al ndjson. ALCOA++ Contemporaneous: cada N writes
# se invoca `sync` para forzar el flush a disco — sin esto, un crash
# del Mac (poco frecuente pero posible en AVE) podría perder los
# últimos ticks que viven en page cache.
NDJSON_SYNC_EVERY="${NDJSON_SYNC_EVERY:-6}"
NDJSON_WRITES=0
ndjson_emit() {
    printf '%s\n' "$1" >>"${NDJSON}"
    NDJSON_WRITES=$((NDJSON_WRITES + 1))
    if (( NDJSON_WRITES % NDJSON_SYNC_EVERY == 0 )); then
        sync 2>/dev/null || true
    fi
}

# Emite un evento "session_start" como primera línea del NDJSON con
# metadata atribuible (ALCOA++ Attributable): host, user, timestamp,
# git_sha, ubond version, monitor pid. Permite correlacionar logs entre
# trayectos sin ambigüedad.
emit_session_start() {
    local host_id user_id git_sha ubond_version monitor_pid
    host_id="$(hostname 2>/dev/null || echo unknown)"
    user_id="${SUDO_USER:-${USER:-unknown}}"
    git_sha="$(cd "${AVEVPC_ROOT}" 2>/dev/null && git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    ubond_version="$(/usr/local/sbin/ubond --version 2>&1 | head -1 | tr -d '"' | head -c 60 || echo unknown)"
    monitor_pid="$$"
    ndjson_emit "$(printf '{"event":"session_start","ts":"%s","host":"%s","user":"%s","git_sha":"%s","ubond_version":"%s","monitor_pid":%s,"tick_s":%s}' \
        "$(ts_now)" "${host_id}" "${user_id}" "${git_sha}" \
        "$(json_escape "${ubond_version}")" "${monitor_pid}" "${TICK_S}")"
    sync 2>/dev/null || true
}

# Append al rawlog con prefijo timestamp+src.
raw_emit() {
    local src="$1"; shift
    printf '[%s] [src=%s] %s\n' "$(ts_now)" "${src}" "$*" >>"${RAWLOG}"
}

# Color helpers (sólo si tty).
if is_tty; then
    C_RST=$'\033[0m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_RED=$'\033[31m'
    C_GRY=$'\033[90m'; C_BLD=$'\033[1m'; BELL=$'\007'
else
    C_RST=""; C_GRN=""; C_YEL=""; C_RED=""; C_GRY=""; C_BLD=""; BELL=""
fi

# ----------------------------------------------------------------------------
# Detectores
# ----------------------------------------------------------------------------

# Detecta utun cuya IP coincida con UBOND_TUN_MAC_IP. Vacío si no hay.
detect_utun() {
    local i utun
    for i in $(seq 0 15); do
        utun="utun${i}"
        if ifconfig "${utun}" 2>/dev/null | awk -v ip="${UBOND_TUN_MAC_IP}" \
                '$1=="inet" && $2==ip {found=1} END{exit !found}'; then
            printf '%s' "${utun}"; return 0
        fi
    done
    return 1
}

# Devuelve "iphone:flag,pixel:flag,wifi:flag" leyendo el process title.
# flag ∈ @ (auth), ~ (peer), ! (down), - (ausente del title)
detect_link_state() {
    local title
    title="$(pgrep -lf 'ubond: ubond0 ' 2>/dev/null | head -1 || true)"
    local r=""
    for name in iphone pixel wifi; do
        local f="-"
        # match [@~!]links.<name>
        if [[ "${title}" =~ @links\.${name}([^a-zA-Z]|$) ]]; then f="@"
        elif [[ "${title}" =~ \~links\.${name}([^a-zA-Z]|$) ]]; then f="~"
        elif [[ "${title}" =~ \!links\.${name}([^a-zA-Z]|$) ]]; then f="!"
        fi
        r+="${name}:${f},"
    done
    printf '%s' "${r%,}"
}

# Cuenta @ (links autenticados) en el title.
count_auth_links() {
    local state="$1" n=0
    [[ "${state}" == *"iphone:@"* ]] && n=$((n+1))
    [[ "${state}" == *"pixel:@"*  ]] && n=$((n+1))
    [[ "${state}" == *"wifi:@"*   ]] && n=$((n+1))
    printf '%d' "${n}"
}

# PID del proceso ubond client (vacío si ausente).
ubond_pid() {
    pgrep -f 'ubond: ubond0 ' 2>/dev/null | head -1 || true
}

# IP de una iface usando ipconfig (vacío si no hay).
iface_ip() {
    ipconfig getifaddr "$1" 2>/dev/null || true
}

# SSID/BSSID del WiFi via wdutil (Sequoia). Devuelve "ssid|bssid".
# Latched: si wdutil falla con permisos, deshabilitamos métrica.
wifi_info() {
    [[ "${WDUTIL_DISABLED}" == "1" ]] && { printf '|'; return 0; }
    if ! command -v wdutil >/dev/null 2>&1; then
        WDUTIL_DISABLED=1; return 0
    fi
    local out ssid bssid
    out="$(wdutil info 2>/dev/null || true)"
    if [[ -z "${out}" ]]; then
        log_warn "wdutil sin output (permisos?) — métrica WiFi deshabilitada"
        WDUTIL_DISABLED=1
        printf '|'; return 0
    fi
    ssid="$(printf '%s\n' "${out}"  | awk -F': ' '/^[[:space:]]*SSID[[:space:]]*:/ {print $2; exit}')"
    bssid="$(printf '%s\n' "${out}" | awk -F': ' '/^[[:space:]]*BSSID[[:space:]]*:/{print $2; exit}')"
    printf '%s|%s' "${ssid}" "${bssid}"
}

# Default gateway del sistema.
default_gw() {
    route -n get default 2>/dev/null \
        | awk '$1=="gateway:"{print $2; exit}'
}

# Ping forzado por utun. Devuelve "rcv/sent|rtt_avg_ms|ttl_ok".
# ttl_ok=1 si todos los ttl<=64 (lección Roche, evita falso ok subnet
# privada). Vacío para campo no medido.
ping_via_utun() {
    local utun="$1"
    [[ -z "${utun}" ]] && { printf '0/3||0'; return 0; }
    local out rc
    out="$(ping -c 3 -t 2 -b "${utun}" "${UBOND_TUN_VPS_IP}" 2>&1)"
    rc=$?
    local sent rcv avg ttl_bad
    # macOS ping: "3 packets transmitted, 3 packets received, 0.0% packet loss"
    sent="$(printf '%s\n' "${out}" | awk -F',' '/packets transmitted/{gsub(/[^0-9]/,"",$1); print $1; exit}')"
    rcv="$(printf '%s\n'  "${out}" | awk -F',' '/packets received/   {gsub(/[^0-9]/,"",$2); print $2; exit}')"
    avg="$(printf '%s\n'  "${out}" | awk -F'/' '/round-trip|rtt/ {print $5; exit}')"
    ttl_bad="$(printf '%s\n' "${out}" | awk '/ttl=/ {for(i=1;i<=NF;i++) if($i ~ /^ttl=/){split($i,a,"="); if(a[2]+0>64) c++} } END{print c+0}')"
    # ALCOA++ Accurate: distinguir "no medido" de "medido a cero".
    # Si el parsing no devuelve datos (ping completo bloqueado, p.ej. red
    # caída), emitimos "null" en vez de inventar sent=3 o rcv=0. El
    # consumidor (jq) puede entonces filtrar `select(.ping.sent != null)`.
    [[ -z "${sent}" ]] && sent="null"
    [[ -z "${rcv}"  ]] && rcv="null"
    [[ -z "${avg}"  ]] && avg="null"
    local ttl_ok=1
    (( ttl_bad > 0 )) && ttl_ok=0
    printf '%s/%s|%s|%s' "${rcv}" "${sent}" "${avg}" "${ttl_ok}"
    [[ "${rc}" -eq 0 ]] || true
}

# curl al endpoint de Cloudflare via utun. Devuelve "status|time_total|public_ip".
curl_via_utun() {
    local utun="$1"
    [[ -z "${utun}" ]] && { printf '0|0|'; return 0; }
    local body fmt
    fmt='%{http_code}|%{time_total}|%{remote_ip}'
    # URL configurable vía config/env (HEALTH_PROBE_HTTP). El default
    # https si HEALTH_PROBE_HTTP es http: forzamos https.
    local probe_url="${HEALTH_PROBE_HTTP:-http://1.1.1.1/cdn-cgi/trace}"
    probe_url="${probe_url/http:/https:}"  # forzar TLS para measurement
    body="$(curl --interface "${utun}" --max-time 5 -s \
        -w "\n${fmt}" "${probe_url}" 2>/dev/null || true)"
    if [[ -z "${body}" ]]; then printf '0|0|'; return 0; fi
    local pub trailer
    pub="$(printf '%s\n' "${body}" | awk -F= '/^ip=/{print $2; exit}' | tr -d '\r')"
    trailer="$(printf '%s\n' "${body}" | tail -1)"
    # Prefijar pub al trailer (que ya trae status|time|remote_ip).
    printf '%s|%s' "${trailer}" "${pub}"
}

# Throughput sample (sólo cada N ticks). Devuelve "speed_Bps|time_total".
throughput_sample() {
    local utun="$1"
    [[ -z "${utun}" ]] && { printf '0|0'; return 0; }
    local out
    out="$(curl --interface "${utun}" --max-time 8 -s -o /dev/null \
        -w '%{speed_download}|%{time_total}' \
        "https://speed.cloudflare.com/__down?bytes=262144" 2>/dev/null || true)"
    [[ -z "${out}" ]] && out="0|0"
    printf '%s' "${out}"
}

# Lee delta del log. Actualiza la variable global *_OFFSET nombrada en $3 y
# escribe en LOG_DELTA_LINES el nº de líneas nuevas relevantes. Las líneas
# relevantes se appendean al rawlog. Sin subshell para que el offset persista.
# Si src=watchdog y aparece "TRIGGER SOS" en el delta, marca SOS_IN_DELTA=1.
LOG_DELTA_LINES=0
SOS_IN_DELTA=0
read_log_delta() {
    LOG_DELTA_LINES=0
    [[ "$2" == "watchdog" ]] && SOS_IN_DELTA=0
    local path="$1" src="$2" var="$3"
    [[ ! -f "${path}" ]] && return 0
    local size off
    size=$(stat -f %z "${path}" 2>/dev/null || echo 0)
    off="${!var}"
    if (( size < off )); then off=0; fi   # truncado / rotado
    if (( size == off )); then return 0; fi
    local delta
    delta="$(tail -c +$((off+1)) "${path}" 2>/dev/null || true)"
    printf -v "${var}" '%s' "${size}"
    if [[ "${src}" == "ubond" ]]; then
        delta="$(printf '%s' "${delta}" \
            | grep -E 'auth|down|reset|seq|MTU|tuntap|rtun|ECONN|OOM|loss' || true)"
    elif [[ "${src}" == "watchdog" ]]; then
        if printf '%s' "${delta}" | grep -q 'TRIGGER SOS'; then
            SOS_IN_DELTA=1
        fi
    fi
    [[ -z "${delta}" ]] && return 0
    local n=0
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        raw_emit "${src}" "${line}"
        n=$((n + 1))
    done <<<"${delta}"
    LOG_DELTA_LINES="${n}"
}

# Watchdog vivo: 1 si el pidfile existe y el pid responde.
watchdog_alive() {
    local f="${GEN_DIR}/ubond_watchdog.pid" pid
    [[ ! -f "${f}" ]] && { echo 0; return 0; }
    pid="$(cat "${f}" 2>/dev/null || true)"
    [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null \
        && { echo 1; return 0; }
    echo 0
}

# Edad en s del flag ubond_unhealthy; -1 si no existe.
health_flag_age() {
    [[ ! -f "${HEALTH_FLAG}" ]] && { echo -1; return 0; }
    local mt; mt=$(stat -f %m "${HEALTH_FLAG}" 2>/dev/null || echo 0)
    echo $(( $(date +%s) - mt ))
}

# Sistema: load, cpu_ubond, batería.
load_avg_1m()  { uptime | awk -F'load averages?: ' '{print $2}' | awk '{print $1}' | tr -d ','; }
cpu_ubond()    {
    local pid; pid="$(ubond_pid)"
    [[ -z "${pid}" ]] && { echo 0; return 0; }
    ps -o %cpu= -p "${pid}" 2>/dev/null | tr -d ' ' || echo 0
}
mem_pressure() {
    # Free pages + speculative as % approximation; tolerante a fallo.
    vm_stat 2>/dev/null | awk '
        /Pages free/        {f=$3+0}
        /Pages active/      {a=$3+0}
        /Pages inactive/    {i=$3+0}
        /Pages speculative/ {s=$3+0}
        /Pages wired/       {w=$4+0}
        END { tot=f+a+i+s+w; if (tot>0) printf "%.1f", 100.0*(f+s)/tot; else print "" }
    '
}
battery_pct() {
    pmset -g batt 2>/dev/null | awk -F';' '/InternalBattery/{print $1}' \
        | grep -oE '[0-9]+%' | head -1 || true
}

# Resolución cacheada de VPS_IP via dig @1.1.1.1 (NUNCA system DNS).
resolve_vps_baseline() {
    local now; now=$(date +%s)
    if [[ -n "${VPS_BASELINE_IP}" ]] && (( now - DNS_LAST_RESOLVE_TS < DNS_REFRESH_S )); then
        return 0
    fi
    if command -v dig >/dev/null 2>&1; then
        local ip resolver="${FALLBACK_DNS_RESOLVER:-1.1.1.1}"
        ip="$(dig "@${resolver}" +time=2 +tries=1 +short "${VPS_IP}" 2>/dev/null \
            | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/{print; exit}')"
        if [[ -n "${ip}" ]]; then
            VPS_BASELINE_IP="${ip}"
            DNS_LAST_RESOLVE_TS="${now}"
            return 0
        fi
    fi
    # Fallback: si VPS_IP ya es IP literal, úsala.
    if [[ "${VPS_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        VPS_BASELINE_IP="${VPS_IP}"
        DNS_LAST_RESOLVE_TS="${now}"
    fi
}

# Rotación: si ndjson > ROTATE_BYTES, comprimir y abrir nuevo.
rotate_if_needed() {
    local sz
    sz=$(stat -f %z "${NDJSON}" 2>/dev/null || echo 0)
    (( sz < ROTATE_BYTES )) && return 0
    local rolled
    rolled="${NDJSON%.ndjson}-rolled-$(date +%Y%m%dT%H%M%S).ndjson"
    mv "${NDJSON}" "${rolled}" 2>/dev/null || true
    : >>"${NDJSON}"; chmod 600 "${NDJSON}"
    raw_emit "monitor" "rotated ${rolled}"
}

# ----------------------------------------------------------------------------
# Pre-flight
# ----------------------------------------------------------------------------
preflight() {
    hr
    log_info "ave-monitor arrancando — tick=${TICK_S}s, throughput=${ENABLE_THROUGHPUT}"
    if ! pgrep -f 'ubond: ubond0 ' >/dev/null 2>&1; then
        die 1 "ubond no está corriendo — lanza tools/04b-conectar-ubond.sh primero"
    fi
    local utun; utun="$(detect_utun || true)"
    if [[ -z "${utun}" ]]; then
        die 1 "no encuentro utun con IP ${UBOND_TUN_MAC_IP} — túnel no establecido"
    fi
    log_info "utun activo: ${utun}"
    resolve_vps_baseline
    log_info "VPS_IP baseline: ${VPS_BASELINE_IP:-<no resuelto>}"
    if [[ "$(watchdog_alive)" == "0" ]]; then
        log_warn "watchdog no corriendo — sin auto-recovery (informativo)"
    fi
    hr
}

# ----------------------------------------------------------------------------
# Tick principal
# ----------------------------------------------------------------------------
do_tick() {
    TICK_COUNT=$((TICK_COUNT + 1))
    local ts; ts="$(ts_now)"
    rotate_if_needed
    resolve_vps_baseline

    # 1.1 links
    local link_state link_auth pid_ubond utun
    link_state="$(detect_link_state)"
    link_auth="$(count_auth_links "${link_state}")"
    pid_ubond="$(ubond_pid)"
    utun="$(detect_utun || true)"

    # 1.2 cobertura física
    local ip_iphone ip_pixel ip_wifi gw winfo wssid wbssid
    ip_iphone="$(iface_ip "${IFACE_IPHONE}")"
    ip_pixel="$(iface_ip  "${IFACE_PIXEL}")"
    ip_wifi="$(iface_ip   "${IFACE_WIFI}")"
    gw="$(default_gw)"
    winfo="$(wifi_info)"
    wssid="${winfo%|*}"; wbssid="${winfo#*|}"

    local iface_change=0
    if [[ "${ip_iphone}" != "${PREV_IFACE_IP_IPHONE}" \
       || "${ip_pixel}"  != "${PREV_IFACE_IP_PIXEL}" \
       || "${ip_wifi}"   != "${PREV_IFACE_IP_WIFI}" ]]; then
        iface_change=1
    fi

    # 1.3 salud túnel
    local utun_present=0; [[ -n "${utun}" ]] && utun_present=1
    local ping_raw rcv_sent rtt ttl_ok ping_succ_pct
    ping_raw="$(ping_via_utun "${utun}")"
    IFS='|' read -r rcv_sent rtt ttl_ok <<<"${ping_raw}"
    local rcv="${rcv_sent%/*}" sent="${rcv_sent#*/}"
    # ALCOA++ Accurate: si "null" propagado desde ping_via_utun, succ_pct
    # también es null (no medido), distinguible de 0 (medido a cero loss).
    if [[ "${sent}" == "null" || "${rcv}" == "null" ]]; then
        ping_succ_pct="null"
    elif [[ "${sent}" -gt 0 ]]; then
        ping_succ_pct=$(( 100 * rcv / sent ))
    else
        ping_succ_pct=0
    fi
    local hflag_age; hflag_age="$(health_flag_age)"

    # 1.4 tráfico real via curl
    local curl_raw http_status time_total remote_ip pub_ip
    curl_raw="$(curl_via_utun "${utun}")"
    IFS='|' read -r http_status time_total remote_ip pub_ip <<<"${curl_raw}"

    # Baseline pública: primer tick con http=200 y pub_ip no vacío.
    if [[ -z "${BASELINE_PUBLIC_IP}" && -n "${pub_ip}" && "${http_status}" == "200" ]]; then
        BASELINE_PUBLIC_IP="${pub_ip}"
        raw_emit "monitor" "baseline public_ip=${BASELINE_PUBLIC_IP}"
    fi

    # 1.5 throughput cada N ticks
    local thr_bps="" thr_time=""
    if [[ "${ENABLE_THROUGHPUT}" == "1" && $((TICK_COUNT % THROUGHPUT_EVERY)) -eq 0 \
            && -n "${utun}" && "${http_status}" == "200" ]]; then
        local thr_raw; thr_raw="$(throughput_sample "${utun}")"
        IFS='|' read -r thr_bps thr_time <<<"${thr_raw}"
    fi

    # 1.6 eventos del binario
    local n_ubond n_watch
    read_log_delta "${UBOND_LOG}"    ubond    UBOND_OFFSET
    n_ubond="${LOG_DELTA_LINES}"
    read_log_delta "${WATCHDOG_LOG}" watchdog WATCHDOG_OFFSET
    n_watch="${LOG_DELTA_LINES}"

    # 1.7 watchdog y SOS — sos_recent sólo cierto si SOS apareció en el
    # delta de este tick (no en líneas viejas del log).
    local wd_alive sos_recent="${SOS_IN_DELTA}"
    wd_alive="$(watchdog_alive)"

    # 1.8 sistema
    local la cpu mem bat
    la="$(load_avg_1m)"
    cpu="$(cpu_ubond)"
    mem="$(mem_pressure)"
    bat="$(battery_pct)"

    # ---- Detección de alertas --------------------------------------------
    local alerts=()
    if [[ "${LAST_LINK_AUTH}" == "0" && "${link_auth}" == "0" ]]; then
        alerts+=("link_auth=0 dos ticks consecutivos")
    fi
    LAST_LINK_AUTH="${link_auth}"

    PING_LOSS_HIST+=("${ping_succ_pct}")
    while (( ${#PING_LOSS_HIST[@]} > 6 )); do
        PING_LOSS_HIST=("${PING_LOSS_HIST[@]:1}")
    done
    if (( ${#PING_LOSS_HIST[@]} == 6 )); then
        local sum=0 v
        for v in "${PING_LOSS_HIST[@]}"; do sum=$((sum + v)); done
        if (( sum / 6 < 50 )); then
            alerts+=("ping_succ_rate<50% en ventana 6 ticks (avg=$((sum/6))%)")
        fi
    fi

    if [[ -n "${thr_bps}" && "${thr_bps}" != "0" ]]; then
        # thr_bps es float; comparar con awk.
        local low; low="$(awk -v v="${thr_bps}" 'BEGIN{print (v<51200)?1:0}')"
        if [[ "${low}" == "1" ]]; then
            LOWTHR_STREAK=$((LOWTHR_STREAK + 1))
            if (( LOWTHR_STREAK >= 2 )); then
                alerts+=("throughput<50KB/s dos muestras (${thr_bps} B/s)")
            fi
        else
            LOWTHR_STREAK=0
        fi
    fi

    if (( iface_change == 1 )); then
        alerts+=("iface_change iphone/pixel/wifi (informativo)")
    fi

    if [[ -n "${BASELINE_PUBLIC_IP}" && -n "${pub_ip}" \
          && "${pub_ip}" != "${BASELINE_PUBLIC_IP}" ]]; then
        alerts+=("public_ip drift: ${BASELINE_PUBLIC_IP} → ${pub_ip} (FUGA túnel?)")
    fi

    if (( sos_recent == 1 )); then
        alerts+=("watchdog disparó SOS")
    fi

    if [[ -n "${PREV_WIFI_BSSID}" && -n "${wbssid}" \
          && ( "${wbssid}" != "${PREV_WIFI_BSSID}" || "${wssid}" != "${PREV_WIFI_SSID}" ) ]]; then
        alerts+=("wifi flap ${PREV_WIFI_SSID}/${PREV_WIFI_BSSID} → ${wssid}/${wbssid}")
    fi

    if (( utun_present == 0 && link_auth > 0 )); then
        alerts+=("utun ausente con link_auth=${link_auth} (raro)")
    fi

    if [[ "${ttl_ok}" == "0" ]]; then
        alerts+=("ping ttl>64 — posible respuesta de host random fuera del túnel")
    fi

    PREV_IFACE_IP_IPHONE="${ip_iphone}"
    PREV_IFACE_IP_PIXEL="${ip_pixel}"
    PREV_IFACE_IP_WIFI="${ip_wifi}"
    PREV_WIFI_BSSID="${wbssid}"
    PREV_WIFI_SSID="${wssid}"

    # ---- NDJSON ----------------------------------------------------------
    local alert_json="null"
    if (( ${#alerts[@]} > 0 )); then
        ALERT_COUNT=$((ALERT_COUNT + 1))
        local first=1; alert_json='['
        for a in "${alerts[@]}"; do
            (( first == 0 )) && alert_json+=','
            alert_json+="\"$(json_escape "${a}")\""
            first=0
        done
        alert_json+=']'
    fi

    local line
    line=$(printf '{"ts":"%s","tick":%d,"links":"%s","link_auth":%d,"ubond_pid":"%s","utun":"%s","utun_present":%d,'\
'"iface_ips":{"iphone":"%s","pixel":"%s","wifi":"%s"},"iface_change":%d,"default_gw":"%s",'\
'"wifi":{"ssid":"%s","bssid":"%s"},"ping":{"succ":"%s","rtt_ms":"%s","ttl_ok":%s,"succ_pct":%d},'\
'"http":{"status":"%s","time":"%s","remote_ip":"%s","public_ip":"%s"},'\
'"throughput":{"bps":"%s","time":"%s"},"events":{"ubond":%d,"watchdog":%d},'\
'"watchdog":{"alive":%d,"sos_recent":%d,"health_flag_age_s":%d},'\
'"sys":{"load1":"%s","cpu_ubond":"%s","mem_free_pct":"%s","battery":"%s"},"alert":%s}' \
        "${ts}" "${TICK_COUNT}" \
        "$(json_escape "${link_state}")" "${link_auth}" "${pid_ubond}" "${utun}" "${utun_present}" \
        "$(json_escape "${ip_iphone}")" "$(json_escape "${ip_pixel}")" "$(json_escape "${ip_wifi}")" \
        "${iface_change}" "$(json_escape "${gw}")" \
        "$(json_escape "${wssid}")" "$(json_escape "${wbssid}")" \
        "${rcv_sent}" "${rtt}" "${ttl_ok}" "${ping_succ_pct}" \
        "${http_status}" "${time_total}" "$(json_escape "${remote_ip}")" "$(json_escape "${pub_ip}")" \
        "${thr_bps}" "${thr_time}" \
        "${n_ubond}" "${n_watch}" \
        "${wd_alive}" "${sos_recent}" "${hflag_age}" \
        "${la}" "${cpu}" "${mem}" "$(json_escape "${bat}")" \
        "${alert_json}")
    ndjson_emit "${line}"

    # ---- Stdout compacto -------------------------------------------------
    local lflag_i lflag_p lflag_w
    lflag_i="${link_state#*iphone:}"; lflag_i="${lflag_i:0:1}"
    lflag_p="$(printf '%s' "${link_state}" | awk -F'pixel:' '{print substr($2,1,1)}')"
    lflag_w="$(printf '%s' "${link_state}" | awk -F'wifi:'  '{print substr($2,1,1)}')"
    color_for() {
        case "$1" in
            '@') printf '%s%s%s' "${C_GRN}" "$2" "${C_RST}" ;;
            '~') printf '%s%s%s' "${C_YEL}" "$2" "${C_RST}" ;;
            '!') printf '%s%s%s' "${C_RED}" "$2" "${C_RST}" ;;
            *)   printf '%s%s%s' "${C_GRY}" "$2" "${C_RST}" ;;
        esac
    }
    local thr_str=""
    if [[ -n "${thr_bps}" && "${thr_bps}" != "0" ]]; then
        thr_str=" thr=$(awk -v v="${thr_bps}" 'BEGIN{printf "%dKB/s", v/1024}')"
    fi
    local alert_indicator=""
    if (( ${#alerts[@]} > 0 )); then
        alert_indicator=" ${C_RED}${C_BLD}ALERT${C_RST}${BELL}"
    fi
    printf '%s links=%s%s%s %s ping=%s %sms http=%s %ss pub=%s%s%s\n' \
        "${ts}" \
        "$(color_for "${lflag_i}" i)" "$(color_for "${lflag_p}" p)" "$(color_for "${lflag_w}" w)" \
        "${utun:-utun?}" "${rcv_sent}" "${rtt:-?}" "${http_status}" "${time_total}" \
        "${pub_ip:-?}" "${thr_str}" "${alert_indicator}"

    # ---- Bloque expandido cada N ticks -----------------------------------
    if (( TICK_COUNT % EXPANDED_EVERY == 0 )); then
        {
            printf '====== EXPANDED tick=%d %s ======\n' "${TICK_COUNT}" "${ts}"
            printf '  links=%s  link_auth=%d  ubond_pid=%s  utun=%s\n' \
                "${link_state}" "${link_auth}" "${pid_ubond:-?}" "${utun:-?}"
            printf '  ip iphone=%s pixel=%s wifi=%s gw=%s\n' \
                "${ip_iphone:-?}" "${ip_pixel:-?}" "${ip_wifi:-?}" "${gw:-?}"
            printf '  wifi ssid=%s bssid=%s\n' "${wssid:-?}" "${wbssid:-?}"
            printf '  ping rcv/sent=%s rtt=%sms ttl_ok=%s\n' "${rcv_sent}" "${rtt:-?}" "${ttl_ok}"
            printf '  http=%s time=%s remote=%s public=%s baseline=%s\n' \
                "${http_status}" "${time_total}" "${remote_ip}" "${pub_ip}" "${BASELINE_PUBLIC_IP:-?}"
            printf '  throughput bps=%s time=%s\n' "${thr_bps:-skip}" "${thr_time:-skip}"
            printf '  watchdog alive=%s sos_recent=%s health_flag_age_s=%s\n' \
                "${wd_alive}" "${sos_recent}" "${hflag_age}"
            printf '  sys load=%s cpu_ubond=%s mem_free_pct=%s bat=%s\n' \
                "${la}" "${cpu}" "${mem}" "${bat:-?}"
            if (( ${#alerts[@]} > 0 )); then
                printf '  ALERTS:\n'
                for a in "${alerts[@]}"; do printf '    - %s\n' "${a}"; done
            fi
        } | tee -a "${RAWLOG}"
    fi
}

# ----------------------------------------------------------------------------
# Loop
# ----------------------------------------------------------------------------
preflight
emit_session_start         # ALCOA++ Attributable: cabecera del log
while :; do
    do_tick || log_warn "tick ${TICK_COUNT} con error parcial — continuando"
    sleep "${TICK_S}"
done
