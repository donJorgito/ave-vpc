#!/usr/bin/env bash
###############################################################################
# tools/test-rebind-runtime.sh
#
# Test runtime end-to-end de REQ-NET-35.1 (rebind socket time-based).
#
# QUE HACE:
#   Simula expiry de pinhole NAT en el carrier 4G via iptables DROP en la
#   RPi (corta el inbound de UN solo link/sport) y verifica:
#
#     1. ubond detecta silencio inbound > UBOND_REBIND_SILENCE_S (90s).
#     2. Loguea "silence X.Xs reached (>= 90s), rebinding socket".
#     3. Cierra el fd UDP y abre uno nuevo -> sport efimero distinto.
#     4. Tras retirar la regla iptables, el bonded recupera (ping 10.10.20.1).
#
# DONDE SE EJECUTA: En tu Mac. Conecta por SSH a la RPi para manipular
#                   iptables. NO requiere root local (lsof basta para ver
#                   el sport).
#
# REQUISITOS:
#   - ubond cliente corriendo en Mac (./04b-conectar-ubond.sh).
#   - ubond service activo en RPi.
#   - SSH sin password a RPi (mismas credenciales que 07b/SOS).
#   - generated/ubond.log con --debug --verbose habilitado por 04b.
#
# OVERRIDES (env vars):
#   RUNTIME_TEST_LINK       Link a aislar. Default: wifi.
#   RUNTIME_TEST_PORT       Puerto remoto del link. Default: 5085 (wifi).
#                           iphone=5083, pixel=5084, wifi=5085.
#   RUNTIME_TEST_SILENCE_S  Segundos de silencio a inducir. Default: 100
#                           (UBOND_REBIND_SILENCE_S=90 + 10s de margen).
#
# SALIDA:
#   reports/test-rebind-runtime.xml (JUnit, 5 checks).
#   stdout con PASS/FAIL por check.
#
# CLEANUP:
#   trap EXIT retira la regla iptables incluso si el test peta. NO mata
#   ubond aunque el test falle (solo reporta).
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# JUnit helpers (escritos en tests/, source-able desde aqui).
# shellcheck disable=SC1091
. "${ROOT_DIR}/tests/_lib_junit.sh"

# Reports en el sitio canonical del repo.

junit_init "test-rebind-runtime"

# --- Overrides -------------------------------------------------------------
LINK_NAME="${RUNTIME_TEST_LINK:-wifi}"
LINK_PORT="${RUNTIME_TEST_PORT:-5085}"
SILENCE_S="${RUNTIME_TEST_SILENCE_S:-100}"

# --- Config RPi ------------------------------------------------------------
CONFIG_FILE="${ROOT_DIR}/config/env"
if [ ! -f "${CONFIG_FILE}" ]; then
    junit_fail "config_present" "config/env no existe"
    junit_finalize
fi
# shellcheck disable=SC1090
. "${CONFIG_FILE}"

RPI_HOST="${RPi_IP:-}"
RPI_USER="${RPi_USER:-jorge}"
RPI_PORT="${RPi_SSH_PORT:-22}"

UBOND_LOG="${ROOT_DIR}/generated/ubond.log"
TUN_VPS_IP="${UBOND_TUN_VPS_IP:-10.10.20.1}"

# --- Estado para cleanup ---------------------------------------------------
SPORT_PRE=""
RULE_INSTALLED=0

ssh_rpi() {
    ssh -o BatchMode=yes -o ConnectTimeout=5 -p "${RPI_PORT}" \
        "${RPI_USER}@${RPI_HOST}" "$@"
}

remove_iptables_rule() {
    [ "${RULE_INSTALLED}" = "1" ] || return 0
    [ -z "${SPORT_PRE}" ] && return 0
    echo "[cleanup] retirando regla iptables DROP sport=${SPORT_PRE} dport=${LINK_PORT}"
    ssh_rpi "sudo iptables -D INPUT -p udp --sport ${SPORT_PRE} --dport ${LINK_PORT} -j DROP" \
        2>/dev/null || echo "[cleanup] WARN: regla ya no existe o no se pudo retirar"
    RULE_INSTALLED=0
}

cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    remove_iptables_rule || true
    exit "${rc}"
}
trap cleanup EXIT INT TERM

# --- 1. Pre-checks ---------------------------------------------------------
PRECHECK_OK=1
PRECHECK_MSG=""

UBOND_PID="$(pgrep -f 'ubond: ubond0 ' 2>/dev/null | head -1 || true)"
if [ -z "${UBOND_PID}" ]; then
    PRECHECK_OK=0
    PRECHECK_MSG="ubond Mac no esta corriendo (pgrep 'ubond: ubond0 ' vacio)"
fi

if [ "${PRECHECK_OK}" = "1" ] && [ -z "${RPI_HOST}" ]; then
    PRECHECK_OK=0
    PRECHECK_MSG="RPi_IP no definido en config/env"
fi

if [ "${PRECHECK_OK}" = "1" ]; then
    if ! ssh_rpi 'systemctl is-active --quiet ubond' 2>/dev/null; then
        PRECHECK_OK=0
        PRECHECK_MSG="ubond.service no activo en RPi (${RPI_USER}@${RPI_HOST}:${RPI_PORT})"
    fi
fi

if [ "${PRECHECK_OK}" = "1" ] && [ ! -f "${UBOND_LOG}" ]; then
    PRECHECK_OK=0
    PRECHECK_MSG="generated/ubond.log no existe (¿corriste 04b-conectar-ubond.sh?)"
fi

if [ "${PRECHECK_OK}" = "1" ]; then
    junit_pass "preconditions_ok"
else
    junit_fail "preconditions_failed" "${PRECHECK_MSG}"
    junit_finalize
fi

# --- 2. Capturar sport efimero pre-rebind ----------------------------------
# lsof imprime UDP sockets del proceso ubond. Filtramos por puerto remoto
# del link bajo test (5083/5084/5085) y extraemos el sport local.
#
# Linea tipica de lsof -nP -iUDP -p <PID>:
#   ubond  12345 jorge   8u  IPv4 ...  UDP 192.168.1.42:54321->203.0.113.10:5085
#
# El sport esta en el campo NAME, antes del "->".
SPORT_PRE="$(lsof -nP -iUDP -p "${UBOND_PID}" 2>/dev/null \
    | awk -v port="${LINK_PORT}" '
        /UDP / && $0 ~ "->.*:" port "$" {
            n=split($NF, a, "->");
            split(a[1], b, ":");
            print b[length(b)];
            exit
        }')"

if [ -n "${SPORT_PRE}" ]; then
    junit_pass "sport_pre_captured"
    echo "  sport efimero pre-rebind: ${SPORT_PRE} (link=${LINK_NAME}, dport=${LINK_PORT})"
else
    junit_fail "sport_pre_missing" \
        "no se pudo extraer sport efimero del link ${LINK_NAME} (dport=${LINK_PORT}) via lsof PID=${UBOND_PID}"
    junit_finalize
fi

# --- 3. Instalar regla iptables DROP en RPi --------------------------------
echo "[T0] instalando iptables DROP -p udp --sport ${SPORT_PRE} --dport ${LINK_PORT} en RPi..."
if ssh_rpi "sudo iptables -I INPUT -p udp --sport ${SPORT_PRE} --dport ${LINK_PORT} -j DROP" 2>/dev/null; then
    RULE_INSTALLED=1
    : "$(date +%s)"  # T0 marker — see logs for timestamp
    junit_pass "iptables_drop_installed"
else
    junit_fail "iptables_drop_failed" \
        "no se pudo insertar regla iptables en RPi (¿sudo sin password configurado?)"
    junit_finalize
fi

# --- 4. Esperar > UBOND_REBIND_SILENCE_S -----------------------------------
# Mientras esperamos, snapshot del log para baseline (lineas previas al
# rebind). Asi grep-eamos solo lineas posteriores a T0.
LOG_BASELINE="$(wc -l < "${UBOND_LOG}" 2>/dev/null || echo 0)"
LOG_BASELINE="${LOG_BASELINE// /}"

echo "[T0+0] esperando ${SILENCE_S}s para que ubond detecte silencio (>= 90s)..."
sleep "${SILENCE_S}"

# --- 5. Verificar log: "silence X.Xs reached" ------------------------------
# Buscamos solo en las lineas nuevas (post-T0). El patron exacto del patch
# es: "%s silence %.0fs reached (>= 90s), rebinding socket".
SILENCE_LINE="$(tail -n +"$((LOG_BASELINE + 1))" "${UBOND_LOG}" 2>/dev/null \
    | grep -E "silence [0-9]+s reached \(>= 90s\), rebinding socket" \
    | head -1 || true)"

if [ -n "${SILENCE_LINE}" ]; then
    junit_pass "rebind_log_present"
    echo "  log: ${SILENCE_LINE}"
else
    junit_fail "rebind_log_missing" \
        "no aparece 'silence X.Xs reached (>= 90s), rebinding socket' en ubond.log tras ${SILENCE_S}s"
fi

# --- 6. Verificar sport post-rebind != sport pre ---------------------------
# Tras el rebind, el kernel asigna un sport efimero nuevo cuando ubond
# crea el socket UDP. Si el patch funciona, SPORT_post != SPORT_pre.
SPORT_POST="$(lsof -nP -iUDP -p "${UBOND_PID}" 2>/dev/null \
    | awk -v port="${LINK_PORT}" '
        /UDP / && $0 ~ "->.*:" port "$" {
            n=split($NF, a, "->");
            split(a[1], b, ":");
            print b[length(b)];
            exit
        }')"

if [ -z "${SPORT_POST}" ]; then
    junit_fail "sport_post_missing" \
        "no se pudo capturar sport post-rebind (link ${LINK_NAME} sin socket UDP activo)"
elif [ "${SPORT_POST}" = "${SPORT_PRE}" ]; then
    junit_fail "sport_unchanged" \
        "sport NO cambio tras rebind: pre=${SPORT_PRE} post=${SPORT_POST} (bug original)"
else
    junit_pass "sport_changed_after_rebind"
    echo "  sport pre=${SPORT_PRE} post=${SPORT_POST} (cambio confirmado)"
fi

# --- 7. Retirar regla iptables ---------------------------------------------
remove_iptables_rule

# --- 8. Verificar recovery: ping bonded a 10.10.20.1 -----------------------
# Damos 5s para que ubond complete el handshake con el sport nuevo.
echo "[recovery] esperando 5s para handshake post-rebind..."
sleep 5

if ping -c 3 -W 2 "${TUN_VPS_IP}" >/dev/null 2>&1; then
    junit_pass "bonded_recovery_ping_ok"
    echo "  ping ${TUN_VPS_IP} OK tras rebind+cleanup"
else
    junit_fail "bonded_recovery_ping_failed" \
        "ping ${TUN_VPS_IP} falla tras rebind (¿no recupera el handshake?)"
fi

junit_finalize
