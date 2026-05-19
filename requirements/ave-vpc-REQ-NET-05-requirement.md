### ave-vpc.REQ-NET-05 - Soporte de WiFi corporativa o redes con captive portal

**Description:**

Cuando el Mac está conectado a una WiFi con restricciones (corporativa
con UDP filtrado, hotel con captive portal, AVE pre-autenticación), el
flujo del bonding no debe verse interrumpido. La detección y manejo de
estos casos lo implementa REQ-NET-06.

**Parent Requirement:** ave-vpc.REQ-NET-03

**Acceptance Criteria:**

- Si la WiFi está en captive portal, el bonding sigue con los enlaces
  móviles sin error.
- Si la WiFi tiene IP pero el UDP saliente está bloqueado (típico
  corporativo), el link `links.wifi` queda en `AUTH_PENDING` y los
  otros enlaces siguen autenticando normalmente.
