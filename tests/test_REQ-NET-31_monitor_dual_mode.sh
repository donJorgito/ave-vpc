#!/bin/sh
# Validates ave-vpc.REQ-NET-31: 08-monitor.py dual-mode mlvpn/ubond.
#
# Wrapper que invoca pytest sobre tests/test_req_net_31_monitor.py
# (REQ-NET-33 Fase 1 — code coverage Python). pytest emite su propio
# JUnit XML detallado a reports/; este wrapper emite el JUnit
# IDLC-style con un check resumen para mantener la convención de
# `tests/test_REQ-NET-X_*.sh`.
#
# Si pytest no está instalado, FAIL explícito con instrucción de
# install. Pin de versiones en requirements-dev.txt.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-31_monitor_dual_mode"

ROOT="$(dirname "$0")/.."
PYTEST_FILE="${ROOT}/tests/test_req_net_31_monitor.py"
PYTEST_REPORT="${ROOT}/reports/REQ-NET-31_pytest.xml"

# 1. pytest disponible.
if ! command -v pytest >/dev/null 2>&1; then
    if ! python3 -c "import pytest" >/dev/null 2>&1; then
        junit_fail "pytest_missing" \
            "pytest no instalado. Ejecuta: pip install -r requirements-dev.txt"
        junit_finalize
    fi
fi

# 2. pytest_cov disponible.
if ! python3 -c "import pytest_cov" >/dev/null 2>&1; then
    junit_fail "pytest_cov_missing" \
        "pytest-cov no instalado. Ejecuta: pip install -r requirements-dev.txt"
    junit_finalize
fi

# 3. Test file existe.
if [ -r "${PYTEST_FILE}" ]; then
    junit_pass "pytest_file_present"
else
    junit_fail "pytest_file_missing" \
        "tests/test_req_net_31_monitor.py no existe"
    junit_finalize
fi

# 4. pytest run con coverage.
# --cov-fail-under=40: umbral inicial conservador (REQ-NET-33 Fase 1
# arrancó en 48% real; 40 deja margen para refactors menores). Subir
# cuando estabilicemos.
mkdir -p "${ROOT}/reports"
PYTEST_OUTPUT="$(cd "${ROOT}" && pytest "${PYTEST_FILE}" \
    --cov=ave_monitor \
    --cov-report=term \
    --cov-fail-under=40 \
    --junitxml="${PYTEST_REPORT}" 2>&1)"
PYTEST_EXIT=$?

if [ "${PYTEST_EXIT}" -eq 0 ]; then
    junit_pass "pytest_passed_with_coverage_40pct"
else
    junit_fail "pytest_failed" \
        "pytest exit ${PYTEST_EXIT}. Ver output completo en stdout:
${PYTEST_OUTPUT}"
fi

# 5. JUnit pytest emitido a reports/.
if [ -r "${PYTEST_REPORT}" ]; then
    junit_pass "pytest_junit_emitted"
else
    junit_fail "pytest_junit_missing" \
        "pytest no emitió JUnit XML a ${PYTEST_REPORT}"
fi

junit_finalize
