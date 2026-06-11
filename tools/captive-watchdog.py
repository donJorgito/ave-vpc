#!/usr/bin/env python3
###############################################################################
# tools/captive-watchdog.py — Watchdog de captive portal + re-login automatico
# (REQ-NET-40)
#
# DONDE SE EJECUTA: en tu Mac, mientras estas conectado al WiFi del AVE
# (portal PlayRenfe / plataforma Icomera).
#
# QUE HACE:
#   C1 (canary tri-estado): cada poll-interval hace un HTTP-GET plano a una
#       URL canary y clasifica en TRES estados:
#         - online  : el body trae el token esperado -> sesion viva.
#         - offline : respuesta recibida pero es el portal -> sesion EXPIRADA.
#         - None    : la peticion falla (timeout / sin ruta) -> WiFi CAIDO.
#       En None NO se intenta re-login (evita thrashing); solo se espera.
#   C2 (re-login estilo wifionice): al detectar online->offline:
#         - GET de la pagina del portal.
#         - parseo de TODOS los <input> del form con html.parser (incl.
#           hidden como CSRFToken) -> dict {name: value}.
#         - re-POST de ese dict (con login=true) a la action del form.
#         - verificacion: re-probe del canary; exito solo si vuelve a online.
#
# PATRON DE REFERENCIA (clonado en build/captive-refs/ via Task C3):
#   - prison-break/.../wifionice.py:40,49-51,62  -> GET -> parse inputs -> POST.
#   - db_wlan_manager/db_wifionice.py:71-85       -> tri-estado online/offline/None.
#
# STDLIB-ONLY (Rule IDLC: sin pip). Usa urllib + html.parser, NO requests/bs4.
#
# USO:
#   ./tools/captive-watchdog.py                       # defaults + env
#   ./tools/captive-watchdog.py --once                # un solo ciclo (test/debug)
#   ./tools/captive-watchdog.py --probe               # solo clasifica estado y sale
#   ./tools/captive-watchdog.py --stop                # mata el daemon vivo
#   ./tools/captive-watchdog.py --canary-url http://... --portal-url http://...
#
# Configurable por flag o env (flag manda sobre env):
#   CANARY_URL / --canary-url        URL HTTP plano del canary.
#   CANARY_TOKEN / --canary-token    substring que confirma "sesion viva".
#   POLL_INTERVAL_S / --poll-interval  segundos entre probes (default 3).
#   PROBE_TIMEOUT_S / --timeout        timeout por peticion (default 2.5).
#   PORTAL_URL / --portal-url        URL de la pagina del captive portal.
#   PORTAL_FORM_ID / --form-id       id/name del <form> a usar (vacio = el 1o).
#   PORTAL_FORM_ACTION / --form-action  override del action del form.
#   WIFI_IFACE / --wifi-iface        interfaz WiFi (best-effort bind por IP).
###############################################################################

import argparse
import html.parser
import logging
import os
import signal
import socket
import sys
import time
import urllib.parse
import urllib.request

# ─── Rutas del proyecto ─────────────────────────────────────────────────────
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
GENERATED_DIR = os.path.join(PROJECT_ROOT, "generated")
PID_FILE = os.path.join(GENERATED_DIR, "captive_watchdog.pid")
LOG_FILE = os.path.join(GENERATED_DIR, "captive_watchdog.log")

# ─── Estados del canary (tri-estado) ────────────────────────────────────────
STATE_ONLINE = "online"     # sesion viva
STATE_OFFLINE = "offline"   # portal / sesion expirada
STATE_DOWN = None           # WiFi caido — NO re-login

# ─── Defaults (todos overridables; cero hardcoding de valores reales) ───────
# OJO: canary DEBE ser HTTP plano. Bajo el DNAT :443 de Renfe todo HTTPS
# devuelve el cert PlayRenfe, no el origin -> un canary HTTPS daria siempre
# "portal". Por eso el default es un endpoint http:// conocido y estable.
DEFAULT_CANARY_URL = "http://www.gstatic.com/generate_204"
# generate_204 devuelve 204 con body vacio cuando hay internet real. Si el
# token esperado esta vacio, la heuristica pasa a "204/2xx sin redirect al
# portal" (ver clasificar_estado).
DEFAULT_CANARY_TOKEN = ""
DEFAULT_POLL_INTERVAL_S = 3.0   # base empirica derhuerst/live-icomera-position
DEFAULT_PROBE_TIMEOUT_S = 2.5   # base empirica idem
# TODO(trayecto AVE): capturar la URL REAL del portal PlayRenfe a bordo
# (DevTools / curl tras DNAT) y fijarla aqui o en config/env como PORTAL_URL.
# El default apunta al canary mismo solo para que el motor sea ejercitable;
# NO es la URL real del portal Renfe.
DEFAULT_PORTAL_URL = ""

# User-Agent neutro de navegador: algunos portales sirven HTML distinto a
# clientes que no parecen browser.
USER_AGENT = "Mozilla/5.0 (Macintosh; captive-watchdog REQ-NET-40)"


# ─── Logging estructurado ───────────────────────────────────────────────────
def configurar_logging():
    """Log a fichero en generated/ + stderr, formato con timestamp y nivel."""
    os.makedirs(GENERATED_DIR, exist_ok=True)
    fmt = logging.Formatter(
        "%(asctime)s %(levelname)s captive-watchdog %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    )
    logger = logging.getLogger("captive-watchdog")
    logger.setLevel(logging.INFO)
    logger.handlers.clear()
    fh = logging.FileHandler(LOG_FILE)
    fh.setFormatter(fmt)
    logger.addHandler(fh)
    sh = logging.StreamHandler(sys.stderr)
    sh.setFormatter(fmt)
    logger.addHandler(sh)
    return logger


log = logging.getLogger("captive-watchdog")


# ─── Parser de formularios (html.parser stdlib, parseo SEGURO sin eval) ─────
class _FormInputParser(html.parser.HTMLParser):
    """Extrae los <form> de una pagina y, por cada uno, todos sus <input>.

    Replica el patron de prison-break/.../wifionice.py:49-51 pero con la
    libreria estandar (sin BeautifulSoup). Resultado: lista de forms, cada
    uno {'action': str, 'id': str, 'name': str, 'inputs': {nombre: valor}}.

    No ejecuta scripts ni evalua nada: html.parser solo tokeniza markup.
    """

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.forms = []
        self._form_actual = None

    def handle_starttag(self, tag, attrs):
        d = dict(attrs)
        if tag == "form":
            self._form_actual = {
                "action": d.get("action", ""),
                "id": d.get("id", ""),
                "name": d.get("name", ""),
                "method": (d.get("method", "post") or "post").lower(),
                "inputs": {},
            }
        elif tag == "input" and self._form_actual is not None:
            # Solo guardamos inputs con name (los sin name no se envian).
            nombre = d.get("name")
            if nombre is not None:
                # value puede faltar (campo vacio) -> "" como en wifionice.
                self._form_actual["inputs"][nombre] = d.get("value", "")
        elif tag == "input" and self._form_actual is None:
            # Input fuera de cualquier form -> lo ignoramos (no se postea).
            pass

    def handle_endtag(self, tag):
        if tag == "form" and self._form_actual is not None:
            self.forms.append(self._form_actual)
            self._form_actual = None


def parsear_forms(html_text):
    """Devuelve la lista de forms parseados de un documento HTML."""
    p = _FormInputParser()
    try:
        p.feed(html_text)
        p.close()
    except Exception as exc:  # html.parser es tolerante, pero por si acaso.
        log.warning("parseo HTML fallo: %s", exc)
    return p.forms


def seleccionar_form(forms, form_id):
    """Elige el form objetivo: por id/name si se especifica, si no el 1o."""
    if not forms:
        return None
    if form_id:
        for f in forms:
            if f.get("id") == form_id or f.get("name") == form_id:
                return f
        log.warning("form-id '%s' no encontrado; usando el primero", form_id)
    return forms[0]


# ─── Bind best-effort al interfaz WiFi (macOS: no hay SO_BINDTODEVICE) ──────
def ip_de_interfaz(iface):
    """Devuelve la IPv4 del interfaz (macOS: `ipconfig getifaddr <if>`).

    macOS no expone SO_BINDTODEVICE (Linux-only); lo mejor que podemos
    hacer es bind por IP de origen. Si no se puede determinar, None ->
    ruta por defecto (aceptable: durante el captive solo el WiFi del tren
    tiene ruta a 80/443).
    """
    if not iface:
        return None
    try:
        import subprocess  # stdlib

        out = subprocess.run(
            ["ipconfig", "getifaddr", iface],
            capture_output=True, text=True, timeout=3,
        )
        ip = out.stdout.strip()
        return ip or None
    except Exception as exc:
        log.warning("no pude obtener IP de %s: %s", iface, exc)
        return None


class _BindToIPHTTPHandler(urllib.request.HTTPHandler):
    """HTTPHandler que fuerza el bind del socket de origen a una IP local."""

    def __init__(self, source_ip):
        super().__init__()
        self._source_ip = source_ip

    def http_open(self, req):
        return self.do_open(self._conn_factory, req)

    def _conn_factory(self, host, **kwargs):
        import http.client  # stdlib

        conn = http.client.HTTPConnection(host, **kwargs)
        conn.source_address = (self._source_ip, 0)
        return conn


def construir_opener(source_ip, timeout):
    """Crea un urllib opener con bind opcional y SIN seguir redirects.

    NO seguimos redirects a proposito: un redirect al walled garden es
    precisamente la senal de "portal / expirado" que queremos detectar.
    """

    class _NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a, **k):
            return None  # no seguir; el 30x lo trataremos como portal.

    handlers = [_NoRedirect()]
    if source_ip:
        handlers.insert(0, _BindToIPHTTPHandler(source_ip))
        log.info("bind de peticiones a IP origen %s (best-effort)", source_ip)
    opener = urllib.request.build_opener(*handlers)
    opener.addheaders = [("User-Agent", USER_AGENT)]
    return opener


# ─── C1: clasificacion tri-estado del canary ────────────────────────────────
def clasificar_estado(opener, canary_url, canary_token, timeout):
    """HTTP-GET al canary y clasifica en STATE_ONLINE / STATE_OFFLINE / DOWN.

    Tri-estado (db_wifionice.py:71-85): solo distinguimos online/offline si
    la peticion EN SI tuvo exito; si falla a nivel de transporte devolvemos
    STATE_DOWN (None) y el llamador NO debe re-loguear.
    """
    req = urllib.request.Request(canary_url, method="GET")
    try:
        with opener.open(req, timeout=timeout) as resp:
            status = resp.getcode()
            cuerpo = resp.read(65536).decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        # Hubo respuesta HTTP (p.ej. 30x/40x): la sesion responde pero el
        # portal nos esta interceptando -> OFFLINE (expirado), no DOWN.
        log.debug("canary HTTPError %s -> offline", e.code)
        return STATE_OFFLINE
    except (urllib.error.URLError, socket.timeout, OSError) as e:
        # Fallo de transporte: timeout, sin ruta, connection refused.
        # WiFi caido -> DOWN. NO re-login.
        log.debug("canary fallo transporte (%s) -> DOWN", e)
        return STATE_DOWN

    # Tenemos cuerpo. Decidir online vs portal.
    if canary_token:
        return STATE_ONLINE if canary_token in cuerpo else STATE_OFFLINE
    # Sin token configurado: heuristica para endpoints tipo generate_204.
    # 204/2xx con cuerpo vacio o minusculo = internet real (online).
    # Cualquier HTML (el portal sirve una pagina) = offline.
    if 200 <= status < 300 and len(cuerpo.strip()) < 32:
        return STATE_ONLINE
    cuerpo_low = cuerpo.lower()
    if "<html" in cuerpo_low or "<form" in cuerpo_low or "login" in cuerpo_low:
        return STATE_OFFLINE
    # Por defecto, 2xx no-HTML lo tratamos como online.
    return STATE_ONLINE if 200 <= status < 300 else STATE_OFFLINE


# ─── C2: re-login estilo wifionice ──────────────────────────────────────────
def resolver_action(portal_url, form, form_action_override):
    """Calcula la URL absoluta del POST a partir del action del form."""
    if form_action_override:
        action = form_action_override
    else:
        action = form.get("action", "") if form else ""
    if not action:
        # Form sin action -> postear a la misma URL del portal (comportamiento
        # estandar de los navegadores).
        return portal_url
    return urllib.parse.urljoin(portal_url, action)


def re_login(opener, portal_url, form_id, form_action_override, timeout):
    """Ejecuta el re-login wifionice: GET portal -> parse inputs -> POST.

    Devuelve (ok, postdata, post_url) — postdata/post_url se exponen para
    que el test sintetico pueda inspeccionarlos.
    """
    if not portal_url:
        log.error("PORTAL_URL vacio: no se puede re-loguear (capturar form "
                  "real PlayRenfe a bordo). TODO REQ-NET-40.")
        return (False, {}, "")

    # 1. GET de la pagina del portal.
    try:
        req = urllib.request.Request(portal_url, method="GET")
        with opener.open(req, timeout=timeout) as resp:
            html_text = resp.read(262144).decode("utf-8", errors="replace")
    except (urllib.error.HTTPError, urllib.error.URLError,
            socket.timeout, OSError) as e:
        log.error("GET portal fallo: %s", e)
        return (False, {}, "")

    # 2. Parsear TODOS los <input> del form (incl. hidden como CSRFToken).
    forms = parsear_forms(html_text)
    form = seleccionar_form(forms, form_id)
    if form is None:
        log.error("no se encontro ningun <form> en el portal")
        return (False, {}, "")

    postdata = dict(form["inputs"])  # copia de los inputs (echo de hidden).
    # Forzar login=true (wifionice usa este marcador para autenticar).
    postdata.setdefault("login", "true")
    log.info("form parseado: %d inputs (%s)",
             len(form["inputs"]), ",".join(sorted(form["inputs"].keys())))

    # 3. Re-POST de los inputs a la action del form.
    post_url = resolver_action(portal_url, form, form_action_override)
    # Guarda anti-SSRF: el HTML del portal es contenido NO confiable (la WiFi
    # del tren MitM-ea HTTP). Un portal malicioso podria fijar action="http://
    # evil/" y robar los inputs (que pueden incluir tokens). Solo posteamos al
    # mismo host del portal (o al action_override explicito del operador).
    if not form_action_override:
        portal_host = urllib.parse.urlparse(portal_url).hostname
        post_host = urllib.parse.urlparse(post_url).hostname
        if post_host and portal_host and post_host != portal_host:
            log.error("re-login ABORTADO: action apunta a host distinto "
                      "(%s != %s) — posible portal falso/MitM",
                      post_host, portal_host)
            return (False, postdata, post_url)
    body = urllib.parse.urlencode(postdata).encode("utf-8")
    try:
        req = urllib.request.Request(
            post_url, data=body, method="POST",
            headers={"Content-Type": "application/x-www-form-urlencoded",
                     "Referer": portal_url},
        )
        with opener.open(req, timeout=timeout) as resp:
            ok = 200 <= resp.getcode() < 400
    except urllib.error.HTTPError as e:
        # 30x cuenta como respuesta del portal (a menudo redirige tras login).
        ok = 300 <= e.code < 400
    except (urllib.error.URLError, socket.timeout, OSError) as e:
        log.error("POST login fallo: %s", e)
        return (False, postdata, post_url)

    log.info("re-login POST a %s -> %s", post_url, "OK" if ok else "rechazado")
    return (ok, postdata, post_url)


# ─── PID file / idempotencia / senales ──────────────────────────────────────
def pid_vivo():
    """Devuelve el PID del daemon si hay uno vivo, si no None."""
    if not os.path.exists(PID_FILE):
        return None
    try:
        with open(PID_FILE) as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)  # senal 0 = comprobar existencia.
        return pid
    except (ValueError, ProcessLookupError, PermissionError, OSError):
        return None


def escribir_pid():
    os.makedirs(GENERATED_DIR, exist_ok=True)
    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))


def borrar_pid():
    try:
        os.remove(PID_FILE)
    except OSError:
        pass


def detener_daemon():
    """Mata el daemon vivo (si lo hay) via SIGTERM."""
    pid = pid_vivo()
    if pid is None:
        print("captive-watchdog: no hay daemon vivo")
        return 1
    os.kill(pid, signal.SIGTERM)
    print(f"captive-watchdog: SIGTERM enviado a PID {pid}")
    return 0


# ─── Bucle principal C1+C2 ──────────────────────────────────────────────────
def bucle(cfg, opener):
    """Loop tri-estado: probe -> clasifica -> en offline re-loguea."""
    estado_previo = None
    while True:
        estado = clasificar_estado(
            opener, cfg.canary_url, cfg.canary_token, cfg.timeout)

        if estado != estado_previo:
            etiqueta = estado if estado is not None else "DOWN(link-caido)"
            log.info("transicion de estado: %s -> %s",
                     estado_previo if estado_previo is not None
                     else "DOWN(link-caido)", etiqueta)
            estado_previo = estado

        if estado is STATE_DOWN:
            # WiFi caido: NO re-login (evita thrashing). Esperar.
            pass
        elif estado == STATE_OFFLINE:
            log.info("sesion expirada detectada -> re-login wifionice")
            ok, _postdata, _url = re_login(
                opener, cfg.portal_url, cfg.form_id,
                cfg.form_action, cfg.timeout)
            if ok:
                # Verificacion: re-probe inmediato del canary.
                verif = clasificar_estado(
                    opener, cfg.canary_url, cfg.canary_token, cfg.timeout)
                if verif == STATE_ONLINE:
                    log.info("re-login OK: canary vuelve a online")
                    estado_previo = STATE_ONLINE
                else:
                    log.warning("re-login enviado pero canary sigue %s",
                                verif if verif is not None else "DOWN")
            else:
                log.warning("re-login fallo; reintento en siguiente tick")

        if cfg.once:
            return estado
        time.sleep(cfg.poll_interval)


# ─── CLI ────────────────────────────────────────────────────────────────────
def _env(nombre, default):
    v = os.environ.get(nombre)
    return v if v is not None and v != "" else default


def parse_args(argv):
    p = argparse.ArgumentParser(
        description="Watchdog captive portal + re-login wifionice (REQ-NET-40)")
    p.add_argument("--canary-url", default=_env("CANARY_URL", DEFAULT_CANARY_URL))
    p.add_argument("--canary-token",
                   default=_env("CANARY_TOKEN", DEFAULT_CANARY_TOKEN))
    p.add_argument("--poll-interval", type=float,
                   default=float(_env("POLL_INTERVAL_S", DEFAULT_POLL_INTERVAL_S)))
    p.add_argument("--timeout", type=float,
                   default=float(_env("PROBE_TIMEOUT_S", DEFAULT_PROBE_TIMEOUT_S)))
    p.add_argument("--portal-url", default=_env("PORTAL_URL", DEFAULT_PORTAL_URL))
    p.add_argument("--form-id", default=_env("PORTAL_FORM_ID", ""))
    p.add_argument("--form-action", default=_env("PORTAL_FORM_ACTION", ""))
    p.add_argument("--wifi-iface", default=_env("WIFI_IFACE", ""))
    p.add_argument("--once", action="store_true",
                   help="un solo ciclo (probe + posible re-login) y sale")
    p.add_argument("--probe", action="store_true",
                   help="solo clasifica el estado del canary y sale")
    p.add_argument("--stop", action="store_true", help="detiene el daemon vivo")
    return p.parse_args(argv)


def main(argv=None):
    cfg = parse_args(sys.argv[1:] if argv is None else argv)
    configurar_logging()

    if cfg.stop:
        return detener_daemon()

    source_ip = ip_de_interfaz(cfg.wifi_iface)
    opener = construir_opener(source_ip, cfg.timeout)

    # --probe: clasifica y sale (util para tests/debug, no toca PID file).
    if cfg.probe:
        estado = clasificar_estado(
            opener, cfg.canary_url, cfg.canary_token, cfg.timeout)
        etiqueta = estado if estado is not None else "DOWN"
        print(etiqueta)
        log.info("probe -> %s", etiqueta)
        return 0

    # Idempotencia: si ya hay un daemon vivo, no arrancamos otro.
    if not cfg.once:
        otro = pid_vivo()
        if otro is not None:
            log.error("ya hay un captive-watchdog vivo (PID %s); aborto", otro)
            return 1
        escribir_pid()

    # Limpieza ante senales.
    def _terminar(signum, _frame):
        log.info("senal %s recibida; terminando limpio", signum)
        borrar_pid()
        sys.exit(0)

    signal.signal(signal.SIGTERM, _terminar)
    signal.signal(signal.SIGINT, _terminar)

    log.info("arrancado: canary=%s portal=%s interval=%.1fs timeout=%.1fs "
             "iface=%s", cfg.canary_url, cfg.portal_url or "(sin portal)",
             cfg.poll_interval, cfg.timeout, cfg.wifi_iface or "(default)")
    try:
        bucle(cfg, opener)
    finally:
        if not cfg.once:
            borrar_pid()
    return 0


if __name__ == "__main__":
    sys.exit(main())
