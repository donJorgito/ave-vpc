#!/bin/sh
# Validates ave-vpc.REQ-SW-05: Git 2.39+.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-SW-05_git"
if ! command -v git >/dev/null 2>&1; then
    junit_fail "git" "git no instalado"
    junit_finalize
fi
VER="$(git --version | awk '{print $3}')"
MAJOR="${VER%%.*}"
REST="${VER#*.}"
MINOR="${REST%%.*}"
if [ "${MAJOR}" -gt 2 ] 2>/dev/null || { [ "${MAJOR}" = "2" ] && [ "${MINOR}" -ge 39 ]; } 2>/dev/null; then
    junit_pass "git_${VER}"
else
    junit_fail "git_${VER}" "git ${VER} < 2.39"
fi
junit_finalize
