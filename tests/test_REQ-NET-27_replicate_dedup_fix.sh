#!/bin/sh
# Validates ave-vpc.REQ-NET-27: fix H1+H2+NULL check para replicación.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-27_replicate_dedup_fix"

ROOT="$(dirname "$0")/.."
PATCH="${ROOT}/patches/ubond_replicate_dedup_fix.patch"

# 1. Patch existe.
if [ -r "${PATCH}" ]; then
    junit_pass "patch_present"
else
    junit_fail "patch_missing" "patches/ubond_replicate_dedup_fix.patch no existe"
    junit_finalize
fi

# 2. Patch modifica pkt.h y ubond.c.
if grep -qE '^\+\+\+ b/src/pkt\.h'   "${PATCH}" \
   && grep -qE '^\+\+\+ b/src/ubond\.c' "${PATCH}"; then
    junit_pass "patch_targets_correct"
else
    junit_fail "patch_targets_wrong" "patch no modifica pkt.h Y ubond.c"
fi

# 3. Patch añade campo `int replicated` a ubond_pkt_t.
if grep -qE '^\+ *int replicated' "${PATCH}"; then
    junit_pass "patch_adds_replicated_field"
else
    junit_fail "patch_no_replicated_field" \
        "patch no añade campo `replicated` al struct ubond_pkt_t"
fi

# 4. Patch añade chequeo `pkt->replicated` en ubond_rtun_send para
# NO sobreescribir data_seq.
if grep -qE '^\+.*pkt->replicated' "${PATCH}"; then
    junit_pass "patch_checks_replicated_in_send"
else
    junit_fail "patch_no_replicated_check" \
        "patch no chequea pkt->replicated antes de reasignar data_seq"
fi

# 5. Patch añade NULL check en ubond_pkt_get del clone path.
if grep -qE '^\+.*if \(!clone\)' "${PATCH}" \
   || grep -qE '^\+.*pool exhausted' "${PATCH}"; then
    junit_pass "patch_null_check_clone"
else
    junit_fail "patch_no_null_check" \
        "patch no chequea NULL del ubond_pkt_get en clone"
fi

# 6. Patch marca clone->replicated = 1.
if grep -qE '^\+.*clone->replicated *= *1' "${PATCH}"; then
    junit_pass "patch_marks_clone_replicated"
else
    junit_fail "patch_no_clone_marking" \
        "patch no marca clone->replicated = 1"
fi

# 7. Patch cambia return 0 a return 1 en dedup hit.
# Verifica al menos que aparece un nuevo `return 1` cerca de un comentario sobre dedup.
if awk '/^\+.*return 1/ {found=1} END {exit !found}' "${PATCH}"; then
    junit_pass "patch_dedup_returns_1"
else
    junit_fail "patch_dedup_still_returns_0" \
        "patch no cambia return 0 → return 1 en dedup hit"
fi

# 8. Patch cambia caller a usar != 0 (no < 0).
if grep -qE '^\+.*pr != 0|^\+.*!= 0\)' "${PATCH}"; then
    junit_pass "patch_caller_uses_neq"
else
    junit_fail "patch_caller_still_lt" \
        "patch no cambia caller a usar != 0"
fi

# 9. 03b lo aplica como Patch 5.
SCRIPT_03B="${ROOT}/03b-setup-mac-ubond.sh"
if grep -qE 'patch.*ubond_replicate_dedup_fix\.patch' "${SCRIPT_03B}"; then
    junit_pass "03b_applies_patch"
else
    junit_fail "03b_no_apply" "03b no aplica ubond_replicate_dedup_fix.patch"
fi

# 10. 07b transporta el patch via UBOND_PATCH3_B64.
SCRIPT_07B="${ROOT}/07b-setup-rpi-ubond.sh"
if grep -qE 'UBOND_PATCH3_B64.*ubond_replicate_dedup_fix\.patch' "${SCRIPT_07B}" \
   && grep -qE 'patch.*ubond_replicate_dedup_fix' "${SCRIPT_07B}"; then
    junit_pass "07b_transports_patch"
else
    junit_fail "07b_no_transport" \
        "07b no transporta y aplica ubond_replicate_dedup_fix.patch"
fi

# 11. Si el binario está compilado, debe contener el log message
# "pool exhausted" del NULL check.
BIN="${ROOT}/build/ubond/src/ubond"
if [ -x "${BIN}" ]; then
    if strings "${BIN}" 2>/dev/null | grep -q 'pool exhausted'; then
        junit_pass "binary_has_null_check_log"
    else
        junit_fail "binary_missing_log" \
            "binary build/ubond/src/ubond no contiene 'pool exhausted' (recompilar)"
    fi
else
    junit_skip "binary_not_built" "build/ubond/src/ubond no existe (skip)"
fi

junit_finalize
