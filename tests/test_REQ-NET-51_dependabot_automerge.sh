#!/bin/sh
# Validates ave-vpc.REQ-NET-51: auto-merge de PRs minor/patch de Dependabot.
# Offline y estático: solo lee .github/workflows/dependabot-automerge.yml.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-51_dependabot_automerge"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF="${ROOT}/.github/workflows/dependabot-automerge.yml"

if [ -r "${WF}" ]; then
    junit_pass "workflow_present"
else
    junit_fail "workflow_missing" "dependabot-automerge.yml no existe"
    junit_finalize
fi

ACTIVE="$(grep -vE '^[[:space:]]*(#|$)' "${WF}")"

# 1. Disparador seguro: pull_request, nunca pull_request_target.
if echo "${ACTIVE}" | grep -q 'pull_request_target'; then
    junit_fail "pull_request_target" "usa pull_request_target (ejecuta con secretos sobre PR ajeno)"
elif echo "${ACTIVE}" | grep -qE '^[[:space:]]*pull_request:'; then
    junit_pass "trigger_pull_request"
else
    junit_fail "trigger_missing" "no declara el disparador pull_request"
fi

# 2. Solo actúa sobre el bot.
if echo "${ACTIVE}" | grep -q "github.event.pull_request.user.login == 'dependabot\[bot\]'"; then
    junit_pass "bot_only_condition"
else
    junit_fail "bot_condition_missing" "falta la condición user.login == 'dependabot[bot]'"
fi

# 3. Solo minor y patch; el major no se menciona como permitido.
if echo "${ACTIVE}" | grep -q 'semver-minor' && echo "${ACTIVE}" | grep -q 'semver-patch'; then
    junit_pass "minor_patch_allowed"
else
    junit_fail "minor_patch_missing" "faltan los tipos semver-minor/semver-patch"
fi
if echo "${ACTIVE}" | grep -q 'semver-major'; then
    junit_fail "major_allowed" "el workflow menciona semver-major"
else
    junit_pass "major_excluded"
fi

# 4. No hace checkout ni ejecuta código del PR.
if echo "${ACTIVE}" | grep -q 'actions/checkout'; then
    junit_fail "checkout_present" "hace checkout del código del PR"
else
    junit_pass "no_checkout"
fi

# 5. Permisos mínimos: nivel de workflow vacío y solo los dos permisos del job.
if echo "${ACTIVE}" | grep -qE '^permissions:[[:space:]]*\{\}'; then
    junit_pass "workflow_permissions_empty"
else
    junit_fail "workflow_permissions" "falta 'permissions: {}' a nivel de workflow"
fi
N_PERM="$(echo "${ACTIVE}" | grep -cE '^[[:space:]]+(contents|pull-requests|issues|actions|checks|packages|id-token):')"
if [ "${N_PERM}" = "2" ] && echo "${ACTIVE}" | grep -qE 'contents:[[:space:]]*write' &&
    echo "${ACTIVE}" | grep -qE 'pull-requests:[[:space:]]*write'; then
    junit_pass "job_permissions_minimal"
else
    junit_fail "job_permissions" "el job debe declarar solo contents: write y pull-requests: write"
fi

# 6. Regla 7: toda action externa va fijada a un SHA de 40 caracteres.
BAD="$(echo "${ACTIVE}" | grep -E '^[[:space:]]*-?[[:space:]]*uses:' | grep -vE '@[0-9a-f]{40}([[:space:]]|$)' || true)"
if [ -z "${BAD}" ]; then
    junit_pass "actions_pinned_sha"
else
    junit_fail "action_not_pinned" "action sin SHA: ${BAD}"
fi

# 7. Fusiona en modo programado (auto), no inmediato.
if echo "${ACTIVE}" | grep -q 'gh pr merge --auto --squash'; then
    junit_pass "merge_auto_squash"
else
    junit_fail "merge_not_auto" "falta 'gh pr merge --auto --squash'"
fi

junit_finalize
