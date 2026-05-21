### ave-vpc.REQ-NET-09 - Tuning de mlvpn para móvil 4G/5G

**Description:**

Los defaults de mlvpn están pensados para enlaces simétricos estables
(ej. dos fibras DSL). En 4G/5G móvil sobre tren, los parámetros por
defecto producen lag percibido alto y throughput agregado por debajo
de la suma teórica de los enlaces. Tres ajustes concretos,
verificables en producción:

1. **MTU del túnel `1400` (antes `1440`)**. Móvil 4G/5G suele anunciar
   MTU 1500. mlvpn encapsula con UDP+IPv4 (28 B) + ChaCha20 nonce+tag
   (~32 B) + header mlvpn (~16 B) ≈ 76 B de overhead. Margen seguro:
   `1500 - 76 = 1424`. Bajamos a 1400 para absorber variaciones de
   PMTU del camino (tren, hairpin del operador) y evitar
   fragmentación / black-hole de PMTUD que se traduce en lag.

2. **`loss_tolerence = 30` y `latency_tolerence = 800` globales en
   `[general]`**. Defaults son 100% (un enlace que pierde TODOS los
   paquetes nunca se saca de la agregación) y 1000 ms (un enlace con
   1 s de RTT sigue contribuyendo al bonding). Con los nuevos
   valores, mlvpn saca de la agregación cualquier enlace que pierda
   >30% o supere 800 ms, en lugar de arrastrar al resto.

3. **Sin `bandwidth_upload` en los `[links.X]`**. El valor anterior
   `10000000` (10 Mbps) era arbitrario y forzaba un reparto
   proporcional incorrecto cuando el ancho de banda real difería
   (típico: Movistar y Yoigo dan capacidades muy distintas según
   cobertura). Sin la directiva, mlvpn auto-balancea por throughput
   observado.

`reorder_buffer_size` se deja en 0 (default) y se documenta en el
config generado: subir a 64-256 solo si el usuario ve en logs el
warning `freebuffer full: reorder_buffer_size must be increased`.
Para videoconferencia UDP/RTP un buffer en mlvpn solo añade latencia
(la app ya tiene su propio jitter buffer).

**Parent Requirement:** ave-vpc.REQ-NET-03

**Acceptance Criteria:**

- `config/env.example` define `TUN_MTU="1400"`. El comentario explica
  el cálculo del overhead.
- `03-setup-mac.sh` genera `mlvpn.conf` con `loss_tolerence = 30` y
  `latency_tolerence = 800` en la sección `[general]`.
- `03-setup-mac.sh` no escribe `bandwidth_upload` en ningún
  `[links.X]`.
- `07-setup-rpi.sh` genera `/etc/mlvpn/mlvpn.conf` con `loss_tolerence
  = 30` y `latency_tolerence = 800` en `[general]`.
- El config generado incluye un comentario explicando cuándo subir
  `reorder_buffer_size` (warning concreto en logs).
- Los cambios son reversibles editando los scripts y reejecutando
  `03-setup-mac.sh` / `07-setup-rpi.sh`. No hay variables nuevas en
  `config/env` además de `TUN_MTU` que ya existía.
