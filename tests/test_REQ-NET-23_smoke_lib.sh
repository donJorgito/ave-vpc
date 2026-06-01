#!/bin/sh
# Validates ave-vpc.REQ-NET-23: smoke-test adaptativo ubond.
# Test estático: archivos existen, syntax OK, funciones clave presentes,
# orchestrators piden root.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-23_smoke_lib"

ROOT="$(dirname "$0")/.."
LIB_DIR="${ROOT}/tools/lib"

# 1. Las 7 libs y los 3 orchestrators existen.
all_present=1
for f in _common.sh env-detect.sh conf-gen.sh tcpdump.sh ubond-runner.sh tests.sh report.sh; do
    [ -r "${LIB_DIR}/${f}" ] || { all_present=0; break; }
done
for f in smoke-casa.sh smoke-cafe.sh smoke-ave.sh; do
    [ -x "${ROOT}/tools/${f}" ] || { all_present=0; break; }
done
if [ "${all_present}" = 1 ]; then
    junit_pass "files_present"
else
    junit_fail "files_missing" "alguna lib u orchestrator no existe"
    junit_finalize
fi

# 2. bash -n OK en todos.
syntax_ok=1
for f in "${LIB_DIR}"/*.sh "${ROOT}"/tools/smoke-*.sh; do
    bash -n "${f}" 2>/dev/null || { syntax_ok=0; break; }
done
if [ "${syntax_ok}" = 1 ]; then
    junit_pass "syntax_ok"
else
    junit_fail "syntax_fail" "alguna lib u orchestrator falla bash -n"
fi

# 3. Cada lib expone sus funciones clave.
check_funcs() {
    file="$1"; shift
    for fn in "$@"; do
        grep -qE "^${fn}\(\)" "${LIB_DIR}/${file}" || return 1
    done
}

if check_funcs "_common.sh" log_info log_warn log_err die require_cmd require_file require_root as_invoker; then
    junit_pass "common_funcs"
else
    junit_fail "common_funcs" "_common.sh no expone alguna función esperada"
fi

if check_funcs "env-detect.sh" env_detect_load_config env_detect_iface_ip env_detect_all env_detect_summary env_detect_eligible_links; then
    junit_pass "env_detect_funcs"
else
    junit_fail "env_detect_funcs" "env-detect.sh no expone alguna función esperada"
fi

if check_funcs "conf-gen.sh" conf_gen_write conf_gen_path; then
    junit_pass "conf_gen_funcs"
else
    junit_fail "conf_gen_funcs" "conf-gen.sh no expone alguna función esperada"
fi

if check_funcs "tcpdump.sh" tcpdump_start_mac tcpdump_start_rpi tcpdump_stop_all tcpdump_pcap_count; then
    junit_pass "tcpdump_funcs"
else
    junit_fail "tcpdump_funcs" "tcpdump.sh no expone alguna función esperada"
fi

if check_funcs "ubond-runner.sh" ubond_runner_cleanup_stale ubond_runner_start_with_conf ubond_runner_wait_auth ubond_runner_find_utun_iface ubond_runner_stop; then
    junit_pass "ubond_runner_funcs"
else
    junit_fail "ubond_runner_funcs" "ubond-runner.sh no expone alguna función esperada"
fi

if check_funcs "tests.sh" run_ping_test run_curl_tunnel run_throughput run_nc_udp_probe; then
    junit_pass "tests_funcs"
else
    junit_fail "tests_funcs" "tests.sh no expone alguna función esperada"
fi

if check_funcs "report.sh" report_render_markdown report_diagnose; then
    junit_pass "report_funcs"
else
    junit_fail "report_funcs" "report.sh no expone alguna función esperada"
fi

# 4. Orchestrators piden root (require_root).
all_root_check=1
for f in smoke-casa.sh smoke-cafe.sh smoke-ave.sh; do
    grep -q 'require_root' "${ROOT}/tools/${f}" || { all_root_check=0; break; }
done
if [ "${all_root_check}" = 1 ]; then
    junit_pass "orchestrators_require_root"
else
    junit_fail "no_root_check" "algún orchestrator no llama require_root"
fi

# 5. Orchestrators tienen trap cleanup.
all_trap=1
for f in smoke-casa.sh smoke-cafe.sh smoke-ave.sh; do
    grep -qE 'trap.*cleanup.*EXIT' "${ROOT}/tools/${f}" || { all_trap=0; break; }
done
if [ "${all_trap}" = 1 ]; then
    junit_pass "orchestrators_have_trap"
else
    junit_fail "no_trap" "algún orchestrator no instala trap cleanup"
fi

# 6. _common.sh NO ejecuta nada al ser sourceado (solo define).
# Heurística: no debe tener llamadas a funciones top-level fuera de
# definiciones — pero la línea `mkdir -p ${SMOKE_TMPDIR}` sí es necesaria
# como bootstrap. Verificamos que NO tenga `set -e` (le rompería sourcing
# en scripts que ya tengan `set +e`).
if ! grep -qE '^set -[a-z]*e' "${LIB_DIR}/_common.sh"; then
    junit_pass "common_no_set_e"
else
    junit_fail "set_e_in_common" "_common.sh tiene 'set -e' que rompería sourcing"
fi

junit_finalize
