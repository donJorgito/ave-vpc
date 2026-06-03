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
