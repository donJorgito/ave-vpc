### ave-vpc.REQ-NET-34 - Watchdog tolerante a degradación parcial

**Description:**

REQ-NET-32 (threshold=8) DEMOSTRADO insuficiente. Validación oficina
2026-06-03 (3 SOS espurios consecutivos en una tarde con misma firma):
cada vez que `[WARN/net] links.pixel write error` aparece en `ubond.log`,
26-56 segundos después el watchdog dispara SOS — exactamente cuando
el threshold (20s o 40s) se cumple.

| Evento | pixel write error | SOS | Delta | Threshold |
|---|---|---|---|---|
| 1 | 12:51:09 | 12:51:35 | 26s | 4 (20s) |
| 3 | 16:44:38 | 16:45:34 | 56s | 8 (40s) |

Subir threshold solo difiere la muerte ~30s. NO es la solución correcta:
threshold alto enmascara caídas legítimas (downtime real largo) y
solo posterga el síntoma.

**Causa raíz aproximada**: cuando un link móvil del bonding (pixel)
experimenta `write error` (NAT 4G expirado, drop celular, write socket
ENETUNREACH), ubond NO degrada con iphone solo de forma que el watchdog
ICMP siga viendo el túnel sano. Aunque iphone sigue `@links.iphone`
autenticado, el ping al utun no vuelve.

Fix propuesto: lógica de health del watchdog que distingue entre:

- **0 links auth + ping KO** → caída total → SOS legítimo.
- **≥1 link auth + ping KO transitorio (<60s)** → degradación, LOG warning, NO SOS.
- **≥1 link auth + ping KO sostenido (>120s)** → degradación seria, SOS.

Implementación candidata en `tools/ubond-watchdog.sh`:

```bash
# Antes de incrementar fails, verificar count de links auth.
auth_count=$(pgrep -f "ubond: ubond0 @" | head -1 | xargs -I{} ps -o command= -p {} | grep -oE "@links\.\w+" | wc -l | tr -d ' ')
if [[ "${auth_count}" -ge 1 && "${fails}" -lt $((FAIL_THRESHOLD * 3)) ]]; then
    log "health degradado fails=${fails}/$((FAIL_THRESHOLD*3)) (${auth_count} link auth, NO SOS)"
    continue
fi
```

**Why:** Sin este fix, el patrón "pixel falla → 30-60s después SOS" rompe
cualquier sesión >10 min en oficina/AVE. Ya validado tres veces hoy.

**Acceptance Criteria:**

- `tools/ubond-watchdog.sh` lee count de `@links.X` autenticados antes
  de cada fail count.
- Si `auth_count >= 1`, escala a 3× threshold antes de SOS.
- Mensaje `health degradado` en log para distinguir de fail real.
- Test (estático): verificar que el script tiene la lógica auth_count.
- Test (runtime, opcional): forzar `links.pixel write error` (matar pixel
  tethering) y validar que watchdog NO dispara SOS si iphone sigue auth
  pero ping KO.

**Validación pendiente:**

- Reproducir el escenario en oficina o AVE.
- Confirmar que el patrón post-fix es "degradación tolerada" no "SOS espurio".

**Related:**

- [[REQ-NET-26]] — watchdog auto-recovery base.
- [[REQ-NET-32]] — threshold 4→8 (necesario pero NO suficiente).
- `~/.claude/projects/.../memory/project_persistent_pixel_sos_pattern.md`
  — el patrón observado y por qué subir threshold no funciona.
- Próxima investigación: `links.pixel write error` causa raíz (NAT 4G timeout?).
