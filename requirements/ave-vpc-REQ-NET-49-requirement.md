### ave-vpc.REQ-NET-49 - Hooks de pre-commit como `repo: local` (IDLC v6.2.1 §7.2)

**Status:** Implementado (`.pre-commit-config.yaml`, `requirements-dev.txt`,
`.github/workflows/ci.yml`). Verificado en local con `pre-commit run
--all-files` (10 hooks, 0 fallos, 0 Skipped). El CI queda desacoplado del
pre-commit con las mismas versiones de herramienta (ver Implementación).

**Description:**

IDLC v6.2.1 §7.2 exige declarar los hooks de pre-commit como `repo: local`, con
las herramientas instaladas desde los proxies de Artifactory de Roche y sin
clonar nunca de `github.com` público (Rule 1 / §8.3.7). El
`.pre-commit-config.yaml` del repo usaba `repo: https://github.com/...` con
cinco repos remotos (pre-commit-hooks, shellcheck-py, gitleaks,
markdownlint-cli, ruff-pre-commit).

**Implementación:**

Los 10 hooks pasan a `repo: local` con `language: system`, igual que la plantilla
canónica `templates/.pre-commit-config.yaml`. Cada herramienta lleva versión
explícita (Rule 7): pre-commit 4.7.0, pre-commit-hooks 4.6.0, ruff 0.11.2
(`requirements-dev.txt`), markdownlint-cli 0.43.0, shellcheck 0.10.0, gitleaks
8.30.1 (tabla en la cabecera del fichero). Las versiones y argumentos son los
mismos que los hooks remotos anteriores: no se elimina ni relaja ninguna regla.
`ruff` añade `--force-exclude` (el entry upstream anterior lo llevaba).

**CI desacoplado con paridad de versiones.** Con `language: system` el runner
`ubuntu-latest` no tiene `pre-commit-hooks` ni `gitleaks`, así que el job `lint`
deja de invocar `pre-commit/action`. Para que el pre-commit siga anticipando los
fallos del CI, las dos herramientas que el CI ejecuta usan la misma versión que
el hook local: gitleaks 8.30.1 como imagen `ghcr.io/gitleaks/gitleaks` fijada por
tag y digest (Rule 7; en ese paso no se instala nada con un gestor de paquetes)
y shellcheck v0.10.0 explícito en la acción (antes `stable`, una versión móvil
que podía fallar en CI donde el hook pasaba). Esto no cumple la letra de Rule 6
("todas las dependencias en la Runner Image"): el runner `ubuntu-latest` no es
una imagen cualificada, la acción de shellcheck descarga su binario en cada
ejecución y el job `test` mantiene un `pip install` previo.

**Cobertura de claves privadas.** El CI deja de ejecutar `detect-private-key`.
La regla `private-key` por defecto de gitleaks exige cabecera, cuerpo de 64 o
más caracteres y pie, por lo que no marca una cabecera suelta ni los formatos
PuTTY, SSH2 y OpenVPN que `detect-private-key` sí marcaba (comprobado con
sondas de texto en gitleaks 8.30.1: 0 hallazgos con la configuración por
defecto). Para no perder esa cobertura, `.gitleaks.toml` extiende las reglas por
defecto con la regla `private-key-header`, que replica las 10 entradas de la
`BLACKLIST` de pre-commit-hooks 4.6.0. Se comprobó con cinco sondas (cabecera
suelta, PuTTY, SSH2, OpenVPN y PGP): la regla marca las cinco, no marca un texto
limpio y el árbol del repo da 0 hallazgos. El hook local y el CI pasan
`--config .gitleaks.toml`, y el test verifica que la regla cubre las 10
entradas.

**Acceptance Criteria:**

- Ningún `repo:` remoto, `rev:` ni `github.com` activo en el fichero.
- Todos los `repo:` son `local` y todos los hooks `language: system`.
- Siguen presentes los 10 hooks previos.
- Versión X.Y.Z documentada por herramienta; sin `latest`.
- `pre-commit run --all-files` termina sin fallos ni Skipped.
- `ci.yml` no invoca `pre-commit/action`; gitleaks se ejecuta con imagen fijada
  por `@sha256:` y su versión es igual a la del hook; shellcheck lleva versión
  explícita igual a la del hook (el test falla si divergen).
- `tests/test_REQ-NET-49_precommit_repo_local.sh` pasa.

**Verification:**

- **Estática, offline:** `tests/test_REQ-NET-49_precommit_repo_local.sh`.
- **Local:** `pre-commit run --all-files` con Python 3.11.5 (`.python-version`).

**Riesgos:**

- Verificado en un runner real (CI de la PR #20, runner 2.338.2): el
  `docker pull` con `tag@digest` funciona y el digest coincide; el paso ejecuta
  `docker run` con los argumentos `dir . --config .gitleaks.toml --redact
  --no-banner`, escanea el árbol y termina con `no leaks found`; el paso de
  shellcheck usa `version: v0.10.0`. La forma `docker://imagen:tag@sha256:...`
  no está documentada por GitHub: que funcione hoy no garantiza que siga así.
  La descarga de la imagen tardó cerca de dos minutos en esa ejecución.
- Rule 1 en el CI: la imagen de gitleaks y las acciones de GitHub proceden de
  registros públicos (fijados por SHA o digest). Es una desviación residual,
  registrada en `SUPPLY_CHAIN.md` (gap-4) y pendiente de aceptación del PO.
- Los casos de fallo del test se comprobaron a mano en la sesión, cada uno con
  una desviación deliberada y restaurada después: versión de gitleaks del CI
  distinta (`gitleaks_version_drift`), `version: stable` en shellcheck
  (`shellcheck_version_drift`, antes el test moría sin mensaje) y una entrada
  quitada de la regla (`private_key_header_gap`). No hay un test automático que
  ejerza esos casos de fallo.
- La paridad de versiones local y CI solo cubre shellcheck y gitleaks, que son
  las herramientas que el CI ejecuta; ruff, markdownlint y el resto de hooks
  corren solo en local y el CI no los repite.
- Con `language: system` una versión local distinta de la fijada no se detecta
  automáticamente; la tabla de la cabecera es la referencia.
- El hook `gitleaks` local escanea lo staged; el CI escanea todo el árbol del
  checkout con `dir`. Mismo motor y versión, distinto alcance.
- La regla `private-key-header` se probó con sondas de texto, no con claves
  reales, y el test comprueba su regex con el motor de expresiones de Python
  (gitleaks usa RE2); los patrones usados son simples y compatibles con ambos,
  pero no se ha probado cada entrada contra el binario de gitleaks.
- El hook local de gitleaks sigue escaneando solo lo staged y el CI todo el
  árbol: una cabecera preexistente en un fichero sin tocar pasaría el hook local
  y fallaría en el CI.

**Related:**

- IDLC v6.2.1 §6.3, §7.2; `templates/.pre-commit-config.yaml`.
- `SUPPLY_CHAIN.md` §4.1, `CONTRIBUTING.md`.
