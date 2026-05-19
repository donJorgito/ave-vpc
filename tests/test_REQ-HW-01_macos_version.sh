#!/bin/sh
# Validates ave-vpc.REQ-HW-01: Mac con macOS 13 (Ventura) o superior.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"

junit_init "REQ-HW-01_macos_version"

if ! command -v sw_vers >/dev/null 2>&1; then
    junit_skip "macos_version" "no estamos en macOS"
    junit_finalize
fi

VERSION="$(sw_vers -productVersion 2>/dev/null || echo "0")"
MAJOR="${VERSION%%.*}"

if [ "${MAJOR}" -ge 13 ] 2>/dev/null; then
    junit_pass "macos_version_${VERSION}"
else
    junit_fail "macos_version_${VERSION}" "macOS ${VERSION} < 13 (Ventura)"
fi

junit_finalize
