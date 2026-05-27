# Fase 1 — Exploración de ubond — Informe

**Fecha**: 2026-05-25
**Branch**: `feat/ubond-evaluation`
**Repo evaluado**: `markfoodyburton/ubond` (fork mlvpn de Mark Burton)
**Commit clonado**: HEAD de `master` (depth=1) — último push 2022-01

## Resumen ejecutivo

ubond **es viable** como base para implementar replicación selectiva de paquetes por 5-tupla (objetivo v2.0.0). El código tiene ya el 70 % del andamiaje necesario — `data_seq` global, reorder buffer con dedup, sistema de filtros PCAP — pero no compila out-of-the-box en macOS Apple Silicon (mismo tipo de issue que tuvimos con mlvpn y el patch utun). El esfuerzo de patch de replicación es manejable; el de patch de portabilidad macOS también.

## Estructura comparada con mlvpn

| | mlvpn | ubond |
|---|---|---|
| Líneas src | ~7544 | ~7821 |
| `mlvpn.c`/`ubond.c` | scheduler WRR estándar | scheduler WRR + lógica de resend + SRTT por túnel |
| `reorder.c` | reorder simple por seq global | reorder con `is_initialized`, drain check, target_len, total_loss tracking |
| `filters.c` | filtro PCAP per-tunnel routing | mismo filtro PCAP per-tunnel routing (idéntico) |
| Crypto | ChaCha20-Poly1305 / Salsa20 | mismo (libsodium) |
| Privilege separation | Sí (`privsep.c`) | Sí (`privsep.c`) |
| Resend buffer | No | **Sí** — `old_pkts[RESENDBUFSIZE]` per túnel (RESENDBUFSIZE=10240) |
| Detección de pérdida | umbral simple | bitmap `seq_vect` con ventana, `loss_av` smoothed |
| SRTT per-túnel | No | **Sí** — `srtt_av/min/max` actualizado en ACKs |
| `data_seq` global | No | **Sí** — secuencia compartida entre túneles, base del dedup |
| `reorder` flag por paquete | No | **Sí** — solo TCP entra al buffer (UDP entra directo, sin reorder) |

## Hallazgos clave para replicación selectiva

### 1. La secuencia global `data_seq` es la pieza central

`build/ubond/src/ubond.c:90`:

```c
static uint64_t data_seq = 1;
```

Cada paquete de datos (no resend) lleva `data_seq` único en todo el túnel (no per-link). Ese número es la clave para que el receptor pueda deduplicar.

`ubond_rtun_send()` línea 663:

```c
if (pkt->p.type != UBOND_PKT_DATA_RESEND) {
    if (pkt->p.reorder) {
        proto->data_seq = data_seq;
    } else {
        proto->data_seq = 0;  // ← UDP no entra
    }
}
```

`reorder.c:251`:

```c
if (!b->enabled || !pkt->p.reorder || !pkt->p.data_seq)
    /* salta el reorder buffer — el paquete va directo */
```

**Implicación**: para implementar **replicación de UDP** hay que cambiar `set_reorder()` para que también marque UDP de interés con `reorder=1` y `data_seq != 0`, **o** añadir un dedup separado del reorder buffer.

### 2. `set_reorder()` ya distingue protocolo IP por byte 9

`build/ubond/src/ubond.c:644` (función `set_reorder`):

```c
if ((pkt->p.type == UBOND_PKT_DATA || pkt->p.type == UBOND_PKT_DATA_RESEND)
    && pkt->p.data[9] == 6) {  // 6 = TCP
    pkt->p.reorder = 1;
} else {
    pkt->p.reorder = 0;  // UDP, ICMP, etc.
}
```

`pkt->p.data[9]` es el campo "Protocol" del header IPv4. **Aquí está el punto natural de extensión**: añadir una función `should_replicate(pkt)` que compruebe 5-tupla y devuelva `true` para flujos críticos (RTP, etc).

### 3. El sistema de filtros existente (PCAP/BPF) ya hace per-tunnel routing

`build/ubond/src/filters.c:6`:

```c
ubond_tunnel_t *
ubond_filters_choose(uint32_t pktlen, const u_char *pktdata) {
    /* itera filtros BPF, devuelve el túnel asignado al primero que matchea */
}
```

`ubond_rtun_choose()` ya lo invoca:

```c
#ifdef HAVE_FILTERS
    ubond_tunnel_t *frtun = ubond_filters_choose(len, data);
    if (frtun) {
        rtun = frtun;
        sbuf = &rtun->hpsbuf;  // high priority send buffer
    }
#endif
```

**Implicación**: extender la sintaxis del config para declarar **filtros de replicación** además de filtros de routing. Reutilizar `pcap_offline_filter()` para evaluar la regla.

### 4. `hpsbuf` (high priority send buffer) per-túnel — vector para replicación

Cada túnel tiene un `hpsbuf` separado del `sbuf` normal. Es lo que usan los filtros existentes para meter paquetes "skip-the-queue". Para replicación: clonar el paquete e insertar en el `hpsbuf` de N túneles activos. El receptor recibe varios con mismo `data_seq` y se queda con uno.

## Punto de extensión propuesto para Fase 2

**Diseño preliminar** (a refinar en REQ-NET-12):

```ini
[filter.replicate]
   "udp dst port 5004"   ; ej. RTP típico
   "udp dst port 19302"  ; ej. STUN/Meet
```

Lógica en `ubond_rtun_choose()`:

1. Tras `ubond_filters_choose` (routing), comprobar `ubond_replication_filters_match(pkt)`.
2. Si match: para cada túnel `t` en estado `UBOND_AUTHOK`, clonar `pkt` (con mismo `data_seq` ya asignado) e insertar en `t->hpsbuf`.
3. Si no match: comportamiento normal (un solo túnel).

Lógica en receptor (`ubond_protocol_read()` o reorder):

- Mantener un set de últimos N `data_seq` vistos por flujo (5-tupla).
- Si el paquete entrante tiene `data_seq` ya visto → descartar.
- Set debe ser pequeño (LRU de ~256 entradas) y específico por flujo replicado para no dañar dedup de TCP normal.

Estimación: **~250-400 LOC** entre filtros nuevos, clone de pkt, dedup set. No requiere romper lógica existente.

## Issues identificados

### Bloqueante #1 — Compilación macOS

```text
ubond.c:1117:18: error: variable has incomplete type 'struct ifreq'
```

Función `ubond_rtun_bind()`. Probablemente usa `SO_BINDTODEVICE` (Linux-only). Igual que tuvimos que escribir `patches/tuntap_darwin_utun.c` para mlvpn, aquí hará falta un patch para `ubond_rtun_bind` que use `IP_BOUND_IF` (la API equivalente en macOS).

Estimación patch: **~50 LOC**, similar a lo que ya conocemos del patch utun.

### Bloqueante #2 — Repo abandonado desde 2022

11★, sin commits desde enero 2022. Cualquier patch nos lo mantenemos nosotros. No hay maintainer al que enviar PRs upstream.

### No-bloqueante — Compatibilidad con stack actual

- ubond usa `RESENDBUFSIZE=10240` per túnel: ~10240 × 1400 bytes = ~14 MB RAM por túnel. Con 3 túneles = 42 MB. **No es problema** en RPi 4 con 4 GB.
- ubond binary se llama `ubond`, no `mlvpn`. No interfiere con el deploy actual.
- ubond escribe a `/etc/ubond/ubond.conf` (separado de `/etc/mlvpn/`). Coexistencia limpia.

## Recomendaciones para Fase 2

1. **Abrir REQ-NET-12 — Replicación selectiva por 5-tupla** con el diseño detallado del filtro + dedup.
2. **Decidir el porting macOS antes que el patch de replicación**: sin compilación local no hay forma de iterar. El porting es trabajo pequeño (50 LOC) y desbloquea el resto.
3. **Mantener `build/ubond/` separado de `build/MLVPN/`** durante toda la v2 — no compartir nada hasta el cutover.
4. **No empezar Fase 3 (implementación)** hasta tener Fase 2 (diseño) validado por escrito. Evita repetir el patrón "tuning empírico" que llevó a 5 commits revertidos en mlvpn.

## Lo que queda fuera del scope de Fase 1

- Probar replicación end-to-end (es Fase 3-5)
- Decidir sintaxis exacta del filtro (es Fase 2)
- Estimar rendimiento real (Fase 5, requiere AVE)
- Tests unitarios (Fase 3)

## Estado de la branch

`feat/ubond-evaluation` contiene:

- `build/ubond/` — clon de upstream
- `docs/v2-ubond/01-fase1-exploracion.md` (este documento)

**Sin cambios en código ave-vpc**. v1.0.0 (en `main`) sigue intacta.
