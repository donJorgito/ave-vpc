#!/bin/sh
# Validates ave-vpc.REQ-NET-12: design doc del filtro de replicación.
# Test estático: el doc tiene que cubrir los puntos clave del diseño
# para que la Fase 3 (implementación) pueda partir de él.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-12_design_doc"

DOC="$(dirname "$0")/../requirements/ave-vpc-REQ-NET-12-requirement.md"

[ -f "${DOC}" ] || { junit_fail "doc_missing" "REQ-NET-12 doc no existe"; junit_finalize; }

# Check 1: Marcado como design doc (Fase 2.2)
if grep -q "design doc.*Fase 2.2" "${DOC}"; then
    junit_pass "marked_as_design_doc"
else
    junit_fail "not_marked" "no está marcado como design doc Fase 2.2"
fi

# Check 2: Define la sintaxis del filtro en config
if grep -q '\[filter.replicate\]' "${DOC}" \
   && grep -qE 'udp.*port|udp.*dst' "${DOC}"; then
    junit_pass "config_syntax_defined"
else
    junit_fail "no_config_syntax" "no define [filter.replicate] con ejemplos"
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

junit_finalize
