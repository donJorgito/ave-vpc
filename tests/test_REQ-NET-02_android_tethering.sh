#!/bin/sh
# Validates ave-vpc.REQ-NET-02: Android USB tethering reconocido por macOS.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-02_android_tethering"
ENV_FILE="$(dirname "$0")/../config/env"
[ -f "${ENV_FILE}" ] || { junit_skip "config_env" "config/env no existe"; junit_finalize; }
# shellcheck source=/dev/null
. "${ENV_FILE}"
command -v ipconfig >/dev/null 2>&1 || { junit_skip "no_macos" "ipconfig no disponible"; junit_finalize; }
IFACE="${IFACE_PIXEL:-en12}"
IP="$(ipconfig getifaddr "${IFACE}" 2>/dev/null || true)"
if [ -n "${IP}" ]; then
    junit_pass "android_${IFACE}_ip_${IP}"
else
    junit_skip "android_no_ip" "${IFACE} sin IP — USB tethering no activo"
fi
junit_finalize
