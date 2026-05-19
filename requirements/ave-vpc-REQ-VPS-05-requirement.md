### ave-vpc.REQ-VPS-05 - IP pública IPv4 estática (o DDNS)

**Description:**

El cliente del bonding debe poder resolver una dirección IPv4 fija
del servidor para abrir las conexiones UDP de mlvpn. En Oracle Cloud
se usa la IP pública de la instancia (estática). En la opción RPi se
usa un DDNS (`200bares.dedyn.io`) actualizado por cron en la propia
RPi y resuelto vía DNS público en el cliente.

**Parent Requirement:** N/A

**Acceptance Criteria:**

- El cliente resuelve `VPS_IP` a una dirección IPv4 alcanzable desde
  internet.
- La IP no cambia durante la sesión del bonding.
