#!/usr/bin/env bash
# check_env_example.sh — verifica que config/env.example tiene todas las
# variables que el resto de scripts esperan. Se invoca desde CI.
set -euo pipefail

REQUIRED=(
    VPS_IP VPS_USER VPS_SSH_PORT
    MLVPN_PORT_1 MLVPN_PORT_2 MLVPN_PORT_3
    TUN_VPS_IP TUN_MAC_IP TUN_MTU
    IFACE_IPHONE IFACE_PIXEL IFACE_WIFI
)

fail=0
for var in "${REQUIRED[@]}"; do
    if grep -q "^${var}=" config/env.example; then
        echo "✓ ${var}"
    else
        echo "ERROR: ${var} no está en config/env.example"
        fail=1
    fi
done
exit "${fail}"
