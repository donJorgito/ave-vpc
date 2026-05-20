#!/bin/sh
# Validates ave-vpc.REQ-NET-07: rebind del enlace WiFi ante cambios de IP.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-07_wifi_ip_rebind"

CONNECT="$(dirname "$0")/../04-conectar.sh"
DISCONNECT="$(dirname "$0")/../05-desconectar.sh"

[ -f "${CONNECT}" ] || { junit_fail "connect_missing" "04-conectar.sh no existe"; junit_finalize; }
[ -f "${DISCONNECT}" ] || { junit_fail "disconnect_missing" "05-desconectar.sh no existe"; junit_finalize; }

# Check 1: revalidación de IP tras captive portal (sleep + ipconfig getifaddr)
if grep -q "tras autenticar el captive" "${CONNECT}" \
   && grep -q "ip_after" "${CONNECT}"; then
    junit_pass "captive_post_revalidation"
else
    junit_fail "captive_post_revalidation_missing" "no revalida IP tras captive portal"
fi

# Check 2: refresco de IP_WIFI cuando cambia tras captive
if grep -q 'IP cambió tras captive' "${CONNECT}" \
   && grep -q 'IP_WIFI="${ip_after}"' "${CONNECT}"; then
    junit_pass "ip_wifi_refresh_on_captive_change"
else
    junit_fail "ip_wifi_refresh_missing" "IP_WIFI no se refresca tras cambio post-captive"
fi

# Check 3: per-link timeout/loss/latency en [links.wifi]
if grep -q "^timeout = 8" "${CONNECT}" \
   && grep -q "^loss_tolerence = 30" "${CONNECT}" \
   && grep -q "^latency_tolerence = 800" "${CONNECT}"; then
    junit_pass "per_link_timeout_loss_latency"
else
    junit_fail "per_link_overrides_missing" "faltan timeout/loss_tolerence/latency_tolerence en [links.wifi]"
fi

# Check 4: watcher en background con sed + SIGHUP
if grep -q "kill -HUP" "${CONNECT}" \
   && grep -q "sed -i '' \"s|bindhost" "${CONNECT}"; then
    junit_pass "wifi_watcher_sighup_rebind"
else
    junit_fail "wifi_watcher_missing" "watcher con sed+SIGHUP no encontrado"
fi

# Check 5: PID del watcher persistido para limpieza
if grep -q "mlvpn_wifi_watcher.pid" "${CONNECT}"; then
    junit_pass "watcher_pid_persisted"
else
    junit_fail "watcher_pid_missing" "no se guarda PID del watcher en mlvpn_wifi_watcher.pid"
fi

# Check 6: 05-desconectar.sh limpia el watcher
if grep -q "mlvpn_wifi_watcher.pid" "${DISCONNECT}" \
   && grep -q 'kill "${WATCHER_PID}"' "${DISCONNECT}"; then
    junit_pass "disconnect_kills_watcher"
else
    junit_fail "disconnect_watcher_cleanup_missing" "05-desconectar.sh no limpia el watcher"
fi

# Check 7: traza de rebind escrita al log
if grep -q "wifi rebind" "${CONNECT}"; then
    junit_pass "rebind_log_trace"
else
    junit_fail "rebind_log_missing" "no se escribe traza de rebind en mlvpn.log"
fi

junit_finalize
