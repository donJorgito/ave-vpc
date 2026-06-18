### ave-vpc.REQ-NET-46 - Eliminar busy-wait CPU 99% en ubond (pacing por lotes)

**Status:** Implementado (patch `patches/ubond_cpu_pacing_busywait.patch`),
validado runtime en Mac (cliente arm64) y RPi (servidor aarch64) el
2026-06-18. Dual review: experto C/libev + auditoría IDLC v6.

**Description:**

El proceso `ubond` clavaba un núcleo de CPU al **99 %** en macOS y Linux,
**incluso en reposo** con un solo enlace autenticado y sin tráfico generado
por el usuario. Diagnóstico con `sudo sample`: ~83 % de las muestras en
`__select` PERO con la CPU al 99 % — firma inconfundible de `select(timeout=0)`
repetido. Un event loop sano tiene `__select` dominante a ~0 % CPU porque el
poll bloquea de verdad; aquí no bloqueaba nunca.

Causa raíz: **tres spinners** con el mismo anti-patrón de libev (un watcher
activo que impide al loop dormir, forzando `select(timeout=0)`):

1. **`ubond_rtun_do_send`, rama "we're too soon"** (`src/ubond.c`): cuando el
   enlace agotaba su presupuesto de bytes del intervalo, armaba un `ev_check`.
   Un `ev_check` activo corre en CADA iteración del loop sin dormir.
2. **`ubond_rtun_recalc_weight`** (`src/ubond.c`): fijaba
   `send_timer.repeat = (DEFAULT_MTU/10) / bytes_per_sec`. Con división entera
   `DEFAULT_MTU/10 = 150` y `bytes_per_sec ≈ 1.25e6` a 10 Mbps, el repeat caía
   a ~0.00012 s → el `send_timer` se disparaba a **~8 kHz** (pacing
   paquete-a-paquete), y el loop nunca dormía más de esa fracción de ms.
3. **`reorder.c:reorder_drain_check`**: `ev_check` que giraba mientras el
   buffer de reordering tuviera paquetes (solo paraba al vaciarse).

**Implementación del fix:**

1. `do_send` rama "too soon": `ev_check` → `ev_timer` durmiente reprogramado
   con `ev_timer_again`, `wait = (bytes_since_adjust - b) / bytes_per_sec`,
   **floor 5 ms** (un `repeat == 0` PARARÍA el timer por semántica de libev) y
   techo `BANDWIDTHCALCTIME`.
2. `do_send` rama de éxito: envío **en lote** — bucle
   `do { ... } while (len > 0 && bytes_since_adjust < b)` que drena todos los
   paquetes que el presupuesto permite en UN solo wakeup, en vez de uno por
   disparo de timer. Desacopla la frecuencia del timer del packet-rate.
3. `recalc_weight`: **floor de 5 ms (200 Hz)** al `send_timer.repeat`.
4. `reorder_drain_check`: `ev_check` → `ev_timer` durmiente (struct, callback,
   init, enqueue, drain). El autor upstream ya tenía la variante `ev_timer`
   comentada en el código.

Es un bug de **diseño del upstream** ubond/mlvpn, no introducido por el
proyecto. El patch se aplica DESPUÉS de los 7 patches REQ-NET previos.

**Acceptance Criteria:**

- `patches/ubond_cpu_pacing_busywait.patch` existe y aplica con `patch -p1 -N`
  sin rechazos sobre upstream `markfoodyburton/ubond` + los 7 patches previos.
- El árbol parcheado compila en macOS (arm64) y Linux (aarch64).
- Tras el fix, ningún `ev_check` queda activo de forma permanente en el
  data-plane; el pacing usa `ev_timer` durmiente.
- Floors de 5 ms presentes en `do_send` (rama too-soon) y en `recalc_weight`.
- `reorder_drain_check` es `ev_timer`, no `ev_check`.
- Integrado en `07b-setup-rpi-ubond.sh` como patch nº 8 (Linux/servidor).
- Registrado en `SUPPLY_CHAIN.md` §2 (fila #9) y `CHANGELOG.md`.
- Test estático `tests/test_REQ-NET-46_cpu_pacing.sh` pasa.

**Verification:**

- **Estática:** `tests/test_REQ-NET-46_cpu_pacing.sh` — el patch existe, aplica
  limpio sobre clone fresco + 7 patches, las marcas del fix están presentes,
  no quedan `ev_check_start` en las rutas corregidas.
- **Runtime (hecha 2026-06-18):**
  - Mac cliente: `sudo sample <pid>` antes = CPU 99 % clavado, `__select` 83 %;
    después = CPU oscila 23-73 % con la carga, 0 % pérdida, latencia 60-148 ms.
  - RPi servidor: `systemd` accounting del binario viejo = **4 h 5 min de CPU
    en ~9 días** mayormente con enlaces caídos (confirmación del spin). Binario
    nuevo compilado e instalado, servicio `active`.

**Regresión detectada y corregida (2026-06-18):**

El cambio `ev_check`→`ev_timer` en `reorder_drain_check` introdujo pérdida en
arranque. Tras `ubond_reorder_reset`, `pkts_per_sec=1`; el rearme del timer
calculaba `wait=(pkts_sent+1)/pkts_per_sec` que con tasa 1 saturaba a 0.25 s
por paquete → el reorder buffer drenaba 1 pkt/250 ms durante la ventana fría
(hasta que `reorder_tick`, cada 0.25 s, sube `pkts_per_sec` a ≥1000) → los
paquetes en ráfaga del arranque caducaban y se contaban como pérdida (~80 %
los primeros segundos). El `ev_check` original no lo sufría porque corría en
cada iteración del loop (drenaba por fuerza bruta de frecuencia). **Fix:**
mientras `pkts_per_sec < 1000` (sin calentar) usar `wait=0.001`; el cálculo
por tasa solo en régimen. Verificado: pérdida por túnel **80 % → 0.0 %**.
Diagnóstico por agente experto (lectura estática), validación runtime con
`tools/safe-loss-test.sh` (dead-man's switch).

**Riesgos:**

- **Jitter de pacing:** los lotes cada ≥5 ms añaden ≤5 ms de burst-shaping.
  A escala AVE (RTT móvil > 30 ms) es imperceptible.
- **Bucle de lote:** acotado por el presupuesto `b` y por el vaciado de
  `sbuf`/`hpsbuf` (`len > 0`); no puede spinear.
- **`ev_timer_again` con `repeat == 0`:** pararía el timer (mataría el pump);
  mitigado con floor estricto > 0 en las dos ramas.
- **Pérdida en rebase del fork:** mitigado al materializar el patch en
  `patches/` y registrarlo en `SUPPLY_CHAIN.md`.

**Related:**

- `patches/ubond_cpu_pacing_busywait.patch` — el patch.
- `build/ubond/src/ubond.c` (`ubond_rtun_do_send`, `ubond_rtun_recalc_weight`)
  y `build/ubond/src/reorder.c` (`reorder_drain_check`) — código corregido.
- `07b-setup-rpi-ubond.sh` — aplica el patch en el RPi (Linux).
- `tools/ensure-askpass.sh` — helper usado para el profiling con `sudo sample`.
- [[REQ-NET-25]] — per-link tolerences (toca el mismo `recalc_weight`).
- `project_ubond_cpu_busywait.md` (memoria) — RCA completo y método.
