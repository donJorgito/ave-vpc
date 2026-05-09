# Oracle Cloud Free Tier: Crear el VPS

Estas son las instrucciones para crear la VM gratis en Oracle Cloud que usaras
como servidor WireGuard. La VM ARM del free tier es gratis **para siempre**
(no es trial de 30 dias).

## Que obtienes gratis

- 1 VM ARM (Ampere A1): hasta 4 OCPUs y 24 GB RAM (nosotros con 1 OCPU y 1 GB basta)
- 200 GB de almacenamiento
- 10 TB de transferencia mensual
- IP publica gratis

## Pasos

### 1. Crear cuenta

1. Ve a https://cloud.oracle.com/
2. Crea una cuenta (necesitas tarjeta de credito pero NO te cobran)
3. Elige region: **eu-madrid-1** o **eu-frankfurt-1** (la mas cercana a tu ruta AVE)

### 2. Crear la VM

1. Menu > Compute > Instances > Create Instance
2. Configuracion:
   - **Name**: `ave-wireguard`
   - **Image**: Ubuntu 22.04 (o la LTS mas reciente)
   - **Shape**: VM.Standard.A1.Flex (ARM), 1 OCPU, 1 GB RAM
   - **Network**: Crear nueva VCN o usar la default
   - **SSH key**: Pega tu clave publica (`cat ~/.ssh/id_ed25519.pub`)
3. Click "Create"
4. Espera ~2 minutos a que arranque
5. Apunta la **IP publica** que te asigna (la usaras en config/env)

### 3. Abrir puerto WireGuard en la VCN

Oracle Cloud tiene un firewall a nivel de red (Security Lists) ademas del
firewall del SO. Hay que abrir el puerto en ambos.

1. Menu > Networking > Virtual Cloud Networks
2. Click en tu VCN
3. Click en "Security Lists" > "Default Security List"
4. "Add Ingress Rules":
   - **Source CIDR**: `0.0.0.0/0`
   - **IP Protocol**: UDP
   - **Destination Port Range**: `51820` (o el que hayas puesto en WG_PORT)
5. Click "Add Ingress Rules"

### 4. Verificar acceso SSH

```bash
# Desde tu Mac:
ssh ubuntu@<IP_PUBLICA>

# Si conecta, ya puedes ejecutar 02-setup-vps.sh
```

### 5. Configurar config/env

```bash
cd ~/projects/ave-vpc
cp config/env.example config/env
# Editar config/env con tu IP y datos
```

## Troubleshooting

### "Out of capacity" al crear la VM ARM

El free tier ARM es muy demandado. Si te da este error:
- Intenta a diferentes horas (madrugada suele funcionar)
- Prueba con otro Availability Domain si tu region tiene varios
- Cambia de region

### No puedo hacer SSH

- Verifica que tu Security List tiene una regla de ingress para TCP 22
- Verifica que la IP publica esta asignada (Instances > tu VM > "Attached VNICs")
- Prueba: `ssh -v ubuntu@<IP>` para ver donde falla

### El ping al VPS no funciona por WireGuard

- Verifica que el puerto UDP esta abierto en Security Lists
- Verifica que iptables no esta bloqueando en el VPS: `sudo iptables -L -n`
- Verifica que WireGuard esta corriendo: `sudo wg show`
