#!/usr/bin/env bash
###############################################################################
# 05-desconectar.sh
#
# DONDE SE EJECUTA: En tu Mac (al llegar al destino)
#
# QUE HACE:
#   1. Para el proceso mlvpn
#   2. Limpia las rutas especificas al VPS
#   3. Restaura la red a su estado normal
#
# Despues de ejecutar este script, tu Mac vuelve a usar la red normal.
# Es seguro ejecutarlo aunque ya estuviera desconectado.
###############################################################################
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Este script requiere sudo."
    echo "Desde Claude Code: SUDO_ASKPASS=/tmp/sudo-askpass.sh sudo -A ./05-desconectar.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config/env"
GENERATED_DIR="${SCRIPT_DIR}/generated"

if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
fi

# --- Paso 1: Parar mlvpn ---
# Matar todos los procesos mlvpn por nombre (el PID file apunta al tee, no al proceso mlvpn)
echo "=> Parando mlvpn..."
if pgrep -f "mlvpn: mlvpn0" &>/dev/null; then
    pkill -f "mlvpn: mlvpn0" 2>/dev/null || true
    sleep 2
    pkill -9 -f "mlvpn: mlvpn0" 2>/dev/null || true
    pkill -f "tee.*mlvpn.log" 2>/dev/null || true
    echo "  mlvpn parado"
else
    echo "  mlvpn ya no estaba corriendo"
fi
rm -f "${GENERATED_DIR}/mlvpn.pid"

# --- Paso 2: Limpiar rutas ---
echo "=> Limpiando rutas..."
if [[ -n "${VPS_IP:-}" ]]; then
    # Borrar rutas con -ifscope (una por interfaz) y la ruta genérica
    sudo route -n delete -host "${VPS_IP}" -ifscope "${IFACE_IPHONE:-en8}" 2>/dev/null || true
    sudo route -n delete -host "${VPS_IP}" -ifscope "${IFACE_PIXEL:-en12}" 2>/dev/null || true
    sudo route -n delete -host "${VPS_IP}" 2>/dev/null || true
    echo "  Rutas a ${VPS_IP} eliminadas"
fi

sudo route -n delete -net 0.0.0.0/1 2>/dev/null || true
sudo route -n delete -net 128.0.0.0/1 2>/dev/null || true

# --- Paso 3: Limpiar archivos temporales ---
echo "=> Limpiando archivos temporales..."
rm -f "${GENERATED_DIR}/mlvpn_active.conf"
rm -f "${GENERATED_DIR}/mlvpn.log"
rm -f "${GENERATED_DIR}/mlvpn.pid"

echo ""
echo "=== Desconectado ==="
echo "Tu Mac ahora usa la red normal."
