# Runbook AVE — operación v2 ubond

- **Autor:** Jorge Lazaro Molina
- **Última actualización:** 2026-06-02
- **Versión:** 1.0 (v2 ubond + watchdog REQ-NET-26)
- **Aplica a:** trayecto AVE Madrid–Orihuela, cliente macOS, RPi en casa.
- **Lectura objetivo:** 5 minutos.

Este runbook es el procedimiento operativo del usuario en el AVE. Para
referencia rápida de tests comparativos v1 vs v2, ver
`docs/v2-ubond/05-cheatsheet-ave.md`.

## TL;DR (30 segundos)

```sh
cd /Users/lazaromj/projects/ave-vpc
sudo ./04b-conectar-ubond.sh                 # arranca ubond + watchdog
bash tools/ave-monitor.sh                    # monitor continuo (otra terminal)
# al llegar:
sudo ./05b-desconectar-ubond.sh
```

Si todo arde: `bash /Users/lazaromj/projects/ave-vpc/SOS.sh`.

## 1. Pre-flight (casa/oficina, 5 min antes de salir)

Hacer **antes** de salir del WiFi de casa.

```sh
cd /Users/lazaromj/projects/ave-vpc

# 1.1 Binario ubond actualizado (REQ-NET-25 latency_tolerence presente)
strings /usr/local/sbin/ubond | grep -m1 latency_tolerence
ssh -p 22 jorge@192.168.1.101 \
  'sudo strings /usr/local/sbin/ubond | grep -m1 latency_tolerence'
# Esperado: ambas líneas imprimen "latency_tolerence". Si una vacía:
#   Mac: cd build/ubond && sudo make install
#   RPi: ./07b-setup-rpi-ubond.sh

# 1.2 Servicios RPi vivos
ssh -p 22 jorge@192.168.1.101 'sudo systemctl is-active mlvpn ubond'
# Esperado: active / active

# 1.3 DDNS resuelve
dig +short 200bares.dedyn.io | head -1   # debe imprimir IP pública

# 1.4 Smoke desde casa (tunel arriba sobre WiFi local)
sudo -E ./tools/smoke-casa.sh   # opcional pero recomendado
```

Hardware en la mochila: **2 cables USB de datos** (no de carga sola),
iPhone con Personal Hotspot habilitado en Movistar, Pixel con USB
tethering habilitado en Yoigo. Mac con WiFi libre para el tren.

## 2. En el AVE — arranque

**Orden FÍSICO** (sin saltarse pasos: el script depende de IPs reales):

1. Sentarte. Mac sobre la mesa.
2. **Conectar iPhone por USB**, activar Personal Hotspot. Esperar a
   que macOS muestre la interfaz (típicamente `en8`).
3. **Conectar Pixel por USB**, activar USB tethering. Esperar interfaz
   (típicamente `en12`).
4. Conectar al WiFi del tren si existe — autenticar el captive portal
   en Safari hasta que `http://captive.apple.com/hotspot-detect.html`
   diga "Success". Si no autentica, pasar de él (`--sin-wifi`).
5. Verificar que las 3 interfaces tienen IP:

   ```sh
   ifconfig en8 | grep 'inet '
   ifconfig en12 | grep 'inet '
   ifconfig en0 | grep 'inet '
   ```

6. **Arrancar el túnel:**

   ```sh
   cd /Users/lazaromj/projects/ave-vpc
   sudo ./04b-conectar-ubond.sh
   # Si el WiFi del tren da problemas:
   # sudo ./04b-conectar-ubond.sh --sin-wifi
   ```

**Confirmación de OK** (mirar la salida del script):

- `Enlaces activos: 2` o `3`.
- `Túnel ubond activo en utunN`.
- `Ping al VPS (10.10.20.1): OK`.
- `Arrancando watchdog (auto-recovery via SOS.sh si pierde gateway)...`.

Si `Ping al VPS ... OK` no aparece, esperar 10 s y reintentar el ping
manual: `ping -c 3 10.10.20.1`. Si sigue KO, ir a §4.

## 3. Durante el viaje — monitorización

Abrir **una segunda terminal** y dejarla corriendo:

```sh
bash /Users/lazaromj/projects/ave-vpc/tools/ave-monitor.sh
# Salida: stdout + generated/ave-monitor-<timestamp>.log
```

> Nota: `tools/ave-monitor.sh` se entrega en este sprint y aún no se ha
> ejercitado en AVE real. **Pendiente validar runtime en trayecto.**

Señales que el monitor mostrará:

- **OK:** RTT al gateway interno (10.10.20.1) <300 ms, loss <5 %, los
  3 enlaces (o 2 sin WiFi) reportan tráfico, watchdog en estado
  `healthy`.
- **Sospechoso:** RTT >500 ms sostenido >30 s, loss >20 %, un enlace
  con `bytes_in=0` durante >60 s (móvil sin cobertura — esperable en
  túneles).
- **Malo:** todos los enlaces a 0 bytes, ping al gateway interno KO
  >20 s. El watchdog disparará SOS solo (ver §4).

Vista alternativa de tráfico (read-only, TUI):

```sh
sudo python3 /Users/lazaromj/projects/ave-vpc/08-monitor.py
```

Logs en vivo:

```sh
tail -f /Users/lazaromj/projects/ave-vpc/generated/ubond.log
tail -f /Users/lazaromj/projects/ave-vpc/generated/ubond_watchdog.log
```

## 4. Si algo falla

### Caso A — corte de red, no he tocado nada

El watchdog (REQ-NET-26) detecta:

- proceso `ubond` ausente, **o**
- `utun` del túnel sin IP `10.10.20.2`, **o**
- ping a `10.10.20.1` por la utun KO 4 veces seguidas (≈20 s).

Cuando cruza el threshold, **invoca SOS.sh automáticamente** y notifica
con `osascript`. **Esperar 20 s** antes de tocar nada. Tras SOS, el
túnel queda apagado y la red Mac restaurada — relanzar §2.6:

```sh
sudo ./04b-conectar-ubond.sh
```

Cooldown del watchdog: 60 s entre SOS sucesivos (anti-spam).

### Caso B — tras watchdog SOS, sigue mal

```sh
# 1. Verificar que SOS limpió bien
ping -c 2 1.1.1.1            # debe responder por la red de los móviles
pgrep -fl 'ubond: '          # debe estar vacío

# 2. Si el ping a 1.1.1.1 KO: red móvil caída. Comprobar visualmente
#    iPhone/Pixel (icono hotspot, datos, cobertura). Reconectar USB.

# 3. Probar fallback v1 (mlvpn) — production, conocido funcional:
sudo ./04-conectar.sh --failover
```

### Caso C — pánico total

```sh
bash /Users/lazaromj/projects/ave-vpc/SOS.sh
```

Mata `mlvpn` + `ubond` + watchdog + watchers, borra rutas `0/1`,
`128/1` y `/32` al VPS, limpia IPs colgadas en utuns, verifica
default route e internet. Termina en <2 s. Si tras SOS no hay
internet: apagar/encender WiFi desde el icono del menú macOS.

## 5. Al llegar

```sh
cd /Users/lazaromj/projects/ave-vpc
sudo ./05b-desconectar-ubond.sh
```

Salida esperada:

- `✓ ubond parado (todas las instancias)`
- `✓ Internet restaurado`

Mata el watchdog **antes** que el binario (si no, el watchdog
detectaría "ubond ausente" y dispararía SOS innecesariamente —
ya gestionado por el script). Cerrar la terminal del `ave-monitor`
con `Ctrl+C`.

## 6. Postmortem

Logs persistidos en `/Users/lazaromj/projects/ave-vpc/generated/`:

| Fichero | Qué contiene | Buscar para... |
|--------|--------------|----------------|
| `ubond.log` | stdout/stderr del binario ubond (debug+verbose) | "tunnels down or lossy", "rtun_down", "auth failed" |
| `ubond_watchdog.log` | ticks del watchdog, triggers SOS | "TRIGGER SOS", "health fail N/4", "recuperado tras N fallos" |
| `ubond_active.conf` | conf efectiva (con IPs reales) | sólo durante la sesión, lo borra 05b/SOS |
| `ave-monitor-<ts>.log` | snapshot del monitor (legible) | gaps de tráfico, picos de RTT, eventos por enlace |
| `ave-monitor-<ts>.ndjson` | métricas estructuradas, una línea/tick (REQ-NET-28) | parseable con `jq`, postmortem ALCOA++ |

Síntomas → dónde mirar:

- **Cortes cortos (<5 s) recurrentes:** `ubond.log` busca
  `tunnels down or lossy`. Si aparece cada ~1 s con uno solo de los
  links → revisar `loss_tolerence`/`latency_tolerence` en
  `generated/ubond.conf` para ese link (REQ-NET-25, descomentar).
- **SOS disparado:** `ubond_watchdog.log` línea
  `TRIGGER SOS — motivo='...'`. Motivos posibles: `proceso ubond
  ausente` (crash), `sin respuesta 10.10.20.1 N×5s` (red caída),
  `flag fresco` (un link reportó down vía updown handler).
- **Ningún enlace autentica al arrancar:** `ubond.log` líneas
  `auth failed` o ausencia de `tuntap_up`. Verificar port forwarding
  router doméstico (UDP 5083/5084/5085 → 192.168.1.101) y
  `systemctl is-active ubond` en RPi.
- **Throughput pésimo en un enlace específico:** captura controlada
  con `sudo -E /Users/lazaromj/projects/ave-vpc/tools/smoke-ave.sh` —
  genera reporte por capa en `/tmp/ave-smoke/report-ave-*.md`
  (REQ-NET-23) con tabla Mac out / RPi in / RPi tun out / Mac utun in.

Tras el viaje, **documentar el resultado** en
`docs/v2-ubond/06-trayecto-<fecha>.md` (un fichero nuevo por trayecto)
con: enlaces activos, anomalías, líneas relevantes de log, veredicto
v1/v2 si se cambió de modo. Commit en git para preservar la traza
ALCOA++.

## Referencias

- `docs/v2-ubond/05-cheatsheet-ave.md` — referencia rápida de tests v1 vs v2.
- `docs/v2-ubond/03-plan-trabajo.md` — roadmap v2.0.0.
- `docs/v2-ubond/04-bugs-trayecto-2026-05-29.md` — bugs históricos.
- REQ-NET-25 (per-link tolerences), REQ-NET-26 (watchdog auto-recovery),
  REQ-NET-27 (data_seq + dedup fix), REQ-NET-28 (monitor ALCOA++).
