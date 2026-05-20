### ave-vpc.REQ-VPS-07 - Puertos UDP del bonding abiertos en el servidor (5080, 5081, 5082)

**Description:**

Los enlaces del bonding mlvpn entran al servidor por puertos UDP
distintos: 5080 (iPhone), 5081 (Pixel) y 5082 (WiFi opcional). Los
tres deben estar abiertos en el firewall del SO del servidor; en
Oracle Cloud también en las Security Lists de la VCN; en la opción
RPi también en el port forwarding del router de casa.

**Mapeo de puerto público opcional:** la variable `MLVPN_PORT_3_REMOTE`
permite que el cliente conecte a un puerto público distinto al
`MLVPN_PORT_3` interno del servidor. Caso de uso: las redes públicas
restrictivas (WiFi del AVE, aeropuertos, hoteles, redes corporativas)
suelen filtrar puertos altos arbitrarios como 5082 pero dejan pasar
443/UDP (QUIC). Configurando `MLVPN_PORT_3_REMOTE="443"` y un mapeo
en el router (`WAN:443/UDP → RPi:5082`), el cliente atraviesa los
filtros sin tocar el core de mlvpn (que sigue escuchando en 5082).
Confirmado en vivo en el AVE 20/05/2026: tcpdump en el servidor
durante 5 s no recibió ningún paquete en 5082 desde el WiFi del tren,
mientras que 5080/5081 sí recibieron tráfico normalmente.

**Parent Requirement:** ave-vpc.REQ-VPS-05

**Acceptance Criteria:**

- `sudo ss -ulnp | grep mlvpn` muestra los tres puertos en escucha
  en el servidor: `5080`, `5081` y `5082`.
- `sudo ufw status` muestra ALLOW para `5080/udp`, `5081/udp` y
  `5082/udp` en el servidor.
- Si se configura `MLVPN_PORT_3_REMOTE` distinto de `MLVPN_PORT_3`,
  el router de casa hace port forwarding del puerto público
  (`MLVPN_PORT_3_REMOTE/udp`) hacia el puerto interno
  (`MLVPN_PORT_3/udp`) de la RPi.
- En la opción RPi, el router doméstico hace port forwarding de los
  tres puertos UDP internos (5080, 5081, 5082) a la IP local de la
  RPi.
