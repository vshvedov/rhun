#!/usr/bin/env python3
"""Markdown documents (markdown.s): blocks, inline styles, links and the layout, through the
headless print-md WIDTH PATH (md_dump's lines)."""
import os
from pathlib import Path
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from viewsharness import ViewsBase  # noqa: E402

SAMPLE = """# Heading one

Some *emphasis*, **strong**, ~~struck~~ and `code` with a [link](https://example.com "title")
and a bare https://rhun.app/docs. Escaped \\*stars\\* and &amp; &lt;tag&gt; &#x2192;.
A hard break here
then the next line.

## Lists

- first item
- second with **bold**
  - nested one
  - nested two
- [ ] a task
- [x] a done task

1. one
2. two

> A quote with a [ref link][r1].
> > nested quote

---

```rust
fn main() {
    let x = "string";
}
```

| Name | Size | Kind |
|:-----|-----:|:----:|
| main.rs | 120 | file |
| `lib` | 3 | dir |

Setext heading
--------------

<!-- hidden comment -->
[r1]: https://example.org/ref
Final <https://auto.link> paragraph.
"""


class Markdown(ViewsBase):
    def dump(self, text, width=500):
        path = self.work / 'doc.md'
        path.write_text(text, encoding='utf-8')
        return self.run_editor([f'print-md {width} {path}'], exts=None, start=False)

    def blocks(self, out):
        return [l.split(' ', 2)[2] for l in out if l.startswith('block ')]

    def texts(self, out):
        return [l for l in out if l.startswith('item text ')]

    def field(self, line, name):
        return line.split(f' {name}=')[1].split(' ')[0]

    def test_blocks_and_their_context(self):
        b = self.blocks(self.dump(SAMPLE))
        kinds = [x.split(' ')[0] for x in b]
        self.assertEqual(kinds, ['type=head', 'type=para', 'type=head'] + ['type=para'] * 10 +
                         ['type=rule', 'type=code', 'type=row', 'type=row', 'type=row', 'type=head', 'type=para'])
        self.assertIn('level=1', b[0])
        self.assertTrue(b[3].startswith('type=para level=0 quote=0 list=1 marker=1'), b[3])
        self.assertTrue(b[5].startswith('type=para level=0 quote=0 list=2 marker=1'), b[5])     # nested
        self.assertIn('marker=3', b[7])                                     # a task
        self.assertIn('marker=4', b[8])                                     # a done task
        self.assertIn('marker=2 num=1', b[9])
        self.assertIn('marker=2 num=2', b[10])
        self.assertIn('quote=1', b[11])
        self.assertIn('quote=2', b[12])
        self.assertIn('level=2', b[18])                                     # setext ---

    def test_inline_styles(self):
        t = self.texts(self.dump(SAMPLE))
        by = {}
        for l in t:
            by.setdefault(self_text(l), l)                                  # the first of each
        self.assertEqual(self.field(by['emphasis'], 'style'), '2')
        self.assertEqual(self.field(by['strong'], 'style'), '1')
        self.assertEqual(self.field(by['struck'], 'style'), '8')
        self.assertEqual(self.field(by['code'], 'style'), '4')
        self.assertEqual(self.field(by['code'], 'face'), '4')
        self.assertEqual(self.field(by['link'], 'style'), '16')
        self.assertEqual(self.field(by['link'], 'link'), '0')
        self.assertIn('*stars*', by)                                        # escapes
        self.assertIn('&', by)
        self.assertIn('<tag>', by)
        self.assertIn('→.', by)                                        # &#x2192;
        self.assertEqual(self.field(by['https://rhun.app/docs'], 'link'), '1')
        self.assertEqual(self.field(by['ref'], 'link'), '2')                # defined after its use
        self.assertEqual(self.field(by['https://auto.link'], 'link'), '4')
        self.assertNotEqual(self.field(by['here'], 'y'), self.field(by['then'], 'y'))   # a hard break

    def test_links(self):
        out = self.dump(SAMPLE)
        links = [l for l in out if l.startswith('link ')]
        self.assertEqual(links, ['link 0 https://example.com', 'link 1 https://rhun.app/docs',
                                 'link 2 https://example.org/ref', 'link 4 https://auto.link'])
        self.assertIn('copy-action 3', out)

    def test_code_is_colored_by_its_grammar(self):
        t = self.texts(self.dump(SAMPLE))
        fn = [l for l in t if self_text(l) == 'fn'][0]
        self.assertEqual(self.field(fn, 'face'), '4')
        self.assertNotEqual(self.field(fn, 'color'), '1')                   # a syntax color, not fg

    def test_wrapping_follows_the_width(self):
        text = 'word ' * 60
        wide = self.dump(text, 800)
        narrow = self.dump(text, 200)
        hw = int(wide[0].split(' height=')[1].split(' ')[0])
        hn = int(narrow[0].split(' height=')[1].split(' ')[0])
        self.assertGreater(hn, hw)
        self.assertLessEqual(int(narrow[0].split(' maxw=')[1]), 200)

    def test_a_word_wider_than_the_line_is_cut(self):
        out = self.dump('x' * 300, 100)
        t = self.texts(out)
        self.assertGreater(len(t), 1)
        self.assertTrue(all(int(self.field(l, 'w')) <= 100 for l in t))

    def test_emphasis_needs_a_closer_and_underscores_inside_words_stay(self):
        t = self.texts(self.dump('a *lone star and snake_case_name and **unclosed\n'))
        self.assertEqual([self_text(l) for l in t], ['a', '*lone', 'star', 'and', 'snake_case_name', 'and',
                                                    '**unclosed'])
        self.assertTrue(all(self.field(l, 'style') == '0' for l in t))

    def body(self, md, base=None):
        b = md.encode()
        out = b'doc %d\n' % len(b) + b
        if base is not None:
            bb = str(base).encode()
            out = b'base %d\n' % len(bb) + bb + b'\n' + out
        path = self.work / 'doc.body'
        path.write_bytes(out)
        return path

    def test_a_rich_document_body(self):
        path = self.body('# Title\n\ntext\n', '/some/folder/')
        out = self.run_editor([f'print-md-body 400 {path}'], exts=None, start=False)
        self.assertIn('base /some/folder', out)
        self.assertEqual([x.split(' ')[0] for x in self.blocks(out)], ['type=head', 'type=para'])
        counted = self.work / 'counted.body'                            # a patch body's count line
        counted.write_bytes(b'2\n' + path.read_bytes())
        out = self.run_editor([f'print-md-body 400 {counted}'], exts=None, start=False)
        self.assertIn('base /some/folder', out)
        bad = self.work / 'bad.body'
        for text in (b'base 1\n/', b'doc 99\nshort', b'doc 1\nadoc 1\nb', b'other 1\nx'):
            bad.write_bytes(text)
            out = self.run_editor([f'print-md-body 400 {bad}'], exts=None, start=False)
            self.assertIn('none', out, text)

    def test_images_from_files_under_the_base(self):
        import struct, zlib

        def png(w, h, rgba):
            def chunk(kind, data):
                c = kind + data
                return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
            raw = b''.join(b'\0' + bytes(rgba) * w for _ in range(h))
            return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) +
                    chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))
        (self.work / 'pics').mkdir()
        (self.work / 'pics/red.png').write_bytes(png(40, 20, (255, 0, 0, 255)))
        (self.work / 'pics/wide.png').write_bytes(png(1200, 100, (0, 0, 255, 255)))
        md = ('Before ![red dot](pics/red.png) after.\n\n![wide](pics/wide.png)\n\n'
              '![remote](https://example.com/x.png) ![missing](pics/none.png)\n')
        path = self.body(md, self.work.as_posix())
        out = self.run_editor([f'print-md-body 400 {path}'], exts=None, start=False)
        imgs = [l for l in out if l.startswith('item image ')]
        self.assertEqual(len(imgs), 2, out)
        self.assertEqual((self.field(imgs[0], 'w'), self.field(imgs[0], 'h')), ('40', '20'))
        w, h = int(self.field(imgs[1], 'w')), int(self.field(imgs[1], 'h'))    # scaled to the width
        self.assertTrue(390 <= w <= 400, w)
        self.assertEqual(h, w * 100 // 1200)
        t = [self_text(l) for l in self.texts(out)]
        self.assertNotIn('remote', t)                                   # not fetched: a chip, not its alt text
        self.assertNotIn('missing', t)
        self.assertNotIn('red', t)
        self.assertEqual([self_text(l) for l in out if l.startswith('item chip ')], ['[Image]', '[Image]'])
        # drawn: the red box in the demo
        shot = self.work / 'shot.ppm'
        out = self.run_editor([f'md-demo-body {path}', 'wait 100', f'shot {shot}'], exts=None, start=False)
        data = shot.read_bytes()
        parts = data.split(b'\n', 3)
        px = parts[3]
        reds = sum(1 for i in range(0, len(px) - 2, 3) if px[i:i + 3] == b'\xff\x00\x00')
        self.assertEqual(reds, 40 * 20)

    def test_relative_links_open_files_under_the_base(self):
        docs = self.proj / 'docs'
        docs.mkdir()
        (docs / 'guide one.md').write_text('# guide\n', encoding='utf-8')
        (docs / 'sub').mkdir()
        md = ('[a](guide%20one.md#part) [b](missing.md) [c](sub) [d](/etc/hosts) [e](#anchor) '
              '[f](mailto:x@y.z) [g](C:guide%20one.md)\n')
        path = self.body(md, docs.as_posix() + '/')
        acts = [f'md-demo-body {path}'] + [f'md-follow {i}' for i in range(7)] + ['print-tabs']
        out = self.run_editor(acts, exts=None, start=False)
        followed = [l for l in out if l.startswith('followed ')]
        self.assertEqual(followed, ['followed 0 1'] + [f'followed {i} 0' for i in range(1, 7)])
        tabs = [l for l in out if l.startswith('tabs=')][0]
        self.assertIn('guide one.md', tabs)
        # without a base nothing relative is followed
        path = self.body('[a](docs/guide%20one.md)\n')
        out = self.run_editor([f'md-demo-body {path}', 'md-follow 0'], exts=None, start=False)
        self.assertIn('followed 0 0', out)

    def test_a_static_picture(self):
        pic = self.work / 'pic.txt'
        pic.write_text('rect 0 0 40 20 #ff0000\nrect 50 0 40 20 #00ff00\n', encoding='utf-8')
        shot = self.work / 'shot.ppm'
        out = self.run_editor([f'pic-demo {pic}', 'wait 100', 'print-panel-tabs', f'shot {shot}'],
                              exts=None, start=False)
        self.assertNotIn('none', out)
        data = shot.read_bytes()
        parts = data.split(b'\n', 3)
        w = int(parts[1].split()[0])
        px = parts[3]
        tab = [l for l in out if l.startswith('panel ') or l.startswith('panel=')]
        # the panel's content box: find the red rectangle and the green one beside it
        reds = [i // 3 for i in range(0, len(px) - 2, 3) if tuple(px[i:i + 3]) == (255, 0, 0)]
        self.assertTrue(reds, tab)
        y0, x0 = divmod(reds[0], w)
        self.assertEqual(len(reds), 40 * 20)
        g = ((y0 + 5) * w + x0 + 55) * 3
        self.assertEqual(tuple(px[g:g + 3]), (0, 255, 0))
        bad = self.work / 'bad.txt'
        bad.write_text('rect 0 0 40 20 #ff0000\nrect nope\n', encoding='utf-8')
        out = self.run_editor([f'pic-demo {bad}'], exts=None, start=False)
        self.assertIn('pic-demo bad 2', out)


    def test_repeated_headings_get_numbered_slugs(self):
        path = self.work / 'doc.md'
        path.write_text('# Same\n\ntext\n\n# Same\n\nmore\n\n## Same\n\n# Other one\n', encoding='utf-8')
        out = self.run_editor([f'md-demo {path}', 'wait 50', 'md-anchor #same', 'md-anchor #same-1',
                               'md-anchor #same-2', 'md-anchor #same-3', 'md-anchor #other-one'], exts=None, start=False)
        ys = {l.split(' ')[1]: int(l.split(' ')[2]) for l in out if l.startswith('anchor ')}
        self.assertEqual(ys['#same'], 0)
        self.assertGreater(ys['#same-1'], ys['#same'])
        self.assertGreater(ys['#same-2'], ys['#same-1'])
        self.assertEqual(ys['#same-3'], -1)
        self.assertGreater(ys['#other-one'], ys['#same-2'])

    def test_unmatched_openers_parse_in_linear_time(self):
        import time
        text = '*a _b ~~c ' * 20000                                    # 200 KB, one paragraph
        start = time.monotonic()
        out = self.dump(text, 800)
        took = time.monotonic() - start
        self.assertTrue(out[0].startswith('blocks=1 '), out[0])
        self.assertLess(took, 3.0)

    def test_suffixed_slugs_never_collide(self):
        path = self.work / 'doc.md'
        path.write_text('# Same\n\n# Same\n\n# Same-1\n', encoding='utf-8')
        out = self.run_editor([f'md-demo {path}', 'wait 50', 'md-anchor #same', 'md-anchor #same-1',
                               'md-anchor #same-1-1'], exts=None, start=False)
        ys = [int(l.split(' ')[2]) for l in out if l.startswith('anchor ')]
        self.assertTrue(0 == ys[0] < ys[1] < ys[2], ys)                 # GitHub: same, same-1, same-1-1

    def test_anchors_in_a_heading_heavy_document_are_quick(self):
        import time
        path = self.work / 'doc.md'
        path.write_text(''.join(f'# H{i}\n' for i in range(16000)), encoding='utf-8')
        start = time.monotonic()
        out = self.run_editor([f'md-demo {path}', 'wait 50', 'md-anchor #h15999', 'md-anchor #h0'], exts=None, start=False)
        took = time.monotonic() - start
        ys = [int(l.split(' ')[2]) for l in out if l.startswith('anchor ')]
        self.assertGreater(ys[0], 0)
        self.assertEqual(ys[1], 0)
        self.assertLess(took, 2.0)

    def test_table_cells_do_not_inherit_another_documents_delimiters(self):
        a, b = self.work / 'a.md', self.work / 'b.md'
        a.write_text('| x | y |\n|---|---|\n| a | *b c |\n', encoding='utf-8')
        b.write_text('| x | y |\n|---|---|\n| a | *b*c |\n', encoding='utf-8')
        out = self.run_editor([f'print-md 400 {a}', f'print-md 400 {b}', f'print-md 400 {b}'], exts=None, start=False)
        bs = [l for l in out if l.startswith('item text ') and l.endswith(' text=b')]
        self.assertEqual(len(bs), 2, out)
        self.assertTrue(all(self.field(l, 'style') == '2' for l in bs), bs)

    # ---- a reply's Markdown (phase 3, task 3): the same in the editor's own documents ----

    def items(self, out, kind):
        return [l for l in out if l.startswith('item %s ' % kind)]

    def test_footnotes(self):
        md = ('Text with a note[^b], another[^a] and again[^b]; [^none] stays.\n\n'
              '[^a]: The second note.\n'
              '[^b]: The first note, with **bold**\n'
              'and a lazy line.\n'
              '[^unused]: Never cited.\n\n'
              'After the notes.\n')
        out = self.dump(md)
        blocks = self.blocks(out)
        # the body's blocks first, then the definitions in order of first use; one never cited is left out
        self.assertEqual([self.field(' ' + b, 'fn') for b in blocks], ['0', '0', '1', '2'], blocks)
        t = self.texts(out)
        sups = [l for l in t if int(self.field(l, 'style')) & 256]
        self.assertEqual([self_text(l) for l in sups], ['1', '2', '1'])
        word = [l for l in t if self_text(l) == 'note'][0]
        for l in sups:
            self.assertEqual(self.field(l, 'face'), '7')                 # three quarters of the text's
            self.assertEqual(self.field(l, 'y'), self.field(word, 'y'))
            self.assertLess(int(self.field(l, 'base')), int(self.field(word, 'base')))  # raised
            self.assertTrue(int(self.field(l, 'style')) & 16)            # a link
        links = [l for l in out if l.startswith('link ')]
        targets = {int(self.field(l, 'link')): None for l in sups}
        self.assertEqual(sorted(l.split(' ', 2)[2] for l in links if int(l.split(' ')[1]) in targets),
                         ['#^a', '#^b', '#^b'])
        self.assertIn('[^none]', [self_text(l) for l in t])               # an unknown id stays text
        texts = [self_text(l) for l in t]
        self.assertNotIn('Never', texts)
        # the definitions: numbered, under a thin rule after the last block
        first = int(self.field(' ' + blocks[2], 'line'))
        self.assertEqual(first, 3)                                        # [^b]'s line
        self.assertIn('1.', texts)
        self.assertIn('2.', texts)
        after = [l for l in t if self_text(l) == 'After'][0]
        first_note = [l for l in t if self_text(l) == 'first'][0]
        rules = [l for l in self.items(out, 'fill') if self.field(l, 'h') == '1' and
                 int(self.field(after, 'y')) < int(self.field(l, 'y')) < int(self.field(first_note, 'y'))]
        self.assertEqual(len(rules), 1, out)
        self.assertIn('bold', texts)
        self.assertIn('lazy', texts)
        # md-anchor scrolls to a definition, as to a heading
        path = self.work / 'doc.md'
        path.write_text(md, encoding='utf-8')
        out = self.run_editor([f'md-demo {path}', 'wait 50', 'md-anchor #^b', 'md-anchor #^a', 'md-anchor #^A',
                               'md-anchor #^none', 'md-anchor #^unused'], exts=None, start=False)
        ys = [int(l.split(' ')[2]) for l in out if l.startswith('anchor ')]
        self.assertGreater(ys[0], 0)
        self.assertGreater(ys[1], ys[0])
        self.assertEqual(ys[2], ys[1])                                    # labels compare without case
        self.assertEqual(ys[3:], [-1, -1])

    def test_footnotes_keep_a_table_after_them_whole(self):
        md = '[^x]: a note\n\nSee[^x].\n\n| a | b |\n|---|---|\n| 1 | 2 |\n'
        out = self.dump(md)
        kinds = [b.split(' ')[0] for b in self.blocks(out)]
        self.assertEqual(kinds, ['type=para', 'type=row', 'type=row', 'type=para'])
        self.assertIn('2', [self_text(l) for l in self.texts(out)])        # the row's cells laid out

    def test_insight_lines(self):
        rule = '─' * 45
        md = (f'`★ Insight {rule}`\n- one point\n- two points\n`{rule}`\n\n'
              f'`★ Insight {rule}`\nPlain point text.\n`{rule}`\n\n'
              'A short `───` and [a link](https://x.example) stay as they are.\n')
        out = self.dump(md, 400)
        t = self.texts(out)
        accent = self.field([l for l in t if self_text(l) == 'a'][0], 'color')   # a link's colour
        labels = [l for l in t if self_text(l) == '★ Insight']
        self.assertEqual(len(labels), 2, t)
        for l in labels:
            self.assertEqual(self.field(l, 'color'), accent)
            self.assertEqual(self.field(l, 'face'), '0')                   # the text's face, not code
            self.assertEqual(self.field(l, 'x'), '0')
        self.assertNotIn(rule, ' '.join(self_text(l) for l in t))          # no rule as text
        fills = self.items(out, 'fill')
        thin = [l for l in fills if self.field(l, 'h') == '1']
        # each label has a rule after it on its line, each closing line is a rule over the width
        for l in labels:
            y = int(self.field(l, 'y'))
            after = [f for f in thin if int(self.field(l, 'x')) + int(self.field(l, 'w')) < int(self.field(f, 'x'))
                     and y < int(self.field(f, 'y')) < y + int(self.field(l, 'h'))]
            self.assertEqual(len(after), 1, (l, thin))
        on_label = lambda f: any(int(self.field(l, 'y')) <= int(self.field(f, 'y')) <
                                 int(self.field(l, 'y')) + int(self.field(l, 'h')) for l in labels)
        wide = [f for f in thin if not on_label(f) and int(self.field(f, 'w')) > 250]
        self.assertEqual(len(wide), 2, thin)       # the first is in the list item it follows lazily
        # the second form: the point is a line of its own between them
        plain = [l for l in t if self_text(l) == 'Plain'][0]
        self.assertGreater(int(self.field(plain, 'y')), int(self.field(labels[1], 'y')))
        self.assertEqual(self.field(plain, 'x'), '0')
        short = [l for l in t if self_text(l) == '───'][0]
        self.assertEqual(self.field(short, 'style'), '4')                  # still a code span

    def test_display_math_is_shown_as_source(self):
        md = ('Before\n\n$$\nE = mc^2\n\\int_0^1 x\\,dx\n$$\n\nAfter $x$ inline, $$ y $$ too.\n\n'
              '$$\nunclosed\n')
        out = self.dump(md)
        kinds = [b.split(' ')[0] for b in self.blocks(out)]
        self.assertEqual(kinds, ['type=para', 'type=code', 'type=para', 'type=code'])
        t = self.texts(out)
        texts = [self_text(l) for l in t]
        code = [l for l in t if self.field(l, 'face') == '4']
        self.assertFalse([l for l in code if '$$' in self_text(l)], code)   # the delimiters are not shown
        self.assertEqual(' '.join(self_text(l) for l in code).replace(' ', ''),
                         'E=mc^2\\int_0^1x\\,dxunclosed')
        fg = self.field([l for l in t if self_text(l) == 'Before'][0], 'color')
        self.assertTrue(all(self.field(l, 'color') == fg for l in code))  # no language: no colours
        self.assertIn('$x$', texts)
        self.assertIn('$$', texts)                                         # inline: text
        self.assertEqual(len([l for l in out if l.startswith('copy-action ')]), 2)

    def test_dollar_amounts_stay_text(self):
        out = self.dump('It costs $5 and $10 today, $$ not math.\n')
        self.assertEqual([b.split(' ')[0] for b in self.blocks(out)], ['type=para'])
        t = self.texts(out)
        self.assertEqual([self_text(l) for l in t], ['It', 'costs', '$5', 'and', '$10', 'today,', '$$', 'not',
                                                     'math.'])
        self.assertTrue(all(self.field(l, 'style') == '0' for l in t))

    def test_remote_image_is_blocked(self):
        md = 'See ![a chart](https://example.com/chart.png "title") here.\n'
        out = self.dump(md)
        chips = self.items(out, 'chip')
        self.assertEqual(len(chips), 1, out)
        self.assertEqual(self_text(chips[0]), '[Image]')
        texts = [self_text(l) for l in self.texts(out)]
        self.assertEqual(texts, ['See', 'here.'])                         # the alt text is not drawn
        see = [l for l in self.texts(out) if self_text(l) == 'See'][0]
        self.assertEqual(self.field(chips[0], 'y'), self.field(see, 'y'))  # in the line
        self.assertIn('link 0 https://example.com/chart.png', out)         # the tip names it
        # in a table's cell too
        out = self.dump('| a | b |\n|---|---|\n| ![pic](https://e.example/p.png) | x |\n')
        self.assertEqual(len(self.items(out, 'chip')), 1, out)
        self.assertNotIn('pic', [self_text(l) for l in self.texts(out)])

    def test_data_image_is_a_chip(self):
        md = '![dot](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==)\n'
        out = self.dump(md)
        chips = self.items(out, 'chip')
        self.assertEqual([self_text(l) for l in chips], ['[Image]'])
        self.assertEqual(self.texts(out), [])
        self.assertEqual(self.items(out, 'image'), [])                    # no thumbnail yet (phase 4)

    def test_link_at_a_point(self):
        """md_link_at, the link under a point, by the assembly unit check tests/markdown_test.s"""
        exe = Path(__file__).resolve().parents[1] / 'build/markdown_test'
        if not exe.exists():
            self.skipTest('build/markdown_test is not built')
        res = subprocess.run([str(exe)], capture_output=True, timeout=60)
        out = res.stdout + res.stderr
        expected = (Path(__file__).resolve().parent / 'data/markdown.expected').read_bytes()
        self.assertEqual(out, expected, out.decode(errors='replace'))
        self.assertEqual(res.returncode, 0)


def self_text(line):
    return line.split(' text=', 1)[1]


if __name__ == '__main__':
    unittest.main()
