#!/usr/bin/env python3
"""Markdown documents (markdown.s): blocks, inline styles, links and the layout, through the
headless print-md WIDTH PATH (md_dump's lines)."""
import os
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
        self.assertIn('remote', t)                                      # alt text: not fetched
        self.assertIn('missing', t)
        self.assertNotIn('red', t)
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

def self_text(line):
    return line.split(' text=', 1)[1]


if __name__ == '__main__':
    unittest.main()
