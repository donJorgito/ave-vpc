#!/bin/sh
# Validates ave-vpc.REQ-NET-32: watchdog FAIL_THRESHOLD NAT-tolerant.
# Static + sourcing harness para verificar default + override env +
# invariante FAIL_THRESHOLD * TICK_S >= 40 (NAT recovery típico móvil).
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-32_watchdog_threshold"

ROOT="$(dirname "$0")/.."
WATCHDOG="${ROOT}/tools/ubond-watchdog.sh"

# 1. Watchdog existe y es ejecutable.
if [ -x "${WATCHDOG}" ]; then
    junit_pass "watchdog_executable"
else
    junit_fail "watchdog_missing" "tools/ubond-watchdog.sh no existe"
    junit_finalize
fi

# 2. Default FAIL_THRESHOLD = 8 en el código.
if grep -qE 'FAIL_THRESHOLD="\$\{WATCHDOG_FAIL_THRESHOLD:-8\}"' "${WATCHDOG}"; then
    junit_pass "default_threshold_8"
else
    junit_fail "default_threshold_wrong" \
        "FAIL_THRESHOLD default no es 8 (esperado tras REQ-NET-32)"
fi

# 3. Default TICK_S = 5.
if grep -qE 'TICK_S="\$\{WATCHDOG_TICK_S:-5\}"' "${WATCHDOG}"; then
    junit_pass "default_tick_5"
else
    junit_fail "default_tick_wrong" \
        "TICK_S default no es 5"
fi

# 4. Invariante FAIL_THRESHOLD * TICK_S >= 40 (NAT-tolerant).
# Extraer valores y multiplicar.
THRESHOLD="$(grep -E 'FAIL_THRESHOLD="\$\{WATCHDOG_FAIL_THRESHOLD:-[0-9]+\}"' "${WATCHDOG}" | sed -E 's/.*:-([0-9]+)\}".*/\1/')"
TICK="$(grep -E 'TICK_S="\$\{WATCHDOG_TICK_S:-[0-9]+\}"' "${WATCHDOG}" | sed -E 's/.*:-([0-9]+)\}".*/\1/')"
if [ -n "${THRESHOLD}" ] && [ -n "${TICK}" ]; then
    PRODUCT="$((THRESHOLD * TICK))"
    if [ "${PRODUCT}" -ge 40 ]; then
        junit_pass "invariant_nat_tolerant"
    else
        junit_fail "invariant_violated" \
            "FAIL_THRESHOLD * TICK_S = ${PRODUCT}s, debe ser >=40s para tolerar NAT recovery"
    fi
else
    junit_fail "values_unparseable" \
        "no pude extraer THRESHOLD/TICK del watchdog"
fi

# 5. Override env: lanzar bash con WATCHDOG_FAIL_THRESHOLD=12 y verificar
# que el valor activo es 12. Stubbear las funciones de side-effect (log,
# trap, ping, sudo) para evitar tocar sistema.
OVERRIDE_RESULT="$(WATCHDOG_FAIL_THRESHOLD=12 bash -c '
    # Stubs para evitar side-effects.
    log() { :; }
    trap "" EXIT
    # Source solo las primeras 50 líneas (config) — no el loop de salud.
    eval "$(sed -n "1,50p" '"${WATCHDOG}"' | grep -v "^trap\|^log_info\|^log " || true)"
    # Cargar la línea de FAIL_THRESHOLD explícitamente.
    eval "$(grep -E "^FAIL_THRESHOLD=|^TICK_S=" '"${WATCHDOG}"')"
    echo "${FAIL_THRESHOLD}"
' 2>/dev/null)"
if [ "${OVERRIDE_RESULT}" = "12" ]; then
    junit_pass "override_env_works"
else
    junit_fail "override_env_broken" \
        "WATCHDOG_FAIL_THRESHOLD=12 NO override correctly (got: ${OVERRIDE_RESULT})"
fi

# 6. Comentario justificativo REQ-NET-32 / SOS investigator presente
# (trazabilidad — IDLC R8/R10).
if grep -qE 'REQ-NET-30 follow-up|SOS investigator|NAT' "${WATCHDOG}"; then
    junit_pass "rationale_documented"
else
    junit_fail "rationale_missing" \
        "watchdog sin comentario justificativo sobre el cambio de threshold"
fi

# 7. Override flag/help: si el watchdog acepta env var, debe estar
# documentado en help o comentarios.
if grep -qE 'WATCHDOG_FAIL_THRESHOLD' "${WATCHDOG}" \
   && grep -c 'WATCHDOG_FAIL_THRESHOLD' "${WATCHDOG}" | awk '{exit !($1>=2)}'; then
    junit_pass "override_documented"
else
    junit_fail "override_undocumented" \
        "WATCHDOG_FAIL_THRESHOLD no está documentado (ej. en help text o comment)"
fi

junit_finalize
