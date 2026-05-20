# Guía de contribución

Gracias por querer mejorar este proyecto. Aquí están las reglas del juego.

## Flujo de trabajo

1. Haz un fork del repositorio
2. Crea una rama: `git checkout -b usuario-descripcion-corta`
3. Haz tus cambios (ver [estándares](#estándares-de-código))
4. Ejecuta los tests: `./tests/verificar-setup.sh`
5. Abre un Pull Request con descripción clara de qué cambia y por qué

## Estándares de código

### Shell scripts
- Bash únicamente (`#!/usr/bin/env bash`)
- `set -euo pipefail` al inicio de cada script
- Compatibles con macOS y Linux (Ubuntu 26.04 LTS)
- Sin código hardcodeado — todo en `config/env`
- Pasar [ShellCheck](https://www.shellcheck.net/) sin warnings

### Commits
Formato: `tipo: descripción corta en imperativo`

| Tipo | Cuándo usarlo |
|------|---------------|
| `feat` | Nueva funcionalidad |
| `fix` | Corrección de bug |
| `docs` | Solo documentación |
| `refactor` | Cambio de código sin nueva funcionalidad ni fix |
| `test` | Añadir o corregir tests |
| `chore` | Mantenimiento (dependencias, CI, etc.) |

Ejemplo: `feat: añadir soporte para tercer enlace WiFi del tren`

### Mensajes de commit con IA
Si el commit contiene código generado o revisado con IA, añade al final:
```
Co-Authored-By: Claude <noreply@anthropic.com>
```

## Pre-commit hooks

Instala los hooks antes de tu primer commit:
```bash
pip install pre-commit
pre-commit install
```

Los hooks comprueban automáticamente ShellCheck y que no se suban secretos.

## Tests

Antes de abrir un PR, verifica que el script de tests pasa:
```bash
./tests/verificar-setup.sh
```

## ¿Qué tipos de contribución son bienvenidas?

- Soporte para otros proveedores de VPS (Hetzner, Vultr, IONOS...)
- Soporte para tercera SIM / tercer enlace
- Soporte para Linux como cliente (no solo macOS)
- Mejoras en la detección automática de interfaces
- Documentación y traducciones
- Corrección de bugs

## Lo que no aceptamos

- Cambios que rompan la compatibilidad con macOS sin añadir la alternativa Linux
- Hardcoding de IPs, usuarios o rutas específicas
- Credenciales, claves o secretos en el código
