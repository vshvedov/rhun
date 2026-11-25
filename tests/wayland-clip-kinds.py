#!/usr/bin/env python3
"""Phase 4 task 4 on a private headless Sway: the selection's offer read for its kinds. A request that takes
files and an image (clip-request 7, as the agents' box of a driver with parts asks) receives text/uri-list
before image/png before the text; a request for text alone never asks for either; an image larger than the
request reads stops at its limit. It reuses tests/wayland-clipboard.py's compositor and its C owner (which
offers one payload under the MIME types it is given); none of that file's own tests run here. Nothing touches
the desktop's clipboard."""
import importlib.util
from pathlib import Path
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location('wayland_clipboard', ROOT / 'tests/wayland-clipboard.py')
base = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(base)

TEXT = 'text/plain;charset=utf-8'
PNG = b'\x89PNG\r\n\x1a\n' + bytes(200)
LIMIT = 10 * 1024 * 1024 + 1        # MP_IMAGE_MAX + 1: what a request reads of an image at most


class ClipKinds(base.Clipboard):
    def clip(self):
        return dict(w.split('=', 1) for w in self.command('print-clip').decode().split())

    def until_kind(self, kind):
        deadline = time.monotonic() + 10
        while True:
            clip = self.clip()
            if clip['kind'] == kind:
                return clip
            self.alive()
            self.assertLess(time.monotonic(), deadline, clip)
            time.sleep(.02)

    def kinds_request(self, mime):
        self.command('clip-request 7')
        return self.owner_request(mime)

    def test_files_win_over_an_image_and_text(self):
        target = self.work / 'a b.txt'
        target.write_text('aye\n')
        uris = b'# a comment\r\nfile://' + str(target).replace(' ', '%20').encode() + b'\r\nhttp://x/y\r\n'
        self.start_case(uris, (TEXT, 'image/png', 'text/uri-list'))
        self.release_owner(self.kinds_request('text/uri-list'))
        clip = self.until_kind('2')
        self.assertEqual(int(clip['read']), len(str(target)) + 1)
        self.assertEqual(clip['asked'], '7')

    def test_an_image_when_no_files(self):
        self.start_case(PNG, (TEXT, 'image/png'))
        self.release_owner(self.kinds_request('image/png'))
        self.assertEqual(int(self.until_kind('4')['read']), len(PNG))

    def test_text_when_neither(self):
        self.start_case(b'plain words', (TEXT,))
        self.finish(self.kinds_request(TEXT), b'plain words', save=False)
        self.assertEqual(self.clip()['kind'], '1')

    def test_text_alone_asks_for_no_image(self):
        self.start_case(b'only the text', (TEXT, 'image/png', 'text/uri-list'))
        self.finish(self.request(TEXT), b'only the text', save=False)
        self.assertEqual(self.clip()['asked'], '1')

    def test_an_image_over_the_limit_stops_reading(self):
        self.start_case(PNG + bytes(LIMIT), (TEXT, 'image/png'))
        inode = self.kinds_request('image/png')
        self.owner.stdin.write(b'finish\n')
        self.owner.stdin.flush()
        self.assertTrue(self.line(self.owner, 30).startswith(b'closed '))
        clip = self.until_kind('4')
        self.assertLessEqual(int(clip['read']), LIMIT)
        deadline = time.monotonic() + 10
        while self.pipe_present(inode):
            self.assertLess(time.monotonic(), deadline, 'the receive was not closed')
            time.sleep(.01)
        self.assertEqual(self.command('print-doc'), b'original\n<eod>\n')


for _name in dir(base.Clipboard):     # only this file's cases run here
    if _name.startswith('test_') and _name not in ClipKinds.__dict__:
        setattr(ClipKinds, _name, None)

if __name__ == '__main__':
    unittest.main(verbosity=2)
