### ave-vpc.REQ-NET-07 - Rebind del enlace WiFi ante cambios de IP

**Description:**

El enlace WiFi (`[links.wifi]` en `mlvpn_active.conf`) debe seguir siendo
funcional aunque la IP del Mac en `IFACE_WIFI` cambie en runtime, ya sea
por renovación DHCP tras autenticar un captive portal o por roaming
entre puntos de acceso (típico en el AVE). El script `04-conectar.sh`
debe (a) verificar la IP tras pasar el captive portal antes de arrancar
mlvpn y (b) lanzar un watcher en background que detecte cambios de IP y
fuerce a mlvpn a reabrir el socket de ese link sin reiniciar el túnel
completo. Adicionalmente, el bloque `[links.wifi]` debe especificar
`timeout`, `loss_tolerence` y `latency_tolerence` per-link más
agresivos que los globales para que mlvpn saque el WiFi de la
agregación cuando se degrada sin tirar abajo el resto.

**Parent Requirement:** ave-vpc.REQ-NET-06

**Acceptance Criteria:**

- Tras pasar el check de captive portal, el script espera 3-5 s y
  revalida la IP de `IFACE_WIFI`. Si cambió, refresca `IP_WIFI` antes de
  escribir `bindhost` en `mlvpn_active.conf`.
- Si la IP desaparece tras el captive (interfaz sin IP), el WiFi se
  omite con aviso, sin error.
- Mientras mlvpn está corriendo, un watcher en background revisa la IP
  de `IFACE_WIFI` cada 5 s. Si detecta un cambio, reescribe `bindhost`
  en `mlvpn_active.conf` y manda `SIGHUP` al proceso `mlvpn [priv]`,
  que recarga la config y rebindea el socket sin reiniciar el túnel.
- El PID del watcher se guarda en
  `generated/mlvpn_wifi_watcher.pid` y `05-desconectar.sh` lo mata
  antes de parar mlvpn.
- El bloque `[links.wifi]` generado por `04-conectar.sh` incluye
  `timeout = 8`, `loss_tolerence = 30` y `latency_tolerence = 800`.
  mlvpn declara DOWN el WiFi en 8 s en vez de los 30 s globales y lo
  saca de la agregación si la pérdida supera 30 % o el RTT 800 ms,
  manteniendo iPhone y Pixel intactos.
- Cada rebind del watcher escribe una línea
  `HH:MM:SS wifi rebind <ip_vieja> -> <ip_nueva>` en
  `generated/mlvpn.log` para trazabilidad.
