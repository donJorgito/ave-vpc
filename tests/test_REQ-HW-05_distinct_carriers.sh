#!/bin/sh
# Validates ave-vpc.REQ-HW-05: SIMs de operadoras distintas (recomendado).
# Verifica que las dos interfaces móviles tienen IPs en rangos privados
# distintos, lo que sugiere DHCP de operadores diferentes.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"

junit_init "REQ-HW-05_distinct_carriers"

ENV_FILE="$(dirname "$0")/../config/env"
[ -f "${ENV_FILE}" ] || { junit_skip "config_env" "config/env no existe"; junit_finalize; }
# shellcheck source=/dev/null
. "${ENV_FILE}"

command -v ipconfig >/dev/null 2>&1 || { junit_skip "no_macos" "ipconfig no disponible"; junit_finalize; }

IP_IPHONE="$(ipconfig getifaddr "${IFACE_IPHONE:-en8}" 2>/dev/null || true)"
IP_PIXEL="$(ipconfig getifaddr "${IFACE_PIXEL:-en12}" 2>/dev/null || true)"

if [ -z "${IP_IPHONE}" ] || [ -z "${IP_PIXEL}" ]; then
    junit_skip "moviles_no_conectados" "uno o ambos móviles sin IP — no se puede comparar"
    junit_finalize
fi

# Comparar primer octeto del subnet
SUB_IPHONE="${IP_IPHONE%%.*}"
SUB_PIXEL="${IP_PIXEL%%.*}"
if [ "${IP_IPHONE%.*}" != "${IP_PIXEL%.*}" ]; then
    junit_pass "distinct_subnets_${SUB_IPHONE}_vs_${SUB_PIXEL}"
else
    junit_fail "same_subnet" "ambos móviles en ${IP_IPHONE%.*}/24 — pueden ser del mismo operador"
fi

junit_finalize
