#!/bin/sh
# Validates ave-vpc.REQ-NET-15: detección de flapping de links.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-15_flap_detection"

SELECTOR="$(dirname "$0")/../tools/seleccionar-mejor-enlace.sh"

[ -f "${SELECTOR}" ] || { junit_fail "selector_missing" "selector no existe"; junit_finalize; }

# Check 1: constantes de flapping definidas
if grep -q "^FLAP_WINDOW_S=60" "${SELECTOR}" \
   && grep -q "^FLAP_THRESHOLD=4" "${SELECTOR}" \
   && grep -q "^FLAP_RECOVERY_S=30" "${SELECTOR}"; then
    junit_pass "flap_constants_defined"
else
    junit_fail "constants_missing" "FLAP_WINDOW_S/THRESHOLD/RECOVERY_S no están en valores esperados"
fi

# Check 2: estado de flapping con 4 maps asociativos
if grep -q "declare -A LAST_AUTH_STATE" "${SELECTOR}" \
   && grep -q "declare -A FLAP_TIMESTAMPS" "${SELECTOR}" \
   && grep -q "declare -A FLAP_EXCLUDED" "${SELECTOR}" \
   && grep -q "declare -A STABLE_SINCE" "${SELECTOR}"; then
    junit_pass "flap_state_arrays"
else
    junit_fail "missing_state_arrays" "faltan los 4 arrays asociativos de flapping"
fi

# Check 3: función update_flap_state
if grep -q "^update_flap_state()" "${SELECTOR}"; then
    junit_pass "update_flap_state_defined"
else
    junit_fail "no_update_function" "función update_flap_state no definida"
fi

# Check 4: se llama en cada tick (no solo eval)
# update_flap_state debe estar dentro del while infinito, antes del
# check de evaluate_and_rotate
if awk '/^while :; do/,/^done$/' "${SELECTOR}" | grep -q "update_flap_state"; then
    junit_pass "called_each_tick"
else
    junit_fail "not_called_each_tick" "update_flap_state no se llama en cada tick"
fi

# Check 5: detecta transiciones comparando con LAST_AUTH_STATE
if grep -q '"\${last}" != "\${now_auth}"' "${SELECTOR}"; then
    junit_pass "detects_transitions"
else
    junit_fail "no_transition_detection" "no se detectan transiciones @↔!"
fi

# Check 6: contador respeta ventana FLAP_WINDOW_S
if grep -q 'now - t.*FLAP_WINDOW_S' "${SELECTOR}"; then
    junit_pass "respects_window"
else
    junit_fail "no_window_cleanup" "no se limpian timestamps fuera de ventana"
fi

# Check 7: excluye link al superar FLAP_THRESHOLD
if grep -q "count.*-ge.*FLAP_THRESHOLD" "${SELECTOR}" \
   && grep -q "FLAP_EXCLUDED\[\$link\]=1" "${SELECTOR}"; then
    junit_pass "excludes_at_threshold"
else
    junit_fail "no_exclusion" "no se excluye link al superar threshold"
fi

# Check 8: reintegra tras FLAP_RECOVERY_S de @ estable
if grep -q "FLAP_RECOVERY_S" "${SELECTOR}" \
   && grep -q "FLAP_EXCLUDED\[\$link\]=0" "${SELECTOR}"; then
    junit_pass "reintegrates_after_recovery"
else
    junit_fail "no_recovery" "no se reintegra link tras estabilidad"
fi

# Check 9: evaluate_and_rotate excluye links flapping del cálculo
if awk '/^evaluate_and_rotate\(\)/,/^}$/' "${SELECTOR}" \
   | grep -q "FLAP_EXCLUDED.*-eq 1"; then
    junit_pass "evaluate_skips_flapping"
else
    junit_fail "evaluate_includes_flapping" "evaluate_and_rotate no excluye links flapping"
fi

# Check 10: log de transiciones de flapping
if grep -q "flapping.*excluido" "${SELECTOR}" \
   && grep -q "estable.*reintegrado" "${SELECTOR}"; then
    junit_pass "logs_flap_transitions"
else
    junit_fail "no_flap_logs" "no se loguean transiciones de flapping"
fi

junit_finalize
