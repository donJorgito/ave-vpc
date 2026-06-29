### ave-vpc.REQ-NET-45 - Banco de medida throughput/latencia/jitter/loss de ubond a través de cada wrapper

**Status:** Implementado en script (`tools/bench-wrappers.sh`),
validado estático. Validación runtime pendiente próximo trayecto AVE.

**Description:**

T4 del plan de bypass (doc 13 sección 3): las vías A-C (socat /
udp2raw / wstunnel) y ubond-directo no se pueden ranquear solo por
"pasa / no pasa" — cada wrapper añade overhead distinto
(reensamblado UDP→TCP→UDP, faketcp, WSS/TLS). Hace falta una métrica
COMPARABLE de coste/rendimiento para decidir qué vía llevar al tren.

`tools/bench-wrappers.sh` mide, **a través del utun de ubond**
(`UBOND_TUN_MAC_IP` → `UBOND_TUN_VPS_IP`, nunca por la red física):

- **latencia:** RTT min/avg/max/stddev (`ping -b <utun>`).
- **jitter:** stddev del RTT (derivado del mismo ping).
- **loss:** % de pérdida de paquetes.
- **throughput:** `iperf3` contra la RPi si está disponible; si no,
  fallback a transferencia bruta cronometrada (`dd | nc`).

El operador lo ejecuta **una vez por vía**, pasando una etiqueta
(`direct` / `socat` / `udp2raw` / `wstunnel`). Cada ejecución AÑADE
una fila comparable a `generated/bench-results.tsv`:

```text
timestamp  label  loss_pct  rtt_min  rtt_avg  rtt_max  rtt_stddev  throughput_mbps  tp_method
```

`--show` vuelca la tabla alineada para comparar vías de un vistazo.

**No se cuelga (requisito duro):** toda medida va acotada por
`run_bounded <TIMEOUT_S>` (usa `timeout`/`gtimeout` si existen;
fallback a guardián `&` + `kill -TERM`). Si el túnel está caído o
iperf3/nc no responden, la medida devuelve `NA` y la fila se escribe
igualmente — el banco nunca bloquea el trayecto.

**Localización del utun:** igual que `ubond-watchdog.sh`, busca
`utun0..15` cuya `inet` sea `UBOND_TUN_MAC_IP` (la subnet
`10.10.20.0/24` puede colisionar con redes corporativas; medir por la
utun correcta es obligatorio). Sin utun → túnel caído → aborta la
medida con error claro.

**Comando RPi-side (NO lo lanza el script; solo lo imprime, igual que
`wrap-socat.sh --server-cmd`):**

```text
iperf3 -s -B <UBOND_TUN_VPS_IP> -1
```

`-B` liga el servidor a la IP del túnel (no mide por la red física);
`-1` atiende un cliente y sale (relanzar por medida; quitarlo para
sesiones de varias vías). Versión PINNED: `iperf3 3.16` (Rule 7).

**Acceptance Criteria:**

- `tools/bench-wrappers.sh` existe, es ejecutable, usa
  `set -uo pipefail` y guard bash >= 4 (house style).
- Acepta una etiqueta posicional y subcomandos `--check`, `--show`,
  `--server-cmd`.
- Mide latencia/jitter/loss vía `ping -b <utun>` y throughput vía
  `iperf3` con fallback a transferencia cronometrada.
- Toda medida acotada por timeout (`run_bounded`) — no se cuelga.
- Localiza el utun de ubond por `UBOND_TUN_MAC_IP`; aborta si no hay.
- Añade una fila TSV comparable a `generated/bench-results.tsv` con
  cabecera idempotente.
- Imprime el comando RPi-side `iperf3 -s -B <UBOND_TUN_VPS_IP>` y NO
  hace `ssh`.
- Lee `UBOND_TUN_VPS_IP` / `UBOND_TUN_MAC_IP` de `config/env` (sin
  hardcoding — Rule 4); declara `IPERF3_PINNED_VERSION` (Rule 7).
- Usa `logger -t bench-wrappers`.
- `bash -n` y `shellcheck --severity=warning` limpios.
- Test estático `tests/test_REQ-NET-45_bench.sh` pasa todos los checks.

**Verification:**

- **Estática:** `tests/test_REQ-NET-45_bench.sh` (existe, ejecutable,
  subcomandos, timeouts, lectura config/env, sin IP hardcodeada,
  versión PINNED, comando RPi, no ssh, `bash -n`).
- **Runtime (pendiente):** próximo trayecto AVE / oficina:
  1. Levantar `iperf3 -s -B <UBOND_TUN_VPS_IP> -1` en la RPi.
  2. `tools/bench-wrappers.sh direct` con ubond-directo activo.
  3. Levantar cada wrapper (socat/udp2raw/wstunnel), apuntar
     `[links.wifi]` al wrapper, repetir `bench-wrappers.sh <vía>`.
  4. `tools/bench-wrappers.sh --show` → ranking coste/rendimiento.

**Riesgos:**

- **iperf3 ausente en el Mac/RPi:** cae a fallback `dd | nc` (requiere
  sink `nc -l 9999` en el destino) o `NA` — informado por log.
- **Medida única no estadística:** una sola pasada por vía; el ruido
  celular del AVE puede sesgar. Mitigación: repetir y promediar (cada
  pasada añade fila; el operador filtra outliers).
- **TARGET dentro de subnet colisionable:** mitigado forzando la
  medida por la utun de ubond (no `ping` global).
- **Fallback nc no equivale a iperf3:** método anotado en columna
  `tp_method` para no comparar peras con manzanas.

**Related:**

- `tools/bench-wrappers.sh` — implementación.
- `tools/wrap-socat.sh`, `tools/wrap-udp2raw.sh`,
  `tools/wrap-wstunnel.sh` — vías que el banco compara (REQ-NET-39).
- `tools/ubond-watchdog.sh` — patrón de localización de utun por
  `UBOND_TUN_MAC_IP` reutilizado aquí.
- `docs/v2-ubond/13-plan-bypass-wifi-tren.md` — sección 3 T4 que
  motiva este REQ.
- `config/env` — `UBOND_TUN_VPS_IP` / `UBOND_TUN_MAC_IP` consumidas.
- [[REQ-NET-44]] — rotación de MAC cuyo efecto en caudal cuantifica
  este banco.
