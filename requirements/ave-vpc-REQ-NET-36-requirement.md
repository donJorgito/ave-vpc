### ave-vpc.REQ-NET-36 - Purga del pool de replicacion en SIGHUP / config reload

**Status:** Implementado, validado estatico, pendiente runtime.

**Description:**

Bug colateral descubierto durante la investigacion del agente
DNS-investigation (2026-06-08). El handler de SIGHUP en `ubond.c`
(`ubond_config_reload`, lineas 2231-2252) llama a `ubond_config()` con
`first_time=0` para releer el fichero de configuracion. La funcion
re-parsea las secciones `[filters]` y `[filters.replicate]` y vuelve a
llamar a `ubond_filters_add` y `ubond_replicate_filter_add`.

`ubond_filters` SI se resetea: `config.c:73` ejecuta
`memset(&ubond_filters, 0, sizeof(ubond_filters))` al inicio de
`ubond_config`. `ubond_replicate_filters` NO. La consecuencia:

- Cada SIGHUP exitoso DUPLICA los filtros de replicacion en el array
  porque `ubond_replicate_filter_add` hace
  `ubond_replicate_filters[count++] = filter` sin verificar si la regla
  ya existe ni resetear count antes.
- Memory leak: los `struct bpf_program` viejos quedan compilados (alloc
  hecho por `pcap_compile`) y nunca se libera con `pcap_freecode`. Cada
  reload deja basura en el heap.
- Comportamiento incorrecto: `ubond_replicate_filter_match` itera sobre
  count, asi que un paquete que matcheaba antes seguira matcheando
  multiples veces — coste CPU por iteracion duplicada y, peor, el limite
  hardcoded de 255 entries puede llenarse en ~50 SIGHUP con 5 reglas.

Tolerable a corto plazo (caso tipico: 3-5 reglas, slot 255, SIGHUP
manual rarisimo). Bloqueante en cuanto exista un watchdog que invoque
SIGHUP automaticamente — escenario que el roadmap REQ-NET-37 (DNS retry
watchdog futuro) introducira.

**Mecanismo del fix:**

- Nueva funcion `void ubond_replicate_filters_clear(void)` en
  `src/filters.c`. Itera el array `[0, count)`, llama
  `pcap_freecode(&ubond_replicate_filters.filter[i])` para liberar el
  bpf_program compilado, y resetea
  `ubond_replicate_filters.count = 0` al final.
- Forward declaration en `src/ubond.h` dentro del bloque
  `#ifdef HAVE_FILTERS` (compilada solo si pcap esta disponible).
- Call site en `src/config.c` justo antes del bucle de re-parse de la
  seccion `[filters.replicate]` (linea 517 actualmente, dentro del
  bloque `#ifdef HAVE_FILTERS` que ya existe).
- Idempotente en `first_time=1`: count=0 al arranque, el for-loop no
  itera, no-op.

**Wire compatibility:**

- Cero cambio en el protocolo wire. La funcion solo toca state
  in-process del cliente y del servidor.
- No afecta a la dedup LRU ni al gating de replicate match.
- Aplica simetricamente en cliente (Mac) y servidor (RPi).

**Why no se aplica a `ubond_filters` (filtros stock):**

`ubond_filters` ya se resetea via `memset` al inicio de `ubond_config`.
Tecnicamente eso tambien deja `bpf_program` compilados sin liberar (el
mismo memory leak conceptual), pero esta fuera del scope de REQ-NET-36
— el bug reportado por DNS-investigation es especifico de
`ubond_replicate_filters` (que NO tiene memset). Tratar el leak de
`ubond_filters` requiere cambiar el comportamiento de re-add via
`ubond_filters_add` y queda como REQ-NET-36.1 si runtime evidence lo
justifica.

**Acceptance Criteria:**

- `patches/ubond_filters_count_purge.patch` existe, aplica limpio sobre
  el arbol con los 8 patches REQ-NET-12/19/25/27/29/30/35 ya aplicados.
- `patch -p1 --dry-run` pasa sin errores ni rejections en `build/ubond`.
- Compila en macOS (Mac client) sin warnings nuevos.
- Compila en Linux RPi (server) sin warnings nuevos.
- `03b-setup-mac-ubond.sh` aplica el patch al final del chain
  (Patch 9, tras REQ-NET-35).
- `07b-setup-rpi-ubond.sh` transporta el patch base64-encoded
  (`UBOND_PATCH7_B64`) y lo aplica en el RPi tras REQ-NET-35.
- Test estatico `tests/test_REQ-NET-36_filters_purge.sh` pasa en CI
  (existencia patch + tamano + literales `ubond_replicate_filters_clear`,
  `pcap_freecode`, `count = 0` + forward decl en ubond.h + callsite
  en config.c + wire en scripts setup).

**Validacion pendiente (runtime):**

1. Rebuild en RPi y Mac con el patch aplicado.
2. Test sintetico de SIGHUP repetido:
   - Arrancar ubond con `[filters.replicate]` con 3 reglas validas.
   - `kill -HUP $(pgrep ubond)` 10 veces consecutivas.
   - Verificar via control socket o log que el numero efectivo de
     filtros sigue siendo 3, no 30.
3. Regression: tras 100 SIGHUP, RSS de ubond no debe crecer mas de
   ~32 KB respecto al baseline (3 bpf_program × ~10 KB cada uno
   × 100 reloads = 30 MB sin el fix; ~0 KB con el fix).
4. Test funcional: paquete que matcheaba pre-reload sigue
   matcheando post-reload (no se rompe la replicacion existente).

**Riesgos:**

- **Race con dataplane:** la llamada a `ubond_replicate_filters_clear`
  ocurre dentro de `ubond_config`, que corre en el event loop principal
  de libev (sincrono respecto a `ubond_rtun_choose`). No hay riesgo de
  que un paquete in-flight vea el array a medio limpiar — todo ocurre
  en el mismo hilo, secuencialmente.
- **Orden del clear vs add:** el clear() se hace ANTES del bucle de
  re-add. Si por error se invirtiera (clear despues de add), el array
  quedaria vacio post-reload. El test estatico verifica que el call
  esta en config.c pero no su orden — validacion runtime debe cubrirlo.
- **`pcap_freecode` sobre bpf_program no inicializado:** el for-loop
  itera `[0, count)`, asi que si count=0 (cold start o post-clear) el
  loop no entra. Si count>0 los slots `[0, count)` fueron poblados por
  `ubond_replicate_filter_add` que copio un bpf_program ya compilado
  por `pcap_compile`. Es seguro liberarlo.
- **Rebase contra los 8 patches existentes:** el patch fue generado
  contra `build/ubond/` con los 8 patches REQ-NET-12/19/25/27/29/30/35
  ya aplicados. Reordenar el chain o insertar un patch intermedio que
  toque las mismas zonas (filtros.c final, ubond.h decl block,
  config.c parser replicate) requiere regenerar.

**Related:**

- [[REQ-NET-29]] - parser filters seccion exclusion (predecessor en
  config.c, mismo bloque `#ifdef HAVE_FILTERS`).
- [[REQ-NET-12]] - patch original de replicacion 5-tupla, define
  `ubond_replicate_filters` y `ubond_replicate_filter_add`.
- [[REQ-NET-35]] - rebind socket UDP en silencio (predecessor en el
  chain de patches).
- `patches/ubond_filters_count_purge.patch` - el patch C en si.
- `tests/test_REQ-NET-36_filters_purge.sh` - validacion estatica.
- `03b-setup-mac-ubond.sh`, `07b-setup-rpi-ubond.sh` - wiring del
  patch en los chains de setup.
