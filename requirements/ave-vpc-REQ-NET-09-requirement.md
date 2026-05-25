### ave-vpc.REQ-NET-09 - Tuning de mlvpn para móvil 4G/5G

**Description:**

Los defaults de mlvpn están pensados para enlaces simétricos estables
(p. ej. dos fibras DSL). Para móvil 4G/5G sobre tren se ajustan los
mínimos imprescindibles, **manteniendo el resto en defaults de
mlvpn** tras validar empíricamente que cualquier "tuning agresivo"
de tolerancias o buffers degrada el túnel en producción real.

**Ajustes que SÍ se aplican:**

1. **MTU del túnel `1400` (antes `1440`)**. Móvil 4G/5G suele anunciar
   MTU 1500. mlvpn encapsula con UDP+IPv4 (28 B) + ChaCha20 nonce+tag
   (~32 B) + header mlvpn (~16 B) ≈ 76 B de overhead. Margen seguro:
   `1500 − 76 = 1424`. Bajamos a 1400 para absorber variaciones de
   PMTU del camino (tren, hairpin del operador) y evitar
   fragmentación / black-hole de PMTUD.

2. **`bandwidth_upload` en TODOS los `[links.X]`** (10 Mbps en
   móviles, 50 Mbps en WiFi). La función
   `mlvpn_rtun_recalc_weight()` solo recalcula los pesos del WRR si
   TODOS los tunnels tienen `bandwidth` definido (verifica `if
   (warned == 0)`). Si falta en alguno, no recalcula → reparto
   colapsa → throughput cae a cientos de KB/s aunque la suma física
   sea Mbps.

3. **Defensive cleanup de instancias mlvpn previas** en
   `04-conectar.sh` (REQ-MAC-05). Cubre el caso de reconexión sin
   `05-desconectar.sh`, que sin esto deja procesos zombie
   acumulándose y duplicando paquetes.

**Lo que NO se fuerza (defaults de mlvpn, intencionadamente):**

- `loss_tolerence` (default 100 %): valores agresivos (15-30 %)
  causan **flapping** con cobertura 4G normal — visto 2026-05-22:
  enlace iPhone oscilando entre 12 % y 21 % de pérdida (típico 4G),
  expulsado/readmitido cada segundo, rompiendo sesiones TCP.
- `latency_tolerence` (default 1000 ms): igual razonamiento.
- `reorder_buffer_size` (default 0): cualquier valor >0 introducía
  retrasos esperando huecos hasta el timeout y degradaba más de lo
  que ayudaba — visto en producción 2026-05-22 con 64 los logs del
  servidor mostraban "freebuffer full" decenas de veces por segundo
  y el throughput era PEOR que sin buffer.

Estas tolerancias se intentaron varias veces (commits 8fa0c56,
597891d, 76e9c59) y se revertieron al baseline en 8521d74. La
documentación queda como advertencia: **no reactivar sin datos
medidos en trayecto AVE real**.

Los problemas reales de bonding paquete-a-paquete con jitter
destructivo en sesiones HTTP/2 se cubren en REQ-NET-11 con un modo
failover dinámico, no con tuning de tolerancias.

**Parent Requirement:** ave-vpc.REQ-NET-03

**Acceptance Criteria:**

- `config/env.example` define `TUN_MTU="1400"`. El comentario explica
  el cálculo del overhead.
- `03-setup-mac.sh` genera `mlvpn.conf` SIN `loss_tolerence`,
  `latency_tolerence` ni `reorder_buffer_size` en `[general]`
  (defaults mlvpn).
- `03-setup-mac.sh` escribe `bandwidth_upload = 10000000` en cada
  `[links.X]` (iphone y pixel).
- `04-conectar.sh` añade `bandwidth_upload = 50000000` al bloque
  `[links.wifi]` cuando el WiFi pasa los pre-flight checks.
- `07-setup-rpi.sh` genera `/etc/mlvpn/mlvpn.conf` SIN
  `loss_tolerence`, `latency_tolerence` ni `reorder_buffer_size` en
  `[general]`. `bandwidth_upload` presente en cada `[links.X]`.
- El comentario en `config/env.example` explica por qué TUN_MTU=1400
  y qué overhead aporta mlvpn.
- Sin variables nuevas en `config/env` más allá de `TUN_MTU` que ya
  existía.
