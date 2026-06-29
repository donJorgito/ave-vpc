#!/bin/sh
# Validates ave-vpc.REQ-NET-24: coexistencia mlvpn↔ubond con subnets distintas.
# Test estático: revisa configs y scripts para garantizar separación de subnet.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-24_coexistencia"

ROOT="$(dirname "$0")/.."
ENV_EXAMPLE="${ROOT}/config/env.example"

# 1. config/env.example define UBOND_TUN_VPS_IP en 10.10.20.x
if [ ! -r "${ENV_EXAMPLE}" ]; then
    junit_fail "env_example_missing" "config/env.example no existe"
    junit_finalize
fi

if grep -qE '^UBOND_TUN_VPS_IP="10\.10\.20\.[0-9]+"' "${ENV_EXAMPLE}" \
   && grep -qE '^UBOND_TUN_MAC_IP="10\.10\.20\.[0-9]+"' "${ENV_EXAMPLE}"; then
    junit_pass "env_example_defines_ubond_subnet"
else
    junit_fail "env_example_subnet" \
        "config/env.example no define UBOND_TUN_VPS_IP/MAC_IP en 10.10.20.x"
fi

# 2. mlvpn sigue en 10.10.10.x — separación clara
if grep -qE '^TUN_VPS_IP="10\.10\.10\.' "${ENV_EXAMPLE}" \
   && grep -qE '^TUN_MAC_IP="10\.10\.10\.' "${ENV_EXAMPLE}"; then
    junit_pass "mlvpn_subnet_unchanged"
else
    junit_fail "mlvpn_subnet" \
        "TUN_*_IP de mlvpn movidos accidentalmente fuera de 10.10.10.x"
fi

# 3. UBOND_TUN_* y TUN_* en subnets distintas
ubond_subnet="$(grep -oE 'UBOND_TUN_VPS_IP="[0-9.]+"' "${ENV_EXAMPLE}" \
                | head -1 | sed 's/.*"\([0-9]*\.[0-9]*\.[0-9]*\)\..*/\1/')"
mlvpn_subnet="$(grep -oE '^TUN_VPS_IP="[0-9.]+"'      "${ENV_EXAMPLE}" \
                | head -1 | sed 's/.*"\([0-9]*\.[0-9]*\.[0-9]*\)\..*/\1/')"
if [ -n "${ubond_subnet}" ] && [ -n "${mlvpn_subnet}" ] \
   && [ "${ubond_subnet}" != "${mlvpn_subnet}" ]; then
    junit_pass "subnets_disjoint"
else
    junit_fail "subnets_collide" \
        "ubond=${ubond_subnet} mlvpn=${mlvpn_subnet} (deben diferir)"
fi

# 4. 03b genera conf usando UBOND_TUN_*
SCRIPT_03B="${ROOT}/03b-setup-mac-ubond.sh"
if grep -qE 'ip4 = "\$\{UBOND_TUN_MAC_IP\}"' "${SCRIPT_03B}" \
   && grep -qE 'ip4_gateway = "\$\{UBOND_TUN_VPS_IP\}"' "${SCRIPT_03B}"; then
    junit_pass "03b_uses_ubond_tun"
else
    junit_fail "03b_wrong_tun" \
        "03b-setup-mac-ubond.sh no usa UBOND_TUN_* en la conf generada"
fi

# 5. 07b idem para servidor
SCRIPT_07B="${ROOT}/07b-setup-rpi-ubond.sh"
if grep -qE 'ip4 = "\$\{UBOND_TUN_VPS_IP\}"' "${SCRIPT_07B}" \
   && grep -qE 'ip4_gateway = "\$\{UBOND_TUN_MAC_IP\}"' "${SCRIPT_07B}"; then
    junit_pass "07b_uses_ubond_tun"
else
    junit_fail "07b_wrong_tun" \
        "07b-setup-rpi-ubond.sh no usa UBOND_TUN_* en la conf generada"
fi

# 6. 07b transporta UBOND_TUN_* al RPi via env del SSH
if grep -qE 'UBOND_TUN_VPS_IP="\$\{UBOND_TUN_VPS_IP' "${SCRIPT_07B}" \
   && grep -qE 'UBOND_TUN_MAC_IP="\$\{UBOND_TUN_MAC_IP' "${SCRIPT_07B}"; then
    junit_pass "07b_propagates_env"
else
    junit_fail "07b_no_env_propagation" \
        "07b no propaga UBOND_TUN_* al heredoc remoto del SSH"
fi

# 7. 04b configura utun cliente con UBOND_TUN_*
SCRIPT_04B="${ROOT}/04b-conectar-ubond.sh"
if grep -qE 'ifconfig.*UBOND_TUN_MAC_IP.*UBOND_TUN_VPS_IP' "${SCRIPT_04B}"; then
    junit_pass "04b_configures_utun"
else
    junit_fail "04b_wrong_ifconfig" \
        "04b-conectar-ubond.sh no configura el utun con UBOND_TUN_*"
fi

# 8. 04b verifica conectividad pinging UBOND_TUN_VPS_IP
if grep -qE 'ping.*"\$\{UBOND_TUN_VPS_IP\}"' "${SCRIPT_04B}"; then
    junit_pass "04b_pings_ubond_gateway"
else
    junit_fail "04b_pings_wrong" \
        "04b-conectar-ubond.sh no pinguea UBOND_TUN_VPS_IP"
fi

# 9. tools/lib/conf-gen.sh usa UBOND_TUN_*
LIB_CONF="${ROOT}/tools/lib/conf-gen.sh"
if grep -qE 'ip4 = "\$\{UBOND_TUN_MAC_IP' "${LIB_CONF}" \
   && grep -qE 'ip4_gateway = "\$\{UBOND_TUN_VPS_IP' "${LIB_CONF}"; then
    junit_pass "lib_conf_uses_ubond_tun"
else
    junit_fail "lib_conf_wrong" \
        "tools/lib/conf-gen.sh no usa UBOND_TUN_*"
fi

# 10. tools/lib/tests.sh pinguea UBOND_TUN_VPS_IP
LIB_TESTS="${ROOT}/tools/lib/tests.sh"
if grep -qE 'target="\$\{UBOND_TUN_VPS_IP' "${LIB_TESTS}"; then
    junit_pass "lib_tests_pings_ubond"
else
    junit_fail "lib_tests_wrong_target" \
        "tools/lib/tests.sh no pinguea UBOND_TUN_VPS_IP"
fi

# 11. Defaults sensibles: si UBOND_TUN_* no están en env, caer a 10.10.20.x
# (NO a 10.10.10.x). Evita regresar al bug accidentalmente.
bad_defaults=0
for f in "${SCRIPT_03B}" "${SCRIPT_04B}" "${SCRIPT_07B}" \
         "${LIB_CONF}" "${LIB_TESTS}" "${ROOT}/tools/lib/ubond-runner.sh"; do
    [ -r "${f}" ] || continue
    if grep -qE 'UBOND_TUN_(VPS|MAC)_IP:?-10\.10\.10\.' "${f}"; then
        bad_defaults=1
        break
    fi
done
if [ "${bad_defaults}" = 0 ]; then
    junit_pass "ubond_defaults_safe"
else
    junit_fail "ubond_defaults_collide" \
        "algún script tiene default UBOND_TUN_*:-10.10.10.x (regresión Bug #5)"
fi

junit_finalize
