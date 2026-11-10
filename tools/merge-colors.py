#!/usr/bin/env python3
"""Сливает цветовую схему KDE (*.colors) в kdeglobals — то же, что делает
plasma-apply-colorscheme, но без запущенной Plasma (во время установки).
Использование: merge-colors.py SCHEME.colors ~/.config/kdeglobals"""
import re, sys

def parse(path):
    sections, order, cur = {}, [], None
    try:
        lines = open(path, encoding='utf-8').read().splitlines()
    except FileNotFoundError:
        lines = []
    for line in lines:
        m = re.match(r'^\[(.+)\]\s*$', line)
        if m:
            cur = m.group(1)
            if cur not in sections:
                sections[cur] = {}
                order.append(cur)
            continue
        if cur is None or not line.strip() or line.lstrip().startswith('#'):
            continue
        if '=' in line:
            k, v = line.split('=', 1)
            sections[cur][k] = v
    return sections, order

scheme, _ = parse(sys.argv[1])
target, order = parse(sys.argv[2])

def put(sec, key, val):
    if sec not in target:
        target[sec] = {}
        order.append(sec)
    target[sec][key] = val

for sec, kv in scheme.items():
    if sec.startswith('Colors:') or sec.startswith('ColorEffects:') or sec == 'WM':
        for k, v in kv.items():
            put(sec, k, v)
put('General', 'ColorScheme', scheme.get('General', {}).get('ColorScheme', 'Forest'))
if 'contrast' in scheme.get('KDE', {}):
    put('KDE', 'contrast', scheme['KDE']['contrast'])

with open(sys.argv[2], 'w', encoding='utf-8') as f:
    for sec in order:
        f.write(f'[{sec}]\n')
        for k, v in target[sec].items():
            f.write(f'{k}={v}\n')
        f.write('\n')
