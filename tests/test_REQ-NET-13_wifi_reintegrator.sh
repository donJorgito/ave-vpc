#!/bin/sh
# Validates ave-vpc.REQ-NET-13: reintegración WiFi tras captive auth.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-13_wifi_reintegrator"

ROOT="$(dirname "$0")/.."
SCRIPT="${ROOT}/tools/wifi-reintegrator.sh"
CONNECT="${ROOT}/04-conectar.sh"
DISCONNECT="${ROOT}/05-desconectar.sh"
SOS="${ROOT}/SOS.sh"

# Check 1: script existe y es ejecutable
if [ -x "${SCRIPT}" ]; then
    junit_pass "reintegrator_executable"
else
    junit_fail "reintegrator_missing" "tools/wifi-reintegrator.sh no existe o no ejecutable"
    junit_finalize
fi

# Check 2: pasa bash -n
if bash -n "${SCRIPT}" 2>/dev/null; then
    junit_pass "reintegrator_syntax_ok"
else
    junit_fail "reintegrator_syntax_bad" "errores de sintaxis"
fi

# Check 3: usa logger -t mlvpn-wifi-reintegrator (consistencia con resto)
if grep -q "logger -t mlvpn-wifi-reintegrator" "${SCRIPT}"; then
    junit_pass "logs_to_syslog"
else
    junit_fail "no_syslog" "no usa logger para syslog"
fi

# Check 4: detiene loop si [links.wifi] ya está en config
if grep -q '"^\\\[links\\.wifi\\\]"' "${SCRIPT}" \
   && grep -q "continue" "${SCRIPT}"; then
    junit_pass "skips_when_wifi_in_config"
else
    junit_fail "no_skip_check" "no comprueba si links.wifi ya está en config"
fi

# Check 5: añade bandwidth_upload + timeout al bloque dinámico
if grep -q "bandwidth_upload = 50000000" "${SCRIPT}" \
   && grep -q "timeout = 8" "${SCRIPT}"; then
    junit_pass "adds_correct_link_params"
else
    junit_fail "wrong_link_params" "no escribe bandwidth_upload=50000000 + timeout=8"
fi

# Check 6: SIGHUP a mlvpn [priv] para recargar config
if grep -q 'kill -HUP.*priv_pid' "${SCRIPT}" \
   && grep -q "pgrep -f 'mlvpn: mlvpn0 \\\\\\[priv\\\\\\]'" "${SCRIPT}"; then
    junit_pass "sighup_to_priv"
else
    junit_fail "no_sighup" "no manda SIGHUP a mlvpn [priv]"
fi

# Check 7: 04-conectar.sh lanza el reintegrator condicional
if grep -q "wifi-reintegrator.sh" "${CONNECT}" \
   && grep -A3 'WIFI_ELIGIBLE.*SIN_WIFI' "${CONNECT}" | grep -q 'wifi-reintegrator' \
   || grep -B5 'wifi-reintegrator' "${CONNECT}" | grep -q "WIFI_ELIGIBLE"; then
    junit_pass "connect_launches_conditionally"
else
    junit_fail "connect_no_launch" "04-conectar.sh no lanza reintegrator condicionalmente"
fi

# Check 8: 05-desconectar mata reintegrator
if grep -q "wifi-reintegrator" "${DISCONNECT}"; then
    junit_pass "disconnect_kills_reintegrator"
else
    junit_fail "disconnect_no_kill" "05-desconectar no mata reintegrator"
fi

# Check 9: SOS.sh también lo mata
if grep -q "wifi-reintegrator" "${SOS}"; then
    junit_pass "sos_kills_reintegrator"
else
    junit_fail "sos_no_kill" "SOS.sh no mata reintegrator"
fi

# Check 10: trap EXIT limpia PID file
if grep -q "trap.*PID_FILE.*EXIT" "${SCRIPT}"; then
    junit_pass "trap_cleans_pid"
else
    junit_fail "no_trap" "trap EXIT no limpia PID file"
fi

# Check 11: PID file en path estándar
if grep -q "mlvpn_wifi_reintegrator.pid" "${SCRIPT}"; then
    junit_pass "standard_pid_path"
else
    junit_fail "wrong_pid_path" "PID file no está en path estándar"
fi

# Check 12: hereda modo --failover (añade fallback_only=1 si otros
# links lo tienen)
if grep -q "failover_active" "${SCRIPT}" \
   && grep -qE 'grep.*fallback_only = 1.*ACTIVE_CONF' "${SCRIPT}"; then
    junit_pass "inherits_failover_mode"
else
    junit_fail "no_failover_inheritance" "no hereda modo --failover (REQ-NET-11)"
fi

junit_finalize
