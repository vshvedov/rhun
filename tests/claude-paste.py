#!/usr/bin/env python3
"""The clipboard's files and images, long pastes and files dropped on the window (phase 4, tasks 4 and 5),
against the fake CLI (tests/scripts/fake-claude.py) over the control socket. It imports tests/claude-attach.py
(and through it tests/claude-chat.py): every rhun gets its own HOME and XDG folders, an environment without
CLAUDE* or ANTHROPIC* variables, and a config whose [claude] section starts the fake. The desktop's clipboard
is never read or written: the headless platform's clipboard is set with clip-set, and drops are reported with
the drop command as a platform reports them. Nothing writes the user's own Claude Code settings."""
import importlib.util
import os
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location('claude_attach', ROOT / 'tests/claude-attach.py')
attach = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(attach)
chat = attach.chat
png = attach.png
PDF = attach.PDF

JPEG = b'\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xff\xd9'
CLIP_BIG = 'The image on the clipboard is larger than 10 MB · not attached'


def clip(text):
    """A text as clip-set text takes it: line feeds as \\n, backslashes doubled."""
    return text.replace('\\', '\\\\').replace('\n', '\\n')


class PasteCase(attach.AttachCase):
    def clip(self):
        """print-clip as a dict."""
        return dict(w.split('=', 1) for w in self.command('print-clip').split())

    def paste(self):
        self.command('cmd paste')

    def box_chat(self, prompt='hello'):
        """A conversation whose box has the keys."""
        self.start()
        self.chat(prompt)
        self.command('agent-focus box')

    def parts(self):
        return self.att()['parts']


class PasteTest(PasteCase):
    """The box of a driver with parts asks for files, an image and text; files win, then an image, then text
    (ar() WV@5822560)."""

    def test_pasted_files_become_chips(self):
        self.box_chat()
        a = self.put('a.txt', 'aye\n')
        b = self.put('b.png', png(2, 2))
        self.command(f'clip-set files {a}|{b}')
        self.paste()
        self.assertEqual(self.clip()['asked'], '7')
        self.assertEqual(self.clip()['kind'], '2')
        parts = self.parts()
        self.assertEqual(len(parts), 2, parts)
        self.assertIn(' text name=a.txt ', parts[0])
        self.assertIn(' image name=b.png ', parts[1])
        self.assertEqual(self.box(), '')

    def test_a_pasted_image_is_named_image_and_is_png(self):
        self.box_chat()
        data = png(3, 3)
        self.command(f'clip-set image {self.put("shot.png", data)}')
        self.paste()
        parts = self.parts()
        self.assertEqual(len(parts), 1, parts)
        self.assertIn(' image name=Image mime=image/png bytes=%d ' % len(data), parts[0])
        self.command('agent-prompt look')
        self.ready()
        block = self.blocks()[0]
        self.assertEqual((block['type'], block['source']['media_type']), ('image', 'image/png'))

    def test_a_pasted_jpeg_keeps_its_type(self):
        self.box_chat()
        self.command(f'clip-set image {self.put("x.bin", JPEG)}')
        self.paste()
        self.assertIn(' mime=image/jpeg ', self.parts()[0])

    def test_files_win_over_an_image_over_text(self):
        self.box_chat()
        f = self.put('f.txt', 'eff\n')
        self.command(f'clip-set files {f}')
        self.command(f'clip-set image {self.put("i.png", png())}')
        self.command('clip-set text some text')
        self.paste()
        self.assertEqual([p.split(' ')[1] for p in self.parts()], ['text'])
        self.command('agent-attach-remove 0')
        self.command('clip-set files ')
        self.paste()
        self.assertEqual([re.search(r'name=(\S+)', p).group(1) for p in self.parts()], ['Image'])
        self.assertEqual(self.box(), '')
        self.command('agent-attach-remove 0')
        self.command('clip-set image ')
        self.paste()
        self.assertEqual(self.parts(), [])
        self.assertEqual(self.box(), 'some text')

    def test_other_fields_get_text_as_before(self):
        # the editor asks for text alone: files and text on the clipboard give the text; an image alone nothing
        self.start()
        self.put('n.txt', 'one\n')
        self.command(f'open {self.project / "n.txt"}')
        self.command(f'clip-set files {self.project / "n.txt"}')
        self.command('clip-set text found')
        self.paste()
        self.assertEqual(self.clip()['asked'], '1')
        self.assertEqual(self.clip()['kind'], '1')
        self.assertIn('found', self.command('print-doc'))
        self.command('clip-set clear')
        self.command(f'clip-set image {self.put("i.png", png())}')
        doc = self.command('print-doc')
        self.paste()
        self.assertEqual(self.command('print-doc'), doc)
        self.assertEqual(self.live_packs(), (0, 0))

    def test_no_parts_no_files(self):
        # a driver without DRVC_PARTS (an extension's session): its box gets the text
        self.box_chat()
        self.command('agent-test-caps 0')
        f = self.put('f.txt', 'eff\n')
        self.command(f'clip-set files {f}')
        self.command('clip-set text plain words')
        self.paste()
        self.assertEqual(self.clip()['asked'], '1')
        self.command('agent-test-caps off')
        self.assertEqual(self.parts(), [])
        self.assertEqual(self.box(), 'plain words')

    def test_an_image_over_the_limit_is_not_read(self):
        self.box_chat()
        big = self.put('big.png', png(4, 4, pad=11 * 1024 * 1024))
        self.command(f'clip-set image {big}')
        self.paste()
        self.assertEqual(self.toast(), 'toast=' + CLIP_BIG)
        self.assertLessEqual(int(self.clip()['read']), 10 * 1024 * 1024 + 1)
        self.assertEqual(self.parts(), [])
        self.assertEqual(self.live_packs(), (0, 0))

    def test_an_unreadable_image_pastes_nothing(self):
        self.box_chat()
        self.command(f'clip-set image {self.put("not.png", b"this is not an image at all, not one byte of it")}')
        self.paste()
        self.assertEqual(self.parts(), [])
        self.assertEqual(self.box(), '')
        self.assertEqual(self.live_packs(), (0, 0))

    def test_a_paste_that_lost_its_box_is_dropped(self):
        self.box_chat()
        f = self.put('f.txt', 'eff\n')
        self.command(f'clip-set files {f}')
        self.command('clip-hold')
        self.paste()
        self.assertEqual(self.clip()['held'], '1')
        self.command('agent-new claude')               # another conversation's box meanwhile
        self.command('agent-focus box')
        self.command('clip-release')
        self.assertEqual(self.parts(), [])
        self.assertEqual(self.live_packs(), (0, 0))

    def test_a_pasted_fifo_path_is_refused_unread(self):
        self.box_chat()
        fifo = self.project / 'pipe'
        os.mkfifo(fifo)
        self.command(f'clip-set files {fifo}')
        self.paste()                                    # a FIFO opened would hang rhun: it is never opened
        self.assertEqual(self.toast(), 'toast=pipe is not a file · not attached')
        self.assertEqual(self.parts(), [])

    def test_hostile_file_lists(self):
        self.box_chat()
        folder = self.project / 'sub dir'
        folder.mkdir()
        loop = self.project / 'loop'
        os.symlink(loop, loop)
        odd = self.put('a\x1bb\tc.txt', 'odd\n')
        self.command(f'clip-set files {folder}|{loop}|{self.project / "gone.txt"}|{odd}|/dev/null')
        self.paste()
        parts = self.parts()
        self.assertEqual(len(parts), 1, parts)
        self.assertIn('name=a b c.txt', parts[0])       # control characters made spaces
        self.assertEqual(self.box(), '@"sub dir/" ')     # a folder: a mention
        many = self.work / 'many.txt'
        many.write_text(''.join(f'{self.project}/f{i}.txt\n' for i in range(10000)), encoding='utf-8')
        for i in range(10000):
            (self.project / f'f{i}.txt').write_text(f'{i}\n')
        self.command('agent-attach-remove 0')
        self.command(f'clip-set files @{many}')
        self.paste()
        self.assertEqual(len(self.parts()), 20)
        self.assertEqual(self.toast(), 'toast=A message takes 20 attachments · f9999.txt was not attached')


class LongPasteTest(PasteCase):
    """Long pastes (cqe WV@3707999, pqe): remembered while the box keeps them and sent beside the text as
    inline_pastes (finding 43); the row shows the paste as it was, live and read again."""

    LONG = '\n'.join(f'line {i} ' + 'x' * 120 for i in range(40))

    def test_a_long_paste_goes_beside_its_text(self):
        self.box_chat()
        self.command('agent-type Here is my log:')
        self.command('clip-set text ' + clip('\n' + self.LONG + '\n'))
        self.paste()
        self.assertEqual(self.command('print-agent-pastes').splitlines()[0], 'pastes=1')
        self.command('agent-type Reply with ok.')
        typed = self.box()
        self.command('key Return')
        self.ready()
        message = self.users()[-1]
        self.assertEqual(message['inline_pastes'], [self.LONG])        # trimmed, as the extension keeps it
        self.assertEqual(message['message']['content'][-1]['text'], typed)
        self.assertEqual(self.command('print-agent-pastes'), 'pastes=0\n')

    def test_a_short_paste_is_only_its_text(self):
        self.box_chat()
        self.command('clip-set text two\\nlines only')
        self.paste()
        self.assertEqual(self.command('print-agent-pastes'), 'pastes=0\n')
        self.command('key Return')
        self.ready()
        self.assertNotIn('inline_pastes', self.users()[-1])

    def test_a_paste_the_prompt_no_longer_holds_is_not_sent(self):
        self.box_chat()
        self.command('clip-set text ' + clip(self.LONG))
        self.paste()
        self.command('agent-prompt something else')     # the box's text replaced, then sent
        self.ready()
        self.assertNotIn('inline_pastes', self.users()[-1])

    def test_paste_over_the_limit_is_refused(self):
        self.box_chat()
        self.command('clip-set text ' + 'y' * 50003)
        self.paste()
        self.assertEqual(self.box(), '')
        notice = self.command('print-agent-bands')
        self.assertIn('That paste is 3 characters over the limit of 50000 · nothing was added, paste less of it',
                      notice)

    def test_the_rows_show_the_paste_not_the_tags(self):
        self.box_chat()
        self.command('agent-type Here is my log: ')
        self.command('clip-set text ' + clip(self.LONG))
        self.paste()
        self.command('agent-type  Reply.')
        self.command('key Return')
        self.ready()
        live = [r for r in self.thread() if r.startswith('user ')][-1]
        self.assertNotIn('pasted_content', live)
        self.command('agent-release')
        self.command('wait-agent off')
        self.until_gone()
        reread = [r for r in self.thread() if r.startswith('user ')][-1]
        self.assertNotIn('pasted_content', reread)
        self.assertEqual(reread, live)



class DropTest(PasteCase):
    """Files dropped on the window (task 5; UI 1.16, WV@5951058): the veil over a conversation of a driver
    with parts, the dropped files attached, what nobody takes opened, rhun's own drags of paths as mentions."""

    def veil(self):
        out = self.command('print-agent-veil')
        m = re.match(r'veil=(\d) area=(-?\d+),(-?\d+),(\d+),(\d+) lines=(\d+) wmax=(\d+)', out)
        return {'veil': int(m.group(1)), 'area': tuple(int(m.group(i)) for i in range(2, 6)),
                'lines': int(m.group(6)), 'wmax': int(m.group(7))}

    def middle(self):
        x, y, w, h = self.veil()['area']
        return x + w // 2, y + h // 2

    def drop(self):
        return dict(w.split('=', 1) for w in self.command('print-drop').split())

    def test_veil_while_files_are_over_the_conversation(self):
        self.box_chat()
        x, y = self.middle()
        self.assertEqual(self.veil()['veil'], 0)
        self.command(f'drop enter {x} {y}')
        self.assertEqual(self.drop()['over'], '1')
        self.assertEqual(self.veil()['veil'], 1)
        self.command(f'drop move 20 {y}')               # over the editor: no veil on the conversation
        self.assertEqual(self.veil()['veil'], 0)
        self.command(f'drop move {x} {y}')
        self.assertEqual(self.veil()['veil'], 1)

    def test_leave_takes_the_veil_away(self):
        self.box_chat()
        x, y = self.middle()
        self.command(f'drop enter {x} {y}')
        self.command('drop leave 0 0')
        self.assertEqual(self.drop()['over'], '0')
        self.assertEqual(self.veil()['veil'], 0)

    def test_drop_attaches(self):
        self.box_chat()
        x, y = self.middle()
        a = self.put('a.txt', 'aye\n')
        b = self.put('b.png', png(2, 2))
        self.command('agent-focus editor')
        self.command(f'drop enter {x} {y}')
        self.command(f'drop files {x} {y} {a}|{b}')
        parts = self.parts()
        self.assertEqual(len(parts), 2, parts)
        self.assertIn(' text name=a.txt ', parts[0])
        self.assertEqual(self.drop()['files'], 'none')
        self.assertEqual(self.veil()['veil'], 0)
        self.assertIn(' focus=1 ', self.command('print-agent-input'))     # the box has the keys
        self.assertEqual(self.command('print-state').count('tabs=0'), 1)   # nothing opened

    def test_a_dropped_folder_is_a_mention(self):
        self.box_chat()
        x, y = self.middle()
        (self.project / 'src').mkdir()
        self.command(f'drop files {x} {y} {self.project / "src"}')
        self.assertEqual(self.parts(), [])
        self.assertEqual(self.box(), '@src/ ')

    def test_drop_outside_the_chat_opens_the_files(self):
        self.box_chat()
        a = self.put('a.txt', 'aye\n')
        (self.project / 'dir').mkdir()
        self.command(f'drop files 400 300 {a}|{self.project / "dir"}')
        self.assertIn('active=a.txt', self.command('print-state'))
        self.assertEqual(self.parts(), [])
        self.assertEqual(self.drop()['opened'], '1')

    def test_drop_with_the_chat_off_or_no_parts_opens_the_files(self):
        self.box_chat()
        x, y = self.middle()
        self.command('agent-test-caps 0')
        a = self.put('a.txt', 'aye\n')
        self.command(f'drop enter {x} {y}')
        self.assertEqual(self.veil()['veil'], 0)
        self.command(f'drop files {x} {y} {a}')
        self.command('agent-test-caps off')
        self.assertEqual(self.parts(), [])
        self.assertIn('active=a.txt', self.command('print-state'))

    def test_drop_in_a_window_without_a_project(self):
        a = self.put('a.txt', 'aye\n')
        self.start(target='--empty')
        self.command(f'drop files 400 300 {a}')
        self.assertIn('active=a.txt', self.command('print-state'))

    def test_a_drop_of_ten_thousand_paths(self):
        self.box_chat()
        x, y = self.middle()
        many = self.work / 'many.txt'
        many.write_text(''.join(f'{self.project}/f{i}.txt\n' for i in range(10000)), encoding='utf-8')
        for i in range(30):
            self.put(f'f{i}.txt', f'{i}\n')
        self.command(f'drop files {x} {y} @{many}')
        self.assertEqual(len(self.parts()), 20)
        self.assertEqual(self.live_packs()[0], 1)
        self.assertEqual(self.drop()['files'], 'none')

    def test_a_dropped_fifo_is_refused_unread(self):
        self.box_chat()
        x, y = self.middle()
        fifo = self.project / 'pipe'
        os.mkfifo(fifo)
        self.command(f'drop files {x} {y} {fifo}')
        self.assertEqual(self.toast(), 'toast=pipe is not a file · not attached')
        self.assertEqual(self.parts(), [])

    def test_nothing_is_kept_after_the_frame(self):
        self.box_chat()
        a = self.put('a.txt', 'aye\n')
        self.command(f'drop files 400 300 {a}')
        self.assertEqual(self.drop()['files'], 'none')
        self.command('wait 50')
        self.assertEqual(self.drop()['files'], 'none')
        self.assertEqual(self.drop()['opened'], '1')

    def test_an_explorer_row_dragged_in_is_a_mention(self):
        self.put('a.txt', 'x\n')
        self.put('b c.txt', 'y\n')
        self.box_chat()
        self.command('cmd toggle_sidebar')
        x, y = self.middle()
        for row_y, want in ((94, '@a.txt '), (122, '@a.txt @"b c.txt" ')):
            self.command(f'move 60 {row_y}')
            self.command('down')
            self.command(f'move 70 {row_y + 3}')
            self.assertEqual(self.drop()['drag'], '1')
            self.command(f'move {x} {y}')
            self.assertEqual(self.veil()['veil'], 1)
            self.command('up')
            self.command('wait 20')
            self.assertEqual(self.box(), want)
            self.assertEqual(self.parts(), [])

    def test_a_click_on_a_row_still_opens_it(self):
        self.put('a.txt', 'x\n')
        self.box_chat()
        self.command('cmd toggle_sidebar')
        self.command('click 60 94')
        self.assertIn('active=a.txt', self.command('print-state'))
        self.assertEqual(self.drop()['drag'], '0')
        self.assertEqual(self.box(), '')

    def test_a_tab_dragged_in_is_a_mention(self):
        a = self.put('a.txt', 'x\n')
        self.box_chat()
        self.command(f'open {a}')
        tabs = self.command('print-tabs-at')
        m = re.search(r'(\d+),(\d+)', tabs)
        tx, ty = int(m.group(1)) + 10, int(m.group(2)) + 5
        x, y = self.middle()
        self.command(f'move {tx} {ty}')
        self.command('down')
        self.command(f'move {tx + 30} {ty}')
        self.command(f'move {x} {y}')
        self.command('up')
        self.command('wait 20')
        self.assertEqual(self.box(), '@a.txt ')

    def test_veil_fits_every_size_and_width(self):
        # its words wrap at 240 px (the panel's metrics) and never run past the area
        for size in (8, 13, 32):
            for width in (240, 380, 600):
                with self.subTest(size=size, width=width):
                    self.stop()
                    self.start(extra=f'[ui]\nagents_width = {width}\n[agents]\nfont_size = {size}\n')
                    self.chat('hello')
                    x, y = self.middle()
                    self.command(f'drop enter {x} {y}')
                    v = self.veil()
                    self.assertEqual(v['veil'], 1)
                    self.assertGreaterEqual(v['lines'], 1)
                    self.assertLessEqual(v['wmax'], v['area'][2])
                    self.assertLessEqual(v['lines'] * size, v['area'][3])

if __name__ == '__main__':
    unittest.main()
