# Mapeo del firewall WiFi Renfe AVE (trayecto 2026-06-09)

## Conclusión

La WiFi del AVE Renfe **no es utilizable como link UDP en ubond** bajo
la configuración actual del operador. Tiene tres restricciones
combinadas que invalidan tanto la solución original
(`UBOND_PORT_3_REMOTE=443`) como un wrapper UDP-en-TCP simple:

1. **UDP outbound bloqueado completamente** (cualquier puerto, cualquier
   destino).
2. **MitM HTTPS universal** — todo TCP/443 outbound es interceptado por
   un proxy TLS-terminator de Renfe que devuelve cert
   `CN=playrenfe.renfe.com` (Sectigo Renfe Operadora) sin importar el
   destino real.
3. **Inestabilidad como link único** — bajo handovers entre AP del
   tren, la wifi se cae por completo si no hay otro link aguantando
   la conectividad del Mac.

Para usarla como link de bonding habría que combinar (a) un protocolo
que detecte MitM y rechace la conexión sin caer (cert pinning forzoso
del lado cliente) y (b) tolerancia a handovers — fuera del alcance de
ubond stock.

## Evidencia (confirmada con datos crudos en este trayecto)

### 1. UDP outbound — bloqueado completamente

Probe 2026-06-09 ~20:33 CEST con ifscope routes vía en0
(172.16.81.50, gateway 172.16.80.1). 7 puertos UDP × 2 destinos
públicos:

| Puerto | Cloudflare 1.1.1.1 | Google 8.8.8.8 |
|---|---|---|
| 53 (DNS) | TX 1, RX 0 | TX 1, RX 0 |
| 80 | TX 1, RX 0 | TX 1, RX 0 |
| 123 (NTP) | TX 1, RX 0 | TX 1, RX 0 |
| 443 (QUIC) | TX 1, RX 0 | TX 1, RX 0 |
| 1194 (OpenVPN) | TX 1, RX 0 | TX 1, RX 0 |
| 5353 (mDNS) | TX 1, RX 0 | TX 1, RX 0 |
| 51820 (WireGuard) | TX 1, RX 0 | TX 1, RX 0 |

14 packets out, 0 replies. ubond también: 4 pps de
`172.16.81.50:63596 → 170.253.45.213:443` saliendo limpios (visto en
tcpdump de en0), 0 packets en RPi (tcpdump `any` con filtro destino
UDP/5085).

### 2. MitM HTTPS universal — cert dump en cuatro destinos simultáneamente

Cert dump 2026-06-09 ~21:24 CEST con ifscope vía en0 + curl `--resolve`
para variar SNI:

| Destino IP | SNI usado | Cert subject | Cert issuer |
|---|---|---|---|
| 1.1.1.1 (Cloudflare) | cloudflare-dns.com | `CN=playrenfe.renfe.com` | Sectigo Renfe |
| 142.250.184.78 (Google) | `www.google.com` | `CN=playrenfe.renfe.com` | Sectigo Renfe |
| 213.133.116.44 (Hetzner) | hetzner.com | `CN=playrenfe.renfe.com` | Sectigo Renfe |
| 170.253.45.213 (RPi) | 200bares.dedyn.io | `CN=playrenfe.renfe.com` | Sectigo Renfe |

**El captive Renfe estaba autenticado durante este probe** (confirmado
por el usuario, no expirado). Todas las HTTPS arbitrary van al proxy
captive y reciben cert de Renfe Operadora, regardless de destino.

El body HTML que sirve este proxy es el WISPAccessGatewayParam
estándar con redirect a `acceso.playrenfe.renfe.com/jci/login.html`
con parámetros como `nasid=S112.021`, `coaip=172.16.80.2`,
`userurl=<destino-original>` y `status=0`.

#### Validación de la metodología

El cert dump se validó por contraposición — el mismo curl ejecutado
saliendo por en12 (pixel) hacia `www.google.com` devolvió:

```text
subject: CN=www.google.com
issuer:  C=US; O=Google Trust Services; CN=WR2
```

Cert real de Google. Confirma que la técnica detecta MitM correctamente
y los certs Renfe vistos vía en0 NO son artefacto metodológico.

### 3. Inestabilidad bajo uso exclusivo

Test ~21:50 CEST: tras `ifconfig en12 down` + `ifconfig en8 down`
(dejando solo en0 wifi tren activo), curl outbound falló con
"Couldn't connect to server" en 7ms. Tras desconectar físicamente las
pixel, en0 quedó **sin IP** (status DOWN). Auto-reconexión wifi del
Mac no recuperó dentro del trayecto.

Hipótesis razonable (no confirmada con pcap): los handovers AP del
tren tumban la asociación wifi y macOS no recupera bajo presión sin
respaldo móvil. No es relevante para el filtro Renfe — pero confirma
que la WiFi tren no aguanta sola operativamente.

### 4. ICMP — pasa con loss alto

Ping desde 172.16.81.50 a 1.1.1.1: 1/3 packets, RTT 90-654ms con
stddev 233ms. Confirma que la wifi tren tiene upstream IP real (no
todo va al captive proxy: ICMP no toca el proxy y sí responde),
aunque con loss y jitter incompatible con bonding fluido.

## Implicaciones para REQ-NET / roadmap

### Cambios al código que SÍ proceden hacer

1. **Fix verify ruta /1 en 04b-conectar-ubond.sh** — aplicado en esta
   sesión (línea 441: cambio de `"128/1"` a `"128.0/1"` para que
   coincida con la salida real de `netstat -rn -f inet`). El falso
   negativo "ERROR: ruta 128/1 NO instalada" desaparece.

2. **Aclarar mensaje del pre-flight WiFi** — el actual "WiFi en
   captive portal — autentica y reejecuta" es ambiguo. La realidad
   detectada es "Apple Hotspot Detect no obtiene Success en la
   probe". Las dos causas posibles son captive portal real (no
   autenticado) o MitM Renfe degradado. Mensaje sugerido: "WiFi sin
   conectividad limpia — captive expirado o MitM activo".

### Cambios que NO proceden

- **Mantener `UBOND_PORT_3_REMOTE=443`** — la hipótesis "QUIC bypass"
  era falsa. El valor por defecto puede dejarse pero no resuelve el
  problema. El comentario en `config/env` debe corregirse para
  reflejar que NO bypaseaba realmente.

- **Wrapper UDP-en-TCP simple** — no funciona porque Renfe MitM-ea
  todo TCP/443. Cualquier wrapper que use HTTPS estándar es
  interceptado.

### Para la próxima sesión SIN tren

1. **Reproducir el test de MitM en una WiFi restrictiva controlada**
   (oficina, café, hotel). Si ninguna de esas tiene MitM HTTPS
   universal, valida que esto es específico de Renfe y no de
   "captive portals en general".

2. **Probar cert pinning forzoso** — si el cliente verifica el cert
   real del destino y rechaza Renfe, ¿qué pasa con la conexión? ¿Renfe
   suelta el flow o dropea silently? Esto determina si hay tunel
   posible vía cliente cert-pinned.

3. **Probar WireGuard sobre TCP wrapper** (e.g.
   `wireguard-go` + `wstunnel`) en cualquier WiFi con MitM HTTPS, no
   en Renfe. Si funciona en un MitM más permisivo, entender el
   diferencial con Renfe.

4. **Decidir si la WiFi tren queda fuera del scope de ubond** y se
   asume que el AVE = solo bonding 4G (iphone+pixel). En ese caso:

   - Eliminar `[links.wifi]` del template de `ubond.conf`.
   - Quitar la regla `ubond-wifi-443` del router.
   - Documentar la decisión y el por qué en README.

## Errores metodológicos cometidos en esta investigación

Para no repetirlos, registro:

1. **Probes sin cert dump al principio**. Vi HTTP 200 de TCP/443 a
   varios cloud providers e inferí "TCP funciona libre" — pero NO
   dumpé el cert. Cuando finalmente lo dumpé, todos eran cert Renfe.
   Lección: ante cualquier HTTP 200/handshake "exitoso" en una red
   sospechosa, dump del cert obligatorio antes de afirmar nada.

2. **Mezclé "confirmado" con "probable"** en la misma frase ("CONFIRMADO
   el filtro probable es por ASN"). El usuario lo señaló y archivó
   como regla a fuego en memoria global y local. Distinguir
   evidencia directa de inferencia siempre.

3. **Asumí que la WiFi tren era "bonus"** para el bonding. El usuario
   corrigió: la WiFi tren ES el objetivo principal por su ancho de
   banda potencial. Toda decisión técnica debe orientarse a hacerla
   funcionar, no a descartarla por conveniencia.

4. **Hipótesis "captive expirado"** cuando el usuario insistía en que
   estaba autenticado. La verdad: el MitM es universal, autenticado
   o no. La sesión captive controla quién puede tener tráfico saliente
   en absoluto, pero el MitM HTTPS aplica siempre.

5. **Probing agresivo mid-trip que tumbó la conexión** del usuario
   varias veces. Para próxima vez: validar bypass en entorno
   controlado antes de operar mid-trip.

## Referencias

- Memoria: `project_renfe_udp_block.md` — síntesis para próximas sesiones
- Memoria: `feedback_lenguaje_rigor.md` — distinguir confirmado/hipótesis
- Memoria: `feedback_no_proyectar_estado.md` — no proyectar cansancio al usuario
- `requirements/ave-vpc-REQ-NET-XX-requirement.md` — futuro REQ para
  cerrar formalmente el caso WiFi tren (asignar ID en próxima sesión)
