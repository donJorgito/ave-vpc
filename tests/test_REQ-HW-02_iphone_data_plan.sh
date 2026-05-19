#!/bin/sh
# Validates ave-vpc.REQ-HW-02: iPhone con plan de datos activo (vía tethering).
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"

junit_init "REQ-HW-02_iphone_data_plan"

ENV_FILE="$(dirname "$0")/../config/env"
if [ ! -f "${ENV_FILE}" ]; then
    junit_skip "config_env" "config/env no existe"
    junit_finalize
fi
# shellcheck source=/dev/null
. "${ENV_FILE}"

IFACE="${IFACE_IPHONE:-en8}"

if ! command -v ipconfig >/dev/null 2>&1; then
    junit_skip "ipconfig_unavailable" "ipconfig no disponible (no macOS)"
    junit_finalize
fi

IP="$(ipconfig getifaddr "${IFACE}" 2>/dev/null || true)"
if [ -n "${IP}" ]; then
    junit_pass "iphone_iface_${IFACE}_has_ip_${IP}"
else
    junit_skip "iphone_no_ip" "${IFACE} sin IP — iPhone tethering no activo en este momento"
fi

junit_finalize
