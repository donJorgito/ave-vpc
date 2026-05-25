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

`04-conectar.sh --failover` configura mlvpn en modo failover en lugar
de bonding:
- Solo iPhone activo
- Pixel y, si aplica, WiFi marcados con `fallback_only = 1` (backup
  pasivo)
- `timeout = 2` global (cap mínimo de mlvpn) → si iPhone deja de
  responder en 2 s, mlvpn cambia automáticamente a Pixel
- Cuando iPhone vuelve, mlvpn regresa a iPhone

Caso de uso principal: meet/videoconferencia en AVE donde la
cobertura de un operador puede caer momentáneamente. Trade-off:
throughput agregado = al mejor enlace solo (no suma de enlaces),
pero **sin jitter destructivo** y con failover de ~2 s en cortes.

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
