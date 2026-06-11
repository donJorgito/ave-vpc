### ave-vpc.REQ-NET-38 - Listener multipuerto en RPi + probe sistemático del firewall WiFi (mapeo qué cruza)

**Status:** Implementado en scripts (Task T1 + Vía F del plan
`docs/v2-ubond/13-plan-bypass-wifi-tren.md`), validado estático.
Validación runtime pendiente: sanity en WiFi oficina + mapeo real en
trayecto AVE.

**Description:**

El firewall de la WiFi Renfe AVE está confirmado (doc
`docs/v2-ubond/12-renfe-firewall-2026-06-09.md`) con tres restricciones:
UDP outbound bloqueado al 100%, DNAT de `tcp/80` y `tcp/443` hacia el
captive portal (cert `playrenfe`), e ICMP funcional con loss alto. Lo
que NO se ha probado nunca: TCP en puertos no estándar (8080, 2222, 993,
8443, alto random), viabilidad DNS-tunnel, y si el DNAT :443 termina TLS
de verdad o solo redirige el SYN.

Sin un mapa fiable de "qué sale y qué no", cada experimento mid-trip se
come un trayecto entero improvisando. Este REQ entrega la infraestructura
de reconocimiento para que en el tren la operación sea: "arranca probe →
lee tabla".

Dos piezas:

```text
T1  RPi: listener multipuerto TCP+UDP que contesta un eco identificable.
Vía F  Mac: probe que barre el set de puertos contra el listener y
            clasifica cada combinación puerto/proto.
```

**Mecanismo del listener (T1, `tools/rpi-multiport-listener.sh`):**

- Corre EN la RPi (Pi OS / Linux). python3 stdlib puro (preinstalado),
  sin dependencias apt. Un proceso multiplexa N×(tcp+udp) sockets vía
  `selectors` (epoll).
- A cada conexión TCP / datagrama UDP contesta:
  `AVE-VPC-LISTENER port=<p> proto=<tcp|udp>`.
- Set por defecto (excluye 22/SSH a propósito):
  `80 443 853 993 2222 8080 8443 9001 9999` en TCP y UDP. Override por
  env `PORTS_TCP` / `PORTS_UDP`.
- Idempotente (PID file en `generated/`), parable limpiamente
  (SIGINT/SIGTERM cierran todos los sockets), shippable como unit
  systemd (subcomandos `install` / `uninstall`).

**Mecanismo del probe (Vía F, `tools/probe-firewall.sh`):**

- Corre en el Mac (bash). Para cada puerto: TCP connect+eco y UDP
  send+recv, con source forzado a la iface WiFi (`IFACE_WIFI` de
  `config/env`, `nc -s <ip-wifi>`, `ping -b <iface>`). Timeouts acotados
  (~3s), secuencial — gentil, no tumba la asociación.
- Clasificación por comparación del eco recibido contra el esperado:
  - `PASS`  = respuesta == eco del listener → el transporte cruza.
  - `DNAT`  = HAY respuesta pero NO es nuestro eco (HTML captive, cert
    ajeno, banner) → proxy/DNAT interceptó. Insight clave: TCP/443 que
    devuelve algo distinto al eco está DNAT-eado al portal.
  - `SILENT` = ninguna respuesta dentro del timeout → DROP del firewall.
- Dos sondas transversales: ICMP reachability vía la iface WiFi y un
  HINT de viabilidad DNS-tunnel (placeholder — requiere infra iodine +
  delegación NS para ser concluyente, Vía D del plan).

**Why python3 stdlib en el RPi y no socat:** evita dependencia apt
(`socat` no está garantizado, python3 sí en Pi OS). Un solo proceso con
`selectors` es más barato en RAM que N×2 procesos socat para una RPi.

**Why no abortar el probe ante un SILENT:** el objetivo es mapear TODO
el set; un puerto que cae no invalida los demás. El probe siempre
completa la tabla.

**Acceptance Criteria:**

- `tools/rpi-multiport-listener.sh` existe, es ejecutable, `set -uo
  pipefail`, referencia `REQ-NET-38` en cabecera.
- El listener NUNCA bindea el puerto 22 (guard explícito que aborta si
  22 aparece en `PORTS_TCP`/`PORTS_UDP`).
- El listener responde el eco con marcador `AVE-VPC-LISTENER` y
  `port=`/`proto=`.
- Subcomandos `run|start|stop|status|install|uninstall` presentes; la
  unit systemd se emite en heredoc dentro de `install`.
- `tools/probe-firewall.sh` existe, es ejecutable, `set -uo pipefail`,
  referencia `REQ-NET-38`, lee `IFACE_WIFI` y `VPS_IP` de `config/env`
  (sin IPs hardcodeadas — Rule 4 IDLC).
- El probe clasifica en `PASS|DNAT|SILENT` y la lógica DNAT se dispara
  cuando hay respuesta distinta del eco.
- El probe fuerza el source a la iface WiFi (`nc -s` / `ping -b`).
- Test estático `tests/test_REQ-NET-38_multiport_listener.sh` pasa todos
  los checks (ambos scripts existen+ejecutables, sintaxis bash OK, guard
  22, set de puertos esperado, eco tag, clasificación DNAT, sin IP
  hardcodeada, unit systemd presente).
- `bash -n` pasa sin errores en ambos scripts.

**Verification:**

- **Estática:** `tests/test_REQ-NET-38_multiport_listener.sh` — checks
  estructurales (existencia, permisos, sintaxis, funciones/puertos
  esperados, ausencia de IP literal). Emite JUnit como el resto.
- **Runtime (pendiente):**
  1. Sanity WiFi oficina: con el listener arriba en el RPi, `probe-
     firewall.sh` debe dar casi todo `PASS` (red abierta).
  2. Trayecto AVE: ejecutar el probe esperando `DNAT` en tcp/80 y
     tcp/443 (confirmado doc 12), `SILENT` en todo UDP, y descubrir qué
     puertos TCP no estándar dan `PASS` (hipótesis Vía A).
  3. Inspección de la tabla para decidir qué vía de túnel (A/B/C/D/E)
     llevar al siguiente trayecto.

**Riesgos:**

- **`nc` BSD vs GNU:** el probe asume el `nc` de macOS (flags `-s -G -w
  -u`). En otro `nc` los flags difieren. Mitigación: documentado;
  ejecutar en el Mac objetivo.
- **HINT DNS no concluyente:** la sonda DNS-tunnel es un placeholder.
  Que el TXT resuelva NO prueba que iodine tunelaría — solo que el
  resolver responde. Conclusión real requiere delegación NS + iodined
  (Vía D, decisión de infra sobre `200bares.dedyn.io`).
- **DNAT vs PASS falso:** si el captive sirviera por casualidad un body
  que contuviera la cadena del eco, se clasificaría PASS erróneamente.
  Improbable (el tag es específico) pero anotado.
- **Puerto alto fijo (9999):** elegido fijo en vez de aleatorio para que
  listener y probe coincidan sin coordinación dinámica. Si 9999 está
  ocupado en el RPi, el bind falla (WARN) y ese puerto dará SILENT.

**Related:**

- [[REQ-NET-36]] — purga de filtros vía SIGHUP; misma serie WiFi tren.
- [[REQ-NET-37]] — pre-resolución DNS de filter hosts; mismo trayecto.
- `docs/v2-ubond/13-plan-bypass-wifi-tren.md` — plan: T1 (§3) y Vía F (§2).
- `docs/v2-ubond/12-renfe-firewall-2026-06-09.md` — evidencia firewall.
- `tools/rpi-multiport-listener.sh` — implementa T1.
- `tools/probe-firewall.sh` — implementa Vía F.
- `tests/test_REQ-NET-38_multiport_listener.sh` — validación estática.
- `config/env` — `IFACE_WIFI`, `VPS_IP` consumidas por el probe.
