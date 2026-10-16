#!/usr/bin/env python3
"""The terminal panel's height follows only its own top edge: not a press on another panel's row
that shares its widget id, and a drag of the edge leaves the editor above it alone. Its hide button
hides it at once."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
EXE = Path(os.environ.get('RHUN_TEST_EXE', ROOT / 'build/rhun')).resolve()
# Vinix's Python build can leave sys.executable empty.
PYTHON = sys.executable or shutil.which('python3') or 'python3'
HEIGHT = 260
# 1280x800 at scale 1: the status bar starts at 774, so the panel's top edge is at 774 - HEIGHT
EDGE = 774 - HEIGHT
# the agents panel (380 wide on the right): its first session row
AGENT_ROW = (1000, 105)


class TerminalPanel(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rhun-terminal-panel-')
        self.home = Path(self.tmp.name).resolve()
        self.project = self.home / 'project'
        self.project.mkdir()
        (self.project / 'long.txt').write_text(
            ''.join(f'line {i:04d}\n' for i in range(1, 2001)), encoding='utf-8')
        self.env = dict(os.environ, HOME=self.home.as_posix(),
                        XDG_CONFIG_HOME=(self.home / 'config').as_posix(),
                        XDG_STATE_HOME=(self.home / 'state').as_posix())
        self.config = self.home / 'config/rhun/config'
        self.config.parent.mkdir(parents=True)

    def tearDown(self):
        for _ in range(50):
            try:
                self.tmp.cleanup()
                return
            except OSError:
                time.sleep(0.2)
        self.tmp.cleanup()

    def run_editor(self, actions, agents=False):
        self.config.write_text(
            '[ui]\nsidebar = false\nagents_panel = ' + str(agents).lower() + '\n'
            '[terminal]\nheight = ' + str(HEIGHT) + '\nshell = ' + Path(PYTHON).as_posix() + '\n'
            '[editor]\ncursor_blink = false\nscroll_past_end = true\n'
            '[files]\nrestore_session = false\nrestore_project = false\n'
            '[updates]\ncheck = false\n[git]\nenabled = false\n', encoding='utf-8')
        script = self.home / 'commands.rsc'
        script.write_text('\n'.join(['cmd toggle_terminal', 'wait 300', *actions, 'quit']) + '\n',
                          encoding='utf-8')
        result = subprocess.run([str(EXE), str(self.project), str(self.project / 'long.txt'),
                                 '--headless', '1280x800', '--scale', '1', '--script', str(script)],
                                env=self.env, capture_output=True, text=True, encoding='utf-8',
                                timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def height(self):
        """The terminal height rhun saved on exit."""
        match = re.search(r'^\[terminal\][^\[]*?^height = (\d+)$', self.config.read_text(encoding='utf-8'),
                          re.M | re.S)
        self.assertIsNotNone(match)
        return int(match.group(1))

    def test_a_press_on_an_agent_session_keeps_the_height(self):
        # a Claude session of the project, so the agents panel lists a row
        slug = re.sub(r'[^A-Za-z0-9]', '-', self.project.as_posix())
        sessions = self.home / '.claude/projects' / slug
        sessions.mkdir(parents=True)
        fixture = (ROOT / 'tests/data/agents/claude.jsonl').read_text(encoding='utf-8')
        (sessions / 's1.jsonl').write_text(fixture.replace('@PROJECT@', self.project.as_posix()),
                                           encoding='utf-8')
        x, y = AGENT_ROW
        self.run_editor(['wait-agents', f'move {x} {y}', 'wait 50', 'down', 'wait 50', f'move {x} {y + 4}',
                          'wait 50', 'up', 'wait 50'], agents=True)
        self.assertEqual(self.height(), HEIGHT)

    def test_dragging_the_edge_leaves_the_editor_alone(self):
        # pressed just above the line, inside the editor's last rows, and dragged down 100: the
        # height follows the pointer, from the edge to the status bar
        out = self.run_editor([f'move 600 {EDGE - 2}', 'wait 50', 'down', 'wait 50',
                               f'move 600 {EDGE + 40}', 'wait 50', f'move 600 {EDGE + 98}',
                               'wait 300', 'up', 'wait 50', 'print-state'])
        state = [line for line in out.splitlines() if line.startswith('tabs=')][-1]
        self.assertIn('line=1 col=1 sel=0', state)
        self.assertEqual(self.height(), HEIGHT - 98)

    def test_a_window_narrower_than_its_panels(self):
        # A 600 pt explorer in a 500 pt window (1000 px at scale 2) gives way, so the editor keeps its
        # 240 pt and the terminal under it a grid. Its negative width once made that grid 268 million
        # columns wide: gigabytes within a second, so the run is watched and stopped early.
        self.config.write_text(
            '[ui]\nsidebar = true\nsidebar_width = 600\nagents_panel = false\n'
            '[terminal]\nshell = /bin/sh\n'
            '[editor]\ncursor_blink = false\n'
            '[files]\nrestore_session = false\nrestore_project = false\n'
            '[updates]\ncheck = false\n[git]\nenabled = false\n', encoding='utf-8')
        script = self.home / 'commands.rsc'
        script.write_text('\n'.join(['wait 200', 'cmd toggle_terminal', 'wait 300',
                                     'type echo R$((1+1))X $(stty size)', 'key Return', 'wait-term R2X',
                                     'print-term', 'print-panels', 'quit']) + '\n', encoding='utf-8')
        out_path = self.home / 'out.txt'

        def limits():
            import resource
            resource.setrlimit(resource.RLIMIT_CPU, (30, 30))
            if sys.platform.startswith('linux'):
                resource.setrlimit(resource.RLIMIT_AS, (2 << 30, 2 << 30))

        def rss_mb(pid):
            try:
                for line in Path(f'/proc/{pid}/status').read_text().splitlines():
                    if line.startswith('VmRSS:'):
                        return int(line.split()[1]) // 1024
            except OSError:
                pass
            ps = subprocess.run(['ps', '-o', 'rss=', '-p', str(pid)], capture_output=True, text=True)
            return int(ps.stdout.strip() or 0) // 1024

        with open(out_path, 'wb') as out:
            proc = subprocess.Popen([str(EXE), str(self.project), '--headless', '1000x600', '--scale', '2',
                                     '--script', str(script)], env=self.env, stdout=out,
                                    stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, preexec_fn=limits)
            peak = 0
            deadline = time.monotonic() + 30
            while proc.poll() is None:
                peak = max(peak, rss_mb(proc.pid))
                if peak > 500 or time.monotonic() > deadline:
                    proc.kill()
                    proc.wait()
                    break
                time.sleep(0.05)
        output = out_path.read_text(encoding='utf-8', errors='replace')
        self.assertLess(peak, 500, output[-2000:])
        self.assertEqual(proc.returncode, 0, output[-2000:])
        self.assertIn('explorer=1 agents=0 term=1', output)
        size = re.search(r'R2X (\d+) (\d+)', output)
        self.assertIsNotNone(size, output[-2000:])
        rows, cols = int(size.group(1)), int(size.group(2))
        self.assertGreaterEqual(rows, 2)
        self.assertTrue(20 <= cols <= 40, cols)       # 480 px of a 1000 px window, less its margins

    def test_the_hide_button_hides_the_panel_at_once(self):
        # the click is handled while the panel is drawn: the frame without it must follow by
        # itself, not with the next caret blink or pointer move (here nothing blinks)
        out = self.run_editor([f'click 1260 {EDGE + 14}', 'print-frames', 'wait 100', 'print-frames',
                               'print-panels'])
        frames = [int(line[7:]) for line in out.splitlines() if line.startswith('frames=')]
        self.assertIn('term=0', out)
        self.assertGreaterEqual(frames[1], 1, out)


if __name__ == '__main__':
    unittest.main(verbosity=2)
