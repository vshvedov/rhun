#!/usr/bin/env python3
"""Reopen Closed Tab (Ctrl+Shift+T, Command+Shift+T on macOS) brings back the last closed tabs, the
latest first, at their place in the strip and with the cursor, selection and scroll a file had. Tabs
that are open again or whose files are gone are passed over; the theme picker keeps Ctrl+K."""
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
EXE = Path(os.environ.get('RHUN_TEST_EXE', ROOT / 'build/rhun')).resolve()
CONFIG = ('[files]\nrestore_session = false\nrestore_project = false\n'
          '[updates]\ncheck = false\n[git]\nenabled = {git}\n'
          '[editor]\ncursor_blink = false\n'
          '[ui]\nagents_panel = false\nsidebar = false\n')


@unittest.skipIf(os.name == 'nt', 'the control socket is Unix only')
class ReopenClosedTab(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rhun-reopen-', dir='/tmp')
        self.work = Path(self.tmp.name).resolve()
        self.project = self.work / 'project'
        self.project.mkdir()
        for name in ('a.txt', 'b.txt', 'c.txt'):
            (self.project / name).write_text(''.join(f'{name} line {i}\n' for i in range(1, 301)),
                                             encoding='utf-8')
        self.env = dict(os.environ, HOME=str(self.work), XDG_CONFIG_HOME=str(self.work / 'config'),
                        XDG_STATE_HOME=str(self.work / 'state'))
        self.write_config(git=False)
        self.process = None
        self.client = None
        self.reader = None

    def tearDown(self):
        self.stop()
        self.tmp.cleanup()

    def write_config(self, git):
        config = self.work / 'config/rhun/config'
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text(CONFIG.format(git='true' if git else 'false'), encoding='utf-8')

    def start(self, *paths):
        control = self.work / 'control'
        control.unlink(missing_ok=True)
        self.process = subprocess.Popen([str(EXE), str(self.project), *map(str, paths),
                                         '--headless', '1000x700', '--scale', '1',
                                         '--control', str(control)], env=self.env,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.client.settimeout(10)
        deadline = time.monotonic() + 10
        while True:
            try:
                self.client.connect(str(control))
                break
            except (FileNotFoundError, ConnectionRefusedError):
                if self.process.poll() is not None or time.monotonic() > deadline:
                    self.fail('editor did not start')
                time.sleep(0.01)
        self.reader = self.client.makefile('r', encoding='utf-8')
        self.command('wait 100')

    def stop(self):
        if self.process is not None:
            if self.process.poll() is None:
                self.process.terminate()
                self.process.wait(timeout=10)
            self.process.stderr.close()
            self.process = None
        if self.reader is not None:
            self.reader.close()
            self.reader = None
        if self.client is not None:
            self.client.close()
            self.client = None

    def command(self, line):
        self.client.sendall((line + '\n').encode('utf-8'))
        output = []
        while True:
            reply = self.reader.readline()
            if reply == 'ok\n':
                return ''.join(output)
            self.assertNotIn(reply, ('', 'error\n'), line)
            output.append(reply)

    def tabs(self):
        return self.command('print-tabs').strip()

    def state(self):
        line = self.command('print-state')
        return dict(part.split('=', 1) for part in line.split() if '=' in part)

    def open(self, *names):
        for name in names:
            self.command(f'open {self.project / name}')

    def reopen(self):
        self.command('key ctrl+shift+t')

    def test_reopens_where_it_was_with_its_cursor_and_selection(self):
        self.start()
        self.open('a.txt', 'b.txt', 'c.txt')
        self.command('cmd prev_tab')
        self.command('key ctrl+g')
        self.command('type 120')
        self.command('key Return')
        for _ in range(3):
            self.command('key shift+Right')
        before = self.state()
        self.assertEqual((before['active'], before['line'], before['col'], before['sel']),
                         ('b.txt', '120', '4', '3'))
        scroll = self.command('print-scroll')
        self.command('cmd close_tab')
        self.assertEqual(self.tabs(), 'tabs=a.txt | *c.txt')
        self.reopen()
        self.assertEqual(self.tabs(), 'tabs=a.txt | *b.txt | c.txt')
        after = self.state()
        for field in ('active', 'line', 'col', 'sel', 'dirty', 'focus'):
            self.assertEqual(after[field], before[field], field)
        self.assertEqual(self.command('print-scroll'), scroll)
        # nothing left to reopen: nothing happens
        self.reopen()
        self.assertEqual(self.tabs(), 'tabs=a.txt | *b.txt | c.txt')

    def test_scroll_comes_back(self):
        self.start()
        self.open('a.txt', 'b.txt')
        self.command('key ctrl+g')
        self.command('type 200')
        self.command('key Return')
        # the cursor stays in view, a few lines up from where going to it put the view
        self.command('move 500 300')
        self.command('scroll -60')
        scroll = self.command('print-scroll')
        self.command('cmd close_tab')
        self.assertNotEqual(self.command('print-scroll'), scroll)
        self.reopen()
        self.assertEqual(self.state()['line'], '200')
        self.assertEqual(self.command('print-scroll'), scroll)

    def test_scroll_comes_back_with_the_cursor_out_of_view(self):
        self.start()
        self.open('a.txt', 'b.txt')
        self.command('move 500 300')
        self.command('scroll 2400')
        scroll = self.command('print-scroll')
        self.assertNotIn(' y=0 ', scroll)
        self.command('cmd close_tab')
        self.reopen()
        self.assertEqual(self.state()['line'], '1')
        self.assertEqual(self.command('print-scroll'), scroll)

    def test_vim_visual_mode_ends_as_when_the_tab_is_left(self):
        self.start()
        self.open('a.txt', 'b.txt')
        self.command('cmd toggle_vim')
        self.command('type jjlvll')
        state = self.state()
        self.assertEqual((state['vim'], state['line'], state['col'], state['sel']), ('visual', '3', '4', '3'))
        self.command('cmd close_tab')
        self.reopen()
        state = self.state()
        self.assertEqual((state['active'], state['vim'], state['line'], state['col'], state['sel']),
                         ('b.txt', 'normal', '3', '4', '0'))

    def test_close_all_comes_back_one_by_one_in_order(self):
        self.start()
        self.open('a.txt', 'b.txt', 'c.txt')
        self.command('cmd settings')
        self.command('cmd prev_tab')
        self.assertEqual(self.tabs(), 'tabs=a.txt | b.txt | *c.txt | Settings')
        self.command('cmd close_all_tabs')
        self.assertEqual(self.tabs(), 'tabs=')
        self.reopen()
        self.assertEqual(self.tabs(), 'tabs=*a.txt')
        self.reopen()
        self.reopen()
        self.assertEqual(self.tabs(), 'tabs=a.txt | b.txt | *c.txt')
        self.reopen()
        self.assertEqual(self.tabs(), 'tabs=a.txt | b.txt | c.txt | *Settings')
        self.reopen()
        self.assertEqual(self.tabs(), 'tabs=a.txt | b.txt | c.txt | *Settings')

    def test_open_tabs_and_missing_files_give_way(self):
        self.start()
        self.open('a.txt', 'b.txt', 'c.txt')
        self.command('cmd close_tab')                   # c.txt
        self.open('c.txt')                              # open again
        self.command('cmd prev_tab')
        self.command('cmd close_tab')                   # b.txt
        (self.project / 'b.txt').unlink()
        self.command('cmd prev_tab')
        self.command('cmd close_tab')                   # a.txt
        self.assertEqual(self.tabs(), 'tabs=*c.txt')
        self.reopen()
        self.assertEqual(self.tabs(), 'tabs=*a.txt | c.txt')
        # b.txt is gone and c.txt is open: nothing else to reopen
        self.reopen()
        self.assertEqual(self.tabs(), 'tabs=*a.txt | c.txt')

    def test_a_tab_closed_twice_is_remembered_once(self):
        self.start()
        self.open('a.txt', 'b.txt')
        self.command('cmd close_tab')
        self.reopen()
        self.command('cmd close_tab')
        self.command('cmd close_tab')                   # a.txt
        self.reopen()
        self.reopen()
        self.assertEqual(self.tabs(), 'tabs=a.txt | *b.txt')
        self.reopen()
        self.assertEqual(self.tabs(), 'tabs=a.txt | *b.txt')

    def test_untitled_tabs_are_not_remembered(self):
        self.start()
        self.open('a.txt')
        self.command('cmd new_file')
        self.assertEqual(self.tabs(), 'tabs=a.txt | *untitled')
        self.command('cmd close_tab')
        self.assertEqual(self.tabs(), 'tabs=*a.txt')
        self.command('cmd close_tab')
        self.reopen()
        self.reopen()
        self.assertEqual(self.tabs(), 'tabs=*a.txt')

    def test_twenty_are_kept(self):
        for i in range(22):
            (self.project / f'f{i:02}.txt').write_text(f'{i}\n', encoding='utf-8')
        self.start()
        self.open(*(f'f{i:02}.txt' for i in range(22)))
        self.command('cmd close_all_tabs')
        for _ in range(25):
            self.reopen()
        names = [f'f{i:02}.txt' for i in range(20)]
        names[-1] = '*' + names[-1]
        self.assertEqual(self.tabs(), 'tabs=' + ' | '.join(names))

    def test_a_changed_file_keeps_the_cursor_inside_its_text(self):
        note = self.project / 'note.txt'
        note.write_text('x' * 50 + '\n', encoding='utf-8')
        self.start()
        self.open('a.txt', 'note.txt')
        self.command('key ctrl+End')
        self.command('cmd close_tab')
        # two-byte characters now cover the old cursor position: it moves to the start of one
        note.write_bytes('é'.encode('utf-8') * 30)
        self.reopen()
        state = self.state()
        self.assertEqual((state['active'], state['line'], state['col']), ('note.txt', '1', '26'))
        self.command('type !')
        self.assertTrue(self.command('print-doc').startswith('é' * 25 + '!' + 'é' * 5))

    def test_another_project_starts_with_nothing_to_reopen(self):
        other = self.work / 'other'
        other.mkdir()
        self.start()
        self.open('a.txt', 'b.txt')
        self.command('cmd close_tab')
        self.command(f'open {other}')
        self.assertIn('other', self.command('print-project'))
        self.reopen()
        self.assertEqual(self.tabs(), 'tabs=')

    def test_theme_picker_keeps_ctrl_k(self):
        self.start()
        self.open('a.txt')
        self.command('cmd close_tab')
        self.reopen()
        self.assertEqual(self.state()['focus'], '0')
        self.assertEqual(self.tabs(), 'tabs=*a.txt')
        self.command('key ctrl+k')
        self.assertEqual(self.state()['focus'], '1')
        self.assertIn('Dracula', self.command('print-palette'))

    @unittest.skipIf(shutil.which('git') is None, 'git is not installed')
    def test_git_history_and_diff_views_come_back(self):
        git = ['git', '-C', str(self.project), '-c', 'user.name=t', '-c', 'user.email=t@t']
        subprocess.run([*git, 'init', '-q'], check=True)
        subprocess.run([*git, 'add', '.'], check=True)
        subprocess.run([*git, 'commit', '-q', '-m', 'one'], check=True)
        with open(self.project / 'a.txt', 'a', encoding='utf-8') as f:
            f.write('more\n')
        self.write_config(git=True)
        self.start()
        self.command('wait-git')
        self.open('a.txt')
        self.command('cmd git_changes')
        self.command('cmd git_history')
        self.assertEqual(self.tabs(), 'tabs=a.txt | a.txt (changes) | *Git')
        self.command('cmd close_tab')
        self.command('cmd close_tab')
        self.assertEqual(self.tabs(), 'tabs=*a.txt')
        self.reopen()
        self.assertEqual(self.tabs(), 'tabs=a.txt | *a.txt (changes)')
        self.command('wait-git')
        self.assertTrue(self.command('print-doc').startswith('@@ -298,3 +298,4 @@'))
        self.reopen()
        self.assertEqual(self.tabs(), 'tabs=a.txt | a.txt (changes) | *Git')


if __name__ == '__main__':
    unittest.main()
