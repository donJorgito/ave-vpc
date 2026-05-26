# Plan de trabajo — backlog priorizado

**Estado**: tras sesión 2026-05-25 (commit `0202531`).
**v1.0.0** estable y validada en producción AVE real.
**Branch principal de v2 work**: `feat/ubond-evaluation`.

## Prioridad 1 — Quick wins de v1.x (oficina, ~2 h cada uno)

Mejoras a la rama `main` que NO requieren ubond. Son arreglos de
bugs detectados en el trayecto del 25/5 que valen la pena cerrar
antes de ir a v2.

### REQ-NET-16 — Selector mide throughput además de ping

**Problema raíz validado en vivo**: el selector elige links cuyo ping
responde pero cuyo throughput es 0 KB/s. La videoconf rompe.

**Diseño preliminar**:
- Cada 5 min, hacer un curl pequeño (~100 KB) por cada interfaz
  física al RPi (no a un servicio externo, para no contar latencia
  Internet).
- El RPi expone un endpoint HTTP minimalista en puerto 5083 (nuevo,
  ufw open) que devuelve datos arbitrarios.
- Añadir un campo `throughput_kbs` a la window stats del selector.
- Score nuevo: `score = (rtt_score * 0.4) + (throughput_score * 0.6)`.
- Si `throughput_kbs == 0` durante 2 muestras consecutivas, el link
  se considera "muerto" aunque el ping responda.

**Coste**: 100 KB × 3 enlaces × 12 ciclos/h ≈ 4 MB/h. Aceptable.

**Tareas**:
1. Endpoint en RPi: `nginx` o socat sirviendo `/dev/urandom`
   tamaño-limitado en 5083/TCP.
2. Patch `seleccionar-mejor-enlace.sh` con `measure_throughput()`.
3. REQ-NET-16 doc + test estático.

**Estimación**: 3 h.

### REQ-NET-17 — Monitor `08-monitor.py` consciente de `--failover`

**Problema**: el usuario reportó que el monitor "agrega" tráfico en
modo failover cuando lo lógico sería ver solo el activo con tráfico
real y los demás con `~0` (keepalives).

**Diseño preliminar**:
- Leer `mlvpn_active.conf` al arranque del monitor.
- Para cada link, marcar `[A]` (activo) o `[B]` (backup) según
  `fallback_only`.
- Mostrar tráfico por separado del agregado físico — un eje
  "data" (activo) vs "keepalives" (backup) para no confundir.

**Estimación**: 2 h.

### REQ-NET-18 — Pre-flight: `verificar-setup.sh` exige bash 4+

**Problema**: bug del 25/5 — los watchers requieren bash 4 pero el
script de verificación no lo comprueba al inicio. Si un usuario
nuevo no tiene Homebrew bash, todo falla en runtime.

**Diseño**: `tests/verificar-setup.sh` añade check inicial:

```bash
if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: necesita bash >=4. Instalar: brew install bash"
    exit 1
fi
```

Y un test `test_REQ-NET-18_bash_version.sh` que verifica que el
check existe.

**Estimación**: 30 min.

## Prioridad 2 — Avanzar Fase 2 del roadmap v2 ubond (oficina, 1-2 h)

### Fase 2.1 — Patch macOS para que ubond compile

**Bloqueante para todo el resto de v2.** Sin compilación local de
ubond no hay forma de iterar.

**Diseño**: similar a `patches/tuntap_darwin_utun.c` que ya tenemos
para mlvpn. El error en `ubond_rtun_bind` (línea 1117) es por
`struct ifreq` incompleto en macOS. Hay que sustituir
`SO_BINDTODEVICE` (Linux-only) por `IP_BOUND_IF` (macOS).

**Tareas**:
1. Crear `patches/ubond_rtun_bind_darwin.c` con la implementación
   alternativa.
2. Modificar (a futuro) el `03b-setup-mac-ubond.sh` para aplicar el
   patch antes de compilar.
3. Verificar que ubond compila limpio en Apple Silicon.

**Estimación**: 1 h (es trabajo conocido, ya hicimos el de utun).

### Fase 2.2 — REQ-NET-12 design doc

**Sin tocar código todavía.**

**Tareas**:
1. `requirements/ave-vpc-REQ-NET-12-requirement.md`:
   - Sintaxis del filtro: `[filter.replicate]` con `udp dport 5004`,
     `udp dport 19302` (RTP, STUN/Meet).
   - Funciones a tocar: `set_reorder()`, `ubond_rtun_choose()`,
     `ubond_protocol_read()` para dedup en receptor.
   - Diagrama del flujo: clone → `hpsbuf` de N túneles → receptor
     dedupea por `data_seq`.
2. Test plan estático con grep patterns esperados.

**Estimación**: 2 h.

## Prioridad 3 — v2 Fase 3 ubond patch (~1-2 días, no en oficina)

Solo arrancar cuando Fase 2 cerrada. Es el trabajo grande de C que
añade el filtro de replicación selectiva a ubond. Mejor reservarlo
para una sesión larga sin interrupciones.

## Prioridad 4 — Mejoras nice-to-have (cuando haya tiempo)

### Plug-and-play del usuario

- `00-detectar-interfaces.sh` con detección más robusta de IFACE_*
  por DHCP range (ya existe pero podría incluir Linux y otros móviles
  no Pixel).
- Auto-detección de Apple Silicon vs Intel para PATH de Homebrew bash.

### Diagnóstico

- Comando `./tools/diagnostico.sh` que reúna: estado mlvpn, watchers
  vivos, mediciones de cada enlace, logs últimos 10 min — todo en
  un solo output para reportar problemas.

### CI

- GitHub Actions: añadir verificación de que los watchers (selector,
  reintegrator, calibrador) funcionan con bash 4 (puede simularse
  en Ubuntu sin problema).

## Lo que NO hacer

Recordatorio (de `project_v2_ubond_roadmap.md`):
1. NO reactivar `loss_tolerence`/`reorder_buffer_size` agresivos.
2. NO reactivar el calibrador WRR (REQ-NET-10 deprecated).
3. NO tocar `bandwidth_upload` en runtime — solo `fallback_only`.
4. NO comprar hardware nuevo sin agotar caminos software.
5. **NO añadir más complejidad al selector sin medir el impacto en CPU
   del Mac**. Cada watcher añade overhead; en el AVE con cobertura
   inestable, el extra de cómputo puede afectar.

## Orden sugerido para mañana en oficina

1. **(30 min) REQ-NET-18** — bash 4+ check en verificar-setup. Quick
   win, primer commit del día, calienta motores.
2. **(2 h) REQ-NET-17** — monitor consciente de `--failover`. Útil
   para ver bien lo que está pasando en los siguientes commits.
3. **(3 h) REQ-NET-16** — selector mide throughput. El más
   importante de v1.x — cierra el último bug grande del trayecto.

Si queda tiempo y motivación tras estos 3, pasar a Fase 2 del
roadmap v2 (porting macOS de ubond + REQ-NET-12 doc).
