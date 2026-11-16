### ave-vpc.REQ-NET-51 - Auto-merge de PRs minor y patch de Dependabot (IDLC v6 §6.2 / §7.4)

**Status:** Implementado (`.github/workflows/dependabot-automerge.yml`).
Verificado de forma estática con `tests/test_REQ-NET-51_dependabot_automerge.sh`.
La activación de `allow_auto_merge` y la prueba con un check fallido son
ajustes del repositorio en GitHub y se registran en el PR, no en el código.

**Description:**

`dependabot.yml` solo genera los PRs. Hasta ahora cada PR minor o patch se
fusionaba a mano tras comprobar el CI. El workflow programa la fusión
automática (squash) de los PRs de `dependabot[bot]` cuyo `update-type` sea
`version-update:semver-minor` o `version-update:semver-patch`. Los major y
cualquier PR que no sea del bot quedan para revisión humana (Peer + PO).

**Implementación:**

1. Disparador `pull_request` (no `pull_request_target`); el job no hace
   checkout ni ejecuta código del PR.
2. Condición `github.event.pull_request.user.login == 'dependabot[bot]'`.
3. `dependabot/fetch-metadata` (fijado a SHA, Regla 7) obtiene `update-type`.
4. `gh pr merge --auto --squash` solo programa la fusión: la ejecuta GitHub
   cuando se cumplen los checks obligatorios de la protección de `main`
   (`Lint y calidad`, `Tests de verificación`, con `strict`). Si un check
   falla, el PR queda abierto sin fusionar.
5. Permisos: `permissions: {}` a nivel de workflow; el job solo recibe
   `contents: write` y `pull-requests: write`.

**Acceptance Criteria:**

- El workflow solo se ejecuta para PRs del bot y nunca con `pull_request_target`.
- Solo minor y patch programan la fusión; `semver-major` no aparece en el fichero.
- No hay `actions/checkout` y toda action va fijada a un SHA de 40 caracteres.
- Permisos mínimos, como en Implementación.
- `tests/test_REQ-NET-51_dependabot_automerge.sh` pasa y falla ante cada
  mutación (disparador, SHA, tipo de update).

**Verification:**

- **Estática:** `tests/test_REQ-NET-51_dependabot_automerge.sh` (10 checks).
- **Runtime:** pendiente del primer PR minor/patch del bot tras activar
  `allow_auto_merge`, y de una PR de prueba con un check fallido que confirme
  que no se fusiona.

**Riesgos:**

- El gate vale lo que valen los tests: el CI no compila ubond ni levanta el
  túnel. Un cambio de comportamiento de una herramienta de lint (p. ej. `ruff`
  0.x, donde un salto de minor puede ser notable) pasaría si los tests no lo
  cubren.
- No hay SAST entre los checks obligatorios; si se añade, hay que incluirlo en
  la protección de rama para que el auto-merge lo espere.
- Fusionar no publica release: los ecosistemas vigilados son herramientas de
  desarrollo y CI, sin efecto sobre el runtime desplegado.

**Related:**

- `.github/dependabot.yml`, `.github/workflows/ci.yml`.
- REQ-NET-49 — hooks de pre-commit y versiones fijadas.
