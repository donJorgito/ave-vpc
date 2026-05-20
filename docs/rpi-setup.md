# Raspberry Pi como endpoint mlvpn en casa

Alternativa a Oracle Cloud: una Raspberry Pi 4 conectada al router de casa
actúa como servidor mlvpn. El tráfico del AVE llega por los puertos UDP
abiertos en el router y sale a internet a través de la fibra óptica.

## Lista de la compra (Amazon.es)

| Componente | Modelo | Precio aprox. |
|---|---|---|
| Placa | [Raspberry Pi 4 Modelo B 4GB](https://www.amazon.es/dp/B09TTNF8BT) | ~118€ |
| Carcasa | [Geekworm aluminio pasiva (sin ventilador)](https://www.amazon.es/dp/B07ZVJDRF3) | ~13€ |
| MicroSD | [SanDisk Ultra 64GB A1](https://www.amazon.es/dp/B0B7NXBM6P) | ~19€ |
| Fuente | [GeeekPi 5V/4A 20W USB-C con interruptor](https://www.amazon.es/dp/B0CF44S2HG) | ~12€ |
| Cable | [deleyCON Cat6 0,5m](https://www.amazon.es/dp/B01LLOFUIA) | ~5€ |
| **Total** | | **~167€** |

> La carcasa Geekworm es de aluminio macizo y actúa como disipador térmico
> pasivo. Sin ventilador, sin ruido.

## Arquitectura con RPi en casa

```
[ Tren AVE ]                    [ Tu casa ]
   Mac                          RPi 4 ── router fibra ── internet
    │ iPhone (UDP 5080)            │         │
    │ Pixel  (UDP 5081)            │    port forwarding
    │ WiFi   (UDP 5082, opcional)  │    UDP 5080–5082 → RPi
    └──────── internet ────────────┘    DDNS: tu-hostname.dedyn.io
```

El Mac en el AVE se conecta al hostname DDNS que siempre apunta a la IP
pública de casa. El router reenvía los paquetes UDP a la RPi.

El 3er enlace WiFi (UDP 5082) es opcional y se activa automáticamente cuando
el WiFi del Mac pasa los pre-flight checks (ver README → "Tercer enlace WiFi").
El RPi siempre tiene el puerto 5082 abierto y escucha allí; es el cliente quien
decide si usarlo. Para WiFi públicos restrictivos (AVE, aeropuertos) que
filtran puertos altos, el cliente puede conectar a 443/UDP y el router mapea
a 5082 internamente — ver `MLVPN_PORT_3_REMOTE` y la regla opcional
`mlvpn-443` más abajo.

> ⚠️ **Requisito previo: IP pública sin CGNAT**
> Muchos ISPs residenciales usan CGNAT (la IP WAN del router empieza por `100.x.x.x`).
> Con CGNAT el port forwarding no funciona — el tráfico entrante nunca llega al router.
> Verifica la IP WAN en el router (Internet → Status → WAN IP Address).
> Si empieza por `100.`, contacta con tu ISP y pide la retirada del CGNAT (suele ser gratuito).

## Paso 1: Grabar la microSD (headless, sin monitor)

Instala **Raspberry Pi Imager** en el Mac:
```bash
brew install --cask raspberry-pi-imager
```

En el Imager:
1. **Dispositivo**: Raspberry Pi 4
2. **OS**: Other general-purpose OS → Ubuntu → **Ubuntu Server 26.04 LTS (64-bit)**
3. **Storage**: tu microSD
4. Haz clic en **Editar ajustes** (⚙) antes de grabar:
   - Hostname: el que quieras (ej. `mi-rpi`)
   - Usuario: el que quieras (ej. `ubuntu`)
   - Activar SSH: "Allow public-key authentication only"
   - Pega tu clave pública SSH (`cat ~/.ssh/id_rsa.pub` o `~/.ssh/id_ed25519.pub`)
   - No configurar WiFi (va por Ethernet)

Graba. Mete la tarjeta en la RPi, conecta el cable Ethernet al router, enchúfala.

## Paso 2: Asignar IP fija a la RPi

La RPi debe tener siempre la misma IP local para que el port forwarding funcione.
Opciones:

- **Reserva DHCP por MAC** en el router (Home → LAN Devices, busca la nueva MAC)
- **IP estática** en la RPi tras el primer arranque con `sudo nmtui`

Verifica que puedes entrar (espera ~1 min tras enchufar):
```bash
ssh TU_USUARIO@192.168.1.XXX
# o por hostname mDNS:
ssh TU_USUARIO@mi-rpi.local
```

## Paso 3: Port Forwarding en el router ZTE F6640

En el router: **Internet → Security → Port Forwarding**

Añade tres reglas:

| Nombre | Protocolo | Puerto externo | IP interna | Puerto interno |
|---|---|---|---|---|
| mlvpn-5080 | UDP | 5080 | IP_LOCAL_RPi | 5080 |
| mlvpn-5081 | UDP | 5081 | IP_LOCAL_RPi | 5081 |
| mlvpn-5082 | UDP | 5082 | IP_LOCAL_RPi | 5082 |
| mlvpn-443 (opcional) | UDP | 443 | IP_LOCAL_RPi | **5082** |

> Sustituye `IP_LOCAL_RPi` por la IP fija que hayas asignado (ej. `192.168.1.101`).
>
> La regla **`mlvpn-443`** es **opcional** pero muy recomendable. Mapea el
> puerto público 443/UDP (que casi ninguna red filtra al ser QUIC) al
> 5082/UDP interno donde mlvpn escucha. Para activarla en el cliente,
> define `MLVPN_PORT_3_REMOTE="443"` en `config/env`.
> El router ZTE F6640 admite port translation (puerto externo distinto
> del interno) sin problema.

## Paso 4: DDNS

La fibra de casa tiene IP pública dinámica. Un hostname DDNS mantiene siempre
un nombre fijo que apunta a tu IP actual.

### Opción A: deSEC (recomendado, gratuito y privado)

[deSEC](https://desec.io) ofrece subdominios `*.dedyn.io` gratuitos con soporte
para el protocolo DynDNS2 que el router ZTE F6640 soporta nativamente.

1. Regístrate en https://desec.io y crea un subdominio `*.dedyn.io`
2. En el router: **Internet → DDNS**
   - Provider: `DynDNS`
   - Provider URL: `https://update.dedyn.io/`
   - Username: tu subdominio completo (`tu-hostname.dedyn.io`)
   - Password: tu token de deSEC
   - Host Name: tu subdominio completo
3. Activa DDNS y aplica

### Opción B: No-IP (soportado nativamente por el router)

[No-IP](https://www.noip.com) está en la lista de proveedores del router ZTE.
Regístrate, crea un hostname y configúralo directamente con el proveedor `No-IP`.

Verifica que el hostname resuelve:
```bash
dig tu-hostname.dedyn.io +short
# Debe devolver la IP pública de casa
```

## Paso 5: Configurar y ejecutar el script de setup

Actualiza `config/env` con los valores de la RPi:

```bash
RPi_IP="192.168.1.XXX"     # IP local de la RPi
RPi_USER="TU_USUARIO"      # usuario configurado en el Imager
RPi_SSH_PORT="22"
```

Ejecuta el script desde el Mac:
```bash
./01-generar-secreto.sh   # si no existe ya keys/mlvpn.secret
./07-setup-rpi.sh
```

El script instala mlvpn (tarda 2-3 min en compilar en ARM), configura NAT,
IP forwarding y el servicio systemd.

## Paso 6: Configurar el Mac para conectar a la RPi

Cambia `VPS_IP` en `config/env`:

```bash
VPS_IP="tu-hostname.dedyn.io"
VPS_USER="TU_USUARIO"
```

Regenera la configuración del Mac:
```bash
./03-setup-mac.sh
```

A partir de aquí, `./04-conectar.sh` funciona exactamente igual que con Oracle Cloud.

## Routing en macOS: bonding completo y anti-loop

Para que el tráfico pase por el tunel mlvpn (bonding real), `04-conectar.sh` añade
rutas 0/1 y 128/1 via utun. Sin ellas, el tráfico va directo por los móviles sin pasar
por el VPN.

**El problema del loop**: las rutas ifscope (flag `I`) al VPS solo aplican cuando el
socket usa `IP_BOUND_IF`. mlvpn usa `bind()` estándar, sin `IP_BOUND_IF`. Con 0/1 en
la tabla global, macOS resuelve el VPS por la ruta 0/1 → el propio tunel → loop.

**La solución**: añadir una ruta regular /32 al VPS (sin ifscope) ANTES de las 0/1.
Las /32 son más específicas que /1 en la tabla global → mlvpn usa ruta directa por
el móvil, el resto del tráfico entra por el tunel.

Para verificar que el bonding funciona correctamente:
```bash
traceroute 8.8.8.8
# Hop 1 debe ser 10.10.10.1 (la RPi) — indica que el tráfico pasa por el tunel
```

## Notas de compatibilidad con Ubuntu 26.04 LTS

El script `07-setup-rpi.sh` está probado en Ubuntu Server 26.04 LTS ARM64.
Diferencias respecto a versiones anteriores:

- **`libpcap-dev` requerido**: Ubuntu 26.04 exige `libpcap-dev` para compilar mlvpn
  (antes era opcional). El script lo instala automáticamente.
- **mlvpn requiere `--user <usuario>`**: mlvpn rechaza arrancar como root sin este flag.
  El script crea un usuario de sistema dedicado `mlvpn` y configura systemd con `--user mlvpn`.
- **Directorio chroot `/var/lib/mlvpn`**: mlvpn hace chroot al home del usuario con el que corre.
  El script crea el usuario `mlvpn` con home en `/var/lib/mlvpn` y los permisos correctos.
- **`file://` no funciona como password**: mlvpn NO implementa el prefijo `file://` — usa el
  literal completo como contraseña. Los scripts embeben el secreto directamente en el config.
- **`bindhost = "0.0.0.0"` obligatorio en servidor**: sin este campo, mlvpn no hace bind a
  los puertos UDP en Ubuntu 26.04 (los links quedan configurados pero sin socket activo).
- **`statuscommand` no `ip4_updns`**: el key correcto del config es `statuscommand`. La clave
  `ip4_updns` es ignorada silenciosamente — el script nunca se ejecuta.
- **Firma del statuscommand**: `script <device> <evento> [link]` con env vars `IP4`,
  `IP4_GATEWAY`, `MTU`, `DEVICE`. La API antigua con `MLVPN_IPADDR`/`MLVPN_INTERFACE` no
  está implementada en este mlvpn.
- **Permisos del statuscommand**: debe ser `chmod 700` (solo owner). mlvpn rechaza ejecutar
  scripts con permisos de grupo u otros (`group/other accessible` → error fatal).
- **Sin NetworkManager**: Ubuntu Server 26.04 usa `systemd-networkd` por defecto,
  no NetworkManager. Para configurar IP estática usar `sudo nmtui` si lo instalas
  o editar `/etc/systemd/network/`. Lo más sencillo: reserva DHCP por MAC en el router.

## Ventajas e inconvenientes frente a Oracle Cloud

| | RPi en casa | Oracle Cloud |
|---|---|---|
| Coste hardware | ~167€ (una sola vez) | 0€ |
| Coste mensual | 0€ | 0€ (Always Free) |
| Ancho de banda | Fibra (~600 Mbps) | Limitado (~480 Mbps) |
| Latencia | Baja (tu casa) | Baja (Madrid) |
| Disponibilidad | Depende de luz y router | Alta (Oracle SLA) |
| Setup | Router + DDNS | Automatizado con Terraform |
| Control | Total | Limitado |
