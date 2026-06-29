# Cheatsheet AVE — sesión de validación v1 vs v2

Doc operativo. Lectura: 2 min. Para imprimir/leer offline antes de
salir hacia el AVE. Sustituye al "qué tengo que correr en el tren"
de memoria.

## Antes de salir de casa

```sh
# 1. Confirmar binarios sincronizados (Mac + RPi tienen REQ-NET-25)
strings /usr/local/sbin/ubond | grep latency_tolerence | head -1
ssh -p 22 jorge@192.168.1.101 \
  'sudo strings /usr/local/sbin/ubond | grep latency_tolerence | head -1'
# Ambas líneas deben imprimir "latency_tolerence". Si una vacía:
#   - Mac: cd build/ubond && sudo make install
#   - RPi: ./07b-setup-rpi-ubond.sh

# 2. Confirmar servicios RPi up
ssh -p 22 jorge@192.168.1.101 'sudo systemctl is-active mlvpn ubond'
# Esperado: active / active

# 3. Hardware: 2 cables USB-de-datos, iPhone con hotspot habilitado,
#    Pixel con USB tethering habilitado. Mac con WiFi libre.
```

## En el AVE — secuencia de tests

Cada test 10-15 min. Anotar latencia, throughput y MOS subjetivo
de videoconf.

### Fase 1 — baseline v1 (mlvpn `--failover`)

```sh
sudo ./04-conectar.sh --failover
# Otra terminal:
sudo python3 ./08-monitor.py
# Comprobar:
#   - traceroute 8.8.8.8  (hop 1 = 10.10.10.1 ✓)
#   - ping 1.1.1.1        (latencia <300ms en cobertura buena)
#   - curl --max-time 30 https://speed.cloudflare.com/__down?bytes=1048576 \
#         -o /dev/null -w 'speed=%{speed_download}\n'
# Anotar.
sudo ./05-desconectar.sh
```

### Fase 2 — v2 ubond bonding puro

```sh
sudo ./04b-conectar-ubond.sh
# (ubond_active.conf tendrá los 3 links con tolerences default)
sudo python3 ./08-monitor.py
# Mismas pruebas que fase 1. Anotar.
# Si ves loss cycling en log syslog cada ~1s, fase 3 lo arregla.
sudo ./05b-desconectar-ubond.sh
```

### Fase 3 — v2 con per-link tolerences (REQ-NET-25)

Editar `generated/ubond_active.conf` antes de arrancar:

```sh
sudo ./04b-conectar-ubond.sh
sudo killall ubond  # paramos para editar conf

# Descomentar en cada [links.X] del ubond_active.conf:
#   loss_tolerence    = 80
#   latency_tolerence = 2000
sudo nano /Users/lazaromj/projects/ave-vpc/generated/ubond_active.conf

# Re-arrancar manual (sin pasar por 04b porque ya se hizo el setup):
sudo /usr/local/sbin/ubond --config /Users/lazaromj/projects/ave-vpc/generated/ubond_active.conf \
  --user ubond --debug --verbose
# Comprobar log: NO debe aparecer "tunnels down or lossy" cada segundo.
# Mismas pruebas. Anotar.
```

### Fase 4 — v2 con replicación selectiva (filters.replicate)

Editar `ubond_active.conf` (descomentar zoom_rtp / anthropic_api en
la sección `[filters.replicate]`):

```sh
# Descomentar en ubond_active.conf:
# [filters.replicate]
# zoom_rtp = "udp and (dst port 8801 or dst port 8802)"
# anthropic_api = "tcp and dst port 443 and dst host api.anthropic.com"

# Re-arrancar como en fase 3.
# Probar Anthropic API:
curl https://api.anthropic.com/v1/messages -H "..." # ver latencia
```

## Métricas a comparar

| Métrica | Cómo medir | Esperado |
|---------|-----------|----------|
| Latencia 10.10.10.1 | `ping -c 50` | <100ms |
| Latencia 1.1.1.1 | `ping -c 50 -i 0.2` | <300ms |
| Throughput 1MB | `curl -w 'speed=%{speed_download}'` | depende cobertura |
| Pérdida ICMP | `ping -c 100 -i 0.1` % loss | <5% en buena cobertura |
| Calidad videoconf | Subjetivo MOS 1-5 | ≥3 |
| CPU RPi | `ssh rpi 'top -bn1 \| grep ubond'` | <50% un core |
| Loss cycling | log de ubond — buscar "tunnels down or lossy" | NO debería en fase 3+ |

## Si algo va mal

```sh
# Pánico nuclear: mata todo + restaura rutas
bash ~/projects/ave-vpc/SOS.sh
# Esto mata mlvpn Y ubond Y watchers, limpia utuns, borra
# rutas /1, deja la red del Mac como antes de conectar.
```

## Smoke-test diagnostic (REQ-NET-23)

Si algún test falla raro, usar el diagnóstico automático:

```sh
sudo -E ./tools/smoke-ave.sh
# Genera reporte markdown en /tmp/ave-smoke/report-ave-*.md con
# tabla de paquetes por capa (Mac out / RPi in / RPi tun out /
# Mac utun in) y veredicto de dónde muere el paquete.
# Captura tcpdump simultáneo en Mac y RPi vía SSH.
```

## Tras volver

- Anotar resultados en `docs/v2-ubond/06-trayecto-<fecha>.md`.
- Commitear el doc.
- Si v2 supera a v1 → roadmap fase 6 (cutover).
- Si v2 introduce regresión vs v1 → mantener v1 como production y
  documentar el gap.
