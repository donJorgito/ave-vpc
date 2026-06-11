#!/bin/sh
# Validates ave-vpc.REQ-NET-45: banco de medida throughput/latencia/jitter/
# loss de ubond a través de cada wrapper (tools/bench-wrappers.sh).
#
# Checks ESTÁTICOS (no toca red, no mide, no requiere túnel): el script existe,
# es ejecutable, acepta etiqueta + --check/--show/--server-cmd, mide
# latencia/jitter/loss (ping) y throughput (iperf3 con fallback), acota toda
# medida con timeout (no se cuelga), localiza el utun por UBOND_TUN_MAC_IP,
# escribe TSV, imprime el comando RPi iperf3, no hace ssh, lee config/env, no
# hardcodea IPs, pinea versión y pasa bash -n.
#
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-45_bench"

ROOT="$(dirname "$0")/.."
TOOLS="${ROOT}/tools"
BENCH="${TOOLS}/bench-wrappers.sh"

# 1. El script existe.
if [ -f "${BENCH}" ]; then
    junit_pass "bench_exists"
else
    junit_fail "bench_missing" "falta tools/bench-wrappers.sh"
    junit_finalize
fi

# 2. Es ejecutable.
if [ -x "${BENCH}" ]; then
    junit_pass "bench_executable"
else
    junit_fail "bench_not_executable" "chmod +x tools/bench-wrappers.sh"
fi

# 3. set -uo pipefail.
if grep -q "set -uo pipefail" "${BENCH}"; then
    junit_pass "set_pipefail"
else
    junit_fail "set_pipefail_missing" "no usa set -uo pipefail"
fi

# 4. Guard bash >= 4.
if grep -q "BASH_VERSINFO" "${BENCH}"; then
    junit_pass "bash4_guard"
else
    junit_fail "bash4_guard_missing" "sin guard bash>=4"
fi

# 5. Expone --check, --show, --server-cmd y acepta una etiqueta posicional.
if grep -q -- "--check" "${BENCH}" \
   && grep -q -- "--show" "${BENCH}" \
   && grep -q -- "--server-cmd" "${BENCH}" \
   && grep -qE "do_bench" "${BENCH}"; then
    junit_pass "subcommands_and_label"
else
    junit_fail "subcommands_missing" "no expone --check/--show/--server-cmd o no acepta etiqueta"
fi

# 6. Mide latencia/jitter/loss: ping forzado por el utun + parseo min/avg/max/stddev.
if grep -qE "ping .*-b" "${BENCH}" \
   && grep -qE "min/avg/max" "${BENCH}" \
   && grep -qiE "loss" "${BENCH}"; then
    junit_pass "measures_latency_jitter_loss"
else
    junit_fail "latency_missing" "no mide latencia/jitter/loss por la utun"
fi

# 7. Mide throughput con iperf3 y tiene fallback de transferencia.
if grep -q "iperf3" "${BENCH}" && grep -qiE "fallback" "${BENCH}"; then
    junit_pass "measures_throughput_with_fallback"
else
    junit_fail "throughput_missing" "no mide throughput con iperf3 + fallback"
fi

# 8. Toda medida acotada con timeout (no se cuelga).
if grep -qE "run_bounded" "${BENCH}" \
   && grep -qE "timeout|gtimeout" "${BENCH}"; then
    junit_pass "measurements_bounded_timeout"
else
    junit_fail "no_timeout" "las medidas no están acotadas con timeout — puede colgarse"
fi

# 9. Localiza el utun de ubond por UBOND_TUN_MAC_IP (no ping global).
if grep -qE "UBOND_TUN_MAC_IP" "${BENCH}" \
   && grep -qE "utun" "${BENCH}"; then
    junit_pass "utun_located_by_tun_ip"
else
    junit_fail "utun_location_missing" "no localiza el utun por UBOND_TUN_MAC_IP"
fi

# 10. Escribe una fila comparable en generated/bench-results.tsv.
if grep -qE "bench-results.tsv" "${BENCH}" \
   && grep -qE "ensure_header|RESULTS_TSV" "${BENCH}"; then
    junit_pass "appends_tsv_row"
else
    junit_fail "tsv_missing" "no añade fila a generated/bench-results.tsv"
fi

# 11. Imprime el comando server-side iperf3 (RPi) y NO hace ssh.
if grep -q "print_server_cmd" "${BENCH}" \
   && grep -qE "iperf3 -s" "${BENCH}" \
   && grep -qE "ejecutar en la RPi" "${BENCH}"; then
    junit_pass "server_cmd_printed"
else
    junit_fail "server_cmd_missing" "no imprime el comando iperf3 -s de la RPi"
fi
if grep -qE "^[[:space:]]*ssh " "${BENCH}"; then
    junit_fail "does_ssh" "bench ejecuta ssh — debe solo imprimir el comando"
else
    junit_pass "no_ssh"
fi

# 12. Lee config/env (UBOND_TUN_VPS_IP/UBOND_TUN_MAC_IP) y no hardcodea IPs
#     públicas. Las IPs default tipo 10.10.20.x son fallbacks de config/env,
#     pero no debe haber IPs públicas DDNS literales fuera de eso. Se permiten
#     127.0.0.1, 0.0.0.0 y la subnet de túnel 10.10.20.x (fallback de var).
uses_cfg=0
grep -q "UBOND_TUN_VPS_IP" "${BENCH}" \
    && grep -q "UBOND_TUN_MAC_IP" "${BENCH}" \
    && grep -q "config/env" "${BENCH}" && uses_cfg=1
hardcoded=0
if grep -vE '_PINNED_VERSION|versión|version' "${BENCH}" \
    | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
    | grep -vE '^(127\.0\.0\.1|0\.0\.0\.0|10\.10\.20\.[0-9]+)$' \
    | grep -q '.'; then
    hardcoded=1
fi
if [ "${uses_cfg}" -eq 1 ] && [ "${hardcoded}" -eq 0 ]; then
    junit_pass "config_env_no_hardcode"
else
    junit_fail "config_env_or_hardcode" \
        "no lee UBOND_TUN_*_IP de config/env o hardcodea una IP pública"
fi

# 13. Versión PINNED de iperf3 (Rule 7 IDLC).
if grep -qE "IPERF3_PINNED_VERSION=" "${BENCH}"; then
    junit_pass "pinned_version"
else
    junit_fail "pinned_version_missing" "no declara IPERF3_PINNED_VERSION"
fi

# 14. logger -t bench-wrappers (house style).
if grep -q "logger -t bench-wrappers" "${BENCH}"; then
    junit_pass "logger_tag"
else
    junit_fail "logger_missing" "no usa logger -t bench-wrappers"
fi

# 15. Sintaxis bash válida.
if bash -n "${BENCH}" 2>/dev/null; then
    junit_pass "bash_syntax_ok"
else
    junit_fail "bash_syntax_fail" "tools/bench-wrappers.sh tiene errores de sintaxis bash"
fi

junit_finalize
