### ave-vpc.REQ-SW-06 - libev 4.33 o superior

**Description:**

mlvpn usa libev como bucle de eventos. La versión mínima soportada por
el código fuente actual de mlvpn es 4.33. Se instala vía Homebrew.

**Parent Requirement:** ave-vpc.REQ-SW-03

**Acceptance Criteria:**

- `brew list libev --versions` devuelve `4.33` o superior.
- mlvpn enlaza correctamente contra `libev` en
  `$(brew --prefix libev)/lib`.
