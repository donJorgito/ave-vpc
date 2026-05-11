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
> pasivo. Sin ventilador, sin ruido. Verificado con 2.627 reseñas en Amazon.

## Arquitectura con RPi en casa

```
[ Tren AVE ]                    [ Tu casa ]
   Mac                          RPi 4 ── router fibra ── internet
    │ iPhone (UDP 5080)            │         │
    │ Pixel  (UDP 5081)            │    port forwarding
    └──────── internet ────────────┘    UDP 5080, 5081 → RPi
                                        DDNS: tu-hostname.duckdns.org
```

El Mac en el AVE se conecta al hostname DDNS que apunta a tu IP de casa.
El router reenvía los paquetes UDP a la RPi. La RPi los reensambla con
mlvpn y los reenvía a internet a través de la fibra.

## Paso 1: Grabar la microSD (headless, sin monitor)

Instala **Raspberry Pi Imager** en el Mac:
```
brew install --cask raspberry-pi-imager
```
O descarga desde https://www.raspberrypi.com/software/

En el Imager:
1. **OS**: Ubuntu Server 24.04 LTS (64-bit) — en la sección "Other general-purpose OS"
2. **Storage**: tu microSD
3. Haz clic en el icono de engranaje (⚙) **antes de grabar** y configura:
   - Hostname: `ave-vpc-rpi`
   - Usuario: `ubuntu` / contraseña (la que quieras, solo por si acaso)
   - Activar SSH: "Allow public-key authentication only"
   - Pega tu clave pública SSH (la misma que usas para Oracle Cloud)

Graba. Mete la tarjeta en la RPi, conecta el cable de red al router, enchúfala.

## Paso 2: Buscar la IP de la RPi en el router

Abre el router en http://192.168.1.1 → Home → LAN Devices (o WLAN Devices).
Busca `ave-vpc-rpi` o una MAC nueva. Anota la IP (ej. `192.168.1.150`).

Verifica que puedes entrar:
```bash
ssh ubuntu@192.168.1.150
```

## Paso 3: Port Forwarding en el router ZTE F6640

En el router: **Internet → Security → Port Forwarding**

Añade dos reglas:

| Nombre | Protocolo | Puerto externo | IP interna | Puerto interno |
|---|---|---|---|---|
| mlvpn-iphone | UDP | 5080 | 192.168.1.150 | 5080 |
| mlvpn-pixel | UDP | 5081 | 192.168.1.150 | 5081 |

> Reemplaza `192.168.1.150` con la IP real de tu RPi.
> Conviene asignarle una IP fija: en el router busca "DHCP Static" o reserva
> por MAC para que siempre tenga la misma IP.

## Paso 4: DDNS — resolver el problema de IP dinámica

La fibra de casa tiene IP pública **dinámica**: puede cambiar cuando el
router se reinicia o el ISP la renueva. El Mac en el AVE necesita un
hostname fijo que siempre apunte a tu IP actual.

**Cómo funciona DDNS**: un cliente (el router o un servicio en la RPi)
detecta cuándo cambia tu IP pública y actualiza automáticamente el registro
DNS del hostname. Así `tu-casa.duckdns.org` siempre apunta a tu IP actual,
aunque cambie cada semana.

### Opción A: DDNS nativo del router ZTE F6640 (recomendada)

El ZTE F6640 tiene soporte DDNS integrado. Ve a **Internet → DDNS**.

1. Registra un hostname gratuito en uno de los proveedores compatibles:
   - **DuckDNS** (https://www.duckdns.org) — más sencillo, gratuito
   - **No-IP** (https://www.noip.com) — también gratuito
2. En el router, introduce el hostname y el token/contraseña del proveedor
3. El router actualiza automáticamente la IP cada vez que cambia

**Ventaja sobre otras opciones**: funciona aunque la RPi esté apagada o
reiniciándose, porque es el propio router quien hace las actualizaciones.

### Opción B: ddclient en la RPi (alternativa)

`ddclient` es el cliente DDNS estándar de Linux, disponible en los repos
de Ubuntu desde hace décadas. Soporta DuckDNS, No-IP, Cloudflare y muchos más.

```bash
sudo apt install ddclient
```

Se configura en `/etc/ddclient.conf`. Ejemplo para DuckDNS:
```
protocol=duckdns
login=token
password=TU_TOKEN_AQUI
tu-hostname
```

Arranca como servicio systemd automáticamente. Útil si el router no tiene
soporte DDNS o prefieres tener el control en la RPi.

## Paso 5: Configurar y ejecutar el script de setup

Actualiza `config/env` con los valores de la RPi:

```bash
# RPi (añadir estas variables)
RPi_IP="192.168.1.150"      # IP local durante el setup
RPi_USER="ubuntu"
RPi_SSH_PORT="22"
```

Ejecuta el script desde el Mac:
```bash
./07-setup-rpi.sh
```

El script instala mlvpn (tarda 2-3 min en compilar en ARM), configura el
servidor y activa el servicio systemd.

## Paso 6: Configurar el Mac para conectar a la RPi

Una vez que el DDNS esté funcionando, cambia `VPS_IP` en `config/env`:

```bash
VPS_IP="tu-hostname.duckdns.org"
```

Regenera la configuración del Mac:
```bash
./03-setup-mac.sh
```

A partir de aquí, `./04-conectar.sh` funciona exactamente igual que con
el VPS de Oracle Cloud.

## Ventajas e inconvenientes frente a Oracle Cloud

| | RPi en casa | Oracle Cloud |
|---|---|---|
| Coste hardware | ~167€ (una sola vez) | 0€ |
| Coste mensual | 0€ | 0€ (Always Free) |
| Ancho de banda | Fibra (~600 Mbps) | Limitado (~480 Mbps) |
| Latencia | Baja (tu casa) | Baja (Madrid) |
| Disponibilidad | Depende de luz y router | Alta (Oracle SLA) |
| Setup | Más pasos (router, DDNS) | Automatizado con Terraform |
| Control | Total | Limitado |
