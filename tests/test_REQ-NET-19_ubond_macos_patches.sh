#!/bin/sh
# Validates ave-vpc.REQ-NET-19: patches macOS para ubond.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-19_ubond_macos_patches"

ROOT="$(dirname "$0")/.."
PATCH="${ROOT}/patches/ubond_macos_compile.patch"
TUNTAP="${ROOT}/patches/tuntap_darwin_utun_ubond.c"

# Check 1: ambos archivos existen
if [ -f "${PATCH}" ] && [ -f "${TUNTAP}" ]; then
    junit_pass "patch_files_exist"
else
    junit_fail "missing_files" "patches/ubond_macos_compile.patch o tuntap_darwin_utun_ubond.c no existen"
    junit_finalize
fi

# Check 2: patch tiene cabeceras unified diff estándar
if head -2 "${PATCH}" | grep -q "^--- a/src/ubond.c$" \
   && head -2 "${PATCH}" | grep -q "^+++ b/src/ubond.c$"; then
    junit_pass "patch_has_standard_headers"
else
    junit_fail "wrong_headers" "el patch no tiene cabeceras a/src/ubond.c y b/src/ubond.c"
fi

# Check 3: patch usa #ifdef __linux__ (no SO_BINDTODEVICE)
# (macOS define SO_BINDTODEVICE pero la API no funciona)
if grep -q "#ifdef __linux__" "${PATCH}" \
   && ! grep -qE "^\\+#if defined\\(SO_BINDTODEVICE\\)" "${PATCH}"; then
    junit_pass "uses_ifdef_linux"
else
    junit_fail "wrong_guard" "patch no usa #ifdef __linux__ (debe usar eso, no SO_BINDTODEVICE)"
fi

# Check 4: el patch añade rama macOS con log_warnx informativo
if grep -q '#else' "${PATCH}" \
   && grep -q "binddev.*ignored" "${PATCH}"; then
    junit_pass "macos_branch_logs"
else
    junit_fail "no_macos_branch" "no hay rama #else con log_warnx para macOS"
fi

# Check 5: tuntap_darwin_utun_ubond.c implementa las 4 funciones
# requeridas por la API de ubond
if grep -q "^ubond_pkt_t \*$" "${TUNTAP}" \
   || grep -q "^ubond_pkt_t \*ubond_tuntap_read" "${TUNTAP}" \
   || grep -q "^ubond_tuntap_read" "${TUNTAP}"; then
    if grep -q "ubond_tuntap_read" "${TUNTAP}" \
       && grep -q "ubond_tuntap_write" "${TUNTAP}" \
       && grep -q "ubond_tuntap_alloc" "${TUNTAP}" \
       && grep -q "root_tuntap_open" "${TUNTAP}"; then
        junit_pass "implements_all_4_functions"
    else
        junit_fail "missing_functions" "faltan funciones de la API ubond"
    fi
else
    junit_fail "missing_functions" "faltan funciones de la API ubond"
fi

# Check 6: NO incluye buffer.h (ubond no lo tiene)
if ! grep -q '#include "buffer.h"' "${TUNTAP}"; then
    junit_pass "no_buffer_h_dependency"
else
    junit_fail "buffer_h_included" 'tuntap_darwin_utun_ubond.c incluye buffer.h pero ubond no lo tiene'
fi

# Check 7: Usa SYSPROTO_CONTROL + UTUN_CONTROL_NAME (API utun macOS)
if grep -q "SYSPROTO_CONTROL" "${TUNTAP}" \
   && grep -q "UTUN_CONTROL_NAME" "${TUNTAP}"; then
    junit_pass "uses_utun_api"
else
    junit_fail "no_utun_api" "no usa la API utun de macOS (SYSPROTO_CONTROL)"
fi

# Check 8: prefijo de 4 bytes con AF_INET (requisito utun)
if grep -q "UTUN_HEADER_SIZE" "${TUNTAP}" \
   && grep -q "htonl(AF_INET)" "${TUNTAP}"; then
    junit_pass "handles_utun_4byte_prefix"
else
    junit_fail "no_prefix_handling" "no maneja el prefijo de 4 bytes de utun"
fi

# Check 9: root_tuntap_open rechaza modo TAP (utun es solo TUN)
if grep -q "TUNTAPMODE_TAP" "${TUNTAP}" \
   && grep -q "TAP mode not supported" "${TUNTAP}"; then
    junit_pass "rejects_tap_mode"
else
    junit_fail "no_tap_check" "root_tuntap_open no rechaza modo TAP"
fi

# Check 10: ubond_tuntap_alloc llama priv_open_tun (no abre directo)
# Esa es la división privsep correcta — la apertura real va por root
if grep -q "priv_open_tun" "${TUNTAP}"; then
    junit_pass "uses_privsep_correctly"
else
    junit_fail "no_privsep" "ubond_tuntap_alloc no llama priv_open_tun"
fi

junit_finalize
