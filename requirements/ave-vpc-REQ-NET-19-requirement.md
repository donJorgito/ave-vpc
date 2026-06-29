### ave-vpc.REQ-NET-19 - Patches macOS para que ubond compile

**Description:**

`markfoodyburton/ubond` (fork de mlvpn explorado en Fase 1, ver
`docs/v2-ubond/01-fase1-exploracion.md`) tenía dos bloqueantes que
impedían compilarlo en macOS Apple Silicon:

1. **`SO_BINDTODEVICE` Linux-only** en `ubond_rtun_bind()`
   (`src/ubond.c:1117`). macOS define la macro pero no la implementa,
   y `<net/if.h>` no completa la `struct ifreq` sin headers Linux —
   error `variable has incomplete type 'struct ifreq'`.

2. **`tuntap_darwin.c` original incluye `buffer.h`** que no existe
   en ubond. ubond es fork de mlvpn donde se eliminó el sistema de
   buffer circular pero el `tuntap_darwin.c` quedó referenciándolo
   — bug del fork sin macOS testeado.

Sin estos parches, ubond NO compila en Apple Silicon. Bloqueante de
Fase 3+ del roadmap v2 ubond.

**Solución:**

- `patches/ubond_macos_compile.patch`: cambia las dos referencias a
  `SO_BINDTODEVICE` en `ubond_rtun_bind()` por bloques
  `#ifdef __linux__` + branch macOS que loguea aviso y sigue. La
  declaración de `struct ifreq` también queda dentro del `#ifdef`.
  No usamos `#if defined(SO_BINDTODEVICE)` porque macOS define la
  macro (con valor 0x1134) sin tener la API funcional.

- `patches/tuntap_darwin_utun_ubond.c`: implementación completa de
  utun usando `SYSPROTO_CONTROL + UTUN_CONTROL_NAME`. Adaptado de
  `patches/tuntap_darwin_utun.c` (que era para mlvpn) a la API de
  ubond:
  - `ubond_pkt_t` en lugar de `circular_buffer_t`
  - `ubond_pkt_get/release()` en lugar de `mlvpn_pktbuffer_*`
  - sin dependencia de `buffer.h`
  - división correcta privsep: `root_tuntap_open()` (root, abre
      el utun) + `ubond_tuntap_alloc()` (unprivileged, llama
      `priv_open_tun()` IPC al proceso priv)

**Aplicación manual** (hasta tener `03b-setup-mac-ubond.sh`
en Fase 4):

```sh
cd build/ubond
patch -p1 < ../../patches/ubond_macos_compile.patch
cp ../../patches/tuntap_darwin_utun_ubond.c src/tuntap_darwin.c
PKG_CONFIG_PATH="$(brew --prefix libev)/lib/pkgconfig:$(brew --prefix libsodium)/lib/pkgconfig" \
CFLAGS="-I$(brew --prefix libev)/include -I$(brew --prefix libsodium)/include" \
LDFLAGS="-L$(brew --prefix libev)/lib -L$(brew --prefix libsodium)/lib" \
ac_cv_func_strnvis=no \
./configure --enable-filters
make
```

Verificado el 2026-05-26: el binario `build/ubond/src/ubond` se
genera correctamente (164 KB) y `ubond --help` arranca y muestra
las opciones esperadas.

**Parent Requirement:** ave-vpc.REQ-NET-09 (rama v2 — ver
`project_v2_ubond_roadmap.md`)

**Acceptance Criteria:**

- `patches/ubond_macos_compile.patch` existe en el repo y aplica
  limpio con `patch -p1` desde `build/ubond/` (formato unified diff
  estándar con cabeceras `--- a/src/ubond.c` y `+++ b/src/ubond.c`).
- `patches/tuntap_darwin_utun_ubond.c` existe e implementa las
  cuatro funciones requeridas por la API de ubond:
  `ubond_tuntap_read`, `ubond_tuntap_write`, `ubond_tuntap_alloc`,
  `root_tuntap_open` (no estática, llamada por `privsep.c`).
- El patch usa `#ifdef __linux__` (no `#if defined(SO_BINDTODEVICE)`)
  porque macOS define la macro pero no la implementa.
- El `tuntap_darwin_utun_ubond.c` NO incluye `buffer.h`.
- Tras aplicar ambos parches, `make` en `build/ubond/` produce
  `src/ubond` sin errores de compilación.
- `ubond --help` arranca y muestra las opciones del binario.
