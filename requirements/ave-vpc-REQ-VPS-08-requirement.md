### ave-vpc.REQ-VPS-08 - IP forwarding habilitado

**Description:**

El servidor enruta el tráfico del túnel hacia internet via NAT
masquerading. Sin IP forwarding del kernel, los paquetes recibidos
por la interfaz del túnel se descartan en lugar de reenviarse.

**Parent Requirement:** ave-vpc.REQ-VPS-01

**Acceptance Criteria:**

- `sysctl net.ipv4.ip_forward` devuelve `1`.
- `/etc/sysctl.d/99-mlvpn.conf` contiene
  `net.ipv4.ip_forward = 1` para persistencia entre reinicios.
