#!/bin/sh
# Validates ave-vpc.REQ-NET-16: selector throughput-aware (pasivo).
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-16_throughput_aware"

SELECTOR="$(dirname "$0")/../tools/seleccionar-mejor-enlace.sh"

[ -f "${SELECTOR}" ] || { junit_fail "selector_missing" "selector no existe"; junit_finalize; }

# Check 1: constantes definidas
if grep -q "^DEAD_LINK_THRESHOLD_S=15" "${SELECTOR}" \
   && grep -q "^MIN_TUNNEL_BPS_PER_TICK=5000" "${SELECTOR}" \
   && grep -q "^MIN_LINK_BPS_PER_TICK=500" "${SELECTOR}"; then
    junit_pass "constants_defined"
else
    junit_fail "constants_missing" "DEAD_LINK_THRESHOLD_S/MIN_TUNNEL_BPS/MIN_LINK_BPS no definidas"
fi

# Check 2: arrays asociativos de estado
if grep -q "declare -A PREV_BYTES" "${SELECTOR}" \
   && grep -q "declare -A DEAD_LINK_SINCE" "${SELECTOR}" \
   && grep -q "declare -A DEAD_LINK_EXCLUDED" "${SELECTOR}"; then
    junit_pass "state_arrays_defined"
else
    junit_fail "missing_state_arrays" "faltan arrays de estado throughput"
fi

# Check 3: función read_iface_bytes con manejo de MAC/sin-MAC
if grep -q "^read_iface_bytes()" "${SELECTOR}" \
   && grep -q 'netstat -ibn' "${SELECTOR}"; then
    junit_pass "read_iface_bytes_defined"
else
    junit_fail "no_read_iface" "función read_iface_bytes no definida"
fi

# Check 4: función find_mlvpn_utun
if grep -q "^find_mlvpn_utun()" "${SELECTOR}" \
   && grep -q "10\\\\.10\\\\.10\\\\." "${SELECTOR}"; then
    junit_pass "find_utun_defined"
else
    junit_fail "no_find_utun" "find_mlvpn_utun no definida"
fi

# Check 5: link_has_fallback_only para excluir backups
if grep -q "^link_has_fallback_only()" "${SELECTOR}"; then
    junit_pass "fallback_check_defined"
else
    junit_fail "no_fallback_check" "link_has_fallback_only no definida"
fi

# Check 6: update_throughput_state definida
if grep -q "^update_throughput_state()" "${SELECTOR}"; then
    junit_pass "update_throughput_defined"
else
    junit_fail "no_update_function" "update_throughput_state no definida"
fi

# Check 7: se llama EN CADA TICK (no solo en eval)
if awk '/^while :; do/,/^done$/' "${SELECTOR}" \
   | grep -q "update_throughput_state"; then
    junit_pass "called_each_tick"
else
    junit_fail "not_each_tick" "update_throughput_state no se llama cada tick"
fi

# Check 8: backups se excluyen del check (solo keepalives).
# El patrón puede ser multilínea: comprobamos que dentro de
# update_throughput_state se referencia is_backup Y hay un continue.
if awk '/^update_throughput_state\(\)/,/^}/' "${SELECTOR}" \
   | grep -q "is_backup"; then
    if awk '/^update_throughput_state\(\)/,/^}/' "${SELECTOR}" \
       | grep -A2 'is_backup' | grep -q "continue"; then
        junit_pass "backups_skipped"
    else
        junit_fail "backups_not_skipped" "is_backup detectado pero sin continue"
    fi
else
    junit_fail "backups_not_skipped" "no se referencia is_backup en update_throughput_state"
fi

# Check 9: evaluate_and_rotate excluye DEAD_LINK_EXCLUDED
if awk '/^evaluate_and_rotate\(\)/,/^}/' "${SELECTOR}" \
   | grep -q "DEAD_LINK_EXCLUDED"; then
    junit_pass "evaluate_excludes_dead"
else
    junit_fail "evaluate_includes_dead" "evaluate_and_rotate no excluye dead links"
fi

# Check 10: log de transiciones (excluido / reintegrado)
if grep -q "dead-link.*excluido" "${SELECTOR}" \
   && grep -q "throughput recuperado.*reintegrado" "${SELECTOR}"; then
    junit_pass "logs_transitions"
else
    junit_fail "no_transition_logs" "no se loguean transiciones de dead-link"
fi

# Check 11: marker DEAD en summary de rotación
if grep -q 'marker="DEAD"' "${SELECTOR}"; then
    junit_pass "dead_marker_in_summary"
else
    junit_fail "no_dead_marker" "summary de rotación no muestra marker DEAD"
fi

# Check 12: condición exacta tunnel_active + link_dead
if grep -q "tunnel_active.*-eq 1" "${SELECTOR}" \
   && grep -q "delta_link.*-lt.*MIN_LINK_BPS_PER_TICK" "${SELECTOR}"; then
    junit_pass "correct_dead_detection_condition"
else
    junit_fail "wrong_condition" "lógica de detección incorrecta"
fi

junit_finalize
