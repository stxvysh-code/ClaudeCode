#!/usr/bin/env python3
"""Собирает Kvantum-тему «Forest» из Graphite-rimless Dark (vinceliuice, GPL-3.0).
Использование (для разработчика, при установке НЕ запускается):
    python3 tools/build-kvantum.py /path/to/Graphite-kde-theme/Kvantum/Graphite-rimless theme/kvantum/Forest
Перекрашивает серые тона в тёмно-зелёные, акценты — в зелёный, включает лёгкую прозрачность с размытием.
"""
import re, sys, pathlib

src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
dst.mkdir(parents=True, exist_ok=True)

ACCENTS = {'4285f4': '8fb573', 'b74aff': 'a7c080', '0057ae': '83c092', 'e040fb': 'd699b6', 'f04a50': 'e67e80'}

def recolor(hexv: str) -> str:
    h = hexv.lower()
    if h in ACCENTS:
        return ACCENTS[h]
    r, g, b = (int(h[i:i + 2], 16) for i in (0, 2, 4))
    if max(r, g, b) - min(r, g, b) > 12:          # не серый цвет — оставляем
        return h
    v = (r + g + b) / 3
    if v < 20 or v > 120:                          # чёрный/светлые (текст, блики) — не трогаем
        if 200 <= v <= 240:                        # светло-серый текст → чуть зеленее
            return '%02x%02x%02x' % (min(255, int(v * 0.985)), min(255, int(v * 1.01)), min(255, int(v * 0.97)))
        return h
    t = 0.94 * v - 13.5                            # затемняем фон (окно ≈ #1b201c)
    t = max(t, 10)
    return '%02x%02x%02x' % (min(255, int(t * 0.93)), min(255, int(t * 1.08)), min(255, int(t * 0.96)))

def sub(text: str) -> str:
    return re.sub(r'#([0-9a-fA-F]{6})\b', lambda m: '#' + recolor(m.group(1)), text)

svg = (src / 'Graphite-rimlessDark.svg').read_text()
(dst / 'Forest.svg').write_text(sub(svg))

kv = (src / 'Graphite-rimlessDark.kvconfig').read_text()
kv = sub(kv)
overrides = {
    'translucent_windows': 'true',
    'blurring': 'true',
    'popup_blurring': 'true',
    'reduce_window_opacity': '12',
    'reduce_menu_opacity': '8',
    'menu_blur_radius': '6',
    'tooltip_blur_radius': '6',
    'opaque': 'kaffeine,kmplayer,subtitlecomposer,kdenlive,vlc,avidemux,avidemux2_qt4,avidemux3_qt4,'
              'avidemux3_qt5,kamoso,QtCreator,VirtualBox,VirtualBoxVM,trojita,dragon,digikam,lyx,haruna,'
              'obs,telegram-desktop,Telegram,org.telegram.desktop,krita,qbittorrent,steam,lutris,okular,gwenview',
}
lines, seen, section = [], set(), None
for line in kv.splitlines():
    m = re.match(r'^\[(.+)\]$', line)
    if m:
        if section == '%General':
            for k, v in overrides.items():
                if k not in seen:
                    lines.append(f'{k}={v}')
        section = m.group(1)
    km = re.match(r'^([A-Za-z_.]+)=', line)
    if section == '%General' and km and km.group(1) in overrides:
        k = km.group(1); seen.add(k)
        line = f'{k}={overrides[k]}'
    lines.append(line)
text = '\n'.join(lines) + '\n'
text = re.sub(r'(?m)^author=.*$', 'author=arch-forest, based on Graphite by Vince Liuice (GPL-3.0), based on KvAdapta by Tsu Jan', text, count=1)
colors = {'highlight.color': '#45603c', 'inactive.highlight.color': '#33452e',
          'highlight.text.color': '#f1f5ec', 'inactive.highlight.text.color': '#dbe1d8'}
for k, v in colors.items():
    text = re.sub(r'(?m)^' + re.escape(k) + r'=.*$', f'{k}={v}', text)
(dst / 'Forest.kvconfig').write_text(text)
print('ok', dst)
