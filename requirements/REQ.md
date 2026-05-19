# Requisitos del sistema

## Hardware

| ID | Requisito | Obligatorio |
|----|-----------|-------------|
| REQ-HW-01 | Mac con macOS 13 (Ventura) o superior | Sí |
| REQ-HW-02 | iPhone con plan de datos activo | Sí |
| REQ-HW-03 | Dispositivo Android con plan de datos activo | Sí |
| REQ-HW-04 | Cable USB compatible con el dispositivo Android | Sí |
| REQ-HW-05 | Las dos SIMs deben ser de operadoras distintas | Recomendado |

## Software en el Mac

| ID | Requisito | Versión mínima | Cómo instalarlo |
|----|-----------|---------------|-----------------|
| REQ-SW-01 | macOS | 13.0 | — |
| REQ-SW-02 | Xcode Command Line Tools | 14.0 | `xcode-select --install` |
| REQ-SW-03 | Homebrew | 4.0 | [brew.sh](https://brew.sh) |
| REQ-SW-04 | Terraform | 1.5 | `brew install terraform` |
| REQ-SW-05 | Git | 2.39 | Incluido en Xcode CLT |
| REQ-SW-06 | libev | 4.33 | Instalado por `03-setup-mac.sh` |
| REQ-SW-07 | libsodium | 1.0.18 | Instalado por `03-setup-mac.sh` |

## VPS (servidor en la nube)

| ID | Requisito | Detalle |
|----|-----------|---------|
| REQ-VPS-01 | Sistema operativo | Ubuntu 26.04 LTS |
| REQ-VPS-02 | CPU mínima | 1 vCPU |
| REQ-VPS-03 | RAM mínima | 512 MB |
| REQ-VPS-04 | Disco mínimo | 10 GB |
| REQ-VPS-05 | IP pública IPv4 estática | Obligatorio |
| REQ-VPS-06 | Puerto TCP 22 abierto | SSH |
| REQ-VPS-07 | Puertos UDP 5080–5082 abiertos | mlvpn bonding |
| REQ-VPS-08 | IP forwarding habilitado | Configurado por `02-setup-vps.sh` |
| REQ-VPS-09 | Latencia al trayecto < 50 ms | Recomendado — usar servidor en España/Europa |

## Red

| ID | Requisito | Detalle |
|----|-----------|---------|
| REQ-NET-01 | iPhone compartiendo red por USB tethering | Interfaz `en8` o similar |
| REQ-NET-02 | Android compartiendo red por USB tethering | Interfaz `en12` o similar |
| REQ-NET-03 | Los dos enlaces activos simultáneamente al conectar | Para bonding real |
| REQ-NET-04 | IP pública sin CGNAT en el servidor doméstico | Opción B (RPi): verificar que IP WAN no empieza por `100.x` |
| REQ-NET-05 | WiFi corporativa o captive portal | Tercer enlace opcional — implementado por REQ-NET-06 |
| REQ-NET-06 | Tercer enlace WiFi con pre-flight checks | `04-conectar.sh` evalúa IP, red de casa y captive portal antes de añadir el WiFi al bonding. Opt-out con `--sin-wifi`. Si UDP al puerto 5082 está bloqueado, mlvpn deja el link en `AUTH_PENDING` (visible en `08-monitor.py`) sin romper los otros enlaces. |

## macOS — Restricciones conocidas

| ID | Restricción | Workaround |
|----|-------------|------------|
| REQ-MAC-01 | `sudo` sin TTY falla en Claude Code y entornos Jamf/MDM | Usar `SUDO_ASKPASS=/tmp/sudo-askpass.sh sudo -A` — creado por `03-setup-mac.sh` |
| REQ-MAC-02 | ~~`netstat -ibn` no captura TX de interfaces TUN (utun)~~ — INCORRECTO, era un bug de parsing | Resuelto en 0.13.0: `netstat -ibn` sí captura el utun en macOS, pero las líneas sin MAC (utun, lo0) tienen offset distinto a las físicas. `08-monitor.py` ahora lee del utun directamente. |
| REQ-MAC-03 | Rutas ifscope no se usan en lookups globales (sin `IP_BOUND_IF`) | `04-conectar.sh` añade ruta /32 regular al VPS antes de las 0/1 para evitar loop |
| REQ-MAC-04 | mlvpn no llama al statuscommand vía `priv_run_script` de forma fiable en macOS | `04-conectar.sh` configura la IP del utun directamente |
