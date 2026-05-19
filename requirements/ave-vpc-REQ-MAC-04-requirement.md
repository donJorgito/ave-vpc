### ave-vpc.REQ-MAC-04 - Configuración del utun directamente desde 04-conectar.sh

**Description:**

mlvpn invoca el `statuscommand` mediante `priv_run_script` para
configurar la interfaz `tun` cuando los enlaces autentican. En
macOS este mecanismo no se ejecuta de forma fiable en el contexto
utun (el script no llega a ejecutarse o se ejecuta con env
incorrecto). Como workaround, `04-conectar.sh` detecta la interfaz
utun creada por mlvpn y configura su IP, gateway y MTU directamente
desde el script de orquestación.

**Parent Requirement:** ave-vpc.REQ-NET-03

**Acceptance Criteria:**

- Tras ejecutar `04-conectar.sh`, `ifconfig <utun>` muestra la IP
  `${TUN_MAC_IP}`, peer `${TUN_VPS_IP}` y MTU `${TUN_MTU}`.
- Las rutas `0.0.0.0/1` y `128.0.0.0/1` apuntan a la utun y todo el
  tráfico saliente pasa por el túnel.
