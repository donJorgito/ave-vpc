#!/usr/bin/env bash
###############################################################################
# SOS.sh — emergencia 1-click para restaurar la red
#
# CUANDO USARLO:
#   Si después de usar mlvpn te quedas sin internet y 05-desconectar.sh no
#   responde, no funciona, o no recuerdas dónde está. Este script:
#   - NO requiere config/env (extrae VPS_IP con awk si existe)
#   - NO requiere internet
#   - Se auto-relanza con sudo si no eres root (usando askpass si existe)
#   - Termina en <2 s, tolerante a fallos (set -u, NO set -e)
#
# COMO EJECUTARLO:
#   bash ~/projects/ave-vpc/SOS.sh
#   (te pedirá la pass en diálogo gráfico vía /tmp/sudo-askpass.sh, o por
#    terminal si no existe)
#
# SI NI ESO RESPONDE:
#   Apaga y enciende el Wi-Fi del Mac desde el icono del menú. Eso fuerza
#   la renegociación de la default route. Reiniciar el Mac también funciona
#   (las rutas son in-memory).
###############################################################################
set -u

# Auto-relanzo con sudo si no soy root.
# Resolvemos path absoluto antes — sudo no busca en PATH y "$0" puede
# ser relativo (`bash SOS.sh` o `./SOS.sh`).
SCRIPT_ABS_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
if [[ "${EUID}" -ne 0 ]]; then
    if [[ -x /tmp/sudo-askpass.sh ]]; then
        SUDO_ASKPASS=/tmp/sudo-askpass.sh exec sudo -A bash "${SCRIPT_ABS_PATH}" "$@"
    else
        exec sudo bash "${SCRIPT_ABS_PATH}" "$@"
    fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/generated"

echo "=== SOS ==="

# 1. Matar TODO lo del túnel (mlvpn v1 + ubond v2) — múltiples patrones
# porque ambos cambian setproctitle. Sin pkill suave + sleep: -9 directo.
#
# IMPORTANTE: para ubond usamos `ubond: ` (dos puntos + espacio) en vez
# de `ubond: ubond0`. Razón: 04b lanza con `--name ubond0` produciendo
# title `ubond: ubond0 [priv]`, pero los smoke-test (tools/lib/) y
# debug runs sin `--name` producen `ubond: ubond [priv]` (sin el "0").
# El patrón corto cubre ambos. Bug detectado en AVE 2026-06-01:
# zombies de smoke-test sobrevivían a SOS.sh.
pkill -9 -f "mlvpn: mlvpn0" 2>/dev/null
pkill -9 -f "/usr/local/sbin/mlvpn" 2>/dev/null
pkill -9 -x "mlvpn" 2>/dev/null
pkill -9 -f "ubond: " 2>/dev/null
pkill -9 -f "/usr/local/sbin/ubond" 2>/dev/null
pkill -9 -x "ubond" 2>/dev/null
pkill -9 -f "seleccionar-mejor-enlace" 2>/dev/null
pkill -9 -f "calibrar-enlaces-dinamico" 2>/dev/null
pkill -9 -f "wifi-reintegrator" 2>/dev/null
pkill -9 -f "tee.*mlvpn.log" 2>/dev/null
pkill -9 -f "tee.*ubond.log" 2>/dev/null
# Watchers v2 si existieran como copias *_ubond.sh
pkill -9 -f "seleccionar-mejor-enlace_ubond" 2>/dev/null
pkill -9 -f "wifi-reintegrator_ubond" 2>/dev/null
# REQ-NET-26: watchdog ubond v2. Si SOS lo lanza el usuario, el
# watchdog NO debe sobrevivir y volver a invocar SOS en bucle.
pkill -9 -f "tools/ubond-watchdog.sh" 2>/dev/null

# Defensivo: matar también por PID files (cubre watchers cuyo nombre
# pueda variar)
for pid_file in "${GENERATED_DIR}"/*.pid; do
    [[ -f "${pid_file}" ]] || continue
    pid="$(cat "${pid_file}" 2>/dev/null || true)"
    [[ -n "${pid}" ]] && kill -9 "${pid}" 2>/dev/null
done

# 2. Borrar rutas 0/1 que tapan la default route (las añade 04-conectar)
route -n delete -net 0.0.0.0/1 2>/dev/null
route -n delete -net 128.0.0.0/1 2>/dev/null

# 3. Borrar /32 al VPS por cada ifscope (NO borra todas las /32 como
# hacía el SOS antiguo — eso podía romper rutas legítimas a NAS,
# impresoras, etc.). Lee VPS_IP con awk para no hacer source de config.
VPS_IP=""
if [[ -f "${SCRIPT_DIR}/config/env" ]]; then
    VPS_IP="$(awk -F'=' '/^VPS_IP=/{gsub(/["[:space:]]/,"",$2); print $2; exit}' \
        "${SCRIPT_DIR}/config/env")"
fi
if [[ -n "${VPS_IP}" ]]; then
    for iface in en0 en1 en2 en3 en4 en5 en6 en7 en8 en9 en10 en11 en12 en13 en14 en15; do
        route -n delete -host "${VPS_IP}" -ifscope "${iface}" 2>/dev/null
    done
    route -n delete -host "${VPS_IP}" 2>/dev/null
fi

# 4. Limpiar artefactos del túnel (PID files, confs activas v1+v2,
#    IPs colgadas en utuns, health flag del watchdog REQ-NET-26).
[[ -d "${GENERATED_DIR}" ]] && {
    rm -f "${GENERATED_DIR}"/*.pid 2>/dev/null
    rm -f "${GENERATED_DIR}/mlvpn_active.conf" 2>/dev/null
    rm -f "${GENERATED_DIR}/ubond_active.conf" 2>/dev/null
    rm -f "${GENERATED_DIR}/ubond_unhealthy" 2>/dev/null
}

# Limpia 10.10.10.x colgada en utuns fantasma (visto tras crashes ubond
# 2026-05-29 y refactor 2026-06-01).
for i in $(seq 0 15); do
    ip="$(ifconfig "utun${i}" 2>/dev/null \
            | awk '$1 == "inet" && $2 ~ /^10\.10\.10\./ { print $2; exit }')"
    if [[ -n "${ip}" ]]; then
        ifconfig "utun${i}" inet delete 2>/dev/null
    fi
done

# 4.5 Rearranque del wrapper udp2raw cliente (REQ-NET-41, 2026-06-12).
#
# MOTIVO: desde que la WiFi del AVE entra como tercer enlace ubond vía el
# wrapper EXTERIOR udp2raw faketcp, el [links.wifi] apunta a 127.0.0.1:5085
# (boca local del wrapper), NO directo al RPi. Si el wrapper udp2raw cliente
# muere, ese link NUNCA recupera por sí solo aunque ubond rearranque. Por eso
# SOS debe relanzarlo. Es ADITIVO/CONDICIONAL: en modo móvil-solo (sin
# wrapper) no se ejecuta nada nuevo y el comportamiento previo es idéntico.
#
# Detección del modo wrapper (cualquiera basta):
#   a) WIFI_VIA_WRAPPER=1 en el entorno
#   b) ubond_active.conf tiene un [links.wifi] con remotehost="127.0.0.1"
# El proceso udp2raw previo ya se mató en el paso 1 (PID files / pkill).
#
# NOTA macOS: el binario es udp2raw_mp y NO soporta -a (auto-iptables: macOS
# no tiene iptables; -a es FATAL). Por eso lanzamos el cliente directamente
# con el comando macOS-correcto SIN -a, en vez de delegar en wrap-udp2raw.sh
# (que pasa -a incondicional, válido en la RPi pero letal aquí). KEY y puertos
# se leen de disco/env — NO se hardcodean (Rule IDLC: sin secretos/IPs fijas).
ACTIVE_CONF="${GENERATED_DIR}/ubond_active.conf"
wrapper_mode=0
if [[ "${WIFI_VIA_WRAPPER:-0}" == "1" ]]; then
    wrapper_mode=1
elif [[ -f "${ACTIVE_CONF}" ]] && awk '
        /^\[links\.wifi\]/ { inwifi=1; next }
        /^\[/             { inwifi=0 }
        inwifi && /^[[:space:]]*remotehost[[:space:]]*=[[:space:]]*"127\.0\.0\.1"/ { found=1 }
        END { exit !found }' "${ACTIVE_CONF}"; then
    wrapper_mode=1
fi

if (( wrapper_mode == 1 )); then
    # Resolver binario (udp2raw o udp2raw_mp), KEY y puertos sin hardcodear.
    WRAP_BIN=""
    for cand in /opt/homebrew/bin/udp2raw_mp /opt/homebrew/bin/udp2raw udp2raw_mp udp2raw; do
        if command -v "${cand}" >/dev/null 2>&1; then WRAP_BIN="${cand}"; break; fi
    done
    WRAP_KEY_FILE="${GENERATED_DIR}/wrap_udp2raw.key"
    WRAP_KEY=""
    [[ -s "${WRAP_KEY_FILE}" ]] && WRAP_KEY="$(cat "${WRAP_KEY_FILE}" 2>/dev/null || true)"
    # Puertos: WRAP_LOCAL_PORT (boca local, default 5085) y UDP2RAW_PORT
    # (faketcp TCP, default 8443). Vienen de env si están exportados; si no,
    # los leemos de config/env con awk (sin source). RPI/host destino = VPS_IP.
    sos_env() {  # awk-extract de config/env, sin source (defensivo)
        [[ -f "${SCRIPT_DIR}/config/env" ]] || return 0
        awk -F'=' '/^'"$1"'=/{gsub(/["[:space:]]/,"",$2); print $2; exit}' \
            "${SCRIPT_DIR}/config/env"
    }
    WRAP_LOCAL_PORT="${WRAP_LOCAL_PORT:-$(sos_env UBOND_PORT_3)}"; WRAP_LOCAL_PORT="${WRAP_LOCAL_PORT:-5085}"
    WRAP_RAW_PORT="${UDP2RAW_PORT:-$(sos_env UDP2RAW_PORT)}";     WRAP_RAW_PORT="${WRAP_RAW_PORT:-8443}"
    WRAP_RHOST="${WRAP_REMOTE_HOST:-$(sos_env VPS_IP)}"

    if [[ -z "${WRAP_BIN}" ]]; then
        echo "✗ udp2raw no instalado — link WiFi vía wrapper no recuperará"
    elif [[ -z "${WRAP_KEY}" || -z "${WRAP_RHOST}" ]]; then
        echo "✗ falta KEY (${WRAP_KEY_FILE}) o VPS_IP — wrapper WiFi no rearrancado"
    else
        # Lanzar cliente faketcp SIN -a (macOS). Log a wrap_udp2raw.log.
        nohup "${WRAP_BIN}" -c \
            -l "127.0.0.1:${WRAP_LOCAL_PORT}" \
            -r "${WRAP_RHOST}:${WRAP_RAW_PORT}" \
            --raw-mode faketcp \
            -k "${WRAP_KEY}" \
            >>"${GENERATED_DIR}/wrap_udp2raw.log" 2>&1 &
        wrap_pid=$!
        disown 2>/dev/null || true
        # 2026-06-12 (review): persistir el PID. El kill del wrapper viejo (paso
        # 1) lee generated/wrap_udp2raw.pid; sin esto, un SOS posterior no podría
        # matar este cliente y colisionarían dos en 127.0.0.1:WRAP_LOCAL_PORT.
        echo "${wrap_pid}" > "${GENERATED_DIR}/wrap_udp2raw.pid"
        echo "✓ wrapper udp2raw cliente rearrancado (pid ${wrap_pid}): 127.0.0.1:${WRAP_LOCAL_PORT} -> ${WRAP_RHOST}:${WRAP_RAW_PORT} (faketcp, sin -a)"
    fi
fi

# 5. Verificación final
echo ""
if pgrep -f "mlvpn: mlvpn0" >/dev/null 2>&1; then
    echo "✗ procesos mlvpn aún vivos (raro tras pkill -9):"
    pgrep -lf "mlvpn: mlvpn0" | sed 's/^/    /'
else
    echo "✓ mlvpn parado"
fi
if pgrep -f "ubond: " >/dev/null 2>&1; then
    echo "✗ procesos ubond aún vivos (raro tras pkill -9):"
    pgrep -lf "ubond: " | sed 's/^/    /'
else
    echo "✓ ubond parado"
fi

DEF_IFACE="$(route -n get default 2>/dev/null | awk '/interface/{print $2}')"
DEF_GW="$(route -n get default 2>/dev/null | awk '/gateway/{print $2}')"
echo "✓ default route: ${DEF_IFACE:-?} → ${DEF_GW:-?}"

# Test internet (IP probe configurable; default 1.1.1.1).
# Lee HEALTH_PROBE_IP de config/env si existe (parser awk porque SOS no
# hace `source` defensivo — algunos env pueden tener errores).
SOS_PROBE_IP=""
if [[ -f "${SCRIPT_DIR}/config/env" ]]; then
    SOS_PROBE_IP="$(awk -F'=' '/^HEALTH_PROBE_IP=/{gsub(/["[:space:]]/,"",$2); print $2; exit}' \
        "${SCRIPT_DIR}/config/env")"
fi
SOS_PROBE_IP="${SOS_PROBE_IP:-1.1.1.1}"
if ping -c 1 -t 2 "${SOS_PROBE_IP}" >/dev/null 2>&1; then
    echo "✓ internet OK (probe ${SOS_PROBE_IP})"
else
    echo "✗ sin internet (probe ${SOS_PROBE_IP}) — apaga/enciende Wi-Fi del menú o reinicia"
fi

echo "=== Listo ==="
