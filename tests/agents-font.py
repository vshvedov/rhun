#!/usr/bin/env python3
"""The agents panel's own text size ([agents] font_size): 0 follows the interface, 1 to 7 act as 8,
at most 32. It applies while running, sizes the list, the conversation and its Markdown, the boxes
in proportion, and the zoom keys change it instead of the editor's while the panel or its prompt
box has the focus (the three Agents commands wherever the focus is)."""
import configparser
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
EXE = Path(os.environ.get('RHUN_TEST_EXE', ROOT / 'build/rhun')).resolve()
MOD = 'cmd' if sys.platform == 'darwin' else 'ctrl'
UI = 13                         # the interface's font size by default

REPLY = '\n'.join(['## Plan', '', 'Some **bold** words and a long line of them ' * 3, '',
                   '- one', '- two', '', '```sh', 'echo hi', '```'])


@unittest.skipIf(os.name == 'nt', 'the control socket is Unix only')
class FontSizeTest(unittest.TestCase):
    def setUp(self):
        # a socket's path is short (104 bytes on macOS): the folder under /tmp
        self.tmp = tempfile.TemporaryDirectory(prefix='rhun-agfont-', dir='/tmp')
        self.work = Path(self.tmp.name).resolve()
        self.project = self.work / 'project'
        self.project.mkdir()
        (self.project / 'a.txt').write_text('hello\n', encoding='utf-8')
        self.config = self.work / 'config/rhun/config'
        self.config.parent.mkdir(parents=True)
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith('CLAUDE') and not k.startswith('ANTHROPIC')}
        self.env.update(HOME=str(self.work), XDG_CONFIG_HOME=str(self.work / 'config'),
                        XDG_STATE_HOME=str(self.work / 'state'), GIT_CONFIG_NOSYSTEM='1')
        slug = re.sub(r'[^A-Za-z0-9]', '-', self.project.as_posix())
        sessions = self.work / '.claude/projects' / slug
        sessions.mkdir(parents=True)
        cwd = self.project.as_posix()
        lines = [json.dumps({'type': 'user', 'message': {'role': 'user', 'content': 'go'},
                             'cwd': cwd, 'sessionId': 's1'}),
                 json.dumps({'type': 'assistant', 'message': {
                     'role': 'assistant', 'content': [{'type': 'text', 'text': REPLY}]}}),
                 json.dumps({'type': 'custom-title', 'customTitle': 's1', 'sessionId': 's1'})]
        (sessions / 's1.jsonl').write_text('\n'.join(lines) + '\n', encoding='utf-8')
        self.process = self.client = self.reader = None

    def tearDown(self):
        self.stop()
        self.tmp.cleanup()

    def configure(self, agents='', editor=17):
        self.config.write_text('[files]\nrestore_session = false\nrestore_project = false\n'
                               '[updates]\ncheck = false\n[git]\nenabled = false\n'
                               '[editor]\ncursor_blink = false\nfont_size = %d\n'
                               '[ui]\nsidebar = false\nagents_panel = true\nagents_width = 380\n'
                               '[agents]\n%s' % (editor, agents), encoding='utf-8')

    def start(self, agents='', editor=17):
        self.configure(agents, editor)
        control = self.work / 'control'
        self.process = subprocess.Popen([str(EXE), str(self.project), str(self.project / 'a.txt'),
                                         '--headless', '1280x800', '--scale', '1',
                                         '--control', str(control)], env=self.env,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.client.settimeout(30)
        deadline = time.monotonic() + 15
        while True:
            try:
                self.client.connect(str(control))
                break
            except (FileNotFoundError, ConnectionRefusedError):
                if self.process.poll() is not None or time.monotonic() > deadline:
                    self.fail('editor did not start')
                time.sleep(0.01)
        self.reader = self.client.makefile('r', encoding='utf-8')
        self.command('wait-agents')

    def stop(self):
        if self.process is not None and self.process.poll() is None:
            try:
                self.client.sendall(b'quit\n')
                self.process.wait(timeout=10)
            except (OSError, subprocess.TimeoutExpired):
                self.process.kill()
                self.process.wait()
        for closable in (self.reader, self.client):
            if closable is not None:
                closable.close()
        self.process = self.client = self.reader = None

    def command(self, line):
        self.client.sendall((line + '\n').encode('utf-8'))
        output = []
        while True:
            reply = self.reader.readline()
            if reply == 'ok\n':
                return ''.join(output)
            self.assertNotIn(reply, ('', 'error\n'), line)
            output.append(reply)

    def metrics(self):
        line = self.command('print-agents-metrics').strip()
        return {k: int(v) for k, v in (field.split('=') for field in line.split())}

    def saved(self):
        """[agents] font_size and [editor] font_size of the file written on exit"""
        self.stop()
        config = configparser.ConfigParser(interpolation=None, strict=False)
        config.read(self.config, encoding='utf-8')
        return config.getint('agents', 'font_size'), config.getint('editor', 'font_size')

    def focus(self):
        return int(re.search(r' focus=(\d+) ', self.command('print-state')).group(1))

    def open_conversation(self):
        self.command('print-agents 1')
        self.command('wait 50')

    def test_the_setting_shows_round_trips_and_applies_live(self):
        self.start('font_size = 20\n')
        self.assertIn('agents.font_size\n', self.command('print-settings'))
        m = self.metrics()
        self.assertEqual((m['size'], m['points'], m['px']), (20, 20, 20))
        big = m
        # the file read again while running: back to the interface's size
        self.configure('font_size = 0\n')
        for _ in range(50):
            self.command('wait 100')
            m = self.metrics()
            if m['size'] == 0:
                break
        self.assertEqual((m['size'], m['points'], m['px']), (0, UI, UI))
        self.assertLess(m['line'], big['line'])
        self.assertLess(m['row'], big['row'])
        self.assertLess(m['small'], m['px'])
        self.command('cmd agents_font_increase')     # a change: the exit writes the file
        self.assertEqual(self.saved(), (UI + 1, 17))
        self.start('font_size = 24\n')
        self.command('cmd toggle_word_wrap')
        self.assertEqual(self.saved()[0], 24)

    def test_sizes_below_8_act_as_8_and_the_most_is_32(self):
        for value, points in ((3, 8), (8, 8), (32, 32), (99, 32), (0, UI)):
            with self.subTest(value=value):
                self.start('font_size = %d\n' % value)
                m = self.metrics()
                self.assertEqual((m['points'], m['px']), (points, points))
                self.stop()

    def test_the_commands_step_and_reset_it_wherever_the_focus_is(self):
        self.start()
        self.assertNotIn(self.focus(), (6, 56))       # the editor's
        sizes = []
        for name in ('increase', 'increase', 'decrease', 'reset', 'decrease', 'decrease'):
            self.command('cmd agents_font_' + name)
            sizes.append(self.metrics()['size'])
        # from 0 up past the interface's size; down from 0 below it
        self.assertEqual(sizes, [UI + 1, UI + 2, UI + 1, 0, UI - 1, UI - 2])
        self.assertEqual(self.saved(), (UI - 2, 17))

    def test_the_bounds_hold_at_8_and_32(self):
        self.start('font_size = 9\n')
        for expected in (8, 0):                      # 8 steps down to following the interface
            self.command('cmd agents_font_decrease')
            self.assertEqual(self.metrics()['size'], expected)
        self.stop()
        self.start('font_size = 31\n')
        for _ in range(3):
            self.command('cmd agents_font_increase')
        self.assertEqual(self.metrics()['size'], 32)
        self.stop()
        self.start('font_size = 5\n')                # acts as 8: one up is 9
        self.command('cmd agents_font_increase')
        self.assertEqual(self.metrics()['size'], 9)

    def test_the_zoom_keys_change_it_only_with_the_panel_focused(self):
        self.start()
        self.command(f'key {MOD}+=')                 # the editor has the focus: the editor zooms
        self.assertEqual(self.metrics()['size'], 0)
        self.command('cmd focus_agents')
        self.assertEqual(self.focus(), 6)
        self.command(f'key {MOD}+=')
        self.command(f'key {MOD}+shift++')
        self.command(f'key {MOD}+-')
        self.assertEqual(self.metrics()['size'], UI + 1)
        self.command(f'key {MOD}+0')
        self.assertEqual(self.metrics()['size'], 0)
        self.command(f'key {MOD}+-')
        self.assertEqual(self.metrics()['size'], UI - 1)
        if sys.platform != 'darwin':
            # X11 and Wayland report the keypad's own keys
            self.command('key ctrl+KP_Add')
            self.command('key ctrl+KP_Add')
            self.command('key ctrl+KP_Subtract')
            self.assertEqual(self.metrics()['size'], UI)
            self.command('key ctrl+KP_0')
            self.assertEqual(self.metrics()['size'], 0)
            self.command('key ctrl+KP_Subtract')
            self.assertEqual(self.metrics()['size'], UI - 1)
        self.assertEqual(self.saved(), (UI - 1, 18))

    def test_the_zoom_keys_in_the_prompt_box(self):
        self.start()
        self.open_conversation()
        self.command('cmd focus_agents')
        self.command('key Return')                   # Enter in the panel goes to the box
        self.assertEqual(self.focus(), 56)
        self.command(f'key {MOD}+=')
        self.command(f'key {MOD}+=')
        self.assertEqual(self.metrics()['size'], UI + 2)
        self.assertEqual(self.focus(), 56)
        self.assertIn('input= ', self.command('print-agent-input'))   # nothing was typed
        self.assertEqual(self.saved(), (UI + 2, 17))

    @unittest.skipIf(sys.platform == 'darwin', 'macOS distinguishes Command from Control')
    def test_physical_control_zooms_on_linux(self):
        self.start()
        self.command('cmd focus_agents')
        self.command('key ctrl+=')
        self.assertEqual(self.metrics()['size'], UI + 1)

    def test_every_height_follows_the_size(self):
        self.start()
        self.open_conversation()

        def rows():
            out = {}
            for n in (1, 2):
                header = self.command('print-agent-row %d' % n).splitlines()[0]
                out[n] = dict(field.split('=', 1) for field in header.split())
            return out
        small = rows()
        self.assertEqual(small[2]['parsed'], '1')
        for _ in range(11):                          # 0 -> 14 -> ... -> 24
            self.command('cmd agents_font_increase')
        self.command('wait 50')
        self.assertEqual(self.metrics()['size'], 24)
        big = rows()
        for n in (1, 2):
            self.assertGreater(int(big[n]['height']), int(small[n]['height']) * 3 // 2, n)
        self.assertGreater(int(big[1]['content']), int(small[1]['content']))
        # the Markdown is laid out again at the size: its blocks stay the same
        self.assertEqual(self.command('print-agent-row 2').splitlines()[1:3],
                         ['heading:2 Plan', 'para ' + ('Some bold words and a long line of them ' * 3).strip()])
        self.command('cmd agents_font_reset')
        self.command('wait 50')
        self.assertEqual(rows()[2]['height'], small[2]['height'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
