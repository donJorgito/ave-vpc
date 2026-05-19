# Changelog

Todos los cambios notables de este proyecto se documentan aquí.
Formato basado en [Keep a Changelog](https://keepachangelog.com/es/1.0.0/).

## [Sin publicar]

## [0.9.0] — 2026-05-19

### Corregido — TÚNEL COMPLETAMENTE FUNCIONAL
- `07-setup-rpi.sh` / `03-setup-mac.sh` — updown script reescrito con la firma
  correcta de mlvpn: `script <device> <evento>` + env vars `IP4`, `IP4_GATEWAY`,
  `MTU`, `DEVICE`. La versión anterior usaba `$1=up/down` y vars `MLVPN_IPADDR`
  etc. que corresponden a una API antigua no implementada en este mlvpn.
- `07-setup-rpi.sh` — permisos del updown script: 700 en vez de 755. mlvpn rechaza
  ejecutar scripts accesibles por grupo u otros (`group/other accessible` → fatal).
- `07-setup-rpi.sh` — `ip4_updns` → `statuscommand` (nombre correcto del config key).
  `ip4_updns` es ignorado silenciosamente; `statuscommand` es el key real.
- `04-conectar.sh` — configura la IP del túnel directamente desde el script en macOS,
  ya que `priv_run_script` no ejecuta el statuscommand de forma fiable en macOS/utun.
- `05-desconectar.sh` — mata mlvpn por nombre de proceso (`mlvpn: mlvpn0`), no por
  PID del tee que era lo que se guardaba en mlvpn.pid.

## [0.8.0] — 2026-05-19

### Corregido
- `01-generar-secreto.sh` — cambiado de `openssl rand -hex 32` (64 chars) a `openssl rand -hex 16`
  (32 chars). El parser de config de mlvpn falla silenciosamente con passwords > ~40 chars:
  el proceso hijo hereda una clave derivada de una password diferente a la configurada.
  Con 32 chars (128 bits de entropía) el sistema funciona correctamente.
- Cron Oracle Cloud eliminado — RPi en casa es el servidor definitivo ✓
- pmset standby restaurado en AC — ya no se necesita para mantener el Mac despierto

### Primer viaje AVE confirmado (18/05/2026)
- Bonding iPhone (Movistar) + Pixel (Yoigo) funcionando en Madrid-Orihuela
- Latencia ~87-677ms (variación normal en tren), 0% pérdida de paquetes al VPS
- El túnel sobrevive cambios de cobertura entre operadoras

## [0.7.0] — 2026-05-18

### Añadido
- `patches/tuntap_darwin_utun.c` — parche utun para macOS: sustituye `/dev/tun` (requiere
  kext obsoleto) por la API nativa `SYSPROTO_CONTROL + UTUN_CONTROL_NAME` (macOS 10.6+,
  Apple Silicon). Aplicado automáticamente por `03-setup-mac.sh` antes de compilar.
- `03-setup-mac.sh` — creación automática de usuario de sistema `mlvpn` en macOS via `dscl`
  (equivalente al usuario mlvpn en la RPi, para privilege separation)
- `03-setup-mac.sh` — comprobación de EUID: el script NO debe ejecutarse con sudo
  (brew no funciona como root); usa sudo internamente donde lo necesita
- `04-conectar.sh` / `05-desconectar.sh` — comprobación de EUID: estos scripts SÍ
  requieren sudo (rutas, utun, proceso mlvpn)

### Corregido
- `04-conectar.sh` — mlvpn arranca con `--user mlvpn` (privilege separation) y sin sudo
  en el propio binario (utun no requiere root en macOS, pero sí el script completo)
- `04-conectar.sh` — log file recreado sin root para evitar permisos incorrectos
- `05-desconectar.sh` — rutas eliminadas correctamente con `-ifscope` por interfaz;
  log y pid limpios en cada desconexión
- `07-setup-rpi.sh` — password embebida directamente en mlvpn.conf en lugar de `file://`
  (`file://` no está implementado en mlvpn: usa el literal como contraseña, no el fichero)
- `07-setup-rpi.sh` — añadido `bindhost = "0.0.0.0"` explícito en los links del servidor
  (sin este campo, mlvpn no hace bind a los puertos UDP en Ubuntu 26.04)
- `03-setup-mac.sh` — password embebida directamente (misma corrección que en RPi)

### Pendiente (en investigación)
- `crypto_decrypt failed: -1` entre Mac (mlvpn compilado con utun patch, libsodium 1.0.20)
  y RPi (mlvpn Ubuntu 26.04). Passwords idénticas, mismo commit de mlvpn (master-b934d49),
  mismo protocolo. Causa pendiente de identificar.

## [0.6.0] — 2026-05-18

### Corregido
- `03-setup-mac.sh` — añadido `ac_cv_func_strnvis=no` al configure: macOS detecta
  `strnvis()` pero con firma incompatible con la usada en `setproctitle.c` de mlvpn,
  provocando errores de compilación. Forzar el fallback interno resuelve el problema.
- `03-setup-mac.sh` — sustituido borrado de directorio de build por `make clean`
  (más seguro y semánticamente correcto)

## [0.5.0] — 2026-05-15

### Añadido
- `docs/rpi-setup.md` — sección "Notas de compatibilidad con Ubuntu 26.04 LTS" con las diferencias descubiertas al instalar en producción
- `docs/rpi-setup.md` — advertencia de CGNAT con instrucciones para verificar y solicitar retirada al ISP
- `README.md` — advertencia de CGNAT en la sección de Opción B (Raspberry Pi)

### Corregido
- `07-setup-rpi.sh` — añadida dependencia `libpcap-dev` (requerida por mlvpn en Ubuntu 26.04)
- `07-setup-rpi.sh` — usuario de sistema dedicado `mlvpn` con home `/var/lib/mlvpn` (mejor que `nobody` para trazabilidad)
- `07-setup-rpi.sh` — servicio systemd usa `--user mlvpn` (mlvpn rechaza arrancar como root sin este flag)
- `07-setup-rpi.sh` — chroot a `/var/lib/mlvpn` (home del usuario mlvpn; mlvpn usa el home del usuario como jaula)
- `07-setup-rpi.sh` — numeración de pasos actualizada (1-9)

## [0.4.0] — 2026-05-13

### Añadido
- `docs/rpi-setup.md` — guía actualizada con deSEC como proveedor DDNS recomendado (protocolo DynDNS2, nativo en router ZTE F6640)
- Soporte deSEC (`*.dedyn.io`) en documentación: alternativa a No-IP, gratuita y privada

### Cambiado
- SO objetivo para Raspberry Pi: **Ubuntu Server 26.04 LTS** (antes 24.04 LTS)
- `07-setup-rpi.sh` — actualizado a Ubuntu 26.04 LTS en comentarios y mensajes de salida
- `docs/rpi-setup.md` — reescrito: Imager headless con Ubuntu 26.04, port forwarding tres puertos (5080-5082), DDNS con deSEC
- `config/env.example` — ejemplo de `VPS_IP` actualizado a `*.dedyn.io`
- `terraform/terraform.tfvars.example` — añadido campo `ssh_public_key` con placeholder
- `terraform/variables.tf` — eliminado default hardcodeado de `ssh_public_key`; ahora se define en `terraform.tfvars`
- `requirements/REQ.md` — REQ-VPS-01 actualizado a Ubuntu 26.04 LTS
- `README.md` — Ubuntu 26.04 LTS, deSEC/dedyn.io, puerto 5082 añadido al port forwarding

### Seguridad
- Eliminada clave pública SSH hardcodeada de `terraform/variables.tf` (historial reescrito con `git filter-repo`)

## [0.3.0] — 2026-05-09

### Añadido
- `06-provision-vps.sh` — itera automáticamente por ambos shapes Always Free (A1.Flex ARM y E2.1.Micro x86) en cada intento; para en cuanto uno tiene éxito
- `.github/workflows/ci.yml` — GitHub Actions con ShellCheck, validación de sintaxis bash, checks IDLC y terraform fmt/validate
- `tests/verificar-setup.sh` — script de verificación del entorno completo
- `requirements/REQ.md` — requisitos del sistema documentados con IDs trazables
- `CONTRIBUTING.md`, `CODEOWNERS`, `LICENSE` — cumplimiento IDLC v6
- Pre-commit hooks: ShellCheck, detect-private-key, trailing whitespace, check-yaml

### Cambiado
- `06-provision-vps.sh` — corregido bug de log doble (tee + cron redirect); añadido PATH completo para que terraform sea encontrado desde cron; jitter aleatorio 0-600s para evitar patrón detectable
- `02-setup-vps.sh` — eliminado mensaje que pedía abrir puertos manualmente (ya lo hace Terraform); añadida dependencia `libtool` necesaria para `autogen.sh`
- `03-setup-mac.sh` — añadido check explícito de Xcode CLT y Homebrew; corregidos warnings SC2155 de ShellCheck
- `04-conectar.sh` — corregidos warnings SC2024 y SC2034 de ShellCheck
- `README.md` — reescrito con arquitectura, tabla de configuración, troubleshooting, alternativas VPS y flujo completo
- `.gitignore` — añadidos `.playwright-mcp/`, `.DS_Store`, `.mcp.json`, `*.png`

### Corregido
- Puertos UDP 5080-5082 y TCP 22 gestionados 100% por Terraform (security list en VCN) — ningún paso manual

## [0.2.0] — 2026-05-08

### Añadido
- `06-provision-vps.sh` — provisionado automático del VPS en Oracle Cloud con Terraform, retry horario con jitter aleatorio, notificación macOS al completar
- `00-detectar-interfaces.sh` — detección automática de interfaces iPhone (hotspot WiFi) y Android (USB tethering)
- `terraform/` — infraestructura Oracle Cloud como código (VCN, subnet, security list, IGW, VM)
- Credenciales OCI generadas automáticamente vía Playwright sin intervención manual
- Soporte shapes `VM.Standard.A1.Flex` (ARM, gratis) y `VM.Standard.E2.1.Micro` (x86, gratis)
- `requirements/REQ.md` — requisitos del sistema documentados
- `tests/verificar-setup.sh` — script de verificación del setup completo
- `CONTRIBUTING.md`, `CODEOWNERS`, `.pre-commit-config.yaml`

### Cambiado
- `02-setup-vps.sh` — añadida dependencia `libtool` (necesaria para `autogen.sh`)
- `03-setup-mac.sh` — añadido check explícito de Xcode CLT y Homebrew
- README completamente reescrito con arquitectura, tabla de configuración, troubleshooting y alternativas de VPS

## [0.1.0] — 2026-05-07

### Añadido
- `01-generar-secreto.sh` — genera `keys/mlvpn.secret`
- `02-setup-vps.sh` — compila e instala mlvpn en el VPS vía SSH
- `03-setup-mac.sh` — compila mlvpn en el Mac, genera `generated/mlvpn.conf`
- `04-conectar.sh` — detecta IPs, crea rutas, arranca mlvpn con bonding
- `05-desconectar.sh` — para mlvpn, elimina rutas
- `config/env.example` — plantilla de configuración
- `docs/oracle-cloud-setup.md` — instrucciones para crear el VPS gratuito
- `.gitignore` — excluye secretos, builds y archivos generados
