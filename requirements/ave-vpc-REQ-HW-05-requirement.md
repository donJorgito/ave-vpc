### ave-vpc.REQ-HW-05 - SIMs de operadoras distintas en los dos móviles

**Description:**

Para que el bonding aporte resiliencia real, los dos enlaces móviles
deben ser de operadores distintos. Si ambas SIMs son del mismo
operador, una caída de la red del operador derribaría los dos enlaces
simultáneamente y el bonding degradaría a 0 enlaces. Este requisito es
*recomendado*, no crítico, para escenarios de máxima fiabilidad.

**Parent Requirement:** N/A

**Acceptance Criteria:**

- iPhone y Android usan SIMs de operadores diferentes (en este proyecto:
  Movistar e Yoigo).
- En el AVE Orihuela-Madrid, al menos uno de los dos operadores
  mantiene cobertura útil en cada tramo del trayecto.
