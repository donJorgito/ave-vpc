### ave-vpc.REQ-NET-31 - Monitor TUI dual-mode mlvpn/ubond

**Description:**

`08-monitor.py` es el monitor TUI real-time interactivo del usuario
durante el viaje. Muestra throughput por enlace + estado links +
modo bonding/failover. Originalmente solo soportaba v1 (mlvpn,
subnet 10.10.10.x, proctitle `mlvpn: mlvpn0`, lee `mlvpn_active.conf`).

Con la migración a v2 ubond (REQ-NET-12+27+29+30), lanzar el monitor
con ubond corriendo no mostraba nada útil — el script buscaba
`mlvpn0` y no lo encontraba. El usuario lo identificó como gap
operativo durante test oficina 2026-06-03.

Refactor a dual-mode con auto-detect:

- `DAEMON_INFO` dict con parámetros por daemon (subnet, proctitle,
  conf, labels, connect_hint).
- `detect_daemon()` retorna tupla `(daemon, both_alive_warning)` —
  preferencia ubond si ambos vivos, con warning explícito (anomalía
  de transición v1→v2 incompleta o SOS fallido).
- `find_tunnel_utun(daemon)`, `check_daemon_links(daemon)`,
  `check_failover_roles(daemon)`, `check_replicate_active(daemon)`
  — todas tomadas el daemon como argumento; las que aplican solo a
  un daemon (failover→mlvpn, replicate→ubond) early-return.
- `draw(daemon, ...)` usa `DAEMON_INFO[daemon]` para etiquetas e IPs.
- Modos: BONDING (verde) | FAILOVER (amarillo, mlvpn-only) |
  REPLICATE (azul, ubond-only).
- CLI flag `--daemon auto|mlvpn|ubond` (default auto).

Backwards compat v1: lanzar con solo mlvpn vivo da output equivalente
al previo.

Complementario a `tools/ave-monitor.sh` (REQ-NET-28, NDJSON forensic
logger ALCOA++): pueden correr simultáneamente. 08-monitor.py es para
viewing humano interactivo, ave-monitor.sh para post-incident
analysis estructurado.

**Why:** Tras REQ-NET-30 cerrado, v2 ubond es target operativo.
Sin monitor TUI v2-aware, el usuario depende solo de logs estáticos
o ave-monitor (NDJSON, no human-friendly real-time) durante el viaje.
Gap operativo bloqueante para el test AVE.

**Acceptance Criteria:**

- `08-monitor.py` ejecutable, `python3 -m py_compile` OK.
- Cumple linting Python (ruff via pre-commit).
- `DAEMON_INFO` es dict con keys 'mlvpn' Y 'ubond'.
- `detect_daemon()` retorna tupla `(daemon|None, bool)`.
- `--daemon auto` detecta correctamente con `subprocess.check_output`
  mockeado en 4 escenarios: solo mlvpn / solo ubond / ambos / ninguno.
- `--daemon mlvpn|ubond` fuerza el daemon especificado.
- Header docstring describe correctamente lo que hace.

**Verification:** test
`tests/test_REQ-NET-31_monitor_dual_mode.sh` con bloque Python
embebido que usa `unittest.mock.patch` para los 4 escenarios.

**Related:**

- [[REQ-NET-28]] — `tools/ave-monitor.sh` NDJSON logger
  (complementario, no reemplazo).
- [[REQ-NET-30]] — dedup gate (causa de la migración a v2).
- Commit `a024ab9`.
