#!/usr/bin/env bash
###############################################################################
# 00-detectar-interfaces.sh
#
# Detecta automáticamente las interfaces de red del iPhone (hotspot WiFi)
# y del Pixel (tethering USB) y actualiza config/env.
#
# Uso:
#   1. Conecta el Pixel por USB y activa su tethering
#   2. Conecta al hotspot WiFi del iPhone
#   3. Ejecuta este script
#   4. Verifica que config/env tiene los valores correctos
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/config/env"

# ─── Colores ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  ✓ $*${NC}"; }
warn() { echo -e "${YELLOW}  ⚠ $*${NC}"; }
fail() { echo -e "${RED}  ✗ $*${NC}"; }

echo ""
echo "=== Detectando interfaces de red ==="
echo ""

# ─── 1. Interfaz WiFi (iPhone hotspot) ───────────────────────────────────────
# La interfaz WiFi del Mac es siempre la marcada como "Wi-Fi" en networksetup

IFACE_WIFI=$(networksetup -listallhardwareports \
  | awk '/Wi-Fi|AirPort/{found=1} found && /Device:/{print $2; exit}')

if [[ -n "${IFACE_WIFI}" ]]; then
  ok "Interfaz WiFi encontrada: ${IFACE_WIFI}"
  # Verificar si está activa (tiene IP asignada)
  if ifconfig "${IFACE_WIFI}" 2>/dev/null | grep -q "inet "; then
    IP_WIFI=$(ifconfig "${IFACE_WIFI}" | awk '/inet /{print $2}')
    ok "  WiFi activa con IP: ${IP_WIFI}"
  else
    warn "  WiFi (${IFACE_WIFI}) sin IP — ¿está conectada al hotspot del iPhone?"
  fi
else
  fail "No se encontró interfaz WiFi. ¿Tiene WiFi este Mac?"
  IFACE_WIFI="en0"
  warn "Usando valor por defecto: en0"
fi

echo ""

# ─── 2. Interfaz USB Pixel (Android tethering) ───────────────────────────────
# Android USB tethering asigna una IP en el rango 192.168.42.x al Mac.
# También puede aparecer como 192.168.43.x en algunos modelos.
# El nombre del hardware port suele contener "Android", "RNDIS" o "Google".

IFACE_USB=""

# Método 1: buscar por IP de Android tethering (192.168.42.x o 192.168.43.x)
while IFS= read -r iface; do
  ip=$(ifconfig "${iface}" 2>/dev/null | awk '/inet /{print $2}')
  if [[ "${ip}" =~ ^192\.168\.4[23]\. ]]; then
    IFACE_USB="${iface}"
    ok "Pixel encontrado por IP Android (${ip}): ${IFACE_USB}"
    break
  fi
done < <(ifconfig -l | tr ' ' '\n')

# Método 2: buscar por nombre del hardware port
if [[ -z "${IFACE_USB}" ]]; then
  IFACE_USB=$(networksetup -listallhardwareports \
    | grep -i -A1 "Android\|RNDIS\|Google\|USB Ethernet\|Tethering" \
    | awk '/Device:/{print $2}' | head -1)
  if [[ -n "${IFACE_USB}" ]]; then
    ok "Pixel encontrado por nombre de hardware: ${IFACE_USB}"
  fi
fi

# Método 3: buscar interfaces USB activas que no sean WiFi ni Bluetooth
if [[ -z "${IFACE_USB}" ]]; then
  warn "No se encontró el Pixel automáticamente."
  echo ""
  echo "  Interfaces de red disponibles en tu Mac:"
  networksetup -listallhardwareports | awk '
    /Hardware Port:/ { port=$0 }
    /Device:/        { print "    " $2 " → " port }
  ' | sed 's/Hardware Port: //'
  echo ""
  echo -n "  Introduce manualmente la interfaz del Pixel (o Enter para saltar): "
  read -r IFACE_USB
fi

if [[ -z "${IFACE_USB}" ]]; then
  warn "Sin interfaz Pixel — deberás ajustarla en config/env antes de conectar"
  IFACE_USB="en5"
  warn "Usando valor por defecto: en5"
else
  ok "Interfaz Pixel: ${IFACE_USB}"
fi

echo ""

# ─── 3. Actualizar config/env ─────────────────────────────────────────────────

if [[ ! -f "${ENV_FILE}" ]]; then
  warn "config/env no existe — copiando desde env.example"
  cp "${SCRIPT_DIR}/config/env.example" "${ENV_FILE}"
fi

# Actualizar IFACE_IPHONE
sed -i '' "s|^IFACE_IPHONE=.*|IFACE_IPHONE=\"${IFACE_WIFI}\"|" "${ENV_FILE}"
# Actualizar IFACE_PIXEL
sed -i '' "s|^IFACE_PIXEL=.*|IFACE_PIXEL=\"${IFACE_USB}\"|" "${ENV_FILE}"

echo "=== config/env actualizado ==="
echo ""
grep "^IFACE_" "${ENV_FILE}"
echo ""
ok "Listo. Puedes ejecutar ./04-conectar.sh cuando estés en el tren."
echo ""
