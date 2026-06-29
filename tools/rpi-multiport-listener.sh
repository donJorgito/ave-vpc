#!/usr/bin/env bash
###############################################################################
# tools/rpi-multiport-listener.sh — REQ-NET-38 (Task T1)
#
# Listener multipuerto que corre EN LA RPi (Debian / Raspberry Pi OS, Linux).
# Escucha TCP + UDP en un set configurable de puertos y contesta a cada
# conexión/datagrama un eco identificable:
#
#     AVE-VPC-LISTENER port=<p> proto=<tcp|udp>
#
# Sirve de base a la Vía F (probe-firewall.sh en el Mac): un cliente puede
# distinguir qué puertos/protocolos sobreviven al firewall WiFi del tren
# comparando la respuesta recibida contra el eco esperado:
#   - eco correcto         → el transporte cruza limpio (PASS)
#   - respuesta distinta   → DNAT / proxy / captive (cuelga otra cosa)
#   - sin respuesta        → SILENT (DROP del firewall)
#
# Diseño (doc docs/v2-ubond/13-plan-bypass-wifi-tren.md §3 T1):
#   - python3 stdlib puro (preinstalado en Pi OS) — sin dependencias apt.
#   - Un único proceso python que bindea N×(tcp+udp) sockets vía selectors.
#   - Idempotente: PID file en generated/, re-lanzar no duplica.
#   - Parametrizable por env: PORTS_TCP, PORTS_UDP (lista separada por espacios).
#   - Parable limpiamente (SIGINT/SIGTERM cierran todos los sockets).
#   - Shippable como unit systemd (install/uninstall más abajo).
#
# NO toca el puerto 22 (SSH) — se excluye explícitamente del set por seguridad.
#
# Uso:
#   ./rpi-multiport-listener.sh run        # foreground (lo usa systemd)
#   ./rpi-multiport-listener.sh start      # background con PID file
#   ./rpi-multiport-listener.sh stop       # para el listener en background
#   ./rpi-multiport-listener.sh status     # estado + puertos en escucha
#   ./rpi-multiport-listener.sh install    # instala unit systemd
#   ./rpi-multiport-listener.sh uninstall  # elimina unit systemd
###############################################################################

set -uo pipefail

# bash >=4 (consistencia con el resto de watchers del repo)
if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: necesita bash >=4 (Pi OS trae 5.x). apt install bash" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/generated"
CONFIG_FILE="${SCRIPT_DIR}/config/env"
PID_FILE="${GENERATED_DIR}/rpi_multiport_listener.pid"
LOG="${GENERATED_DIR}/rpi_multiport_listener.log"

mkdir -p "${GENERATED_DIR}"

# Cargar config/env si existe (puede aportar PORTS_TCP/PORTS_UDP override).
# No es fatal si falta: el listener no depende de VPS_IP ni nada del túnel.
if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
fi

# Set de puertos por defecto. 22 (SSH) queda FUERA a propósito.
# Elegidos para mapear el firewall Renfe (doc 12 + 13):
#   80,443       → confirmados DNAT al captive; sirven de control negativo.
#   853 (DoT)    → DNS-over-TLS, candidato a pasar si solo DNAT-ean 80/443.
#   993 (IMAPS)  → puerto "legítimo" alto que operadores rara vez tocan.
#   2222,8080,8443,9001 → puertos no estándar, hipótesis Vía A (TCP limpio).
#   9999 (alto)  → control de "puerto random alto" no privilegiado.
PORTS_TCP="${PORTS_TCP:-80 443 853 993 2222 8080 8443 9001 9999}"
PORTS_UDP="${PORTS_UDP:-80 443 853 993 2222 8080 8443 9001 9999}"

# Marcador del eco — el probe lo busca para distinguir PASS de DNAT.
ECHO_TAG="${LISTENER_ECHO_TAG:-AVE-VPC-LISTENER}"

# Ruta de la unit systemd.
SYSTEMD_UNIT="/etc/systemd/system/ave-vpc-listener.service"

log() { printf '%s %s\n' "$(date -Iseconds)" "$*" | tee -a "${LOG}" >&2; }

# Salvaguarda: nunca permitir el puerto 22 en el set (SSH).
_guard_no_ssh() {
    local p
    for p in ${PORTS_TCP} ${PORTS_UDP}; do
        if [[ "${p}" == "22" ]]; then
            echo "ERROR: el puerto 22 (SSH) no puede estar en PORTS_TCP/PORTS_UDP" >&2
            exit 1
        fi
    done
}

###############################################################################
# run_foreground — corazón del listener (python3 stdlib).
#
# Pasa los sets de puertos y el tag por env al intérprete python. python3
# usa selectors (epoll en Linux) para multiplexar todos los sockets en un
# único hilo: barato en RAM para una RPi.
###############################################################################
run_foreground() {
    _guard_no_ssh
    log "listener arrancando — TCP=[${PORTS_TCP}] UDP=[${PORTS_UDP}] tag=${ECHO_TAG}"
    PORTS_TCP="${PORTS_TCP}" PORTS_UDP="${PORTS_UDP}" ECHO_TAG="${ECHO_TAG}" \
        exec python3 - <<'PYEOF'
import os, sys, socket, selectors, signal

ports_tcp = [int(p) for p in os.environ.get("PORTS_TCP", "").split()]
ports_udp = [int(p) for p in os.environ.get("PORTS_UDP", "").split()]
tag = os.environ.get("ECHO_TAG", "AVE-VPC-LISTENER")

sel = selectors.DefaultSelector()
sockets = []

def payload(port, proto):
    # Eco identificable que el probe del Mac compara byte a byte.
    return (f"{tag} port={port} proto={proto}\n").encode()

def open_tcp(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("0.0.0.0", port))
    except OSError as e:
        sys.stderr.write(f"WARN tcp/{port} bind fallo: {e}\n")
        s.close()
        return
    s.listen(16)
    s.setblocking(False)
    sel.register(s, selectors.EVENT_READ, ("tcp-accept", port))
    sockets.append(s)

def open_udp(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("0.0.0.0", port))
    except OSError as e:
        sys.stderr.write(f"WARN udp/{port} bind fallo: {e}\n")
        s.close()
        return
    s.setblocking(False)
    sel.register(s, selectors.EVENT_READ, ("udp", port))
    sockets.append(s)

for p in ports_tcp:
    open_tcp(p)
for p in ports_udp:
    open_udp(p)

if not sockets:
    sys.stderr.write("ERROR: ningún socket abierto, abortando\n")
    sys.exit(1)

stop = False
def _stop(signum, frame):
    global stop
    stop = True
signal.signal(signal.SIGINT, _stop)
signal.signal(signal.SIGTERM, _stop)

sys.stderr.write(f"listening tcp={ports_tcp} udp={ports_udp}\n")
sys.stderr.flush()

while not stop:
    events = sel.select(timeout=1.0)
    for key, _ in events:
        kind, port = key.data
        sock = key.fileobj
        try:
            if kind == "tcp-accept":
                conn, _addr = sock.accept()
                # Eco síncrono + cierre: conexión efímera, sin estado.
                try:
                    conn.settimeout(2.0)
                    conn.recv(1024)          # drenar lo que mande el cliente
                    conn.sendall(payload(port, "tcp"))
                finally:
                    conn.close()
            elif kind == "udp":
                data, addr = sock.recvfrom(1024)
                sock.sendto(payload(port, "udp"), addr)
        except OSError:
            # Conexión rota / datagrama suelto: ignorar, seguir sirviendo.
            continue

for s in sockets:
    try:
        s.close()
    except OSError:
        pass
sys.stderr.write("listener parado\n")
PYEOF
}

###############################################################################
# start / stop / status — gestión en background con PID file (idempotente).
###############################################################################
start_background() {
    if [[ -f "${PID_FILE}" ]]; then
        local old_pid
        old_pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
        if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
            echo "listener ya corriendo (pid ${old_pid})" >&2
            exit 0
        fi
        rm -f "${PID_FILE}"
    fi
    run_foreground >>"${LOG}" 2>&1 &
    echo "$!" >"${PID_FILE}"
    log "listener en background (pid $!)"
}

stop_background() {
    if [[ ! -f "${PID_FILE}" ]]; then
        echo "no hay PID file — listener no corriendo" >&2
        return 0
    fi
    local pid
    pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
        # SIGTERM al wrapper bash; el exec python hereda el PID y lo captura.
        kill -TERM "${pid}" 2>/dev/null || true
        log "SIGTERM enviado a listener pid=${pid}"
    fi
    rm -f "${PID_FILE}"
}

show_status() {
    if [[ -f "${PID_FILE}" ]]; then
        local pid
        pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            echo "listener ACTIVO (pid ${pid})"
        else
            echo "listener INACTIVO (PID file stale)"
        fi
    else
        echo "listener INACTIVO (sin PID file)"
    fi
    echo "TCP esperados: ${PORTS_TCP}"
    echo "UDP esperados: ${PORTS_UDP}"
    # ss está en Pi OS (iproute2). Mostrar lo que realmente escucha.
    if command -v ss >/dev/null 2>&1; then
        echo "--- en escucha (ss) ---"
        ss -tulnp 2>/dev/null | grep -E "python3|LISTEN|UNCONN" || true
    fi
}

###############################################################################
# install / uninstall — unit systemd.
#
# La unit corre el script con el subcomando `run` (foreground). systemd
# gestiona arranque/parada/restart; NO se usa el PID file en modo systemd
# (Type=simple, systemd es el supervisor).
###############################################################################
install_unit() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        echo "ERROR: install requiere root (sudo)" >&2
        exit 1
    fi
    cat >"${SYSTEMD_UNIT}" <<EOF
[Unit]
Description=AVE-VPC multiport listener (REQ-NET-38 / Task T1)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# Sets de puertos pasados por env (override del default del script).
Environment=PORTS_TCP=${PORTS_TCP}
Environment=PORTS_UDP=${PORTS_UDP}
Environment=LISTENER_ECHO_TAG=${ECHO_TAG}
ExecStart=${SCRIPT_DIR}/tools/rpi-multiport-listener.sh run
Restart=on-failure
RestartSec=3
# Endurecido básico: el listener no necesita escribir en disco salvo logs.
NoNewPrivileges=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now ave-vpc-listener.service
    log "unit systemd instalada y arrancada: ${SYSTEMD_UNIT}"
}

uninstall_unit() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        echo "ERROR: uninstall requiere root (sudo)" >&2
        exit 1
    fi
    systemctl disable --now ave-vpc-listener.service 2>/dev/null || true
    rm -f "${SYSTEMD_UNIT}"
    systemctl daemon-reload
    log "unit systemd eliminada: ${SYSTEMD_UNIT}"
}

###############################################################################
# Dispatcher
###############################################################################
case "${1:-run}" in
    run)       run_foreground ;;
    start)     start_background ;;
    stop)      stop_background ;;
    status)    show_status ;;
    install)   install_unit ;;
    uninstall) uninstall_unit ;;
    *)
        echo "uso: $0 {run|start|stop|status|install|uninstall}" >&2
        exit 2
        ;;
esac
