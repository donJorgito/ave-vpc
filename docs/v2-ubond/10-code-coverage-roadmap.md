# REQ-NET-33 — Code coverage roadmap (3 fases incrementales)

## Origen

Audit IDLC v6 deep (2026-06-03) detectó que los tests del repo son
estáticos: grep contra patches, bash syntax, presencia de funciones
clave. Detectan gaps de configuración pero NO regresiones funcionales
en el código que ejecuta. Sin coverage real, un refactor puede romper
flujos sin disparar fallos en tests.

El usuario aprobó añadir coverage progresivamente (no todo de golpe).
Estrategia ordenada por ROI, no por completitud.

## Fase 1 — Python `coverage.py` + `pytest` (próxima sesión)

**Scope**: `08-monitor.py` (524 LOC).

**Por qué primero**: un solo fichero, lógica determinística, ya
mockeable (sin syscalls inevitables). El test actual
`test_REQ-NET-31_monitor_dual_mode.sh` ya usa `unittest.mock` embebido
en heredoc shell — convertirlo a pytest puro es marginal en esfuerzo y
da coverage real.

**Pasos**:

1. Crear `requirements-dev.txt`:

   ```text
   pytest==8.3.4
   pytest-cov==6.0.0
   ```

2. Migrar `tests/test_REQ-NET-31_monitor_dual_mode.sh` a
   `tests/test_req_net_31_monitor.py`:

   ```python
   from unittest.mock import patch
   import importlib.util

   def load_monitor():
       spec = importlib.util.spec_from_file_location('m', '08-monitor.py')
       m = importlib.util.module_from_spec(spec)
       spec.loader.exec_module(m)
       return m

   def test_daemon_info_has_both():
       m = load_monitor()
       assert 'mlvpn' in m.DAEMON_INFO
       assert 'ubond' in m.DAEMON_INFO

   def test_detect_daemon_only_ubond():
       m = load_monitor()
       with patch.object(m.subprocess, 'check_output',
                         return_value='ubond: ubond0 @links.iphone\n'):
           assert m.detect_daemon() == ('ubond', False)
   # ... 3 escenarios más
   ```

3. Hook pre-commit (`.pre-commit-config.yaml`):

   ```yaml
   - repo: local
     hooks:
       - id: pytest-monitor
         name: pytest 08-monitor.py with coverage
         entry: pytest --cov=08-monitor --cov-fail-under=70 tests/test_req_net_31_monitor.py
         language: system
         pass_filenames: false
         files: ^(08-monitor\.py|tests/test_req_net_31_monitor\.py)$
   ```

4. CI step en `.github/workflows/ci.yml`:

   ```yaml
   - name: Python coverage
     run: |
       pip install -r requirements-dev.txt
       pytest --cov=08-monitor --cov-report=xml:reports/coverage-monitor.xml \
         tests/test_req_net_31_monitor.py
   ```

5. Mantener `tests/test_REQ-NET-31_monitor_dual_mode.sh` como
   wrapper que invoca pytest y emite JUnit XML compatible con
   `_lib_junit.sh` (para que la traza con `tests/check_idlc_files.sh`
   siga funcionando).

**Coverage targets**: 70% líneas, 60% branches inicial. Subir tras
estabilizar.

**Estimación**: 30-60 min.

## Fase 2 — Bash `kcov` (tras Fase 1)

**Scope**: scripts operativos (`04b-conectar-ubond.sh`, `SOS.sh`,
`tools/ubond-watchdog.sh`, `tools/medir-enlaces.sh`, etc.).

**Decisión kcov vs bashcov**: kcov es más limpio en CI Linux
(headless, sin Ruby), bashcov necesita Ruby + funciona mejor local.
Lane 1 personal: prefiero kcov por simpler CI.

**Por qué después**: el shell del repo es ~2000 líneas total, con
mucha lógica de I/O orchestration (ssh, sudo, tcpdump). El coverage %
puede ser engañoso — 80% en `04b-conectar-ubond.sh` no significa
"funciona", significa "se ejecutaron las líneas".

**Pasos**:

1. Instalar kcov en CI runner:

   ```bash
   sudo apt-get install -y kcov
   ```

2. Wrapper `tests/run_with_coverage.sh`:

   ```bash
   #!/bin/sh
   COV_DIR="reports/coverage-bash"
   mkdir -p "${COV_DIR}"
   for t in tests/test_REQ-*.sh; do
       kcov --include-pattern=ave-vpc "${COV_DIR}/$(basename "${t}" .sh)" "${t}"
   done
   kcov --merge "${COV_DIR}/merged" "${COV_DIR}"/test_*
   ```

3. CI artifact `reports/coverage-bash/merged/cobertura.xml`.

**Coverage targets**: 50% líneas (realista para shell I/O).

**Estimación**: 2-3 h.

## Fase 3 — C patches `gcov` + `lcov` (tras primer AVE OK)

**Scope**: SOLO las líneas patched de `build/ubond/src/ubond.c` y
`config.c` por nuestros 8 patches. NO el código upstream — sería
injusto auditar 5000 LOC que no escribimos.

**Por qué último**: setup más caro (rebuild instrumentado, harness C),
ROI bajo dado tamaño pequeño del cambio (4-30 líneas por patch). Sin
embargo, post primer trayecto AVE: si surgen regresiones imposibles de
diagnosticar con tests estáticos, esta fase aporta valor concreto.

**Pasos**:

1. Build instrumentado:

   ```bash
   cd build/ubond
   CFLAGS="-fprofile-arcs -ftest-coverage -O0 -g" \
       LDFLAGS="-fprofile-arcs" \
       ./configure --enable-filters
   make
   ```

2. Harness `tests/c/test_dedup_gate.c`:

   ```c
   // Linkear con ubond.o instrumentado.
   // Stubs: log_debug, log_warnx, ev_*, sockets.
   // Test: invoca ubond_replicate_dedup_check con
   //  - data_seq=0 (early return)
   //  - data_seq=N único (insert + return 0)
   //  - data_seq=N repetido (return 1, dedup hit)
   //  - LRU fill + wrap (verificar comportamiento ring)
   ```

3. Recolección:

   ```bash
   ./test_dedup_gate
   gcov src/ubond.c
   lcov --capture --directory . --output-file reports/coverage-c.info
   lcov --extract reports/coverage-c.info \
       '*/build/ubond/src/ubond.c' \
       '*/build/ubond/src/config.c' \
       --output-file reports/coverage-c-patched.info
   ```

4. Coverage targets: 80% sobre las LÍNEAS PATCHED (no todo el .c).

**Estimación**: 4-6 h.

## Coordinación con tests existentes

Los 3 fases NO sustituyen a los `test_REQ-NET-X_*.sh` actuales —
los complementan. Los static checks siguen siendo la primera línea
(detectan que el patch existe, las build scripts lo wirean, etc.).
El coverage añade segunda línea: "el código patched se ejecuta y
hace lo esperado bajo entrada controlada".

## Decisión: cuándo arrancar cada fase

| Fase | Trigger |
|---|---|
| 1 (Python) | Sesión con tiempo libre 1h, antes del próximo AVE. |
| 2 (Bash) | Tras Fase 1 estable >2 semanas sin issues. |
| 3 (C) | Tras incidente AVE que tests estáticos no expliquen. |

Cada fase commit propio + sub-requirement (REQ-NET-33.1/.2/.3).
