# Changelog

Todos los cambios notables de este proyecto se documentan aquí.
Formato basado en [Keep a Changelog](https://keepachangelog.com/es/1.0.0/).

## [Sin publicar]

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
