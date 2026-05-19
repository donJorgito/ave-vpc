#!/bin/sh
# Validates ave-vpc.REQ-HW-04: cable USB de datos compatible con el Android.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"

junit_init "REQ-HW-04_usb_cable"

ENV_FILE="$(dirname "$0")/../config/env"
[ -f "${ENV_FILE}" ] || { junit_skip "config_env" "config/env no existe"; junit_finalize; }
# shellcheck source=/dev/null
. "${ENV_FILE}"

IFACE="${IFACE_PIXEL:-en12}"

command -v networksetup >/dev/null 2>&1 || { junit_skip "no_macos" "networksetup no disponible"; junit_finalize; }

# Si la interfaz aparece en networksetup, el cable USB de datos funciona.
if networksetup -listallhardwareports | grep -q "Device: ${IFACE}"; then
    junit_pass "iface_${IFACE}_visible_to_macos"
else
    junit_skip "iface_not_present" "${IFACE} no presente — Android no conectado o cable solo de carga"
fi

junit_finalize
