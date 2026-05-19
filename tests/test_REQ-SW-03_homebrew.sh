#!/bin/sh
# Validates ave-vpc.REQ-SW-03: Homebrew.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-SW-03_homebrew"
if ! command -v brew >/dev/null 2>&1; then
    junit_skip "brew" "Homebrew no instalado (CI Linux: SKIP)"
    junit_finalize
fi
junit_pass "brew_$(brew --version | head -1 | tr ' ' '_')"
junit_finalize
