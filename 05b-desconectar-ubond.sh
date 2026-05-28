#!/usr/bin/env bash
###############################################################################
# 05b-desconectar-ubond.sh
#
# Para el túnel ubond (v2) — espejo de 05-desconectar.sh para mlvpn.
# Limpia procesos ubond, rutas /32 al VPS, y rutas 0/1 + 128/1.
#
# NO toca mlvpn. Si tienes ambos arriba (raro), ejecutar también 05.
###############################################################################
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Este script requiere sudo."
    echo "  sudo ./05b-desconectar-ubond.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config/env"
GENERATED_DIR="${SCRIPT_DIR}/generated"

if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
fi

echo "=> Matando procesos ubond y watchers..."
pkill -f "ubond: ubond0" 2>/dev/null || true
sleep 1
pkill -9 -f "ubond: ubond0" 2>/dev/null || true
pkill -9 -f "tee.*ubond.log" 2>/dev/null || true

if [[ -f "${GENERATED_DIR}/ubond.pid" ]]; then
    PID="$(cat "${GENERATED_DIR}/ubond.pid")"
    kill -9 "${PID}" 2>/dev/null || true
    rm -f "${GENERATED_DIR}/ubond.pid"
fi

echo "=> Limpiando rutas..."
# Rutas que añade 04b
route -n delete -net 0.0.0.0/1 2>/dev/null || true
route -n delete -net 128.0.0.0/1 2>/dev/null || true

# Rutas /32 al VPS por cada interfaz
if [[ -n "${VPS_IP:-}" ]]; then
    route -n delete -host "${VPS_IP}" 2>/dev/null || true
    for iface in "${IFACE_IPHONE:-en8}" "${IFACE_PIXEL:-en12}" "${IFACE_WIFI:-en0}"; do
        route -n delete -host "${VPS_IP}" -ifscope "${iface}" 2>/dev/null || true
    done
fi

echo "=> Limpiando ubond_active.conf..."
rm -f "${GENERATED_DIR}/ubond_active.conf" 2>/dev/null || true

echo ""
if pgrep -f "ubond: ubond0" >/dev/null 2>&1; then
    echo "✗ AVISO: quedan procesos ubond vivos:"
    pgrep -lf "ubond: ubond0" | sed 's/^/    /'
else
    echo "✓ ubond parado (todas las instancias)"
fi

# Verificar que la conexión vuelve a funcionar
echo "=> Verificando conectividad externa..."
if ping -c 1 -t 2 8.8.8.8 >/dev/null 2>&1; then
    echo "✓ Internet restaurado"
else
    echo "✗ AVISO: ping a 8.8.8.8 sigue fallando"
    echo "  Comprueba rutas: netstat -rn -f inet | head -20"
fi
