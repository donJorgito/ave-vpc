#!/usr/bin/env python3
###############################################################################
# 08-monitor.py — Monitor de bonding mlvpn en tiempo real
#
# DONDE SE EJECUTA: En tu Mac (con mlvpn activo)
#
# QUE MUESTRA:
#   - Throughput útil del túnel mlvpn leído del utun (sin overhead UDP)
#   - Throughput de cada enlace físico (iPhone, Pixel, WiFi si activo)
#   - Estado de cada link: ACTIVO | AUTH... | sin IP
#   - Suma encapsulada (tráfico real por las físicas, incluye overhead)
#   - Actualización cada segundo
#
# USO:
#   ./08-monitor.py
#   ./08-monitor.py --interval 2   # actualizar cada 2 segundos
#
# REQUISITOS:
#   - Python 3 (incluido en macOS)
#   - mlvpn corriendo (./04-conectar.sh ejecutado)
###############################################################################

import sys
import time
import subprocess
import os
import re
import argparse
import socket
from collections import defaultdict

# ─── Colores ──────────────────────────────────────────────────────────────────
RESET  = '\033[0m'
BOLD   = '\033[1m'
GREEN  = '\033[92m'
YELLOW = '\033[93m'
RED    = '\033[91m'
CYAN   = '\033[96m'
DIM    = '\033[2m'
BLUE   = '\033[94m'


def get_interface_stats():
    """Lee bytes in/out de todas las interfaces via netstat -ibn.

    netstat -ibn varía las columnas según la interfaz:
      - Físicas (con MAC):    name mtu <Link#N> MAC  Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll  (11 cols)
      - utun/lo0 (sin MAC):   name mtu <Link#N>      Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll  (10 cols)

    Detectamos si parts[3] es una MAC (5 ':') para desplazar el offset y leer Ibytes/Obytes
    correctamente en ambos casos. Esto es lo que permite leer el utun de mlvpn directamente.
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


def find_mlvpn_utun():
    """Busca el utun que mlvpn está usando (el que tiene 10.10.10.x)."""
    try:
        out = subprocess.check_output(['ifconfig'], text=True)
        current = None
        for line in out.splitlines():
            m = re.match(r'^(utun\d+):', line)
            if m:
                current = m.group(1)
            if current and '10.10.10.' in line:
                return current
    except Exception:
        pass
    return None


def check_mlvpn_links():
    """Obtiene el estado de los links de mlvpn desde el nombre del proceso."""
    try:
        out = subprocess.check_output(['ps', 'aux'], text=True)
        for line in out.splitlines():
            if 'mlvpn: mlvpn0' in line and '[priv]' not in line:
                # @link = autenticado, !link = no autenticado
                authed = re.findall(r'@(links\.\w+)', line)
                pending = re.findall(r'!(links\.\w+)', line)
                return {l: 'OK' for l in authed} | {l: 'AUTH_PENDING' for l in pending}
    except Exception:
        pass
    return {}


def check_failover_roles():
    """Lee mlvpn_active.conf y devuelve {link_key: 'active'|'backup'} (REQ-NET-17).

    Si algún link tiene `fallback_only = 1`, el túnel está en modo --failover
    (REQ-NET-11). En ese modo:
      - "active" = el link sin fallback_only=1 (lleva la carga real)
      - "backup" = links con fallback_only=1 (solo keepalives mlvpn ~1pkt/s)

    Devuelve dict vacío {} si no hay config, no se puede leer, o ningún link
    tiene fallback_only=1 (modo bonding clásico, no aplica distinción).

    El conf está chmod 600 owner=root → intentamos leer sin sudo (a veces
    funciona si el monitor se lanza con sudo o si los permisos cambiaron),
    si falla, sudo -n (no interactivo: si no hay cache, devolvemos {}).
    """
    conf_path = os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        'generated', 'mlvpn_active.conf'
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


def check_captive_portal():
    """Detecta captive portal en la WiFi (HTTP 204 test)."""
    try:
        import urllib.request
        r = urllib.request.urlopen(
            'http://captive.apple.com/hotspot-detect.html',
            timeout=2
        )
        # Apple devuelve 200 con "<HTML>..." si hay captive portal
        # y una página diferente. Simplificamos: si llega, no hay captive.
        content = r.read(100).decode('utf-8', errors='ignore')
        if 'Success' in content:
            return False  # Sin captive
        return True  # Posible captive
    except Exception:
        return True  # Sin conectividad → posible captive o sin red


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


def draw(interfaces, prev_stats, curr_stats, interval, links_status, utun, iteration, failover_roles):
    """Dibuja la pantalla del monitor."""
    os.system('clear')

    is_failover = bool(failover_roles)
    mode_str = f'{YELLOW}[FAILOVER]{RESET}' if is_failover else f'{GREEN}[BONDING]{RESET}'

    print(f'{BOLD}{CYAN}┌─ ave-vpc mlvpn monitor ─────────────────────────────────────────┐{RESET}')
    print(f'{BOLD}{CYAN}│{RESET}  Actualización cada {interval}s  •  Modo: {mode_str}  •  Ctrl+C para salir' + f'{BOLD}{CYAN} │{RESET}')
    print(f'{BOLD}{CYAN}└─────────────────────────────────────────────────────────────────┘{RESET}')
    print()

    # ─── Estado del túnel ─────────────────────────────────────────────
    if utun:
        # Leemos los bytes directamente del utun (tráfico útil del túnel,
        # sin overhead UDP). En macOS, netstat -ibn sí captura los counters
        # del utun de mlvpn una vez parseado correctamente (ver get_interface_stats).
        p_utun = prev_stats.get(utun, (0, 0))
        c_utun = curr_stats.get(utun, (0, 0))
        agg_rx = max(0, c_utun[0] - p_utun[0]) / interval
        agg_tx = max(0, c_utun[1] - p_utun[1]) / interval
        print(f'{BOLD}  TÚNEL mlvpn  {GREEN}●{RESET}  {utun}  IP: {BOLD}10.10.10.2{RESET}')
        print(f'  {"↓ RX":<18} {GREEN}{fmt_bytes(agg_rx):>10}{RESET}  {DIM}(tráfico útil del túnel){RESET}')
        print(f'  {"↑ TX":<18} {CYAN}{fmt_bytes(agg_tx):>10}{RESET}  {DIM}(tráfico útil del túnel){RESET}')
    else:
        print(f'  {RED}TÚNEL mlvpn  ✗  No activo — ejecuta ./04-conectar.sh{RESET}')
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
    elif active_count >= 2:
        summary_str = f'{GREEN}BONDING ACTIVO ({active_count} enlaces){RESET}'
    elif active_count == 1:
        summary_str = f'{YELLOW}DEGRADADO (1 enlace){RESET}'
    else:
        summary_str = f'{RED}SIN BONDING{RESET}'

    print(f'  {summary_str}', end='')
    if utun:
        # En modo failover: sumar SOLO el activo. En bonding: suma de todos.
        # Mostrar también keepalives de backups por separado para confirmar
        # que mlvpn los mantiene vivos (~1 pkt/s) sin enviar data por ellos.
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
            print(f'  •  Encapsulado {DIM}↓{fmt_bytes(sum_active_rx)} ↑{fmt_bytes(sum_active_tx)}{RESET}', end='')
    print()
    print()
    print(f'  {DIM}iter {iteration}{RESET}')


def main():
    parser = argparse.ArgumentParser(description='Monitor mlvpn en tiempo real')
    parser.add_argument('--interval', '-i', type=float, default=1.0,
                        help='Intervalo de actualización en segundos (default: 1)')
    args = parser.parse_args()

    prev_stats = get_interface_stats()
    iteration = 0

    try:
        while True:
            time.sleep(args.interval)
            iteration += 1
            curr_stats = get_interface_stats()
            utun = find_mlvpn_utun()
            links = check_mlvpn_links()
            failover_roles = check_failover_roles()
            draw(['en8', 'en12', 'en0'], prev_stats, curr_stats,
                 args.interval, links, utun, iteration, failover_roles)
            prev_stats = curr_stats
    except KeyboardInterrupt:
        print('\n  Saliendo...')
        sys.exit(0)


if __name__ == '__main__':
    main()
