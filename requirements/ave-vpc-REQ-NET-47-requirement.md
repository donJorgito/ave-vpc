### ave-vpc.REQ-NET-47 - Corregir deadlock del camino de envío (`busy_writing`) introducido por REQ-NET-46

**Status:** Implementado (patch `patches/ubond_busywriting_deadlock.patch`),
diagnosticado y corregido en ruta durante el test real AVE Orihuela→Madrid del
2026-11-10. Dual review: experto C/libev + auditoría IDLC v6.

**Description:**

Primer test real del túnel ubond en el AVE tras los cambios de junio. El túnel
levantaba correctamente, autenticaba los dos enlaces móviles y pingaba, y
**a los 17-45 segundos el cliente dejaba de transmitir de golpe**, sin
recuperarse nunca. Solo revivía reiniciando el proceso.

Evidencia medida (no inferida), cliente Mac:

- `tcpdump` en la interfaz física del enlace Pixel: el tráfico saliente pasa de
  ~100 pkt/s a **0 pkt/s en un solo segundo** (11:54:41 → 11:54:42), mientras el
  servidor **sigue enviando** (87, 34, luego keepalives a ~2-3 pkt/s).
- Las rutas estaban **intactas** durante toda la caída: muestreo cada 4 s dio
  `rutas_vps=3 rutas_/1=2` constantes mientras el ping al túnel ya fallaba.
  Queda descartada la hipótesis de pérdida de la ruta anti-loop.
- `ubond` seguía declarando los enlaces activos (`@links.pixel @links.iphone`)
  hasta que vencía su `timeout = 30`, momento en que el watchdog disparaba SOS.

Causa raíz: **regresión introducida por el patch de REQ-NET-46**
(`ubond_cpu_pacing_busywait.patch`). `busy_writing` es un semáforo que significa
"tengo una tanda de escrituras pendientes de que `io_write` me avise", y solo se
decrementa **una vez por callback** de `ubond_rtun_write()` (`src/ubond.c`). El
bucle de envío por lotes que introdujo REQ-NET-46 lo incrementaba una vez **por
paquete**. Con `bandwidth_upload = 10 Mbit/s` y el floor de 5 ms del timer, el
presupuesto por despertar son ~6250 bytes ≈ 4 paquetes: el contador subía +4 y
bajaba -1, así que **nunca volvía a cero** en cuanto había tráfico real.

La trampa se cerraba en la rama "too soon" de `ubond_rtun_do_send()`: al pasarse
de presupuesto cae al tramo final de la función, que ejecutaba
`ev_io_stop(io_write)` **sin comprobar `busy_writing`** — a diferencia de su
gemela del camino de éxito, que sí lleva esa guarda. Parado `io_write`, ya no
quedaba nadie que decrementase el contador, y los dos únicos bombeos restantes
(`ubond_rtun_write_timeout` y `ubond_rtun_write_check`) están ambos guardados
por `if (!tun->busy_writing)` → **el enlace quedaba mudo de forma permanente**.

La salida de emergencia que existía antes de REQ-NET-46 ya no está: el
`check_ev` rescataba esta situación corriendo en cada iteración del loop, pero
aquel patch eliminó su único `ev_check_start`. Hoy el watcher se inicializa
(`ev_check_init`) y nunca se arranca, solo se para.

Explica por qué tardaba 17-45 s (hace falta una ráfaga que infle el contador) y
por qué la validación de junio no lo detectó: fue en oficina, con tráfico corto
y ligero en el que el lote casi siempre enviaba un único paquete.

**Implementación del fix:**

1. **Contador por lote, no por paquete** (`ubond_rtun_do_send`, bucle de envío):
   variable local `batch_sent`; `tun->busy_writing++` se ejecuta como mucho una
   vez por invocación, que es lo que casa con el decremento único de
   `ubond_rtun_write()`. La contabilidad de bytes (`bytes_since_adjust`) y el
   arranque de `io_write` siguen siendo por paquete, sin cambios.
2. **Guarda en el `ev_io_stop` del tramo final**: misma condición
   `!tun->busy_writing` que ya llevaba el `ev_io_stop` del camino de éxito. Es
   cinturón sobre tirantes: aunque algo volviera a inflar el contador, no se
   mata al único watcher capaz de bajarlo.
3. **Reset del semáforo en el rebind** (`ubond_rtun_rebind_socket_internal`):
   el mismo deadlock por otra puerta, detectado por el revisor experto y
   verificado después. Esa función para `io_write` y cierra el socket, pero
   nunca reseteaba `busy_writing` (el único reset vivía en la creación del
   túnel). Si quedaba una escritura en vuelo, el contador se quedaba clavado y
   tras el rebind nadie volvía a arrancar `io_write` (`ubond_rtun_start` solo
   arranca `io_read`) → enlace mudo permanente. Lo dispara REQ-NET-35 tras
   `UBOND_REBIND_SILENCE_S` (90 s) de silencio inbound, así que **no es** el
   fallo medido hoy (17-45 s), pero es idéntico en naturaleza. Como el socket
   se cierra ahí mismo, no hay escritura pendiente real: `busy_writing = 0`.

**Hallazgos del revisor experto (C/libev) que NO se han cambiado:**

- `ubond_rtun_write_check` es **código muerto**: REQ-NET-46 eliminó su único
  `ev_check_start`, así que solo quedan DOS bombeos reales (`io_write` y
  `send_timer`), no tres. Documentado en los comentarios del fix para no
  apoyarse en una red de seguridad que no existe. Eliminar la función es
  limpieza aparte, fuera del alcance de este arreglo.
- La rama `if (len > 0)` del tramo final de `do_send` es **inalcanzable** desde
  que REQ-NET-46 metió el `return` en el camino de éxito (`len` siempre vale 0
  ahí). No es doble contabilidad de bytes, es código muerto. Igualmente,
  limpieza aparte.

**Acceptance Criteria:**

- `patches/ubond_busywriting_deadlock.patch` existe y aplica con `patch -p1 -N`
  sin rechazos sobre upstream `markfoodyburton/ubond` + los 8 patches previos.
- El árbol parcheado compila en macOS (arm64) y Linux (aarch64).
- `tun->busy_writing++` aparece como mucho una vez por invocación de
  `ubond_rtun_do_send`, guardado por `batch_sent`.
- Los dos `ev_io_stop` de `ubond_rtun_do_send` están guardados por
  `!tun->busy_writing`.
- Integrado en `07b-setup-rpi-ubond.sh` como patch nº 9 (Linux/servidor).
- `07b-setup-rpi-ubond.sh` admite `FORCE_REBUILD=1` para recompilar sobre una
  RPi ya provisionada (sin esto era imposible propagar patches nuevos).
- Registrado en `SUPPLY_CHAIN.md` §2 y `CHANGELOG.md`.
- Test estático `tests/test_REQ-NET-47_busywriting_deadlock.sh` pasa.

**Verification:**

- **Estática:** `tests/test_REQ-NET-47_busywriting_deadlock.sh` — el patch
  existe, las marcas del fix están presentes en el árbol, no queda ningún
  `ev_io_stop` sin guarda en `do_send`, y el incremento del semáforo está
  acotado por `batch_sent`.
- **Runtime:** sesión AVE 2026-11-10 — pendiente de ventana de validación con el
  túnel levantado; el diagnóstico sí es runtime (tcpdump bidireccional en Mac y
  RPi, muestreo de rutas y de estado de enlaces cada 4 s).

**Riesgos:**

- **Reintroducir el spin de CPU de REQ-NET-46:** la guarda nueva mantiene
  `io_write` activo mientras haya una escritura en vuelo, y un socket UDP casi
  siempre es escribible. Acotado porque `busy_writing` ya no puede inflarse: el
  callback de `io_write` lo baja a 0 en un solo disparo y entonces el stop sí se
  ejecuta. Vigilar CPU en la validación runtime.
- **Enlace que nunca vuelve a ser escribible:** si `io_write` no dispara jamás,
  `busy_writing` se queda en 1 y el enlace vuelve a quedar mudo. No observado;
  el modo de fallo anterior necesitaba inflar el contador, que es lo que se
  corrige. Un rearme defensivo por `send_timer` queda como mejora futura.

**Related:**

- `patches/ubond_busywriting_deadlock.patch` — el patch.
- `build/ubond/src/ubond.c` (`ubond_rtun_do_send`) — código corregido.
- `07b-setup-rpi-ubond.sh` — aplica el patch en el RPi y soporta `FORCE_REBUILD`.
- [[REQ-NET-46]] — el patch que introdujo la regresión; mismo `do_send`.
- `project_ubond_busywriting_deadlock.md` (memoria) — RCA completo y las
  hipótesis descartadas con evidencia (red, NAT de operador, rutas, relojes).
