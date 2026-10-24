#!/usr/bin/env python3
"""Doc views (feature view-doc), driven headlessly with the viewfake extension: Markdown rendered in
a view, keyboard scrolling, Tab between links and Enter following them (a file under the base, a
"#slug" heading, a link event for the rest), following the editor's top line, and the ops rhun
refuses."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from viewsharness import ViewsBase  # noqa: E402

DOC = 4                 # the doc view's number: todo 1, items 2, logs 3


class Docs(ViewsBase):
    def setUp(self):
        super().setUp()
        self.env['VIEWFAKE_DOC'] = '1'
        (self.proj / 'docs').mkdir()
        (self.proj / 'docs/guide one.md').write_text('# Guide\n', encoding='utf-8')

    def shown(self, *actions):
        return self.run_editor(['view-show readme', 'wait 300', *actions, 'wait 50', 'print-docview readme'])

    def head(self, out):
        line = [l for l in out if l.startswith('doc scroll=')][-1]
        return dict(kv.split('=') for kv in line[4:].split(' '))

    def test_the_document_renders_in_the_view(self):
        out = self.shown()
        head = self.head(out)
        self.assertEqual(head['scroll'], '0')
        self.assertEqual(head['focus'], '-')
        self.assertGreater(int(head['height']), 600)
        self.assertTrue(any(l.startswith('block 0 type=head level=1') for l in out), out)
        self.assertTrue(any(l.startswith('base /') for l in out))
        self.assertIn(f'0 view {DOC} open doc side readme', self.fake_log())

    def test_keys_scroll(self):
        out = self.shown('view-focus readme', 'key Down', 'key Down', 'key Next')
        s1 = int(self.head(out)['scroll'])
        self.assertGreater(s1, 40)
        out = self.shown('view-focus readme', 'key End', 'wait 50', 'print-docview readme', 'key Home')
        heads = [self.head([l]) for l in out if l.startswith('doc scroll=')]
        self.assertGreaterEqual(int(heads[0]['scroll']), s1)
        self.assertEqual(heads[1]['scroll'], '0')

    def test_tab_and_enter_follow_links(self):
        # link 0: a file under the base opens in a tab
        out = self.shown('view-focus readme', 'key Tab', 'key Return', 'wait 100', 'print-tabs')
        self.assertEqual(self.head(out)['focus'], '0')
        self.assertIn('guide one.md', [l for l in out if l.startswith('tabs=')][0])
        # link 1: "#second-part" scrolls to its heading
        out = self.shown('view-focus readme', 'key Tab', 'key Tab', 'key Return')
        head = self.head(out)
        self.assertEqual(head['focus'], '1')
        self.assertGreater(int(head['scroll']), 300)
        # links 2 and 3: a scheme rhun does not follow, a missing file: link events
        self.shown('view-focus readme', 'key Tab', 'key Tab', 'key Tab', 'key Return', 'key Tab', 'key Return',
                   'wait 100')
        log = self.fake_log()
        links = [(l, log[i + 1]) for i, l in enumerate(log) if l.startswith(f'0 view {DOC} link ')]
        self.assertEqual([b for _, b in links], ['custom:thing', 'nothing.md'])
        self.assertTrue(links[0][0].endswith(' 12'), links)

    def test_shift_tab_goes_back_and_wraps(self):
        out = self.shown('view-focus readme', 'key shift+Tab')
        self.assertEqual(self.head(out)['focus'], '3')

    def test_following_the_editor(self):
        text = ''.join(f'## Section {i}\n\nText of section {i}.\n\n' for i in range(60))
        (self.proj / 'long.md').write_text(text, encoding='utf-8')
        out = self.shown(f'open {self.proj / "long.md"}', 'wait 200', 'cmd viewfake.docfollow', 'wait 300',
                         'print-docview readme', 'key ctrl+End', 'wait 100')
        heads = [self.head([l]) for l in out if l.startswith('doc scroll=')]
        self.assertNotEqual(heads[0]['follow'], '0')
        self.assertEqual(heads[0]['scroll'], '0')
        self.assertGreater(int(heads[1]['scroll']), 1000)

    def test_an_image_by_handle(self):
        self.env['VIEWFAKE_PIC'] = 'nokeys'                             # views, view-images
        out = self.shown('cmd viewfake.docimg', 'wait 400')
        imgs = [l for l in out if l.startswith('item image ')]
        self.assertEqual(len(imgs), 1, out)
        self.assertIn(' w=30 h=10 ', imgs[0])

    def item(self, out, text):
        line = [l for l in out if l.startswith('item text ') and l.endswith(' text=' + text)][0]
        f = dict(kv.split('=', 1) for kv in line.split(' ')[2:] if '=' in kv)
        return int(f['x']), int(f['y']), int(f['w']), int(f['h'])

    def test_dragging_selects_and_copy_takes_the_text(self):
        (self.proj / 'note.txt').write_text('', encoding='utf-8')
        out = self.shown()
        head = [l for l in out if l.startswith('doc scroll=')][0]
        ox, oy = map(int, head.split(' at=')[1].split(' ')[0].split(','))
        x0, y0, w0, h0 = self.item(out, 'Some')
        x1, y1, w1, h1 = self.item(out, 'with')
        out = self.shown(f'move {ox + x0 + 1} {oy + y0 + h0 // 2}', 'down',
                         f'move {ox + x1 + w1 + 2} {oy + y1 + h1 // 2}', 'up', 'wait 50', 'key ctrl+c',
                         f'open {self.proj / "note.txt"}', 'key ctrl+v', 'wait 100', 'print-doc')
        self.assertIn('Some text with', out)
        # Ctrl+A in the view selects it all
        out = self.shown('view-focus readme', 'key ctrl+a', 'key ctrl+c', f'open {self.proj / "note.txt"}',
                         'key ctrl+v', 'wait 100', 'print-doc')
        self.assertTrue(any('The end.' in l for l in out), out)
        self.assertTrue(any(l.startswith('Readme') or 'Readme' in l for l in out))

    def test_copy_button_copies_code_without_fences_or_a_final_newline(self):
        (self.proj / 'paste.txt').write_text('')
        out = self.shown('cmd viewfake.doccopy', 'wait 100')
        head = self.head(out)
        ox, oy = map(int, head['at'].split(','))
        copy = next(line for line in out if line.startswith('item copy '))
        fields = dict(kv.split('=', 1) for kv in copy.split()[2:] if '=' in kv)
        x = ox + int(fields['x']) + int(fields['w']) // 2
        y = oy + int(fields['y']) + int(fields['h']) // 2
        out = self.run_editor(['view-show readme', 'wait 200', 'cmd viewfake.doccopy', 'wait 100',
                               f'click {x} {y}', f'open {self.proj / "paste.txt"}', 'key ctrl+v',
                               'echo pasted', 'print-doc'])
        pasted = '\n'.join(out[out.index('pasted') + 1:out.index('<eod>')])
        self.assertEqual(pasted, '# install tools\nprintf "café"\n\techo done')
        self.assertFalse(any(' link ' in line and line.startswith('0 view ') for line in self.fake_log()))

    def test_copy_buttons_are_keyboard_accessible_and_keep_their_own_code(self):
        (self.proj / 'paste.txt').write_text('')
        out = self.shown('cmd viewfake.doccopy', 'wait 100', 'view-focus readme',
                         'key Tab', 'key Tab', 'key Return', f'open {self.proj / "paste.txt"}',
                         'key ctrl+v', 'echo pasted', 'print-doc')
        pasted = '\n'.join(out[out.index('pasted') + 1:out.index('<eod>')])
        self.assertEqual(pasted, 'echo second')

    def test_ops_rhun_refuses(self):
        self.shown('cmd viewfake.docbad', 'cmd viewfake.docbig', 'cmd viewfake.doctree', 'wait 400')
        errs = [l for l in self.fake_log() if l.startswith('error ')]
        self.assertTrue(any(l.endswith(' syntax op 1') for l in errs), errs)
        self.assertTrue(any(l.endswith(' toobig doc') for l in errs), errs)
        self.assertTrue(any(' noview ' in l for l in errs), errs)

    def test_without_the_feature_it_is_not_supported(self):
        del self.env['VIEWFAKE_DOC']
        out = self.run_editor(['view-show readme', 'wait 300', 'print-views'])
        self.assertFalse(any(' kind=doc ' in l for l in out), out)


    def long_md(self):
        text = ''.join(f'## Section {i}\n\nText of section {i}.\n\n' for i in range(60))
        (self.proj / 'long.md').write_text(text, encoding='utf-8')
        (self.proj / 'other.txt').write_text('one\ntwo\nthree\n' * 20, encoding='utf-8')

    def test_a_double_click_moves_only_the_followed_document(self):
        self.long_md()
        out = self.shown(f'open {self.proj / "long.md"}', 'wait 200', 'cmd viewfake.docfollow', 'wait 300')
        head = [l for l in out if l.startswith('doc scroll=')][-1]
        ox, oy = map(int, head.split(' at=')[1].split(' ')[0].split(','))
        out = self.shown(f'open {self.proj / "long.md"}', 'wait 200', 'cmd viewfake.docfollow', 'wait 300',
                         f'open {self.proj / "other.txt"}', 'wait 200', f'click {ox + 20} {oy + 200}',
                         f'click {ox + 20} {oy + 200}', 'wait 200', 'print-state')
        state = [l for l in out if l.startswith('tabs=')][-1]
        self.assertIn(' active=other.txt line=1 ', state)

if __name__ == '__main__':
    unittest.main()
