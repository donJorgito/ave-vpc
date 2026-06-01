### ave-vpc.REQ-NET-24 - Coexistencia mlvpn↔ubond con subnets distintas

**Description:**

ubond (v2) y mlvpn (v1) deben poder correr **simultáneamente** en el
RPi sin pisarse. La coexistencia tiene dos planos:

1. **INPUT** (Mac → RPi): puertos UDP distintos (mlvpn 5080-5082 vs
   ubond 5083-5085). Ya cumplido en REQ-NET-21.
2. **OUTPUT** (RPi kernel → Mac): subnets de tunnel distintas. Si
   ambos tunnels asignan la misma IP `10.10.10.1/24` a sus interfaces
   (`mlvpn0` y `ubond0`), el kernel Linux mantiene dos rutas idénticas
   `10.10.10.0/24 dev mlvpn0` y `10.10.10.0/24 dev ubond0`, y enruta
   replies por la primera (mlvpn0). Las respuestas ICMP/TCP/UDP del
   kernel salen por el tunnel **equivocado** y nunca llegan al cliente
   ubond, rompiendo el dataplane v2 silenciosamente.

Este RQ documenta el contrato:

- **mlvpn** usa `10.10.10.0/24` (TUN_VPS_IP=10.10.10.1, TUN_MAC_IP=10.10.10.2).
- **ubond** usa `10.10.20.0/24` (UBOND_TUN_VPS_IP=10.10.20.1, UBOND_TUN_MAC_IP=10.10.20.2).
- Ambos tunnels pueden estar `active` en `systemctl is-active` simultáneamente.
- Un cliente Mac corriendo `04-conectar.sh` (mlvpn) no interfiere
  con uno corriendo `04b-conectar-ubond.sh` (ubond), ni viceversa.

**Parent Requirement:** ave-vpc.REQ-NET-21 (setup ubond RPi).

**Why:** Bug #5 del trayecto AVE 2026-05-29 quedó documentado como
"dataplane no fluye" tras horas de hipótesis sobre el patch C
(clone-to-N, dedup, wire format, regresión upstream). El 2026-06-01
el smoke-test adaptativo (REQ-NET-23) capturó simultáneamente Mac
y RPi, mostrando que los paquetes UDP llegaban al RPi pero las
replies del kernel nunca volvían. La causa raíz fue la colisión de
subnet en `ip route show`. Este RQ fija la separación para que el
bug no pueda volver a surgir por configuración.

**Acceptance Criteria:**

- `config/env.example` define `UBOND_TUN_VPS_IP` y `UBOND_TUN_MAC_IP`
  en subnet `10.10.20.0/24`, distintas de `TUN_VPS_IP`/`TUN_MAC_IP`.
- `03b-setup-mac-ubond.sh` genera `generated/ubond.conf` con
  `ip4`/`ip4_gateway` apuntando a `UBOND_TUN_*`.
- `07b-setup-rpi-ubond.sh` genera `/etc/ubond/ubond.conf` con
  `ip4`/`ip4_gateway` apuntando a `UBOND_TUN_*`.
- `04b-conectar-ubond.sh` configura el utun cliente con
  `UBOND_TUN_MAC_IP/UBOND_TUN_VPS_IP` y verifica conectividad
  pinging `UBOND_TUN_VPS_IP`.
- `tools/lib/conf-gen.sh` y `tools/lib/tests.sh` usan `UBOND_TUN_*`,
  no `TUN_*` (que sigue siendo de mlvpn).
- Ningún script ubond v2 referencia las constantes literales
  `10.10.10.1` o `10.10.10.2` (esas son de v1).
- Defaults sensibles si `UBOND_TUN_*` no están definidas: caer a
  `10.10.20.1`/`10.10.20.2`, NO a `10.10.10.x`.

**Verification:** test estático `test_REQ-NET-24_coexistencia.sh`
que cubre los criterios de arriba via grep + comprobación de
defaults. Validación end-to-end en sesión 2026-06-01: smoke-casa.sh
con mlvpn Y ubond corriendo en RPi simultáneamente, ping 5/5 OK
sobre `UBOND_TUN_VPS_IP=10.10.20.1`.

**Related:**

- [[REQ-NET-21]] — setup paralelo ubond RPi (donde nació la falsa
  asunción de subnet compartida).
- [[REQ-NET-23]] — smoke-test adaptativo, herramienta que
  identificó el bug.
- `docs/v2-ubond/04-bugs-trayecto-2026-05-29.md` sección
  "Resolución Bug #5".
