### ave-vpc.REQ-NET-23 - Smoke-test adaptativo ubond (tools/smoke-*)

**Description:**

`tools/smoke-{casa,cafe,ave}.sh` son tres orchestrators que validan en
runtime el dataplane ubond bajo distintos entornos de red:

- `smoke-casa.sh` — RPi alcanzable por LAN (192.168.1.101). iPhone/Pixel
  obligatorios; WiFi excluido por hairpin NAT.
- `smoke-cafe.sh` — RPi sólo por DDNS. WiFi (sin captive) + tethering
  opcional.
- `smoke-ave.sh` — RPi por DDNS. iPhone+Pixel obligatorios; tests
  repetidos en bucle de 4 rondas para capturar oscilación.

Cada orchestrator carga librerías compartidas en `tools/lib/` que NO se
duplican entre scripts (regla: un script por entorno, lógica reutilizable
en libs):

- `_common.sh` — logging, require_root, as_invoker (drop-priv para SSH).
- `env-detect.sh` — detección de WiFi/iPhone/Pixel IPs, captive portal,
  alcanzabilidad LAN/DDNS, selección automática del target SSH.
- `conf-gen.sh` — generación de `${SMOKE_TMPDIR}/ubond_smoke.conf` a
  partir de los links elegibles + remote target.
- `tcpdump.sh` — capturas Mac (multi-iface) y RPi (vía SSH como user
  invocador, no como root).
- `ubond-runner.sh` — cleanup zombies, start/stop con conf temporal,
  wait_auth, find_utun_iface.
- `tests.sh` — ping ICMP, curl HTTP por túnel, throughput 1MB Cloudflare,
  netcat UDP probe.
- `report.sh` — diagnóstico automático: cuenta paquetes en cada punto
  (Mac out / RPi in / RPi tun out / Mac utun in) y emite veredicto en
  markdown.

Diseño "una password sudo por run": el orchestrator se invoca como
`sudo -E ./tools/smoke-X.sh`. `_common.sh:require_root` valida EUID==0
al inicio. Las libs ejecutan ops privilegiadas (tcpdump, ifconfig,
pkill) directamente. Las ops como SSH/scp se delegan a `as_invoker` que
dropea privilegios al `${SUDO_USER}` original.

**Parent Requirement:** ave-vpc.REQ-NET-22 (depende del cliente
04b-conectar-ubond.sh).

**Acceptance Criteria:**

- Existen `tools/smoke-casa.sh`, `tools/smoke-cafe.sh`, `tools/smoke-ave.sh`,
  todos ejecutables, todos pasan `bash -n` y `shellcheck`.
- Existen las 7 libs en `tools/lib/`: `_common.sh`, `env-detect.sh`,
  `conf-gen.sh`, `tcpdump.sh`, `ubond-runner.sh`, `tests.sh`, `report.sh`.
- Las libs NO se ejecutan al ser sourceadas — solo definen funciones.
- Cada orchestrator hace `require_root` (chequeo EUID).
- Cada orchestrator hace `trap cleanup EXIT INT TERM` que para tcpdump
  y ubond.
- Las libs no duplican código relevante entre sí (cada función vive en
  una sola lib).
- El reporte automático distingue 4 puntos de captura y emite veredicto
  texto plano sobre dónde muere el paquete.

**Verification:** test estático `test_REQ-NET-23_smoke_lib.sh` que
comprueba existencia de archivos, sintaxis, presencia de funciones
clave en cada lib, y require_root en orchestrators.

**Related:**

- [[REQ-NET-22]] — cliente ubond.
- [[REQ-NET-19]] — patches macOS.
- [[REQ-NET-12]] — replicación selectiva (filtros).
