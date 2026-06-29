#!/bin/sh
# Validates ave-vpc.REQ-NET-25: per-link loss_tolerence y latency_tolerence
# (port de mlvpn al patch C de ubond).
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-25_per_link_tolerence"

ROOT="$(dirname "$0")/.."
PATCH="${ROOT}/patches/ubond_per_link_tolerence.patch"

# 1. El patch existe.
if [ -r "${PATCH}" ]; then
    junit_pass "patch_present"
else
    junit_fail "patch_missing" "patches/ubond_per_link_tolerence.patch no existe"
    junit_finalize
fi

# 2. El patch modifica los 3 archivos esperados.
if grep -qE '^\+\+\+ b/src/ubond\.h'  "${PATCH}" \
   && grep -qE '^\+\+\+ b/src/ubond\.c'  "${PATCH}" \
   && grep -qE '^\+\+\+ b/src/config\.c' "${PATCH}"; then
    junit_pass "patch_targets_correct"
else
    junit_fail "patch_targets_wrong" \
        "el patch no modifica src/ubond.h, src/ubond.c y src/config.c"
fi

# 3. El patch añade campos loss_tolerence y latency_tolerence_ms al struct.
if grep -qE '^\+.*double loss_tolerence' "${PATCH}" \
   && grep -qE '^\+.*latency_tolerence_ms' "${PATCH}"; then
    junit_pass "patch_adds_struct_fields"
else
    junit_fail "patch_no_struct_fields" \
        "el patch no añade los nuevos campos al struct ubond_tunnel_t"
fi

# 4. El patch añade el parser de loss_tolerence/latency_tolerence en config.c.
if grep -qE '_conf_set_uint_from_conf' "${PATCH}" \
   && grep -qE '"loss_tolerence"'   "${PATCH}" \
   && grep -qE '"latency_tolerence"' "${PATCH}"; then
    junit_pass "patch_adds_parser"
else
    junit_fail "patch_no_parser" \
        "el patch no añade el parser de configuración"
fi

# 5. El patch añade caps (100% para loss, 5000 ms para latency).
if grep -qE 'loss_tolerence is capped to 100' "${PATCH}" \
   && grep -qE 'latency_tolerence capped to 5000' "${PATCH}"; then
    junit_pass "patch_has_caps"
else
    junit_fail "patch_no_caps" \
        "el patch no establece caps explícitos para loss/latency tolerence"
fi

# 6. 03b lo aplica como Patch 4 en su chain.
SCRIPT_03B="${ROOT}/03b-setup-mac-ubond.sh"
if grep -qE 'patch.*ubond_per_link_tolerence\.patch' "${SCRIPT_03B}"; then
    junit_pass "03b_applies_patch"
else
    junit_fail "03b_no_apply" \
        "03b-setup-mac-ubond.sh no aplica ubond_per_link_tolerence.patch"
fi

# 7. 03b lo lista en el pre-flight de patches requeridos.
if grep -qE 'ubond_per_link_tolerence\.patch' "${SCRIPT_03B}" | head; then
    if grep -qE '^for p in.*ubond_per_link_tolerence' "${SCRIPT_03B}"; then
        junit_pass "03b_preflight_includes_patch"
    else
        junit_fail "03b_preflight_missing" \
            "03b no incluye el patch en el pre-flight de archivos requeridos"
    fi
else
    junit_fail "03b_no_reference" "03b sin referencias al patch"
fi

# 8. 07b transporta el patch via UBOND_PATCH2_B64 al RPi.
SCRIPT_07B="${ROOT}/07b-setup-rpi-ubond.sh"
if grep -qE 'UBOND_PATCH2_B64.*ubond_per_link_tolerence\.patch' "${SCRIPT_07B}" \
   && grep -qE 'patch.*ubond_per_link_tolerence' "${SCRIPT_07B}"; then
    junit_pass "07b_transports_patch"
else
    junit_fail "07b_no_transport" \
        "07b no transporta y aplica ubond_per_link_tolerence.patch en RPi"
fi

# 9. Si el binario está compilado, debe tener los nuevos strings.
BIN="${ROOT}/build/ubond/src/ubond"
if [ -x "${BIN}" ]; then
    if strings "${BIN}" 2>/dev/null | grep -q '^loss_tolerence$' \
       && strings "${BIN}" 2>/dev/null | grep -q '^latency_tolerence$'; then
        junit_pass "binary_has_new_keys"
    else
        junit_fail "binary_missing_keys" \
            "el binario en build/ubond/src/ubond no contiene loss_tolerence/latency_tolerence"
    fi
else
    junit_skip "binary_not_built" "build/ubond/src/ubond no existe (skip)"
fi

junit_finalize
