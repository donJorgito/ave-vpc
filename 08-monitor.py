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


def draw(interfaces, prev_stats, curr_stats, interval, links_status, utun, iteration):
    """Dibuja la pantalla del monitor."""
    os.system('clear')

    print(f'{BOLD}{CYAN}┌─ ave-vpc mlvpn monitor ─────────────────────────────────────────┐{RESET}')
    print(f'{BOLD}{CYAN}│{RESET}  Actualización cada {interval}s  •  Ctrl+C para salir{RESET}' + ' ' * 20 + f'{BOLD}{CYAN}│{RESET}')
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
    print(f'  {"Enlace":<12} {"Estado":<16} {"IP":<18} {"↓ RX":>10}  {"↑ TX":>10}')
    print(f'  {"─"*12} {"─"*16} {"─"*18} {"─"*10}  {"─"*10}')

    active_count = 0
    for link_key, (label, iface) in link_names.items():
        ip = get_interface_ip(iface)
        link_status = links_status.get(link_key)

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
        print(f'  {BOLD}{label:<12}{RESET} {status_str:<25} {DIM}{ip_str:<18}{RESET} '
              f'{color}{fmt_bytes(rx):>10}{RESET}  {color}{fmt_bytes(tx):>10}{RESET}')

    print()

    # ─── Resumen ──────────────────────────────────────────────────────
    if active_count >= 2:
        bonding_str = f'{GREEN}BONDING ACTIVO ({active_count} enlaces){RESET}'
    elif active_count == 1:
        bonding_str = f'{YELLOW}DEGRADADO (1 enlace){RESET}'
    else:
        bonding_str = f'{RED}SIN BONDING{RESET}'

    print(f'  {bonding_str}', end='')
    if utun:
        # Suma de físicas = tráfico encapsulado (con overhead UDP ~2-3%).
        # La diferencia con el agregado del túnel = overhead de protocolo.
        sum_rx = sum_tx = 0
        for _, (_, iface) in link_names.items():
            if get_interface_ip(iface):
                p2 = prev_stats.get(iface, (0, 0))
                c2 = curr_stats.get(iface, (0, 0))
                sum_rx += max(0, c2[0] - p2[0]) / interval
                sum_tx += max(0, c2[1] - p2[1]) / interval
        print(f'  •  Encapsulado {DIM}↓{fmt_bytes(sum_rx)} ↑{fmt_bytes(sum_tx)}{RESET}')
    else:
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
            draw(['en8', 'en12', 'en0'], prev_stats, curr_stats,
                 args.interval, links, utun, iteration)
            prev_stats = curr_stats
    except KeyboardInterrupt:
        print('\n  Saliendo...')
        sys.exit(0)


if __name__ == '__main__':
    main()
