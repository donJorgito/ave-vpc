#!/usr/bin/env bash
###############################################################################
# 01-generar-secreto.sh
#
# DONDE SE EJECUTA: En tu Mac
#
# QUE HACE:
#   Genera un secreto compartido (password) que mlvpn usa para cifrar
#   el tunel entre el Mac y el VPS.
#
# COMO FUNCIONA LA AUTENTICACION DE MLVPN:
#   A diferencia de WireGuard (que usa pares de claves publica/privada),
#   mlvpn usa un secreto compartido (shared secret). Ambos extremos
#   conocen el mismo secreto y lo usan para cifrar con ChaCha20-Poly1305
#   (via libsodium). Es seguro siempre que el secreto sea largo y aleatorio.
#
# QUE ES MLVPN:
#   mlvpn (Multi-Link VPN) es un software que crea un tunel VPN que puede
#   usar MULTIPLES conexiones de red a la vez. A diferencia de WireGuard
#   (que usa una sola conexion), mlvpn abre un socket UDP por cada interfaz
#   de red y reparte los paquetes entre todas. Resultado: bonding real,
#   no solo failover.
#
# QUE GENERA:
#   keys/
#   └── mlvpn.secret     <- El secreto compartido (64 chars aleatorios)
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_DIR="${SCRIPT_DIR}/keys"

# --- Paso 1: Crear directorio con permisos restrictivos ---
mkdir -p "${KEYS_DIR}"
chmod 700 "${KEYS_DIR}"

# --- Paso 2: Generar secreto aleatorio ---
# openssl rand: genera bytes aleatorios criptograficamente seguros
# -hex 32: 32 bytes = 64 caracteres hexadecimales
echo "=> Generando secreto compartido para mlvpn..."
openssl rand -hex 32 > "${KEYS_DIR}/mlvpn.secret"
chmod 600 "${KEYS_DIR}/mlvpn.secret"

echo ""
echo "=== Secreto generado ==="
echo ""
echo "Archivo: ${KEYS_DIR}/mlvpn.secret"
echo "Longitud: $(wc -c < "${KEYS_DIR}/mlvpn.secret" | tr -d ' ') caracteres"
echo ""
echo "Este secreto se copiara automaticamente al VPS en el paso 02."
echo ""
echo "Siguiente paso: ejecuta 02-setup-vps.sh"
