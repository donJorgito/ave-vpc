### ave-vpc.REQ-NET-53 - ruff con reglas explícitas y como gate de CI (IDLC v6 Rule 8)

**Status:** Implementado (`ruff.toml`, `.github/workflows/ci.yml`,
`.pre-commit-config.yaml`, `requirements-dev.txt`). Verificado en local con
`ruff` 0.17.5 y `pre-commit run --all-files`.

**Description:**

El PR #21 de Dependabot subió `ruff` de 0.11.2 a 0.17.5 y se fusionó solo al
pasar el CI. Con 0.17.5, `ruff check .` falla con 15 errores (BLE001, S110,
PLW1510, UP041, I001) que 0.11.2 no marcaba. Causa comprobada: el repo no tenía
configuración de ruff y el conjunto de reglas por defecto cambió entre versiones
(con 0.11.2 los defaults eran `E4`, `E7`, `E9` y `F`; con 0.17.5 y esas mismas
cuatro reglas el repo pasa limpio). El CI no lo detectó porque ruff solo corría
en el hook local de pre-commit, no en el CI.

**Implementación:**

1. `ruff.toml` fija `select = ["E4", "E7", "E9", "F"]` y excluye `build` y
   `__pycache__`. Es el mismo conjunto que se aplicaba hasta ahora: no se
   relaja ni se amplía ninguna regla. Ampliarlas pasa a ser un cambio explícito.
2. `ci.yml` añade el paso `ruff check .` en el job `test`, con la versión de
   `requirements-dev.txt`, de modo que una subida de ruff queda cubierta por el
   gate que espera el auto-merge de Dependabot (REQ-NET-51).
3. `pre-commit-hooks` pasa a 6.0.0 (equivale al PR #22 de Dependabot) y se
   actualizan las versiones documentadas en la cabecera de
   `.pre-commit-config.yaml` (ruff 0.17.5, pre-commit-hooks 6.0.0).

**Acceptance Criteria:**

- `ruff.toml` declara las cuatro reglas y no contiene `ignore`.
- El CI ejecuta `ruff check .`.
- `ruff check .` y `pre-commit run --all-files` pasan con ruff 0.17.5 y
  pre-commit-hooks 6.0.0.
- `tests/test_REQ-NET-53_ruff_explicit_rules.sh` pasa.

**Verification:**

- **Estática y ejecución:** `tests/test_REQ-NET-53_ruff_explicit_rules.sh`.
- **Reproducción del defecto:** con ruff 0.11.2 el repo pasaba; con 0.17.5 sin
  `ruff.toml`, 15 errores; con 0.17.5 y `select = E4,E7,E9,F`, 0 errores.

**Riesgos:**

- Las versiones de la tabla de `.pre-commit-config.yaml` son informativas y
  pueden quedar por detrás de `requirements-dev.txt` tras una subida de
  Dependabot; la fuente de verdad es `requirements-dev.txt`.
- Las reglas extra de ruff 0.17 (excepciones genéricas, `subprocess` sin `check`,
  etc.) quedan sin aplicar. Adoptarlas exige tocar `08-monitor.py` y
  `tools/captive-watchdog.py` y es una decisión aparte.

**Related:**

- REQ-NET-49 — hooks de pre-commit con versiones fijadas.
- REQ-NET-51 — auto-merge de Dependabot (depende de que el CI cubra el lint).
