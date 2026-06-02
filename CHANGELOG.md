# Changelog

Todos los cambios notables de este proyecto se documentan aquí.
Formato basado en [Keep a Changelog](https://keepachangelog.com/es/1.0.0/).

## [Sin publicar]

Trabajo hacia **v2.0.0** — migración a ubond con replicación selectiva
de paquetes (UDP/RTP) por 5-tupla. Ver `project_v2_ubond_roadmap.md`
en memoria del proyecto. Plan en 6 fases, ejecutándose
incrementalmente sin romper la v1.0.0 actual.

### Fix regresión REQ-NET-27 — `replicated` uninit en pool reuse (2026-06-02)

Staff-review independiente post-merge detectó regresión bloqueante:
el campo `int replicated` añadido a `ubond_pkt_t` no se inicializaba
en `ubond_pkt_get()`. Como el pool reusa slots de paquetes liberados,
un clone (`replicated=1`) que vuelve al pool y sale para un paquete
normal heredaba el flag → reproducía intermitentemente el mismo
síntoma de H1 (data_seq divergente), con dificultad de debug porque
es esporádico ("a veces falla, a veces no").

Fix de una línea en `ubond_pkt_get()` (`build/ubond/src/ubond.c`):
`if (p) p->replicated = 0;` antes de `return p;`. Patch regenerado a
114 líneas (era 99). Mac+RPi redeployed via `make install` y 07b.

### Fix replicación selectiva — H1+H2+NULL (REQ-NET-27, 2026-06-02)

Bloque B del postmortem AVE 2026-06-01. Causas C1+C2+C3 corregidas.

- **`patches/ubond_replicate_dedup_fix.patch`** (~99 líneas): toca
  `src/pkt.h` (1 hunk) y `src/ubond.c` (5 hunks).
- **H1** (data_seq sobrescrito): añadido `int replicated` a struct
  `ubond_pkt_t` (campo externo, NO al wire format). En
  `ubond_rtun_choose` se marca `clone->replicated = 1`. En
  `ubond_rtun_send` se chequea: si `pkt->replicated`, no sobreescribir
  `proto->data_seq` ni incrementar el global → todos los clones
  llegan al receptor con el MISMO `data_seq` → la dedup LRU matchea.
- **H2** (return 0 vs < 0): cambiado contrato de `ubond_protocol_read`:
  `< 0` error, `= 0` válido sigue, `> 0` consumido (dedup hit). Caller
  en `ubond_rtun_read` cortocircuita con `!= 0`. Ya no se contabilizan
  duplicados como pérdida en reorder.
- **NULL check**: añadido `if (!clone) continue;` en clone path con
  log `pool exhausted, skipping clone for %s` (defensive).
- **03b**: aplica como Patch 5 en su chain.
- **07b**: transporta vía `UBOND_PATCH3_B64` y aplica al final.
- **Mac y RPi binarios actualizados** vía `make install` y 07b
  reprovision (verificado con `strings | grep "pool exhausted"`).
- REQ-NET-27 + test estático `test_REQ-NET-27_replicate_dedup_fix.sh`
  (11/11 PASS).

Validación runtime requiere reproducir trayecto AVE — pendiente.

### Watchdog ubond v2 + auto-recovery (REQ-NET-26, 2026-06-02)

Postmortem del incidente AVE 2026-06-01 (analizado con 3 agentes
expertos en paralelo + verificador independiente). Causa primaria:
v2+replicación cae bajo flap de cobertura, sin que ningún sistema lo
detecte hasta que el usuario nota apps fallando y ejecuta `SOS.sh`
manualmente.

Bloque A implementado (Bloque B con fix C pendiente):

- **`tools/ubond-watchdog.sh`** (nuevo) — daemon que vigila tres
  señales: pgrep procesos ubond ausentes, ping a `UBOND_TUN_VPS_IP`
  con threshold 4×5s, flag-file `generated/ubond_unhealthy` tocado
  por el statuscommand. Tras umbral invoca `SOS.sh` con cooldown 60s
  y notifica via `osascript`. Auto-recovery sin intervención humana.
- **`04b-conectar-ubond.sh`**: pasa `--debug --verbose` al binario
  (sin esto `generated/ubond.log` quedaba en 0 bytes — diagnóstico
  ciego). Captura PID real con `pgrep "ubond: ubond0 [priv]"`, no del
  subshell `tee`. Arranca el watchdog tras configurar el utun.
- **`05b-desconectar-ubond.sh`**: mata el watchdog ANTES que ubond
  para evitar double-cleanup. Usa pattern "ubond: " (con espacio)
  que cubre todas las variantes de title.
- **`SOS.sh`**: mata `tools/ubond-watchdog.sh` (sin esto el watchdog
  detectaría "ubond ausente" y dispararía SOS en bucle). Limpia
  `ubond_unhealthy` flag.
- **`03b-setup-mac-ubond.sh`**: regenera `ubond_updown_mac.sh` propio
  (no copia del de mlvpn). Log a `/tmp/ubond_updown.log` separado.
  En `rtun_down`/`tuntap_down` toca `ubond_unhealthy` → señal
  temprana al watchdog (más rápido que ping timeout).
- REQ-NET-26 + test estático `test_REQ-NET-26_watchdog.sh` (12/12 PASS).

Validación runtime requiere reproducir el incidente AVE — pendiente.

### SOS.sh + ubond-runner.sh — bugfix process title (AVE 2026-06-01)

- `SOS.sh` no mataba procesos ubond lanzados por smoke-tests porque
  el pattern "ubond: ubond0" no matcheaba el title "ubond: ubond
  [priv]" (sin el "0") que producen los runs sin `--name ubond0`.
  Cambiado a "ubond: " (con espacio) que cubre ambas variantes —
  bug detectado en vivo en AVE.
- `tools/lib/ubond-runner.sh`: añadido `--name ubond0` para alinear
  el process title con producción (04b ya lo hace). Defense in
  depth.
- Verificación final de SOS.sh también actualizada al nuevo pattern
  (antes daba falso "✓ ubond parado").

### Pre-AVE 2026-06-01 — preparativos sesión validación trayecto

- Conf templates (`03b-setup-mac-ubond.sh`, `04b-conectar-ubond.sh`):
  ejemplos comentados de `loss_tolerence=80` y `latency_tolerence=2000`
  por enlace para AVE noisy. El usuario los descomenta en el tren si
  observa loss cycling.
- `tools/lib/report.sh`: el veredicto del smoke-test ahora toma el
  resultado de ping como ground truth. Si ping pasa, "Dataplane
  FUNCIONA"; el contador 0 en pcap de ubond0 se anota como fallo de
  captura RPi (timing entre tcpdump y interfaz UP), no como bug
  real. Evita falsos negativos en diagnóstico AVE.
- `docs/v2-ubond/05-cheatsheet-ave.md`: secuencia de fases (v1
  baseline → v2 bonding → v2+tolerences → v2+replicate) con métricas
  a anotar y comandos exactos.

### Bug #6 atenuado — per-link tolerences en ubond (REQ-NET-25, 2026-06-01)

- Nuevo patch C `patches/ubond_per_link_tolerence.patch` (~130
  líneas) port de mlvpn al fork ubond:
  - `loss_tolerence` (% loss, max 100): per-link override del
    hardcoded `LOSS_TOLERENCE = 31.0` en `ubond_rtun_check_lossy`.
  - `latency_tolerence` (ms, max 5000): gracia adicional para el
    keepalive ack antes de marcar UBOND_LOSSY (mapeo semántico —
    ubond no tiene check separado de RTT como mlvpn).
- Se aplica como Patch 4 en `03b-setup-mac-ubond.sh` y vía
  `UBOND_PATCH2_B64` en `07b-setup-rpi-ubond.sh` después del
  patch de replicación (orden importa).
- Defaults 0 = comportamiento histórico preservado.
- REQ-NET-25 + test estático `test_REQ-NET-25_per_link_tolerence.sh`
  (9/9 PASS) verifica el patch, su aplicación en los scripts y
  los caps explícitos.
- Validación runtime del comportamiento ("el ciclo loss cycling
  se atenúa") requiere AVE real — pendiente para próximo trayecto.

### Bug #5 resuelto — coexistencia mlvpn↔ubond (REQ-NET-24, 2026-06-01)

- ubond v2 ahora usa subnet `10.10.20.0/24` (mlvpn sigue en
  `10.10.10.0/24`). `config/env` añade `UBOND_TUN_VPS_IP=10.10.20.1`
  y `UBOND_TUN_MAC_IP=10.10.20.2`.
- `03b-setup-mac-ubond.sh`, `04b-conectar-ubond.sh`,
  `07b-setup-rpi-ubond.sh` y `tools/lib/{conf-gen,tests,ubond-runner}.sh`
  pasan a `UBOND_TUN_*` con defaults seguros (10.10.20.x — nunca caen
  a 10.10.10.x para evitar regresar al bug).
- `tools/smoke-casa.sh` ahora incluye WiFi como link en target=LAN
  (no hay hairpin posible cuando se conecta a IP local del RPi).
- REQ-NET-24 + test estático `test_REQ-NET-24_coexistencia.sh`
  (11/11 PASS) verifica los criterios: subnets distintas, scripts
  usan `UBOND_TUN_*`, no hay defaults `10.10.10.x` en código v2.
- **Validado runtime**: smoke-casa.sh con mlvpn.service Y ubond.service
  activos en RPi, ping 5/5 success al gateway 10.10.20.1.

### Smoke-test adaptativo ubond (REQ-NET-23, 2026-06-01)

- **`tools/smoke-{casa,cafe,ave}.sh`** — orchestrators que arrancan
  ubond cliente en runtime, capturan tcpdump simultáneo en Mac y RPi
  (vía SSH), corren batería de tests (ping ICMP, curl HTTP por túnel,
  throughput 1MB, UDP probe) y emiten un reporte markdown con
  diagnóstico automático: cuenta paquetes en cada punto (Mac out / RPi
  in / RPi tun out / Mac utun in) y declara dónde muere el paquete.
- **`tools/lib/`** (7 librerías sourceables) — código compartido entre
  los 3 orchestrators sin duplicación: `_common.sh` (logging,
  require_root, as_invoker), `env-detect.sh`, `conf-gen.sh`,
  `tcpdump.sh`, `ubond-runner.sh`, `tests.sh`, `report.sh`.
- **Diseño "una password por run"**: el orchestrator se invoca como
  `sudo -E ./tools/smoke-X.sh`. `require_root` valida EUID==0 al
  inicio. SSH y scp se ejecutan dropeando privs al `${SUDO_USER}`
  vía `as_invoker`.
- Test estático `test_REQ-NET-23_smoke_lib.sh` (12 PASS) verifica
  existencia de archivos, sintaxis, funciones expuestas por cada lib,
  y que los orchestrators piden root y instalan trap cleanup.
- Validado en runtime desde una cafetería (2026-06-01): Mac out=116,
  RPi in=128, RPi tun out=0 → veredicto "ubond servidor no escribe al
  tun" — Bug #5 pinpointed por primera vez con datos concretos.

### SOS.sh consciente de v2 (2026-06-01)

- Mata procesos `ubond: ubond0` y `/usr/local/sbin/ubond` además de
  los de mlvpn.
- Limpia IPs `10.10.10.x` colgadas en utun fantasma (vista tras crashes
  ubond y refactor smoke-test).
- Borra `generated/ubond_active.conf` además de `mlvpn_active.conf`.
- Verificación final reporta estado independiente de mlvpn y ubond.

### Hardening IDLC v6 (2026-05-26)

- **Rule 2 — Defensa en profundidad de secrets**: añadido `gitleaks`
  v8.30.1 al pre-commit. Complementa `detect-private-key`
  (que solo cubre SSH/PGP) detectando tokens, API keys, AWS/GCP creds
  y patrones similares.
- **Rule 5 — CI sin lógica inline**: extraídos los 5 bloques bash
  de `.github/workflows/ci.yml` a scripts versionables en
  `tests/check_*.sh` (env vars, tfvars.example, IDLC files,
  .gitignore sensibles, bash syntax). El YAML se queda con el
  scaffolding y los `run:` apuntan a los scripts.
- **Rule 7 — Acciones GitHub pineadas a SHA**: las 5 actions
  (`actions/checkout`, `ludeeus/action-shellcheck`,
  `pre-commit/action`, `hashicorp/setup-terraform`,
  `actions/upload-artifact`) ahora referencian commit SHA inmutable
  con comentario `# vX.Y.Z` informativo.
- **Rule 8 — IaC linting**: añadido `terraform_tflint` (vía
  `antonbabenko/pre-commit-terraform` v1.105.0) junto con
  `terraform_fmt` y `terraform_validate`. Detectó y se corrigieron
  6 warnings en `terraform/`: `required_version` ausente y 5
  variables sin `type` declarado.

### Hardening IDLC v6 — segunda iteración (2026-05-27)

Tras audit más exhaustivo, 3 gaps adicionales detectados y cerrados:

- **Rule 8 — Docs linting**: añadido `markdownlint-cli` v0.43.0 al
  pre-commit con `.markdownlint.yml`. Pinneado a v0.43 porque
  versiones >=0.44 actualizan transitiva de eslint exigiendo
  Node 20.19+/22.13+/24+, incompatible con Node 21.x del Mac. Auto-fix
  resolvió ~129 warnings; 13 MD040 (lenguaje en bloques fenced)
  arreglados manualmente con `text` / `bash` / `ini` según corresponda.
- **Rule 9 — Branch protection en `main`**: configurada via API
  GitHub. Requiere status checks "Lint y calidad" + "Tests de
  verificación" verdes, historial lineal, sin force-push ni delete,
  conversation resolution. `enforce_admins=false` para permitir
  push directo solo de admin (workflow personal).
- **Rule 10 — Release v1.0.0 publicado**: `gh release create v1.0.0`
  con notas extraídas del CHANGELOG. Antes solo existía el git tag
  (no visible en la pestaña Releases de GitHub UI).

## [1.0.0] — 2026-05-25

Primera versión **estable** del bonding mlvpn + failover dinámico.
Validada en producción en uso doméstico y trayecto AVE
Orihuela-Madrid. La v1.0.0 cierra el ciclo de tuning empírico
(commits 8fa0c56 → dedd8f2) con el aprendizaje de que el bonding
paquete-a-paquete tiene límites estructurales para sesiones
HTTP/2/videoconf, mitigados con el modo `--failover` dinámico.

### Añadido

- **REQ-NET-11 — Modo failover dinámico (`--failover`) para
  videoconf y sesiones HTTP/2**. El bonding paquete-a-paquete de
  mlvpn (default WRR) reparte cada paquete entre los enlaces; con
  latencias dispares (típico móvil 4G: 50 vs 100 ms) los paquetes
  alternados llegan desordenados al destino y **rompen HTTP/2
  streaming, WebSockets y videoconferencias** aunque permitan TCP
  largos. Validado 2026-05-22: `curl` con descarga lineal a
  801 KB/s ✓ pero sesión Anthropic API (HTTP/2 SSE) inutilizable
  mientras el túnel estaba activo.

  Solución: `04-conectar.sh --failover` configura mlvpn en modo
  failover en lugar de bonding paquete-a-paquete:
  - Estado inicial: iPhone activo, Pixel y WiFi marcados
    `fallback_only = 1` (backup pasivo).
  - `timeout = 2` global → si el activo cae, mlvpn salta al backup
    en 2 s (cap mínimo de mlvpn).
  - **Selector dinámico** `tools/seleccionar-mejor-enlace.sh` en
    background: cada 5 s ping ICMP desde cada interfaz al RPi,
    ventana deslizante 60 s, cada 30 s evalúa
    `score = 1000 − RTT − pérdida × 10` y, si el ganador difiere del
    activo con margen ≥ 20 puntos, **rota** el rol activo↔backup
    reescribiendo `fallback_only` per-link y SIGHUP. **Solo toca
    `fallback_only`, NUNCA `bandwidth_upload`** (eso desestabilizó
    mlvpn al intentarlo en REQ-NET-10 y se descartó).
  - Solo considera enlaces autenticados a nivel mlvpn (`@links.X`).
    Excluye `!links.X` (AUTH_PENDING) — defensa contra WiFi del AVE
    con buen ping ICMP pero UDP 5082 filtrado.
  - Coste en datos: ~1.5 MB/día.
  - Sin `--failover`: bonding clásico intacto (no regresión).
  - El RPi no necesita cambios: `fallback_only` es per-link y mlvpn
    sincroniza estado por keepalive.
  - `tests/test_REQ-NET-11_failover_mode.sh` (14 checks).
- **`tools/medir-enlaces.sh` — herramienta de medición repetible**
  para tomar perfil de cobertura real por ubicación. Útil para
  comparar tramos del AVE, oficina, casa, etc. Comando
  `--resumen` agrega mediciones acumuladas y sugiere
  `bandwidth_upload` calibrado.

### Cambiado

- **Logs de watchers unificados en syslog** (Apple Unified Log).
  Antes: el selector y el watcher de IP del WiFi escribían en
  `generated/mlvpn.log` mientras el binario mlvpn ya emitía a
  syslog — inconsistente. Ahora todos usan
  `logger -t mlvpn-<componente>`. Para verlo:

  ```bash
  log stream --predicate 'eventMessage CONTAINS[c] "mlvpn"' --info
  ```

- **Rollback del tuning agresivo de mlvpn** (commit `8521d74`). Se
  intentaron `loss_tolerence` 15-30 %, `latency_tolerence = 800`,
  `reorder_buffer_size` 64-512 (commits 8fa0c56, 597891d, 76e9c59)
  buscando mejorar throughput agregado. **Todos degradaron el
  túnel en producción real** (validado 2026-05-22):
  - `loss_tolerence` agresivo causaba flapping (enlaces 4G normales
    oscilan entre 12-21 % de pérdida; expulsados/readmitidos cada
    segundo rompían sesiones TCP).
  - `reorder_buffer_size > 0` producía "freebuffer full" repetido y
    retrasaba el flujo entero esperando huecos hasta timeout —
    throughput PEOR que sin buffer.
  Estado final: solo MTU 1400, `bandwidth_upload` per-link, REQ-MAC-05
  cleanup zombies, REQ-NET-08 detección de casa por IP pública. El
  resto en defaults mlvpn. Lecciones documentadas en REQ-NET-09 como
  advertencia para futuras iteraciones.

### Deprecated

- **REQ-NET-10 — Calibración dinámica vía `bandwidth_upload`**.
  Sustituido funcionalmente por REQ-NET-11 (failover dinámico vía
  `fallback_only`, mucho más conservador). El SIGHUP frecuente
  reescribiendo pesos WRR desestabilizaba mlvpn.
  `tools/calibrar-enlaces-dinamico.sh` se mantiene en el repo como
  herramienta experimental, pero `04-conectar.sh` ya **no lo lanza
  automáticamente**.
  Ejecuta `./tools/medir-enlaces.sh <etiqueta>` en distintas
  ubicaciones (estación, AVE km X, oficina, casa…) para acumular
  un perfil de cobertura real. `./tools/medir-enlaces.sh --resumen`
  promedia las mediciones y sugiere `bandwidth_upload` calibrado.
  Datos en `generated/measurements/`.

### Corregido

- **REQ-MAC-05 — Limpieza defensiva de instancias mlvpn previas al
  reconectar**. Caso real observado en runtime: hasta 4 procesos
  `mlvpn: mlvpn0 @links.pixel @links.iphone` corriendo a la vez
  (51 min, 31 min, 7 min, 3 min de antigüedad), todos encapsulando
  los mismos paquetes en paralelo, la RPi recibiendo streams
  duplicados y la videoconferencia con lag descomunal. Causa:
  `04-conectar.sh` arrancaba mlvpn sin verificar si ya había uno
  vivo de un arranque anterior — típico cuando el usuario reconecta
  sin pasar por `05-desconectar.sh`. Fix:
  - `04-conectar.sh` hace `pgrep -f "mlvpn: mlvpn0"` al inicio y, si
    encuentra procesos, los mata con `pkill -f` + `pkill -9 -f` antes
    de arrancar el nuevo. Mensaje explícito al usuario.
  - `05-desconectar.sh` verifica con `pgrep -f` tras `pkill -9` que
    no quedan supervivientes; si los hubiera, los lista para
    diagnóstico. Mensaje cambiado a "mlvpn parado (todas las
    instancias)" para distinguirlo del caso anterior.
  - `tests/test_REQ-MAC-05_defensive_cleanup.sh` (5 checks).
- **REQ-NET-09 — Tuning de mlvpn para móvil 4G/5G**. Los defaults
  estaban pensados para enlaces simétricos estables y producían lag
  alto y throughput por debajo de la suma teórica. Diagnóstico real
  observado: ~400 KB/s vía túnel con 2 enlaces 4G que deberían dar
  Mbps. La causa raíz fue una mala interpretación inicial del
  comportamiento de mlvpn — corregida en este commit:
  - `TUN_MTU` baja de 1440 a 1400. Móvil 4G suele tener MTU 1500;
    encapsulado mlvpn = ~76 B (UDP+IPv4 28 + ChaCha20 nonce+tag 32 +
    header mlvpn 16). Margen seguro 1500-76 = 1424; usamos 1400 para
    absorber variaciones de PMTU del camino (tren, hairpin del
    operador). Un MTU demasiado alto provoca fragmentación o
    black-hole de PMTUD.
  - `loss_tolerence = 25` y `latency_tolerence = 800` globales en
    `[general]` (cliente y servidor). Defaults son 100 % / 1000 ms,
    demasiado permisivos. 25 % es el sweet spot: en una primera
    iteración bajamos a 15 % pero causaba FLAPPING en producción
    (enlace iPhone oscilando entre 12 % y 21 % de pérdida — normal
    en 4G — y mlvpn lo expulsaba/readmitía cada segundo, rompiendo
    sesiones TCP). 25 % descarta enlaces realmente rotos sin
    oscilar con cobertura móvil normal.
  - **`bandwidth_upload` OBLIGATORIO en TODOS los `[links.X]`**. La
    función `mlvpn_rtun_recalc_weight()` solo recalcula los pesos
    del Weighted Round Robin si TODOS los tunnels tienen `bandwidth`
    definido. Si falta en alguno, no recalcula → reparto colapsado.
    Restaurado a `10000000` en iphone/pixel y `50000000` en
    `[links.wifi]`. (Una versión inicial de este REQ los eliminó
    creyendo que mlvpn auto-balancearía sin ellos — lectura
    incorrecta del código; revertido.)
  - **`reorder_buffer_size = 512` global** en `[general]` (cliente y
    servidor). Con 2 enlaces de latencias dispares los paquetes
    alternados llegan desordenados; sin reorder buffer el TCP
    cliente trata los out-of-order como pérdida → entra en
    congestion control → throughput colapsa. Pero un buffer pequeño
    es aún peor: con 64 los logs del servidor mostraban "freebuffer
    full" decenas de veces por segundo y el throughput era PEOR que
    sin buffer. 512 da margen para 4G/5G con bonding agresivo.
  - `tests/test_REQ-NET-09_mlvpn_tuning.sh` (7 checks).
- **REQ-NET-08 — Detección de "red de casa" por IP pública en lugar de
  subred local**. La detección anterior (`rpi_subnet == wifi_subnet`
  - ping a `RPi_IP`) daba falsos positivos en cualquier WiFi con el
  mismo `192.168.1.x` por defecto (la mayoría de routers ISP, hoteles
  y cafés) si algún dispositivo respondía como `.101`. Caso real:
  WiFi ajena con subred coincidente → script asumía "casa" y saltaba
  el 3er enlace sin necesidad. Reemplazada por comparación de IP
  pública: el Mac consulta su IP pública saliendo por `IFACE_WIFI`
  con 3 servicios HTTP de fallback (`api.ipify.org`, `ifconfig.me/ip`,
  `icanhazip.com`, `--max-time 2`) y la compara con la IP que
  resuelve el DDNS de la RPi (`VPS_IP`). Si coinciden, los paquetes
  cruzarían el mismo NAT → casa real. Independiente de la subred
  local. La comprobación va después del check de captive portal
  (necesita salida HTTPS funcional). Sin variables nuevas en
  `config/env`.
- `tests/test_REQ-NET-08_home_via_public_ip.sh` (8 checks). Test de
  REQ-NET-06 actualizado para reconocer la nueva detección.

### Cambiado

- **iPhone por cable USB en lugar de Wi-Fi hotspot**: docs y defaults
  pasan a asumir que **ambos móviles van por USB** (iPhone con Personal
  Hotspot por cable, Android con USB tethering). Esto libera el Wi-Fi
  del Mac para el 3er enlace (Wi-Fi del AVE / hotel / oficina), que ya
  estaba implementado pero requería un cable extra para el iPhone.
  Cambios:
  - `config/env.example`: `IFACE_IPHONE` por defecto pasa de `en0`
    (Wi-Fi) a `en8` (USB típica del iPhone). `IFACE_PIXEL` de `en5`
    a `en12`. Comentarios reescritos para describir los rangos DHCP de
    cada móvil (`172.20.10.x` iPhone, `192.168.42.x`/`43.x` Android).
  - `00-detectar-interfaces.sh` reescrito: detecta cada móvil por su
    rango DHCP característico en lugar de asumir el iPhone en la Wi-Fi
    del Mac. La Wi-Fi se detecta como `IFACE_WIFI` (3er enlace).
  - `README.md`: diagramas de arquitectura, tabla de hardware y "Antes
    de subir al tren" actualizados. Tabla de hardware ahora incluye
    fila explícita de "2 cables USB de datos" y avisa de que cables
    solo de carga no valen.
  - `REQ-HW-04` ampliado: ya no es solo del cable del Android, ahora
    cubre ambos móviles. Parent pasa a `REQ-HW-02, REQ-HW-03`.

### Añadido

- **`MLVPN_PORT_3_REMOTE`**: variable opcional con el puerto público al
  que conecta el cliente para el 3er enlace WiFi. Si difiere de
  `MLVPN_PORT_3` (puerto interno donde escucha el servidor), se asume
  que el router hace mapeo de puertos. Caso de uso: las redes WiFi
  públicas restrictivas (AVE, aeropuertos, hoteles) filtran puertos
  altos como 5082 pero dejan pasar 443/UDP (QUIC). Configurando
  `MLVPN_PORT_3_REMOTE="443"` y un mapeo `WAN:443/UDP → RPi:5082` en
  el router, el cliente atraviesa los filtros sin tocar el core de
  mlvpn (que sigue en 5082). Reversible cambiando una variable.
- `04-conectar.sh`: usa `MLVPN_PORT_3_REMOTE` para `remoteport` del
  link wifi y muestra el mapeo en pantalla cuando difiere del interno.
- README: nueva sección "Puerto público alternativo
  (`MLVPN_PORT_3_REMOTE`)" con instrucciones del router.
- `docs/rpi-setup.md`: regla `mlvpn-443` opcional añadida a la tabla
  de port forwarding.
- REQ-VPS-07 actualizado para describir el mapeo público opcional.

### Cambiado (sin publicar antes, parte del cambio anterior)

- `requirements/REQ.md`: título de REQ-VPS-07 ahora especifica que los
  puertos son los del servidor.

### Añadido (commit anterior, ya publicado)

- **REQ-NET-07**: rebind del enlace WiFi ante cambios de IP (renovación
  DHCP tras captive portal, roaming entre APs del AVE). `04-conectar.sh`:
  - Tras pasar el captive, espera 4 s y revalida la IP de `IFACE_WIFI`
    antes de escribir `bindhost` (caso real visto en el AVE 20/05/2026:
    DHCP renovó `172.18.152.114` → `172.18.152.147` segundos después de
    autenticar y mlvpn quedaba bound a una IP inexistente con
    `!links.wifi` permanente).
  - Watcher en background (`generated/mlvpn_wifi_watcher.pid`) revisa
    la IP cada 5 s; si cambia, reescribe `bindhost` y manda `SIGHUP` a
    `mlvpn [priv]`, que recarga la config y rebindea el socket sin
    reiniciar el túnel completo.
  - `[links.wifi]` ahora incluye `timeout = 8`,
    `loss_tolerence = 30` y `latency_tolerence = 800` (overrides per-
    link agresivos sobre los 30 s globales). mlvpn saca el WiFi de la
    agregación cuando se degrada en 8 s en vez de 30 s, sin afectar a
    iPhone/Pixel.
- `05-desconectar.sh` mata el watcher antes de parar mlvpn.
- `tests/test_REQ-NET-07_wifi_ip_rebind.sh` con 7 checks de
  trazabilidad.
- `docs/screenshots/monitor-bonding-en-ave.png` — captura real del
  monitor durante un trayecto Madrid → Orihuela, embebida en el
  README.

### Cambiado

- README: la sección de monitorización ya no recomienda
  `tail -f generated/mlvpn.log` (mlvpn manda los logs runtime a
  syslog, el fichero solo recoge errores tempranos de arranque y los
  rebind del watcher). En su lugar:
  `log stream --predicate 'process == "mlvpn"' --info`.

## [0.14.0] — 2026-05-19

### Cambiado

- **Estructura de `requirements/` conforme a IDLC v6**: un fichero por
  requirement (`ave-vpc-<REQ-ID>-requirement.md`) siguiendo la plantilla
  oficial `templates/iac_component-id-requirement.md` del repo IDLC. 31
  ficheros generados (5 HW + 7 SW + 9 VPS + 6 NET + 4 MAC). El antiguo
  `requirements/REQ.md` queda como índice navegable con links a cada
  fichero individual.

### Añadido

- **31 tests de trazabilidad** en `tests/test_<REQ-ID>_*.sh`, uno por
  requirement (cumple Section 5.3.3.4 de IDLC v5 / Test traceability de
  IDLC v6). Cada test:
  - Sigue el patrón POSIX shell del repo IDLC (visto en
    `tests/test_RQ001_markdown_lint.sh` del propio IDLC).
  - Emite reporte JUnit XML en `reports/<TESTSUITE>.xml`.
  - Soporta SKIP cuando el entorno no aplica (CI Linux sin Mac, sin
    móviles, sin SSH al VPS).
- `tests/_lib_junit.sh` — helper común con funciones `junit_init`,
  `junit_pass`, `junit_fail`, `junit_skip`, `junit_finalize`.
- `tests/verificar-setup.sh` — orquestador reescrito: ejecuta todos los
  `test_REQ-*.sh` secuencialmente y resume PASS/FAIL/SKIP. Sustituye al
  conjunto de checks lineales que tenía antes.
- `.github/workflows/ci.yml`:
  - Step nuevo "Verificar trazabilidad IDLC": comprueba que cada
    `requirements/ave-vpc-REQ-*-requirement.md` tiene su test
    correspondiente.
  - Step nuevo "Ejecutar tests test_REQ-*.sh": ejecuta el orquestador.
  - Step nuevo "Publicar reportes JUnit XML": sube `reports/` como
    artifact del workflow run.
  - El check de variables en `config/env.example` ahora también valida
    `MLVPN_PORT_3` e `IFACE_WIFI` (introducidos en 0.12.0).
- `.gitignore`: excluye `reports/` (los XML se generan en cada ejecución).

## [0.13.0] — 2026-05-19

### Corregido

- `08-monitor.py` — `get_interface_stats()` parseaba mal las interfaces sin
  MAC (utun, lo0). Las físicas tienen 11 columnas en `netstat -ibn` (con MAC
  en `parts[3]`) y los utun tienen 10 (sin MAC). El parser usaba offsets
  fijos `parts[6]`/`parts[9]` que solo funcionan con MAC, así que para utun
  leía Opkts/Coll en vez de Ibytes/Obytes. Ahora detecta la presencia de MAC
  y aplica el offset correcto.
- `08-monitor.py` — el agregado del túnel se calculaba como SUMA de las
  interfaces físicas (con overhead UDP del bonding ~2-3% incluido). Ahora se
  lee directamente del utun de mlvpn → tráfico útil real. Validado en vivo
  contra utun6 (Cisco AnyConnect): 5.6 GB Ibytes / 2.4 GB Obytes correctos.
- `08-monitor.py` — eliminada la lista hardcoded `['en8', 'en12', 'en0']` en
  el cálculo del agregado encapsulado; ahora itera sobre `link_names` que ya
  refleja la configuración del bonding.

### Cambiado

- El bloque `TÚNEL mlvpn` ahora muestra el throughput útil real del túnel
  (sin overhead). Se añade una línea `Encapsulado` al final con la suma de
  físicas para que sea visible la diferencia (overhead del protocolo).

### Notas

- Esto corrige una afirmación incorrecta del proyecto: el comentario en
  versiones anteriores decía que `netstat -ibn` no captura TX de interfaces
  TUN en macOS. Era un bug de parsing en `get_interface_stats()`, no una
  limitación de macOS. `REQ-MAC-02` actualizado.

## [0.12.0] — 2026-05-19

### Añadido

- Tercer enlace WiFi en mlvpn (`[links.wifi]`, puerto UDP 5082). El bonding
  ahora puede usar 3 enlaces simultáneamente: iPhone USB, Pixel USB y WiFi
  nativo del Mac.
- `04-conectar.sh` — pre-flight checks que evalúan automáticamente si la WiFi
  actual es elegible como 3er enlace antes de añadirla al bonding:
  - Sin IP en `IFACE_WIFI` → se omite con aviso
  - Mac en la subred del RPi y el RPi local responde → se omite (evita
    hairpin NAT cuando se está en la red de casa)
  - Captive portal detectado vía `captive.apple.com/hotspot-detect.html` →
    se omite con mensaje "autentica en el navegador y reejecuta"
  - Si pasa todos los checks, anexa `[links.wifi]` dinámicamente al
    `mlvpn_active.conf` con la IP real de la WiFi actual
- Flag `--sin-wifi` en `04-conectar.sh` para forzar bonding solo con móviles
  aunque la WiFi sea elegible.
- `MLVPN_PORT_3` (default `5082`) e `IFACE_WIFI` (default `en0`) en
  `config/env.example`. Compatibilidad hacia atrás: si no están definidas en
  un `config/env` antiguo, los scripts usan los defaults.
- `02-setup-vps.sh` y `07-setup-rpi.sh` — apertura automática de UDP 5082 en
  el firewall del servidor (ufw/firewall-cmd) y bloque `[links.wifi]` en la
  configuración mlvpn del servidor.
- `tests/verificar-setup.sh` — comprobación informativa de `IFACE_WIFI` (no
  falla si no tiene IP, es opcional).
- `requirements/REQ.md` — REQ-NET-06 sobre el 3er enlace y referencia desde
  REQ-NET-05.
- `README.md` — sección "Tercer enlace WiFi (automático)" con matriz de
  comportamiento por escenario (casa, captive, oficina, hotel, AVE).
- `docs/rpi-setup.md` — diagrama actualizado con el 3er enlace WiFi opcional.

### Corregido

- `04-conectar.sh` — eliminada duplicación de la /32 anti-loop al VPS que se
  añadía dos veces (en el paso 2 y otra vez tras crear utun). Ahora se añade
  una sola vez con preferencia móvil → WiFi como fallback.

## [0.11.0] — 2026-05-19

### Añadido

- `08-monitor.py` — monitor en tiempo real de enlaces mlvpn y tráfico agregado.
  Muestra throughput por enlace físico (iPhone, Pixel, WiFi) + estado de autenticación
  de cada link mlvpn. El agregado se calcula sumando las interfaces físicas porque
  `netstat -ibn` no captura TX de interfaces TUN (utun) en macOS.

### Corregido

- `04-conectar.sh` — routing anti-loop para bonding completo con rutas 0/1 via tunel:
  Las rutas ifscope al VPS no se usan en lookups globales de macOS (sockets sin
  `IP_BOUND_IF`). Fix: añadir ruta /32 regular (sin ifscope) al VPS justo antes de
  las 0/1. Las /32 son más específicas que /1 en la tabla global → mlvpn usa ruta
  directa, el resto del tráfico entra por el tunel.
  Verificado: `traceroute 8.8.8.8` → hop 1 = 10.10.10.1 (RPi) ✓

## [0.10.0] — 2026-05-19

### Añadido

- `03-setup-mac.sh` — crea `/tmp/sudo-askpass.sh` automáticamente: helper que muestra
  un diálogo gráfico macOS para la contraseña de sudo. Necesario en Macs corporativos
  con Jamf/MDM donde sudo sin TTY falla. Uso: `SUDO_ASKPASS=/tmp/sudo-askpass.sh sudo -A <cmd>`
- `docs/rpi-setup.md` — documentadas las restricciones del statuscommand de mlvpn:
  firma correcta, env vars, permisos 700, key `statuscommand` vs `ip4_updns`

### Corregido

- `02-setup-vps.sh` — sincronizado con los fixes de mlvpn: `statuscommand`, firma
  correcta del updown script, `chmod 700`, password embebida (sin `file://`)
- `04-conectar.sh` / `05-desconectar.sh` — mensajes de error actualizados con instrucciones
  para usar el askpass desde Claude Code

## [0.9.0] — 2026-05-19

### Corregido — TÚNEL COMPLETAMENTE FUNCIONAL

- `07-setup-rpi.sh` / `03-setup-mac.sh` — updown script reescrito con la firma
  correcta de mlvpn: `script <device> <evento>` + env vars `IP4`, `IP4_GATEWAY`,
  `MTU`, `DEVICE`. La versión anterior usaba `$1=up/down` y vars `MLVPN_IPADDR`
  etc. que corresponden a una API antigua no implementada en este mlvpn.
- `07-setup-rpi.sh` — permisos del updown script: 700 en vez de 755. mlvpn rechaza
  ejecutar scripts accesibles por grupo u otros (`group/other accessible` → fatal).
- `07-setup-rpi.sh` — `ip4_updns` → `statuscommand` (nombre correcto del config key).
  `ip4_updns` es ignorado silenciosamente; `statuscommand` es el key real.
- `04-conectar.sh` — configura la IP del túnel directamente desde el script en macOS,
  ya que `priv_run_script` no ejecuta el statuscommand de forma fiable en macOS/utun.
- `05-desconectar.sh` — mata mlvpn por nombre de proceso (`mlvpn: mlvpn0`), no por
  PID del tee que era lo que se guardaba en mlvpn.pid.

## [0.8.0] — 2026-05-19

### Corregido

- `01-generar-secreto.sh` — cambiado de `openssl rand -hex 32` (64 chars) a `openssl rand -hex 16`
  (32 chars). El parser de config de mlvpn falla silenciosamente con passwords > ~40 chars:
  el proceso hijo hereda una clave derivada de una password diferente a la configurada.
  Con 32 chars (128 bits de entropía) el sistema funciona correctamente.
- Cron Oracle Cloud eliminado — RPi en casa es el servidor definitivo ✓
- pmset standby restaurado en AC — ya no se necesita para mantener el Mac despierto

### Primer viaje AVE confirmado (18/05/2026)

- Bonding iPhone (Movistar) + Pixel (Yoigo) funcionando en Madrid-Orihuela
- Latencia ~87-677ms (variación normal en tren), 0% pérdida de paquetes al VPS
- El túnel sobrevive cambios de cobertura entre operadoras

## [0.7.0] — 2026-05-18

### Añadido

- `patches/tuntap_darwin_utun.c` — parche utun para macOS: sustituye `/dev/tun` (requiere
  kext obsoleto) por la API nativa `SYSPROTO_CONTROL + UTUN_CONTROL_NAME` (macOS 10.6+,
  Apple Silicon). Aplicado automáticamente por `03-setup-mac.sh` antes de compilar.
- `03-setup-mac.sh` — creación automática de usuario de sistema `mlvpn` en macOS via `dscl`
  (equivalente al usuario mlvpn en la RPi, para privilege separation)
- `03-setup-mac.sh` — comprobación de EUID: el script NO debe ejecutarse con sudo
  (brew no funciona como root); usa sudo internamente donde lo necesita
- `04-conectar.sh` / `05-desconectar.sh` — comprobación de EUID: estos scripts SÍ
  requieren sudo (rutas, utun, proceso mlvpn)

### Corregido

- `04-conectar.sh` — mlvpn arranca con `--user mlvpn` (privilege separation) y sin sudo
  en el propio binario (utun no requiere root en macOS, pero sí el script completo)
- `04-conectar.sh` — log file recreado sin root para evitar permisos incorrectos
- `05-desconectar.sh` — rutas eliminadas correctamente con `-ifscope` por interfaz;
  log y pid limpios en cada desconexión
- `07-setup-rpi.sh` — password embebida directamente en mlvpn.conf en lugar de `file://`
  (`file://` no está implementado en mlvpn: usa el literal como contraseña, no el fichero)
- `07-setup-rpi.sh` — añadido `bindhost = "0.0.0.0"` explícito en los links del servidor
  (sin este campo, mlvpn no hace bind a los puertos UDP en Ubuntu 26.04)
- `03-setup-mac.sh` — password embebida directamente (misma corrección que en RPi)

### Pendiente (en investigación)

- `crypto_decrypt failed: -1` entre Mac (mlvpn compilado con utun patch, libsodium 1.0.20)
  y RPi (mlvpn Ubuntu 26.04). Passwords idénticas, mismo commit de mlvpn (master-b934d49),
  mismo protocolo. Causa pendiente de identificar.

## [0.6.0] — 2026-05-18

### Corregido

- `03-setup-mac.sh` — añadido `ac_cv_func_strnvis=no` al configure: macOS detecta
  `strnvis()` pero con firma incompatible con la usada en `setproctitle.c` de mlvpn,
  provocando errores de compilación. Forzar el fallback interno resuelve el problema.
- `03-setup-mac.sh` — sustituido borrado de directorio de build por `make clean`
  (más seguro y semánticamente correcto)

## [0.5.0] — 2026-05-15

### Añadido

- `docs/rpi-setup.md` — sección "Notas de compatibilidad con Ubuntu 26.04 LTS" con las diferencias descubiertas al instalar en producción
- `docs/rpi-setup.md` — advertencia de CGNAT con instrucciones para verificar y solicitar retirada al ISP
- `README.md` — advertencia de CGNAT en la sección de Opción B (Raspberry Pi)

### Corregido

- `07-setup-rpi.sh` — añadida dependencia `libpcap-dev` (requerida por mlvpn en Ubuntu 26.04)
- `07-setup-rpi.sh` — usuario de sistema dedicado `mlvpn` con home `/var/lib/mlvpn` (mejor que `nobody` para trazabilidad)
- `07-setup-rpi.sh` — servicio systemd usa `--user mlvpn` (mlvpn rechaza arrancar como root sin este flag)
- `07-setup-rpi.sh` — chroot a `/var/lib/mlvpn` (home del usuario mlvpn; mlvpn usa el home del usuario como jaula)
- `07-setup-rpi.sh` — numeración de pasos actualizada (1-9)

## [0.4.0] — 2026-05-13

### Añadido

- `docs/rpi-setup.md` — guía actualizada con deSEC como proveedor DDNS recomendado (protocolo DynDNS2, nativo en router ZTE F6640)
- Soporte deSEC (`*.dedyn.io`) en documentación: alternativa a No-IP, gratuita y privada

### Cambiado

- SO objetivo para Raspberry Pi: **Ubuntu Server 26.04 LTS** (antes 24.04 LTS)
- `07-setup-rpi.sh` — actualizado a Ubuntu 26.04 LTS en comentarios y mensajes de salida
- `docs/rpi-setup.md` — reescrito: Imager headless con Ubuntu 26.04, port forwarding tres puertos (5080-5082), DDNS con deSEC
- `config/env.example` — ejemplo de `VPS_IP` actualizado a `*.dedyn.io`
- `terraform/terraform.tfvars.example` — añadido campo `ssh_public_key` con placeholder
- `terraform/variables.tf` — eliminado default hardcodeado de `ssh_public_key`; ahora se define en `terraform.tfvars`
- `requirements/REQ.md` — REQ-VPS-01 actualizado a Ubuntu 26.04 LTS
- `README.md` — Ubuntu 26.04 LTS, deSEC/dedyn.io, puerto 5082 añadido al port forwarding

### Seguridad

- Eliminada clave pública SSH hardcodeada de `terraform/variables.tf` (historial reescrito con `git filter-repo`)

## [0.3.0] — 2026-05-09

### Añadido

- `06-provision-vps.sh` — itera automáticamente por ambos shapes Always Free (A1.Flex ARM y E2.1.Micro x86) en cada intento; para en cuanto uno tiene éxito
- `.github/workflows/ci.yml` — GitHub Actions con ShellCheck, validación de sintaxis bash, checks IDLC y terraform fmt/validate
- `tests/verificar-setup.sh` — script de verificación del entorno completo
- `requirements/REQ.md` — requisitos del sistema documentados con IDs trazables
- `CONTRIBUTING.md`, `CODEOWNERS`, `LICENSE` — cumplimiento IDLC v6
- Pre-commit hooks: ShellCheck, detect-private-key, trailing whitespace, check-yaml

### Cambiado

- `06-provision-vps.sh` — corregido bug de log doble (tee + cron redirect); añadido PATH completo para que terraform sea encontrado desde cron; jitter aleatorio 0-600s para evitar patrón detectable
- `02-setup-vps.sh` — eliminado mensaje que pedía abrir puertos manualmente (ya lo hace Terraform); añadida dependencia `libtool` necesaria para `autogen.sh`
- `03-setup-mac.sh` — añadido check explícito de Xcode CLT y Homebrew; corregidos warnings SC2155 de ShellCheck
- `04-conectar.sh` — corregidos warnings SC2024 y SC2034 de ShellCheck
- `README.md` — reescrito con arquitectura, tabla de configuración, troubleshooting, alternativas VPS y flujo completo
- `.gitignore` — añadidos `.playwright-mcp/`, `.DS_Store`, `.mcp.json`, `*.png`

### Corregido

- Puertos UDP 5080-5082 y TCP 22 gestionados 100% por Terraform (security list en VCN) — ningún paso manual

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
