#!/bin/sh
# Validates ave-vpc.REQ-NET-21: setup paralelo de ubond en RPi.
# Test estático del 07b-setup-rpi-ubond.sh.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-21_setup_rpi_ubond"

ROOT="$(dirname "$0")/.."
SCRIPT="${ROOT}/07b-setup-rpi-ubond.sh"

[ -f "${SCRIPT}" ] || { junit_fail "missing" "07b-setup-rpi-ubond.sh no existe"; junit_finalize; }

# Check 1: ejecutable y bash -n OK
if [ -x "${SCRIPT}" ] && bash -n "${SCRIPT}" 2>/dev/null; then
    junit_pass "syntax_and_perms_ok"
else
    junit_fail "syntax_bad" "no ejecutable o sintaxis errónea"
    junit_finalize
fi

# Check 2: puertos UDP distintos a mlvpn (5083-5085 por defecto)
if grep -q 'UBOND_PORT_1.*5083' "${SCRIPT}" \
   && grep -q 'UBOND_PORT_2.*5084' "${SCRIPT}" \
   && grep -q 'UBOND_PORT_3.*5085' "${SCRIPT}"; then
    junit_pass "different_udp_ports_from_mlvpn"
else
    junit_fail "wrong_ports" "puertos no son 5083/5084/5085"
fi

# Check 3: solo aplica el patch de replicación (no los macOS)
if grep -q "ubond_replicate_filter.patch" "${SCRIPT}" \
   && ! grep -q "ubond_macos_compile.patch" "${SCRIPT}" \
   && ! grep -q "tuntap_darwin_utun_ubond.c" "${SCRIPT}"; then
    junit_pass "only_replicate_patch"
else
    junit_fail "wrong_patches" "aplica patches macOS (no aplican en Linux)"
fi

# Check 4: comparte secret con mlvpn
if grep -q "keys/mlvpn.secret" "${SCRIPT}"; then
    junit_pass "shares_mlvpn_secret"
else
    junit_fail "no_secret_share" "no usa keys/mlvpn.secret"
fi

# Check 5: SSH al RPi con el patrón conocido (heredoc + env vars)
if grep -q 'ssh -p "${RPi_SSH_PORT}"' "${SCRIPT}" \
   && grep -q 'UBOND_PATCH=' "${SCRIPT}"; then
    junit_pass "ssh_pattern_with_env"
else
    junit_fail "wrong_ssh_pattern" "no usa el patrón ssh+heredoc con env vars"
fi

# Check 6: instala libpcap-dev (requerido para [filter.replicate])
if grep -q "libpcap-dev" "${SCRIPT}"; then
    junit_pass "installs_libpcap"
else
    junit_fail "no_libpcap" "no instala libpcap-dev (necesario para filtros BPF)"
fi

# Check 7: ./configure --enable-filters
if grep -q -- "--enable-filters" "${SCRIPT}"; then
    junit_pass "enables_filters"
else
    junit_fail "no_filters" "configure sin --enable-filters"
fi

# Check 8: clona el repo correcto
if grep -q "markfoodyburton/ubond" "${SCRIPT}"; then
    junit_pass "clones_correct_repo"
else
    junit_fail "wrong_repo" "no clona markfoodyburton/ubond"
fi

# Check 9: idempotente — comprueba si ubond ya instalado
if grep -q "command -v ubond" "${SCRIPT}" \
   && grep -q "ya instalado" "${SCRIPT}"; then
    junit_pass "idempotent"
else
    junit_fail "not_idempotent" "no detecta ubond ya instalado"
fi

# Check 10: usuario sistema 'ubond' con home /var/lib/ubond
if grep -q "useradd --system" "${SCRIPT}" \
   && grep -q "/var/lib/ubond" "${SCRIPT}"; then
    junit_pass "creates_system_user"
else
    junit_fail "no_user" "no crea usuario sistema ubond"
fi

# Check 11: ufw abre los 3 puertos UDP de ubond
if grep -q "ufw allow.*UBOND_PORT_1" "${SCRIPT}" \
   && grep -q "ufw allow.*UBOND_PORT_2" "${SCRIPT}" \
   && grep -q "ufw allow.*UBOND_PORT_3" "${SCRIPT}"; then
    junit_pass "ufw_opens_3_ports"
else
    junit_fail "no_ufw" "no abre los 3 puertos UDP en ufw"
fi

# Check 12: systemd unit ubond.service paralela a mlvpn.service
if grep -q "ubond.service" "${SCRIPT}" \
   && grep -q "ExecStart=/usr/local/sbin/ubond" "${SCRIPT}" \
   && grep -q "systemctl enable ubond" "${SCRIPT}"; then
    junit_pass "creates_systemd_unit"
else
    junit_fail "no_unit" "no crea ubond.service o no la habilita"
fi

# Check 13: NO arranca automáticamente (decisión del usuario)
if grep -qE "NO.*arranc|systemctl start.*decisi" "${SCRIPT}"; then
    junit_pass "does_not_auto_start"
else
    junit_fail "auto_starts" "el servicio se arranca automáticamente"
fi

# Check 14: NO toca mlvpn ni mlvpn.service
if ! grep -qE "\\bsystemctl (stop|disable|restart) mlvpn\\b" "${SCRIPT}" \
   && ! grep -qE "\\brm[^#]+mlvpn" "${SCRIPT}"; then
    junit_pass "preserves_mlvpn"
else
    junit_fail "touches_mlvpn" "el script altera mlvpn"
fi

# Check 15: limpia /tmp/ubond-build tras compilar
if grep -q "rm -rf /tmp/ubond-build" "${SCRIPT}"; then
    junit_pass "cleans_build_dir"
else
    junit_fail "leaves_build" "no limpia /tmp/ubond-build"
fi

junit_finalize
