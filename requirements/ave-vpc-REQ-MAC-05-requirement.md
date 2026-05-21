### ave-vpc.REQ-MAC-05 - Limpieza de instancias mlvpn previas al reconectar

**Description:**

Si el usuario ejecuta `04-conectar.sh` sin haber pasado antes por
`05-desconectar.sh` (típico cuando el túnel sigue arriba pero algo no
funciona y se quiere "reconectar"), el script anterior arrancaba un
nuevo proceso mlvpn dejando vivos los previos. Resultado observado en
runtime: hasta 4 instancias mlvpn corriendo a la vez encapsulando los
mismos paquetes en paralelo, la RPi recibiendo streams duplicados, el
reordering colapsando y la latencia disparándose. Síntoma típico:
videoconferencia con lag descomunal aunque el monitor "se vea bien".

`04-conectar.sh` debe detectar y matar cualquier instancia mlvpn previa
al inicio (defensive cleanup) antes de arrancar la nueva.
`05-desconectar.sh` debe verificar tras `pkill -9` que efectivamente
no queda ningún proceso vivo, y avisar si los hubiera (caso patológico
que indicaría un bug en el matching del pkill).

**Parent Requirement:** ave-vpc.REQ-MAC-04

**Acceptance Criteria:**

- `04-conectar.sh`, antes de arrancar el binario mlvpn, hace `pgrep
  -f "mlvpn: mlvpn0"`; si encuentra procesos, ejecuta `pkill -f`
  seguido de `sleep 1` + `pkill -9 -f` + `pkill -f tee.*mlvpn.log` y
  espera 1 s antes de continuar.
- El usuario ve un mensaje "Detectadas instancias mlvpn previas —
  matando antes de arrancar la nueva" cuando esto ocurre.
- `05-desconectar.sh`, tras el `pkill -9`, verifica con `pgrep -f
  "mlvpn: mlvpn0"` que no queden procesos. Si quedan, los lista con
  `pgrep -lf` para diagnóstico. Si no, imprime "mlvpn parado (todas
  las instancias)".
- Tras una secuencia de N reconexiones consecutivas sin desconectar,
  `pgrep -f "mlvpn: mlvpn0"` devuelve exactamente 2 procesos (1
  `[priv]` + 1 worker), no 2N.
