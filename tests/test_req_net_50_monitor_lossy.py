"""Tests pytest para REQ-NET-50 — 08-monitor.py: enlaces LOSSY (~) de ubond.

ubond escribe en el título del proceso '@' (UBOND_AUTHOK), '~' (UBOND_LOSSY) y
'!' (resto). El monitor solo parseaba '@' y '!': un enlace '~' desaparecía del
diccionario y draw() lo pintaba como SIN TUNEL aunque seguía recibiendo.

La ruta de 08-monitor.py se puede sustituir con la variable de entorno
AVE_MONITOR_PATH (para comprobar que estos tests fallan contra una copia del
código anterior al fix).
"""
import importlib.util
import os
import re
from unittest.mock import patch

import pytest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MONITOR_PATH = os.environ.get("AVE_MONITOR_PATH") or os.path.join(REPO_ROOT, "08-monitor.py")

IFACES = {"IFACE_IPHONE": "en8", "IFACE_PIXEL": "en12", "IFACE_WIFI": "en0"}


@pytest.fixture(scope="module")
def monitor():
    spec = importlib.util.spec_from_file_location("ave_monitor_req50", MONITOR_PATH)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def _links(monitor, output):
    with patch.object(monitor.subprocess, "check_output", return_value=output):
        return monitor.check_daemon_links("ubond")


def _draw(monitor, capsys, links, replicate_active=True):
    """Ejecuta draw() con las tres interfaces con IP y devuelve stdout sin ANSI."""
    with patch.object(monitor.os, "system", return_value=0), \
         patch.object(monitor, "get_link_ifaces", return_value=IFACES), \
         patch.object(monitor, "get_interface_ip", return_value="192.168.1.50"):
        monitor.draw("ubond", {}, {}, 1.0, links, "utun7", 1, {}, replicate_active)
    return re.sub(r"\033\[[0-9;]*m", "", capsys.readouterr().out)


def _row(out, label):
    return next(ln for ln in out.splitlines() if ln.strip().startswith(label))


def test_tilde_se_parsea_como_lossy(monitor):
    out = "ubond: ubond0 ~links.iphone\n"
    assert _links(monitor, out) == {"links.iphone": "LOSSY"}


def test_titulo_mixto_arroba_tilde_y_admiracion(monitor):
    out = "ubond: ubond0 !links.wifi @links.pixel ~links.iphone\n"
    assert _links(monitor, out) == {
        "links.wifi": "AUTH_PENDING",
        "links.pixel": "OK",
        "links.iphone": "LOSSY",
    }


def test_reproduccion_del_defecto_no_pierde_enlaces(monitor):
    """Caso reproducido por el lead: antes devolvía solo links.pixel."""
    out = "ubond: ubond0 ~links.wifi @links.pixel ~links.iphone\n"
    assert _links(monitor, out) == {
        "links.wifi": "LOSSY",
        "links.pixel": "OK",
        "links.iphone": "LOSSY",
    }


def test_linea_priv_se_ignora(monitor):
    out = (
        "root 1 0.0 0.0 ubond: ubond0 [priv] ~links.iphone\n"
        "root 2 0.0 0.0 ubond: ubond0 @links.pixel\n"
    )
    assert _links(monitor, out) == {"links.pixel": "OK"}


def test_draw_lossy_no_dice_sin_tunel(monitor, capsys):
    out = _draw(monitor, capsys, {"links.iphone": "LOSSY", "links.pixel": "OK"})
    row = _row(out, "iPhone")
    assert "SIN TUNEL" not in row
    assert "PÉRDIDAS ~" in row
    # el enlace realmente ausente sigue diciendo SIN TUNEL
    assert "SIN TUNEL" in _row(out, "WiFi")


def test_draw_lossy_distinto_de_ok_y_pendiente(monitor, capsys):
    out = _draw(monitor, capsys, {
        "links.iphone": "LOSSY", "links.pixel": "OK", "links.wifi": "AUTH_PENDING",
    })
    assert "ACTIVO" in _row(out, "Pixel")
    assert "AUTH..." in _row(out, "WiFi")
    assert "PÉRDIDAS ~" in _row(out, "iPhone")
    assert "ACTIVO" not in _row(out, "iPhone")


def test_draw_lossy_no_cuenta_como_enlace_activo(monitor, capsys):
    """ubond no planifica ni replica sobre un enlace LOSSY: no suma al resumen."""
    out = _draw(monitor, capsys, {"links.iphone": "LOSSY", "links.pixel": "OK"})
    assert "REPLICATE degradado (1 enlace)" in out
    assert "REPLICATE ACTIVO" not in out


def test_draw_lossy_mantiene_ancho_de_columnas(monitor, capsys):
    out = _draw(monitor, capsys, {"links.iphone": "LOSSY", "links.pixel": "OK"})
    ok = _row(out, "Pixel")
    lossy = _row(out, "iPhone")
    assert ok.index("192.168.1.50") == lossy.index("192.168.1.50")
