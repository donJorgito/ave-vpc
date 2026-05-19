### ave-vpc.REQ-SW-02 - Xcode Command Line Tools instalados

**Description:**

La compilación de mlvpn en el Mac requiere el toolchain estándar de
desarrollo: `clang`, `make`, `ld` y headers del sistema. macOS los
distribuye a través de los Xcode Command Line Tools (CLT). Versión
mínima recomendada: 14.0.

**Parent Requirement:** ave-vpc.REQ-SW-01

**Acceptance Criteria:**

- `xcode-select -p` devuelve una ruta válida (no error).
- `clang --version` se ejecuta sin error.
