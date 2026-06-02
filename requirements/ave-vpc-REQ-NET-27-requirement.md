### ave-vpc.REQ-NET-27 - Fix replicación selectiva (H1+H2+NULL check)

**Description:**

Tras el incidente AVE 2026-06-01 (REQ-NET-26 trata los síntomas), el
análisis post-mortem con 3 agentes expertos identificó dos bugs C en
el patch de replicación selectiva (REQ-NET-12) que explican la causa
primaria de la caída:

**H1** — `ubond_rtun_send` (`build/ubond/src/ubond.c:697-705 + 813`)
sobreescribe `proto->data_seq` después de que el patch de replicación
lo asignó UNA vez en `ubond_rtun_choose` para todos los clones. Cada
clon termina con un `data_seq` distinto en el wire → la dedup LRU del
receptor nunca matchea → ambos clones se entregan al tap → el reorder
los contabiliza como huecos → `loss++` → status pasa a `UBOND_LOSSY` →
`request_resend(RESENDBUFSIZE)` (1024 paquetes) → satura el
`hpsend_buffer` y propaga la degradación a otros enlaces.

**H2** — La dedup LRU en `ubond_protocol_read` (línea 652) retorna `0`
cuando descarta un duplicado, pero el caller en `ubond_rtun_read`
(línea 460) solo cortocircuita con `< 0`. El paquete duplicado prosigue
a `ubond_reorder_insert`, contabilizado como `aolderb` (loss++) →
mismo efecto cascada que H1. Bug latente que se manifestaría tras fix
H1 si no se corrige el contrato del retorno.

**Defensive (NULL check)** — `ubond_pkt_get()` en el clone path (línea
1865) puede devolver NULL si el pool está exhausto Y el malloc fallback
también falla. Sin chequeo, esto es un crash. Probabilidad baja, coste
del fix trivial.

Fix implementado en `patches/ubond_replicate_dedup_fix.patch`:

1. **`pkt.h`**: añadir campo `int replicated` a `ubond_pkt_t` (struct
   externa, NO al wire format `ubond_proto_t`).
2. **`ubond_rtun_choose`**: marcar `clone->replicated = 1` tras
   `memcpy`, y NULL check en `ubond_pkt_get()`.
3. **`ubond_rtun_send`**: si `pkt->replicated`, NO sobreescribir
   `proto->data_seq` ni incrementar el global `data_seq`.
4. **`ubond_protocol_read`**: cambiar `return 0` del dedup hit a
   `return 1` (paquete consumido internamente).
5. **`ubond_rtun_read`**: cambiar contrato de `< 0` a `!= 0` (cubre
   error y dedup-hit).

**Parent Requirement:** ave-vpc.REQ-NET-12 (replicación selectiva).

**Why:** Sin estos fixes, la replicación es inutilizable bajo flap de
cobertura (caso AVE típico). El throughput se colapsa en pocos minutos
y el cliente entra en bucle de Reset (verificado en logs RPi del
incidente: 9 entradas `Reset` entre 13:07-16:16 con PIDs cliente
cambiantes).

**Acceptance Criteria:**

- `patches/ubond_replicate_dedup_fix.patch` existe (~99 líneas).
- El patch modifica `src/pkt.h` (1 hunk) y `src/ubond.c` (5 hunks).
- `pkt.h` declara `int replicated` en `ubond_pkt_t`.
- `ubond.c` `ubond_rtun_send` chequea `pkt->replicated` antes de
  reasignar `proto->data_seq` y antes de `data_seq++`.
- `ubond.c` `ubond_rtun_choose` marca `clone->replicated = 1` y
  chequea NULL de `ubond_pkt_get()`.
- `ubond.c` `ubond_protocol_read` retorna `1` (no `0`) en dedup hit.
- `ubond.c` `ubond_rtun_read` usa `!= 0` (no `< 0`) para
  cortocircuitar.
- 03b lo aplica como Patch 5 en su chain.
- 07b lo transporta vía `UBOND_PATCH3_B64` y lo aplica al final del
  pipeline.
- Binario compilado pasa `strings | grep "pool exhausted"` (defensive
  log message).

**Verification:** test estático
`test_REQ-NET-27_replicate_dedup_fix.sh`. Validación runtime requiere
reproducir el escenario AVE — pendiente próximo trayecto. Idealmente
con instrumentación de `replicate_dedup_hits` para validar que el
contador crece tras este fix (antes era 0 porque la dedup nunca
matcheaba).

**Related:**

- [[REQ-NET-12]] — replicación selectiva (la que tenía los bugs).
- [[REQ-NET-26]] — watchdog/auto-recovery (síntomas).
- `docs/v2-ubond/06-trayecto-2026-06-01.md` — incidente post-mortem.
