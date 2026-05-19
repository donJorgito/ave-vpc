### ave-vpc.REQ-SW-07 - libsodium 1.0.18 o superior

**Description:**

mlvpn usa libsodium para el cifrado del túnel (ChaCha20-Poly1305).
Versión mínima: 1.0.18. Se instala vía Homebrew.

**Parent Requirement:** ave-vpc.REQ-SW-03

**Acceptance Criteria:**

- `brew list libsodium --versions` devuelve `1.0.18` o superior.
- mlvpn enlaza correctamente contra `libsodium` en
  `$(brew --prefix libsodium)/lib`.
