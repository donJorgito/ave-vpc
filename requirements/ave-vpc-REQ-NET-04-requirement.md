### ave-vpc.REQ-NET-04 - IP pública sin CGNAT en la conexión doméstica

**Description:**

En la opción B (RPi en casa como servidor mlvpn), el ISP residencial
debe ofrecer una IP pública IPv4 sin CGNAT. Con CGNAT (rangos
`100.64.0.0/10` en la WAN del router) el port forwarding no funciona
porque el tráfico entrante nunca llega al router del usuario.

**Parent Requirement:** ave-vpc.REQ-VPS-05

**Acceptance Criteria:**

- La IP WAN del router doméstico no está en el rango `100.64.0.0/10`.
- El port forwarding configurado en el router es alcanzable desde
  internet (tests externos a UDP 5080-5082 llegan a la RPi). Si se
  configura `MLVPN_PORT_3_REMOTE` (ver REQ-VPS-07), también el puerto
  público mapeado (típicamente 443/UDP) debe llegar a la RPi.
