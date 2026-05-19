#!/usr/bin/env bash
# tests/verificar-setup.sh
#
# Verifica que el entorno está correctamente configurado antes del primer uso
# o después de cambios. No modifica nada — solo comprueba.
#
# Uso: ./tests/verificar-setup.sh
# Salida: lista de checks con ✓ / ✗ y código de salida 1 si alguno falla

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${SCRIPT_DIR}/config/env"
KEYS_DIR="${SCRIPT_DIR}/keys"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
FAILED=0

ok()   { echo -e "${GREEN}  ✓ $*${NC}"; }
fail() { echo -e "${RED}  ✗ $*${NC}"; FAILED=1; }
warn() { echo -e "${YELLOW}  ⚠ $*${NC}"; }
section() { echo ""; echo "── $* ──────────────────────────────"; }

# ─── REQ-SW: Herramientas del Mac ────────────────────────────────────────────
section "REQ-SW: Herramientas"

# REQ-SW-02
if xcode-select -p &>/dev/null; then
  ok "REQ-SW-02: Xcode CLT instalado"
else
  fail "REQ-SW-02: Xcode CLT no instalado — ejecuta: xcode-select --install"
fi

# REQ-SW-03
if command -v brew &>/dev/null; then
  ok "REQ-SW-03: Homebrew $(brew --version | head -1)"
else
  fail "REQ-SW-03: Homebrew no instalado — ver https://brew.sh"
fi

# REQ-SW-04
if command -v terraform &>/dev/null; then
  ok "REQ-SW-04: Terraform $(terraform version -json 2>/dev/null | grep -o '"[0-9.]*"' | head -1 || terraform version | head -1)"
else
  fail "REQ-SW-04: Terraform no instalado — brew install terraform"
fi

# REQ-SW-05
if command -v git &>/dev/null; then
  ok "REQ-SW-05: Git $(git --version)"
else
  fail "REQ-SW-05: Git no encontrado"
fi

# REQ-SW-06 / REQ-SW-07
MLVPN_BIN=$(command -v mlvpn 2>/dev/null || echo "/usr/local/sbin/mlvpn")
if [[ -x "${MLVPN_BIN}" ]]; then
  ok "mlvpn instalado: ${MLVPN_BIN}"
else
  warn "mlvpn no instalado — se instalará al ejecutar ./03-setup-mac.sh"
fi

# ─── REQ-NET: Configuración ───────────────────────────────────────────────────
section "Configuración (config/env)"

if [[ -f "${ENV_FILE}" ]]; then
  ok "config/env existe"
  # shellcheck source=/dev/null
  source "${ENV_FILE}"

  [[ -n "${VPS_IP:-}" && "${VPS_IP}" != "203.0.113.50" ]] \
    && ok "VPS_IP configurada: ${VPS_IP}" \
    || fail "VPS_IP no configurada o tiene el valor de ejemplo"

  [[ -n "${VPS_USER:-}" ]] \
    && ok "VPS_USER: ${VPS_USER}" \
    || fail "VPS_USER no configurado"

  [[ -n "${IFACE_IPHONE:-}" ]] \
    && ok "IFACE_IPHONE: ${IFACE_IPHONE}" \
    || warn "IFACE_IPHONE no configurado — ejecuta ./00-detectar-interfaces.sh"

  [[ -n "${IFACE_PIXEL:-}" ]] \
    && ok "IFACE_PIXEL: ${IFACE_PIXEL}" \
    || warn "IFACE_PIXEL no configurado — ejecuta ./00-detectar-interfaces.sh"
else
  fail "config/env no existe — ejecuta: cp config/env.example config/env"
fi

# ─── Secreto mlvpn ───────────────────────────────────────────────────────────
section "Secreto de cifrado"

if [[ -f "${KEYS_DIR}/mlvpn.secret" ]]; then
  PERMS=$(stat -f "%OLp" "${KEYS_DIR}/mlvpn.secret" 2>/dev/null || stat -c "%a" "${KEYS_DIR}/mlvpn.secret" 2>/dev/null)
  ok "keys/mlvpn.secret existe (permisos: ${PERMS})"
  [[ "${PERMS}" == "600" ]] || warn "Permisos deberían ser 600 — ejecuta: chmod 600 keys/mlvpn.secret"
else
  warn "keys/mlvpn.secret no existe — ejecuta: ./01-generar-secreto.sh"
fi

# ─── Conectividad al VPS ─────────────────────────────────────────────────────
section "Conectividad al VPS"

if [[ -n "${VPS_IP:-}" && "${VPS_IP}" != "203.0.113.50" ]]; then
  if ping -c 1 -W 2 "${VPS_IP}" &>/dev/null 2>&1; then
    ok "Ping al VPS (${VPS_IP}): OK"
  else
    fail "No se puede hacer ping al VPS (${VPS_IP})"
  fi

  if ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
       -p "${VPS_SSH_PORT:-22}" "${VPS_USER:-ubuntu}@${VPS_IP}" "exit" &>/dev/null 2>&1; then
    ok "SSH al VPS (puerto ${VPS_SSH_PORT:-22}): OK"
  else
    warn "SSH al VPS: no accesible en puerto ${VPS_SSH_PORT:-22} (normal si aún no configurado)"
  fi
else
  warn "VPS_IP no configurada — omitiendo tests de conectividad"
fi

# ─── Interfaces de red ────────────────────────────────────────────────────────
section "Interfaces de red (REQ-NET)"

if [[ -n "${IFACE_IPHONE:-}" ]]; then
  if ifconfig "${IFACE_IPHONE}" &>/dev/null 2>&1; then
    IP_IF=$(ifconfig "${IFACE_IPHONE}" | awk '/inet /{print $2}')
    [[ -n "${IP_IF}" ]] \
      && ok "IFACE_IPHONE (${IFACE_IPHONE}) activa con IP ${IP_IF}" \
      || warn "IFACE_IPHONE (${IFACE_IPHONE}) existe pero sin IP — ¿está el hotspot activo?"
  else
    warn "IFACE_IPHONE (${IFACE_IPHONE}) no existe — ¿está el hotspot activo?"
  fi
fi

if [[ -n "${IFACE_PIXEL:-}" ]]; then
  if ifconfig "${IFACE_PIXEL}" &>/dev/null 2>&1; then
    IP_PX=$(ifconfig "${IFACE_PIXEL}" | awk '/inet /{print $2}')
    [[ -n "${IP_PX}" ]] \
      && ok "IFACE_PIXEL (${IFACE_PIXEL}) activa con IP ${IP_PX}" \
      || warn "IFACE_PIXEL (${IFACE_PIXEL}) existe pero sin IP — ¿está el tethering activo?"
  else
    warn "IFACE_PIXEL (${IFACE_PIXEL}) no existe — ¿está el Pixel conectado por USB?"
  fi
fi

# IFACE_WIFI es opcional (3er enlace). Si falta o no tiene IP, no es error.
IFACE_WIFI_VAL="${IFACE_WIFI:-en0}"
if ifconfig "${IFACE_WIFI_VAL}" &>/dev/null 2>&1; then
  IP_WF=$(ifconfig "${IFACE_WIFI_VAL}" | awk '/inet /{print $2}')
  if [[ -n "${IP_WF}" ]]; then
    ok "IFACE_WIFI (${IFACE_WIFI_VAL}) activa con IP ${IP_WF} — candidata a 3er enlace"
  else
    warn "IFACE_WIFI (${IFACE_WIFI_VAL}) sin IP — el 3er enlace WiFi se omitirá"
  fi
else
  warn "IFACE_WIFI (${IFACE_WIFI_VAL}) no existe — el 3er enlace WiFi se omitirá"
fi

# ─── Resumen ──────────────────────────────────────────────────────────────────
echo ""
if [[ ${FAILED} -eq 0 ]]; then
  echo -e "${GREEN}✓ Todos los checks obligatorios pasaron.${NC}"
  exit 0
else
  echo -e "${RED}✗ Hay checks fallidos. Revisa los errores arriba.${NC}"
  exit 1
fi
