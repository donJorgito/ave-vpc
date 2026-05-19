### ave-vpc.REQ-HW-01 - Mac con macOS 13 (Ventura) o superior

**Description:**

El cliente del bonding mlvpn debe ejecutarse en un Mac con macOS 13
(Ventura) o versión posterior. Versiones anteriores carecen del soporte
nativo de utun (SYSPROTO_CONTROL + UTUN_CONTROL_NAME) que necesita el
parche aplicado en `patches/tuntap_darwin_utun.c` y de las llamadas a
`route -ifscope` que se utilizan en `04-conectar.sh`.

**Parent Requirement:** N/A

**Acceptance Criteria:**

- `sw_vers -productVersion` devuelve un valor cuyo componente mayor es
  igual o superior a 13.
- El binario `mlvpn` compilado con el parche utun arranca sin errores en
  esa versión.
