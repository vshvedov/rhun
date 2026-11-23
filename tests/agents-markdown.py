#!/usr/bin/env python3
"""Replies in the agents panel are drawn as Markdown: their blocks as the panel lays them out, the
user's own prompts plain, a reply growing in place (a code fence cut in half by the stream) ends as
the same document a whole one parses to, file links open the file at their line, a width change
lays the rows out again, and replies are parsed only once they come into view, the rows in view
staying where they were."""
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
EXE = Path(os.environ.get('RHUN_TEST_EXE', ROOT / 'build/rhun')).resolve()

REPLY = '\n'.join([
    '## Plan',
    '',
    'Some **bold** and *slanted* words, with `code` too.',
    '',
    '- the first step',
    '- the second step',
    '',
    '| name | size |',
    '| --- | --- |',
    '| a | 1 |',
    '| b | 2 |',
    '',
    '```python',
    'def main():',
    '    return 1',
    '```',
    '',
    'See [the source](src/main.c:3) and [the docs](https://example.com/docs).',
])


def record(role, content, cwd):
    if role == 'user':
        return {'type': 'user', 'message': {'role': 'user', 'content': content}, 'cwd': cwd,
                'sessionId': 's1'}
    return {'type': 'assistant', 'message': {'role': 'assistant',
                                             'content': [{'type': 'text', 'text': content}]}}


@unittest.skipIf(os.name == 'nt', 'the control socket is Unix only')
class AgentsMarkdown(unittest.TestCase):
    def setUp(self):
        # a socket's path is short (104 bytes on macOS): the folder under /tmp
        self.tmp = tempfile.TemporaryDirectory(prefix='rhun-agmd-', dir='/tmp')
        self.work = Path(self.tmp.name).resolve()
        self.project = self.work / 'project'
        (self.project / 'src').mkdir(parents=True)
        (self.project / 'src/main.c').write_text(''.join('line %d\n' % i for i in range(1, 41)),
                                                  encoding='utf-8')
        (self.project / 'notes.txt').write_text('one\ntwo\nthree\nfour\n', encoding='utf-8')
        self.config = self.work / 'config/rhun/config'
        self.config.parent.mkdir(parents=True)
        self.write_config(380)
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith('CLAUDE') and not k.startswith('ANTHROPIC')}
        self.env.update(HOME=str(self.work), XDG_CONFIG_HOME=str(self.work / 'config'),
                        XDG_STATE_HOME=str(self.work / 'state'), GIT_CONFIG_NOSYSTEM='1')
        slug = re.sub(r'[^A-Za-z0-9]', '-', self.project.as_posix())
        self.sessions = self.work / '.claude/projects' / slug
        self.sessions.mkdir(parents=True)
        self.process = self.client = self.reader = None

    def tearDown(self):
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        for closable in (self.reader, self.client):
            if closable is not None:
                closable.close()
        self.tmp.cleanup()

    def write_config(self, width):
        self.config.write_text('[files]\nrestore_session = false\nrestore_project = false\n'
                               '[updates]\ncheck = false\n[git]\nenabled = false\n'
                               '[editor]\ncursor_blink = false\n'
                               '[ui]\nsidebar = false\nagents_panel = true\nagents_width = %d\n'
                               % width, encoding='utf-8')

    def session(self, name, turns, age=0):
        """a Claude transcript of (role, text) turns; age: seconds it is older than now"""
        cwd = self.project.as_posix()
        lines = [json.dumps(record(role, text, cwd)) for role, text in turns]
        lines.append(json.dumps({'type': 'custom-title', 'customTitle': name, 'sessionId': name}))
        path = self.sessions / (name + '.jsonl')
        path.write_text('\n'.join(lines) + '\n', encoding='utf-8')
        if age:
            stamp = time.time() - age
            os.utime(path, (stamp, stamp))
        return path

    def start(self, size='1280x800'):
        control = self.work / 'control'
        self.process = subprocess.Popen([str(EXE), str(self.project), '--headless', size,
                                         '--scale', '1', '--control', str(control)], env=self.env,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.client.settimeout(30)
        deadline = time.monotonic() + 15
        while True:
            try:
                self.client.connect(str(control))
                break
            except (FileNotFoundError, ConnectionRefusedError):
                if self.process.poll() is not None or time.monotonic() > deadline:
                    self.fail('editor did not start')
                time.sleep(0.01)
        self.reader = self.client.makefile('r', encoding='utf-8')
        self.command('wait-agents')

    def command(self, line):
        self.client.sendall((line + '\n').encode('utf-8'))
        output = []
        while True:
            reply = self.reader.readline()
            if reply == 'ok\n':
                return ''.join(output)
            self.assertNotIn(reply, ('', 'error\n'), line)
            output.append(reply)

    def open(self, title):
        listing = self.command('print-agents').splitlines()
        rows = [line for line in listing if line.startswith('Claude: ')]
        index = rows.index('Claude: ' + title) + 1
        self.command('print-agents %d' % index)
        self.command('wait 50')

    def row(self, n):
        """print-agent-row N: (header fields, the block lines)"""
        lines = self.command('print-agent-row %d' % n).splitlines()
        self.assertTrue(lines and lines[0].startswith('row='), lines)
        header = dict(field.split('=', 1) for field in lines[0].split())
        return header, lines[1:]

    def blocks(self, n):
        """the block lines without where the links were drawn"""
        return [re.sub(r' at -?\d+ -?\d+$', '', line) for line in self.row(n)[1]]

    def test_a_reply_is_drawn_as_its_blocks(self):
        self.session('s1', [('user', 'Please make **x** bold'), ('assistant', REPLY)])
        self.start()
        self.open('s1')
        header, _ = self.row(2)
        self.assertEqual((header['role'], header['parsed']), ('agent', '1'), header)
        self.assertEqual(self.blocks(2), [
            'heading:2 Plan',
            'para Some bold and slanted words, with code too.',
            'list 2 items',
            '  item the first step',
            '  item the second step',
            'table 3x2',
            'code:python 2 lines',
            'para See the source and the docs.',
            'link the source -> src/main.c:3',
            'link the docs -> https://example.com/docs',
        ])
        # the user's own prompt stays plain, and print-agents keeps the source text of both
        self.assertEqual(self.row(1)[1], ['plain Please make **x** bold'])
        listing = self.command('print-agents')
        self.assertIn('user Please make **x** bold\n', listing)
        self.assertIn('agent ## Plan\n', listing)

    def test_a_reply_streamed_in_pieces_ends_as_one_code_block(self):
        self.session('s1', [('user', 'go'), ('assistant', 'Start')])
        self.start()
        self.open('s1')
        self.assertEqual(self.blocks(2), ['para Start'])
        # the fence arrives cut in half, its language too, and its closing fence a byte at a time
        self.command('agent-test-append \\n\\n``')
        self.command('agent-test-append `py')
        self.assertEqual(self.blocks(2), ['para Start', 'code:py 0 lines'])
        self.command('agent-test-append thon\\nprint(1)\\npri')
        self.assertEqual(self.blocks(2), ['para Start', 'code:python 2 lines'])
        self.command('agent-test-append nt(2)\\n`')
        self.command('agent-test-append `')
        self.command('agent-test-append `\\nafter it')
        self.assertEqual(self.blocks(2), ['para Start', 'code:python 2 lines', 'para after it'])
        self.assertIn('agent Start\n', self.command('print-agents'))

    def test_many_small_appends_keep_the_document_and_the_height_right(self):
        self.session('whole', [('user', 'go'), ('assistant', REPLY)], age=60)
        self.session('grown', [('user', 'go'), ('assistant', 'x')])
        self.start()
        self.open('whole')
        expected_blocks = self.blocks(2)
        expected_height = self.row(2)[0]['height']
        self.open('grown')
        self.command('print-frames')
        parses = int(self.row(2)[0]['parses'])
        # the reply becomes REPLY a few bytes at a time ("x" first: "x" then "## Plan" makes no
        # heading, so the first piece takes it out by starting again on a line of its own)
        text = '\n\n' + REPLY
        pieces, start = [], 0
        while start < len(text):
            # the command line loses blanks at a piece's ends: cut between two other bytes
            end = min(start + 7, len(text))
            while end < len(text) and ' ' in text[end - 1:end + 1]:
                end += 1
            pieces.append(text[start:end])
            start = end
        for piece in pieces:
            self.command('agent-test-append ' + piece.replace('\n', '\\n'))
        frames = int(self.command('print-frames').split('=')[1])
        header, _ = self.row(2)
        self.assertEqual(self.blocks(2), ['para x'] + expected_blocks)
        # parsed at most once a frame drawn
        self.assertLessEqual(int(header['parses']) - parses, frames)
        self.assertGreater(int(header['parses']) - parses, 0)
        # its height is the whole reply's, and an extra paragraph's ("x")
        self.assertGreater(int(header['height']), int(expected_height))

    def test_clicking_a_file_link_opens_the_file_at_its_line(self):
        reply = ('Look at [main](src/main.c:12), [the notes](notes.txt#L3), '
                 '[the absolute one](%s:5-7) and [nothing](missing/file.c:2).'
                 % (self.project / 'src/main.c').as_posix())
        self.session('s1', [('user', 'where?'), ('assistant', reply)])
        self.start()
        self.open('s1')
        links = [line for line in self.row(2)[1] if line.startswith('link ')]
        self.assertEqual(len(links), 4, links)
        where = {}
        for line in links:
            match = re.match(r'link (.*) -> (.*) at (-?\d+) (-?\d+)$', line)
            self.assertIsNotNone(match, line)
            where[match.group(1)] = (int(match.group(3)), int(match.group(4)))
        for name, path, line in (('main', 'src/main.c', 12), ('the notes', 'notes.txt', 3),
                                 ('the absolute one', 'src/main.c', 5)):
            self.command('click %d %d' % where[name])
            self.command('wait 50')
            state = self.command('print-state')
            self.assertIn(' active=%s line=%d ' % (Path(path).name, line), state, name)
            self.assertIn(' focus=0 ', state, name)
            self.command('cmd focus_agents')
        self.command('click %d %d' % where['nothing'])
        self.command('wait 50')
        self.assertIn('No such file: missing/file.c:2', self.command('print-toast'))

    def links_at(self, n):
        where = {}
        for line in self.row(n)[1]:
            match = re.match(r'link (.*) -> (.*) at (-?\d+) (-?\d+)$', line)
            if match:
                where[match.group(1)] = (int(match.group(3)), int(match.group(4)))
        return where

    def test_file_uris_open_the_file(self):
        main = (self.project / 'src/main.c').as_posix()
        notes = (self.project / 'notes.txt').as_posix()
        spaced = self.project / 'a b.txt'
        spaced.write_text('x\ny\n', encoding='utf-8')
        reply = ('See [at a line](file://%s#L12), [whole](file://%s), [spaced](file://%s:2) and '
                 '[on a host](file://localhost%s#L4).'
                 % (main, notes, spaced.as_posix().replace(' ', '%20'), main))
        self.session('s1', [('user', 'where?'), ('assistant', reply)])
        self.start()
        self.open('s1')
        where = self.links_at(2)
        self.assertEqual(len(where), 4, where)
        for name, path, line in (('at a line', 'main.c', 12), ('whole', 'notes.txt', 1),
                                 ('spaced', 'a b.txt', 2), ('on a host', 'main.c', 4)):
            self.command('click %d %d' % where[name])
            self.command('wait 50')
            state = self.command('print-state')
            self.assertIn(' active=%s line=%d ' % (path, line), state, name)
            self.command('cmd focus_agents')

    def test_an_encoded_hash_or_colon_stays_in_the_name(self):
        # the line suffix is split from the text as written, then the path decoded: %23 and %3A are part of
        # the file's name; a name written with a # in it still opens
        for name in ('a#b.txt', 'a:b.txt', 'c d.txt'):
            (self.project / name).write_text(''.join('l%d\n' % i for i in range(1, 6)), encoding='utf-8')
        spaced = (self.project / 'c d.txt').as_posix().replace(' ', '%20')
        reply = ('[hash](a%%23b.txt), [colon](a%%3Ab.txt), [hash at 3](a%%23b.txt#L3), [plain](src/main.c:12), '
                 '[uri](file://%s:2) and [raw](a#b.txt).' % spaced)
        self.session('s1', [('user', 'where?'), ('assistant', reply)])
        self.start()
        self.open('s1')
        where = self.links_at(2)
        self.assertEqual(len(where), 6, where)
        for name, path, line in (('hash', 'a#b.txt', 1), ('raw', 'a#b.txt', 1), ('colon', 'a:b.txt', 1),
                                 ('hash at 3', 'a#b.txt', 3), ('plain', 'main.c', 12), ('uri', 'c d.txt', 2)):
            self.command('click %d %d' % where[name])
            self.command('wait 50')
            state = self.command('print-state')
            self.assertIn(' active=%s line=%d ' % (path, line), state, name)
            self.command('cmd focus_agents')

    def test_only_rhun_file_links_to_files_are_followed(self):
        other = self.work / 'other'
        other.mkdir()
        (other / 'x.txt').write_text('x\n', encoding='utf-8')
        reply = ('[ext](rhun://ext/someone/thing), [install](rhun://extension/someone/thing), '
                 '[folder](rhun://file/%s) and [file](rhun://file/%s).'
                 % (other.as_posix(), (other / 'x.txt').as_posix()))
        self.session('s1', [('user', 'where?'), ('assistant', reply)])
        self.start()
        self.open('s1')
        where = self.links_at(2)
        self.assertEqual(len(where), 4, where)
        before = self.command('print-state')
        for name in ('ext', 'install', 'folder'):
            self.command('click %d %d' % where[name])
            self.command('wait 50')
            self.assertEqual(self.command('print-state'), before, name)
            self.assertEqual(self.command('print-toast').strip(), 'toast=', name)
        self.command('click %d %d' % where['file'])
        self.command('wait 50')
        self.assertIn(' active=x.txt ', self.command('print-state'))

    def test_a_width_change_lays_the_rows_out_again(self):
        self.session('s1', [('user', 'go'), ('assistant', REPLY + '\n\n' + 'a long line of words ' * 30)])
        self.start()
        self.open('s1')
        wide, _ = self.row(2)
        self.command('resize 500x800')       # the editor keeps 240: the panel gives way
        self.command('wait 50')
        narrow, _ = self.row(2)
        self.assertGreater(int(narrow['height']), int(wide['height']))
        self.assertGreater(int(narrow['content']), int(wide['content']))
        self.assertEqual(narrow['parsed'], '1')

    def test_replies_are_parsed_as_they_come_into_view_and_the_rows_stay_put(self):
        reply = '# Step {0}\n\n- one\n- two\n\n```sh\necho {0}\necho done\n```\n\nThat is step {0}.'
        turns = []
        for i in range(40):
            turns.append(('user', 'step %d' % i))
            turns.append(('assistant', reply.format(i)))
        self.session('s1', turns)
        self.start()
        self.open('s1')
        last = 80
        rows = {n: self.row(n)[0] for n in range(1, last + 1)}
        shown = [n for n in rows if rows[n]['y'] != '-1']
        self.assertIn(last, shown)
        # the replies above the view were never parsed: their plain text stands in
        top = min(shown)
        hidden = [n for n in range(2, top, 2)]
        self.assertTrue(hidden, shown)
        self.assertTrue(all(rows[n]['parsed'] == '0' for n in hidden), rows)
        self.assertTrue(all(rows[n]['parsed'] == '1' for n in shown if n % 2 == 0), rows)
        # up: the replies coming into view are parsed, the rows already in view move by the wheel
        # alone; down again: they come back where they were
        self.command('move 1100 400')
        self.command('scroll -300')
        after = {n: self.row(n)[0] for n in range(1, last + 1)}
        newly = [n for n in hidden if after[n]['parsed'] == '1']
        self.assertTrue(newly, 'scrolling up parsed nothing')
        self.assertTrue(any(after[n]['height'] != rows[n]['height'] for n in newly),
                        'the estimates were exact: nothing to keep in place')
        # 300 px of wheel at the default sensitivity and scale 1, no more, no less
        both = [n for n in shown if after[n]['y'] != '-1']
        self.assertTrue(both, (shown, after))
        for n in both:
            self.assertEqual(int(after[n]['y']) - int(rows[n]['y']), 300,
                             'row %d jumped when a reply above it was parsed' % n)
        self.command('scroll 300')
        for n in shown:
            self.assertEqual(self.row(n)[0]['y'], rows[n]['y'], n)

if __name__ == '__main__':
    unittest.main()
