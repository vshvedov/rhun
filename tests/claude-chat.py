#!/usr/bin/env python3
"""Claude Code's chat in the agents panel, against the fake CLI (tests/scripts/fake-claude.py), over
the control socket. Every rhun gets its own HOME and XDG folders and a config whose [claude] section
starts the fake through python3; the environment it is given has no CLAUDE* or ANTHROPIC* variable
(these tests run inside Claude Code sessions too), and TERM is set, so rhun uses that environment
instead of asking a login shell for one."""
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
EXE = Path(os.environ.get('RHUN_TEST_EXE', ROOT / 'build/rhun')).resolve()
FAKE = ROOT / 'tests/scripts/fake-claude.py'
PYTHON = Path(sys.executable).resolve()


def clean_env(base):
    """base without the variables a surrounding Claude Code session sets."""
    return {k: v for k, v in base.items() if not k.startswith(('CLAUDE', 'ANTHROPIC'))}


def slug(path):
    """The folder name Claude Code gives a working directory (UTF-16 units, as its JS regex sees them)."""
    out = []
    for ch in str(path):
        if re.fullmatch(r'[A-Za-z0-9]', ch):
            out.append(ch)
        else:
            out.append('--' if ord(ch) > 0xffff else '-')
    return ''.join(out)


def section(text, name):
    """The lines of one [section] of a config file, as written."""
    lines, inside = [], False
    for line in text.splitlines():
        if line.startswith('['):
            inside = line.strip() == '[' + name + ']'
            continue
        if inside and line.strip():
            lines.append(line.rstrip())
    return lines


@unittest.skipIf(os.name == 'nt', 'the control socket is Unix only')
class ChatCase(unittest.TestCase):
    """The shared part: a project, rhun started with a config, commands over the socket, the end."""

    BASE = ('[files]\nrestore_session = false\nrestore_project = false\n'
            '[updates]\ncheck = false\n[git]\nenabled = false\n'
            '[editor]\ncursor_blink = false\n[ui]\nsidebar = false\n')

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rhun-claude-chat-')
        self.work = Path(self.tmp.name).resolve()
        self.project = self.work / 'project'
        self.project.mkdir()
        self.config = self.work / 'config/rhun/config'
        self.config.parent.mkdir(parents=True)
        self.fake_log = self.work / 'fake-claude.log'
        self.env = dict(clean_env(os.environ), HOME=str(self.work), XDG_CONFIG_HOME=str(self.work / 'config'),
                        XDG_STATE_HOME=str(self.work / 'state'), GIT_CONFIG_NOSYSTEM='1', TERM='dumb',
                        FAKE_CLAUDE_LOG=str(self.fake_log))
        self.process = self.client = self.reader = None

    def tearDown(self):
        self.stop()
        self.tmp.cleanup()

    def claude_section(self, extra=''):
        """[claude] with the fake as the program, then extra lines."""
        return f'[claude]\nwrapper = {PYTHON}\nexecutable = {FAKE}\n' + extra

    def start(self, claude=None, extra='', env=None):
        """rhun on the project with BASE + claude (default: claude_section()) + extra as its config."""
        if claude is None:
            claude = self.claude_section()
        self.config.write_text(self.BASE + claude + extra, encoding='utf-8')
        control = self.work / 'control'
        if control.exists():
            control.unlink()
        self.process = subprocess.Popen([str(EXE), str(self.project), '--headless', '1280x800',
                                         '--scale', '1', '--control', str(control)],
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

    def command(self, line):
        """Send one control command; its output without the final ok."""
        self.client.sendall((line + '\n').encode('utf-8'))
        output = []
        while True:
            reply = self.reader.readline()
            if reply == 'ok\n':
                return ''.join(output)
            self.assertNotIn(reply, ('', 'error\n'), line)
            output.append(reply)

    def reply(self, line):
        """Send one control command; its output and whether it answered ok (rather than error)."""
        self.client.sendall((line + '\n').encode('utf-8'))
        output = []
        while True:
            reply = self.reader.readline()
            if reply in ('ok\n', 'error\n'):
                return ''.join(output), reply == 'ok\n'
            self.assertNotEqual(reply, '', line)
            output.append(reply)

    def quit(self):
        """End rhun the way the user does (it writes its config if a setting changed), and wait."""
        self.client.sendall(b'quit\n')
        self.assertEqual(self.process.wait(timeout=15), 0)
        self.stop()

    def stop(self):
        """Tear down: quit, so rhun ends what it started (the discovery worker would go on writing in
        the test's folder after a kill); by pid when that fails, never by name: the user runs rhun and
        claude of their own."""
        if self.process is not None and self.process.poll() is None:
            try:
                self.client.sendall(b'quit\n')
                self.process.wait(timeout=10)
            except (OSError, subprocess.TimeoutExpired):
                self.process.kill()
                self.process.wait(timeout=10)
        for closable in (self.reader, self.client):
            if closable is not None:
                closable.close()
        if self.process is not None:
            self.process.stderr.close()
        self.process = self.client = self.reader = None


class SettingsTest(ChatCase):
    def test_claude_settings_show_and_are_written_back(self):
        claude = self.claude_section('chat = false\ninitial_mode = plan\n'
                                     'env.FOO = very-secret-value\nenv.ANSWER_2 = forty two\n')
        self.start(claude, '[agents]\nidle_stop_minutes = 15\n')
        out = self.command('print-settings')
        for row in ('claude.chat', 'claude.executable', 'claude.wrapper', 'claude.initial_mode',
                    'agents.idle_stop_minutes', 'claude.env.FOO=(set)', 'claude.env.ANSWER_2=(set)'):
            self.assertIn(row + '\n', out)
        self.assertNotIn('very-secret-value', out)
        self.assertNotIn('forty two', out)
        # the rows of the section are together, the pairs after them
        rows = [line for line in out.splitlines() if line.startswith('claude.')]
        self.assertEqual(rows, ['claude.chat', 'claude.executable', 'claude.wrapper', 'claude.initial_mode',
                                'claude.env.FOO=(set)', 'claude.env.ANSWER_2=(set)'])
        self.command('cmd toggle_word_wrap')         # a setting changed: the exit writes the file
        self.quit()
        saved = self.config.read_text(encoding='utf-8')
        self.assertEqual(section(saved, 'claude'), [
            'chat = false', f'executable = {FAKE}', f'wrapper = {PYTHON}', 'initial_mode = plan',
            'env.FOO = very-secret-value', 'env.ANSWER_2 = forty two'])
        self.assertIn('idle_stop_minutes = 15', section(saved, 'agents'))

    def test_defaults_and_odd_values(self):
        # manual is the CLI's old name of default; a bad name, a long pair and an out-of-range number
        claude = ('[claude]\ninitial_mode = manual\nenv.1BAD = x\nenv.A-B = y\nenv.OK = fine\n'
                  'env.HUGE = ' + 'v' * 9000 + '\n')
        self.start(claude, '[agents]\nidle_stop_minutes = 999\n')
        out = self.command('print-settings')
        pairs = [line for line in out.splitlines() if line.startswith('claude.env.')]
        self.assertEqual(pairs, ['claude.env.OK=(set)'])
        self.command('cmd toggle_word_wrap')
        self.quit()
        saved = self.config.read_text(encoding='utf-8')
        self.assertEqual(section(saved, 'claude'), [
            'chat = true', 'executable =', 'wrapper =', 'initial_mode = default', 'env.OK = fine'])
        self.assertIn('idle_stop_minutes = 240', section(saved, 'agents'))

    def test_the_cli_default_mode_is_written_empty(self):
        self.start('[claude]\ninitial_mode = plan\n')
        self.command('cmd toggle_word_wrap')
        self.quit()
        self.start('[claude]\ninitial_mode =\n')
        self.command('cmd toggle_word_wrap')
        self.quit()
        saved = self.config.read_text(encoding='utf-8')
        self.assertIn('initial_mode =', section(saved, 'claude'))
        self.assertIn('idle_stop_minutes = 10', section(saved, 'agents'))

    def test_the_settings_page_names_the_section(self):
        self.start()
        self.command('cmd settings')
        # the search matches a row's section title too: "code" is only in the title, "Claude Code"
        self.command('type code wrapper')
        self.assertEqual(self.command('print-settings'), 'claude.wrapper\n')


class ExecutableTest(ChatCase):
    """claude_exe: the program and its wrapper, found the way the chat starts them."""

    def setUp(self):
        super().setUp()
        self.bin = self.work / 'bin'
        self.bin.mkdir()
        # a PATH with nothing called claude on it but what a test puts in bin
        self.env['PATH'] = f'{self.bin}:/usr/bin:/bin'

    def program(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('#!/bin/sh\nexit 0\n', encoding='utf-8')
        path.chmod(0o755)
        return path

    def exe(self, claude):
        self.start(claude)
        out = self.command('print-claude-exe')
        self.stop()
        return out.splitlines()

    def test_wrapper_and_executable(self):
        self.assertEqual(self.exe(self.claude_section()), [str(PYTHON), str(FAKE)])

    def test_a_bare_name_is_looked_up_on_path(self):
        claude = self.program(self.bin / 'claude')
        wrap = self.program(self.bin / 'mywrap')
        self.assertEqual(self.exe('[claude]\n'), [str(claude)])
        self.assertEqual(self.exe('[claude]\nwrapper = mywrap\n'), [str(wrap), str(claude)])
        other = self.program(self.bin / 'other-claude')
        self.assertEqual(self.exe('[claude]\nexecutable = other-claude\n'), [str(other)])

    def test_the_usual_places_follow_path(self):
        local = self.program(self.work / '.local/bin/claude')
        self.assertEqual(self.exe('[claude]\n'), [str(local)])
        self.assertEqual(self.exe('[claude]\nexecutable = ~/.local/bin/claude\n'), [str(local)])

    def test_a_missing_program_is_none(self):
        self.program(self.bin / 'claude')
        self.assertEqual(self.exe('[claude]\nexecutable = /nonexistent/claude\n'), ['none'])
        self.assertEqual(self.exe('[claude]\nexecutable = no-such-claude\n'), ['none'])
        self.assertEqual(self.exe('[claude]\nwrapper = no-such-wrapper\n'), ['none'])
        self.program(self.work / 'plain-file').chmod(0o644)
        self.assertEqual(self.exe(f'[claude]\nexecutable = {self.work / "plain-file"}\n'), ['none'])


class TranscriptPathTest(ChatCase):
    """claude_transcript: where the CLI writes a conversation's file."""

    def path(self, cwd, sid='0b8d6f2e-1111-4222-8333-444455556666', claude='[claude]\n', env=None):
        self.start(claude, env=env)
        out = self.command(f'print-claude-path {cwd} {sid}')
        self.stop()
        return out.rstrip('\n')

    def test_a_linked_folder_gives_the_resolved_slug(self):
        link = self.work / 'link'
        link.symlink_to(self.project)
        sid = '0b8d6f2e-1111-4222-8333-444455556666'
        expected = self.work / '.claude/projects' / slug(self.project) / (sid + '.jsonl')
        self.assertEqual(self.path(link, sid), str(expected))
        self.assertEqual(self.path(self.project, sid), str(expected))

    def test_the_config_folder(self):
        sid = 's1'
        # an absolute env.CLAUDE_CONFIG_DIR wins over the environment's, a relative one does not count
        configured = self.work / 'configured'
        given = self.work / 'given'
        name = slug(self.project) + '/s1.jsonl'
        self.assertEqual(self.path(self.project, sid, f'[claude]\nenv.CLAUDE_CONFIG_DIR = {configured}/\n',
                                   env={'CLAUDE_CONFIG_DIR': str(given)}), f'{configured}/projects/{name}')
        self.assertEqual(self.path(self.project, sid, '[claude]\nenv.CLAUDE_CONFIG_DIR = relative/dir\n',
                                   env={'CLAUDE_CONFIG_DIR': str(given)}), f'{given}/projects/{name}')
        self.assertEqual(self.path(self.project, sid, env={'CLAUDE_CONFIG_DIR': ''}),
                         f'{self.work}/.claude/projects/{name}')

    def test_slug_rules(self):
        # not on disk: taken as given. Other characters are '-', those past U+FFFF two; 200 bytes at most
        odd = '/nonexistent/café-\U0001F600.x'
        self.assertEqual(self.path(odd, 's'), f'{self.work}/.claude/projects/{slug(odd)}/s.jsonl')
        deep = '/nonexistent/' + 'a' * 250
        self.assertEqual(self.path(deep, 's'), f'{self.work}/.claude/projects/{slug(deep)[:200]}/s.jsonl')


class DiscoveryTest(ChatCase):
    def test_the_index_reads_the_configured_folder(self):
        folder = self.work / 'claude-config'
        sessions = folder / 'projects' / slug(self.project)
        sessions.mkdir(parents=True)
        fixture = (ROOT / 'tests/data/agents/claude.jsonl').read_text(encoding='utf-8')
        (sessions / 's1.jsonl').write_text(fixture.replace('@PROJECT@', self.project.as_posix()),
                                           encoding='utf-8')
        self.start(f'[claude]\nenv.CLAUDE_CONFIG_DIR = {folder}\n')
        self.command('cmd focus_agents')
        self.command('wait-agents')
        self.assertEqual(self.command('print-agents-page'), 'shown=1 total=1 loading=0 error=0\n')



class SeamTest(ChatCase):
    """The prompt box and cards through the driver table (agent_drv.s): a Claude Code conversation has
    the box when the chat is on; other sessions keep none."""

    def setUp(self):
        super().setUp()
        self.env['CODEX_HOME'] = str(self.work / '.codex')
        self.env['GROK_HOME'] = str(self.work / '.grok')
        sessions = self.work / '.claude/projects' / slug(self.project)
        sessions.mkdir(parents=True)
        fixture = (ROOT / 'tests/data/agents/claude.jsonl').read_text(encoding='utf-8')
        (sessions / 's1.jsonl').write_text(fixture.replace('@PROJECT@', self.project.as_posix()),
                                           encoding='utf-8')
        codex = self.work / '.codex/sessions/2026/09/26'
        codex.mkdir(parents=True)
        fixture = (ROOT / 'tests/data/agents/codex.jsonl').read_text(encoding='utf-8')
        (codex / 'rollout-c1.jsonl').write_text(fixture.replace('@PROJECT@', self.project.as_posix()),
                                                encoding='utf-8')

    def rows(self):
        """The list's rows (print-agents before anything is open), waiting for discovery."""
        self.command('cmd focus_agents')
        self.command('wait-agents')
        rows = self.command('print-agents').splitlines()
        self.assertEqual(len(rows), 2, rows)
        return rows

    def open_row(self, kind):
        """Open the first row of that kind (Claude, Codex); its print-agent-input lines."""
        n = next(i for i, row in enumerate(self.rows()) if row.startswith(kind + ':')) + 1
        self.command(f'print-agents {n}')
        return self.command('print-agent-input').splitlines()

    def test_a_claude_conversation_has_the_box(self):
        self.start()
        lines = self.open_row('Claude')
        self.assertTrue(lines[0].endswith(' box=1'), lines)
        self.assertEqual(self.command('print-agent-live'),
                         'state=off pid=0 sid= mode= queued=0 requests=0 new=0\n')

    def test_send_gives_the_drivers_error_row(self):
        self.start('[claude]\nexecutable = /nonexistent/claude\n')
        self.open_row('Claude')
        out, ok = self.reply('agent-prompt hello')
        self.assertTrue(ok)
        self.command('wait-agent failed 5000')
        thread = self.command('print-agents').splitlines()
        missing = ('Claude Code was not found. Install it, or set its path in Settings > Claude Code.')
        self.assertEqual(thread[-1], 'error ' + missing[:60])
        self.assertNotIn('user hello', thread)      # it never went: the text stays in the box
        self.assertTrue(self.command('print-agent-input').startswith('input=hello '))
        self.assertEqual(self.command('print-agent-live').splitlines(),
                         ['state=failed pid=0 sid= mode= queued=0 requests=0 new=0', 'report=' + missing])

    def test_chat_off_has_no_box(self):
        self.start(self.claude_section('chat = false\n'))
        lines = self.open_row('Claude')
        self.assertTrue(lines[0].endswith(' box=0'), lines)
        out, ok = self.reply('agent-prompt x')
        self.assertFalse(ok)
        self.assertNotIn('error x', self.command('print-agents'))
        out, ok = self.reply('agent-new claude')
        self.assertFalse(ok)

    def test_a_codex_session_has_no_box(self):
        self.start()
        lines = self.open_row('Codex')
        self.assertTrue(lines[0].endswith(' box=0'), lines)
        out, ok = self.reply('agent-prompt x')
        self.assertFalse(ok)

    def test_a_new_claude_draft(self):
        self.start()
        self.command('agent-new claude')
        self.assertEqual(self.command('print-agent-input'), 'input= focus=1 new=claude pending=0 box=1\n')
        self.command('key Escape')                  # out of the box
        self.command('key Escape')                  # and the draft
        self.assertEqual(self.command('print-agent-input'), 'input= focus=0 new=- pending=0 box=0\n')

    def test_wait_agent_times_out_with_the_state(self):
        self.start()
        self.open_row('Claude')
        out, ok = self.reply('wait-agent ready|working 300')
        self.assertFalse(ok)
        self.assertEqual(out, 'timeout state=off\n')
        out, ok = self.reply('wait-agent bogus 300')
        self.assertFalse(ok)


MOD = 'cmd' if sys.platform == 'darwin' else 'ctrl'
ROLES = ('user', 'agent', 'tool', 'result', 'error', 'info')
PINNED = ['--output-format', 'stream-json', '--verbose', '--input-format', 'stream-json',
          '--include-partial-messages', '--permission-prompt-tool=stdio',
          '--setting-sources=user,project,local', '--max-thinking-tokens=31999']
MODEL = 'claude-opus-5-5'
REPLY = f'agent({MODEL}) '            # the first reply of a conversation names its model
SLOW_ROW = REPLY + ''.join('word%d ' % i for i in range(10))     # print-agents shows 60 bytes
UUID4 = re.compile(r'[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}')
BACK = (922, 60)                    # the open conversation's Back button (1280x800, the agents panel alone)


class DrivenCase(ChatCase):
    """The fake's log and the open conversation's rows."""

    def records(self):
        """The fake's log, a record a line."""
        if not self.fake_log.exists():
            return []
        return [json.loads(line) for line in self.fake_log.read_text(encoding='utf-8').splitlines() if line]

    def starts(self):
        return [r for r in self.records() if r.get('start') == 'stream']

    def stdin(self):
        """The lines the fake read, parsed."""
        return [json.loads(r['stdin']) for r in self.records() if 'stdin' in r]

    def prompts(self):
        """The texts of the user messages the fake read."""
        return [m['message']['content'][0]['text'] for m in self.stdin() if m.get('type') == 'user']

    def thread(self):
        """The open conversation's rows (print-agents: the list's rows first, then these)."""
        return [line for line in self.command('print-agents').splitlines()
                if line.split(' ')[0].split('(')[0] in ROLES]

    def live(self):
        return self.command('print-agent-live')

    def sid(self):
        return re.search(r' sid=(\S*)', self.live()).group(1)

    def chat(self, prompt, wait='ready', ms=10000):
        """A new conversation, its first prompt, and the state waited for."""
        self.command('agent-new claude')
        self.command('agent-prompt ' + prompt)
        if wait:
            self.command(f'wait-agent {wait} {ms}')

    def seed(self, sid='s1'):
        """A transcript of the project's conversation sid (the agents fixture)."""
        folder = self.work / '.claude/projects' / slug(self.project)
        folder.mkdir(parents=True, exist_ok=True)
        fixture = (ROOT / 'tests/data/agents/claude.jsonl').read_text(encoding='utf-8')
        path = folder / (sid + '.jsonl')
        path.write_text(fixture.replace('@PROJECT@', self.project.as_posix()), encoding='utf-8')
        return path

    def listed(self):
        """The list's rows once discovery is done (print-agents shows the page's rows first)."""
        self.command('cmd focus_agents')
        self.command('wait-agents')
        return [line for line in self.command('print-agents').splitlines() if line.startswith('Claude')]

    def open_listed(self):
        """Open the one listed conversation; its rows."""
        rows = self.listed()
        self.assertEqual(len(rows), 1, rows)
        self.command('print-agents 1')
        return self.thread()

    def until_gone(self):
        """Until the open session's process is reaped (its file read again)."""
        deadline = time.monotonic() + 10
        while ' pid=1 ' in self.live():
            self.assertLess(time.monotonic(), deadline, self.live())
            time.sleep(0.05)

    def until(self, check, what, seconds=10):
        deadline = time.monotonic() + seconds
        while True:
            value = check()
            if value:
                return value
            self.assertLess(time.monotonic(), deadline, what)
            time.sleep(0.05)


class ChatTest(DrivenCase):
    """A new conversation with the fake: the start, the handshake, a prompt, the streamed reply."""

    def test_new_conversation_round_trip(self):
        self.start(env={'CLAUDECODE': '1'})         # rhun runs inside Claude Code: its child must not
        self.chat('hello')
        self.assertEqual(self.thread()[-2:], ['user hello', REPLY + 'ok: hello'])
        starts = self.starts()
        self.assertEqual(len(starts), 1, starts)
        argv = starts[0]['argv']
        self.assertEqual(argv[:-1], PINNED)
        self.assertTrue(argv[-1].startswith('--session-id='), argv)
        sid = argv[-1][len('--session-id='):]
        self.assertRegex(sid, UUID4)
        self.assertEqual(starts[0]['cwd'], str(self.project))
        self.assertEqual(starts[0]['env']['CLAUDE_CODE_ENTRYPOINT'], 'rhun')
        self.assertEqual(starts[0]['env']['MCP_CONNECTION_NONBLOCKING'], 'true')
        self.assertIsNone(starts[0]['env']['CLAUDECODE'])
        self.assertEqual(self.stdin()[0], {'type': 'control_request', 'request_id': 'r1',
                                           'request': {'subtype': 'initialize', 'hooks': None}})
        self.assertEqual(self.stdin()[1], {'type': 'user', 'message': {
            'role': 'user', 'content': [{'type': 'text', 'text': 'hello'}]},
            'parent_tool_use_id': None, 'session_id': ''})
        self.assertEqual(self.live(), f'state=ready pid=1 sid={sid} mode=default queued=0 requests=0 new=0\n')
        transcript = self.work / '.claude/projects' / slug(self.project) / (sid + '.jsonl')
        self.assertTrue(transcript.exists())

    def test_text_streams_into_one_row(self):
        self.start()
        self.chat('slow', 'working')
        deadline = time.monotonic() + 10
        first = None
        while time.monotonic() < deadline:
            last = self.thread()[-1]
            if last.startswith('agent ') and len(last) > len('agent '):
                first = last
                break
            time.sleep(0.02)
        self.assertIsNotNone(first)
        self.assertLess(len(first), 50, first)
        time.sleep(0.4)
        second = self.thread()[-1]
        self.assertTrue(second.startswith(first), (first, second))
        self.assertGreater(len(second), len(first))
        self.command('wait-agent ready 20000')
        thread = self.thread()
        self.assertEqual([row for row in thread if row.startswith('agent')], [SLOW_ROW])

    def test_prompts_wait_for_the_handshake(self):
        self.start(env={'FAKE_CLAUDE_INIT_MS': '800'})
        self.command('agent-new claude')
        self.command('agent-prompt one')
        self.command('agent-prompt two')
        live = self.live()
        self.assertTrue(live.startswith('state=starting pid=1 '), live)
        self.assertIn(' queued=2 ', live)
        self.command('wait-agent ready 10000')
        lines = self.stdin()
        self.assertEqual([m.get('type') for m in lines], ['control_request', 'user', 'user'])
        self.assertEqual(self.prompts(), ['one', 'two'])
        self.assertEqual(self.thread(), ['user one', 'user two', REPLY + 'ok: one', 'agent ok: two'])

    def test_unknown_records_are_ignored(self):
        self.start()
        self.chat('unknown')
        self.assertEqual(self.thread(), ['user unknown', REPLY + 'ok: unknown'])
        self.assertTrue(self.live().startswith('state=ready pid=1 '))

    def test_turn_error_shows_the_cli_text(self):
        self.start()
        self.chat('error')
        thread = self.thread()
        self.assertEqual(thread[0], 'user error')
        self.assertTrue(thread[-1].startswith('error API Error: 529 {"type":"overloaded_error"'), thread)
        self.assertTrue(self.live().startswith('state=ready pid=1 '))

    def test_cli_missing(self):
        self.start('[claude]\nexecutable = /nonexistent/claude\n')
        self.chat('hello', 'failed')
        lines = self.live().splitlines()
        self.assertTrue(lines[0].startswith('state=failed pid=0 '), lines)
        self.assertEqual(lines[1], 'report=Claude Code was not found. Install it, or set its path in '
                                   'Settings > Claude Code.')
        self.assertTrue(self.command('print-agent-input').startswith('input=hello '))
        self.assertEqual(self.starts(), [])

    def test_a_long_folder_finds_its_file(self):
        # a slug over 200 bytes: rhun's path is provisional (the real CLI cuts it and adds a hash, the fake
        # does not); at the first turn's end the file named after the id is found in the projects folder
        self.project = self.work / ('p' * max(140, 210 - len(str(self.work))))
        self.project.mkdir()
        self.assertGreater(len(slug(self.project)), 200)
        self.start()
        self.chat('hello')
        self.assertEqual(self.thread(), ['user hello', REPLY + 'ok: hello'])
        self.assertTrue(self.live().endswith(' new=0\n'), self.live())
        self.command('agent-release')               # the file is read again from the found path
        self.command('wait-agent off')
        self.assertEqual(self.thread(), ['user hello', REPLY + 'ok: hello'])

    def test_process_end_mid_turn_is_an_error_row(self):
        self.start()
        self.chat('exit', 'failed')                 # the fake dies mid-reply, status 2
        # the file is read again (the streamed part is not in it), then why it failed
        self.assertEqual(self.thread(), ['user exit', 'error Claude Code ended (exit status 2).'])
        lines = self.live().splitlines()
        self.assertTrue(lines[0].startswith('state=failed pid=0 '), lines)
        self.assertEqual(lines[1], 'report=Claude Code ended (exit status 2).')

    def test_env_pairs_reach_the_process(self):
        self.start(self.claude_section('env.FOO = bar\n'), env={'FAKE_CLAUDE_ECHO_ENV': 'FOO'})
        self.chat('hello')
        self.assertEqual(self.starts()[0]['env']['FOO'], 'bar')

    def test_the_initial_mode_is_passed(self):
        self.start(self.claude_section('initial_mode = plan\n'))
        self.chat('hello')
        argv = self.starts()[0]['argv']
        self.assertIn('--permission-mode=plan', argv)
        self.assertIn(' mode=plan ', self.live())

    def test_draft_keeps_its_first_character(self):
        self.start()
        self.command('agent-new claude')
        self.command('agent-type h')
        self.assertTrue(self.command('print-agent-input').startswith('input=h '))
        self.command('wait-agent ready')
        self.assertTrue(self.command('print-agent-input').startswith('input=h '))
        self.assertEqual(len(self.starts()), 1)
        self.assertEqual(self.prompts(), [])
        self.assertEqual(self.thread(), [])

    def test_no_duplicates_while_driven(self):
        self.start()
        self.chat('hello')
        transcript = self.work / '.claude/projects' / slug(self.project) / (self.sid() + '.jsonl')
        self.assertTrue(transcript.exists())
        time.sleep(3)                               # the panel's one-second poll sees the file grow
        thread = self.thread()
        self.assertEqual(thread.count('user hello'), 1, thread)
        self.assertEqual(thread.count(REPLY + 'ok: hello'), 1, thread)

    def test_send_during_a_turn_is_refused(self):
        self.start()
        self.chat('slow', 'working')
        self.command('agent-prompt more')
        self.assertTrue(self.command('print-agent-input').startswith('input=more '))
        self.command('wait-agent ready 20000')
        self.assertEqual(self.prompts(), ['slow'])
        self.assertNotIn('user more', self.thread())

    def test_back_mid_turn_keeps_the_session(self):
        self.start()
        self.chat('slow', 'working')
        pid = self.starts()[0]['pid']
        self.command(f'click {BACK[0]} {BACK[1]}')  # back to the list (Escape would stop the turn)
        # the panel's poll sees the new file grow: discovery lists it (on the same AS, by its path)
        deadline = time.monotonic() + 5
        while True:
            self.command('wait-agents')
            rows = self.command('print-agents').splitlines()
            if rows or time.monotonic() > deadline:
                break
            time.sleep(0.2)
        self.assertEqual(len(rows), 1, rows)
        self.assertTrue(rows[0].startswith('Claude') and rows[0].endswith(': New conversation'), rows)
        self.assertIn(f' {pid}', self.command('print-uproc').split('\n')[0])
        self.assertTrue(self.live().startswith('state=off '))   # nothing open
        self.command('print-agents 1')
        self.command('wait-agent ready 20000')
        thread = self.thread()
        self.assertEqual(thread[0], 'user slow')
        self.assertEqual([row for row in thread if row.startswith('agent')], [SLOW_ROW])

    def test_reply_rows_have_the_files_labels(self):
        # a streamed reply is labeled as the file reader labels it: the model where it changes
        self.start()
        self.chat('hello')
        self.command('agent-prompt again')
        self.command('wait-agent ready')
        streamed = self.thread()
        self.assertEqual(streamed, ['user hello', REPLY + 'ok: hello', 'user again', 'agent ok: again'])
        self.command('agent-release')
        self.command('wait-agent off')
        self.assertEqual(self.thread(), streamed)


class ResumeTest(DrivenCase):
    """An existing conversation from the list: --resume with its id, the stream under its old rows, the
    file read again once the process is gone."""

    def fresh_thread(self):
        """The open conversation as a new rhun reads it from the file."""
        self.stop()
        self.start()
        return self.open_listed()

    def test_resume_sends_the_id(self):
        self.seed()
        self.start()
        old = self.open_listed()
        self.assertEqual(len(old), 6, old)
        self.command('agent-prompt hello')
        self.command('wait-agent ready')
        starts = self.starts()
        self.assertEqual(len(starts), 1, starts)
        self.assertEqual(starts[0]['argv'], PINNED + ['--resume=s1'])
        self.assertEqual(starts[0]['cwd'], str(self.project))
        self.assertEqual(self.thread(), old + ['user hello', REPLY + 'ok: hello'])
        self.assertEqual(self.live(), 'state=ready pid=1 sid=s1 mode=default queued=0 requests=0 new=0\n')

    def test_rows_after_stop_match_the_file(self):
        self.seed()
        self.start()
        old = self.open_listed()
        self.command('agent-prompt hello')
        self.command('wait-agent ready')
        self.command('agent-prompt again')
        self.command('wait-agent ready')
        streamed = self.thread()
        self.assertEqual(streamed, old + ['user hello', REPLY + 'ok: hello', 'user again', 'agent ok: again'])
        self.command('agent-release')
        self.command('wait-agent off')
        self.assertTrue(self.live().startswith('state=off pid=0 '), self.live())
        self.assertEqual(self.thread(), streamed)
        self.assertEqual(self.fresh_thread(), streamed)

    def test_new_conversation_is_one_row_after_discovery(self):
        self.start()
        self.chat('hello')
        deadline = time.monotonic() + 8
        rows = self.listed()
        while not rows and time.monotonic() < deadline:
            time.sleep(0.2)
            rows = self.listed()
        self.assertEqual(len(rows), 1, rows)
        time.sleep(1.5)                             # another poll and page: still the one row
        rows = self.listed()
        self.assertEqual(len(rows), 1, rows)
        self.assertEqual(self.thread(), ['user hello', REPLY + 'ok: hello'])
        self.command('agent-prompt again')          # the row is still the live session
        self.command('wait-agent ready')
        self.assertEqual(self.thread()[-2:], ['user again', 'agent ok: again'])
        self.assertEqual(len(self.starts()), 1)

    def test_unknown_id_fails_cleanly(self):
        self.seed()
        self.start(env={'FAKE_CLAUDE_RESUME': 'unknown'})
        old = self.open_listed()
        self.command('agent-prompt hello')
        self.command('wait-agent failed')
        self.until_gone()
        text = 'No conversation found with session ID: s1'
        self.assertEqual(self.live().splitlines(),
                         ['state=failed pid=0 sid=s1 mode= queued=0 requests=0 new=0', 'report=' + text])
        self.assertEqual(self.thread(), old + ['error ' + text])
        self.assertTrue(self.command('print-agent-input').startswith('input=hello '))
        self.assertEqual(self.prompts(), [])        # it never got past the start

    def test_rows_after_stop_match_the_file_with_tools(self):
        self.seed()
        self.start()
        old = self.open_listed()
        self.command('agent-prompt auto')
        self.command('wait-agent ready')
        self.command('agent-prompt tool')
        self.command('wait-agent waiting')
        self.command('agent-card 1')
        self.command('wait-agent ready')
        streamed = self.thread()
        self.assertEqual(streamed, old + ['user auto', 'tool(Bash) touch auto.txt', 'result ' + BASH_DONE,
                                          REPLY + 'done', 'user tool', 'tool(Bash) touch approved.txt',
                                          'result ' + BASH_DONE, 'agent done'])
        self.command('agent-release')
        self.command('wait-agent off')
        self.assertEqual(self.thread(), streamed)
        self.assertEqual(self.fresh_thread(), streamed)


BASH_DONE = '(Bash completed with no output)'
REJECTED = ("The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a "
            "file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the "
            "user to tell you how to proceed.")
QUESTIONS_TWO = [{'question': 'Which language?', 'header': 'Language', 'multiSelect': False,
                  'options': [{'label': 'Python', 'description': 'Scripts'}, {'label': 'Go', 'description': 'Services'},
                              {'label': 'Rust', 'description': 'Systems'}]},
                 {'question': 'Which tools?', 'header': 'Tools', 'multiSelect': True,
                  'options': [{'label': 'git', 'description': ''}, {'label': 'make', 'description': ''},
                              {'label': 'docker', 'description': ''}]}]


class RequestTest(DrivenCase):
    """Claude's tool calls as rows, its requests (permissions, questions, plans) as cards."""

    def card(self):
        """The open card's line of print-agent-input, or None."""
        lines = self.command('print-agent-input').splitlines()
        return lines[1] if len(lines) > 1 else None

    def answers(self):
        """The answers the fake took for single requests, in order."""
        return [r['answer'] for r in self.records() if 'answer' in r]

    def logged(self, key):
        return [r[key] for r in self.records() if key in r]

    def tool_ids(self):
        """The ids of the tool calls in the conversation's file."""
        path = self.work / '.claude/projects' / slug(self.project) / (self.sid() + '.jsonl')
        records = [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines() if line]
        return [block['id'] for r in records if r.get('type') == 'assistant'
                for block in r['message']['content'] if block.get('type') == 'tool_use']

    def responses(self):
        """The control_response lines the fake read."""
        return [m['response'] for m in self.stdin() if m.get('type') == 'control_response']

    def test_tool_row_and_result(self):
        self.start()
        self.chat('auto')
        self.assertEqual(self.thread(), ['user auto', 'tool(Bash) touch auto.txt', 'result ' + BASH_DONE,
                                         REPLY + 'done'])
        self.assertEqual(self.answers(), [])

    def test_permission_allow(self):
        self.start()
        self.chat('tool', 'waiting')
        self.assertEqual(self.card(), 'card=Allow this bash command? touch approved.txt options=Yes|No')
        self.assertIn(' requests=1 ', self.live())
        self.assertEqual(self.thread(), ['user tool', 'tool(Bash) touch approved.txt'])
        self.command('agent-card 1')
        self.command('wait-agent ready')
        self.assertIsNone(self.card())
        self.assertIn(' requests=0 ', self.live())
        tid = self.tool_ids()
        self.assertEqual(self.answers(), [{'behavior': 'allow', 'toolUseID': tid[0], 'updatedInput': {
            'command': 'touch approved.txt', 'description': 'Run touch approved.txt'}}])
        self.assertEqual(list(self.responses()[0]), ['subtype', 'request_id', 'response'])
        self.assertTrue((self.project / 'approved.txt').exists())
        self.assertEqual(self.thread(), ['user tool', 'tool(Bash) touch approved.txt', 'result ' + BASH_DONE,
                                         REPLY + 'done'])

    def test_permission_deny(self):
        self.start()
        self.chat('tool', 'waiting')
        self.command('agent-card 2')
        self.command('wait-agent ready')
        tid = self.tool_ids()
        self.assertEqual(self.answers(), [{'behavior': 'deny', 'message': REJECTED, 'interrupt': True,
                                           'toolUseID': tid[0]}])
        self.assertFalse((self.project / 'approved.txt').exists())
        self.assertIn('result ' + REJECTED[:60], self.thread())

    def test_numeric_request_ids_are_echoed_as_numbers(self):
        self.start(env={'FAKE_CLAUDE_NUMERIC_IDS': '1'})
        self.chat('tool', 'waiting')
        self.command('agent-card 1')
        self.command('wait-agent ready')
        self.assertEqual(self.responses()[0]['request_id'], 7)
        self.assertEqual(self.answers()[0]['behavior'], 'allow')

    def test_input_that_cannot_be_echoed_is_denied(self):
        self.start()
        self.chat('deep')
        self.assertIsNone(self.card())
        tid = self.tool_ids()
        self.assertEqual(self.answers(), [{'behavior': 'deny', 'message': 'rhun cannot pass this input back '
                                           'unchanged', 'interrupt': False, 'toolUseID': tid[0]}])

    def test_two_requests_queue(self):
        self.start()
        self.chat('tool2', 'waiting')
        self.assertEqual(self.card(), 'card=Allow this bash command? touch approved.txt options=Yes|No')
        self.command('agent-card 1')
        self.command('wait-agent waiting')
        self.assertEqual(self.card(), 'card=Allow this bash command? touch denied.txt options=Yes|No')
        self.command('agent-card 2')
        self.command('wait-agent ready')
        self.assertEqual([a['behavior'] for a in self.answers()], ['allow', 'deny'])
        self.assertEqual(self.thread()[-1], REPLY + 'done')

    def test_question_cards_in_order(self):
        self.start()
        self.chat('ask2', 'waiting')
        self.assertEqual(self.card(), 'card=Which language? options=Python|Go|Rust')
        self.command('agent-card 2')
        self.assertEqual(self.card(), 'card=Which tools? options=git|make|docker')
        self.assertIn(' requests=1 ', self.live())
        self.assertEqual(self.answers(), [])
        self.command('agent-card 3')
        self.command('wait-agent ready')
        tid = self.tool_ids()
        self.assertEqual(self.answers(), [{'behavior': 'allow', 'toolUseID': tid[0], 'updatedInput': {
            'questions': QUESTIONS_TWO, 'answers': {'Which language?': 'Go', 'Which tools?': 'docker'}}}])
        self.assertEqual(self.logged('questions_kept'), [True])

    def test_plan_card(self):
        self.start(self.claude_section('initial_mode = plan\n'))
        self.chat('plan', 'waiting')
        self.assertIn(' mode=plan ', self.live())
        self.assertEqual(self.card(), 'card=Accept this plan? options=Yes|No, keep planning')
        self.assertEqual(self.thread(), ['user plan', 'tool(ExitPlanMode) ', 'agent # Plan'])
        self.command('agent-card 1')
        self.command('wait-agent ready')
        lines = [m for m in self.stdin() if m.get('type') in ('control_request', 'control_response')]
        self.assertEqual(lines[-2]['request'], {'subtype': 'set_permission_mode', 'mode': 'default'})
        self.assertEqual(lines[-1]['response']['response']['behavior'], 'allow')
        answer = self.answers()[0]
        self.assertEqual(answer['updatedInput']['plan'], '# Plan\n\n1. Add the file\n2. Test it')
        self.assertEqual(self.thread()[-1], REPLY + 'approved default')
        self.assertIn(' mode=default ', self.live())

    def test_plan_keep_planning(self):
        self.start(self.claude_section('initial_mode = plan\n'))
        self.chat('plan', 'waiting')
        self.command('agent-card 2')
        self.command('wait-agent ready')
        tid = self.tool_ids()
        self.assertEqual(self.answers(), [{'behavior': 'deny', 'message': 'User chose to stay in plan mode and '
                                           'continue planning', 'interrupt': False, 'toolUseID': tid[0]}])
        self.assertNotIn('set_permission_mode', json.dumps(self.stdin()))
        self.assertIn(' mode=plan ', self.live())

    def test_withdrawn_request(self):
        self.start()
        self.chat('withdraw', 'waiting')
        self.assertEqual(self.card(), 'card=Allow this bash command? touch withdrawn.txt options=Yes|No')
        self.until(lambda: 'info Withdrawn by Claude' in self.thread(), 'the withdrawn row')
        self.assertIsNone(self.card())
        self.assertIn(' requests=0 ', self.live())
        self.command('wait-agent ready')
        self.assertEqual(self.answers(), [])
        self.assertEqual(self.responses(), [])
        self.assertEqual(self.thread(), ['user withdraw', 'tool(Bash) touch withdrawn.txt', 'info Withdrawn by Claude',
                                         'result ' + REJECTED[:60], REPLY + 'done'])

    def test_unknown_request_gets_an_error_reply(self):
        self.start()
        self.chat('unhandled')
        error = {'behavior': 'error', 'message': 'not supported by rhun yet'}
        self.assertEqual(self.logged('unhandled'), [[error] * 5])
        self.assertEqual([r['subtype'] for r in self.responses()], ['error'] * 5)
        self.assertIsNone(self.card())
        self.assertEqual(self.thread(), ['user unhandled', REPLY + 'done'])

    def test_33rd_request_is_refused(self):
        self.start()
        self.chat('many', 'waiting')
        self.until(lambda: ' requests=32 ' in self.live(), 'the 32 requests kept')
        for i in range(32):
            self.assertEqual(self.card(), f'card=Allow this bash command? touch many{i}.txt options=Yes|No')
            self.command('agent-card 1')
        self.command('wait-agent ready 20000')
        self.assertEqual(self.logged('many'), [['allow'] * 32 + ['error']])
        self.assertIsNone(self.card())

    def test_a_card_goes_when_the_process_ends(self):
        self.start()
        self.chat('tool', 'waiting')
        self.command('agent-release')               # the process ends with the request unanswered
        deadline = time.monotonic() + 10
        while ' pid=1 ' in self.live():
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.05)
        self.assertIsNone(self.card())
        self.assertIn(' requests=0 ', self.live())
        self.assertIn('info Claude Code ended before the request was answered.', self.thread())


def alive(pid):
    """Whether the process runs (or is a zombie nobody reaped yet)."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


BUSY = 'Too many agents are running. Stop one and send again.'
UNANSWERED = 'info Claude Code ended before the request was answered.'


class LifeTest(DrivenCase):
    """Stop, and the process's life: it starts when the user types, stops when idle, when a draft is left,
    when the chat is switched off or the project changes, and never outlives rhun."""

    def pid(self, n=-1):
        return self.starts()[n]['pid']

    def gone(self, pid, seconds=10):
        self.until(lambda: not alive(pid), f'process {pid} still runs', seconds)

    def interrupts(self):
        return [m for m in self.stdin()
                if m.get('type') == 'control_request' and m['request'].get('subtype') == 'interrupt']

    def streaming(self):
        """Until the reply's row has text."""
        self.until(lambda: any(r.startswith('agent') and r != 'agent ' and not r.endswith(') ')
                               for r in self.thread()), 'the reply streams')

    def card(self):
        lines = self.command('print-agent-input').splitlines()
        return lines[1] if len(lines) > 1 else None

    def box(self):
        return self.command('print-agent-input').splitlines()[0].split(' box=')[1]

    def uproc_pids(self):
        return re.findall(r'\b\d+\b', self.command('print-uproc'))

    def test_stop_interrupts(self):
        self.start()
        self.chat('slow', 'working')
        self.streaming()
        self.command('agent-stop')
        self.command('agent-stop')                  # a second Stop in the same turn does nothing
        self.command('wait-agent ready 20000')
        stops = self.interrupts()
        self.assertEqual(len(stops), 1, stops)
        self.assertRegex(stops[0]['request_id'], r'^r\d+$')
        self.assertEqual(stops[0]['request'], {'subtype': 'interrupt'})
        thread = self.thread()
        self.assertEqual(thread[0], 'user slow')
        self.assertEqual(thread[-1], 'info Interrupted')
        self.assertEqual(thread.count('info Interrupted'), 1)
        self.assertNotIn(SLOW_ROW, thread)          # cut short
        self.assertTrue(self.live().startswith('state=ready pid=1 '), self.live())
        self.command('agent-prompt hello')          # the next turn runs as usual, with no Stop of its own
        self.command('wait-agent ready')
        self.assertEqual(self.thread()[-2:], ['user hello', 'agent ok: hello'])
        self.assertEqual(len(self.interrupts()), 1)
        self.assertEqual(len(self.starts()), 1)

    def test_stop_withdraws_a_card_quietly(self):
        self.start()
        self.chat('pending', 'waiting')
        self.assertIsNotNone(self.card())
        self.command('agent-stop')
        self.command('wait-agent ready')
        self.assertIsNone(self.card())
        thread = self.thread()
        self.assertNotIn('info Withdrawn by Claude', thread)
        self.assertEqual(thread[-1], 'info Interrupted')

    def test_escape_stops_a_turn(self):
        self.start()
        self.chat('slow', 'working')
        self.streaming()
        self.command('cmd focus_agents')
        self.command('key Escape')                  # the panel has the keys and a turn runs: Stop
        self.command('wait-agent ready 20000')
        self.assertEqual(len(self.interrupts()), 1)
        self.assertEqual(self.thread()[-1], 'info Interrupted')
        self.assertTrue(self.command('print-agent-input').startswith('input= focus=0 '))
        self.command('key Escape')                  # no turn: back to the list, as before
        self.assertTrue(self.live().startswith('state=off pid=0 '), self.live())
        self.command('print-agents 1')
        self.command('agent-prompt slow')
        self.command('wait-agent working')
        self.streaming()
        self.command('key Tab')                     # into the box
        self.command('key Escape')                  # the box has the keys and a turn runs: Stop
        self.command('wait-agent ready 20000')
        self.assertEqual(len(self.interrupts()), 2)
        self.assertTrue(self.command('print-agent-input').startswith('input= focus=1 '))
        self.command('key Escape')                  # no turn: out of the box, as before
        self.assertTrue(self.command('print-agent-input').startswith('input= focus=0 '))
        self.assertTrue(self.live().startswith('state=ready pid=1 '), self.live())

    def test_reading_starts_nothing(self):
        for sid in ('s1', 's2', 's3'):
            self.seed(sid)
        self.start()
        self.assertEqual(len(self.listed()), 3)
        for n in (1, 2, 3):
            self.command(f'print-agents {n}')
            self.command('move 1000 300')
            self.command('scroll 5')
            self.command('scroll -5')
            self.assertTrue(self.live().startswith('state=off pid=0 '), self.live())
            self.command(f'click {BACK[0]} {BACK[1]}')
        self.command('print-agents 2')
        time.sleep(2)
        self.assertTrue(self.live().startswith('state=off pid=0 '), self.live())
        self.assertEqual(self.uproc_pids(), [])
        self.assertEqual(self.starts(), [])

    def test_typing_starts_the_process(self):
        self.start()
        self.command('agent-new claude')            # agent-type: text into the box, not sent
        self.command('agent-type h')
        self.command('wait-agent ready')
        self.assertEqual(len(self.starts()), 1)
        self.command('agent-new claude')            # real keys in a new conversation's box
        self.assertTrue(self.command('print-agent-input').startswith('input= focus=1 '))
        self.command('type h')
        self.command('wait-agent ready')
        self.assertEqual(len(self.starts()), 2)
        self.assertTrue(self.command('print-agent-input').startswith('input=h '))
        self.assertEqual(self.prompts(), [])
        self.stop()
        self.seed()                                 # real keys in an existing conversation's box
        self.start()
        self.open_listed()
        self.assertTrue(self.live().startswith('state=off '), self.live())
        self.command('key Tab')
        self.command('type x')
        self.command('wait-agent ready')
        self.assertEqual(self.starts()[-1]['argv'][-1], '--resume=s1')
        self.assertEqual(len(self.starts()), 3)
        self.command('type y')                      # more keys start nothing more
        time.sleep(0.5)
        self.assertEqual(len(self.starts()), 3)
        self.assertTrue(self.command('print-agent-input').startswith('input=xy '))
        self.assertEqual(self.prompts(), [])
        self.stop()                                 # a paste into the box
        self.start()
        self.command('key ' + MOD + '+n')           # the text to paste, copied from a new file
        self.command('type pasted')
        self.command('key ' + MOD + '+a')
        self.command('key ' + MOD + '+c')
        self.open_listed()
        self.command('key Tab')
        self.command('key ' + MOD + '+v')
        self.command('wait-agent ready')
        self.assertTrue(self.command('print-agent-input').startswith('input=pasted '))
        self.assertEqual(len(self.starts()), 4)
        self.assertEqual(self.prompts(), [])

    def test_abandoned_draft_stops(self):
        self.seed()
        self.start()
        self.assertEqual(len(self.listed()), 1)
        # Back
        self.command('agent-new claude')
        self.command('agent-type h')
        self.command('wait-agent ready')
        pid = self.pid()
        self.command('key Escape')                  # out of the box
        self.command('key Escape')                  # back to the list: the draft is left
        self.gone(pid)
        self.assertEqual(len(self.listed()), 1)
        self.assertEqual(self.uproc_pids(), [])
        # another conversation opened
        self.command('agent-new claude')
        self.command('agent-type h')
        self.command('wait-agent ready')
        pid = self.pid()
        self.command('print-agents 1')              # the listed one (a draft is pinned after the page)
        self.gone(pid)
        self.assertTrue(self.thread()[0].startswith('user '), self.thread())
        self.assertEqual(len(self.listed()), 1)
        # the panel closed
        self.command('agent-new claude')
        self.command('agent-type h')
        self.command('wait-agent ready')
        pid = self.pid()
        self.command('cmd toggle_agents')
        self.gone(pid)
        self.assertEqual(len(self.listed()), 1)
        self.assertEqual(self.prompts(), [])
        # one that got a prompt stays when it is left
        self.chat('hello')
        pid = self.pid()
        self.command(f'click {BACK[0]} {BACK[1]}')
        time.sleep(0.5)
        self.assertTrue(alive(pid))
        rows = self.listed()
        self.assertEqual(len(rows), 2, rows)

    def test_idle_stop_and_transparent_restart(self):
        self.start()
        self.chat('hello')
        sid = self.sid()
        pid = self.pid()
        self.command('agent-timing idle=300')
        self.command('wait-agent off 5000')
        self.gone(pid)
        self.assertEqual(self.thread(), ['user hello', REPLY + 'ok: hello'])    # read again from the file
        self.assertNotIn(' report=', self.live())
        self.command('agent-prompt again')
        self.command('wait-agent ready')
        starts = self.starts()
        self.assertEqual(len(starts), 2)
        self.assertEqual(starts[1]['argv'][-1], '--resume=' + sid)
        self.assertEqual(self.thread()[-2:], ['user again', 'agent ok: again'])

    def test_quit_mid_turn_leaves_no_process(self):
        self.start()
        self.chat('slow', 'working')
        pid = self.pid()
        self.quit()
        self.gone(pid, 8)
        # one that ignores SIGTERM goes too
        self.start(env={'FAKE_CLAUDE_LINGER_MS': '60000'})
        self.chat('mute', 'working')
        pid = self.pid()
        self.quit()
        self.gone(pid, 8)

    def test_crash_mid_turn(self):
        self.start()
        self.chat('exit', 'failed')
        sid = self.sid()
        crashed = ['user exit', 'error Claude Code ended (exit status 2).']
        self.assertEqual(self.thread(), crashed)     # the file's rows, then why it ended
        self.command('agent-prompt again')          # the next Send starts it again with the file
        self.command('wait-agent ready')
        starts = self.starts()
        self.assertEqual(len(starts), 2)
        self.assertEqual(starts[1]['argv'][-1], '--resume=' + sid)
        thread = self.thread()
        self.assertEqual(thread[:3], crashed + ['user again'])
        self.assertTrue(thread[3].endswith('ok: again'), thread)

    def test_the_cap(self):
        self.start()
        self.command('agent-timing guard=2')
        self.chat('hello')
        self.chat('hello')
        first, second = self.pid(0), self.pid(1)
        self.chat('hello')                          # a third: the idle one used longest ago is released
        self.assertEqual(len(self.starts()), 3)
        self.gone(first)
        self.assertTrue(alive(second))
        self.assertEqual(self.thread(), ['user hello', REPLY + 'ok: hello'])
        self.stop()
        self.fake_log.unlink()
        self.start()
        self.command('agent-timing guard=2')
        self.chat('slow', 'working')
        self.chat('slow', 'working')
        self.chat('hello', 'failed')                # none idle
        self.assertEqual(self.live().splitlines()[1], 'report=' + BUSY)
        self.assertEqual(self.thread(), ['error ' + BUSY[:60]])
        self.assertTrue(self.command('print-agent-input').startswith('input=hello '))
        self.assertEqual(len(self.starts()), 2)

    def test_chat_off_stops_processes(self):
        self.start()
        self.chat('slow', 'working')
        pid = self.pid()
        self.config.write_text(self.BASE + self.claude_section('chat = false\n'), encoding='utf-8')
        self.gone(pid, 15)
        self.until(lambda: self.box() == '0', 'the box is gone')
        self.assertTrue(self.live().startswith('state=off pid=0 '), self.live())
        self.assertEqual(self.thread()[0], 'user slow')     # the file's rows
        self.config.write_text(self.BASE + self.claude_section('chat = true\n'), encoding='utf-8')
        self.until(lambda: self.box() == '1', 'the box is back', 15)
        self.assertEqual(len(self.starts()), 1)

    def test_settings_switch_shows_and_hides_the_box(self):
        self.seed()
        self.start()
        self.open_listed()
        self.assertEqual(self.box(), '1')
        self.command('cmd settings')
        self.command('type chat with claude')
        self.assertEqual(self.command('print-settings'), 'claude.chat\n')
        self.command(f'click {CHAT_SWITCH[0]} {CHAT_SWITCH[1]}')
        self.assertEqual(self.box(), '0')
        self.command(f'click {CHAT_SWITCH[0]} {CHAT_SWITCH[1]}')
        self.assertEqual(self.box(), '1')

    def test_project_switch_stops_processes(self):
        self.start()
        self.chat('slow', 'working')
        pid = self.pid()
        other = self.work / 'other'
        other.mkdir()
        self.command(f'open {other}')
        self.gone(pid)
        self.assertTrue(self.live().startswith('state=off pid=0 '), self.live())

    def test_child_that_will_not_exit(self):
        # stdout closes mid-turn, SIGTERM is ignored: the end of stdout's deadline, then the kill
        self.start(env={'FAKE_CLAUDE_LINGER_MS': '60000'})
        self.command('agent-timing eof=300 kill=300')
        self.chat('mute', 'failed', 15000)
        pid = self.pid()
        self.gone(pid)
        self.assertNotIn(str(pid), self.uproc_pids())
        self.assertTrue(self.thread()[-1].startswith('error Claude Code ended'), self.thread())

    def test_a_release_with_a_card_up_ends_off(self):
        self.start()
        self.chat('tool', 'waiting')
        self.command('agent-release')               # rhun ends it: no failure, whatever its status
        self.command('wait-agent off')
        self.until_gone()
        lines = self.live().splitlines()
        self.assertEqual(len(lines), 1, lines)
        self.assertIn(' requests=0 ', lines[0])
        self.assertIsNone(self.card())
        thread = self.thread()
        self.assertEqual([row for row in thread if row.startswith('error')], [])
        self.assertEqual(thread[-1], UNANSWERED)

    def test_a_result_takes_a_waiting_card(self):
        self.start()
        self.chat('orphan', 'waiting')
        self.assertEqual(self.card(), 'card=Allow this bash command? touch orphan.txt options=Yes|No')
        self.command('wait-agent ready')
        self.assertIsNone(self.card())
        self.assertIn(' requests=0 ', self.live())

    def passes(self, seconds=3):
        def count():
            return int(self.command('print-loop-stats').split()[0].split('=')[1])
        before = count()
        time.sleep(seconds)
        return count() - before - 1

    def test_idle_rhun_has_no_timer(self):
        self.env['CODEX_HOME'] = str(self.work / '.codex')
        self.seed()
        codex = self.work / '.codex/sessions/2026/09/26'
        codex.mkdir(parents=True)
        fixture = (ROOT / 'tests/data/agents/codex.jsonl').read_text(encoding='utf-8')
        (codex / 'rollout-c1.jsonl').write_text(fixture.replace('@PROJECT@', self.project.as_posix()),
                                                encoding='utf-8')
        self.start()
        self.command('cmd focus_agents')
        self.command('wait-agents')
        rows = self.command('print-agents').splitlines()
        self.assertEqual(len(rows), 2, rows)
        n_claude = next(i for i, row in enumerate(rows) if row.startswith('Claude:')) + 1
        n_codex = next(i for i, row in enumerate(rows) if row.startswith('Codex:')) + 1

        def idle(n):
            self.command(f'click {BACK[0]} {BACK[1]}')
            self.command(f'print-agents {n}')
            time.sleep(1.5)
            return self.passes()
        codex_passes = idle(n_codex)
        claude_passes = idle(n_claude)
        self.assertLessEqual(claude_passes, codex_passes + 1, (claude_passes, codex_passes))
        # and after a process ran and was released
        self.command('agent-prompt hello')
        self.command('wait-agent ready')
        self.command('agent-release')
        self.command('wait-agent off')
        self.until_gone()
        time.sleep(5)                               # discovery reads the file that changed
        released = self.passes()
        self.assertLessEqual(released, codex_passes + 1, (released, codex_passes))


CHAT_SWITCH = (776, 348)            # the switch of Settings' one row "Chat with Claude Code" (1280x800)


if __name__ == '__main__':
    unittest.main()
