### ave-vpc.REQ-VPS-09 - Latencia al trayecto inferior a 50 ms

**Description:**

La latencia ida y vuelta entre el cliente y el servidor afecta al
desempeño del bonding y a la usabilidad de VPNs corporativas y
videollamadas que pasen por el túnel. Recomendado: servidor
ubicado en España o Europa Occidental con RTT < 50 ms desde el AVE
Orihuela-Madrid.

**Parent Requirement:** ave-vpc.REQ-VPS-05

**Acceptance Criteria:**

- `ping -c 5 ${VPS_IP}` desde un enlace móvil estable reporta
  latencia media inferior a 50 ms cuando hay buena cobertura.
