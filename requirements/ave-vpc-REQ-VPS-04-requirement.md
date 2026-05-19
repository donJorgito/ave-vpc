### ave-vpc.REQ-VPS-04 - Disco mínimo 10 GB

**Description:**

10 GB cubren Ubuntu Server, el toolchain de compilación de mlvpn y
los logs de systemd con margen. No se almacenan datos de usuario en
el VPS (es un relay de paquetes).

**Parent Requirement:** ave-vpc.REQ-VPS-01

**Acceptance Criteria:**

- `df -BG /` muestra al menos 10 GB de tamaño total en el filesystem
  raíz.
