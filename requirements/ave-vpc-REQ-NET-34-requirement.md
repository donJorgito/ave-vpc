### ave-vpc.REQ-NET-34 - Auto-recovery iphone NAT carrier expiry

**Status:** Implementado y validado en producción AVE 2026-06-05.

**Description:**

Sub-síntoma observable y recurrente del problema general "watchdog tolerante
a degradación parcial": cuando el túnel ubond v2 lleva varios minutos de
trayecto AVE con cobertura cambiante, el operador 4G del iPhone (Movistar)
expira el pinhole UDP del NAT carrier. El binario ubond NO tiene rebind
logic — sigue mandando keepalives al sport efímero ya muerto, el servidor
en la RPi nunca los recibe, y el link queda como `!links.iphone`
(AUTH_PENDING) de forma permanente, hasta que el usuario interviene
manualmente bajando y subiendo la interfaz en macOS.

Mecanismo del fix: forzar re-DHCP en la iface tethering (`ifconfig en8 down`
seguido de `ifconfig en8 up`) regenera el mapping NAT del operador,
ubond ve `getifaddr` sin IP → bind socket nuevo → el siguiente keepalive
sale por un sport fresco que el operador acepta. Recuperación en <30s
sin tocar el binario.

`tools/iphone-relink-watchdog.sh` automatiza esa secuencia: lee el
proctitle de ubond cada 5s, contabiliza cuántos ticks consecutivos el
link aparece como `!links.${LINK_NAME}`, y tras `FAIL_THRESHOLD` ticks
ejecuta `ifconfig down/up` con cooldown de 90s para evitar flap-loop.

**Why:** Sin esta recuperación automática, una expiración de NAT en
medio del AVE rompe la sesión durante minutos hasta que el usuario nota
la degradación, abre terminal, identifica el link caído y actúa. El
patrón se reproduce cada 6-15 min en trayectos largos. La recuperación
manual no es operativamente viable durante una llamada o sesión SSH.

**Acceptance Criteria (implementación):**

- `tools/iphone-relink-watchdog.sh` existe, ejecutable, requiere root
  (exit 1 si EUID != 0).
- Variables override `RELINK_LINK_NAME` (default `iphone`),
  `RELINK_IFACE` (default `en8`), `RELINK_TICK_S` (default 5),
  `RELINK_FAIL_THRESHOLD` (default 12 = 60s), `RELINK_COOLDOWN_S`
  (default 90), `RELINK_GAP_S` (default 2 entre down y up).
- Detecta link DOWN parseando proctitle ubond en busca de
  `!links.${LINK_NAME}` (no usa exit code de ping ni del binario).
- Reset de `fail_count` cuando el proceso ubond no corre (no actúa
  sobre falso positivo si el túnel está apagado).
- Reset de `fail_count` cuando el link se recupera por sí solo antes
  de cruzar el threshold.
- Cooldown post-acción: tras `ifconfig down/up`, no actúa de nuevo
  durante `RELINK_COOLDOWN_S` aunque el link siga `!`.
- Lanzado automáticamente por `04b-conectar-ubond.sh` en background
  tras configurar el utun, junto al watchdog general.

**Validación AVE 2026-06-05 (`generated/iphone_relink_watchdog.log`):**

Tres actuaciones exitosas en un mismo trayecto Madrid → Orihuela:

| Actuación | Trigger (DOWN 12/12) | ACTION ifconfig | Recovery |
|---|---|---|---|
| 1 | 09:30:54Z | 09:30:54Z → 09:30:56Z | DOWN 4/12 a las 09:31:36Z, recovered 09:31:56Z |
| 2 | 09:39:04Z | 09:39:04Z → 09:39:06Z | DOWN 1/12 a las 09:39:11Z, recovered 09:39:16Z |
| 3 | 10:05:11Z | 10:05:11Z → 10:05:13Z | DOWN 2/12 a las 10:05:23Z, recovered 10:05:28Z |

Las tres actuaciones recuperaron `@links.iphone` autenticado sin
intervención humana.

**Mecanismo real de recovery — Hipótesis A confirmada (análisis pcap +
investigación dedicada 2026-06-08):**

Análisis de `evidence/ave-2026-06-05/iphone-4g.pcap0` (parser pcap nativo,
1.05M paquetes) + análisis de discriminación A/B/C en sesión 2026-06-08
confirmó:

- **Sport del Mac NO cambia**: siguió siendo 55478 antes Y después del
  `ifconfig en8 down/up`. El kernel del Mac mantiene el socket UDP
  exacto; ubond no rebinda nada.
- **Recovery es causal con la acción**: último RX antes de action a
  delta=−88.7s, primer RX post-action a +2.54s (110ms tras el primer
  TX post-up). Tight coupling temporal descarta hipótesis "operador
  recupera solo" (placebo).
- **Mecanismo: PDP/CGNAT refresh carrier-side**. El `ifconfig down`
  notifica vía USB-CDC al iPhone que su iface tethering se cierra;
  al `up` el iPhone renegocia session PDP en Movistar; el operador
  ve session-teardown y crea NAT mapping nuevo al primer paquete
  TX post-up. La "frescura" es carrier-side, no Mac-side.

**Implicación para REQ-NET-35**: NO es sustituto. NET-35 (rebind socket
en C) genera nuevo sport efímero local — distinto mecanismo. Cubre el
escenario "operador acepta nuevo 5-tuple" (CGNAT mapping table-stuck).
NET-34 cubre "operador tiene PDP context muerto" (modem-side issue).
Son **complementarios** — el AC original "mover NET-34 a tools/legacy/
cuando NET-35 entre en build" queda **descartado**. Test runtime
pendiente para confirmar definitivamente independencia.

**Limitación REQ-NET-32 (threshold=8) confirmada insuficiente para AVE
2026-06-05**: el watchdog general (`tools/ubond-watchdog.sh`) disparó
**6 SOS automáticos** durante el trayecto (10:52, 11:27, 11:57, 12:07,
12:19, 12:21 CEST) pese al fix del threshold. iphone-relink-watchdog
solo cubre el sub-síntoma iphone-down; cuando ambos links 4G fallan
simultáneamente (cobertura cero o handover bidireccional), el túnel
cae completo y el watchdog general escala 8/8. Pendiente subir
threshold general a 12 + considerar REQ-NET-34/35 cubriendo también
pixel.

**Related:**

- [[REQ-NET-26]] — watchdog auto-recovery base (vía SOS.sh).
- [[REQ-NET-32]] — threshold 4→8 en watchdog general (NAT-tolerant).
- `tools/ubond-watchdog.sh` — watchdog general (este es complementario,
  específico de la iface iphone porque el remedio es distinto: ahí
  SOS.sh full-restart, aquí solo `ifconfig down/up` que es mucho más
  ligero).
