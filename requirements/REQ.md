# Requisitos del sistema — Índice

Cada requisito está en su propio fichero `ave-vpc-<REQ-ID>-requirement.md`
en este directorio, conforme a IDLC v6 (un fichero por requirement,
plantilla `iac_component-id-requirement.md`). Cada requirement tiene un
test correspondiente `test_<REQ-ID>_*.sh` en `tests/` que verifica su
cumplimiento y emite un reporte JUnit XML en `reports/`.

## Hardware (REQ-HW)

| ID | Título |
|----|--------|
| [REQ-HW-01](ave-vpc-REQ-HW-01-requirement.md) | Mac con macOS 13 (Ventura) o superior |
| [REQ-HW-02](ave-vpc-REQ-HW-02-requirement.md) | iPhone con plan de datos activo |
| [REQ-HW-03](ave-vpc-REQ-HW-03-requirement.md) | Dispositivo Android con plan de datos activo |
| [REQ-HW-04](ave-vpc-REQ-HW-04-requirement.md) | Cable USB compatible con el dispositivo Android |
| [REQ-HW-05](ave-vpc-REQ-HW-05-requirement.md) | SIMs de operadoras distintas en los dos móviles |

## Software del Mac (REQ-SW)

| ID | Título |
|----|--------|
| [REQ-SW-01](ave-vpc-REQ-SW-01-requirement.md) | macOS 13.0 o superior como SO del cliente |
| [REQ-SW-02](ave-vpc-REQ-SW-02-requirement.md) | Xcode Command Line Tools instalados |
| [REQ-SW-03](ave-vpc-REQ-SW-03-requirement.md) | Homebrew instalado |
| [REQ-SW-04](ave-vpc-REQ-SW-04-requirement.md) | Terraform 1.5 o superior |
| [REQ-SW-05](ave-vpc-REQ-SW-05-requirement.md) | Git 2.39 o superior |
| [REQ-SW-06](ave-vpc-REQ-SW-06-requirement.md) | libev 4.33 o superior |
| [REQ-SW-07](ave-vpc-REQ-SW-07-requirement.md) | libsodium 1.0.18 o superior |

## Servidor mlvpn (REQ-VPS)

| ID | Título |
|----|--------|
| [REQ-VPS-01](ave-vpc-REQ-VPS-01-requirement.md) | Sistema operativo Ubuntu 26.04 LTS |
| [REQ-VPS-02](ave-vpc-REQ-VPS-02-requirement.md) | CPU mínima 1 vCPU |
| [REQ-VPS-03](ave-vpc-REQ-VPS-03-requirement.md) | RAM mínima 512 MB |
| [REQ-VPS-04](ave-vpc-REQ-VPS-04-requirement.md) | Disco mínimo 10 GB |
| [REQ-VPS-05](ave-vpc-REQ-VPS-05-requirement.md) | IP pública IPv4 estática (o DDNS) |
| [REQ-VPS-06](ave-vpc-REQ-VPS-06-requirement.md) | Puerto TCP 22 abierto para SSH |
| [REQ-VPS-07](ave-vpc-REQ-VPS-07-requirement.md) | Puertos UDP del bonding abiertos en el servidor (5080, 5081, 5082) |
| [REQ-VPS-08](ave-vpc-REQ-VPS-08-requirement.md) | IP forwarding habilitado |
| [REQ-VPS-09](ave-vpc-REQ-VPS-09-requirement.md) | Latencia al trayecto inferior a 50 ms |

## Red (REQ-NET)

| ID | Título |
|----|--------|
| [REQ-NET-01](ave-vpc-REQ-NET-01-requirement.md) | iPhone compartiendo red por USB tethering |
| [REQ-NET-02](ave-vpc-REQ-NET-02-requirement.md) | Android compartiendo red por USB tethering |
| [REQ-NET-03](ave-vpc-REQ-NET-03-requirement.md) | Dos enlaces activos simultáneamente al conectar |
| [REQ-NET-04](ave-vpc-REQ-NET-04-requirement.md) | IP pública sin CGNAT en la conexión doméstica |
| [REQ-NET-05](ave-vpc-REQ-NET-05-requirement.md) | Soporte de WiFi corporativa o redes con captive portal |
| [REQ-NET-06](ave-vpc-REQ-NET-06-requirement.md) | Tercer enlace WiFi con pre-flight checks |
| [REQ-NET-07](ave-vpc-REQ-NET-07-requirement.md) | Rebind del enlace WiFi ante cambios de IP |

## Restricciones macOS (REQ-MAC)

| ID | Título |
|----|--------|
| [REQ-MAC-01](ave-vpc-REQ-MAC-01-requirement.md) | Workaround de sudo sin TTY en Macs Jamf/MDM |
| [REQ-MAC-02](ave-vpc-REQ-MAC-02-requirement.md) | Lectura correcta de counters de utun via netstat -ibn |
| [REQ-MAC-03](ave-vpc-REQ-MAC-03-requirement.md) | Ruta /32 anti-loop al VPS preferiendo enlaces móviles |
| [REQ-MAC-04](ave-vpc-REQ-MAC-04-requirement.md) | Configuración del utun directamente desde 04-conectar.sh |
