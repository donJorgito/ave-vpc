#!/bin/sh
# Validates ave-vpc.REQ-NET-43: wrapper de túnel ICMP (ptunnel-ng) — Vía E,
# link de vida para tunelar ubond a través del firewall del WiFi del AVE.
#
# Checks ESTÁTICOS (no arranca binarios, no toca red ni ICMP): el launcher
# existe, es ejecutable, expone --check/--stop/--server-cmd, idempotente
# (PID file + kill -0), no hardcodea IP pública, pinea versión, source
# config/env, exige root (raw ICMP), maneja el secreto -x con chmod 600 sin
# imprimirlo en el log de arranque, documenta el caveat lossy/last-resort, y
# pasa bash -n.
#
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-43_icmp_tunnel"

ROOT="$(dirname "$0")/.."
PTUNNEL="${ROOT}/tools/wrap-ptunnel.sh"

# 1. El script existe.
if [ -f "${PTUNNEL}" ]; then
    junit_pass "wrap_ptunnel_exists"
else
    junit_fail "wrap_ptunnel_missing" "falta tools/wrap-ptunnel.sh"
    junit_finalize
fi

# 2. Es ejecutable.
if [ -x "${PTUNNEL}" ]; then
    junit_pass "executable"
else
    junit_fail "not_executable" "wrap-ptunnel.sh sin +x (chmod +x)"
fi

# 3. set -uo pipefail.
if grep -q "set -uo pipefail" "${PTUNNEL}"; then
    junit_pass "set_pipefail"
else
    junit_fail "set_pipefail_missing" "no usa set -uo pipefail"
fi

# 4. Guard bash >= 4.
if grep -q "BASH_VERSINFO" "${PTUNNEL}"; then
    junit_pass "bash4_guard"
else
    junit_fail "bash4_guard_missing" "sin guard bash>=4"
fi

# 5. Expone --check, --stop, --server-cmd.
if grep -q -- "--check" "${PTUNNEL}" \
   && grep -q -- "--stop" "${PTUNNEL}" \
   && grep -q -- "--server-cmd" "${PTUNNEL}"; then
    junit_pass "flags_present"
else
    junit_fail "flags_missing" "no expone --check/--stop/--server-cmd"
fi

# 6. Idempotencia: PID file + kill -0 + "ya corriendo".
if grep -q "PID_FILE" "${PTUNNEL}" && grep -q "kill -0" "${PTUNNEL}" \
   && grep -qE "ya corriendo" "${PTUNNEL}"; then
    junit_pass "idempotent_double_launch"
else
    junit_fail "idempotent_missing" "sin rechazo de doble lanzamiento"
fi

# 7. logger -t (house style).
if grep -q "logger -t" "${PTUNNEL}"; then
    junit_pass "logger_tag"
else
    junit_fail "logger_missing" "no usa logger -t"
fi

# 8. Source config/env (VPS_IP + UBOND_PORT_3) sin IP pública hardcodeada.
uses_cfg=0
grep -q "VPS_IP" "${PTUNNEL}" && grep -q "UBOND_PORT_3" "${PTUNNEL}" && uses_cfg=1
hardcoded=0
# Solo codigo ejecutable: se ignoran comentarios (Rule 4 permite IPs en
# docs/comentarios, p.ej. la referencia a evidencia 1.1.1.1 del trayecto).
if grep -vE '^\s*#|_PINNED_VERSION|versión|version' "${PTUNNEL}" \
    | sed 's/#.*//' \
    | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
    | grep -vE '^(127\.0\.0\.1|0\.0\.0\.0)$' \
    | grep -q '.'; then
    hardcoded=1
fi
if [ "${uses_cfg}" -eq 1 ] && [ "${hardcoded}" -eq 0 ]; then
    junit_pass "no_hardcoded_ip"
else
    junit_fail "hardcoded_or_no_config" "hardcodea IP o no consume VPS_IP/UBOND_PORT_3"
fi

# 9. Versión PINNED.
if grep -qE "PINNED_VERSION=" "${PTUNNEL}"; then
    junit_pass "pinned_version"
else
    junit_fail "pinned_version_missing" "no declara versión PINNED"
fi

# 10. Imprime comando server-side (ptunnel-ng) a ejecutar en la RPi.
if grep -q "print_server_cmd" "${PTUNNEL}" \
   && grep -qE "ejecutar en la RPi" "${PTUNNEL}" \
   && grep -q "ptunnel-ng" "${PTUNNEL}"; then
    junit_pass "server_cmd_printed"
else
    junit_fail "server_cmd_missing" "no imprime el comando ptunnel-ng server-side"
fi

# 11. NO hace ssh.
if grep -qE "^[[:space:]]*ssh " "${PTUNNEL}"; then
    junit_fail "does_ssh" "ejecuta ssh — debe solo imprimir el comando"
else
    junit_pass "no_ssh"
fi

# 12. Usa ICMP/raw + exige root.
if grep -qiE "ICMP" "${PTUNNEL}" \
   && grep -qE "EUID.*-ne 0|requiere root" "${PTUNNEL}"; then
    junit_pass "icmp_and_root"
else
    junit_fail "icmp_root_missing" "no usa ICMP o no exige root"
fi

# 13. Documenta el caveat lossy / último recurso (no ancho de banda).
if grep -qiE "loss|lossy|último recurso|last.resort|keepalive" "${PTUNNEL}" \
   && grep -qiE "no.*ancho de banda|no.*bandwidth|NO es para ancho" "${PTUNNEL}"; then
    junit_pass "lossy_caveat_documented"
else
    junit_fail "lossy_caveat_missing" "no documenta el caveat lossy/last-resort"
fi

# 14. Secreto -x: chmod 600 y NO impreso en el log de arranque.
if grep -q "chmod 600" "${PTUNNEL}" \
   && grep -qE "NO imprimir|NO se imprime|no.*imprim" "${PTUNNEL}"; then
    junit_pass "secret_handling"
else
    junit_fail "secret_handling_missing" "no protege el -x (chmod 600 + no log en arranque)"
fi

# 15. Sintaxis bash válida.
if bash -n "${PTUNNEL}" 2>/dev/null; then
    junit_pass "bash_syntax_ok"
else
    junit_fail "bash_syntax_fail" "errores de sintaxis bash"
fi

junit_finalize
