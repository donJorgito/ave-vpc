### ave-vpc.REQ-NET-20 - Setup paralelo de ubond en macOS (Fase 4)

**Description:**

`03b-setup-mac-ubond.sh` instala ubond (fork de mlvpn con replicación
selectiva — REQ-NET-12) en paralelo a mlvpn. Filosofía clave: **NO
sustituye mlvpn, coexisten** durante toda la fase de validación de
v2. Esto permite alternar entre uno u otro sin reinstalar nada y
revertir trivialmente si v2 da problemas en producción real.

Layout:

| | mlvpn (v1.x estable) | ubond (v2 experimental) |
|---|---|---|
| Binario | `/usr/local/sbin/mlvpn` | `/usr/local/sbin/ubond` |
| Usuario sistema | `mlvpn` | `ubond` |
| Config | `generated/mlvpn.conf` | `generated/ubond.conf` |
| Active config (runtime) | `generated/mlvpn_active.conf` | `generated/ubond_active.conf` |
| Updown script | `generated/mlvpn_updown_mac.sh` | `generated/ubond_updown_mac.sh` |
| Conector | `04-conectar.sh` | `04b-conectar-ubond.sh` (Fase 4 pendiente) |

El script aplica los **3 patches** del repo en orden:

1. `patches/ubond_macos_compile.patch` (REQ-NET-19) — `SO_BINDTODEVICE`
   bajo `#ifdef __linux__`.
2. `patches/tuntap_darwin_utun_ubond.c` (REQ-NET-19) — sustituye
   `tuntap_darwin.c` con la implementación utun-API moderna.
3. `patches/ubond_replicate_filter.patch` (REQ-NET-12) — añade la
   sección `[filter.replicate]` y la lógica clone-to-N + dedup LRU.

Tras compilar e instalar, genera una **plantilla `ubond.conf`** con
la sección `[filter.replicate]` comentada con ejemplos típicos para
videoconf (Zoom, Meet RTP, Anthropic API) que el usuario puede
descomentar según necesite.

**Parent Requirement:** ave-vpc.REQ-NET-12 (rama v2)

**Acceptance Criteria:**

- `03b-setup-mac-ubond.sh` existe, es ejecutable, pasa `bash -n` y
  `shellcheck`.
- NO ejecuta como root (igual que `03-setup-mac.sh`); usa sudo
  internamente solo donde es necesario (dscl, make install).
- Verifica:
  - Xcode CLT instalado
  - Homebrew presente
  - **bash 4+ disponible** (instala con `brew install bash` si falta;
    los watchers usan `declare -A`)
  - Las 4 dependencias mínimas: `libev`, `libsodium`, `libpcap`,
    `autoconf/automake/libtool/pkg-config`.
- Verifica que existen los 3 patches en `patches/` antes de continuar.
- Si `ubond` ya está instalado en `/usr/local/sbin/ubond`, lo
  reporta y salta la compilación (idempotencia).
- En la compilación:
  - Clona `markfoodyburton/ubond` en `build/ubond/` con
    `--depth 1`.
  - Aplica los 3 patches en orden con `patch -p1 -N` (no fail si
    ya aplicado).
  - Configure con `--enable-filters` (requerido para
    `[filter.replicate]`).
  - Make + sudo make install.
- Crea usuario de sistema `ubond` con UID libre desde 501 (mlvpn
  usa desde 500), shell `/usr/bin/false`, home `/var/empty`. NO crea
  duplicados si ya existe.
- Genera `generated/ubond.conf` con:
  - `[general]` con secret embebido (lee `keys/mlvpn.secret`),
    `interface_name = "ubond0"`, MTU desde `config/env`.
  - Sección `[filter.replicate]` comentada con ≥4 ejemplos
    (zoom_rtp, meet_stun_turn, rtp_generic, anthropic_api).
  - Mismos `bandwidth_upload` que mlvpn (10 Mbps móvil).
- Copia `generated/mlvpn_updown_mac.sh` → `ubond_updown_mac.sh`
  (firma idéntica). Si no existe el de mlvpn, avisa pero no falla.
- NO toca `mlvpn` ni su config — coexisten.
