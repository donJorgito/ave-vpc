#!/bin/sh
# Validates ave-vpc.REQ-NET-28: monitor continuo cliente ubond v2.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-28_monitor"

ROOT="$(dirname "$0")/.."
MONITOR="${ROOT}/tools/ave-monitor.sh"

# 1. Tool existe, ejecutable, sintaxis OK.
if [ -x "${MONITOR}" ] && bash -n "${MONITOR}" 2>/dev/null; then
    junit_pass "monitor_present_and_valid"
else
    junit_fail "monitor_missing" "tools/ave-monitor.sh no existe o sintaxis errónea"
    junit_finalize
fi

# 2. Reusa libs comunes (no duplica logging).
if grep -qE '_common\.sh' "${MONITOR}" \
   && grep -qE 'env-detect\.sh' "${MONITOR}"; then
    junit_pass "reuses_libs"
else
    junit_fail "duplicates_libs" \
        "monitor no reusa _common.sh / env-detect.sh"
fi

# 3. Pre-flight: aborta si no hay ubond corriendo.
if grep -qE 'pgrep.*"ubond:|require_root' "${MONITOR}"; then
    junit_pass "monitor_has_preflight"
else
    junit_fail "no_preflight" "monitor sin pre-flight (no chequea ubond/utun)"
fi

# 4. Ping con ifscope (-b utunN), NO global. Cualquier mayuscula/minuscula
# de la variable utun es aceptable (UTUN, utun, ${UTUN_IFACE}, etc).
if grep -qiE 'ping[^|]*-b[[:space:]]+"?\$\{?utun' "${MONITOR}"; then
    junit_pass "ping_uses_ifscope"
else
    junit_fail "ping_global" \
        "monitor hace ping global — falso positivo por colisión subnet con red corp"
fi

# 5. DNS via 1.1.1.1 directo, no system resolver.
if grep -qE 'dig.*@1\.1\.1\.1' "${MONITOR}" \
   || grep -qE 'dig.*@1\.0\.0\.1' "${MONITOR}"; then
    junit_pass "dns_via_public_resolver"
else
    junit_fail "dns_via_system" \
        "monitor usa system DNS resolver (falla con WiFi AVE flapping)"
fi

# 6. Parsing con awk patrón explícito, NO tail|head.
# Heurística: si hay `tail -[0-9] |.*head` para parsear stats, mal.
if grep -qE 'tail -[0-9]+ ?\| ?head' "${MONITOR}"; then
    junit_fail "parsing_uses_tail_head" \
        "monitor parsea con tail|head (lección AVE 2026-06-01)"
else
    junit_pass "parsing_explicit_awk"
fi

# 7. --max-time en operaciones curl/ping (anti-bloqueo).
if grep -qE 'curl[^|]*--max-time' "${MONITOR}"; then
    junit_pass "curl_has_max_time"
else
    junit_fail "curl_no_max_time" \
        "curl sin --max-time bloquearía el tick si la red cae"
fi

# 8. Output dual (stdout + NDJSON).
if grep -qE 'ave-monitor.*\.ndjson|NDJSON|json' "${MONITOR}"; then
    junit_pass "ndjson_output"
else
    junit_fail "no_ndjson" "monitor no produce NDJSON parseable"
fi

# 9. Append-only por línea con flush (ALCOA++ contemporaneity).
# Heurística: aparece `>>` (append redirect) en escritura de log.
if grep -qE '>>"?\$\{?(LOG|NDJSON|MONITOR_LOG)' "${MONITOR}"; then
    junit_pass "append_only_writes"
else
    junit_fail "no_append_only" \
        "monitor no escribe en append-only (rompe ALCOA++ originality)"
fi

# 10. Trap INT TERM EXIT para cierre limpio.
if grep -qE 'trap [^#]*EXIT|trap [^#]*INT|trap [^#]*TERM' "${MONITOR}"; then
    junit_pass "has_trap_cleanup"
else
    junit_fail "no_trap" "monitor sin trap — log puede quedar truncado"
fi

# 11. Idempotencia: si hay monitor corriendo, aborta.
if grep -qE 'pidfile|PID_FILE' "${MONITOR}" \
   && grep -qE 'kill -0' "${MONITOR}"; then
    junit_pass "idempotent_pidfile"
else
    junit_fail "no_idempotency" \
        "monitor sin chequeo idempotencia — dos instancias pisarían el log"
fi

# 12. Detección de anomalías (al menos una alerta).
if grep -qE 'alert|ALERT|FUGA|sos_triggered' "${MONITOR}"; then
    junit_pass "detects_anomalies"
else
    junit_fail "no_alerts" "monitor no detecta condiciones anómalas"
fi

# 13. CLI flags --tick, --background, --no-throughput.
if grep -qE -- '--tick' "${MONITOR}" \
   && grep -qE -- '--background' "${MONITOR}"; then
    junit_pass "cli_flags_present"
else
    junit_fail "cli_flags_missing" \
        "monitor no expone --tick / --background"
fi

# 14. Timestamp ISO 8601 con offset (ALCOA++ atribuibilidad).
# Usar grep -F para evitar interpretación de regex en formatos %Y.
if grep -qF 'date -Iseconds' "${MONITOR}" \
   || grep -qF 'date +%Y-%m-%dT' "${MONITOR}"; then
    junit_pass "iso_8601_timestamps"
else
    junit_fail "no_iso_timestamps" \
        "monitor no usa timestamps ISO 8601 con offset (ALCOA++)"
fi

# 15. Permisos restrictivos en logs (datos sensibles).
if grep -qE 'chmod 600|umask' "${MONITOR}"; then
    junit_pass "logs_chmod_restricted"
else
    junit_fail "logs_world_readable" \
        "monitor no restringe permisos del log (IPs públicas/CGNAT son sensibles)"
fi

# 16. ALCOA++ Attributable: emite session_start con metadata.
if grep -qE 'emit_session_start|"event":"session_start"' "${MONITOR}" \
   && grep -qE 'host|hostname|git_sha|git rev-parse' "${MONITOR}"; then
    junit_pass "alcoa_attributable_session_start"
else
    junit_fail "alcoa_no_session_metadata" \
        "monitor no emite session_start con host/user/git_sha (ALCOA++ Attributable)"
fi

# 17. ALCOA++ Contemporaneous: sync periódico, no batch al EXIT.
if grep -qE 'sync 2>/dev/null|sync$|fsync|NDJSON_SYNC_EVERY' "${MONITOR}"; then
    junit_pass "alcoa_contemporaneous_sync"
else
    junit_fail "alcoa_no_sync" \
        "monitor no hace sync periódico — crash puede perder últimos minutos (ALCOA++ Contemporaneous)"
fi

# 18. ALCOA++ Accurate: distingue null (no medido) de 0 (medido a cero).
if grep -qE 'sent="null"|rcv="null"|succ_pct="null"' "${MONITOR}"; then
    junit_pass "alcoa_accurate_null_vs_zero"
else
    junit_fail "alcoa_extrapolates" \
        "monitor extrapola en lugar de emitir null (ALCOA++ Accurate)"
fi

junit_finalize
