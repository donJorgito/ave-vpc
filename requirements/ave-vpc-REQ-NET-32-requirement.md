### ave-vpc.REQ-NET-32 - Watchdog FAIL_THRESHOLD AVE-handover-tolerant (12 ticks)

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

**Enmienda REQ-NET-32.1 (2026-06-08, post-AVE 2026-06-05):**

Análisis pcap del trayecto AVE 2026-06-05 reveló 6 SOS automáticos del
watchdog general pese al `threshold=8`. Los handovers celulares en alta
velocidad (cambio de celda + reautenticación + reconvergencia NAT del
operador) pueden durar >40s, por debajo del timeout natural de ubond
(30s) pero cruzando el threshold del watchdog.

Fix: subir `FAIL_THRESHOLD: 8 → 12` (60s tolerance). Cubre hasta el
doble del timeout interno de ubond sin enmascarar caídas legítimas:
una caída real durará >60s y aún disparará SOS. Override sigue activo
via `WATCHDOG_FAIL_THRESHOLD=N`.

Invariante actualizada: `FAIL_THRESHOLD * TICK_S >= 60` (cubre
handovers AVE + doble del timeout ubond).

**Why:** Sin este ajuste, cualquier ventana >20s sin red en el AVE
(handover de celda, túnel ferroviario, captive portal renegotiation)
dispara SOS innecesario, abortando la conexión cuando habría
recuperado por sí sola en 5-15s.

**Acceptance Criteria (vigente tras REQ-NET-32.1):**

- `tools/ubond-watchdog.sh` define `FAIL_THRESHOLD=${WATCHDOG_FAIL_THRESHOLD:-12}`.
- `TICK_S` default = 5.
- Override env funciona: `WATCHDOG_FAIL_THRESHOLD=8 source` produce
  `FAIL_THRESHOLD=8` (legacy 40s) — y cualquier otro valor numérico.
- Invariante: `FAIL_THRESHOLD * TICK_S >= 60` (assert del test).

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
