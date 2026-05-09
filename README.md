# ave-vpc — Bonding de conexiones móviles para el AVE

[![Licencia: MIT](https://img.shields.io/badge/Licencia-MIT-blue.svg)](LICENSE)
[![Shell: bash](https://img.shields.io/badge/Shell-bash-green.svg)](https://www.gnu.org/software/bash/)
[![Plataforma: macOS](https://img.shields.io/badge/Plataforma-macOS-lightgrey.svg)](https://www.apple.com/macos/)

Agrega múltiples conexiones móviles en tiempo real usando [mlvpn](https://github.com/zehome/MLVPN) y un VPS gratuito en Oracle Cloud. Diseñado para trayectos de tren de larga distancia donde la cobertura es inestable y las videollamadas se interrumpen.

**El resultado:** si un enlace móvil cae, el tráfico continúa por el otro sin corte visible. Si ambos funcionan, el ancho de banda se suma.

---

## Tabla de contenidos

- [Problema que resuelve](#problema-que-resuelve)
- [Arquitectura](#arquitectura)
- [Bonding vs Failover](#bonding-vs-failover)
- [Requisitos](#requisitos)
- [Instalación](#instalación)
- [Uso diario](#uso-diario)
- [Estructura del proyecto](#estructura-del-proyecto)
- [Configuración](#configuración)
- [Opción: tres enlaces](#opción-tres-enlaces)
- [Alternativas al VPS gratuito](#alternativas-al-vps-gratuito)
- [Solución de problemas](#solución-de-problemas)
- [Contribuir](#contribuir)
- [Licencia](#licencia)

---

## Problema que resuelve

En el AVE (Orihuela/Murcia → Madrid, y vuelta), la cobertura móvil es inestable. Cada vez que el tren pasa por un túnel o cambia de antena, la conexión se interrumpe. Con una única SIM:

- La VPN corporativa se cae y hay que reconectar manualmente
- Las videollamadas (Teams, Meet, Zoom) se cortan
- El streaming se para

Con dos SIMs de operadoras distintas y este proyecto, los cortes de una se cubren con la otra.

---

## Arquitectura

```
                         INTERNET
                            │
                    ┌───────┴───────┐
                    │  VPS Oracle   │
                    │  Cloud Madrid │
                    │ 10.10.10.1/24 │
                    │   mlvpn0      │
                    └───────┬───────┘
                           /│\
              UDP:5080 ───/ │ \─── UDP:5081
                           / \
          ┌───────────────┐   ┌───────────────┐
          │ iPhone        │   │ Pixel Android │
          │ Movistar      │   │ Yoigo         │
          │ Hotspot WiFi  │   │ USB Tethering │
          └───────┬───────┘   └───────┬───────┘
                  └─────────┬─────────┘
                       ┌────┴────┐
                       │   Mac   │
                       │ mlvpn0  │
                       │10.10.10.2│
                       └─────────┘
                            │
                   VPN corporativa /
                   Videollamadas /
                   Navegación
```

mlvpn distribuye los paquetes entre los dos enlaces activos simultáneamente. El VPS los reensambla en orden y los envía a internet. El tráfico de vuelta sigue el mismo camino inverso.

---

## Bonding vs Failover

| | Failover | Bonding (este proyecto) |
|--|----------|--------------------------|
| Interfaces activas | 1 (la otra espera) | Todas a la vez |
| Ancho de banda efectivo | max(A, B) | A + B |
| Si cae un enlace | Corte de 2–6 s | Sin corte visible |
| Distribución de paquetes | Todo por un camino | Repartido entre todos |

---

## Requisitos

### Hardware

| Dispositivo | Función | Notas |
|-------------|---------|-------|
| Mac (macOS 13+) | Cliente, ejecuta los scripts | Apple Silicon o Intel |
| iPhone con SIM | Enlace 1 — hotspot WiFi | Cualquier operadora |
| Android con SIM | Enlace 2 — tethering USB | Mejor si es operadora distinta |
| Cable USB-A/C | Conectar el Android al Mac | |

### Software en el Mac

- **Homebrew** — [brew.sh](https://brew.sh)
- **Xcode Command Line Tools** — `xcode-select --install`
- **Terraform** — `brew install terraform`
- **Git** — incluido en Xcode CLT

Los scripts instalan automáticamente el resto de dependencias (libev, libsodium, etc.).

### VPS

- Cuenta en [Oracle Cloud Free Tier](https://cloud.oracle.com) — gratuito de forma permanente
- Ubuntu 24.04 LTS
- IP pública IPv4
- Puertos UDP 5080–5082 abiertos (Terraform los configura automáticamente)

---

## Instalación

### 1. Clonar el repositorio

```bash
git clone https://github.com/<tu-usuario>/ave-vpc.git
cd ave-vpc
```

### 2. Configurar variables

```bash
cp config/env.example config/env
# Edita config/env — al menos VPS_IP y los IFACE_* (paso 6 los detecta automáticamente)
```

### 3. Provisionar el VPS automáticamente

Los servidores ARM gratuitos de Oracle tienen lista de espera. El script lo intenta cada hora hasta conseguirlo (se para solo cuando lo logra).

Primero configura las credenciales OCI siguiendo [`docs/oracle-cloud-setup.md`](docs/oracle-cloud-setup.md), luego:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edita terraform/terraform.tfvars con tu tenancy OCID

# Inicia el proceso automático
./06-provision-vps.sh --setup-cron

# Seguir el progreso
tail -f generated/provision.log
```

Cuando el VPS se crea, el script actualiza `config/env` con la IP y envía una notificación macOS.

> Si no quieres esperar, puedes usar un VPS de pago desde €2/mes. Ver [Alternativas](#alternativas-al-vps-gratuito).

### 4. Generar el secreto compartido

```bash
./01-generar-secreto.sh
```

Crea `keys/mlvpn.secret`. **Nunca lo subas a git** (ya está en `.gitignore`).

### 5. Configurar el VPS

```bash
./02-setup-vps.sh
```

Se conecta por SSH y hace todo: instala dependencias, compila mlvpn, configura NAT/IP forwarding y crea el servicio systemd. Tarda ~5 minutos.

### 6. Configurar el Mac

```bash
./03-setup-mac.sh
```

Instala dependencias con Homebrew, compila mlvpn y genera `generated/mlvpn.conf`.

### 7. Detectar interfaces (una vez, con los móviles conectados)

```bash
# Con el iPhone en hotspot WiFi y el Android conectado por USB con tethering activo:
./00-detectar-interfaces.sh
```

Detecta automáticamente las interfaces de red y actualiza `config/env`.

### 8. Verificar el setup

```bash
./tests/verificar-setup.sh
```

Comprueba que todo está correcto antes del primer viaje.

---

## Uso diario

### Antes de subir al tren

1. Activa el hotspot WiFi del iPhone y conéctate desde el Mac
2. Conecta el Android por USB y activa el tethering

### En el tren

```bash
./04-conectar.sh
```

Verifica que funciona:

```bash
ping 10.10.10.1        # debe responder el VPS
curl ifconfig.me       # debe mostrar la IP del VPS, no la tuya
```

Monitoriza el bonding en tiempo real:

```bash
tail -f generated/mlvpn.log
```

### Al llegar

```bash
./05-desconectar.sh
```

---

## Estructura del proyecto

```
ave-vpc/
├── 00-detectar-interfaces.sh   # Detecta interfaces iPhone/Android automáticamente
├── 01-generar-secreto.sh       # Genera el secreto de cifrado mlvpn
├── 02-setup-vps.sh             # Configura el VPS (ejecutar una vez)
├── 03-setup-mac.sh             # Configura el Mac (ejecutar una vez)
├── 04-conectar.sh              # Conectar en el tren
├── 05-desconectar.sh           # Desconectar al llegar
├── 06-provision-vps.sh         # Provisiona el VPS en Oracle Cloud (auto-retry)
├── config/
│   └── env.example             # Plantilla de configuración
├── docs/
│   └── oracle-cloud-setup.md   # Guía para obtener credenciales OCI
├── generated/                  # Archivos en tiempo de ejecución (gitignored)
│   ├── mlvpn.conf              # Configuración del cliente mlvpn
│   ├── mlvpn.log               # Log de mlvpn
│   └── provision.log           # Log del proceso de provisión
├── keys/                       # Secreto compartido (gitignored)
│   └── mlvpn.secret
├── requirements/
│   └── REQ.md                  # Requisitos del sistema
├── terraform/
│   ├── main.tf                 # Infraestructura Oracle Cloud
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
└── tests/
    └── verificar-setup.sh      # Tests de verificación del setup
```

---

## Configuración

Todas las variables viven en `config/env` (creado a partir de `config/env.example`).

| Variable | Descripción | Valor por defecto |
|----------|-------------|-------------------|
| `VPS_IP` | IP pública del VPS | *(rellenar)* |
| `VPS_USER` | Usuario SSH del VPS | `ubuntu` |
| `VPS_SSH_PORT` | Puerto SSH | `22` |
| `MLVPN_PORT_1` | Puerto UDP enlace 1 (iPhone) | `5080` |
| `MLVPN_PORT_2` | Puerto UDP enlace 2 (Android) | `5081` |
| `TUN_VPS_IP` | IP del VPS en el túnel | `10.10.10.1` |
| `TUN_MAC_IP` | IP del Mac en el túnel | `10.10.10.2` |
| `TUN_MTU` | MTU del túnel | `1440` |
| `IFACE_IPHONE` | Interfaz WiFi (hotspot iPhone) | `en0` |
| `IFACE_PIXEL` | Interfaz USB Android | `en5` |

---

## Opción: tres enlaces

Para máxima redundancia, conecta iPhone por USB, Android por USB, y el WiFi del Mac al WiFi del tren:

1. Conecta ambos móviles por USB con tethering activo
2. Conecta el WiFi del Mac al WiFi del tren
3. Añade en `config/env`:
   ```bash
   MLVPN_PORT_3="5082"
   IFACE_TREN="en0"   # o la interfaz WiFi del tren
   ```
4. Añade un tercer enlace en la config de mlvpn (Mac y VPS)

---

## Alternativas al VPS gratuito

Si Oracle Cloud no tiene capacidad disponible en tu región, estos proveedores tienen servidores en España o Europa con precios muy bajos:

| Proveedor | Precio/mes | Localización | Nota |
|-----------|-----------|--------------|------|
| [Vultr](https://vultr.com) | $3.50 | **Madrid**, Amsterdam, Frankfurt... | Latencia mínima para el tren |
| [IONOS](https://ionos.es) | $2.00 | **España**, Alemania, UK | El más barato con servidor en España |
| [Hetzner](https://hetzner.com) | ~€3–4 | Núremberg, Falkenstein, Helsinki | Muy fiable |
| [Scaleway](https://scaleway.com) | €4.99 | París, Amsterdam | |

Para usarlos: crea el VPS manualmente (Ubuntu 24.04, IP pública) y asegúrate de abrir los puertos TCP 22 y UDP 5080-5082 en su firewall. Luego pon la IP en `VPS_IP` de `config/env`. Con Oracle Cloud esto lo hace Terraform automáticamente.

---

## Solución de problemas

**El túnel se crea pero no hay internet**
```bash
# Verificar IP forwarding en el VPS
ssh ubuntu@$VPS_IP "sudo sysctl net.ipv4.ip_forward"
# Debe devolver: net.ipv4.ip_forward = 1

# Verificar NAT
ssh ubuntu@$VPS_IP "sudo iptables -t nat -L POSTROUTING -n"
# Debe haber una regla MASQUERADE
```

**mlvpn no conecta (timeout)**
```bash
# Ver logs en tiempo real
tail -f generated/mlvpn.log

# Verificar que los puertos UDP están accesibles
nc -uzv $VPS_IP 5080 && echo "5080 OK"
nc -uzv $VPS_IP 5081 && echo "5081 OK"
```

**El Android no se detecta como interfaz**
```bash
# Asegúrate de que el tethering USB está activo en el Android
# Luego ejecuta:
networksetup -listallhardwareports
# Busca una entrada nueva que aparezca al conectar el cable
```

**El cron de provisión no funciona**
```bash
# Verificar que está registrado
crontab -l | grep ave-vpc

# Ver log
tail -20 generated/provision.log

# Lanzar manualmente para depurar
NO_JITTER=1 ./06-provision-vps.sh
```

---

## Contribuir

Lee [`CONTRIBUTING.md`](CONTRIBUTING.md) antes de abrir un PR.

---

## Licencia

[MIT](LICENSE)
