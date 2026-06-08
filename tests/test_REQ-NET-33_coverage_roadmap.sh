#!/bin/sh
# Validates ave-vpc.REQ-NET-33: code coverage roadmap (3 fases).
#
# Este REQ es de tipo "roadmap/meta" — no implementa una feature concreta
# sino que planifica las 3 fases incrementales de code coverage:
# Fase 1 (Python pytest+cov), Fase 2 (Bash kcov), Fase 3 (C gcov+lcov).
#
# El test verifica que el roadmap está documentado y que cada fase
# arrancada tiene su artefacto correspondiente. Así cumple la regla IDLC
# v6 §7.3 "1:1 filename↔requirement mapping" sin fingir cobertura
# funcional de un meta-REQ.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-33_coverage_roadmap"

ROOT="$(dirname "$0")/.."
REQ_DOC="${ROOT}/requirements/ave-vpc-REQ-NET-33-requirement.md"
ROADMAP_DOC="${ROOT}/docs/v2-ubond/10-code-coverage-roadmap.md"

# 1. Requirement file existe.
if [ -r "${REQ_DOC}" ]; then
    junit_pass "req_doc_present"
else
    junit_fail "req_doc_missing" "requirements/ave-vpc-REQ-NET-33-requirement.md no existe"
    junit_finalize
fi

# 2. Roadmap doc detallado existe y referencia las 3 fases.
if [ -r "${ROADMAP_DOC}" ]; then
    junit_pass "roadmap_doc_present"
else
    junit_fail "roadmap_doc_missing" "docs/v2-ubond/10-code-coverage-roadmap.md no existe"
fi

# 3. Roadmap menciona Fase 1 Python.
if grep -qE "Fase 1.*[Pp]ython|Phase 1.*[Pp]ython" "${ROADMAP_DOC}" 2>/dev/null; then
    junit_pass "roadmap_phase1_python"
else
    junit_fail "roadmap_phase1_missing" "Roadmap no menciona Fase 1 Python"
fi

# 4. Roadmap menciona Fase 2 Bash.
if grep -qE "Fase 2.*[Bb]ash|Phase 2.*[Bb]ash|Fase 2.*kcov|Fase 2.*bashcov" "${ROADMAP_DOC}" 2>/dev/null; then
    junit_pass "roadmap_phase2_bash"
else
    junit_fail "roadmap_phase2_missing" "Roadmap no menciona Fase 2 Bash"
fi

# 5. Roadmap menciona Fase 3 C.
if grep -qE "Fase 3.*[Cc][^a-z]|Phase 3.*[Cc][^a-z]|Fase 3.*gcov|Fase 3.*lcov" "${ROADMAP_DOC}" 2>/dev/null; then
    junit_pass "roadmap_phase3_c"
else
    junit_fail "roadmap_phase3_missing" "Roadmap no menciona Fase 3 C"
fi

# 6. Fase 1 (Python coverage) marcada implementada → artefactos
# correspondientes existen.
if grep -qE "[Ff]ase 1.*[✓\\bDONE\\b]|[Ff]ase 1.*[Hh]echa|[Ff]ase 1.*implementada" "${ROADMAP_DOC}" "${REQ_DOC}" 2>/dev/null; then
    junit_pass "phase1_marked_implemented"
    # Verificar artefactos Fase 1.
    PHASE1_OK=1
    [ -r "${ROOT}/requirements-dev.txt" ] || PHASE1_OK=0
    [ -r "${ROOT}/tests/test_req_net_31_monitor.py" ] || PHASE1_OK=0
    grep -qE "pytest-monitor-coverage|pytest.*--cov" "${ROOT}/.pre-commit-config.yaml" 2>/dev/null || PHASE1_OK=0
    if [ "${PHASE1_OK}" = "1" ]; then
        junit_pass "phase1_artifacts_present"
    else
        junit_fail "phase1_artifacts_missing" \
            "Fase 1 marcada implementada pero falta requirements-dev.txt, test pytest, o hook pre-commit"
    fi
else
    junit_skip "phase1_not_implemented_yet" "Fase 1 aún no marcada implementada (ok si planificada)"
fi

# 7. Fase 2 (Bash kcov) y Fase 3 (C gcov) — solo verificar que NO se
# han marcado implementadas falsamente (sin artefactos).
for phase in 2 3; do
    if grep -qE "[Ff]ase ${phase}.*[✓]|[Ff]ase ${phase}.*[Hh]echa|[Ff]ase ${phase}.*implementada" "${ROADMAP_DOC}" "${REQ_DOC}" 2>/dev/null; then
        case "${phase}" in
            2)
                if grep -qE "kcov|bashcov" "${ROOT}/tests/run_with_coverage.sh" 2>/dev/null \
                   || [ -d "${ROOT}/reports/coverage-bash" ]; then
                    junit_pass "phase${phase}_consistent"
                else
                    junit_fail "phase${phase}_falsely_marked" \
                        "Fase 2 marcada implementada pero falta kcov harness"
                fi
                ;;
            3)
                if [ -d "${ROOT}/tests/c" ] || [ -r "${ROOT}/reports/coverage-c.info" ]; then
                    junit_pass "phase${phase}_consistent"
                else
                    junit_fail "phase${phase}_falsely_marked" \
                        "Fase 3 marcada implementada pero falta C harness"
                fi
                ;;
        esac
    else
        junit_skip "phase${phase}_planned_only" "Fase ${phase} planificada, no implementada (ok)"
    fi
done

junit_finalize
