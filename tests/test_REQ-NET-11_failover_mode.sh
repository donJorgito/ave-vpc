#!/bin/sh
# Validates ave-vpc.REQ-NET-11: modo failover dinámico para sesiones interactivas.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-11_failover_mode"

ROOT="$(dirname "$0")/.."
CONNECT="${ROOT}/04-conectar.sh"
DISCONNECT="${ROOT}/05-desconectar.sh"
SELECTOR="${ROOT}/tools/seleccionar-mejor-enlace.sh"

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
if grep -qE 's/\^timeout = \[0-9\]\*\$/timeout = 2/' "${CONNECT}"; then
    junit_pass "timeout_2_replaces_global"
else
    junit_fail "timeout_2_missing" "no se sustituye timeout global por 2 en --failover"
fi

# Check 4: awk inserta fallback_only=1 en [links.pixel]
if grep -q '\$0 == "\[links.pixel\]"' "${CONNECT}" \
   && grep -q '"fallback_only = 1"' "${CONNECT}"; then
    junit_pass "fallback_only_inserted_pixel"
else
    junit_fail "fallback_only_missing" "no se inserta fallback_only=1 en [links.pixel]"
fi

# Check 5: WiFi también queda como fallback en --failover
if grep -A5 'if "\${FAILOVER}"; then' "${CONNECT}" | grep -q 'fallback_only = 1' \
   || grep -B2 'echo "fallback_only = 1" >> "\${GENERATED_DIR}/mlvpn_active.conf"' "${CONNECT}" >/dev/null; then
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

# Check 8: bash -n del 04-conectar.sh
if bash -n "${CONNECT}" 2>/dev/null; then
    junit_pass "connect_syntax_ok"
else
    junit_fail "connect_syntax_error" "04-conectar.sh tiene errores de sintaxis"
fi

# Check 9: existe selector dinámico ejecutable
if [ -x "${SELECTOR}" ]; then
    junit_pass "selector_executable"
else
    junit_fail "selector_missing" "tools/seleccionar-mejor-enlace.sh no existe o no ejecutable"
fi

# Check 10: selector solo toca fallback_only, NUNCA bandwidth_upload
if [ -f "${SELECTOR}" ] \
   && grep -q "fallback_only" "${SELECTOR}" \
   && ! grep -qE "^\\s*(awk|sed).*bandwidth_upload" "${SELECTOR}"; then
    junit_pass "selector_only_touches_fallback"
else
    junit_fail "selector_touches_bandwidth" "el selector debe tocar SOLO fallback_only"
fi

# Check 11: selector excluye links no autenticados (defensa WiFi UDP filtrado)
if [ -f "${SELECTOR}" ] \
   && grep -q "authenticated_links" "${SELECTOR}" \
   && grep -q '@links' "${SELECTOR}"; then
    junit_pass "selector_excludes_pending"
else
    junit_fail "selector_no_pending_check" "el selector no filtra AUTH_PENDING"
fi

# Check 12: histeresis MIN_SCORE_GAP para no rotar por ruido
if [ -f "${SELECTOR}" ] && grep -q "^MIN_SCORE_GAP=" "${SELECTOR}"; then
    junit_pass "selector_hysteresis"
else
    junit_fail "selector_no_hysteresis" "falta MIN_SCORE_GAP en selector"
fi

# Check 13: 04-conectar.sh lanza el selector cuando --failover
if grep -q 'seleccionar-mejor-enlace.sh' "${CONNECT}" \
   && grep -A2 'if "\${FAILOVER}"' "${CONNECT}" | grep -q 'nohup.*seleccionar-mejor'; then
    junit_pass "connect_starts_selector"
else
    junit_fail "connect_no_selector" "04-conectar.sh no lanza el selector con --failover"
fi

# Check 14: 05-desconectar.sh mata el selector (tras refactor SOS
# atómico el orden ya no importa: pkill -9 mata todo en ms a la vez)
if grep -q "seleccionar-mejor-enlace\|mlvpn_failover_selector" "${DISCONNECT}" \
   || grep -qE 'pid_file.*kill -9|for.*\.pid' "${DISCONNECT}"; then
    junit_pass "disconnect_kills_selector"
else
    junit_fail "disconnect_no_selector_kill" "05-desconectar.sh no mata selector"
fi

junit_finalize
