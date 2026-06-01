#!/usr/bin/env bash
# tools/lib/conf-gen.sh
#
# Genera config ubond temporal para el smoke-test, usando la lista de
# links elegibles detectados por env-detect.sh y el target remoto (LAN o
# DDNS). El conf vive en ${SMOKE_TMPDIR}/ubond_smoke.conf.
#
# Asunciones:
#   - Las claves criptográficas residen en ${AVEVPC_ROOT}/keys/mlvpn.secret
#     (compartidas con mlvpn — secreto único).
#   - Los puertos remotos son UBOND_PORT_1/2/3 (5083/5084/5085) salvo override.
#   - El statuscommand es generated/ubond_updown_mac.sh — debe existir y
#     tener permisos 700 (el privsep de ubond rechaza group/other accessible).

# shellcheck source=tools/lib/_common.sh
: "${AVEVPC_ROOT:?source _common.sh primero}"

CONF_GEN_PATH="${SMOKE_TMPDIR}/ubond_smoke.conf"

# Mapa link-name → puerto remoto (paralelo al esquema de 03b-setup-mac-ubond.sh
# y 07b-setup-rpi-ubond.sh: iphone=5083, pixel=5084, wifi=5085).
_conf_gen_port_for_link() {
    case "$1" in
        iphone) echo "${UBOND_PORT_1:-5083}" ;;
        pixel)  echo "${UBOND_PORT_2:-5084}" ;;
        wifi)   echo "${UBOND_PORT_3:-5085}" ;;
        *)      die 2 "link desconocido: $1" ;;
    esac
}

# Genera el conf. Args:
#   $1: remote_host  (RPi_IP o VPS_IP — env_detect_all lo resuelve)
#   resto: una o más entradas "name|iface|ip" (formato ELIGIBLE_LINKS)
conf_gen_write() {
    local remote_host="$1"; shift
    [[ -n "${remote_host}" ]] || die 2 "conf_gen_write: remote_host vacío"
    [[ $# -gt 0 ]] || die 2 "conf_gen_write: sin links"

    local secret_file="${AVEVPC_ROOT}/keys/mlvpn.secret"
    require_file "${secret_file}"
    local secret
    secret="$(tr -d '\n' < "${secret_file}")"

    local statuscmd="${AVEVPC_ROOT}/generated/ubond_updown_mac.sh"
    require_file "${statuscmd}"
    # Privsep de ubond: 700 obligatorio.
    chmod 700 "${statuscmd}"

    {
        cat <<HEADER
# ${CONF_GEN_PATH} — generado por tools/lib/conf-gen.sh
# Uso: smoke-test (NO production). No se trackea en git.
[general]
mode = "client"
tuntap = "tun"
interface_name = "ubond0"
ip4 = "${UBOND_TUN_MAC_IP:-10.10.20.2}"
ip4_gateway = "${UBOND_TUN_VPS_IP:-10.10.20.1}"
mtu = ${TUN_MTU:-1400}
password = "${secret}"
timeout = 30
statuscommand = "${statuscmd}"

[filters]
[filters.fifo]

HEADER

        local entry name _iface ip port
        for entry in "$@"; do
            IFS='|' read -r name _iface ip <<<"${entry}"
            port="$(_conf_gen_port_for_link "${name}")"
            cat <<LINK
[links.${name}]
bindhost = "${ip}"
remotehost = "${remote_host}"
remoteport = ${port}
bandwidth_upload = 10000000

LINK
        done
    } > "${CONF_GEN_PATH}"

    chmod 600 "${CONF_GEN_PATH}"
    log_info "Conf generada: ${CONF_GEN_PATH} (${#} link(s) → ${remote_host})"
}

conf_gen_path() { echo "${CONF_GEN_PATH}"; }
