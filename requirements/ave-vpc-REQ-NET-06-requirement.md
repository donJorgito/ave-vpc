### ave-vpc.REQ-NET-06 - Tercer enlace WiFi con pre-flight checks

**Description:**

El script `04-conectar.sh` debe evaluar automáticamente la WiFi del
Mac (`IFACE_WIFI`) en cada arranque y añadirla al bonding mlvpn como
tercer enlace UDP en `MLVPN_PORT_3` solo si pasa los pre-flight
checks: tener IP asignada, no estar tras un captive portal y no estar
saliendo por el mismo NAT que la RPi (ver REQ-NET-08 para los detalles
de la detección de "red de casa" por IP pública). El usuario puede
forzar la exclusión con la bandera `--sin-wifi`.

**Parent Requirement:** ave-vpc.REQ-NET-05

**Acceptance Criteria:**

- Si el WiFi no tiene IP, el script sigue con los móviles sin error.
- La detección de "red de casa" se realiza comparando la IP pública
  saliendo por `IFACE_WIFI` con la IP pública del DDNS de la RPi
  (REQ-NET-08); si coinciden, el WiFi se omite con aviso.
- Si HTTP a `captive.apple.com/hotspot-detect.html` no devuelve
  `<TITLE>Success</TITLE>`, el WiFi se omite con aviso de captive.
- El flag `--sin-wifi` salta el WiFi independientemente de los
  checks.
- Si el WiFi pasa los checks pero el UDP está bloqueado, mlvpn deja
  `links.wifi` en `AUTH_PENDING` (visible en `08-monitor.py`) sin
  romper los otros enlaces.
