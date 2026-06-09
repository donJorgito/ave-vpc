### ave-vpc.REQ-NET-37 - Pre-resolución DNS de hosts en filters.replicate antes de lanzar ubond

**Status:** Implementado en script (Opción C, pre-resolver en 04b),
validado estático. Validación runtime pendiente próximo trayecto AVE.

**Description:**

`generated/ubond.conf` (template) declara dos entradas en
`[filters.replicate]` con cláusula BPF `host <fqdn>`:

```text
anthropic_api  = "tcp and dst port 443 and host api.anthropic.com"
claude_ai      = "tcp and dst port 443 and host claude.ai"
```

`pcap_compile()` con `host <fqdn>` invoca internamente
`pcap_nametoaddr()` → `getaddrinfo()` del sistema. Si DNS está roto
en el momento del compile (típico AVE: WiFi del tren todavía
pre-captive, móvil 4G todavía sin IP estable, o resolver corporativo
bloqueado), `pcap_compile` falla con `unknown host` y `config.c`
emite `log_warnx("invalid replicate filter ... unknown host")`. La
entrada se descarta SIN reintento — replicación efectivamente OFF
para esa entrada el resto de la sesión, aunque DNS recupere después.

**Síntoma observado** (pcap AVE 2026-06-05): ambos filtros
`anthropic_api` y `claude_ai` ausentes en `ubond_replicate_filters`
tras el startup. Tráfico HTTPS hacia `api.anthropic.com` y
`claude.ai` no se replica — sale por un solo túnel WRR-elegido,
queda expuesto a los flaps de ese único enlace.

**Hipótesis confirmada:** auditor C/network 2026-06-08 trazó la ruta
`pcap_compile → pcap_nametoaddr → getaddrinfo`. Reproducible
sintéticamente bloqueando DNS local antes de lanzar `ubond
--config` con un conf que tenga `host <fqdn>` literal: WARN
"unknown host" + filtro descartado, sin reintento posterior.

**Why Opción C (pre-resolver en 04b) y no fix en C:**

- El fix en C (retry + SIGHUP cuando DNS recupera) es invasivo:
  toca `config.c` parser, añade timer libev en cliente, y requiere
  re-compilar el ubond del cliente Y del server. Diferido a futuro
  como `tools/ubond-watchdog.sh` (REQ separado, no este).
- La Opción C resuelve los `host <fqdn>` en el wrapper bash que ya
  genera `ubond_active.conf`. Una vez sustituido por IP literal,
  `pcap_compile` ya no toca DNS — el problema desaparece. Cero
  cambio en el binario ubond, cero impacto en el server, deploy
  inmediato en el cliente.
- Coste: la IP del filtro queda "congelada" al startup. Si el FQDN
  cambia de IP mid-sesión (anycast move, Anthropic CDN reshuffle),
  el filtro deja de matchear. Mitigación: cada `04b-conectar-ubond.sh`
  resuelve de nuevo, y los SOS.sh / re-conexión ciclan el script.
  Para servicios estables como `api.anthropic.com` el riesgo es
  bajo.

**Mecanismo del fix (04b Paso 3.7):**

- Tras `cp ubond.conf ubond_active.conf` y la sustitución
  `PLACEHOLDER_IPHONE_IP` / `PLACEHOLDER_PIXEL_IP`, ANTES de lanzar
  `/usr/local/sbin/ubond`, escanear `ubond_active.conf` con
  `grep -oE 'host [a-zA-Z][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}'` para
  extraer todos los fqdns referenciados en cláusulas BPF `host`.
- Para cada fqdn, llamar a `resolve_filter_host()`:
  - System DNS primero (`dig +short`).
  - Fallback a la lista `FALLBACK_DNS_RESOLVERS` (1.1.1.1 / 8.8.8.8
    / 9.9.9.9 default, configurable en `config/env`).
- Si UN resolver responde con IP válida, sustituir in-place
  `host <fqdn>` → `host <ip>` via `sed -i.bak`.
- Si NINGÚN resolver responde, comentar la línea entera con prefijo
  `# REQ-NET-37 dns-fail: <linea>` para auditoría posterior. Los
  demás filtros (icmp, zoom, rtp_generic) siguen activos — la
  replicación parcial es preferible a ninguna.

**Why no abortar:** los filtros icmp/zoom/rtp no llevan `host
<fqdn>`, no dependen de DNS, y son útiles por sí mismos. Abortar
04b por DNS roto sobre `api.anthropic.com` (servicio opcional)
sería excesivo. Reportar y seguir.

**Acceptance Criteria:**

- `04b-conectar-ubond.sh` tiene una sección `Paso 3.7:
  Pre-resolución filter hosts` entre el Paso 3.5 (pre-resolución
  VPS_IP) y el Paso 4 (arrancar ubond).
- La sección referencia `REQ-NET-37` en su comentario.
- Helper `resolve_filter_host()` usa `FALLBACK_DNS_RESOLVERS` (no
  hardcoding de resolvers — Rule 4 IDLC).
- Cuando un fqdn resuelve, sustituye `host <fqdn>` por `host <ip>`
  via `sed -i.bak` sobre `ubond_active.conf` (no sobre el template
  `ubond.conf`).
- Cuando un fqdn NO resuelve por ningún resolver, comenta la línea
  entera con marker `REQ-NET-37 dns-fail:`. El resto de filtros
  permanece intacto y `04b` continúa.
- Test estático `tests/test_REQ-NET-37_dns_filter_preresolve.sh`
  pasa los 10 checks (sección presente, FALLBACK_DNS_RESOLVERS
  usado, sustitución `host fqdn -> host ip`, comentario en caso de
  fail, target solo `ubond_active.conf`, regex BPF de extracción,
  sintaxis bash OK).
- `bash -n 04b-conectar-ubond.sh` pasa sin errores.

**Verification:**

- **Estática:** `tests/test_REQ-NET-37_dns_filter_preresolve.sh` —
  10/10 PASS al implementar (2026-06-08).
- **Runtime (pendiente):** próximo trayecto AVE:
  1. Smoke test pre-captive con WiFi tren bloqueado: 04b debe
     comentar líneas `host api.anthropic.com` / `host claude.ai`
     con marker `REQ-NET-37 dns-fail:` en
     `generated/ubond_active.conf` y arrancar ubond sin esos dos
     filtros pero con icmp/zoom/rtp activos.
  2. Smoke test post-captive con DNS funcional: 04b debe sustituir
     ambas entradas por `host <ip>` literal y `pcap_compile` no
     debe emitir `unknown host` en `ubond.log`.
  3. Inspección de `generated/ubond_active.conf` tras 04b en ambos
     escenarios para confirmar el comportamiento esperado.

**Riesgos:**

- **TTL congelado:** la IP queda fija para la sesión. Si Anthropic
  hace anycast reshuffle a otra IP, el filtro deja de matchear.
  Mitigación: ciclo de `04b` re-resuelve. Próxima iteración:
  `tools/ubond-watchdog.sh` con SIGHUP periódico cuando DNS cambia
  (diferido).
- **Múltiples IPs por FQDN:** `dig +short api.anthropic.com` puede
  devolver varias A records. La implementación toma la última
  (`tail -1`) — una IP cualquiera del pool. Si el tráfico real va
  por otra IP del pool, el filtro no matchea. Solución más robusta
  (futura): expandir a múltiples cláusulas `host` OR-eadas. No es
  crítico hoy: para Anthropic SSE el cliente HTTP/2 reusa
  conexión, una sola IP a la vez.
- **Regex BPF demasiado laxa:** la regex
  `host [a-zA-Z][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}` matchea cualquier
  cosa que parezca FQDN tras la palabra `host`. No matchea IPs
  literales (que empiezan por dígito) — ese es el comportamiento
  deseado, las IPs no necesitan resolución. Pero si alguien
  escribe `host invalid_name` (sin punto), no matchea — también
  deseado, esos casos `pcap_compile` los rechazaría igualmente.

**Related:**

- [[REQ-NET-12]] — replicación selectiva por 5-tupla, introduce
  `[filters.replicate]` con cláusulas `host <fqdn>` que motivan
  este REQ.
- [[REQ-NET-29]] — parser fix `strncmp → strcmp` para que
  `[filters.replicate]` no se trate como `[filters]` stock. Sin
  NET-29, los filtros replicate ni siquiera entrarían al parser
  correcto. NET-29 + NET-37 son ambos pre-requisitos para que
  replicación funcione bajo DNS roto al startup.
- `04b-conectar-ubond.sh` — Paso 3.7 implementa el fix.
- `tests/test_REQ-NET-37_dns_filter_preresolve.sh` — validación
  estática.
- `config/env` — `FALLBACK_DNS_RESOLVERS` consumida por
  `resolve_filter_host()`.
- `docs/v2-ubond/04-bugs-trayecto-2026-05-29.md` — bugs trayecto
  AVE serie (mismo registro de incidentes).
