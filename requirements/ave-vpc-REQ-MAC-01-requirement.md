### ave-vpc.REQ-MAC-01 - Workaround de sudo sin TTY en Macs Jamf/MDM

**Description:**

En Macs gestionados con Jamf/MDM (caso del Mac corporativo Roche del
usuario), el binario `sudo` invocado sin TTY (por ejemplo, desde
Claude Code) falla al pedir password. Para los scripts de
`04-conectar.sh` y `05-desconectar.sh`, que requieren sudo, el
proyecto provee un helper askpass que muestra un diálogo gráfico
nativo de macOS.

**Parent Requirement:** ave-vpc.REQ-SW-01

**Acceptance Criteria:**

- `03-setup-mac.sh` crea `/tmp/sudo-askpass.sh` con permisos `700`.
- El helper invoca `osascript` para mostrar un diálogo nativo macOS
  con campo de password oculto.
- `SUDO_ASKPASS=/tmp/sudo-askpass.sh sudo -A ./04-conectar.sh`
  funciona desde un entorno sin TTY.
