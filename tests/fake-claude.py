#!/usr/bin/env python3
"""tests/scripts/fake-claude.py against the recordings of Claude Code 2.1.330 (2.1.289 for the kinds the
2.1.330 runs did not produce): the same records in the same order (tests/data/claude-shapes, made from the
recordings by tools/claude-shapes.py; README.txt there has the command line and what was learned) and the
fields rhun reads. The fake cannot drift from the CLI without this failing (spec 11)."""
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


def logged(path):
    """The fake's log lines."""
    return [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines()]


if __name__ == '__main__':
    unittest.main()
