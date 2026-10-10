#!/usr/bin/env python3
"""The caret blinks in every text field as it does in the editor: the find bar and replace, the
command palette, Go to File, Go to Line, a prompt (Save As), a setting, vim's command line and the
commit message. Shots over 1.2 s after typing differ only in a caret-wide column while
cursor_blink is on, and not at all with it off."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
EXE = Path(os.environ.get('RHUN_TEST_EXE', ROOT / 'build/rhun')).resolve()
SHOTS = 5                       # 300 ms apart: both halves of the 530 ms blink


def settings_row_y(section, key):
    """y of a setting's row in a 1400 px wide Settings tab (as tests/settings-ui.py lays it out)"""
    spec = importlib.util.spec_from_file_location('settings_ui', ROOT / 'tests/settings-ui.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    y, previous = 228, None
    for sec, name, _ in module.ROWS:
        if not module.THEME_ROWS.get((sec, name), True):
            continue
        if sec != previous:
            y += 48
            previous = sec
        if (sec, name) == (section, key):
            return y + 32
        y += 72
    raise KeyError(key)


class FieldBlink(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rhun-blink-')
        self.work = Path(self.tmp.name).resolve()
        self.project = self.work / 'project'
        self.project.mkdir()
        (self.project / 'notes.txt').write_text('alpha beta\nab cd\n', encoding='utf-8')
        self.env = dict(os.environ, HOME=self.work.as_posix(),
                        XDG_CONFIG_HOME=(self.work / 'config').as_posix(),
                        XDG_STATE_HOME=(self.work / 'state').as_posix())

    def tearDown(self):
        self.tmp.cleanup()

    def shots(self, actions, blink, size='1000x700', git=False):
        """the frames shown after actions, 300 ms apart, as (width, pixels)"""
        config = self.work / 'config/rhun/config'
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text('[ui]\nsidebar = false\nagents_panel = false\ntooltips = false\n'
                          f'[editor]\ncursor_blink = {"true" if blink else "false"}\n'
                          '[files]\nrestore_session = false\nrestore_project = false\n'
                          f'[git]\nenabled = {"true" if git else "false"}\ncommit_ai = off\n'
                          '[updates]\ncheck = false\n', encoding='utf-8')
        paths = [self.work / f'shot{i}.ppm' for i in range(SHOTS)]
        lines = [*actions]
        for i, path in enumerate(paths):
            if i:
                lines.append('wait 300')
            lines.append('shot ' + path.as_posix())
        script = self.work / 'actions.rsc'
        script.write_text('\n'.join([*lines, 'quit']) + '\n', encoding='utf-8')
        result = subprocess.run([str(EXE), self.project.as_posix(), '--headless', size, '--scale', '1',
                                 '--script', script.as_posix()], env=self.env, capture_output=True,
                                timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
        frames = []
        for path in paths:
            magic, dims, _, pixels = path.read_bytes().split(b'\n', 3)
            frames.append((int(dims.split()[0]), pixels))
        return frames

    def columns(self, a, b):
        """the x range where two frames differ, or None"""
        width, first = a
        _, second = b
        if first == second:
            return None
        lo, hi = width, -1
        stride = width * 3
        for row in range(0, len(first), stride):
            if first[row:row + stride] != second[row:row + stride]:
                for x in range(width):
                    i = row + x * 3
                    if first[i:i + 3] != second[i:i + 3]:
                        lo, hi = min(lo, x), max(hi, x)
        return lo, hi

    def check(self, name, actions, **kwargs):
        frames = self.shots(actions, True, **kwargs)
        spans = [self.columns(frames[0], frame) for frame in frames[1:]]
        changed = [span for span in spans if span]
        self.assertTrue(changed, f'{name}: the caret never went off')
        for lo, hi in changed:
            self.assertLessEqual(hi - lo, 3, f'{name}: more than the caret changed (x {lo}..{hi})')
        steady = self.shots(actions, False, **kwargs)
        self.assertTrue(all(frame == steady[0] for frame in steady), f'{name}: changed without blinking')

    def test_the_editor(self):
        self.check('editor', ['cmd new_file', 'type abc'])

    def test_the_find_bar_and_replace(self):
        self.check('find', [f'open {(self.project / "notes.txt").as_posix()}', 'cmd find', 'type ab'])
        self.check('replace', [f'open {(self.project / "notes.txt").as_posix()}', 'cmd replace', 'key Tab', 'type xy'])

    def test_the_palette_and_its_prompts(self):
        self.check('command palette', ['cmd command_palette', 'type zz'])
        self.check('go to file', ['cmd quick_open', 'type note'])
        self.check('go to line', [f'open {(self.project / "notes.txt").as_posix()}', 'cmd goto_line', 'type 2'])
        self.check('save as', ['cmd new_file', 'type x', 'cmd save_as', 'type y'])

    def test_a_setting(self):
        y = settings_row_y('ui', 'font')
        self.check('setting', ['cmd settings', f'click 900 {y}', 'type x'], size='1400x900')

    def test_a_field_scrolled_out_of_view_does_not_blink(self):
        # a setting being typed, its page scrolled until the field is gone: no frames for a caret no
        # one sees, and the blink again once it is back
        config = self.work / 'config/rhun/config'
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text('[ui]\nsidebar = false\nagents_panel = false\ntooltips = false\n'
                          'auto_hide_scrollbars = false\n'
                          '[files]\nrestore_session = false\nrestore_project = false\n'
                          '[git]\nenabled = false\n[updates]\ncheck = false\n', encoding='utf-8')
        y = settings_row_y('ui', 'font')
        script = self.work / 'actions.rsc'
        script.write_text('\n'.join(['cmd settings', f'click 900 {y}', 'type x', 'move 700 450',
                                     'scroll 3000', 'wait 150', 'print-frames', 'wait 1800', 'print-frames',
                                     'scroll -3000', 'type y', 'wait 150', 'print-frames', 'wait 1800',
                                     'print-frames', 'print-state', 'quit']) + '\n', encoding='utf-8')
        result = subprocess.run([str(EXE), self.project.as_posix(), '--headless', '1400x900', '--scale', '1',
                                 '--script', script.as_posix()], env=self.env, capture_output=True,
                                text=True, encoding='utf-8', timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        frames = [int(line.removeprefix('frames=')) for line in lines if line.startswith('frames=')]
        self.assertLessEqual(frames[1], 1, result.stdout)     # at most the frame that ends the blink
        self.assertIn(frames[3], (3, 4), result.stdout)
        self.assertIn(' focus=4 ', lines[-1])

    def test_vims_command_line(self):
        self.check('vim command line', [f'open {(self.project / "notes.txt").as_posix()}', 'cmd toggle_vim', 'type :s'])

    @unittest.skipIf(shutil.which('git') is None, 'git is not installed')
    def test_the_commit_message(self):
        git = ['git', '-C', str(self.project), '-c', 'user.name=t', '-c', 'user.email=t@t']
        subprocess.run([*git, 'init', '-q'], check=True)
        subprocess.run([*git, 'add', '.'], check=True)
        subprocess.run([*git, 'commit', '-qm', 'one'], check=True)
        (self.project / 'notes.txt').write_text('changed\n', encoding='utf-8')
        self.check('commit message', ['wait-git', 'cmd git_history', 'wait-git', 'key Return', 'type fix'],
                   git=True)


if __name__ == '__main__':
    unittest.main()
