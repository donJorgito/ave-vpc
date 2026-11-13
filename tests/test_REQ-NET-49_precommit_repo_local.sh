#!/bin/sh
# Validates ave-vpc.REQ-NET-49: los hooks de pre-commit se declaran como
# `repo: local` (IDLC v6.2.1 §7.2, Rule 1 / §8.3.7) con versiones fijadas.
# Offline y estático: solo lee .pre-commit-config.yaml y requirements-dev.txt.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-49_precommit_repo_local"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CFG="${ROOT}/.pre-commit-config.yaml"
DEV="${ROOT}/requirements-dev.txt"

if [ -r "${CFG}" ]; then
    junit_pass "config_present"
else
    junit_fail "config_missing" ".pre-commit-config.yaml no existe"
    junit_finalize
fi

# Líneas activas (sin comentarios ni vacías).
ACTIVE="$(grep -vE '^[[:space:]]*(#|$)' "${CFG}")"

# 1. Ningún repo remoto: ni `repo: https://`, ni `rev:`, ni URL github.com activa.
if echo "${ACTIVE}" | grep -qE 'repo:[[:space:]]*(https?|git|ssh)://|repo:[[:space:]]*git@'; then
    junit_fail "remote_repo_present" "queda un 'repo:' remoto"
else
    junit_pass "no_remote_repo"
fi
if echo "${ACTIVE}" | grep -qE '^[[:space:]]*rev:|github\.com'; then
    junit_fail "rev_or_github_present" "quedan 'rev:' o referencias a github.com en líneas activas"
else
    junit_pass "no_rev_no_github"
fi

# 2. Todos los repos son `local` (nº de 'repo:' == nº de 'repo: local').
N_REPO="$(echo "${ACTIVE}" | grep -cE '^[[:space:]]*-[[:space:]]*repo:')"
N_LOCAL="$(echo "${ACTIVE}" | grep -cE '^[[:space:]]*-[[:space:]]*repo:[[:space:]]*local[[:space:]]*$')"
if [ "${N_REPO}" -ge 1 ] && [ "${N_REPO}" = "${N_LOCAL}" ]; then
    junit_pass "all_repos_local"
else
    junit_fail "repos_not_all_local" "repo=${N_REPO} local=${N_LOCAL}"
fi

# 3. Todo hook usa `language: system` (herramienta preinstalada, sin clonar).
N_HOOK="$(echo "${ACTIVE}" | grep -cE '^[[:space:]]*-[[:space:]]*id:')"
N_SYS="$(echo "${ACTIVE}" | grep -cE '^[[:space:]]*language:[[:space:]]*system[[:space:]]*$')"
if [ "${N_HOOK}" -ge 1 ] && [ "${N_HOOK}" = "${N_SYS}" ]; then
    junit_pass "all_hooks_language_system"
else
    junit_fail "hooks_not_system" "hooks=${N_HOOK} system=${N_SYS}"
fi

# 4. Los hooks esperados siguen presentes (no se quitó ninguna regla).
for id in trailing-whitespace end-of-file-fixer check-yaml check-added-large-files \
          detect-private-key shellcheck gitleaks markdownlint ruff pytest-monitor-coverage; do
    if echo "${ACTIVE}" | grep -qE "^[[:space:]]*-[[:space:]]*id:[[:space:]]*${id}[[:space:]]*$"; then
        junit_pass "hook_${id}"
    else
        junit_fail "hook_${id}_missing" "falta el hook ${id}"
    fi
done

# 5. Rule 7: versiones fijadas, sin 'latest'; cada herramienta con versión X.Y.Z.
if grep -qi 'latest' "${CFG}"; then
    junit_fail "latest_present" "'latest' no está permitido (Rule 7)"
else
    junit_pass "no_latest"
fi
for tool in pre-commit pre-commit-hooks ruff markdownlint-cli shellcheck gitleaks; do
    if grep -E "^#[[:space:]]+${tool}[[:space:]]" "${CFG}" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'; then
        junit_pass "version_documented_${tool}"
    else
        junit_fail "version_missing_${tool}" "sin versión X.Y.Z en la tabla de herramientas"
    fi
done
for pkg in pre-commit pre-commit-hooks ruff; do
    if grep -qE "^${pkg}==[0-9]+\.[0-9]+\.[0-9]+" "${DEV}"; then
        junit_pass "pinned_${pkg}"
    else
        junit_fail "unpinned_${pkg}" "${pkg}== no fijado en requirements-dev.txt"
    fi
done

# 6. Paridad CI <-> pre-commit: el pre-commit solo anticipa los fallos del CI si
#    usan la misma herramienta y versión. Se compara la versión documentada en la
#    cabecera de .pre-commit-config.yaml con la que fija .github/workflows/ci.yml.
CI="${ROOT}/.github/workflows/ci.yml"
if [ -r "${CI}" ]; then
    junit_pass "ci_present"
else
    junit_fail "ci_missing" ".github/workflows/ci.yml no existe"
    junit_finalize
fi
CI_ACTIVE="$(grep -vE '^[[:space:]]*(#|$)' "${CI}")"

# 6a. El CI ya no reutiliza pre-commit como escáner (las herramientas son
#     'language: system' y el runner no las tiene instaladas).
if echo "${CI_ACTIVE}" | grep -qE 'pre-commit/action'; then
    junit_fail "ci_uses_precommit_action" "ci.yml aún invoca pre-commit/action"
else
    junit_pass "ci_no_precommit_action"
fi

# 6b. gitleaks: imagen fijada por tag y digest, con la misma versión que el hook.
CFG_GITLEAKS="$(grep -E '^#[[:space:]]+gitleaks[[:space:]]' "${CFG}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
CI_GITLEAKS_REF="$(echo "${CI_ACTIVE}" | grep -oE 'docker://[^[:space:]]*gitleaks[^[:space:]]*' | head -1)"
CI_GITLEAKS="$(echo "${CI_GITLEAKS_REF}" | grep -oE ':v[0-9]+\.[0-9]+\.[0-9]+' | head -1 | tr -d ':v')"
if echo "${CI_GITLEAKS_REF}" | grep -qE '@sha256:[0-9a-f]{64}$'; then
    junit_pass "ci_gitleaks_digest_pinned"
else
    junit_fail "ci_gitleaks_not_digest_pinned" "imagen sin @sha256:<64 hex>: '${CI_GITLEAKS_REF}'"
fi
if [ -n "${CFG_GITLEAKS}" ] && [ "${CFG_GITLEAKS}" = "${CI_GITLEAKS}" ]; then
    junit_pass "gitleaks_version_parity"
else
    junit_fail "gitleaks_version_drift" "pre-commit='${CFG_GITLEAKS}' ci='${CI_GITLEAKS}'"
fi

# 6c. shellcheck: versión explícita en el CI (nunca 'stable'/'latest') e igual a la del hook.
CFG_SHELLCHECK="$(grep -E '^#[[:space:]]+shellcheck[[:space:]]' "${CFG}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
CI_SHELLCHECK="$(echo "${CI_ACTIVE}" | grep -E '^[[:space:]]*version:[[:space:]]*v[0-9]+\.[0-9]+\.[0-9]+' | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)"
if [ -n "${CFG_SHELLCHECK}" ] && [ "${CFG_SHELLCHECK}" = "${CI_SHELLCHECK}" ]; then
    junit_pass "shellcheck_version_parity"
else
    junit_fail "shellcheck_version_drift" "pre-commit='${CFG_SHELLCHECK}' ci='${CI_SHELLCHECK}'"
fi

# 6d. gitleaks usa la MISMA configuración en el hook local y en el CI
#     (.gitleaks.toml), de modo que ambos aplican las mismas reglas.
GL_CONF="${ROOT}/.gitleaks.toml"
if [ -r "${GL_CONF}" ]; then
    junit_pass "gitleaks_config_present"
else
    junit_fail "gitleaks_config_missing" ".gitleaks.toml no existe"
    junit_finalize
fi
if echo "${ACTIVE}" | grep -E 'entry:[[:space:]]*gitleaks' | grep -qF -- '--config .gitleaks.toml'; then
    junit_pass "hook_gitleaks_uses_config"
else
    junit_fail "hook_gitleaks_no_config" "el hook gitleaks no pasa --config .gitleaks.toml"
fi
if echo "${CI_ACTIVE}" | grep -E '^[[:space:]]*args:' | grep -F 'dir' | grep -qF -- '--config .gitleaks.toml'; then
    junit_pass "ci_gitleaks_uses_config"
else
    junit_fail "ci_gitleaks_no_config" "el paso gitleaks del CI no pasa --config .gitleaks.toml"
fi

# 6e. La regla `private-key-header` cubre las 10 entradas de detect-private-key
#     (BLACKLIST de pre-commit-hooks 4.6.0). La regla por defecto de gitleaks no
#     marca cabeceras sueltas ni los formatos PuTTY, SSH2 y OpenVPN. Las
#     entradas se construyen en dos mitades para que este fichero no contenga
#     cabeceras completas y no lo marquen ni detect-private-key ni gitleaks.
if python3 -I - "${GL_CONF}" <<'PY'
import re
import sys
import tomllib

cfg = tomllib.load(open(sys.argv[1], "rb"))
rule = next(r for r in cfg["rules"] if r["id"] == "private-key-header")
rx = re.compile(rule["regex"])
kw = [k.lower() for k in rule["keywords"]]
entries = [
    ("BEGIN RSA PRIVATE ", "KEY"), ("BEGIN DSA PRIVATE ", "KEY"),
    ("BEGIN EC PRIVATE ", "KEY"), ("BEGIN OPENSSH PRIVATE ", "KEY"),
    ("BEGIN PRIVATE ", "KEY"), ("PuTTY-User-Key-File-", "2"),
    ("BEGIN SSH2 ENCRYPTED PRIVATE ", "KEY"),
    ("BEGIN PGP PRIVATE KEY ", "BLOCK"),
    ("BEGIN ENCRYPTED PRIVATE ", "KEY"),
    ("BEGIN OpenVPN Static key V", "1"),
]
bad = []
for a, b in entries:
    s = a + b
    if not rx.search(s):
        bad.append("regex no cubre: " + s)
    if not any(k in s.lower() for k in kw):
        bad.append("keyword no cubre: " + s)
if bad:
    print("; ".join(bad))
    sys.exit(1)
PY
then
    junit_pass "private_key_header_covers_detect_private_key"
else
    junit_fail "private_key_header_gap" "la regla private-key-header no cubre alguna entrada de detect-private-key"
fi

junit_finalize
