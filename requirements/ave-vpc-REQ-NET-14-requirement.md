### ave-vpc.REQ-NET-14 - Rotación inmediata si current activo no autenticado

**Description:**

El selector dinámico (REQ-NET-11) rotaba al "mejor enlace" solo cuando
había una diferencia de score sostenida ≥ 20 puntos respecto al activo
actual (histeresis para evitar oscilación con ruido). Pero hay un caso
en el que esa histeresis es contraproducente: cuando el link "activo
según config" (sin `fallback_only=1`) NO está autenticado a nivel
mlvpn (proceso muestra `!links.X`), seguir esperando al gap retrasa
inútilmente el cambio a un link que sí está operativo.

Caso real validado 2026-05-25 en AVE:

- Config: iPhone activo (sin fallback_only), Pixel y WiFi como backup
- Realidad: iPhone en `!` (UDP 5080 filtrado o operador caído),
  Pixel en `@`, WiFi en `!`
- Selector veía iPhone como current_active aunque mlvpn lo había
  marcado AUTH_PENDING. Sin autorrotación inmediata, el selector
  esperaba a que Pixel acumulara 20 puntos de gap respecto a iPhone
  — pero como iPhone tenía score 0 (sin BW útil) y Pixel score
  positivo, eventualmente sí rotaba; mientras tanto, segundos
  perdidos en cada arranque.

**Fix:** si `current_active_link` NO aparece en
`authenticated_links()` (lista de `@links.X` extraída del proceso
mlvpn), el selector rota **inmediatamente** al mejor candidato
autenticado, sin esperar al gap.

**Parent Requirement:** ave-vpc.REQ-NET-11

**Acceptance Criteria:**

- `tools/seleccionar-mejor-enlace.sh`, en `evaluate_and_rotate()`,
  comprueba si `current_active_link` está en `authenticated_links`
  y guarda el resultado en `current_authed` (1 si sí, 0 si no).
- Si `current_authed == 0` y hay un `best_link` candidato, rota
  inmediatamente sin evaluar `gap >= MIN_SCORE_GAP`.
- El log de la rotación menciona la causa: "current=X en !
  AUTH_PENDING (REQ-NET-14)".
- Si `current` está autenticado, comportamiento previo intacto: solo
  rota con `gap >= MIN_SCORE_GAP`.
- Si no hay `current` (todos en fallback_only=1, situación rara), rota
  al `best_link` directamente.
