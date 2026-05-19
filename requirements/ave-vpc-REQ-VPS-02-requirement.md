### ave-vpc.REQ-VPS-02 - CPU mínima 1 vCPU

**Description:**

mlvpn server cifra/descifra paquetes con ChaCha20-Poly1305 y consume
poca CPU. Una sola vCPU es suficiente para el caudal del bonding
sobre 4G/5G (~50-150 Mbps).

**Parent Requirement:** N/A

**Acceptance Criteria:**

- `nproc` devuelve `1` o más.
- Bajo carga del túnel, el uso de CPU del proceso `mlvpn` no satura
  un core durante el trayecto AVE Orihuela-Madrid.
