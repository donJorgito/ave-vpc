### ave-vpc.REQ-NET-50 - El monitor muestra los enlaces LOSSY (`~`) de ubond

**Status:** Implementado (`08-monitor.py`: `check_daemon_links`, `draw`).
Verificado sin red con pytest. Validación runtime pendiente de un test real
con el túnel levantado.

**Description:**

`check_daemon_links` obtiene el estado de cada enlace del título del proceso
del daemon. ubond lo construye en `update_process_title()`
(`build/ubond/src/ubond.c`) con tres símbolos: `@` (`UBOND_AUTHOK`), `~`
(`UBOND_LOSSY`) y `!` (cualquier otro estado). El monitor solo reconocía `@` y
`!`, de modo que un enlace en `~` se omitía del diccionario devuelto y
`draw()` lo pintaba como `SIN TUNEL`, igual que un enlace ausente.

Reproducción sin red: con `subprocess.check_output` parcheado para devolver
`ubond: ubond0 ~links.wifi @links.pixel ~links.iphone`, la función devolvía
solo `{'links.pixel': 'OK'}`. En un viaje real el iPhone se vio como
`SIN TUNEL` mientras cursaba tráfico (1,7 KB/s rx, 2,5 KB/s tx); es coherente
con este defecto, pero el título exacto en ese instante no se capturó, así que
no se da como causa probada.

**Implementación del fix:**

1. `check_daemon_links` añade el patrón `~(links\.\w+)` y devuelve el estado
   `LOSSY` para esos enlaces.
2. `draw()` pinta `PÉRDIDAS ~` en amarillo (`YELLOW`, el color de aviso ya usado
   por `AUTH...` y `SIN TUNEL`), con 11 caracteres visibles dentro de la columna
   de 16, sin alterar el ancho de la tabla.
3. Un enlace LOSSY **no suma** a `active_count`, y por tanto no cuenta en
   `REPLICATE ACTIVO (N enlaces)` / `BONDING ACTIVO (N enlaces)`. Justificación
   en el código de ubond: la elección de enlace para enviar
   (`ubond_rtun_choose`, `status != UBOND_AUTHOK` retorna) y la replicación
   (`status != UBOND_AUTHOK` continúa) excluyen los enlaces LOSSY; el recuento
   `connected` también exige `UBOND_AUTHOK`. Sigue recibiendo (las rutas de
   recepción usan `status >= UBOND_AUTHOK`), por eso no es `SIN TUNEL`.
4. Único consumidor del diccionario: `draw()`. `check_failover_roles` (solo
   mlvpn, lee la configuración) y `check_replicate_active` (lee la
   configuración) no lo usan.

**Acceptance Criteria:**

- `~links.X` se devuelve como `LOSSY`; `@` como `OK`; `!` como `AUTH_PENDING`.
- Un título mixto devuelve los tres estados; la línea con `[priv]` se ignora.
- `draw()` con un enlace LOSSY no muestra `SIN TUNEL` en su fila; un enlace
  realmente ausente sigue mostrándolo.
- El enlace LOSSY no cuenta como activo en el resumen.
- Las columnas de la tabla siguen alineadas.
- `tests/test_REQ-NET-50_monitor_lossy_links.sh` pasa; los tests de estado
  fallan contra `08-monitor.py` anterior al fix.

**Verification:**

- **Estática y con mocks:** `tests/test_req_net_50_monitor_lossy.py` (8 tests),
  ejecutado por `tests/test_REQ-NET-50_monitor_lossy_links.sh` y por el hook
  `pytest-monitor-coverage` de pre-commit.
- **Runtime:** pendiente.

**Riesgos:**

- Un resumen con todos los enlaces en LOSSY muestra `SIN BONDING`, coherente
  con que ubond no planifica sobre ellos.
- Otras herramientas con el mismo parseo `@`/`!` quedan fuera de este alcance
  (ver informe de la tarea).

**Related:**

- `08-monitor.py`, `build/ubond/src/ubond.c` (`update_process_title`).
- `tools/iphone-relink-watchdog.sh` — ya usa `[@!~]`.
- REQ-NET-31 — monitor dual-mode (origen de `check_daemon_links`).
