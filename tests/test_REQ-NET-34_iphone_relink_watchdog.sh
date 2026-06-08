#!/bin/sh
# Validates ave-vpc.REQ-NET-34: auto-recovery iphone NAT carrier expiry.
# Static checks sobre tools/iphone-relink-watchdog.sh — no requiere ubond
# corriendo ni root, debe pasar siempre en CI.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-34_iphone_relink_watchdog"

ROOT="$(dirname "$0")/.."
WATCHDOG="${ROOT}/tools/iphone-relink-watchdog.sh"

# 1. Script existe y es ejecutable.
if [ -x "${WATCHDOG}" ]; then
    junit_pass "watchdog_executable"
else
    junit_fail "watchdog_missing" "tools/iphone-relink-watchdog.sh no existe o no es ejecutable"
    junit_finalize
fi

# 2. Variables override parseables — todas las 5 documentadas en el AC.
for var in RELINK_LINK_NAME RELINK_IFACE RELINK_TICK_S RELINK_FAIL_THRESHOLD RELINK_COOLDOWN_S; do
    if grep -qE "\\\$\\{${var}:-" "${WATCHDOG}"; then
        junit_pass "override_${var}"
    else
        junit_fail "override_${var}_missing" \
            "variable override ${var} no aparece con default \${${var}:-...}"
    fi
done

# 3. Defaults concretos del AC: link=iphone, iface=en8, tick=5, threshold=12, cooldown=90.
if grep -qE 'LINK_NAME="\$\{RELINK_LINK_NAME:-iphone\}"' "${WATCHDOG}"; then
    junit_pass "default_link_iphone"
else
    junit_fail "default_link_wrong" "default RELINK_LINK_NAME no es 'iphone'"
fi
if grep -qE 'IFACE="\$\{RELINK_IFACE:-en8\}"' "${WATCHDOG}"; then
    junit_pass "default_iface_en8"
else
    junit_fail "default_iface_wrong" "default RELINK_IFACE no es 'en8'"
fi
if grep -qE 'TICK_S="\$\{RELINK_TICK_S:-5\}"' "${WATCHDOG}"; then
    junit_pass "default_tick_5"
else
    junit_fail "default_tick_wrong" "default RELINK_TICK_S no es 5"
fi
if grep -qE 'FAIL_THRESHOLD="\$\{RELINK_FAIL_THRESHOLD:-12\}"' "${WATCHDOG}"; then
    junit_pass "default_threshold_12"
else
    junit_fail "default_threshold_wrong" "default RELINK_FAIL_THRESHOLD no es 12"
fi
if grep -qE 'COOLDOWN_S="\$\{RELINK_COOLDOWN_S:-90\}"' "${WATCHDOG}"; then
    junit_pass "default_cooldown_90"
else
    junit_fail "default_cooldown_wrong" "default RELINK_COOLDOWN_S no es 90"
fi

# 4. Check EUID -ne 0 → exit 1 (requiere root para ifconfig).
if grep -qE 'EUID.*-ne 0' "${WATCHDOG}" && grep -qE 'requiere root' "${WATCHDOG}"; then
    junit_pass "requires_root"
else
    junit_fail "no_root_check" \
        "watchdog no rechaza ejecución sin root (necesario para ifconfig down/up)"
fi

# 5. Detección link DOWN vía proctitle: busca "!links.${LINK_NAME}" en title.
if grep -qE '"\!links\.\$\{?LINK_NAME\}?"\*' "${WATCHDOG}" \
   || grep -qE '\*"!links\.\$\{?LINK_NAME\}?"\*' "${WATCHDOG}"; then
    junit_pass "detects_via_proctitle"
else
    junit_fail "proctitle_detection_missing" \
        "watchdog no busca '!links.\${LINK_NAME}' en proctitle ubond"
fi

# 6. Acción correctiva: ifconfig $IFACE down + sleep + up cuando threshold reached.
if grep -qE 'ifconfig "\$IFACE" down' "${WATCHDOG}" \
   && grep -qE 'ifconfig "\$IFACE" up' "${WATCHDOG}" \
   && grep -qE 'sleep "\$DOWN_UP_GAP_S"' "${WATCHDOG}"; then
    junit_pass "action_ifconfig_down_up"
else
    junit_fail "action_missing" \
        "watchdog no ejecuta secuencia 'ifconfig down → sleep → up'"
fi

# 7. Cooldown logic — no flap loop tras una acción.
if grep -qE 'last_action_ts' "${WATCHDOG}" \
   && grep -qE 'COOLDOWN_S' "${WATCHDOG}" \
   && grep -qE 'cooldown active' "${WATCHDOG}"; then
    junit_pass "cooldown_logic"
else
    junit_fail "cooldown_missing" \
        "watchdog no implementa cooldown — riesgo flap-loop"
fi

# 8. Si proceso ubond no corre, fail_count se resetea (no falsos positivos).
# Patrón: pgrep ubond → -z pid → fail_count=0 / continue.
if grep -qE 'pgrep -f .*ubond' "${WATCHDOG}" \
   && grep -A 6 'if \[\[ -z "\$pid" \]\]' "${WATCHDOG}" | grep -q 'fail_count=0'; then
    junit_pass "resets_when_ubond_absent"
else
    junit_fail "no_reset_logic" \
        "watchdog no resetea fail_count cuando ubond no corre"
fi

# 9. Sintaxis bash OK.
if bash -n "${WATCHDOG}" 2>/dev/null; then
    junit_pass "bash_syntax_ok"
else
    junit_fail "bash_syntax_error" "bash -n encontró error de sintaxis"
fi

# 10. Override env: lanzar con RELINK_FAIL_THRESHOLD=20 y verificar que
# el valor activo es 20. Stubbear el while loop para no entrar en el daemon.
OVERRIDE_RESULT="$(RELINK_FAIL_THRESHOLD=20 bash -c '
    # Cargar solo las líneas de config (variables hasta justo antes de while).
    eval "$(grep -E "^(LINK_NAME|IFACE|TICK_S|FAIL_THRESHOLD|COOLDOWN_S|DOWN_UP_GAP_S)=" '"${WATCHDOG}"')"
    echo "${FAIL_THRESHOLD}"
' 2>/dev/null)"
if [ "${OVERRIDE_RESULT}" = "20" ]; then
    junit_pass "override_env_works"
else
    junit_fail "override_env_broken" \
        "RELINK_FAIL_THRESHOLD=20 NO override correctly (got: ${OVERRIDE_RESULT})"
fi

# 11. Trazabilidad — comentario justificativo REQ-NET-34 + AVE 2026-06-05.
if grep -qE 'REQ-NET-34' "${WATCHDOG}" \
   && grep -qE 'NAT|carrier|pinhole' "${WATCHDOG}"; then
    junit_pass "rationale_documented"
else
    junit_fail "rationale_missing" \
        "watchdog sin comentario REQ-NET-34 + razón NAT carrier expiry"
fi

# 12. Lanzamiento automático desde 04b-conectar-ubond.sh.
SCRIPT_04B="${ROOT}/04b-conectar-ubond.sh"
if [ -f "${SCRIPT_04B}" ] && grep -qE 'iphone-relink-watchdog\.sh' "${SCRIPT_04B}"; then
    junit_pass "launched_by_04b"
else
    junit_fail "not_launched_by_04b" \
        "04b-conectar-ubond.sh no arranca tools/iphone-relink-watchdog.sh"
fi

junit_finalize
