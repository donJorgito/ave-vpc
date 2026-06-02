#!/bin/sh
# Validates ave-vpc.REQ-NET-26: watchdog ubond v2 + visibilidad.
# Test estático: verifica existencia, sintaxis, integraciones y patrones.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-26_watchdog"

ROOT="$(dirname "$0")/.."
WATCHDOG="${ROOT}/tools/ubond-watchdog.sh"

# 1. Watchdog existe, ejecutable, sintaxis OK.
if [ -x "${WATCHDOG}" ] && bash -n "${WATCHDOG}" 2>/dev/null; then
    junit_pass "watchdog_present_and_valid"
else
    junit_fail "watchdog_missing" "tools/ubond-watchdog.sh no existe o sintaxis errónea"
    junit_finalize
fi

# 2. Watchdog implementa las 3 señales de salud.
if grep -q 'pgrep -f "ubond: "' "${WATCHDOG}" \
   && grep -qE 'ping.*-c.*1.*\$\{?TARGET\}?' "${WATCHDOG}" \
   && grep -q 'HEALTH_FLAG' "${WATCHDOG}"; then
    junit_pass "watchdog_three_signals"
else
    junit_fail "watchdog_signals" "watchdog no implementa las 3 vías (pgrep, ping, flag)"
fi

# 3. Watchdog invoca SOS.sh con cooldown.
if grep -q 'SOS.sh' "${WATCHDOG}" && grep -q 'SOS_COOLDOWN' "${WATCHDOG}"; then
    junit_pass "watchdog_invokes_sos_with_cooldown"
else
    junit_fail "watchdog_no_sos" "watchdog no invoca SOS.sh o sin cooldown"
fi

# 4. Watchdog notifica via osascript.
if grep -q 'osascript.*display notification' "${WATCHDOG}"; then
    junit_pass "watchdog_notifies"
else
    junit_fail "watchdog_no_notify" "watchdog no notifica via osascript"
fi

# 5. 04b lanza ubond con --debug --verbose.
SCRIPT_04B="${ROOT}/04b-conectar-ubond.sh"
if grep -qE -- '--debug --verbose|--debug.*--verbose|--verbose.*--debug' "${SCRIPT_04B}"; then
    junit_pass "04b_launches_with_debug"
else
    junit_fail "04b_no_debug" "04b no lanza ubond con --debug --verbose (log queda vacío)"
fi

# 6. 04b captura PID real del binario, no del subshell tee.
if grep -qE 'pgrep.*"ubond: ubond0 \\\[priv\\\]"' "${SCRIPT_04B}" \
   && grep -q 'TEE_PID' "${SCRIPT_04B}"; then
    junit_pass "04b_pid_capture_real"
else
    junit_fail "04b_pid_wrong" "04b sigue capturando \$! del subshell tee como PID"
fi

# 7. 04b arranca el watchdog.
if grep -qE 'tools/ubond-watchdog\.sh' "${SCRIPT_04B}"; then
    junit_pass "04b_starts_watchdog"
else
    junit_fail "04b_no_watchdog" "04b no arranca tools/ubond-watchdog.sh"
fi

# 8. 05b mata el watchdog ANTES que ubond.
SCRIPT_05B="${ROOT}/05b-desconectar-ubond.sh"
# Tomar las líneas con grep -n y verificar orden numérico.
W_LINE=$(grep -n 'ubond_watchdog\|tools/ubond-watchdog' "${SCRIPT_05B}" | head -1 | cut -d: -f1)
U_LINE=$(grep -n 'pkill -f "ubond: "' "${SCRIPT_05B}" | head -1 | cut -d: -f1)
if [ -n "${W_LINE}" ] && [ -n "${U_LINE}" ] && [ "${W_LINE}" -lt "${U_LINE}" ]; then
    junit_pass "05b_kills_watchdog_first"
else
    junit_fail "05b_wrong_order" "05b no mata watchdog antes que ubond (W=${W_LINE} U=${U_LINE})"
fi

# 9. SOS.sh mata el watchdog.
if grep -qE 'pkill.*tools/ubond-watchdog' "${ROOT}/SOS.sh"; then
    junit_pass "sos_kills_watchdog"
else
    junit_fail "sos_no_watchdog" "SOS.sh no mata el watchdog (loop infinito posible)"
fi

# 10. SOS.sh limpia flag de salud.
if grep -q 'ubond_unhealthy' "${ROOT}/SOS.sh"; then
    junit_pass "sos_cleans_health_flag"
else
    junit_fail "sos_no_flag_clean" "SOS.sh no limpia generated/ubond_unhealthy"
fi

# 11. 03b genera ubond_updown_mac.sh propio (no copia de mlvpn) con
# log path /tmp/ubond_updown.log.
SCRIPT_03B="${ROOT}/03b-setup-mac-ubond.sh"
if grep -q '/tmp/ubond_updown.log' "${SCRIPT_03B}" \
   && grep -q 'HEALTH_FLAG' "${SCRIPT_03B}"; then
    junit_pass "03b_generates_own_updown"
else
    junit_fail "03b_copies_mlvpn_updown" \
        "03b no genera updown propio con log separado y health flag"
fi

# 12. updown handler toca health flag en rtun_down y tuntap_down.
if grep -qE 'rtun_down\)|tuntap_down\)' "${SCRIPT_03B}" \
   && grep -E 'touch.*HEALTH_FLAG' "${SCRIPT_03B}" >/dev/null; then
    junit_pass "updown_touches_flag_on_down"
else
    junit_fail "updown_no_flag_touch" \
        "updown handler no toca HEALTH_FLAG en eventos down"
fi

junit_finalize
