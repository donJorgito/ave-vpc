#!/bin/sh
# Validates ave-vpc.REQ-NET-31: 08-monitor.py dual-mode mlvpn/ubond.
# Combina static checks (file present, syntax) con import-level Python
# tests usando unittest.mock para 4 escenarios de detect_daemon.
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-31_monitor_dual_mode"

ROOT="$(dirname "$0")/.."
MONITOR="${ROOT}/08-monitor.py"

# 1. Script existe y es ejecutable.
if [ -x "${MONITOR}" ]; then
    junit_pass "monitor_executable"
else
    junit_fail "monitor_missing" "08-monitor.py no existe o no es ejecutable"
    junit_finalize
fi

# 2. py_compile pasa.
if python3 -m py_compile "${MONITOR}" 2>/dev/null; then
    junit_pass "py_compile_ok"
else
    junit_fail "py_compile_fail" "python3 -m py_compile 08-monitor.py FALLA"
    junit_finalize
fi

# 3. DAEMON_INFO contiene mlvpn Y ubond. (Import-level check)
if python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('m', '${MONITOR}')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
assert 'mlvpn' in m.DAEMON_INFO, 'DAEMON_INFO missing mlvpn'
assert 'ubond' in m.DAEMON_INFO, 'DAEMON_INFO missing ubond'
" 2>/dev/null; then
    junit_pass "daemon_info_has_both"
else
    junit_fail "daemon_info_missing" "DAEMON_INFO no contiene mlvpn y ubond"
fi

# 4. DAEMON_INFO entries tienen subkeys requeridos.
if python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('m', '${MONITOR}')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
required_keys = {'tun_subnet', 'proc_pattern', 'active_conf', 'connect_hint', 'header_label', 'tunnel_label'}
for daemon in ('mlvpn', 'ubond'):
    actual = set(m.DAEMON_INFO[daemon].keys())
    missing = required_keys - actual
    assert not missing, f'{daemon} missing keys: {missing}'
" 2>/dev/null; then
    junit_pass "daemon_info_subkeys"
else
    junit_fail "daemon_info_subkeys_missing" \
        "DAEMON_INFO entries no tienen todos los subkeys requeridos"
fi

# 5-8. detect_daemon retorna tupla correcta en 4 escenarios via mock.
# Caso A: solo ubond vivo → ('ubond', False).
# Caso B: solo mlvpn vivo → ('mlvpn', False).
# Caso C: ambos vivos → ('ubond', True) — preferencia + warning flag.
# Caso D: ninguno → (None, False).
if python3 -c "
import importlib.util
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('m', '${MONITOR}')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

# A: solo ubond
with patch.object(m.subprocess, 'check_output', return_value='ubond: ubond0 @links.iphone\nother proc\n'):
    r = m.detect_daemon()
    assert r == ('ubond', False), f'A failed: {r}'

# B: solo mlvpn
with patch.object(m.subprocess, 'check_output', return_value='mlvpn: mlvpn0 @links.iphone\nother proc\n'):
    r = m.detect_daemon()
    assert r == ('mlvpn', False), f'B failed: {r}'

# C: ambos
with patch.object(m.subprocess, 'check_output', return_value='ubond: ubond0 @links.iphone\nmlvpn: mlvpn0 @links.iphone\n'):
    r = m.detect_daemon()
    assert r == ('ubond', True), f'C failed: {r}'

# D: ninguno
with patch.object(m.subprocess, 'check_output', return_value='other proc\n'):
    r = m.detect_daemon()
    assert r == (None, False), f'D failed: {r}'
" 2>/dev/null; then
    junit_pass "detect_daemon_4_scenarios"
else
    junit_fail "detect_daemon_wrong" \
        "detect_daemon falla en al menos uno de los 4 escenarios mockeados"
fi

# 9. check_failover_roles early-return {} para daemon != mlvpn.
if python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('m', '${MONITOR}')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
assert m.check_failover_roles('ubond') == {}, 'failover_roles should be {} for ubond'
" 2>/dev/null; then
    junit_pass "failover_roles_ubond_empty"
else
    junit_fail "failover_roles_ubond_not_empty" \
        "check_failover_roles('ubond') no retorna {} (debería early-return)"
fi

# 10. check_replicate_active early-return False para daemon != ubond.
if python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('m', '${MONITOR}')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
assert m.check_replicate_active('mlvpn') is False, 'replicate_active should be False for mlvpn'
" 2>/dev/null; then
    junit_pass "replicate_active_mlvpn_false"
else
    junit_fail "replicate_active_mlvpn_not_false" \
        "check_replicate_active('mlvpn') no retorna False (debería early-return)"
fi

# 11. Backwards compat v1: subnet mlvpn = 10.10.10. y ubond = 10.10.20.
if python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('m', '${MONITOR}')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
assert m.DAEMON_INFO['mlvpn']['tun_subnet'] == '10.10.10.', 'mlvpn subnet wrong'
assert m.DAEMON_INFO['ubond']['tun_subnet'] == '10.10.20.', 'ubond subnet wrong'
" 2>/dev/null; then
    junit_pass "subnet_correct_per_daemon"
else
    junit_fail "subnet_wrong" \
        "tun_subnet no es 10.10.10. para mlvpn y 10.10.20. para ubond"
fi

junit_finalize
