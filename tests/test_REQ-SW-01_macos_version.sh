#!/bin/sh
# Validates ave-vpc.REQ-SW-01: macOS 13.0 o superior.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-SW-01_macos_version"
if ! command -v sw_vers >/dev/null 2>&1; then
    junit_skip "macos_version" "no estamos en macOS (CI Linux: SKIP esperado)"
    junit_finalize
fi
VERSION="$(sw_vers -productVersion 2>/dev/null || echo "0")"
MAJOR="${VERSION%%.*}"
if [ "${MAJOR}" -ge 13 ] 2>/dev/null; then
    junit_pass "macos_${VERSION}"
else
    junit_fail "macos_${VERSION}" "macOS ${VERSION} < 13"
fi
junit_finalize
