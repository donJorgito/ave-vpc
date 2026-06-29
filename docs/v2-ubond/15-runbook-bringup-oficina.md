# Runbook — bring-up del bypass WiFi del tren EN OFICINA

- **Autor:** Jorge Lazaro Molina
- **Última actualización:** 2026-06-11
- **Branch:** `feat/ubond-evaluation`
- **Aplica a:** validación end-to-end Mac (cliente) ↔ Raspberry Pi (servidor)
  de la tooling de bypass del firewall, ANTES del trayecto AVE.
- **Objetivo:** dejar TODA la fontanería montada y verificada en oficina, de
  modo que en el tren el procedimiento se reduzca a "lanzar probe, elegir el
  transporte ganador". Es el material de `13-plan-bypass-wifi-tren.md` §1-3 y §6
  llevado a pasos copia-pegables.

Este runbook NO modifica scripts: solo los ejecuta. Cada vía es independiente;
puedes montar todas en oficina y luego elegir cuáles llevar al tren.

> **Convención de acceso a la RPi:** los comandos server-side se ejecutan vía
> `ssh -p ${RPi_SSH_PORT} ${RPi_USER}@${VPS_IP}` (DDNS, alcanzable desde
> oficina). La RPi ya corre el servidor ubond en `${UBOND_PORT_3}` y tiene el
> repo clonado. Cada wrapper imprime su comando server-side EXACTO con
> `--server-cmd`; este runbook muestra cómo obtenerlo y dónde pegarlo.

## TL;DR (orden de fases)

```text
Fase 0  Prereqs        : source config/env + toolchain Mac/RPi + ssh OK
Fase A  Listener+probe : rpi-multiport-listener.sh + probe-firewall.sh (REQ-NET-38)
Fase B  Baseline socat : Vía C, confirma que ubond tolera TCP-wrap (REQ-NET-39)
Fase C  Sigilo         : Vía A udp2raw faketcp ∥ Vía B wstunnel WSS
Fase D  Medida         : bench-wrappers.sh por vía (REQ-NET-45)
Fase E  Captive        : captive-watchdog.py --probe/--once (REQ-NET-40)
Limpieza               : --stop de cada wrapper + 05b-desconectar-ubond.sh
```

---

## Fase 0 — Prereqs

### 0.1 Cargar config/env

```sh
cd /Users/lazaromj/projects/ave-vpc
source config/env
echo "VPS_IP=${VPS_IP} RPi=${RPi_USER}@${VPS_IP}:${RPi_SSH_PORT} UBOND_PORT_3=${UBOND_PORT_3}"
```

- **Esperado:** `VPS_IP=200bares.dedyn.io RPi=jorge@200bares.dedyn.io:22
  UBOND_PORT_3=5085`.

### 0.2 Toolchain en el Mac

Cada wrapper trae su propio `--check`, que verifica el binario y, si falta,
imprime el `brew install` con la versión pineada. Lánzalos todos:

```sh
tools/wrap-socat.sh    --check
tools/wrap-udp2raw.sh  --check
tools/wrap-wstunnel.sh --check
tools/wrap-iodine.sh   --check
tools/wrap-ptunnel.sh  --check
tools/bench-wrappers.sh --check
```

- **Esperado:** cada uno imprime `OK: <bin> presente (...)`. Cualquier `FALTA:`
  trae el comando de instalación; ejecútalo y re-corre el `--check`.
- **Caveat de nombre de binario:** el formula `udp2raw` de Homebrew puede
  instalar el ejecutable como `udp2raw_mp`. Si `wrap-udp2raw.sh --check` dice
  `FALTA` pero `command -v udp2raw_mp` SÍ existe, crea un symlink en el `PATH`
  (`ln -s "$(command -v udp2raw_mp)" /opt/homebrew/bin/udp2raw`) o exporta el
  binario donde el wrapper lo busque. Verifícalo antes de la Fase C.

### 0.3 RPi alcanzable

```sh
ssh -p "${RPi_SSH_PORT}" "${RPi_USER}@${VPS_IP}" 'hostname; uname -m; sudo systemctl is-active ubond'
```

- **Esperado:** hostname de la RPi, arquitectura (`aarch64`/`armv7l`) y `active`
  para el servicio ubond.

### 0.4 Toolchain en la RPi (paso MANUAL del operador)

Las vías que crucen necesitan SU binario TAMBIÉN en la RPi (Linux). Esto NO lo
hace ningún script: instálalo a mano según la vía que vayas a montar.

```sh
ssh -p "${RPi_SSH_PORT}" "${RPi_USER}@${VPS_IP}" \
  'sudo apt-get update && sudo apt-get install -y socat iodine iperf3'
```

- `socat`, `iodine`, `iperf3`: están en apt.
- `udp2raw` y `wstunnel`: NO están en apt estándar — descarga el binario release
  del repo upstream (arquitectura según `uname -m` del paso 0.3). El
  `--server-cmd` de cada wrapper recuerda el origen exacto.
- `ptunnel-ng`: apt o release upstream según disponibilidad.

---

## Fase A — Listener multipuerto + probe (REQ-NET-38)

Reconocimiento: levanta en la RPi un servicio que escucha TCP+UDP en un set de
puertos y devuelve un eco identificable; desde el Mac, `probe-firewall.sh` mapea
qué cruza. En oficina es un sanity check (se espera casi todo PASS); la señal
REAL llega en el tren.

### A.1 Arrancar el listener en la RPi

```sh
ssh -p "${RPi_SSH_PORT}" "${RPi_USER}@${VPS_IP}" \
  'cd ~/ave-vpc && sudo tools/rpi-multiport-listener.sh install'
```

- `install` instala y arranca la unit systemd `ave-vpc-listener.service`
  (persistente, `Restart=on-failure`). Para una prueba efímera sin systemd usa
  `tools/rpi-multiport-listener.sh start` en su lugar.
- **Verificar:**

```sh
ssh -p "${RPi_SSH_PORT}" "${RPi_USER}@${VPS_IP}" \
  'cd ~/ave-vpc && tools/rpi-multiport-listener.sh status'
```

- **Esperado:** `listener ACTIVO`, y bajo `--- en escucha (ss) ---` los puertos
  `80 443 853 993 2222 8080 8443 9001 9999` en TCP (`LISTEN`) y UDP (`UNCONN`).
  El puerto 22 (SSH) está excluido a propósito.

### A.2 Lanzar el probe desde el Mac (en WiFi de oficina)

`probe-firewall.sh` fuerza el egress por la WiFi (`IFACE_WIFI`). Con los links
4G activos NECESITA root para instalar una ruta scoped; sin root avisa de que la
medida puede reflejar otra iface. Lánzalo con `sudo` y la WiFi asociada:

```sh
sudo -E env "PATH=${PATH}" tools/probe-firewall.sh
```

- **Esperado en oficina:** tabla `PUERTO/PROTO -> RESULTADO` con casi todo
  `PASS` (la WiFi de oficina no es restrictiva), `ICMP REACHABLE`, y un
  `DNS-tunnel hint UNKNOWN` (placeholder, requiere infra iodine).
- **Leyenda de resultados:**
  - `PASS` = respuesta == eco `AVE-VPC-LISTENER port=<p> proto=<...>` → el
    transporte cruza limpio.
  - `DNAT` = hubo bytes de vuelta pero NO son nuestro eco (HTML del captive,
    cert ajeno, banner) → algo interceptó (proxy/DNAT). En el tren ESTA es la
    clave: TCP/443 Renfe devuelve el cert `playrenfe`.
  - `SILENT` = sin respuesta dentro del timeout → DROP del firewall.

> **Nota de método:** en oficina esto solo valida que listener + probe + ruta
> scoped funcionan. El mapa que importa lo da el MISMO comando en la WiFi del
> tren.

---

## Fase B — Túnel baseline (Vía C, socat) — REQ-NET-39

Baseline UDP-over-TCP. No es sigiloso, pero es trivial de diagnosticar y
confirma que ubond TOLERA ir sobre un wrapper TCP antes de pelear con sigilo.

### B.1 Arrancar el wrapper-server socat en la RPi

Obtén el comando server-side EXACTO y pégalo en la RPi:

```sh
tools/wrap-socat.sh --server-cmd
```

- Imprime un `socat -d -d TCP4-LISTEN:${UBOND_PORT_3},reuseaddr,fork
  UDP4:127.0.0.1:${UBOND_PORT_3}`. Ejecútalo en la RPi:

```sh
ssh -p "${RPi_SSH_PORT}" "${RPi_USER}@${VPS_IP}" \
  'socat -d -d TCP4-LISTEN:5085,reuseaddr,fork UDP4:127.0.0.1:5085'
```

- Déjalo corriendo (foreground) en esa sesión SSH o lánzalo con `nohup ... &`.

### B.2 Arrancar el wrapper-cliente socat en el Mac

```sh
tools/wrap-socat.sh
```

- **Esperado:** log `arrancando socat: UDP4-LISTEN:5085 <-> TCP:${VPS_IP}:5085`
  y un PID file en `generated/wrap_socat.pid`. Déjalo en su terminal.

### B.3 Levantar ubond apuntando el WiFi al wrapper

En otra terminal, con el wrapper ya arriba:

```sh
sudo WIFI_VIA_WRAPPER=1 WRAP_LOCAL_PORT="${UBOND_PORT_3}" ./04b-conectar-ubond.sh
```

- `WIFI_VIA_WRAPPER=1` hace que `[links.wifi]` apunte a
  `127.0.0.1:${WRAP_LOCAL_PORT}` (boca UDP local del wrapper) en vez de a
  `${VPS_IP}`. El resto del bonding (iPhone/Pixel por UDP directo) no cambia.
- **Esperado:** el script imprime `WiFi añadido VIA WRAPPER (REQ-NET-41):
  127.0.0.1:${UBOND_PORT_3}` y levanta el utun.

### B.4 Verificar el utun y el tráfico de IDA

```sh
ifconfig | grep -B1 "${UBOND_TUN_MAC_IP}"
ping -c 3 "${UBOND_TUN_VPS_IP}"
```

- **Esperado:** un `utunN` con `inet ${UBOND_TUN_MAC_IP}` y 3 respuestas de
  `${UBOND_TUN_VPS_IP}`.

### B.5 CRUCIAL — verificar tráfico de VUELTA (no asumir simetría)

El reviewer marcó que con `fork`, socat abre un puerto UDP origen efímero por
fork hacia ubond; si la conexión TCP se recicla, las replies de ubond pueden
quedar huérfanas (pérdida en UDP-stateful). Hay que comprobar explícitamente que
vuelve tráfico, no solo que sale:

```sh
ping -c 20 "${UBOND_TUN_VPS_IP}"          # loss debe ser ~0%, no solo "1 reply"
ssh -p "${RPi_SSH_PORT}" "${RPi_USER}@${VPS_IP}" "ping -c 5 ${UBOND_TUN_MAC_IP}"
```

- **Esperado:** loss ~0% en AMBOS sentidos. Si el ping de la RPi hacia
  `${UBOND_TUN_MAC_IP}` falla o el loss en B.5 sube respecto a B.4, la simetría
  está rota → confirma que C es solo baseline diagnóstico y NO un transporte de
  trayecto. Las vías sigilosas (Fase C) son los candidatos reales.

---

## Fase C — Túneles sigilosos (Vía A udp2raw faketcp, Vía B wstunnel)

Mismo patrón que la Fase B (server-cmd en RPi → cliente en Mac → ubond con
`WIFI_VIA_WRAPPER=1`), parando antes el wrapper de la fase previa
(`tools/wrap-socat.sh --stop`) para no chocar en el puerto local.

### C.1 Vía A — udp2raw faketcp (REQ-NET-39)

Requiere ROOT en AMBOS extremos (raw sockets) y la MISMA PSK `-k` en los dos
lados. El `--server-cmd` revela deliberadamente la clave generada:

```sh
tools/wrap-udp2raw.sh --server-cmd
```

- Copia el bloque `sudo udp2raw -s -l 0.0.0.0:8443 -r 127.0.0.1:${UBOND_PORT_3}
  --raw-mode faketcp -k "<PSK>" -a` y pégalo en la RPi como root:

```sh
ssh -p "${RPi_SSH_PORT}" "${RPi_USER}@${VPS_IP}"   # luego pega el sudo udp2raw -s ...
```

- Arranca el cliente en el Mac (root) y levanta ubond:

```sh
sudo tools/wrap-udp2raw.sh
sudo WIFI_VIA_WRAPPER=1 WRAP_LOCAL_PORT="${UBOND_PORT_3}" ./04b-conectar-ubond.sh
```

- **Verificar:** misma comprobación de IDA y VUELTA que B.4/B.5
  (`ping ${UBOND_TUN_VPS_IP}` y ping inverso desde la RPi).
- **Nota PSK:** si re-generas la clave en el Mac (borras
  `generated/wrap_udp2raw.key`), DEBES re-ejecutar `--server-cmd` y actualizar
  el comando en la RPi; claves distintas = no cruza.

### C.2 Vía B — wstunnel WSS (REQ-NET-39)

```sh
tools/wrap-wstunnel.sh --server-cmd
```

- Pega el `sudo wstunnel server --restrict-to 127.0.0.1:${UBOND_PORT_3}
  "wss://0.0.0.0:443"` en la RPi (`<443` requiere root o
  `CAP_NET_BIND_SERVICE`; necesita cert TLS — self-signed sirve para oficina).
- Arranca el cliente y levanta ubond:

```sh
tools/wrap-wstunnel.sh
sudo WIFI_VIA_WRAPPER=1 WRAP_LOCAL_PORT="${UBOND_PORT_3}" ./04b-conectar-ubond.sh
```

- **Caveat TLS (importante):** en oficina, con cert self-signed, relaja la
  verificación SOLO como opt-in explícito de lab:

```sh
WS_INSECURE_SKIP_VERIFY=1 tools/wrap-wstunnel.sh
```

- **EN EL TREN NO uses `WS_INSECURE_SKIP_VERIFY`.** Renfe MitM-ea todo TCP/443
  con el cert `playrenfe`; con verify desactivado el cliente completaría el
  handshake CONTRA el MitM y reportaría un FALSO PASS. Para el trayecto hay que
  PINEAR el cert del RPi (rechazar el de Renfe). El flag exacto de pinning de
  `wstunnel 10.1.6` está marcado como TODO en el wrapper: **verifícalo
  on-device antes del trayecto.**

---

## Fase D — Medir y ranquear (REQ-NET-45)

Con cada transporte arriba (y ubond levantado por encima), corre el banco UNA
VEZ POR VÍA. Cada ejecución añade una fila a `generated/bench-results.tsv`.

### D.1 Servidor iperf3 en la RPi

```sh
tools/bench-wrappers.sh --server-cmd
```

- Pega el `iperf3 -s -B ${UBOND_TUN_VPS_IP} -1` en la RPi (atiende un cliente y
  sale; relánzalo por cada medida, o quita `-1` para dejarlo persistente).

```sh
ssh -p "${RPi_SSH_PORT}" "${RPi_USER}@${VPS_IP}" "iperf3 -s -B ${UBOND_TUN_VPS_IP}"
```

### D.2 Medir cada transporte

Ejecuta una etiqueta por vía, con esa vía como `[links.wifi]` activo:

```sh
tools/bench-wrappers.sh direct      # ubond directo (sin wrapper), referencia
tools/bench-wrappers.sh socat
tools/bench-wrappers.sh udp2raw
tools/bench-wrappers.sh wstunnel
```

- **Esperado:** cada corrida imprime latencia (loss/RTT min/avg/max/stddev) y
  throughput, y vuelca la tabla acumulada.

### D.3 Leer el ranking

```sh
tools/bench-wrappers.sh --show
```

- **Cómo ranquear:** columnas `loss_pct`, `rtt_avg_ms`, `rtt_stddev_ms`
  (jitter) y `throughput_mbps`. El mejor candidato de trayecto es el que más se
  acerca a la fila `direct` en throughput y latencia con `loss_pct` bajo. `socat`
  sirve de cordura (debe pasar); `udp2raw`/`wstunnel` son los que decidirán el
  trayecto.

---

## Fase E — Captive watchdog dry-run (REQ-NET-40)

Valida la lógica tri-estado del watchdog contra un canary benigno. El form REAL
de PlayRenfe SOLO se rellena en el tren (TODO marcado en el script).

### E.1 Probe de estado (un disparo)

```sh
tools/captive-watchdog.py --probe
```

- **Esperado en oficina (internet real):** imprime `online`. Estados posibles:
  `online` (canary devuelve token/204), `offline` (responde pero es portal),
  `DOWN` (fallo de transporte = WiFi caído, NO re-login).

### E.2 Un ciclo completo

```sh
tools/captive-watchdog.py --once
```

- **Esperado:** clasifica y, si detecta `offline`, intentaría el re-login. Con
  `PORTAL_URL` vacío (default) registra el TODO REQ-NET-40 y no postea — correcto
  hasta capturar el form real a bordo. Para ejercitar el motor de re-login en
  oficina, apúntalo a un form sintético:

```sh
tools/captive-watchdog.py --once --portal-url http://localhost:8080/form
```

- **En el tren:** se rellena `PORTAL_URL`/`PORTAL_FORM_*` con la action y los
  inputs reales del portal PlayRenfe capturados a bordo.

---

## Limpieza

Parar en orden inverso al arranque.

```sh
# Wrapper(s) activo(s) en el Mac:
tools/wrap-socat.sh    --stop
tools/wrap-udp2raw.sh  --stop
tools/wrap-wstunnel.sh --stop
tools/wrap-iodine.sh   --stop
tools/wrap-ptunnel.sh  --stop

# Watchdog captive (si quedó como daemon):
tools/captive-watchdog.py --stop

# ubond + watchdog:
sudo ./05b-desconectar-ubond.sh

# Listener en la RPi:
ssh -p "${RPi_SSH_PORT}" "${RPi_USER}@${VPS_IP}" \
  'cd ~/ave-vpc && sudo tools/rpi-multiport-listener.sh uninstall'   # o: stop
```

- Mata también los comandos server-side que dejaste en sesiones SSH (socat /
  udp2raw / wstunnel / iperf3) con `Ctrl-C` o `pkill` en la RPi.

---

## Caveats conocidos — verificar ON-DEVICE

Vías D y E (iodine / ptunnel-ng) son LINKS DE VIDA (señalización / keepalive),
no de ancho de banda. Su bring-up sigue el mismo patrón `--server-cmd`, pero
arrastran prerrequisitos que el operador debe resolver a mano:

- **mac-rotate.sh (REQ-NET-44):** en macOS 14+ Apple eliminó `airport -z`
  (ausente en macOS 26.5). El wrapper cae a `networksetup -setairportpower
  off/on` para desasociar y aplicar el nuevo `ether`. **Verifica que la rotación
  realmente prende:** `sudo tools/mac-rotate.sh --rotate` seguido de
  `--show`; si la "MAC actual" tras rotar NO coincide con la generada, el cambio
  no se aplicó (driver/timing) y hay que ajustar la mecánica. `--restore`
  recupera la MAC hardware original.
- **wrap-ptunnel.sh (Vía E):** las letras de flag de ptunnel-ng 1.42 pueden
  diferir entre builds (`-R`/`-P` mayúscula/minúscula). El wrapper lo marca como
  TODO: confirma contra `ptunnel-ng --help` de la versión pineada que el reenvío
  a `127.0.0.1:${UBOND_PORT_3}` es correcto ANTES de fiarte de él.
- **wrap-iodine.sh (Vía D):** requiere DELEGACIÓN NS de un subdominio a la RPi
  ANTES de que funcione. El operador debe, en el panel deSEC de
  `${VPS_IP}`: crear `t IN NS ns.t...` + `ns.t IN A <IP pública>`, abrir
  `53/udp` del router hacia la RPi, y comprobar `dig NS t.200bares.dedyn.io`
  antes de probar el túnel. Sin esa delegación, iodine NO levanta.

---

## Asunciones que el operador DEBE confirmar

- **Acceso SSH a la RPi:** este runbook usa `${RPi_USER}@${VPS_IP}:${RPi_SSH_PORT}`
  (`jorge@200bares.dedyn.io:22`) por DDNS, según la instrucción de la tarea. Otros
  docs del repo (p.ej. `07-trayecto-runbook.md`) hacen SSH a la IP LAN
  `192.168.1.101` cuando estás en casa. Usa la ruta que aplique a tu ubicación;
  ambas llegan a la misma RPi.
- **Ruta del repo en la RPi:** se asume `~/ave-vpc`. Ajusta el `cd ~/ave-vpc`
  de los comandos SSH si tu clon está en otra ruta.
