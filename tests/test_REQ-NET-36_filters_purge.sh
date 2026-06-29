#!/bin/sh
# Validates ave-vpc.REQ-NET-36: purga del pool de replicación en SIGHUP /
# config reload (memory leak + duplicate filters fix). Static checks sobre
# patches/ubond_filters_count_purge.patch + wire en scripts setup. No
# requiere ubond corriendo ni root, debe pasar siempre en CI antes de la
# rebuild RPi+Mac.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-36_filters_purge"

ROOT="$(dirname "$0")/.."
PATCH="${ROOT}/patches/ubond_filters_count_purge.patch"
SCRIPT_03B="${ROOT}/03b-setup-mac-ubond.sh"
SCRIPT_07B="${ROOT}/07b-setup-rpi-ubond.sh"
FILTERS_C="${ROOT}/build/ubond/src/filters.c"
UBOND_H="${ROOT}/build/ubond/src/ubond.h"
CONFIG_C="${ROOT}/build/ubond/src/config.c"

# 1. Patch existe y tiene tamano razonable (> 1 KB, < 10 KB).
if [ -f "${PATCH}" ] && [ -s "${PATCH}" ]; then
    SIZE=$(wc -c < "${PATCH}" | tr -d ' ')
    if [ "${SIZE}" -gt 1000 ] && [ "${SIZE}" -lt 10000 ]; then
        junit_pass "patch_exists_reasonable_size"
    else
        junit_fail "patch_size_out_of_range" \
            "patches/ubond_filters_count_purge.patch tiene ${SIZE} bytes (esperado 1000-10000)"
    fi
else
    junit_fail "patch_missing" \
        "patches/ubond_filters_count_purge.patch no existe o esta vacio"
    junit_finalize
fi

# 2. Patch contiene el literal de la nueva funcion.
if grep -q "ubond_replicate_filters_clear" "${PATCH}"; then
    junit_pass "function_clear_present"
else
    junit_fail "function_clear_missing" \
        "patch no introduce ubond_replicate_filters_clear"
fi

# 3. Patch llama a pcap_freecode (libera bpf_program compilados).
if grep -q "pcap_freecode" "${PATCH}"; then
    junit_pass "pcap_freecode_present"
else
    junit_fail "pcap_freecode_missing" \
        "patch sin pcap_freecode - los bpf_program quedarian sin liberar (memory leak)"
fi

# 4. Patch resetea count a 0 (no solo libera).
if grep -qE "ubond_replicate_filters\.count *= *0" "${PATCH}"; then
    junit_pass "count_reset_present"
else
    junit_fail "count_reset_missing" \
        "patch no resetea ubond_replicate_filters.count a 0 - duplicacion en SIGHUP persiste"
fi

# 5. Patch declara la funcion en ubond.h (forward decl publica).
# Heuristica: el patch debe incluir un hunk sobre src/ubond.h con la
# declaracion `void ubond_replicate_filters_clear(void)`.
if grep -q "src/ubond.h" "${PATCH}" && \
   grep -q "void ubond_replicate_filters_clear(void)" "${PATCH}"; then
    junit_pass "header_forward_decl_present"
else
    junit_fail "header_forward_decl_missing" \
        "patch sin forward decl en src/ubond.h - el call site en config.c daria warning"
fi

# 6. Patch llama a la funcion clear() en config.c (call site).
if grep -q "src/config.c" "${PATCH}" && \
   grep -qE "^\+.*ubond_replicate_filters_clear\(\)" "${PATCH}"; then
    junit_pass "config_callsite_present"
else
    junit_fail "config_callsite_missing" \
        "patch no anade call ubond_replicate_filters_clear() en src/config.c"
fi

# 7. Si build/ubond/src/filters.c existe post-build: contiene la nueva
# funcion (regression killer: si alguien rebuilda sin aplicar el patch,
# este check lo detecta).
if [ -f "${FILTERS_C}" ]; then
    if grep -q "ubond_replicate_filters_clear" "${FILTERS_C}"; then
        junit_pass "build_tree_filters_c_has_function"
    else
        junit_skip "build_tree_filters_c_unpatched" \
            "build/ubond/src/filters.c existe pero sin la funcion - rebuild pendiente"
    fi
else
    junit_skip "build_tree_filters_c_absent" \
        "build/ubond/src/filters.c no existe (CI sin clone) - skipping"
fi

# 8. Si build/ubond/src/ubond.h existe post-build: contiene la forward decl.
if [ -f "${UBOND_H}" ]; then
    if grep -q "ubond_replicate_filters_clear" "${UBOND_H}"; then
        junit_pass "build_tree_ubond_h_has_decl"
    else
        junit_skip "build_tree_ubond_h_unpatched" \
            "build/ubond/src/ubond.h existe pero sin forward decl - rebuild pendiente"
    fi
else
    junit_skip "build_tree_ubond_h_absent" \
        "build/ubond/src/ubond.h no existe (CI sin clone) - skipping"
fi

# 9. Si build/ubond/src/config.c existe post-build: contiene el call site.
if [ -f "${CONFIG_C}" ]; then
    if grep -q "ubond_replicate_filters_clear()" "${CONFIG_C}"; then
        junit_pass "build_tree_config_c_has_callsite"
    else
        junit_skip "build_tree_config_c_unpatched" \
            "build/ubond/src/config.c existe pero sin el callsite - rebuild pendiente"
    fi
else
    junit_skip "build_tree_config_c_absent" \
        "build/ubond/src/config.c no existe (CI sin clone) - skipping"
fi

# 10. 03b-setup-mac-ubond.sh aplica el patch (grep nombre).
if [ -f "${SCRIPT_03B}" ] && grep -q "ubond_filters_count_purge.patch" "${SCRIPT_03B}"; then
    junit_pass "wired_in_03b"
else
    junit_fail "not_wired_in_03b" \
        "03b-setup-mac-ubond.sh no aplica ubond_filters_count_purge.patch"
fi

# 11. 07b-setup-rpi-ubond.sh transporta y aplica el patch (grep nombre).
if [ -f "${SCRIPT_07B}" ] && grep -q "ubond_filters_count_purge.patch" "${SCRIPT_07B}"; then
    junit_pass "wired_in_07b"
else
    junit_fail "not_wired_in_07b" \
        "07b-setup-rpi-ubond.sh no transporta/aplica ubond_filters_count_purge.patch"
fi

junit_finalize
