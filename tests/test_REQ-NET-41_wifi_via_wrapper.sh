#!/bin/sh
# Validates ave-vpc.REQ-NET-41: enlace WiFi de ubond enrutable a través de un
# wrapper local (modo OPT-IN WIFI_VIA_WRAPPER) sin regresionar el path directo.
# Checks estáticos/estructurales — NO requiere ubond corriendo ni WiFi tren.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-41_wifi_via_wrapper"

ROOT="$(dirname "$0")/.."
CONNECT="${ROOT}/04b-conectar-ubond.sh"
REINTEG="${ROOT}/tools/wifi-reintegrator.sh"

# --- 1. Ambos ficheros existen ---
if [ -f "${CONNECT}" ]; then junit_pass "04b_exists"; else junit_fail "04b_exists" "falta ${CONNECT}"; fi
if [ -f "${REINTEG}" ]; then junit_pass "reintegrator_exists"; else junit_fail "reintegrator_exists" "falta ${REINTEG}"; fi

if [ ! -f "${CONNECT}" ] || [ ! -f "${REINTEG}" ]; then
    junit_finalize
fi

# --- 2. Embeben el REQ-ID ---
if grep -q "REQ-NET-41" "${CONNECT}"; then junit_pass "04b_req_id"; else junit_fail "04b_req_id" "sin REQ-NET-41"; fi
if grep -q "REQ-NET-41" "${REINTEG}"; then junit_pass "reintegrator_req_id"; else junit_fail "reintegrator_req_id" "sin REQ-NET-41"; fi

# --- 3. Variable OPT-IN WIFI_VIA_WRAPPER con default 0 (OFF) ---
if grep -q 'WIFI_VIA_WRAPPER="${WIFI_VIA_WRAPPER:-0}"' "${CONNECT}"; then
    junit_pass "04b_optin_default_off"
else
    junit_fail "04b_optin_default_off" "no define WIFI_VIA_WRAPPER con default 0"
fi
if grep -q 'WIFI_VIA_WRAPPER="${WIFI_VIA_WRAPPER:-0}"' "${REINTEG}"; then
    junit_pass "reintegrator_optin_default_off"
else
    junit_fail "reintegrator_optin_default_off" "no define WIFI_VIA_WRAPPER con default 0"
fi

# --- 4. WRAP_LOCAL_PORT: misma variable que los wrappers (coherencia) ---
if grep -q 'WRAP_LOCAL_PORT="${WRAP_LOCAL_PORT:-' "${CONNECT}"; then
    junit_pass "04b_wrap_local_port"
else
    junit_fail "04b_wrap_local_port" "no define WRAP_LOCAL_PORT con default desde env"
fi

# --- 5. PATH POR DEFECTO INTACTO: el [links.wifi] directo sigue escribiendo
#        remotehost = "${VPS_IP}" y remoteport = ${UBOND_PORT_3_REMOTE} ---
if grep -q 'remotehost = "${VPS_IP}"' "${CONNECT}" && grep -q 'remoteport = ${UBOND_PORT_3_REMOTE}' "${CONNECT}"; then
    junit_pass "04b_default_path_unchanged"
else
    junit_fail "04b_default_path_unchanged" "el path directo (VPS_IP / UBOND_PORT_3_REMOTE) ya no está presente"
fi
# Reintegrator: rama mlvpn por defecto sigue escribiendo VPS_IP / MLVPN_PORT_3_REMOTE
if grep -q 'remotehost = "${VPS_IP}"' "${REINTEG}" && grep -q 'remoteport = ${MLVPN_PORT_3_REMOTE}' "${REINTEG}"; then
    junit_pass "reintegrator_default_path_unchanged"
else
    junit_fail "reintegrator_default_path_unchanged" "rama mlvpn directa alterada"
fi

# --- 6. RAMA WRAPPER: escribe remotehost = "127.0.0.1" y remoteport = WRAP_LOCAL_PORT ---
if grep -q 'remotehost = "127.0.0.1"' "${CONNECT}" && grep -q 'remoteport = ${WRAP_LOCAL_PORT}' "${CONNECT}"; then
    junit_pass "04b_wrapper_path_loopback"
else
    junit_fail "04b_wrapper_path_loopback" "rama wrapper no apunta a 127.0.0.1:WRAP_LOCAL_PORT"
fi
if grep -q 'remotehost = "127.0.0.1"' "${REINTEG}" && grep -q 'remoteport = ${WRAP_LOCAL_PORT}' "${REINTEG}"; then
    junit_pass "reintegrator_wrapper_path_loopback"
else
    junit_fail "reintegrator_wrapper_path_loopback" "rama wrapper no apunta a 127.0.0.1:WRAP_LOCAL_PORT"
fi

# --- 7. La rama wrapper también pone bindhost en loopback (no sale por iface física) ---
if grep -q 'bindhost = "127.0.0.1"' "${CONNECT}"; then
    junit_pass "04b_wrapper_bindhost_loopback"
else
    junit_fail "04b_wrapper_bindhost_loopback" "rama wrapper no fija bindhost=127.0.0.1"
fi

# --- 8. El branch está gateado por WIFI_VIA_WRAPPER == 1 ---
if grep -q '"${WIFI_VIA_WRAPPER}" == "1"' "${CONNECT}"; then
    junit_pass "04b_branch_gated"
else
    junit_fail "04b_branch_gated" "el branch wrapper no está gateado por WIFI_VIA_WRAPPER==1"
fi

# --- 9. NO auto-launch: 04b imprime el hint del wrapper pero NO lo ejecuta.
#        Aceptamos referencias al path del wrapper SOLO dentro de un echo (hint).
#        Rechazamos una invocación directa tipo `tools/wrap-socat.sh` al inicio
#        de comando (no precedida de echo). ---
if grep -E '^[[:space:]]*"?\$\{SCRIPT_DIR\}/tools/wrap-' "${CONNECT}" >/dev/null 2>&1; then
    junit_fail "04b_no_autolaunch" "parece auto-lanzar un wrapper (invocación directa)"
else
    junit_pass "04b_no_autolaunch"
fi
# Sí debe existir el hint impreso al operador.
if grep -q 'tools/wrap-socat.sh' "${CONNECT}"; then
    junit_pass "04b_prints_hint"
else
    junit_fail "04b_prints_hint" "no imprime hint del comando wrapper a lanzar"
fi

# --- 10. set -uo pipefail / set -o pipefail conservado (Rule IDLC bash) ---
if grep -q "set -euo pipefail" "${CONNECT}"; then junit_pass "04b_set_flags"; else junit_fail "04b_set_flags" "04b sin set -euo pipefail"; fi
if grep -q "set -o pipefail" "${REINTEG}"; then junit_pass "reintegrator_set_flags"; else junit_fail "reintegrator_set_flags" "reintegrator sin set -o pipefail"; fi

# --- 11. Sintaxis bash OK (bash -n) en ambos ficheros ---
if command -v bash >/dev/null 2>&1; then
    if bash -n "${CONNECT}" 2>/dev/null; then junit_pass "04b_bash_syntax"; else junit_fail "04b_bash_syntax" "bash -n falla en 04b"; fi
    if bash -n "${REINTEG}" 2>/dev/null; then junit_pass "reintegrator_bash_syntax"; else junit_fail "reintegrator_bash_syntax" "bash -n falla en reintegrator"; fi
else
    junit_skip "bash_syntax" "bash no disponible"
fi

junit_finalize
