#!/bin/sh
# Validates ave-vpc.REQ-NET-52: el commit de ubond que compilan 03b (Mac) y 07b
# (RPi) está fijado en patches/ubond.ref (IDLC v6 Rule 7).
# Offline y estático: solo lee patches/ubond.ref y los dos scripts.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-52_ubond_pinned_ref"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REF="${ROOT}/patches/ubond.ref"
MAC="${ROOT}/03b-setup-mac-ubond.sh"
RPI="${ROOT}/07b-setup-rpi-ubond.sh"

# 1. El fichero de referencia existe y contiene un SHA de 40 caracteres.
if [ -r "${REF}" ]; then
    junit_pass "ref_file_present"
else
    junit_fail "ref_file_missing" "patches/ubond.ref no existe"
    junit_finalize
fi
if [ "$(wc -l < "${REF}" | tr -d ' ')" = "1" ] &&
    grep -qE '^[0-9a-f]{40}$' "${REF}"; then
    junit_pass "ref_is_full_sha"
else
    junit_fail "ref_not_sha" "patches/ubond.ref debe tener una sola línea con un SHA de 40 caracteres"
fi

for S in "${MAC}" "${RPI}"; do
    N="$(basename "${S}")"
    ACTIVE="$(grep -vE '^[[:space:]]*#' "${S}")"

    # 2. Lee la referencia compartida.
    if echo "${ACTIVE}" | grep -q 'patches/ubond.ref\|PATCHES_DIR}/ubond.ref'; then
        junit_pass "${N}_reads_ref"
    else
        junit_fail "${N}_no_ref" "${N} no lee patches/ubond.ref"
    fi

    # 3. Ya no clona el master sin fijar.
    if echo "${ACTIVE}" | grep -qE 'git clone[^|]*markfoodyburton/ubond'; then
        junit_fail "${N}_unpinned_clone" "${N} clona ubond sin fijar el commit"
    else
        junit_pass "${N}_no_unpinned_clone"
    fi

    # 4. Descarga el commit exacto y verifica que el checkout coincide.
    if echo "${ACTIVE}" | grep -q 'fetch.*"\${UBOND_REF}"' &&
        echo "${ACTIVE}" | grep -q 'rev-parse HEAD'; then
        junit_pass "${N}_fetches_and_verifies_ref"
    else
        junit_fail "${N}_no_verify" "${N} no hace fetch por SHA y verificación de rev-parse HEAD"
    fi
done

# 5. La RPi recibe la referencia en el entorno del script remoto.
if grep -q 'UBOND_REF="\${UBOND_REF}"' "${RPI}"; then
    junit_pass "rpi_passes_ref_to_remote"
else
    junit_fail "rpi_ref_not_passed" "07b no pasa UBOND_REF al script remoto"
fi

junit_finalize
