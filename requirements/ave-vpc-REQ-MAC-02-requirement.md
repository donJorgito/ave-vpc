### ave-vpc.REQ-MAC-02 - Lectura correcta de counters de utun via netstat -ibn

**Description:**

`netstat -ibn` en macOS reporta los counters de bytes (Ibytes/Obytes)
en posiciones distintas según la interfaz: las físicas tienen 11
columnas (con MAC en la cuarta) y las virtuales sin MAC (utun, lo0)
tienen 10. Un parser de offsets fijos solo funciona para uno de los
dos casos. `08-monitor.py` debe detectar la presencia de la MAC y
ajustar el offset para leer correctamente los bytes del utun de
mlvpn (tráfico útil del túnel sin overhead UDP).

**Parent Requirement:** ave-vpc.REQ-SW-01

**Acceptance Criteria:**

- `get_interface_stats()` en `08-monitor.py` detecta si `parts[3]`
  tiene formato MAC (5 caracteres `:`) y aplica offset 4 ó 3 en
  consecuencia.
- Las interfaces físicas (`en0`, `en8`, `en12`) y las virtuales
  (`utun*`, `lo0`) reportan Ibytes/Obytes correctos.
- El asterisco `*` que netstat añade en estados transitorios se
  elimina del nombre para que el lookup contra `ifconfig` coincida.
