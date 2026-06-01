#!/usr/bin/env bash
# tools/lib/_common.sh
#
# Helpers compartidos por las libs de smoke-test (env-detect, conf-gen,
# tcpdump, ubond-runner, tests, report). Sourceable. Sin side-effects al
# cargarse — solo define funciones y constantes.
#
# Convenciones:
#   - Funciones públicas: log_info/warn/err, die, require_cmd, require_file,
#     require_root, as_invoker.
#   - Variables exportadas: AVEVPC_ROOT (raíz del repo), SMOKE_TMPDIR.
#   - Códigos de salida: 0 OK; 2 prereq missing; 3 sudo missing; 1 otros.

set -uo pipefail

AVEVPC_ROOT="${AVEVPC_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SMOKE_TMPDIR="${SMOKE_TMPDIR:-/tmp/ave-smoke}"
mkdir -p "${SMOKE_TMPDIR}"

# --- logging -----------------------------------------------------------------

_LOG_PREFIX="${_LOG_PREFIX:-smoke}"

log_info() { printf '[%s] [INFO]  %s\n'  "${_LOG_PREFIX}" "$*"; }
log_warn() { printf '[%s] [WARN]  %s\n'  "${_LOG_PREFIX}" "$*" >&2; }
log_err()  { printf '[%s] [ERROR] %s\n'  "${_LOG_PREFIX}" "$*" >&2; }

die() {
    local code="${1:-1}"; shift || true
    log_err "$*"
    exit "${code}"
}

# --- prerequisitos -----------------------------------------------------------

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die 2 "comando requerido no encontrado: $1"
}

require_file() {
    [[ -r "$1" ]] || die 2 "fichero requerido no legible: $1"
}

# Verifica que ejecutamos como root. Los orchestrators smoke-* se invocan
# `sudo ./tools/smoke-XXX.sh` — UNA password prompt al inicio, después
# todas las operaciones (tcpdump, ifconfig, kill ubond) son nativas sin
# pedir más passwords. El SUDO_USER original queda disponible para SSH.
require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die 3 "Este script debe ejecutarse como root: sudo $0 $*"
    fi
    if [[ -z "${SUDO_USER:-}" ]]; then
        log_warn "Ejecutado como root sin sudo — SSH usará el HOME de root"
    fi
}

# Ejecuta un comando como el usuario original (no como root). Útil para
# operaciones que necesitan las claves SSH del usuario (~/.ssh) en lugar
# de las de root. Si no hay SUDO_USER (ejecutado directamente como root),
# usa el comando tal cual.
as_invoker() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        sudo -u "${SUDO_USER}" -H "$@"
    else
        "$@"
    fi
}

# --- utilidades --------------------------------------------------------------

# Si la salida es un terminal, formato bonito; si no, plano. Útil para
# orchestrators que se ejecutan en CI o en pipe.
is_tty() { [[ -t 1 ]]; }

# Imprime una línea separadora.
hr() { printf '%s\n' '----------------------------------------------------'; }
