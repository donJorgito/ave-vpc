#!/bin/sh
# Validates ave-vpc.REQ-NET-38: Listener multipuerto en RPi (T1) + probe del firewall (Vía F).
# Checks estáticos/estructurales — no requiere RPi viva ni WiFi tren.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-38_multiport_listener"

ROOT="$(dirname "$0")/.."
LISTENER="${ROOT}/tools/rpi-multiport-listener.sh"
PROBE="${ROOT}/tools/probe-firewall.sh"

# --- 1. Ambos scripts existen ---
if [ -f "${LISTENER}" ]; then junit_pass "listener_exists"; else junit_fail "listener_exists" "falta ${LISTENER}"; fi
if [ -f "${PROBE}" ]; then junit_pass "probe_exists"; else junit_fail "probe_exists" "falta ${PROBE}"; fi

# Si falta alguno, no tiene sentido seguir con greps.
if [ ! -f "${LISTENER}" ] || [ ! -f "${PROBE}" ]; then
    junit_finalize
fi

# --- 2. Ejecutables ---
if [ -x "${LISTENER}" ]; then junit_pass "listener_executable"; else junit_fail "listener_executable" "rpi-multiport-listener.sh no +x"; fi
if [ -x "${PROBE}" ]; then junit_pass "probe_executable"; else junit_fail "probe_executable" "probe-firewall.sh no +x"; fi

# --- 3. set -uo pipefail (Rule IDLC bash) ---
if grep -q "set -uo pipefail" "${LISTENER}"; then junit_pass "listener_set_flags"; else junit_fail "listener_set_flags" "sin set -uo pipefail"; fi
if grep -q "set -uo pipefail" "${PROBE}"; then junit_pass "probe_set_flags"; else junit_fail "probe_set_flags" "sin set -uo pipefail"; fi

# --- 4. Embeben el REQ-ID ---
if grep -q "REQ-NET-38" "${LISTENER}"; then junit_pass "listener_req_id"; else junit_fail "listener_req_id" "sin REQ-NET-38"; fi
if grep -q "REQ-NET-38" "${PROBE}"; then junit_pass "probe_req_id"; else junit_fail "probe_req_id" "sin REQ-NET-38"; fi

# --- 5. Sintaxis bash OK (bash -n) ---
if command -v bash >/dev/null 2>&1; then
    if bash -n "${LISTENER}" 2>/dev/null; then junit_pass "listener_bash_syntax"; else junit_fail "listener_bash_syntax" "bash -n falla"; fi
    if bash -n "${PROBE}" 2>/dev/null; then junit_pass "probe_bash_syntax"; else junit_fail "probe_bash_syntax" "bash -n falla"; fi
else
    junit_skip "bash_syntax" "bash no disponible"
fi

# --- 6. Listener: guard del puerto 22 (no debe bindearse SSH) ---
if grep -q "_guard_no_ssh" "${LISTENER}"; then junit_pass "listener_guard_ssh"; else junit_fail "listener_guard_ssh" "sin guard del puerto 22"; fi

# --- 7. Listener: set de puertos esperado por defecto ---
EXPECTED_PORTS="80 443 853 993 2222 8080 8443 9001 9999"
if grep -q "${EXPECTED_PORTS}" "${LISTENER}"; then junit_pass "listener_default_ports"; else junit_fail "listener_default_ports" "set por defecto != '${EXPECTED_PORTS}'"; fi

# --- 8. Listener: eco identificable con tag + port + proto ---
if grep -q "AVE-VPC-LISTENER" "${LISTENER}"; then junit_pass "listener_echo_tag"; else junit_fail "listener_echo_tag" "sin tag AVE-VPC-LISTENER"; fi

# --- 9. Listener: subcomandos run/start/stop/status/install/uninstall ---
MISSING=""
for sub in run start stop status install uninstall; do
    grep -q "${sub})" "${LISTENER}" || MISSING="${MISSING} ${sub}"
done
if [ -z "${MISSING}" ]; then junit_pass "listener_subcommands"; else junit_fail "listener_subcommands" "faltan:${MISSING}"; fi

# --- 10. Listener: unit systemd embebida en install ---
if grep -q "ave-vpc-listener.service" "${LISTENER}" && grep -q "ExecStart=" "${LISTENER}"; then
    junit_pass "listener_systemd_unit"
else
    junit_fail "listener_systemd_unit" "sin unit systemd embebida"
fi

# --- 11. Probe: lee IFACE_WIFI y VPS_IP de config/env (sin hardcoding) ---
if grep -q "IFACE_WIFI" "${PROBE}" && grep -q "VPS_IP" "${PROBE}"; then
    junit_pass "probe_reads_config"
else
    junit_fail "probe_reads_config" "no lee IFACE_WIFI/VPS_IP de config"
fi

# --- 12. Probe: sin IPs IPv4 literales hardcodeadas (Rule 4 IDLC) ---
# Excluimos 0.0.0.0 (no aplica al probe) y comentarios de versión.
if grep -E '"[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}"' "${PROBE}" >/dev/null 2>&1; then
    junit_fail "probe_no_hardcoded_ip" "IP literal encontrada en probe-firewall.sh"
else
    junit_pass "probe_no_hardcoded_ip"
fi

# --- 13. Probe: clasificación PASS/DNAT/SILENT presente ---
if grep -q "PASS" "${PROBE}" && grep -q "DNAT" "${PROBE}" && grep -q "SILENT" "${PROBE}"; then
    junit_pass "probe_classification"
else
    junit_fail "probe_classification" "faltan estados PASS/DNAT/SILENT"
fi

# --- 14. Probe: lógica DNAT = respuesta presente pero != eco esperado ---
if grep -q "classify" "${PROBE}"; then junit_pass "probe_dnat_logic"; else junit_fail "probe_dnat_logic" "sin función classify()"; fi

# --- 15. Probe: source forzado a la iface WiFi (nc -s / ping -b) ---
if grep -q "nc -s" "${PROBE}" || grep -q 'nc -u -s' "${PROBE}"; then
    junit_pass "probe_bind_iface"
else
    junit_fail "probe_bind_iface" "no fuerza source a la iface WiFi"
fi

junit_finalize
