### ave-vpc.REQ-NET-16 - Selector throughput-aware (medición pasiva)

**Description:**

El selector dinámico (REQ-NET-11/14/15) elegía el "mejor link"
basándose solo en RTT y pérdida de pings ICMP. En producción AVE
2026-05-25 se observó un caso patológico: el iPhone respondía a
ping con RTT bajo y 0 % loss, **pero el throughput real del túnel
por ese link era 0 KB/s** (operador con cobertura "lógica" pero
saturado/estrangulado). El selector lo elegía como activo y rompía
la sesión.

ICMP responde porque son paquetes pequeños (56 B); el UDP del
túnel mlvpn (paquetes ~1400 B continuos) está siendo descartado
por el operador. **El ping es señal de "puede haber camino", NO
de "hay BW útil"**.

**Solución (medición pasiva):** el selector lee deltas de
contadores `netstat -ibn` cada tick. Si:

- El túnel utun fluye >1 KB/s (tráfico real del usuario)
- Y un link específico autenticado contribuye <100 B/s (solo
  keepalives, no data)
- Durante 15 s sostenidos

→ ese link se considera "muerto" (`DEAD_LINK_EXCLUDED=1`) y se
excluye del pool del selector hasta que vuelva a fluir tráfico
real por él.

Si el túnel está idle (sin tráfico del usuario), no se penaliza
nada — no podemos evaluar BW sin demanda.

**Ventajas vs. enfoque activo (curl periódico)**:
- 0 tráfico extra (lectura de contadores ya disponibles)
- 0 puertos nuevos en RPi/router
- 0 endpoints nuevos
- Datos reales del uso del usuario, no sintéticos

**Trade-off**: solo detecta dead-links cuando hay carga. Si el túnel
está idle y un link está muerto, no se descubre hasta que el
usuario empiece a usar el túnel. Aceptable.

**Parent Requirement:** ave-vpc.REQ-NET-11

**Acceptance Criteria:**

- `tools/seleccionar-mejor-enlace.sh` define las constantes
  `DEAD_LINK_THRESHOLD_S=15`, `MIN_TUNNEL_BPS_PER_TICK=5000`
  (1 KB/s), `MIN_LINK_BPS_PER_TICK=500` (100 B/s, suficiente para
  exceder keepalives mlvpn ~30 B/s).
- Estado: arrays `PREV_BYTES`, `DEAD_LINK_SINCE`,
  `DEAD_LINK_EXCLUDED`, variable `PREV_UTUN_BYTES`.
- Función `read_iface_bytes(iface)` lee bytes acumulados
  (in+out) de `netstat -ibn`, manejando ambos formatos (con MAC y
  sin MAC).
- Función `find_mlvpn_utun()` localiza el utun de mlvpn buscando
  el que tiene IP 10.10.10.x.
- Función `link_has_fallback_only(link)` lee
  `mlvpn_active.conf` y devuelve "1" si el link tiene
  `fallback_only=1`. Backups se EXCLUYEN del check (solo llevan
  keepalives intencionalmente).
- Función `update_throughput_state()` se llama **en cada tick**
  (no solo cada eval). Para cada link autenticado y NO backup:
  detecta tráfico bajo con túnel activo y, tras
  `DEAD_LINK_THRESHOLD_S` sostenidos, marca
  `DEAD_LINK_EXCLUDED=1`.
- Recuperación: cuando el link excluido tiene un tick con
  tráfico ≥`MIN_LINK_BPS_PER_TICK`, sale de exclusión inmediato
  (no requiere ventana de estabilidad — throughput es señal directa).
- `evaluate_and_rotate()` excluye los links con
  `DEAD_LINK_EXCLUDED=1` del cálculo de score, igual que ya
  excluye los `FLAP_EXCLUDED=1`.
- Cada cambio de estado (excluir / reintegrar) loguea via
  `logger -t mlvpn-selector` con descripción del evento (incluye
  bytes/tick observados).
- El resumen de rotación usa marcador `DEAD` para los links
  excluidos por throughput (en vez de `@` o `FLAP`).
