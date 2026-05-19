#!/bin/sh
# tests/verificar-setup.sh
#
# Orquestador de los tests de trazabilidad IDLC.
# Ejecuta secuencialmente todos los `test_REQ-*.sh` del directorio,
# cada uno valida un requirement individual y emite un reporte JUnit XML
# en `reports/`. Resume PASS/FAIL/SKIP al final.
#
# Uso: ./tests/verificar-setup.sh
# Salida: lista por test + resumen + código 1 si alguno falla.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "${SCRIPT_DIR}")" || exit 1  # raíz del repo

REPORT_DIR="reports"
mkdir -p "${REPORT_DIR}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAILED_TESTS=""

for t in "${SCRIPT_DIR}"/test_REQ-*.sh; do
    [ -f "${t}" ] || continue
    NAME="$(basename "${t}" .sh)"
    OUTPUT="$(sh "${t}" 2>&1)"
    EXIT_CODE=$?
    LAST_LINE="$(echo "${OUTPUT}" | tail -1)"

    case "${LAST_LINE}" in
        *"RESULT: PASS"*)
            PASS_COUNT=$((PASS_COUNT + 1))
            printf "${GREEN}  ✓ %s${NC}\n" "${NAME}"
            ;;
        *"RESULT: SKIP"*)
            SKIP_COUNT=$((SKIP_COUNT + 1))
            printf "${YELLOW}  ⊝ %s${NC}\n" "${NAME}"
            ;;
        *)
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAILED_TESTS="${FAILED_TESTS} ${NAME}"
            printf "${RED}  ✗ %s (exit ${EXIT_CODE})${NC}\n" "${NAME}"
            # Mostrar las líneas FAIL del output del test fallido
            echo "${OUTPUT}" | grep "FAIL:" | sed 's/^/      /'
            ;;
    esac
done

TOTAL=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
echo ""
echo "── Resumen ───────────────────────────────────────"
printf "  ${GREEN}PASS: %d${NC}   ${RED}FAIL: %d${NC}   ${YELLOW}SKIP: %d${NC}   Total: %d\n" \
    "${PASS_COUNT}" "${FAIL_COUNT}" "${SKIP_COUNT}" "${TOTAL}"
echo "  Reportes JUnit XML en: ${REPORT_DIR}/"

if [ "${FAIL_COUNT}" -gt 0 ]; then
    echo ""
    printf "${RED}✗ Tests fallidos:${NC}%s\n" "${FAILED_TESTS}"
    exit 1
fi

if [ "${PASS_COUNT}" -eq 0 ] && [ "${SKIP_COUNT}" -gt 0 ]; then
    printf "${YELLOW}⊝ Todos los tests omitidos (entorno sin VPS/móviles/macOS).${NC}\n"
    exit 0
fi

printf "${GREEN}✓ Todos los tests obligatorios pasaron.${NC}\n"
exit 0
