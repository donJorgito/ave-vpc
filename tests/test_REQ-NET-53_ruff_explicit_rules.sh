#!/bin/sh
# Validates ave-vpc.REQ-NET-53: ruff con reglas explícitas y como gate de CI.
# Estático (ruff.toml y ci.yml) más una ejecución de `ruff check .` si ruff está
# instalado.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-53_ruff_explicit_rules"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CFG="${ROOT}/ruff.toml"
CI="${ROOT}/.github/workflows/ci.yml"

# 1. ruff.toml existe y declara las reglas explícitamente.
if [ -r "${CFG}" ]; then
    junit_pass "ruff_toml_present"
else
    junit_fail "ruff_toml_missing" "ruff.toml no existe"
    junit_finalize
fi
ACTIVE="$(grep -vE '^[[:space:]]*(#|$)' "${CFG}")"
if echo "${ACTIVE}" | grep -qE '^select[[:space:]]*=[[:space:]]*\["E4",[[:space:]]*"E7",[[:space:]]*"E9",[[:space:]]*"F"\]'; then
    junit_pass "rules_explicit"
else
    junit_fail "rules_not_explicit" "ruff.toml debe fijar select = [\"E4\", \"E7\", \"E9\", \"F\"]"
fi
if echo "${ACTIVE}" | grep -qE '^(ignore|per-file-ignores|extend-ignore)'; then
    junit_fail "rules_relaxed" "ruff.toml relaja reglas con ignore"
else
    junit_pass "no_ignore"
fi

# 2. ruff es un gate de CI.
if grep -vE '^[[:space:]]*#' "${CI}" | grep -qE 'run:[[:space:]]*ruff check'; then
    junit_pass "ci_runs_ruff"
else
    junit_fail "ci_no_ruff" "ci.yml no ejecuta 'ruff check'"
fi

# 3. El repo pasa ruff con la versión instalada.
if command -v ruff >/dev/null 2>&1; then
    if (cd "${ROOT}" && ruff check . >/dev/null 2>&1); then
        junit_pass "ruff_check_clean"
    else
        junit_fail "ruff_check_fails" "ruff check . falla"
    fi
else
    junit_skip "ruff_check_clean" "ruff no instalado (pip install -r requirements-dev.txt)"
fi

junit_finalize
