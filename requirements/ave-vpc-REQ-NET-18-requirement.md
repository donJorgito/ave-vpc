### ave-vpc.REQ-NET-18 - Pre-flight: verificar-setup exige bash 4+

**Description:**

Los watchers del túnel (`tools/seleccionar-mejor-enlace.sh`,
`tools/wifi-reintegrator.sh`, `tools/calibrar-enlaces-dinamico.sh`)
usan `declare -A` (arrays asociativos), que NO existen en bash 3.2 —
el shell que macOS instala por defecto en `/bin/bash`. Cada uno de
estos scripts ya tiene su propio relauncher que detecta
`BASH_VERSINFO[0] < 4` y se reejecuta con `/opt/homebrew/bin/bash` o
`/usr/local/bin/bash`. Pero si Homebrew bash no está instalado, esos
relaunchers fallan en runtime con el bug visto el 2026-05-25:

```
line 44: iphone: unbound variable
ERROR: necesita bash >=4. Instalar: brew install bash
```

El usuario solo descubrió el problema lanzando el túnel en
producción real (AVE) — un fallo grave que debería haberse detectado
antes. El test runner `tests/verificar-setup.sh` debe comprobar al
inicio que existe un bash 4+ accesible y abortar con mensaje claro
si no.

**Parent Requirement:** ave-vpc.REQ-NET-09

**Acceptance Criteria:**

- `tests/verificar-setup.sh`, antes de iterar tests, busca un bash
  ejecutable en `/opt/homebrew/bin/bash`, `/usr/local/bin/bash`,
  `/bin/bash` y para cada uno consulta `BASH_VERSINFO[0]`.
- Si ninguno tiene versión ≥4, sale con código 1 y mensaje rojo:
  ```
  ERROR: bash >=4 no encontrado en el sistema.
  Los watchers del túnel ... requieren arrays asociativos (declare -A),
  incompatibles con bash 3.2 que es el default de macOS. Instalar:
    brew install bash
  ```
- Si encuentra al menos uno con versión ≥4, continúa la ejecución
  normal sin imprimir nada (no añadir ruido cuando todo va bien).
- El check no asume que `/usr/bin/env bash` resuelve a v4+ (puede
  que sí en el shell del usuario pero no bajo sudo). Por eso prueba
  paths absolutos.
