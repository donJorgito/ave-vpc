#!/bin/sh
# Validates ave-vpc.REQ-NET-39: wrappers UDP-over-X (socat / udp2raw /
# wstunnel) para tunelar ubond a través del firewall del WiFi del AVE.
#
# Checks ESTÁTICOS (no arranca binarios, no toca red): los tres launchers
# existen, son ejecutables, exponen --check/--stop/--server-cmd, tienen
# lógica anti-doble-lanzamiento (idempotencia), no hardcodean IPs, pinean
# versión en el hint de --check, imprimen el comando server-side, y pasan
# bash -n.
#
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-39_udp_wrappers"

ROOT="$(dirname "$0")/.."
TOOLS="${ROOT}/tools"

SOCAT="${TOOLS}/wrap-socat.sh"
UDP2RAW="${TOOLS}/wrap-udp2raw.sh"
WSTUNNEL="${TOOLS}/wrap-wstunnel.sh"

# 1. Los tres scripts existen.
all_exist=1
for f in "${SOCAT}" "${UDP2RAW}" "${WSTUNNEL}"; do
    [ -f "${f}" ] || all_exist=0
done
if [ "${all_exist}" -eq 1 ]; then
    junit_pass "all_three_wrappers_exist"
else
    junit_fail "wrappers_missing" "falta alguno de wrap-socat/udp2raw/wstunnel.sh"
    junit_finalize
fi

# 2. Los tres son ejecutables.
all_exec=1
for f in "${SOCAT}" "${UDP2RAW}" "${WSTUNNEL}"; do
    [ -x "${f}" ] || all_exec=0
done
if [ "${all_exec}" -eq 1 ]; then
    junit_pass "all_three_executable"
else
    junit_fail "not_executable" "algún wrapper no tiene +x (chmod +x tools/wrap-*.sh)"
fi

# 3. Cada uno usa set -uo pipefail.
for f in "${SOCAT}" "${UDP2RAW}" "${WSTUNNEL}"; do
    name="$(basename "${f}")"
    if grep -q "set -uo pipefail" "${f}"; then
        junit_pass "set_pipefail_${name}"
    else
        junit_fail "set_pipefail_missing_${name}" "${name} no usa set -uo pipefail"
    fi
done

# 4. Cada uno tiene guard bash >= 4.
for f in "${SOCAT}" "${UDP2RAW}" "${WSTUNNEL}"; do
    name="$(basename "${f}")"
    if grep -q "BASH_VERSINFO" "${f}"; then
        junit_pass "bash4_guard_${name}"
    else
        junit_fail "bash4_guard_missing_${name}" "${name} sin guard bash>=4"
    fi
done

# 5. Cada uno expone --check, --stop y --server-cmd.
for f in "${SOCAT}" "${UDP2RAW}" "${WSTUNNEL}"; do
    name="$(basename "${f}")"
    if grep -q -- "--check" "${f}" \
       && grep -q -- "--stop" "${f}" \
       && grep -q -- "--server-cmd" "${f}"; then
        junit_pass "flags_present_${name}"
    else
        junit_fail "flags_missing_${name}" "${name} no expone --check/--stop/--server-cmd"
    fi
done

# 6. Idempotencia: lógica anti-doble-lanzamiento (PID file + kill -0).
for f in "${SOCAT}" "${UDP2RAW}" "${WSTUNNEL}"; do
    name="$(basename "${f}")"
    if grep -q "PID_FILE" "${f}" && grep -q "kill -0" "${f}" \
       && grep -qE "ya corriendo" "${f}"; then
        junit_pass "idempotent_double_launch_${name}"
    else
        junit_fail "idempotent_missing_${name}" \
            "${name} sin rechazo de doble lanzamiento (PID file + kill -0)"
    fi
done

# 7. logger -t para syslog (house style).
for f in "${SOCAT}" "${UDP2RAW}" "${WSTUNNEL}"; do
    name="$(basename "${f}")"
    if grep -q "logger -t" "${f}"; then
        junit_pass "logger_tag_${name}"
    else
        junit_fail "logger_missing_${name}" "${name} no usa logger -t"
    fi
done

# 8. Sin hardcoding de IP: deben leer VPS_IP/UBOND_PORT_3 de config/env,
#    no incrustar la IP DDNS ni 5085 literal como única fuente. Verifica
#    que aparece VPS_IP y que NO hay un IP-literal tipo a.b.c.d hardcodeado.
for f in "${SOCAT}" "${UDP2RAW}" "${WSTUNNEL}"; do
    name="$(basename "${f}")"
    uses_cfg=0
    grep -q "VPS_IP" "${f}" && grep -q "UBOND_PORT_3" "${f}" && uses_cfg=1
    # Ningún IPv4 literal "público" hardcodeado (127.0.0.1 y 0.0.0.0 son OK).
    # Se excluyen las líneas de versión pinneada (Rule 7): un SemVer de 4
    # componentes tipo socat 1.8.0.0 matchea el patrón IPv4 pero NO es una IP.
    hardcoded=0
    if grep -vE '_PINNED_VERSION|versión|version' "${f}" \
        | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
        | grep -vE '^(127\.0\.0\.1|0\.0\.0\.0)$' \
        | grep -q '.'; then
        hardcoded=1
    fi
    if [ "${uses_cfg}" -eq 1 ] && [ "${hardcoded}" -eq 0 ]; then
        junit_pass "no_hardcoded_ip_${name}"
    else
        junit_fail "hardcoded_or_no_config_${name}" \
            "${name} hardcodea IP o no consume VPS_IP/UBOND_PORT_3"
    fi
done

# 9. Versión PINNED en el hint de --check (Rule 7 IDLC). Cada script declara
#    una variable *_PINNED_VERSION.
for f in "${SOCAT}" "${UDP2RAW}" "${WSTUNNEL}"; do
    name="$(basename "${f}")"
    if grep -qE "PINNED_VERSION=" "${f}"; then
        junit_pass "pinned_version_${name}"
    else
        junit_fail "pinned_version_missing_${name}" \
            "${name} no declara una versión PINNED para el hint de instalación"
    fi
done

# 10. Imprime comando server-side a ejecutar en la RPi (print_server_cmd).
for f in "${SOCAT}" "${UDP2RAW}" "${WSTUNNEL}"; do
    name="$(basename "${f}")"
    if grep -q "print_server_cmd" "${f}" \
       && grep -qE "ejecutar en la RPi" "${f}"; then
        junit_pass "server_cmd_printed_${name}"
    else
        junit_fail "server_cmd_missing_${name}" \
            "${name} no imprime el comando server-side de la RPi"
    fi
done

# 11. NO debe hacer ssh (el script solo imprime el comando server-side).
for f in "${SOCAT}" "${UDP2RAW}" "${WSTUNNEL}"; do
    name="$(basename "${f}")"
    if grep -qE "^[[:space:]]*ssh " "${f}"; then
        junit_fail "does_ssh_${name}" "${name} ejecuta ssh — debe solo imprimir el comando"
    else
        junit_pass "no_ssh_${name}"
    fi
done

# 12. wrap-udp2raw exige root y faketcp; wrap-wstunnel soporta variante TLS.
if grep -q "faketcp" "${UDP2RAW}" \
   && grep -qE "EUID.*-ne 0|requiere root" "${UDP2RAW}"; then
    junit_pass "udp2raw_faketcp_and_root"
else
    junit_fail "udp2raw_faketcp_root_missing" \
        "wrap-udp2raw no usa faketcp o no exige root"
fi
if grep -qE "wss|WRAP_WS_TLS" "${WSTUNNEL}"; then
    junit_pass "wstunnel_tls_variant"
else
    junit_fail "wstunnel_tls_missing" "wrap-wstunnel no documenta variante TLS/WSS"
fi

# 13. Sintaxis bash válida en los tres (regression killer).
for f in "${SOCAT}" "${UDP2RAW}" "${WSTUNNEL}"; do
    name="$(basename "${f}")"
    if bash -n "${f}" 2>/dev/null; then
        junit_pass "bash_syntax_ok_${name}"
    else
        junit_fail "bash_syntax_fail_${name}" "${name} tiene errores de sintaxis bash"
    fi
done

junit_finalize
