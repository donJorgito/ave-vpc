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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config/env"
GENERATED_DIR="${SCRIPT_DIR}/generated"

if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
fi

# --- Paso 1: Parar mlvpn ---
echo "=> Parando mlvpn..."
if [[ -f "${GENERATED_DIR}/mlvpn.pid" ]]; then
    MLVPN_PID="$(cat "${GENERATED_DIR}/mlvpn.pid")"
    if sudo kill -0 "${MLVPN_PID}" 2>/dev/null; then
        sudo kill "${MLVPN_PID}"
        # Esperar a que termine limpiamente (ejecutara el script down)
        sleep 2
        # Si sigue vivo, forzar
        sudo kill -9 "${MLVPN_PID}" 2>/dev/null || true
        echo "  mlvpn (PID ${MLVPN_PID}) parado"
    else
        echo "  mlvpn ya no estaba corriendo"
    fi
    rm -f "${GENERATED_DIR}/mlvpn.pid"
else
    # Buscar por nombre de proceso como fallback
    sudo pkill -f "mlvpn.*mlvpn_active.conf" 2>/dev/null && echo "  mlvpn parado (por nombre)" || echo "  No hay mlvpn activo"
fi

# --- Paso 2: Limpiar rutas ---
echo "=> Limpiando rutas..."
if [[ -n "${VPS_IP:-}" ]]; then
    sudo route -n delete -host "${VPS_IP}" 2>/dev/null && echo "  Ruta a ${VPS_IP} eliminada" || echo "  No habia ruta a ${VPS_IP}"
fi

# Limpiar rutas /1 del tunel (las que puso el script up/down)
sudo route -n delete -net 0.0.0.0/1 2>/dev/null || true
sudo route -n delete -net 128.0.0.0/1 2>/dev/null || true

# --- Paso 3: Limpiar archivos temporales ---
echo "=> Limpiando archivos temporales..."
rm -f "${GENERATED_DIR}/mlvpn_active.conf"

echo ""
echo "=== Desconectado ==="
echo "Tu Mac ahora usa la red normal."
