#!/bin/bash
# ensure-askpass.sh — recrea /tmp/sudo-askpass.sh si falta (idempotente).
#
# Por qué: el helper vive en /tmp, que macOS purga al reiniciar. Los scripts
# de conexión (04-conectar.sh, 04b-conectar-ubond.sh, SOS.sh, ...) se invocan
# vía `SUDO_ASKPASS=/tmp/sudo-askpass.sh sudo -A`, así que el archivo debe
# existir ANTES de llamarlos — no pueden auto-repararse desde dentro.
#
# Uso:
#   ./tools/ensure-askpass.sh && SUDO_ASKPASS=/tmp/sudo-askpass.sh sudo -A ./04b-conectar-ubond.sh --sin-wifi
#
# Salida: imprime la ruta del askpass en stdout para poder encadenar:
#   SUDO_ASKPASS="$(./tools/ensure-askpass.sh)" sudo -A ...
set -euo pipefail

ASKPASS_SCRIPT="/tmp/sudo-askpass.sh"

if [[ ! -x "${ASKPASS_SCRIPT}" ]]; then
    cat > "${ASKPASS_SCRIPT}" << 'ASKPASS'
#!/bin/bash
osascript -e 'Tell application "System Events" to display dialog "Contraseña sudo (ave-vpc):" with hidden answer default answer ""' -e 'text returned of result'
ASKPASS
    chmod 700 "${ASKPASS_SCRIPT}"
    echo "=> sudo askpass recreado: ${ASKPASS_SCRIPT}" >&2
else
    echo "=> sudo askpass ya existe: ${ASKPASS_SCRIPT}" >&2
fi

echo "${ASKPASS_SCRIPT}"
