#!/usr/bin/env bash
###############################################################################
# SOS.sh — Script de emergencia para restaurar la red
#
# CUANDO USARLO:
#   Si despues de usar mlvpn te quedas sin internet y 05-desconectar.sh
#   no funciona o no lo encuentras. Este script no necesita internet,
#   no necesita config/env, no necesita nada. Solo ejecutalo.
#
# COMO EJECUTARLO:
#   Si tienes terminal abierta:
#     bash ~/projects/ave-vpc/SOS.sh
#
#   Si no recuerdas el path:
#     bash -c 'sudo route -n delete -net 0.0.0.0/1; sudo route -n delete -net 128.0.0.0/1; sudo pkill mlvpn'
#
#   Si ni siquiera el terminal responde:
#     1. Reinicia el Mac (todas las rutas son in-memory, desaparecen)
#     2. Si no quieres reiniciar: apaga Wi-Fi desde el icono del menu
#        y vuelvelo a encender. Eso restaura la ruta por defecto.
#
###############################################################################

echo "=== SOS: Restaurando red ==="
echo ""

# Paso 1: Matar mlvpn (el proceso que secuestra el trafico)
echo "[1/4] Matando mlvpn..."
sudo pkill -9 mlvpn 2>/dev/null && echo "  -> mlvpn matado" || echo "  -> no habia mlvpn"

# Paso 2: Eliminar las rutas que capturan todo el trafico
# mlvpn pone dos rutas /1 que "tapan" la ruta por defecto:
#   0.0.0.0/1     -> tunel (captura la mitad inferior de internet)
#   128.0.0.0/1   -> tunel (captura la mitad superior de internet)
# Sin estas rutas, la ruta por defecto original vuelve a funcionar.
echo "[2/4] Eliminando rutas del tunel..."
sudo route -n delete -net 0.0.0.0/1 2>/dev/null && echo "  -> ruta 0.0.0.0/1 eliminada" || echo "  -> no existia"
sudo route -n delete -net 128.0.0.0/1 2>/dev/null && echo "  -> ruta 128.0.0.0/1 eliminada" || echo "  -> no existia"

# Paso 3: Eliminar ruta especifica al VPS (si existe)
# Busca cualquier ruta /32 que no sea localhost y la elimina
echo "[3/4] Eliminando rutas especificas..."
netstat -rn -f inet | awk '$3 ~ /UH/ && $1 !~ /^127/ {print $1}' | while read -r host; do
    sudo route -n delete -host "${host}" 2>/dev/null && echo "  -> ruta a ${host} eliminada"
done

# Paso 4: Verificar que hay internet
echo "[4/4] Verificando conexion..."
if ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
    echo "  -> Internet OK"
else
    echo "  -> Sin internet. Prueba:"
    echo "     1. Apaga y enciende Wi-Fi desde el icono del menu"
    echo "     2. Si no funciona, reinicia el Mac"
fi

echo ""
echo "=== Listo ==="
