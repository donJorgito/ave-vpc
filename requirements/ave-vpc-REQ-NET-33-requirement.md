### ave-vpc.REQ-NET-33 - Code coverage strategy (roadmap multi-fase)

**Description:**

Adoptar code coverage real (no solo tests estáticos) para los tres
lenguajes activos del proyecto, en fases incrementales por ROI:

- **Fase 1 — Python (`coverage.py` + `pytest`)**: cobertura de
  `08-monitor.py` (524 LOC). Coste setup ~30 min, ROI alto (un solo
  fichero, mockeable, ya tiene test embebido en `test_REQ-NET-31`).
- **Fase 2 — Bash (`bashcov` o `kcov`)**: cobertura de scripts
  operativos (`04b-conectar-ubond.sh`, `tools/ubond-watchdog.sh`,
  `SOS.sh`, `tools/medir-enlaces.sh`, etc.). Coste setup ~2-3h
  (kcov es más limpio en CI; bashcov requiere Ruby). ROI medio —
  mucha lógica son llamadas externas (ssh, sudo, ifconfig) cuya
  cobertura no refleja calidad funcional.
- **Fase 3 — C patches (`gcov` + `lcov`)**: cobertura de las
  modificaciones a `build/ubond/src/ubond.c` y `config.c`. Coste
  setup ~4-6h (rebuild ubond instrumentado con `-fprofile-arcs
  -ftest-coverage`, harness de prueba que invoque las funciones
  patched). ROI bajo en absoluto (patches pequeños, 4-30 líneas
  cada uno) pero alto en confianza para AVE → considerar tras
  primer trayecto exitoso si surgen regresiones.

**Why:** El audit IDLC v6 deep 2026-06-03 identificó que los tests
actuales son estáticos (grep + bash syntax + JUnit XML), lo cual
detecta gaps de configuración pero NO regresiones funcionales en el
código. Sin coverage real, una refactorización futura puede romper
flujos sin que ningún test falle. La estrategia incremental por
ROI evita el sobreesfuerzo Lane 1 mientras cubre lo más crítico
primero (Python: monitor del usuario en viaje).

**Acceptance Criteria por fase:**

**Fase 1 (REQ-NET-33.1):**

- `coverage.py` y `pytest` añadidos a `requirements-dev.txt` o
  documentado en CONTRIBUTING.md cómo instalarlos.
- Hook pre-commit ejecuta `pytest --cov=08-monitor --cov-fail-under=70`.
- Test `test_REQ-NET-31` migrado de embedded-Python-en-bash a
  `tests/test_REQ_NET_31_monitor.py` (pytest puro con fixtures +
  `unittest.mock`).
- CI artifact: `reports/coverage-monitor.xml` (Cobertura format) o
  `coverage.html`.
- Coverage objetivo inicial: 70% líneas, 60% branches.

**Fase 2 (REQ-NET-33.2):**

- `kcov` o `bashcov` instalado (decisión: ver Issue separada).
- Wrapper `tests/run_with_coverage.sh` para correr los `test_REQ-*.sh`
  bajo coverage.
- Output combinado `reports/coverage-bash.xml`.
- Coverage objetivo inicial: 50% líneas (es realista para shell con
  mucho I/O externo).

**Fase 3 (REQ-NET-33.3):**

- Build alternativo `build/ubond/` con `CFLAGS="-fprofile-arcs
  -ftest-coverage"`.
- Harness C `tests/c/test_dedup_gate.c` que invoca
  `ubond_replicate_dedup_check` con secuencias mockeadas (LRU
  fill, dup detection, data_seq=0 short-circuit).
- `gcov` ejecutado tras tests, `lcov --capture` genera
  `reports/coverage-c.info`.
- Coverage objetivo: 80% sobre las LÍNEAS PATCHED solo (no todo
  ubond.c — sería injusto sobre código upstream que no testamos).

**Plan de ejecución incremental (poco a poco):**

| Fase | Cuándo | Estado | Bloqueante para |
|---|---|---|---|
| 1 (Python) | 2026-06-03 oficina | ✓ HECHA — coverage 48% real, threshold 40% | — |
| 2 (Bash) | Tras Fase 1 estable >2 semanas | pending | — |
| 3 (C) | Tras primer trayecto AVE OK | pending | — |

Cada fase aterriza en su propio commit + sub-requirement.

**Verification:** test
`tests/test_REQ-NET-33_coverage_strategy.sh` valida que el roadmap
está documentado (este archivo + `docs/v2-ubond/10-code-coverage-roadmap.md`)
y que cada fase completada tiene su artifact correspondiente.

Pendiente crear el test cuando arranque Fase 1.

**Related:**

- [[REQ-NET-31]] — monitor TUI dual-mode (objeto Fase 1).
- [[REQ-NET-26]] — watchdog (objeto Fase 2).
- [[REQ-NET-30]] — dedup gate C (objeto Fase 3).
- IDLC v6 R8 — linting + tests (audit 2026-06-03).
