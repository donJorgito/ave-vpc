### ave-vpc.REQ-NET-10 - Calibración dinámica de pesos WRR (DEPRECATED)

> **Estado: DEPRECATED 2026-05-25**. La calibración dinámica del
> WRR vía `bandwidth_upload` desestabilizó mlvpn en producción real
> (SIGHUP frecuente provocaba colapso de throughput). Sustituido
> funcionalmente por REQ-NET-11 (failover dinámico vía
> `fallback_only`, mucho más conservador). El script
> `tools/calibrar-enlaces-dinamico.sh` se mantiene en el repo como
> herramienta de uso manual experimental, pero **04-conectar.sh ya
> NO lo lanza automáticamente**.

**Description (histórica):**

La intención era reescribir `bandwidth_upload` per-link cada 30 s
proporcional al "score" observado de cada enlace (RTT + pérdida) y
hacer SIGHUP a mlvpn para que recalculara pesos WRR sin tirar el
túnel. Validado empíricamente que **no funciona en producción real**:
- El SIGHUP frecuente con cambios en `bandwidth_upload` causaba
  desestabilización del bonding.
- Combinación con `reorder_buffer_size` agresivo del REQ-NET-09 hacía
  que el throughput colapsara a 80 KB/s y rompiera conexiones HTTP/2.
- Visto 2026-05-22.

**Lo que se aprendió (aplicado en REQ-NET-11):**

- Tocar pesos WRR en runtime es agresivo. Tocar solo `fallback_only`
  per-link (cambiar el rol activo↔backup) es mucho más estable.
- mlvpn hace failover automático con `timeout = 2` (cap mínimo) si
  el activo cae — no hace falta calibrador para casos de caída
  abrupta.
- El selector de mejor enlace (REQ-NET-11) cubre la "rotación
  proactiva" sin tocar pesos.

**Parent Requirement:** ave-vpc.REQ-NET-09

**Acceptance Criteria (estado deprecated):**

- `tools/calibrar-enlaces-dinamico.sh` existe en el repo y pasa
  `bash -n` + `shellcheck`. Es ejecutable.
- `04-conectar.sh` **NO** lanza este script automáticamente. El
  bloque que lo lanzaba está eliminado del flujo principal.
- El script si se invoca manualmente envía sus trazas a syslog
  (`logger -t mlvpn-calibrator`), no a `generated/mlvpn.log`.
- Para casos de uso real (failover en AVE), se usa REQ-NET-11
  (`--failover` con selector dinámico).
