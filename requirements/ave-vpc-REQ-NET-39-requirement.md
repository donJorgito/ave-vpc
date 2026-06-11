### ave-vpc.REQ-NET-39 - Wrappers UDP-over-X para tunelar ubond a través del firewall del WiFi del AVE

**Status:** Implementado en scripts (tres launchers cliente Vía A/B/C),
validado estático. Validación runtime (oficina end-to-end + trayecto
AVE) pendiente.

**Description:**

El WiFi del AVE (router onboard Icomera/Nomad) **bloquea todo el UDP
outbound** (confirmado 2026-06-09: 7 puertos × 2 destinos = 0/14
replies) y **DNAT-ea `tcp/80` y `tcp/443`** hacia el portal cautivo
(cert `playrenfe` en 4 destinos distintos → es redirección por puerto,
no proxy TLS por SNI). ubond es **UDP-only por diseño** (socket
`SOCK_DGRAM`, `sendto`/`recvfrom`, crypto libsodium a nivel de
datagrama — `ubond.c:1320,1334,469,848,788`). **No se toca ubond.**

Para que el link `[links.wifi]` sobreviva al firewall, ubond apunta ese
link a `127.0.0.1:<puerto-local>` en vez de a `VPS_IP:443/udp`, y un
**wrapper exterior** cruza el firewall:

```text
  ubond client --UDP--> 127.0.0.1:LOCAL_PORT (wrapper cliente)
      ==transporte==> RPi:WRAP_PORT (wrapper servidor)
      --UDP--> 127.0.0.1:5085 (ubond server real, UBOND_PORT_3)
```

Este REQ entrega los **tres launchers cliente** (Vías C/A/B del plan
`docs/v2-ubond/13-plan-bypass-wifi-tren.md`), cada uno parametrizable,
idempotente, parable, con `--check` y que **imprime el comando
server-side exacto** a ejecutar en la RPi (el script NO hace ssh):

- **Vía C — `tools/wrap-socat.sh`** (baseline): socat
  `UDP4-LISTEN:<local>` ↔ `TCP4:<rpi>:<port>`. La más simple de montar
  y diagnosticar; confirma que ubond TOLERA ir sobre TCP antes de pelear
  con sigilo. No sigilosa: un TCP real a puerto random pasa solo si
  Renfe NO DNAT-ea todo el rango TCP. stunnel (TLS) anotado como
  opcional, NO baseline.
- **Vía A — `tools/wrap-udp2raw.sh`** (faketcp stealth): udp2raw en
  `--raw-mode faketcp` sobre puerto TCP no estándar (default 8443).
  faketcp fabrica paquetes que *parecen* TCP a un firewall stateful sin
  handshake real → cruza filtros "solo-TCP-permitido". Requiere root en
  ambos extremos (raw sockets) y PSK compartida `-k`. Falla si Renfe
  DNAT-ea TODO el rango TCP o si hay proxy TLS-terminating real en 443.
- **Vía B — `tools/wrap-wstunnel.sh`** (WebSocket/TLS, más robusto vs
  MitM): wstunnel cliente expone UDP local ↔ WSS al server RPi. WSS-sobre-443
  puede tunelar A TRAVÉS de un proxy TLS-terminating (handshake TLS real
  - `Upgrade: websocket`, indistinguible de HTTPS de navegador) donde
  faketcp no puede. Variantes con y sin TLS documentadas.

**Por qué tres vías y no una:** son independientes y de coste-riesgo
distinto. C es baseline de diagnóstico; A es sigilosa barata (si el DNAT
es solo 80/443); B es la más robusta frente a MitM real (si 443 es proxy
TLS). En oficina se montan las tres; en el trayecto cada una responde
UNA pregunta: "¿sobrevive este transporte al firewall Renfe?".

**Mecanismo común de los launchers:**

- Cargan `config/env` para `VPS_IP` y `UBOND_PORT_3` (5085) — sin
  hardcoding de IPs/puertos (Rule 4 IDLC). Overrides por env
  (`WRAP_LOCAL_PORT`, `WRAP_REMOTE_HOST`, `WRAP_REMOTE_PORT`/`UDP2RAW_PORT`/`WS_PORT`).
- PID file en `generated/wrap_<via>.pid`; rechazan doble lanzamiento
  (idempotencia) comprobando `kill -0` del pid previo.
- `trap INT TERM` mata el hijo y borra el PID file (parable limpio).
  Modo `--stop` explícito.
- `log()` vía `logger -t wrap-<via>` + tee a `generated/wrap_<via>.log`.
- Modo `--check`: verifica binario instalado; si falta, imprime hint
  brew/apt con **versión PINNED** (Rule 7 IDLC).
- Modo `--server-cmd`: imprime SOLO el comando RPi y sale.

**Acceptance Criteria:**

- Existen y son ejecutables: `tools/wrap-socat.sh`,
  `tools/wrap-udp2raw.sh`, `tools/wrap-wstunnel.sh`.
- Cada uno arranca con `set -uo pipefail` y guard `bash >= 4`.
- Ninguno hardcodea IPs: `VPS_IP`/`WRAP_REMOTE_HOST` y `UBOND_PORT_3`
  vienen de `config/env`/env (Rule 4 IDLC).
- Cada uno soporta `--check`, `--stop`, `--server-cmd`.
- `--check` imprime un hint de instalación con versión PINNED cuando el
  binario falta (Rule 7 IDLC).
- Idempotencia: con un PID file fresco + proceso vivo, una segunda
  invocación sale 0 sin lanzar un segundo proceso (rechazo doble
  lanzamiento presente en los tres).
- Cada launcher imprime el comando server-side a ejecutar en la RPi y
  NO ejecuta ssh ni el lado servidor.
- `wrap-udp2raw.sh` exige root (raw sockets) y usa una PSK `-k`
  compartida (env `UDP2RAW_KEY` o generada+persistida en
  `generated/wrap_udp2raw.key`).
- `wrap-wstunnel.sh` soporta variante TLS (default, `wss://`) y sin TLS
  (`WRAP_WS_TLS=0`, `ws://`).
- `bash -n` pasa en los tres scripts.
- Test estático `tests/test_REQ-NET-39_udp_wrappers.sh` pasa todos los
  checks (existencia, ejecutable, flags expuestos, lógica anti-doble
  lanzamiento, sin hardcoding de IP, versión pineada en `--check`,
  sintaxis bash).

**Verification:**

- **Estática:** `tests/test_REQ-NET-39_udp_wrappers.sh` — PASS al
  implementar (2026-06-11).
- **Runtime (pendiente):**
  1. **Oficina end-to-end (por vía):** lanzar el wrapper server en la
     RPi (comando que imprime `--server-cmd`) + el cliente en el Mac,
     apuntar `[links.wifi]` de ubond a `127.0.0.1:<LOCAL_PORT>`, y
     confirmar que el link `wifi` sube en el proctitle de ubond y pasa
     tráfico (ping al gateway `UBOND_TUN_VPS_IP`).
  2. **Trayecto AVE (por vía):** misma fontanería; única pregunta por
     vía: ¿el transporte cruza el firewall Renfe? Esperado: C/A pasan si
     el DNAT es solo 80/443; B pasa si 443 es proxy TLS-terminating.
  3. **Medida (T4 plan 13):** throughput/latencia/jitter/loss de ubond a
     través de cada wrapper vs ubond directo, para ranquear vías.

**Riesgos:**

- **DNAT de todo el rango TCP:** si Renfe DNAT-ea más que 80/443, C y A
  no encuentran puerto limpio. No verificado (probe pendiente, Vía F del
  plan).
- **Proxy TLS-terminating que valida origin:** si el proxy :443 rechaza
  backends que no sean el portal, B también cae. Mitigación parcial:
  variante `ws://` a puerto alto limpio.
- **Overhead UDP→TCP→UDP (Vía C):** el reensamblado y el head-of-line
  blocking de TCP pueden degradar el bonding bajo pérdida; C es baseline
  de diagnóstico, no necesariamente la vía productiva.
- **Raw sockets / root (Vía A):** udp2raw exige root en ambos extremos;
  la regla iptables `-a` que evita el RST del kernel debe persistir en la
  RPi. PSK compartida: si difiere entre extremos, no hay túnel.
- **CLI de wstunnel:** la serie v10 (asumida, pineada 10.1.6) tiene CLI
  distinta de la v6 antigua (`client`/`server` + `-L udp://...`). Una
  versión equivocada en la RPi rompe el comando server-side impreso.
- **TTL/cert WSS self-signed:** el cliente usa
  `--tls-verify-certificate=false` para self-signed; en producción
  convendría un cert real del FQDN DDNS.

**Related:**

- `docs/v2-ubond/13-plan-bypass-wifi-tren.md` — plan de bypass; este REQ
  implementa los launchers cliente de Vías C (§2 Vía C), A (§2 Vía A) y
  B (§2 Vía B). Infra transversal T1/T2/T3 (listener RPi, wrapper-as-link,
  toolchain) son REQs separados.
- [[REQ-NET-36]] — SIGHUP purga filters (link wifi reintegrado tras flap).
- `config/env` — `VPS_IP`, `UBOND_PORT_3` (5085), `UBOND_PORT_3_REMOTE`
  consumidos por los wrappers.
- `tools/ubond-watchdog.sh` — house style (set -uo pipefail, PID en
  generated/, logger -t) replicado en los tres launchers.
- `tools/wrap-socat.sh`, `tools/wrap-udp2raw.sh`, `tools/wrap-wstunnel.sh`
  — implementación.
- `tests/test_REQ-NET-39_udp_wrappers.sh` — validación estática.
