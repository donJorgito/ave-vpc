#!/bin/sh
# Validates ave-vpc.REQ-NET-10: calibración dinámica de pesos WRR.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-10_dynamic_calibration"

ROOT="$(dirname "$0")/.."
CALIB="${ROOT}/tools/calibrar-enlaces-dinamico.sh"
CONNECT="${ROOT}/04-conectar.sh"
DISCONNECT="${ROOT}/05-desconectar.sh"

# Check 1: el script existe y es ejecutable
if [ -x "${CALIB}" ]; then
    junit_pass "calibrator_executable"
else
    junit_fail "calibrator_missing" "tools/calibrar-enlaces-dinamico.sh no existe o no es ejecutable"
    junit_finalize
fi

# Check 2: pasa bash -n
if bash -n "${CALIB}" 2>/dev/null; then
    junit_pass "calibrator_syntax_ok"
else
    junit_fail "calibrator_syntax_bad" "tools/calibrar-enlaces-dinamico.sh tiene errores de sintaxis"
fi

# Check 3: usa ping con -S (sin curl periódico — descartado por costoso)
if grep -q 'ping -c 1 -t 1 -W 1500 -S' "${CALIB}" \
   && ! grep -q 'curl.*--max-time.*--interface.*&$' "${CALIB}"; then
    junit_pass "ping_only_no_periodic_curl"
else
    junit_fail "wrong_measurement_method" "el calibrador debe usar solo ping (no curl periódico)"
fi

# Check 4: ventana deslizante de 12 muestras
if grep -q "^WINDOW_SIZE=12" "${CALIB}"; then
    junit_pass "sliding_window_12"
else
    junit_fail "window_size_wrong" "WINDOW_SIZE debe ser 12 (= 60s con TICK 5s)"
fi

# Check 5: recalibra cada 30 s (RECALC_EVERY=6 ticks de 5s)
if grep -q "^RECALC_EVERY=6" "${CALIB}" \
   && grep -q "^TICK_INTERVAL=5" "${CALIB}"; then
    junit_pass "recalc_period_30s"
else
    junit_fail "recalc_period_wrong" "RECALC_EVERY=6 + TICK_INTERVAL=5 = 30s ausentes"
fi

# Check 6: solo aplica cambios si diff >25%
if grep -q 'diff_pct.*-gt 25' "${CALIB}"; then
    junit_pass "hysteresis_25pct"
else
    junit_fail "no_hysteresis" "falta histeresis de 25 % para evitar SIGHUP excesivos"
fi

# Check 7: histeresis temporal SUSTAINED_FAIL_S para fallback_only
if grep -q "^SUSTAINED_FAIL_S=60" "${CALIB}"; then
    junit_pass "sustained_fail_60s"
else
    junit_fail "no_sustained_threshold" "SUSTAINED_FAIL_S=60 ausente"
fi

# Check 8: SIGHUP a mlvpn [priv]
if grep -q 'kill -HUP.*priv_pid' "${CALIB}" \
   && grep -q "pgrep -f 'mlvpn: mlvpn0 \\\\\\[priv\\\\\\]'" "${CALIB}"; then
    junit_pass "sighup_to_priv_process"
else
    junit_fail "no_sighup" "no manda SIGHUP al proceso mlvpn [priv]"
fi

# Check 9: el script auxiliar sigue disponible en tools/ aunque
# 04-conectar.sh ya no lo lance (deprecated en favor de
# tools/seleccionar-mejor-enlace.sh, REQ-NET-11). Mantenemos el
# script para casos de uso experimentales fuera del flujo principal.
# Verificamos que SI se referenciara, está como bloque comentado o
# referencia documental — no que esté activamente lanzado.
if grep -q 'calibrar-enlaces-dinamico' "${CONNECT}" \
   || [ -x "${ROOT}/tools/calibrar-enlaces-dinamico.sh" ]; then
    junit_pass "calibrator_available_for_manual_use"
else
    junit_fail "calibrator_disappeared" "calibrador eliminado del repo"
fi

# Check 10: 05-desconectar.sh mata el calibrador antes de mlvpn
LINE_KILL=$(grep -n "mlvpn_calibrator.pid" "${DISCONNECT}" | head -1 | cut -d: -f1)
LINE_PKILL=$(grep -n 'pkill -f "mlvpn: mlvpn0"' "${DISCONNECT}" | head -1 | cut -d: -f1)
if [ -n "${LINE_KILL}" ] && [ -n "${LINE_PKILL}" ] && [ "${LINE_KILL}" -lt "${LINE_PKILL}" ]; then
    junit_pass "disconnect_kills_calibrator_first"
else
    junit_fail "disconnect_order_wrong" "05-desconectar.sh debe matar el calibrador ANTES que mlvpn"
fi

# Check 11: trap EXIT limpia el PID file
if grep -q "trap.*PID_FILE.*EXIT" "${CALIB}"; then
    junit_pass "trap_cleans_pid_file"
else
    junit_fail "no_pid_cleanup" "el calibrador no limpia su PID file en exit"
fi

junit_finalize
