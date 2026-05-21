### ave-vpc.REQ-NET-09 - Tuning de mlvpn para móvil 4G/5G

**Description:**

Los defaults de mlvpn están pensados para enlaces simétricos estables
(ej. dos fibras DSL). En 4G/5G móvil sobre tren, los parámetros por
defecto producen lag percibido alto y throughput agregado por debajo
de la suma teórica de los enlaces. Cinco ajustes concretos:

1. **MTU del túnel `1400` (antes `1440`)**. Móvil 4G/5G suele anunciar
   MTU 1500. mlvpn encapsula con UDP+IPv4 (28 B) + ChaCha20 nonce+tag
   (~32 B) + header mlvpn (~16 B) ≈ 76 B de overhead. Margen seguro:
   `1500 - 76 = 1424`. Bajamos a 1400 para absorber variaciones de
   PMTU del camino (tren, hairpin del operador) y evitar
   fragmentación / black-hole de PMTUD que se traduce en lag.

2. **`loss_tolerence = 15` y `latency_tolerence = 800` globales en
   `[general]`** (cliente y servidor). Defaults son 100% (un enlace
   que pierde TODOS los paquetes nunca se saca de la agregación) y
   1000 ms. Con los nuevos valores mlvpn saca de la agregación
   cualquier enlace que pierda >15 % o supere 800 ms.

3. **`bandwidth_upload` OBLIGATORIO en TODOS los `[links.X]`**. La
   función `mlvpn_rtun_recalc_weight()` de mlvpn solo recalcula los
   pesos del Weighted Round Robin si TODOS los tunnels tienen
   `bandwidth` definido (verifica `if (warned == 0)`). Si falta en
   alguno, no recalcula → el reparto colapsa → throughput cae a
   cientos de KB/s aunque la suma física sea Mbps. Valores:
   `10000000` (10 Mbps) para los enlaces móviles, `50000000` para
   WiFi cuando aplique.

4. **`reorder_buffer_size = 64` global en `[general]`** (cliente y
   servidor). Con 2 enlaces de latencias dispares (típico móvil
   4G/5G: 30-100 ms cada uno), los paquetes alternados llegan
   desordenados al receptor. Sin reorder buffer, el TCP del cliente
   trata los out-of-order como pérdida → activa congestion control →
   throughput colapsa. 64 entradas es un compromiso latencia/orden
   estándar para móvil.

5. **Defensive cleanup de instancias mlvpn previas** en
   `04-conectar.sh` (REQ-MAC-05). Cubre el caso de reconexión sin
   `05-desconectar.sh`, que sin esto deja procesos zombie
   acumulándose y duplicando paquetes.

**Parent Requirement:** ave-vpc.REQ-NET-03

**Acceptance Criteria:**

- `config/env.example` define `TUN_MTU="1400"`. El comentario explica
  el cálculo del overhead.
- `03-setup-mac.sh` genera `mlvpn.conf` con `loss_tolerence = 15`,
  `latency_tolerence = 800` y `reorder_buffer_size = 64` en la
  sección `[general]`.
- `03-setup-mac.sh` escribe `bandwidth_upload = 10000000` en cada
  `[links.X]` (iphone y pixel).
- `04-conectar.sh` añade `bandwidth_upload = 50000000` al bloque
  `[links.wifi]` cuando el WiFi pasa los pre-flight checks.
- `07-setup-rpi.sh` genera `/etc/mlvpn/mlvpn.conf` con
  `loss_tolerence = 15`, `latency_tolerence = 800` y
  `reorder_buffer_size = 64` en `[general]`, y `bandwidth_upload`
  en cada `[links.X]`.
- Los comentarios en los configs generados explican por qué cada
  parámetro está donde está, citando el síntoma observable
  (`freebuffer full`, `mlvpn_rtun_recalc_weight warned>0`).
- Sin variables nuevas en `config/env` además de `TUN_MTU` que ya
  existía.
