# Changelog

Todos los cambios notables de este proyecto se documentan aquí.
Formato basado en [Keep a Changelog](https://keepachangelog.com/es/1.0.0/).

## [Sin publicar]

Trabajo hacia **v2.0.0** — migración a ubond con replicación selectiva
de paquetes (UDP/RTP) por 5-tupla. Ver `project_v2_ubond_roadmap.md`
en memoria del proyecto. Plan en 6 fases, ejecutándose
incrementalmente sin romper la v1.0.0 actual.

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
  ```
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
  + ping a `RPi_IP`) daba falsos positivos en cualquier WiFi con el
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
