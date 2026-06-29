#!/usr/bin/env bash
# check_idlc_files.sh — verifica que los ficheros obligatorios IDLC v6
# existen en la raíz del repo.
set -euo pipefail

REQUIRED=(
    README.md CONTRIBUTING.md CHANGELOG.md CODEOWNERS LICENSE
    .pre-commit-config.yaml requirements/REQ.md tests/verificar-setup.sh
)

fail=0
for f in "${REQUIRED[@]}"; do
    if [ -f "${f}" ]; then
        echo "✓ ${f}"
    else
        echo "ERROR: ${f} no existe"
        fail=1
    fi
done
exit "${fail}"
