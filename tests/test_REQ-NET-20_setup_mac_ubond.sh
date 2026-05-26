#!/bin/sh
# Validates ave-vpc.REQ-NET-20: setup paralelo de ubond en macOS.
# Test estático del 03b-setup-mac-ubond.sh — verifica estructura,
# orden de pasos y coexistencia con mlvpn.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-20_setup_mac_ubond"

ROOT="$(dirname "$0")/.."
SCRIPT="${ROOT}/03b-setup-mac-ubond.sh"

[ -f "${SCRIPT}" ] || { junit_fail "script_missing" "03b-setup-mac-ubond.sh no existe"; junit_finalize; }

# Check 1: ejecutable y pasa bash -n
if [ -x "${SCRIPT}" ] && bash -n "${SCRIPT}" 2>/dev/null; then
    junit_pass "executable_and_syntax_ok"
else
    junit_fail "syntax_or_perms" "no ejecutable o sintaxis errónea"
    junit_finalize
fi

# Check 2: NO ejecuta como root (igual que 03-setup-mac.sh)
if grep -q '"\${EUID}" -eq 0' "${SCRIPT}" \
   && grep -q "No ejecutes este script con sudo" "${SCRIPT}"; then
    junit_pass "rejects_root_execution"
else
    junit_fail "no_root_check" "no rechaza ejecución como root"
fi

# Check 3: verifica los 3 patches presentes antes de compilar
if grep -q "ubond_macos_compile.patch" "${SCRIPT}" \
   && grep -q "tuntap_darwin_utun_ubond.c" "${SCRIPT}" \
   && grep -q "ubond_replicate_filter.patch" "${SCRIPT}"; then
    junit_pass "checks_all_3_patches"
else
    junit_fail "missing_patch_check" "no verifica los 3 patches esperados"
fi

# Check 4: comprueba bash 4+ (los watchers lo necesitan)
if grep -q "BASH_VERSINFO" "${SCRIPT}" \
   && grep -q "brew install bash" "${SCRIPT}"; then
    junit_pass "ensures_bash_4_plus"
else
    junit_fail "no_bash_check" "no asegura bash 4+ disponible"
fi

# Check 5: instala las 4 deps clave (libev, libsodium, libpcap, autotools)
if grep -q "libev libsodium libpcap" "${SCRIPT}"; then
    junit_pass "installs_required_libs"
else
    junit_fail "missing_libs" "no instala todas las libs (libev, libsodium, libpcap)"
fi

# Check 6: clona el repo correcto de ubond
if grep -q "markfoodyburton/ubond" "${SCRIPT}"; then
    junit_pass "clones_correct_repo"
else
    junit_fail "wrong_repo" "no clona markfoodyburton/ubond"
fi

# Check 7: idempotente — salta compilación si ubond ya instalado
if grep -q '/usr/local/sbin/ubond' "${SCRIPT}" \
   && grep -q "ya está instalado" "${SCRIPT}"; then
    junit_pass "idempotent"
else
    junit_fail "not_idempotent" "no detecta ubond ya instalado"
fi

# Check 8: aplica los 3 patches en orden correcto
if grep -B1 "ubond_replicate_filter.patch" "${SCRIPT}" \
   | grep -q "tuntap_darwin_utun_ubond.c\|ubond_macos_compile.patch"; then
    junit_pass "patches_applied_in_order"
else
    junit_fail "wrong_order" "los patches no se aplican en el orden esperado"
fi

# Check 9: configure con --enable-filters
if grep -q -- "--enable-filters" "${SCRIPT}"; then
    junit_pass "enables_filters"
else
    junit_fail "no_filters" "configure sin --enable-filters (REQ-NET-12 no funcionaría)"
fi

# Check 10: usuario de sistema 'ubond' (paralelo a mlvpn) con UID libre desde 501
if grep -q "id ubond" "${SCRIPT}" \
   && grep -q "NEW_UID=501" "${SCRIPT}" \
   && grep -q "dscl . -create /Users/ubond" "${SCRIPT}"; then
    junit_pass "creates_ubond_user"
else
    junit_fail "no_ubond_user" "no crea usuario sistema 'ubond' separado"
fi

# Check 11: NO toca mlvpn ni su config (coexisten).
# Buscamos comandos destructivos contra mlvpn — \brm\b para no
# matchear "fo*rm*ato" en comentarios. Lo mismo para uninstall.
if ! grep -qE "\\brm\\b[^#]*mlvpn|sudo[^#]*rm[^#]*mlvpn" "${SCRIPT}" \
   && ! grep -qE "\\buninstall\\b[^#]*mlvpn" "${SCRIPT}" \
   && ! grep -qE "dscl\\..*delete.*mlvpn|sudo dscl[^#]*-delete.*mlvpn" "${SCRIPT}"; then
    junit_pass "preserves_mlvpn"
else
    junit_fail "touches_mlvpn" "el script elimina/desinstala mlvpn"
fi

# Check 12: genera generated/ubond.conf con [filter.replicate] de ejemplo
if grep -q "ubond.conf" "${SCRIPT}" \
   && grep -q "\[filter.replicate\]" "${SCRIPT}" \
   && grep -qE "zoom_rtp|meet_stun|rtp_generic" "${SCRIPT}"; then
    junit_pass "generates_config_with_replicate_examples"
else
    junit_fail "no_config_template" "no genera ubond.conf con ejemplos [filter.replicate]"
fi

# Check 13: copia mlvpn_updown_mac.sh → ubond_updown_mac.sh
if grep -q "mlvpn_updown_mac.sh" "${SCRIPT}" \
   && grep -q "ubond_updown_mac.sh" "${SCRIPT}"; then
    junit_pass "reuses_updown_script"
else
    junit_fail "no_updown_reuse" "no reusa el updown script de mlvpn"
fi

# Check 14: usa secret compartido (keys/mlvpn.secret) — un único secret
# para ambos lados del túnel ubond debe coincidir con el de mlvpn
if grep -q "keys/mlvpn.secret\|mlvpn.secret" "${SCRIPT}"; then
    junit_pass "shares_secret_with_mlvpn"
else
    junit_fail "no_shared_secret" "no comparte secret con mlvpn"
fi

junit_finalize
