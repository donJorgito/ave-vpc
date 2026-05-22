### ave-vpc.REQ-NET-10 - Calibración dinámica de pesos WRR en runtime

**Description:**

Los pesos del Weighted Round Robin de mlvpn (`bandwidth_upload`) son
estáticos en la config inicial generada por `03-setup-mac.sh`. En la
práctica, la cobertura móvil cambia drásticamente durante un
trayecto: medido en producción 2026-05-22, el mismo Pixel pasó de
253 KB/s + timeouts a 2.9 MB/s en 10 minutos; iPhone fluctuó entre
1.0 MB/s y 2.7 MB/s en el mismo periodo. Una calibración estática
queda obsoleta en minutos.

`tools/calibrar-enlaces-dinamico.sh` corre como watcher en background
(lanzado por `04-conectar.sh`, terminado por `05-desconectar.sh`) y
recalcula los pesos WRR cada 30 s sin tirar el túnel. mlvpn soporta
recarga de config + recalculo de pesos al recibir `SIGHUP` (visto en
`build/MLVPN/src/config.c:384`, ya usado por el watcher de IP del
WiFi en REQ-NET-07).

**Coste en datos**: 1 ping ICMP × N enlaces cada 5 s ≈ 1.5 MB/día.
No se hace medición de throughput con curl periódico porque competiría
con el tráfico del usuario (descartado explícitamente como demasiado
intrusivo).

**Parent Requirement:** ave-vpc.REQ-NET-09

**Acceptance Criteria:**

- `tools/calibrar-enlaces-dinamico.sh` existe, es ejecutable, pasa
  `bash -n` y `shellcheck`.
- `04-conectar.sh` lanza el calibrador en background tras autenticar
  los enlaces, solo si la config activa tiene ≥2 `[links.*]`. PID en
  `generated/mlvpn_calibrator.pid`.
- `05-desconectar.sh` lee el PID y mata el calibrador antes de parar
  mlvpn, para evitar que reescriba la config en mitad del shutdown.
- El calibrador hace `ping -S <iface_ip>` (no curl) cada 5 s desde
  cada interfaz física al `VPS_IP` resuelto a IPv4.
- Mantiene una ventana deslizante de 12 muestras (60 s) por enlace.
- Cada 30 s recalcula `score = 1000 / (rtt_avg/50 + 1)` y aplica
  penalización ×0.3 si la pérdida está entre 15-40 %. Por debajo no
  penaliza; por encima activa fallback.
- Si la pérdida supera 40 % sostenida 60 s, marca `fallback_only = 1`
  para ese link. Cuando se recupera (loss <15 %), restaura
  `fallback_only = 0`. Loguea cada transición en
  `generated/mlvpn.log` con timestamp.
- Solo aplica cambios (sed + SIGHUP a `mlvpn [priv]`) si algún
  `bandwidth_upload` recalculado difiere >25 % del actual o si cambia
  algún `fallback_only`. Evita SIGHUP excesivos.
- Reescribe per-link en `mlvpn_active.conf`; nunca toca el config
  generado por `03-setup-mac.sh` (`mlvpn.conf` plantilla).
- El calibrador limpia su PID file al terminar (trap EXIT).
