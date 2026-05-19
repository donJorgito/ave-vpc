### ave-vpc.REQ-NET-02 - Android compartiendo red por USB tethering

**Description:**

El dispositivo Android debe tener el USB tethering habilitado y estar
conectado al Mac por cable USB. macOS debe reconocerlo como una
interfaz de red dedicada (típicamente `en12`, configurable vía
`IFACE_PIXEL` en `config/env`).

**Parent Requirement:** ave-vpc.REQ-HW-03

**Acceptance Criteria:**

- `ipconfig getifaddr ${IFACE_PIXEL}` devuelve una IPv4 válida.
- `networksetup -listallhardwareports` lista la interfaz como
  Hardware Port asociado al Android.
