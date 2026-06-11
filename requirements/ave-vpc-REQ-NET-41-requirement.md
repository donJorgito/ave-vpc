### ave-vpc.REQ-NET-41 - Enlace WiFi de ubond enrutable a través de un wrapper local (bypass firewall AVE)

**Status:** Implementado en script (modo OPT-IN `WIFI_VIA_WRAPPER`),
validado estático. Validación runtime pendiente próximo trayecto AVE.

**Description:**

ubond es UDP-only por diseño (`SOCK_DGRAM`, crypto libsodium por
datagrama — no se toca). El firewall del WiFi del AVE (Icomera/Nomad)
bloquea TODO el UDP outbound (confirmado 2026-06-09: 7 puertos × 2
destinos = 0/14 replies) y DNAT-ea tcp/80+443 al portal cautivo. Por
tanto el enlace `[links.wifi]` apuntando directo a `VPS_IP:443/udp`
NUNCA cruza el firewall del tren.

La solución (Task T2 del plan doc 13) es un wrapper EXTERIOR
(`tools/wrap-socat.sh` / `wrap-udp2raw.sh` / `wrap-wstunnel.sh`) que
expone una boca UDP local en `127.0.0.1:<WRAP_LOCAL_PORT>` (default
`UBOND_PORT_3` = 5085) y la cruza por TCP/WSS/faketcp hasta la RPi,
donde otro wrapper la entrega al puerto UDP real de ubond. Para que el
bonding use esa boca, el `[links.wifi]` del cliente debe poder apuntar
a `127.0.0.1:<WRAP_LOCAL_PORT>` en vez de a `VPS_IP:443`.

Este REQ añade esa capacidad de forma **ADITIVA y OPT-IN**: por
defecto el comportamiento es EXACTAMENTE el de hoy (WiFi directo a la
RPi). El cambio NO puede regresionar v1.0.0 (mlvpn) ni el bonding
ubond v2 estable, que son el path productivo de fallback.

**Mecanismo del fix:**

- Variable de entorno `WIFI_VIA_WRAPPER` (default `0` = OFF). Cuando
  vale `1`, el bloque `[links.wifi]` se escribe con:
  - `bindhost = "127.0.0.1"`
  - `remotehost = "127.0.0.1"`
  - `remoteport = ${WRAP_LOCAL_PORT}`
  Cuando vale `0` (default), el bloque se escribe BYTE-IDÉNTICO al
  actual (`bindhost = IP_WIFI`, `remotehost = VPS_IP`,
  `remoteport = UBOND_PORT_3_REMOTE`).
- `WRAP_LOCAL_PORT` es la MISMA variable y MISMO default que consumen
  los tres wrappers (`wrap-socat.sh`, `wrap-udp2raw.sh`,
  `wrap-wstunnel.sh`): `${UBOND_PORT_3:-5085}`. Coherencia total — no
  hay un segundo nombre de puerto que mantener sincronizado.
- En `04b-conectar-ubond.sh`: el branch wrapper vive dentro del
  `if "${WIFI_ELIGIBLE}"` del Paso 3, junto al branch directo.
- En `tools/wifi-reintegrator.sh` (REQ-NET-13): mismo branch OPT-IN en
  el `cat >> ACTIVE_CONF` dinámico. El reintegrator hoy es mlvpn-only
  (escribe `mlvpn_active.conf`, SIGHUP a `mlvpn0`); el branch queda
  listo por si se deriva un reintegrator ubond, sin alterar mlvpn por
  defecto.

**Decisión: el wrapper NO se auto-arranca.** `04b` solo APUNTA el
enlace e imprime un hint con el comando exacto del wrapper a lanzar por
separado. Razón: minimizar blast radius. Auto-lanzar un wrapper desde
04b (que ya hace routing, DNS pre-resolve, arranque de ubond y
watchdogs) acoplaría su ciclo de vida al del túnel y multiplicaría los
modos de fallo. El operador arranca el wrapper que toque para la vía
elegida (A/B/C) y luego ubond lo usa como cualquier otro endpoint UDP.

**Why no regresiona el path por defecto:**

- `WIFI_VIA_WRAPPER` default `0`. Sin exportarla, el `[links.wifi]`
  emitido es idéntico carácter a carácter al de antes de este REQ.
- La pre-resolución DNS del Paso 3.5 sustituye `remotehost = "${VPS_IP}"`.
  En modo wrapper `remotehost` es el literal `127.0.0.1`, que esa `sed`
  NO matchea → no hay interacción cruzada. En modo directo el bloque
  contiene `VPS_IP` igual que siempre, y la `sed` actúa igual.
- mlvpn (v1) no ve la variable en su flujo normal: 04-conectar.sh no la
  lee, y el reintegrator solo cambia de rama si `WIFI_VIA_WRAPPER=1`.

**Acceptance Criteria:**

- `04b-conectar-ubond.sh` define `WIFI_VIA_WRAPPER="${WIFI_VIA_WRAPPER:-0}"`
  y `WRAP_LOCAL_PORT="${WRAP_LOCAL_PORT:-${UBOND_PORT_3}}"`.
- Con `WIFI_VIA_WRAPPER` OFF (default), el `[links.wifi]` escrito sigue
  conteniendo `remotehost = "${VPS_IP}"` y `remoteport = ${UBOND_PORT_3_REMOTE}`
  (path por defecto intacto).
- Con `WIFI_VIA_WRAPPER=1`, el `[links.wifi]` escribe
  `bindhost = "127.0.0.1"`, `remotehost = "127.0.0.1"` y
  `remoteport = ${WRAP_LOCAL_PORT}`.
- 04b imprime un hint con el comando del wrapper y NO lo auto-lanza
  (no hay invocación de `tools/wrap-*.sh` ejecutándolo).
- `tools/wifi-reintegrator.sh` tiene el mismo branch OPT-IN gateado por
  `WIFI_VIA_WRAPPER`, con la rama por defecto byte-idéntica a la previa.
- Ambos ficheros mantienen `set -uo pipefail` / `set -o pipefail` y no
  introducen IPs literales fuera de `127.0.0.1` (loopback, no es
  endpoint público — Rule 4 IDLC).
- Test estático `tests/test_REQ-NET-41_wifi_via_wrapper.sh` pasa todos
  los checks (var opt-in presente, default sin tocar, rama wrapper
  escribe 127.0.0.1, no auto-launch, sintaxis bash OK).
- `bash -n` pasa en ambos ficheros.

**Verification:**

- **Estática:** `tests/test_REQ-NET-41_wifi_via_wrapper.sh` al
  implementar (2026-06-11).
- **Runtime (pendiente):** próximo trayecto AVE:
  1. Arrancar `tools/wrap-socat.sh` (Vía C baseline) en Mac + su espejo
     en RPi.
  2. `sudo WIFI_VIA_WRAPPER=1 ./04b-conectar-ubond.sh` y confirmar que
     `generated/ubond_active.conf` tiene `[links.wifi]` apuntando a
     `127.0.0.1:5085`.
  3. Verificar tráfico de VUELTA por el utun (ping VPS interno) — el
     wrapper C tiene caveat de simetría (ver wrap-socat.sh).
  4. Repetir sin la variable y confirmar que el `[links.wifi]` vuelve a
     apuntar directo a `VPS_IP` (no regresión).

**Riesgos:**

- **Wrapper no arrancado:** si el operador olvida lanzar el wrapper, el
  enlace WiFi apunta a un `127.0.0.1:PORT` muerto y no autentica
  (degrada a 2 enlaces móviles, NO tumba el túnel). El hint impreso por
  04b mitiga el olvido.
- **Caveat de simetría (Vía C socat):** documentado en
  `tools/wrap-socat.sh` — el camino de vuelta puede quedar huérfano con
  `fork`. Ortogonal a este REQ (que solo enruta el enlace); se valida
  en el trayecto.
- **Coexistencia de puertos:** `WRAP_LOCAL_PORT` default = `UBOND_PORT_3`
  (5085). Si el wrapper escucha en el mismo 5085 que ubond usaría
  localmente para otra cosa, colisión. Hoy no la hay (ubond client no
  bindea 5085 en loopback), pero overrideable vía env si surgiera.

**Related:**

- [[REQ-NET-13]] — `wifi-reintegrator.sh`, reintegración dinámica del
  WiFi vía SIGHUP; este REQ añade el branch wrapper a su escritura.
- [[REQ-NET-39]] — `tools/wrap-socat.sh` (Vía C), wrapper baseline cuyo
  `WRAP_LOCAL_PORT` consume este REQ.
- `04b-conectar-ubond.sh` — Paso 3, branch OPT-IN del `[links.wifi]`.
- `tools/wrap-udp2raw.sh`, `tools/wrap-wstunnel.sh` — wrappers Vía A/B,
  misma boca local `WRAP_LOCAL_PORT`.
- `config/env` — `UBOND_PORT_3` (default del puerto local del wrapper).
- `docs/v2-ubond/13-plan-bypass-wifi-tren.md` — Task T2 (wrapper como
  link ubond) y arquitectura del wrapper (sección 1).
- `tests/test_REQ-NET-41_wifi_via_wrapper.sh` — validación estática.
