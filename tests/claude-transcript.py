#!/usr/bin/env python3
"""A conversation's typed rows (phase 3): a tool call's row with its parts (header, link, description, note,
IN and OUT clipped with a fade, a text that opens in a tab), meta and unknown-block rows, cleaning, limits,
the fit at every panel size and width. Rows are made with the test seam (agent-test-tool, agent-test-row):
no driver and no reader is needed, so most cases run on a Codex conversation (no driver at all) or on a
Claude conversation that is only read. Then Claude Code's calls as rows (task 4, claude_blocks.s): every
tool's form from the fake's scenarios and from seeded files, the stream and the file giving the same rows
(ParityTest), hostile records. It imports tests/claude-chat.py for its cases (own HOME and XDG
folders, no CLAUDE* or ANTHROPIC* variables); nothing here starts the real CLI or writes the user's own
Claude Code settings."""
import importlib.util
import json
from pathlib import Path
import re
import time
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

    def test_full_text_from_a_line(self):
        self.codex()
        line = json.dumps({'id': 'r1', 'output': 'the whole text ' * 200})
        src = self.work / 'records.jsonl'
        src.write_text('{"first": 1}\n' + line + '\n', encoding='utf-8')
        offset = len('{"first": 1}\n')
        self.tool('r1 name=Bash out=%s state=ok src=%s:%d:%d' % ('the whole text ' * 200, src, offset,
                                                                    len(line.encode())))
        head, parts = self.row_line(self.base)
        out = [p for p in parts if p.startswith('out ')][0]
        self.assertIn(' kept=600 ', out)                              # a row with a place keeps a preview
        self.command('agent-row-click %d out' % (self.base + 1))
        self.assertNotIn(CHANGED, self.command('print-toast'))
        self.assertIn('the whole text', self.command('print-doc'))
        self.command('cmd focus_agents')
        src.write_text('{"first": 2, "x": 1}\n' + line + '\n', encoding='utf-8')   # its line moved
        self.command('cmd close_tab')                # (a second click would find its tab)
        self.command('cmd focus_agents')
        self.command('agent-row-click %d out' % (self.base + 1))
        self.assertIn(CHANGED, self.command('print-toast'))

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
        head, _ = self.drawn(2)                         # (row 1: the fixture's thinking, task 6)
        self.assertEqual(head['role'], 'agent')
        self.assertEqual(head['parsed'], '1')
        px = int(re.search(r' px=(\d+)', self.command('print-agents-metrics')).group(1))
        self.assertEqual((int(head['face']), int(head['code'])), (px, px))



MODEL = chat.MODEL
YB = chat.REJECTED
XB = ("The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file "
      "edit, the new_string was NOT written to the file). The user provided the following reason for the "
      "rejection: ")


def call(tid, name, tool_input, mid=None):
    """An assistant line of a conversation's file with one tool_use block."""
    return {'type': 'assistant', 'message': {'model': MODEL, 'id': mid or 'msg-' + tid, 'role': 'assistant',
                                             'content': [{'type': 'tool_use', 'id': tid, 'name': name,
                                                          'input': tool_input}]}}


def result(tid, content, is_error=None, structured=None):
    """A user line with one tool_result block (and the file's toolUseResult)."""
    block = {'tool_use_id': tid, 'type': 'tool_result', 'content': content}
    if is_error is not None:
        block['is_error'] = is_error
    line = {'type': 'user', 'message': {'role': 'user', 'content': [block]}}
    if structured is not None:
        line['toolUseResult'] = structured
    return line


def prompt(text):
    return {'type': 'user', 'message': {'role': 'user', 'content': text}}


def reply(text):
    return {'type': 'assistant', 'message': {'model': MODEL, 'id': 'msg-r', 'role': 'assistant',
                                             'content': [{'type': 'text', 'text': text}]}}


class ToolCase(RowCase):
    """Claude's calls: the rows of a scenario of the fake, or of a seeded conversation file."""

    def file(self, sid='s1'):
        return self.work / '.claude/projects' / chat.slug(self.project) / (sid + '.jsonl')

    def seed_lines(self, lines, sid='s1'):
        """A Claude conversation file of these lines (each gets the session's id, the folder and a time)."""
        path = self.file(sid)
        path.parent.mkdir(parents=True, exist_ok=True)
        out = []
        for i, line in enumerate(lines):
            if line.get('type') in ('user', 'assistant', 'system'):
                line = dict(line, cwd=self.project.as_posix(), sessionId=sid,
                            timestamp='2026-11-23T17:%02d:%02d.000Z' % (i // 60 % 60, i % 60))
            out.append(json.dumps(line) + '\n')
        path.write_text(''.join(out), encoding='utf-8')
        return path

    def append_lines(self, lines, sid='s1'):
        with self.file(sid).open('a', encoding='utf-8') as stream:
            for line in lines:
                stream.write(json.dumps(dict(line, cwd=self.project.as_posix(), sessionId=sid)) + '\n')

    def open_seeded(self, lines, extra=''):
        self.seed_lines([prompt('look')] + lines)
        self.start(extra=extra)
        self.open_listed()

    def calls(self, content=True):
        """The open conversation's tool rows: dicts of name, state, flags, kids and their parts (a part's
        word -> its text; todo -> a list)."""
        out = []
        for head, parts in self.rows_of('content' if content else ''):
            m = re.match(r'(\d+) tool .*?name=(.*) state=(\S+) flags=(\S+) kids=(\S+)$', head)
            if not m:
                continue
            row = {'row': int(m.group(1)), 'name': m.group(2), 'state': m.group(3),
                   'flags': set(m.group(4).split(',')) - {'-'}, 'kids': m.group(5), 'todo': []}
            for part in parts:
                word, _, text = part.partition(' ')
                if word == 'todo':
                    row['todo'].append(text)
                else:
                    row[word] = text
            out.append(row)
        return out

    def rows_of(self, how=''):
        out = []
        for line in self.command('print-agent-rows ' + how).splitlines():
            if line.startswith(' '):
                out[-1][1].append(line.strip())
            elif line:
                out.append((line, []))
        return out

    def scenario(self, prompt, cards=(), wait='ready'):
        """A new conversation with that prompt; each card answered in turn (agent-card ARGS)."""
        self.command('agent-timing card=0')         # (a new card's lock)
        self.command('agent-new claude')
        self.command('agent-prompt ' + prompt)
        for answer in cards:
            self.command('wait-agent waiting 10000')
            self.command('agent-timing advance=0')
            for word in answer.split(';'):
                self.command('agent-card ' + word)
        if wait:
            self.command('wait-agent %s 15000' % wait)

    def reread(self):
        """The program ends and the conversation is read again from its file."""
        self.command('agent-release')
        self.command('wait-agent off')
        self.until_gone()

    def by_name(self, name):
        return [c for c in self.calls() if c['name'] == name]


class ToolsTest(ToolCase):
    """Each tool's form, as the extension's renderers draw it (index.js 2.1.328), from the fake's records."""

    def test_every_tool_row(self):
        self.start()
        self.scenario('tools')
        rows = self.calls()
        names = [c['name'] for c in rows]
        self.assertEqual(names, ['Read', 'Read', 'Read', 'Read', 'Edit', 'Edit', 'Edit', 'Write', 'Write', 'Bash',
                                 'Bash', 'Grep', 'Grep', 'Grep', 'Glob', 'Glob', 'ToolSearch', 'Web Search',
                                 'Web Fetch', 'ToolSearch', 'Update Todos'])
        project = self.project.as_posix()
        read, part, missing, image, edit, edit_all, edit_bad, new, over, bash, bash_bad = rows[:11]
        # Read: the file's name, a link to it at the lines read; nothing else (a failed one: OUT)
        self.assertEqual((read['second'], read['link'], read['state']), ('notes.txt', project + '/notes.txt', 'ok'))
        self.assertNotIn('out', read)
        self.assertEqual((part['link'], part['tail']), (project + '/a.py 3-5', '(lines 3-5)'))
        self.assertEqual(missing['state'], 'failed')
        self.assertTrue(missing['out'].startswith('1/') and 'File does not exist.' in missing['out'], missing)
        self.assertNotIn('out', image)
        # Edit: its note by the line counts, the diff of the two strings, a link that looks for the new text
        self.assertEqual((edit['note'], edit['find'], edit['flags']), ('Modified', 'TWO', {'diff'}))
        self.assertEqual(edit_all['note'], 'Modified')
        self.assertEqual((edit_bad['state'], edit_bad['note']), ('failed', 'Edit failed'))
        self.assertIn('String to replace not found in file.', edit_bad['out'])
        self.assertNotIn('tool_use_error', edit_bad['out'])
        # Write: "N lines", the text under it, its tab "Write NAME"
        self.assertEqual((new['note'], new['pre'], new['title'], new['flags']),
                         ('1 line', '1/5 hello', 'Write new.txt', {'pre'}))
        self.assertEqual(over['title'], 'Write notes.txt')
        # Bash: the description; IN the command (a Copy button), OUT the output; a failure in OUT
        self.assertEqual((bash['second'], bash['in'], bash['out'], bash['flags']),
                         ('Print out', '1/8 echo out', '1/3 out', {'shell'}))
        self.assertEqual((bash_bad['state'], bash_bad['out']), ('failed', '2/54 Exit code 1'))
        grep, grep_files, grep_count, glob, glob_none, search1, web, fetch, search2, todo = rows[11:]
        self.assertEqual((grep['second'], grep['note'], grep['title']), ('"row"', '8 lines of output', 'Grep output'))
        self.assertEqual(grep_files['note'], '2 lines of output')
        self.assertEqual(grep_count['note'], '2 lines of output')
        self.assertEqual((glob['second'], glob['note'], glob['title']), ('pattern: "*.py"', 'Found 1 file',
                                                                         'Glob output'))
        self.assertEqual(glob_none['note'], 'No files found')
        self.assertEqual(search1['flags'], {'hidden'})
        self.assertEqual((web['second'], web['out'][:12]), ('IANA example domain', '5/187 Web se'))
        self.assertEqual((fetch['second'], fetch['link'], fetch['note']),
                         ('https://example.com', 'https://example.com', 'Fetched from https://example.com'))
        self.assertEqual(todo['todo'], ['[x] a', '[-] b', '[ ] c'])
        self.assertNotIn('hidden', ' '.join(self.thread()))      # print-agents: no line for ToolSearch
        self.assertIn('tool(TodoWrite) ', self.thread())
        # the scenarios that run without asking
        self.scenario('grep run')
        self.assertEqual([c['note'] for c in self.calls()], ['8 lines of output', '2 lines of output',
                                                              '2 lines of output'])
        self.scenario('glob run')
        self.assertEqual([(c['second'], c['note']) for c in self.calls()], [('pattern: "*.txt"', 'Found 1 file')])
        self.scenario('websearch run')
        web, = self.calls()
        self.assertEqual((web['name'], web['second'], web['desc']),
                         ('Web Search', 'rhun editor', 'Allowed: rhun.app, github.com · Blocked: example.com'))
        self.scenario('todo')
        self.assertEqual(self.calls()[-1]['todo'], ['[x] a', '[-] b', '[ ] c'])

    def test_the_task_tools_are_a_list(self):
        self.start(env={'FAKE_CLAUDE_TASKS': '1'})
        self.scenario('todo')
        lists = [c['todo'] for c in self.calls() if c['name'] == 'Update Todos']
        self.assertEqual(lists, [['[ ] a'], ['[ ] a', '[ ] b'], ['[ ] a', '[ ] b', '[ ] c'],
                                 ['[x] a', '[ ] b', '[ ] c']])
        live = self.calls()
        self.reread()
        self.assertEqual(self.calls(), live)

    def test_the_other_forms(self):
        """The tools no run recorded (NotebookEdit, Skill, the extension's own) in the bundle's forms."""
        self.open_seeded([
            call('n1', 'NotebookEdit', {'notebook_path': '/x/nb.ipynb', 'cell_id': 'c3', 'new_source': 'print(1)'}),
            result('n1', 'Updated cell'),
            call('n2', 'NotebookEdit', {'notebook_path': '/x/nb.ipynb'}),
            call('s1', 'Skill', {'skill': '/review', 'args': '--quick'}), result('s1', 'Launching skill'),
            call('o1', 'TaskOutput', {'task_id': 'b1234'}), result('o1', 'done\n'),
            call('a1', 'AgentOutputTool', {'agentId': 'x'}), result('a1', 'whatever'),
            call('k1', 'SandboxNetworkAccess', {'host': 'example.com'}),
            call('f1', 'SendUserFile', {'files': ['/x/a.png', ' /x/b.txt ', 'https://e.com/c'], 'caption': 'Two'}),
            result('f1', 'Sent.'),
            call('p1', 'SendToProject', {'project_name': 'Docs'}),
            call('r1', 'ReadCoalesced', {'fileReads': [{'file_path': '/x/a.c'}, {'file_path': '/y/b.c', 'offset': 3}]}),
            call('x1', 'ExitPlanMode', {'plan': '# P'}), result('x1', 'User chose to stay in plan mode', True),
            call('x2', 'ExitPlanMode', {}),
            call('q1', 'AskUserQuestion', {'questions': [{'question': 'Red?'}]}), result('q1', XB + 'no colours', True),
            call('q2', 'AskUserQuestion', {'questions': [{'question': 'A?'}, {'question': 'B?'}]}),
            result('q2', 'The user did not answer the questions.'),
            call('h1', 'Search', {'pattern': 'x'}),
            call('m1', 'mcp__github_ai__get', {'url': 'https://API.Example.com:8443/v1/x'}),
            call('m2', 'mcp__slack__post', {'channel': 'general', 'text': 'hi'}),
            call('m3', 'mcp__x__y', {'title': 'z' * 50}),
            call('t1', 'Artifact', {'file_path': 'page.html'}),
            result('t1', 'Published version 2 at https://claude.ai/artifact/abc to the team'),
        ])
        rows = self.calls()
        names = [c['name'] for c in rows]
        self.assertEqual(names, ['Edit Notebook Cell', 'Edit Notebook Cell', 'review', 'TaskOutput', 'AgentOutputTool',
                                 'Network Access', 'Sent', 'Send to project', 'Read', 'Claude’s Plan', 'Plan Mode',
                                 'Question', 'Questions', 'Search', 'GitHub AI [get]', 'Slack [post]', 'X [y]',
                                 'Artifact'])
        nb, nb2, skill, out, agent_out, net, sent, project, coalesced, plan, mode, red, ab, search, m1, m2, m3, art = rows
        self.assertEqual((nb['second'], nb['note'], nb['pre'], nb['link']), ('nb.ipynb:c3', 'Success', '1/8 print(1)',
                                                                             '/x/nb.ipynb'))
        self.assertEqual((nb2['note'], nb2['pre']), ('Pending', '1/12 [No content]'))
        self.assertEqual((skill['second'], skill.get('out')), ('skill', None))
        self.assertEqual((out['second'], out['out']), ('task: "b1234"', '1/5 done'))
        self.assertEqual(agent_out.get('out'), None)
        self.assertEqual(net['second'], 'example.com')
        self.assertEqual((sent['second'], sent['link'], sent['desc'], sent.get('out')),
                         ('a.png, b.txt, c', '/x/a.png', 'Two', None))
        self.assertTrue(project['in'].startswith('3/'), project)
        self.assertEqual((coalesced['second'], coalesced['link']), ('a.c, b.c', '/x/a.c'))
        self.assertEqual((plan['note'], plan['state']), ('Stayed in plan mode', 'failed'))
        self.assertEqual((red['note'], red['desc'], red['state']), ('Declined · 1 question', 'Reason: no colours',
                                                                    'denied'))
        self.assertEqual(ab['note'], 'No answer · 2 questions')
        self.assertEqual((search['second'], search['in'][:2]), ('pattern: "x"', '3/'))
        self.assertEqual((m1['second'], m2['second'], m3['second']), ('api.example.com', '#general', 'z' * 40 + '…'))
        self.assertEqual((art['second'], art['link'], art['note']),
                         ('page.html', 'https://claude.ai/artifact/abc', 'Published — Open artifact ↗'))

    def test_names_match_whole(self):
        self.open_seeded([call('t1', 'TaskCreate', {'title': 'no subject'}), call('t2', 'Bashful', {'command': 'ls'}),
                          call('t3', 'AgentX', {'description': 'd', 'prompt': 'p'}),
                          call('t4', 'mcp__a__b', {'query': 'q'}), call('t5', 'Bash ', {'command': 'ls'})])
        rows = self.calls()
        self.assertEqual([c['name'] for c in rows], ['TaskCreate', 'Bashful', 'AgentX', 'A [b]', 'Bash '])
        for c in rows:
            self.assertNotIn('shell', c['flags'], c)
            self.assertNotIn('parent', c['flags'], c)
        self.assertTrue(rows[0]['in'].startswith('3/'), rows[0])     # the generic form: its input as JSON
        self.assertEqual(rows[3]['second'], 'q')
        self.assertNotIn('in', rows[3])                 # an MCP call: OUT only

    def test_read_tail_forms(self):
        self.open_seeded([call('r1', 'Read', {'file_path': '/x/a.txt', 'offset': 9, 'limit': 5}),
                          call('r2', 'Read', {'file_path': '/x/a.txt', 'offset': 9}),
                          call('r3', 'Read', {'file_path': '/x/a.txt', 'limit': 5}),
                          call('r4', 'Read', {})])
        r1, r2, r3, r4 = self.calls()
        self.assertEqual((r1['tail'], r1['link']), ('(lines 10-14)', '/x/a.txt 10-14'))
        self.assertEqual((r2['tail'], r2['link']), ('(from line 10)', '/x/a.txt 10-0'))
        self.assertEqual((r3.get('tail'), r3['link']), (None, '/x/a.txt 1-5'))
        self.assertEqual((r4['name'], r4.get('second')), ('Read', None))

    def test_edit_note_counts(self):
        self.open_seeded([call('e1', 'Edit', {'file_path': '/x/a', 'old_string': 'a', 'new_string': 'a\nb\nc'}),
                          call('e2', 'Edit', {'file_path': '/x/a', 'old_string': 'a\nb', 'new_string': 'a'}),
                          call('e3', 'Edit', {'file_path': '/x/a', 'old_string': 'a', 'new_string': 'b'}),
                          call('e4', 'Edit', {'old_string': 'a', 'new_string': 'b'}),
                          result('e3', '<tool_use_error>String to replace not found in file.\nString: a'
                                       '</tool_use_error>', True)])
        e1, e2, e3, e4 = self.calls()
        self.assertEqual([e1['note'], e2['note'], e3['note']], ['Added 2 lines', 'Removed 1 line', 'Edit failed'])
        self.assertEqual(e3['out'], '2/46 String to replace not found in file.')
        self.assertEqual((e4['second'], e4.get('link')), ('file', None))

    def test_write_notes(self):
        self.open_seeded([call('w1', 'Write', {'file_path': '/x/a.txt', 'content': 'one\ntwo\nthree'}),
                          call('w2', 'Write', {'file_path': '/x/b.json', 'content': {'k': [1]}}),
                          call('w3', 'Write', {'file_path': '/x/c.txt', 'content': 'x'}),
                          result('w3', 'Error writing file', True)])
        w1, w2, w3 = self.calls()
        self.assertEqual((w1['note'], w1['pre'], w1['title']), ('3 lines', '3/13 one', 'Write a.txt'))
        self.assertEqual((w2['note'], w2['pre']), ('Write succeeded', '5/22 {'))
        self.assertEqual((w3['note'], w3['state'], w3['out'], w3.get('title')),
                         ('Write failed', 'failed', '1/18 Error writing file', None))

    def test_glob_and_grep_notes_open_their_output(self):
        self.start()
        self.scenario('glob run')
        glob, = self.calls()
        n = glob['row']
        drawn = self.drawn(n)[1]
        self.assertFalse([l for l in drawn if l.startswith('out ')], drawn)     # OUT only for its tab
        self.assertIn(6, self.buttons(n))                                       # the note is the button
        self.command('agent-row-click %d note' % (n + 1))
        self.assertIn(' active=Glob output ', self.command('print-state'))
        self.assertEqual(self.command('print-doc'), 'notes.txt\n<eod>\n')

    def test_webfetch_link_asks(self):
        self.start()
        self.scenario('tools')
        fetch, = self.by_name('Web Fetch')
        self.command('agent-row-click %d link' % (fetch['row'] + 1))
        palette = self.command('print-palette').splitlines()
        self.assertTrue(palette[0].startswith('choose=') and palette[0].endswith(
            'wants to open example.com in your browser: https://example.com'), palette[0])
        self.command('key Escape')

    def test_todo_items(self):
        self.open_seeded([call('t1', 'TodoWrite', {'todos': [{'content': 'one', 'status': 'completed'},
                                                             {'content': 'two', 'status': 'in_progress'},
                                                             {'content': 'three', 'status': 'pending'},
                                                             {'status': 'pending'}, 'junk']}),
                          call('t2', 'TodoWrite', {'todos': 'not a list'})])
        t1, t2 = self.calls()
        self.assertEqual((t1['name'], t1['todo']), ('Update Todos', ['[x] one', '[-] two', '[ ] three']))
        self.assertEqual(t2['name'], 'TodoWrite')                     # the generic form
        self.assertTrue(t2['in'].startswith('3/'), t2)

    def test_a_record_sent_again_is_dropped(self):
        self.start(env={'FAKE_CLAUDE_PRESERVED': '1'})
        self.scenario('auto')
        before = self.thread()
        self.command('agent-prompt /compact')
        self.command('wait-agent ready 15000')
        after = self.thread()
        self.assertEqual(after.count(chat.REPLY + 'done'), 1, after)
        self.assertEqual(after.count('tool(Bash) touch auto.txt'), 1, after)
        self.assertEqual(after[:len(before)], before)

    def test_blob_lines_do_not_double_calls(self):
        blob = {'type': 'api-request-blob', 'sessionId': 's1', 'hash': 'h', 'message': {'messages': [
            {'role': 'assistant', 'content': [{'type': 'tool_use', 'id': 'b1', 'name': 'Bash',
                                               'input': {'command': 'ls'}}]},
            {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': 'b1', 'content': 'x'}]}]}}
        copy = dict(call('b1', 'Bash', {'command': 'ls'}), type='api-request-blob')
        self.open_seeded([call('b1', 'Bash', {'command': 'ls'}), blob, copy, result('b1', 'a.py'), blob,
                          {'type': 'attachment', 'attachment': {'type': 'file'}}, reply('done')])
        rows = self.calls()
        self.assertEqual(len(rows), 1, rows)
        self.assertEqual((rows[0]['state'], rows[0]['out']), ('ok', '1/4 a.py'))
        self.assertEqual(self.thread(), ['user look', 'tool(Bash) ls', 'result a.py', 'agent(%s) done' % MODEL])

    def test_a_result_before_its_messages_next_call(self):
        self.start()
        self.scenario('read')
        self.command('agent-new claude')
        self.command('agent-prompt tools')
        self.command('wait-agent ready 15000')
        first, second = self.calls()[:2]
        self.assertEqual((first['second'], first['state']), ('notes.txt', 'ok'))
        self.assertEqual((second['second'], second['state']), ('a.py', 'ok'))
        lines = [json.loads(l) for l in self.file(self.sid()).read_text().splitlines()]
        kinds = [(l['type'], l['message']['content'][0]['type']) for l in lines
                 if l['type'] in ('user', 'assistant') and isinstance(l['message']['content'], list)][:5]
        self.assertEqual(kinds[1:], [('assistant', 'tool_use'), ('user', 'tool_result'), ('assistant', 'tool_use'),
                                     ('user', 'tool_result')])

    def test_plan_row_opens_the_plan_tab(self):
        self.start(self.claude_section('initial_mode = plan\n'))
        self.scenario('plan', cards=['2'])
        plan, = self.calls()
        self.assertEqual((plan['name'], plan['second'], plan['note'], plan['title']),
                         ('Claude’s Plan', 'fake.md', 'User approved the plan', 'Plan'))
        self.assertIn('md', plan['flags'])
        self.assertTrue(plan['in'].startswith('4/') and plan['in'].endswith('# Plan'), plan)
        self.assertNotIn('agent # Plan', self.thread())
        self.command('agent-row-click %d in' % (plan['row'] + 1))
        tabs = [l for l in self.command('print-mdtab').splitlines() if l.startswith('mdtab ')]
        self.assertEqual(len(tabs), 1, tabs)
        self.assertIn(' title=Plan ', tabs[0])
        self.assertIn(' comment=0', tabs[0])                       # no owner: no Comment

    def test_question_row_summary(self):
        self.start()
        self.scenario('ask2', cards=['2;3;submit'])
        ask, = self.calls()
        self.assertEqual((ask['name'], ask['note'], ask['state']), ('Questions', 'Answered · 2 questions', 'ok'))
        self.assertEqual(ask['out'], '2/%d Which language? → Go' % len('Which language? → Go\nWhich tools? → docker'
                                                                       .encode()))

    def test_mcp_header(self):
        self.start()
        self.scenario('mcp')
        mcp, = self.calls()
        self.assertEqual(mcp['name'], 'A Server With A Long Name [a_tool_whose_name_runs_past_sixty_four_bytes]')
        self.assertEqual((mcp['second'], mcp['out']), ('weather', '1/5 sunny'))
        self.assertNotIn('in', mcp)

    def test_generic_row_has_pretty_json(self):
        self.open_seeded([call('g1', 'Frobnicate', {'a': [1, 2], 'b': 'x'}), result('g1', 'did it')])
        g, = self.calls()
        self.assertEqual((g['name'], g['in'], g['out']), ('Frobnicate', '7/41 {', '1/6 did it'))
        self.command('agent-row-click %d in' % (g['row'] + 1))
        self.assertEqual(self.command('print-doc'), '{\n  "a": [\n    1,\n    2\n  ],\n  "b": "x"\n}\n<eod>\n')

    def test_denied_with_a_reason_is_a_note_and_no_out(self):
        self.open_seeded([call('d1', 'Bash', {'command': 'rm -rf x'}), result('d1', XB + 'too risky', True)])
        d, = self.calls()
        self.assertEqual((d['state'], d['note']), ('denied', 'Reason: too risky'))
        self.assertNotIn('out', d)

    def test_denied_without_a_reason_shows_nothing_and_is_denied(self):
        self.open_seeded([call('d1', 'Bash', {'command': 'rm -rf x'}), result('d1', YB, True)])
        d, = self.calls()
        self.assertEqual(d['state'], 'denied')
        self.assertNotIn('out', d)
        self.assertNotIn('note', d)

    def test_a_reason_over_2000_is_an_out(self):
        self.open_seeded([call('d1', 'Bash', {'command': 'x'}), result('d1', XB + 'r' * 2001, True)])
        d, = self.calls()
        self.assertEqual(d['state'], 'denied')
        self.assertNotIn('note', d)
        self.assertEqual(d['out'], '1/2001 ' + 'r' * 60)

    def test_tool_error_text(self):
        self.start()
        self.scenario('toolerror')
        read, edit = self.calls()
        self.assertEqual(read['state'], 'failed')
        self.assertIn('File does not exist.', read['out'])
        self.assertEqual((edit['state'], edit['note'], edit['out']),
                         ('failed', 'Edit failed', '2/57 String to replace not found in file.'))

    def test_running_then_done(self):
        self.start()
        self.command('agent-new claude')
        self.command('agent-prompt subagent')
        self.until(lambda: [c for c in self.calls() if c['state'] == 'running'], 'the agent call runs')
        agent, = self.calls()
        self.assertEqual((agent['name'], agent['second'], agent['flags']), ('Agent:', 'look around', {'parent', 'wait'}))
        self.command('wait-agent ready 15000')
        agent, = self.calls()
        self.assertEqual((agent['state'], agent['flags']), ('ok', {'parent'}))

    def test_a_stopped_turn_stops_its_calls(self):
        self.start()
        self.scenario('noid')
        rows = self.calls()
        self.assertEqual([c['state'] for c in rows], ['stopped', 'stopped'])
        self.reread()                                 # the file: stopped by nothing but a later prompt
        self.assertEqual([c['state'] for c in self.calls()], ['running', 'running'])

    def test_a_file_that_ends_in_a_call_keeps_it_running(self):
        self.open_seeded([call('c1', 'Bash', {'command': 'make'})])
        self.assertEqual(self.calls()[0]['state'], 'running')
        self.append_lines([result('c1', 'built')])
        self.until(lambda: self.calls()[0]['state'] == 'ok', 'its result reaches it')
        self.append_lines([call('c2', 'Bash', {'command': 'make again'}), prompt('next')])
        self.until(lambda: len(self.calls()) == 2 and self.calls()[1]['state'] == 'stopped', 'a prompt stops it')
        self.append_lines([result('c2', 'late')])
        self.until(lambda: self.calls()[1]['state'] == 'ok', 'a late result still reaches it')
        self.assertEqual(self.calls()[1]['out'], '1/4 late')

    def test_whole_text_comes_from_the_file(self):
        text = ''.join('line %06d of the output %s\n' % (i, 'x' * 30) for i in range(6000))
        self.open_seeded([call('c1', 'Bash', {'command': 'cat big'}), result('c1', text)])
        c, = self.calls(content=False)
        self.assertIn(' kept=', c['out'])
        kept = int(re.search(r' kept=(\d+)', c['out']).group(1))
        self.assertLessEqual(kept, 600)
        self.command('agent-row-click %d out' % (c['row'] + 1))
        doc = self.command('print-doc')
        self.assertEqual(doc, text + '\n<eod>\n')

    def test_initialize_has_the_two_flags(self):
        self.start()
        self.scenario('hello')
        request = self.stdin()[0]['request']
        self.assertEqual((request['perTaskStopAffordance'], request['forwardNestedSubagentToolCalls']), (True, True))
        self.assertEqual(list(request)[-2:], ['perTaskStopAffordance', 'forwardNestedSubagentToolCalls'])


# The fake's scenarios that make rows, with the cards their turn asks (agent-card words, ";" between the
# answers of one card) and the environment or config they need. Every one is compared stream to file.
PARITY = [
    ('tools', (), {}), ('read', (), {}), ('write', ('1',), {}), ('grep run', (), {}), ('glob run', (), {}),
    ('websearch run', (), {}), ('todo', (), {}), ('image', (), {}), ('toolerror', (), {}), ('denied', (), {}),
    ('hooks', (), {}), ('unknownblock', (), {}), ('echo', (), {}), ('think a short thought', (), {}),
    ('tool', ('1',), {}), ('tool2', ('1', '3'), {}), ('auto', (), {}), ('ran', (), {}), ('fails', (), {}),
    ('mcp', (), {}), ('other', ('1',), {}), ('ask2', ('2;3;submit',), {}), ('edit', ('1',), {}),
    ('fetch', ('1',), {}), ('pwsh', ('1',), {}), ('net', ('1',), {}), ('skill', ('1',), {}),
    ('project', ('1',), {}), ('glob', ('1',), {}), ('grep', ('1',), {}), ('websearch', ('1',), {}),
    ('noid', (), {}), ('subagent', (), {}), ('pending', ('3',), {}), ('withdraw', (), {}),
    ('apierror', (), {}), ('/context', (), {}), ('hello', (), {}), ('bg', (), {}),
    ('agent', (), {'until': 'The folder has a.py and notes.txt.'}),
]
# What a scenario may differ by between the stream and the file, each with the README finding that says why
# the CLI keeps it in one of the two only: (scenario, kind, what, finding). kind "drop": a row of the stream
# ("KIND TEXT") the file has no record for; kind "state": a call's state as the stream leaves it and as the
# file does. Nothing else may differ.
DIFFERENCES = [
    # a call that never got a result (no id: an unrecorded shape) is stopped when its turn ends; the file
    # ends in it, and a file's end stops nothing (finding 27: the file may still grow)
    ('noid', 'state', ('stopped', 'running'), 27),
    # a custom command: the stream's prompt row is the text rhun sent; the file keeps the command's echo
    # string instead ("<command-message>…", finding 31), whose row is task 8's
    ('echo', 'drop', 'user echo', 31),
    # a local command: the file has its caveat, the command's string and system/local_command, the stream a
    # <synthetic> reply (finding 31); the rows of the file's form are task 8's
    ('/context', 'drop', 'user /context', 31),
    ('/context', 'drop', 'agent ## Context Usage', 31),
    # the turn's error comes from the stream's result record, which the file never has (finding 27)
    ('apierror', 'drop', 'error API Error: Repeated 529 Overloaded errors', 27),
    # a request Claude withdrew: control_cancel_request is a stream record, never a line of the file
    # (finding 27: user, assistant and system lines only; C10)
    ('withdraw', 'drop', 'info Withdrawn by Claude', 27),
    # a subagent's calls: the stream gives them under their call; on disk they are in the agent's own file,
    # never in the conversation's (finding 34), read when its line is opened (task 11)
    ('agent', 'kids', 'Agent:', 34),
]


def blocks(dump):
    """print-agent-rows content as a list of rows, each its head without its index and its part lines."""
    out = []
    for line in dump.splitlines():
        if line.startswith(' '):
            out[-1].append(line)
        elif line:
            out.append([line.split(' ', 1)[1]])
    return out


class ParityTest(ToolCase):
    """The stream and the file give the same rows (print-agent-rows content), scenario by scenario."""

    def compare(self, name):
        live = blocks(self.command('print-agent-rows content'))
        self.reread()
        reread = blocks(self.command('print-agent-rows content'))
        dropped = False
        for scenario, kind, what, finding in DIFFERENCES:
            if scenario != name:
                continue
            if kind == 'kids':
                live = [[re.sub(r' kids=\d+$', ' kids=-', row[0])] + [l for l in row[1:] if not l.startswith('    ')
                                                                      and not l.startswith('  call ')]
                        if ' name=' + what + ' ' in row[0] else row for row in live]
            elif kind == 'state':
                live = [[line.replace(' state=' + what[0] + ' ', ' state=' + what[1] + ' ') for line in row]
                        for row in live]
            else:
                role, text = what.split(' ', 1)
                keep = [row for row in live if not (row[0].split(' ', 1)[0] == role and '  text ' + text in row)]
                self.assertEqual(len(keep), len(live) - 1, (name, what))
                live, dropped = keep, True
        if dropped:                                   # the prompts' places moved with the rows dropped
            live = [[re.sub(r' turn=\S+', '', line) for line in row] for row in live]
            reread = [[re.sub(r' turn=\S+', '', line) for line in row] for row in reread]
        self.assertEqual(reread, live, name)
        return '\n'.join(line for row in live for line in row)

    def test_rows_from_the_file_equal_rows_from_the_stream(self):
        self.start(self.claude_section('initial_mode = default\n'))
        for prompt, cards, more in PARITY:
            with self.subTest(prompt):
                self.scenario(prompt, cards)
                if 'until' in more:                   # the agent's own turn after its task ended
                    self.until(lambda: [r for r in self.thread() if r.endswith(more['until'])], prompt, 20)
                    self.command('wait-agent ready 15000')
                self.compare(prompt.split()[0])
        self.stop()
        self.start(self.claude_section('initial_mode = plan\n'))
        self.scenario('plan', ('2',))
        self.assertIn('Claude’s Plan', self.compare('plan'))
        self.stop()
        self.start(env={'FAKE_CLAUDE_TASKS': '1'})
        self.scenario('todo')
        self.compare('todo')

    def test_typed_rows_without_a_driver(self):
        self.start()
        self.scenario('tools')
        self.reread()
        rows = self.command('print-agent-rows content')
        starts = len(self.starts())
        self.stop()
        self.start(self.claude_section('chat = false\n'))
        self.open_listed()
        self.assertEqual(self.command('print-agent-rows content'), rows)
        self.assertEqual(len(self.starts()), starts)          # no process
        self.assertIn('state=off pid=0', self.live())

    def test_result_after_resync_is_dropped(self):
        self.start()
        self.command('agent-new claude')
        self.command('agent-prompt subagent')
        self.until(lambda: [c for c in self.calls() if c['state'] == 'running'], 'the agent call runs')
        self.command('agent-release')                 # the program ends while its call runs; its result may
        self.command('wait-agent off')                #   still come before it is gone
        self.until_gone()
        time.sleep(2)
        rows = self.command('print-agent-rows content')
        self.command('print-frames')
        self.stop()
        self.start(self.claude_section('chat = false\n'))
        self.open_listed()
        self.assertEqual(self.command('print-agent-rows content'), rows)

    def test_a_subagents_records_touch_no_usage_or_model(self):
        self.start(env={'FAKE_CLAUDE_CONTEXT': '50000'})
        self.scenario('auto')
        ctx = re.search(r' ctx=(\S+)', self.command('print-agent-live')).group(1)
        self.command('agent-prompt agent')
        self.until(lambda: [r for r in self.thread() if r.endswith('The folder has a.py and notes.txt.')],
                   'the agent ended and its turn replied', 20)
        self.command('wait-agent ready 15000')
        self.assertEqual(re.search(r' ctx=(\S+)', self.command('print-agent-live')).group(1), ctx)
        self.assertFalse([r for r in self.thread() if 'haiku' in r], self.thread())
        agent = self.by_name('Agent:')[0]
        self.assertEqual(agent['kids'], '2')                  # its two calls, children of its row
        self.assertEqual([r for r in self.thread() if r.startswith('tool(')], ['tool(Bash) touch auto.txt',
                                                                               'tool(Agent) List the files'])


class HostileTest(ToolCase):
    """Unknown, wrong and hostile input is harmless."""

    def test_huge_output(self):
        big = 'y' * (3 << 20)
        self.open_seeded([call('h1', 'Bash', {'command': 'yes'}), result('h1', big)])
        c, = self.calls(content=False)
        self.assertRegex(c['out'], r'^1/3145728 kept=600 ')

    def test_many_todos(self):
        todos = [{'content': 'item %d' % i, 'status': 'pending'} for i in range(100000)]
        self.open_seeded([call('t1', 'TodoWrite', {'todos': todos})])
        self.assertEqual(len(self.calls()[0]['todo']), 200)

    def test_deep_nesting_is_cut(self):
        value = 'x'
        for _ in range(150):
            value = [value]
        self.open_seeded([call('n1', 'Frob', {'v': value})])
        n, = self.calls()
        self.command('agent-row-click %d in' % (n['row'] + 1))
        self.assertIn('…', self.command('print-doc'))

    def test_duplicate_and_unknown_ids(self):
        self.open_seeded([call('d1', 'Bash', {'command': 'one'}), call('d1', 'Bash', {'command': 'two'}),
                          result('d1', 'out'), result('nobody', 'lost'), result('', 'no id'),
                          {'type': 'user', 'message': {'role': 'user', 'content': [{'type': 'tool_result'}]}}])
        one, two = self.calls()
        self.assertEqual((one['state'], two['state'], two['out']), ('running', 'ok', '1/3 out'))
        self.assertNotIn('lost', self.command('print-agent-rows'))

    def test_wrong_types_fall_back_to_generic(self):
        self.open_seeded([call('w1', 'Read', {'file_path': 7}), call('w2', 'Edit', {'file_path': [], 'old_string': 1}),
                          call('w3', 'TaskUpdate', {'taskId': '9', 'status': 'completed'}),
                          {'type': 'assistant', 'message': {'model': MODEL, 'content': 'a string'}},
                          {'type': 'assistant', 'message': {'model': MODEL, 'content': [7, {'type': 9}]}},
                          {'type': 'user', 'message': {'role': 'user', 'content': 5}}])
        w1, w2, w3 = self.calls()
        self.assertEqual((w1['name'], w1.get('second')), ('Read', None))
        self.assertEqual((w2['name'], w2['second']), ('Edit', 'file'))
        self.assertEqual(w3['name'], 'TaskUpdate')        # an unknown task: the generic form
        self.assertIn('in', w3)

    def test_bidi_and_controls_in_headers(self):
        self.open_seeded([call('b1', 'Bash', {'command': 'ls', 'description': 'a‮b\x1b[31mc\x07d⁦e'})])
        b, = self.calls()
        self.assertEqual(b['second'], 'abcde')

    def test_link_schemes(self):
        self.open_seeded([call('l1', 'WebFetch', {'url': 'javascript:alert(1)'}),
                          call('l2', 'WebFetch', {'url': 'file:///etc/passwd'}),
                          call('l3', 'Read', {'file_path': '../../etc/passwd'}),
                          call('l4', 'WebFetch', {'url': 'https://e.com/' + 'a' * 5000})])
        l1, l2, l3, l4 = self.calls()
        self.assertNotIn('link', l1)
        self.assertNotIn('link', l2)
        self.assertNotIn('link', l4)                       # past 4000 bytes: no link
        before = self.command('print-state')
        self.command('agent-row-click %d link' % (l3['row'] + 1))
        self.assertNotIn('passwd', self.command('print-state'))

    def test_a_changed_file_gives_the_preview(self):
        text = ''.join('row %d\n' % i for i in range(400))
        path = self.seed_lines([prompt('look'), call('c1', 'Bash', {'command': 'x'}), result('c1', text)])
        self.start()
        self.open_listed()
        c, = self.calls()
        path.write_text('{"type": "queue-operation"}\n' + path.read_text(), encoding='utf-8')   # lines moved
        self.command('agent-row-click %d out' % (c['row'] + 1))
        self.assertIn(CHANGED, self.command('print-toast'))
        self.assertTrue(self.command('print-doc').startswith('row 0\n'))


# ---- task 7: an edit's inline diff and a written file's text (agentdiff.s) ----

PART_PRE, PART_DIFF = 4, 5


def numbered(n, word, start=0):
    return ''.join('x%d = %d  # %s %d\n' % (i, i, word, i) for i in range(start, start + n))


class DiffCase(ToolCase):
    """A call's diff block as print-agent-row draws it and print-agent-rows keeps it."""

    def block(self, n):
        """Row n's (from 0) block as drawn in the last frame: its box (a dict: x, y, w, h and the words after
        it), its visual rows [(line, kind, x, y, w, syntax runs [(class, bytes)], text)], the "Click to
        expand" chip's box or None, and the row's buttons."""
        box, rows, expand = None, [], None
        for line in self.drawn(n)[1]:
            if line.startswith('diffbox '):
                words = line.split(' ')
                x, y, w, h = (int(v) for v in words[1].split(','))
                box = dict(dict(word.split('=', 1) for word in words[2:]), x=x, y=y, w=w, h=h)
                box = {k: int(v) if isinstance(v, str) and re.fullmatch(r'-?\d+', v) else v for k, v in box.items()}
            elif line.startswith('diff '):
                m = re.match(r'diff (\d+) (add|del|same) (-?\d+),(-?\d+),(\d+) syn=(\S*) ?(.*)$', line)
                self.assertTrue(m, line)
                runs = [tuple(int(v) for v in run.split(':')) for run in m.group(6).split(',') if run]
                rows.append((int(m.group(1)), m.group(2), int(m.group(3)), int(m.group(4)), int(m.group(5)),
                             runs, m.group(7)))
            elif line.startswith('expand '):
                expand = tuple(int(v) for v in line.split(' ')[1].split(','))
        return box, rows, expand, self.buttons(n)

    def kept(self, n, content=False):
        """print-agent-rows' diff lines of row n: the counts line and the lines kept ("- T", "+ T", "= T")."""
        _, parts = self.row_line(n, content)
        return [p for p in parts if p.startswith('diff ') or p[:2] in ('- ', '+ ', '= ') or p in ('-', '+', '=')]

    def metrics(self):
        """(the interface's points, the panel's text size)."""
        out = self.command('print-agents-metrics')
        return int(re.search(r'points=(\d+)', out).group(1)), int(re.search(r' px=(\d+)', out).group(1))

    def tabs(self):
        return [t for t in self.command('print-tabs').strip()[len('tabs='):].split(' | ') if t]

    def edit(self, tid, a, b, name='a.py', more=''):
        esc = lambda s: s.replace('\n', '\\n').replace('\t', '\\t').replace('\r', '\\r')
        self.tool('%s name=Edit second=%s link=%s a=%s b=%s flags=8 state=ok%s'
                  % (tid, name, name, esc(a), esc(b), more))


class DiffTest(DiffCase):
    """An Edit's two strings as an inline coloured diff, a Write's text coloured, clipped at 10 x MI_20 with a
    fade and "Click to expand" (UI 3.13: TTt @5253500, ITt @5253190), built once from what the row keeps."""

    def test_edit_shows_removed_and_added(self):
        (self.project / 'notes.txt').write_text('first line\nsecond\n', encoding='utf-8')
        self.start()
        self.scenario('edit', ('1',))
        row = self.by_name('Edit')[0]['row']
        self.assertEqual(self.kept(row), ['diff +1 -1', '- first line', '+ first line (edited)'])
        box, rows, expand, buttons = self.block(row)
        self.assertEqual([(r[0], r[1], r[6]) for r in rows], [(0, 'del', 'first line'),
                                                              (1, 'add', 'first line (edited)')])
        self.assertLess(rows[0][3], rows[1][3])
        points, size = self.metrics()
        self.assertEqual(box['h'], 2 * box['lh'] + mi(20, size))
        self.assertEqual((box['cut'], expand), (0, None))
        self.assertIn(PART_DIFF, buttons)            # the whole block opens the diff tab
        self.assertEqual(buttons[PART_DIFF][:4], (box['x'], box['y'], box['w'], box['h']))

    def test_identical_sides_show_no_signs(self):
        self.codex()
        self.edit('i', 'same\nlines', 'same\nlines')
        self.assertEqual(self.kept(self.base), ['diff +0 -0', '= same', '= lines'])
        _, rows, _, _ = self.block(self.base)
        self.assertEqual([r[1] for r in rows], ['same', 'same'])

    def test_a_cut_diff_opens_a_diff_tab_of_the_whole_sides(self):
        old = ''.join('old line %06d\n' % i for i in range(20000))       # about 300 KiB a side
        new = ''.join('new line %06d\n' % i for i in range(20000))
        big = (self.project / 'big.txt').as_posix()
        self.open_seeded([call('e1', 'Edit', {'file_path': big, 'old_string': old, 'new_string': new}),
                          result('e1', 'The file %s has been updated successfully.' % big, False,
                                 {'filePath': big, 'oldString': old, 'newString': new})])
        e, = self.calls(content=False)
        self.assertEqual(e['note'], 'Modified')
        kept = self.kept(e['row'])
        self.assertLessEqual(len(kept), 1 + 24)      # a preview of 12 lines a side
        box, rows, expand, buttons = self.block(e['row'])
        points, size = self.metrics()
        self.assertEqual((box['cut'], box['h']), (1, 10 * mi(20, size)))
        self.assertIsNotNone(expand)
        start = len(self.tabs())
        self.command('agent-row-click %d diff' % (e['row'] + 1))
        self.assertIn(' active=Diff View: big.txt ', self.command('print-state'))
        doc = self.command('print-doc')
        for text in ('old line 019999', 'new line 019999', 'old line 000000', 'new line 000000'):
            self.assertIn(text, doc)
        self.assertEqual(len(self.tabs()), start + 1)

    def test_diff_height_follows_the_font(self):
        for size in (8, 13, 32):
            if size != 8:                            # a rhun of its own for each size
                self.stop()
                self.tmp.cleanup()
                self.setUp()
            with self.subTest(size=size):
                self.codex('[agents]\nfont_size = %d\n' % size)
                points, px = self.metrics()
                self.assertEqual(px, size)
                self.edit('long', numbered(40, 'a'), numbered(40, 'b'))
                box, rows, expand, _ = self.block(self.base)
                self.assertEqual((box['h'], box['cut']), (10 * mi(20, size), 1))
                self.assertIsNotNone(expand)
                self.assertLessEqual(rows[-1][3] + box['lh'], box['y'] + box['h'])   # nothing below the block
                self.edit('short', 'one\n', 'two\n')
                box, rows, expand, _ = self.block(self.base + 1)
                self.assertEqual((box['h'], box['cut'], expand), (2 * box['lh'] + mi(20, size), 0, None))

    def test_colours_follow_the_file_name(self):
        self.codex()
        self.edit('p', 'def f():\n    pass', 'def g():\n    return 1', name='a.py')
        self.edit('z', 'def f():\n    pass', 'def g():\n    return 1', name='a.zzz')
        _, py, _, _ = self.block(self.base)
        _, zz, _, _ = self.block(self.base + 1)
        first = [r for r in py if r[6].startswith('def ')][0]
        self.assertNotEqual(first[5][0][0], 0, first)        # "def": the grammar's keyword class
        self.assertEqual(first[5][0][1], 3)
        for r in zz:
            self.assertEqual({c for c, _ in r[5]}, {0}, r)    # no grammar: plain

    def test_long_lines_wrap_at_240(self):
        self.codex('[ui]\nagents_width = 240\n')
        self.edit('w', 'x', 'word ' * 80)
        box, rows, expand, _ = self.block(self.base)
        added = [r for r in rows if r[1] == 'add']
        self.assertGreater(len(added), 3, rows)
        self.assertEqual({r[0] for r in added}, {1})          # one line, wrapped
        for r in rows:
            self.assertGreaterEqual(r[2], box['x'])
            self.assertLessEqual(r[2] + r[4], box['x'] + box['w'], (r, box))
        self.assertEqual([r[3] - added[0][3] for r in added[:3]], [0, box['lh'], 2 * box['lh']])

    def test_tabs_are_four_cells(self):
        self.codex()
        self.edit('t', '\tab', '    ab', name='a.zzz')
        _, rows, _, _ = self.block(self.base)
        tab, spaces = rows
        self.assertEqual((tab[1], spaces[1]), ('del', 'add'))
        self.assertLessEqual(abs(tab[4] - spaces[4]), 2, (tab, spaces))    # (a cell is the rounded advance)
        self.assertGreater(tab[4], 0)

    def test_crlf_binary_and_huge_lines(self):
        self.codex()
        self.edit('c', 'one\r\ntwo\r\n', 'one\r\nTWO\r\n', name='a.zzz')
        self.assertEqual(self.kept(self.base), ['diff +1 -1', '= one', '- two', '+ TWO'])
        self.edit('b', 'x', 'bin\\x01\\x02ary\\xff', name='a.bin')
        self.assertEqual(self.kept(self.base + 1)[2], '+ binary\ufffd')
        self.edit('h', 'x', 'y' * 40000, name='a.zzz')         # a streamed side: 16 KiB kept, cut
        box, rows, expand, _ = self.block(self.base + 2)
        self.assertEqual(box['cut'], 1)
        self.assertIsNotNone(expand)
        _, parts = self.row_line(self.base + 2)
        self.assertIn('diff +1 -1', parts)

    def test_written_file_is_coloured_and_clipped(self):
        text = ''.join('def f%d(x):\n    return x + %d\n' % (i, i) for i in range(20))
        path = (self.project / 'made.py').as_posix()
        self.open_seeded([call('w1', 'Write', {'file_path': path, 'content': text}),
                          result('w1', 'File created successfully at: ' + path, False,
                                 {'type': 'create', 'filePath': path, 'content': text, 'structuredPatch': [],
                                  'originalFile': None})])
        w, = self.calls(content=False)
        self.assertEqual((w['note'], w['pre']), ('41 lines', '40/%d def f0(x):' % len(text)))   # (split by LF)
        box, rows, expand, buttons = self.block(w['row'])
        points, size = self.metrics()
        self.assertEqual((box['cut'], box['h']), (1, 10 * mi(20, size)))
        self.assertEqual({r[1] for r in rows}, {'same'})
        self.assertNotEqual(rows[0][5][0][0], 0, rows[0])     # "def" coloured
        self.assertIsNotNone(expand)
        self.assertIn(PART_PRE, buttons)
        self.command('agent-row-click %d pre' % (w['row'] + 1))
        self.assertIn(' active=Write made.py ', self.command('print-state'))
        self.assertEqual(self.command('print-doc'), text + '\n<eod>\n')

    def test_a_diff_is_built_once(self):
        self.codex()
        self.edit('d', 'one\ntwo\n', 'one\nTWO\n')
        built = self.block(self.base)[0]['built']
        for i in range(120):
            self.command('agent-test-row meta a line below the diff %d' % i)
        self.command('key End')
        self.command('cmd focus_agents')
        self.command('key Home')
        self.assertEqual(self.block(self.base)[0]['built'], built, 'scrolled away and back')
        self.command('resize 1100 800')          # (W H: "WxH" reads as a height of 0)
        box = self.block(self.base)[0]
        self.assertEqual(box['built'], built, 'a width change')
        self.command('resize 1280 800')
        self.assertEqual(self.block(self.base)[0]['built'], built)
        self.edit('d', 'one\ntwo\n', 'one\nTHREE\n')         # its sides changed: built again
        self.assertEqual(self.kept(self.base)[2:], ['- two', '+ THREE'])

    def test_a_second_click_finds_the_diff_tab(self):
        self.codex()
        self.edit('d', 'one\n', 'two\n')
        start = len(self.tabs())
        self.command('agent-row-click %d diff' % (self.base + 1))
        self.assertIn(' active=Diff View: a.py ', self.command('print-state'))
        self.assertEqual(len(self.tabs()), start + 1)
        self.command('cmd focus_agents')
        self.command('agent-row-click %d diff' % (self.base + 1))
        self.assertEqual(len(self.tabs()), start + 1)
        self.command('cmd close_tab')
        self.assertEqual(len(self.tabs()), start)
        self.command('cmd focus_agents')
        self.command('agent-row-click %d diff' % (self.base + 1))
        self.assertEqual(len(self.tabs()), start + 1)

    def test_enter_on_a_diff_opens_its_tab(self):
        self.codex()
        self.edit('d', 'one\n', 'two\n')
        self.command('cmd focus_agents')
        self.command('key Up')
        self.command('key Return')
        self.assertIn(' active=Diff View: a.py ', self.command('print-state'))

    def test_diff_rows_fit(self):
        self.codex()
        self.edit('a', numbered(30, 'a'), numbered(30, 'b') + '\t' + 'long ' * 60 + '\n')
        self.tool('w name=Write second=made.py link=made.py note=40 lines title=Write made.py b=%s flags=4 state=ok'
                  % numbered(40, 'w').replace('\n', '\\n'))
        self.edit('s', 'x\n', 'y\n')
        blocks, current = [], None
        for line in self.command('print-agent-rows-fit').splitlines():
            if line.startswith('size='):
                current = (dict(w.split('=', 1) for w in line.split(' ')), [])
                blocks.append(current)
            else:
                current[1].append(line.strip())
        seen = 0
        for head, parts in blocks:
            if int(head['row']) < self.base:
                continue
            size, tw, h = int(head['size']), int(head['tw']), int(head['h'])
            boxes = {}
            for p in parts:
                words = p.split(' ')
                kind = words[0] if words[0] != 'button' else 'button' + words[1]
                x, y, w, hh = (int(v) for v in words[-1].split(','))
                self.assertGreaterEqual(x, 0, (head, p))
                self.assertLessEqual(x + w, tw, (head, p))
                self.assertLessEqual(y + hh, h, (head, p))
                boxes[kind] = (x, y, w, hh)
            diff = boxes['diff']
            seen += 1
            self.assertLessEqual(diff[3], 10 * mi(20, size), head)
            button = boxes.get('button%d' % PART_DIFF) or boxes.get('button%d' % PART_PRE)
            self.assertEqual(button, diff, head)
            self.assertGreaterEqual(button[3], mi(16, size) - 1, head)
            if 'expand' in boxes:                    # the chip inside the block
                ex = boxes['expand']
                self.assertTrue(diff[0] <= ex[0] and ex[0] + ex[2] <= diff[0] + diff[2] and
                                diff[1] <= ex[1] and ex[1] + ex[3] <= diff[1] + diff[3], (head, ex, diff))
            for kind, b in boxes.items():            # nothing else of the row in the block
                if kind in ('diff', 'expand') or kind.startswith('button'):
                    continue
                self.assertFalse(b[1] < diff[1] + diff[3] and diff[1] < b[1] + b[3], (head, kind, b, diff))
        self.assertEqual(seen, 25 * 34 * 3)

    def test_stream_and_file_give_the_same_diffs(self):
        """The fake's tools (an Edit, a replace_all, a Write of a new file and one over a file), edit, write and
        diffs (sides past a file row's preview): the same rows live and reread (ParityTest's rule)."""
        (self.project / 'notes.txt').write_text('first line\nsecond\n', encoding='utf-8')
        self.start(self.claude_section('initial_mode = default\n'))
        for prompt, cards in (('tools', ()), ('edit', ('1',)), ('write', ('1',)), ('diffs', ())):
            with self.subTest(prompt):
                self.scenario(prompt, cards)
                dump = ParityTest.compare(self, prompt)
                self.assertIn('diff +', dump) if prompt != 'write' else self.assertIn('pre ', dump)
        live = self.kept(self.by_name('Edit')[0]['row'], content=True)
        self.assertIn('- x3 = 3  # row 3', live)
        self.assertIn('+ x3 = 33  # row 3', live)
        # past the preview's last shared line nothing is known: no line is shown as removed that was only cut
        self.assertNotIn('- x10 = 10  # row 10', live)
        self.assertEqual(live[-1], '= x9 = 9  # row 9')
        self.assertLessEqual(len(live), 1 + 24)

    def test_a_thousand_edits_open_and_scroll_as_without_diffs(self):
        """The speed test: a conversation of 1,000 Edits (40 lines a side) opens and scrolls in the time one of
        1,000 Reads does; only the diffs in view are built."""
        times = {}
        for kind in ('Read', 'Edit'):
            lines = []
            for i in range(1000):
                tid = 'c%d' % i
                if kind == 'Edit':
                    lines.append(call(tid, 'Edit', {'file_path': '/x/f%d.py' % i, 'old_string': numbered(40, 'a', i),
                                                    'new_string': numbered(40, 'b', i)}))
                else:
                    lines.append(call(tid, 'Read', {'file_path': '/x/f%d.py' % i}))
                lines.append(result(tid, 'ok'))
                lines.append(reply('done %d' % i))
            self.seed_lines([prompt('look')] + lines)
            self.start()
            self.command('cmd focus_agents')
            self.command('wait-agents')
            began = time.monotonic()
            self.command('print-agents 1')
            self.command('print-frames')
            opened = time.monotonic() - began
            self.command('move 1100 400')
            began = time.monotonic()
            for _ in range(20):
                self.command('scroll -400')
            scrolled = (time.monotonic() - began) / 20
            self.command('cmd focus_agents')
            began = time.monotonic()
            self.command('key Home')
            home = time.monotonic() - began
            thread = dict(w.split('=', 1) for w in self.command('print-agent-thread').split())
            times[kind] = (opened, scrolled, home, thread)
            self.assertEqual(int(thread['rows']), 1 + 2000)      # the prompt, a call and a reply a turn
            if kind == 'Edit':
                first, last = int(thread['first']), int(thread['last'])
                n = next(i for i in range(first, last + 1) if self.drawn(i)[0].get('role') == 'tool')
                built = self.block(n)[0]['built']
                # the rows at the end, the 20 steps up and the first rows: never the thousand
                self.assertLess(built, 200, built)
            self.stop()
            self.tmp.cleanup()
            self.setUp()
        print('\nthousand: ' + '; '.join('%s rows %s open %.3f s, scroll step %.4f s, Home %.4f s, walked %s'
                                         % (k, v[3]['rows'], v[0], v[1], v[2], v[3]['walked'])
                                         for k, v in times.items()))
        (read_open, read_step, read_home, _), (edit_open, edit_step, edit_home, _) = times['Read'], times['Edit']
        self.assertLess(edit_open, read_open * 1.5 + 0.3, times)
        self.assertLess(edit_step, read_step * 1.5 + 0.02, times)
        self.assertLess(edit_home, read_home * 1.5 + 0.05, times)


# ---- thinking rows and todo lists (task 6): UI 3.10 (index.js aTt @5212014, the estimate's words AGe), 7.2
# (Ctrl+O, _o @5925806), the todo list (DTt @5267995); finding 29 (thinking) and 28 (the todo tools)

def thought(text, ms=None, display=None, kind='thinking'):
    """An assistant line of a conversation's file with one thinking block, as 2.1.330 writes it."""
    block = {'type': kind, 'thinking': text, 'signature': 'c2lnbmF0dXJl'} if kind == 'thinking' else \
        {'type': kind, 'data': 'c2lnbmF0dXJl'}
    line = {'type': 'assistant', 'message': {'model': MODEL, 'id': 'msg-t', 'role': 'assistant', 'content': [block]}}
    if ms is not None:
        line['thinkingDurationMs'] = ms
    if display is not None:
        line['thinkingDisplay'] = display
    return line


def todo_call(tid, *items):
    """A TodoWrite call of (status, content) items."""
    return call(tid, 'TodoWrite', {'todos': [{'content': c, 'status': s, 'activeForm': c} for s, c in items]})


class ThinkCase(ToolCase):
    """Thinking rows read through print-agent-rows, print-agent-row and print-agent-thread."""

    def thinks(self, content=False):
        """The open conversation's thinking rows: dicts of row, label, open, ms, tokens, live, h, text."""
        out = []
        for head, parts in self.rows_of('content' if content else ''):
            m = re.match(r'(\d+) thinking ', head)
            if not m:
                continue
            row = {'row': int(m.group(1)), 'text': None}
            label = re.search(r' label=(.*?)(?= open=| ms=)', head)
            row['label'] = label.group(1) if label else None
            for key in ('open', 'ms', 'tokens', 'live', 'h'):
                value = re.search(r' %s=(\S+)' % key, head)
                row[key] = None if not value else (None if value.group(1) == '-' else int(value.group(1)))
            for part in parts:
                if part.startswith('text '):
                    row['text'] = part[5:]
            out.append(row)
        return out

    def engine(self):
        line = self.command('print-agent-thread').strip()
        return dict(word.split('=', 1) for word in line.split(' '))

    def think_open(self):
        return self.engine()['think'] == '1'


class ThinkingTest(ThinkCase):
    """Thinking rows: a static line with the CLI's default display, a button that opens its Markdown with
    "summarized"; one open state for all of them (a click, Enter, Ctrl+O, the command)."""

    def test_default_display_is_a_static_row(self):
        self.start()
        self.command('agent-new claude')
        self.command('agent-prompt thinkslow 2500')
        self.until(lambda: [t for t in self.thinks() if t['live'] and t['tokens'] >= 200], 'thinking streams')
        t, = self.thinks()
        self.assertRegex(t['label'], r'^Thinking\.\.\. · \d+ tokens$')
        self.assertEqual(t['text'], None)
        self.assertEqual(self.buttons(t['row']), {})                 # no text: no button
        self.assertIn('thinking(live) ', self.thread())
        self.command('wait-agent ready 15000')
        t, = self.thinks()
        self.assertEqual(t['live'], 0)
        self.assertGreaterEqual(t['ms'], 2000)
        self.assertEqual(t['label'], 'Thought for %ds' % ((t['ms'] + 500) // 1000))
        self.assertEqual(self.buttons(t['row']), {})
        self.assertIn('thinking(%ds) ' % ((t['ms'] + 500) // 1000), self.thread())
        live = self.rows_of('content')
        self.reread()
        self.assertEqual(self.rows_of('content'), live)
        t, = self.thinks()
        self.assertEqual(self.buttons(t['row']), {})

    def test_summarized_text_streams_and_opens(self):
        self.start()
        self.scenario('think A **bold** idea')
        t, = self.thinks()
        self.assertEqual((t['text'], t['label'], t['ms']), ('A **bold** idea', 'Thought for 3s', 3109))
        self.assertIn(7, self.buttons(t['row']))                     # PART_TOGGLE
        closed = self.drawn(t['row'])[1]
        self.assertFalse([l for l in closed if 'bold idea' in l], closed)
        self.command('agent-row-click %d toggle' % (t['row'] + 1))
        self.assertTrue(self.think_open())
        t2, = self.thinks()
        self.assertEqual(t2['open'], 1)
        self.assertGreater(t2['h'], t['h'])
        opened = self.drawn(t['row'])[1]
        self.assertTrue([l for l in opened if l.startswith('para ') and 'bold idea' in l], opened)
        self.reread()
        t3, = self.thinks()
        self.assertEqual(t3['text'], 'A **bold** idea')
        self.assertIn(7, self.buttons(t3['row']))

    def stdin_order(self):
        """(index of the first set_max_thinking_tokens with "summarized", index of the first prompt) in what
        the fake read"""
        lines = self.stdin()
        ask = [i for i, m in enumerate(lines) if m.get('type') == 'control_request' and
               m['request'].get('subtype') == 'set_max_thinking_tokens']
        prompt = [i for i, m in enumerate(lines) if m.get('type') == 'user']
        return [lines[i]['request'] for i in ask], ask[:1], prompt[:1]

    def test_summaries_are_asked_at_a_start_when_the_setting_says_so(self):
        local = self.project / '.claude'
        local.mkdir()
        (local / 'settings.local.json').write_text(json.dumps({'showThinkingSummaries': True}), encoding='utf-8')
        self.start()
        self.chat('hello')
        asked, first, prompt = self.stdin_order()
        self.assertEqual([(a['max_thinking_tokens'], a.get('thinking_display')) for a in asked],
                         [(31999, 'summarized')])
        self.assertLess(first[0], prompt[0])
        self.stop()
        (local / 'settings.local.json').write_text(json.dumps({}), encoding='utf-8')
        self.start()
        self.chat('hello')
        self.assertEqual(self.stdin_order()[0][1:], [])           # the second start asked nothing
        asked = [m for m in self.stdin() if m.get('type') == 'control_request' and
                 m['request'].get('subtype') == 'set_max_thinking_tokens']
        self.assertEqual(len(asked), 1, asked)                     # (the first start's)

    def test_thinking_without_a_duration(self):
        self.start()
        self.scenario('think')
        t, = self.thinks()
        self.assertEqual((t['label'], t['ms'], t['text']), ('Thinking', None, None))
        self.assertIn('thinking(-) ', self.thread())

    def test_click_opens_all(self):
        self.open_seeded([thought('first idea', 1200, 'summarized'), reply('one'),
                          thought('second idea', 800, 'summarized'), reply('two')])
        a, b = self.thinks()
        self.assertEqual((a['label'], b['label']), ('Thought for 1s', 'Thought for 1s'))
        self.command('agent-row-click %d' % (a['row'] + 1))
        a2, b2 = self.thinks()
        self.assertEqual((a2['open'], b2['open']), (1, 1))
        self.assertGreater(b2['h'], b['h'])
        self.command('agent-row-click %d toggle' % (b['row'] + 1))
        self.assertEqual([t['open'] for t in self.thinks()], [0, 0])
        self.assertEqual([t['h'] for t in self.thinks()], [a['h'], b['h']])

    def test_enter_on_the_focused_row(self):
        self.open_seeded([thought('an idea', 1200, 'summarized'), reply('one'), thought('', 900), reply('two')])
        self.command('cmd focus_agents')
        self.command('key Down')
        self.assertEqual(self.engine()['focus'], '1')               # the first row with an action
        self.command('key Down')
        self.assertEqual(self.engine()['focus'], '1')               # a thinking row without text has none
        self.command('key Return')
        self.assertTrue(self.think_open())
        self.command('key space')
        self.assertFalse(self.think_open())

    def test_ctrl_o_in_the_panel_and_in_the_box(self):
        self.start()
        self.scenario('think a thought')
        self.command('cmd focus_agents')
        self.command('key ctrl+o')
        self.assertTrue(self.think_open())
        self.command('key ctrl+o')
        self.assertFalse(self.think_open())
        self.command('key Tab')
        self.assertIn(' focus=1 ', self.command('print-agent-input'))
        self.command('type ab')
        self.command('key ctrl+o')
        self.assertTrue(self.think_open())
        self.assertTrue(self.command('print-agent-input').startswith('input=ab focus=1 '),
                        self.command('print-agent-input'))
        self.command('agent-focus editor')
        self.command('key ctrl+o')                                  # the editor's: Open File
        self.assertTrue(self.think_open())
        self.assertTrue(self.command('print-palette').startswith('field='), self.command('print-palette'))
        self.command('key Escape')
        self.command('cmd agents_toggle_thinking')                  # the palette's command
        self.assertFalse(self.think_open())

    def test_the_command_in_the_palette_and_a_when_clause(self):
        self.start(extra='[keys]\nctrl+shift+u = agents_toggle_thinking when agentsFocus\n')
        self.scenario('think a thought')
        self.command('cmd command_palette')
        self.command('type Expand or Collapse Thinking')
        self.assertIn('Agents: Expand or Collapse Thinking', self.command('print-palette'))
        self.command('key Escape')
        self.command('agent-focus editor')
        self.command('key ctrl+shift+u')
        self.assertFalse(self.think_open())                         # the clause does not hold
        self.command('cmd focus_agents')
        self.command('key ctrl+shift+u')
        self.assertTrue(self.think_open())

    def test_open_thinking_is_markdown_and_parsed_once(self):
        self.open_seeded([thought('# Plan\n\nFirst **check** the `code`.\n\n- one\n- two', 2000, 'summarized'),
                          reply('done')])
        t, = self.thinks()
        n = t['row'] + 1
        before = int(self.drawn(t['row'])[0]['parses'])
        self.command('cmd agents_toggle_thinking')
        head, lines = self.drawn(t['row'])
        self.assertEqual(head['parsed'], '1')
        self.assertTrue([l for l in lines if l.startswith('heading:1 Plan')], lines)
        self.assertTrue([l for l in lines if l.strip().startswith('item ') and 'one' in l], lines)
        parses = int(head['parses'])
        self.assertEqual(parses, before + 1)
        for _ in range(3):
            self.command('print-frames')
        self.command('resize 1100x800')
        self.command('resize 1280x800')
        self.assertEqual(int(self.drawn(t['row'])[0]['parses']), parses)
        self.command('agent-row-click %d' % n)                       # closed and open again: kept
        self.command('agent-row-click %d' % n)
        self.assertEqual(int(self.drawn(t['row'])[0]['parses']), parses)

    def test_opening_another_conversation_closes_them(self):
        self.open_seeded([thought('an idea', 1200, 'summarized'), reply('one')])
        self.command('cmd agents_toggle_thinking')
        self.assertTrue(self.think_open())
        self.command('cmd focus_agents')
        self.command('key Escape')                                  # back to the list
        self.command('print-agents 1')
        self.assertFalse(self.think_open())
        self.assertEqual(self.thinks()[0]['open'], 0)

    def test_thinking_from_the_file(self):
        self.open_seeded([thought('', 2400, 'updates'), reply('one'),
                          thought('Weighing it.', 3109, 'summarized'), reply('two'),
                          thought('', None, kind='redacted_thinking'), reply('three'),
                          dict(thought('a subagent thinks', 100), isSidechain=True)])
        a, b, c = self.thinks()
        self.assertEqual((a['label'], a['text'], a['ms']), ('Thought for 2s', None, 2400))
        self.assertEqual((b['label'], b['text']), ('Thought for 3s', 'Weighing it.'))
        self.assertEqual((c['label'], c['text'], c['ms']), ('Thinking', None, None))
        self.assertEqual(self.buttons(a['row']), {})
        self.assertIn(7, self.buttons(b['row']))
        self.assertEqual(self.buttons(c['row']), {})
        self.assertEqual(self.thread()[1:], ['thinking(2s) ', 'agent(%s) one' % MODEL, 'thinking(3s) Weighing it.',
                                             'agent two', 'thinking(-) ', 'agent three'])

    def test_toggle_keeps_the_view(self):
        lines = []
        for i in range(60):
            lines += [prompt('step %d' % i), thought('An idea about step %d.\n\nIt has **two** paragraphs.' % i,
                                                     1000 + i, 'summarized'), reply('reply %d' % i)]
        self.seed_lines(lines)
        self.start()
        self.open_listed()
        self.command('cmd focus_agents')
        self.command('key Home')
        for _ in range(12):
            self.command('key PageDown')
        before = self.engine()['anchor']
        self.assertNotEqual(before, '-')
        self.command('key ctrl+o')
        self.assertTrue(self.think_open())
        self.assertEqual(self.engine()['anchor'], before)
        self.command('key ctrl+o')
        self.assertEqual(self.engine()['anchor'], before)


class TodoTest(ThinkCase):
    """A todo list in its call's row: a box an item (empty, a dash for the active one, a check for a done one,
    its text struck through and muted), the text wrapped at the row's width."""

    def items(self, n):
        """The todo lines row n was drawn with: (state mark, x, y, w, h, text)."""
        out = []
        for line in self.drawn(n)[1]:
            m = re.match(r'todo (\[.\]) (-?\d+),(-?\d+),(-?\d+),(-?\d+) ?(.*)$', line)
            if m:
                out.append((m.group(1),) + tuple(int(v) for v in m.group(2, 3, 4, 5)) + (m.group(6),))
        return out

    def test_boxes_and_strike(self):
        self.open_seeded([todo_call('t1', ('completed', 'Read the notes'), ('in_progress', 'Write the code'),
                                    ('pending', 'Run the tests'))])
        c, = self.calls()
        self.assertEqual(c['todo'], ['[x] Read the notes', '[-] Write the code', '[ ] Run the tests'])
        items = self.items(c['row'])
        self.assertEqual([(i[0], i[5]) for i in items], [('[x]', 'Read the notes'), ('[-]', 'Write the code'),
                                                         ('[ ]', 'Run the tests')])
        metrics = self.command('print-agents-metrics')
        ui = int(re.search(r'points=(\d+)', metrics).group(1))
        px = int(re.search(r' px=(\d+)', metrics).group(1))
        xs = {i[1] for i in items}
        self.assertEqual(len(xs), 1, items)                          # the texts in one column
        tops = [i[2] for i in items]
        self.assertEqual(tops, sorted(tops))
        self.assertGreaterEqual(tops[1] - tops[0], items[0][4])       # one under the other
        checks = [tuple(int(v) for v in l.split(' ')[1].split(','))
                  for l in self.drawn(c['row'])[1] if l.startswith('check ')]
        self.assertEqual(len(checks), 3, checks)
        for (x, y, w, h), item in zip(checks, items):
            self.assertEqual((w, h), (mi(14, px, ui), mi(14, px, ui)))
            self.assertLess(x + w, item[1])                         # the box left of its text
            self.assertLess(abs(y - item[2]), item[4])

    def test_a_later_list_is_its_own_row(self):
        self.open_seeded([todo_call('t1', ('in_progress', 'a'), ('pending', 'b')), result('t1', 'ok'),
                          reply('working'),
                          todo_call('t2', ('completed', 'a'), ('in_progress', 'b')), result('t2', 'ok')])
        first, second = self.calls()
        self.assertEqual((first['todo'], second['todo']), (['[-] a', '[ ] b'], ['[x] a', '[-] b']))
        self.assertEqual(self.engine()['todo'], str(second['row']))
        self.assertEqual([i[0] for i in self.items(first['row'])], ['[-]', '[ ]'])
        self.assertEqual([i[0] for i in self.items(second['row'])], ['[x]', '[-]'])

    def test_task_tools_give_the_list_as_it_stands(self):
        self.start(env={'FAKE_CLAUDE_TASKS': '1'})
        self.scenario('todo')
        lists = [c for c in self.calls() if c['name'] == 'Update Todos']
        self.assertEqual(len(lists), 4, lists)
        fourth = lists[3]
        self.assertEqual([(i[0], i[5]) for i in self.items(fourth['row'])], [('[x]', 'a'), ('[ ]', 'b'),
                                                                             ('[ ]', 'c')])
        self.assertEqual(self.engine()['todo'], str(fourth['row']))
        self.reread()
        again = [c for c in self.calls() if c['name'] == 'Update Todos'][3]
        self.assertEqual([(i[0], i[5]) for i in self.items(again['row'])], [('[x]', 'a'), ('[ ]', 'b'),
                                                                            ('[ ]', 'c')])
        self.assertEqual(self.engine()['todo'], str(again['row']))

    def test_todo_rows_fit(self):
        long = 'a todo item whose words run on for a while so that it wraps at any panel width ' * 3
        self.open_seeded([todo_call('t1', ('completed', long), ('in_progress', 'short'), ('pending', long)),
                          thought('Some thinking text that wraps when it is open in a narrow panel. ' * 4, 1500,
                                  'summarized'), thought('', 700)])
        self.command('cmd agents_toggle_thinking')
        ui = int(re.search(r'points=(\d+)', self.command('print-agents-metrics')).group(1))
        blocks, current = [], None
        for line in self.command('print-agent-rows-fit').splitlines():
            if line.startswith('size='):
                current = (dict(w.split('=', 1) for w in line.split(' ')), [])
                blocks.append(current)
            else:
                current[1].append(line.strip())
        self.assertEqual(len(blocks), 25 * 34 * 3)
        seen = set()
        for head, parts in blocks:
            size, tw, h = int(head['size']), int(head['tw']), int(head['h'])
            boxes = []
            for p in parts:
                words = p.split(' ')
                kind = words[0] if words[0] != 'button' else 'button' + words[1]
                seen.add(kind)
                x, y, w, hh = (int(v) for v in words[-1].split(','))
                self.assertGreaterEqual(x, 0, (head, p))
                self.assertLessEqual(x + w, tw, (head, p))
                self.assertLessEqual(y + hh, h, (head, p))
                if kind.startswith('button'):
                    self.assertGreaterEqual(hh, mi(16, size, ui) - 1, (head, p))
                boxes.append((kind, x, y, w, hh))
            texts = [b for b in boxes if not b[0].startswith('button')]
            buttons = [b for b in boxes if b[0].startswith('button')]
            for group in (texts, buttons):
                for i, a in enumerate(group):
                    for b in group[i + 1:]:
                        overlap = (a[1] < b[1] + b[3] and b[1] < a[1] + a[3] and
                                   a[2] < b[2] + b[4] and b[2] < a[2] + a[4] and a[3] and b[3] and a[4] and b[4])
                        self.assertFalse(overlap, (head, a, b))
        self.assertTrue({'todo', 'check', 'label', 'button7', 'text'} <= seen, seen)


class ThinkParityTest(ThinkCase):
    """ParityTest's comparison for the thinking scenarios (PARITY has `think TEXT` and `todo` in both forms)."""

    compare = ParityTest.compare

    def test_thinking_rows_from_the_file_equal_rows_from_the_stream(self):
        self.start()
        for prompt in ('think', 'think A **bold** idea', 'thinkslow 600', 'tool2', 'slow'):
            with self.subTest(prompt):
                if prompt == 'tool2':
                    self.scenario(prompt, ('1', '1'))
                else:
                    self.scenario(prompt)
                dump = self.compare(prompt.split()[0])
                self.assertIn('thinking ', dump)


if __name__ == '__main__':
    unittest.main()
