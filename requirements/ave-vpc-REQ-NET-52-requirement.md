### ave-vpc.REQ-NET-52 - Commit de ubond fijado en la compilación del Mac y de la RPi (IDLC v6 Rule 7)

**Status:** Implementado (`patches/ubond.ref`, `03b-setup-mac-ubond.sh`,
`07b-setup-rpi-ubond.sh`). Verificado de forma estática con
`tests/test_REQ-NET-52_ubond_pinned_ref.sh`. Validación runtime pendiente: una
ejecución real de `03b` y de `07b` con `FORCE_REBUILD=1`.

**Description:**

`03b` y `07b` hacían `git clone --depth 1` del `master` de
`markfoodyburton/ubond` y le aplicaban los parches del repo. Sin commit fijado,
dos compilaciones en momentos distintos podían partir de código distinto
(Regla 7, versionado determinista). El `master` actual es el commit
`466b4227ceaee0882978ce0b754e2138f9f2d77d` (único commit relevante, de
2021-11-06; el repo upstream no recibe cambios desde 2022). Es también el commit
sobre el que está construido `build/ubond` en el Mac, de modo que el cambio no
altera lo que se compila hoy.

**Implementación:**

1. `patches/ubond.ref` contiene el SHA de 40 caracteres, una sola línea. Es la
   única fuente de verdad para Mac y RPi.
2. `03b` lee el fichero, valida el formato, descarga solo ese commit
   (`git init` + `git fetch --depth 1 <url> <sha>` + `checkout --detach`) y
   aborta si `HEAD` no coincide con la referencia, también cuando reutiliza un
   `build/ubond` existente.
3. `07b` lee y valida el fichero en el Mac, pasa `UBOND_REF` al script remoto y
   este hace el mismo fetch por SHA y la misma verificación en la RPi.
4. Para actualizar ubond hay que cambiar `patches/ubond.ref` en un PR; los
   parches se vuelven a probar con el CI.

**Acceptance Criteria:**

- `patches/ubond.ref` es una línea con un SHA de 40 caracteres hexadecimales.
- Ni `03b` ni `07b` contienen un `git clone` activo de ubond.
- Ambos hacen fetch por SHA y comprueban `rev-parse HEAD` contra la referencia.
- `07b` pasa `UBOND_REF` al script remoto.
- `tests/test_REQ-NET-52_ubond_pinned_ref.sh` pasa y los tests REQ-NET-20 y
  REQ-NET-21 siguen pasando.

**Verification:**

- **Estática:** `tests/test_REQ-NET-52_ubond_pinned_ref.sh`.
- **Runtime:** pendiente (ver Status). El fetch de un SHA concreto con
  `--depth 1` depende de que GitHub lo permita para commits alcanzables; si
  falla, el script aborta con error y no compila otro código.

**Riesgos:**

- `tests/test_REQ-NET-46_cpu_pacing.sh` sigue clonando `master` para comprobar
  que los parches aplican; queda fuera de este alcance.
- Si upstream reescribe la historia y el SHA deja de existir, la compilación
  falla en lugar de usar código distinto (comportamiento deseado).

**Related:**

- `patches/*.patch`, `03b-setup-mac-ubond.sh`, `07b-setup-rpi-ubond.sh`.
- REQ-NET-47 — `FORCE_REBUILD` para propagar parches a una RPi provisionada.
