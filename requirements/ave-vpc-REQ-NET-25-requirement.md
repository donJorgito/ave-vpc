### ave-vpc.REQ-NET-25 - Per-link loss_tolerence/latency_tolerence en ubond (port mlvpn)

**Description:**

ubond v2 hereda de mlvpn la idea de tener umbrales globales de
"link aceptable" (loss% antes de marcar LOSSY, RTT máximo). Pero
en ubond el código tenía esos valores **hardcoded como constantes
globales**:

- `LOSS_TOLERENCE = 31.0` en `ubond.c:136`.
- Timeout de keepalive ack = `UBOND_IO_TIMEOUT_DEFAULT*2 + 2*RTT`
  hardcoded en `ubond_rtun_check_lossy` (`ubond.c:1931`).

El Bug #6 del trayecto AVE 2026-05-29 documentó cómo esto causaba
un ciclo de 1s entre `tunnels up` y `tunnels down or lossy`:
con RTT 4G ~200ms el threshold queda en 0.9s, cualquier jitter
encima del RTT promedio supera el umbral y mark lossy → keepalive
arriva → recover → repeat.

mlvpn original tenía per-link `loss_tolerence` (% loss, max 100,
default 100) y `latency_tolerence` (ms, max 1000, default 1000).
Esta fase porta ambos a ubond con un mapeo semántico:

- **`loss_tolerence`**: idéntico a mlvpn — % loss umbral antes de
  marcar UBOND_LOSSY. Reemplaza el `LOSS_TOLERENCE` global en
  `ubond_rtun_check_lossy` (las otras 6+ usos del símbolo en
  funciones internas de averaging quedan intactos — son heurísticas
  de loss-cnt accounting, no decisiones de estado).
- **`latency_tolerence`**: ms extra de gracia para el ack del
  keepalive antes de marcar LOSSY. Mapeo semántico — ubond no
  tiene un check separado de "RTT excede X ms" como mlvpn, así
  que aquí significa "tolerancia adicional sumada al threshold
  base de keepalive". Cap a 5000 ms.

Defaults: 0 (preserva el comportamiento histórico — usa
`LOSS_TOLERENCE` global y no añade gracia extra).

**Parent Requirement:** ave-vpc.REQ-NET-22.

**Why:** Bug #6 (loss cycling) bloquea el AVE: aun si el
dataplane fluye (ya cubierto por REQ-NET-24), un enlace que
oscila entre AUTHOK y LOSSY cada segundo:

- Llena el log con ruido.
- Activa request_resend innecesariamente, gastando ancho.
- Disrupta sesiones TCP que toman ese ciclo como pérdida real
  → congestion control falsamente disparado.

Sin per-link override, sería necesario recompilar y subir
`LOSS_TOLERENCE` global, pero eso afecta a todos los enlaces.
Per-link es la forma correcta: el iPhone Movistar puede tener
threshold de loss=80% y grace=2000ms (red noisy), mientras el
Pixel Yoigo puede mantener defaults estrictos.

**Acceptance Criteria:**

- `patches/ubond_per_link_tolerence.patch` existe en `patches/`,
  130 líneas aprox, modifica `src/ubond.h`, `src/ubond.c`,
  `src/config.c`.
- `03b-setup-mac-ubond.sh` valida la presencia del patch en su
  pre-flight + lo aplica (Patch 4) en su chain.
- `07b-setup-rpi-ubond.sh` transporta el patch al RPi vía
  `UBOND_PATCH2_B64` (base64) + lo aplica tras
  `ubond_replicate_filter.patch` (orden importa: el patch asume
  el estado post-replicate).
- El binario compilado en build/ubond/src/ubond contiene los
  strings `loss_tolerence` y `latency_tolerence` (verificable
  con `strings`).
- Las claves `loss_tolerence` y `latency_tolerence` se aceptan
  en bloques `[links.X]` del `ubond.conf`. Si no se especifican,
  se usa default global (sin regresión).
- Cap explícito: loss_tolerence > 100 se trunca a 100 con
  warning. latency_tolerence > 5000 se trunca a 5000 con warning.

**Verification:** test estático
`test_REQ-NET-25_per_link_tolerence.sh`. La validación runtime
del comportamiento (que el ciclo de loss cycling se atenúa con
override per-link) requiere condiciones AVE reales (no se
reproduce en LAN/casa). Marcado como pendiente para próximo
trayecto AVE.

**Related:**

- [[REQ-NET-22]] — cliente ubond.
- [[REQ-NET-24]] — coexistencia mlvpn↔ubond.
- `docs/v2-ubond/04-bugs-trayecto-2026-05-29.md` Bug #6 sección.
