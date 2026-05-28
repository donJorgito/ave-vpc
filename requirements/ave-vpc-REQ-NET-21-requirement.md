### ave-vpc.REQ-NET-21 - Setup paralelo de ubond en RPi (Fase 4 v2)

**Description:**

`07b-setup-rpi-ubond.sh` es el complemento servidor de
`03b-setup-mac-ubond.sh` (REQ-NET-20): instala ubond en la
Raspberry Pi en paralelo a mlvpn. Filosofía clave: **ambos
servidores pueden estar arriba a la vez** porque escuchan en
puertos UDP distintos.

Layout en RPi:

| | mlvpn (v1.x estable) | ubond (v2 experimental) |
|---|---|---|
| Binario | `/usr/local/sbin/mlvpn` | `/usr/local/sbin/ubond` |
| Config | `/etc/mlvpn/mlvpn.conf` | `/etc/ubond/ubond.conf` |
| Updown | `/etc/mlvpn/mlvpn_updown.sh` | `/etc/ubond/ubond_updown.sh` |
| Usuario | `mlvpn` | `ubond` |
| Chroot | `/var/lib/mlvpn` | `/var/lib/ubond` |
| Servicio | `mlvpn.service` | `ubond.service` |
| Puertos UDP | 5080, 5081, 5082 | **5083, 5084, 5085** |
| Estado por defecto | `enabled` + `started` | `enabled` pero **NO started** |

**Diferencias respecto al setup macOS** (REQ-NET-20):

- **Solo aplica el patch de replicación** (`patches/ubond_replicate_filter.patch`).
  Los patches macOS (REQ-NET-19, `SO_BINDTODEVICE` + `tuntap_darwin_utun_ubond.c`)
  NO aplican: Linux compila vanilla porque `SO_BINDTODEVICE` existe nativo
  y `/dev/net/tun` es la API estándar.
- **El servicio se crea pero NO arranca automáticamente**. Decisión
  del usuario activar v2 cuando lo pruebe. Evita interferencias con
  mlvpn ya en producción.
- **Sección `[filters.replicate]` vacía**. El servidor solo necesita
  el dedup LRU (que se activa en `protocol_read` independientemente
  del contenido de la sección). Las reglas de replicación las define
  el cliente.

**Parent Requirement:** ave-vpc.REQ-NET-20

**Acceptance Criteria:**

- `07b-setup-rpi-ubond.sh` existe, ejecutable, pasa `bash -n` y
  `shellcheck`.
- Lee `RPi_IP`, `RPi_USER`, `RPi_SSH_PORT` de `config/env`. Falla
  con mensaje claro si falta `RPi_IP`.
- Define puertos UDP `UBOND_PORT_1=5083`, `UBOND_PORT_2=5084`,
  `UBOND_PORT_3=5085` (con override por env vars), distintos a los
  de mlvpn.
- Verifica que existe `patches/ubond_replicate_filter.patch` antes
  de conectar al RPi.
- Comparte `keys/mlvpn.secret` (mismo password que mlvpn — un único
  secret para ambos lados).
- En el RPi (vía SSH heredoc):
  - Instala dependencias APT (`build-essential pkg-config autoconf
    automake libtool libev-dev libsodium-dev libpcap-dev git`).
  - Si `ubond` ya instalado, salta compilación (idempotente).
  - Clona `markfoodyburton/ubond` con `--depth 1` en `/tmp/ubond-build`.
  - Aplica **solo** `ubond_replicate_filter.patch` (NO los macOS).
    `patch -p1 -N` no falla si ya aplicado.
  - `./configure --enable-filters` (requerido para `[filters.replicate]`).
  - Genera `/etc/ubond/ubond.conf` (mode=server, sección
    `[filters.replicate]` vacía, puertos 5083-5085).
  - Genera `/etc/ubond/ubond_updown.sh` con la misma lógica que
    `/etc/mlvpn/mlvpn_updown.sh` (NAT MASQUERADE + iptables FORWARD).
  - Crea usuario sistema `ubond` con home `/var/lib/ubond` (chroot).
  - `ufw allow` para los 3 puertos UDP nuevos.
  - Crea `ubond.service` systemd unit paralelo a `mlvpn.service`.
  - `systemctl enable ubond` PERO **NO** `systemctl start`. Imprime
    el comando para activarlo manualmente.
- NO toca mlvpn ni su servicio: `mlvpn.service` sigue corriendo si
  estaba arriba.
- Limpia `/tmp/ubond-build` tras compilar (no deja basura).
