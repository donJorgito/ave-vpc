#!/bin/sh
# tests/_lib_junit.sh
#
# Helper común para los tests test_REQ-*.sh.
#
# Uso típico:
#   . "$(dirname "$0")/_lib_junit.sh"
#   junit_init "REQ-XX-NN_short_description"
#   if condicion_test; then junit_pass "case_name"; else junit_fail "case_name" "razón"; fi
#   junit_finalize
#
# Salida: $REPORT_DIR/${TESTSUITE}.xml + códigos de retorno (0 OK, 1 fail).
# Si todos los testcases son SKIP, exit 0 (skip no rompe el pipeline).

# Reset POSIX
set -eu

REPORT_DIR="${REPORTS_DIR:-reports}"

junit_init() {
    TESTSUITE="$1"
    REPORT_FILE="${REPORT_DIR}/${TESTSUITE}.xml"
    mkdir -p "${REPORT_DIR}"
    TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%S")"
    TOTAL=0
    FAILURES=0
    SKIPS=0
    CASES=""
    echo "=== ${TESTSUITE} ==="
}

junit_pass() {
    name="$1"
    TOTAL=$((TOTAL + 1))
    CASES="${CASES}
    <testcase name=\"${name}\" classname=\"${TESTSUITE}\"/>"
    echo "  PASS: ${name}"
}

junit_fail() {
    name="$1"
    msg="${2:-failed}"
    TOTAL=$((TOTAL + 1))
    FAILURES=$((FAILURES + 1))
    CASES="${CASES}
    <testcase name=\"${name}\" classname=\"${TESTSUITE}\">
      <failure message=\"${msg}\"/>
    </testcase>"
    echo "  FAIL: ${name} — ${msg}"
}

junit_skip() {
    name="$1"
    msg="${2:-skipped}"
    TOTAL=$((TOTAL + 1))
    SKIPS=$((SKIPS + 1))
    CASES="${CASES}
    <testcase name=\"${name}\" classname=\"${TESTSUITE}\">
      <skipped message=\"${msg}\"/>
    </testcase>"
    echo "  SKIP: ${name} — ${msg}"
}

junit_finalize() {
    cat > "${REPORT_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="${TESTSUITE}" tests="${TOTAL}" failures="${FAILURES}" skipped="${SKIPS}" timestamp="${TIMESTAMP}">${CASES}
  </testsuite>
</testsuites>
EOF
    echo "Report: ${REPORT_FILE}"
    if [ "${FAILURES}" -gt 0 ]; then
        echo "RESULT: FAIL (${FAILURES}/${TOTAL} failures)"
        exit 1
    fi
    if [ "${SKIPS}" -eq "${TOTAL}" ] && [ "${TOTAL}" -gt 0 ]; then
        echo "RESULT: SKIP (todos los checks omitidos)"
        exit 0
    fi
    echo "RESULT: PASS (${TOTAL} checks, ${SKIPS} skipped)"
    exit 0
}
