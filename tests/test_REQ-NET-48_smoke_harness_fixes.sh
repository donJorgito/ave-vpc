#!/bin/sh
# Validates ave-vpc.REQ-NET-48: corrige tres defectos del arnés de smoke-tests
# (wait_auth con patrón de título erróneo, stop que no mata, diagnóstico con
# falso positivo). Offline: sin red ni sudo. Se carga la lib real bajo bash y
# se sustituyen pgrep/pkill/ifconfig/tcpdump/sleep por stubs en el PATH.
#
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-48_smoke_harness_fixes"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="${ROOT}/tools/lib/ubond-runner.sh"
REPORT="${ROOT}/tools/lib/report.sh"

if ! command -v bash >/dev/null 2>&1; then
    junit_skip "all" "bash no disponible"
    junit_finalize
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
BIN="${WORK}/bin"
mkdir -p "${BIN}"

# pgrep -f PAT: casa contra los títulos falsos de $FAKE_TITLES (ERE, como pgrep).
cat > "${BIN}/pgrep" <<'STUB'
#!/bin/sh
[ -s "${FAKE_TITLES}" ] && grep -qE -- "$2" "${FAKE_TITLES}"
STUB
# pkill: registra el patrón; solo "mata" (vacía los títulos) si casa Y KILL_WORKS=1.
cat > "${BIN}/pkill" <<'STUB'
#!/bin/sh
pat=""
for a in "$@"; do pat="$a"; done
echo "${pat}" >> "${PKILL_LOG}"
if [ "${KILL_WORKS:-1}" = 1 ] && [ -s "${FAKE_TITLES}" ] && grep -qE -- "${pat}" "${FAKE_TITLES}"; then
    : > "${FAKE_TITLES}"
fi
exit 0
STUB
printf '#!/bin/sh\nexit 0\n' > "${BIN}/ifconfig"
printf '#!/bin/sh\nexit 0\n' > "${BIN}/sleep"
# tcpdump -nn -r FILE: una línea por paquete (líneas del fichero salvo HDR).
cat > "${BIN}/tcpdump" <<'STUB'
#!/bin/sh
grep -v '^HDR$' "$3" || true
STUB
chmod +x "${BIN}"/*

export FAKE_TITLES="${WORK}/titles" PKILL_LOG="${WORK}/pkill.log"
REAL_TITLE='ubond: ubond0 !links.wifi @links.pixel @links.iphone'

# Ejecuta un snippet bash con la lib del runner cargada.
run_runner() {
    PATH="${BIN}:${PATH}" AVEVPC_ROOT="${ROOT}" SMOKE_TMPDIR="${WORK}" \
    UBOND_TUN_MAC_IP=10.10.20.2 bash -c '
        log_info() { echo "INFO $*"; }; log_warn() { echo "WARN $*"; }
        log_err() { echo "ERROR $*"; }
        source "'"${RUNNER}"'"
        '"$1"
}

# 1. El patrón de wait_auth casa con un título real y el antiguo no.
echo "${REAL_TITLE}" > "${FAKE_TITLES}"
new_re="$(run_runner 'ubond_runner_auth_title_re')"
if echo "${REAL_TITLE}" | grep -qE -- "${new_re}" \
   && ! echo "${REAL_TITLE}" | grep -qE 'ubond: ubond @links\.'; then
    junit_pass "auth_pattern_matches_real_title"
else
    junit_fail "auth_pattern_wrong" "patrón '${new_re}' no casa con el título real"
fi

# 2. El patrón deriva de UBOND_CLIENT_NAME (no está fijado a ubond0).
alt_re="$(UBOND_CLIENT_NAME=otro run_runner 'ubond_runner_auth_title_re')"
if echo 'ubond: otro @links.x' | grep -qE -- "${alt_re}" \
   && ! echo "${REAL_TITLE}" | grep -qE -- "${alt_re}" \
   && grep -q -- '--name "${UBOND_CLIENT_NAME}"' "${RUNNER}"; then
    junit_pass "pattern_derived_from_client_name"
else
    junit_fail "pattern_hardcoded" "el nombre del cliente debe salir de UBOND_CLIENT_NAME"
fi

# 3. wait_auth devuelve 0 con el título real y 1 sin auth (links solo '!').
echo "${REAL_TITLE}" > "${FAKE_TITLES}"
if run_runner 'ubond_runner_wait_auth 2' >/dev/null; then
    junit_pass "wait_auth_succeeds_with_real_title"
else
    junit_fail "wait_auth_timeout" "no detectó el título real"
fi
echo 'ubond: ubond0 !links.wifi !links.pixel' > "${FAKE_TITLES}"
if run_runner 'ubond_runner_wait_auth 2' >/dev/null 2>&1; then
    junit_fail "wait_auth_false_positive" "dio auth sin ningún @links"
else
    junit_pass "wait_auth_times_out_without_auth"
fi

# 4. stop mata por título "ubond: " y solo declara "detenido" si no queda nada.
echo "${REAL_TITLE}" > "${FAKE_TITLES}"; : > "${PKILL_LOG}"
out="$(KILL_WORKS=1 run_runner 'ubond_runner_stop; echo "rc=$?"')"
if echo "${out}" | grep -q 'detenido' && echo "${out}" | grep -q 'rc=0' \
   && grep -qxF '^ubond: ubond0 ' "${PKILL_LOG}" && ! grep -q 'usr/local' "${PKILL_LOG}"; then
    junit_pass "stop_kills_by_title"
else
    junit_fail "stop_wrong_pattern" "salida: ${out}; pkill: $(tr '\n' '|' < "${PKILL_LOG}")"
fi

# 4b. El patrón de kill está anclado: un proceso ajeno con la cadena en sus
#     argumentos (decoy) no casa; los títulos reales ([priv] y autenticado) sí.
kill_re="$(run_runner 'printf "%s" "${UBOND_TITLE_RE}"')"
DECOY='tail -f /dev/null ubond: ubond0 @links.q'
if echo 'ubond: ubond0 [priv]' | grep -qE -- "${kill_re}" \
   && echo "${REAL_TITLE}" | grep -qE -- "${kill_re}" \
   && ! echo "${DECOY}" | grep -qE -- "${kill_re}" \
   && echo "${DECOY}" | grep -qE 'ubond: '; then
    junit_pass "kill_pattern_anchored_vs_decoy"
else
    junit_fail "kill_pattern_not_anchored" "patrón '${kill_re}' casa el decoy o no casa un título real"
fi

# 4c. stop NO mata ni se queda bloqueado por un proceso ajeno (decoy): rc=0.
echo "${DECOY}" > "${FAKE_TITLES}"
out="$(KILL_WORKS=0 run_runner 'ubond_runner_stop; echo "rc=$?"')"
if echo "${out}" | grep -q 'rc=0' && echo "${out}" | grep -q 'ubond detenido'; then
    junit_pass "stop_ignores_decoy"
else
    junit_fail "stop_false_survivor" "salida: ${out}"
fi

# 4d. cleanup_stale mata por título (no por ruta del binario) y solo si hay cliente.
echo "${REAL_TITLE}" > "${FAKE_TITLES}"; : > "${PKILL_LOG}"
out="$(KILL_WORKS=1 UBOND_BIN=/usr/local/sbin/ubond run_runner 'ubond_runner_cleanup_stale; echo "rc=$?"')"
if echo "${out}" | grep -q 'rc=0' && echo "${out}" | grep -q 'previos' \
   && grep -qxF '^ubond: ubond0 ' "${PKILL_LOG}" && ! grep -q 'usr/local' "${PKILL_LOG}" \
   && ! [ -s "${FAKE_TITLES}" ]; then
    junit_pass "cleanup_stale_kills_by_title"
else
    junit_fail "cleanup_stale_wrong_pattern" "salida: ${out}; pkill: $(tr '\n' '|' < "${PKILL_LOG}")"
fi
: > "${PKILL_LOG}"; : > "${FAKE_TITLES}"
run_runner 'ubond_runner_cleanup_stale' >/dev/null 2>&1
if [ ! -s "${PKILL_LOG}" ]; then
    junit_pass "cleanup_stale_noop_without_clients"
else
    junit_fail "cleanup_stale_kills_nothing_alive" "pkill invocado sin clientes"
fi

# 5. Si el cliente sobrevive: error, rc=1 y sin "detenido".
echo "${REAL_TITLE}" > "${FAKE_TITLES}"
out="$(KILL_WORKS=0 run_runner 'ubond_runner_stop; echo "rc=$?"')"
if echo "${out}" | grep -q 'ERROR' && echo "${out}" | grep -q 'rc=1' \
   && ! echo "${out}" | grep -q 'ubond detenido'; then
    junit_pass "stop_reports_survivor"
else
    junit_fail "stop_hides_survivor" "salida: ${out}"
fi

# 6. Diagnóstico: sin pcap RPi => "no verificable"; con pcap RPi de 0 pkts => filtrado.
run_diag() {
    PATH="${BIN}:${PATH}" AVEVPC_ROOT="${ROOT}" SMOKE_TMPDIR="${WORK}/cap" \
    TESTS_PING_RECEIVED=0 TESTS_PING_TOTAL=5 bash -c '
        source "'"${REPORT}"'"; report_diagnose'
}
mkdir -p "${WORK}/cap"
printf 'HDR\np1\np2\n' > "${WORK}/cap/cap_mac_en0.pcap"
out="$(run_diag)"
if echo "${out}" | grep -q 'no verificable' && ! echo "${out}" | grep -q 'Mac envía pero RPi no recibe'; then
    junit_pass "missing_rpi_capture_is_unverifiable"
else
    junit_fail "missing_capture_false_positive" "salida: ${out}"
fi

: > "${WORK}/cap/cap_rpi_eth.pcap"   # 0 bytes: scp truncado, tampoco es "0 pkts"
out="$(run_diag)"
if echo "${out}" | grep -q 'no verificable'; then
    junit_pass "empty_rpi_file_is_unverifiable"
else
    junit_fail "empty_file_false_positive" "salida: ${out}"
fi

printf 'HDR\n' > "${WORK}/cap/cap_rpi_eth.pcap"   # captura válida sin paquetes
out="$(run_diag)"
if echo "${out}" | grep -q 'Mac envía pero RPi no recibe'; then
    junit_pass "real_zero_packets_still_reports_filtering"
else
    junit_fail "real_zero_lost" "salida: ${out}"
fi

junit_finalize
