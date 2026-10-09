#!/usr/bin/env python3
# Random editing sessions as control scripts: keys, typing, commands, clicks, scrolling, resizes,
# with print-state and a screenshot every few steps (into OUTDIR).
# usage: tests/fuzz.py DIR FIRST_SEED LAST_SEED [STEPS]
import os
import random
import sys

CMDS = ('quick_open command_palette new_file save_as close_tab reopen_closed_tab next_tab prev_tab undo redo cut copy '
        'paste select_all select_line select_next duplicate_line delete_line move_line_up move_line_down '
        'indent outdent toggle_comment newline_below newline_above find replace find_next find_prev '
        'find_in_files goto_line settings select_theme select_language toggle_sidebar toggle_agents '
        'focus_explorer focus_agents new_folder rename_file zoom_in zoom_out zoom_reset toggle_word_wrap '
        'toggle_whitespace toggle_line_numbers toggle_vim').split()
KEYS = ('Return BackSpace Delete Tab shift+Tab Escape Up Down Left Right Home End Page_Up Page_Down '
        'ctrl+Left ctrl+Right shift+Down shift+Right shift+End ctrl+shift+Left alt+Up alt+Down ctrl+z '
        'ctrl+shift+z ctrl+d ctrl+slash ctrl+a ctrl+c ctrl+v ctrl+x ctrl+Home ctrl+End F1 ctrl+Tab ctrl+p '
        'ctrl+g ctrl+f ctrl+h ctrl+shift+t').split()
WORDS = ['if (x) {', 'return 0;', 'hello world', 'fn main() {}', '# heading', '"str', '(a, b)', 'x = [1, 2',
         'été naïve', 'tab\there', '  indent', '// c',
         # vim keys when vim mode is on
         'dd', 'yyp', 'ciwx', '3x', 'vjd', 'u', '.', 'dap', 'gg', 'G', '>>', 'A;', 'o', 'wd$', ':noh', '/re', 'n']
FILES = ['src/main.s', 'src/lib.s', 'README.md', 'tests/data/lines.c', 'runtime/syntax/c.syn',
         'tools/arm64.py', 'src/app/doc.s', 'tests/data/prose.md', 'runtime/themes/nord.theme', 'build.sh',
         'tests/data/images/rgba.png', 'tests/data/images/baseline-420.jpg', 'tests/data/images/progressive-gray.jpg',
         'tests/data/images/interlaced-transparent.gif', 'tests/data/images/palette8.bmp', 'tests/data/images/rle.tga']


def script(seed, steps):
    r = random.Random(seed)
    lines = ['open ' + f for f in r.sample(FILES, 3)]
    shots = 0
    for i in range(steps):
        k = r.random()
        if k < 0.25 or k >= 0.90:
            lines.append('key ' + r.choice(KEYS))
        elif k < 0.40:
            lines.append('type ' + r.choice(WORDS))
        elif k < 0.55:
            lines.append('cmd ' + r.choice(CMDS))
        elif k < 0.70:
            lines.append('click %d %d' % (r.randrange(1400), r.randrange(860)))
        elif k < 0.75:
            lines.append('click %d %d right' % (r.randrange(1400), r.randrange(860)))
        elif k < 0.82:
            lines.append('scroll 0 %d' % r.choice([-600, -120, 120, 600, 2400]))
        elif k < 0.86:
            lines.append('move %d %d' % (r.randrange(1400), r.randrange(860)))
        elif k < 0.88:
            lines.append('resize %d %d' % (r.randrange(500, 1600), r.randrange(400, 1000)))
        else:
            lines.append('open ' + r.choice(FILES))
        if i % 6 == 5:
            shots += 1
            lines.append('print-state')
            lines.append('shot OUTDIR/%d-%d.ppm' % (seed, shots))
    lines += ['print-doc', 'quit']
    return '\n'.join(lines) + '\n'


def main():
    out, first, last = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    steps = int(sys.argv[4]) if len(sys.argv) > 4 else 120
    os.makedirs(out, exist_ok=True)
    for seed in range(first, last):
        with open(os.path.join(out, '%d.rsc' % seed), 'w') as f:
            f.write(script(seed, steps))


if __name__ == '__main__':
    main()
