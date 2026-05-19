#!/bin/sh
# Validates ave-vpc.REQ-MAC-01: helper sudo askpass para Macs Jamf/MDM.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-MAC-01_sudo_askpass"
SETUP="$(dirname "$0")/../03-setup-mac.sh"
[ -f "${SETUP}" ] || { junit_fail "script_missing" "03-setup-mac.sh no existe"; junit_finalize; }
# Verifica que 03-setup-mac.sh genera el helper askpass
if grep -q "/tmp/sudo-askpass.sh" "${SETUP}" && grep -q "osascript" "${SETUP}"; then
    junit_pass "askpass_generation_in_03_setup_mac"
else
    junit_fail "askpass_missing" "03-setup-mac.sh no genera /tmp/sudo-askpass.sh con osascript"
fi
# Si está disponible, verifica que existe y tiene permisos correctos
if [ -f "/tmp/sudo-askpass.sh" ]; then
    PERMS=$(stat -f "%OLp" /tmp/sudo-askpass.sh 2>/dev/null || stat -c "%a" /tmp/sudo-askpass.sh 2>/dev/null)
    if [ "${PERMS}" = "700" ]; then
        junit_pass "askpass_file_700_perms"
    else
        junit_fail "askpass_perms_${PERMS}" "esperado 700, real ${PERMS}"
    fi
else
    junit_skip "askpass_file_missing" "/tmp/sudo-askpass.sh no creado todavía (CI o setup pendiente)"
fi
junit_finalize
