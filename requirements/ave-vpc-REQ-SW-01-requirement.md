### ave-vpc.REQ-SW-01 - macOS 13.0 o superior como SO del cliente

**Description:**

El sistema operativo del cliente debe ser macOS 13 (Ventura) o
posterior. Esto garantiza disponibilidad de las APIs nativas de utun y
del comportamiento estable de `route -ifscope` que el bonding necesita.

**Parent Requirement:** ave-vpc.REQ-HW-01

**Acceptance Criteria:**

- `sw_vers -productVersion` devuelve `13.x` o superior.
