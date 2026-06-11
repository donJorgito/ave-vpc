### ave-vpc.REQ-NET-44 - Rotación de MAC del WiFi para resetear la cuota de datos del portal Icomera del AVE

**Status:** Implementado en script (`tools/mac-rotate.sh`), validado
estático. Validación runtime pendiente próximo trayecto AVE.

**Description:**

El router onboard del AVE (plataforma Icomera/Nomad) impone un
`dataLimit` POR DISPOSITIVO — observado ~209 MB en el trayecto, tras
los cuales throttlea la conexión a un caudal inutilizable para
bonding. El identificador de "dispositivo" del portal es la **MAC del
adaptador WiFi** del cliente. Cambiar la MAC del adaptador presenta
una identidad nueva al portal y **resetea la cuota** (el captive
vuelve a ofrecer la franquicia completa, a costa de exigir
re-autenticación).

Es un mecanismo **POST-auth** y **ortogonal a la vía de bypass**: afecta
por igual a socat / udp2raw / wstunnel / ubond-directo (doc 13 sección
5.1). Por eso vive en una herramienta propia, no acoplada a ningún
wrapper.

`tools/mac-rotate.sh` rota la MAC efectiva de `IFACE_WIFI` en macOS:

```text
--show     MAC actual (ether) + MAC hardware (sistema) + original persistida
--rotate   genera+aplica una MAC aleatoria locally-administered unicast
--restore  vuelve a la MAC hardware original
```

**Mecánica macOS:** la MAC efectiva solo cambia con la interfaz
desasociada/down. El flujo es: `airport <iface> -z` (desasocia 802.11)
→ `ifconfig <iface> down` → `ifconfig <iface> ether <newmac>` →
`ifconfig <iface> up`. El cambio **NO persiste tras reboot** —
aceptable (el throttle también se resetea por sesión).

**Bit-math de la MAC (seguridad — un valor inválido brickea el WiFi
hasta `--restore`):**

Sobre el PRIMER octeto, bits numerados desde 0 (LSB):

- bit 0 (`0x01`) = I/G : 0 → unicast, 1 → multicast (rompería el WiFi).
- bit 1 (`0x02`) = U/L : 0 → universal (OUI), 1 → locally-administered.

Se genera `(rand & 0xFE) | 0x02` para el primer octeto:

- `& 0xFE` LIMPIA bit 0 → garantiza **unicast**.
- `| 0x02` PRENDE bit 1 → garantiza **locally-administered**.

Esto FUERZA ambos bits con independencia del valor aleatorio: la MAC
nunca será multicast ni colisionará con un OUI asignado. Los otros 5
octetos son aleatorios. `is_valid_local_unicast()` re-valida el valor
ANTES de pasarlo a `ifconfig` (defensa en profundidad).

**Recuperación garantizada del original:** antes de la PRIMERA
rotación, `persist_original_once()` lee la MAC HARDWARE del sistema
(`networksetup -getmacaddress`, fallback `ioreg IOMACAddress`) y la
escribe en `generated/mac-rotate-original-<iface>.mac`. La función es
idempotente: si el fichero ya existe (rotaciones encadenadas), NO se
sobrescribe. Así `--restore` siempre recupera el hardware real aunque
se hayan hecho N rotaciones seguidas. `networksetup`/`ioreg` reportan
la MAC permanente incluso con la efectiva ya rotada, por lo que
`--restore` funciona incluso sin fichero de respaldo.

**Acoplamiento captive:** `--rotate`/`--restore` TIRAN la asociación
WiFi momentáneamente. Cualquier link ubond sobre WiFi parpadeará y el
portal pedirá re-auth. El script lo AVISA por log; el re-login lo
gestiona `tools/captive-watchdog.py` (detecta offline → reintenta).

**Acceptance Criteria:**

- `tools/mac-rotate.sh` existe, es ejecutable, usa `set -uo pipefail`
  y tiene guard bash >= 4 (house style).
- Expone subcomandos `--show`, `--rotate`, `--restore`.
- `--rotate` y `--restore` exigen root (`require_root`).
- La generación de MAC aplica `(rand & 0xFE) | 0x02` al primer octeto
  (unicast + locally-administered), comentado explícitamente.
- `is_valid_local_unicast()` valida formato + bit I/G=0 + bit U/L=1
  antes de tocar `ifconfig`.
- Persiste la MAC hardware original en
  `generated/mac-rotate-original-<iface>.mac` de forma idempotente
  (no sobrescribe si ya existe).
- Lee `IFACE_WIFI` de `config/env` (sin hardcoding — Rule 4); todas
  las expansiones de la interfaz van entrecomilladas (sin inyección).
- Usa `logger -t mac-rotate` y AVISA del blip de la asociación WiFi.
- `bash -n` y `shellcheck --severity=warning` limpios.
- Test estático `tests/test_REQ-NET-44_mac_rotate.sh` pasa todos los
  checks.

**Verification:**

- **Estática:** `tests/test_REQ-NET-44_mac_rotate.sh` (existe,
  ejecutable, subcomandos, bit-math, validador, persistencia,
  config/env, sin IP hardcodeada, `bash -n`).
- **Runtime (pendiente):** próximo trayecto AVE:
  1. `sudo tools/mac-rotate.sh --show` → anotar MAC hardware.
  2. Consumir cuota hasta throttle observado.
  3. `sudo tools/mac-rotate.sh --rotate` → confirmar MAC efectiva
     cambia a una locally-administered y el portal vuelve a ofrecer
     franquicia tras re-auth (captive-watchdog).
  4. Medir caudal recuperado vs. throttled.
  5. `sudo tools/mac-rotate.sh --restore` → confirmar vuelta a la MAC
     hardware original.

**Riesgos:**

- **MAC inválida brickea el WiFi:** mitigado por bit-math forzada +
  `is_valid_local_unicast()` pre-aplicación.
- **Pérdida del original:** mitigado por persistencia idempotente +
  fallback a `networksetup`/`ioreg` (MAC permanente).
- **Blip de la asociación:** esperado y avisado; el captive-watchdog
  reautentica. No ejecutar en mitad de un flujo crítico.
- **Colisión de identidad en el portal:** dos rotaciones a la misma
  MAC aleatoria es improbable (2^46 combinaciones) pero posible; el
  operador puede re-rotar.
- **Detección anti-abuso del operador:** rotar MAC repetidamente puede
  ser detectado/bloqueado por Icomera. Uso moderado.

**Related:**

- `tools/mac-rotate.sh` — implementación.
- `tools/captive-watchdog.py` — re-auth tras el blip de asociación.
- `docs/v2-ubond/13-plan-bypass-wifi-tren.md` — sección 5.1 (riesgo
  cuota/MAC) que motiva este REQ.
- `config/env` — `IFACE_WIFI` consumida por el script.
- [[REQ-NET-45]] — banco de medida que cuantifica el caudal recuperado
  tras la rotación.
