#!/usr/bin/env bash
###############################################################################
# 05-desconectar.sh — SOS atómico
#
# Trae el Mac de vuelta a red directa en <2 s. Diseñado para casos reales
# de AVE: cuando algo va mal, el usuario lanza este script y SIEMPRE
# termina rápido y limpio. Tolerante a fallos: si alguna operación falla
# (kill, route, DNS), sigue con el resto sin abortar.
#
# Diferencias vs versiones previas (REQ-MAC-05):
# - `set -u` solo (no `-eo pipefail`): un fallo parcial NO aborta la
#   limpieza completa. Antes podía dejar procesos vivos si algo fallaba
#   antes de llegar a su kill.
# - `pkill -9` directo desde el principio (sin pkill suave + sleep).
#   El antiguo sleep 2 s era una espera ciega innecesaria.
# - No hace `source` del config/env: extrae VPS_IP con awk para evitar
#   ejecutar código y para no depender de DNS.
# - Itera por todas las interfaces `en*` posibles al borrar rutas
#   ifscope (no solo las IFACE_IPHONE/PIXEL/WIFI conocidas).
# - Verificación final con estado de default route.
###############################################################################
set -u

if [[ "${EUID}" -ne 0 ]]; then
    echo "Necesita sudo:"
    echo "  SUDO_ASKPASS=/tmp/sudo-askpass.sh sudo -A ./05-desconectar.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/generated"

echo "=> Matando procesos mlvpn y watchers..."
# Procesos por nombre — kill -9 directo, sin pkill suave previo
pkill -9 -f "mlvpn: mlvpn0" 2>/dev/null
pkill -9 -f "seleccionar-mejor-enlace" 2>/dev/null
pkill -9 -f "calibrar-enlaces-dinamico" 2>/dev/null
pkill -9 -f "wifi-reintegrator" 2>/dev/null
pkill -9 -f "tee.*mlvpn.log" 2>/dev/null

# Defensivo: si algún PID file existe y apunta a un proceso vivo, también -9
for pid_file in "${GENERATED_DIR}"/*.pid; do
    [[ -f "${pid_file}" ]] || continue
    pid="$(cat "${pid_file}" 2>/dev/null || true)"
    [[ -n "${pid}" ]] && kill -9 "${pid}" 2>/dev/null
done

echo "=> Limpiando rutas del túnel..."
# Rutas 0/1 que mandaban todo el tráfico al utun
route -n delete -net 0.0.0.0/1 2>/dev/null
route -n delete -net 128.0.0.0/1 2>/dev/null

# Rutas /32 al VPS por cada interfaz física posible.
# Leemos VPS_IP del config con awk (sin source, evita ejecutar código).
VPS_IP=""
if [[ -f "${SCRIPT_DIR}/config/env" ]]; then
    VPS_IP="$(awk -F'=' '/^VPS_IP=/{gsub(/["[:space:]]/,"",$2); print $2; exit}' \
        "${SCRIPT_DIR}/config/env")"
fi
if [[ -n "${VPS_IP}" ]]; then
    # Tirar -ifscope por cada en* (algunas no existen → fallan rápido y se ignoran)
    for iface in en0 en1 en2 en3 en4 en5 en6 en7 en8 en9 en10 en11 en12 en13 en14 en15; do
        route -n delete -host "${VPS_IP}" -ifscope "${iface}" 2>/dev/null
    done
    route -n delete -host "${VPS_IP}" 2>/dev/null
fi

echo "=> Limpiando ficheros temporales..."
rm -f "${GENERATED_DIR}"/*.pid 2>/dev/null
rm -f "${GENERATED_DIR}/mlvpn_active.conf" 2>/dev/null

# --- Verificación final ---
echo ""
if pgrep -f "mlvpn: mlvpn0" >/dev/null 2>&1; then
    echo "✗ AVISO: quedan procesos mlvpn vivos:"
    pgrep -lf "mlvpn: mlvpn0" | sed 's/^/    /'
else
    echo "✓ mlvpn parado (todas las instancias)"
fi

DEF_IFACE="$(route -n get default 2>/dev/null | awk '/interface/{print $2}')"
DEF_GW="$(route -n get default 2>/dev/null | awk '/gateway/{print $2}')"
echo "✓ Default route: ${DEF_IFACE:-?} → ${DEF_GW:-?}"

echo ""
echo "=== Desconectado ==="
