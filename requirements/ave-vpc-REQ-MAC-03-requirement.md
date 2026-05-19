### ave-vpc.REQ-MAC-03 - Ruta /32 anti-loop al VPS preferiendo enlaces móviles

**Description:**

Las rutas `route -ifscope` en macOS solo se aplican cuando el socket
saliente está atado con `IP_BOUND_IF`. Sockets normales del kernel
no las consultan, por lo que el tráfico UDP de mlvpn al VPS podría
caer en la ruta `0/1`/`128/1` del propio túnel y entrar en bucle.
`04-conectar.sh` añade una ruta `/32` al `VPS_IP` sin `-ifscope`
(más específica que `/1`) preferentemente vía un enlace móvil
(Pixel > iPhone > WiFi como fallback) para romper ese bucle.

**Parent Requirement:** ave-vpc.REQ-NET-03

**Acceptance Criteria:**

- Tras ejecutar `04-conectar.sh`, `netstat -rn -f inet` muestra una
  ruta `/32` regular al `VPS_IP` con gateway de uno de los enlaces
  móviles activos.
- `traceroute 8.8.8.8` desde el Mac sale por la interfaz del túnel
  (hop 1 es la IP del servidor mlvpn dentro del túnel).
