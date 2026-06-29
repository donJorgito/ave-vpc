#!/bin/sh
# Validates ave-vpc.REQ-NET-42: wrapper de túnel DNS (iodine) — Vía D, link de
# vida para tunelar ubond a través del firewall del WiFi del AVE.
#
# Checks ESTÁTICOS (no arranca binarios, no toca red ni DNS): el launcher
# existe, es ejecutable, expone --check/--stop/--server-cmd, idempotente
# (PID file + kill -0), no hardcodea IP pública, pinea versión, source
# config/env, exige root (TUN), maneja el secreto -P con chmod 600 sin
# imprimirlo en el log de arranque, documenta la delegación NS, y pasa bash -n.
#
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-42_dns_tunnel"

ROOT="$(dirname "$0")/.."
IODINE="${ROOT}/tools/wrap-iodine.sh"

# 1. El script existe.
if [ -f "${IODINE}" ]; then
    junit_pass "wrap_iodine_exists"
else
    junit_fail "wrap_iodine_missing" "falta tools/wrap-iodine.sh"
    junit_finalize
fi

# 2. Es ejecutable.
if [ -x "${IODINE}" ]; then
    junit_pass "executable"
else
    junit_fail "not_executable" "wrap-iodine.sh sin +x (chmod +x)"
fi

# 3. set -uo pipefail.
if grep -q "set -uo pipefail" "${IODINE}"; then
    junit_pass "set_pipefail"
else
    junit_fail "set_pipefail_missing" "no usa set -uo pipefail"
fi

# 4. Guard bash >= 4.
if grep -q "BASH_VERSINFO" "${IODINE}"; then
    junit_pass "bash4_guard"
else
    junit_fail "bash4_guard_missing" "sin guard bash>=4"
fi

# 5. Expone --check, --stop, --server-cmd.
if grep -q -- "--check" "${IODINE}" \
   && grep -q -- "--stop" "${IODINE}" \
   && grep -q -- "--server-cmd" "${IODINE}"; then
    junit_pass "flags_present"
else
    junit_fail "flags_missing" "no expone --check/--stop/--server-cmd"
fi

# 6. Idempotencia: PID file + kill -0 + "ya corriendo".
if grep -q "PID_FILE" "${IODINE}" && grep -q "kill -0" "${IODINE}" \
   && grep -qE "ya corriendo" "${IODINE}"; then
    junit_pass "idempotent_double_launch"
else
    junit_fail "idempotent_missing" "sin rechazo de doble lanzamiento"
fi

# 7. logger -t (house style).
if grep -q "logger -t" "${IODINE}"; then
    junit_pass "logger_tag"
else
    junit_fail "logger_missing" "no usa logger -t"
fi

# 8. Source config/env (VPS_IP + UBOND_PORT_3) sin IP pública hardcodeada.
uses_cfg=0
grep -q "VPS_IP" "${IODINE}" && grep -q "UBOND_PORT_3" "${IODINE}" && uses_cfg=1
hardcoded=0
# Solo codigo ejecutable: se ignoran comentarios (Rule 4 permite IPs en
# docs/comentarios) y la red interna del tunel con override por env.
if grep -vE '^\s*#|_PINNED_VERSION|versión|version' "${IODINE}" \
    | sed 's/#.*//' \
    | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
    | grep -vE '^(127\.0\.0\.1|0\.0\.0\.0|172\.16\.30\.0)$' \
    | grep -q '.'; then
    hardcoded=1
fi
if [ "${uses_cfg}" -eq 1 ] && [ "${hardcoded}" -eq 0 ]; then
    junit_pass "no_hardcoded_ip"
else
    junit_fail "hardcoded_or_no_config" "hardcodea IP o no consume VPS_IP/UBOND_PORT_3"
fi

# 9. Versión PINNED.
if grep -qE "PINNED_VERSION=" "${IODINE}"; then
    junit_pass "pinned_version"
else
    junit_fail "pinned_version_missing" "no declara versión PINNED"
fi

# 10. Imprime comando server-side (iodined) a ejecutar en la RPi.
if grep -q "print_server_cmd" "${IODINE}" \
   && grep -qE "ejecutar en la RPi" "${IODINE}" \
   && grep -q "iodined" "${IODINE}"; then
    junit_pass "server_cmd_printed"
else
    junit_fail "server_cmd_missing" "no imprime el comando iodined server-side"
fi

# 11. NO hace ssh.
if grep -qE "^[[:space:]]*ssh " "${IODINE}"; then
    junit_fail "does_ssh" "ejecuta ssh — debe solo imprimir el comando"
else
    junit_pass "no_ssh"
fi

# 12. Subdominio configurable + exige root (TUN).
if grep -q "IODINE_SUBDOMAIN" "${IODINE}" \
   && grep -qE "EUID.*-ne 0|requiere root" "${IODINE}"; then
    junit_pass "subdomain_and_root"
else
    junit_fail "subdomain_root_missing" "sin IODINE_SUBDOMAIN configurable o no exige root"
fi

# 13. Documenta la delegación NS como prerrequisito del operador.
if grep -qiE "delegaci.n NS|deleg" "${IODINE}" && grep -qi "deSEC" "${IODINE}"; then
    junit_pass "ns_delegation_documented"
else
    junit_fail "ns_delegation_missing" "no documenta la delegación NS en deSEC"
fi

# 14. Secreto -P: chmod 600 y NO impreso en el log de arranque.
if grep -q "chmod 600" "${IODINE}" \
   && grep -qE "NO imprimir|NO se imprime|no.*imprim" "${IODINE}"; then
    junit_pass "secret_handling"
else
    junit_fail "secret_handling_missing" "no protege el -P (chmod 600 + no log en arranque)"
fi

# 15. Sintaxis bash válida.
if bash -n "${IODINE}" 2>/dev/null; then
    junit_pass "bash_syntax_ok"
else
    junit_fail "bash_syntax_fail" "errores de sintaxis bash"
fi

junit_finalize
