#!/usr/bin/env python3
"""rhun's in-process MCP server for Claude Code's chat (phase 4 task 9), against the
fake CLI (tests/scripts/fake-claude.py), over the control socket. It imports tests/claude-chat.py for its
cases: every rhun gets its own HOME and XDG folders and an environment without CLAUDE* or ANTHROPIC*
variables; the fake's config folder is the test's HOME, so nothing here writes the user's own Claude Code
settings. The real claude is never started.

ToolsTest: initialize's server and note, the handshake (FAKE_CLAUDE_MCP=nomanifest), getDiagnostics (the
Problems store joined with the extensions' marks of open documents: the echo test extension), the JSON-RPC
errors, the CLI's notifications, a CLI without the server. HooksTest (task 10): saving before a read or an
edit, the problems that are new after an edit, the waits and their bounds, the diagnostics row."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location('claude_chat', ROOT / 'tests/claude-chat.py')
chat = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(chat)

EXTS = ROOT / 'tests/ext/exts'
# the SHA-256 of rhun's note (claude_mcp.s `note`, docs/guide.md prints it whole)
NOTE_SHA = '2fc12b1fda3731ccb2e22b9688c027d089d55ce8d0dd913882f34ff06594c251'
NOTIFIED = {'mcp_response': {'jsonrpc': '2.0', 'result': {}, 'id': 0}}
SCHEMA = {'type': 'object', 'properties': {
    'uri': {'type': 'string', 'description': 'file:// URI of the one file to check. Omit to get every file '
            'that has at least one diagnostic (at or above `minSeverity`, when given).'},
    'minSeverity': {'type': 'string', 'enum': ['Error', 'Warning', 'Information', 'Hint'],
                    'description': 'Include only diagnostics at least this severe. From most to least severe: '
                    'Error, Warning, Information, Hint. Omit to include every severity.'}},
    'additionalProperties': False, '$schema': 'http://json-schema.org/draft-07/schema#'}


class McpCase(chat.DrivenCase):
    """A project with a.py (ten lines) and notes.txt; rhun optionally with the echo test extension."""

    def setUp(self):
        super().setUp()
        self.a = self.project / 'a.py'
        self.a.write_text(''.join('line %d\n' % i for i in range(1, 11)), encoding='utf-8')
        self.notes = self.project / 'notes.txt'
        self.notes.write_text('alpha\nbravo\ncharlie\ndelta\necho\n', encoding='utf-8')

    def start_ext(self, extra='', env=None, exts=EXTS):
        """rhun as ChatCase.start makes it, with the extensions of exts (default: the echo test extension)."""
        self.config.write_text(self.BASE + self.claude_section() + extra, encoding='utf-8')
        control = self.work / 'control'
        if control.exists():
            control.unlink()
        self.process = subprocess.Popen([str(chat.EXE), str(self.project), '--headless', '1280x800', '--scale', '1',
                                         '--extensions', str(exts), '--control', str(control)],
                                        env=dict(self.env, **(env or {})),
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.client.settimeout(30)
        deadline = time.monotonic() + 10
        while True:
            try:
                self.client.connect(str(control))
                break
            except (FileNotFoundError, ConnectionRefusedError):
                if self.process.poll() is not None or time.monotonic() > deadline:
                    self.fail('editor did not start')
                time.sleep(0.01)
        self.reader = self.client.makefile('r', encoding='utf-8')

    def mcp(self, message):
        """agent-mcp: the server's answer to a JSON-RPC message (parsed), or None for a notification."""
        out = self.command('agent-mcp ' + (message if isinstance(message, str) else json.dumps(message))).strip()
        return None if out == 'none' else json.loads(out)

    def call(self, args=None, name='getDiagnostics'):
        """A tools/call's result."""
        params = {'name': name}
        if args is not None:
            params['arguments'] = args
        return self.mcp({'jsonrpc': '2.0', 'id': 7, 'method': 'tools/call', 'params': params})['result']

    def diags(self, args=None):
        """getDiagnostics' list (the call must succeed; its text is compact JSON)."""
        result = self.call(args or {})
        self.assertFalse(result.get('isError'), result)
        text = result['content'][0]['text']
        self.assertEqual(text, json.dumps(json.loads(text), separators=(',', ':'), ensure_ascii=False))
        return json.loads(text)

    def problem(self, path, line, col, sev, source, message, code=None, end=None):
        extra = (' code=' + code if code else '') + (' end=%d:%d' % end if end else '')
        self.assertEqual(self.command(f'agent-test-problem {path} {line} {col} {sev} {source}{extra} {message}'),
                         'kept\n')

    def tools(self):
        first = self.command('print-agent-tools').splitlines()[0]
        return {k: (int(v) if v.isdigit() else v) for k, v in (w.split('=', 1) for w in first.split(' '))}

    def initialize(self):
        return [r['initialize'] for r in self.records() if 'initialize' in r]

    def logged(self, key):
        return [r[key] for r in self.records() if key in r]

    def mcp_log(self):
        return self.logged('mcp')

    def sent(self, subtype):
        return [r['sent'] for r in self.records() if 'sent' in r and r['sent']['subtype'] == subtype]

    def answered_ids(self):
        return {m['response'].get('request_id') for m in self.stdin() if m.get('type') == 'control_response'}

    def uri(self, path):
        return 'file://' + str(path)


class ToolsTest(McpCase):
    def test_initialize_declares_the_server_and_the_note(self):
        self.start()
        self.chat('hello')
        init = self.initialize()[0]
        self.assertEqual(init['sdkMcpServers'], ['rhun'])
        manifest = init['sdkMcpServerManifests']['rhun']
        self.assertEqual(manifest['initializeResult']['protocolVersion'], '2025-11-25')
        self.assertEqual(manifest['initializeResult']['serverInfo']['name'], 'rhun')
        self.assertEqual(manifest['initializeResult']['capabilities'], {'tools': {'listChanged': True}})
        tool, = manifest['toolsListResult']['tools']
        self.assertEqual(tool['name'], 'getDiagnostics')
        self.assertEqual(tool['inputSchema'], SCHEMA)
        self.assertEqual(tool['annotations'], {'title': 'Get diagnostics', 'readOnlyHint': True})
        note = init['appendSystemPrompt']
        self.assertTrue(note.startswith('\n# rhun Editor Context\n'), note[:60])
        self.assertEqual(hashlib.sha256(note.encode('utf-8')).hexdigest(), NOTE_SHA)
        self.assertNotIn('VS Code', note)
        self.assertNotIn('VSCode', note)
        self.assertIn('mcp__rhun__getDiagnostics', note)
        self.assertIs(init['systemPromptSnapshot'], True)
        # the manifest saved the handshake: no mcp_message at all (finding 45)
        self.assertEqual(self.sent('mcp_message'), [])
        self.assertEqual(self.tools()['asked'], 0)

    def test_the_handshake_is_answered(self):
        self.start(env={'FAKE_CLAUDE_MCP': 'nomanifest'})
        self.chat('hello')
        self.until(lambda: len(self.mcp_log()) >= 3, 'the handshake')
        init, notified, listed = self.mcp_log()[:3]
        self.assertEqual(init['method'], 'initialize')
        self.assertEqual(init['answer'], {'mcp_response': {'jsonrpc': '2.0', 'id': 0, 'result': {
            'protocolVersion': '2025-11-25', 'capabilities': {'tools': {'listChanged': True}},
            'serverInfo': {'name': 'rhun', 'version': init['answer']['mcp_response']['result']['serverInfo']['version']}}}})
        self.assertEqual(notified['method'], 'notifications/initialized')
        self.assertEqual(notified['answer'], NOTIFIED)
        self.assertEqual(listed['method'], 'tools/list')
        tools = listed['answer']['mcp_response']['result']['tools']
        self.assertEqual([t['name'] for t in tools], ['getDiagnostics'])
        self.assertEqual(listed['answer']['mcp_response']['id'], 1)
        self.assertEqual(self.tools()['asked'], 3)

    def test_requests_before_the_initialize_answer_are_served(self):
        # the CLI asks before it answers initialize (finding 44): rhun's answer goes before anything rhun
        # writes only after the initialize answer (r2, get_settings)
        self.start(env={'FAKE_CLAUDE_MCP': 'nomanifest'})
        self.chat('hello')
        first = self.sent('mcp_message')[0]['id']
        lines = self.stdin()
        at = next(i for i, m in enumerate(lines) if m.get('type') == 'control_response'
                  and m['response'].get('request_id') == first)
        r2 = next(i for i, m in enumerate(lines) if m.get('request_id') == 'r2')
        self.assertLess(at, r2)

    def test_tools_list_has_get_diagnostics(self):
        self.start()
        listed = self.mcp({'jsonrpc': '2.0', 'id': 'x', 'method': 'tools/list'})
        self.assertEqual(listed['id'], 'x')
        tool, = listed['result']['tools']
        self.assertEqual(tool['name'], 'getDiagnostics')
        self.assertTrue(tool['description'].startswith('Get the errors, warnings and other diagnostics rhun currently '
                                                       'shows in its Problems panel'), tool['description'])
        self.assertNotIn('VS Code', tool['description'])
        self.assertTrue(tool['description'].endswith("Only files in the project's folders are listed."))
        self.assertEqual(tool['inputSchema'], SCHEMA)
        self.assertEqual(tool['annotations'], {'title': 'Get diagnostics', 'readOnlyHint': True})
        init = self.mcp({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2024-11-05'}})
        self.assertEqual(init['result']['protocolVersion'], '2024-11-05')
        init = self.mcp({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '1999-01-01'}})
        self.assertEqual(init['result']['protocolVersion'], '2025-11-25')
        self.assertEqual(self.mcp({'jsonrpc': '2.0', 'id': 2, 'method': 'ping'}), {'jsonrpc': '2.0', 'id': 2, 'result': {}})

    def test_get_diagnostics_for_all_files_and_for_one(self):
        self.start()
        self.assertEqual(self.diags(), [])
        self.problem(self.a, 4, 12, 'error', 'python', 'invalid syntax', code='E999', end=(4, 13))
        self.problem(self.notes, 2, 1, 'warning', 'spell', 'Unknown word: bravo')
        outside = self.work / 'outside.c'
        self.problem(outside, 1, 1, 'error', 'cc', 'not in the project')
        listed = self.diags()
        self.assertEqual(listed, [
            {'uri': self.uri(self.a), 'diagnostics': [{'message': 'invalid syntax', 'severity': 'Error', 'range': {
                'start': {'line': 3, 'character': 11}, 'end': {'line': 3, 'character': 12}},
                'source': 'python', 'code': 'E999'}]},
            {'uri': self.uri(self.notes), 'diagnostics': [{'message': 'Unknown word: bravo', 'severity': 'Warning',
                'range': {'start': {'line': 1, 'character': 0}, 'end': {'line': 1, 'character': 0}},
                'source': 'spell'}]}])
        self.assertEqual(self.diags({'uri': self.uri(self.notes)}), listed[1:])
        # open, the file says how many lines it has
        self.command(f'open {self.a}')
        one = self.diags({'uri': self.uri(self.a)})
        self.assertEqual(one[0]['linesInFile'], 11)
        self.assertEqual(one[0]['diagnostics'], listed[0]['diagnostics'])
        self.command('agent-test-problems-clear')
        self.assertEqual(self.diags(), [])

    def test_one_clean_file_has_its_empty_entry(self):
        self.start()
        self.assertEqual(self.diags({'uri': self.uri(self.notes)}), [{'uri': self.uri(self.notes), 'diagnostics': []}])
        self.command(f'open {self.notes}')
        self.assertEqual(self.diags({'uri': self.uri(self.notes)}),
                         [{'uri': self.uri(self.notes), 'linesInFile': 6, 'diagnostics': []}])
        self.assertEqual(self.diags(), [])          # without uri: only files with problems

    def test_min_severity(self):
        self.start()
        for sev in ('error', 'warning', 'info', 'hint'):
            self.problem(self.a, 1, 1, sev, 'lint', 'a ' + sev)
        self.problem(self.notes, 1, 1, 'hint', 'lint', 'only a hint')
        def messages(args):
            return [(e['uri'].rsplit('/', 1)[1], [d['message'] for d in e['diagnostics']]) for e in self.diags(args)]
        self.assertEqual(messages({}), [('a.py', ['a error', 'a warning', 'a info', 'a hint']), ('notes.txt', ['only a hint'])])
        self.assertEqual(messages({'minSeverity': 'Warning'}), [('a.py', ['a error', 'a warning'])])
        self.assertEqual(messages({'minSeverity': 'Error'}), [('a.py', ['a error'])])
        self.assertEqual(messages({'minSeverity': 'Information'}), [('a.py', ['a error', 'a warning', 'a info'])])
        # with uri the file's entry stays, empty
        self.assertEqual(messages({'minSeverity': 'Error', 'uri': self.uri(self.notes)}), [('notes.txt', [])])
        bad = self.call({'minSeverity': 'Fatal'})
        self.assertTrue(bad['isError'])
        self.assertEqual(bad['content'][0]['text'], 'minSeverity must be Error, Warning, Information or Hint')

    def test_store_and_marks_are_joined_once(self):
        self.start_ext()
        (self.project / 'a.txt').write_text('hello world\nsecond line\n', encoding='utf-8')
        self.command(f'open {self.project / "a.txt"}')
        self.command('cmd echo.diag')
        self.command('wait-ext echo running')
        self.until(lambda: 'a note' in self.command('print-marks'), 'the extension marks')
        a_txt = self.uri(self.project / 'a.txt')
        listed = self.diags()
        self.assertEqual(listed, [{'uri': a_txt, 'linesInFile': 3, 'diagnostics': [
            {'message': 'first word', 'severity': 'Error', 'range': {'start': {'line': 0, 'character': 0},
                                                                     'end': {'line': 0, 'character': 5}},
             'source': 'rhun-tests/echo'},
            {'message': 'second word', 'severity': 'Warning', 'range': {'start': {'line': 1, 'character': 0},
                                                                        'end': {'line': 1, 'character': 6}},
             'source': 'rhun-tests/echo'},
            {'message': 'a note', 'severity': 'Information', 'range': {'start': {'line': 1, 'character': 7},
                                                                      'end': {'line': 1, 'character': 11}},
             'source': 'rhun-tests/echo'}]}])
        # the store holds one of them too (same range, severity and message): listed once, from the store
        self.problem(self.project / 'a.txt', 1, 1, 'error', 'lint', 'first word', code='W1', end=(1, 6))
        # and another with the same range and a message that differs: both
        self.problem(self.project / 'a.txt', 2, 8, 'info', 'lint', 'a note, longer', end=(2, 12))
        messages = [(d['message'], d.get('source'), d.get('code')) for d in self.diags()[0]['diagnostics']]
        self.assertEqual(messages, [('first word', 'lint', 'W1'), ('a note, longer', 'lint', None),
                                    ('second word', 'rhun-tests/echo', None), ('a note', 'rhun-tests/echo', None)])
        # a message of 900 bytes the store and its mark both hold: one entry, whole
        long = 'x' * 890 + ' long tail'
        self.problem(self.a, 3, 1, 'warning', 'lint', long, end=(3, 5))
        self.command(f'open {self.a}')
        self.until(lambda: 'lint' in self.command('print-marks'), 'the store mark')
        entry = self.diags({'uri': self.uri(self.a)})[0]
        self.assertEqual([d['message'] for d in entry['diagnostics']], [long])

    def test_a_marks_tip_is_still_cut(self):
        self.start()
        long = ('é' * 150) + ' tail that is not shown'
        self.problem(self.a, 2, 1, 'error', 'lint', long, end=(2, 5))
        self.command(f'open {self.a}')
        marks = self.until(lambda: [l for l in self.command('print-marks').splitlines() if 'lint' in l], 'the mark')
        shown = marks[0].split(' problems:lint ', 1)[1]
        self.assertEqual(len(shown.encode()), 200)         # cut at 200 bytes, at a character's start
        self.assertEqual(shown, 'é' * 100)
        self.assertEqual(self.diags()[0]['diagnostics'][0]['message'], long)

    def test_positions_are_from_zero(self):
        self.start()
        self.a.write_text('x = 1\né\U0001d11e y\n', encoding='utf-8')
        self.problem(self.a, 2, 'c3', 'error', 'chars', 'counted in characters', end=(2, 4))
        self.problem(self.a, 2, 5, 'error', 'bytes', 'counted in bytes')
        closed = [d['range'] for d in self.diags()[0]['diagnostics']]
        self.assertEqual(closed, [{'start': {'line': 1, 'character': 2}, 'end': {'line': 1, 'character': 3}},
                                  {'start': {'line': 1, 'character': 4}, 'end': {'line': 1, 'character': 4}}])
        self.command(f'open {self.a}')
        opened = [d['range'] for d in self.diags()[0]['diagnostics']]
        # é is one UTF-16 unit, the clef two: the third character starts at unit 3
        self.assertEqual(opened[0], {'start': {'line': 1, 'character': 3}, 'end': {'line': 1, 'character': 4}})
        self.assertEqual(opened[1], closed[1])

    def test_uri_forms_and_a_uri_that_names_no_file(self):
        self.start()
        self.problem(self.a, 1, 1, 'error', 'lint', 'in a')
        def one(uri):
            return [d['message'] for e in self.diags({'uri': uri}) for d in e['diagnostics']]
        self.assertEqual(one(self.uri(self.a)), ['in a'])
        self.assertEqual(one(str(self.a)), ['in a'])
        self.assertEqual(one('a.py'), ['in a'])                     # under the conversation's checkout
        self.assertEqual(one('./a.py'), ['in a'])
        self.assertEqual(one('file://' + str(self.project) + '/%61.py'), ['in a'])     # %XX decoded
        for uri, said in (('http://example.com/x', 'uri must name a file'), ('', 'uri must name a file'),
                          ('/etc/hosts', "uri must name a file in the project's folders"),
                          ('../outside.txt', "uri must name a file in the project's folders"),
                          (str(self.project / '..' / 'project' / 'a.py'), "uri must name a file in the project's folders"),
                          ('a' * 100000, 'uri must name a file')):
            with self.subTest(uri[:40]):
                out = self.call({'uri': uri})
                self.assertTrue(out['isError'])
                self.assertEqual(out['content'][0]['text'], said)
        for args in ([1, 2], 'text', {'uri': 5}, {'uri': None}):
            with self.subTest(args=args):
                out = self.mcp({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call',
                                'params': {'name': 'getDiagnostics', 'arguments': args}})['result']
                self.assertTrue(out['isError'])

    def test_ten_thousand_problems(self):
        self.start()
        self.assertEqual(self.command('agent-test-problems 10000'), 'kept=10000\n')
        listed = self.diags()
        self.assertEqual(len(listed), 100)
        self.assertEqual(sum(len(e['diagnostics']) for e in listed), 10000)
        self.assertEqual(listed[0]['diagnostics'][0]['message'], 'problem 0')
        took = self.tools()['took_us']
        self.assertLess(took, 50000, took)
        # and through the wire: one line, within the connection's limit
        self.chat('hello')

    def test_an_unknown_tool_and_an_unknown_method(self):
        self.start()
        self.assertEqual(self.mcp({'jsonrpc': '2.0', 'id': 3, 'method': 'tools/call', 'params': {'name': 'nope'}}),
                         {'jsonrpc': '2.0', 'id': 3, 'error': {'code': -32602, 'message': 'Unknown tool: nope'}})
        self.assertEqual(self.mcp({'jsonrpc': '2.0', 'id': 4, 'method': 'resources/list'}),
                         {'jsonrpc': '2.0', 'id': 4, 'error': {'code': -32601, 'message': 'Method not found'}})
        invalid = {'jsonrpc': '2.0', 'id': None, 'error': {'code': -32600, 'message': 'Invalid Request'}}
        for message in ('[{"jsonrpc":"2.0","id":1,"method":"ping"}]', '{"jsonrpc":"2.0","id":{"a":1},"method":"ping"}',
                        '{"jsonrpc":"2.0","id":1}', '"text"', 'not json'):
            with self.subTest(message):
                self.assertEqual(self.mcp(message), invalid)
        self.assertIsNone(self.mcp({'jsonrpc': '2.0', 'method': 'notifications/cancelled', 'params': {'requestId': 6}}))

    def test_an_unknown_server(self):
        self.start()
        self.chat('unhandled')
        answers = self.logged('unhandled')[0]
        self.assertEqual(answers[1], {'behavior': 'error', 'message': 'unknown server'})

    def test_the_clis_notifications_are_answered_and_change_nothing(self):
        self.start(env={'FAKE_CLAUDE_MCP': 'nomanifest'})
        self.chat('hello')
        before = self.thread()
        self.command('agent-prompt notify')
        self.command('wait-agent ready')
        notes = [m for m in self.mcp_log() if m['method'] in ('experiment_gates', 'file_updated')]
        self.assertEqual([m['answer'] for m in notes], [NOTIFIED, NOTIFIED])
        self.assertEqual(self.thread(), before + ['user notify', 'agent notified'])
        self.assertEqual(self.notes.read_text(encoding='utf-8'), 'alpha\nbravo\ncharlie\ndelta\necho\n')

    def test_the_calls_row(self):
        self.start()
        self.problem(self.a, 4, 12, 'error', 'python', 'invalid syntax', code='E999', end=(4, 13))
        self.chat('diag', 'waiting')
        card = self.command('print-agent-card')
        self.assertIn('mcp__rhun__getDiagnostics', card)
        self.command('agent-card 1')
        self.command('wait-agent ready')
        call = [m for m in self.mcp_log() if m['method'] == 'tools/call'][0]
        text = call['answer']['mcp_response']['result']['content'][0]['text']
        self.assertEqual(json.loads(text)[0]['uri'], self.uri(self.a))
        self.assertIs(call['answer']['mcp_response']['result']['isError'], False)
        rows = self.thread()
        self.assertTrue(any(r.startswith('tool(mcp__rhun__getDiagnostics)') for r in rows), rows)
        self.assertEqual(rows[-1], chat.REPLY + 'The diagnostics tool returned 1 entry.')
        self.assertEqual(self.tools()['calls'], 1)
        out = self.command('print-agent-row %d' % next(i + 1 for i, r in enumerate(rows) if r.startswith('tool(mcp__')))
        self.assertIn(' Rhun [getDiagnostics]', out)            # phase 3's form of an MCP tool's row
        self.assertIn('out 0 [{"uri":"file://', out)            # its OUT: the JSON the server answered

    def test_an_older_cli_without_the_server(self):
        self.start(env={'FAKE_CLAUDE_MCP': 'off'})
        self.chat('hello')
        self.assertEqual(self.thread()[-1], chat.REPLY + 'ok: hello')
        self.command('agent-prompt diag')
        self.command('wait-agent ready')
        self.assertEqual(self.thread()[-1], 'agent There is no getDiagnostics tool.')
        tools = self.tools()
        self.assertEqual((tools['calls'], tools['asked'], tools['lists']), (0, 0, 0))

    def test_late_and_failed_answers_do_not_stop_a_turn(self):
        for knob in ('slow', 'error'):
            with self.subTest(knob):
                self.start(env={'FAKE_CLAUDE_MCP': knob, 'FAKE_CLAUDE_MCP_WAIT_MS': '5000'})
                self.chat('hello', ms=15000)
                self.assertEqual(self.thread()[-1], chat.REPLY + 'ok: hello')
                if knob == 'error':
                    self.until(lambda: len(self.mcp_log()) >= 5, 'the extra requests')
                    errors = {m['method']: m['answer']['mcp_response'].get('error', {}).get('code')
                              for m in self.mcp_log()}
                    self.assertEqual(errors['resources/list'], -32601)
                    self.assertEqual(errors['no/such-method'], -32601)
                self.quit()
                self.fake_log.unlink()

    def test_every_request_is_answered_or_cancelled(self):
        self.start(env={'FAKE_CLAUDE_MCP': 'nomanifest'})
        self.chat('diag', 'waiting')
        self.command('agent-stop')
        self.command('wait-agent ready')
        self.command('agent-prompt diag')
        self.command('wait-agent waiting')
        self.command('agent-card 1')
        self.command('wait-agent ready')
        sent = [s['id'] for s in self.sent('mcp_message')]
        self.assertGreaterEqual(len(sent), 4)
        self.assertEqual(set(sent) - self.answered_ids(), set())

    def test_nothing_is_read_until_asked(self):
        self.start()
        self.problem(self.a, 1, 1, 'error', 'lint', 'something')
        self.chat('hello')
        self.command(f'open {self.a}')
        tools = self.tools()
        self.assertEqual((tools['calls'], tools['asked'], tools['lists']), (0, 0, 0))


if __name__ == '__main__':
    unittest.main()
