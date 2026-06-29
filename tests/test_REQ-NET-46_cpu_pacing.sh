#!/bin/sh
# Validates ave-vpc.REQ-NET-46: elimina busy-wait CPU 99% en ubond (pacing por
# lotes). Checks ESTÁTICOS sobre el patch (no compila, no toca red): el patch
# existe, aplica limpio sobre upstream + los 7 patches previos, contiene las
# marcas del fix (envío en lote, ev_timer durmiente, floors de 5ms) y no deja
# ev_check_start residual en las rutas corregidas.
#
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-46_cpu_pacing"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCHES="${ROOT}/patches"
PATCH="${PATCHES}/ubond_cpu_pacing_busywait.patch"

# 1. El patch existe.
if [ -f "${PATCH}" ]; then
    junit_pass "patch_exists"
else
    junit_fail "patch_missing" "falta patches/ubond_cpu_pacing_busywait.patch"
    junit_finalize
fi

# 2. Toca src/reorder.c y src/ubond.c.
if grep -q "^diff --git a/src/reorder.c" "${PATCH}" \
   && grep -q "^diff --git a/src/ubond.c" "${PATCH}"; then
    junit_pass "patch_targets_both_files"
else
    junit_fail "patch_targets_missing" "el patch debe tocar reorder.c y ubond.c"
fi

# 3. Marca: envío EN LOTE en do_send (bucle do/while por presupuesto).
if grep -q "Drain as many packets" "${PATCH}" \
   && grep -q "while (len > 0 && tun->bytes_since_adjust < b)" "${PATCH}"; then
    junit_pass "batch_send_present"
else
    junit_fail "batch_send_missing" "do_send no envía en lote (do/while presupuesto)"
fi

# 4. Marca: floor de 5ms en recalc_weight (cap timer 200Hz).
if grep -q "cap timer at 200Hz" "${PATCH}" \
   && grep -q "repeat = 0.005" "${PATCH}"; then
    junit_pass "recalc_floor_present"
else
    junit_fail "recalc_floor_missing" "falta floor 5ms en recalc_weight"
fi

# 5. Marca: reorder_drain_check pasa a ev_timer durmiente.
if grep -q "ev_timer reorder_drain_check" "${PATCH}"; then
    junit_pass "reorder_timer_present"
else
    junit_fail "reorder_timer_missing" "reorder_drain_check sigue siendo ev_check"
fi

# 6. NO debe AÑADIR (líneas '+') ningún ev_check_start en las rutas corregidas:
#    el fix sustituye ev_check por ev_timer. Líneas eliminadas ('-') sí lo tienen.
if grep -E "^\+" "${PATCH}" | grep -q "ev_check_start"; then
    junit_fail "ev_check_start_readded" "el patch reintroduce ev_check_start (+)"
else
    junit_pass "no_ev_check_start_added"
fi

# 7. Usa ev_timer_again (rearmado durmiente) en las líneas añadidas.
if grep -E "^\+" "${PATCH}" | grep -q "ev_timer_again"; then
    junit_pass "ev_timer_again_present"
else
    junit_fail "ev_timer_again_missing" "el fix no rearma con ev_timer_again"
fi

# 8. El patch aplica limpio sobre upstream fresco + los 7 patches previos
#    (solo si hay red/git; si no, se marca skipped — no bloquea CI offline).
if command -v git >/dev/null 2>&1 && command -v patch >/dev/null 2>&1; then
    TMP="$(mktemp -d)"
    if git clone --depth 1 -q https://github.com/markfoodyburton/ubond.git "${TMP}/u" 2>/dev/null; then
        ( cd "${TMP}/u" || exit 1
          for pf in ubond_replicate_filter ubond_per_link_tolerence \
                    ubond_replicate_dedup_fix ubond_filters_section_exclusion \
                    ubond_dedup_gate_data_seq ubond_rebind_on_silence \
                    ubond_filters_count_purge; do
              [ -f "${PATCHES}/${pf}.patch" ] && \
                  patch -p1 -N < "${PATCHES}/${pf}.patch" >/dev/null 2>&1
          done
          # --dry-run + grep de "hunk" fallido: patch devuelve 0 a veces aun
          # con hunks ignorados, así que comprobamos el texto también.
          out="$(patch -p1 --dry-run < "${PATCH}" 2>&1)"
          echo "${out}" | grep -qiE "fail|hunk.*ignored" && exit 1
          exit 0 )
        if [ $? -eq 0 ]; then
            junit_pass "patch_applies_clean"
        else
            junit_fail "patch_apply_failed" "el patch no aplica limpio sobre upstream+7"
        fi
    else
        junit_skip "patch_applies_clean" "sin red para clonar upstream"
    fi
    rm -rf "${TMP}"
else
    junit_skip "patch_applies_clean" "git/patch no disponibles"
fi

# 9. Integrado en 07b-setup-rpi-ubond.sh (despliegue Linux/servidor).
if grep -q "ubond_cpu_pacing_busywait" "${ROOT}/07b-setup-rpi-ubond.sh"; then
    junit_pass "integrated_in_07b"
else
    junit_fail "not_integrated_07b" "07b no aplica el patch REQ-NET-46"
fi

junit_finalize
