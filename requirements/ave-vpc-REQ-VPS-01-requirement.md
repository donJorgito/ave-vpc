### ave-vpc.REQ-VPS-01 - Sistema operativo Ubuntu 26.04 LTS

**Description:**

El servidor mlvpn (VPS Oracle Cloud o Raspberry Pi en casa) debe usar
Ubuntu Server 26.04 LTS. Esta es la versión validada con los scripts
`02-setup-vps.sh` y `07-setup-rpi.sh`, que dependen de `apt`,
`systemd`, `ufw` y la versión de libsodium incluida.

**Parent Requirement:** N/A

**Acceptance Criteria:**

- `cat /etc/os-release | grep VERSION_ID` devuelve `"26.04"`.
- `lsb_release -is` devuelve `Ubuntu`.
