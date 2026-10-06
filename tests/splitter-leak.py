#!/usr/bin/env python3
"""A press inside a splitter's strip belongs to the splitter: rows and the scrollbar under
it must not see it — no file opens, the list does not scroll — yet the drag still resizes."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
EXE = Path(os.environ.get('RHUN_TEST_EXE', ROOT / 'build/rhun')).resolve()

# 1000x700 at scale 1: the sidebar is 240 wide, so the left splitter's strip is x 236-244 and
# overlaps the explorer's rows and scrollbar; a file row sits at y=300.
STRIP = 240

with tempfile.TemporaryDirectory(prefix='rhun-leak-') as temporary:
    work = Path(temporary).resolve()
    project = work / 'project'
    project.mkdir()
    for i in range(1, 41):
        (project / f'f{i}.txt').write_text(f'file {i}\n')
    config = work / 'config/rhun/config'
    config.parent.mkdir(parents=True)
    env = dict(os.environ, HOME=str(work), XDG_CONFIG_HOME=str(work / 'config'),
               XDG_STATE_HOME=str(work / 'state'))

    def run(lines):
        # a strip press resizes and persists sidebar_width, so pin it again before every launch
        config.write_text('[files]\nrestore_session = false\nrestore_project = false\n'
                          '[updates]\ncheck = false\n[git]\nenabled = false\n'
                          '[ui]\nagents_panel = false\nsidebar_width = 240\n')
        script = work / 'commands.rsc'
        script.write_text('\n'.join([*lines, 'quit']) + '\n', encoding='utf-8')
        result = subprocess.run([str(EXE), str(project), '--headless', '1000x700', '--scale', '1',
                                 '--script', str(script)], env=env, capture_output=True, timeout=20,
                                check=True)
        return result.stdout.decode('utf-8')

    def ppm(path):
        magic, size, maximum, pixels = path.read_bytes().split(b'\n', 3)
        return int(size.split()[0]), pixels

    # a press inside the strip must not activate the row under it
    output = run([f'move {STRIP - 2} 300', 'down', 'wait 60', 'print-state', 'up'])
    assert 'tabs=0 ' in output, output
    print('ok   splitter/strip-press-does-not-open-a-row')

    # a vertical drag inside the strip must not grab the scrollbar under it: rows do not move.
    # only compare rows above the drag path — hover under the pointer is allowed to highlight
    pre, post = work / 'pre.ppm', work / 'post.ppm'
    run([f'shot {pre.as_posix()}', f'move {STRIP - 2} 300', 'down',
         f'move {STRIP - 2} 500', f'move {STRIP - 2} 500', f'move {STRIP - 2} 500',
         'up', 'wait 60', f'shot {post.as_posix()}'])
    width, before = ppm(pre)
    _, after = ppm(post)
    same = all(before[(y * width + x) * 3:(y * width + x) * 3 + 3] ==
               after[(y * width + x) * 3:(y * width + x) * 3 + 3]
               for y in range(80, 280) for x in range(20, 220))
    assert same, 'the scrollbar under the strip dragged the list'
    print('ok   splitter/strip-drag-does-not-scroll-the-list')

    # the strip still resizes: dragging it to 400 writes the new width when rhun quits
    run([f'move {STRIP - 2} 300', 'down',
         'move 400 300', 'move 400 300', 'move 400 300', 'up'])
    assert 'sidebar_width = 400' in config.read_text(), config.read_text()
    print('ok   splitter/strip-drag-resizes')

    # a press just past the divider belongs to the handle, not the editor: the caret stays put
    output = run(['open ' + (project / 'f1.txt').as_posix(), 'wait 300',
                  f'move {STRIP + 3} 300', 'down', 'wait 100', 'print-state', 'up'])
    assert 'line=1 col=1 ' in output, output
    print('ok   splitter/strip-press-does-not-move-the-caret')

    # a double-click snaps the panel back to its default width, like Zed's resize handle;
    # real clicks drift a few px between presses, so the two presses are not identical
    run([f'move {STRIP - 2} 300', 'down',
         'move 400 300', 'move 400 300', 'move 400 300', 'up', 'wait 60',
         'click 398 300', 'click 403 302'])
    assert 'sidebar_width = 240' in config.read_text(), config.read_text()
    print('ok   splitter/double-click-resets-the-width')
