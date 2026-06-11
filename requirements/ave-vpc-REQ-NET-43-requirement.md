### ave-vpc.REQ-NET-43 - Vía E: launcher de túnel ICMP (ptunnel-ng) como link de vida para ubond

**Status:** Implementado en script (`tools/wrap-ptunnel.sh`), validado
estático. Validación runtime pendiente próximo trayecto AVE.

**Description:**

El firewall del WiFi del AVE (router Icomera/Nomad) bloquea TODO el UDP
outbound (confirmado 2026-06-09) y DNAT-ea `tcp/80+443` al portal cautivo,
pero el **ICMP outbound está CONFIRMADO funcional** (2026-06-09: echo a
1.1.1.1, 1/3 replies, RTT 90-654ms). La Vía E explota ese hueco con un
**túnel ICMP** (ptunnel-ng): el cliente encapsula TCP/UDP dentro de ICMP echo
request, el proxy ICMP en la RPi lo desencapsula y lo entrega a ubond real en
`127.0.0.1:5085`, y las respuestas vuelven como echo reply.

ICMP en el AVE es lossy (1/3 observado) y de latencia alta/variable, y el
firewall puede rate-limitar ICMP en cualquier momento. NO es para ancho de
banda: es un **link de vida / último recurso** para keepalive/señalización de
ubond cuando A (faketcp), B (WSS), C (socat) y D (DNS) están todas KO. ubond
debe tolerar pérdida/latencia en este link (degradación, no muerte) — por eso
es path de último recurso, no productivo.

`tools/wrap-ptunnel.sh` es el launcher cliente (Mac), house-style espejo de
`wrap-udp2raw.sh`: `set -uo pipefail`, guard bash>=4, source `config/env`,
PID file en `generated/`, idempotente, `--check`/`--stop`/`--server-cmd`,
`logger -t`, versión PINNED en el hint, y `print_server_cmd()` que emite el
comando `ptunnel-ng` proxy exacto para la RPi (el script NO hace ssh).

El cliente expone un puerto local (default `UBOND_PORT_3`/5085) al que ubond
apunta su `[links.wifi]` (`127.0.0.1:LOCAL_PORT`); el cliente fija el destino
final tras el proxy (`-R 127.0.0.1 -P <ubond>`), de modo que el server solo
necesita el modo proxy con el secreto compartido.

**Secreto compartido (-x):**

ptunnel-ng autentica con `-x`. `wrap-ptunnel.sh` lo resuelve igual que
`wrap-udp2raw.sh` su PSK: env `PTUNNEL_PASSWORD` →
`generated/wrap_ptunnel.pass` (si existe) → generación `openssl rand -hex 16`
persistida con `chmod 600`. Ambos extremos DEBEN usar el MISMO `-x`. El
secreto NO se imprime en el log de arranque (que puede no ser 0600); solo se
revela deliberadamente en `--server-cmd`.

**Acceptance Criteria:**

- `tools/wrap-ptunnel.sh` existe, es ejecutable, `bash -n` y
  `shellcheck --severity=warning` limpios.
- Expone `--check`, `--stop`, `--server-cmd`; idempotente (PID file +
  `kill -0` + "ya corriendo"); usa `logger -t wrap-ptunnel`.
- Lee `VPS_IP`/`UBOND_PORT_3` de `config/env`; no hardcodea IP pública.
- Declara `PTUNNEL_PINNED_VERSION` (1.42, verify tag) con hints brew (Mac)
  y apt/release (RPi).
- Exige root (raw ICMP sockets) en arranque; el secreto `-x` se
  genera/persiste con `chmod 600` y NO se imprime en el log de arranque.
- `print_server_cmd()` emite el comando `ptunnel-ng` proxy exacto e incluye
  el `-x` real.
- La cabecera del script y este requirement documentan el caveat
  lossy/alta-latencia y que la vía es para keepalive/último recurso, NO para
  ancho de banda.
- Test estático `tests/test_REQ-NET-43_icmp_tunnel.sh` pasa.

**Verification:**

- **Estática:** `tests/test_REQ-NET-43_icmp_tunnel.sh` (estructura, flags,
  versión PINNED, no-hardcoding, source config/env, `bash -n`).
- **Runtime (pendiente):** próximo trayecto AVE:
  1. `sudo tools/wrap-ptunnel.sh --check` confirma binario.
  2. `ptunnel-ng` proxy en RPi (de `--server-cmd`).
  3. `sudo tools/wrap-ptunnel.sh` levanta el cliente; comprobar que el túnel
     ICMP transporta tráfico de y hacia ubond real.
  4. ubond apunta `[links.wifi]` a `127.0.0.1:5085`; confirmar keepalive
     (no se espera throughput, solo "hay vida").

**Riesgos:**

- **Loss/latencia:** ICMP en el AVE perdió 2/3 de los echos (06-09). ubond
  podría declarar el link muerto si el keepalive no tolera esa pérdida.
  Mitigación: subir tolerancia del link en la conf ubond para este path.
- **Rate-limit ICMP:** el firewall puede capar ICMP a posteriori; la vía
  podría caer mid-sesión. No probado en Renfe con túnel real (vía abierta).
- **Throughput:** ínfimo; inútil para datos pesados. Por diseño: link de
  vida, no path productivo.

**Related:**

- `docs/v2-ubond/13-plan-bypass-wifi-tren.md` — sección 2, Vía E.
- [[REQ-NET-42]] — Vía D (DNS, iodine), el otro link de vida.
- [[REQ-NET-39]] — Vías A/B/C (UDP-over-X), wrappers hermanos house-style.
- `tools/wrap-udp2raw.sh` — patrón de PSK/`--server-cmd`/root espejado aquí.
- `config/env` — `VPS_IP`, `UBOND_PORT_3` consumidos por el wrapper.
- `tools/wrap-ptunnel.sh` — implementación.
- `tests/test_REQ-NET-43_icmp_tunnel.sh` — validación estática.
- `project_renfe_udp_block.md` (memoria) — evidencia ICMP funcional 06-09.
