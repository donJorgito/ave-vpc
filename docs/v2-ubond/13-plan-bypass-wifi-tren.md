# Plan de trabajo — Bypass del firewall WiFi del tren para tunelar ubond

**Fecha:** 2026-06-11 (oficina)
**Branch:** `feat/ubond-evaluation`
**Estado:** propuesta de trabajo — pendiente de triar qué ejecutar

---

## 0. Marco mental: pensar como el operador

El WiFi del AVE lo provee un router onboard tipo **Icomera/Nomad** que agrega
varios módems celulares. Para imponer captive portal + filtrar, el patrón
estándar de la industria es:

- **DNAT por puerto** de `tcp/80` y `tcp/443` hacia el portal cautivo
  (walled garden). Esto explica el "MitM HTTPS universal" observado el
  2026-06-09: **no es inspección criptográfica por destino, es redirección
  por puerto** — por eso 4 IPs destino distintas devuelven el mismo cert
  `playrenfe`. Es DNAT de `:443`, no un proxy TLS que discrimine SNI.
- **Bloqueo total de UDP outbound** (vía típica de VPNs WireGuard/OpenVPN;
  barato de capar con una regla `DROP udp`).
- **Walled garden**: pre-auth se permite DNS (el portal necesita resolver) +
  el rango de IPs del propio portal.

### Qué está CONFIRMADO (evidencia 2026-06-09, cert dump verificado)

- UDP outbound 100% KO (7 puertos × 2 destinos = 0/14 replies).
- TCP/443 → DNAT al portal (cert Sectigo Renfe en 4 destinos distintos).
- ICMP outbound funciona con loss alto (1/3 a 1.1.1.1, RTT 90-654ms).

### Qué NO se ha probado nunca (vías abiertas, NO cerradas)

- **TCP en puertos no estándar** (8080, 2222, 993, 8443, alto random). Los
  operadores rara vez DNAT-ean todo el rango TCP; típicamente solo 80/443.
- **DNS tunneling** (iodine/dns2tcp) — el walled garden resuelve DNS pre-auth.
- **ICMP tunneling** (ptunnel-ng) — ICMP confirmado funcional, aunque lossy.
- **Comportamiento del DNAT :443**: ¿termina TLS de verdad (proxy) o solo
  redirige el SYN al portal? Determina si wstunnel/TLS real puede atravesarlo.

> **Nota de método:** la WiFi de oficina NO reproduce Renfe. El objetivo de
> la fase oficina es dejar **toda la fontanería montada y validada end-to-end**
> (Mac↔RPi) de modo que en el trayecto solo haya que contestar UNA pregunta
> por vía: "¿sobrevive este transporte al firewall Renfe?". Sin fontanería
> previa, cada experimento mid-trip se come el tiempo de un trayecto entero.

---

## 1. Arquitectura del wrapper (común a casi todas las vías)

ubond es **UDP-only por diseño** (socket `SOCK_DGRAM`, `sendto`/`recvfrom`,
crypto libsodium a nivel de datagrama — `ubond.c:1320,1334,469,848,788`).
**No se toca ubond.** El wrapper va POR FUERA:

```text
  Mac                                             RPi (200bares.dedyn.io)
  ┌──────────────┐   UDP local    ┌─────────┐    ┌─────────┐   UDP local   ┌────────┐
  │ ubond client │ ──────────────▶│ wrapper │════│ wrapper │──────────────▶│ ubond  │
  │ (utun7)      │ 127.0.0.1:PORT │ cliente │ TCP│ servidor│ 127.0.0.1:5085│ server │
  └──────────────┘                └─────────┘ /  └─────────┘               └────────┘
                                            otro
                                          transporte
```

ubond apunta su `[links.wifi]` a `127.0.0.1:<puerto-local-del-wrapper>` en vez
de a la IP del RPi. El wrapper se encarga de cruzar el firewall. El resto del
bonding (iPhone/Pixel por UDP directo) no cambia.

---

## 2. Aproximaciones (vías de bypass) y sus pruebas

Ordenadas por probabilidad estimada de éxito × coste de montaje. Cada vía es
**independiente**: se pueden montar todas en oficina y luego elegir cuáles
llevar al tren.

### Vía A — UDP-over-TCP en puerto NO estándar (udp2raw / phantun, modo faketcp)

**Hipótesis Renfe:** el DNAT solo captura 80/443; un TCP a `:2222` o `:8443`
sale limpio. faketcp emite paquetes que *parecen* TCP a un stateful firewall
sin hacer handshake real → pasa filtros "solo-TCP-permitido".

- **Riesgo:** si Renfe hace DNAT de TODO el rango TCP, no pasa. Si hay un
  proxy TLS-terminating en 443, faketcp no aplica (no es TLS).
- **Montaje oficina:** udp2raw server en RPi (`-r` raw mode), client en Mac,
  ubond por encima. Requiere root en ambos (raw sockets).

### Vía B — UDP-over-WebSocket/TLS (wstunnel)

**Hipótesis Renfe:** si el DNAT :443 es un proxy que termina TLS y reenvía por
Host/SNI, un WebSocket-over-HTTPS legítimo hacia un Host que el portal acepte
podría tunelarse *a través* del propio proxy. Es la vía más robusta frente a
un MitM real.

- **Riesgo:** si el proxy valida que el backend es el portal y no un origin
  arbitrario, corta. Necesita un endpoint TLS válido en el RPi (cert).
- **Montaje oficina:** wstunnel server en RPi (TLS, puerto 443 o 8443),
  client en Mac expone UDP local, ubond por encima. Probar con y sin TLS real.

### Vía C — UDP-over-TCP "clásico" (stunnel + socat, o socat solo)

Wrapper genérico y bien entendido. socat hace `UDP-LISTEN ↔ TCP`, stunnel
añade TLS si hace falta. Menos sigiloso que A/B pero trivial de montar y
diagnosticar; sirve de **baseline** para confirmar que ubond tolera ir sobre
TCP antes de pelear con sigilo.

- **Montaje oficina:** socat en ambos extremos; medir overhead/latencia que
  añade el reensamblado UDP→TCP→UDP frente a ubond directo.

### Vía D — DNS tunneling (iodine / dns2tcp)

**Hipótesis Renfe:** el walled garden DEBE resolver DNS pre-auth → un túnel
DNS sale aunque no haya pagado el captive. Throughput bajísimo (decenas de
kbps) pero podría servir para señalización/keepalive o como link de último
recurso.

- **Riesgo:** requiere delegar un subdominio NS al RPi (infra DNS). Lento.
  Probablemente NO sirve para bonding de ancho de banda, sí para "hay vida".
- **Montaje oficina:** delegación NS de un subdominio de `200bares.dedyn.io`
  (o dominio aparte) → iodined en RPi. Validar que levanta `dns0` y pinga.

### Vía E — ICMP tunneling (ptunnel-ng)

**Hipótesis Renfe:** ICMP outbound confirmado funcional (06-09). ptunnel-ng
mete TCP/UDP dentro de echo request/reply.

- **Riesgo:** lossy (06-09 vio 1/3), latencia alta; firewall puede rate-limit
  ICMP. Igual que DNS: candidato a "link de vida", no a ancho de banda.
- **Montaje oficina:** ptunnel-ng server en RPi, client en Mac, ubond encima.

### Vía F — Probe sistemático del firewall (no es túnel, es reconocimiento)

Herramienta propia que, dada una WiFi, mapea **qué sale y qué no** sin tumbar
la conexión: barrido TCP connect a un set de puertos contra el RPi (que
escucha en todos), barrido UDP, test DNS-tunnel-viability, test ICMP. Produce
una tabla "puerto/protocolo → pasa/DNAT/silencio". Es lo que convierte el
trayecto en "ejecutar probe → leer tabla" en vez de improvisar.

- **Montaje oficina:** listener multipuerto en RPi + script de barrido en Mac.
  Validar contra WiFi oficina (esperado: casi todo abierto) para sanity.

---

## 3. Infraestructura transversal (la necesitan varias vías)

- **T1 — Listener multipuerto en RPi:** un servicio que acepte
  TCP+UDP en un set de puertos (22, 80, 443, 853, 993, 2222, 8080, 8443, alto
  random) y responda un eco identificable. Base de la Vía F y del bring-up de
  A/B/C. Idempotente, systemd, parable.
- **T2 — Wrapper como link ubond:** generalizar `[links.wifi]` para que
  pueda apuntar a `127.0.0.1:<port>` (salida del wrapper local) en vez de a
  `VPS_IP:443/udp`. Parametrizar en `04b-conectar-ubond.sh` +
  `wifi-reintegrator.sh`. Sin esto, ninguna vía A-E entra al bonding.
- **T3 — Toolchain:** instalar en Mac (brew) y RPi (apt/compilar) las
  herramientas de las vías que decidamos: udp2raw, phantun, wstunnel, socat,
  stunnel, iodine, ptunnel-ng. Documentar versiones (Rule 7 IDLC: pin).
- **T4 — Banco de medida:** script que mide throughput + latencia + jitter +
  loss de ubond a través de cada wrapper, comparado con ubond directo, para
  ranquear las vías por coste-rendimiento (no solo "pasa/no pasa").

---

## 4. Captive portal (Task #3 heredada — ahora con su sitio correcto)

El re-login del captive **solo tiene sentido acoplado a una vía que funcione**:
da igual reautenticar si el transporte no cruza. Pero es ortogonal al wrapper
(el captive hay que pasarlo SIEMPRE para tener IP utilizable). Por eso entra
como bloque propio:

- **C1 — Watchdog canary tri-valor:** probe HTTP-plano a un canary cada 1-3s,
  estado `online`/`offline`/`None` (None = WiFi caído, no re-login). Base
  empírica: interval 3s / timeout 2.5s. Patrón db_wlan_manager.
- **C2 — Re-login estilo wifionice:** GET portal → parsear hidden inputs
  (incl. CSRFToken) → re-POST con `login=true`. **Bloqueado por** captura real
  del form PlayRenfe (solo en tren). En oficina: implementar el motor genérico
  - tests con un form sintético; rellenar el form real en trayecto.
- **C3 — Clonar repos de referencia** que la memoria daba por presentes y NO
  están en disco (verificado hoy): makefu/prison-break (wifionice.py),
  sistason/db_wlan_manager, derhuerst/wifi-on-ice-portal-client,
  hannsadrian/onboard-api-discovery. En `build/` (gitignored).

---

## 5. Riesgos / decisiones que condicionan el plan

1. **MAC randomization & cuota:** Icomera observado con `dataLimit` ~209MB →
   throttle. Cambiar MAC resetea. Afecta a CUALQUIER vía (es post-auth). Hay
   que decidir si automatizamos rotación de MAC.
2. **Raw sockets / root:** udp2raw, phantun, ptunnel-ng, iodine requieren root
   en ambos extremos. El RPi ya corre ubond como servicio root; el Mac ya pide
   root en 04b. OK, pero documentar.
3. **DNS infra (Vía D):** requiere delegación NS — toca el dominio deSEC
   `200bares.dedyn.io`. Decisión de infra, no solo de código.
4. **IDLC v6:** cada vía que se implemente = REQ-NET-XX + test 1:1 +
   doc + CHANGELOG. NO empujar "minimal viable". Próximo REQ libre:
   **REQ-NET-38**.
5. **No romper v1/v2 estables:** todo esto es aditivo sobre
   `feat/ubond-evaluation`. mlvpn v1.0.0 y ubond bonding-móvil siguen siendo
   el path productivo.

---

## 6. Orden sugerido para fase oficina (a confirmar al triar)

```text
Bring-up común:   T1 (listener RPi) → T3 (toolchain) → T2 (wrapper-as-link)
Reconocimiento:   F  (probe firewall) — valida T1, da el mapa
Túnel baseline:   C-via (socat/stunnel) — confirma que ubond tolera TCP-wrap
Túnel sigiloso:   A (udp2raw/phantun) ∥ B (wstunnel) — los candidatos reales
Medida:           T4 (banco) sobre A/B/C — ranking
Último recurso:   D (DNS) ∥ E (ICMP) — solo si interesa "link de vida"
Captive:          C1 (watchdog) ∥ C2 (motor re-login) ∥ C3 (clonar refs)
```

Las vías A-E son paralelizables una vez T1+T2+T3 están. El captive (C1-C3) es
paralelo a todo lo demás.
