### ave-vpc.REQ-NET-11 - Modo failover para sesiones interactivas

**Description:**

El bonding paquete-a-paquete de mlvpn (default WRR) reparte cada
paquete entre los enlaces activos. Con 2 enlaces 4G de latencias
dispares (típico móvil: iPhone ~50 ms vs Pixel ~100 ms), los paquetes
alternados llegan al destino en orden distinto al que salieron.
Aunque TCP los reordena, el delay introducido por esperar al "lento"
rompe sesiones HTTP/2 streaming, WebSockets y videoconferencias en
tiempo real (Zoom, Teams, Meet, Anthropic API). Validado en
producción 2026-05-22: `curl` con descarga lineal a 801 KB/s ✓ pero
sesión Claude (HTTP/2 SSE) inutilizable mientras el túnel estaba
activo.

`04-conectar.sh --failover` configura mlvpn en modo failover dinámico
en lugar de bonding:
- Inicialmente: iPhone activo, Pixel y WiFi marcados
  `fallback_only = 1` (backup pasivo)
- `timeout = 2` global → failover en ~2 s ante caída del activo
- **Selector dinámico** (`tools/seleccionar-mejor-enlace.sh`)
  lanzado en background:
  - Cada 5 s mide RTT y pérdida de cada enlace al RPi público.
  - Cada 30 s evalúa scores (`score = 1000 - rtt - loss × 10`) y,
    si el ganador difiere del activo con margen ≥ 20 puntos, **rota**
    el rol activo↔backup reescribiendo `fallback_only` y SIGHUP.
  - Solo considera enlaces marcados `@` (autenticados a nivel mlvpn).
    Excluye los `!` (AUTH_PENDING): un WiFi del AVE puede tener
    buen RTT ICMP pero filtrar UDP 5082 — sin esta salvaguarda lo
    elegiríamos ganador y romperíamos el túnel.
  - Solo toca `fallback_only` per-link (NUNCA bandwidth_upload):
    cambios suaves que mlvpn asimila sin desestabilizar.

Caso de uso principal: meet/videoconferencia en AVE donde la
cobertura cambia entre operadoras a lo largo del trayecto. El
sistema escoge automáticamente el mejor en cada momento. Trade-off:
throughput = al mejor enlace solo (no suma), pero **sin jitter
destructivo** y con cambios suaves de ~2 s.

**Parent Requirement:** ave-vpc.REQ-NET-09

**Acceptance Criteria:**

- `04-conectar.sh` acepta el flag `--failover`. Sin él, comportamiento
  por defecto (bonding paquete-a-paquete) intacto.
- Con `--failover`, el script:
  - Sustituye el `timeout = N` global del config activo por
    `timeout = 2`.
  - Inserta `fallback_only = 1` en el bloque `[links.pixel]` tras
    `bandwidth_upload`.
  - Si el WiFi pasa los pre-flight checks, también añade
    `fallback_only = 1` al bloque `[links.wifi]`.
  - Imprime mensaje "Modo --failover activo: Pixel como backup
    pasivo, timeout=2s" antes de arrancar mlvpn.
- El help (`./04-conectar.sh` sin sudo) lista el flag con descripción.
- El comportamiento sin `--failover` es bit-a-bit equivalente al
  anterior (no se introduce regresión en bonding clásico).
- El RPi NO necesita cambios: `fallback_only` es per-link y mlvpn
  evalúa el estado de los links en ambos extremos por keepalive
  recíproco.
- `tools/seleccionar-mejor-enlace.sh` se lanza en background si
  `--failover` está activo. PID en
  `generated/mlvpn_failover_selector.pid`. Lo mata `05-desconectar.sh`
  ANTES de parar mlvpn (no en mitad del shutdown).
- El selector solo considera enlaces autenticados a nivel mlvpn
  (proceso muestra `@links.X`). Excluye `!links.X` (AUTH_PENDING) —
  defensa contra WiFi del AVE con UDP 5082 filtrado.
- El selector emite cada rotación a syslog con
  `logger -t mlvpn-selector "<scores y ganador>"`. Se ve con:
  `log stream --predicate 'process == "mlvpn-selector"' --info` o
  combinado con todo el resto:
  `log stream --predicate 'eventMessage CONTAINS[c] "mlvpn"' --info`.
