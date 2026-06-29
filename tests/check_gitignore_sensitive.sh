#!/usr/bin/env bash
# check_gitignore_sensitive.sh — confirma que entradas sensibles están
# excluidas del repo.
set -euo pipefail

SENSITIVE=(
    config/env
    keys/
)

fail=0
for entry in "${SENSITIVE[@]}"; do
    if grep -q "${entry}" .gitignore; then
        echo "✓ ${entry} en .gitignore"
    else
        echo "ERROR: ${entry} no está en .gitignore"
        fail=1
    fi
done
exit "${fail}"
