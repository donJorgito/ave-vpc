#!/bin/sh
# Validates ave-vpc.REQ-NET-35: rebind socket UDP en silencio inbound (fix C).
# Static checks sobre patches/ubond_rebind_on_silence.patch + wire en
# scripts setup. No requiere ubond corriendo ni root, debe pasar siempre
# en CI antes de la rebuild RPi+Mac.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-35_rebind_on_silence"

ROOT="$(dirname "$0")/.."
PATCH="${ROOT}/patches/ubond_rebind_on_silence.patch"
SCRIPT_03B="${ROOT}/03b-setup-mac-ubond.sh"
SCRIPT_07B="${ROOT}/07b-setup-rpi-ubond.sh"

# 1. Patch existe y tiene tamano > 0.
if [ -f "${PATCH}" ] && [ -s "${PATCH}" ]; then
    junit_pass "patch_exists_nonempty"
else
    junit_fail "patch_missing" "patches/ubond_rebind_on_silence.patch no existe o esta vacio"
    junit_finalize
fi

# 2. Patch contiene literal `reauth_attempts_no_inbound` (struct field).
if grep -q "reauth_attempts_no_inbound" "${PATCH}"; then
    junit_pass "field_reauth_attempts_present"
else
    junit_fail "field_reauth_attempts_missing" \
        "patch no introduce el campo reauth_attempts_no_inbound"
fi

# 3. Patch contiene literal `ubond_rtun_rebind_socket` (nueva funcion).
if grep -q "ubond_rtun_rebind_socket" "${PATCH}"; then
    junit_pass "function_rebind_socket_present"
else
    junit_fail "function_rebind_socket_missing" \
        "patch no introduce la funcion ubond_rtun_rebind_socket"
fi

# 4. Patch contiene `ev_io_stop` + `close` + `freeaddrinfo` (cuerpo del rebind).
HAS_EV_STOP=0
HAS_CLOSE=0
HAS_FREEADDR=0
grep -q "ev_io_stop" "${PATCH}" && HAS_EV_STOP=1
grep -q "close(t->fd)" "${PATCH}" && HAS_CLOSE=1
grep -q "freeaddrinfo" "${PATCH}" && HAS_FREEADDR=1
if [ "${HAS_EV_STOP}" = "1" ] && [ "${HAS_CLOSE}" = "1" ] && [ "${HAS_FREEADDR}" = "1" ]; then
    junit_pass "rebind_body_complete"
else
    junit_fail "rebind_body_incomplete" \
        "patch sin alguna de: ev_io_stop, close(t->fd), freeaddrinfo (ev_stop=${HAS_EV_STOP} close=${HAS_CLOSE} freeaddr=${HAS_FREEADDR})"
fi

# 5. Patch contiene gating server_mode (no rebindar el listener del servidor).
if grep -q "!t->server_mode" "${PATCH}"; then
    junit_pass "server_mode_gating_present"
else
    junit_fail "server_mode_gating_missing" \
        "patch sin gate '!t->server_mode' - riesgo: server intentaria rebindar su listener UDP"
fi

# 6. Patch contiene `UBOND_REBIND_THRESHOLD` (constante de gating).
if grep -q "UBOND_REBIND_THRESHOLD" "${PATCH}"; then
    junit_pass "threshold_constant_present"
else
    junit_fail "threshold_constant_missing" \
        "patch sin UBOND_REBIND_THRESHOLD - no hay umbral de rebind"
fi

# 7. Si build/ubond/src/ubond.c existe post-build: contiene
# `reauth_attempts_no_inbound` (regression killer: si alguien rebuilda
# desde scratch sin aplicar el patch, este check lo detecta).
UBOND_C="${ROOT}/build/ubond/src/ubond.c"
if [ -f "${UBOND_C}" ]; then
    if grep -q "reauth_attempts_no_inbound" "${UBOND_C}"; then
        junit_pass "build_tree_has_field"
    else
        junit_skip "build_tree_unpatched" \
            "build/ubond/src/ubond.c existe pero sin el campo - rebuild pendiente"
    fi
else
    junit_skip "build_tree_absent" \
        "build/ubond/src/ubond.c no existe (CI sin clone) - skipping"
fi

# 8. 03b-setup-mac-ubond.sh aplica el patch (grep nombre).
if [ -f "${SCRIPT_03B}" ] && grep -q "ubond_rebind_on_silence.patch" "${SCRIPT_03B}"; then
    junit_pass "wired_in_03b"
else
    junit_fail "not_wired_in_03b" \
        "03b-setup-mac-ubond.sh no transporta/aplica ubond_rebind_on_silence.patch"
fi

# 9. 07b-setup-rpi-ubond.sh transporta y aplica el patch (grep nombre).
if [ -f "${SCRIPT_07B}" ] && grep -q "ubond_rebind_on_silence.patch" "${SCRIPT_07B}"; then
    junit_pass "wired_in_07b"
else
    junit_fail "not_wired_in_07b" \
        "07b-setup-rpi-ubond.sh no transporta/aplica ubond_rebind_on_silence.patch"
fi

junit_finalize
