#!/usr/bin/env bash
###############################################################################
# 00-detectar-interfaces.sh
#
# Detecta automáticamente las interfaces de red de:
#   - iPhone (Personal Hotspot por USB)  → IP DHCP 172.20.10.x
#   - Pixel  (USB tethering Android)     → IP DHCP 192.168.42.x / 192.168.43.x
#   - Wi-Fi nativa del Mac (3er enlace)  → la marcada como "Wi-Fi" en networksetup
#
# Y actualiza config/env con IFACE_IPHONE, IFACE_PIXEL e IFACE_WIFI.
#
# Uso:
#   1. Conecta el iPhone por USB y activa "Compartir Internet" (USB)
#   2. Conecta el Pixel por USB y activa "Anclaje USB"
#   3. Ejecuta este script
#   4. Verifica que config/env tiene los valores correctos
#
# El Wi-Fi del Mac no necesita estar conectado a nada para detectarlo;
# 04-conectar.sh evalúa en runtime si es elegible como 3er enlace.
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

# ─── 1. Interfaz USB iPhone (Personal Hotspot por cable) ─────────────────────
# El iPhone con "Compartir Internet" activo y conectado por USB asigna al Mac
# una IP en el rango 172.20.10.x (siempre, independientemente del operador).

IFACE_IPHONE_DETECTED=""
while IFS= read -r iface; do
  ip=$(ifconfig "${iface}" 2>/dev/null | awk '/inet /{print $2}')
  if [[ "${ip}" =~ ^172\.20\.10\. ]]; then
    IFACE_IPHONE_DETECTED="${iface}"
    ok "iPhone encontrado por IP Personal Hotspot (${ip}): ${IFACE_IPHONE_DETECTED}"
    break
  fi
done < <(ifconfig -l | tr ' ' '\n')

if [[ -z "${IFACE_IPHONE_DETECTED}" ]]; then
  warn "iPhone no detectado por IP."
  echo "    Verifica:"
  echo "      - Cable USB de datos conectado (no solo de carga)"
  echo "      - Personal Hotspot activo en el iPhone"
  echo "      - 'Confiar en este ordenador' aceptado en el iPhone"
  echo ""
  echo -n "    Introduce manualmente la interfaz del iPhone (Enter para 'en8'): "
  read -r IFACE_IPHONE_DETECTED
  IFACE_IPHONE_DETECTED="${IFACE_IPHONE_DETECTED:-en8}"
  warn "Usando: ${IFACE_IPHONE_DETECTED}"
fi

echo ""

# ─── 2. Interfaz USB Pixel (Android tethering) ───────────────────────────────
# Android USB tethering asigna al Mac una IP en 192.168.42.x o 192.168.43.x.

IFACE_PIXEL_DETECTED=""
while IFS= read -r iface; do
  # No queremos volver a coger la del iPhone aunque por error coincida
  [[ "${iface}" == "${IFACE_IPHONE_DETECTED}" ]] && continue
  ip=$(ifconfig "${iface}" 2>/dev/null | awk '/inet /{print $2}')
  if [[ "${ip}" =~ ^192\.168\.4[23]\. ]]; then
    IFACE_PIXEL_DETECTED="${iface}"
    ok "Pixel encontrado por IP Android (${ip}): ${IFACE_PIXEL_DETECTED}"
    break
  fi
done < <(ifconfig -l | tr ' ' '\n')

if [[ -z "${IFACE_PIXEL_DETECTED}" ]]; then
  warn "Pixel no detectado por IP. Listado de hardware ports:"
  echo ""
  networksetup -listallhardwareports | awk '
    /Hardware Port:/ { port=$0 }
    /Device:/        { print "    " $2 " → " port }
  ' | sed 's/Hardware Port: //'
  echo ""
  echo -n "    Introduce manualmente la interfaz del Pixel (Enter para 'en12'): "
  read -r IFACE_PIXEL_DETECTED
  IFACE_PIXEL_DETECTED="${IFACE_PIXEL_DETECTED:-en12}"
  warn "Usando: ${IFACE_PIXEL_DETECTED}"
fi

echo ""

# ─── 3. Interfaz Wi-Fi del Mac (3er enlace opcional) ─────────────────────────
# La interfaz Wi-Fi del Mac es siempre la marcada como "Wi-Fi" en networksetup.
# 04-conectar.sh decide en runtime si es elegible (sin IP / red de casa /
# captive portal → se omite sin romper el bonding).

IFACE_WIFI_DETECTED=$(networksetup -listallhardwareports \
  | awk '/Wi-Fi|AirPort/{found=1} found && /Device:/{print $2; exit}')

if [[ -n "${IFACE_WIFI_DETECTED}" ]]; then
  ok "Wi-Fi del Mac (3er enlace opcional): ${IFACE_WIFI_DETECTED}"
  if ifconfig "${IFACE_WIFI_DETECTED}" 2>/dev/null | grep -q "inet "; then
    IP_WIFI=$(ifconfig "${IFACE_WIFI_DETECTED}" | awk '/inet /{print $2}')
    ok "  Wi-Fi conectada con IP: ${IP_WIFI}"
  else
    warn "  Wi-Fi sin IP — normal si no estás en una red ahora; se evalúa en runtime"
  fi
else
  fail "No se encontró interfaz Wi-Fi en este Mac"
  IFACE_WIFI_DETECTED="en0"
  warn "Usando valor por defecto: en0"
fi

echo ""

# ─── 4. Actualizar config/env ─────────────────────────────────────────────────

if [[ ! -f "${ENV_FILE}" ]]; then
  warn "config/env no existe — copiando desde env.example"
  cp "${SCRIPT_DIR}/config/env.example" "${ENV_FILE}"
fi

sed -i '' "s|^IFACE_IPHONE=.*|IFACE_IPHONE=\"${IFACE_IPHONE_DETECTED}\"|" "${ENV_FILE}"
sed -i '' "s|^IFACE_PIXEL=.*|IFACE_PIXEL=\"${IFACE_PIXEL_DETECTED}\"|" "${ENV_FILE}"
sed -i '' "s|^IFACE_WIFI=.*|IFACE_WIFI=\"${IFACE_WIFI_DETECTED}\"|" "${ENV_FILE}"

echo "=== config/env actualizado ==="
echo ""
grep "^IFACE_" "${ENV_FILE}"
echo ""
ok "Listo. Puedes ejecutar ./04-conectar.sh cuando estés en el tren."
echo ""
