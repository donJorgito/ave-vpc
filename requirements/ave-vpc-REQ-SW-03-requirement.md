### ave-vpc.REQ-SW-03 - Homebrew instalado

**Description:**

Las dependencias de compilación de mlvpn (libev, libsodium, autoconf,
automake, libtool, pkg-config) se instalan vía Homebrew. Versión
mínima recomendada: 4.0.

**Parent Requirement:** ave-vpc.REQ-SW-01

**Acceptance Criteria:**

- `brew --version` se ejecuta sin error.
- `brew list libev libsodium` reporta ambas como instaladas tras
  ejecutar `03-setup-mac.sh`.
