#!/bin/sh
# Validates ave-vpc.REQ-NET-50: 08-monitor.py muestra los enlaces LOSSY (~).
#
# Wrapper que invoca pytest sobre tests/test_req_net_50_monitor_lossy.py y
# emite el JUnit IDLC-style con un check resumen (misma convención que
# test_REQ-NET-31_monitor_dual_mode.sh).
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-50_monitor_lossy_links"

ROOT="$(dirname "$0")/.."
PYTEST_FILE="${ROOT}/tests/test_req_net_50_monitor_lossy.py"
PYTEST_REPORT="${ROOT}/reports/REQ-NET-50_pytest.xml"

# 1. pytest disponible.
if ! command -v pytest >/dev/null 2>&1; then
    if ! python3 -c "import pytest" >/dev/null 2>&1; then
        junit_fail "pytest_missing" \
            "pytest no instalado. Ejecuta: pip install -r requirements-dev.txt"
        junit_finalize
    fi
fi

# 2. Test file existe.
if [ -r "${PYTEST_FILE}" ]; then
    junit_pass "pytest_file_present"
else
    junit_fail "pytest_file_missing" \
        "tests/test_req_net_50_monitor_lossy.py no existe"
    junit_finalize
fi

# 3. pytest run.
mkdir -p "${ROOT}/reports"
PYTEST_OUTPUT="$(cd "${ROOT}" && pytest "${PYTEST_FILE}" -q \
    --junitxml="${PYTEST_REPORT}" 2>&1)"
PYTEST_EXIT=$?

if [ "${PYTEST_EXIT}" -eq 0 ]; then
    junit_pass "pytest_passed"
else
    junit_fail "pytest_failed" \
        "pytest exit ${PYTEST_EXIT}. Ver output completo en stdout:
${PYTEST_OUTPUT}"
fi

# 4. JUnit pytest emitido a reports/.
if [ -r "${PYTEST_REPORT}" ]; then
    junit_pass "pytest_junit_emitted"
else
    junit_fail "pytest_junit_missing" \
        "pytest no emitió JUnit XML a ${PYTEST_REPORT}"
fi

junit_finalize
