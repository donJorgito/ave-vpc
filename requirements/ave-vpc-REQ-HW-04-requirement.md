### ave-vpc.REQ-HW-04 - Cables USB de datos para ambos móviles

**Description:**

Tanto el iPhone (Personal Hotspot por USB) como el Android (USB
tethering) necesitan un cable USB de **datos** entre el móvil y el Mac.
Los cables solo de carga no exponen los endpoints USB necesarios para
que macOS cree la interfaz de red virtual, y por tanto no permiten el
tethering aunque la opción esté activada en el móvil.

Tipos según móvil:

- iPhone: USB-C ↔ USB-C (iPhone 15+) o Lightning ↔ USB-C/USB-A.
- Pixel / Android moderno: USB-C ↔ USB-C o USB-C ↔ USB-A.

**Parent Requirement:** ave-vpc.REQ-HW-02, ave-vpc.REQ-HW-03

**Acceptance Criteria:**

- Al conectar cada móvil por su cable, el Mac detecta el dispositivo y
  expone la interfaz de tethering en `networksetup -listallhardwareports`.
- Cada interfaz pasa a estado `active` y recibe IP por DHCP cuando el
  tethering está habilitado en el móvil correspondiente
  (rango `172.20.10.x` para iPhone, `192.168.42.x` / `192.168.43.x` para
  Android).
