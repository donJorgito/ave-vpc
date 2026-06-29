### ave-vpc.REQ-NET-26 - Watchdog ubond v2 con auto-recovery + visibilidad

**Description:**

El cliente ubond v2 debe disponer de detección automática de pérdida de
túnel y auto-recuperación sin intervención humana. Antes de este RQ, el
incidente AVE 2026-06-01 mostró que con replicación selectiva activa la
red caía silenciosamente y el usuario tenía que ejecutar `SOS.sh` a mano
para restaurar conectividad.

Componentes del RQ:

1. **`tools/ubond-watchdog.sh`** — daemon en background que vigila tres
   señales de salud:
   - `pgrep -f "ubond: "` → si no hay procesos, túnel muerto.
   - `ping -c1 -t2 ${UBOND_TUN_VPS_IP}` cada 5s → si falla 4 veces
     seguidas (~20s), gateway interno inalcanzable.
   - `${GENERATED_DIR}/ubond_unhealthy` flag-file → señal del
     statuscommand cuando emite `rtun_down`/`tuntap_down`.

   Tras umbral, invoca `SOS.sh` para limpieza completa + notificación
   `osascript`. Cooldown 60s entre invocaciones SOS para evitar spam.

2. **04b-conectar-ubond.sh** — modificaciones de visibilidad y arranque
   del watchdog:
   - Pasar `--debug --verbose` al binario ubond. Sin esto, ubond escribe
     a syslog y macOS unified log filtra `log_info` por nivel — el
     `generated/ubond.log` quedaba en 0 bytes (verificado en incidente).
   - Capturar el PID real del binario via `pgrep -f "ubond: ubond0
     [priv]"`, no `$!` que es del subshell `tee`.
   - Arrancar `tools/ubond-watchdog.sh` en background tras configurar
     el utun.

3. **05b-desconectar-ubond.sh** — matar el watchdog ANTES que ubond.
   Si se mata ubond primero, el watchdog detecta "proceso ausente" y
   dispara SOS, doble-cleanup innecesario.

4. **SOS.sh** — matar el watchdog y limpiar `ubond_unhealthy` flag.

5. **`generated/ubond_updown_mac.sh`** (regenerado por 03b) — log a
   `/tmp/ubond_updown.log` (separado de mlvpn), y en
   `rtun_down`/`tuntap_down` toca `generated/ubond_unhealthy` para
   que el watchdog reaccione antes que el ping timeout.

**Parent Requirement:** ave-vpc.REQ-NET-22 (cliente ubond).

**Why:** Incidente trayecto AVE 2026-06-01: dos pérdidas totales de
conectividad en sesión real, ambas requiriendo `bash SOS.sh` manual.
Análisis post-mortem (3 agentes en paralelo + verificador independiente)
identificó:

- Cero watchdog activo en v2 (el de v1, `seleccionar-mejor-enlace.sh`,
  solo conoce mlvpn).
- `04b` lanzaba ubond sin `--debug`, log file en 0 bytes →
  diagnóstico ciego.
- PID file capturaba subshell `tee`, no binario ubond.
- Statuscommand recibía eventos `rtun_down` pero no actuaba.

Sin este RQ, cualquier fallo de v2 (sea por bug en código C, sea por
condiciones de red) deja al usuario en estado degradado hasta que él
mismo lo detecta. Para uso real en AVE eso es inaceptable.

**Acceptance Criteria:**

- `tools/ubond-watchdog.sh` existe, ejecutable, pasa `bash -n` y
  `shellcheck`.
- Implementa detección por 3 vías (pgrep, ping, flag-file).
- Invoca `SOS.sh` con cooldown configurable.
- Notificación nativa macOS via osascript.
- `04b-conectar-ubond.sh` lanza ubond con `--debug --verbose` y captura
  PID real (no del tee).
- `04b` arranca el watchdog tras configurar el utun.
- `05b-desconectar-ubond.sh` mata el watchdog ANTES que ubond.
- `SOS.sh` mata el watchdog (`pkill -9 -f tools/ubond-watchdog.sh`)
  y limpia `ubond_unhealthy`.
- `03b-setup-mac-ubond.sh` genera `ubond_updown_mac.sh` propio (no
  copia del de mlvpn) con:
  - Log path `/tmp/ubond_updown.log`.
  - Tocar `ubond_unhealthy` en `rtun_down` y `tuntap_down`.
  - Limpiar `ubond_unhealthy` en `tuntap_up`.

**Verification:** test estático `test_REQ-NET-26_watchdog.sh`. La
validación runtime requiere reproducir el incidente AVE — pendiente
para próximo trayecto.

**Related:**

- [[REQ-NET-22]] — cliente ubond.
- [[REQ-NET-23]] — smoke-test (diferente: on-demand vs continuous).
- [[REQ-NET-25]] — per-link tolerences.
- `docs/v2-ubond/06-trayecto-2026-06-01.md` — incidente que motivó
  este RQ.
