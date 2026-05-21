#!/bin/sh
# Validates ave-vpc.REQ-NET-09: tuning de mlvpn para móvil 4G/5G.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-09_mlvpn_tuning"

ROOT="$(dirname "$0")/.."
SETUP_MAC="${ROOT}/03-setup-mac.sh"
SETUP_RPI="${ROOT}/07-setup-rpi.sh"
ENV_EXAMPLE="${ROOT}/config/env.example"

[ -f "${SETUP_MAC}" ] || { junit_fail "setup_mac_missing" "03-setup-mac.sh no existe"; junit_finalize; }
[ -f "${SETUP_RPI}" ] || { junit_fail "setup_rpi_missing" "07-setup-rpi.sh no existe"; junit_finalize; }
[ -f "${ENV_EXAMPLE}" ] || { junit_fail "env_example_missing" "config/env.example no existe"; junit_finalize; }

# Check 1: TUN_MTU=1400 en config/env.example
if grep -q '^TUN_MTU="1400"$' "${ENV_EXAMPLE}"; then
    junit_pass "tun_mtu_1400"
else
    junit_fail "tun_mtu_wrong" "TUN_MTU debe ser 1400 en config/env.example"
fi

# Check 2: el comentario sobre overhead/PMTU está presente en env.example
if grep -q "overhead" "${ENV_EXAMPLE}" \
   && grep -q -i "PMTU\|fragmenta" "${ENV_EXAMPLE}"; then
    junit_pass "tun_mtu_explanation"
else
    junit_fail "tun_mtu_comment_missing" "falta comentario explicando el cálculo de TUN_MTU"
fi

# Check 3: 03-setup-mac.sh emite loss_tolerence=30 y latency_tolerence=800 en [general]
if grep -q "^loss_tolerence = 30$" "${SETUP_MAC}" \
   && grep -q "^latency_tolerence = 800$" "${SETUP_MAC}"; then
    junit_pass "mac_global_tolerences"
else
    junit_fail "mac_global_tolerences_missing" "loss/latency_tolerence globales ausentes en 03-setup-mac.sh"
fi

# Check 4: 03-setup-mac.sh NO emite bandwidth_upload en los links
if grep -q "^bandwidth_upload" "${SETUP_MAC}"; then
    junit_fail "bandwidth_upload_present" "bandwidth_upload sigue presente en 03-setup-mac.sh — debe eliminarse para auto-balanceo"
else
    junit_pass "bandwidth_upload_removed"
fi

# Check 5: 07-setup-rpi.sh emite loss_tolerence=30 y latency_tolerence=800 en [general]
if grep -q "^loss_tolerence = 30$" "${SETUP_RPI}" \
   && grep -q "^latency_tolerence = 800$" "${SETUP_RPI}"; then
    junit_pass "rpi_global_tolerences"
else
    junit_fail "rpi_global_tolerences_missing" "loss/latency_tolerence globales ausentes en 07-setup-rpi.sh"
fi

# Check 6: el config generado documenta cuándo subir reorder_buffer_size
if grep -q "reorder_buffer_size" "${SETUP_MAC}" \
   && grep -q "freebuffer full" "${SETUP_MAC}"; then
    junit_pass "reorder_buffer_documented"
else
    junit_fail "reorder_buffer_undocumented" "falta guía de reorder_buffer_size en 03-setup-mac.sh"
fi

junit_finalize
