#!/usr/bin/env bash
# check_bash_syntax.sh — bash -n sobre todos los scripts del repo.
set -euo pipefail

fail=0
while IFS= read -r f; do
    echo "Comprobando sintaxis: ${f}"
    bash -n "${f}" || fail=1
done < <(find . -name "*.sh" -not -path "./.git/*" -not -path "./build/*")
exit "${fail}"
