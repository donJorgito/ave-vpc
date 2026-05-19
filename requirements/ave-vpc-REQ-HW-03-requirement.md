### ave-vpc.REQ-HW-03 - Dispositivo Android con plan de datos activo

**Description:**

El segundo enlace móvil del bonding proviene de un dispositivo Android
(Pixel 6 Pro en este proyecto) que comparte conexión por USB tethering.
El plan de datos del operador debe estar activo y el USB tethering
habilitado en los ajustes del sistema.

**Parent Requirement:** N/A

**Acceptance Criteria:**

- Con el Android conectado por USB y el USB tethering habilitado, el Mac
  muestra una interfaz de red nueva (típicamente `en12`).
- `ipconfig getifaddr <iface>` devuelve una dirección IPv4 asignada por
  DHCP (rango típico `10.215.43.x` con Yoigo).
