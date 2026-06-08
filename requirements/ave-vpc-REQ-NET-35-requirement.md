### ave-vpc.REQ-NET-35 - Rebind socket UDP en silencio inbound (fix C definitivo NAT carrier expiry)

**Status:** Disenado, pendiente de implementar/compilar/validar.

**Description:**

Reemplazo definitivo del band-aid REQ-NET-34 (`tools/iphone-relink-watchdog.sh`).
Aquel watchdog en bash detecta silencio inbound parseando proctitle de ubond
y fuerza re-DHCP de la iface tethering (`ifconfig en8 down/up`) para
regenerar el pinhole NAT del carrier 4G. Funciona en produccion AVE
2026-06-05 (tres recuperaciones automaticas exitosas), pero el mecanismo
es invasivo: tira la iface entera, lo cual impacta a otros consumidores
(otros procesos en el host pueden estar usando esa iface), y depende de
permisos root para `ifconfig`. Tampoco se aplica al peer Pixel/Yoigo
ni al WiFi del tren cuando esos enlaces sufran el mismo sintoma.

REQ-NET-35 mueve la solucion al binario ubond: el cliente lleva un
contador `reauth_attempts_no_inbound` que se incrementa cada vez que
`ubond_rtun_check_timeout` marca el tunel como `status_down` por silencio
(no llego DATA ni KEEPALIVE en la ventana de timeout configurada). Cuando
ese contador alcanza `UBOND_REBIND_THRESHOLD` (3 iteraciones, ~750ms tras
el primer status_down con `UBOND_IO_TIMEOUT_DEFAULT=0.25s`), el cliente
cierra el socket UDP actual, libera `addrinfo`, y deja que el siguiente
`ubond_rtun_tick_connect` ejecute `ubond_rtun_start` de nuevo. El kernel
asigna un sport efimero distinto, el carrier abre un pinhole nuevo, y el
challenge sale por ese sport fresco. Recuperacion sin tocar la iface ni
otros procesos.

**Why REQ-NET-34 es band-aid:**

- Externo al binario (proceso bash separado, mas piezas en juego).
- Requiere root permanente.
- Tira `ifconfig` de toda la iface, afecta a otros consumidores.
- Hardcoded a la iface `en8` (no portable a otros enlaces ubond).
- Logica de detection paralela y duplicada (proctitle parsing es fragil).

**Mecanismo del fix (REQ-NET-35):**

- Nuevo campo `int reauth_attempts_no_inbound` en `ubond_tunnel_t`
  (`src/ubond.h`).
- Reset a 0 en:
  - `ubond_rtun_new` (creacion de tunel).
  - `ubond_rtun_status_up` (link recuperado).
  - `ubond_rtun_read` cuando recibe `UBOND_PKT_DATA` o
    `UBOND_PKT_KEEPALIVE` autenticado (cualquier inbound prueba que el
    pinhole NAT sigue vivo).
- Incremento en `ubond_rtun_check_timeout`, justo antes de
  `ubond_rtun_status_down`, gated por `!t->server_mode` (el server no
  tiene control sobre el sport del peer).
- Gating del rebind en `ubond_rtun_check_timeout`, antes de
  `ubond_rtun_tick_connect`, cuando `reauth_attempts_no_inbound >=
  UBOND_REBIND_THRESHOLD`. Tras rebind, contador reset a 0.
- Nueva funcion estatica `ubond_rtun_rebind_socket_internal(t)`:
  `ev_io_stop(io_read)` + `ev_io_stop(io_write)` + `close(fd)` +
  `freeaddrinfo(addrinfo)`. `tick_connect` reabre via `ubond_rtun_start`.
- Wrapper publico `void ubond_rtun_rebind_socket(t)` con forward decl en
  `ubond.h` para futuro uso externo.
- `#define UBOND_REBIND_THRESHOLD 3` inline en `ubond.c` (no hay
  cabecera global apropiada en ubond; `defines.h` solo contiene
  attribute macros).

**Wire compatibility:**

- Cero cambio en el protocolo wire: el campo es local al cliente, ningun
  byte adicional en `ubond_proto_t`.
- Cliente parchado contra server vanilla: funciona (cliente rebinda
  socket, server simplemente ve un nuevo source addr y lo acepta como
  haria con cualquier reconexion).
- Cliente vanilla contra server parchado: funciona (server gated por
  `!server_mode` no incrementa, no rebinda; comportamiento identico al
  pre-patch).

**Acceptance Criteria:**

- `patches/ubond_rebind_on_silence.patch` existe, aplica limpio sobre
  el arbol con los 6 patches REQ-NET-12/19/25/27/29/30 ya aplicados.
- `git apply --check` y `patch -p1 --dry-run` ambos pasan sin errores
  ni rejections.
- Compila en macOS (Mac client) sin warnings nuevos.
- Compila en Linux RPi (server) sin warnings nuevos.
- `03b-setup-mac-ubond.sh` aplica el patch tras los 6 anteriores, en
  el orden final del chain.
- `07b-setup-rpi-ubond.sh` transporta el patch base64-encoded y lo
  aplica en el RPi tras los 5 anteriores (solo los que aplican en
  Linux: REQ-NET-12/25/27/29/30).
- Test estatico `tests/test_REQ-NET-35_rebind_on_silence.sh` pasa en CI
  (existencia patch, contenido, wire en scripts setup).
- Cuando el patch entre en build verificado en produccion, mover
  `tools/iphone-relink-watchdog.sh` a `tools/legacy/` y eliminar su
  invocacion desde `04b-conectar-ubond.sh`. REQ-NET-34 queda
  superseded.

**Validacion pendiente (runtime):**

1. Rebuild en RPi y Mac con el patch aplicado.
2. Test sintetico simulando NAT expiry: con `iptables -A OUTPUT -p udp
   --dport 5083 -j DROP` durante 30s en el Mac, verificar que el cliente
   ubond:
   - Marca el tunel `iphone` como down tras timeout (~6-8s).
   - Tras `UBOND_REBIND_THRESHOLD` ticks (~750ms) loggea
     `"<name> silence threshold reached (3), rebinding socket"`.
   - Tras quitar la regla iptables, el sport en el siguiente
     `ubond_rtun_start` es distinto al previo (verificar con `lsof -i
     UDP -p $(pgrep ubond)`).
   - Tunel vuelve a AUTHOK sin intervencion.
3. Test produccion AVE Madrid -> Orihuela: verificar al menos 3
   recuperaciones automaticas en un trayecto, comparables a las tres
   que documento REQ-NET-34.
4. Verificar que `tools/iphone-relink-watchdog.sh` ya NO se dispara en
   esa misma sesion (porque ubond recupera antes de que el watchdog
   acumule 12 ticks). Si watchdog sigue actuando, REQ-NET-35 no esta
   recuperando lo suficientemente rapido y hay que revisar threshold.

**Riesgos:**

- **Rebase contra los 6 patches existentes:** el patch fue generado via
  Python `difflib.unified_diff` contra `build/ubond/` con los 6 patches
  REQ-NET-12/19/25/27/29/30 ya aplicados. Si en algun futuro se reordena
  el chain o se inserta un patch intermedio que toca las mismas zonas
  (struct, `ubond_rtun_new`, `status_up`, `check_timeout`), habra que
  regenerar contra el arbol nuevo.
- **Server gating:** la condicion `!t->server_mode` antes de incrementar
  Y antes de rebindar es critica. Si por error se quitase, el server
  intentaria cerrar el socket UDP de escucha ante cualquier silencio,
  rompiendo el listener para todos los clientes.
- **Race con libev:** tras `ev_io_stop`, el handler del proximo tick
  vera `t->fd == -1` y `t->addrinfo == NULL`, lo cual `ubond_rtun_start`
  ya maneja. Pero si algun callsite externo (no presente hoy) llamase
  `ubond_rtun_send` entre el rebind y el siguiente `tick_connect`,
  habria un write a fd=-1 que retorna -1 EBADF: cubierto por el
  manejo de error existente en `ubond_rtun_send`. Aun asi, conviene
  validar bajo carga sostenida que no aparezcan logs de "send error
  EBADF" en los milisegundos posteriores al rebind.
- **Threshold demasiado bajo:** con `UBOND_REBIND_THRESHOLD=3` y
  `UBOND_IO_TIMEOUT_DEFAULT=0.25s`, son ~750ms tras el primer
  status_down. En handovers entre celdas que duren mas de 1s, podria
  rebindar prematuramente. Mitigacion: el primer status_down ya implica
  que paso el `timeout` configurado del tunel (4-8s tipicos), asi que
  el rebind real ocurre 4-8s + 0.75s tras el ultimo paquete inbound.
  Si en validacion AVE se observa rebind excesivo, subir a 5 o 8.
- **Threshold demasiado alto:** si se sube a >10, el binario tarda mas
  en recuperar que el watchdog REQ-NET-34 (que actua a 60s). Habria
  que mantener el watchdog como red de seguridad.

**Related:**

- [[REQ-NET-34]] - **superseded por este**: cuando REQ-NET-35 entre en
  build verificado, REQ-NET-34 se mueve a legacy.
- [[REQ-NET-12]] - patch replicacion 5-tupla (parte del chain).
- [[REQ-NET-25]] - per-link loss/latency tolerences (parte del chain).
- [[REQ-NET-27]] - data_seq compartido + dedup return contract (parte
  del chain).
- [[REQ-NET-29]] - parser filters seccion exclusion (parte del chain).
- [[REQ-NET-30]] - dedup gate por wire signal data_seq (ultimo del
  chain antes de este).
- `patches/ubond_rebind_on_silence.patch` - el patch C en si.
- `tests/test_REQ-NET-35_rebind_on_silence.sh` - validacion estatica.
- `03b-setup-mac-ubond.sh`, `07b-setup-rpi-ubond.sh` - wiring del patch
  en los chains de setup.
