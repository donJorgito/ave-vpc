#!/bin/sh
# Validates IDLC v6 Section 5.3.3.4: trazabilidad REQ ↔ Test.
#
# Cada `requirements/ave-vpc-REQ-*-requirement.md` debe tener un
# correspondiente `tests/test_REQ-*.sh` y viceversa. Sin esto, el repo
# pierde la garantía de que cada requisito está testeado.
#
# El step equivalente existe en .github/workflows/ci.yml (línea 90).
# Este test local lo replica para que el desarrollador detecte mismatches
# antes de empujar (no esperar al CI verde/rojo).
#
# El nombre del fichero NO es `test_REQ-XX-NN_*.sh` porque NO valida un
# requirement individual — valida la trazabilidad transversal del proyecto.
#
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "trazabilidad_idlc"

ROOT="$(dirname "$0")/.."

# Check 1: cada REQ tiene su test
missing_tests=""
for req in "${ROOT}"/requirements/ave-vpc-REQ-*-requirement.md; do
    [ -f "${req}" ] || continue
    ID=$(basename "${req}" | sed -E 's/^ave-vpc-(REQ-[A-Z]+-[0-9]+)-requirement\.md$/\1/')
    if ! ls "${ROOT}"/tests/test_${ID}_*.sh >/dev/null 2>&1; then
        missing_tests="${missing_tests} ${ID}"
    fi
done
if [ -z "${missing_tests}" ]; then
    junit_pass "every_req_has_test"
else
    junit_fail "reqs_without_test" "REQs sin test:${missing_tests}"
fi

# Check 2: cada test tiene su REQ
missing_reqs=""
for t in "${ROOT}"/tests/test_REQ-*.sh; do
    [ -f "${t}" ] || continue
    ID=$(basename "${t}" .sh | sed -E 's/^test_(REQ-[A-Z]+-[0-9]+)_.*$/\1/')
    if ! [ -f "${ROOT}/requirements/ave-vpc-${ID}-requirement.md" ]; then
        missing_reqs="${missing_reqs} ${ID}"
    fi
done
if [ -z "${missing_reqs}" ]; then
    junit_pass "every_test_has_req"
else
    junit_fail "tests_without_req" "Tests sin REQ:${missing_reqs}"
fi

# Check 3: cada REQ está listado en requirements/REQ.md (índice)
unlisted=""
for req in "${ROOT}"/requirements/ave-vpc-REQ-*-requirement.md; do
    [ -f "${req}" ] || continue
    ID=$(basename "${req}" | sed -E 's/^ave-vpc-(REQ-[A-Z]+-[0-9]+)-requirement\.md$/\1/')
    if ! grep -q "${ID}" "${ROOT}/requirements/REQ.md"; then
        unlisted="${unlisted} ${ID}"
    fi
done
if [ -z "${unlisted}" ]; then
    junit_pass "every_req_in_index"
else
    junit_fail "reqs_unlisted" "REQs no listados en REQ.md:${unlisted}"
fi

# Check 4: la primera línea de cada REQ doc tiene el ID en el título
# (formato esperado: "### ave-vpc.REQ-NET-XX - <título>")
malformed=""
for req in "${ROOT}"/requirements/ave-vpc-REQ-*-requirement.md; do
    [ -f "${req}" ] || continue
    ID=$(basename "${req}" | sed -E 's/^ave-vpc-(REQ-[A-Z]+-[0-9]+)-requirement\.md$/\1/')
    first_line=$(head -1 "${req}")
    if ! echo "${first_line}" | grep -q "ave-vpc\.${ID}"; then
        malformed="${malformed} ${ID}"
    fi
done
if [ -z "${malformed}" ]; then
    junit_pass "every_req_has_correct_title"
else
    junit_fail "malformed_titles" "REQs con título mal formado:${malformed}"
fi

# Check 5: cada REQ doc tiene la sección "Acceptance Criteria"
no_ac=""
for req in "${ROOT}"/requirements/ave-vpc-REQ-*-requirement.md; do
    [ -f "${req}" ] || continue
    ID=$(basename "${req}" | sed -E 's/^ave-vpc-(REQ-[A-Z]+-[0-9]+)-requirement\.md$/\1/')
    if ! grep -q "Acceptance Criteria" "${req}"; then
        no_ac="${no_ac} ${ID}"
    fi
done
if [ -z "${no_ac}" ]; then
    junit_pass "every_req_has_acceptance_criteria"
else
    junit_fail "no_acceptance_criteria" "REQs sin Acceptance Criteria:${no_ac}"
fi

junit_finalize
