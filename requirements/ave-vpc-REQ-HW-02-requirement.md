### ave-vpc.REQ-HW-02 - iPhone con plan de datos activo

**Description:**

Uno de los dos enlaces móviles del bonding proviene de un iPhone que
comparte conexión por USB tethering. El plan de datos del operador debe
estar activo y permitir el uso del Personal Hotspot mientras el iPhone
está conectado al Mac por cable USB-C / Lightning.

**Parent Requirement:** N/A

**Acceptance Criteria:**

- Con el iPhone conectado por USB y el Personal Hotspot habilitado, el
  Mac muestra una interfaz de red nueva (típicamente `en8`).
- `ipconfig getifaddr <iface>` devuelve una dirección IPv4 asignada por
  DHCP del operador (rango típico `172.20.10.x` con Movistar).
