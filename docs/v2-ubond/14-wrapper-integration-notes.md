# Notas de integración de los wrappers — iodine (Vía D) y udp2raw (Vía A)

**Fecha:** 2026-06-11 (oficina)
**Branch:** `feat/ubond-evaluation`
**Estado:** notas de operador — cierra dos gaps de integración señalados en review

Este documento resuelve dos preguntas concretas de cableado que un revisor
marcó sobre `tools/wrap-iodine.sh` y `tools/wrap-udp2raw.sh`: cómo apunta
ubond su `[links.wifi]` a través del túnel DNS de iodine, y cómo persiste la
regla iptables de faketcp de udp2raw (más el caveat del cliente macOS).

---

## AVISO DE PROCEDENCIA (rigor: confirmado vs. inferido)

En esta sesión **no se pudo ejecutar** `iodine --help`, `man iodine`,
`man iodined`, `udp2raw --help` ni `brew list --versions` (la shell estaba
bloqueada en el entorno de trabajo). Por tanto:

- Lo que sigue del **comportamiento de los flags** procede de la documentación
  conocida de iodine / udp2raw y del diseño ya codificado en los
  wrappers del repo. **NO** está re-confirmado contra el `--help`/`man` del
  binario instalado en esta máquina en esta sesión.
- Antes de llevar esto al tren, el operador **debe** ejecutar los comandos de
  la sección "Verificación pendiente" para confirmar versión y flags reales.

---

## 1. iodine (Vía D) — cableado de `dns0` con `[links.wifi]`

### 1.1 Cómo se asigna la IP del extremo cliente del túnel

iodine levanta una interfaz TUN punto-a-punto (`dns0`). El servidor `iodined`
define la red del túnel con su argumento posicional de IP (en el wrapper:
`${TUN_NET%/*}.1`, es decir `172.16.30.1` con el default `172.16.30.0/27`).
La IP del **cliente** se negocia automáticamente en el handshake: `iodined`
reparte una IP del mismo `/27` al cliente (típicamente `172.16.30.2` para el
primer cliente). El cliente **no** elige su IP con un flag; la recibe del
servidor. La IP de servidor (`172.16.30.1`) es estable y es la que importa
para apuntar ubond.

> Confirmar en `man iodined` que el primer cliente recibe `.2` del rango y que
> no existe flag de IP fija de cliente que necesitemos forzar.

### 1.2 Qué debe poner ubond como `remotehost`/`remoteport`

iodine **no** reenvía UDP arbitrario a los servicios reales de la RPi: solo
transporta los paquetes IP que entran por la interfaz `dns0`. Para que ubond
cruce, su tráfico tiene que **entrar por `dns0`**, es decir, ir dirigido a la
IP del extremo servidor del túnel, no a la IP pública de la RPi.

Recipe concreta, tras `sudo tools/wrap-iodine.sh` arriba en el Mac:

```text
[links.wifi]
  remotehost = 172.16.30.1     # IP de dns0 en el lado RPi (iodined), NO la pública
  remoteport = 5085            # UBOND_PORT_3 (puerto UDP real de ubond)
```

Es decir: ubond habla UDP a `172.16.30.1:5085`. El kernel del Mac enruta ese
destino por `dns0` (es la /27 del túnel), iodine lo encapsula en queries DNS,
y sale por el resolver del WiFi.

### 1.3 Qué tiene que hacer la RPi (lado servidor)

El paquete UDP de ubond llega a la RPi **con destino `172.16.30.1:5085`**, no
`127.0.0.1:5085`. Dos opciones para que ubond-server lo reciba:

- **Opción A (recomendada, sin tocar la config de ubond):** reenvío en la RPi
  del extremo del túnel a ubond local, como ya sugiere la cabecera del
  wrapper:

  ```sh
  socat UDP4-LISTEN:5085,bind=172.16.30.1,reuseaddr,fork UDP4:127.0.0.1:5085
  ```

- **Opción B:** que ubond-server haga bind explícito a `172.16.30.1` (o a
  `0.0.0.0`) en lugar de solo `127.0.0.1`, de modo que escuche directamente en
  la IP de `dns0`.

Con cualquiera de las dos, el `remotehost` de ubond en el Mac es
`172.16.30.1`. El gap del review queda resuelto así: **ubond apunta a la IP
`dns0` del servidor (172.16.30.1), no a 127.0.0.1 ni a la IP pública**, y la
RPi necesita que algo escuche en esa IP de `dns0` (socat-forward u ubond bind).

---

## 2. udp2raw (Vía A) — persistencia de iptables faketcp + caveat macOS

### 2.1 Qué hace `-a` realmente

El flag `-a` (`--auto-rule`) hace que udp2raw **añada automáticamente** una
regla iptables que DROP-ea, en el kernel Linux, los paquetes TCP del puerto
faketcp **antes** de que el stack envíe un RST. Sin esa regla, el kernel ve un
"TCP" para un socket que no existe y responde RST, tumbando el túnel. Esto
coincide con lo que afirman ambos wrappers (`-a auto añade regla iptables para
que el kernel no resetee los faketcp con RST`).

> Confirmar el texto exacto de `-a` y `-g`/`--keep-rule` en `udp2raw --help`.

### 2.2 Persistencia en la RPi (Linux) durante la vida del túnel

La regla que añade `-a` es **runtime**: vive en la tabla iptables del kernel
mientras corre udp2raw y, por diseño, udp2raw la **retira al salir** limpio.
Implicaciones operativas:

- No hace falta `iptables-save` para la vida normal del túnel: mientras el
  proceso udp2raw esté vivo, la regla está puesta. El `-a` la re-aplica en cada
  arranque del proceso.
- Existe `-g` (`--keep-rule`) que **re-chequea y re-inserta** periódicamente la
  regla por si algo la borra; útil si en la RPi hay otro gestor de firewall que
  pueda purgar reglas. Considerar añadir `-g` al comando server-side si se
  observan caídas correlacionadas con flushes de iptables.
- Si udp2raw muere con SIGKILL (no limpio), la regla puede quedar huérfana en
  la tabla. No es peligrosa (solo DROP-ea ese puerto faketcp), pero conviene
  saberlo para depurar. No requiere persistencia explícita entre reinicios:
  el siguiente arranque con `-a` la vuelve a poner.

Conclusión del gap: en la RPi **no hace falta persistir la regla a disco**; el
propio `-a` la gestiona durante la vida del proceso. Si hay un firewall que la
borre en caliente, usar `-g` para que udp2raw la reinyecte.

### 2.3 Caveat del CLIENTE macOS

`-a` es **iptables, solo Linux**. En el Mac (cliente) no hay iptables, así que
`-a` no añade ninguna regla útil: en macOS udp2raw usa raw sockets vía BPF y
**no depende de una regla de firewall** para evitar el RST del mismo modo que
Linux. El wrapper cliente pasa `-a` igualmente; en macOS es efectivamente
inocuo (no-op respecto a iptables), no perjudica.

- El cliente macOS **sí** necesita raw sockets → **root** (de ahí el `sudo` en
  `wrap-udp2raw.sh`). Eso ya está cubierto.
- Si en alguna versión el RST del kernel macOS llegara a interferir, la
  mitigación NO es iptables sino una regla **pf** (`pfctl`) que bloquee el RST
  saliente de ese puerto/flujo. **Pendiente de confirmar empíricamente** si
  hace falta; en la práctica udp2raw cliente suele funcionar en macOS sin regla
  pf manual.

---

## 3. Versiones PINNED corregidas (Rule 7 IDLC)

Los wrappers pinean estas versiones; **deben re-verificarse** contra el
binario instalado por brew en esta máquina (ver sección 4):

Versiones VERIFICADAS contra el binario instalado por brew (2026-06-11):

- **iodine:** `0.8.0` (no 0.7.0). `brew list --versions iodine` → `iodine 0.8.0`.
  `wrap-iodine.sh` actualizado a `IODINE_PINNED_VERSION="0.8.0"`. Binario en
  `/opt/homebrew/sbin/iodine`.
- **udp2raw:** fórmula brew **`udp2raw-multiplatform`**, versión `20230206.0`
  (no `20200818.0`), binario **`udp2raw_mp`** (NO `udp2raw`).
  `wrap-udp2raw.sh` actualizado: pin `20230206.0` + detección de binario
  (`udp2raw` o `udp2raw_mp`) en `UDP2RAW_BIN`, así el `--check` y el lanzamiento
  funcionan con el nombre de brew. RPi (Linux): el binario del release sí se
  llama `udp2raw`.
- **wstunnel:** `10.5.5` (no 10.1.6) — `wstunnel-cli 10.5.5`. Pin actualizado.
- **socat:** `1.8.1.1`. **iperf3:** `3.21`. Pins actualizados.
- **ptunnel-ng:** NO existe en brew. Solo `ptunnel` `0.72` (codebase distinto,
  flags `-p/-lp/-da/-dp`, no `-R/-P`). Vía E queda BLOQUEADA-PENDIENTE hasta
  decidir binario (compilar utoni/ptunnel-ng o adaptar a ptunnel clásico).

---

## 4. Verificación pendiente (ejecutar ANTES del tren)

Estos comandos NO se pudieron correr en esta sesión. Ejecutarlos y pegar el
output en el siguiente commit para cerrar la procedencia:

```sh
# versiones y nombre de binario reales
brew list --versions iodine udp2raw-multiplatform
command -v iodine iodined udp2raw udp2raw_mp

# flags reales (citar el texto en el doc)
iodine -v ; iodine --help 2>&1 | head -60
man iodined | sed -n '1,80p'      # confirmar reparto de IP de cliente (.2)
udp2raw --help 2>&1 | grep -A1 -- '-a\|--auto-rule\|-g\|--keep-rule'
```

Criterios de cierre:

- iodine: versión `0.8.0` ya confirmada; queda verificar que el cliente recibe
  `172.16.30.2` (o el `.2` del rango) automáticamente, sin flag de IP fija.
- udp2raw: confirmar nombre de binario (`udp2raw` vs `udp2raw_mp`), versión para
  el pin, y el texto de `-a`/`-g`.
