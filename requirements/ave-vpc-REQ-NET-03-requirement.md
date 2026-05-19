### ave-vpc.REQ-NET-03 - Dos enlaces activos simultáneamente al conectar

**Description:**

Para que el bonding aporte agregación real (no failover), los dos
enlaces móviles deben estar activos y autenticados simultáneamente
contra el servidor mlvpn cuando se ejecuta `04-conectar.sh`. mlvpn
reparte los paquetes salientes entre los enlaces autenticados según
el `bandwidth_upload` de cada uno.

**Parent Requirement:** ave-vpc.REQ-NET-01, ave-vpc.REQ-NET-02

**Acceptance Criteria:**

- Tras ejecutar `04-conectar.sh`, el proceso `mlvpn` muestra
  `@links.iphone @links.pixel` en su nombre (autenticados).
- `08-monitor.py` muestra ambos enlaces en estado `ACTIVO`.
- Tráfico generado por el cliente se reparte entre las dos interfaces
  físicas (visible como counters crecientes en ambas).
