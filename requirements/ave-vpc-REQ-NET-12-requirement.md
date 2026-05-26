### ave-vpc.REQ-NET-12 - Replicación selectiva de paquetes por 5-tupla

> **Estado**: implementado 2026-05-26 (Fase 3). Patch en
> `patches/ubond_replicate_filter.patch` (283 líneas, 4 archivos:
> `ubond.h`, `filters.c`, `ubond.c`, `config.c`). ubond compila
> limpio en macOS Apple Silicon con el patch aplicado (binario
> 164952 bytes). Pendiente: validación end-to-end con dos UDP fakes
> (Fase 3 tests integración) + comparativa AVE real (Fase 5).

**Description:**

El bonding paquete-a-paquete WRR de mlvpn/ubond rompe sesiones HTTP/2
streaming, WebSockets y videoconferencias UDP/RTP cuando los enlaces
tienen latencias dispares (caso real validado en producción AVE
2026-05-25). El modo `--failover` (REQ-NET-11) lo mitiga sacrificando
agregación de BW.

La solución técnica que SÍ recupera bonding real para flujos
interactivos es **replicación selectiva de paquetes**: para flujos
críticos identificados por 5-tupla (ej. UDP/RTP de videoconf), enviar
el MISMO paquete por **TODOS** los túneles activos simultáneamente;
el receptor descarta duplicados quedándose con el primero que llegue.

Beneficios:
- **Latencia efectiva = la del enlace más rápido** (no la del más
  lento, como con bonding round-robin).
- **Cero jitter** del bonding paquete-a-paquete.
- **Resiliencia**: si un enlace cae mid-flujo, los demás siguen
  entregando.
- **Throughput sigue agregándose** para el resto del tráfico (TCP
  largos, descargas) que no matchea las reglas.

Coste: cada paquete replicado consume N veces ancho de banda. Por
eso el filtro es **selectivo** (5-tupla específica), no global.

ubond ya tiene el 70 % del andamiaje (`data_seq` global, reorder
buffer con dedup, sistema de filtros PCAP/BPF, `hpsbuf`
high-priority send buffer per-túnel). Lo que falta es:

1. Nueva sección `[filter.replicate]` en el config con reglas
   tipo BPF.
2. Lógica de clone-to-N-tunnels en `ubond_rtun_choose()`.
3. Dedup set LRU en el receptor para descartar duplicados.

**Parent Requirement:** ave-vpc.REQ-NET-09 (rama v2)

---

## Sintaxis del filtro en config

Sección nueva `[filter.replicate]` (paralela a la existente
`[filters]` que hace per-tunnel routing). Cada entrada es un nombre
arbitrario asociado a una expresión BPF/pcap-filter:

```
[filter.replicate]
rtp_zoom        = "udp and (dst port 19302 or src port 19302)"
rtp_meet        = "udp and (dst port 3478 or dst port 19305)"
anthropic_sse   = "tcp and dst port 443 and dst host api.anthropic.com"
```

Las expresiones se compilan con `pcap_compile()` igual que los
filtros existentes (sección `[filters]`). Pero al matchear, el
comportamiento es distinto: en lugar de devolver UN túnel destino,
el paquete se duplica a TODOS los túneles activos (excepto los
excluidos por `fallback_only=1`, `FLAP_EXCLUDED`, `DEAD_LINK_EXCLUDED`).

## Diseño técnico — lado cliente (envío)

### 1. Estructura nueva en `ubond.h`

```c
struct ubond_replicate_filters_s {
    uint16_t count;
    struct bpf_program filter[255];
    char name[255][32];  /* solo para logs */
};
```

### 2. Función nueva `filters.c`

```c
/* Devuelve 1 si el paquete matchea alguna regla de replicación */
int ubond_replicate_filter_match(uint32_t pktlen, const u_char *pktdata);

/* Añade una regla compilada al pool de replicación */
int ubond_replicate_filter_add(const struct bpf_program *filter,
                               const char *name);
```

### 3. Modificación de `ubond_rtun_choose()` en `ubond.c:1777`

**Antes** (estado actual, simplificado):
```c
ubond_pkt_t *spkt = pop_from_send_buffer();
ubond_tunnel_t *frtun = ubond_filters_choose(len, data);
if (frtun) {
    rtun = frtun;
    sbuf = &rtun->hpsbuf;
}
UBOND_TAILQ_INSERT_HEAD(sbuf, spkt);  /* un solo túnel */
```

**Después** (con replicación):
```c
ubond_pkt_t *spkt = pop_from_send_buffer();

/* Comprobar si el paquete debe replicarse */
if (ubond_replicate_filter_match(spkt->p.len, (u_char *)spkt->p.data)) {
    /* Asignar data_seq UNA VEZ aquí (todas las copias deben tenerlo
     * idéntico para que el receptor pueda dedupear). */
    spkt->p.reorder = 1;
    spkt->p.data_seq = data_seq++;

    /* Clonar e insertar en hpsbuf de cada túnel elegible */
    int copies = 0;
    LIST_FOREACH(t, &rtuns, entries) {
        if (t->status != UBOND_AUTHOK) continue;
        if (t->fallback_only) continue;  /* respeta --failover */
        if (ubond_pkt_list_is_full(&t->hpsbuf)) continue;

        ubond_pkt_t *clone = ubond_pkt_get();
        memcpy(&clone->p, &spkt->p, sizeof(spkt->p));
        UBOND_TAILQ_INSERT_HEAD(&t->hpsbuf, clone);
        copies++;
    }
    ubond_pkt_release(spkt);  /* original ya no se usa */
    log_debug("replicate", "data_seq=%lu enviado por %d tuneles",
              spkt->p.data_seq, copies);
    return;
}

/* Camino normal — un solo túnel via WRR + filtros routing */
ubond_tunnel_t *frtun = ubond_filters_choose(len, data);
if (frtun) {
    rtun = frtun;
    sbuf = &rtun->hpsbuf;
}
UBOND_TAILQ_INSERT_HEAD(sbuf, spkt);
```

### 4. `set_reorder()` cambia comportamiento mínimamente

El `set_reorder()` actual (`ubond.c:639`) solo asigna `reorder=1` a
TCP. Con replicación, **los paquetes replicados también deben tener
`reorder=1`** para que `data_seq` se asigne y el reorder buffer del
receptor pueda dedupearlos.

Pero los paquetes replicados pasan por `ubond_replicate_filter_match`
ANTES de `set_reorder()`. Si replicamos, ya forzamos `reorder=1`
manualmente y nos saltamos `set_reorder()`.

## Diseño técnico — lado servidor (recepción + dedup)

### 5. Dedup set LRU en `ubond.c`

```c
/* Set circular de últimos REPLICATE_DEDUP_SIZE data_seq vistos.
 * 1024 entradas a uint64_t = 8 KB, despreciable. */
#define REPLICATE_DEDUP_SIZE 1024

static uint64_t replicate_dedup_seen[REPLICATE_DEDUP_SIZE] = {0};
static uint16_t replicate_dedup_idx = 0;

/* Devuelve 1 si data_seq ya fue visto recientemente (= duplicado),
 * 0 si es nuevo (lo añade al set). */
static int ubond_replicate_dedup_check(uint64_t data_seq) {
    if (data_seq == 0) return 0;  /* paquetes sin reorder */

    /* Búsqueda lineal — para 1024 entradas modernas, ~1µs */
    for (int i = 0; i < REPLICATE_DEDUP_SIZE; i++) {
        if (replicate_dedup_seen[i] == data_seq) return 1;
    }
    /* Nuevo: insertar en posición circular */
    replicate_dedup_seen[replicate_dedup_idx] = data_seq;
    replicate_dedup_idx = (replicate_dedup_idx + 1) % REPLICATE_DEDUP_SIZE;
    return 0;
}
```

### 6. Modificación de `ubond_protocol_read()` en `ubond.c:556`

Tras desencriptar y antes de meter al reorder buffer:

```c
/* REQ-NET-12: dedup de paquetes replicados.
 * Los paquetes replicados llegan con mismo data_seq por N túneles.
 * El primero que llega se procesa; los demás se descartan aquí
 * antes de tocar el reorder buffer (que tendría problemas con
 * paquetes "out-of-order" que en realidad son duplicados). */
if (ubond_replicate_dedup_check(proto->data_seq)) {
    log_debug("replicate", "%s descartando duplicado data_seq=%lu",
              tun->name, proto->data_seq);
    return 0;  /* éxito: el "primer hermano" ya pasó */
}
```

### 7. ¿Por qué set LRU separado del reorder buffer?

El reorder buffer existente (`reorder.c`) ya descarta paquetes con
`data_seq <= min_seqn` (línea 251). Eso podría servir para dedup,
PERO:

- El reorder buffer **espera al hueco** (timeout) cuando llega un
  paquete out-of-order. Para videoconf UDP/RTP, esa espera es
  destructiva — la app necesita el paquete ya o nada.
- Los paquetes UDP no entran al reorder buffer (`reorder=0` por
  defecto en `set_reorder`).
- El dedup de reorder es por "ya entregado", no por "ya visto en
  algún túnel".

Por eso el set LRU es **adicional** y se ejecuta ANTES del reorder
buffer. Para los paquetes UDP replicados, el reorder buffer queda
inactivo (los entregamos directo); el set LRU descarta los
duplicados de los demás túneles.

## Edge cases

### EC1 — Modo `--failover` activo

En `--failover`, los túneles con `fallback_only=1` solo llevan
keepalives. El loop de replicación los excluye (ver código arriba).
La replicación solo va por el activo + cualquier otro sin
`fallback_only=1`. Si solo hay 1 enlace activo, la "replicación" es
1 copia (= comportamiento normal).

### EC2 — Túneles excluidos por flapping (REQ-NET-15) o dead-link (REQ-NET-16)

`FLAP_EXCLUDED` y `DEAD_LINK_EXCLUDED` son state del selector
externo, no del proceso mlvpn. mlvpn no los conoce. Pero el selector
ya marca esos túneles como `fallback_only=1` cuando los excluye, así
que el chequeo `t->fallback_only` los cubre indirectamente.

### EC3 — Paquetes UDP DATA_RESEND

Los `UBOND_PKT_DATA_RESEND` son retransmisiones que mlvpn pide cuando
detecta pérdida en un túnel concreto. NO deben replicarse — su
propósito es retransmitir un paquete específico por un túnel
concreto. La función `ubond_replicate_filter_match` solo se llama
para `UBOND_PKT_DATA`, no para `_RESEND`.

### EC4 — `data_seq` overflow

`data_seq` es uint64_t. A 1 Gbps de paquetes-replicados, tarda
millones de años en hacer wrap. No es problema.

### EC5 — Filtros mal escritos

Si una expresión BPF mal formada se intenta compilar, `pcap_compile`
falla. El config loader (`config.c`) loguea warning y NO añade la
regla. Mismo comportamiento que filtros existentes.

### EC6 — Receptor sin replicación habilitada

El receptor (RPi) NO necesita config de replicación — solo el dedup
LRU es siempre activo. Si data_seq se repite, descarta. Si nunca se
repite (el cliente no replica), nunca descarta nada. El cambio en
`protocol_read()` es transparente para tráfico no replicado.

## Cambios fuera de `ubond.c`

- `config.c` (~línea 447): nuevo bloque que reconoce
  `[filter.replicate]` y compila las reglas con `pcap_compile`,
  añadiéndolas con `ubond_replicate_filter_add()`.
- `ubond.h`: declarar `struct ubond_replicate_filters_s` y la global.
- `filters.c`: implementar `ubond_replicate_filter_match` y
  `ubond_replicate_filter_add`.

## Estimación de tamaño del patch

- `ubond.h`: ~10 LOC (struct + extern)
- `filters.c`: ~30 LOC (nuevas funciones)
- `ubond.c`: ~50 LOC (modificaciones rtun_choose + protocol_read +
  dedup set)
- `config.c`: ~25 LOC (parser de la nueva sección)
- Total: **~115 LOC**, dentro del rango previsto en Fase 1
  (250-400 LOC era estimación pesimista).

## Plan de pruebas (Fase 3)

1. **Test unitario del dedup set**: dado un set, comprobar que
   data_seq repetidos se detectan; verificar wrap circular.
2. **Test integración con 2 UDP fakes** (sockets locales con
   distintos delays sintéticos):
   - Cliente envía 1000 paquetes UDP que matchean filtro
   - Servidor recibe ~1000 distintos (no ~3000)
3. **Test en producción AVE** (Fase 5): comparar latencia y jitter
   percibida en videoconf con/sin replicación.

---

**Acceptance Criteria:**

- `requirements/ave-vpc-REQ-NET-12-requirement.md` (este documento)
  describe completa la sintaxis, las funciones a tocar, los edge
  cases y el plan de tests.
- Sin código todavía. La implementación es Fase 3 separada.
- Test estático `tests/test_REQ-NET-12_design_doc.sh` que verifica
  que el doc cubre los puntos clave (sintaxis, dedup LRU, edge
  cases, estimación LOC).
- El diseño respeta la arquitectura existente: usa
  `data_seq` global, `pcap_compile`, `hpsbuf`, sistema de filtros.
- El receptor es 100 % compatible hacia atrás: si nadie replica,
  el dedup set nunca dispara.
- Sin variables nuevas en `config/env`. Toda la config de
  replicación va en `mlvpn.conf` / `ubond.conf` (sección nueva
  `[filter.replicate]`).
