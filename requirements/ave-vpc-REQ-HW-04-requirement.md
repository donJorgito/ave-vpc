### ave-vpc.REQ-HW-04 - Cable USB compatible con el dispositivo Android

**Description:**

Para el USB tethering del Android se necesita un cable USB de datos
compatible con el dispositivo. Cables solo de carga no exponen los
endpoints USB necesarios para que el sistema operativo cree la interfaz
de red virtual.

**Parent Requirement:** ave-vpc.REQ-HW-03

**Acceptance Criteria:**

- Al conectar el Android por el cable, el Mac detecta el dispositivo y
  expone la interfaz de tethering en `networksetup -listallhardwareports`.
- La interfaz pasa a estado `active` cuando el USB tethering está
  habilitado en el Android.
