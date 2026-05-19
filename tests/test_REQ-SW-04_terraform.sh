#!/bin/sh
# Validates ave-vpc.REQ-SW-04: Terraform 1.5+.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-SW-04_terraform"
if ! command -v terraform >/dev/null 2>&1; then
    junit_skip "terraform" "terraform no instalado"
    junit_finalize
fi
VER="$(terraform -version 2>/dev/null | head -1 | sed 's/Terraform v//')"
MAJOR="${VER%%.*}"
REST="${VER#*.}"
MINOR="${REST%%.*}"
if [ "${MAJOR}" -gt 1 ] 2>/dev/null || { [ "${MAJOR}" = "1" ] && [ "${MINOR}" -ge 5 ]; } 2>/dev/null; then
    junit_pass "terraform_${VER}"
else
    junit_fail "terraform_${VER}" "Terraform ${VER} < 1.5"
fi
junit_finalize
