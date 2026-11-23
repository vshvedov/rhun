#!/usr/bin/env python3
"""Generates src/gfx/icondata.s: icon drawing programs on a 128x128 grid (16 px = 128 units), and
the explorer's tables of file icon names and file types; the icon numbers of the SVG icons go into
src/rhun.inc. Ops: W w | M x y | L x y | O cx cy r (ring) | D cx cy r (disc) | P n x y ... (filled
polygon) | F n x y ... preserves SVG contour winding, including holes."""
import json, math, os

def arc(cx, cy, r, a0, a1, n):
    return [(round(cx + r * math.cos(math.radians(a0 + (a1 - a0) * i / n))),
             round(cy + r * math.sin(math.radians(a0 + (a1 - a0) * i / n)))) for i in range(n + 1)]

def line(pts):
    return [('M',) + pts[0]] + [('L',) + p for p in pts[1:]]

box = [(12, 20), (116, 20), (116, 108), (12, 108), (12, 20)]
ICONS = [
    ('CHEV_R',   [('W', 12), ('M', 48, 30), ('L', 82, 64), ('L', 48, 98)]),
    ('CHEV_D',   [('W', 12), ('M', 30, 48), ('L', 64, 82), ('L', 98, 48)]),
    ('FOLDER',   [('W', 10)] + line([(14, 30), (50, 30), (62, 42), (114, 42), (114, 100), (14, 100), (14, 30)])),
    ('FILE',     [('W', 10)] + line([(28, 12), (74, 12), (100, 38), (100, 116), (28, 116), (28, 12)])
                 + line([(74, 12), (74, 38), (100, 38)])),
    ('CLOSE',    [('W', 12), ('M', 38, 38), ('L', 90, 90), ('M', 90, 38), ('L', 38, 90)]),
    ('SIDEBAR',  [('W', 10)] + line(box) + [('M', 48, 20), ('L', 48, 108)]),
    ('PANEL_R',  [('W', 10)] + line(box) + [('M', 80, 20), ('L', 80, 108)]),
    ('SLIDERS',  [('W', 10), ('M', 14, 34), ('L', 114, 34), ('M', 14, 64), ('L', 114, 64), ('M', 14, 94), ('L', 114, 94),
                  ('D', 42, 34, 13), ('D', 86, 64, 13), ('D', 56, 94, 13)]),
    ('SEARCH',   [('W', 11), ('O', 54, 54, 32), ('M', 78, 78), ('L', 110, 110)]),
    ('SPARK',    [('P', 8, 64, 8, 74, 54, 120, 64, 74, 74, 64, 120, 54, 74, 8, 64, 54, 54)]),
    ('MIN',      [('W', 8), ('M', 40, 64), ('L', 88, 64)]),
    ('MAX',      [('W', 8)] + line([(40, 40), (88, 40), (88, 88), (40, 88), (40, 40)])),
    ('RESTORE',  [('W', 8)] + line([(40, 54), (74, 54), (74, 88), (40, 88), (40, 54)])
                 + line([(54, 54), (54, 40), (88, 40), (88, 74), (74, 74)])),
    ('WCLOSE',   [('W', 8), ('M', 42, 42), ('L', 86, 86), ('M', 86, 42), ('L', 42, 86)]),
    ('DOT',      [('D', 64, 64, 30)]),
    ('PLUS',     [('W', 12), ('M', 64, 22), ('L', 64, 106), ('M', 22, 64), ('L', 106, 64)]),
    ('CHECK',    [('W', 13), ('M', 26, 66), ('L', 54, 94), ('L', 104, 36)]),
    ('TERMINAL', [('W', 11), ('M', 22, 38), ('L', 56, 64), ('L', 22, 90), ('M', 64, 94), ('L', 106, 94)]),
    ('BACK',     [('W', 11), ('M', 106, 64), ('L', 26, 64), ('M', 60, 30), ('L', 26, 64), ('L', 60, 98)]),
    ('USER',     [('W', 10), ('O', 64, 42, 22)] + line(arc(64, 122, 46, -160, -20, 10))),
    ('ARROW_DN', [('W', 11), ('M', 64, 18), ('L', 64, 106), ('M', 30, 72), ('L', 64, 106), ('L', 98, 72)]),
    ('REFRESH',  [('W', 11)] + line(arc(64, 64, 40, -60, 230, 16)) + [('P', 3, 94, 10, 98, 46, 62, 40)]),
    ('CHEV_UP',  [('W', 12), ('M', 30, 80), ('L', 64, 46), ('L', 98, 80)]),
    ('CHEV_DN2', [('W', 12), ('M', 30, 48), ('L', 64, 82), ('L', 98, 48)]),
    ('CASE',     [('D', 64, 64, 20)]),
    ('WORD',     [('D', 64, 64, 20)]),
    ('RUNE',     [('W', 11), ('M', 48, 30), ('L', 48, 98), ('M', 48, 30), ('L', 76, 48), ('L', 48, 66), ('L', 80, 98)]),
    ('BRANCH',   [('W', 10), ('O', 40, 26, 13), ('O', 40, 102, 13), ('O', 90, 42, 13), ('M', 40, 39), ('L', 40, 89)]
                 + line([(90, 55), (90, 64), (84, 74), (70, 80), (52, 84), (42, 89)])),
    ('ARROW_UP', [('W', 11), ('M', 64, 110), ('L', 64, 22), ('M', 30, 56), ('L', 64, 22), ('L', 98, 56)]),
    ('MINUS',    [('W', 12), ('M', 22, 64), ('L', 106, 64)]),
    ('DISCARD',  [('W', 11)] + line(arc(66, 70, 36, 180, 360, 12) + [(102, 98)]) + [('P', 3, 14, 62, 46, 62, 30, 84)]),
    # FILE and FOLDER with a plus at the lower right, their outlines open around it
    ('FILE_PLUS', [('W', 10)] + line([(86, 62), (86, 36), (62, 12), (20, 12), (20, 116), (62, 116)])
                  + line([(62, 12), (62, 36), (86, 36)]) + [('M', 96, 74), ('L', 96, 118), ('M', 74, 96), ('L', 118, 96)]),
    ('FOLDER_PLUS', [('W', 10)] + line([(114, 64), (114, 42), (62, 42), (50, 30), (12, 30), (12, 100), (64, 100)])
                    + [('M', 96, 76), ('L', 96, 118), ('M', 74, 97), ('L', 118, 97)]),
]

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
inc = os.path.join(root, 'src/rhun.inc')
with open(os.path.join(root, 'assets/icons/providers/contours.json')) as source:
    providers = json.load(source)
    for name, contours in providers.items():
        if name == 'OPENCODE':
            continue
        ICONS.append((name, [('F', len(points), *[v for point in points for v in point])
                            for points in contours]))
# explorer file icons (assets/icons/files, flattened by tools/file-icons.py): F_ and the file's name
FILE_ICONS = {}
with open(os.path.join(root, 'assets/icons/files/contours.json')) as source:
    for name, contours in json.load(source).items():
        FILE_ICONS[name] = len(ICONS)
        ICONS.append(('F_' + name.upper().replace('-', '_'), [('F', len(points), *[v for point in points for v in point])
                                                              for points in contours]))
# Keep the existing embedded icon numbers stable when adding a provider.
ICONS.append(('OPENCODE', [('F', len(points), *[v for point in points for v in point])
                          for points in providers['OPENCODE']]))
# drawn icons added later go last too: a pinned tab's pin, its head, flared foot and needle
ICONS.append(('PIN', [('W', 10)] + line([(40, 14), (88, 14)])
                     + line([(50, 14), (50, 54), (30, 76), (30, 84), (98, 84), (98, 76), (78, 54), (78, 14)])
                     + [('M', 64, 84), ('L', 64, 118)]))
# the extensions button: a puzzle piece (a square with a knob on top and one on the right), and a
# "more" button of three dots
ICONS.append(('PUZZLE', [('W', 10)] + line([(22, 38), (46, 38), (46, 30)] + arc(58, 30, 12, 180, 360, 8)
                                           + [(70, 38), (90, 38), (90, 60), (98, 60)] + arc(98, 72, 12, 270, 450, 8)
                                           + [(90, 84), (90, 108), (22, 108), (22, 38)])))
ICONS.append(('MORE', [('D', 64, 28, 10), ('D', 64, 64, 10), ('D', 64, 100, 10)]))
# icons extensions name in status items, menus and buttons ($(play), contributions-commands design)
ICONS.append(('PLAY', [('P', 3, 40, 22, 106, 64, 40, 106)]))
ICONS.append(('STOP', [('P', 4, 32, 32, 96, 32, 96, 96, 32, 96)]))
ICONS.append(('DEBUG', [('W', 10)] + line([(30, 22), (98, 64), (30, 106), (30, 22)]) + [('D', 96, 100, 14)]))
ICONS.append(('BUG', [('W', 10), ('O', 64, 74, 26), ('D', 64, 36, 13), ('M', 64, 50), ('L', 64, 100),
                      ('M', 38, 62), ('L', 18, 54), ('M', 38, 82), ('L', 16, 84), ('M', 42, 96), ('L', 24, 112),
                      ('M', 90, 62), ('L', 110, 54), ('M', 90, 82), ('L', 112, 84), ('M', 86, 96), ('L', 104, 112)]))
ICONS.append(('WARNING', [('W', 10)] + line([(64, 14), (116, 108), (12, 108), (64, 14)])
                         + [('M', 64, 46), ('L', 64, 76), ('D', 64, 92, 7)]))
ICONS.append(('ERROR', [('W', 10), ('O', 64, 64, 46), ('M', 46, 46), ('L', 82, 82), ('M', 82, 46), ('L', 46, 82)]))
ICONS.append(('INFO', [('W', 10), ('O', 64, 64, 46), ('D', 64, 40, 7), ('M', 64, 58), ('L', 64, 92)]))
ICONS.append(('BELL', [('W', 10)] + line([(28, 92)] + arc(64, 56, 36, 180, 360, 12) + [(100, 92)])
                      + [('M', 18, 94), ('L', 110, 94), ('D', 64, 110, 9), ('M', 64, 14), ('L', 64, 22)]))
ICONS.append(('GEAR', [('W', 10), ('O', 64, 64, 32), ('O', 64, 64, 11)]
                      + [op for k in range(8) for op in (
                          ('M', round(64 + 34 * math.cos(math.radians(45 * k))), round(64 + 34 * math.sin(math.radians(45 * k)))),
                          ('L', round(64 + 52 * math.cos(math.radians(45 * k))), round(64 + 52 * math.sin(math.radians(45 * k)))))]))
ICONS.append(('EDIT', [('W', 10)] + line([(22, 106), (30, 80), (88, 22), (106, 40), (48, 98), (22, 106)])
                      + [('M', 76, 34), ('L', 94, 52)]))
ICONS.append(('TRASH', [('W', 10), ('M', 18, 32), ('L', 110, 32)] + line([(48, 32), (52, 16), (76, 16), (80, 32)])
                       + line([(30, 32), (38, 112), (90, 112), (98, 32)])
                       + [('M', 54, 52), ('L', 56, 92), ('M', 74, 52), ('L', 72, 92)]))
ICONS.append(('EYE', [('W', 10)] + line(arc(64, 118, 76, 225, 315, 12) + arc(64, 10, 76, 45, 135, 12)) + [('D', 64, 64, 15)]))
ICONS.append(('LOCK', [('W', 10)] + line([(40, 58), (40, 40)] + arc(64, 40, 24, 180, 360, 10) + [(88, 58)])
                      + line([(24, 58), (104, 58), (104, 114), (24, 114), (24, 58)]) + [('D', 64, 86, 9)]))
ICONS.append(('COPY', [('W', 10)] + line([(44, 44), (110, 44), (110, 112), (44, 112), (44, 44)])
                      + line([(84, 44), (84, 18), (18, 18), (18, 86), (44, 86)])))
ICONS.append(('FILTER', [('W', 10)] + line([(14, 20), (114, 20), (76, 66), (76, 108), (52, 96), (52, 66), (14, 20)])))
ICONS.append(('LIST', [('W', 10), ('D', 22, 32, 8), ('D', 22, 64, 8), ('D', 22, 96, 8),
                       ('M', 44, 32), ('L', 112, 32), ('M', 44, 64), ('L', 112, 64), ('M', 44, 96), ('L', 112, 96)]))
ICONS.append(('BEAKER', [('W', 10)] + line([(48, 14), (48, 52), (16, 110), (112, 110), (80, 52), (80, 14)])
                        + [('M', 40, 14), ('L', 88, 14), ('M', 30, 84), ('L', 98, 84)]))
ICONS.append(('CLOUD', [('W', 10)] + line([(36, 98)] + arc(36, 78, 20, 90, 270, 6) + arc(60, 50, 26, 200, 340, 8)
                                          + arc(92, 70, 22, 270, 450, 8) + [(36, 98)])))
# testing's states: a ring (queued, running) and a slashed circle (skipped)
ICONS.append(('RING', [('W', 12), ('O', 64, 64, 34)]))
ICONS.append(('SLASH', [('W', 11), ('O', 64, 64, 38), ('M', 37, 91), ('L', 91, 37)]))
# the debugger's toolbar (debugview.s; PLAY and STOP above serve as Continue and Stop): pause, step
# over, into and out
ICONS.append(('DBG_PAUSE', [('P', 4, 32, 24, 54, 24, 54, 104, 32, 104), ('P', 4, 74, 24, 96, 24, 96, 104, 74, 104)]))
ICONS.append(('DBG_OVER', [('W', 11)] + line(arc(64, 72, 40, 180, 340, 12)) + [('P', 3, 86, 60, 118, 56, 108, 86),
                                                                              ('D', 64, 104, 11)]))
ICONS.append(('DBG_INTO', [('W', 11), ('M', 64, 12), ('L', 64, 62), ('P', 3, 42, 48, 86, 48, 64, 78),
                           ('D', 64, 104, 11)]))
ICONS.append(('DBG_OUT', [('W', 11), ('M', 64, 84), ('L', 64, 34), ('P', 3, 42, 48, 86, 48, 64, 18),
                          ('D', 64, 108, 11)]))
# the agents panel's spinner (agentspin.s): six frames of "·", "✢", "*", "✶", "✻", "✽" as vectors (the glyphs
# are not in every interface font), each a little larger than the one before
def spokes(n, r0, r1, a0=-90):
    out = []
    for k in range(n):
        a = math.radians(a0 + 360 * k / n)
        out += [('M', round(64 + r0 * math.cos(a)), round(64 + r0 * math.sin(a))),
                ('L', round(64 + r1 * math.cos(a)), round(64 + r1 * math.sin(a)))]
    return out

def star(n, r0, r1):
    pts = []
    for k in range(2 * n):
        a = math.radians(-90 + 180 * k / n)
        r = r1 if k % 2 == 0 else r0
        pts += [round(64 + r * math.cos(a)), round(64 + r * math.sin(a))]
    return [('P', 2 * n) + tuple(pts)]

ICONS.append(('SPIN0', [('D', 64, 64, 12)]))
ICONS.append(('SPIN1', [('W', 14)] + spokes(4, 6, 40) + [('D', 64, 64, 10)]))
ICONS.append(('SPIN2', [('W', 13)] + spokes(6, 0, 40)))
ICONS.append(('SPIN3', star(6, 22, 50)))
ICONS.append(('SPIN4', [('W', 16)] + spokes(8, 12, 50) + [('D', 64, 64, 14)]))
ICONS.append(('SPIN5', [('W', 22)] + spokes(8, 14, 52) + [('D', 64, 64, 20)]))
# icon_mask keys its cache by icon | size << 8
assert len(ICONS) <= 256, len(ICONS)
# the color names of file icons, in the order of their theme slots from T_ICON (src/app/theme.s)
COLORS = ['red', 'orange', 'yellow', 'green', 'blue', 'purple', 'pink', 'cyan', 'grey', 'white']

def file_icon(icon, color, where):
    # as src/app/fileicon.s reads them: names in any case, and gray for grey
    names = {name.lower(): name for name in FILE_ICONS}
    assert icon.lower() in names, '%s: no icon %s' % (where, icon)
    color = 'grey' if color.lower() == 'gray' else color.lower()
    assert color in COLORS, '%s: no color %s' % (where, color)
    return FILE_ICONS[names[icon.lower()]], COLORS.index(color)

# grammars name their icon at run time (icon = name color, grey when the color is left out); check
# the built-in ones here
for f in sorted(os.listdir(os.path.join(root, 'runtime/syntax'))):
    for line in open(os.path.join(root, 'runtime/syntax', f), encoding='utf-8'):
        key, eq, value = line.partition('=')
        words = value.split()
        if eq and key.strip() == 'icon' and words:
            file_icon(words[0], words[1] if len(words) > 1 else 'grey', f)
# types.txt: patterns, then icon and color; whole names first, as file_icon tries them first
types = []
for n, line in enumerate(open(os.path.join(root, 'assets/icons/files/types.txt'), encoding='utf-8')):
    words = line.split()
    if not words or words[0].startswith('#'):
        continue
    icon, color = file_icon(words[-2], words[-1], 'types.txt:%d' % (n + 1))
    for pat in words[:-2]:
        ext = pat.startswith('*.')
        name = pat[2:] if ext else pat
        assert name and '*' not in name and len(name) < 256 and name.isascii(), pat
        types.append((ext, name.lower(), icon, color))
types.sort(key=lambda e: e[0])

def name_bytes(s):
    return ', '.join(str(b) for b in s.encode())

out = ['# vector icon programs, generated by tools/icons.py', '.section .rodata', '.globl icon_table',
       '.p2align 3', 'icon_table:']
out += ['    .quad ic_%s' % n.lower() for n, _ in ICONS]
for name, prog in ICONS:
    b = []
    for c in prog:
        b += [ord(c[0])] + list(c[1:])
    b.append(0)
    assert all(0 <= v <= 255 for v in b), name
    out.append('ic_%s: .byte %s' % (name.lower(), ', '.join(map(str, b))))
# file_icon_names: length, icon, name; a length of 0 ends it
out += ['# file icon names for the grammars\' icon keys: length, icon, name', '.globl file_icon_names',
        'file_icon_names:']
for name, icon in sorted(FILE_ICONS.items()):
    out.append('    .byte %d, %d, %s    # %s' % (len(name), icon, name_bytes(name), name))
out.append('    .byte 0')
# file_types: length, 1 for an extension, icon, color, lowercase name or extension
out += ['# types.txt: length, 1 for an extension (0 for a whole name), icon, color, lowercase pattern',
        '.globl file_types', 'file_types:']
for ext, name, icon, color in types:
    out.append('    .byte %d, %d, %d, %d, %s    # %s' % (len(name), ext, icon, color, name_bytes(name), name))
out.append('    .byte 0')
open(os.path.join(root, 'src/gfx/icondata.s'), 'w').write('\n'.join(out) + '\n')

# icon numbers in src/rhun.inc: the drawn icons are written by hand there (checked here), the
# others between the markers
BEGIN, END = '# icons from SVG files (tools/icons.py)\n', '# end of the icons from SVG files\n'
text = open(inc).read()
head, rest = text.split(BEGIN)
_, tail = rest.split(END)
import re
for name, value in re.findall(r'^\.equ IC_(\w+), (\d+)', head, re.M):
    assert ICONS[int(value)][0] == name, ('rhun.inc: IC_%s is not icon %s' % (name, value))
first = len(re.findall(r'^\.equ IC_\w+, \d+', head, re.M))
gen = ['.equ IC_%s, %d\n' % (name, n) for n, (name, _) in enumerate(ICONS) if n >= first]
gen.append('.equ IC_COUNT, %d\n' % len(ICONS))
open(inc, 'w').write(head + BEGIN + ''.join(gen) + END + tail)
