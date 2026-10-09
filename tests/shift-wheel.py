#!/usr/bin/env python3
"""Shift turns the wheel sideways on Linux and Windows (discussion 67), in the views that scroll
sideways: the editor and an image. macOS turns a Shift wheel itself, so rhun leaves it as it comes
there. The terminal keeps Shift's wheel for its scrollback."""
import hashlib
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
EXE = Path(os.environ.get('RHUN_TEST_EXE', ROOT / 'build/rhun')).resolve()
MACOS = sys.platform == 'darwin'


@unittest.skipIf(os.name == 'nt', 'the control socket is Unix only')
class ShiftWheel(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rhun-shift-wheel-', dir='/tmp')
        self.work = Path(self.tmp.name).resolve()
        self.project = self.work / 'project'
        self.project.mkdir()
        lines = [f'line {i:02d} ' + 'wide ' * 60 for i in range(80)]
        (self.project / 'wide.txt').write_text('\n'.join(lines) + '\n', encoding='utf-8')
        config = self.work / 'config/rhun/config'
        config.parent.mkdir(parents=True)
        config.write_text('[files]\nrestore_session = false\nrestore_project = false\n'
                          '[updates]\ncheck = false\n[git]\nenabled = false\n'
                          '[editor]\ncursor_blink = false\n'
                          '[ui]\nagents_panel = false\nsidebar = false\nauto_hide_scrollbars = false\n'
                          '[terminal]\nshell = /bin/sh\n', encoding='utf-8')
        self.env = dict(os.environ, HOME=str(self.work), XDG_CONFIG_HOME=str(self.work / 'config'),
                        XDG_STATE_HOME=str(self.work / 'state'), PS1='$ ', ENV='', HISTFILE='/dev/null')
        self.process = self.client = self.reader = None

    def tearDown(self):
        if self.process is not None:
            if self.process.poll() is None:
                self.process.terminate()
                self.process.wait(timeout=10)
            self.reader.close()
            self.client.close()
            self.process.stderr.close()
        # the shell goes on a moment after rhun and can still write in its home folder
        for _ in range(50):
            try:
                self.tmp.cleanup()
                return
            except OSError:
                time.sleep(0.1)
        self.tmp.cleanup()

    def start(self, *paths):
        control = self.work / 'control'
        self.process = subprocess.Popen([str(EXE), str(self.project), *map(str, paths),
                                         '--headless', '1280x800', '--scale', '1',
                                         '--control', str(control)], env=self.env,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.client.settimeout(15)
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

    def command(self, line):
        self.client.sendall((line + '\n').encode('utf-8'))
        output = []
        while True:
            reply = self.reader.readline()
            if reply == 'ok\n':
                return ''.join(output)
            self.assertNotIn(reply, ('', 'error\n'), line)
            output.append(reply)

    def scroll(self):
        """the editor's x in pixels and y in 1/256 lines"""
        fields = dict(part.split('=') for part in self.command('print-scroll').split())
        return int(fields['x']), int(fields['y'])

    def shot(self):
        path = self.work / 'shot.ppm'
        self.command(f'shot {path}')
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def test_the_editor_scrolls_sideways_with_shift(self):
        self.start(self.project / 'wide.txt')
        self.command('move 600 400')    # the wheel goes to what is under the pointer
        self.command('scroll 120 shift')
        x, y = self.scroll()
        if MACOS:
            self.assertEqual(x, 0)
            self.assertGreater(y, 0)
            return
        self.assertEqual((x, y), (120, 0))
        # without Shift it goes down, and Alt still makes it fast
        self.command('scroll 120')
        x, y = self.scroll()
        self.assertEqual(x, 120)
        self.assertGreater(y, 0)
        self.command('scroll 30 shift+alt')
        self.assertEqual(self.scroll(), (240, y))
        self.command('scroll -240 shift')
        self.assertEqual(self.scroll(), (0, y))

    def test_an_image_pans_sideways_with_shift(self):
        # a gradient, so that any pan moves pixels
        w, h = 1200, 900
        image = self.project / 'gradient.ppm'
        image.write_bytes(f'P6\n{w} {h}\n255\n'.encode() + bytes(
            v for y in range(h) for x in range(w) for v in (x % 256, y % 256, (x // 256 * 60) % 256)))
        self.start(image)
        self.command('move 600 400')
        # zoomed in past the view both ways (Ctrl's wheel stops at 100% on the way)
        self.command('scroll -500 ctrl')
        self.command('scroll -500 ctrl')
        self.assertIn(' zoom=300 fit=0 ', self.command('print-state'))
        before = self.shot()
        self.command('scroll 40 shift')
        self.assertNotEqual(self.shot(), before)
        # it went as far as a sideways wheel goes (down on macOS, as it came)
        self.command('scroll -40' if MACOS else 'scroll-x -40')
        self.assertEqual(self.shot(), before)

    def test_the_terminal_keeps_shift_for_its_scrollback(self):
        self.start()
        self.command('cmd toggle_terminal')
        self.command('type seq 1 300; echo done$((1000 + 1))')
        self.command('key Return')
        self.command('wait-term done1001')
        x, y = self.command('print-term-cell 1 4').split()
        self.command(f'move {x} {y}')
        # print-term shows the live screen: the scrollback shows in pictures
        bottom = self.shot()
        self.command('scroll -200 shift')
        up = self.shot()
        self.assertNotEqual(up, bottom)
        # the same as the wheel without Shift
        self.command('scroll 2000')
        self.assertEqual(self.shot(), bottom)
        self.command('scroll -200')
        self.assertEqual(self.shot(), up)


if __name__ == '__main__':
    unittest.main()
