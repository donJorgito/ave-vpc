### ave-vpc.REQ-NET-28 - Monitor continuo del cliente ubond v2 (ALCOA++)

**Description:**

`tools/ave-monitor.sh` es el monitor continuo que corre durante todo
el trayecto AVE (Madrid-Orihuela y vuelta). Su propósito es
**observabilidad postmortem ALCOA++**, complementando — no
sustituyendo — el watchdog auto-recovery (REQ-NET-26) y los
smoke-tests on-demand (REQ-NET-23).

Distinción clara:

| Tool | Misión | Cadencia | Acción |
|------|--------|----------|--------|
| `ubond-watchdog.sh` (REQ-NET-26) | Auto-recovery | 5s tick | Dispara SOS.sh |
| `smoke-{casa,cafe,ave}.sh` (REQ-NET-23) | Diagnóstico puntual | On-demand | Reporte único |
| `ave-monitor.sh` (REQ-NET-28) | Observabilidad continua | 10s tick | NDJSON append-only |

El monitor produce DOS canales de output:

1. **Stdout legible (tty con color)**: una línea compacta por tick +
   bloque expandido cada 5 minutos. El usuario en el tren ve el
   estado en tiempo real.
2. **Fichero NDJSON append-only** (`generated/ave-monitor-<startISO>.ndjson`):
   estructura parseable para postmortem. Un objeto JSON por tick con
   campos timestamp, links, ping, throughput, eventos del binario, etc.

**Parent Requirement:** ave-vpc.REQ-NET-22 (cliente ubond).

**Why:** Incidente AVE 2026-06-01 reveló que cuando v2+replicación
caía:

- El usuario detectaba el fallo solo cuando sus apps fallaban (latencia
  de detección humana ~minutos).
- Sin log continuo del estado de los links, RTT, throughput, no había
  forma de reconstruir QUÉ pasó antes del fallo.
- El watchdog (REQ-NET-26) ahora dispara SOS automáticamente, pero
  sin monitor el postmortem es ciego.

Sesión 2026-06-02 (post-mortem con 4 agentes expertos): el usuario
explicitó "el monitor era un requisito, no lo estamos cumpliendo".
Este RQ formaliza el monitor como herramienta de primera línea para
todos los trayectos AVE futuros.

**Acceptance Criteria:**

- `tools/ave-monitor.sh` existe, ejecutable, pasa `bash -n` y
  `shellcheck -x`.
- Reusa `tools/lib/_common.sh` y `tools/lib/env-detect.sh` (no
  duplica logging ni env detection).
- Pre-flight: verifica que ubond está corriendo y el utun existe.
  Aborta con mensaje claro si no.
- Output dual: stdout legible + NDJSON append-only.
- Captura las métricas categorizadas en el diseño técnico (links,
  cobertura, salud túnel, tráfico real, throughput muestreado,
  eventos binario, watchdog, sistema).
- Ping al gateway interno con `-b ${UTUN}` (ifscope), NO global —
  evita falsos positivos por colisión de subnet con red corp
  (lección oficina Roche 2026-06-02).
- DNS para hostnames vía `dig @1.1.1.1` con cache 60s, NO via system
  resolver (lección AVE 2026-06-01 cafe DNS timeout).
- Parsing de salidas (ping, curl, ifconfig, process title) con `awk`
  patrones explícitos, NO `tail | head` (lección AVE 2026-06-01
  monitor roto).
- Anti-bloqueo: cada operación de red con `--max-time` finito; si la
  iteración tarda más que el tick, marca `tick_skip=1` y continúa.
- Detección de anomalías visible en tty (color rojo + bell `\a`):
  - link_count_auth == 0 dos ticks consecutivos.
  - ping_succ_rate < 50% en ventana de 6 ticks.
  - throughput < 50 KB/s dos muestras consecutivas.
  - public_ip_via_tunnel ≠ baseline (FUGA del túnel).
  - TRIGGER SOS en watchdog log.
- ALCOA++:
  - Atributable: timestamps ISO 8601 con offset, paths atributables.
  - Legible: tty con colores y formato consistente.
  - Contemporáneo: append por línea con flush, NO batch al EXIT.
  - Original: copia raw de líneas de `ubond.log` y `watchdog.log`,
    no solo summarized.
  - Exacto: parsing con awk explícito, sin extrapolaciones.
  - Completo: todas las categorías de métricas en cada tick.
  - Consistente: mismo formato JSON entre ticks.
  - Enduring: rotación size-based (10 MB) con archivo histórico.
  - Available: path conocido `generated/ave-monitor-<startISO>.*` +
    symlink `ave-monitor.ndjson` → latest para `tail -f`.
- Trap INT TERM EXIT: cierra ficheros, borra pidfile, imprime
  resumen final (ticks, alertas, ventanas con SOS).
- Idempotencia: si ya hay monitor corriendo (pidfile válido), aborta
  con mensaje.
- Flags CLI: `--tick N`, `--background`, `--no-throughput`.

**Verification:** test estático
`tests/test_REQ-NET-28_monitor.sh`. Validación runtime requiere
trayecto AVE — pendiente próximo viaje.

**Related:**

- [[REQ-NET-22]] — cliente ubond.
- [[REQ-NET-23]] — smoke-tests on-demand (diferente: puntual vs
  continuo).
- [[REQ-NET-26]] — watchdog auto-recovery (diferente: actúa, vs
  monitor que observa).
- [[REQ-NET-27]] — fix replicación (sin monitor el debug fue ciego).
- `docs/v2-ubond/06-trayecto-2026-06-01.md` — incidente que motivó.
- `docs/v2-ubond/07-trayecto-runbook.md` — runbook operativo
  (referencia el monitor en sección 3).
