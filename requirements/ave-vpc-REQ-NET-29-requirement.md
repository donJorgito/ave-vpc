### ave-vpc.REQ-NET-29 - Parser de [filters] excluye sub-secciones

**Description:**

El parser de configuración de ubond (`build/ubond/src/config.c:474`)
hacía `strncmp(section, "filters", 7) == 0` al detectar la sección
`[filters]` para procesarla con la lógica de filtros stock (que asume
`tun != NULL`). Esto matcheaba TAMBIÉN `filters.replicate` y
`filters.fifo` — sub-secciones especializadas (REQ-NET-12). Resultado:
las entries de `[filters.replicate]` se procesaban además como filtros
stock con `tun=NULL` → `pcap_compile` recibía interface vacío →
generaba warnings `filters X interface not found` y un leak menor en
`pcap_compile`.

**Síntoma observado**: warnings repetidos en `ubond.log` al startup
del cliente bajo `[filters.replicate]` activo. NO causa el cuelgue
del dataplane (eso es REQ-NET-30) — solo ruido en logs y leak
de memoria menor.

Fix en `patches/ubond_filters_section_exclusion.patch`: cambia
`strncmp(section, "filters", 7) == 0` por
`strcmp(section, "filters") == 0`. Match exacto, sub-secciones
`filters.X` ya no entran al pipeline de filtros stock.

**Why:** REQ-NET-12 introdujo `[filters.replicate]` como sección
hermana de `[filters]`, asumiendo que el parser TOML las
distinguiría. La heurística `strncmp(...,7)` fue introducida antes
y nadie revisó la interacción cuando llegó replicate.

**Acceptance Criteria:**

- `patches/ubond_filters_section_exclusion.patch` existe (~21 líneas).
- El patch modifica `src/config.c` (1 hunk).
- Cambia `strncmp(section, "filters", 7) == 0` por
  `strcmp(section, "filters") == 0`.
- 03b lo aplica como Patch 6 en su chain.
- 07b lo transporta vía `UBOND_PATCH4_B64` y lo aplica al final del
  pipeline.
- Tras aplicar el patch, `ubond.log` con `[filters.replicate]`
  poblado NO emite warnings `filters X interface not found` para
  entries de filters.replicate / filters.fifo.

**Verification:** test estático
`tests/test_REQ-NET-29_filters_section_exclusion.sh` valida la
forma del patch + wiring en build scripts.

**Related:**

- [[REQ-NET-12]] — replicación selectiva (introduce filters.replicate).
- [[REQ-NET-30]] — dedup gate fix (cuelgue real, no las warnings).
- Commit `cbe2a10`.
