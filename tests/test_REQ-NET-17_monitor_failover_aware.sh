#!/bin/sh
# Validates ave-vpc.REQ-NET-17: monitor consciente de modo --failover.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-17_monitor_failover_aware"

MONITOR="$(dirname "$0")/../08-monitor.py"

[ -f "${MONITOR}" ] || { junit_fail "monitor_missing" "08-monitor.py no existe"; junit_finalize; }

# Check 1: existe función check_failover_roles
if grep -q "^def check_failover_roles" "${MONITOR}"; then
    junit_pass "function_defined"
else
    junit_fail "no_function" "check_failover_roles no definida"
fi

# Check 2: lee mlvpn_active.conf
if grep -q "mlvpn_active.conf" "${MONITOR}"; then
    junit_pass "reads_active_conf"
else
    junit_fail "no_conf_read" "no lee mlvpn_active.conf"
fi

# Check 3: parsea fallback_only correctamente
if grep -qE "fallback_only.*\\\\s\\*=\\\\s\\*\\(\\\\d\\+\\)" "${MONITOR}"; then
    junit_pass "parses_fallback_only"
else
    junit_fail "no_fallback_parse" "no parsea fallback_only con regex"
fi

# Check 4: devuelve dict vacío si no hay backup (modo bonding)
if grep -q "has_any_backup" "${MONITOR}" \
   && grep -q "return roles if has_any_backup else {}" "${MONITOR}"; then
    junit_pass "empty_when_bonding"
else
    junit_fail "no_empty_check" "no devuelve {} en modo bonding clásico"
fi

# Check 5: fallback a sudo -n si fallan permisos
if grep -q "sudo.*-n.*cat" "${MONITOR}" \
   && grep -q "PermissionError" "${MONITOR}"; then
    junit_pass "sudo_fallback"
else
    junit_fail "no_sudo_fallback" "no intenta sudo -n cat si fallan permisos"
fi

# Check 6: draw() recibe failover_roles y muestra [FAILOVER]/[BONDING]
if grep -q "failover_roles" "${MONITOR}" \
   && grep -q "\[FAILOVER\]" "${MONITOR}" \
   && grep -q "\[BONDING\]" "${MONITOR}"; then
    junit_pass "header_mode_indicator"
else
    junit_fail "no_mode_indicator" "header no muestra [FAILOVER]/[BONDING]"
fi

# Check 7: muestra columna Rol con [A] / [B]
if grep -q '"Rol"' "${MONITOR}" \
   && grep -q '\[A\] ●' "${MONITOR}" \
   && grep -q '\[B\] ◌' "${MONITOR}"; then
    junit_pass "role_column"
else
    junit_fail "no_role_column" "falta columna Rol con [A]/[B]"
fi

# Check 8: resumen separa activo de backups (keepalives)
if grep -q "sum_active_rx" "${MONITOR}" \
   && grep -q "sum_backup_rx" "${MONITOR}"; then
    junit_pass "summary_separates_active_backup"
else
    junit_fail "no_separation" "resumen no separa activo de backups"
fi

# Check 9: main() llama check_failover_roles cada tick
if awk '/def main\(\)/,/^if __name__/' "${MONITOR}" \
   | grep -q "failover_roles = check_failover_roles"; then
    junit_pass "called_in_main_loop"
else
    junit_fail "not_in_loop" "check_failover_roles no se llama en el loop principal"
fi

# Check 10: bash -n equivalente para Python — comprobamos sintaxis
if python3 -m py_compile "${MONITOR}" 2>/dev/null; then
    junit_pass "python_syntax_ok"
else
    junit_fail "python_syntax_bad" "08-monitor.py tiene errores de sintaxis Python"
fi

junit_finalize
