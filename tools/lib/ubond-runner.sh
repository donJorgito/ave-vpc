#!/usr/bin/env bash
# tools/lib/ubond-runner.sh
#
# Ciclo de vida de ubond cliente para smoke-tests:
#   - cleanup_stale: mata procesos colgados y limpia la subnet ubond de utuns
#     fantasma (problema observado en debug 2026-05-29).
#   - start_with_conf: lanza ubond con el conf indicado en background,
#     redirigiendo a un log conocido.
#   - wait_auth: bloquea hasta que ≥1 link aparece como autenticado en log,
#     o hasta timeout.
#   - find_utun_iface: detecta qué utunN ha tomado la IP del túnel.
#   - stop: kill limpio.
#
# Asume que el script padre ya ejecuta como root (require_root).

# shellcheck source=tools/lib/_common.sh
: "${AVEVPC_ROOT:?source _common.sh primero}"

UBOND_BIN="${UBOND_BIN:-/usr/local/sbin/ubond}"
UBOND_LOG="${SMOKE_TMPDIR}/ubond_client.log"
UBOND_PID_FILE="${SMOKE_TMPDIR}/ubond_client.pid"

# Mata procesos ubond colgados, limpia IPs ubond (10.10.20.x) de utuns
# fantasma. Importante: NO tocamos 10.10.10.x — esa subnet pertenece a
# mlvpn y un cleanup global rompería v1 corriendo simultáneamente
# (REQ-NET-24).
ubond_runner_cleanup_stale() {
    if pgrep -f "${UBOND_BIN}" >/dev/null 2>&1; then
        log_warn "Procesos ubond previos — terminando"
        pkill -9 -f "${UBOND_BIN}" || true
        sleep 1
    fi
    local subnet_re="${UBOND_TUN_MAC_IP%.*}\\."  # ej. 10.10.20.
    # Escapa puntos para regex literal.
    subnet_re="${subnet_re//./\\.}"
    local i ip
    for i in $(seq 0 15); do
        ip="$(ifconfig "utun${i}" 2>/dev/null \
                | awk -v re="^${subnet_re}" '$1 == "inet" && $2 ~ re { print $2; exit }')"
        if [[ -n "${ip}" ]]; then
            log_warn "Limpiando ${ip} de utun${i} (zombie ubond de run anterior)"
            ifconfig "utun${i}" inet delete 2>/dev/null || true
        fi
    done
    rm -f "${UBOND_LOG}" "${UBOND_PID_FILE}"
}

# Lanza ubond cliente en background. Args: $1 = conf path.
ubond_runner_start_with_conf() {
    local conf="$1"
    require_file "${conf}"
    require_cmd "${UBOND_BIN}"

    : > "${UBOND_LOG}"
    "${UBOND_BIN}" \
        --config "${conf}" \
        --user ubond \
        --debug --verbose \
        > "${UBOND_LOG}" 2>&1 &
    local pid="$!"
    echo "${pid}" > "${UBOND_PID_FILE}"
    log_info "ubond cliente arrancado (PID ${pid}) → log ${UBOND_LOG}"
}

# Espera hasta que al menos un link aparezca autenticado (`@links.NAME`)
# en el log. Args: $1 = timeout en segundos (default 15).
# Devuelve 0 si hay auth, 1 si timeout.
ubond_runner_wait_auth() {
    local timeout="${1:-15}"
    local elapsed=0
    while (( elapsed < timeout )); do
        if grep -qE "@links\.[a-z]+" "${UBOND_LOG}" 2>/dev/null; then
            log_info "Auth detectada tras ${elapsed}s"
            return 0
        fi
        # Match alternativo: el process title lo refleja también.
        if pgrep -f "ubond: ubond @links\." >/dev/null 2>&1; then
            log_info "Auth detectada (via process title) tras ${elapsed}s"
            return 0
        fi
        sleep 1; elapsed=$((elapsed + 1))
    done
    log_warn "Timeout (${timeout}s) sin auth"
    return 1
}

# Detecta qué utunN tiene la IP del túnel ubond. Devuelve el nombre por
# stdout (ej. "utun7"), vacío si no hay.
ubond_runner_find_utun_iface() {
    local target="${UBOND_TUN_MAC_IP:-10.10.20.2}"
    local i ip
    for i in $(seq 0 15); do
        ip="$(ifconfig "utun${i}" 2>/dev/null \
                | awk '$1 == "inet" && $2 == "'"${target}"'" { print $2; exit }')"
        if [[ -n "${ip}" ]]; then
            echo "utun${i}"; return 0
        fi
    done
    return 1
}

# Para ubond limpio (kill + cleanup IPs ubond colgadas). Importante: solo
# limpiamos utuns con la IP de ubond (UBOND_TUN_MAC_IP), no las de mlvpn.
ubond_runner_stop() {
    if [[ -f "${UBOND_PID_FILE}" ]]; then
        pkill -f "${UBOND_BIN}" 2>/dev/null || true
    fi
    sleep 1
    pkill -9 -f "${UBOND_BIN}" 2>/dev/null || true
    rm -f "${UBOND_PID_FILE}"
    local target="${UBOND_TUN_MAC_IP:-10.10.20.2}"
    local i ip
    for i in $(seq 0 15); do
        ip="$(ifconfig "utun${i}" 2>/dev/null \
                | awk '$1 == "inet" && $2 == "'"${target}"'" { print $2; exit }')"
        [[ -n "${ip}" ]] && ifconfig "utun${i}" inet delete 2>/dev/null || true
    done
    log_info "ubond detenido"
}

# Imprime las últimas N líneas del log de ubond (default 30).
ubond_runner_tail_log() {
    local n="${1:-30}"
    if [[ -r "${UBOND_LOG}" ]]; then tail -n "${n}" "${UBOND_LOG}"; fi
}
