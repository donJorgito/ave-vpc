### ave-vpc.REQ-VPS-07 - Puertos UDP 5080-5082 abiertos

**Description:**

Los enlaces del bonding mlvpn entran al servidor por puertos UDP
distintos: 5080 (iPhone), 5081 (Pixel), 5082 (WiFi opcional). Los
tres deben estar abiertos en el firewall del SO; en Oracle Cloud
también en las Security Lists de la VCN; en la opción RPi también
en el port forwarding del router de casa.

**Parent Requirement:** ave-vpc.REQ-VPS-05

**Acceptance Criteria:**

- `sudo ss -ulnp | grep mlvpn` muestra los tres puertos en escucha.
- `sudo ufw status` muestra ALLOW para `5080/udp`, `5081/udp` y
  `5082/udp`.
