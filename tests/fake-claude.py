#!/usr/bin/env python3
"""tests/scripts/fake-claude.py against the recordings of Claude Code 2.1.330 (2.1.289 for the kinds the
2.1.330 runs did not produce): the same records in the same order (tests/data/claude-shapes, made from the
recordings by tools/claude-shapes.py; README.txt there has the command line and what was learned) and the
fields rhun reads. The fake cannot drift from the CLI without this failing (spec 11)."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import queue
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid as uuid_mod

ROOT = Path(__file__).resolve().parents[1]
FAKE = ROOT / 'tests/scripts/fake-claude.py'
SHAPES = ROOT / 'tests/data/claude-shapes'
_spec = importlib.util.spec_from_file_location('claude_shapes', ROOT / 'tools/claude-shapes.py')
claude_shapes = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(claude_shapes)
# the command line rhun pins (tests/data/claude-shapes/README.txt), for a trusted folder
STREAM = ['--output-format', 'stream-json', '--verbose', '--input-format', 'stream-json',
          '--include-partial-messages', '--permission-prompt-tool=stdio', '--setting-sources=user,project,local',
          '--max-thinking-tokens=31999']
HELP = ROOT / 'tests/data/claude/help-2.1.330.txt'
# accepted by 2.1.330 (every recording passes them), not in --help
HIDDEN = {'--permission-prompt-tool', '--max-thinking-tokens', '--thinking'}
# phase 2's line: the pinned one with every user message and every answer echoed back (findings 17, 18)
REPLAY = [*STREAM, '--replay-user-messages']


def documented(flag, text):
    """flag (`--flag` or `--flag=value`) is one of the options `claude --help` lists (or a known hidden one)."""
    flag = flag.split('=', 1)[0]
    return flag in HIDDEN or re.search(r'(^|[\s,])' + re.escape(flag) + r'([\s,=]|$)', text, re.M) is not None


class Fake:
    """The fake on pipes; every record it writes is kept in order."""

    def __init__(self, home, cwd, *args, env=None, base=None):
        """base: the command line in place of STREAM; args follow it."""
        environment = {k: v for k, v in os.environ.items() if not k.startswith(('CLAUDE_CONFIG_DIR', 'FAKE_CLAUDE'))}
        environment.update(HOME=str(home), **(env or {}))
        self.process = subprocess.Popen([sys.executable, str(FAKE), *(STREAM if base is None else base), *args],
                                        cwd=cwd, env=environment,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, encoding='utf-8')
        self.records = []
        self.raw_ok = False                 # a line that is not JSON comes as {"raw": LINE} (scenario unknown)
        self.raw = []                       # the lines as the fake wrote them
        self.lines = queue.Queue()
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()

    def read(self):
        """Puts every record on the queue, a line that is not JSON as its exception (until() raises it),
        and None at the end."""
        try:
            for line in self.process.stdout:
                self.raw.append(line)
                try:
                    self.lines.put(json.loads(line))
                except ValueError:
                    self.lines.put({'raw': line} if self.raw_ok else
                                   NotJson('the fake wrote a line that is not JSON: %r' % line[:200]))
        except (OSError, ValueError) as error:
            self.lines.put(error)
        finally:
            self.lines.put(None)

    def take(self, record):
        """A record from the queue, kept; an exception from the reader is raised."""
        if isinstance(record, Exception):
            raise record
        self.records.append(record)
        return record

    def send(self, record):
        self.process.stdin.write(json.dumps(record) + '\n')
        self.process.stdin.flush()

    def until(self, test, timeout=20):
        """Reads records until test(record) holds; returns that record."""
        deadline = time.time() + timeout
        while True:
            record = self.lines.get(timeout=max(0.1, deadline - time.time()))
            if record is None:
                raise AssistantEnded(self.records[-3:])
            if test(self.take(record)):
                return record

    def initialize(self, suggestions=None):
        """suggestions True or False: phase 2's initialize (promptSuggestions and the two dialog kinds)."""
        request = {'subtype': 'initialize', 'hooks': None}
        if suggestions is not None:
            request.update(promptSuggestions=suggestions,
                           supportedDialogKinds=['fable_overage_consent_prompt', 'auto_mode_server_fallback'])
        self.send({'type': 'control_request', 'request_id': 'r1', 'request': request})
        return self.until(lambda r: r.get('type') == 'control_response')['response']['response']

    def prompt(self, text, uid=None):
        message = {'type': 'user', 'message': {'role': 'user', 'content': [{'type': 'text', 'text': text}]},
                   'parent_tool_use_id': None, 'session_id': ''}
        if uid:
            message['uuid'] = uid
        self.send(message)

    def request(self, rid, subtype, **fields):
        """A control request; its control_response (the whole record)."""
        self.send({'type': 'control_request', 'request_id': rid, 'request': dict({'subtype': subtype}, **fields)})
        return self.until(lambda r: r.get('type') == 'control_response' and r['response'].get('request_id') == rid)

    def since(self, index):
        """The records kept from index on."""
        return self.records[index:]

    def answer(self, request, response):
        self.send({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': request['request_id'],
                                                             'response': response}})

    def interrupt(self, rid='r2'):
        self.send({'type': 'control_request', 'request_id': rid, 'request': {'subtype': 'interrupt'}})

    def finish(self, timeout=20):
        self.process.stdin.close()
        status = self.process.wait(timeout)
        while True:
            record = self.lines.get(timeout=5)
            if record is None:
                return status
            self.take(record)


class AssistantEnded(AssertionError):
    pass


class NotJson(AssertionError):
    pass


RECORDED = (SHAPES / 'keys.txt').read_text(encoding='utf-8').splitlines()


def key_order_faults(lines):
    """The key lines (tools/claude-shapes.py) of the records in lines (as the fake wrote them) whose field
    order no recorded record of their kind has."""
    records = []
    for line in lines:
        try:
            records.append(json.loads(line))
        except ValueError:
            continue
    return sorted({line for line in claude_shapes.key_lines(records)
                   if not claude_shapes.key_order_ok(line, RECORDED)})


def is_type(kind, subtype=None):
    return lambda r: r.get('type') == kind and (subtype is None or r.get('subtype') == subtype or
                                                r.get('request', {}).get('subtype') == subtype)


def is_delta(r):
    return r.get('type') == 'stream_event' and r['event'].get('type') == 'content_block_delta' and \
        r['event'].get('delta', {}).get('type') == 'text_delta'


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rhun-fake-claude-')
        self.home = Path(self.tmp.name).resolve()
        self.project = self.home / 'project'
        self.project.mkdir()
        self.fakes = []

    def tearDown(self):
        faults = []
        for fake in self.fakes:
            if fake.process.poll() is None:
                fake.process.kill()
                fake.process.wait()
            if not fake.process.stdin.closed:
                fake.process.stdin.close()
            fake.reader.join(5)
            fake.process.stdout.close()
            faults += key_order_faults(fake.raw)
        self.tmp.cleanup()
        # every record any test made the fake write keeps the recordings' field order (keys.txt)
        self.assertEqual(faults, [], 'records whose field order no recording has')

    def fake(self, *args, base=None, **env):
        fake = Fake(self.home, self.project, *args, env=env, base=base)
        self.fakes.append(fake)
        return fake

    def expect(self, name, fake, records=None):
        """The fake's records (or those given: an excerpt, as the shape files 12 to 17 are) have the shapes of
        the recording."""
        self.assertEqual(claude_shapes.shapes(fake.records if records is None else records),
                         (SHAPES / (name + '.txt')).read_text().split(), name)

    def transcript(self, sid):
        return self.home / '.claude/projects' / re.sub(r'[^A-Za-z0-9]', '-', str(self.project)) / (sid + '.jsonl')

    def record(self, fake):
        """The fake's session record (<config>/sessions/<pid>.json)."""
        return self.home / '.claude/sessions' / ('%d.json' % fake.process.pid)


class Shapes(Base):
    def test_01_init(self):
        fake = self.fake()
        response = fake.initialize()
        self.assertTrue({'commands', 'models', 'account', 'pid', 'current_permission_mode'} <= set(response))
        record = json.loads((self.home / '.claude/sessions' / ('%d.json' % fake.process.pid)).read_text())
        self.assertTrue({'pid', 'sessionId', 'procStart', 'pidDomain', 'startedAt'} <= set(record))
        fake.prompt('Reply with the single word ok.')
        init = fake.until(is_type('system', 'init'))
        self.assertTrue({'session_id', 'model', 'permissionMode', 'apiKeySource', 'cwd'} <= set(init))
        result = fake.until(is_type('result'))
        self.assertTrue({'subtype', 'is_error', 'result', 'session_id', 'usage', 'modelUsage', 'stop_reason',
                         'terminal_reason'} <= set(result))
        self.assertEqual(fake.finish(), 0)
        self.expect('01-init', fake)
        self.assertFalse((self.home / '.claude/sessions' / ('%d.json' % fake.process.pid)).exists(),
                         'a clean exit leaves the session record')

    def test_02_permission(self):
        fake = self.fake('--permission-mode', 'manual')
        fake.initialize()
        fake.prompt('tool2')
        first = fake.until(is_type('control_request', 'can_use_tool'))
        self.assertTrue({'tool_name', 'input', 'tool_use_id', 'permission_suggestions'} <= set(first['request']))
        fake.answer(first, {'behavior': 'allow', 'updatedInput': first['request']['input']})
        second = fake.until(is_type('control_request', 'can_use_tool'))
        fake.answer(second, {'behavior': 'deny', 'message': 'no'})
        fake.until(is_type('result'))
        fake.finish()
        self.expect('02-permission', fake)
        self.assertTrue((self.project / 'approved.txt').exists())
        self.assertFalse((self.project / 'denied.txt').exists())

    def test_03_ask(self):
        fake = self.fake()
        fake.initialize()
        fake.prompt('ask')
        request = fake.until(is_type('control_request', 'can_use_tool'))
        self.assertTrue(request['request']['requires_user_interaction'])
        updated = dict(request['request']['input'], answers={'Which color do you prefer?': 'Blue'})
        fake.answer(request, {'behavior': 'allow', 'updatedInput': updated})
        self.assertEqual(fake.until(is_type('result'))['result'], '{"Which color do you prefer?": "Blue"}')
        fake.finish()
        self.expect('03-ask-user-question', fake)

    def test_04_plan_request_fields(self):
        fake = self.fake()
        fake.initialize()
        fake.prompt('plan')
        request = fake.until(is_type('control_request', 'can_use_tool'))
        self.assertEqual(request['request']['tool_name'], 'ExitPlanMode')
        self.assertTrue({'plan', 'planFilePath'} <= set(request['request']['input']))
        fake.answer(request, {'behavior': 'allow', 'updatedInput': request['request']['input'], 'updatedPermissions': [
            {'type': 'setMode', 'mode': 'acceptEdits', 'destination': 'session'}]})
        self.assertEqual(fake.until(is_type('system', 'status'))['permissionMode'], 'acceptEdits')
        self.assertEqual(fake.until(is_type('result'))['result'], 'approved acceptEdits')
        fake.finish()

    def test_05_interrupt(self):
        fake = self.fake()
        fake.initialize()
        fake.prompt('slow')
        fake.until(is_delta)
        fake.interrupt()
        result = fake.until(is_type('result'))
        self.assertEqual((result['subtype'], result['terminal_reason']), ('error_during_execution', 'aborted_streaming'))
        self.assertTrue(result['modelUsage'], 'an interrupted turn of 2.1.330 reports what it spent (05)')
        stop = [r for r in fake.records if is_type('stream_event')(r) and r['event']['type'] == 'message_stop']
        self.assertEqual(stop[-1]['abandoned_blocks']['from_block_index'], 2, 'the cut stream is closed (05)')
        self.assertEqual(fake.finish(), 1, 'after an interrupted turn the CLI exits with status 1 (C9)')
        self.expect('05-interrupt', fake)

    def test_06_interrupt_pending(self):
        fake = self.fake()
        fake.initialize()
        fake.prompt('pending')
        request = fake.until(is_type('control_request', 'can_use_tool'))
        time.sleep(0.3)
        fake.interrupt()
        cancel = fake.until(is_type('control_cancel_request'))
        self.assertEqual(cancel['request_id'], request['request_id'])
        self.assertEqual(request['request']['blocked_path'], str(self.project / 'pending.txt'))
        fake.until(is_type('result'))
        rejection = next(r for r in fake.records if is_type('user')(r) and
                         r['message']['content'][0]['type'] == 'tool_result')['message']['content'][0]
        self.assertEqual((list(rejection), rejection['is_error']), (['type', 'content', 'is_error', 'tool_use_id'], True))
        fake.answer(request, {'behavior': 'allow', 'updatedInput': request['request']['input']})  # ignored (C10)
        self.assertEqual(fake.finish(), 1)
        self.expect('06-interrupt-pending-permission', fake)
        self.assertFalse((self.project / 'pending.txt').exists())

    def test_07_resume_and_fork(self):
        first = self.fake()
        first.initialize()
        first.prompt('one')
        sid = first.until(is_type('system', 'init'))['session_id']
        first.until(is_type('result'))
        first.finish()
        resumed = self.fake('--resume', sid)
        resumed.initialize()
        resumed.prompt('two')
        self.assertEqual(resumed.until(is_type('system', 'init'))['session_id'], sid)
        resumed.until(is_type('result'))
        resumed.finish()
        self.expect('07a-resume', resumed)
        new = '0b5e1c4e-2f1a-4b5e-9d1c-3a2b1c0d9e8f'
        copy = self.fake('--resume', sid, '--fork-session', '--session-id', new)
        copy.initialize()
        copy.prompt('three')
        self.assertEqual(copy.until(is_type('system', 'init'))['session_id'], new)
        copy.until(is_type('result'))
        copy.finish()
        self.expect('07b-fork', copy)
        texts = [json.loads(line)['message']['content'][0].get('text') for line in
                 self.transcript(new).read_text().splitlines()]
        self.assertEqual(texts, ['one', 'ok: one', 'two', 'ok: two', 'three', 'ok: three'])

    def test_session_id_needs_fork_with_resume(self):
        first = self.fake('--session-id', '11111111-2222-4333-8444-555555555555')
        first.initialize()
        first.prompt('one')
        self.assertEqual(first.until(is_type('system', 'init'))['session_id'], '11111111-2222-4333-8444-555555555555')
        first.until(is_type('result'))
        first.finish()
        refused = self.fake('--resume', '11111111-2222-4333-8444-555555555555', '--session-id',
                            '66666666-2222-4333-8444-555555555555')
        self.assertEqual(refused.process.wait(10), 1)

    def test_11_unknown_resume(self):
        fake = self.fake('--resume', '00000000-0000-4000-8000-000000000000')
        status = fake.finish()
        self.assertEqual(status, 1)
        self.expect('11-resume-unknown-id', fake)
        self.assertEqual(fake.records[0]['session_id'], '00000000-0000-4000-8000-000000000000')

    def test_requests_rhun_does_not_know_get_an_error(self):
        fake = self.fake()
        fake.initialize()
        fake.send({'type': 'control_request', 'request_id': 'r5', 'request': {'subtype': 'no_such_subtype'}})
        response = fake.until(is_type('control_response'))['response']
        self.assertEqual((response['subtype'], response['request_id']), ('error', 'r5'))
        fake.finish()

    def test_auth_status(self):
        for mode, expected in (('ok', True), ('out', False), ('key', True)):
            out = subprocess.run([sys.executable, str(FAKE), 'auth', 'status'], capture_output=True, text=True,
                                 env=dict(os.environ, HOME=str(self.home), FAKE_CLAUDE_AUTH=mode), timeout=20)
            self.assertEqual(json.loads(out.stdout)['loggedIn'], expected)

    def test_equals_flags_are_accepted(self):
        # 2.1.330 takes `--flag=value` and `--flag value` alike (README.txt); so does the fake
        sid = '22222222-3333-4444-8555-666666666666'
        two = ['--output-format', 'stream-json', '--verbose', '--input-format', 'stream-json',
               '--include-partial-messages', '--permission-prompt-tool', 'stdio', '--setting-sources', 'user',
               '--max-thinking-tokens', '31999']
        for args in ([*STREAM, '--session-id=' + sid, '--permission-mode=plan'], ['-p', *two]):
            fake = Fake(self.home, self.project, env={}, base=args)
            self.fakes.append(fake)
            self.assertIn('current_permission_mode', fake.initialize(), args)
            fake.prompt('one')
            init = fake.until(is_type('system', 'init'))
            fake.until(is_type('result'))
            self.assertEqual(fake.finish(), 0)
            if '--permission-mode=plan' in args:
                self.assertEqual((init['session_id'], init['permissionMode']), (sid, 'plan'))
        environment = dict(os.environ, HOME=str(self.home))
        for args in (STREAM[:-1],                                       # a pinned flag missing
                     [*STREAM, '--settings={"forceLoginMethod":"claudeai"}'],   # one the fake does not know
                     [*STREAM[:-1], '--max-thinking-tokens=lots'],
                     [*STREAM[:-2], '--setting-sources=user,everything', STREAM[-1]],
                     [*STREAM, '--resume']):                            # a value missing
            out = subprocess.run([sys.executable, str(FAKE), *args], capture_output=True, text=True,
                                 env=environment, timeout=20, stdin=subprocess.DEVNULL)
            self.assertEqual(out.returncode, 2, args)

    def test_the_flags_the_fake_understands_are_claudes(self):
        # spec 11 drift: the fake reads no flag the recorded CLI does not have
        text = HELP.read_text(encoding='utf-8')
        flags = [a for a in STREAM if a.startswith('-')] + ['-p', '--permission-mode', '--model', '--resume',
                                                             '--fork-session', '--session-id',
                                                             '--replay-user-messages',
                                                             '--allow-dangerously-skip-permissions',
                                                             '--thinking=disabled', '--effort']
        self.assertEqual([f for f in flags if not documented(f, text)], [])
        self.assertTrue(documented('--setting-sources=user', text))
        self.assertFalse(documented('--no-such-flag', text))

    def test_setting_sources_are_honoured_and_logged(self):
        log = self.home / 'fake.log'
        (self.project / '.claude').mkdir()
        (self.project / '.claude/settings.json').write_text('{"permissions": {"defaultMode": "plan"}}')
        (self.home / '.claude').mkdir()
        (self.home / '.claude/settings.json').write_text('{"permissions": {"defaultMode": "acceptEdits"}}')
        modes = []
        for sources in ('user,project,local', 'user', 'project'):
            args = [*STREAM[:-2], '--setting-sources=' + sources, STREAM[-1]]
            fake = Fake(self.home, self.project, env={'FAKE_CLAUDE_LOG': str(log)}, base=args)
            self.fakes.append(fake)
            modes.append(fake.initialize()['current_permission_mode'])
            fake.finish()
        self.assertEqual(modes, ['plan', 'acceptEdits', 'plan'])
        self.assertEqual([r['sources'] for r in logged(log) if r.get('start') == 'stream'],
                         [['user', 'project', 'local'], ['user'], ['project']])


class Scenarios(Base):
    """The scenarios and switches tests/agents-claude.py drives through rhun, and the fake's own manners:
    it ends with its stdin, its stdout or a SIGTERM, never waits for an answer nobody can give, and logs."""

    def test_plain_scenarios_end_their_turns(self):
        fake = self.fake()
        fake.initialize()
        for prompt, final in (('hello there', 'ok: hello there'), ('think', 'thought about it'),
                              ('wait a bit', 'ok: wait a bit'), ('auto', 'done'), ('subagent', 'done'),
                              ('ran', 'done'), ('fails', 'done'), ('early', 'early'), ('replay', 'ok: replay'),
                              ('mcp', 'done'), ('noid', 'done')):
            fake.prompt(prompt)
            self.assertEqual(fake.until(is_type('result'))['result'], final, prompt)
        self.assertFalse([r for r in fake.records if is_type('control_request')(r)], 'auto asked')
        self.assertTrue((self.project / 'auto.txt').exists())
        self.assertTrue((self.project / 'ran.txt').exists())
        self.assertTrue([r for r in fake.records if r.get('isReplay')], 'no replayed user line')
        self.assertTrue([r for r in fake.records if r.get('parent_tool_use_id')], 'no subagent records')
        self.assertTrue([r for r in fake.records if is_type('system', 'thinking_tokens')(r)])
        fake.prompt('error')
        result = fake.until(is_type('result'))
        self.assertEqual((result['subtype'], result['is_error']), ('error_during_execution', True))
        self.assertTrue(result['errors'][0].startswith('API Error: 529'), result)
        self.assertEqual(fake.finish(), 0)
        self.assertFalse(self.record(fake).exists())

    def test_tool_runs_the_command_it_names(self):
        fake = self.fake()
        fake.initialize()
        fake.prompt('tool touch a1.txt')
        request = fake.until(is_type('control_request', 'can_use_tool'))
        self.assertEqual(request['request']['input']['command'], 'touch a1.txt')
        self.assertEqual(request['request']['permission_suggestions'][0]['rules'][0]['ruleContent'], 'touch a1.txt')
        fake.answer(request, {'behavior': 'allow', 'updatedInput': request['request']['input']})
        self.assertEqual(fake.until(is_type('result'))['result'], 'done')
        fake.finish()
        self.assertTrue((self.project / 'a1.txt').exists())

    def test_ask2_takes_a_multi_select_answer(self):
        log = self.home / 'fake.log'
        fake = self.fake(FAKE_CLAUDE_LOG=str(log))
        fake.initialize()
        fake.prompt('ask2')
        request = fake.until(is_type('control_request', 'can_use_tool'))
        questions = request['request']['input']['questions']
        self.assertEqual([q['multiSelect'] for q in questions], [False, True])
        answers = {'Which language?': 'Go', 'Which tools?': 'git, make'}
        fake.answer(request, {'behavior': 'allow', 'updatedInput': dict(request['request']['input'], answers=answers)})
        self.assertEqual(json.loads(fake.until(is_type('result'))['result']), answers)
        fake.finish()
        self.assertIn({'questions_kept': True, 'pid': fake.process.pid}, logged(log))

    def test_a_skipped_question_and_kept_planning_end_the_turn(self):
        fake = self.fake()
        fake.initialize()
        for prompt, final in (('ask', 'skipped'), ('plan', 'planning')):
            fake.prompt(prompt)
            request = fake.until(is_type('control_request', 'can_use_tool'))
            fake.answer(request, {'behavior': 'deny', 'message': 'no'})
            self.assertEqual(fake.until(is_type('result'))['result'], final)
        self.assertEqual(fake.finish(), 0)

    def test_withdraw_deep_and_askx(self):
        log = self.home / 'fake.log'
        fake = self.fake(FAKE_CLAUDE_LOG=str(log))
        fake.initialize()
        fake.prompt('withdraw')
        request = fake.until(is_type('control_request', 'can_use_tool'))
        cancel = fake.until(is_type('control_cancel_request'))
        self.assertEqual(cancel['request_id'], request['request_id'])
        fake.answer(request, {'behavior': 'allow', 'updatedInput': request['request']['input']})  # too late
        self.assertEqual(fake.until(is_type('result'))['result'], 'done')
        self.assertFalse((self.project / 'withdrawn.txt').exists())
        for prompt, depth in (('deep', 'input'), ('deep rule', 'rule')):
            fake.prompt(prompt)
            record = fake.until(is_type('control_request', 'can_use_tool'))
            request = record['request']
            value = request['input']['nested'] if depth == 'input' else \
                request['permission_suggestions'][0]['rules'][0]['nested']
            for _ in range(70):
                value = value[0]
            self.assertEqual(value, 'end', prompt)
            fake.answer(record, {'behavior': 'deny', 'message': 'no'})
            self.assertEqual(fake.until(is_type('result'))['result'], 'done')
        fake.prompt('askx')
        request = fake.until(is_type('control_request', 'can_use_tool'))
        self.assertEqual(list(request['request']['input']), ['questions', 'answers', 'note'])
        fake.answer(request, {'behavior': 'allow', 'updatedInput': dict(
            request['request']['input'], answers={'Which color do you prefer?': 'Red'})})
        self.assertEqual(json.loads(fake.until(is_type('result'))['result']), {'Which color do you prefer?': 'Red'})
        fake.finish()
        self.assertEqual([r['answer']['behavior'] for r in logged(log) if 'answer' in r], ['deny', 'deny', 'allow'])

    def test_numeric_request_ids(self):
        fake = self.fake(FAKE_CLAUDE_NUMERIC_IDS='1')
        fake.initialize()
        fake.prompt('tool')
        request = fake.until(is_type('control_request', 'can_use_tool'))
        self.assertEqual(request['request_id'], 7)
        fake.answer({'request_id': '7'}, {'behavior': 'deny', 'message': 'a string id'})   # not its id: ignored
        fake.answer(request, {'behavior': 'allow', 'updatedInput': request['request']['input']})
        self.assertEqual(fake.until(is_type('result'))['result'], 'done')
        self.assertTrue((self.project / 'approved.txt').exists())
        fake.prompt('withdraw')
        self.assertEqual(fake.until(is_type('control_cancel_request'))['request_id'], 8)
        self.assertEqual(fake.until(is_type('result'))['result'], 'done')
        self.assertEqual(fake.finish(), 0)

    def test_many_asks_33_times_at_once(self):
        log = self.home / 'fake.log'
        fake = self.fake(FAKE_CLAUDE_LOG=str(log))
        fake.initialize()
        fake.prompt('many')
        requests = [fake.until(is_type('control_request', 'can_use_tool')) for _ in range(33)]
        for request in requests[:32]:
            fake.answer(request, {'behavior': 'allow', 'updatedInput': request['request']['input']})
        fake.send({'type': 'control_response', 'response': {'subtype': 'error', 'request_id': requests[32]['request_id'],
                                                             'error': 'rhun already has 32 requests waiting'}})
        self.assertEqual(fake.until(is_type('result'))['result'], 'done')
        fake.finish()
        many = next(r['many'] for r in logged(log) if 'many' in r)
        self.assertEqual(many, ['allow'] * 32 + ['error'])

    def test_racing_completes_before_it_answers_the_interrupt(self):
        fake = self.fake()
        fake.initialize()
        fake.prompt('racing')
        fake.until(is_delta)
        fake.interrupt()
        fake.until(lambda r: r.get('type') == 'control_response' and r['response']['request_id'] == 'r2')
        result = next(r for r in fake.records if r.get('type') == 'result')
        self.assertEqual((result['subtype'], result['result']), ('success', 'almost'))
        sid = result['session_id']
        self.assertFalse(self.transcript(sid).exists(), 'racing saved its turn before the result')
        self.assertEqual(fake.finish(), 0)
        self.assertEqual([json.loads(l)['type'] for l in self.transcript(sid).read_text().splitlines()],
                         ['user', 'assistant'], 'racing saves its turn after the result')

    def test_racing_ends_by_itself_when_stdin_closes(self):
        fake = self.fake()
        fake.initialize()
        fake.prompt('racing')
        fake.until(is_delta)
        self.assertEqual(fake.finish(timeout=10), 0)
        self.assertEqual([r['result'] for r in fake.records if r.get('type') == 'result'], ['almost'])

    def test_deaf_answers_no_interrupt_and_a_sigterm_ends_it_as_a_crash(self):
        fake = self.fake()
        fake.initialize()
        fake.prompt('deaf')
        fake.until(is_delta)
        fake.interrupt()
        time.sleep(0.5)
        fake.process.send_signal(signal.SIGTERM)
        self.assertEqual(fake.process.wait(10), 143)
        fake.finish()
        self.assertFalse([r for r in fake.records[1:] if r.get('type') in ('control_response', 'result')],
                         'deaf answered the interrupt or ended its turn')
        self.assertTrue(self.record(fake).exists(), 'a SIGTERM removed the session record (only a clean exit does, C7)')

    def test_an_interrupt_between_turns_is_answered(self):
        fake = self.fake()
        fake.initialize()
        fake.interrupt('r7')
        response = fake.until(is_type('control_response'))['response']
        self.assertEqual((response['subtype'], response['request_id']), ('success', 'r7'))
        fake.prompt('hello')
        self.assertEqual(fake.until(is_type('result'))['result'], 'ok: hello', 'the old interrupt cut the turn')
        self.assertEqual(fake.finish(), 0)

    def test_unsaved_saves_nothing_when_interrupted(self):
        fake = self.fake()
        fake.initialize()
        fake.prompt('unsaved')
        sid = fake.until(is_type('system', 'status'))['session_id']
        fake.interrupt()
        result = fake.until(is_type('result'))
        self.assertEqual((result['subtype'], result['terminal_reason']), ('error_during_execution', 'aborted_streaming'))
        self.assertEqual(fake.finish(), 1)
        self.assertFalse(self.transcript(sid).exists(), 'the interrupted turn saved something')
        fake = self.fake()                  # "late": saved a second after the result
        fake.initialize()
        fake.prompt('unsaved late')
        sid = fake.until(is_type('system', 'status'))['session_id']
        fake.interrupt()
        fake.until(is_type('result'))
        self.assertFalse(self.transcript(sid).exists(), 'saved before the result')
        self.assertEqual(fake.finish(), 1)
        self.assertEqual([json.loads(l)['message']['content'][0]['text']
                          for l in self.transcript(sid).read_text().splitlines()],
                         ['unsaved late', '[Request interrupted by user]'])
        fake = self.fake()                  # not interrupted: saved and answered when stdin closes
        fake.initialize()
        fake.prompt('unsaved')
        sid = fake.until(is_type('system', 'status'))['session_id']
        self.assertEqual(fake.finish(timeout=10), 0)
        self.assertEqual([r['result'] for r in fake.records if r.get('type') == 'result'], ['ok: unsaved'])
        self.assertEqual([json.loads(l)['type'] for l in self.transcript(sid).read_text().splitlines()],
                         ['user', 'assistant'])

    def test_exit_dies_mid_turn_and_leaves_its_record(self):
        log = self.home / 'fake.log'
        fake = self.fake(FAKE_CLAUDE_LOG=str(log))
        fake.initialize()
        fake.prompt('exit')
        self.assertEqual(fake.process.wait(10), 2)
        fake.finish()
        self.assertTrue(self.record(fake).exists(), 'a crash removed the session record')
        self.assertIn({'exit': 2, 'pid': fake.process.pid}, logged(log))

    def test_big_sends_a_record_above_64_mib(self):
        fake = self.fake()
        fake.initialize()
        fake.prompt('big')
        request = fake.until(is_type('control_request', 'can_use_tool'))
        self.assertEqual(request['request']['input']['command'], 'touch big.txt')
        fake.until(is_delta, timeout=60)
        self.assertGreater(len(fake.raw[-1]), 64 << 20)
        self.assertEqual(fake.finish(), 1)
        self.assertTrue(self.record(fake).exists(), 'big ends as a crash')

    def test_stdin_closing_withdraws_a_waiting_request(self):
        for prompt in ('pending', 'ask', 'many'):
            fake = self.fake()
            fake.initialize()
            fake.prompt(prompt)
            fake.until(is_type('control_request', 'can_use_tool'))
            started = time.time()
            self.assertEqual(fake.finish(timeout=10), 1, prompt)
            self.assertLess(time.time() - started, 5, prompt)
            self.assertEqual(fake.records[-1]['subtype'], 'error_during_execution', prompt)
            self.assertFalse(self.record(fake).exists(), prompt)
            results = [r['message']['content'][0] for r in fake.records if is_type('user')(r)]
            calls = 33 if prompt == 'many' else 1
            self.assertEqual([(b['type'], b.get('is_error')) for b in results],
                             [('tool_result', True)] * calls + [('text', None)], prompt)
        self.assertFalse((self.project / 'pending.txt').exists())

    def test_it_exits_when_its_stdout_is_gone(self):
        environment = {k: v for k, v in os.environ.items() if not k.startswith(('CLAUDE_CONFIG_DIR', 'FAKE_CLAUDE'))}
        process = subprocess.Popen([sys.executable, str(FAKE), *STREAM], cwd=self.project,
                                   env=dict(environment, HOME=str(self.home)), stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        try:
            process.stdout.close()
            process.stdin.write(b'{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}\n')
            process.stdin.flush()
            self.assertEqual(process.wait(10), 1)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            try:
                process.stdin.close()
            except BrokenPipeError:
                pass
        self.assertFalse((self.home / '.claude/sessions' / ('%d.json' % process.pid)).exists())

    def test_the_log(self):
        log = self.home / 'fake.log'
        fake = self.fake('--permission-mode', 'manual', FAKE_CLAUDE_LOG=str(log), CLAUDE_EFFORT='high',
                         CLAUDE_CODE_ENTRYPOINT='rhun', CLAUDECODE='', FAKE_CLAUDE_ECHO_ENV='MY_TOKEN_NAME,OTHER',
                         MY_TOKEN_NAME='x1')
        fake.initialize()
        fake.prompt('tool')
        request = fake.until(is_type('control_request', 'can_use_tool'))
        fake.answer(request, {'behavior': 'deny', 'message': 'no'})
        fake.until(is_type('result'))
        fake.finish()
        lines = logged(log)
        pid = fake.process.pid
        self.assertTrue(all(r['pid'] == pid for r in lines))
        start = lines[0]
        self.assertEqual((start['start'], start['argv'][-2:], start['cwd']),
                         ('stream', ['--permission-mode', 'manual'], str(self.project)))
        self.assertIn('CLAUDE_EFFORT', start['names'])
        self.assertEqual(start['sources'], ['user', 'project', 'local'])
        self.assertEqual({k: start['env'][k] for k in ('CLAUDE_CODE_ENTRYPOINT', 'CLAUDECODE', 'MY_TOKEN_NAME', 'OTHER')},
                         {'CLAUDE_CODE_ENTRYPOINT': 'rhun', 'CLAUDECODE': '', 'MY_TOKEN_NAME': 'x1', 'OTHER': None})
        sent = [json.loads(r['stdin']) for r in lines if 'stdin' in r]
        self.assertEqual([m['type'] for m in sent], ['control_request', 'user', 'control_response'])
        self.assertIn({'answer': {'behavior': 'deny', 'message': 'no'}, 'pid': pid}, lines)
        self.assertEqual(lines[-1], {'exit': 0, 'pid': pid})
        environment = {k: v for k, v in os.environ.items() if not k.startswith('FAKE_CLAUDE')}
        environment.update(HOME=str(self.home), FAKE_CLAUDE_LOG=str(log))
        auth = subprocess.run([sys.executable, str(FAKE), 'auth', 'status'], capture_output=True, text=True,
                              env=environment, timeout=20)
        self.assertEqual((auth.returncode, logged(log)[-1]['start']), (0, 'auth'))
        refused = subprocess.run([sys.executable, str(FAKE), '-p'], capture_output=True, text=True,
                                 env=environment, timeout=20, stdin=subprocess.DEVNULL)
        self.assertEqual((refused.returncode, logged(log)[-1]['start']), (2, 'refused'))

    def test_switches(self):
        fake = self.fake(FAKE_CLAUDE_ACCOUNT='bedrock', FAKE_CLAUDE_KEYSRC='ANTHROPIC_API_KEY', FAKE_CLAUDE_MODE='auto',
                         FAKE_CLAUDE_INIT_MS='300')
        started = time.time()
        response = fake.initialize()
        self.assertGreaterEqual(time.time() - started, 0.3)
        self.assertEqual((response['account']['apiProvider'], response['current_permission_mode']), ('bedrock', 'auto'))
        fake.prompt('hello')
        self.assertEqual(fake.until(is_type('system', 'init'))['apiKeySource'], 'ANTHROPIC_API_KEY')
        fake.finish()
        fake = self.fake(FAKE_CLAUDE_ACCOUNT='none')
        self.assertNotIn('account', fake.initialize())
        fake.finish()
        started = time.time()
        held = subprocess.run([sys.executable, str(FAKE), 'auth', 'status'], capture_output=True, text=True,
                              env=dict(os.environ, HOME=str(self.home), FAKE_CLAUDE_AUTH_MS='300'), timeout=20)
        self.assertGreaterEqual(time.time() - started, 0.3)
        self.assertTrue(json.loads(held.stdout)['loggedIn'])
        switch = self.home / 'auth-mode'
        switch.write_text('out\n')
        out = subprocess.run([sys.executable, str(FAKE), 'auth', 'status'], capture_output=True, text=True,
                             env=dict(os.environ, HOME=str(self.home), FAKE_CLAUDE_AUTH='@' + str(switch)), timeout=20)
        self.assertEqual((out.returncode, json.loads(out.stdout)['loggedIn']), (1, False))

    def test_set_permission_mode(self):
        fake = self.fake()
        fake.initialize()
        fake.send({'type': 'control_request', 'request_id': 'r3', 'request': {'subtype': 'set_permission_mode',
                                                                              'mode': 'plan'}})
        self.assertEqual(fake.until(is_type('control_response'))['response']['response'], {'mode': 'plan'})
        self.assertEqual(fake.until(is_type('system', 'status'))['permissionMode'], 'plan')
        fake.finish()

    def test_text_is_raw_utf8(self):
        fake = self.fake()
        fake.initialize()
        fake.prompt('héllo ✓')
        sid = fake.until(is_type('system', 'init'))['session_id']
        self.assertEqual(fake.until(is_type('result'))['result'], 'ok: héllo ✓')
        fake.finish()
        self.assertIn('ok: héllo ✓', fake.raw[-1], 'the CLI writes UTF-8, not \\u escapes')
        self.assertIn('héllo ✓', self.transcript(sid).read_text(encoding='utf-8'))

    def test_every_record_keeps_the_recorded_field_order(self):
        # tearDown checks every test's records the same way; this one covers most kinds and shows the check bites
        fake = self.fake('--permission-mode', 'manual')
        fake.initialize()
        for prompt in ('hello', 'think', 'auto', 'subagent', 'error', 'fails', 'early', 'replay', 'mcp', 'noid'):
            fake.prompt(prompt)
            fake.until(is_type('result'))
        for prompt, answer in (('tool', {'behavior': 'deny', 'message': 'no'}), ('ask', None), ('plan', None)):
            fake.prompt(prompt)
            request = fake.until(is_type('control_request', 'can_use_tool'))
            fake.answer(request, answer or {'behavior': 'allow', 'updatedInput': request['request']['input']})
            fake.until(is_type('result'))
        fake.prompt('slow')
        fake.until(is_delta)
        fake.interrupt()
        fake.until(is_type('result'))
        fake.finish()
        self.assertEqual(key_order_faults(fake.raw), [])
        kinds = {line.split(' ')[0] for line in claude_shapes.key_lines([json.loads(l) for l in fake.raw])}
        self.assertTrue({'result/success', 'result/error_during_execution', 'system/init', 'system/status',
                         'system/status:mode', 'system/thinking_tokens', 'control_request/can_use_tool:Bash',
                         'control_request/can_use_tool:ExitPlanMode', 'user:tool_result:AskUserQuestion',
                         'user:tool_result:ExitPlanMode', 'user:tool_result:Bash', 'user:tool_result:Bash:error',
                         'stream_event/message_start', 'assistant:thinking', 'assistant:tool_use',
                         'control_response/success:commands', 'control_response/success:still_queued',
                         'user:string'} <= kinds,
                        kinds)
        last = json.loads(fake.raw[-1])
        moved = dict(type='result', **{k: v for k, v in last.items() if k != 'type'})
        self.assertEqual(key_order_faults([json.dumps(moved)]), claude_shapes.key_lines([moved]),
                         'a result with type first passed')
        extra = dict(last, invented=1)
        self.assertEqual(key_order_faults([json.dumps(extra)]), claude_shapes.key_lines([extra]),
                         'a field the recordings do not have passed')

    def test_unknown_sends_what_nobody_knows_then_a_reply(self):
        fake = self.fake()
        fake.raw_ok = True
        fake.initialize()
        fake.prompt('unknown')
        self.assertEqual(fake.until(is_type('result'))['result'], 'ok: unknown')
        self.assertEqual(fake.finish(), 0)
        # the deliberate unknowns have no recorded field order: leave them out of tearDown's check
        fake.raw = [line for line in fake.raw if 'future_' not in line]
        odd = [r.get('type') + '/' + str(r.get('subtype', '')) if 'raw' not in r else 'raw' for r in fake.records
               if r.get('type') == 'future_record' or r.get('subtype') == 'future_subtype' or 'raw' in r]
        self.assertEqual(odd, ['future_record/', 'system/future_subtype', 'raw'])
        reply = [r for r in fake.records if 'raw' not in r][-12:]
        self.assertEqual(claude_shapes.shapes(reply)[-8:], (SHAPES / '01-init.txt').read_text().split()[-8:])

    def test_a_session_id_must_be_a_uuid(self):
        fake = self.fake('--session-id', 'not-a-uuid')
        self.assertEqual(fake.process.wait(10), 1)


UUID_A, UUID_B = '1a1a1a1a-0000-4000-8000-00000000000a', '2b2b2b2b-0000-4000-8000-00000000000b'
UUID_C, UUID_D = '3c3c3c3c-0000-4000-8000-00000000000c', '4d4d4d4d-0000-4000-8000-00000000000d'


def is_lifecycle(uid, state):
    return lambda r: r.get('type') == 'command_lifecycle' and r['command_uuid'] == uid and r['state'] == state


def states(fake, uid):
    return [r['state'] for r in fake.records if r.get('type') == 'command_lifecycle' and r['command_uuid'] == uid]


def unrecorded(fake, *names):
    """Leaves the lines holding a member no recording has (a knob's) out of tearDown's field-order check."""
    fake.raw = [line for line in fake.raw if not any('"%s"' % name in line for name in names)]


class Phase2(Base):
    """What phase 2 drives (README.txt findings 10 on): messages during a turn, the settings requests, the
    permission suggestions of Edit and WebFetch, bypass, the CLI's own commands, the knobs."""

    def test_12_13_held_messages_and_an_interrupt(self):
        fake = self.fake(base=REPLAY)
        fake.initialize(suggestions=True)
        fake.prompt('held think', UUID_A)
        fake.until(is_delta)
        fake.prompt('two', UUID_B)
        fake.until(is_lifecycle(UUID_B, 'completed'), 30)
        self.expect('12-held', fake)
        fake.until(lambda r: r.get('type') == 'prompt_suggestion')     # (the recording had none just here)
        start = len(fake.records)
        fake.prompt('held', UUID_C)
        fake.until(is_delta)
        fake.prompt('four', UUID_D)
        fake.until(is_lifecycle(UUID_D, 'queued'))
        fake.until(is_delta)
        answer = fake.request('r2', 'interrupt')['response']['response']
        self.assertEqual(answer, {'still_queued': [UUID_D]}, 'the held message stays queued (13)')
        fake.until(lambda r: r.get('type') == 'prompt_suggestion', 30)
        self.expect('13-held-interrupt', fake, fake.since(start))
        self.assertEqual((states(fake, UUID_C), states(fake, UUID_D)),
                         (['queued', 'started', 'cancelled'], ['queued', 'started', 'completed']))
        self.assertEqual(fake.finish(), 1)

    def test_14_held_without_replay(self):
        fake = self.fake()
        fake.initialize(suggestions=False)
        fake.prompt('held', UUID_A)
        fake.until(is_delta)
        fake.prompt('two', UUID_B)
        fake.until(is_lifecycle(UUID_B, 'completed'), 30)
        self.assertEqual(fake.finish(), 0)
        self.expect('14-held-noreplay', fake)
        self.assertFalse([r for r in fake.records if r.get('isReplay')], 'a replay without the flag')
        self.assertFalse([r for r in fake.records if r.get('type') == 'prompt_suggestion'], 'a suggestion when off')

    def test_replay_and_lifecycle_of_a_held_message(self):
        log = self.home / 'fake.log'
        fake = self.fake(base=REPLAY, FAKE_CLAUDE_LOG=str(log), FAKE_CLAUDE_REFUSE_HELD='1')
        fake.initialize(suggestions=True)
        fake.prompt('held', UUID_A)
        fake.until(is_delta)
        fake.prompt('refused one', UUID_B)          # the knob: the next held message is refused
        fake.prompt('three', UUID_C)
        fake.until(is_lifecycle(UUID_C, 'completed'), 30)
        echoes = [r for r in fake.records if r.get('isReplay')]
        self.assertEqual([(r['uuid'], r['message']['content'][0]['text']) for r in echoes],
                         [(UUID_A, 'held'), (UUID_C, 'three')], 'each message comes back with its uuid, as it starts')
        results = [r for r in fake.records if r.get('type') == 'result']
        self.assertEqual([r['user_message_uuid'] for r in results], [UUID_A, UUID_C])
        self.assertEqual((states(fake, UUID_A), states(fake, UUID_B), states(fake, UUID_C)),
                         (['queued', 'started', 'completed'], ['refused'], ['queued', 'started', 'completed']))
        order = [r.get('type') + '/' + str(r.get('subtype') or r.get('state') or '') for r in fake.records
                 if r.get('type') in ('command_lifecycle', 'system', 'user', 'result') and
                 r.get('subtype') not in ('status', 'commands_changed')]
        a_start = order.index('command_lifecycle/started')
        self.assertEqual(order[a_start:a_start + 3], ['command_lifecycle/started', 'system/init', 'user/'],
                         'started, system/init (every turn), then the replay')
        fake.prompt('plain without a uuid')
        reply = fake.until(lambda r: r.get('isReplay'))
        self.assertNotIn(reply['uuid'], (UUID_A, UUID_B, UUID_C), 'a message without a uuid gets the CLI\'s own')
        self.assertIsNone(fake.until(is_type('result')).get('user_message_uuid'))
        self.assertEqual(fake.finish(), 0)
        self.assertIn({'refused': UUID_B, 'pid': fake.process.pid}, logged(log))
        self.assertFalse([r for r in fake.records if r.get('isReplay') and r['uuid'] == UUID_B], 'the refused one ran')

    def test_15_permission_with_replay_and_saved_rules(self):
        fake = self.fake('--permission-mode=default', base=REPLAY)
        fake.initialize(suggestions=True)
        fake.prompt('tool touch a.txt')
        request = fake.until(is_type('control_request', 'can_use_tool'))
        rules = [dict(s, destination='localSettings') for s in request['request']['permission_suggestions']
                 if s['type'] == 'addRules']
        answer = {'behavior': 'allow', 'updatedInput': request['request']['input'], 'updatedPermissions': rules}
        fake.answer(request, answer)
        echo = fake.until(is_type('control_response'))
        self.assertEqual(echo['response']['response'], answer, 'the answer comes back as it was sent (18)')
        fake.until(is_type('result'))
        self.expect('15-permission-replay', fake)
        local = json.loads((self.project / '.claude/settings.local.json').read_text())
        self.assertEqual(local, {'permissions': {'allow': ['Bash(touch a.txt)']}})
        start = len(fake.records)
        fake.prompt('tool touch a.txt')
        fake.until(is_type('result'))
        self.assertFalse([r for r in fake.since(start) if is_type('control_request')(r)], 'the saved rule asked again')
        fake.prompt('tool touch b.txt')                 # allowed with another command: that one runs
        request = fake.until(is_type('control_request', 'can_use_tool'))
        fake.answer(request, {'behavior': 'allow', 'updatedInput': dict(request['request']['input'], command='touch c.txt')})
        fake.until(is_type('result'))
        fake.finish()
        self.assertEqual(sorted(p.name for p in self.project.glob('*.txt')), ['a.txt', 'c.txt'])

    def test_16_edit_and_its_mode_suggestion(self):
        (self.project / 'notes.txt').write_text('hello\n')
        fake = self.fake('--permission-mode=default', base=REPLAY)
        fake.initialize(suggestions=True)
        fake.prompt('edit notes.txt')
        request = fake.until(is_type('control_request', 'can_use_tool'))
        self.assertEqual(request['request']['permission_suggestions'],
                         [{'type': 'setMode', 'mode': 'acceptEdits', 'destination': 'session'}])
        self.assertEqual((request['request']['description'], list(request['request']['input'])),
                         ('notes.txt', ['file_path', 'old_string', 'new_string', 'replace_all']))
        fake.answer(request, {'behavior': 'allow', 'updatedInput': request['request']['input'],
                              'updatedPermissions': request['request']['permission_suggestions']})
        fake.until(lambda r: r.get('type') == 'prompt_suggestion')
        start = next(i for i, r in enumerate(fake.records) if is_type('stream_event')(r) and
                     r['event']['type'] == 'message_start')
        self.expect('16-edit', fake, fake.since(start))
        self.assertIn({'type': 'system', 'subtype': 'status', 'status': None, 'permissionMode': 'acceptEdits'},
                      [{k: r.get(k) for k in ('type', 'subtype', 'status', 'permissionMode')} for r in fake.records
                       if is_type('system', 'status')(r) and 'permissionMode' in r])
        mark = len(fake.records)
        fake.prompt('edit notes.txt')
        fake.until(is_type('result'))
        self.assertFalse([r for r in fake.since(mark) if is_type('control_request')(r)], 'acceptEdits asked again')
        fake.finish()
        self.assertEqual((self.project / 'notes.txt').read_text(), 'hello (edited) (edited)\n')
        self.assertFalse((self.project / '.claude').exists(), 'a session update wrote a file')

    def test_suggestions_of_edit_and_fetch(self):
        fake = self.fake('--permission-mode=default')
        fake.initialize()
        fake.prompt('fetch https://example.com/page')
        request = fake.until(is_type('control_request', 'can_use_tool'))
        self.assertEqual(request['request']['tool_name'], 'WebFetch')
        self.assertEqual(request['request']['permission_suggestions'], [
            {'type': 'addRules', 'destination': 'localSettings',
             'rules': [{'toolName': 'WebFetch', 'ruleContent': 'domain:example.com'}], 'behavior': 'allow'}])
        fake.answer(request, {'behavior': 'allow', 'updatedInput': request['request']['input'], 'updatedPermissions': [
            dict(request['request']['permission_suggestions'][0], destination='session')]})
        self.assertEqual(fake.until(is_type('result'))['result'], 'Example Domain')
        mark = len(fake.records)
        fake.prompt('fetch https://example.com/other')
        fake.until(is_type('result'))
        self.assertFalse([r for r in fake.since(mark) if is_type('control_request')(r)], 'the session rule asked again')
        fake.prompt('edit missing.txt')
        request = fake.until(is_type('control_request', 'can_use_tool'))
        self.assertEqual(request['request']['tool_name'], 'Edit')
        fake.answer(request, {'behavior': 'deny', 'message': 'no', 'interrupt': True})
        self.assertEqual(fake.until(is_type('result'))['terminal_reason'], 'aborted_tools')
        fake.finish()
        self.assertFalse((self.project / '.claude').exists(), 'a session rule was written to a file')

    def test_17_the_clis_own_commands(self):
        fake = self.fake(base=REPLAY)
        fake.initialize(suggestions=False)
        fake.prompt('hello')
        fake.until(is_type('result'))
        start = len(fake.records)
        answers = {}
        for command in ('/context', '/cost', '/status', '/compact'):
            fake.prompt(command)
            record = fake.until(is_type('result'))
            answers[command] = (record['result'], record.get('local_command'), 'terminal_reason' in record)
        fake.finish()
        self.expect('17-slash', fake, fake.since(start))
        self.assertEqual(answers['/status'], ("/status isn't available in this environment.", None, False))
        self.assertEqual(answers['/compact'], ('', 'compact', False))
        self.assertTrue(answers['/context'][0].startswith('## Context Usage'))
        self.assertEqual(answers['/cost'][1], 'cost')
        statuses = [r.get('status') for r in fake.since(start) if is_type('system', 'status')(r)]
        self.assertEqual(statuses, ['compacting', None], 'a local command sends no requesting status')
        commands = [c['name'] for c in fake.records[0]['response']['response']['commands']]
        self.assertEqual(commands, ['compact', 'context', 'usage'])

    def test_get_settings_and_flag_settings(self):
        log = self.home / 'fake.log'
        (self.home / '.claude').mkdir()
        (self.home / '.claude/settings.json').write_text('{"effortLevel": "xhigh"}')
        fake = self.fake(FAKE_CLAUDE_LOG=str(log))
        fake.initialize()
        settings = fake.request('r2', 'get_settings')['response']['response']
        self.assertEqual(list(settings), ['effective', 'sources', 'served_settings_state', 'applied'])
        self.assertEqual((settings['applied']['model'], settings['applied']['effort'],
                          settings['applied']['ultracodeAvailable']), ('claude-opus-5-5', 'xhigh', False))
        self.assertEqual([s['source'] for s in settings['sources']], ['userSettings'])
        empty = fake.request('r3', 'apply_flag_settings', settings={'model': 'sonnet'})['response']
        self.assertEqual(empty, {'subtype': 'success', 'request_id': 'r3'}, 'no response member (11)')
        settings = fake.request('r4', 'get_settings')['response']['response']
        self.assertEqual((settings['applied']['model'], settings['applied']['effort'], settings['effective']['model']),
                         ('claude-sonnet-5', 'xhigh', 'sonnet'))
        self.assertEqual([s['source'] for s in settings['sources']], ['userSettings', 'flagSettings'])
        fake.request('r5', 'apply_flag_settings', settings={'effortLevel': 'low'})
        self.assertEqual(fake.request('r6', 'get_settings')['response']['response']['applied']['effort'], 'low')
        refused = fake.request('r7', 'update_settings', source='localSettings', settings={'model': 'opus'})['response']
        self.assertEqual((refused['subtype'], refused['error']), ('error', 'update_settings keys not allowed: model'))
        self.assertEqual(fake.request('r8', 'update_settings', source='projectSettings',
                                      settings={'outputStyle': 'x'})['response']['error'],
                         'update_settings: unsupported source projectSettings')
        fake.request('r9', 'update_settings', source='localSettings', settings={'outputStyle': 'default'})
        self.assertEqual(json.loads((self.project / '.claude/settings.local.json').read_text()),
                         {'outputStyle': 'default'})
        self.assertEqual(fake.request('r10', 'set_max_thinking_tokens', max_thinking_tokens=0)['response'],
                         {'subtype': 'success', 'request_id': 'r10'})
        fake.prompt('hello')
        message = fake.until(is_type('assistant'))
        self.assertEqual(message['message']['model'], 'claude-sonnet-5', 'the flag model answers')
        fake.until(is_type('result'))
        self.assertEqual(fake.request('r11', 'get_plan')['response']['response'], {'exists': False})
        fake.prompt('plan')
        fake.until(is_type('control_request', 'can_use_tool'))
        plan = fake.request('r12', 'get_plan')['response']['response']
        self.assertEqual((plan['exists'], plan['content'].startswith('# Plan'), list(plan)),
                         (True, True, ['exists', 'content', 'path']))
        fake.finish()
        self.assertEqual(json.loads((self.home / '.claude/settings.json').read_text()), {'effortLevel': 'xhigh'},
                         'apply_flag_settings wrote the user\'s settings')
        self.assertIn({'thinking': {'max_thinking_tokens': 0, 'thinking_display': None}, 'pid': fake.process.pid},
                      logged(log))
        # a new process: nothing of the flags is left; userSettings' effortLevel goes to the model's own
        fake = self.fake('--model=sonnet', '--effort=max')
        fake.initialize()
        self.assertEqual([fake.request('r2', 'get_settings')['response']['response']['applied'][k]
                          for k in ('model', 'effort')], ['claude-sonnet-5', 'max'])
        fake.finish()
        fake = self.fake(FAKE_CLAUDE_SETTINGS_ERROR='Unexpected token', FAKE_CLAUDE_MODELS='ultra')
        fake.initialize()
        settings = fake.request('r2', 'get_settings')['response']['response']
        self.assertEqual(([e['message'] for e in settings['errors']], settings['applied']['ultracodeAvailable']),
                         (['Unexpected token'], True))
        self.assertEqual(fake.request('r3', 'update_settings', source='userSettings',
                                      settings={'effortLevel': 'high'})['response']['response'], {})
        fake.finish()
        unrecorded(fake, 'errors')
        self.assertEqual(json.loads((self.home / '.claude/settings.json').read_text()),
                         {'effortLevel': 'xhigh', 'modelSettings': {'claude-opus-5-5': {'effortLevel': 'high'}}},
                         'update_settings userSettings effortLevel is per model (12)')

    def test_bypass_at_a_start_and_by_request(self):
        # 10: a start takes bypassPermissions without --allow-dangerously-skip-permissions; set_permission_mode
        # takes it only in a process started with that flag or in bypass
        fake = self.fake('--permission-mode=bypassPermissions')
        self.assertEqual(fake.initialize()['current_permission_mode'], 'bypassPermissions')
        for rid, mode in (('r2', 'default'), ('r3', 'bypassPermissions')):
            self.assertEqual(fake.request(rid, 'set_permission_mode', mode=mode)['response']['response'], {'mode': mode})
        fake.finish()
        fake = self.fake('--permission-mode=default')
        fake.initialize()
        refused = fake.request('r2', 'set_permission_mode', mode='bypassPermissions')['response']
        self.assertEqual((refused['subtype'], refused['error']), (
            'error', 'Cannot set permission mode to bypassPermissions because the session was not launched with '
                     '--dangerously-skip-permissions'))
        mark = len(fake.records)
        fake.request('r3', 'set_permission_mode', mode='default')       # unchanged: no status line
        fake.request('r4', 'set_permission_mode', mode='acceptEdits')
        fake.until(is_type('system', 'status'))
        self.assertEqual([r.get('permissionMode') for r in fake.since(mark) if is_type('system', 'status')(r)],
                         ['acceptEdits'])
        fake.finish()
        fake = self.fake('--permission-mode=default', '--allow-dangerously-skip-permissions')
        fake.initialize()
        self.assertEqual(fake.request('r2', 'set_permission_mode', mode='bypassPermissions')['response']['response'],
                         {'mode': 'bypassPermissions'})
        self.assertEqual(fake.until(is_type('system', 'status'))['permissionMode'], 'bypassPermissions')
        fake.finish()

    def test_phase2_flags_and_the_initialize_log(self):
        log = self.home / 'fake.log'
        args = [*STREAM[:-1], '--thinking=disabled', '--replay-user-messages', '--allow-dangerously-skip-permissions',
                '--model', 'sonnet', '--effort=low']
        fake = self.fake(base=args, FAKE_CLAUDE_LOG=str(log))
        fake.initialize(suggestions=True)
        fake.finish()
        lines = logged(log)
        self.assertEqual(lines[0]['switches'], {'replay': True, 'allow_bypass': True, 'thinking': 'disabled',
                                                'model': 'sonnet', 'effort': 'low'})
        self.assertIn({'initialize': {'promptSuggestions': True, 'supportedDialogKinds': [
            'fable_overage_consent_prompt', 'auto_mode_server_fallback']}, 'pid': fake.process.pid}, lines)
        environment = dict(os.environ, HOME=str(self.home))
        for refused in ([*STREAM, '--thinking=disabled'],                   # both thinking flags
                        [*STREAM[:-1], '--thinking=enabled'],
                        [*STREAM, '--effort=huge']):
            out = subprocess.run([sys.executable, str(FAKE), *refused], capture_output=True, text=True,
                                 env=environment, timeout=20, stdin=subprocess.DEVNULL)
            self.assertEqual(out.returncode, 2, refused)

    def test_knobs(self):
        fake = self.fake(FAKE_CLAUDE_MODELS='effort,nothink,auto,fast,unavailable', FAKE_CLAUDE_AUTH_CONFLICT='1',
                         FAKE_CLAUDE_CONTEXT='600000', FAKE_CLAUDE_RATE='warning')
        response = fake.initialize()
        first = response['models'][0]
        self.assertEqual((first['supportedEffortLevels'], first['supportsThinkingOff'], first['supportsAutoMode'],
                          first['supportsFastMode']), (['low', 'medium', 'high', 'xhigh', 'max'], True, True, True))
        self.assertEqual([m['value'] for m in response['unavailable_models']], ['haiku'])
        self.assertIn('auth_conflict', response)
        fake.prompt('hello')
        rate = fake.until(is_type('rate_limit_event'))['rate_limit_info']
        result = fake.until(is_type('result'))
        used = result['usage']
        self.assertEqual(sum(used[k] for k in ('input_tokens', 'cache_creation_input_tokens',
                                               'cache_read_input_tokens', 'output_tokens')), 600000)
        self.assertEqual((rate['status'], rate['unifiedWindows']['five_hour']['utilization']), ('allowed_warning', 0.85))
        fake.prompt('usage')
        message = fake.until(is_type('assistant'))['message']          # the message reports its cache too
        self.assertEqual(message['usage']['cache_creation']['ephemeral_1h_input_tokens'], 2000)
        result = fake.until(is_type('result'))
        self.assertEqual(result['usage']['cache_creation'], {'ephemeral_1h_input_tokens': 2000,
                                                             'ephemeral_5m_input_tokens': 0})
        for kind, status, window in (('weekly', 'allowed_warning', 'seven_day'), ('paused', 'rejected', 'five_hour'),
                                     ('spend', 'rejected', 'overage'), ('allowed', 'allowed', 'five_hour')):
            before = len(fake.records)
            fake.prompt('rate ' + kind)
            info = fake.until(is_type('rate_limit_event'))['rate_limit_info']
            self.assertEqual((info['status'], info['rateLimitType']), (status, window), kind)
            fake.until(is_type('result'))
            events = [r for r in fake.records[before:] if is_type('rate_limit_event')(r)]
            self.assertEqual(len(events), 1, kind)                  # FAKE_CLAUDE_RATE's is not sent too
        self.assertEqual(list(result['modelUsage'].values())[0]['cacheCreationEphemeral1hInputTokens'], 2000)
        fake.finish()
        unrecorded(fake, 'unavailable_models', 'auth_conflict')
        fake = self.fake(FAKE_CLAUDE_RATE='rejected')
        fake.initialize()
        fake.prompt('hello')
        self.assertEqual(fake.until(is_type('rate_limit_event'))['rate_limit_info']['status'], 'rejected')
        fake.finish()


FILE_RECORDED = (SHAPES / 'file-keys.txt').read_text(encoding='utf-8').splitlines()
# what the CLI writes to the file beside the records a reader reads (finding 27): the fake writes none of the
# bookkeeping, and every type it writes is one the CLI wrote
FILE_TYPES = {'user', 'assistant', 'system', 'attachment', 'file-history-snapshot'}   # (p6b: checkpoints)


def file_faults(records):
    """The file key lines (claude-shapes --file-keys) of the fake's file lines whose field order no recorded line
    of their kind has."""
    return sorted({line for line in claude_shapes.file_key_lines(records)
                   if not claude_shapes.key_order_ok(line, FILE_RECORDED)})


def shape_file(name):
    return (SHAPES / (name + '.txt')).read_text().split()


def is_result_of(tid):
    return lambda r: r.get('type') == 'user' and isinstance(r['message']['content'], list) and \
        r['message']['content'][0].get('tool_use_id') == tid


def calls(records, parent=None):
    """{tool_use id: name} of the calls in records (those made under parent, when given)."""
    return {b['id']: b['name'] for r in records if r.get('type') == 'assistant'
            and r.get('parent_tool_use_id') == parent for b in r['message']['content'] if b.get('type') == 'tool_use'}


def results(records):
    """{tool_use id: (block, tool_use_result)} of the tool results in records."""
    return {r['message']['content'][0]['tool_use_id']: (r['message']['content'][0], r.get('tool_use_result'))
            for r in records if r.get('type') == 'user' and isinstance(r['message']['content'], list)
            and r['message']['content'] and r['message']['content'][0].get('type') == 'tool_result'}


class Phase3(Base):
    """What phase 3 reads (README.txt findings 27 on): the conversation's file, every tool's result, thinking
    with text, subagents and tasks, compaction, local and custom commands, hooks."""

    def lines(self, sid=None, path=None):
        path = path or self.transcript(sid)
        return [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines() if line.strip()]

    def sid(self, fake):
        return next(r['session_id'] for r in fake.records if is_type('system', 'init')(r))

    def test_the_file_is_written_as_the_cli_writes_it(self):
        fake = self.fake(base=REPLAY, FAKE_CLAUDE_HOOKS='post,stop', FAKE_CLAUDE_PRESERVED='1')
        fake.initialize(suggestions=False)
        for prompt in ('hello', 'tools', 'think one two three four five six', 'echo hi', '/context', '/compact',
                       'agent', 'denied', 'toolerror', 'bg'):
            fake.prompt(prompt)
            for _ in range(2 if prompt == 'agent' else 1):        # the agent's notification has a turn too
                fake.until(is_type('result'))
        fake.finish(30)
        sid = self.sid(fake)
        lines = self.lines(sid)
        self.assertEqual(file_faults(lines), [], 'file lines whose field order no recorded line has')
        self.assertLessEqual({line['type'] for line in lines}, FILE_TYPES)
        # one content block a line, thinking saved with its text, the lines of a message share its id
        assistant = [line for line in lines if line['type'] == 'assistant']
        self.assertTrue(all(len(line['message']['content']) == 1 for line in assistant))
        thought = [line for line in assistant if line['message']['content'][0]['type'] == 'thinking']
        self.assertIn('one two three four five six', [line['message']['content'][0]['thinking'] for line in thought])
        self.assertTrue(any(line.get('thinkingDurationMs') == 3109 for line in thought))
        # parentUuid chains the message lines (a compaction boundary starts again with logicalParentUuid)
        for before, line in zip(lines, lines[1:]):
            if line['type'] == 'attachment' or before['type'] == 'attachment':
                continue
            expected = None if line.get('subtype') == 'compact_boundary' else before['uuid']
            self.assertEqual(line['parentUuid'], expected, line)
        # a tool's result line carries the stream's structured result and the call's line
        streamed = results(fake.records)
        written = {line['message']['content'][0]['tool_use_id']: line for line in lines if line['type'] == 'user'
                   and isinstance(line['message']['content'], list)
                   and line['message']['content'][0].get('type') == 'tool_result'}
        for tid, line in written.items():
            self.assertEqual(line['message']['content'][0], streamed[tid][0])
            self.assertEqual(line.get('toolUseResult'), streamed[tid][1])
            call = next(c for c in lines if c['uuid'] == line['sourceToolAssistantUUID'])
            self.assertEqual(call['message']['content'][0]['id'], tid)
        # the shapes the CLI's file has: summarized thinking, the commands and compaction (the file-*.txt shapes
        # leave out the Stop hooks' summary, the maintainer's own)
        shapes = claude_shapes.file_shapes([l for l in lines if l.get('subtype') != 'stop_hook_summary'])
        self.assertIn(' '.join(shape_file('file-thinking')), ' '.join(shapes))
        self.assertIn(' '.join(shape_file('file-compact')), ' '.join(shapes))
        self.assertNotIn('isSidechain', {k for line in lines if line.get('isSidechain') for k in line})
        flagged = {f: [line['message']['content'][:30] for line in lines if line.get(f)]
                   for f in ('isMeta', 'isCompactSummary', 'isVisibleInTranscriptOnly')}
        self.assertEqual(flagged['isCompactSummary'], ['This session is being continue'])
        self.assertIn('<local-command-caveat>The comm', flagged['isMeta'])
        kinds = {claude_shapes.file_kind(line, {}) for line in lines}
        self.assertTrue({'system/local_command', 'system/compact_boundary', 'system/stop_hook_summary',
                         'attachment/hook_additional_context'} <= kinds, kinds)

    def test_every_tool_scenario_has_its_recorded_result(self):
        fake = self.fake(base=REPLAY)
        fake.initialize(suggestions=False)
        fake.prompt('tools')
        fake.until(is_type('result'))
        fake.finish()
        # 18-tools: two Reads in one message, the first's result as the second streams, the last after message_stop
        turn = fake.records[next(i for i, r in enumerate(fake.records) if r.get('type') == 'user' and r.get('isReplay')):]
        recorded = shape_file('18-tools')
        self.assertEqual(claude_shapes.shapes(turn)[:16], recorded[:16])
        made = calls(fake.records)
        got = results(fake.records)
        self.assertEqual(sorted(set(made.values())), ['Bash', 'Edit', 'Glob', 'Grep', 'Read', 'TodoWrite', 'ToolSearch',
                                                     'WebFetch', 'WebSearch', 'Write'])
        recorded_results = {}
        for line in FILE_RECORDED:
            kind, parts = claude_shapes.parse_key_line(line)
            if kind.startswith('user:tool_result:') and 'toolUseResult' in parts:
                recorded_results.setdefault(kind, []).append(parts['toolUseResult'])
        for tid, name in made.items():
            block, structured = got[tid]
            error = block.get('is_error') is True
            if isinstance(structured, dict):
                self.assertTrue(any(claude_shapes.subsequence(list(structured), keys) for keys in
                                    recorded_results.get('user:tool_result:%s%s' % (name, ':error' if error else ''), [])),
                                (name, list(structured)))
            elif structured is not None:
                self.assertTrue(error and structured.startswith('Error: '), (name, structured))
        texts = [(made[tid], got[tid][0]['content']) for tid in made]
        reads = [c for n, c in texts if n == 'Read']
        self.assertEqual(reads[0].split('\n')[:2], ['1\tone', '2\ttwo'])
        self.assertTrue(reads[1].startswith('2\tx2 = 2'))
        self.assertEqual(reads[3][0]['source']['media_type'], 'image/png')
        self.assertIn('<tool_use_error>String to replace not found in file.\nString: nothing-here</tool_use_error>',
                      [c for n, c in texts if n == 'Edit'])
        self.assertIn('Found 8 total occurrences across 1 file.', '\n'.join(c for n, c in texts if n == 'Grep'))
        self.assertEqual([c for n, c in texts if n == 'Glob'], ['a.py', 'No files found'])
        # the todo tools: TodoWrite with the whole list, or the task tools one item a call
        fake = self.fake(base=REPLAY, FAKE_CLAUDE_TASKS='1')
        fake.initialize(suggestions=False)
        fake.prompt('todo')
        init = fake.until(is_type('system', 'init'))
        fake.until(is_type('result'))
        fake.finish()
        self.assertTrue({'TaskCreate', 'TaskUpdate'} <= set(init['tools']) and 'TodoWrite' not in init['tools'])
        self.assertEqual([n for n in calls(fake.records).values()],
                         ['ToolSearch', 'TaskCreate', 'TaskCreate', 'TaskCreate', 'TaskUpdate'])
        # phase 2's asking scenarios give the recorded results; with `run` they ask nothing (as 2.1.330 ran them)
        fake = self.fake(base=REPLAY)
        fake.initialize(suggestions=False)
        for prompt in ('glob run', 'grep run', 'websearch run', 'read notes.txt', 'image'):
            mark = len(fake.records)
            fake.prompt(prompt)
            fake.until(is_type('result'))
            self.assertFalse([r for r in fake.since(mark) if is_type('control_request')(r)], prompt)
        fake.finish()
        structured = [s for _, s in results(fake.records).values()]
        self.assertEqual(structured[0]['filenames'], ['notes.txt'])
        self.assertEqual([s['mode'] for s in structured[1:4]], ['content', 'files_with_matches', 'count'])
        self.assertEqual(structured[4]['query'], 'rhun editor')
        self.assertEqual(structured[5], 'Error: File does not exist. Note: your current working directory is %s.'
                         % self.project)

    def test_thinking_with_text_and_duration(self):
        fake = self.fake(base=REPLAY)
        fake.initialize(suggestions=False)
        fake.prompt('think 17 times 23 is 391 so the answer is 391')
        fake.until(is_type('result'))
        fake.finish()
        turn = fake.records[next(i for i, r in enumerate(fake.records) if r.get('type') == 'user'):]
        self.assertEqual(claude_shapes.fold_pairs(claude_shapes.shapes(turn)), shape_file('19-thinking'))
        deltas = ''.join(r['event']['delta']['thinking'] for r in fake.records if r.get('type') == 'stream_event'
                         and r['event'].get('delta', {}).get('type') == 'thinking_delta')
        record = next(r for r in fake.records if r.get('type') == 'assistant'
                      and r['message']['content'][0]['type'] == 'thinking')
        said = record['message']['content'][0]['thinking']
        self.assertEqual((said, deltas.strip()), ('17 times 23 is 391 so the answer is 391',) * 2)
        self.assertEqual((record['thinking_duration_ms'], record['thinking_display']), (3109, 'summarized'))
        line = next(l for l in self.lines(self.sid(fake)) if l['type'] == 'assistant')
        self.assertEqual((line['message']['content'][0]['thinking'], line['thinkingDurationMs'], line['thinkingDisplay']),
                         (said, 3109, 'summarized'))
        self.assertEqual(claude_shapes.file_shapes(self.lines(self.sid(fake))), shape_file('file-thinking'))

    def test_agent_records_and_nesting(self):
        log = self.home / 'fake.log'
        fake = self.fake(base=REPLAY, FAKE_CLAUDE_LOG=str(log))
        fake.send({'type': 'control_request', 'request_id': 'r1', 'request': {
            'subtype': 'initialize', 'hooks': None, 'promptSuggestions': False,
            'perTaskStopAffordance': True, 'forwardNestedSubagentToolCalls': True}})
        fake.until(lambda r: r.get('type') == 'control_response')
        fake.prompt('agent')
        first = fake.until(is_type('result'))
        last = fake.until(is_type('result'))
        fake.finish()
        self.assertIn({'initialize': {'promptSuggestions': False, 'supportedDialogKinds': None,
                                      'perTaskStopAffordance': True, 'forwardNestedSubagentToolCalls': True},
                       'pid': fake.process.pid}, logged(log))
        turn = fake.records[next(i for i, r in enumerate(fake.records) if r.get('type') == 'user'):]
        self.assertEqual(claude_shapes.shapes(turn)[:len(shape_file('21-agent'))], shape_file('21-agent'))
        (agent_tid, name), = calls(fake.records).items()
        self.assertEqual(name, 'Agent')
        launched = results(fake.records)[agent_tid][1]
        self.assertEqual(launched['status'], 'async_launched')
        children = calls(fake.records, agent_tid)
        self.assertEqual(list(children.values()), ['Bash', 'Bash'])
        after = fake.records[fake.records.index(first):]
        self.assertTrue(any(r.get('parent_tool_use_id') == agent_tid for r in after), 'the agent works on after the result')
        child = [r for r in fake.records if r.get('parent_tool_use_id') == agent_tid]
        self.assertTrue(all(r.get('agent_id') == launched['agentId'] for r in child))
        self.assertFalse(any('tool_use_result' in r for r in child))
        notified = next(r for r in fake.records if is_type('system', 'task_notification')(r))
        self.assertEqual((notified['task_id'], notified['tool_use_id'], notified['status']),
                         (launched['agentId'], agent_tid, 'completed'))
        self.assertEqual(last['result'], 'The folder has a.py and notes.txt.')
        # on disk: the conversation's file holds no subagent line; the agent's own file and its meta beside it
        sid = self.sid(fake)
        lines = self.lines(sid)
        self.assertFalse([l for l in lines if l.get('isSidechain') or l.get('agentId')])
        self.assertEqual(claude_shapes.file_shapes(lines), shape_file('file-agent'))
        folder = self.transcript(sid).with_suffix('') / 'subagents'
        sub = self.lines(path=folder / ('agent-%s.jsonl' % launched['agentId']))
        self.assertEqual(claude_shapes.file_shapes(sub), shape_file('file-subagent'))
        self.assertTrue(all(l['isSidechain'] and l['agentId'] == launched['agentId'] for l in sub))
        self.assertEqual(file_faults(sub), [])
        meta = json.loads((folder / ('agent-%s.meta.json' % launched['agentId'])).read_text())
        self.assertEqual(meta['toolUseId'], agent_tid)

    def test_stop_task_and_background(self):
        fake = self.fake(base=REPLAY, FAKE_CLAUDE_BG_MS='20000')
        fake.initialize(suggestions=False)
        # an agent stopped while it waits: its task ends killed, the agent's last record the interrupt mark
        fake.prompt('agent wait')
        fake.until(is_type('result'))
        started = next(r for r in fake.records if is_type('system', 'task_started')(r))
        mark = len(fake.records)
        answer = fake.request('r2', 'stop_task', task_id=started['task_id'])['response']
        self.assertEqual(answer, {'subtype': 'success', 'request_id': 'r2', 'response': {}})
        fake.until(is_type('result'))
        records = fake.since(mark)
        self.assertEqual([r['patch']['status'] for r in records if is_type('system', 'task_updated')(r)], ['killed'])
        self.assertEqual([r['status'] for r in records if is_type('system', 'task_notification')(r)], ['stopped'])
        self.assertTrue(any(r.get('parent_tool_use_id') == started['tool_use_id'] and r.get('type') == 'user'
                            and r['message']['content'][0].get('text') == '[Request interrupted by user]' for r in records))
        self.assertEqual(fake.request('r3', 'stop_task', task_id='nothing')['response']['subtype'], 'error')
        # a running call sent to the background: its result at once, then stop_task kills it
        fake.prompt('bg')
        call = fake.until(lambda r: r.get('type') == 'assistant' and r['message']['content'][0].get('type') == 'tool_use')
        tid = call['message']['content'][0]['id']
        fake.until(is_type('system', 'task_started'))
        answer = fake.request('r4', 'background_tasks', tool_use_id=tid)['response']['response']
        self.assertEqual(answer, {'backgrounded': True})
        block = fake.until(is_result_of(tid))
        self.assertTrue(block['message']['content'][0]['content'].startswith('Command was manually backgrounded by user'))
        self.assertTrue(block['tool_use_result']['backgroundedByUser'])
        fake.until(is_type('result'))
        task = [r for r in fake.records if is_type('system', 'background_tasks_changed')(r)][-1]['tasks'][0]
        self.assertEqual(fake.request('r5', 'background_tasks', tool_use_id=tid)['response']['response'],
                         {'backgrounded': False})
        self.assertEqual(fake.request('r6', 'stop_task', task_id=task['task_id'])['response']['response'], {})
        # Stop while it runs: the bundle's cTt text and aborted_tools
        fake.prompt('bg')
        call = fake.until(lambda r: r.get('type') == 'assistant' and r['message']['content'][0].get('type') == 'tool_use')
        fake.until(is_type('system', 'task_started'))
        fake.interrupt('r7')
        stopped = fake.until(is_result_of(call['message']['content'][0]['id']))
        self.assertTrue(stopped['message']['content'][0]['content'].endswith('The instruction to stop and wait still stands.'))
        self.assertEqual(stopped['tool_use_result'], 'User rejected tool use')
        self.assertEqual(fake.until(is_type('result'))['terminal_reason'], 'aborted_tools')
        fake.finish()

    def test_compaction_commands_and_hooks(self):
        # 20-compact: the preserved record sent again, with its uuid
        fake = self.fake(base=REPLAY, FAKE_CLAUDE_PRESERVED='1')
        fake.initialize(suggestions=False)
        fake.prompt('hello')
        fake.until(is_type('result'))
        fake.prompt('/context')
        fake.until(is_type('result'))
        mark = len(fake.records)
        fake.prompt('/compact')
        fake.until(is_type('result'))
        fake.finish()
        excerpt = fake.since(mark)
        self.assertEqual(claude_shapes.shapes(excerpt)[-len(shape_file('20-compact')):], shape_file('20-compact'))
        again = [r for r in excerpt if r.get('type') == 'assistant']
        self.assertEqual(again[0]['uuid'], [r for r in fake.records[:mark] if r.get('type') == 'assistant'][-1]['uuid'])
        # 22-hooks: SessionStart before the answer, UserPromptSubmit before system/init, Stop before the result
        fake = self.fake(*['--include-hook-events'], base=REPLAY, FAKE_CLAUDE_HOOKS='start,prompt,stop,block')
        fake.initialize(suggestions=False)
        fake.prompt('hello', UUID_A)
        fake.until(is_type('result'))
        self.assertEqual(claude_shapes.shapes(fake.records, hooks=True), shape_file('22-hooks'))
        fake.prompt('BLOCKME reply ok')
        blocked = fake.until(is_type('result'))
        fake.prompt('echo hi')
        fake.until(is_type('result'))
        fake.finish()
        self.assertTrue(blocked['result'].startswith('UserPromptSubmit operation blocked by hook:'))
        self.assertTrue(any(is_type('system', 'informational')(r) for r in fake.records))
        lines = self.lines(self.sid(fake))
        self.assertFalse([l for l in lines if l['type'] == 'user' and 'BLOCKME' in json.dumps(l['message'])])
        replayed = [r['message']['content'] for r in fake.records if r.get('type') == 'user' and r.get('isReplay')]
        self.assertIn('<command-message>hi</command-message>\n<command-name>/hi</command-name>', replayed)
        # without --include-hook-events only SessionStart's records
        fake = self.fake(base=REPLAY, FAKE_CLAUDE_HOOKS='start,prompt,stop')
        fake.initialize(suggestions=False)
        fake.prompt('hello')
        fake.until(is_type('result'))
        fake.finish()
        events = {r['hook_event'] for r in fake.records if is_type('system', 'hook_started')(r)}
        self.assertEqual(events, {'SessionStart'})

    def test_unrecorded_scenarios(self):
        fake = self.fake(base=REPLAY)
        fake.initialize(suggestions=False)
        for prompt in ('unknownblock', 'apierror'):
            fake.prompt(prompt)
            fake.until(is_type('result'))
        fake.finish()
        unrecorded(fake, 'mystery', 'api_retry', 'overloaded')
        blocks = [r['message']['content'][0]['type'] for r in fake.records if r.get('type') == 'assistant']
        self.assertIn('mystery', blocks)
        self.assertTrue(any(r.get('error') == 'overloaded' for r in fake.records if r.get('type') == 'assistant'))


def cut_file(name):
    """A phase 4 shape file (claude-shapes --cut-data): [(dir, shape, record or None)], '#' lines (the run that
    follows) as ('#', TEXT, None)."""
    out = []
    for line in (SHAPES / (name + '.txt')).read_text(encoding='utf-8').splitlines():
        out.append(('#', line[1:].strip(), None) if line.startswith('#') else claude_shapes.parse_cut_line(line))
    return out


def run_of(lines, word):
    """The lines of the run whose '#' line starts with word."""
    out, inside = [], False
    for item in lines:
        if item[0] == '#':
            inside = item[1].startswith(word)
        elif inside:
            out.append(item)
    return out


def recorded(lines, direction, kind=None, subtype=None):
    """The detailed records of a direction (and type, and request subtype or message method)."""
    out = []
    for d, _, record in lines:
        if d != direction or record is None or (kind and record.get('type') != kind):
            continue
        request = record.get('request') or {}
        if subtype and subtype not in (request.get('subtype'), (request.get('message') or {}).get('method')):
            continue
        out.append(record)
    return out


PASTE_ID = re.compile(r'pasted_content id=\\*"\d+\\*"')
# a two-page PDF's head as the recorded one (the shape files keep 16 characters of base64)
PDF = base64.b64encode(b'%PDF-1.4\n1 0 obj\n<< >>\nendobj\ntrailer\n<< >>\n%%EOF\n').decode()
DOT = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC'
NOTES = 'alpha\nbravo\ncharlie\ndelta\necho\n'
# the data the recordings sent, by the 16 characters the shape files keep
WHOLE = {DOT: DOT, PDF: PDF, NOTES: NOTES, 'The secret word is mango.\n': 'The secret word is mango.\n',
         base64.b64encode(b'This is not an image, just some text.\n').decode():
             base64.b64encode(b'This is not an image, just some text.\n').decode()}
WHOLE = {key[:16] + '…': value for key, value in WHOLE.items()}
# the extension's three hooks (P 2.2), as finding 48 sent them
EXT_HOOKS = {'PreToolUse': [{'matcher': 'Edit|Write|MultiEdit', 'hookCallbackIds': ['hook_0']},
                            {'matcher': 'Edit|Write|Read', 'hookCallbackIds': ['hook_1']}],
             'PostToolUse': [{'matcher': 'Edit|Write|MultiEdit', 'hookCallbackIds': ['hook_2'], 'contextOnly': True}]}


def whole(value, project):
    """A recorded 'out' record made sendable: cut data restored, $CWD the test's project."""
    if isinstance(value, dict):
        return {k: (WHOLE[v] if k == 'data' and v in WHOLE else whole(v, project)) for k, v in value.items()}
    if isinstance(value, list):
        return [whole(v, project) for v in value]
    if isinstance(value, str):
        return value.replace('$CWD', str(project))
    return value


class Phase4(Base):
    """What phase 4 reads (README.txt findings 38 on; shape files 23 to 26): a message's blocks and their replay,
    rhun's in-process MCP server, the SDK hooks, the answers to an edit."""

    def cut(self, value):
        return claude_shapes.cut(value, [(str(self.project), '$CWD')])

    def mcp_fake(self, *args, servers=('rhun',), hooks=None, manifests=None, answer=None, **env):
        """A fake started with sdkMcpServers (and hooks, manifests), its initialize answer, and a thread that
        answers the CLI's mcp_message requests as the recorder's server did (answer(message): a reply to use
        instead, None to keep the recorder's, False to leave it unanswered)."""
        fake = self.fake(*args, base=REPLAY, **env)
        fake.mcp, fake.hooked = [], []
        request = {'subtype': 'initialize', 'hooks': hooks, 'promptSuggestions': False,
                   'sdkMcpServers': list(servers)}
        if manifests:
            request['sdkMcpServerManifests'] = manifests
        fake.send({'type': 'control_request', 'request_id': 'r1', 'request': request})
        fake.answer_mcp = answer or (lambda message: None)
        return fake

    def serve(self, fake, record):
        """The recorder's answer to an mcp_message of the CLI (24-sdk-mcp's out lines)."""
        message = record['request']['message']
        fake.mcp.append(message)
        mine = fake.answer_mcp(message)
        if mine is False:
            return
        if mine is None:
            if 'id' not in message:
                mine = {'jsonrpc': '2.0', 'result': {}, 'id': 0}
            elif message['method'] == 'initialize':
                mine = {'jsonrpc': '2.0', 'id': message['id'], 'result': {
                    'protocolVersion': message['params']['protocolVersion'],
                    'capabilities': {'tools': {'listChanged': True}}, 'serverInfo': {'name': 'rhun', 'version': '0.19.2'}}}
            elif message['method'] == 'tools/list':
                mine = {'jsonrpc': '2.0', 'id': message['id'], 'result': {'tools': [TOOL]}}
            elif message['method'] == 'tools/call':
                mine = {'jsonrpc': '2.0', 'id': message['id'], 'result': {'content': [{'type': 'text', 'text': DIAG}]}}
            else:
                mine = {'jsonrpc': '2.0', 'id': message['id'], 'error': {'code': -32601, 'message': 'Method not found'}}
        fake.answer(record, {'mcp_response': mine})

    def until_served(self, fake, test, timeout=20):
        """Reads records, serving the CLI's mcp_message requests, until test(record) holds."""
        def step(record):
            if is_type('control_request', 'mcp_message')(record):
                self.serve(fake, record)
            return test(record)
        return fake.until(step, timeout)

    def test_cut_files_parse_and_keep_their_shapes(self):
        for name in ('23-attach', '24-sdk-mcp', '25-sdk-hooks', '26-edit-answer'):
            lines = cut_file(name)
            self.assertTrue(lines, name)
            for direction, shape, record in lines:
                if record is not None:
                    self.assertEqual(claude_shapes.shape(record, hooks=True) or
                                     '%s/%s' % (record.get('type'), record.get('subtype')), shape, (name, record))
                    self.assertNotIn('/Users/', json.dumps(record), name)

    def test_23_blocks_replayed_and_saved_as_recorded(self):
        """The recorded messages (order, image alone, opened file alone, inline_pastes, documents, not an image)
        sent again: the fake's replays are the recorded replays (data cut, the paste id aside); the file's prompt
        lines carry the blocks, imagePasteIds and the isMeta image line."""
        lines = cut_file('23-attach')
        fake = self.fake(base=REPLAY)
        fake.initialize(suggestions=False)
        sent = recorded(run_of(lines, 'order'), 'out', 'user') + recorded(run_of(lines, 'notimage'), 'out', 'user')
        replays = [r for r in recorded(run_of(lines, 'order'), 'in', 'user') + recorded(run_of(lines, 'notimage'), 'in',
                                                                                       'user') if r.get('isReplay')]
        self.assertEqual(len(sent), len(replays))
        for message, expected in zip(sent, replays):
            message = whole(message, self.project)
            message.pop('uuid', None)
            mark = len(fake.records)
            fake.send(message)
            replay = fake.until(lambda r: r.get('type') == 'user' and r.get('isReplay'))
            fake.until(is_type('result'))
            got = json.dumps(self.cut(replay['message']['content']), ensure_ascii=False)
            self.assertEqual(PASTE_ID.sub('id', got), PASTE_ID.sub('id', json.dumps(expected['message']['content'],
                                                                                    ensure_ascii=False)), mark)
        fake.finish()
        lines = Phase3.lines(self, next(r['session_id'] for r in fake.records if is_type('system', 'init')(r)))
        self.assertEqual(file_faults(lines), [])
        prompts = [l for l in lines if l['type'] == 'user' and not l.get('isMeta')
                   and l['message']['content'][0].get('type') != 'tool_result']
        self.assertEqual([p.get('imagePasteIds') for p in prompts], [[1], [2], None, None, None, None, None])
        meta = [l['message']['content'][0]['text'] for l in lines if l.get('isMeta')]
        self.assertEqual(len(meta), 2)
        self.assertTrue(all(m.startswith('[Image: source: /tmp/claude-') and m.endswith('.png]') for m in meta), meta)
        self.assertIn('<pasted_content id=', json.dumps(prompts[3]['message']))

    def test_echoblocks_names_each_block(self):
        fake = self.fake(base=REPLAY)
        fake.initialize(suggestions=False)
        fake.send({'type': 'user', 'message': {'role': 'user', 'content': [
            {'type': 'image', 'source': {'type': 'base64', 'media_type': 'image/png', 'data': DOT}},
            {'type': 'document', 'source': {'type': 'text', 'media_type': 'text/plain', 'data': NOTES},
             'title': 'notes.txt'},
            {'type': 'document', 'source': {'type': 'base64', 'media_type': 'application/pdf', 'data': PDF},
             'title': 'two.pdf'},
            {'type': 'text', 'text': 'echoblocks'}]}, 'parent_tool_use_id': None, 'session_id': ''})
        reply = fake.until(is_type('result'))['result']
        fake.finish()
        self.assertEqual(reply.split('\n'), ['image image/png 69', 'document text/plain notes.txt 31',
                                             'document application/pdf two.pdf %d' % len(base64.b64decode(PDF)),
                                             'text 10'])

    def test_24_handshake_call_error_and_interrupt(self):
        lines = cut_file('24-sdk-mcp')
        asked = [r['request']['message'] for r in recorded(lines, 'in', 'control_request', 'mcp_message')]
        fake = self.mcp_fake(FAKE_CLAUDE_LOG=str(self.home / 'fake.log'))
        # the JSON-RPC initialize goes out before the initialize answer, then initialized and tools/list
        first = fake.until(lambda r: r.get('type') in ('control_request', 'control_response'))
        self.assertTrue(is_type('control_request', 'mcp_message')(first))
        self.assertEqual(first['request']['message'], asked[0])
        self.serve(fake, first)
        self.until_served(fake, lambda r: r.get('type') == 'control_response' and r['response'].get('request_id') == 'r1')
        self.until_served(fake, lambda r: is_type('control_request', 'mcp_message')(r)
                          and r['request']['message'].get('method') == 'tools/list')
        self.assertEqual(fake.mcp[:3], asked[:3])
        for attempt in range(40):          # 44: the server is listed once its tools/list was answered
            fake.send({'type': 'control_request', 'request_id': 'r2-%d' % attempt, 'request': {'subtype': 'mcp_status'}})
            status = self.until_served(fake, lambda r: r.get('type') == 'control_response'
                                       and r['response'].get('request_id') == 'r2-%d' % attempt)
            if status['response']['response']['mcpServers']:
                break
            time.sleep(0.05)
        self.assertEqual(status['response']['response']['mcpServers'],
                         [{'name': 'rhun', 'status': 'connected', 'serverInfo': {'name': 'rhun', 'version': '0.19.2'},
                           'transport': 'sdk', 'scope': 'dynamic', 'source': 'sdk',
                           'tools': [{'name': 'getDiagnostics', 'annotations': {'readOnly': True}}]}])
        # a call: can_use_tool as recorded, then tools/call, then the tool row with the content list
        fake.prompt('diag')
        init = self.until_served(fake, is_type('system', 'init'))
        self.assertIn('mcp__rhun__getDiagnostics', init['tools'])
        self.assertEqual(init['mcp_servers'], [{'name': 'rhun', 'status': 'connected', 'source': 'sdk'}])
        request = self.until_served(fake, is_type('control_request', 'can_use_tool'))
        model = recorded(lines, 'in', 'control_request', 'can_use_tool')[0]['request']
        self.assertEqual(list(request['request']), list(model))
        for key in ('tool_name', 'mcp_server', 'display_name', 'permission_suggestions', 'server_policy_ask_only'):
            self.assertEqual(request['request'][key], model[key], key)
        fake.answer(request, {'behavior': 'allow', 'updatedInput': {}, 'toolUseID': request['request']['tool_use_id']})
        call = self.until_served(fake, lambda r: bool(fake.mcp) and fake.mcp[-1].get('method') == 'tools/call')
        sent_call = fake.mcp[-1]
        model_call = next(m for m in asked if m.get('method') == 'tools/call')
        self.assertEqual(list(sent_call), list(model_call))
        self.assertEqual(list(sent_call['params']['_meta']), list(model_call['params']['_meta']))
        self.assertEqual((sent_call['id'], sent_call['params']['_meta']['progressToken']), (2, 2))
        row = self.until_served(fake, is_result_of(request['request']['tool_use_id']))
        model_row = next(r for r in recorded(lines, 'in', 'user') if isinstance(r['message']['content'], list)
                         and r['message']['content'][0].get('type') == 'tool_result')
        self.assertEqual(list(row['message']['content'][0]), list(model_row['message']['content'][0]))
        self.assertEqual(row['tool_use_result'], row['message']['content'][0]['content'])
        self.assertEqual(self.until_served(fake, is_type('result'))['result'], 'The diagnostics tool returned 1 entry.')
        del call
        # isError: the text as a string, is_error, "Error: " + text
        fake.answer_mcp = lambda m: {'jsonrpc': '2.0', 'id': m['id'], 'result': {
            'content': [{'type': 'text', 'text': 'rhun: the diagnostics are not ready'}], 'isError': True}} \
            if m.get('method') == 'tools/call' else None
        fake.prompt('diag a.py')
        request = self.until_served(fake, is_type('control_request', 'can_use_tool'))
        self.assertEqual(request['request']['input'], {'uri': 'file://%s' % (self.project / 'a.py')})
        fake.answer(request, {'behavior': 'allow', 'updatedInput': request['request']['input'],
                              'toolUseID': request['request']['tool_use_id']})
        row = self.until_served(fake, is_result_of(request['request']['tool_use_id']))
        self.assertEqual((row['message']['content'][0]['content'], row['message']['content'][0]['is_error'],
                          row['tool_use_result']),
                         ('rhun: the diagnostics are not ready', True, 'Error: rhun: the diagnostics are not ready'))
        self.until_served(fake, is_type('result'))
        # a call held and interrupted: notifications/cancelled, no control_cancel_request, the stopped text
        fake.answer_mcp = lambda m: False if m.get('method') == 'tools/call' else None
        mark = len(fake.records)
        fake.prompt('diag')
        request = self.until_served(fake, is_type('control_request', 'can_use_tool'))
        fake.answer(request, {'behavior': 'allow', 'updatedInput': {}, 'toolUseID': request['request']['tool_use_id']})
        before = len(fake.mcp)
        self.until_served(fake, lambda r: len(fake.mcp) > before and fake.mcp[-1].get('method') == 'tools/call')
        held = fake.mcp[-1]
        fake.interrupt('r9')
        cancelled = self.until_served(fake, lambda r: is_type('control_request', 'mcp_message')(r)
                                      and r['request']['message'].get('method') == 'notifications/cancelled')
        model_cancel = next(m for m in asked if m.get('method') == 'notifications/cancelled')
        self.assertEqual(cancelled['request']['message'], dict(model_cancel, params=dict(
            model_cancel['params'], requestId=held['id'])))
        stopped = self.until_served(fake, is_result_of(request['request']['tool_use_id']))
        model_stopped = recorded(lines, 'in', 'user')[-2]
        self.assertEqual(stopped['message']['content'][0]['content'], model_stopped['message']['content'][0]['content'])
        self.assertEqual(stopped['tool_use_result'], model_stopped['tool_use_result'])
        self.assertEqual(self.until_served(fake, is_type('result'))['terminal_reason'], 'aborted_tools')
        self.assertFalse([r for r in fake.since(mark) if r.get('type') == 'control_cancel_request'])
        fake.finish()
        methods = [l['mcp']['method'] for l in logged(self.home / 'fake.log') if 'mcp' in l]
        self.assertEqual(methods[:3], ['initialize', 'notifications/initialized', 'tools/list'])

    def test_24_variants_manifests_off_error_late_never(self):
        # manifests (45): parked, no handshake, the call's id 2
        fake = self.mcp_fake(manifests={'rhun': {'initializeResult': {
            'protocolVersion': '2025-11-25', 'capabilities': {'tools': {'listChanged': True}},
            'serverInfo': {'name': 'rhun', 'version': '0.19.2'}}, 'toolsListResult': {'tools': [TOOL]}}})
        answer = fake.until(lambda r: r.get('type') == 'control_response')['response']['response']
        self.assertEqual(answer['sdk_mcp_manifests_parked'], {'rhun': 'parked'})
        self.assertEqual(list(answer)[list(answer).index('current_permission_mode') + 1], 'sdk_mcp_manifests_parked')
        fake.prompt('diag')
        request = self.until_served(fake, is_type('control_request', 'can_use_tool'))
        fake.answer(request, {'behavior': 'allow', 'updatedInput': {}, 'toolUseID': request['request']['tool_use_id']})
        self.until_served(fake, is_type('result'))
        fake.finish()
        self.assertEqual([(m['method'], m['id']) for m in fake.mcp], [('tools/call', 2)])
        # an older CLI (FAKE_CLAUDE_MCP=off): nothing new at all
        (self.project / 'notes.txt').write_text(NOTES)
        fake = self.mcp_fake(hooks=EXT_HOOKS, FAKE_CLAUDE_MCP='off')
        answer = fake.until(lambda r: r.get('type') == 'control_response')['response']['response']
        self.assertNotIn('hooks_applied', answer)
        fake.prompt('hookedit notes.txt')
        request = fake.until(is_type('control_request', 'can_use_tool'))
        fake.answer(request, {'behavior': 'allow', 'updatedInput': request['request']['input'],
                              'toolUseID': request['request']['tool_use_id']})
        fake.until(is_type('result'))
        fake.finish()
        self.assertFalse([r for r in fake.records if is_type('control_request', 'mcp_message')(r)
                          or is_type('control_request', 'hook_callback')(r)])
        # tools/list answered with an error: asked again three times, then connected without tools (44)
        fake = self.mcp_fake(answer=lambda m: {'jsonrpc': '2.0', 'id': m['id'], 'error': {
            'code': -32603, 'message': 'rhun: no tools today'}} if m.get('method') == 'tools/list' else None,
                             FAKE_CLAUDE_MCP='error')
        fake.prompt('hello')
        init = self.until_served(fake, is_type('system', 'init'))
        self.until_served(fake, is_type('result'))
        fake.finish()
        self.assertEqual([m['method'] for m in fake.mcp], ['initialize', 'notifications/initialized', 'tools/list',
                                                           'tools/list', 'tools/list', 'tools/list', 'resources/list',
                                                           'no/such-method'])
        self.assertEqual(init['mcp_servers'], [{'name': 'rhun', 'status': 'connected', 'source': 'sdk'}])
        self.assertNotIn('mcp__rhun__getDiagnostics', init['tools'])
        # a server that never answers (51): initialize again at half the wait, then failed; the turn waited
        fake = self.mcp_fake(answer=lambda m: False, FAKE_CLAUDE_MCP_WAIT_MS='800')
        started = time.time()
        fake.prompt('hello')
        init = self.until_served(fake, is_type('system', 'init'))
        self.assertGreaterEqual(time.time() - started, 0.7)
        self.assertEqual(init['mcp_servers'], [{'name': 'rhun', 'status': 'failed', 'source': 'sdk'}])
        self.until_served(fake, is_type('result'))
        fake.finish()
        self.assertEqual([m['method'] for m in fake.mcp], ['initialize', 'initialize'])
        # slow: the handshake begins after the initialize answer
        fake = self.mcp_fake(FAKE_CLAUDE_MCP='slow')
        first = fake.until(lambda r: r.get('type') in ('control_request', 'control_response'))
        self.assertEqual(first['type'], 'control_response')
        fake.prompt('diag')
        request = self.until_served(fake, is_type('control_request', 'can_use_tool'))
        fake.answer(request, {'behavior': 'allow', 'updatedInput': {}, 'toolUseID': request['request']['tool_use_id']})
        self.until_served(fake, is_type('result'))
        fake.finish()

    def hook_turn(self, fake, prompt, answers, allow=None):
        """Runs a prompt of a hook scenario: each hook_callback is answered only once every callback of its event
        has arrived (answers(request) gives the answer, None: none), can_use_tool by allow(request) or with its
        own input. The control requests in order."""
        order, waiting = [], []
        fake.prompt(prompt)
        while True:
            record = self.until_served(fake, lambda r: r.get('type') in ('control_request', 'result'))
            if is_type('control_request', 'mcp_message')(record):
                continue
            if record.get('type') == 'result':
                for item in waiting:
                    if answers(item) is not None:
                        fake.answer(item, answers(item))
                return order, record
            order.append(record)
            if is_type('control_request', 'hook_callback')(record):
                waiting.append(record)
                event = record['request']['input']['hook_event_name']
                expected = sum(len(m['hookCallbackIds']) for m in EXT_HOOKS[event]
                               if re.fullmatch(m['matcher'], record['request']['input']['tool_name']))
                if len(waiting) == expected:
                    for item in waiting:
                        if answers(item) is not None:
                            fake.answer(item, answers(item))
                    waiting = []
            elif is_type('control_request', 'can_use_tool')(record):
                fake.answer(record, dict(allow(record) if allow else {
                    'behavior': 'allow', 'updatedInput': record['request']['input']},
                    toolUseID=record['request']['tool_use_id']))

    def test_25_hooks_around_an_edit_a_write_and_a_read(self):
        lines = cut_file('25-sdk-hooks')
        model = [r['request'] for r in recorded(lines, 'in', 'control_request', 'hook_callback')]
        (self.project / 'notes.txt').write_text(NOTES)
        fake = self.mcp_fake(hooks=EXT_HOOKS, FAKE_CLAUDE_LOG=str(self.home / 'fake.log'))
        answer = self.until_served(fake, lambda r: r.get('type') == 'control_response'
                                   and r['response'].get('request_id') == 'r1')['response']['response']
        self.assertTrue(answer['hooks_applied'])
        context = '<ide_diagnostics>[\n  {\n    "filePath": "%s",\n    "line": 2\n  }\n]</ide_diagnostics>' % (
            self.project / 'notes.txt')

        def answers(request):
            if request['request']['input']['hook_event_name'] == 'PostToolUse':
                return {'continue': True, 'hookSpecificOutput': {'hookEventName': 'PostToolUse',
                                                                 'additionalContext': context}}
            return {'continue': True}

        def whole_file(request):
            text = (self.project / 'notes.txt').read_text()
            edit = request['request']['input']
            return {'behavior': 'allow', 'updatedInput': {
                'file_path': edit['file_path'], 'old_string': text,
                'new_string': text.replace(edit['old_string'], edit['new_string'], 1), 'replace_all': False}}
        order, _ = self.hook_turn(fake, 'hookedit notes.txt', answers, whole_file)
        self.assertEqual([(r['request']['subtype'], r['request'].get('callback_id')) for r in order],
                         [(r['subtype'], r.get('callback_id')) for r in model[:2]] + [('can_use_tool', None)] +
                         [(r['subtype'], r.get('callback_id')) for r in model[2:3]])
        for got, want in zip([r['request'] for r in order if r['request']['subtype'] == 'hook_callback'], model):
            self.assertEqual(list(got), list(want))
            self.assertEqual(list(got['input']), list(want['input']))
            self.assertEqual(got['input']['scratchpad_dir'].split('/')[-1], 'scratchpad')
        post = order[-1]['request']['input']
        self.assertEqual(post['tool_input']['old_string'], NOTES)        # the input as allowed
        self.assertEqual(list(post['tool_response']), list(model[2]['input']['tool_response']))
        self.assertEqual((self.project / 'notes.txt').read_text(), 'alpha (edited)\n' + NOTES.split('\n', 1)[1])
        # the context reaches no stream record; the file's line comes right after the call's result
        self.assertFalse([r for r in fake.records if 'ide_diagnostics' in json.dumps(r)
                          and r.get('type') not in ('control_response',)])
        order, _ = self.hook_turn(fake, 'writefile w.txt hi', answers,
                                  lambda r: {'behavior': 'allow', 'updatedInput': dict(r['request']['input'],
                                                                                        content='hello from rhun\n')})
        self.assertEqual([r['request'].get('callback_id', 'ask') for r in order], ['hook_0', 'hook_1', 'ask', 'hook_2'])
        self.assertEqual((self.project / 'w.txt').read_text(), 'hello from rhun\n')
        order, _ = self.hook_turn(fake, 'hookread notes.txt', answers)
        self.assertEqual([r['request'].get('callback_id', 'ask') for r in order], ['hook_1'])
        fake.finish()
        lines = Phase3.lines(self, next(r['session_id'] for r in fake.records if is_type('system', 'init')(r)))
        self.assertEqual(file_faults(lines), [])
        for i, line in enumerate(lines):
            if line['type'] == 'attachment' and line['attachment']['type'] == 'hook_additional_context':
                self.assertEqual(lines[i - 1]['message']['content'][0]['type'], 'tool_result')
                self.assertEqual(line['parentUuid'], lines[i - 1]['uuid'])
                self.assertEqual(line['attachment']['content'], [context])
                self.assertEqual(line['renderedRole'], 'system')
        self.assertEqual(sorted(l['attachment']['hookName'] for l in lines if l['type'] == 'attachment'),
                         ['PostToolUse:Edit', 'PostToolUse:Write'])
        hooks = [l['hook'] for l in logged(self.home / 'fake.log') if 'hook' in l]
        self.assertEqual([h['callback_id'] for h in hooks][:3], ['hook_0', 'hook_1', 'hook_2'])

    def test_25_a_deadline_and_an_unknown_answer(self):
        (self.project / 'notes.txt').write_text(NOTES)
        fake = self.mcp_fake(hooks=EXT_HOOKS, FAKE_CLAUDE_HOOK_DEADLINE='300')
        fake.prompt('hookedit notes.txt')
        first = self.until_served(fake, is_type('control_request', 'hook_callback'))
        self.assertNotIn('deadline_ms', first['request'])                # 48: 2.1.330 sends none
        request = self.until_served(fake, is_type('control_request', 'can_use_tool'))   # nobody answered the hooks
        fake.answer(request, {'behavior': 'allow', 'updatedInput': request['request']['input'],
                              'toolUseID': request['request']['tool_use_id']})
        post = self.until_served(fake, is_type('control_request', 'hook_callback'))
        fake.answer(post, {'weird': True})
        self.assertEqual(self.until_served(fake, is_type('result'))['result'], 'edited')
        fake.finish()

    def test_26_answers_to_an_edit(self):
        lines = cut_file('26-edit-answer')
        texts = [r['message']['content'][0]['content'] for r in recorded(lines, 'in', 'user')
                 if isinstance(r['message']['content'], list) and r['message']['content'][0].get('is_error')]
        (self.project / 'notes.txt').write_text(NOTES)
        (self.project / 'crlf.txt').write_bytes(b'one\r\ntwo\r\nthree\r\nfour\r\nfive\r\n')
        fake = self.fake(base=REPLAY)
        fake.initialize(suggestions=False)

        def turn(prompt, answer, before=None):
            fake.prompt(prompt)
            request = fake.until(is_type('control_request', 'can_use_tool'))
            if before:
                before()
            fake.answer(request, dict(answer(request['request']), toolUseID=request['request']['tool_use_id']))
            tid = request['request']['tool_use_id']
            row = fake.until(is_result_of(tid))
            return row, fake.until(is_type('result'))
        # deny with interrupt: Yb whatever the message, aborted_tools, the denial listed
        row, end = turn('editfile notes.txt bravo BRAVO',
                        lambda r: {'behavior': 'deny', 'message': 'User cancelled the edit', 'interrupt': True})
        self.assertEqual(row['message']['content'][0]['content'], texts[0])
        self.assertEqual(row['tool_use_result'], 'User rejected tool use')
        self.assertEqual((end['terminal_reason'], [d['tool_name'] for d in end['permission_denials']]),
                         ('aborted_tools', ['Edit']))
        # an allow after the file changed: the recorded refusal, the file untouched
        row, _ = turn('editfile notes.txt bravo BRAVO', lambda r: {'behavior': 'allow', 'updatedInput': r['input']},
                      lambda: (self.project / 'notes.txt').write_text('alpha\nchanged meanwhile\n'))
        self.assertEqual(row['message']['content'][0]['content'], texts[1])
        self.assertEqual((self.project / 'notes.txt').read_text(), 'alpha\nchanged meanwhile\n')
        # CR LF: LF strings, CR LF kept; then a whole-file LF updatedInput, CR LF kept
        row, _ = turn('editfile crlf.txt two TWO', lambda r: {'behavior': 'allow', 'updatedInput': r['input']})
        self.assertEqual(row['tool_use_result']['originalFile'], 'one\ntwo\nthree\nfour\nfive\n')
        self.assertEqual((self.project / 'crlf.txt').read_bytes(), b'one\r\nTWO\r\nthree\r\nfour\r\nfive\r\n')
        turn('editfile crlf.txt three THREE', lambda r: {'behavior': 'allow', 'updatedInput': {
            'file_path': r['input']['file_path'], 'old_string': 'one\nTWO\nthree\nfour\nfive\n',
            'new_string': 'one\nTWO\nTHREE\nfour\nfive\n', 'replace_all': False}})
        self.assertEqual((self.project / 'crlf.txt').read_bytes(), b'one\r\nTWO\r\nTHREE\r\nfour\r\nfive\r\n')
        fake.finish()

    def test_notify_and_the_logged_members(self):
        log = self.home / 'fake.log'
        fake = self.mcp_fake(hooks=EXT_HOOKS, FAKE_CLAUDE_LOG=str(log))
        fake.prompt('notify')
        self.until_served(fake, is_type('result'))
        fake.finish()
        self.assertEqual([m.get('method') for m in fake.mcp][-2:], ['experiment_gates', 'file_updated'])
        init = next(l['initialize'] for l in logged(log) if 'initialize' in l)
        self.assertEqual((init['sdkMcpServers'], init['hooks']), (['rhun'], EXT_HOOKS))


# the recorder's server (finding 46): one tool, one entry for a.py
TOOL = {'name': 'getDiagnostics', 'description': 'Get the errors, warnings and other diagnostics rhun shows.',
        'inputSchema': {'type': 'object', 'properties': {'uri': {'type': 'string'}}},
        'annotations': {'title': 'Get diagnostics', 'readOnlyHint': True}}
DIAG = json.dumps([{'uri': 'file:///p/a.py', 'linesInFile': 10, 'diagnostics': [
    {'message': 'invalid syntax', 'severity': 'Error', 'range': {'start': {'line': 3, 'character': 11},
                                                                'end': {'line': 3, 'character': 12}},
     'source': 'python', 'code': 'E999'}]}], separators=(',', ':'))


def logged(path):
    """The fake's log lines."""
    return [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines()]



class Phase6b(Base):
    """Fork from a message, rewind, export, a cut turn run again (README findings 102 to 106; claude-chat-p6b)."""

    def lines(self, sid):
        return [json.loads(line) for line in self.transcript(sid).read_text(encoding='utf-8').splitlines()]

    def prompt_lines(self, sid):
        return [r for r in self.lines(sid) if r.get('type') == 'user' and isinstance(r['message']['content'], list)
                and r['message']['content'][0].get('type') == 'text']

    def chat(self, *prompts, args=(), **env):
        fake = self.fake(*args, base=REPLAY, **env)
        fake.initialize()
        sid = None
        for prompt in prompts:
            fake.prompt(prompt, str(uuid_mod.uuid4()))
            sid = fake.until(is_type('system', 'init'))['session_id']
            fake.until(is_type('result'))
        fake.finish()
        return sid

    def test_fork_keeps_the_source_up_to_an_entry(self):
        sid = self.chat('one', 'two')
        parent = self.prompt_lines(sid)[1]['parentUuid']
        self.assertEqual(parent, [r for r in self.lines(sid) if r.get('type') == 'assistant'][0]['uuid'])
        new = '0b5e1c4e-2f1a-4b5e-9d1c-3a2b1c0d9e8f'
        copy = self.fake('--resume', sid, '--fork-session', '--session-id', new, '--resume-session-at', parent,
                         base=REPLAY)
        copy.initialize()
        copy.prompt('three', str(uuid_mod.uuid4()))
        copy.until(is_type('result'))
        copy.finish()
        texts = [r['message']['content'][0].get('text') for r in self.lines(new) if r.get('type') in ('user', 'assistant')]
        self.assertEqual(texts, ['one', 'ok: one', 'three', 'ok: three'])
        self.assertEqual(self.prompt_lines(new)[1]['parentUuid'], parent)
        gone = self.fake('--resume', sid, '--fork-session', '--session-id', '1b5e1c4e-2f1a-4b5e-9d1c-3a2b1c0d9e8f',
                         '--resume-session-at', '99999999-0000-4000-8000-000000000000', base=REPLAY)
        record = gone.until(is_type('result'))
        self.assertEqual(record['errors'], ['No message found with message.uuid of: '
                                            '99999999-0000-4000-8000-000000000000'])
        self.assertEqual(gone.process.wait(10), 1)

    def test_rewind_files_and_checkpoints(self):
        on = {'CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING': 'true'}
        target = self.project / 'a.txt'
        sid = self.chat('write a.txt one', 'write a.txt two\nthree', args=('--permission-mode', 'acceptEdits'), **on)
        self.assertEqual(target.read_text(), 'two\nthree')
        first, second = [r['uuid'] for r in self.prompt_lines(sid)]
        snaps = [r for r in self.lines(sid) if r.get('type') == 'file-history-snapshot']
        self.assertEqual([(r['messageId'], r['isSnapshotUpdate']) for r in snaps],
                         [(first, False), (first, True), (second, False)])
        fake = self.fake('--resume', sid, base=REPLAY, **on)
        fake.initialize()
        check = fake.request('r2', 'rewind_files', user_message_id=second, dry_run=True)['response']['response']
        self.assertEqual(check, {'canRewind': True, 'filesChanged': [str(target)], 'insertions': 1, 'deletions': 2})
        self.assertEqual(target.read_text(), 'two\nthree')
        self.assertEqual(fake.request('r3', 'rewind_files', user_message_id='nope')['response']['response'],
                         {'canRewind': False, 'error': 'No file checkpoint found for this message.'})
        self.assertEqual(fake.request('r4', 'rewind_files', user_message_id=second)['response']['response'],
                         {'canRewind': True, 'skippedLinks': 0})
        self.assertEqual(target.read_text(), 'one')
        fake.request('r5', 'rewind_files', user_message_id=first)
        self.assertFalse(target.exists())
        fake.finish()
        off = self.fake('--resume', sid, base=REPLAY, CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING='false')
        off.initialize()
        self.assertEqual(off.request('r2', 'rewind_files', user_message_id=second)['response']['response'],
                         {'canRewind': False, 'error': 'File rewinding is not enabled.'})
        off.finish()
        self.assertEqual(file_faults(self.lines(sid)), [])

    def test_export(self):
        sid = self.chat('hello there', 'again')
        fake = self.fake('--resume', sid, base=REPLAY)
        fake.initialize()
        answer = fake.request('r2', 'export_conversation')['response']['response']
        self.assertEqual(answer['text'], '\n❯ hello there\n\n⏺ ok: hello there\n❯ again\n\n⏺ ok: again')
        self.assertRegex(answer['default_filename'], r'^\d{4}-\d\d-\d\d-\d{6}-hello-there\.txt$')
        fake.finish()

    def test_a_cut_turn_runs_again(self):
        first = self.fake(base=REPLAY)
        first.initialize()
        first.prompt('linger 30', str(uuid_mod.uuid4()))
        sid = first.until(is_type('system', 'init'))['session_id']
        first.until(lambda r: r.get('type') == 'user' and r.get('isReplay'))
        time.sleep(0.3)
        first.process.send_signal(signal.SIGTERM)
        first.process.wait(10)
        cut = self.prompt_lines(sid)[-1]['uuid']
        quiet = self.fake('--resume', sid, base=REPLAY, CLAUDE_CODE_RESUME_INTERRUPTED_TURN='0')
        quiet.initialize()
        time.sleep(0.5)
        quiet.finish()
        self.assertFalse([r for r in quiet.records if r.get('type') in ('assistant', 'result')])
        again = self.fake('--resume', sid, base=REPLAY, CLAUDE_CODE_RESUME_INTERRUPTED_TURN='1',
                          CLAUDE_CODE_RESUME_INTERRUPTED_TURN_MAX_AGE_MS='3600000')
        again.initialize()
        reply = again.until(is_type('assistant'))
        result = again.until(is_type('result'))
        self.assertEqual((reply['resume_reason'], reply['user_message_uuid']), ('interrupted_turn', cut))
        self.assertEqual((result['resume_reason'], result['user_message_uuid'], result['result']),
                         ('interrupted_turn', cut, 'ok: linger 30'))
        again.finish()
        self.assertFalse([r for r in again.records if r.get('type') == 'user' and r.get('isReplay')])
        done = self.fake('--resume', sid, base=REPLAY, CLAUDE_CODE_RESUME_INTERRUPTED_TURN='1')
        done.initialize()
        time.sleep(0.5)
        done.finish()
        self.assertFalse([r for r in done.records if r.get('type') == 'assistant'])


if __name__ == '__main__':
    unittest.main()
