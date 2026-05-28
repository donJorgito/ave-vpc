#!/bin/sh
# Validates ave-vpc.REQ-NET-12: design doc del filtro de replicación.
# Test estático: el doc tiene que cubrir los puntos clave del diseño
# para que la Fase 3 (implementación) pueda partir de él.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-12_design_doc"

DOC="$(dirname "$0")/../requirements/ave-vpc-REQ-NET-12-requirement.md"

[ -f "${DOC}" ] || { junit_fail "doc_missing" "REQ-NET-12 doc no existe"; junit_finalize; }

# Check 1: Marcado como Fase 2.2 (design doc) o Fase 3 (implementado)
if grep -qE "(design doc.*Fase 2\.2|implementado.*Fase 3)" "${DOC}"; then
    junit_pass "marked_as_design_or_implemented"
else
    junit_fail "not_marked" "no está marcado como Fase 2.2/3"
fi

# Check 2: Define la sintaxis del filtro en config
if grep -q '\[filters.replicate\]' "${DOC}" \
   && grep -qE 'udp.*port|udp.*dst' "${DOC}"; then
    junit_pass "config_syntax_defined"
else
    junit_fail "no_config_syntax" "no define [filters.replicate] con ejemplos"
fi

# Check 3: Identifica las funciones concretas a modificar en ubond
if grep -q "ubond_rtun_choose" "${DOC}" \
   && grep -q "ubond_protocol_read" "${DOC}" \
   && grep -q "set_reorder" "${DOC}"; then
    junit_pass "target_functions_identified"
else
    junit_fail "no_target_functions" "no identifica funciones a modificar"
fi

# Check 4: Define dedup LRU separado del reorder buffer
if grep -qE "(dedup.*LRU|set LRU|REPLICATE_DEDUP_SIZE)" "${DOC}" \
   && grep -q "reorder buffer" "${DOC}"; then
    junit_pass "lru_dedup_defined"
else
    junit_fail "no_lru_dedup" "no define dedup LRU separado del reorder buffer"
fi

# Check 5: Justifica POR QUÉ no usar reorder buffer para dedup (latencia)
if grep -qE "espera al hueco|timeout|destructiva|RTP" "${DOC}"; then
    junit_pass "justifies_separate_dedup"
else
    junit_fail "no_justification" "no justifica por qué dedup separado del reorder"
fi

# Check 6: Edge case --failover (excluir backups)
if grep -q "fallback_only" "${DOC}" \
   && grep -q "EC1\|--failover" "${DOC}"; then
    junit_pass "ec_failover"
else
    junit_fail "missing_ec_failover" "no documenta edge case --failover"
fi

# Check 7: Edge case DATA_RESEND no replicar
if grep -q "DATA_RESEND" "${DOC}" \
   && grep -qE "no.*replicar|NO.*deben replicarse" "${DOC}"; then
    junit_pass "ec_data_resend"
else
    junit_fail "missing_ec_resend" "no documenta que DATA_RESEND no se replica"
fi

# Check 8: Edge case receptor sin replicación (compat hacia atrás)
if grep -qE "(transparente|compatibilidad hacia atrás|nunca dispara)" "${DOC}"; then
    junit_pass "ec_backward_compat"
else
    junit_fail "no_compat" "no documenta compatibilidad hacia atrás"
fi

# Check 9: data_seq global (mecanismo de identificación)
if grep -q "data_seq" "${DOC}" \
   && grep -qE "global|UN(A|i)CO|único|idéntico" "${DOC}"; then
    junit_pass "data_seq_explained"
else
    junit_fail "no_data_seq_explanation" "no explica el rol de data_seq"
fi

# Check 10: Estimación LOC realista
if grep -qE "LOC|líneas" "${DOC}" \
   && grep -qE "1[0-5][0-9].*LOC|11[0-5]" "${DOC}"; then
    junit_pass "loc_estimate_present"
else
    junit_fail "no_loc_estimate" "no hay estimación de tamaño del patch"
fi

# Check 11: Plan de pruebas con tests unitarios + integración + producción
if grep -qE "[Tt]est unitario" "${DOC}" \
   && grep -qE "integraci[oó]n" "${DOC}" \
   && grep -qE "[Aa]ve|producci[oó]n" "${DOC}"; then
    junit_pass "test_plan_complete"
else
    junit_fail "incomplete_test_plan" "plan de pruebas incompleto"
fi

# Check 12: Cambios FUERA de ubond.c documentados (filters.c, config.c, ubond.h)
if grep -q "filters.c" "${DOC}" \
   && grep -q "config.c" "${DOC}" \
   && grep -q "ubond.h" "${DOC}"; then
    junit_pass "all_files_documented"
else
    junit_fail "files_missing" "faltan referencias a filters.c/config.c/ubond.h"
fi

# Check 13: pcap_compile (reusa la API de filtros existente)
if grep -q "pcap_compile" "${DOC}"; then
    junit_pass "reuses_pcap_compile"
else
    junit_fail "no_pcap_reuse" "no documenta reuso de pcap_compile"
fi

# Check 14: hpsbuf (high-priority send buffer per-tunnel)
if grep -q "hpsbuf" "${DOC}"; then
    junit_pass "uses_hpsbuf"
else
    junit_fail "no_hpsbuf" "no menciona hpsbuf como vector de inserción"
fi

# --- Checks de IMPLEMENTACIÓN (Fase 3) ---

PATCH="$(dirname "$0")/../patches/ubond_replicate_filter.patch"

# Check 15: patch de implementación existe
if [ -f "${PATCH}" ]; then
    junit_pass "implementation_patch_exists"
else
    junit_fail "no_patch" "patches/ubond_replicate_filter.patch no existe"
    junit_finalize
fi

# Check 16: patch toca los 4 archivos esperados
if grep -q '^diff --git a/src/ubond.h' "${PATCH}" \
   && grep -q '^diff --git a/src/filters.c' "${PATCH}" \
   && grep -q '^diff --git a/src/ubond.c' "${PATCH}" \
   && grep -q '^diff --git a/src/config.c' "${PATCH}"; then
    junit_pass "patch_touches_4_files"
else
    junit_fail "missing_files" "el patch no toca los 4 archivos esperados"
fi

# Check 17: nueva struct ubond_replicate_filters_s
if grep -q "^+struct ubond_replicate_filters_s" "${PATCH}"; then
    junit_pass "struct_replicate_filters_added"
else
    junit_fail "no_struct" "no se añade struct ubond_replicate_filters_s"
fi

# Check 18: funciones públicas implementadas
if grep -q "^+int ubond_replicate_filter_match" "${PATCH}" \
   && grep -q "^+int ubond_replicate_filter_add" "${PATCH}"; then
    junit_pass "match_and_add_functions"
else
    junit_fail "missing_functions" "faltan _match() y/o _add()"
fi

# Check 19: dedup LRU implementado
if grep -q "^+#define REPLICATE_DEDUP_SIZE" "${PATCH}" \
   && grep -q "ubond_replicate_dedup_check" "${PATCH}"; then
    junit_pass "dedup_lru_implemented"
else
    junit_fail "no_dedup" "dedup LRU no implementado"
fi

# Check 20: parser config para [filters.replicate]
if grep -q "filters.replicate" "${PATCH}"; then
    junit_pass "config_parser_added"
else
    junit_fail "no_config_parser" "parser de [filters.replicate] no añadido"
fi

# Check 21: clone-to-N en rtun_choose
if grep -q "ubond_replicate_filter_match" "${PATCH}" \
   && grep -q 'LIST_FOREACH(t, &rtuns' "${PATCH}"; then
    junit_pass "clone_to_n_tunnels"
else
    junit_fail "no_clone_logic" "no se ve la lógica clone-to-N tras el match"
fi

# Check 22: dedup activo en protocol_read
if grep -q 'ubond_replicate_dedup_check(proto->data_seq)' "${PATCH}"; then
    junit_pass "dedup_active_in_read"
else
    junit_fail "no_dedup_in_read" "dedup no se invoca en protocol_read"
fi

# Check 23: respeta fallback_only (modo --failover)
if grep -qE 'if \(t->fallback_only\)' "${PATCH}"; then
    junit_pass "respects_fallback_only"
else
    junit_fail "no_fallback_check" "no se respeta fallback_only en clone loop"
fi

junit_finalize
