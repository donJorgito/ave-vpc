# Bugs y observaciones — trayecto AVE 2026-05-29

Sesión de debug en condiciones reales (Madrid → Orihuela) con
WiFi del AVE + iPhone tethering + Pixel tethering. Las condiciones
**NO se reproducen en casa** (LAN fibra estable sin CGNAT) — por eso
el debug solo es útil aquí.

## Bugs CONFIRMADOS y arreglados en esta sesión

### Bug #1 — Patch viejo aplicaba parcialmente

**Síntoma**: 03b/07b reportaban `2 out of 7 hunks failed` en `ubond.c`.
**Causa**: el patch fue generado contra una versión vieja del master
upstream; la actual movió las líneas.
**Fix**: regenerado `patches/ubond_replicate_filter.patch` contra
master `466b422`.
**Estado**: cerrado.

### Bug #2 — `memcpy` parcial en clone-to-N

**Síntoma**: paquetes replicados llegaban con longitud aleatoria
(probable corrupción).
**Causa**: el código original hacía
`memcpy(&clone->p, &spkt->p, sizeof(spkt->p))` — solo copiaba el
campo `p`, dejando `clone->len` (wire length) y `clone->timestamp`
sin inicializar (basura del pool reutilizado).
**Fix**: cambiado a `memcpy(clone, spkt, sizeof(*spkt))`.
**Estado**: cerrado en código, pero NO testeado en vivo (porque el
bug #4 impide llegar a este path).

### Bug #3 — Sección `[filter.replicate]` incompatible con parser

**Síntoma**: ubond tiraba `No remote address specified.` y abortaba.
**Causa**: en `config.c:254`, ubond hace
`strncmp(section, "filters", 7) != 0` para distinguir filtros de
túneles. La sección `[filter.replicate]` (sin s) NO matchea ese
prefix, así que ubond la trataba como un túnel y exigía
remotehost/remoteport.
**Fix**: renombrado a `[filters.replicate]` (con s) en patch, 03b,
07b, tests, y docs.
**Estado**: cerrado.

### Bug #4 — Puertos cliente: `MLVPN_PORT_*` en vez de `UBOND_PORT_*`

**Síntoma**: el smoke test de ayer "funcionó" (ping a través del
túnel OK) pero estaba hablando con el servidor mlvpn (puertos
5080/5081) por error, no con ubond. Falso positivo total.
**Causa**: 03b generaba `generated/ubond.conf` con
`remoteport = ${MLVPN_PORT_1}` (5080) en vez de `${UBOND_PORT_1}`
(5083).
**Fix**: añadidos `UBOND_PORT_1=5083` etc. al script + cambio en
plantilla.
**Estado**: cerrado.

## Bugs OBSERVADOS pero NO entendidos

### Bug #5 — Dataplane no fluye aunque auth funciona — RESUELTO 2026-06-01

**Estado**: causa raíz identificada y validada. NO era código ubond.
Era colisión de tun IP en RPi entre `mlvpn0` y `ubond0`. Documentado
abajo.

**Síntoma**: ubond autentica los enlaces (`@links.iphone`,
`@links.pixel`, `2 tunnels up`), keepalives van y vienen, pero
`ping 10.10.10.1` 100% loss. Tráfico real (HTTP, etc.) tampoco fluye.

**Lo que SÍ sabemos**:

- Auth funciona: handshake completo en ambos enlaces.
- Keepalives bidireccionales: en el log se ven
  `sent 46 bytes (size=512, type=2)` y `recv 46 bytes (size=2, type=2)`
  cada segundo. Conectividad UDP cliente↔servidor confirmada.
- En el receptor (RPi) `tcpdump` ve los paquetes UDP entrar.
- utun7 se crea y configura con la IP correcta.
- Las rutas 0/1 + 128/1 + /32 al VPS están bien.
- El protocol_read del receptor recibe paquetes (logs `< links.X recv`).

**Lo que NO sabemos**:

- Por qué el ping ICMP no traversa el túnel.
- Si los paquetes ICMP llegan a `ubond_protocol_read` en el receptor
  y son rechazados por dedup/reorder/loss-detection.
- Si los paquetes ICMP llegan a `tuntap_write` o se pierden en
  alguna cola intermedia.
- Si la respuesta vuelve por el VPS y se pierde antes de llegar
  al utun del cliente.

**Marco**: v1 (mlvpn) funciona en este mismo trayecto AVE con
`--failover` (validado 2026-05-25). Mismo Mac, mismo iPhone/Pixel,
mismo router doméstico, mismo DDNS, misma RPi. Por tanto:

- **CGNAT** está resuelto desde v1. Conexión es OUTBOUND
  Mac→RPi via DDNS (no necesitamos inbound). No relevante para v2.
- **Jitter** lo maneja v1 sin problemas. No es lo que rompe v2.
- **El bug está en v2 sí o sí**, no en infraestructura.

**Hipótesis pendientes de verificar (orden de probabilidad)**:

1. **Diferencia de protocolo entre ubond y mlvpn**. ubond es un
   fork con cambios estructurales (data_seq global, hpsbuf, reorder
   diferente). El servidor mlvpn ESCUCHA en 5080-5082 (mlvpn-proto)
   y ubond escucha en 5083-5085 (ubond-proto). Cuando el cliente
   ubond habla a 5083, llega al ubond.service en RPi. ubond.service
   está usando el binario VANILLA hoy (compilado sin nuestro patch
   en el último intento). Si ubond cliente patcheado no es 100%
   wire-compatible con ubond servidor vanilla, los paquetes auth
   pasan pero los paquetes data no.
   **Debug**: poner el MISMO binario (mismo patch, mismo commit
   hash) en cliente y servidor, comprobar si funciona.
2. **El reorder buffer descarta paquetes nuevos por seq>min_seqn**.
   Vimos `Request resend 17` y `unable to resend seq 15 (Not Found
   - empty slot)` muchos en el log. El reorder buffer puede quedar
   en un estado donde rechaza paquetes válidos.
   **Debug**: leer `reorder.c` con calma, trazar el flujo de
   data_seq desde send hasta receive.
3. **El nuevo binario de ubond compilado contra master `466b422`
   tiene una regresión upstream que afecta el dataplane**.
   ubond es repo abandonado desde 2022 (11 stars), pero `master`
   tiene commits hasta cerca de la fecha. El último commit es
   "Move rtun to ubond.c" — un refactor que pudo introducir el
   bug en upstream.
   **Debug**: probar binario vanilla en Mac y RPi (sin nuestro
   patch) — bonding puro de ubond. Si va: nuestro patch es el
   problema. Si no: upstream regression.
4. **Mi inserción del bloque clone-to-N rompe el flujo normal aunque
   el if-block no se ejecute**. Aunque `count > 0` está ahora
   gating, la presencia del code path puede afectar al optimizador
   o al stack frame de manera sutil.
   **Debug**: revertir hunk de clone-to-N, recompilar, probar.
   Si va sin clone-to-N pero con dedup → el problema es clone-to-N.

### Bug #6 — Loss detection cicla "tunnels up" / "tunnels down or lossy"

**Síntoma**: tras autenticar, ubond emite cada segundo:

```log
[INFO/rtt] links.pixel keepalive reached threashold,
            keepalive recieved 0.784944s ago
[INFO] all tunnels are down or lossy but fallback is not available
[INFO/rtt] links.pixel packet loss acceptable again: 0.000000%/31.000000%
[INFO] 1 tunnels up (normal mode)
```

**Hipótesis**: el threshold de keepalive RTT es demasiado tight para
las latencias del AVE (que oscilan entre 50ms y 1s). ubond marca el
enlace como lossy → fallback (no hay) → tunnels down → keepalive
arriva → tunnels up otra vez. Cicla.

**Pendiente**: revisar valor del threshold y considerar override
per-link tipo `loss_tolerence` (que ya intentamos en v1 con
resultados mixtos — REQ-NET-09 deprecated tuning).

### Bug #7 — Solo 1 enlace autentica intermitentemente

**Síntoma**: en el smoke test de las 07:48, 2 enlaces auth. En el de
las 08:39, solo Pixel auth (iPhone no). Mismo binario, mismo conf,
distintos resultados.

**Hipótesis**: el iPhone tethering tiene CGNAT muy agresivo en
ciertos momentos (Movistar-train específico) y el handshake UDP
cliente→server falla silenciosamente. Pixel/Yoigo tiene una NAT
más permisiva.

**Pendiente**: tcpdump en RPi durante un intento de auth para ver
si los paquetes 5083 llegan o no.

## Otras observaciones

### `SOS.sh` — usuario reportó que "no sabe si funciona"

**Pendiente**: probar SOS.sh en condiciones controladas. Validar
que mata todos los procesos VPN y restaura rutas. Posiblemente
necesita actualización para conocer también ubond (paralelo al
05b-desconectar).

### Conectividad UDP intermitente Mac → RPi

**Síntoma**: a veces UDP test (`nc -u`) llega al RPi (tcpdump lo
ve), a veces no. Sin cambio aparente.

**Hipótesis**: NAT timeout en el carrier o en el AVE. La conntrack
expira en ~30s y al siguiente paquete tarda en re-establecer la
ruta. ubond keepalives mantienen viva una sesión, pero pruebas
manuales con `nc` (sin keepalive) caducan rápido.

## Plan de debug futuro (NO en casa, sino en próximo trayecto)

1. **Capturar `tcpdump` simultáneo en Mac (sale) + RPi (entra)**
   con timestamps para ver dónde se pierden los paquetes ICMP.
2. **Inyectar log_debug en `tuntap_write_pkt` y
   `ubond_rtun_read_data` del binario** para confirmar si los
   paquetes ICMP llegan al binario y entran/salen del utun.
3. **Probar 04b SIN `[filters.replicate]` en el conf y SIN
   recompilar el binario con el patch de replicación** —
   binario vanilla ubond + conf vanilla. Si va, el problema es
   nuestro patch. Si no va, el problema es ubond+AVE conditions.
4. **Comparar latencia/loss entre v1 (mlvpn --failover) y v2
   en el mismo trayecto**, mismas condiciones. Si v1 va y v2 no,
   confirma regresión. Si ambos sufren, problema infra.

## Estado del repo tras esta sesión

- Bugs #1-#4 commiteados como cerrados.
- Bug #5 (dataplane) sigue abierto, código tal cual con dedup
  gating y memcpy completo.
- Bug #6 (loss cycling) probablemente preexistente en upstream,
  agravado por AVE conditions.
- Bug #7 (auth intermitente) probablemente CGNAT.
- v1 sigue intacto y funcional para el viaje.

---

## Resolución Bug #5 — sesión 2026-06-01 (cafetería)

Tras instrumentar el dataplane con un smoke-test adaptativo
(REQ-NET-23, `tools/smoke-{casa,cafe,ave}.sh` con tcpdump
simultáneo Mac+RPi vía SSH), el reporte automático pinpointed:

```text
- Mac UDP out (físicas):  116 pkts ✓
- RPi UDP in (5083-85):   128 pkts ✓
- RPi tun out (ubond0):     0 pkts ✗
- Mac utun in:              5 pkts (sólo requests salientes)
```

Veredicto del tool: "RPi recibe UDP pero NO escribe al tun".

Investigación manual en RPi reveló la verdadera causa:

```text
$ ip route show | grep 10.10.10
10.10.10.0/24 dev mlvpn0  proto kernel scope link src 10.10.10.1
10.10.10.0/24 dev ubond0  proto kernel scope link src 10.10.10.1

$ ip addr | grep "10.10.10.1"
    inet 10.10.10.1/24 scope global mlvpn0
    inet 10.10.10.1/24 scope global ubond0
```

**Causa raíz**: tanto `mlvpn0` como `ubond0` tienen IP `10.10.10.1/24`
simultáneamente. La coexistencia funciona para INPUT (puertos UDP
distintos: 5080-5082 vs 5083-5085) pero ROMPE para OUTPUT. Cuando
ubond decrypta una request ICMP echo y la inyecta en `ubond0` vía
`tuntap_write`, el kernel responde a 10.10.10.2 buscando ruta a
`10.10.10.0/24` → matchea la PRIMERA entrada (mlvpn0, creada antes).
La reply sale por mlvpn0, donde no hay cliente Mac escuchando ubond.

**Validación**:

```text
$ ssh rpi 'sudo systemctl stop mlvpn'
$ ./tools/smoke-cafe.sh
ping 10.10.10.1: 5/5 paquetes recibidos, 0% packet loss
```

Confirmado: con mlvpn parado, dataplane ubond fluye 100%. Bug #5
pinpointed a colisión de routing, NO a código ubond.

**Bugs colaterales detectados durante la investigación**:

- `Error: ipv4: Address already assigned` en RPi journal: ubond no
  podía crear ubond0 limpio porque mlvpn0 mantenía 10.10.10.1.
- `links.iphone received invalid packet of N bytes`: scanners de
  internet hitting puerto 5083 (publicamente forwardeado en
  router). NO era nuestro tráfico — falsos positivos de debug.

**Plan de fix (siguiente sesión)**:

- Subnet distinta para ubond: `10.10.20.0/24` con
  `UBOND_TUN_VPS_IP=10.10.20.1` y `UBOND_TUN_MAC_IP=10.10.20.2`.
- Cambios en `config/env`, `03b-setup-mac-ubond.sh`,
  `07b-setup-rpi-ubond.sh`, `04b-conectar-ubond.sh`,
  `tools/lib/conf-gen.sh`.
- Nuevo REQ-NET-24 + test que valida coexistencia mlvpn+ubond
  con ambas subnets activas.

## Mejoras de tooling permanente derivadas de esta sesión

- `tools/smoke-{casa,cafe,ave}.sh` (REQ-NET-23): suite que evita
  tener que volver a debugarse a ciegas en futuros bugs de
  dataplane. Reproducible, capturas concretas, veredicto
  automático.
- `SOS.sh` consciente de v2: elimina procesos ubond y limpia
  utuns colgadas — vital tras crashes durante debug.
- Memoria `[[bug5-rpi-tun-ip-collision]]`: causa raíz para
  evitar que se reabra como hipótesis falsa en sesiones futuras.
