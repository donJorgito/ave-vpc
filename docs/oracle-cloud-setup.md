# Oracle Cloud Free Tier: crear el VPS

Estas son las instrucciones para crear la VM gratis en Oracle Cloud que usarás
como servidor **mlvpn**. La VM ARM del free tier es gratis **para siempre**
(no es trial de 30 días).

> Si prefieres Raspberry Pi en casa, ver [`docs/rpi-setup.md`](rpi-setup.md).
> Si quieres provisionar la VM automáticamente (Terraform + retry cron), usar
> directamente `06-provision-vps.sh` desde el Mac y saltarse esta guía.

## Qué obtienes gratis

- 1 VM ARM (Ampere A1): hasta 4 OCPUs y 24 GB RAM (con 1 OCPU y 1 GB basta)
- 200 GB de almacenamiento
- 10 TB de transferencia mensual
- IP pública gratis

## Pasos

### 1. Crear cuenta

1. Ve a https://cloud.oracle.com/
2. Crea una cuenta (necesitas tarjeta de crédito pero NO te cobran)
3. Elige región: **eu-madrid-1** o **eu-frankfurt-1** (la más cercana a la
   ruta AVE)

### 2. Crear la VM

1. Menu > Compute > Instances > Create Instance
2. Configuración:
   - **Name**: `ave-vpc-server`
   - **Image**: Ubuntu Server 26.04 LTS (la versión validada con los scripts;
     si no estuviera disponible aún en tu región, usa la LTS más reciente)
   - **Shape**: VM.Standard.A1.Flex (ARM), 1 OCPU, 1 GB RAM
   - **Network**: crear nueva VCN o usar la default
   - **SSH key**: pega tu clave pública (`cat ~/.ssh/id_ed25519.pub`)
3. Click "Create"
4. Espera ~2 minutos a que arranque
5. Apunta la **IP pública** que te asigna (la usarás en `config/env`)

### 3. Abrir los puertos mlvpn en la VCN

Oracle Cloud tiene un firewall a nivel de red (Security Lists) además del
firewall del SO. Hay que abrir los puertos en ambos.

mlvpn escucha en tres puertos UDP — uno por enlace:

| Puerto | Enlace |
|--------|--------|
| 5080/UDP | iPhone (Movistar) |
| 5081/UDP | Pixel (Yoigo) |
| 5082/UDP | WiFi del tren (opcional) |

1. Menu > Networking > Virtual Cloud Networks
2. Click en tu VCN
3. Click en "Security Lists" > "Default Security List"
4. "Add Ingress Rules" — añade una regla con todo el rango:
   - **Source CIDR**: `0.0.0.0/0`
   - **IP Protocol**: UDP
   - **Destination Port Range**: `5080-5082`
5. Click "Add Ingress Rules"

Si prefieres tres reglas separadas (una por puerto), también vale.

### 4. Verificar acceso SSH

```bash
# Desde tu Mac:
ssh ubuntu@<IP_PUBLICA>

# Si conecta, ya puedes ejecutar 02-setup-vps.sh
```

### 5. Configurar `config/env`

```bash
cd ~/projects/ave-vpc
cp config/env.example config/env
# Editar config/env con tu IP y datos
```

## Troubleshooting

### "Out of capacity" al crear la VM ARM

El free tier ARM es muy demandado. Si te da este error:
- Intenta a diferentes horas (madrugada suele funcionar)
- Prueba con otro Availability Domain si tu región tiene varios
  (`eu-madrid-1` solo tiene AD-0)
- Cambia de región
- Usa `06-provision-vps.sh` que automatiza el retry cada hora con cron

### No puedo hacer SSH

- Verifica que tu Security List tiene una regla de ingress para TCP 22
- Verifica que la IP pública está asignada (Instances > tu VM > "Attached VNICs")
- Prueba: `ssh -v ubuntu@<IP>` para ver dónde falla

### El bonding mlvpn no levanta

- Verifica que los puertos UDP 5080-5082 están abiertos en Security Lists
- Verifica que `ufw` no está bloqueando en el VPS:
  `sudo ufw status` — debe permitir 5080:5082/udp
- Verifica que mlvpn está corriendo: `sudo systemctl status mlvpn`
- Comprueba que el servidor escucha: `sudo ss -ulnp | grep mlvpn`
