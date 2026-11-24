#!/usr/bin/env python3
"""Pictures in a conversation as thumbnails (phase 4, task 6): the box's image chips, a prompt's chips live and
read again from the file, a reply's data: images, the picture opened in an image tab of its own, and the limits
that keep rhun fast: nothing decoded while a frame is drawn or while keys come, one decode a loop pass, the
header's size read first (16 megapixels at most), at most 64 thumbnails and 32 MiB of source bytes kept.
Against the fake CLI (tests/scripts/fake-claude.py), over the control socket; it imports tests/claude-attach.py
(and through it tests/claude-chat.py): every rhun gets its own HOME and XDG folders and an environment without
CLAUDE* or ANTHROPIC* variables."""
import base64
import importlib.util
import os
from pathlib import Path
import re
import struct
import time
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location('claude_attach', ROOT / 'tests/claude-attach.py')
attach = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(attach)
chat = attach.chat
IMAGES = ROOT / 'tests/data/images'


def flat_png(width, height, grey=0x80, pad=0):
    """A PNG of one flat grey, compressed (a few kilobytes even at 8000 x 8000); pad: a private chunk of
    random bytes so that two pictures of one size differ."""
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    row = b'\0' + bytes([grey]) * width
    comp = zlib.compressobj(9)
    data = b''.join(comp.compress(row) for _ in range(height)) + comp.flush()
    out = (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 0, 0, 0, 0))
           + chunk(b'IDAT', data))
    if pad:
        out += chunk(b'prVt', os.urandom(pad))
    return out + chunk(b'IEND', b'')


WEBP = b'RIFF' + struct.pack('<I', 30) + b'WEBPVP8 ' + struct.pack('<I', 18) + bytes(18)


class ImagesCase(attach.AttachCase):
    def images(self):
        """print-agent-images: {'head': {...}, 'recs': [{'id', 'kind', 'state', ...}]}."""
        lines = self.command('print-agent-images').splitlines()
        head = {k: int(v) for k, v in (w.split('=', 1) for w in lines[0].split(' '))}
        recs = []
        for line in lines[1:]:
            words = line.split(' ')
            rec = {'id': int(words[0]), 'kind': words[1], 'state': words[2]}
            rec.update(w.split('=', 1) for w in words[3:])
            recs.append(rec)
        return {'head': head, 'recs': recs}

    def head(self):
        return self.images()['head']

    def until_head(self, key, value, seconds=10):
        seen = []
        try:
            return self.until(lambda: seen.append(self.head()) or seen[-1][key] == value or None, f'{key}={value}',
                              seconds)
        except AssertionError:
            self.fail(f'{key}={value}: {seen[-1]}')

    def row_dump(self, number):
        return self.command(f'print-agent-row {number + 1}')

    def chip_thumb(self):
        """The box chips' thumb= values, in order."""
        return [int(m.group(1)) for line in self.att()['parts'] for m in [re.search(r' thumb=(\d)', line)] if m]

    def reread(self):
        """The program ends and the conversation is read again from its file."""
        self.command('agent-release')
        self.command('wait-agent off')
        self.until_gone()

    def send_image(self, path, prompt='echoblocks'):
        self.attach(path)
        self.command('agent-prompt ' + prompt)
        self.ready()
        return self.last_user_row()


class ImagesTest(ImagesCase):
    def test_a_chip_gets_its_picture_after_the_frame(self):
        self.start()
        self.chat('hello')
        self.attach(self.put('a.png', flat_png(300, 200)))
        recs = self.images()['recs']
        self.assertEqual(len(recs), 1, recs)
        self.assertEqual(recs[0]['pin'], '1')
        self.until_head('decoded', 1)
        rec = self.images()['recs'][0]
        self.assertEqual((rec['state'], rec['size'], rec['thumb']), ('ready', '300x200', '96x64'))
        self.command('print-frames')
        self.until(lambda: self.chip_thumb() == [1] or None, 'the chip drew its picture')
        # the chip's text names the picture, not the file
        self.command('agent-prompt echoblocks')
        self.ready()
        self.assertEqual(self.chips(self.last_user_row()), [f'i\ta.png\t#{rec["id"]}'])

    def test_attach_then_send_at_once(self):
        # sent before any decode: the record has its own bytes, so the row's chip gets its picture afterwards and
        # opens; the pack is gone at once
        self.start()
        self.chat('hello')
        self.command('agent-images-hold 1')
        self.attach(self.put('a.png', flat_png(300, 200)))
        self.command('agent-prompt echoblocks')
        self.ready()
        self.assertEqual(self.live_packs(), (0, 0))
        self.assertEqual(self.head()['decoded'], 0)
        row = self.last_user_row()
        [chip] = self.chips(row)
        rid = int(chip.split('\t')[2][1:])
        self.command('agent-images-hold 0')
        self.until(lambda: ' thumb=1' in self.row_dump(row) or None, 'the row drew its picture')
        rec = [r for r in self.images()['recs'] if r['id'] == rid][0]
        self.assertEqual(rec['pin'], '0')
        self.command(f'agent-image-open {rid} a.png')
        self.command('wait 50')
        self.command('print-frames')
        state = self.until(lambda: re.search(r' active= ?a\.png image=(\d+x\d+)', self.command('print-state')),
                           'the picture in a tab')
        self.assertEqual(state.group(1), '300x200')

    def test_no_decode_on_the_draw_path(self):
        self.start()
        self.chat('hello')
        self.command('agent-images-hold 1')
        for i in range(3):
            self.send_image(self.put(f'{i}.png', flat_png(20 + i, 20)), prompt=f'p{i}')
        for _ in range(5):
            self.command('print-frames')
        head = self.head()
        self.assertEqual((head['decoded'], head['thumbs']), (0, 0), head)
        self.assertGreaterEqual(head['waiting'], 3, head)
        self.command('agent-images-hold 0')
        self.until_head('decoded', 3)

    def test_no_decode_while_keys_come(self):
        self.start()
        self.chat('hello')
        self.command('agent-images-hold 1')
        self.attach(self.put('a.png', flat_png(300, 200)))
        self.command('agent-focus box')
        self.command('type x')
        self.command('agent-images-hold 0')
        for _ in range(10):
            self.command('type x')
            time.sleep(0.1)
            self.assertEqual(self.head()['decoded'], 0)
        self.until_head('decoded', 1, seconds=3)

    def test_one_decode_a_pass(self):
        self.start()
        self.chat('hello')
        self.command('agent-images-hold 1')
        self.attach(*[self.put(f'{i}.png', flat_png(40, 30 + i)) for i in range(4)])
        self.assertEqual(self.head()['waiting'], 4)
        before = int(re.search(r'passes=(\d+)', self.command('print-loop-stats')).group(1))
        self.command('agent-images-hold 0')
        self.until_head('decoded', 4)
        after = int(re.search(r'passes=(\d+)', self.command('print-loop-stats')).group(1))
        self.assertGreaterEqual(after - before, 4)

    def test_idle_after_decoding(self):
        self.start()
        self.chat('hello')
        self.attach(self.put('a.png', flat_png(64, 64)))
        self.until_head('decoded', 1)
        self.until(lambda: self.chip_thumb() == [1] or None, 'the chip drew its picture')
        self.command('wait 300')
        before = int(re.search(r'passes=(\d+)', self.command('print-loop-stats')).group(1))
        time.sleep(1)
        after = int(re.search(r'passes=(\d+)', self.command('print-loop-stats')).group(1))
        self.assertLessEqual(after - before, 6, 'the loop rests once the thumbnails are made')

    def test_a_tool_results_image_live_and_reread(self):
        """Checklist 3.12: a Read of a picture shows it under the call's output, live (decoded once, kept) and
        read again from the file (its place: the result's line, its n-th image)."""
        self.put('dot.png', flat_png(40, 30))
        self.start()
        self.chat('image')

        def call_row():
            return [int(l.split(' ')[0]) for l in self.rows() if re.match(r'\d+ tool', l)][-1]
        row = call_row()
        self.until(lambda: re.search(r'^pics 1 drew 1$', self.row_dump(row), re.M) or None, 'the live call drew it')
        self.assertEqual([r['kind'] for r in self.images()['recs']], ['bytes'])
        self.assertRegex(self.row_dump(row), r'(?m)^button 40 ')
        self.reread()
        row = call_row()
        self.until(lambda: re.search(r'^pics 1 drew 1$', self.row_dump(row), re.M) or None, 'the reread call drew it')
        place = [r for r in self.images()['recs'] if r['kind'] == 'place']
        self.assertEqual(len(place), 1, self.images()['recs'])
        self.assertEqual(place[0]['size'], '40x30')
        self.command(f'agent-image-open {place[0]["id"]}')
        self.until(lambda: re.search(r' image=40x30', self.command('print-state')), 'the picture opens')

    def test_a_prompts_image_live_and_reread(self):
        self.start()
        self.chat('hello')
        row = self.send_image(self.put('a.png', flat_png(300, 200)))
        self.until(lambda: ' thumb=1' in self.row_dump(row) or None, 'the live row drew its picture')
        self.reread()
        row = self.last_user_row()
        [chip] = self.chips(row)
        kind, label, target = chip.split('\t')
        self.assertEqual((kind, label), ('i', '[Image]'))
        self.assertRegex(target, r'^@\d+:\d+:0:\d+$')          # its line's place, its image, the line's hash
        self.until(lambda: ' thumb=1' in self.row_dump(row) or None, 'the reread row drew its picture')
        recs = self.images()['recs']
        self.assertEqual([r['kind'] for r in recs], ['place'], recs)
        self.assertEqual(recs[0]['size'], '300x200')
        self.command(f'agent-image-open {recs[0]["id"]}')
        self.until(lambda: re.search(r' image=300x200', self.command('print-state')), 'the reread picture opens')

    def test_a_place_whose_line_changed_gives_no_picture(self):
        """A place is the record's line by its offset and length: when the file was rewritten (another record now
        lies there, as long, between line feeds) the picture is not read from it: none rather than a wrong one."""
        self.start()
        self.chat('hello')
        self.send_image(self.put('a.png', flat_png(300, 200)))
        sid = self.sid()
        self.reread()
        row = self.last_user_row()
        [chip] = self.chips(row)
        off, length = map(int, chip.split('\t')[2][1:].split(':')[:2])
        path = self.work / '.claude/projects' / chat.slug(self.project) / (sid + '.jsonl')
        data = path.read_bytes()
        line = data[off:off + length]
        uuid = re.search(rb'"uuid": ?"([0-9a-f-]{36})"', line).group(1)
        other = bytes(b'0123456789abcdef'[(b'0123456789abcdef'.index(c) + 1) % 16] if c != ord('-') else c
                      for c in uuid)
        path.write_bytes(data[:off] + line.replace(uuid, other) + data[off + length:])
        recs = self.images()['recs']
        self.assertEqual([r['kind'] for r in recs], ['place'], recs)
        self.command(f'agent-image-open {recs[0]["id"]}')
        time.sleep(0.5)
        self.assertNotIn(' image=', self.command('print-state'))

    def test_thumbs_go_with_their_rows(self):
        self.start()
        self.chat('hello')
        row = self.send_image(self.put('a.png', flat_png(30, 20)))
        self.until(lambda: ' thumb=1' in self.row_dump(row) or None, 'the row drew its picture')
        self.assertEqual([r['kind'] for r in self.images()['recs']], ['bytes'])
        self.reread()                                   # its rows go: the live row's picture with them
        self.assertNotIn('bytes', [r['kind'] for r in self.images()['recs']])

    def test_a_data_image_in_a_reply_is_drawn(self):
        self.start()
        self.chat('hello')
        data = base64.b64encode(flat_png(40, 20)).decode()
        self.command(f'agent-test-row agent A picture:\\n\\n![p](data:image/png;base64,{data})\\n\\nafter')
        self.command('print-frames')
        recs = self.until(lambda: self.images()['recs'] or None, 'the reply asked for its picture')
        self.assertEqual(len(recs), 1)
        self.until_head('decoded', 1)
        rec = self.images()['recs'][0]
        self.assertEqual((rec['size'], rec['thumb']), ('40x20', '40x20'))
        self.command('print-frames')
        self.until(lambda: self.head()['copies'] >= 1 or None, 'the reply drew its picture')

    def test_a_remote_image_stays_blocked(self):
        self.start()
        self.chat('hello')
        self.command('agent-test-row agent ![x](https://example.com/a.png) and ![y](data:image/webp;base64,UklGRg==)')
        self.command('print-frames')
        self.command('wait 400')
        self.assertEqual(self.images()['recs'], [])

    def test_webp_is_a_chip_without_a_picture_and_is_sent(self):
        self.start()
        self.chat('hello')
        path = self.put('w.webp', WEBP)
        self.attach(path)
        self.assertEqual(self.images()['recs'], [])
        self.command('agent-prompt echoblocks')
        self.ready()
        self.assertEqual(self.blocks()[0]['source']['media_type'], 'image/webp')
        self.assertEqual(self.chips(self.last_user_row()), [f'i\tw.webp\t{path}'])

    def test_jpeg_and_gif_are_decoded(self):
        self.start()
        self.chat('hello')
        self.attach(IMAGES / 'baseline-420.jpg', IMAGES / 'interlaced-transparent.gif')
        self.until_head('decoded', 2)
        self.assertEqual([r['state'] for r in self.images()['recs']], ['ready', 'ready'])

    def test_sixteen_megapixels_is_the_cap(self):
        self.start()
        self.chat('hello')
        self.attach(self.put('four.png', flat_png(4000, 4000)))
        self.until_head('decoded', 1, seconds=20)
        self.assertEqual(self.images()['recs'][0]['thumb'], '96x96')
        self.attach(self.put('eight.png', flat_png(8000, 8000)))
        self.until_head('refused', 1)
        refused = self.images()['recs'][1]
        self.assertEqual((refused['size'], refused['thumb']), ('8000x8000', '0x0'))
        self.assertEqual(self.head()['decoded'], 1)
        self.command(f'agent-image-open {refused["id"]}')
        self.command('wait 50')
        self.assertEqual(self.toast(), 'toast=Too large to preview')
        self.assertNotIn('image=', self.command('print-state'))

    def test_not_an_image(self):
        self.start()
        self.chat('hello')
        bad = flat_png(10, 10)
        bad = bad[:40] + bytes(len(bad) - 52) + bad[-12:]      # a PNG's signature, its data damaged
        self.attach(self.put('bad.png', bad))
        self.until_head('failed', 1)
        self.command(f'agent-image-open {self.images()["recs"][0]["id"]} bad.png')
        self.command('wait 50')
        self.assertIn('image=error', self.command('print-state'))

    def test_source_bytes_are_capped(self):
        self.start()
        self.chat('hello')
        self.command('agent-images-hold 1')
        size = 3 << 20
        for batch in range(4):
            self.attach(*[self.put(f'{batch}-{i}.png', flat_png(8, 8, pad=size)) for i in range(3)])
            self.command('agent-prompt echoblocks')
            self.ready(60000)
        head = self.head()
        self.assertEqual(head['records'], 12)
        self.assertLessEqual(head['kept'], 32 << 20)
        oldest = self.images()['recs'][0]
        self.assertEqual(oldest['bytes'], '0')
        self.command(f'agent-image-open {oldest["id"]}')
        self.command('wait 50')
        self.assertEqual(self.toast(), 'toast=The picture is no longer in memory.')

    def test_the_cache_keeps_64(self):
        self.start()
        self.chat('hello')
        for batch in range(2):
            if batch:
                self.chat('again')                       # another conversation: the first batch out of view
                time.sleep(1.1)                          #   for longer than IMG_SHOWN_MS
            pics = ''.join(f'![p](data:image/png;base64,{base64.b64encode(flat_png(4, 4, grey=batch * 100 + i)).decode()}) '
                           for i in range(40))
            self.command(f'agent-test-row agent {pics}')
            self.command('print-frames')
            self.until_head('decoded', 40 * (batch + 1), seconds=20)
        head = self.head()
        self.assertEqual((head['decoded'], head['thumbs']), (80, 64), head)
        self.command('wait 500')
        self.assertEqual(self.head()['decoded'], 80)    # nothing decoded again: no churn

    def test_the_image_tab_is_in_no_session_file_and_not_reopened(self):
        self.start()
        self.chat('hello')
        self.attach(self.put('a.png', flat_png(30, 20)))
        rid = self.images()['recs'][0]['id']
        self.command(f'agent-image-open {rid} a.png')
        self.command('wait 50')
        self.until(lambda: 'a.png image=30x20' in self.command('print-state') or None, 'the tab')
        tabs = self.command('print-tabs')
        self.command('cmd close_tab')
        self.assertNotIn('a.png image=', self.command('print-state'))
        self.command('cmd reopen_closed_tab')
        self.assertNotIn('a.png image=', self.command('print-state'), tabs)
        self.command('cmd save')                         # nothing to save, nothing asked
        self.assertNotIn('dialog', self.command('print-state'))


class FitTest(ImagesCase):
    def test_thumbnails_fit(self):
        """The box's chips and a prompt row's at the panel's sizes and widths: every picture drawn, every chip
        of the box inside the panel."""
        for size in (8, 13, 32):
            for width in (240, 700):
                with self.subTest(size=size, width=width):
                    self.start(extra=f'[ui]\nagents_width = {width}\n[agents]\nfont_size = {size}\n')
                    self.chat('hello')
                    row = self.send_image(self.put('a.png', flat_png(300, 200)))
                    self.attach(self.put('b.png', flat_png(20, 90)), self.put('c.png', flat_png(90, 20)))
                    self.command('print-frames')
                    def drawn():                    # a chip scrolled out of the chips' rows is not drawn (nor decoded)
                        return [l for l in self.att()['parts'] if not re.search(r' at=0,0,0,0', l)]
                    self.command('wait 400')         # (at 32 in 240 px the box leaves its chips no room: none drawn)
                    self.until(lambda: all(' thumb=1' in l for l in drawn()) or None, (size, width, self.att()))
                    for line in drawn():
                        x, y, w, h = (int(v) for v in re.search(r' at=(-?\d+),(-?\d+),(\d+),(\d+)', line).groups())
                        self.assertGreaterEqual(x, 1280 - width - 1, line)
                        self.assertLessEqual(x + w, 1280, line)
                    self.until(lambda: ' thumb=1' in self.row_dump(row) or None, (size, width))
                    self.stop()


if __name__ == '__main__':
    unittest.main()
