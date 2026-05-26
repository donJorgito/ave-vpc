### ave-vpc.REQ-NET-13 - Reintegración del WiFi tras autenticar captive portal

**Description:**

Cuando el usuario lanza `04-conectar.sh` antes de autenticar el captive
portal del WiFi (típico al subir a un AVE: conectas WiFi → tienes IP →
lanzas el túnel; el captive sigue sin autenticar), el pre-flight check
falla y el WiFi queda fuera del bonding **permanentemente** hasta
desconectar y reconectar todo el túnel — incómodo y disruptivo.

Caso real validado 2026-05-25: usuario lanzó `04-conectar.sh
--failover` al sentarse en el tren, captive del AVE no autenticado
todavía, WiFi descartada del bonding. Después autenticó el captive en
el navegador (la WiFi pasó a ser usable directamente para HTTP/TCP),
pero el túnel mlvpn nunca volvió a evaluar el WiFi y siguió sin él.

`tools/wifi-reintegrator.sh` corre como watcher en background
(lanzado por `04-conectar.sh` solo cuando se cumplen las condiciones
de "reintegración pendiente": WiFi tiene IP, no `--sin-wifi`, no pasó
pre-flight inicial). Cada 30 s reintenta los pre-flight; si pasan,
añade dinámicamente el bloque `[links.wifi]` al `mlvpn_active.conf` y
manda `SIGHUP` a `mlvpn [priv]` para que recargue la config y abra el
nuevo socket sin tirar el túnel. Mismo mecanismo que REQ-NET-07.

**Coste en datos:** 1 curl HTTP a `captive.apple.com` (~200 B) + 3
curls a servicios de IP pública (~100 B c/u) cada 30 s ≈ 80 KB/h.
Despreciable. El watcher se para automáticamente cuando detecta que
`[links.wifi]` ya está en config (no sigue pingando indefinidamente).

**Parent Requirement:** ave-vpc.REQ-NET-06

**Acceptance Criteria:**

- `tools/wifi-reintegrator.sh` existe, es ejecutable, pasa `bash -n`
  y `shellcheck`.
- Detecta el modo `--failover` consultando si algún otro link tiene
  `fallback_only = 1` en `mlvpn_active.conf`. Si sí, añade también
  `fallback_only = 1` al bloque `[links.wifi]` que escribe (para no
  romper el modelo "1 activo, demás backup" de REQ-NET-11).
- Las funciones de comprobación (`get_public_ip_via_iface`,
  `resolve_vps_public_ip`, `wifi_passes_preflight`) son
  semánticamente equivalentes a las de `04-conectar.sh` (captive
  portal, IP pública vs DDNS RPi).
- El watcher detiene su loop si `[links.wifi]` ya está en
  `mlvpn_active.conf` (no spam de checks innecesarios).
- Cuando todos los pre-flight pasan, escribe el bloque
  `[links.wifi]` con `bandwidth_upload = 50000000` y `timeout = 8`
  per-link (mismos valores que el bloque inicial).
- Tras escribir el config, manda `SIGHUP` al proceso `mlvpn [priv]`
  encontrado por `pgrep -f`. Si no hay proceso vivo, loguea AVISO
  pero no aborta.
- Logs en syslog con tag `mlvpn-wifi-reintegrator` (igual convención
  que el resto de watchers).
- `04-conectar.sh` lanza el reintegrator solo cuando:
  - `--sin-wifi` NO está activo
  - `IP_WIFI` no está vacío (hay IP en `IFACE_WIFI`)
  - `WIFI_ELIGIBLE` es false (no entró al bonding inicial)
- `05-desconectar.sh` y `SOS.sh` matan el reintegrator con
  `pkill -9 -f "wifi-reintegrator"` antes que mlvpn (orden
  importante: si está reescribiendo config en mitad del shutdown
  puede dejar config corrupta).
- PID en `generated/mlvpn_wifi_reintegrator.pid`. `trap EXIT` lo
  limpia.
