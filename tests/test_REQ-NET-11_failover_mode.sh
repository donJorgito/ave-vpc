#!/bin/sh
# Validates ave-vpc.REQ-NET-11: modo failover para sesiones interactivas.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-11_failover_mode"

CONNECT="$(dirname "$0")/../04-conectar.sh"

[ -f "${CONNECT}" ] || { junit_fail "connect_missing" "04-conectar.sh no existe"; junit_finalize; }

# Check 1: flag --failover en parser
if grep -q -- "--failover) FAILOVER=true" "${CONNECT}"; then
    junit_pass "flag_failover_recognized"
else
    junit_fail "flag_missing" "flag --failover no parseado"
fi

# Check 2: flag --failover documentado en el help
if grep -q -- '--failover.*Modo failover' "${CONNECT}"; then
    junit_pass "flag_failover_documented"
else
    junit_fail "flag_undocumented" "--failover no aparece en mensaje de uso"
fi

# Check 3: timeout=2 sustituye al global cuando el flag está activo
if grep -q '^timeout = [0-9]\*' "${CONNECT}" && false; then
    junit_pass "timeout_sed"  # placeholder, ver check siguiente
else
    if grep -qE 's/\^timeout = \[0-9\]\*\$/timeout = 2/' "${CONNECT}"; then
        junit_pass "timeout_2_replaces_global"
    else
        junit_fail "timeout_2_missing" "no se sustituye timeout global por 2 en --failover"
    fi
fi

# Check 4: awk inserta fallback_only=1 en [links.pixel]
if grep -q '\$0 == "\[links.pixel\]"' "${CONNECT}" \
   && grep -q '"fallback_only = 1"' "${CONNECT}"; then
    junit_pass "fallback_only_inserted_pixel"
else
    junit_fail "fallback_only_missing" "no se inserta fallback_only=1 en [links.pixel]"
fi

# Check 5: WiFi también queda como fallback en --failover
if grep -B2 -A4 'IP_WIFI.*FAILOVER' "${CONNECT}" >/dev/null 2>&1 \
   || grep -E 'FAILOVER.*\}.*echo "fallback_only' "${CONNECT}" >/dev/null \
   || grep -A5 'echo "fallback_only = 1"' "${CONNECT}" | grep -q 'mlvpn_active.conf'; then
    junit_pass "wifi_also_fallback"
else
    junit_fail "wifi_not_fallback" "WiFi no se marca fallback_only en --failover"
fi

# Check 6: mensaje informativo al usuario
if grep -q 'Modo --failover activo' "${CONNECT}"; then
    junit_pass "user_message"
else
    junit_fail "no_user_message" "falta mensaje informativo para el usuario"
fi

# Check 7: comportamiento por defecto (sin flag) no cambia: FAILOVER=false
if grep -q '^FAILOVER=false$' "${CONNECT}"; then
    junit_pass "default_off"
else
    junit_fail "default_not_safe" "FAILOVER no por defecto en false"
fi

# Check 8: bash -n del script entero
if bash -n "${CONNECT}" 2>/dev/null; then
    junit_pass "bash_syntax_ok"
else
    junit_fail "bash_syntax_error" "04-conectar.sh tiene errores de sintaxis"
fi

junit_finalize
