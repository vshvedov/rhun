#!/usr/bin/env python3
"""A message's parts in the agents panel (phase 4, tasks 2 and 3): files attached to the box's message, what goes
to Claude Code as content blocks, who owns a pack and when it is freed, the types and limits, the chips above
the box and the "+" menu. Against the fake CLI (tests/scripts/fake-claude.py), over the control socket; it
imports tests/claude-chat.py for its cases: every rhun gets its own HOME and XDG folders, an environment without
CLAUDE* or ANTHROPIC* variables, and a config whose [claude] section starts the fake. Nothing here writes the
user's own Claude Code settings: the fake's config folder is the test's HOME."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import time
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location('claude_chat', ROOT / 'tests/claude-chat.py')
chat = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(chat)

NOT_SENT = 'toast=A queued message was not sent.'
UNSUPPORTED_TAIL = ('. Supported types: images (PNG, JPG, GIF, WebP), text files, and PDFs. To reference unsupported '
                    'files, please include its absolute file path in your prompt (using @ for paths inside your '
                    'working directory, and entering the path for files outside).')


def png(width=1, height=1, pad=0):
    """A real PNG of that size (grey), padded with a private ancillary chunk to about pad bytes."""
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    raw = b''.join(b'\0' + b'\x80' * width for _ in range(height))
    out = (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 0, 0, 0, 0))
           + chunk(b'IDAT', zlib.compress(raw)))
    if pad > len(out) + 24:
        out += chunk(b'prVt', os.urandom(pad - len(out) - 24))
    return out + chunk(b'IEND', b'')


PDF = b'%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n'


class AttachCase(chat.DrivenCase):
    """The box's pack (print-agent-attachments), the user messages the fake read, files in the project."""

    def put(self, name, data):
        path = self.project / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data if isinstance(data, bytes) else data.encode('utf-8'))
        return path

    def att(self):
        """print-agent-attachments: {'parts': [line...], 'head': {...}, 'tail': {...}}."""
        lines = self.command('print-agent-attachments').splitlines()
        head = dict(w.split('=', 1) for w in lines[0].split(' '))
        tail = dict(w.split('=', 1) for w in lines[-1].split(' '))
        return {'parts': lines[1:-1], 'head': {k: int(v) for k, v in head.items()},
                'tail': {k: int(v) for k, v in tail.items()}}

    def live_packs(self):
        tail = self.att()['tail']
        return tail['live'], tail['bytes']

    def users(self):
        return [m for m in self.stdin() if m.get('type') == 'user']

    def blocks(self):
        """The content of the last user message the fake read."""
        return self.users()[-1]['message']['content']

    def box(self):
        return re.match(r'input=(.*?) focus=', self.command('print-agent-input'), re.S).group(1)

    def toast(self):
        return self.command('print-toast').strip()

    def rows(self):
        return self.command('print-agent-rows').splitlines()

    def last_user_row(self):
        idx = [int(line.split(' ')[0]) for line in self.rows() if re.match(r'\d+ user ', line)]
        return idx[-1]

    def chips(self, which):
        return self.command(f'print-agent-row-chips {which}').rstrip('\n').split('\n')

    def ready(self, ms=20000):
        self.command(f'wait-agent ready {ms}')

    def attach(self, *paths):
        self.command('agent-attach ' + '|'.join(str(p) for p in paths))


class SeamTest(AttachCase):
    """What goes to Claude Code: the blocks of findings 38 to 41, in the extension's order."""

    def test_an_image_goes_as_base64(self):
        self.start()
        self.chat('hello')
        data = png(3, 2)
        path = self.put('a.png', data)
        self.attach(path)
        self.assertEqual(self.att()['head'], {'parts': 1, 'bytes': len(data)})
        self.command('agent-prompt echoblocks')
        self.ready()
        blocks = self.blocks()
        self.assertEqual(len(blocks), 2, blocks)
        self.assertEqual(blocks[0]['type'], 'image')
        self.assertEqual(blocks[0]['source']['type'], 'base64')
        self.assertEqual(blocks[0]['source']['media_type'], 'image/png')
        self.assertEqual(base64.b64decode(blocks[0]['source']['data']), data)
        self.assertEqual(blocks[1], {'type': 'text', 'text': 'echoblocks'})
        self.assertEqual(self.thread()[-1], f'agent image image/png {len(data)}')
        self.assertEqual(self.att()['head'], {'parts': 0, 'bytes': 0})

    def test_a_text_file_goes_as_a_document_with_its_name(self):
        self.start()
        self.chat('hello')
        text = 'The secret word is mango.\nwith "quotes" and \\ and é\n'
        path = self.put('notes.txt', text)
        self.attach(path)
        self.command('agent-prompt echoblocks')
        self.ready()
        self.assertEqual(self.blocks()[0], {'type': 'document', 'source': {
            'type': 'text', 'media_type': 'text/plain', 'data': text}, 'title': 'notes.txt'})

    def test_a_pdf_goes_as_a_base64_document(self):
        self.start()
        self.chat('hello')
        path = self.put('two.pdf', PDF)
        self.attach(path)
        self.command('agent-prompt echoblocks')
        self.ready()
        block = self.blocks()[0]
        self.assertEqual(block['type'], 'document')
        self.assertEqual(block['title'], 'two.pdf')
        self.assertEqual(block['source']['type'], 'base64')
        self.assertEqual(block['source']['media_type'], 'application/pdf')
        self.assertEqual(base64.b64decode(block['source']['data']), PDF)

    def test_blocks_in_the_extensions_order(self):
        # the files in the order they were attached, then the prompt's text (Tje WV@3691058)
        self.start()
        self.chat('hello')
        self.attach(self.put('b.txt', 'bee\n'), self.put('a.png', png()), self.put('c.pdf', PDF))
        self.command('agent-prompt echoblocks')
        self.ready()
        self.assertEqual([(b['type'], (b.get('source') or {}).get('media_type')) for b in self.blocks()],
                         [('document', 'text/plain'), ('image', 'image/png'), ('document', 'application/pdf'),
                          ('text', None)])

    def test_attachments_alone_send_no_text_block(self):
        self.start()
        self.chat('hello')
        self.attach(self.put('a.png', png()))
        self.command('agent-prompt   ')
        self.ready()
        self.assertEqual([b['type'] for b in self.blocks()], ['image'])

    def test_a_blank_box_with_a_chip_sends(self):
        self.start()
        self.chat('hello')
        self.command('agent-prompt   ')                 # nothing to send without a chip
        self.assertEqual(len(self.users()), 1)
        path = self.put('a.png', png())
        self.attach(path)
        self.command('agent-prompt ')
        self.ready()
        self.assertEqual(len(self.users()), 2)
        self.assertEqual(self.chips(self.last_user_row()), [f'i\ta.png\t{path}'])
        self.assertEqual(self.att()['head']['parts'], 0)

    def test_the_prompts_row_has_its_chips(self):
        # at once (READY), queued (waiting for the start), held (written during a turn): the row it becomes
        # has its chips whenever it is made, and a queued row shows them meanwhile
        self.start(env={'FAKE_CLAUDE_INIT_MS': '1500'})
        img = self.put('a.png', png())
        txt = self.put('n.txt', 'n\n')
        self.command('agent-new claude')
        self.attach(img)
        self.command('agent-prompt first')
        self.assertEqual(self.chips('q0'), [f'i\ta.png\t{img}'])
        self.ready()
        self.assertEqual(self.chips(self.last_user_row()), [f'i\ta.png\t{img}'])
        self.attach(txt)                                # at once
        self.command('agent-prompt second')
        self.ready()
        self.assertEqual(self.chips(self.last_user_row()), [f'd\tn.txt\t{txt}'])
        self.command('agent-prompt held')               # held
        self.command('wait-agent working 5000')
        self.attach(img, txt)
        self.command('agent-prompt third')
        self.assertEqual(self.chips('q0'), [f'i\ta.png\t{img}', f'd\tn.txt\t{txt}'])
        self.ready()
        rows = self.rows()
        index = [i for i, l in enumerate(rows) if l == '  text third']
        self.assertTrue(index, rows)
        number = int(rows[index[0] - 1].split(' ')[0])
        self.assertEqual(self.chips(number), [f'i\ta.png\t{img}', f'd\tn.txt\t{txt}'])
        self.assertEqual(self.live_packs(), (0, 0))

    def test_a_driver_without_parts_gets_none(self):
        # an extension's driver has no DRVC_PARTS; agent-test-caps tells the UI the same of Claude's
        self.start()
        self.chat('hello')
        self.command('agent-test-caps 0')
        out, ok = self.reply('agent-attach ' + str(self.put('a.png', png())))
        self.assertFalse(ok)
        self.assertEqual(out, 'this agent takes no attachments\n')
        self.command('agent-test-caps off')
        self.command('agent-prompt more')
        self.ready()
        self.assertEqual(self.blocks(), [{'type': 'text', 'text': 'more'}])
        self.assertEqual(self.live_packs(), (0, 0))

    def test_a_pack_is_encoded_once(self):
        self.start()
        self.chat('hello')
        data = png(64, 64, pad=200000)
        self.attach(self.put('a.png', data))
        for _ in range(30):
            self.command('print-frames')
            self.command('wait 5')
        self.assertEqual(self.att()['tail']['encoded'], 0)
        self.command('agent-prompt echoblocks')
        self.ready()
        self.assertEqual(self.att()['tail']['encoded'], len(base64.b64encode(data)))

    def test_a_message_too_large_is_refused_whole(self):
        self.start()
        self.chat('hello')
        path = self.put('big.txt', 'x' * 30000 + '\n')
        self.attach(path)
        self.command('agent-timing queue=20000')
        self.command('agent-prompt keep me')
        self.assertEqual(self.toast(), 'toast=This message is too large to send: remove an attachment.')
        self.assertEqual(self.box(), 'keep me')
        self.assertEqual(self.att()['head']['parts'], 1)
        self.assertEqual(len(self.users()), 1)
        self.command('agent-timing queue=%d' % (16 << 20))
        self.command('agent-prompt keep me')
        self.ready()
        self.assertEqual(self.blocks()[0]['title'], 'big.txt')

    def test_buffers_shrink_after_a_big_message(self):
        self.start()
        self.chat('hello')
        data = png(8, 8, pad=9 << 20)
        self.attach(self.put('big.png', data))
        self.command('agent-prompt echoblocks')
        self.ready(60000)
        self.assertEqual(self.thread()[-1], f'agent image image/png {len(data)}')
        self.command('wait 100')
        bufs = dict(w.split('=') for w in self.command('print-agent-bufs').split())
        self.assertLess(int(bufs['bufs']), 1 << 20, bufs)
        self.assertLessEqual(int(bufs['arena']), 1 << 20, bufs)


class PackLifeTest(AttachCase):
    """Who owns a pack, and that every path frees or gives back what it holds: each ends on live= and bytes=."""

    def test_refused_send_keeps_the_pack(self):
        self.start()
        self.chat('held', 'working')
        for n in range(1, 17):
            self.command(f'agent-prompt m{n}')
        path = self.put('a.txt', 'a\n')
        self.attach(path)
        self.command('agent-prompt m17')
        self.assertEqual(self.toast(), 'toast=Sixteen messages are already waiting.')
        self.assertEqual(self.box(), 'm17')
        self.assertEqual(self.att()['head'], {'parts': 1, 'bytes': 2})
        self.assertEqual(self.live_packs(), (1, 2))
        self.ready(30000)

    def test_a_sent_pack_is_gone(self):
        self.start()
        self.chat('hello')
        self.attach(self.put('a.txt', 'abc\n'))
        self.assertEqual(self.live_packs(), (1, 4))
        self.command('agent-prompt more')
        self.ready()
        self.assertEqual(self.live_packs(), (0, 0))

    def test_a_queued_pack_goes_at_ready(self):
        self.start(env={'FAKE_CLAUDE_INIT_MS': '1000'})
        self.command('agent-new claude')
        self.attach(self.put('a.txt', 'abc\n'))
        self.command('agent-prompt first')
        self.assertIn(' queued=1 ', self.live())
        self.assertEqual(self.live_packs(), (1, 4))
        self.ready()
        self.assertEqual(self.live_packs(), (0, 0))
        self.assertEqual(self.blocks()[0]['title'], 'a.txt')

    def test_a_queued_pack_comes_back_when_the_start_fails(self):
        self.seed()
        self.start(env={'FAKE_CLAUDE_RESUME': 'unknown'})
        self.open_listed()
        path = self.put('a.txt', 'abc\n')
        self.attach(path)
        self.command('agent-prompt hello')
        self.command('wait-agent failed')
        self.until_gone()
        self.assertEqual(self.box(), 'hello')
        self.assertEqual(self.att()['parts'][0].split(' ')[:3], ['0', 'text', 'name=a.txt'])
        self.assertEqual(self.live_packs(), (1, 4))

    def test_a_held_prompts_chips_come_back_when_it_is_dropped(self):
        # the CLI refuses the held message (FAKE_CLAUDE_REFUSE_HELD: lifecycle refused): its text and both chips,
        # the file read again from its path, the pasted image from the bytes it kept, are back in the box
        self.start(env={'FAKE_CLAUDE_REFUSE_HELD': '1'})
        self.chat('held', 'working')
        image = png(5, 5)
        self.put('img.bin', image)
        path = self.put('a.txt', 'abc\n')
        self.attach(path)
        self.command('agent-attach bytes:' + str(self.project / 'img.bin'))
        self.command('agent-prompt more')
        self.until(lambda: self.box() == 'more', 'the refused message back in the box')
        self.assertEqual(self.toast(), NOT_SENT)
        parts = self.att()['parts']
        self.assertEqual([p.split(' ')[1:4] for p in parts], [['text', 'name=a.txt', 'mime=text/plain'],
                                                              ['image', 'name=Image', 'mime=image/png']])
        self.assertEqual(self.live_packs(), (1, 4 + len(image)))
        self.ready()
        self.command('agent-prompt echoblocks')            # the image's bytes are the ones attached
        self.ready()
        self.assertEqual(base64.b64decode(self.blocks()[1]['source']['data']), image)

    def test_a_held_prompts_chips_come_back_when_the_process_dies(self):
        self.start()
        self.chat('exit 1500', 'working')
        path = self.put('a.txt', 'abc\n')
        self.attach(path)
        self.command('agent-prompt more')
        self.command('wait-agent failed 10000')
        self.assertEqual(self.box(), 'more')
        self.assertEqual(self.att()['head'], {'parts': 1, 'bytes': 4})
        self.assertEqual(self.live_packs(), (1, 4))

    def test_a_held_file_that_vanished_says_so(self):
        # held: slimmed to its path; the file deleted meanwhile; the process dies: the other chip is back
        self.start()
        self.chat('exit 2000', 'working')
        gone = self.put('gone.txt', 'gone\n')
        kept = self.put('kept.txt', 'kept\n')
        self.attach(gone, kept)
        self.command('agent-prompt more')
        gone.unlink()
        self.command('wait-agent failed 10000')
        self.assertEqual(self.box(), 'more')
        self.assertEqual([p.split(' ')[2] for p in self.att()['parts']], ['name=kept.txt'])
        self.assertEqual(self.live_packs(), (1, 5))

    def test_held_bytes_are_capped(self):
        # three held prompts with 4 MiB pasted images each: at most 10 MiB of pathless bytes are kept (the
        # oldest's image goes first); given back, the two kept come back, the oldest's cannot
        self.start()
        self.chat('exit 4000', 'working')
        self.put('img.bin', png(16, 16, pad=4 << 20))
        size = (self.project / 'img.bin').stat().st_size
        for word in ('one', 'two', 'three'):
            self.command('agent-attach bytes:' + str(self.project / 'img.bin'))
            self.command('agent-prompt ' + word)
        live, held = self.live_packs()
        self.assertEqual(live, 3)
        self.assertLessEqual(held, 10 << 20)
        self.assertEqual(held, 2 * size)
        self.command('wait-agent failed 10000')
        self.assertEqual(self.box(), 'one\n\ntwo\n\nthree')
        self.assertEqual([p.split(' ')[1] for p in self.att()['parts']], ['image', 'image'])
        self.assertEqual(self.live_packs(), (1, 2 * size))

    def test_a_started_held_prompt_frees_its_pack(self):
        self.start()
        self.chat('held', 'working')
        self.attach(self.put('a.txt', 'abc\n'))
        self.command('agent-prompt more')
        self.assertEqual(self.live_packs(), (1, 0))        # held: slimmed to its path
        self.ready()
        self.assertEqual(self.live_packs(), (0, 0))

    def other(self):
        """Another project: every conversation of this one goes."""
        other = self.work / 'other'
        other.mkdir(exist_ok=True)
        self.command('open ' + str(other))
        self.command('wait 200')

    def test_a_queued_pack_goes_with_its_conversation(self):
        self.start(env={'FAKE_CLAUDE_INIT_MS': '3000'})
        self.command('cmd focus_agents')
        self.command('agent-new claude')
        self.attach(self.put('a.txt', 'abc\n'))
        self.command('agent-prompt first')
        self.assertEqual(self.live_packs(), (1, 4))
        self.other()
        self.assertEqual(self.live_packs(), (0, 0))

    def test_each_conversation_has_its_own_pack(self):
        self.start()
        self.command('cmd focus_agents')
        self.chat('a')
        first = self.sid()
        self.attach(self.put('a.txt', 'a\n'))
        self.command(f'click {chat.BACK[0]} {chat.BACK[1]}')
        self.chat('b')
        self.attach(self.put('b.txt', 'bb\n'), self.put('c.txt', 'ccc\n'))
        self.command(f'click {chat.BACK[0]} {chat.BACK[1]}')
        self.command('agent-new claude')                # a draft with a chip of its own
        self.attach(self.put('d.txt', 'dddd\n'))
        self.assertEqual([p.split(' ')[2] for p in self.att()['parts']], ['name=d.txt'])
        self.assertEqual(self.live_packs(), (3, 2 + 3 + 4 + 5))
        self.command(f'click {chat.BACK[0]} {chat.BACK[1]}')
        rows = [line for line in self.command('print-agents').splitlines() if line.startswith('Claude')]
        for n in range(1, len(rows) + 1):
            self.command(f'print-agents {n}')
            if self.sid() == first:
                break
            self.command(f'click {chat.BACK[0]} {chat.BACK[1]}')
        self.assertEqual(self.sid(), first)
        self.assertEqual([p.split(' ')[2] for p in self.att()['parts']], ['name=a.txt'])
        self.assertEqual(self.live_packs(), (3, 14))

    def test_a_draft_keeps_its_pack_when_it_becomes_a_conversation(self):
        self.start()
        self.command('agent-new claude')
        self.attach(self.put('a.txt', 'abc\n'))
        self.command('agent-type x')                    # the draft becomes its conversation at the first key
        self.command('wait 50')
        self.assertEqual(self.att()['head']['parts'], 1)
        self.command('agent-prompt echoblocks')
        self.ready()
        self.assertEqual(self.blocks()[0]['title'], 'a.txt')
        self.assertEqual(self.live_packs(), (0, 0))

    def test_closing_everything_leaves_no_pack(self):
        # packs in a box, parked, queued and held, in two conversations: the project closed, none is left
        self.start()
        self.command('cmd focus_agents')
        self.chat('held', 'working')
        self.attach(self.put('a.txt', 'a\n'))
        self.command('agent-prompt more')               # held
        self.attach(self.put('b.txt', 'b\n'))           # in the box
        self.command(f'click {chat.BACK[0]} {chat.BACK[1]}')     # parked
        self.chat('two')
        self.attach(self.put('c.txt', 'c\n'))
        self.assertEqual(self.live_packs()[0], 3)
        self.other()
        self.assertEqual(self.live_packs(), (0, 0))


class TypesTest(AttachCase):
    """What a file is (its bytes, then its name), the limits and their words."""

    def kind(self, name, data):
        """The kind agent-attach gives the file, or the toast or band it gives instead."""
        path = self.put(name, data)
        self.command('print-toast')
        self.attach(path)
        parts = self.att()['parts']
        if parts:
            self.command('agent-attach-remove 0')
            return parts[0].split(' ')[1]
        return self.notice()

    def notice(self):
        bands = self.command('print-agent-bands')
        for line in bands.splitlines():
            if 'Unsupported' in line:
                return 'unsupported'
        toast = self.toast()
        return toast

    def test_types_by_content_and_name(self):
        self.start()
        self.chat('hello')
        table = [('a.dat', png(), 'image'), ('Makefile', 'all:\n', 'text'), ('LICENSE', 'MIT\n', 'text'),
                 ('x.unknownext', 'plain words\n', 'text'), ('pic.txt', png(), 'image'),
                 ('doc.bin', PDF, 'pdf'), ('w.webp', b'RIFF\x10\0\0\0WEBPVP8 ' + b'\0' * 8, 'image'),
                 ('j.jpg', b'\xff\xd8\xff\xe0' + b'\0' * 20, 'image'), ('g.gif', b'GIF89a' + b'\0' * 20, 'image')]
        for name, data, kind in table:
            self.assertEqual(self.kind(name, data), kind, name)
        for name, data in [('nul.unknownext', b'a\0b\n'), ('bad.unknownext', b'\xff\xfe x\n'),
                           ('archive.zip', b'PK\x03\x04' + b'\0' * 40), ('bad.txt', b'ok \xc3\x28 no\n')]:
            path = self.put(name, data)
            self.attach(path)
            self.assertEqual(self.att()['head']['parts'], 0, name)
            band = [l for l in self.command('print-agent-bands').splitlines() if 'Unsupported' in l]
            self.assertTrue(band and name in band[-1], (name, band))

    def test_unsupported_names_make_one_band(self):
        self.start()
        self.chat('hello')
        names = ['a.zip', 'b.zip', 'c.zip', 'd.zip', 'e.zip']
        for count, text in [(1, 'Unsupported file type: a.zip'),
                            (3, 'Unsupported file types: a.zip, b.zip, c.zip'),
                            (5, 'Unsupported file types: a.zip, b.zip, c.zip and 2 more')]:
            self.attach(*[self.put(n, b'PK\x03\x04\0\0') for n in names[:count]])
            band = [l for l in self.command('print-agent-bands').splitlines() if 'Unsupported' in l]
            self.assertTrue(band and band[-1].endswith(text + UNSUPPORTED_TAIL), band)

    def test_limits_and_their_answers(self):
        self.start()
        self.chat('hello')
        dot = ' · '
        big_text = self.put('big.txt', 'x' * (256 * 1024 + 1))
        self.attach(big_text)
        self.assertEqual(self.toast(), f'toast=big.txt is larger than 256 KB{dot}not attached')
        huge = self.put('huge.png', png(4, 4, pad=(10 << 20) + 10))
        self.attach(huge)
        self.assertEqual(self.toast(), f'toast=huge.png is larger than 10 MB{dot}not attached')
        self.assertEqual(self.att()['head']['parts'], 0)
        six = self.put('six.png', png(4, 4, pad=6 << 20))
        self.attach(six)
        self.attach(self.put('six2.png', png(4, 4, pad=6 << 20)))
        self.assertEqual(self.toast(), f'toast=These files are more than 10 MB together{dot}six2.png was not attached')
        self.command('agent-attach-remove 0')
        small = [self.put(f's{n}.txt', f'{n}\n') for n in range(21)]
        self.attach(*small)
        self.assertEqual(self.att()['head']['parts'], 20)
        self.assertEqual(self.toast(), f'toast=A message takes 20 attachments{dot}s20.txt was not attached')
        for _ in range(20):
            self.command('agent-attach-remove 0')
        self.attach(self.project / 'missing.txt')
        self.assertEqual(self.toast(), f'toast=missing.txt could not be read{dot}not attached')
        self.assertEqual(self.live_packs(), (0, 0))

    def test_an_empty_file_is_skipped(self):
        self.start()
        self.chat('hello')
        self.command('print-toast')
        self.attach(self.put('empty.txt', b''))
        self.assertEqual(self.att()['head']['parts'], 0)
        self.assertEqual(self.toast(), 'toast=')

    def test_a_folder_is_not_an_attachment(self):
        self.start()
        self.chat('hello')
        (self.project / 'src').mkdir()
        (self.project / 'my dir').mkdir()
        self.attach(self.project / 'src')
        self.assertEqual(self.att()['head']['parts'], 0)
        self.assertEqual(self.box(), '@src/ ')
        self.attach(str(self.project / 'my dir') + '/')
        self.assertEqual(self.box(), '@src/ @"my dir/" ')

    def test_not_a_file_and_too_big_are_refused_unread(self):
        self.start()
        self.chat('hello')
        dot = ' · '
        fifo = self.project / 'pipe'
        os.mkfifo(fifo)
        began = time.monotonic()
        self.attach(fifo)
        self.assertLess(time.monotonic() - began, 1.0)
        self.assertEqual(self.toast(), f'toast=pipe is not a file{dot}not attached')
        self.attach('/dev/zero')
        self.assertEqual(self.toast(), f'toast=zero is not a file{dot}not attached')
        sparse = self.project / 'sparse.bin'
        with open(sparse, 'wb') as f:
            f.truncate(10 << 30)
        before = self.rss()
        self.attach(sparse)
        self.assertEqual(self.toast(), f'toast=sparse.bin is larger than 10 MB{dot}not attached')
        self.assertLess(self.rss() - before, 4 << 20)
        sparse.unlink()
        grows = self.put('grows.txt', 'x' * 1000)
        self.command('agent-timing attach=400')
        self.client.sendall(('agent-attach ' + str(grows) + '\n').encode())
        time.sleep(0.15)
        with open(grows, 'a') as f:
            f.write('y' * (256 * 1024))
        while self.reader.readline() not in ('ok\n', 'error\n'):
            pass
        self.command('agent-timing attach=0')
        self.assertEqual(self.toast(), f'toast=grows.txt is larger than 256 KB{dot}not attached')
        self.assertEqual(self.live_packs(), (0, 0))

    def rss(self):
        out = subprocess.run(['/bin/ps', '-o', 'rss=', '-p', str(self.process.pid)], capture_output=True,
                             text=True).stdout.strip()
        return int(out) * 1024


class HostileTest(AttachCase):
    def test_names(self):
        # a name with TAB, ESC and DEL (a line feed cannot cross the control socket's line), and one of 255 bytes:
        # one chip line each, spaces for the controls
        self.start()
        self.chat('hello')
        odd = self.put('a\tb\x7fc\x1bd.txt', 'odd\n')
        long_name = 'n' * 249 + '\u00e9' + '.txt'    # 255 bytes: the longest a file system has
        long_path = self.put(long_name, 'long\n')
        self.attach(odd, long_path)
        parts = self.att()['parts']
        self.assertEqual(len(parts), 2)
        self.assertIn('name=a b c d.txt ', parts[0])
        name = re.search(r'name=(\S+) ', parts[1]).group(1)
        self.assertEqual(name, long_name)
        self.command('agent-prompt names')
        self.ready()
        chips = self.chips(self.last_user_row())
        self.assertEqual(len(chips), 2, chips)
        self.assertEqual(chips[0].split('\t')[:2], ['d', 'a b c d.txt'])
        self.assertEqual(self.blocks()[0]['title'], 'a b c d.txt')


def rect(text):
    return tuple(int(v) for v in text.split(','))


def overlap(a, b):
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    return not (ax + aw <= bx or bx + bw <= ax or ay + ah <= by or by + bh <= ay)


class ChipsTest(AttachCase):
    """The chips above the box (task 3): drawn from a layout made when the pack or the width changed, each with
    its x; the footer's "+" and its menu; Attach File; the command menu's two entries."""

    PARTS = 4096
    CONTEXT = 8192
    MENTIONS = 16384
    MODES = 64

    def chips_at(self):
        """Each chip's rect and its x's, as drawn last."""
        out = []
        for line in self.att()['parts']:
            at = rect(re.search(r' at=(\S+)', line).group(1))
            x = rect(re.search(r' x=(\S+)', line).group(1))
            out.append((at, x))
        return out

    def foot(self):
        first = self.command('print-agents-foot').splitlines()[0]
        head = first.split(' label=', 1)[0]
        return dict(word.split('=', 1) for word in head.split(' '))

    def three(self):
        return [self.put('a.png', png()), self.put('notes.txt', 'n\n'), self.put('two.pdf', PDF)]

    def test_chips_row_above_the_box(self):
        self.start()
        self.chat('hello')
        self.attach(*self.three())
        self.command('wait 50')
        chips = self.chips_at()
        self.assertEqual(len(chips), 3)
        add_y = int(self.foot()['add_at'].split(',')[1])
        for at, x in chips:
            self.assertGreater(at[2], 0)
            self.assertLess(at[1] + at[3], add_y - 30)           # above the box, which is above the footer
            self.assertGreaterEqual(x[0], at[0])                 # its x inside it, at least MI_16 square
            self.assertLessEqual(x[0] + x[2], at[0] + at[2])
            self.assertGreaterEqual(x[2], 16)
            self.assertGreaterEqual(x[3], 16)
        for i, (a, _) in enumerate(chips):
            for b, _ in chips[i + 1:]:
                self.assertFalse(overlap(a, b), chips)

    def test_remove_with_its_x(self):
        self.start()
        self.chat('hello')
        self.attach(*self.three())
        self.command('wait 50')
        _, x = self.chips_at()[1]
        self.command(f'click {x[0] + x[2] // 2} {x[1] + x[3] // 2}')
        self.command('wait 50')
        self.assertEqual([p.split(' ')[2] for p in self.att()['parts']], ['name=a.png', 'name=two.pdf'])

    def test_a_removed_chip_is_not_sent(self):
        self.start()
        self.chat('hello')
        self.attach(*self.three())
        self.command('wait 50')
        _, x = self.chips_at()[0]
        self.command(f'click {x[0] + x[2] // 2} {x[1] + x[3] // 2}')
        self.command('agent-prompt echoblocks')
        self.ready()
        self.assertEqual([b.get('title') for b in self.blocks()], ['notes.txt', 'two.pdf', None])
        sent = [r['stdin'] for r in self.records() if 'stdin' in r]
        self.assertFalse(any('image/png' in line for line in sent))

    def test_twenty_chips_at_240_keep_the_box_and_footer(self):
        self.start(extra='[ui]\nagents_width = 240\n')
        self.chat('hello')
        self.attach(*[self.put(f'file-number-{n}.txt', f'{n}\n') for n in range(20)])
        self.command('wait 50')
        chips = self.chips_at()
        self.assertEqual(len(chips), 20)
        shown = [c for c in chips if c[0][2] > 0]
        self.assertLess(len(shown), 20)                          # three rows show, the rest scroll
        foot = self.foot()
        self.assertNotEqual(foot['add_at'], '0,0')
        self.assertNotEqual(foot['menu_at'], '0,0')
        top = min(c[0][1] for c in shown)
        before = [c[0] for c in chips]
        self.command(f'move {shown[0][0][0] + 5} {top + 5}')
        self.command('scroll 3')
        self.command('wait 50')
        after = [c[0] for c in self.chips_at()]
        self.assertNotEqual(before, after)                       # the wheel over them shows others
        self.assertNotEqual(self.foot()['add_at'], '0,0')

    def test_chips_are_measured_on_change_only(self):
        self.start()
        self.chat('hello')
        self.attach(*self.three())
        self.command('wait 50')
        before = self.att()['tail']['measures']
        for _ in range(30):
            self.command('print-frames')
            self.command('wait 5')
        self.command('agent-type typing does not measure the chips')
        self.command('wait 50')
        self.assertEqual(self.att()['tail']['measures'], before)
        self.command('agent-attach-remove 0')
        self.command('wait 50')
        self.assertEqual(self.att()['tail']['measures'], before + 1)

    def test_chips_fit_every_size_and_width(self):
        self.start()
        self.chat('hello')
        lines = self.command('print-agent-attachments-fit').splitlines()
        self.assertEqual(len(lines), 25 * 34 * 3)
        for line in lines:
            head = dict(w.split('=') for w in line.split(' c=')[0].split())
            w, n, mi16 = int(head['w']), int(head['n']), int(head['mi16'])
            chips = [tuple(int(v) for v in c.split(',')) for c in line.split(' c=')[1:]]
            self.assertEqual(len(chips), n, line)
            boxes = []
            for cx, cy, cw, ch, xx, xy in chips:
                self.assertGreaterEqual(cx, 0, line)
                self.assertLessEqual(cx + cw, w, line)
                self.assertGreaterEqual(xx, cx, line)            # its x inside it, MI_16 square
                self.assertLessEqual(xx + mi16, cx + cw, line)
                self.assertGreaterEqual(xy, cy, line)
                self.assertLessEqual(xy + mi16, cy + ch, line)
                boxes.append((cx, cy, cw, ch))
            for i, a in enumerate(boxes):
                for b in boxes[i + 1:]:
                    self.assertFalse(overlap(a, b), line)
            self.assertGreater(int(head['h']), 0, line)

    def test_chips_follow_the_conversation(self):
        self.start()
        self.command('cmd focus_agents')
        self.chat('a')
        first = self.sid()
        self.attach(self.put('a.txt', 'a\n'))
        self.command(f'click {chat.BACK[0]} {chat.BACK[1]}')
        self.chat('b')
        self.command('wait 50')
        self.assertEqual(self.att()['parts'], [])
        self.attach(self.put('b.txt', 'b\n'))
        self.command(f'click {chat.BACK[0]} {chat.BACK[1]}')
        rows = [line for line in self.command('print-agents').splitlines() if line.startswith('Claude')]
        for n in range(1, len(rows) + 1):
            self.command(f'print-agents {n}')
            if self.sid() == first:
                break
            self.command(f'click {chat.BACK[0]} {chat.BACK[1]}')
        self.command('wait 50')
        parts = self.att()['parts']
        self.assertEqual([p.split(' ')[2] for p in parts], ['name=a.txt'])
        self.assertGreater(self.chips_at()[0][0][2], 0)          # drawn in this conversation's box

    def test_plus_and_its_menu(self):
        self.start()
        self.chat('hello')
        add = rect(self.foot()['add_at'])
        self.command(f'click {add[0]} {add[1]}')
        self.assertEqual(self.command('print-menu').splitlines(), ['Upload from computer', 'Add context'])
        self.command('menu-pick Add context')
        self.assertEqual(self.box(), '@')
        self.assertIn('focus=1', self.command('print-agent-input'))
        self.command(f'agent-test-caps {self.PARTS | self.MODES}')      # without mentions: Upload only
        self.command('wait 50')
        add = rect(self.foot()['add_at'])
        self.command(f'click {add[0]} {add[1]}')
        self.assertEqual(self.command('print-menu').splitlines(), ['Upload from computer'])

    def test_no_plus_without_the_capability(self):
        self.start()
        self.chat('hello')
        self.command(f'agent-test-caps {self.MODES}')
        self.command('wait 50')
        self.assertEqual(self.foot()['add_at'], '0,0')
        lines = self.command('print-agents-foot').splitlines()[1:]
        self.assertTrue(all(' add_w=0 ' in line for line in lines))

    def test_upload_opens_the_browser_in_the_checkout(self):
        self.start()
        self.chat('hello')
        self.put('inside.txt', 'i\n')
        add = rect(self.foot()['add_at'])
        self.command(f'click {add[0]} {add[1]}')
        self.command('menu-pick Upload from computer')
        self.command('wait 50')
        palette = self.command('print-palette').splitlines()
        self.assertEqual(palette[0], 'field=~/project/')        # the conversation's checkout (HOME is the test's)
        self.assertTrue(any(line.strip(' >') == 'inside.txt' for line in palette[1:]), palette)

    def test_enter_attaches_and_closes_shift_enter_stays(self):
        self.start()
        self.chat('hello')
        self.put('alpha.txt', 'a\n')
        self.put('beta.txt', 'b\n')
        self.command('agent-menu')
        self.command('agent-type Attach file')
        self.command('key Return')
        self.assertNotEqual(self.command('print-palette').splitlines()[0], 'none')
        self.command('type alpha')
        self.command('key shift+Return')
        self.assertEqual([p.split(' ')[2] for p in self.att()['parts']], ['name=alpha.txt'])
        self.assertNotEqual(self.command('print-palette').splitlines()[0], 'none')     # it stays
        for _ in range(5):
            self.command('key BackSpace')
        self.command('type beta')
        self.command('key Return')
        self.assertEqual([p.split(' ')[2] for p in self.att()['parts']], ['name=alpha.txt', 'name=beta.txt'])
        self.assertTrue(self.command('print-palette').startswith('none'))             # it closed

    def test_command_menu_has_attach_and_mention(self):
        self.start()
        self.chat('hello')
        self.command('agent-menu')
        lines = self.command('print-agent-menu').splitlines()
        rows = [l.split(' ', 2)[2].split('\t')[:2] for l in lines if l.startswith('row ')]
        self.assertEqual(rows[:3], [['Attach file…', 'Upload a file to include in conversation'],
                                    ['Mention file from this project…', 'Reference a project file with @mention'],
                                    ['Clear conversation', 'Start a new conversation']])
        section = [l for l in lines if l.startswith('section ')][0]
        self.assertEqual(section, 'section Context')
        self.command('agent-type Mention')
        self.command('key Return')
        self.assertEqual(self.box(), '@')

    def test_a_slash_command_keeps_the_chips(self):
        self.start()
        self.chat('hello')
        self.attach(self.put('a.txt', 'a\n'))
        self.command('agent-prompt /model')
        self.command('wait 50')
        self.assertEqual(self.att()['head']['parts'], 1)
        self.assertEqual(len(self.users()), 1)

    def test_footer_fit_with_the_plus(self):
        self.start()
        self.chat('hello')
        lines = self.command('print-agents-foot').splitlines()[1:]
        self.assertEqual(len(lines), 25 * 34)
        for line in lines:
            numbers = {k: int(v) for k, v in (f.split('=') for f in line.split(' label=')[0].split())}
            rects = {name: (numbers[name + '_x'], numbers[name + '_y'], numbers[name + '_w'], numbers[name + '_h'])
                     for name in ('add', 'mode', 'menu', 'pill', 'send') if numbers[name + '_w'] > 0}
            self.assertIn('add', rects, line)
            for name, (x, y, w, h) in rects.items():
                self.assertGreaterEqual(x, 0, line)
                self.assertLessEqual(x + w, numbers['w'], line)
            names = list(rects)
            for i, a in enumerate(names):
                for b in names[i + 1:]:
                    self.assertFalse(overlap(rects[a], rects[b]), f'{a} and {b}: {line}')

    def test_a_footer_without_modes(self):
        self.start()
        self.chat('hello')
        self.command(f'agent-test-caps {self.PARTS | self.CONTEXT}')
        self.command('wait 50')
        foot = self.foot()
        self.assertNotEqual(foot['add_at'], '0,0')
        lines = self.command('print-agents-foot').splitlines()[1:]
        for line in lines:
            self.assertIn(' mode_w=0 ', line)
            self.assertIn(' pill_w=0 ', line)
            self.assertNotIn(' add_w=0 ', line)
        self.command('agent-test-caps 0')                    # neither: no footer, as an extension's session
        self.command('wait 50')
        lines = self.command('print-agents-foot').splitlines()[1:]
        self.assertTrue(all(' add_w=0 ' in line and ' menu_w=0 ' in line for line in lines), lines[0])


if __name__ == '__main__':
    unittest.main()
