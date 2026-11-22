#!/usr/bin/env python3
"""Claude Code's chat in the agents panel, against the fake CLI (tests/scripts/fake-claude.py), over
the control socket. Every rhun gets its own HOME and XDG folders and a config whose [claude] section
starts the fake through python3; the environment it is given has no CLAUDE* or ANTHROPIC* variable
(these tests run inside Claude Code sessions too), and TERM is set, so rhun uses that environment
instead of asking a login shell for one."""
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


if __name__ == '__main__':
    unittest.main()
