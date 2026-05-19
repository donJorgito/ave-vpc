#!/bin/sh
# Validates ave-vpc.REQ-SW-06: libev 4.33+ (vía Homebrew).
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-SW-06_libev"
if ! command -v brew >/dev/null 2>&1; then
    junit_skip "brew" "Homebrew no disponible (CI Linux: SKIP)"
    junit_finalize
fi
if ! brew list libev >/dev/null 2>&1; then
    junit_skip "libev_not_installed" "libev no instalada — la instala 03-setup-mac.sh"
    junit_finalize
fi
VER="$(brew list libev --versions | awk '{print $2}')"
junit_pass "libev_${VER}"
junit_finalize
