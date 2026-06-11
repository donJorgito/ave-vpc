#!/bin/sh
# Validates ave-vpc.REQ-NET-44: rotación de MAC del WiFi para resetear la
# cuota del portal Icomera del AVE (tools/mac-rotate.sh).
#
# Checks ESTÁTICOS (no toca red, NO rota la MAC, no requiere root): el script
# existe, es ejecutable, expone --show/--rotate/--restore, exige root en las
# mutaciones, genera una MAC locally-administered unicast (bit-math presente),
# valida la MAC antes de aplicar, persiste el original idempotentemente,
# entrecomilla la interfaz, lee config/env, no hardcodea IPs, usa logger -t,
# avisa del blip WiFi, y pasa bash -n.
#
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-44_mac_rotate"

ROOT="$(dirname "$0")/.."
TOOLS="${ROOT}/tools"
MR="${TOOLS}/mac-rotate.sh"

# 1. El script existe.
if [ -f "${MR}" ]; then
    junit_pass "mac_rotate_exists"
else
    junit_fail "mac_rotate_missing" "falta tools/mac-rotate.sh"
    junit_finalize
fi

# 2. Es ejecutable.
if [ -x "${MR}" ]; then
    junit_pass "mac_rotate_executable"
else
    junit_fail "mac_rotate_not_executable" "chmod +x tools/mac-rotate.sh"
fi

# 3. set -uo pipefail.
if grep -q "set -uo pipefail" "${MR}"; then
    junit_pass "set_pipefail"
else
    junit_fail "set_pipefail_missing" "no usa set -uo pipefail"
fi

# 4. Guard bash >= 4.
if grep -q "BASH_VERSINFO" "${MR}"; then
    junit_pass "bash4_guard"
else
    junit_fail "bash4_guard_missing" "sin guard bash>=4"
fi

# 5. Expone --show, --rotate, --restore.
if grep -q -- "--show" "${MR}" \
   && grep -q -- "--rotate" "${MR}" \
   && grep -q -- "--restore" "${MR}"; then
    junit_pass "subcommands_present"
else
    junit_fail "subcommands_missing" "no expone --show/--rotate/--restore"
fi

# 6. Exige root en las mutaciones (require_root / EUID).
if grep -qE "require_root|EUID" "${MR}"; then
    junit_pass "requires_root"
else
    junit_fail "requires_root_missing" "no exige root para rotar/restaurar"
fi

# 7. Bit-math MAC locally-administered unicast: (rand & 0xFE) | 0x02.
#    Acepta variantes hex/decimal del enmascarado (0xFE/254, 0x02/2).
if grep -qiE "0xFE|& *254" "${MR}" && grep -qiE "0x02|\| *2" "${MR}"; then
    junit_pass "mac_bitmath_local_unicast"
else
    junit_fail "mac_bitmath_missing" \
        "no aplica (rand & 0xFE)|0x02 para unicast + locally-administered"
fi

# 8. Documenta los bits I/G (unicast) y U/L (locally-administered).
if grep -qiE "I/G|unicast" "${MR}" && grep -qiE "U/L|locally-administered|local" "${MR}"; then
    junit_pass "mac_bits_documented"
else
    junit_fail "mac_bits_undocumented" "no documenta los bits I/G y U/L"
fi

# 9. Valida la MAC antes de aplicarla (función validadora).
if grep -qE "is_valid_local_unicast|valid.*unicast" "${MR}"; then
    junit_pass "mac_validated_before_apply"
else
    junit_fail "mac_validation_missing" "no valida la MAC antes de ifconfig ether"
fi

# 10. Persiste la MAC original de forma idempotente (no sobrescribe).
if grep -qE "persist_original_once|ORIG_MAC_FILE" "${MR}" \
   && grep -qE "networksetup|ioreg" "${MR}"; then
    junit_pass "original_mac_persisted"
else
    junit_fail "original_mac_persist_missing" \
        "no persiste la MAC hardware original (networksetup/ioreg)"
fi

# 11. Desasocia el WiFi (airport -z) antes de cambiar la MAC.
if grep -q "airport" "${MR}" && grep -qE -- "-z" "${MR}"; then
    junit_pass "wifi_disassociate"
else
    junit_fail "wifi_disassociate_missing" "no desasocia el WiFi (airport -z) antes del cambio"
fi

# 12. Aplica la MAC con ifconfig ether.
if grep -qE "ifconfig .*ether" "${MR}"; then
    junit_pass "ifconfig_ether_used"
else
    junit_fail "ifconfig_ether_missing" "no usa ifconfig <iface> ether <mac>"
fi

# 13. Lee IFACE_WIFI de config/env (sin hardcoding — Rule 4) y entrecomilla
#     la interfaz (sin inyección). No debe hardcodear IPs públicas.
uses_cfg=0
grep -q "IFACE_WIFI" "${MR}" && grep -q "config/env" "${MR}" && uses_cfg=1
quoted=0
grep -qE 'ifconfig "\$\{IFACE\}"' "${MR}" && quoted=1
hardcoded=0
if grep -vE '_PINNED_VERSION|versión|version' "${MR}" \
    | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
    | grep -vE '^(127\.0\.0\.1|0\.0\.0\.0)$' \
    | grep -q '.'; then
    hardcoded=1
fi
if [ "${uses_cfg}" -eq 1 ] && [ "${quoted}" -eq 1 ] && [ "${hardcoded}" -eq 0 ]; then
    junit_pass "config_env_quoted_no_hardcode"
else
    junit_fail "config_env_or_injection" \
        "no lee IFACE_WIFI de config/env, no entrecomilla la interfaz, o hardcodea IP"
fi

# 14. logger -t mac-rotate (house style).
if grep -q "logger -t mac-rotate" "${MR}"; then
    junit_pass "logger_tag"
else
    junit_fail "logger_missing" "no usa logger -t mac-rotate"
fi

# 15. Avisa del blip de la asociación WiFi / re-auth captive.
if grep -qiE "re-auth|reautentic|asociaci|blip|suelt" "${MR}"; then
    junit_pass "warns_wifi_blip"
else
    junit_fail "warns_wifi_blip_missing" "no avisa del blip WiFi / re-auth captive"
fi

# 16. NO debe hacer ssh (solo opera localmente).
if grep -qE "^[[:space:]]*ssh " "${MR}"; then
    junit_fail "does_ssh" "mac-rotate ejecuta ssh — debe operar solo localmente"
else
    junit_pass "no_ssh"
fi

# 17. Sintaxis bash válida.
if bash -n "${MR}" 2>/dev/null; then
    junit_pass "bash_syntax_ok"
else
    junit_fail "bash_syntax_fail" "tools/mac-rotate.sh tiene errores de sintaxis bash"
fi

junit_finalize
