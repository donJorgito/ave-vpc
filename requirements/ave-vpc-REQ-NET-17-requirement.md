### ave-vpc.REQ-NET-17 - Monitor `08-monitor.py` consciente de `--failover`

**Description:**

`08-monitor.py` mostraba siempre throughput agregado de todas las
interfaces físicas, sin distinguir entre activo y backup. En modo
bonding clásico esto es correcto (todos los links llevan tráfico
proporcional). Pero en modo `--failover` (REQ-NET-11), donde solo el
link sin `fallback_only=1` debería transportar datos y los demás solo
keepalives mlvpn, el monitor confundía al usuario: parecía que el
bonding "agregaba" cuando en realidad mlvpn estaba usando solo el
activo.

Caso real reportado por el usuario el 2026-05-25 en AVE: "el monitor
sigue mostrando tráfico como agregado, cuando si uso failover no lo
debería agregar o sí?". Sin distinción visual de roles, el usuario
no podía verificar si `fallback_only` estaba funcionando.

**Solución:** el monitor lee `generated/mlvpn_active.conf` cada
iteración, detecta si algún link tiene `fallback_only = 1`
(indicador de modo failover), y muestra:

- Header con `[FAILOVER]` o `[BONDING]` según corresponda
- Columna nueva `Rol` per-link: `[A] ●` (activo, verde) o `[B] ◌`
  (backup, azul)
- Resumen final separa "Activo ↓X ↑Y" de "Backups (solo
  keepalives) ↓A ↑B" — si los backups tienen tráfico significativo
  (>1 KB/s), hay un bug en el comportamiento de `fallback_only`

En modo bonding clásico (sin links con `fallback_only=1`), el
monitor mantiene el comportamiento previo intacto.

**Parent Requirement:** ave-vpc.REQ-NET-11

**Acceptance Criteria:**

- `08-monitor.py` define una función `check_failover_roles()` que
  lee `generated/mlvpn_active.conf` y devuelve un dict con keys
  `links.iphone`, `links.pixel`, `links.wifi` mapeados a
  `'active'` o `'backup'`. Devuelve `{}` si el archivo no existe,
  no se puede leer, o ningún link tiene `fallback_only = 1`.
- La función intenta leer sin sudo primero; si falla por permisos,
  intenta `sudo -n cat` (no interactivo). Si tampoco, devuelve `{}`.
- `draw()` recibe el dict y, si NO está vacío, añade columna `Rol`
  con `[A]` verde para active y `[B]` azul para backup.
- Header del monitor muestra `[FAILOVER]` (amarillo) o `[BONDING]`
  (verde) según el modo detectado.
- Resumen final, en modo failover, separa `Activo ↓X ↑Y` de
  `Backups (solo keepalives) ↓A ↑B`. En modo bonding mantiene
  `Encapsulado ↓X ↑Y` como antes.
- Sin regresión en modo bonding clásico: si `check_failover_roles`
  devuelve `{}`, todo el comportamiento previo (columnas, resumen)
  intacto.
- El parser tolera comentarios `#`, líneas vacías y secciones
  desconocidas en el conf sin romperse.
