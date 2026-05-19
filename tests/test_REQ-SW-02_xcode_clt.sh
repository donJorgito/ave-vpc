#!/bin/sh
# Validates ave-vpc.REQ-SW-02: Xcode Command Line Tools.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-SW-02_xcode_clt"
if ! command -v xcode-select >/dev/null 2>&1; then
    junit_skip "xcode_select" "xcode-select no disponible (no macOS)"
    junit_finalize
fi
if xcode-select -p >/dev/null 2>&1; then
    junit_pass "xcode_clt_installed"
else
    junit_fail "xcode_clt" "xcode-select -p falla"
fi
junit_finalize
