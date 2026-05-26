### ave-vpc.REQ-NET-15 - Detección de flapping de links

**Description:**

Algunos enlaces (típicamente WiFi público restrictivo del AVE) tienen
un patrón muy concreto: el handshake mlvpn (paquete UDP pequeño)
atraviesa el firewall/DPI, el link autentica a nivel mlvpn (`@`),
empieza a fluir tráfico → el firewall detecta UDP no estándar y lo
corta → el link pasa a `!` (AUTH_PENDING) → mlvpn reintenta handshake
→ autentica un instante → vuelta al ciclo. Sin tratamiento, esto
gasta CPU + datos en re-handshakes inútiles y desestabiliza el
bonding entero.

Caso real validado 2026-05-25 en AVE: WiFi del tren con
`MLVPN_PORT_3_REMOTE=443` autenticaba unos segundos y caía a `!`
cíclicamente. Ningún check de RTT/loss del selector lo capturaba
porque ICMP sí responde, solo UDP del túnel está filtrado.

**Solución:** el selector cuenta transiciones `@↔!` en una ventana
deslizante. Si supera el umbral, marca el link como flapping y lo
excluye del pool de candidatos hasta que esté `@` estable durante un
tiempo mínimo. El link se reintegra automáticamente cuando recupera.

**Parámetros:**

- `FLAP_WINDOW_S=60` — ventana de observación
- `FLAP_THRESHOLD=4` — número de transiciones para considerar flapping
- `FLAP_RECOVERY_S=30` — tiempo en `@` estable para reintegrar

**Parent Requirement:** ave-vpc.REQ-NET-11

**Acceptance Criteria:**

- `tools/seleccionar-mejor-enlace.sh` define las constantes
  `FLAP_WINDOW_S`, `FLAP_THRESHOLD`, `FLAP_RECOVERY_S`.
- Una función `update_flap_state()` se llama **en cada tick** (no
  solo en eval cada 30 s) y mantiene 4 mapas asociativos:
  `LAST_AUTH_STATE`, `FLAP_TIMESTAMPS`, `FLAP_EXCLUDED`,
  `STABLE_SINCE`.
- En cada tick, para cada link presente en config:
  - Detecta el estado actual (`@` o `!`) consultando
    `authenticated_links`.
  - Si hay transición respecto al estado anterior, registra el
    timestamp en `FLAP_TIMESTAMPS[link]` (CSV).
  - Limpia timestamps fuera de la ventana `FLAP_WINDOW_S`.
  - Si el link no está excluido y el contador supera
    `FLAP_THRESHOLD`, lo marca excluido y resetea
    `STABLE_SINCE[link]=0`.
  - Si el link está excluido y lleva al menos `FLAP_RECOVERY_S` en
    `@` (medido por `STABLE_SINCE`), lo reintegra y resetea
    `FLAP_TIMESTAMPS`.
- `evaluate_and_rotate()` excluye del cálculo de score los links con
  `FLAP_EXCLUDED[link]=1`.
- Cada transición de estado flapping (entrada y salida) loguea via
  `logger -t mlvpn-selector` con el conteo de transiciones.
- El resumen de rotación muestra `FLAP` como marker para los links
  excluidos por flapping (en vez de `@`).
