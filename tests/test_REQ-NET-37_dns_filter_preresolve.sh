#!/bin/sh
# Validates ave-vpc.REQ-NET-37: pre-resolución DNS de hosts en
# [filters.replicate] antes de lanzar ubond.
#
# Bug detrás del REQ: pcap_compile("tcp and dst port 443 and host
# api.anthropic.com") invoca pcap_nametoaddr → getaddrinfo. Si DNS
# falla al startup (AVE WiFi pre-captive típico), el filtro se
# descarta silenciosamente sin reintento — replicación efectivamente
# off para esa entrada el resto de la sesión.
#
# Fix Opción C: 04b-conectar-ubond.sh resuelve cada `host <fqdn>`
# antes de lanzar ubond y sustituye por `host <ip>` literal en
# ubond_active.conf. Si todos los resolvers fallan, comenta la línea
# con prefijo de auditoría — el resto de filtros siguen activos.
#
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-37_dns_filter_preresolve"

ROOT="$(dirname "$0")/.."
SCRIPT_04B="${ROOT}/04b-conectar-ubond.sh"

# 1. Script existe.
if [ -f "${SCRIPT_04B}" ]; then
    junit_pass "script_04b_exists"
else
    junit_fail "script_04b_missing" "04b-conectar-ubond.sh no existe"
    junit_finalize
fi

# 2. Sección "Pre-resolución filter hosts" presente como Paso 3.7.
if grep -qE "Paso 3\.7.*Pre-resoluci.*filter host" "${SCRIPT_04B}"; then
    junit_pass "step_3_7_section_present"
else
    junit_fail "step_3_7_section_missing" \
        "04b no tiene sección 'Paso 3.7: Pre-resolución filter hosts'"
fi

# 3. La sección referencia REQ-NET-37 (traceability).
if grep -q "REQ-NET-37" "${SCRIPT_04B}"; then
    junit_pass "req_net_37_referenced"
else
    junit_fail "req_net_37_not_referenced" \
        "04b no referencia REQ-NET-37 (traceability lost)"
fi

# 4. Usa FALLBACK_DNS_RESOLVERS para fallback (no hardcoding).
# La función resolve_filter_host debe leer la variable; si alguien
# hardcodease 1.1.1.1 dentro del helper, el test falla.
if grep -qE 'resolve_filter_host\(\)' "${SCRIPT_04B}" \
   && awk '/resolve_filter_host\(\)/,/^}/' "${SCRIPT_04B}" \
        | grep -q "FALLBACK_DNS_RESOLVERS"; then
    junit_pass "fallback_dns_resolvers_used"
else
    junit_fail "fallback_dns_resolvers_missing" \
        "resolve_filter_host no usa FALLBACK_DNS_RESOLVERS (hardcoding o ausencia)"
fi

# 5. Sustitución `host <fqdn>` -> `host <ip>` via sed in-place sobre
# ubond_active.conf.
if grep -qE "sed.*host \\\$\{fqdn\}.*host \\\$\{FILTER_IP\}" "${SCRIPT_04B}" \
   || grep -qE "sed.*'s\|host .*\|host .*\|" "${SCRIPT_04B}" \
   || grep -qE 's/host \$\{fqdn\}/host \$\{FILTER_IP\}/' "${SCRIPT_04B}"; then
    junit_pass "host_fqdn_substitution_present"
else
    # Heurística más laxa: que aparezca tanto `host ${fqdn}` como
    # `host ${FILTER_IP}` en el script (en cualquier sed).
    if grep -q 'host ${fqdn}' "${SCRIPT_04B}" \
       && grep -q 'host ${FILTER_IP}' "${SCRIPT_04B}"; then
        junit_pass "host_fqdn_substitution_present"
    else
        junit_fail "host_fqdn_substitution_missing" \
            "04b no sustituye 'host <fqdn>' por 'host <ip>' en ubond_active.conf"
    fi
fi

# 6. Si el FQDN no resuelve por NINGÚN resolver, la línea se comenta.
# Look-for: prefijo de auditoría 'REQ-NET-37 dns-fail:' en el sed.
if grep -q "REQ-NET-37 dns-fail" "${SCRIPT_04B}"; then
    junit_pass "dns_fail_comment_present"
else
    junit_fail "dns_fail_comment_missing" \
        "04b no comenta la línea con marker 'REQ-NET-37 dns-fail' cuando todos los resolvers fallan"
fi

# 7. Modifica ubond_active.conf (NO ubond.conf template — REQ-NET-37
# no toca el template, solo el runtime).
# La sustitución debe apuntar a ubond_active.conf.
if awk '/Paso 3\.7/,/Paso 4/' "${SCRIPT_04B}" \
        | grep -q 'ubond_active\.conf'; then
    junit_pass "targets_runtime_conf_only"
else
    junit_fail "targets_runtime_conf_missing" \
        "Paso 3.7 no toca ubond_active.conf (debería ser el único target)"
fi
# Y NO debe modificar el template ubond.conf en el bloque del Paso 3.7.
if awk '/Paso 3\.7/,/Paso 4/' "${SCRIPT_04B}" \
        | grep -E 'sed.*ubond\.conf"' \
        | grep -v 'ubond_active\.conf' \
        | grep -q '.'; then
    junit_fail "modifies_template_unsafely" \
        "Paso 3.7 modifica el template ubond.conf — solo debe tocar ubond_active.conf"
else
    junit_pass "template_ubond_conf_untouched"
fi

# 8. Extracción de fqdns con regex BPF `host <fqdn>` (no IPs).
# Verifica que hay un grep/awk/regex que captura `host <fqdn>`.
if grep -qE 'host \[a-zA-Z\]\[a-zA-Z0-9\.-\]\*' "${SCRIPT_04B}"; then
    junit_pass "fqdn_extraction_regex_present"
else
    junit_fail "fqdn_extraction_regex_missing" \
        "04b no extrae fqdns con regex 'host <fqdn>' del conf"
fi

# 9. Sintaxis bash válida (regression killer si alguien rompe el script).
if bash -n "${SCRIPT_04B}" 2>/dev/null; then
    junit_pass "bash_syntax_ok"
else
    junit_fail "bash_syntax_fail" "04b-conectar-ubond.sh tiene errores de sintaxis bash"
fi

junit_finalize
