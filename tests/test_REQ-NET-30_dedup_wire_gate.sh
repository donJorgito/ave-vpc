#!/bin/sh
# Validates ave-vpc.REQ-NET-30: dedup gate por wire signal data_seq!=0.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-30_dedup_wire_gate"

ROOT="$(dirname "$0")/.."
PATCH="${ROOT}/patches/ubond_dedup_gate_data_seq.patch"

# 1. Patch existe.
if [ -r "${PATCH}" ]; then
    junit_pass "patch_present"
else
    junit_fail "patch_missing" "patches/ubond_dedup_gate_data_seq.patch no existe"
    junit_finalize
fi

# 2. Patch modifica solo src/ubond.c (1 hunk en protocol_read).
if grep -qE '^\+\+\+ b/src/ubond\.c' "${PATCH}"; then
    junit_pass "patch_targets_ubond_c"
else
    junit_fail "patch_wrong_target" "patch no modifica src/ubond.c"
fi

# 3. Patch elimina el gate viejo `replicate_filters.count > 0` como
# precondición del dedup_check.
if grep -qE '^-.*ubond_replicate_filters\.count *> *0 *&&' "${PATCH}"; then
    junit_pass "patch_removes_count_gate"
else
    junit_fail "patch_no_count_removal" \
        "patch NO elimina el gate replicate_filters.count > 0"
fi

# 4. Patch añade el gate nuevo `proto->data_seq != 0` como precondición.
if grep -qE '^\+.*proto->data_seq *!= *0' "${PATCH}"; then
    junit_pass "patch_adds_data_seq_gate"
else
    junit_fail "patch_no_data_seq_gate" \
        "patch NO añade gate proto->data_seq != 0"
fi

# 5. Patch preserva el match de tipos UBOND_PKT_DATA / UBOND_PKT_DATA_RESEND.
if grep -qE 'UBOND_PKT_DATA.*UBOND_PKT_DATA_RESEND' "${PATCH}"; then
    junit_pass "patch_keeps_type_match"
else
    junit_fail "patch_breaks_type_match" \
        "patch NO mantiene check tipo DATA/DATA_RESEND"
fi

# 6. Patch incluye comentario justificativo REQ-NET-30 (trazabilidad).
if grep -qE 'REQ-NET-30' "${PATCH}"; then
    junit_pass "patch_traces_req_net_30"
else
    junit_fail "patch_no_traceability" \
        "patch sin referencia REQ-NET-30 en comentarios"
fi

# 7. 03b lo aplica como Patch 7 en su chain.
SCRIPT_03B="${ROOT}/03b-setup-mac-ubond.sh"
if grep -qE 'patch.*ubond_dedup_gate_data_seq\.patch' "${SCRIPT_03B}"; then
    junit_pass "03b_applies_patch"
else
    junit_fail "03b_no_apply" "03b no aplica ubond_dedup_gate_data_seq.patch"
fi

# 8. 07b lo transporta vía UBOND_PATCH5_B64 y lo aplica.
SCRIPT_07B="${ROOT}/07b-setup-rpi-ubond.sh"
if grep -qE 'UBOND_PATCH5_B64.*ubond_dedup_gate_data_seq\.patch' "${SCRIPT_07B}" \
   && grep -qE 'patch.*ubond_dedup_gate_data_seq' "${SCRIPT_07B}"; then
    junit_pass "07b_transports_patch"
else
    junit_fail "07b_no_transport" \
        "07b no transporta y aplica ubond_dedup_gate_data_seq.patch"
fi

# 9. REGRESSION-KILLER: si build/ubond/src/ubond.c existe (post-build),
# verificar que el gate nuevo está en el código compilable Y el viejo
# desapareció como condición del dedup. Heurística: en el bloque de
# protocol_read (líneas 640-700 aprox), la condición de dedup_check
# debe usar `data_seq != 0`. Si todavía aparece el gate viejo
# `replicate_filters.count > 0` en ese mismo bloque como condición
# del dedup, hay regresión.
UBOND_C="${ROOT}/build/ubond/src/ubond.c"
if [ -r "${UBOND_C}" ]; then
    # Extraer 25 líneas alrededor de cada call site a dedup_check.
    BLOCK="$(grep -n -B 25 -A 5 'ubond_replicate_dedup_check' "${UBOND_C}" 2>/dev/null || true)"
    if echo "${BLOCK}" | grep -qE 'proto->data_seq *!= *0'; then
        junit_pass "build_has_data_seq_gate"
    else
        junit_fail "build_missing_data_seq_gate" \
            "build/ubond/src/ubond.c no contiene 'proto->data_seq != 0' cerca de dedup_check"
    fi
    # Regresión: gate viejo NO debe estar como precondición del dedup.
    if echo "${BLOCK}" | grep -qE 'ubond_replicate_filters\.count *> *0 *&&'; then
        junit_fail "build_has_old_gate_regression" \
            "build/ubond/src/ubond.c TODAVÍA tiene gate replicate_filters.count > 0 (regresión REQ-NET-30)"
    else
        junit_pass "build_no_count_gate_regression"
    fi
else
    junit_skip "build_not_present" "build/ubond/src/ubond.c no existe (skip — recompilar para activar regression-killer)"
fi

# 10. Coherencia con REQ-NET-27: el patch posterior NO debe haber
# regresado cambios de NET-27. Verificar que el contrato `return 1` en
# dedup hit (REQ-NET-27) sigue presente en el código si build/ existe.
if [ -r "${UBOND_C}" ]; then
    if awk '
        /ubond_replicate_dedup_check/ { in_block=1 }
        in_block && /return 1/ { found=1 }
        in_block && /^}/ { in_block=0 }
        END { exit !found }
    ' "${UBOND_C}"; then
        junit_pass "build_preserves_req_net_27_return"
    else
        junit_fail "build_breaks_req_net_27" \
            "build/ubond/src/ubond.c no preserva 'return 1' del dedup hit (regresión REQ-NET-27)"
    fi
else
    junit_skip "build_not_present_for_net27" "build no existe (skip coherence check)"
fi

junit_finalize
