#!/bin/sh
# Validates ave-vpc.REQ-NET-40: watchdog captive portal + re-login wifionice.
#
# Levanta un servidor HTTP SINTETICO local (python3 stdlib) que sirve:
#   - /canary       : "alive" o pagina-portal segun un fichero de estado.
#   - /portal       : un form captive con hidden inputs incl. CSRFToken.
#   - /login        : action del form; registra el POST recibido a disco.
# Luego ejercita tools/captive-watchdog.py contra ese server y verifica:
#   1. clasifica ONLINE cuando el canary devuelve el token.
#   2. clasifica OFFLINE cuando el canary devuelve la pagina portal.
#   3. el parser html.parser extrae CSRFToken y demas hidden inputs.
#   4. el re-POST llega al server con login=true + el CSRFToken echo.
#
# Es la prueba clave de que el MOTOR funciona ANTES de ver el form real
# PlayRenfe en el tren. JUnit XML a reports/ (estilo _lib_junit.sh).
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-40_captive_watchdog"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WATCHDOG="${ROOT}/tools/captive-watchdog.py"
PY="$(command -v python3 || true)"

# 0. Pre-requisitos.
if [ -z "${PY}" ]; then
    junit_skip "python3_missing" "python3 no disponible"
    junit_finalize
fi
if [ ! -r "${WATCHDOG}" ]; then
    junit_fail "watchdog_missing" "tools/captive-watchdog.py no existe"
    junit_finalize
fi
if ! "${PY}" -c "import ast,sys; ast.parse(open('${WATCHDOG}').read())" 2>/dev/null; then
    junit_fail "watchdog_syntax" "captive-watchdog.py no compila (ast.parse)"
    junit_finalize
fi
junit_pass "watchdog_present_and_compiles"

# Directorio temporal de trabajo del test.
WORKDIR="$(mktemp -d 2>/dev/null || mktemp -d -t captivewd)"
STATE_FILE="${WORKDIR}/canary_state"   # contiene "alive" u "offline"
POST_LOG="${WORKDIR}/post.log"         # el server escribe aqui el body POST
PORT_FILE="${WORKDIR}/port"            # el server escribe el puerto elegido
SRV_PID=""

cleanup() {
    [ -n "${SRV_PID}" ] && kill "${SRV_PID}" 2>/dev/null
    rm -rf "${WORKDIR}" 2>/dev/null
}
trap cleanup EXIT INT TERM

echo "alive" > "${STATE_FILE}"

# ─── Servidor HTTP sintetico (inline python, stdlib) ────────────────────────
# Sirve canary tri-valor, form captive con hidden CSRFToken, y captura POST.
cat > "${WORKDIR}/server.py" <<'PYEOF'
import http.server, os, sys, urllib.parse

WORK = os.environ["WD_WORK"]
STATE = os.path.join(WORK, "canary_state")
POSTLOG = os.path.join(WORK, "post.log")
PORTF = os.path.join(WORK, "port")

# Form sintetico: imita el patron wifionice (hidden inputs incl. CSRFToken).
PORTAL_HTML = (
    "<html><body><h1>PlayRenfe (synthetic)</h1>"
    "<form id='loginform' method='post' action='/login'>"
    "<input type='hidden' name='CSRFToken' value='SYNTH-CSRF-1234567890ab'>"
    "<input type='hidden' name='uamip' value='10.0.0.1'>"
    "<input type='hidden' name='challenge' value='deadbeef'>"
    "<input type='submit' name='login' value='true'>"
    "</form></body></html>"
)
ALIVE_BODY = "CANARY_ALIVE_TOKEN"

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):  # silenciar ruido en el test
        pass

    def _send(self, code, body, ctype="text/html"):
        b = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path.startswith("/canary"):
            with open(STATE) as f:
                st = f.read().strip()
            if st == "alive":
                self._send(200, ALIVE_BODY, "text/plain")
            else:
                # Sesion expirada: el portal sirve su pagina HTML.
                self._send(200, PORTAL_HTML)
        elif self.path.startswith("/portal"):
            self._send(200, PORTAL_HTML)
        else:
            self._send(404, "nope", "text/plain")

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n).decode()
        with open(POSTLOG, "w") as f:
            f.write(body)
        # Tras login OK, el portal "abre" la sesion: marcar alive.
        with open(STATE, "w") as f:
            f.write("alive")
        self._send(200, "LOGIN_OK", "text/plain")

srv = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(PORTF, "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
PYEOF

WD_WORK="${WORKDIR}" "${PY}" "${WORKDIR}/server.py" &
SRV_PID=$!

# Esperar a que el server escriba su puerto (timeout acotado).
i=0
while [ ! -s "${PORT_FILE}" ] && [ "${i}" -lt 50 ]; do
    i=$((i + 1))
    sleep 0.1
done
PORT="$(cat "${PORT_FILE}" 2>/dev/null || echo "")"
if [ -z "${PORT}" ]; then
    junit_fail "server_startup" "el server sintetico no levanto"
    junit_finalize
fi
junit_pass "synthetic_server_up"

CANARY="http://127.0.0.1:${PORT}/canary"
PORTAL="http://127.0.0.1:${PORT}/portal"

# ─── Check 1: clasifica ONLINE cuando el canary trae el token ───────────────
echo "alive" > "${STATE_FILE}"
EST="$("${PY}" "${WATCHDOG}" --probe \
        --canary-url "${CANARY}" --canary-token "CANARY_ALIVE_TOKEN" \
        --timeout 2.5 2>/dev/null)"
if [ "${EST}" = "online" ]; then
    junit_pass "detects_online"
else
    junit_fail "detects_online" "esperado 'online', obtenido '${EST}'"
fi

# ─── Check 2: clasifica OFFLINE cuando el canary sirve la pagina portal ─────
echo "offline" > "${STATE_FILE}"
EST="$("${PY}" "${WATCHDOG}" --probe \
        --canary-url "${CANARY}" --canary-token "CANARY_ALIVE_TOKEN" \
        --timeout 2.5 2>/dev/null)"
if [ "${EST}" = "offline" ]; then
    junit_pass "detects_offline_expired"
else
    junit_fail "detects_offline_expired" "esperado 'offline', obtenido '${EST}'"
fi

# ─── Check 3+4: re-login parsea hidden inputs y POSTea login=true ───────────
# Estado expirado -> un ciclo --once debe disparar el re-login wifionice.
echo "offline" > "${STATE_FILE}"
rm -f "${POST_LOG}"
"${PY}" "${WATCHDOG}" --once \
    --canary-url "${CANARY}" --canary-token "CANARY_ALIVE_TOKEN" \
    --portal-url "${PORTAL}" --form-id "loginform" \
    --timeout 2.5 >/dev/null 2>&1

if [ ! -s "${POST_LOG}" ]; then
    junit_fail "relogin_posted" "el watchdog no emitio ningun POST de re-login"
    junit_fail "relogin_parsed_csrftoken" "sin POST no hay CSRFToken que verificar"
    junit_fail "relogin_login_true" "sin POST no hay login=true que verificar"
    junit_finalize
fi
junit_pass "relogin_posted"

BODY="$(cat "${POST_LOG}")"

# Check 3: el CSRFToken hidden fue parseado y reenviado (URL-encoded).
if echo "${BODY}" | grep -q "CSRFToken=SYNTH-CSRF-1234567890ab"; then
    junit_pass "relogin_parsed_csrftoken"
else
    junit_fail "relogin_parsed_csrftoken" \
        "CSRFToken no presente/echo en el POST: ${BODY}"
fi

# Check 4: login=true presente en el POST (marcador de autenticacion).
if echo "${BODY}" | grep -q "login=true"; then
    junit_pass "relogin_login_true"
else
    junit_fail "relogin_login_true" "login=true no presente en el POST: ${BODY}"
fi

# Check extra: otros hidden inputs (uamip, challenge) tambien reenviados.
if echo "${BODY}" | grep -q "uamip=10.0.0.1" && \
   echo "${BODY}" | grep -q "challenge=deadbeef"; then
    junit_pass "relogin_echoes_all_hidden_inputs"
else
    junit_fail "relogin_echoes_all_hidden_inputs" \
        "no se reenviaron todos los hidden inputs: ${BODY}"
fi

junit_finalize
