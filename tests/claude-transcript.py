#!/usr/bin/env python3
"""A conversation's typed rows (phase 3): a tool call's row with its parts (header, link, description, note,
IN and OUT clipped with a fade, a text that opens in a tab), meta and unknown-block rows, cleaning, limits,
the fit at every panel size and width. Rows are made with the test seam (agent-test-tool, agent-test-row):
no driver and no reader is needed, so most cases run on a Codex conversation (no driver at all) or on a
Claude conversation that is only read. It imports tests/claude-chat.py for its cases (own HOME and XDG
folders, no CLAUDE* or ANTHROPIC* variables); nothing here starts the real CLI or writes the user's own
Claude Code settings."""
import importlib.util
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location('claude_chat', ROOT / 'tests/claude-chat.py')
chat = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(chat)

TIP = 'Press Enter to open the full text in an editor tab'
CHANGED = "The conversation's file changed: showing what was kept."


def mi(n, size, ui=13):
    """A panel metric at a panel text size (agentfont.s: the interface's metric times size / its size)."""
    return max(1, (n * size + ui // 2) // ui)


class RowCase(chat.DrivenCase):
    """A conversation to put rows on, and the dumps read."""

    def codex(self, extra=''):
        """A Codex conversation of the project (no driver: nothing can be asked of one), opened."""
        path = self.work / '.codex/sessions/2026/10/02/rollout-test.jsonl'
        path.parent.mkdir(parents=True)
        fixture = (ROOT / 'tests/data/agents/codex.jsonl').read_text(encoding='utf-8')
        path.write_text(fixture.replace('@PROJECT@', self.project.as_posix()), encoding='utf-8')
        self.start(extra=extra)
        self.command('cmd focus_agents')
        self.command('wait-agents')
        rows = [line for line in self.command('print-agents').splitlines() if line.startswith('Codex')]
        self.assertEqual(len(rows), 1, rows)
        self.command('print-agents 1')
        self.base = len(self.rows())

    def claude(self, extra=''):
        """The project's Claude conversation (the agents fixture), opened and only read."""
        self.seed()
        self.start(extra=extra)
        self.open_listed()
        self.base = len(self.rows())

    def tool(self, line):
        self.command('agent-test-tool ' + line)

    def rows(self):
        """print-agent-rows as (header line, [part lines])."""
        out = []
        for line in self.command('print-agent-rows').splitlines():
            if line.startswith(' '):
                out[-1][1].append(line.strip())
            else:
                out.append((line, []))
        return out

    def row_line(self, n, content=False):
        """print-agent-rows' line of row n (from 0) and its parts."""
        lines = self.command('print-agent-rows %s%d 1' % ('content ' if content else '', n)).splitlines()
        return lines[0], [line.strip() for line in lines[1:]]

    def drawn(self, n):
        """print-agent-row of row n (from 0): its header fields and its drawn parts."""
        lines = self.command('print-agent-row %d' % (n + 1)).splitlines()
        return dict(w.split('=', 1) for w in lines[0].split(' ')), lines[1:]

    def buttons(self, n):
        """The buttons row n was drawn with: {part: (x, y, w, h, id)}."""
        out = {}
        for line in self.drawn(n)[1]:
            m = re.match(r'button (\d+) (-?\d+),(-?\d+),(-?\d+),(-?\d+) (\d+)$', line)
            if m:
                out[int(m.group(1))] = tuple(int(v) for v in m.group(2, 3, 4, 5, 6))
        return out


class RowTest(RowCase):
    """A call's row is made of neutral parts; the renderer never reads its name."""

    def test_a_row_needs_no_claude_code(self):
        self.codex()
        for i, name in enumerate(('Bash', 'Edit', 'TodoWrite')):
            self.tool('c%d name=%s second=src/main.c tail=(3 lines) desc=Look at it note=Read 3 lines '
                      'in=ls -la\\nsrc out=total 0\\nmain.c state=ok' % (i, name))
        rows = self.rows()[self.base:]
        self.assertEqual(len(rows), 3, rows)
        parts = [(re.sub(r' name=\S+', '', head.split(' ', 1)[1]), lines) for head, lines in rows]
        self.assertEqual(parts[0][1], parts[1][1])
        self.assertEqual(parts[0][1], parts[2][1])
        drawn = []
        for n in range(self.base, self.base + 3):
            _, lines = self.drawn(n)
            # the body is the same; only the header's name (and where the texts after it begin) differ
            drawn.append([l for l in lines if l.split(' ')[0] in ('desc', 'note', 'in', 'out')])
        self.assertTrue(drawn[0], drawn)
        self.assertEqual(drawn[0], drawn[1])
        self.assertEqual(drawn[0], drawn[2])
        self.assertIn('tool(TodoWrite) src/main.c', self.command('print-agents'))

    def test_header_link_asks_or_opens(self):
        (self.project / 'notes.txt').write_text(''.join('line %d\n' % i for i in range(1, 30)), encoding='utf-8')
        self.codex()
        self.tool('w name=Fetch second=example.com link=https://example.com/a state=ok')
        self.tool('f name=Read second=notes.txt link=notes.txt l0=12 l1=14 state=ok')
        self.tool('j name=Open second=alert link=javascript:alert(1) state=ok')
        self.tool('l name=Open second=far link=' + 'x' * 5000 + ' state=ok')
        w, f, j, l = range(self.base, self.base + 4)
        self.assertIn(1, self.buttons(w))
        self.command('agent-row-click %d link' % (w + 1))
        palette = self.command('print-palette').splitlines()
        # a Codex conversation has no driver: the reply asks
        self.assertEqual(palette[0], 'choose=This reply wants to open example.com in your browser: '
                                     'https://example.com/a')
        self.command('key Escape')
        self.command('agent-row-click %d link' % (f + 1))
        self.assertIn(' active=notes.txt line=12 ', self.command('print-state'))
        self.command('cmd focus_agents')
        before = self.command('print-state')
        self.command('agent-row-click %d link' % (j + 1))
        self.assertEqual(self.command('print-state'), before)        # another scheme: nothing
        self.assertNotIn('link', ' '.join(self.row_line(l)[1]))      # 5,000 bytes: no link at all
        self.assertNotIn(1, self.buttons(l))

    def test_find_puts_the_caret_on_the_new_text(self):
        (self.project / 'a.txt').write_text('one\ntwo\nthe new text here\nfour\n', encoding='utf-8')
        self.codex()
        self.tool('e name=Edit second=a.txt link=a.txt find=the new text here\\nand more state=ok')
        self.command('agent-row-click %d link' % (self.base + 1))
        self.assertIn(' active=a.txt line=3 ', self.command('print-state'))

    def test_what_is_a_button(self):
        self.codex()
        cases = [('a' * 250, False), ('a' * 251, True), ('a\\nb\\nc', False), ('a\\nb\\nc\\nd', True),
                 ('\U0001F600' * 125, False), ('\U0001F600' * 126, True)]     # 2 UTF-16 units each
        for i, (text, big) in enumerate(cases):
            self.tool('b%d name=Bash out=%s state=ok' % (i, text))
            self.assertEqual(3 in self.buttons(self.base + i), big, (i, text[:20]))

    def test_clip_height_follows_the_font(self):
        self.codex()
        self.tool('c name=Bash out=' + '\\n'.join('line %d' % i for i in range(40)) + ' state=ok')
        for size in (8, 13, 32):
            self.command('agent-cfg-set-font %d' % size) if False else None
            self.config.write_text(self.config.read_text())
            self.command('cmd agents_font_reset')
            for _ in range(abs(size - 13)):
                self.command('cmd agents_font_%s' % ('increase' if size > 13 else 'decrease'))
            self.command('print-frames')
            b = self.buttons(self.base)
            self.assertIn(3, b)
            self.assertEqual(b[3][3], 3 * mi(20, size), size)

    def test_error_text(self):
        self.codex()
        self.tool('s name=Bash out=no such file\\nsecond line\\nthird state=failed')
        self.tool('l name=Bash out=' + 'error words ' * 400 + ' state=failed')
        head, parts = self.row_line(self.base)
        self.assertIn('state=failed', head)
        _, drawn = self.drawn(self.base)
        self.assertEqual(len([l for l in drawn if l.startswith('out ')]), 3)    # whole
        self.assertNotIn(3, self.buttons(self.base))
        _, drawn = self.drawn(self.base + 1)
        self.assertEqual(len([l for l in drawn if l.startswith('out ')]), 10)   # 10 lines, a button
        self.assertIn(3, self.buttons(self.base + 1))

    def test_live_text_is_capped(self):
        self.codex()
        text = '\\n'.join('output line %05d %s' % (i, 'x' * 40) for i in range(20000))
        self.tool('big name=Bash out=' + text + ' state=ok')
        head, parts = self.row_line(self.base)
        out = [p for p in parts if p.startswith('out ')][0]
        self.assertIn(' kept=16384 ', out)
        self.assertTrue(out.startswith('out 20000/'), out)
        self.command('agent-row-click %d out' % (self.base + 1))
        doc = self.command('print-doc')
        last = [l for l in doc.splitlines() if l.strip()][-2]
        self.assertRegex(last, r'^… \d+ more lines$')

    def test_output_is_cleaned(self):
        self.codex()
        self.tool('d name=Bash out=\\e[31mred\\e[0m \\e]0;title\\a bell\\a crlf\\r\\nc1\\xc2\\x85 '
                  'bidi\\xe2\\x80\\xaeevil bad\\xffbyte state=ok')
        _, parts = self.row_line(self.base)
        out = [p for p in parts if p.startswith('out ')][0]
        self.assertIn('red  bell crlf', out)
        self.assertNotIn('\x1b', out)
        self.assertNotIn('title', out)
        self.assertTrue(out.startswith('out 2/'), out)      # CR LF: one line feed
        drawn = [l for l in self.drawn(self.base)[1] if l.startswith('out ')]
        self.assertEqual(drawn[1], 'out 1 c1 bidievil bad\ufffdbyte')

    def test_hidden_call_has_no_row(self):
        self.codex()
        before = self.command('print-agent-thread')
        self.tool('h name=Bash second=hidden flags=1 state=ok')
        head, _ = self.row_line(self.base)
        self.assertIn(' h=0 ', head)
        self.assertNotIn('hidden', self.command('print-agents'))
        content = lambda t: re.search(r' content=(\d+)', t).group(1)
        self.assertEqual(content(self.command('print-agent-thread')), content(before))

    def test_states_and_dots(self):
        self.codex()
        for i, state in enumerate(('running', 'ok', 'failed', 'denied', 'stopped')):
            self.tool('s%d name=Bash second=x state=%s' % (i, state))
            self.assertIn('state=' + state, self.row_line(self.base + i)[0])
        self.command('agent-test-row agent a reply')
        self.command('agent-test-row thinking ms=3000')
        rows = self.command('print-agents').splitlines()
        self.assertIn('thinking(3s) ', rows)

    def test_copy_button_copies_the_command(self):
        self.codex()
        self.tool('c name=Bash in=make test\\n  && echo done flags=2 state=ok')
        self.assertIn(8, self.buttons(self.base))
        self.command('agent-row-click %d copy' % (self.base + 1))
        self.assertIn('Copied.', self.command('print-toast'))
        self.command('key ' + chat.MOD + '+n')
        self.command('key ' + chat.MOD + '+v')
        self.assertIn('make test\n  && echo done', self.command('print-doc'))

    def test_unknown_block_row(self):
        self.codex()
        self.command('agent-test-row unknown mystery_block')
        self.assertIn('unknown mystery_block', self.command('print-agents'))
        head, _ = self.row_line(self.base)
        self.assertIn(' type=mystery_block', head)

    def test_ids_are_unique_in_a_frame(self):
        self.codex('[agents]\nfont_size = 8\n')        # many rows in view
        for i in range(60):
            self.tool('i%d name=Bash second=s link=https://e.com/%d in=%s out=%s flags=2 state=ok'
                      % (i, i, 'a' * 300, '\\n'.join('l%d' % k for k in range(6))))
            self.command('agent-test-row meta note %d' % i)
            self.command('agent-test-row thinking ms=1000')
            self.command('agent-test-row unknown block%d' % i)
            self.command('agent-test-row agent reply %d' % i)
        self.command('key End')
        e = dict(w.split('=', 1) for w in self.command('print-agent-thread').split())
        ids = []
        for n in range(int(e['first']), int(e['last']) + 1):
            for line in self.drawn(n)[1]:
                if line.startswith('button '):     # (a link's line names its button's id again)
                    ids.append(int(line.split(' ')[-1]))
        self.assertGreater(len(ids), 10)
        self.assertEqual(len(ids), len(set(ids)))

    def test_rows_fit_every_size_and_width(self):
        self.codex()
        self.tool('a name=Bash second=src/app/a_very_long_file_name_for_testing.s link=src/app/x.s tail=(3 lines) '
                  'desc=A description that is long enough to be cut note=Read 3 lines in=%s out=%s flags=2 '
                  'title=Bash output state=ok' % ('x' * 400, '\\n'.join('line %d' % i for i in range(9))))
        self.tool('b name=Bash out=short state=failed')
        self.command('agent-test-row meta a meta line that wraps when the panel is narrow')
        self.command('agent-test-row unknown block')
        ui = int(re.search(r'points=(\d+)', self.command('print-agents-metrics')).group(1))
        blocks, current = [], None
        for line in self.command('print-agent-rows-fit').splitlines():
            if line.startswith('size='):
                current = (dict(w.split('=', 1) for w in line.split(' ')), [])
                blocks.append(current)
            else:
                current[1].append(line.strip())
        self.assertEqual(len(blocks), 25 * 34 * 4)
        for head, parts in blocks:
            size, tw = int(head['size']), int(head['tw'])
            boxes = []
            for p in parts:
                words = p.split(' ')
                kind = words[0] if words[0] != 'button' else 'button' + words[1]
                x, y, w, h = (int(v) for v in words[-1].split(','))
                self.assertGreaterEqual(x, 0, (head, p))
                self.assertLessEqual(x + w, tw, (head, p))
                self.assertLessEqual(y + h, int(head['h']), (head, p))
                if kind.startswith('button'):
                    self.assertGreaterEqual(h, mi(16, size, ui) - 1, (head, p))
                boxes.append((kind, x, y, w, h))
            texts = [b for b in boxes if not b[0].startswith('button')]
            buttons = [b for b in boxes if b[0].startswith('button')]
            for group in (texts, buttons):
                for i, a in enumerate(group):
                    for b in group[i + 1:]:
                        overlap = (a[1] < b[1] + b[3] and b[1] < a[1] + a[3] and
                                   a[2] < b[2] + b[4] and b[2] < a[2] + a[4] and a[3] and b[3] and a[4] and b[4])
                        self.assertFalse(overlap, (head, a, b))

    def test_reply_faces(self):
        self.claude()
        head, _ = self.drawn(1)
        self.assertEqual(head['role'], 'agent')
        self.assertEqual(head['parsed'], '1')
        px = int(re.search(r' px=(\d+)', self.command('print-agents-metrics')).group(1))
        self.assertEqual((int(head['face']), int(head['code'])), (px, px))


if __name__ == '__main__':
    unittest.main()
