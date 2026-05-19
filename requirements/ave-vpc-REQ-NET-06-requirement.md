### ave-vpc.REQ-NET-06 - Tercer enlace WiFi con pre-flight checks

**Description:**

El script `04-conectar.sh` debe evaluar automáticamente la WiFi del
Mac (`IFACE_WIFI`) en cada arranque y añadirla al bonding mlvpn como
tercer enlace UDP en `MLVPN_PORT_3` solo si pasa los pre-flight
checks: tener IP asignada, no estar en la subred del RPi (red de
casa), y no estar tras un captive portal. El usuario puede forzar la
exclusión con la bandera `--sin-wifi`.

**Parent Requirement:** ave-vpc.REQ-NET-05

**Acceptance Criteria:**

- Si el WiFi no tiene IP, el script sigue con los móviles sin error.
- Si la IP del Mac está en la subred de `RPi_IP/24` y `RPi_IP`
  responde a ping local, el WiFi se omite con aviso "red de casa".
- Si HTTP a `captive.apple.com/hotspot-detect.html` no devuelve
  `<TITLE>Success</TITLE>`, el WiFi se omite con aviso de captive.
- El flag `--sin-wifi` salta el WiFi independientemente de los
  checks.
- Si el WiFi pasa los checks pero el UDP está bloqueado, mlvpn deja
  `links.wifi` en `AUTH_PENDING` (visible en `08-monitor.py`) sin
  romper los otros enlaces.
