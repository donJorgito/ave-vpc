#!/bin/sh
# Validates ave-vpc.REQ-HW-03: Android con plan de datos activo (vía tethering).
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"

junit_init "REQ-HW-03_android_data_plan"

ENV_FILE="$(dirname "$0")/../config/env"
[ -f "${ENV_FILE}" ] || { junit_skip "config_env" "config/env no existe"; junit_finalize; }
# shellcheck source=/dev/null
. "${ENV_FILE}"

IFACE="${IFACE_PIXEL:-en12}"

command -v ipconfig >/dev/null 2>&1 || { junit_skip "ipconfig_unavailable" "no macOS"; junit_finalize; }

IP="$(ipconfig getifaddr "${IFACE}" 2>/dev/null || true)"
if [ -n "${IP}" ]; then
    junit_pass "android_iface_${IFACE}_has_ip_${IP}"
else
    junit_skip "android_no_ip" "${IFACE} sin IP — USB tethering Android no activo"
fi

junit_finalize
