#!/usr/bin/env python3
###############################################################################
# 08-monitor.py — Monitor TUI real-time de bonding mlvpn (v1) o ubond (v2)
#
# DONDE SE EJECUTA: En tu Mac (con mlvpn o ubond activo)
#
# QUE MUESTRA (auto-adapta según daemon detectado):
#   v1 mlvpn:
#     - Modo BONDING o FAILOVER (lee fallback_only de mlvpn_active.conf)
#     - Throughput utun (10.10.10.2) + por enlace físico
#     - Estado links: ACTIVO / AUTH... / sin IP
#   v2 ubond:
#     - Modo BONDING o REPLICATE (detecta [filters.replicate] activa)
#     - Throughput utun (10.10.20.2) + por enlace físico
#     - Estado links: ACTIVO / AUTH... / sin IP
#
# USO:
#   ./08-monitor.py                    # auto-detect mlvpn o ubond
#   ./08-monitor.py --daemon mlvpn     # forzar v1
#   ./08-monitor.py --daemon ubond     # forzar v2
#   ./08-monitor.py --interval 2       # tick 2s (default 1s)
#
# REQUISITOS:
#   - Python 3 (incluido en macOS)
#   - mlvpn vivo (./04-conectar.sh) o ubond vivo (./04b-conectar-ubond.sh)
#
# COMPLEMENTARIO A tools/ave-monitor.sh:
#   - 08-monitor.py: TUI real-time para uso humano interactivo durante
#     viaje. No persiste — clear() cada tick. Útil cuando quieres VER
#     el estado en directo.
#   - tools/ave-monitor.sh: NDJSON logger background para forensic
#     post-incident (ALCOA++). No tiene display, escribe a fichero.
#     Útil para reconstruir QUÉ pasó después.
#   Pueden correr simultáneamente sin interferir.
###############################################################################

import sys
import time
import subprocess
import os
import re
import argparse


# ─── Colores ──────────────────────────────────────────────────────────────────
RESET  = '\033[0m'
BOLD   = '\033[1m'
GREEN  = '\033[92m'
YELLOW = '\033[93m'
RED    = '\033[91m'
CYAN   = '\033[96m'
DIM    = '\033[2m'
BLUE   = '\033[94m'


# ─── Daemon abstraction ───────────────────────────────────────────────────────
# Toda la diferencia v1/v2 vive aquí. Si añades daemons (ej. wireguard),
# añade entrada con sus parámetros y el resto del script lo soporta.
DAEMON_INFO = {
    'mlvpn': {
        'tun_subnet': '10.10.10.',
        'tun_ip': '10.10.10.2',
        'proc_pattern': 'mlvpn: mlvpn0',
        'active_conf': 'mlvpn_active.conf',
        'header_label': 'mlvpn v1 monitor',
        'tunnel_label': 'TÚNEL mlvpn',
        'connect_hint': './04-conectar.sh',
    },
    'ubond': {
        'tun_subnet': '10.10.20.',
        'tun_ip': '10.10.20.2',
        'proc_pattern': 'ubond: ubond0',
        'active_conf': 'ubond_active.conf',
        'header_label': 'ubond v2 monitor',
        'tunnel_label': 'TÚNEL ubond',
        'connect_hint': './04b-conectar-ubond.sh',
    },
}


def detect_daemon():
    """Auto-detecta qué daemon está corriendo. Si ambos vivos: prefiere
    ubond (v2 es el target post-migración) Y emite warning explícito
    porque indica estado anómalo (transición v1→v2 incompleta o SOS
    fallido). Si ninguno: None.

    Devuelve tupla (daemon, both_alive_warning).
    """
    try:
        out = subprocess.check_output(['ps', 'aux'], text=True)
    except Exception:
        return (None, False)
    has_ubond = any(
        'ubond: ubond0' in line and '[priv]' not in line
        for line in out.splitlines()
    )
    has_mlvpn = any(
        'mlvpn: mlvpn0' in line and '[priv]' not in line
        for line in out.splitlines()
    )
    if has_ubond and has_mlvpn:
        return ('ubond', True)
    if has_ubond:
        return ('ubond', False)
    if has_mlvpn:
        return ('mlvpn', False)
    return (None, False)


def get_interface_stats():
    """Lee bytes in/out de todas las interfaces via netstat -ibn.

    netstat -ibn varía las columnas según la interfaz:
      - Físicas (con MAC):    name mtu <Link#N> MAC  Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll  (11 cols)
      - utun/lo0 (sin MAC):   name mtu <Link#N>      Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll  (10 cols)

    Detectamos si parts[3] es una MAC (5 ':') para desplazar el offset y leer Ibytes/Obytes
    correctamente en ambos casos. Esto es lo que permite leer el utun directamente.
    """
    try:
        out = subprocess.check_output(['netstat', '-ibn'], text=True)
    except Exception:
        return {}
    stats = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 9 or '<Link#' not in line:
            continue
        # netstat añade '*' al nombre cuando la interfaz tiene flag UP en estado
        # transitorio. Lo eliminamos para que el lookup contra ifconfig coincida.
        iface = parts[0].rstrip('*')
        # Si parts[3] tiene formato MAC (xx:xx:xx:xx:xx:xx), los counters empiezan en [4]
        # Si no (utun, lo0), empiezan en [3]
        offset = 4 if len(parts) > 3 and parts[3].count(':') == 5 else 3
        try:
            ibytes = int(parts[offset + 2])
            obytes = int(parts[offset + 5])
            stats[iface] = (ibytes, obytes)
        except (ValueError, IndexError):
            continue
    return stats


def get_interface_ip(iface):
    """Obtiene la IP de una interfaz."""
    try:
        out = subprocess.check_output(['ipconfig', 'getifaddr', iface],
                                      text=True, stderr=subprocess.DEVNULL)
        return out.strip()
    except Exception:
        return None


def find_tunnel_utun(daemon):
    """Busca el utun que el daemon dado está usando (subnet específica
    por daemon: 10.10.10.x para mlvpn, 10.10.20.x para ubond)."""
    subnet = DAEMON_INFO[daemon]['tun_subnet']
    try:
        out = subprocess.check_output(['ifconfig'], text=True)
        current = None
        for line in out.splitlines():
            m = re.match(r'^(utun\d+):', line)
            if m:
                current = m.group(1)
            if current and subnet in line:
                return current
    except Exception:
        pass
    return None


def check_daemon_links(daemon):
    """Obtiene el estado de los links del daemon desde el nombre del proceso.
    El proctitle de mlvpn/ubond tiene la forma:
      'mlvpn: mlvpn0 @links.iphone @links.pixel !links.wifi ...'
    @ = autenticado, ! = autenticación pendiente.
    """
    pattern = DAEMON_INFO[daemon]['proc_pattern']
    try:
        out = subprocess.check_output(['ps', 'aux'], text=True)
        for line in out.splitlines():
            if pattern in line and '[priv]' not in line:
                authed = re.findall(r'@(links\.\w+)', line)
                pending = re.findall(r'!(links\.\w+)', line)
                return {l: 'OK' for l in authed} | {l: 'AUTH_PENDING' for l in pending}
    except Exception:
        pass
    return {}


def check_failover_roles(daemon):
    """Lee mlvpn_active.conf y devuelve {link_key: 'active'|'backup'} (REQ-NET-17).

    Solo aplica a mlvpn — ubond v2 no usa `fallback_only` (su modo
    failover/replicate se decide via [filters.replicate], no via marca
    por link). Si daemon != 'mlvpn', devuelve {} sin leer nada.

    Si algún link tiene `fallback_only = 1`, el túnel está en modo --failover
    (REQ-NET-11). En ese modo:
      - "active" = el link sin fallback_only=1 (lleva la carga real)
      - "backup" = links con fallback_only=1 (solo keepalives mlvpn ~1pkt/s)

    Devuelve dict vacío {} si no hay config, no se puede leer, o ningún link
    tiene fallback_only=1 (modo bonding clásico, no aplica distinción).
    """
    if daemon != 'mlvpn':
        return {}
    conf_path = os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        'generated', DAEMON_INFO[daemon]['active_conf']
    )
    if not os.path.exists(conf_path):
        return {}
    content = None
    try:
        with open(conf_path, 'r') as f:
            content = f.read()
    except (PermissionError, OSError):
        try:
            content = subprocess.check_output(
                ['sudo', '-n', 'cat', conf_path],
                text=True, stderr=subprocess.DEVNULL
            )
        except subprocess.CalledProcessError:
            return {}
    if not content:
        return {}

    roles = {}
    has_any_backup = False
    current_section = None
    for raw in content.splitlines():
        line = raw.strip()
        m = re.match(r'^\[links\.(\w+)\]', line)
        if m:
            current_section = f'links.{m.group(1)}'
            roles[current_section] = 'active'  # default si no aparece fallback_only
            continue
        if line.startswith('[') and current_section:
            current_section = None
            continue
        if current_section:
            m_fb = re.match(r'fallback_only\s*=\s*(\d+)', line)
            if m_fb:
                if m_fb.group(1) == '1':
                    roles[current_section] = 'backup'
                    has_any_backup = True
                else:
                    roles[current_section] = 'active'

    # Sin ningún backup → bonding clásico, no aplica distinción de roles
    return roles if has_any_backup else {}


def check_replicate_active(daemon):
    """Solo aplica a ubond: detecta si la sección [filters.replicate]
    tiene al menos una regla BPF activa (no comentada). Si sí → modo
    REPLICATE. Si no → bonding clásico.

    Lee primero generated/ubond_active.conf (si 04b lo creó) y cae a
    generated/ubond.conf como fallback. ubond_active.conf en sistemas
    reales suele ser 0600 root, así que probamos `sudo -n cat` (no
    interactivo: si no hay cache, fallback al .conf user-readable).
    """
    if daemon != 'ubond':
        return False
    base_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'generated')
    for name in ('ubond_active.conf', 'ubond.conf'):
        conf_path = os.path.join(base_dir, name)
        if not os.path.exists(conf_path):
            continue
        content = None
        try:
            with open(conf_path, 'r') as f:
                content = f.read()
        except (PermissionError, OSError):
            try:
                content = subprocess.check_output(
                    ['sudo', '-n', 'cat', conf_path],
                    text=True, stderr=subprocess.DEVNULL
                )
            except subprocess.CalledProcessError:
                continue
        if not content:
            continue
        in_replicate = False
        for raw in content.splitlines():
            line = raw.strip()
            if line == '[filters.replicate]':
                in_replicate = True
                continue
            if line.startswith('[') and in_replicate:
                in_replicate = False
                continue
            if in_replicate and line and not line.startswith('#') and '=' in line:
                return True
        return False
    return False


def fmt_bytes(b):
    """Formatea bytes/s de forma legible."""
    if b < 1000:
        return f'{b:.0f} B/s'
    elif b < 1_000_000:
        return f'{b/1000:.1f} KB/s'
    else:
        return f'{b/1_000_000:.2f} MB/s'


def fmt_total(b):
    """Formatea bytes totales."""
    if b < 1024:
        return f'{b} B'
    elif b < 1_048_576:
        return f'{b/1024:.1f} KB'
    elif b < 1_073_741_824:
        return f'{b/1_048_576:.2f} MB'
    else:
        return f'{b/1_073_741_824:.2f} GB'


def draw(daemon, prev_stats, curr_stats, interval, links_status, utun,
         iteration, failover_roles, replicate_active):
    """Dibuja la pantalla del monitor."""
    os.system('clear')

    info = DAEMON_INFO[daemon]
    is_failover = bool(failover_roles)
    is_replicate = bool(replicate_active)

    if is_failover:
        mode_str = f'{YELLOW}[FAILOVER]{RESET}'
    elif is_replicate:
        mode_str = f'{BLUE}[REPLICATE]{RESET}'
    else:
        mode_str = f'{GREEN}[BONDING]{RESET}'

    title = f'ave-vpc {info["header_label"]}'
    print(f'{BOLD}{CYAN}┌─ {title} ─────────────────────────────────────────┐{RESET}')
    print(f'{BOLD}{CYAN}│{RESET}  Tick {interval}s  •  Modo: {mode_str}  •  Ctrl+C para salir' + f'{BOLD}{CYAN}  │{RESET}')
    print(f'{BOLD}{CYAN}└─────────────────────────────────────────────────────────────────┘{RESET}')
    print()

    # ─── Estado del túnel ─────────────────────────────────────────────
    if utun:
        # Leemos los bytes directamente del utun (tráfico útil del túnel,
        # sin overhead UDP). En macOS, netstat -ibn sí captura los counters
        # del utun una vez parseado correctamente (ver get_interface_stats).
        p_utun = prev_stats.get(utun, (0, 0))
        c_utun = curr_stats.get(utun, (0, 0))
        agg_rx = max(0, c_utun[0] - p_utun[0]) / interval
        agg_tx = max(0, c_utun[1] - p_utun[1]) / interval
        print(f'{BOLD}  {info["tunnel_label"]}  {GREEN}●{RESET}  {utun}  IP: {BOLD}{info["tun_ip"]}{RESET}')
        print(f'  {"↓ RX":<18} {GREEN}{fmt_bytes(agg_rx):>10}{RESET}  {DIM}(tráfico útil del túnel){RESET}')
        print(f'  {"↑ TX":<18} {CYAN}{fmt_bytes(agg_tx):>10}{RESET}  {DIM}(tráfico útil del túnel){RESET}')
    else:
        print(f'  {RED}{info["tunnel_label"]}  ✗  No activo — ejecuta {info["connect_hint"]}{RESET}')
    print()

    # ─── Enlaces físicos ──────────────────────────────────────────────
    link_names = {
        'links.iphone': ('iPhone', 'en8'),
        'links.pixel':  ('Pixel',  'en12'),
        'links.wifi':   ('WiFi',   'en0'),
    }

    print(f'{BOLD}  ENLACES FÍSICOS{RESET}')
    if is_failover:
        # En modo failover, añadir columna Rol para distinguir A=activo, B=backup.
        # Los backup solo llevan keepalives mlvpn (~1 pkt/s) — su tráfico debe
        # ser ~0 KB/s. Si crece significativamente, hay bug en mlvpn fallback.
        print(f'  {"Enlace":<12} {"Estado":<16} {"Rol":<8} {"IP":<18} {"↓ RX":>10}  {"↑ TX":>10}')
        print(f'  {"─"*12} {"─"*16} {"─"*8} {"─"*18} {"─"*10}  {"─"*10}')
    else:
        print(f'  {"Enlace":<12} {"Estado":<16} {"IP":<18} {"↓ RX":>10}  {"↑ TX":>10}')
        print(f'  {"─"*12} {"─"*16} {"─"*18} {"─"*10}  {"─"*10}')

    active_count = 0
    failover_active_link = None
    for link_key, (label, iface) in link_names.items():
        ip = get_interface_ip(iface)
        link_status = links_status.get(link_key)
        role = failover_roles.get(link_key)  # 'active' | 'backup' | None

        if ip is None:
            status_str = f'{DIM}sin IP{RESET}'
            color = DIM
        elif link_status == 'OK':
            status_str = f'{GREEN}ACTIVO ●{RESET}'
            color = GREEN
            active_count += 1
        elif link_status == 'AUTH_PENDING':
            status_str = f'{YELLOW}AUTH...{RESET}'
            color = YELLOW
        else:
            status_str = f'{YELLOW}SIN TUNEL{RESET}'
            color = YELLOW

        p = prev_stats.get(iface, (0, 0))
        c = curr_stats.get(iface, (0, 0))
        rx = max(0, c[0] - p[0]) / interval if ip else 0
        tx = max(0, c[1] - p[1]) / interval if ip else 0

        ip_str = ip if ip else '–'

        if is_failover:
            if role == 'active':
                role_str = f'{GREEN}[A] ●{RESET}'
                failover_active_link = label
            elif role == 'backup':
                role_str = f'{BLUE}[B] ◌{RESET}'
            else:
                role_str = f'{DIM}─{RESET}'
            print(f'  {BOLD}{label:<12}{RESET} {status_str:<25} {role_str:<17} {DIM}{ip_str:<18}{RESET} '
                  f'{color}{fmt_bytes(rx):>10}{RESET}  {color}{fmt_bytes(tx):>10}{RESET}')
        else:
            print(f'  {BOLD}{label:<12}{RESET} {status_str:<25} {DIM}{ip_str:<18}{RESET} '
                  f'{color}{fmt_bytes(rx):>10}{RESET}  {color}{fmt_bytes(tx):>10}{RESET}')

    print()

    # ─── Resumen ──────────────────────────────────────────────────────
    if is_failover:
        if failover_active_link:
            summary_str = f'{YELLOW}FAILOVER{RESET}  •  activo: {GREEN}{failover_active_link}{RESET}'
        else:
            summary_str = f'{RED}FAILOVER sin activo (todos en backup){RESET}'
    elif is_replicate and active_count >= 2:
        summary_str = f'{BLUE}REPLICATE ACTIVO ({active_count} enlaces){RESET}'
    elif is_replicate:
        summary_str = f'{YELLOW}REPLICATE degradado ({active_count} enlace){RESET}'
    elif active_count >= 2:
        summary_str = f'{GREEN}BONDING ACTIVO ({active_count} enlaces){RESET}'
    elif active_count == 1:
        summary_str = f'{YELLOW}DEGRADADO (1 enlace){RESET}'
    else:
        summary_str = f'{RED}SIN BONDING{RESET}'

    print(f'  {summary_str}', end='')
    if utun:
        # En modo failover: sumar SOLO el activo. En bonding/replicate: suma de todos.
        # En failover, mostrar también keepalives de backups por separado para
        # confirmar que mlvpn los mantiene vivos (~1 pkt/s) sin enviar data.
        sum_active_rx = sum_active_tx = 0
        sum_backup_rx = sum_backup_tx = 0
        for link_key, (_, iface) in link_names.items():
            if not get_interface_ip(iface):
                continue
            p2 = prev_stats.get(iface, (0, 0))
            c2 = curr_stats.get(iface, (0, 0))
            d_rx = max(0, c2[0] - p2[0]) / interval
            d_tx = max(0, c2[1] - p2[1]) / interval
            if is_failover and failover_roles.get(link_key) == 'backup':
                sum_backup_rx += d_rx
                sum_backup_tx += d_tx
            else:
                sum_active_rx += d_rx
                sum_active_tx += d_tx
        if is_failover:
            print(f'  •  Activo {DIM}↓{fmt_bytes(sum_active_rx)} ↑{fmt_bytes(sum_active_tx)}{RESET}')
            print(f'  Backups (solo keepalives) {DIM}↓{fmt_bytes(sum_backup_rx)} ↑{fmt_bytes(sum_backup_tx)}{RESET}', end='')
        else:
            # En modo replicate, el "encapsulado" es ~N×útil (replicado por N links).
            # La diferencia útil/encapsulado revela el factor de replicación real.
            print(f'  •  Encapsulado {DIM}↓{fmt_bytes(sum_active_rx)} ↑{fmt_bytes(sum_active_tx)}{RESET}', end='')
    print()
    print()
    print(f'  {DIM}iter {iteration}  •  daemon: {daemon}{RESET}')


def main():
    parser = argparse.ArgumentParser(
        description='Monitor TUI real-time de mlvpn (v1) o ubond (v2)'
    )
    parser.add_argument('--interval', '-i', type=float, default=1.0,
                        help='Intervalo de actualización en segundos (default: 1)')
    parser.add_argument('--daemon', '-d',
                        choices=['auto', 'mlvpn', 'ubond'], default='auto',
                        help='Cuál monitorizar (default: auto-detect)')
    args = parser.parse_args()

    if args.daemon == 'auto':
        daemon, both_alive = detect_daemon()
        if daemon is None:
            print(f'{RED}Ningún daemon detectado.{RESET}')
            print(f'  Lanza {DAEMON_INFO["mlvpn"]["connect_hint"]} (v1)'
                  f' o {DAEMON_INFO["ubond"]["connect_hint"]} (v2).')
            sys.exit(1)
        if both_alive:
            print(f'{YELLOW}{BOLD}AVISO:{RESET}{YELLOW} mlvpn Y ubond vivos simultáneamente.{RESET}')
            print(f'  Estado anómalo (transición v1→v2 incompleta o SOS fallido).')
            print(f'  Mostrando ubond. Para limpiar: ejecuta SOS.sh y relanza.')
            print(f'  Para forzar mlvpn: --daemon mlvpn')
            time.sleep(2)
        else:
            print(f'{DIM}Auto-detected: {daemon}{RESET}')
            time.sleep(0.5)
    else:
        daemon = args.daemon

    prev_stats = get_interface_stats()
    iteration = 0

    try:
        while True:
            time.sleep(args.interval)
            iteration += 1
            curr_stats = get_interface_stats()
            utun = find_tunnel_utun(daemon)
            links = check_daemon_links(daemon)
            failover_roles = check_failover_roles(daemon)
            replicate_active = check_replicate_active(daemon)
            draw(daemon, prev_stats, curr_stats,
                 args.interval, links, utun, iteration,
                 failover_roles, replicate_active)
            prev_stats = curr_stats
    except KeyboardInterrupt:
        print('\n  Saliendo...')
        sys.exit(0)


if __name__ == '__main__':
    main()
