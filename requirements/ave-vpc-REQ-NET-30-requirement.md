### ave-vpc.REQ-NET-30 - Dedup gate por wire signal data_seq!=0

**Description:**

Causa raíz del cuelgue del dataplane bajo `[filters.replicate]` activo
(síntoma: ping 0/N pese a túnel autenticado y links activos). NO se
solucionaba con REQ-NET-27 (data_seq compartido) ni REQ-NET-29
(parser filters).

El gate de dedup en `build/ubond/src/ubond.c:659` (post REQ-NET-12+27+29)
dependía de `ubond_replicate_filters.count > 0` — estado LOCAL del
receptor. Si cliente tiene `[filters.replicate]` poblado y server
tiene la sección VACÍA (default según `07b-setup-rpi-ubond.sh:216`),
entonces:

- Cliente: `count > 0` → clona en `ubond_rtun_choose` y marca clones
  con `data_seq != 0` en el wire packet.
- Server: `count == 0` → gate `count > 0` FALSE → server NO dedupea
  aunque el wire trae clones.
- Kernel del RPi recibe paquetes duplicados (ICMP echo, TCP SYN, etc.)
  → comportamiento errático (rate-limit, conntrack confuso) → ping 0/N.

Fix en `patches/ubond_dedup_gate_data_seq.patch`: cambia el gate de
`ubond_replicate_filters.count > 0` a `proto->data_seq != 0` —
señal autoritativa del SENDER en el wire packet. Receptor dedupea sii
sender marcó. Sin negociación. data_seq=0 está reservado (counter
global empieza en 1 en `ubond.c:90`) para tráfico que no requiere
dedup (UDP/ICMP no replicado, keepalives, auth, version<1 legacy).

Wire format intacto — patch puramente receiver-side. Compatibilidad
matriz cliente×server verificada (sin regresión para tráfico no
replicado, fix completo para asimétrico).

**Why:** Asimetría cliente/server SIEMPRE rompe si la lógica depende
de config local en lugar de señal autoritativa del wire. La señal
existe (`data_seq` en `ubond_proto_t` en `pkt.h:32`, serializada con
`htobe64`/`be64toh`); REQ-NET-12 simplemente no la usaba. Test
oficina 2026-06-03 reprodujo el bug determinísticamente.

**Acceptance Criteria:**

- `patches/ubond_dedup_gate_data_seq.patch` existe (~32 líneas).
- El patch modifica solo `src/ubond.c` (1 hunk en `ubond_protocol_read`).
- Sustituye `ubond_replicate_filters.count > 0` por `proto->data_seq != 0`.
- 03b lo aplica como Patch 7 en su chain.
- 07b lo transporta vía `UBOND_PATCH5_B64` y lo aplica al final del
  pipeline.
- Tras compilar, `build/ubond/src/ubond.c` líneas 650-680 contienen
  literal `proto->data_seq != 0` Y NO contienen el gate viejo
  `replicate_filters.count > 0` como condición del dedup.

**Verification:** test estático
`tests/test_REQ-NET-30_dedup_wire_gate.sh` valida la forma del patch +
wiring + (si build/ existe) regression-killer sobre el .c actual.

**Validación runtime (oficina 2026-06-03):**

- Pre-patch + asimetría (Mac filters poblado, RPi vacío): ping 0/10.
- Post-patch + asimetría: ping 10/10, RTT mediana 49ms, 0 duplicados
  en `tcpdump -i ubond0` RPi (11 echo requests = 11 (id, seq) únicos).

**Rollback plan:**

`patch -R -p1 -d build/ubond < patches/ubond_dedup_gate_data_seq.patch`
seguido de rebuild. Workaround temporal: replicar `[filters.replicate]`
simétrico en RPi `/etc/ubond/ubond.conf`.

**Related:**

- [[REQ-NET-12]] — replicación selectiva (introdujo el gate `count > 0`).
- [[REQ-NET-27]] — fix anterior insuficiente (data_seq compartido).
- [[REQ-NET-29]] — fix anterior, solo warnings.
- `docs/v2-ubond/08-req-net-30-dedup-asymmetry.md` — RCA + métricas
  post-deploy + plan rollback.
- Commit `bf5f2a5`.
