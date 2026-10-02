#!/usr/bin/env python3
"""Interface colors of a theme: ui_fg on the bars, panels and popups, fg in the editor, unfocused fills."""
from collections import Counter
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
EXE = Path(os.environ.get('RHUN_TEST_EXE', ROOT / 'build/rhun')).resolve()

# Hue tells the text apart: ui_fg is red, fg is green, every fill is gray or blue.
THEME = '''name = Chrome
kind = dark

bg                   = #000040
fg                   = #00ff00
accent               = #0000ff
panel                = #b0b0b0
titlebar             = #a0a0a0
titlebar_unfocused   = #707070
tab_active           = #d0d0d0
tab_active_unfocused = #909090
popup                = #c4c4c4
input                = #e0e0e0
hover                = #c8c8c8
active               = #9090a0
ui_fg                = #ff0000
'''
W, H = 1400, 860
# (x0, y0, x1, y1), ends excluded, at scale 1 with a 240 explorer and a 380 agents panel
TITLE = (0, 1, W, 38)
TABS = (242, 42, 1018, 74)
STATUS = (0, 836, W, 860)
EXPLORER = (0, 41, 239, 833)
AGENTS = (1022, 41, W, 833)
EDITOR = (242, 77, 1018, 833)
TAB_PAD = (243, 44, 255, 72)    # the active tab, left of its label


def read_ppm(path):
    magic, size, depth, pixels = path.read_bytes().split(b'\n', 3)
    assert magic == b'P6' and depth == b'255', path
    w, h = map(int, size.split())
    assert (w, h) == (W, H), (w, h)
    return pixels


def region(pixels, box):
    x0, y0, x1, y1 = box
    return b''.join(pixels[(y * W + x0) * 3:(y * W + x1) * 3] for y in range(y0, y1))


def colors(pixels, box):
    data = region(pixels, box)
    return [tuple(data[i:i + 3]) for i in range(0, len(data), 3)]


def dominant(pixels, box):
    return '#%02x%02x%02x' % Counter(colors(pixels, box)).most_common(1)[0][0]


def text(pixels, box):
    """(ui_fg pixels, fg pixels): red or green well above the other channels, antialiased edges included"""
    ui = fg = 0
    for r, g, b in colors(pixels, box):
        ui += r - max(g, b) >= 64
        fg += g - max(r, b) >= 64
    return ui, fg


def fill_box(pixels, box, color, least):
    """the box spanned by the rows and columns of box with at least `least` pixels of color"""
    x0, y0, x1, y1 = box
    xs, ys = Counter(), Counter()
    for y in range(y0, y1):
        for x in range(x0, x1):
            if pixels[(y * W + x) * 3:(y * W + x) * 3 + 3] == color:
                xs[x] += 1
                ys[y] += 1
    xs = [x for x in xs if xs[x] >= least]
    ys = [y for y in ys if ys[y] >= least]
    assert xs and ys, (box, color)
    return min(xs), min(ys), max(xs) + 1, max(ys) + 1


def inset(box, d):
    x0, y0, x1, y1 = box
    return x0 + d, y0 + d, x1 - d, y1 - d


with tempfile.TemporaryDirectory(prefix='rhun-theme-') as temporary:
    work = Path(temporary).resolve()
    project = work / 'project'
    project.mkdir()
    (project / 'a.txt').write_text('alpha beta gamma\ndelta epsilon\n')
    (project / 'b.txt').write_text('second\n')
    config = work / 'config/rhun'
    (config / 'themes').mkdir(parents=True)
    (config / 'themes/chrome.theme').write_text(THEME)
    env = dict(os.environ, HOME=work.as_posix(), XDG_CONFIG_HOME=(work / 'config').as_posix(),
               XDG_STATE_HOME=(work / 'state').as_posix(), GIT_CONFIG_NOSYSTEM='1',
               GIT_AUTHOR_NAME='Ann', GIT_AUTHOR_EMAIL='ann@example.com',
               GIT_COMMITTER_NAME='Ann', GIT_COMMITTER_EMAIL='ann@example.com')
    env.pop('RHUN_SCALE', None)     # the regions are at scale 1
    # two commits; the newest carries all three kinds of chip: main (current), other (branch), v1 (tag)
    for args in (['init', '-q', '-b', 'main'], ['add', 'a.txt'], ['commit', '-q', '-m', 'First'],
                 ['add', 'b.txt'], ['commit', '-q', '-m', 'Second'], ['tag', 'v1'], ['branch', 'other']):
        subprocess.run(['git', *args], cwd=project, check=True, capture_output=True,
                       env=dict(env, GIT_AUTHOR_DATE='2026-01-01T10:00:00Z', GIT_COMMITTER_DATE='2026-01-01T10:00:00Z'))

    def shots(theme, lines, git=False):
        """run lines, where 'shot NAME' saves a screenshot; -> {NAME: pixels}"""
        (config / 'config').write_text(f'[ui]\ntheme = {theme}\nscale = 1.0\nsidebar_width = 240\n'
                                       'agents_panel = true\nagents_width = 380\n[editor]\ncursor_blink = false\n'
                                       f'[git]\nenabled = {str(git).lower()}\n[updates]\ncheck = false\n')
        names = [line.split()[1] for line in lines if line.startswith('shot ')]
        lines = [f'shot {work / line.split()[1]}.ppm' if line.startswith('shot ') else line for line in lines]
        script = work / 'commands.rsc'
        script.write_text('\n'.join(['open a.txt', *lines, 'quit']) + '\n')
        subprocess.run([str(EXE), str(project), '--headless', f'{W}x{H}', '--script', str(script)],
                       cwd=project, env=env, capture_output=True, timeout=20, check=True)
        return {name: read_ppm(work / f'{name}.ppm') for name in names}

    s = shots('chrome', ['shot focused', 'focus 0', 'shot unfocused', 'focus 1', 'shot refocused',
                         'cmd command_palette', 'shot palette'])
    f, u, r = s['focused'], s['unfocused'], s['refocused']

    for box, want in [(TITLE, '#a0a0a0'), (TABS, '#b0b0b0'), (STATUS, '#b0b0b0'), (EXPLORER, '#b0b0b0'),
                      (EDITOR, '#000040'), (TAB_PAD, '#d0d0d0')]:
        assert dominant(f, box) == want, (box, dominant(f, box), want)
    print('ok   theme/layout')

    for box in [TITLE, TABS, STATUS, EXPLORER, AGENTS]:
        ui, fg = text(f, box)
        assert ui >= 30 and fg == 0, (box, ui, fg)
    print('ok   theme/interface-text')

    ui, fg = text(f, EDITOR)
    assert fg >= 30 and ui == 0, (ui, fg)
    print('ok   theme/editor-text')

    assert [dominant(p, TITLE) for p in (f, u, r)] == ['#a0a0a0', '#707070', '#a0a0a0']
    assert [dominant(p, TAB_PAD) for p in (f, u, r)] == ['#d0d0d0', '#909090', '#d0d0d0']
    assert region(f, STATUS) == region(u, STATUS) and region(f, EXPLORER) == region(u, EXPLORER)
    print('ok   theme/unfocused')

    # the palette card, inset past its border
    card = fill_box(s['palette'], (0, 0, W, H), b'\xc4\xc4\xc4', 50)
    ui, fg = text(s['palette'], inset(card, 8))
    assert ui >= 30 and fg == 0, (card, ui, fg)
    print('ok   theme/popup-text')

    # in git history, select the oldest commit (third row): a subject and a date on the selected fill
    s = shots('chrome', ['cmd settings', 'shot settings', 'cmd toggle_git_history', 'wait-git',
                         'click 500 146', 'wait-git', 'shot git'], git=True)

    # settings: the page heading on bg in fg, the rows (panel cards) below it in ui_fg
    cards = fill_box(s['settings'], EDITOR, b'\xb0\xb0\xb0', 50)
    ui, fg = text(s['settings'], inset(cards, 8))
    assert ui >= 30 and fg == 0, (cards, ui, fg)
    ui, fg = text(s['settings'], (EDITOR[0], EDITOR[1], EDITOR[2], cards[1]))
    assert fg >= 30 and ui == 0, (ui, fg)
    print('ok   theme/settings-text')

    # git history on bg: the selected row (active) and the branch chip (hover) in ui_fg, the rest in fg
    g = s['git']
    details = fill_box(g, EDITOR, b'\xb0\xb0\xb0', 50)
    rows = (EDITOR[0] + 30, EDITOR[1], details[0] - 1, EDITOR[1] + 100)     # right of the graph
    selected = fill_box(g, rows, b'\x90\x90\xa0', 20)
    branch = fill_box(g, rows, b'\xc8\xc8\xc8', 5)
    ui, fg = text(g, selected)
    assert ui >= 30 and fg == 0, (selected, ui, fg)
    ui, fg = text(g, branch)
    assert ui >= 10 and fg == 0, (branch, ui, fg)
    plain = (rows[0], rows[1], rows[2], selected[1])
    ui, fg = text(g, plain)
    assert fg >= 30 and ui == text(g, branch)[0], (plain, ui, fg)
    ui, fg = text(g, details)
    assert ui >= 30 and fg == 0, (details, ui, fg)
    print('ok   theme/git-text')

    # a built-in theme gives no unfocused colors: losing the focus leaves the bars as they were
    s = shots('rhun-dark', ['shot focused', 'focus 0', 'shot unfocused'])
    for box in [TITLE, TABS]:
        assert region(s['focused'], box) == region(s['unfocused'], box), box
    print('ok   theme/builtin-focus')
