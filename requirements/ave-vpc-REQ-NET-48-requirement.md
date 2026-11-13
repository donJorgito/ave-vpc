### ave-vpc.REQ-NET-48 - Corregir tres defectos del arnés de smoke-tests (`tools/`)

**Status:** Implementado (`tools/lib/ubond-runner.sh`, `tools/lib/report.sh`).
Verificado de forma estática y con stubs, sin red ni sudo. Validación runtime
pendiente de una ventana con la red libre.

**Description:**

Tres defectos verificados en el arnés `tools/smoke-*.sh` que lo dejaban inservible
o engañoso:

1. **`ubond_runner_wait_auth` nunca detectaba la autenticación.** Buscaba
   `@links.X` en el log del cliente y hacía `pgrep -f 'ubond: ubond @links\.'`.
   El cliente se lanza con `--name ubond0`, así que su título real es, por
   ejemplo, `ubond: ubond0 !links.wifi @links.pixel @links.iphone`; el patrón
   antiguo no casa (0 coincidencias con un título real; 1 con
   `ubond: ubond0 .*@links\.`). El log del cliente tiene una sola línea y nunca
   contiene `@links`. Resultado: la puerta siempre expiraba y todos los smoke
   tests se saltaban.
2. **`ubond_runner_stop` no mataba nada.** Hacía `pkill -f "${UBOND_BIN}"`, pero
   el proceso reescribe su título a `ubond: ...`, de modo que la ruta del
   binario ya no aparece en la línea de comandos. Aun así registraba
   "ubond detenido". Medido: se acumularon tres clientes.
3. **Diagnóstico automático con falso positivo.** `report_diagnose` contaba
   como 0 paquetes una captura RPi ausente (scp fallido) e imprimía "Mac envía
   pero RPi no recibe — filtrado en red".

**Implementación del fix:**

1. `UBOND_CLIENT_NAME` (por defecto `ubond0`) es la única fuente del nombre: se
   usa en `--name` al lanzar y en el patrón de `wait_auth`
   (`ubond_runner_auth_title_re` → `ubond: <nombre> .*@links\.`). Se elimina la
   búsqueda en el log, que nunca podía casar.
2. Un único patrón anclado `^ubond: <nombre>` (seguido de espacio) (`UBOND_TITLE_RE`, derivado de
   `UBOND_CLIENT_NAME`; mismo criterio que
   `tools/iphone-relink-watchdog.sh`) y dos helpers compartidos
   (`ubond_runner_clients_alive`, `ubond_runner_kill_clients`) sirven a
   `ubond_runner_stop` y a `ubond_runner_cleanup_stale`. El ancla evita casar
   procesos ajenos que lleven `ubond: ...` en sus argumentos (reproducido con
   `pgrep`: `tail -f /dev/null "ubond: ubond0 @links.q"` casa `ubond:` sin
   ancla y no casa con `^ubond: ubond0` más espacio). `stop` verifica con `pgrep` que no
   queda ningún cliente: si queda, registra un error y devuelve 1 en lugar de
   "detenido". `cleanup_stale` (que corre al inicio de cada smoke) ya no deja
   clientes de la ejecución anterior.
3. `report_diagnose` distingue captura no disponible (fichero ausente o de 0
   bytes, sin cabecera pcap) de 0 paquetes con `_report_have_capture`, y en ese
   caso emite "no verificable" en lugar de culpar a la red o al servidor.

**Acceptance Criteria:**

- Con un título real `ubond: ubond0 !links.wifi @links.pixel @links.iphone`,
  el patrón de `wait_auth` casa; el patrón antiguo no.
- El patrón sigue el valor de `UBOND_CLIENT_NAME` (no está fijado a `ubond0`).
- `ubond_runner_stop` mata por el título anclado `^ubond: <nombre>` (seguido de espacio) y devuelve
  0 con "detenido" solo si no queda ningún cliente; si queda uno devuelve 1 y
  registra error. Un proceso ajeno con `ubond: ubond0 ...` en sus argumentos no
  casa ni provoca un falso rc=1.
- `ubond_runner_cleanup_stale` mata por el mismo título (no por la ruta del
  binario) y no invoca `pkill` si no hay clientes.
- El patrón anclado casa `ubond: ubond0 [priv]` y
  `ubond: ubond0 !links.wifi @links.pixel @links.iphone`.
- Sin pcap RPi disponible, el diagnóstico dice "no verificable" y no
  "filtrado en red"; con pcap RPi presente y 0 paquetes, mantiene "filtrado".
- `tests/test_REQ-NET-48_smoke_harness_fixes.sh` pasa.

**Verification:**

- **Estática y por stubs:** `tests/test_REQ-NET-48_smoke_harness_fixes.sh`
  (stubs de `pgrep`/`pkill`/`ifconfig`/`tcpdump`; sin red, sin sudo).
- **Runtime:** pendiente (smoke test real con el túnel levantado).

**Riesgos:**

- El kill casa con cualquier cliente llamado `UBOND_CLIENT_NAME` del equipo
  (por defecto `ubond0`, como `04b`), incluido uno lanzado fuera del arnés.
- `04b-conectar-ubond.sh`, `05b-desconectar-ubond.sh`, `SOS.sh` y `conf-gen.sh`
  conservan el literal `ubond0` (preexistente, fuera de este alcance).

**Related:**

- `tools/lib/ubond-runner.sh`, `tools/lib/report.sh`, `tools/lib/tcpdump.sh`.
- `tools/iphone-relink-watchdog.sh` — patrón anclado de referencia.
- `05b-desconectar-ubond.sh` — origen del criterio de kill por título.
