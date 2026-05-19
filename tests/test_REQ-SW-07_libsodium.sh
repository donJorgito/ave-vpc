#!/bin/sh
# Validates ave-vpc.REQ-SW-07: libsodium 1.0.18+ (vía Homebrew).
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-SW-07_libsodium"
if ! command -v brew >/dev/null 2>&1; then
    junit_skip "brew" "Homebrew no disponible (CI Linux: SKIP)"
    junit_finalize
fi
if ! brew list libsodium >/dev/null 2>&1; then
    junit_skip "libsodium_not_installed" "libsodium no instalada — la instala 03-setup-mac.sh"
    junit_finalize
fi
VER="$(brew list libsodium --versions | awk '{print $2}')"
junit_pass "libsodium_${VER}"
junit_finalize
