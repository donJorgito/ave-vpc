### ave-vpc.REQ-NET-08 - Detección de "red de casa" por IP pública

**Description:**

El pre-flight check de "red de casa" en `04-conectar.sh` debe detectar
si el Mac está saliendo a Internet por el mismo NAT que la RPi
(condición que causa hairpin NAT en el 3er enlace WiFi). La detección
no puede basarse en la subred local (`192.168.1.x` es el rango por
defecto de la mayoría de routers domésticos, hoteles y cafeterías) ni
en un ping a la IP local de la RPi (cualquier dispositivo en la red
ajena con la misma IP da falso positivo). En su lugar, el script
compara la IP pública saliendo por `IFACE_WIFI` (consultando un
servicio HTTP externo desde esa interfaz concreta) con la IP pública
del DDNS de la RPi (`VPS_IP`). Si coinciden, la WiFi se omite del
bonding con aviso "red de casa".

**Parent Requirement:** ave-vpc.REQ-NET-06

**Acceptance Criteria:**

- `04-conectar.sh` define una función `get_public_ip_via_iface()` que
  consulta secuencialmente `https://api.ipify.org`,
  `https://ifconfig.me/ip` y `https://icanhazip.com` con
  `curl --interface ${IFACE_WIFI} --max-time 2`, devuelve la primera
  respuesta que sea una IPv4 válida y string vacío si todas fallan.
- `04-conectar.sh` define una función `resolve_vps_public_ip()` que
  devuelve `VPS_IP` tal cual si ya es una IP literal, y en caso
  contrario hace `dig +short +time=2 +tries=1 ${VPS_IP} A` y devuelve
  la última línea que sea una IPv4 válida.
- `check_wifi_eligibility()` invoca ambas funciones después del check
  de captive portal y antes del anti-bind-stale; si las dos devuelven
  IPs no vacías y son iguales, sale con mensaje "red de casa" y
  retorno 1.
- El script ya no contiene la heurística antigua (`rpi_subnet`,
  `wifi_subnet`, `ping … "${RPi_IP}"`) ni hace asunciones sobre la
  subred local del WiFi.
- Si los dos servicios devuelven IPs distintas (caso oficina, hotel,
  AVE, casa de un amigo) o si alguno falla por captive todavía no
  autenticado, el check no clasifica como casa y deja que mlvpn use
  el WiFi normalmente (los siguientes checks se encargan de filtrar
  fallos de UDP).
- El comportamiento es independiente de la subred local del WiFi y
  no requiere variables nuevas en `config/env`.
