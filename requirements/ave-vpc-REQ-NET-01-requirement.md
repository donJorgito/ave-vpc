### ave-vpc.REQ-NET-01 - iPhone compartiendo red por USB tethering

**Description:**

El iPhone debe estar configurado en modo *Personal Hotspot* y
conectado al Mac por cable USB. macOS debe reconocerlo como una
interfaz de red dedicada (típicamente `en8`, configurable vía
`IFACE_IPHONE` en `config/env`).

**Parent Requirement:** ave-vpc.REQ-HW-02

**Acceptance Criteria:**

- `ipconfig getifaddr ${IFACE_IPHONE}` devuelve una IPv4 válida.
- `networksetup -listallhardwareports` lista la interfaz como
  Hardware Port asociado al iPhone.
