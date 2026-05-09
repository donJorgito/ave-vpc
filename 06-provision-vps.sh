#!/bin/bash
# 06-provision-vps.sh
# Intenta crear la VM en Oracle Cloud con Terraform.
# Diseñado para ejecutarse como cron hasta que haya capacidad disponible.
#
# Uso manual:   ./06-provision-vps.sh
# Setup cron:   ./06-provision-vps.sh --setup-cron
# Quitar cron:  ./06-provision-vps.sh --remove-cron

set -euo pipefail

# PATH completo para que cron encuentre terraform y ssh
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="$SCRIPT_DIR/terraform"
LOG_FILE="$SCRIPT_DIR/generated/provision.log"
CRON_MARKER="ave-vpc-provision"

mkdir -p "$SCRIPT_DIR/generated"

# Rota el log si supera 500KB para no llenar el disco
if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE")" -gt 512000 ]; then
  mv "$LOG_FILE" "${LOG_FILE}.old"
fi

log() {
  local msg
  msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg" >> "$LOG_FILE"
  # Muestra en terminal si es sesión interactiva
  [ -t 1 ] && echo "$msg"
  return 0
}

notify() {
  # Notificación macOS si está disponible
  osascript -e "display notification \"$1\" with title \"AVE-VPC\"" 2>/dev/null || true
}

# ─── Gestión del cron ─────────────────────────────────────────────────────────

setup_cron() {
  local script_path="$SCRIPT_DIR/06-provision-vps.sh"
  local cron_line="7 * * * * $script_path >> $LOG_FILE 2>&1 # $CRON_MARKER"
  if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
    echo "El cron ya está configurado."
  else
    (crontab -l 2>/dev/null; echo "$cron_line") | crontab -
    echo "Cron configurado: se ejecutará cada hora a las :07."
    echo "Log: $LOG_FILE"
    echo "Para quitarlo: $script_path --remove-cron"
  fi
}

remove_cron() {
  (crontab -l 2>/dev/null | grep -v "$CRON_MARKER") | crontab -
  echo "Cron eliminado."
}

# ─── Argumentos ───────────────────────────────────────────────────────────────

case "${1:-}" in
  --setup-cron)  setup_cron; exit 0 ;;
  --remove-cron) remove_cron; exit 0 ;;
esac

# Jitter aleatorio: espera 0-600 segundos (±5 min) antes de lanzar
# Evita un patrón fijo que Oracle podría detectar como automatismo
# Para saltarse el jitter en tests: NO_JITTER=1 ./06-provision-vps.sh
if [ "${NO_JITTER:-0}" = "1" ]; then
  log "Jitter desactivado (modo test)"
else
  JITTER=$((RANDOM % 601))
  log "Jitter: esperando ${JITTER}s antes de intentar..."
  sleep "$JITTER"
fi

# ─── Salvaguarda: solo shapes Always Free ─────────────────────────────────────
# Si el shape en terraform.tfvars no es uno de los dos shapes Always Free,
# el script se niega a ejecutar para evitar costes accidentales.

ALLOWED_SHAPES="VM.Standard.A1.Flex VM.Standard.E2.1.Micro"
CURRENT_SHAPE=$(grep -E '^\s*shape\s*=' "$TF_DIR/terraform.tfvars" 2>/dev/null | sed 's/.*=\s*"\(.*\)"/\1/' || echo "")
# Si no hay shape en tfvars, se usa el default del variables.tf (A1.Flex) → OK
if [ -n "$CURRENT_SHAPE" ] && ! echo "$ALLOWED_SHAPES" | grep -qw "$CURRENT_SHAPE"; then
  echo "ERROR DE SEGURIDAD: shape '$CURRENT_SHAPE' no es Always Free. Script detenido."
  echo "Shapes permitidos: $ALLOWED_SHAPES"
  exit 1
fi

# Si la VM ya existe en el state de Terraform, no hace falta seguir
if [ -f "$TF_DIR/terraform.tfstate" ]; then
  EXISTING=$(grep -c '"type": "oci_core_instance"' "$TF_DIR/terraform.tfstate" 2>/dev/null; true)
  if [ "${EXISTING:-0}" -gt 0 ] 2>/dev/null; then
    echo "La VM ya existe en el state de Terraform. Nada que hacer."
    remove_cron
    exit 0
  fi
fi

# ─── Verificaciones previas ───────────────────────────────────────────────────

if ! command -v terraform &>/dev/null; then
  log "ERROR: terraform no está instalado. Ejecuta: brew install terraform"
  exit 1
fi

if [ ! -f "$HOME/.oci/config" ]; then
  log "ERROR: ~/.oci/config no existe. Consulta docs/oracle-cloud-setup.md"
  exit 1
fi

if [ ! -f "$TF_DIR/terraform.tfvars" ]; then
  log "ERROR: terraform/terraform.tfvars no existe. Copia terraform.tfvars.example y rellénalo."
  exit 1
fi

# ─── Terraform ────────────────────────────────────────────────────────────────

cd "$TF_DIR"

# Init solo si hace falta
if [ ! -d ".terraform" ]; then
  log "Ejecutando terraform init..."
  terraform init -input=false >> "$LOG_FILE" 2>&1
fi

log "=== Intento de provisión ==="

if terraform apply -auto-approve -input=false >> "$LOG_FILE" 2>&1; then
  IP=$(terraform output -raw public_ip 2>/dev/null || echo "")
  log "✓ VM creada con éxito. IP pública: $IP"

  # Actualiza config/env con la IP del VPS
  ENV_FILE="$SCRIPT_DIR/config/env"
  if [ -n "$IP" ]; then
    # Crea config/env desde el ejemplo si no existe
    if [ ! -f "$ENV_FILE" ]; then
      cp "$SCRIPT_DIR/config/env.example" "$ENV_FILE"
      log "✓ config/env creado desde env.example"
    fi
    sed -i '' "s/^VPS_IP=.*/VPS_IP=\"$IP\"/" "$ENV_FILE"
    log "✓ config/env actualizado con VPS_IP=$IP"
    log "  ⚠ Revisa IFACE_IPHONE e IFACE_PIXEL en config/env (dependen de tu Mac)"
  fi

  # Notificación macOS (aparece aunque el Mac esté bloqueado)
  notify "¡VM creada! IP: $IP — Ejecuta ./02-setup-vps.sh"

  # Banner en el log para que sea inconfundible
  log ""
  log "╔══════════════════════════════════════════════╗"
  log "║  ✓  VM CREADA CON ÉXITO                      ║"
  log "║  IP: $IP"
  log "║  Siguiente paso: ./02-setup-vps.sh            ║"
  log "╚══════════════════════════════════════════════╝"
  log ""

  # Elimina el cron automáticamente
  remove_cron
  log "✓ Cron eliminado (ya no hace falta reintentar)"

else
  # Terraform falla por "Out of capacity" u otro error transitorio
  EXIT_CODE=${PIPESTATUS[0]}
  log "✗ Fallo (código $EXIT_CODE) — se reintentará en el próximo cron"
  # Salimos con 0 para que cron no lo marque como error permanente
  exit 0
fi
