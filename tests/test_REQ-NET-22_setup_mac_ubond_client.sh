#!/bin/sh
# Validates ave-vpc.REQ-NET-22: cliente ubond paralelo a mlvpn.
# Test estático del 04b-conectar-ubond.sh.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-22_setup_mac_ubond_client"

ROOT="$(dirname "$0")/.."
SCRIPT="${ROOT}/04b-conectar-ubond.sh"

[ -f "${SCRIPT}" ] || { junit_fail "missing" "04b-conectar-ubond.sh no existe"; junit_finalize; }

# Check 1: ejecutable y bash -n OK
if [ -x "${SCRIPT}" ] && bash -n "${SCRIPT}" 2>/dev/null; then
    junit_pass "syntax_and_perms_ok"
else
    junit_fail "syntax_bad" "no ejecutable o sintaxis errónea"
    junit_finalize
fi

# Check 2: requiere sudo (EUID check)
if grep -qE 'EUID.*-ne 0|"\${EUID}".*-ne 0' "${SCRIPT}"; then
    junit_pass "requires_sudo"
else
    junit_fail "no_sudo_check" "no comprueba EUID"
fi

# Check 3: lee generated/ubond.conf (no mlvpn.conf)
if grep -q 'generated/ubond.conf\|GENERATED_DIR.*ubond.conf' "${SCRIPT}" \
   && ! grep -q 'GENERATED_DIR.*mlvpn.conf' "${SCRIPT}"; then
    junit_pass "reads_ubond_conf"
else
    junit_fail "wrong_config" "no lee ubond.conf (o lee mlvpn.conf)"
fi

# Check 4: arranca /usr/local/sbin/ubond (no mlvpn binary)
if grep -q '/usr/local/sbin/ubond' "${SCRIPT}" \
   && ! grep -qE '"\$\{?MLVPN_BIN' "${SCRIPT}"; then
    junit_pass "starts_ubond_binary"
else
    junit_fail "wrong_binary" "no arranca /usr/local/sbin/ubond"
fi

# Check 5: --name ubond0 (interfaz tun distinta a mlvpn0)
if grep -q -- '--name ubond0' "${SCRIPT}"; then
    junit_pass "name_ubond0"
else
    junit_fail "wrong_name" "no usa --name ubond0"
fi

# Check 6: --user ubond (no --user mlvpn)
if grep -q -- '--user ubond' "${SCRIPT}"; then
    junit_pass "user_ubond"
else
    junit_fail "wrong_user" "no usa --user ubond"
fi

# Check 7: puertos UDP 5083/5084/5085 por defecto
if grep -qE 'UBOND_PORT_1.*5083' "${SCRIPT}" \
   && grep -qE 'UBOND_PORT_2.*5084' "${SCRIPT}" \
   && grep -qE 'UBOND_PORT_3.*5085' "${SCRIPT}"; then
    junit_pass "ubond_ports_distinct_from_mlvpn"
else
    junit_fail "wrong_ports" "puertos no son 5083/5084/5085"
fi

# Check 8: cleanup defensivo busca 'ubond: ubond0' (no mlvpn: mlvpn0)
if grep -q 'pgrep -f "ubond: ubond0"\|pkill -f "ubond: ubond0"' "${SCRIPT}"; then
    junit_pass "defensive_cleanup_ubond"
else
    junit_fail "no_cleanup" "no hace cleanup de instancias ubond previas"
fi

# Check 9: NO toca mlvpn (no kill mlvpn, no escribir mlvpn_active.conf)
if ! grep -qE 'pkill.*mlvpn|kill.*mlvpn\.pid|generated/mlvpn_active' "${SCRIPT}"; then
    junit_pass "preserves_mlvpn"
else
    junit_fail "touches_mlvpn" "el script altera estado de mlvpn"
fi

# Check 10: pre-flight WiFi (captive + hairpin NAT)
if grep -q 'captive.apple.com' "${SCRIPT}" \
   && grep -q 'hairpin' "${SCRIPT}"; then
    junit_pass "wifi_preflight"
else
    junit_fail "no_preflight" "falta pre-flight WiFi (captive o hairpin)"
fi

# Check 11: genera ubond_active.conf desde ubond.conf
if grep -q 'cp.*ubond.conf.*ubond_active.conf\|generated/ubond_active.conf' "${SCRIPT}"; then
    junit_pass "generates_active_conf"
else
    junit_fail "no_active_conf" "no genera ubond_active.conf"
fi

# Check 12: rutas ifscope al VPS_IP (anti-loop)
if grep -q 'route.*ifscope.*VPS_IP\|route.*-host.*VPS_IP.*ifscope' "${SCRIPT}"; then
    junit_pass "ifscope_routes"
else
    junit_fail "no_ifscope" "no crea rutas ifscope al VPS"
fi

# Check 13: sustituye PLACEHOLDER_*_IP en config
if grep -q 'PLACEHOLDER_IPHONE_IP' "${SCRIPT}" \
   && grep -q 'PLACEHOLDER_PIXEL_IP' "${SCRIPT}"; then
    junit_pass "placeholder_substitution"
else
    junit_fail "no_substitution" "no sustituye PLACEHOLDER_*_IP"
fi

# Check 14: guarda PID en generated/ubond.pid
if grep -q 'generated/ubond.pid\|GENERATED_DIR.*ubond.pid' "${SCRIPT}"; then
    junit_pass "saves_pid"
else
    junit_fail "no_pid" "no guarda PID en ubond.pid"
fi

junit_finalize
