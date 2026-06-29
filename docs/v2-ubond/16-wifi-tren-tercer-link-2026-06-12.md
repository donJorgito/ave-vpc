# WiFi del AVE como tercer link de ubond — LOGRADO (trayecto 2026-06-12)

**Fecha:** 2026-06-12 (a bordo del AVE)
**Branch:** `feat/ubond-evaluation`
**Estado:** objetivo histórico del proyecto **conseguido** — los tres
enlaces (@) activos simultáneamente, WiFi del tren incluida.

## Conclusión

La WiFi del AVE Renfe **SÍ es utilizable como link de ubond**, contra lo
que concluía el doc 12. La vía ganadora a bordo es **Vía A
(udp2raw faketcp)**, NO la Vía B (wstunnel) que se había previsto como
respaldo anti-MitM. Se alcanzó el estado:

```text
ubond: ubond0 @links.wifi @links.pixel @links.iphone
```

Los tres links con `@` (activos) a la vez, vía el wrapper udp2raw para
la WiFi del tren. Túnel `utun7` con rutas `0/1` + `128/1` instaladas;
ping al gateway del túnel `10.10.20.1` funciona.

El hallazgo central **invierte la hipótesis del doc 12**: el firewall
del tren NO bloquea todo TCP saliente ni hace MitM universal en todos
los puertos. Inspecciona en capa 7 y corta específicamente el
**WebSocket Upgrade** — por eso wstunnel (WSS) muere y faketcp, que
fabrica paquetes que parecen TCP bruto sin capa 7 que inspeccionar,
cruza limpio.

## Topología medida hoy

- **Mac**, 3 interfaces:
  - `en0` = WiFi tren — IP `172.18.165.131`, gw `172.18.164.1`,
    IP pública del tren `195.76.196.166`.
  - `en8` = iPhone (Movistar) — `172.20.10.4`.
  - `en12` = Pixel (Yoigo) — `10.251.186.99`.
- **RPi servidor** en `200bares.dedyn.io` — IP pública
  `170.253.45.213`, SSH por puerto **2222**.
- Captive portal del tren **autenticado** por el usuario antes de las
  pruebas.

## Evidencia (CONFIRMADA — medido a bordo)

### 1. TCP saliente cruza limpio en puerto alto — sin MitM en 8443

- TCP a **8443** saliente desde `en0`: **da SYN-ACK, cruza limpio**.
- Los puertos 443/80/22 dan timeout, pero **eso es porque el router de
  casa del RPi solo tiene port-forward de 8443**, NO porque Renfe los
  bloquee. Distinción importante: el timeout es del lado RPi, no del
  filtro del tren.
- El **handshake TLS completo** a `RPi:8443` desde el tren completa
  entero: TLSv1.3, cert self-signed del RPi **verificado idéntico al
  real** (serial `18E753…`, fingerprint `85:EB:CF…`). NO es el cert
  `playrenfe`, es decir **NO hay MitM en 8443**.
- **SSH (TCP persistente)** por `en0` a `2222` sostiene una sesión de
  8s+ sin cortes → el TCP bruto persistente cruza bien.

### 2. El firewall corta el WebSocket Upgrade (capa 7)

- Un WebSocket WSS (wstunnel) sobre `8443` **completa el TLS** y luego
  **se cuelga al hacer el Upgrade WebSocket** — reintenta en bucle sin
  llegar a establecer.
- El **mismo wstunnel por celular (`en12`) funciona perfecto** (eco en
  0.22s).
- **Conclusión:** el firewall del tren inspecciona capa 7 y corta
  específicamente el WebSocket Upgrade, NO las conexiones TCP/TLS
  normales.

### 3. Vía A (udp2raw faketcp) cruza — eco end-to-end verificado

faketcp NO es TLS real: fabrica paquetes que parecen TCP, el firewall
los deja pasar como tráfico TCP y NO puede inspeccionar capa 7 porque
no hay WebSocket/HTTP que mirar.

- Eco UDP end-to-end por faketcp sobre la WiFi del tren: **VERIFICADO**
  con tag infalsificable `ECO-UDP-9999:…`.
- Latencia media **~90ms** (min 82, max 102 en tanda buena).
- Pérdida del enlace: **~25–54% según tanda**. Pero se midió que la
  pérdida es del **enlace WiFi del tren en sí** (un ping ICMP base por
  `en0` también pierde igual), NO del túnel faketcp. El faketcp es
  fiel; la WiFi del tren va y viene.

### 4. Bonding real conseguido

Montaje: udp2raw cliente en Mac (escucha `127.0.0.1:5085`, faketcp a
`RPi:8443`) + udp2raw server en RPi (`8443` → reenvía a `ubond:5085`) +
ubond con `WIFI_VIA_WRAPPER=1`.

- Estado alcanzado:
  `ubond: ubond0 @links.wifi @links.pixel @links.iphone` — los tres
  links activos a la vez.
- Ping al gateway del túnel `10.10.20.1`: **0% pérdida en tanda corta,
  25% en tanda larga** (por la WiFi del tren).
- Túnel `utun7` con rutas `0/1` + `128/1` instaladas.

## Inversión de la hipótesis del doc 12

El doc 12 (2026-06-09) concluyó "MitM HTTPS universal" y asumió que
haría falta WSS/cert-pinning para sobrevivir al MitM. La evidencia de
hoy lo corrige:

- El MitM aplica al tráfico HTTPS estándar del captive, pero **NO al
  puerto 8443** con TCP/TLS directo a un destino propio.
- **WSS muere** (Upgrade cortado en capa 7); **faketcp cruza** porque
  no expone capa 7 inspeccionable.
- Por tanto la Vía A pasa de "primaria por latencia" a **única vía
  viable a bordo**, y la Vía B (wstunnel) queda **descartada para la
  WiFi del tren** (sigue siendo válida por celular).

## Limitaciones y trabajo pendiente (CONFIRMADO hoy)

1. **`ubond-watchdog.sh` demasiado agresivo.** Disparó `SOS.sh` y mató
   todo cuando la WiFi del tren tuvo una caída transitoria. No debería
   disparar SOS si al menos un link sigue `@`. **PENDIENTE arreglar.**

2. **Falsos negativos del pre-flight de captive en `04b`.** Marca
   "WiFi en captive portal" aunque el captive esté autenticado — el
   curl a `captive.apple.com` falla por la inestabilidad/timing de la
   WiFi del tren. Con `WIFI_VIA_WRAPPER` el gate correcto debería ser
   "¿wrapper ready en `127.0.0.1`?", NO "¿internet limpio por `en0`?".

3. **SSH de control inestable sobre `en0`.** Se cae repetidamente al
   ejecutar comandos largos que matan/lanzan procesos; la WiFi del tren
   es inestable. Conviene mover el SSH de control al celular y dejar
   `en0` solo para las medidas. Hoy se usó **tmux en el RPi** para que
   los procesos sobrevivan a los cortes de SSH.

4. **IP literal en el conf de prueba.** El conf usó la IP literal del
   RPi (`170.253.45.213`) en vez del hostname DDNS — fue SOLO para la
   prueba manual. Es mala práctica para producción: si cambia la IP
   DDNS falla en silencio. El `04b` real **pre-resuelve DNS
   dinámicamente**.

## Referencias

- `docs/v2-ubond/12-renfe-firewall-2026-06-09.md` — análisis previo,
  cuya hipótesis de MitM universal queda corregida por este doc.
- `docs/v2-ubond/13-plan-bypass-wifi-tren.md` — plan de vías de bypass.
- `docs/v2-ubond/14-wrapper-integration-notes.md` — cableado de
  `wrap-udp2raw.sh` con `[links.wifi]`.
- Memoria: `feedback_lenguaje_rigor.md` — distinguir confirmado/hipótesis.
- Memoria: `project_veredicto_vias_bypass.md` — veredicto de vías de
  bypass (Vía A udp2raw faketcp ganadora).
