### ave-vpc.REQ-NET-40 - Watchdog de captive portal + re-login automático estilo wifionice (PlayRenfe / Icomera)

**Status:** Motor genérico implementado y validado con form sintético
(test estático/funcional local). Captura del form REAL PlayRenfe y
validación runtime pendientes próximo trayecto AVE.

**Description:**

El WiFi del AVE lo provee un router onboard Icomera/Nomad con captive
portal PlayRenfe. La sesión autenticada **expira silenciosamente** a
mitad de trayecto (timeout de inactividad, salto de celda del backhaul,
o cuota `dataLimit` ~209MB observada en Icomera). Cuando expira, todo el
tráfico `tcp/80` y `tcp/443` vuelve a ser DNAT-eado al portal — el
transporte que tunela ubond (cualquier vía A-E de
`docs/v2-ubond/13-plan-bypass-wifi-tren.md`) deja de cruzar. Sin un
re-login automático, el operador tendría que reabrir el navegador y
pasar el portal a mano cada vez, mid-trip.

Este REQ aporta un daemon stdlib-only (`tools/captive-watchdog.py`) que:

1. **C1 — Detección de expiración por canary tri-estado.** Cada
   `poll interval` (default 3s, base empírica derhuerst/live-icomera-
   position) hace un HTTP-GET plano a una URL canary y clasifica en
   TRES estados, NO dos:
   - `online`  — el body recibido contiene el token esperado → sesión viva.
   - `offline` — respuesta recibida pero es el portal/redirect (token
     ausente, o redirect al walled garden) → sesión EXPIRADA, re-login.
   - `None`    — la petición falla a nivel de transporte (timeout, sin
     ruta, connection refused) → el WiFi está CAÍDO, **no** expirado.
     En este estado NO se intenta re-login (sería thrashing inútil): se
     registra y se espera al siguiente tick.

   El tri-estado replica el patrón de `db_wlan_manager`
   (`db_wifionice.py:71-85`): solo se cambia el estado cuando la
   comprobación devuelve `True`/`False`; si la comprobación falla por sí
   misma (`_make_request` → `False`/`None`, líneas 51-56) NO se altera
   el estado conocido.

2. **C2 — Re-login estilo wifionice.** Al transitar `online -> offline`:
   - GET de la página del portal (`portal base URL`).
   - Parseo de TODOS los `<input>` del formulario con `html.parser`
     (stdlib), incluidos los hidden como `CSRFToken`, construyendo un
     dict `{name: value}`. Réplica directa de
     `prison-break/.../wifionice.py:49-51`.
   - Re-POST de ese dict (con `login=true` forzado) a la action del form.
     El handshake UAM lo resuelve el servidor; el cliente solo reenvía
     los hidden inputs — NO hay cripto/MD5/CHAP cliente. Réplica de
     `wifionice.py:62`.
   - Verificación: re-probe del canary; éxito sólo si vuelve a `online`.

**Why el form PlayRenfe es CONFIGURABLE y no hardcoded:** el `action`
del form, los nombres de los campos y la URL del portal de PlayRenfe
**sólo se pueden capturar a bordo del tren** (en oficina el WiFi no
reproduce Renfe). Por eso el endpoint del portal, la URL canary, el
token esperado, el intervalo, el timeout y el interfaz WiFi son todos
overridables por env/flag (Rule 4 IDLC: cero hardcoding). Se entrega un
default sano + un TODO claramente marcado donde rellenar el form real,
y un modo que permite que un form SINTÉTICO ejercite el motor HOY.

**Why bind al interfaz WiFi es best-effort en macOS:** macOS no expone
`SO_BINDTODEVICE` (Linux-only). El bind se intenta por la IP del
interfaz (`--wifi-iface` → IP vía `ifconfig`/`ipconfig getifaddr`); si
no se puede determinar, se documenta la limitación y se usa la ruta por
defecto. Es aceptable: durante el captive sólo el WiFi del tren tiene
ruta a `80/443`.

**Acceptance Criteria:**

- `tools/captive-watchdog.py` existe, es Python 3 stdlib-only (sólo
  `urllib`, `html.parser`, `socket`, `argparse`, `logging`, `os`,
  `signal`, `time`) — NO `requests`/`bs4`/pip.
- Loop canary tri-estado `online`/`offline`/`None`; en `None` NO
  re-login; transiciones de estado registradas con logging estructurado.
- Re-login: GET portal → `html.parser` extrae todos los `<input>`
  (incl. `CSRFToken`) → re-POST con `login=true` → verifica canary.
- Configurable por env/flag: `--canary-url`, `--canary-token`,
  `--poll-interval`, `--timeout`, `--portal-url`, `--wifi-iface`,
  `--form-id`/`--form-action`. PID file en `generated/`. Termina limpio
  ante SIGTERM/SIGINT (borra PID file). Idempotente: si ya hay un PID
  vivo, no arranca otro.
- Toda petición de red está acotada en tiempo (`timeout=` en cada
  `urlopen`). HTML parseado de forma segura (`html.parser`, sin `eval`,
  sin ejecutar scripts).
- Comentarios en español (Rule estilo proyecto).
- Test `tests/test_REQ-NET-40_captive_watchdog.sh` (REQ-ID embebido)
  levanta un servidor HTTP sintético local que sirve (a) canary "alive"
  y (b) un form captive con hidden inputs incl. `CSRFToken`, y verifica
  que el watchdog: detecta `online`, detecta `offline`, parsea los
  hidden inputs y emite el re-POST con `login=true`. JUnit XML a
  `reports/`.

**Verification:**

- **Funcional local (sintético):**
  `tests/test_REQ-NET-40_captive_watchdog.sh` — arranca un HTTP server
  inline que alterna entre página viva y página-portal, lanza el motor
  de re-login del watchdog contra él, y comprueba:
  1. clasifica `online` cuando el canary devuelve el token.
  2. clasifica `offline` cuando el canary devuelve la página portal.
  3. el parser `html.parser` extrae `CSRFToken` y demás hidden inputs.
  4. el re-POST llega al server con `login=true` + el `CSRFToken` echo.
- **Runtime (pendiente — sólo a bordo):**
  1. Capturar el HTML real del form PlayRenfe (DevTools / curl al portal
     tras DNAT) en el trayecto.
  2. Rellenar `PLAYRENFE_PORTAL_URL`, `--form-id`/`--form-action` y el
     `canary-token` reales en `config/env`.
  3. Forzar expiración (esperar timeout o agotar cuota) y confirmar que
     el watchdog re-loguea solo y el canary vuelve a `online`.

**Riesgos:**

- **Form real desconocido:** el `action`/campos PlayRenfe son un TODO
  marcado en el código. Hasta capturarlos a bordo, el motor sólo está
  probado contra el form sintético. Mitigación: el motor es agnóstico
  al nombre de los campos (reenvía TODOS los inputs), así que muy
  probablemente funcione "tal cual" en cuanto se le dé la URL correcta.
- **Bind a interfaz en macOS:** best-effort por IP; si el routing
  durante el captive no aísla el WiFi del tren, el probe podría salir
  por otro interfaz. Mitigación: durante el captive sólo el WiFi tiene
  ruta a 80/443 (las celulares van por ubond). Documentado.
- **Cuota / MAC randomization:** el re-login no resetea la cuota
  Icomera (`dataLimit`). Si la expiración es por cuota agotada, el
  re-login puede fallar repetidamente. Mitigación futura: rotación de
  MAC (fuera de alcance de este REQ, ver riesgo 1 del plan bypass).
- **MitM HTTPS universal:** el canary DEBE ser HTTP plano (no HTTPS):
  bajo DNAT :443 todo HTTPS devuelve el cert PlayRenfe, no el origin.
  Un canary HTTPS daría siempre "portal". Documentado: canary http://.

**Related:**

- `docs/v2-ubond/13-plan-bypass-wifi-tren.md` — Tasks C1/C2/C3, sección 4.
- `build/captive-refs/prison-break/prisonbreak/plugins/wifionice.py` —
  patrón GET → parse inputs → POST (líneas 40, 49-51, 62). Clonado C3.
- `build/captive-refs/db_wlan_manager/db_wifionice.py` — tri-estado
  online/offline/None (líneas 71-85), CSRFToken (106-110). Clonado C3.
- `tools/captive-watchdog.py` — implementación C1+C2.
- `tests/test_REQ-NET-40_captive_watchdog.sh` — validación sintética.
- [[REQ-NET-37]] — pre-resolución DNS de filters; mismo registro de
  problemas de conectividad pre-captive en AVE.
