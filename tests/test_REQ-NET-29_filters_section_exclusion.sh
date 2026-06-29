#!/bin/sh
# Validates ave-vpc.REQ-NET-29: parser [filters] excluye sub-secciones.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-29_filters_section_exclusion"

ROOT="$(dirname "$0")/.."
PATCH="${ROOT}/patches/ubond_filters_section_exclusion.patch"

# 1. Patch existe.
if [ -r "${PATCH}" ]; then
    junit_pass "patch_present"
else
    junit_fail "patch_missing" "patches/ubond_filters_section_exclusion.patch no existe"
    junit_finalize
fi

# 2. Patch modifica config.c (1 hunk).
if grep -qE '^\+\+\+ b/src/config\.c' "${PATCH}"; then
    junit_pass "patch_targets_config_c"
else
    junit_fail "patch_wrong_target" "patch no modifica src/config.c"
fi

# 3. Patch sustituye strncmp(...,"filters",7) == 0 por strcmp(...,"filters") == 0.
# Heurística: debe haber un `-` con strncmp y un `+` con strcmp para "filters".
if grep -qE '^-.*strncmp.*"filters", *7' "${PATCH}" \
   && grep -qE '^\+.*strcmp.*"filters"' "${PATCH}"; then
    junit_pass "patch_replaces_strncmp_with_strcmp"
else
    junit_fail "patch_wrong_substitution" \
        "patch no sustituye strncmp(...,7) por strcmp(...) sobre la sección filters"
fi

# 4. 03b lo aplica como Patch 6 en su chain.
SCRIPT_03B="${ROOT}/03b-setup-mac-ubond.sh"
if grep -qE 'patch.*ubond_filters_section_exclusion\.patch' "${SCRIPT_03B}"; then
    junit_pass "03b_applies_patch"
else
    junit_fail "03b_no_apply" "03b no aplica ubond_filters_section_exclusion.patch"
fi

# 5. 07b lo transporta y aplica.
SCRIPT_07B="${ROOT}/07b-setup-rpi-ubond.sh"
if grep -qE 'UBOND_PATCH4_B64.*ubond_filters_section_exclusion\.patch' "${SCRIPT_07B}" \
   && grep -qE 'patch.*ubond_filters_section_exclusion' "${SCRIPT_07B}"; then
    junit_pass "07b_transports_patch"
else
    junit_fail "07b_no_transport" \
        "07b no transporta y aplica ubond_filters_section_exclusion.patch"
fi

# 6. Si build/ubond/src/config.c existe (post-build), verificar que
# la sustitución está aplicada — el matching es por strcmp exacto, no
# strncmp.
CONFIG_C="${ROOT}/build/ubond/src/config.c"
if [ -r "${CONFIG_C}" ]; then
    # Buscar al menos una línea con strcmp("filters") cercana al manejo
    # de section.
    if grep -qE 'strcmp\(.*"filters"\)' "${CONFIG_C}"; then
        junit_pass "build_has_strcmp_filters"
    else
        junit_fail "build_missing_strcmp" \
            "build/ubond/src/config.c no contiene strcmp(...,\"filters\") (rebuild)"
    fi
else
    junit_skip "build_not_present" "build/ubond/src/config.c no existe (skip)"
fi

junit_finalize
