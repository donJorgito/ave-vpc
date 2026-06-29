"""Tests pytest para REQ-NET-31 — 08-monitor.py dual-mode mlvpn/ubond.

Cubre lo mismo que el shell wrapper test_REQ-NET-31_monitor_dual_mode.sh
pero con pytest puro + fixtures + unittest.mock — habilita coverage real
(REQ-NET-33 Fase 1).

Loadea 08-monitor.py via importlib (no es importable normal porque tiene
guion en el nombre y no termina en .py importable). Cada test mockea
subprocess.check_output / open / etc. para aislar.
"""
import importlib.util
import os
from unittest.mock import patch

import pytest


REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MONITOR_PATH = os.path.join(REPO_ROOT, "08-monitor.py")


@pytest.fixture(scope="module")
def monitor():
    """Carga 08-monitor.py una vez por módulo de tests."""
    spec = importlib.util.spec_from_file_location("ave_monitor", MONITOR_PATH)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


# ─── DAEMON_INFO structure ──────────────────────────────────────────────


def test_daemon_info_has_both_daemons(monitor):
    assert "mlvpn" in monitor.DAEMON_INFO
    assert "ubond" in monitor.DAEMON_INFO


def test_daemon_info_required_subkeys(monitor):
    required = {
        "tun_subnet",
        "proc_pattern",
        "active_conf",
        "connect_hint",
        "header_label",
        "tunnel_label",
    }
    for daemon in ("mlvpn", "ubond"):
        actual = set(monitor.DAEMON_INFO[daemon].keys())
        missing = required - actual
        assert not missing, f"{daemon} missing keys: {missing}"


def test_subnet_correct_per_daemon(monitor):
    assert monitor.DAEMON_INFO["mlvpn"]["tun_subnet"] == "10.10.10."
    assert monitor.DAEMON_INFO["ubond"]["tun_subnet"] == "10.10.20."


def test_proc_pattern_no_collision(monitor):
    """mlvpn y ubond tienen procnames distintos — el pattern de uno no
    debe matchear el otro."""
    mlvpn_pat = monitor.DAEMON_INFO["mlvpn"]["proc_pattern"]
    ubond_pat = monitor.DAEMON_INFO["ubond"]["proc_pattern"]
    assert mlvpn_pat not in ubond_pat
    assert ubond_pat not in mlvpn_pat


# ─── detect_daemon — 4 escenarios ───────────────────────────────────────


def test_detect_daemon_only_ubond(monitor):
    output = "ubond: ubond0 @links.iphone @links.pixel\nother proc\n"
    with patch.object(monitor.subprocess, "check_output", return_value=output):
        assert monitor.detect_daemon() == ("ubond", False)


def test_detect_daemon_only_mlvpn(monitor):
    output = "mlvpn: mlvpn0 @links.iphone\nother proc\n"
    with patch.object(monitor.subprocess, "check_output", return_value=output):
        assert monitor.detect_daemon() == ("mlvpn", False)


def test_detect_daemon_both_alive_warns(monitor):
    output = (
        "ubond: ubond0 @links.iphone\n"
        "mlvpn: mlvpn0 @links.iphone\n"
        "other proc\n"
    )
    with patch.object(monitor.subprocess, "check_output", return_value=output):
        # Ambos vivos → preferencia ubond + flag warning True
        assert monitor.detect_daemon() == ("ubond", True)


def test_detect_daemon_neither_alive(monitor):
    output = "other proc\nyet another\n"
    with patch.object(monitor.subprocess, "check_output", return_value=output):
        assert monitor.detect_daemon() == (None, False)


def test_detect_daemon_ignores_priv_processes(monitor):
    """[priv] processes no deben contar como vivo (es child auxiliar)."""
    output = "ubond: ubond0 [priv]\nother proc\n"
    with patch.object(monitor.subprocess, "check_output", return_value=output):
        assert monitor.detect_daemon() == (None, False)


def test_detect_daemon_subprocess_failure(monitor):
    """Si subprocess.check_output lanza, devuelve (None, False) — no crash."""
    with patch.object(
        monitor.subprocess, "check_output", side_effect=OSError("boom")
    ):
        assert monitor.detect_daemon() == (None, False)


# ─── early-returns por daemon ───────────────────────────────────────────


def test_check_failover_roles_ubond_returns_empty(monitor):
    """failover roles solo aplica a mlvpn — para ubond debe early-return {}."""
    assert monitor.check_failover_roles("ubond") == {}


def test_check_replicate_active_mlvpn_returns_false(monitor):
    """replicate active solo aplica a ubond — para mlvpn debe ser False."""
    assert monitor.check_replicate_active("mlvpn") is False


# ─── check_daemon_links parsea correctamente proctitle ──────────────────


def test_check_daemon_links_parses_authed_and_pending(monitor):
    """proctitle con @links.X (authed) y !links.Y (pending) genera dict
    con states correctos."""
    output = "ubond: ubond0 @links.pixel @links.iphone !links.wifi\n"
    with patch.object(monitor.subprocess, "check_output", return_value=output):
        result = monitor.check_daemon_links("ubond")
        assert result.get("links.pixel") == "OK"
        assert result.get("links.iphone") == "OK"
        assert result.get("links.wifi") == "AUTH_PENDING"


def test_check_daemon_links_no_match_returns_empty(monitor):
    """Si el daemon no está en el output, devuelve {}."""
    output = "completely unrelated\n"
    with patch.object(monitor.subprocess, "check_output", return_value=output):
        assert monitor.check_daemon_links("ubond") == {}


# ─── find_tunnel_utun parsea ifconfig por subnet ───────────────────────


def test_find_tunnel_utun_finds_ubond_subnet(monitor):
    """ifconfig output con utun7 que tiene 10.10.20.x → devuelve 'utun7'."""
    output = (
        "utun5: flags=8051 mtu 1400\n"
        "\tinet 10.10.10.2 --> 10.10.10.1\n"
        "utun7: flags=8051 mtu 1400\n"
        "\tinet 10.10.20.2 --> 10.10.20.1\n"
    )
    with patch.object(monitor.subprocess, "check_output", return_value=output):
        assert monitor.find_tunnel_utun("ubond") == "utun7"
        # Y para mlvpn encuentra utun5 (subnet 10.10.10.)
        assert monitor.find_tunnel_utun("mlvpn") == "utun5"


def test_find_tunnel_utun_not_found_returns_none(monitor):
    """Sin ningún utun matching → devuelve None."""
    output = "utun5: flags=8051 mtu 1400\n\tinet 10.99.99.1 --> 10.99.99.2\n"
    with patch.object(monitor.subprocess, "check_output", return_value=output):
        assert monitor.find_tunnel_utun("ubond") is None


# ─── fmt helpers ────────────────────────────────────────────────────────


def test_fmt_bytes_thresholds(monitor):
    assert monitor.fmt_bytes(0).endswith("B/s")
    assert monitor.fmt_bytes(500).endswith("B/s")
    assert monitor.fmt_bytes(1500).endswith("KB/s")
    assert monitor.fmt_bytes(2_500_000).endswith("MB/s")


def test_fmt_total_thresholds(monitor):
    assert monitor.fmt_total(0).endswith("B")
    assert monitor.fmt_total(2048).endswith("KB")
    assert monitor.fmt_total(2_000_000).endswith("MB")
    assert monitor.fmt_total(2_000_000_000).endswith("GB")


# ─── get_interface_stats — netstat parsing ──────────────────────────────


def test_get_interface_stats_parses_physical_and_utun(monitor):
    """netstat -ibn formato dual: físicas (con MAC) y utuns (sin MAC).
    El parser debe leer Ibytes/Obytes correctamente en ambos casos."""
    netstat_output = (
        "Name  Mtu   Network       Address              Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll\n"
        "en0   1500  <Link#5>      aa:bb:cc:dd:ee:ff   1234  0      567890   2345  0      678901   0\n"
        "utun7 1400  <Link#19>                          100   0       50000   200   0       60000   0\n"
        "lo0   16384 <Link#1>                          5000  0      999999   5000  0      999999   0\n"
    )
    with patch.object(
        monitor.subprocess, "check_output", return_value=netstat_output
    ):
        stats = monitor.get_interface_stats()
        # Físicas: offset 4 (después de MAC).
        assert stats["en0"] == (567890, 678901)
        # utun: offset 3 (sin MAC).
        assert stats["utun7"] == (50000, 60000)
        assert stats["lo0"] == (999999, 999999)


def test_get_interface_stats_subprocess_failure_returns_empty(monitor):
    with patch.object(
        monitor.subprocess, "check_output", side_effect=OSError("boom")
    ):
        assert monitor.get_interface_stats() == {}


def test_get_interface_ip_returns_value(monitor):
    with patch.object(
        monitor.subprocess, "check_output", return_value="172.20.10.4\n"
    ):
        assert monitor.get_interface_ip("en8") == "172.20.10.4"


def test_get_interface_ip_failure_returns_none(monitor):
    with patch.object(
        monitor.subprocess, "check_output", side_effect=OSError("boom")
    ):
        assert monitor.get_interface_ip("en8") is None


# ─── check_failover_roles — full path mlvpn ─────────────────────────────


def test_check_failover_roles_mlvpn_with_backup(monitor, tmp_path):
    """conf con un link fallback_only=1 → roles assigned active/backup."""
    conf_content = (
        "[general]\n"
        "mode = client\n"
        "[links.iphone]\n"
        "bindhost = 0.0.0.0\n"
        "[links.pixel]\n"
        "bindhost = 0.0.0.0\n"
        "fallback_only = 1\n"
    )
    # Crear conf en path esperado por el script (generated/mlvpn_active.conf).
    generated = tmp_path / "generated"
    generated.mkdir()
    conf_path = generated / "mlvpn_active.conf"
    conf_path.write_text(conf_content)

    # Mockear el __file__ del módulo para que generated/ apunte a tmp_path.
    with patch.object(monitor.os.path, "abspath", return_value=str(tmp_path / "08-monitor.py")):
        roles = monitor.check_failover_roles("mlvpn")

    # iphone activo, pixel backup (porque tiene fallback_only=1).
    assert roles.get("links.iphone") == "active"
    assert roles.get("links.pixel") == "backup"


def test_check_failover_roles_mlvpn_no_backup_returns_empty(monitor, tmp_path):
    """conf sin ningún fallback_only=1 → bonding clásico, devuelve {}."""
    conf_content = (
        "[links.iphone]\nbindhost = 0.0.0.0\n"
        "[links.pixel]\nbindhost = 0.0.0.0\n"
    )
    generated = tmp_path / "generated"
    generated.mkdir()
    (generated / "mlvpn_active.conf").write_text(conf_content)

    with patch.object(monitor.os.path, "abspath", return_value=str(tmp_path / "08-monitor.py")):
        assert monitor.check_failover_roles("mlvpn") == {}


def test_check_failover_roles_mlvpn_missing_conf_returns_empty(monitor, tmp_path):
    """conf no existe → devuelve {} sin crash."""
    with patch.object(monitor.os.path, "abspath", return_value=str(tmp_path / "08-monitor.py")):
        assert monitor.check_failover_roles("mlvpn") == {}


# ─── check_replicate_active — full path ubond ───────────────────────────


def test_check_replicate_active_ubond_with_rules(monitor, tmp_path):
    """conf con regla en [filters.replicate] → True."""
    conf_content = (
        "[general]\nmode = client\n"
        "[filters.replicate]\n"
        'icmp_all = "icmp"\n'
    )
    generated = tmp_path / "generated"
    generated.mkdir()
    (generated / "ubond.conf").write_text(conf_content)

    with patch.object(monitor.os.path, "abspath", return_value=str(tmp_path / "08-monitor.py")):
        assert monitor.check_replicate_active("ubond") is True


def test_check_replicate_active_ubond_empty_section_returns_false(monitor, tmp_path):
    """conf con [filters.replicate] vacío → False."""
    conf_content = (
        "[general]\nmode = client\n"
        "[filters.replicate]\n"
        "[links.iphone]\nbindhost = 0.0.0.0\n"
    )
    generated = tmp_path / "generated"
    generated.mkdir()
    (generated / "ubond.conf").write_text(conf_content)

    with patch.object(monitor.os.path, "abspath", return_value=str(tmp_path / "08-monitor.py")):
        assert monitor.check_replicate_active("ubond") is False


def test_check_replicate_active_ubond_only_comments_returns_false(monitor, tmp_path):
    """conf con solo comentarios en [filters.replicate] → False."""
    conf_content = (
        "[filters.replicate]\n"
        "# icmp_all = \"icmp\"\n"
        "# zoom = \"udp port 3478\"\n"
        "[links.iphone]\nbindhost = 0.0.0.0\n"
    )
    generated = tmp_path / "generated"
    generated.mkdir()
    (generated / "ubond.conf").write_text(conf_content)

    with patch.object(monitor.os.path, "abspath", return_value=str(tmp_path / "08-monitor.py")):
        assert monitor.check_replicate_active("ubond") is False


def test_check_replicate_active_ubond_no_conf_returns_false(monitor, tmp_path):
    """Sin ubond.conf ni ubond_active.conf → False."""
    with patch.object(monitor.os.path, "abspath", return_value=str(tmp_path / "08-monitor.py")):
        assert monitor.check_replicate_active("ubond") is False
