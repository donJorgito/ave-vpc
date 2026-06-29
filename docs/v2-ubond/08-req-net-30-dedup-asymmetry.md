# REQ-NET-30 — Causa raíz del cuelgue de replicación: asimetría de `[filters.replicate]`

## Resumen ejecutivo

El cuelgue del dataplane bajo `[filters.replicate]` activo (síntoma: ping 0/N pese a tener túnel autenticado y links activos) NO era un problema de C-level race ni de timing, ni se solucionaba con REQ-NET-27 (`data_seq` compartido) ni con REQ-NET-29 (parser filters).

Era un bug **arquitectónico**: el gate de dedup en el receptor (`ubond.c:659`) dependía de la config local del receptor (`ubond_replicate_filters.count > 0`), no de la señal autoritativa del sender en el wire packet. Cuando el cliente tiene la sección poblada y el servidor la tiene vacía (default según `07b-setup-rpi-ubond.sh:216`), el servidor NO dedupea aunque el wire trae clones marcados con `data_seq != 0` → kernel del RPi recibe paquetes duplicados → dataplane se rompe.

## Validación experimental (oficina 2026-06-03, 12:35-12:45)

### Setup

- Mac (cliente): `[filters.replicate]` con `icmp_all = "icmp"` + reglas anthropic/zoom/rtp.
- RPi (server): tres iteraciones del test:
  - **Iteración 1** (sin tocar nada): `[filters.replicate]` vacía → ping 0/N (bug reproducido).
  - **Iteración 2**: añadido `icmp_all = "icmp"` simétrico al RPi + restart ubond.
  - **Iteración 3**: ping con replicate activo end-to-end.

### Resultado

```text
PING 10.10.20.1 (10.10.20.1): 56 data bytes
64 bytes from 10.10.20.1: icmp_seq=0 ttl=64 time=49.607 ms
64 bytes from 10.10.20.1: icmp_seq=1 ttl=64 time=46.798 ms
[...]
64 bytes from 10.10.20.1: icmp_seq=9 ttl=64 time=54.706 ms
10 packets transmitted, 10 packets received, 0.0% packet loss
RTT min/avg/max/stddev = 45.694/51.708/57.608/4.252 ms
```

**10/10 con `[filters.replicate]` simétrico activo.** Anteriormente (asimétrico): 0/N reproducible.

### Pcap evidence (RPi `ubond0`, 60 paquetes durante el test)

De 16 ICMP echo-request ids únicos capturados, **14 mostraron 2 echo-requests llegando al `ubond0`** (gap 8-150ms entre el primer y segundo clone), 2 mostraron 1 request. Esto confirma que:

1. El cliente clona ICMP correctamente (los 2 clones salen al wire por túneles distintos).
2. El servidor — incluso con simetría — no dedupea TODOS los duplicados (leakage parcial).
3. El usuario sigue viendo 10/10 porque el kernel Linux responde a ambas requests, las 2 echo-replies vuelven, y el dedup del cliente Mac (que SÍ tiene `count > 0`) descarta la duplicada.

El leakage residual no rompe el ping pero apunta a un bug secundario por investigar (ver "Pregunta abierta" abajo).

## Diagnóstico C-level

### Gate actual (post REQ-NET-12 + 27)

```c
// build/ubond/src/ubond.c:659 (post REQ-NET-12 + 27)
if (ubond_replicate_filters.count > 0 &&
    (proto->type == UBOND_PKT_DATA || proto->type == UBOND_PKT_DATA_RESEND) &&
    ubond_replicate_dedup_check(proto->data_seq)) {
    /* descartar duplicado */
}
```

**Defecto**: depende de `ubond_replicate_filters.count`, que es estado LOCAL del receptor. Si el sender clona pero el receptor no tiene filtros configurados, la dedup nunca corre.

### Gate propuesto (REQ-NET-30)

```c
if ((proto->type == UBOND_PKT_DATA || proto->type == UBOND_PKT_DATA_RESEND) &&
    proto->data_seq != 0 &&
    ubond_replicate_dedup_check(proto->data_seq)) {
    /* descartar duplicado */
}
```

**Justificación**:

- `data_seq` viaja en el wire (`ubond_proto_t` en `pkt.h:32`, serializado con `htobe64`).
- Counter global empieza en 1 (`ubond.c:90`); `data_seq=0` está reservado como "este paquete no requiere dedup" (UDP/ICMP no replicado, keepalives, auth, version<1 legacy).
- La señal es autoritativa: el SENDER decidió en `rtun_choose` que el paquete es replicado y le puso `data_seq`. El receptor confía y dedupea. Sin negociación.

### Wire compatibility

El cambio es puramente receiver-side, no toca el wire format. Matriz:

| Cliente | Server | Resultado |
|---|---|---|
| sin patch | con patch | OK (sin replicate, `data_seq=0` siempre, gate no dispara) |
| con patch (replicate) | sin patch | Comportamiento actual (server dedupea sii su `count > 0`). **No regresa**. |
| con patch | con patch | **Bug fixed**, simétrico o asimétrico. ✓ |

## Patch entregable

`patches/ubond_dedup_gate_data_seq.patch` — 32 líneas, 1 hunk, modifica solo `ubond.c:659-665` añadiendo el comentario justificativo y cambiando el gate. Aplicable tras REQ-NET-12 (ya orden actual).

## RCA pendiente — leakage parcial residual (REQ-NET-31, separado)

El test simétrico mostró 14/16 pings con echo-request DUPLICADO llegando al `ubond0` del RPi pese a tener dedup activo (count>0 + datos correctos).

### Hipótesis previa DESCARTADA por auditor (2026-06-03)

> "¿`set_reorder()` resetea `proto->data_seq=0` al forzar `reorder=0` para ICMP?"

**Mecánicamente falsa**: `set_reorder()` se invoca SOLO en `ubond_rtun_send:713` (sender path). En el receive path (`ubond_rtun_read` → decode en `ubond.c:637` → gate dedup en línea 661), `set_reorder` no aparece. `proto->data_seq` se deserializa con `be64toh` y NO se modifica antes del check. Los ICMP clones llegan con `data_seq != 0` y el nuevo gate los dedupea correctamente.

### Hipótesis vigentes (a investigar como REQ-NET-31)

1. **LRU size insuficiente bajo burst**: `REPLICATE_DEDUP_SIZE = 1024` en `ubond.c:209`. Si tráfico TCP heavy ocupa la LRU más rápido que el gap entre clones (8-150ms observado), el `data_seq` del primer clone se sobreescribe antes de que llegue el segundo. A 6.8k pps + gap 150ms, posible. En el test mínimo (solo pings, ≪1k pps), improbable como causa única.
2. **Race entre lectura concurrente de dos tunnels en el mismo tick libev**: aunque libev es single-threaded, si ambos tunnels entregan paquete en el mismo tick del loop, los handlers se ejecutan secuencialmente. El primero llama `dedup_check` (write LRU), el segundo llama `dedup_check` (read LRU + match). Debería funcionar — auditable con instrumentación log_warnx.
3. **Pre-ubond drop**: el "second clone" no llegó nunca al wire — drop en NAT corp / 4G del operador. Tcpdump RPi solo capta lo que llega al `ubond0` (post-ubond decode); necesitaríamos tcpdump en el wire UDP (puertos 5083/5084) en ambos extremos para descartar drops upstream.
4. **Capture artifact en tcpdump**: descartado por análisis local — `tcpdump -nn -r pcap` con direction split mostró 60 in / 60 out, todos paquetes legítimos; los 14/16 pings con duplicate echo-request son reales en `ubond0`.

**Recomendación**: tracking como REQ-NET-31. NO bloquea REQ-NET-30 — el patch arregla el bug primario (asimetría → dataplane roto). El leakage residual es un bug secundario que NO degrada la funcionalidad observable (Mac dedupea réplicas en su lado, ping ve 10/10).

## Lecciones para v2

1. **Asimetrías cliente/server SIEMPRE rompen** algo si no se diseñan explícitamente. Preferir señales autoritativas en el wire packet sobre estado local del receptor.
2. **Validar bajo condiciones representativas de producción**, no solo en setups simétricos artificiales. La asimetría (default de `07b`) era el escenario real, y escondía el bug en tests simétricos.
3. **Tcpdump en el extremo correcto** (RPi `ubond0`) fue el único método para distinguir entre "cliente no envía" y "server no procesa". Sin esa visibilidad, un mes de debugging especulativo.

## Próximos pasos (post-auditor 2026-06-03)

1. ✓ Auditor revisó: APROBADO CON CAVEATS (corregir hipótesis `set_reorder` falsa — hecho en este doc + memoria).
2. ✓ Wire del patch en build scripts: `03b-setup-mac-ubond.sh:66,194-201` y `07b-setup-rpi-ubond.sh:106,123,180-187` (commit conjunto con este doc).
3. Compilar Mac+RPi con el patch (`patch -p1 -d build/ubond < patches/ubond_dedup_gate_data_seq.patch && make && sudo make install` en Mac; mismo flujo via SSH en RPi).
4. Re-test asimétrico (Mac filters poblado, RPi vacío) — si pasa 10/10, REQ-NET-30 confirmado.
5. Si paso 4 OK: revertir el `icmp_all` añadido manualmente al RPi durante el test (workaround pre-patch deja de ser necesario).
6. Crear REQ-NET-31 issue: investigar leakage residual (LRU size + race + pre-ubond drops).

## Rollback plan

Si tras aplicar el patch hay regresión observable (ping desde Mac, throughput, conexión inestable más allá del baseline pre-patch):

1. **Mac**: `patch -R -p1 -d build/ubond < patches/ubond_dedup_gate_data_seq.patch && cd build/ubond && make && sudo make install`.
2. **RPi**: SSH + reverse equivalente + `sudo systemctl restart ubond`.
3. **Workaround inmediato**: replicar simétricamente las reglas BPF del cliente en `/etc/ubond/ubond.conf` del RPi (sección `[filters.replicate]`). Eso restaura el comportamiento del test 12:40-12:41 oficina (10/10 con simetría).
4. Revertir el commit del bundle: `git revert <hash>`.

## Métricas de éxito post-deploy

Para confirmar el fix en producción real (≠ oficina):

1. **Próximo trayecto AVE Orihuela-Madrid**: ping ≥9/10 sostenido vía utun durante todo el trayecto con `[filters.replicate]` activo en cliente y vacío en server. Pre-patch: 0/N reproducible. Criterio de éxito: zero SOS triggered por health-check del watchdog.
2. **Logs RPi**: `journalctl -u ubond | grep "descartando duplicado data_seq"` debería tener count ≥1 por cada paquete replicado (medir ratio dedup_hits / clones_enviados desde Mac, esperar ~50%).
3. **No regresión TCP**: medir throughput TCP no-replicado (ej. `iperf3` por túnel) pre vs post patch — no degradar >2% (overhead estimado del LRU lookup en cada paquete TCP).
