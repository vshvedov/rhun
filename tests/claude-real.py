#!/usr/bin/env python3
"""rhun's chat against the real Claude Code, opt in: RHUN_REAL_CLAUDE=1 (skipped otherwise; not in
tests/run.sh, never in CI). It spends 8 small prompts of the maintainer's own plan.

What rhun sees: its own HOME, XDG_CONFIG_HOME and XDG_STATE_HOME in a temporary folder, and an
environment without CLAUDE* or ANTHROPIC* variables (CLAUDE_CONFIG_DIR is not set), TERM set. Its
config's [claude] section names the real program, initial_mode = default (the maintainer's own
settings say defaultMode auto, which would ask for nothing) and env.HOME = the real home.

What the child claude sees: that environment with HOME replaced by the real home (rhun's env pairs),
plus rhun's forced CLAUDE_CODE_ENTRYPOINT and MCP_CONNECTION_NONBLOCKING. So it finds the sign-in
where it always does (the login keychain, ~/.claude) and the user's own settings, and it writes the
conversation under the real ~/.claude/projects/<slug of the temporary project>. Neither rhun nor this
test reads a credential: the only look at the sign-in is `claude auth status --json`, of which only
"loggedIn" is kept, never printed beyond yes or no.

rhun finds the conversation's file under its own HOME: <its HOME>/.claude/projects/<slug> is a symbolic
link to that one real folder (made before rhun starts), so rhun sees nothing else of ~/.claude.

The project is a fresh git repository with one file in a temporary folder (RHUN_REAL_CLAUDE_TMP, or the
system's), outside any rhun checkout. At the end the real ~/.claude/projects folders named after the
test's projects are deleted, and nothing else there: each name is checked to hold the slug of the
test's own temporary folder first, and printed.

RHUN_REAL_CLAUDE_RECORD=DIR: every line between rhun and the CLI goes to DIR/<test>.jsonl
({"dir": "in"|"out", "t": seconds, "msg": ...}) through a small wrapper, and the conversations' files
are copied there before they are deleted, for finding out what the CLI sent; the initialize answer
names the account, so keep such files to yourself."""
import importlib.util
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location('claude_chat', ROOT / 'tests/claude-chat.py')
chat = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(chat)

ENABLED = os.environ.get('RHUN_REAL_CLAUDE') == '1'
REAL_HOME = Path(pwd.getpwuid(os.getuid()).pw_dir)
REAL_PROJECTS = REAL_HOME / '.claude/projects'
WAIT_MS = 180000                    # a real turn, at most
PYTHON = Path(sys.executable).resolve()
OK = re.compile(r'^agent(\(\S+\))? ok\.?$', re.IGNORECASE)
# a reply long enough to stop: 400 numbers had all streamed before the Stop reached the CLI
COUNT = 'Count from 1 to 2000, one number per line. Nothing else.'

RECORDER = r'''import json, os, subprocess, sys, threading, time
log = open(os.environ['REC_LOG'], 'a', encoding='utf-8')
lock = threading.Lock()
def note(direction, raw):
    try:
        msg = json.loads(raw)
    except ValueError:
        msg = raw.decode('utf-8', 'replace')
    with lock:
        log.write(json.dumps({'dir': direction, 't': round(time.time(), 3), 'msg': msg}) + '\n')
        log.flush()
child = subprocess.Popen([os.environ['REC_CLAUDE']] + sys.argv[1:], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
def feed():
    for raw in sys.stdin.buffer:
        note('out', raw)
        try:
            child.stdin.write(raw)
            child.stdin.flush()
        except OSError:
            break
    child.stdin.close()
threading.Thread(target=feed, daemon=True).start()
for raw in child.stdout:
    note('in', raw)
    sys.stdout.buffer.write(raw)
    sys.stdout.buffer.flush()
sys.exit(child.wait())
'''


def claude_program():
    """The real claude: RHUN_REAL_CLAUDE_EXE, or the one on PATH, or ~/.local/bin/claude."""
    named = os.environ.get('RHUN_REAL_CLAUDE_EXE') or shutil.which('claude') or str(REAL_HOME / '.local/bin/claude')
    return Path(named).resolve()


def logged_in(program):
    """Whether claude, in the environment the child gets, says it is signed in (its output is not kept)."""
    env = dict(chat.clean_env(os.environ), HOME=str(REAL_HOME), TERM='dumb')
    try:
        out = subprocess.run([str(program), 'auth', 'status', '--json'], env=env, capture_output=True,
                             timeout=60).stdout
        return bool(json.loads(out).get('loggedIn'))
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return False


def child_args(pid):
    try:
        return subprocess.run(['ps', '-p', str(pid), '-o', 'args='], capture_output=True, text=True).stdout
    except OSError:
        return ''


@unittest.skipUnless(ENABLED, 'set RHUN_REAL_CLAUDE=1 to run against the real Claude Code')
class RealCase(chat.DrivenCase):
    base = None
    made = []                       # the real ~/.claude/projects folders the projects get

    @classmethod
    def setUpClass(cls):
        cls.program = claude_program()
        if not cls.program.exists():
            raise AssertionError(f'no claude at {cls.program}')
        if not logged_in(cls.program):
            raise AssertionError('claude is not signed in: run `claude` and sign in first')
        print('claude signed in: yes', file=sys.stderr)
        parent = os.environ.get('RHUN_REAL_CLAUDE_TMP') or None
        cls.base = Path(tempfile.mkdtemp(prefix='rhun-claude-real-', dir=parent)).resolve()
        if str(cls.base).startswith(str(ROOT)):
            raise AssertionError('the temporary folder is inside the checkout')

    @classmethod
    def tearDownClass(cls):
        mark = chat.slug(cls.base)
        for folder in cls.made:
            if folder.parent == REAL_PROJECTS and mark in folder.name and folder.is_dir() \
                    and not folder.is_symlink():
                record = os.environ.get('RHUN_REAL_CLAUDE_RECORD')
                if record:
                    for path in folder.glob('*.jsonl'):
                        shutil.copy(path, Path(record) / path.name)
                print(f'deleting {folder}', file=sys.stderr)
                shutil.rmtree(folder)
        cls.made = []
        if cls.base is not None and not os.environ.get('RHUN_REAL_CLAUDE_KEEP'):
            shutil.rmtree(cls.base, ignore_errors=True)

    def setUp(self):
        self.work = self.base / self._testMethodName
        self.project = self.work / 'project'
        self.project.mkdir(parents=True)
        (self.project / 'notes.txt').write_text('A file for rhun\'s real-CLI test.\n', encoding='utf-8')
        git_env = dict(chat.clean_env(os.environ), GIT_CONFIG_NOSYSTEM='1', HOME=str(self.work),
                       GIT_AUTHOR_NAME='rhun test', GIT_AUTHOR_EMAIL='test@example.invalid',
                       GIT_COMMITTER_NAME='rhun test', GIT_COMMITTER_EMAIL='test@example.invalid')
        for args in (['init', '-q'], ['add', 'notes.txt'], ['commit', '-q', '-m', 'One file']):
            subprocess.run(['git', *args], cwd=self.project, env=git_env, check=True)
        name = chat.slug(self.project)
        self.assertIn(chat.slug(self.base), name)
        self.assertLessEqual(len(name), 200)
        real = REAL_PROJECTS / name
        real.mkdir(parents=True, exist_ok=True)
        type(self).made.append(real)
        home = self.work / 'home'
        (home / '.claude/projects').mkdir(parents=True)
        (home / '.claude/projects' / name).symlink_to(real, target_is_directory=True)
        self.real_folder = real
        self.config = self.work / 'config/rhun/config'
        self.config.parent.mkdir(parents=True)
        self.fake_log = self.work / 'no-fake.log'
        self.env = dict(chat.clean_env(os.environ), HOME=str(home), XDG_CONFIG_HOME=str(self.work / 'config'),
                        XDG_STATE_HOME=str(self.work / 'state'), GIT_CONFIG_NOSYSTEM='1', TERM='dumb')
        self.recorder = None
        record = os.environ.get('RHUN_REAL_CLAUDE_RECORD')
        if record:
            Path(record).mkdir(parents=True, exist_ok=True)
            self.recorder = self.work / 'recorder.py'
            self.recorder.write_text(RECORDER, encoding='utf-8')
            self.recorder.chmod(0o755)
            self.env['REC_LOG'] = str(Path(record).resolve() / (self._testMethodName + '.jsonl'))
        self.process = self.client = self.reader = None
        self.sockets = None

    def tearDown(self):
        self.stop()
        if self.sockets is not None:
            shutil.rmtree(self.sockets, ignore_errors=True)

    def claude_section(self, extra=''):
        section = f'[claude]\nexecutable = {self.program}\ninitial_mode = default\nenv.HOME = {REAL_HOME}\n'
        if self.recorder:
            section = (f'[claude]\nwrapper = {PYTHON}\nexecutable = {self.recorder}\ninitial_mode = default\n'
                       f'env.HOME = {REAL_HOME}\nenv.REC_CLAUDE = {self.program}\n')
        return section + extra

    def start(self, claude=None, extra='', env=None):
        """ChatCase.start with the control socket in a short folder (a Unix socket's path is short)."""
        if claude is None:
            claude = self.claude_section()
        self.config.write_text(self.BASE + claude + extra, encoding='utf-8')
        if self.sockets is None:
            self.sockets = Path(tempfile.mkdtemp(prefix='rhun-real-', dir='/tmp'))
        control = self.sockets / 'c'
        if control.exists():
            control.unlink()
        self.process = subprocess.Popen([str(chat.EXE), str(self.project), '--headless', '1280x800',
                                         '--scale', '1', '--control', str(control)],
                                        env=dict(self.env, **(env or {})),
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        deadline = time.monotonic() + 10
        while True:
            try:
                self.client.connect(str(control))
                break
            except (FileNotFoundError, ConnectionRefusedError):
                if self.process.poll() is not None or time.monotonic() > deadline:
                    self.fail('editor did not start')
                time.sleep(0.01)
        self.client.settimeout(WAIT_MS / 1000 + 30)
        self.reader = self.client.makefile('r', encoding='utf-8')

    def wait(self, states, ms=WAIT_MS):
        """Until the open session is in one of states (failed ends the wait too, as a failure)."""
        out, ok = self.reply(f'wait-agent {states}|failed {ms}')
        live = self.live()
        state = live.split(' ', 1)[0][len('state='):]
        self.assertTrue(ok and state in states.split('|'), (states, out, live, self.thread()))

    def send(self, prompt, wait='ready'):
        self.command('agent-prompt ' + prompt)
        if wait:
            self.wait(wait)

    def card(self):
        lines = self.command('print-agent-input').splitlines()
        return lines[1] if len(lines) > 1 else None

    def pick(self, label):
        """Option label of the open card, by its place."""
        card = self.card()
        self.assertIsNotNone(card)
        options = card.rsplit(' options=', 1)[1].split('|')
        self.assertIn(label, options, card)
        self.command(f'agent-card {options.index(label) + 1}')

    def child(self):
        """The pid of the running claude (print-uproc's entry whose command line is claude's)."""
        for pid in re.findall(r'\b\d+\b', self.command('print-uproc').split('=', 1)[-1]):
            if '--input-format' in child_args(pid):
                if self.recorder:           # the recorder's own child is claude
                    kids = subprocess.run(['pgrep', '-P', pid], capture_output=True, text=True).stdout.split()
                    return int(kids[0]) if kids else None
                return int(pid)
        return None

    def errors(self):
        return [row for row in self.thread() if row.startswith('error')]

    def listed_until_one(self):
        deadline = time.monotonic() + 10
        rows = self.listed()
        while len(rows) != 1 and time.monotonic() < deadline:
            time.sleep(0.3)
            rows = self.listed()
        return rows


class RealTest(RealCase):
    def test_a_conversation(self):
        """(1) a reply, (2) a permission allowed, (3) one denied, (4) Stop, (5) release and --resume."""
        self.start()
        # (1) a new conversation
        self.command('agent-new claude')
        self.send('Reply with the word ok')
        thread = self.thread()
        self.assertEqual(thread[0], 'user Reply with the word ok', thread)
        self.assertRegex(thread[-1], OK)
        self.assertEqual(self.errors(), [])
        self.assertTrue(self.live().startswith('state=ready pid=1 '), self.live())
        sid = self.sid()
        self.assertRegex(sid, chat.UUID4)
        self.assertTrue((self.real_folder / (sid + '.jsonl')).exists())
        rows = self.listed_until_one()
        self.assertEqual(len(rows), 1, rows)
        time.sleep(1.5)                             # another poll and page: still the one row
        self.assertEqual(len(self.listed()), 1)
        # (2) a permission card, allowed ("echo" alone runs unasked: the user's settings allow Bash(echo:*))
        command = 'touch rhun-test.txt && echo rhun-test'
        self.send('Use the Bash tool to run exactly this command, then reply with the word done: ' + command,
                  'waiting|ready')
        card = self.card()
        self.assertIsNotNone(card, ('no card', self.thread()))
        self.assertTrue(card.startswith('card=Allow this bash command? '), card)
        self.assertIn(command, card)
        self.assertIn(f'tool(Bash) {command}', self.thread())
        self.pick('Yes')
        self.wait('ready')
        thread = self.thread()
        self.assertIn('result rhun-test', thread)
        self.assertTrue((self.project / 'rhun-test.txt').exists())
        self.assertIsNone(self.card())
        self.assertEqual(self.errors(), [])
        # (3) a permission denied: the turn ends, the conversation goes on
        self.send('Use the Bash tool to run exactly this command: touch rhun-denied.txt', 'waiting|ready')
        self.assertIn('touch rhun-denied.txt', self.card() or '', self.thread())
        self.pick('No')
        self.wait('ready')
        self.assertFalse((self.project / 'rhun-denied.txt').exists())
        self.assertIsNone(self.card())
        self.assertIn(' requests=0 ', self.live())
        self.assertEqual(self.errors(), [])
        thread = self.thread()
        self.assertIn('result ' + chat.REJECTED[:60], thread)
        self.assertEqual(thread[-1], 'info Interrupted', thread)   # No interrupts: the turn ends there
        # (4) Stop during a long reply, then a short prompt
        before = len(self.thread())
        self.send(COUNT, 'working')
        self.until(lambda: any(r.startswith('agent') and re.search(r'\d', r) for r in self.thread()[before:]),
                   'the count streams', 60)
        self.command('agent-stop')
        self.wait('ready')
        thread = self.thread()
        self.assertEqual(thread[-1], 'info Interrupted', thread[before:])
        self.assertEqual(thread[before:].count('info Interrupted'), 1, thread[before:])
        self.assertEqual(self.errors(), [])
        self.send('Reply with the word ok')
        self.assertRegex(self.thread()[-1], OK)
        self.assertEqual(self.errors(), [])
        # (5) release, then the same conversation again (--resume)
        streamed = self.thread()
        self.command('agent-release')
        self.wait('off', 20000)
        self.until_gone()
        reread = self.thread()
        with self.subTest('the rows streamed are the rows the file gives'):
            self.assertEqual(reread, streamed)
        self.send('Reply with the word ok')
        pid = self.child()                          # it runs on after the turn, until released
        self.assertIsNotNone(pid, self.command('print-uproc'))
        self.assertIn('--resume=' + sid, child_args(pid))
        self.assertRegex(self.thread()[-1], OK)
        self.assertEqual(self.sid(), sid)
        self.command('agent-release')
        self.wait('off', 20000)
        self.until_gone()
        after = self.thread()
        self.assertEqual(after[:len(reread)], reread)
        self.stop()
        self.start()
        self.assertEqual(self.open_listed(), after)

    def test_markdown_reply(self):
        """(6) a reply drawn as its Markdown blocks."""
        self.start()
        self.command('agent-new claude')
        self.send("Reply with a level-2 heading 'T', a two-item list and a fenced code block containing "
                  "x=1. Nothing else.")
        thread = self.thread()
        self.assertEqual(self.errors(), [])
        n = next(i for i, row in enumerate(thread) if row.startswith('agent')) + 1
        blocks = self.command(f'print-agent-row {n}').splitlines()
        self.assertTrue(blocks[0].startswith('row='), blocks)
        self.assertIn('role=agent', blocks[0])
        body = blocks[1:]
        self.assertIn('heading:2 T', body)
        self.assertIn('list 2 items', body)
        self.assertTrue(any(re.fullmatch(r'code:\S* 1 lines?', b) for b in body), body)

    def test_quit_mid_turn(self):
        """(7) quit rhun while a turn runs: the child is gone within 10 s."""
        self.start()
        self.command('agent-new claude')
        self.send(COUNT, 'working')
        pid = self.child()
        self.assertIsNotNone(pid, self.command('print-uproc'))
        self.quit()
        self.until(lambda: not chat.alive(pid), f'claude {pid} still runs', 10)


if __name__ == '__main__':
    unittest.main()
