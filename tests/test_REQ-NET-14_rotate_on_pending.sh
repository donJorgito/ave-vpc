#!/bin/sh
# Validates ave-vpc.REQ-NET-14: rotación inmediata si current_active no autenticado.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-14_rotate_on_pending"

SELECTOR="$(dirname "$0")/../tools/seleccionar-mejor-enlace.sh"

[ -f "${SELECTOR}" ] || { junit_fail "selector_missing" "selector no existe"; junit_finalize; }

# Check 1: existe variable current_authed
if grep -q "current_authed" "${SELECTOR}"; then
    junit_pass "current_authed_tracked"
else
    junit_fail "no_current_authed" "no se rastrea si current está autenticado"
fi

# Check 2: comprueba con authenticated_links
if grep -q 'echo "\${auth_list}" | grep -qx "\${current}"' "${SELECTOR}"; then
    junit_pass "checks_current_in_auth_list"
else
    junit_fail "no_check" "no comprueba current contra auth_list"
fi

# Check 3: rota si current_authed=0 sin esperar al gap
if grep -q 'current_authed.*-eq 0' "${SELECTOR}" \
   && grep -q "should_rotate=1" "${SELECTOR}"; then
    junit_pass "rotates_when_not_authed"
else
    junit_fail "no_immediate_rotation" "no rota inmediato si current_authed=0"
fi

# Check 4: razón "AUTH_PENDING" en log de rotación
if grep -q "AUTH_PENDING" "${SELECTOR}" && grep -q "REQ-NET-14" "${SELECTOR}"; then
    junit_pass "logs_reason_authpending"
else
    junit_fail "no_log_reason" "no se loguea razón con REQ-NET-14"
fi

# Check 5: comportamiento previo intacto si current sí está autenticado
# (debe seguir requiriendo gap >= MIN_SCORE_GAP)
if grep -q "MIN_SCORE_GAP" "${SELECTOR}" \
   && grep -q '"\${gap}".*-ge.*"\${MIN_SCORE_GAP}"' "${SELECTOR}"; then
    junit_pass "preserves_gap_logic"
else
    junit_fail "lost_gap_logic" "se ha perdido la lógica de gap mínimo"
fi

junit_finalize
