### ave-vpc.REQ-NET-22 - Cliente ubond paralelo a mlvpn (Fase 4 v2)

**Description:**

`04b-conectar-ubond.sh` es el cliente v2: arranca el binario ubond
desde `/usr/local/sbin/ubond` con `generated/ubond.conf`, paralelo a
`04-conectar.sh` (que sigue manejando mlvpn v1.x). Filosofía de
coexistencia heredada de [[REQ-NET-20]] / [[REQ-NET-21]]:

- Puertos UDP distintos (5083/5084/5085 vs 5080-5082).
- Binarios distintos (`ubond` vs `mlvpn`).
- Configs distintas (`ubond.conf` vs `mlvpn.conf`).
- Interfaz tun distinta (`ubond0` vs `mlvpn0`).
- Usuarios sistema distintos (`ubond` vs `mlvpn`).

**Diferencias respecto a `04-conectar.sh` (REQ-NET-04 implícito):**

- Lee `generated/ubond.conf` (creado por `03b-setup-mac-ubond.sh`)
  en vez de `generated/mlvpn.conf`.
- Arranca `/usr/local/sbin/ubond --user ubond --name ubond0`.
- Cleanup defensivo busca `ubond: ubond0` en vez de `mlvpn: mlvpn0`.
- **Sin watchers de `--failover` ni `wifi-reintegrator` en esta
  primera versión** — la v2 se valida primero en bonding puro
  contra `[filters.replicate]`. Si funciona, se duplican los
  watchers como `tools/seleccionar-mejor-enlace_ubond.sh` y
  `tools/wifi-reintegrator_ubond.sh` (decisión de duplicar vs
  parametrizar tomada en [[ubond-v2-roadmap]] memoria del
  proyecto: duplicar es más seguro para v1.x).

**Parent Requirement:** ave-vpc.REQ-NET-20

**Acceptance Criteria:**

- `04b-conectar-ubond.sh` existe, ejecutable, pasa `bash -n` y
  `shellcheck`.
- Verifica `EUID == 0` (requiere sudo) con mensaje claro.
- Acepta flag `--sin-wifi`. Otros argumentos provocan exit con uso.
- Aborta con mensaje claro si:
  - `config/env` no existe.
  - `generated/ubond.conf` no existe (sugiere ejecutar 03b).
  - `/usr/local/sbin/ubond` no existe (sugiere ejecutar 03b).
- Detecta IPs reales de `IFACE_IPHONE`/`IFACE_PIXEL`/`IFACE_WIFI`
  con `ipconfig getifaddr`.
- Pre-flight WiFi idéntico al de `04-conectar.sh`:
  captive portal + IP pública == DDNS RPi (red de casa).
- Crea rutas `-ifscope` al `${VPS_IP}` por cada interfaz.
- Genera `generated/ubond_active.conf` desde `generated/ubond.conf`
  reemplazando `PLACEHOLDER_IPHONE_IP` / `PLACEHOLDER_PIXEL_IP`
  con IPs reales. Añade bloque `[links.wifi]` si WiFi elegible.
- Cleanup defensivo previo (REQ-MAC-05 análogo): mata procesos
  `ubond: ubond0` previos antes de arrancar el nuevo.
- Arranca `/usr/local/sbin/ubond --config ubond_active.conf
  --name ubond0 --user ubond` y guarda PID en
  `generated/ubond.pid`.
- Detecta `utun` creado por ubond (vía `ifconfig` + verificación
  de proceso `ubond: ubond0 @`) y configura IP del túnel
  - rutas `0.0.0.0/1` + `128.0.0.0/1`.
- Imprime resumen con enlaces, PID y log path.
- NO toca mlvpn ni su PID ni `mlvpn_active.conf`. Si mlvpn está
  arriba, sigue arriba.
