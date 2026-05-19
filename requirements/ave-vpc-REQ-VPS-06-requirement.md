### ave-vpc.REQ-VPS-06 - Puerto TCP 22 abierto para SSH

**Description:**

El acceso administrativo al servidor (provisión, debug, restart) se
hace por SSH. El puerto TCP 22 (o el alternativo configurado en
`VPS_SSH_PORT`, 2222 en la opción RPi) debe estar abierto en el
firewall del SO y accesible desde la IP pública.

**Parent Requirement:** ave-vpc.REQ-VPS-05

**Acceptance Criteria:**

- `ssh -p ${VPS_SSH_PORT} ${VPS_USER}@${VPS_IP}` establece sesión sin
  timeout.
- `sudo ufw status | grep -E "22|${VPS_SSH_PORT}"` muestra ALLOW.
