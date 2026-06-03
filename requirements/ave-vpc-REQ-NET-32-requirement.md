### ave-vpc.REQ-NET-32 - Watchdog FAIL_THRESHOLD NAT-tolerant (8 ticks)

**Description:**

Refuerzo a REQ-NET-26 (watchdog auto-recovery). Análisis post-incidente
2026-06-03 12:51:35 (oficina): SOS disparado por watchdog tras 10 min
Mac idle. Causa próxima: `links.pixel write error` 5s antes del primer
health fail = patrón canónico de expiración del UDP NAT mapping en el
operador 4G.

Mecanismo:

- Mac idle ~10 min sin tráfico saliente.
- Operador 4G droppea el UDP mapping (timeout típico 30-180s sin
  tráfico).
- Próximo paquete (ping del watchdog) sale por el túnel pero el reply
  no vuelve porque el mapping ya no existe.
- ubond reabre el mapping con el primer paquete real (5-15s típico).
- Watchdog con `FAIL_THRESHOLD=4` (20s) dispara SOS ANTES que la
  recuperación natural de NAT y ANTES del propio timeout=30 de ubond.
  Coordinación rota.

Fix en `tools/ubond-watchdog.sh`: subir
`FAIL_THRESHOLD: 4 → 8` (40s tolerance). Supera el peor caso de
recuperación NAT (15s) con cushion. Override via env
`WATCHDOG_FAIL_THRESHOLD=N`.

Invariante de diseño documentada: `FAIL_THRESHOLD * TICK_S >= 40` (40s
cubre NAT recovery típico móvil + margen).

**Why:** Sin este ajuste, cualquier ventana >20s sin red en el AVE
(handover de celda, túnel ferroviario, captive portal renegotiation)
dispara SOS innecesario, abortando la conexión cuando habría
recuperado por sí sola en 5-15s.

**Acceptance Criteria:**

- `tools/ubond-watchdog.sh` define `FAIL_THRESHOLD=${WATCHDOG_FAIL_THRESHOLD:-8}`.
- `TICK_S` default = 5.
- Override env funciona: `WATCHDOG_FAIL_THRESHOLD=12 source` produce
  `FAIL_THRESHOLD=12`.
- Invariante: `FAIL_THRESHOLD * TICK_S >= 40` (assert del test).

**Verification:** `tests/test_REQ-NET-32_watchdog_threshold.sh`
sourcing harness para verificar default, override env, e invariante.

**Mejoras pendientes (futuras REQ-NET-XX):**

- Métrica health alternativa: `≥1 link autenticado + ping KO = degradado, no SOS`. Solo SOS si 0 links auth.
- Keepalive aplicación más bajo que el NAT timeout del operador
  (probar `timeout=15` por link en ubond.conf).
- tcpdump rotativo automático en background del watchdog para capturar
  evidencia del próximo incidente.

**Related:**

- [[REQ-NET-26]] — watchdog auto-recovery base.
- Commit `b61f345`.
- Análisis 12:51:35 documentado en `docs/v2-ubond/08-req-net-30-dedup-asymmetry.md`
  (sección "Investigación SOS").
