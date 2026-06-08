# Supply Chain — External Code Provenance

Este documento cumple **IDLC v6 Rule 1 (No External Code without provenance)**
para la única dependencia OSS modificada en `ave-vpc`: el fork `markfoodyburton/ubond`
y los 7 patches locales aplicados sobre él.

Resto de dependencias OSS se consumen como binarios sin parchear (Homebrew,
apt, pip) y se cubren via los scanners SCA estándar (gitleaks, ruff,
shellcheck, tflint) sin necesidad de SBOM custom.

## 1. Upstream pinneado

- **Repositorio**: `https://github.com/markfoodyburton/ubond`
- **Branch**: `master`
- **Commit SHA pinneado**: `466b4227ceaee0882978ce0b754e2138f9f2d77d`
  - Verificado en `build/ubond/.git/packed-refs:2`.
  - Coincide hoy (2026-06-08) con `HEAD` upstream — el fork está al tip;
    cualquier avance upstream requiere re-rebase manual (ver sección 5).
- **Parent project**: `https://github.com/zehome/mlvpn`
  (HEAD `b934d4953d480cbbd43128d01150b829fa8839df`, pinned solo informativo
  — `ave-vpc` ya no consume `mlvpn` en v2).
- **Razón del fork**:
  - REQ-NET-12 — replicación selectiva por 5-tupla (no presente en mlvpn).
  - REQ-NET-19 — soporte macOS (`utun` + `SO_BINDTODEVICE` portable).

El clone se realiza con `git clone --depth 1` desde
`03b-setup-mac-ubond.sh:150` y `07b-setup-rpi-ubond.sh:152`. El SHA queda
implícito en la depth-1 ref; los scripts NO fijan SHA explícito hoy
(deuda técnica trackeada como **gap-1** abajo).

## 2. Patches locales aplicados

Orden de aplicación según `03b-setup-mac-ubond.sh:66` y bloque
`03b-setup-mac-ubond.sh:157-213`:

| # | Patch (en `patches/`)                       | LOC   | REQ-ID         | Plataforma |
|---|---------------------------------------------|-------|----------------|------------|
| 1 | `ubond_macos_compile.patch`                 | 1441  | REQ-NET-19     | macOS      |
| 2 | `tuntap_darwin_utun_ubond.c` (replace file) | 6757  | REQ-NET-19     | macOS      |
| 3 | `ubond_replicate_filter.patch`              | 9811  | REQ-NET-12     | macOS+Linux|
| 4 | `ubond_per_link_tolerence.patch`            | 6333  | REQ-NET-25     | macOS+Linux|
| 5 | `ubond_replicate_dedup_fix.patch`           | 4823  | REQ-NET-27     | macOS+Linux|
| 6 | `ubond_filters_section_exclusion.patch`     | 1092  | REQ-NET-29     | macOS+Linux|
| 7 | `ubond_dedup_gate_data_seq.patch`           | 1988  | REQ-NET-30     | macOS+Linux|
| 8 | `ubond_rebind_on_silence.patch`             | 7748  | REQ-NET-35 + REQ-NET-35.1 | macOS+Linux |

Notas:

- En RPi (`07b-setup-rpi-ubond.sh:21-26`) hoy solo se aplica el patch #3;
  los #4-#8 conviven funcionalmente por el lado mac (gap **gap-2** abajo).
- Los patches 1 y 3 son `patch -p1`; el item 2 es **replace de fichero**
  (`cp patches/tuntap_darwin_utun_ubond.c src/tuntap_darwin.c`,
  `03b-setup-mac-ubond.sh:164`) — no es diff, es código nuevo escrito
  desde cero por el SME.

Mapping detallado de cada REQ-ID a su requirement file está en
`requirements/ave-vpc-REQ-NET-{12,19,25,27,29,30,35}-requirement.md`.

## 3. SME review

Lane 1 — Personal project, single-developer cadence. El SME es:

- **Jorge Lazaro Molina** (autor del repo, autor de los 7 patches,
  validador de runtime en AVE Madrid-Orihuela).

Cada patch tiene **dual sign-off implícito** via:

- Commit message en `git log` con REQ-ID + descripción.
- Entrada en `CHANGELOG.md` con fecha + razón + evidencia de runtime
  (ej. `CHANGELOG.md:13` REQ-NET-35.1, `CHANGELOG.md:156` REQ-NET-30).
- Test estático en `tests/test_REQ-NET-NN_*.sh` (12+ checks por patch).

Para Lane 2 (proyectos compliance-bound) este modelo NO aplica — un
SME externo independiente sería requerido. Se documenta aquí como
limitación reconocida del Lane 1.

## 4. Scan evidence

### 4.1. Scanners activos en repo

`pre-commit` ejecuta sobre código del repo Roche, NO sobre `build/ubond`
(excluido explícitamente):

- `gitleaks` v8.30.1 — secrets scan (`.pre-commit-config.yaml:25`).
- `ruff` v0.11.2 con `--exclude build/` (`.pre-commit-config.yaml:57`).
- `shellcheck` v0.10.0.1 — solo `*.sh` del repo.
- `markdownlint` v0.43.0 con `--ignore build/`
  (`.pre-commit-config.yaml:46`).
- `detect-private-key` + `check-added-large-files --maxkb=500`.

### 4.2. Cobertura real sobre código upstream + patches

| Asset                              | Scan ejecutado | Evidencia |
|------------------------------------|----------------|-----------|
| `build/ubond/` (upstream clonado)  | NO             | Excluido en pre-commit; `build/` está en `.gitignore` y no es ingestado al repo Roche. |
| `patches/*.patch` (committed)      | gitleaks SI; SAST C/C++ NO | Pre-commit cubre secrets; no hay clang-tidy/cppcheck wired hoy. |
| Binario `ubond` compilado          | NO             | No se distribuye binario; cada host compila desde fuente. |

### 4.3. CVE check upstream

Metodología (manual, 2026-06-08):

- `markfoodyburton/ubond` — repo personal, sin CVE registrado en NVD.
  Último commit upstream coincide con SHA pinneado.
- `zehome/mlvpn` (parent) — sin CVE registrado en NVD; proyecto en
  modo mantenimiento desde 2020.
- Dependencias C transitive de ubond: `libev`, `libsodium`. Cubiertas
  por package manager del host (Homebrew/apt) — actualización
  responsabilidad del runtime, no del fork.

**Frecuencia de re-check**: trimestral (próxima ventana 2026-09-08) o
ad-hoc si CVE de `libsodium`/`libev` aparece en NVD feed.

### 4.4. Gaps reconocidos

- **gap-1**: clone sin `git checkout <SHA>` explícito. Riesgo: si
  upstream avanza, un setup nuevo trae un commit distinto del pinneado
  aquí. Mitigación pendiente: añadir `git -C ubond checkout 466b4227`
  tras `git clone --depth 1` en ambos scripts setup.
- **gap-2**: RPi solo aplica patch #3 hoy; #4-#8 NO se aplican en
  Linux. Mitigación: actualizar `07b-setup-rpi-ubond.sh` para iterar
  los 8 patches igual que macOS, o documentar por qué Linux no los
  necesita.
- **gap-3**: SAST C/C++ no wired. Mitigación posible: `cppcheck`
  pre-commit hook sobre `patches/*.c`. Lane 1, baja prioridad.

## 5. Update policy

- **Modelo**: **frozen fork**. El SHA pinneado no se mueve sin causa
  (CVE upstream, feature requerida).
- **Re-rebase trigger**:
  - CVE público en `markfoodyburton/ubond` o `zehome/mlvpn`.
  - Nueva REQ-NET-NN que requiera código upstream nuevo.
  - Revisión trimestral planificada (próxima 2026-09-08).
- **Procedimiento de re-rebase**:
  1. Branch `chore/ubond-rebase-YYYY-MM-DD`.
  2. `git fetch upstream master`, registrar nuevo SHA candidato.
  3. Re-aplicar los 8 patches en orden; documentar conflicts.
  4. Smoke-test con `tests/test_REQ-NET-23_smoke_lib.sh` + runtime AVE.
  5. Update sección 1 con nuevo SHA + entrada en `CHANGELOG.md`.
- **Conflict handling**: si >2 patches conflictan, evaluar abandono
  del rebase y mantener SHA actual; los patches son la value-add
  principal, no el upstream.

## 6. Risk register

| Riesgo                                    | Probabilidad | Impacto | Mitigación |
|-------------------------------------------|--------------|---------|------------|
| Upstream archivado / abandonado           | Media        | Bajo    | Fork frozen ya cubre uso actual. SHA pinneado garantiza reproducibilidad. |
| Upstream desaparece de GitHub             | Baja         | Medio   | Mirror local en `build/ubond` de cada host. Evaluar mirror oficial en namespace Roche si Lane sube de 1 a 2. |
| Patches conflictan al rebase              | Alta (>1 año) | Medio  | Frozen fork minimiza necesidad de rebase. Tests estáticos por patch detectan regresión inmediata. |
| CVE en `libsodium`/`libev` transitivo     | Media        | Alto    | Cubierto por package manager del host; no requiere acción en repo. |
| SHA pinneado drift por clone --depth 1    | Alta          | Medio  | gap-1 — fix pendiente con `git checkout <SHA>` post-clone. |
| Patch #2 (replace file) divergencia upstream | Media     | Bajo    | `tuntap_darwin_utun_ubond.c` es código completo, no diff — sobrevive a cambios en otros ficheros del upstream. |

## 7. Referencias

- IDLC v6 Rule 1 — External Code Provenance.
- IDLC v6 Rule 7 — Versioning (SHA pinning, no `@latest`).
- `requirements/ave-vpc-REQ-NET-12-requirement.md` (replicación selectiva).
- `requirements/ave-vpc-REQ-NET-19-requirement.md` (soporte macOS utun).
- `CHANGELOG.md:13-67` (últimas iteraciones REQ-NET-34/35).
- `03b-setup-mac-ubond.sh:139-220` (compile pipeline canonical).
- `07b-setup-rpi-ubond.sh:73-110` (compile pipeline RPi).
