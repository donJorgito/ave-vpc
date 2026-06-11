### ave-vpc.REQ-NET-42 - Vía D: launcher de túnel DNS (iodine) como link de vida para ubond

**Status:** Implementado en script (`tools/wrap-iodine.sh`), validado
estático. Validación runtime pendiente próximo trayecto AVE. Bloqueado
para uso real por la delegación NS (prerrequisito de infra del operador).

**Description:**

El firewall del WiFi del AVE (router Icomera/Nomad) bloquea TODO el UDP
outbound (confirmado 2026-06-09) y DNAT-ea `tcp/80+443` al portal cautivo.
ubond es UDP-only por diseño, así que ninguna vía directa cruza pre-auth.
Sin embargo, el walled garden del portal DEBE resolver DNS pre-auth (lo
necesita para mostrar el propio portal). La Vía D explota ese hueco con un
**túnel DNS** (iodine): el cliente codifica datos en queries DNS al resolver
del WiFi, que las reenvía por la jerarquía DNS hasta un servidor autoritativo
(`iodined`) corriendo en la RPi para un subdominio delegado por NS.

Throughput bajísimo (decenas de kbps), RTT alto. NO es para ancho de banda:
es un **link de vida / último recurso** para tunelar el control/keepalive de
ubond (o un path mínimo de datos) cuando A (faketcp), B (WSS), C (socat) y E
(ICMP) están todas KO. El cliente ubond apuntaría su `[links.wifi]` al extremo
del túnel DNS (interfaz `dnsX` que iodine levanta), no a `127.0.0.1`.

`tools/wrap-iodine.sh` es el launcher cliente (Mac), house-style espejo de
`wrap-udp2raw.sh`: `set -uo pipefail`, guard bash>=4, source `config/env`,
PID file en `generated/`, idempotente, `--check`/`--stop`/`--server-cmd`,
`logger -t`, versión PINNED en el hint, y `print_server_cmd()` que emite el
comando `iodined` exacto a ejecutar en la RPi (el script NO hace ssh).

**Prerrequisito de infra (lo hace el OPERADOR, no el script):**

iodine necesita un subdominio cuyo registro NS apunte a la RPi. Para
`IODINE_SUBDOMAIN="t.200bares.dedyn.io"`, en el panel deSEC de
`200bares.dedyn.io` el operador debe crear:

```text
t            IN NS   ns.t.200bares.dedyn.io.
ns.t         IN A    <IP pública del operador / RPi>
```

y abrir port-forward `53/udp` del router hacia la RPi
(`192.168.1.101`). Verificación previa obligatoria:
`dig NS t.200bares.dedyn.io` debe devolver `ns.t.200bares.dedyn.io`. El
wrapper NO crea registros DNS; asume que la delegación ya existe.

**Secreto compartido (-P):**

iodine autentica cliente/server con un secreto `-P`. `wrap-iodine.sh` lo
resuelve igual que `wrap-udp2raw.sh` su PSK: env `IODINE_PASSWORD` →
`generated/wrap_iodine.pass` (si existe) → generación `openssl rand -hex 16`
persistida con `chmod 600`. Ambos extremos DEBEN usar el MISMO `-P`. El
secreto NO se imprime en el log de arranque (que puede no ser 0600); solo se
revela deliberadamente en `--server-cmd`.

**Acceptance Criteria:**

- `tools/wrap-iodine.sh` existe, es ejecutable, `bash -n` y
  `shellcheck --severity=warning` limpios.
- Expone `--check`, `--stop`, `--server-cmd`; idempotente (PID file +
  `kill -0` + "ya corriendo"); usa `logger -t wrap-iodine`.
- Lee `VPS_IP`/`UBOND_PORT_3` de `config/env`; no hardcodea IP pública.
- Declara `IODINE_PINNED_VERSION` (0.7.0, verify tag) con hints brew (Mac)
  y apt/release (RPi).
- `IODINE_SUBDOMAIN` es configurable y OBLIGATORIO en arranque (aborta con
  mensaje claro si falta); resolver DNS configurable (`IODINE_DNS_SERVER`),
  default autodetectado (el del WiFi).
- Exige root (TUN) en arranque; el secreto `-P` se genera/persiste con
  `chmod 600` y NO se imprime en el log de arranque.
- `print_server_cmd()` emite el comando `iodined` exacto, referencia el
  prerrequisito de delegación NS, e incluye el `-P` real.
- La cabecera del script y este requirement documentan que la delegación NS
  en deSEC es un prerrequisito que ejecuta el operador.
- Test estático `tests/test_REQ-NET-42_dns_tunnel.sh` pasa.

**Verification:**

- **Estática:** `tests/test_REQ-NET-42_dns_tunnel.sh` (estructura, flags,
  versión PINNED, no-hardcoding, source config/env, `bash -n`).
- **Runtime (pendiente):** próximo trayecto AVE, tras delegación NS y
  port-forward 53/udp:
  1. `sudo tools/wrap-iodine.sh --check` confirma binario.
  2. `iodined` en RPi (de `--server-cmd`); `dig NS` confirma delegación.
  3. `sudo IODINE_SUBDOMAIN=t.200bares.dedyn.io tools/wrap-iodine.sh`
     levanta `dnsX` y hace ping al extremo del túnel.
  4. ubond apunta `[links.wifi]` al extremo `dnsX`; confirmar keepalive.

**Riesgos:**

- **Delegación NS:** sin ella la vía no existe. Toca el dominio deSEC
  `200bares.dedyn.io` — decisión de infra, no de código.
- **Detección DPI DNS:** algunos portales inspeccionan/limitan queries
  anómalas (TXT/NULL grandes, alta frecuencia). Si Renfe lo hace, la vía
  cae. No se ha probado en Renfe (vía abierta, no cerrada).
- **Throughput:** decenas de kbps; inútil para datos pesados. Por diseño:
  link de vida, no path productivo.
- **Resolver bloqueado:** si el captive solo permite su propio resolver,
  forzar `IODINE_DNS_SERVER` al gateway del captive.

**Related:**

- `docs/v2-ubond/13-plan-bypass-wifi-tren.md` — sección 2, Vía D.
- [[REQ-NET-43]] — Vía E (ICMP, ptunnel-ng), el otro link de vida.
- [[REQ-NET-39]] — Vías A/B/C (UDP-over-X), wrappers hermanos house-style.
- `tools/wrap-udp2raw.sh` — patrón de PSK/`--server-cmd`/root espejado aquí.
- `config/env` — `VPS_IP`, `UBOND_PORT_3` consumidos por el wrapper.
- `tools/wrap-iodine.sh` — implementación.
- `tests/test_REQ-NET-42_dns_tunnel.sh` — validación estática.
