### ave-vpc.REQ-VPS-03 - RAM mínima 512 MB

**Description:**

mlvpn server tiene huella de memoria muy baja (<10 MB residentes).
512 MB de RAM cubren el sistema operativo + mlvpn + ufw + sshd con
margen.

**Parent Requirement:** N/A

**Acceptance Criteria:**

- `free -m` muestra al menos 512 MB de RAM total.
- El proceso `mlvpn` se mantiene estable bajo el caudal del bonding.
