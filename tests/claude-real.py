#!/usr/bin/env python3
"""rhun's chat against the real Claude Code, opt in: RHUN_REAL_CLAUDE=1 (skipped otherwise; not in
tests/run.sh, never in CI). It spends about 30 small prompts of the maintainer's own plan (phase 2's
on Haiku with low effort; the model test picks Sonnet on a running process but sends it no prompt). It never sends /fast or update_settings,
and saves permission rules for "this session" only; the module's teardown checks that
~/.claude/settings.json is byte for byte what it was (a checksum, never the content) and prints what the
run left under ~/.claude: the CLI's own session-env/<id> folders and the plan test's plans/NAME.md.

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

rhun finds the conversation's file there too: its Claude folder follows the HOME the child gets (the
env.HOME pair), so it reads the real ~/.claude/projects/<slug> and sessions/ (nothing else of ~/.claude).

The project is a fresh git repository with one file in a temporary folder (RHUN_REAL_CLAUDE_TMP, or the
system's), outside any rhun checkout. At the end the real ~/.claude/projects folders named after the
test's projects are deleted, and nothing else there: each name is checked to hold the slug of the
test's own temporary folder first, and printed.

RHUN_REAL_CLAUDE_RECORD=DIR: every line between rhun and the CLI goes to DIR/<test>.jsonl
({"dir": "in"|"out", "t": seconds, "msg": ...}) through a small wrapper, and the conversations' files
are copied there before they are deleted, for finding out what the CLI sent; the initialize answer
names the account, so keep such files to yourself."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import pwd
import re
import select
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


SETTINGS = REAL_HOME / '.claude/settings.json'
BEFORE = {}
BASES = []                          # the temporary folders of the run
SIDS = set()                        # the conversations the run made (their files' names)


def checksum(path):
    """The SHA-256 of a file's bytes (never its content), or None when it is missing."""
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except FileNotFoundError:
        return None


def claude_names():
    """The names in each folder of the real ~/.claude (names only: nothing is opened)."""
    out = {}
    root = REAL_HOME / '.claude'
    for sub in root.iterdir() if root.is_dir() else ():
        if sub.is_dir() and not sub.is_symlink():
            try:
                out[sub.name] = set(os.listdir(sub))
            except OSError:
                pass
    return out


def setUpModule():
    """The maintainer's own Claude Code settings: their checksum before the run (~/.claude.json changes by
    itself as the CLI runs: only its presence is noted)."""
    if ENABLED:
        BEFORE['settings'] = checksum(SETTINGS)
        BEFORE['names'] = claude_names()


def tearDownModule():
    """The settings file is byte for byte what it was; what the run left under ~/.claude is printed (names
    that carry one of the run's conversation ids or temporary folders, and plan files made meanwhile)."""
    if not ENABLED or 'settings' not in BEFORE:
        return
    after = claude_names()
    marks = SIDS | {chat.slug(base) for base in BASES}
    for folder, names in sorted(after.items()):
        new = sorted(names - BEFORE['names'].get(folder, set()))
        ours = [n for n in new if folder == 'plans' or any(m in n for m in marks)]
        if ours:
            print(f'left in ~/.claude/{folder}: {" ".join(ours)}', file=sys.stderr)
    if checksum(SETTINGS) != BEFORE['settings']:
        raise AssertionError('~/.claude/settings.json changed during the run')
    print('~/.claude/settings.json: unchanged', file=sys.stderr)


def outside(program, cwd):
    """What a claude started outside rhun in cwd applies, (model, effort), from get_settings: no prompt is
    sent. Nothing else of its answers is kept."""
    env = dict(chat.clean_env(os.environ), HOME=str(REAL_HOME), TERM='dumb')
    child = subprocess.Popen([str(program), '--output-format', 'stream-json', '--verbose', '--input-format',
                              'stream-json', '--permission-prompt-tool=stdio', '--setting-sources=user,project,local'],
                             cwd=cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL)
    try:
        for n, subtype in ((1, 'initialize'), (2, 'get_settings')):
            request = {'subtype': subtype, 'hooks': None} if n == 1 else {'subtype': subtype}
            child.stdin.write((json.dumps({'type': 'control_request', 'request_id': f'o{n}',
                                           'request': request}) + '\n').encode())
        child.stdin.flush()
        deadline = time.monotonic() + 60
        buf = b''
        while time.monotonic() < deadline:
            ready, _, _ = select.select([child.stdout], [], [], 1)
            if not ready:
                continue
            chunk = os.read(child.stdout.fileno(), 65536)
            if not chunk:
                break
            buf += chunk
            while b'\n' in buf:
                line, buf = buf.split(b'\n', 1)
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                response = msg.get('response') or {}
                if msg.get('type') == 'control_response' and response.get('request_id') == 'o2':
                    applied = (response.get('response') or {}).get('applied') or {}
                    return applied.get('model'), applied.get('effort')
        return None
    finally:
        child.stdin.close()
        child.stdout.close()
        try:
            child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait(timeout=10)


def child_args(pid):
    try:
        return subprocess.run(['ps', '-p', str(pid), '-o', 'args='], capture_output=True, text=True).stdout
    except OSError:
        return ''


@unittest.skipUnless(ENABLED, 'set RHUN_REAL_CLAUDE=1 to run against the real Claude Code')
class RealCase(chat.DrivenCase):
    base = None
    made = []                       # the real ~/.claude/projects folders the projects get
    record_wire = False             # every line between rhun and the CLI to the test's wire.jsonl

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
        BASES.append(cls.base)
        if str(cls.base).startswith(str(ROOT)):
            raise AssertionError('the temporary folder is inside the checkout')

    @classmethod
    def tearDownClass(cls):
        mark = chat.slug(cls.base)
        for folder in cls.made:
            if folder.parent == REAL_PROJECTS and mark in folder.name and folder.is_dir() \
                    and not folder.is_symlink():
                record = os.environ.get('RHUN_REAL_CLAUDE_RECORD')
                for path in folder.glob('*.jsonl'):
                    SIDS.add(path.stem)
                    if record:
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
        home.mkdir()
        self.real_folder = real
        self.config = self.work / 'config/rhun/config'
        self.config.parent.mkdir(parents=True)
        self.fake_log = self.work / 'no-fake.log'
        self.env = dict(chat.clean_env(os.environ), HOME=str(home), XDG_CONFIG_HOME=str(self.work / 'config'),
                        XDG_STATE_HOME=str(self.work / 'state'), GIT_CONFIG_NOSYSTEM='1', TERM='dumb')
        self.recorder = None
        record = os.environ.get('RHUN_REAL_CLAUDE_RECORD')
        if record or self.record_wire:
            self.recorder = self.work / 'recorder.py'
            self.recorder.write_text(RECORDER, encoding='utf-8')
            self.recorder.chmod(0o755)
            self.env['REC_LOG'] = str(self.work / 'wire.jsonl')
        if record:
            Path(record).mkdir(parents=True, exist_ok=True)
            self.env['REC_LOG'] = str(Path(record).resolve() / (self._testMethodName + '.jsonl'))
        self.process = self.client = self.reader = None
        self.sockets = None
        self.children = set()

    def tearDown(self):
        self.stop()
        for pid in self.children:              # every claude this test saw ends with its rhun (by pid only)
            deadline = time.monotonic() + 10
            while chat.alive(pid) and time.monotonic() < deadline:
                time.sleep(0.1)
            if chat.alive(pid):
                os.kill(pid, 9)
                self.fail(f'claude {pid} outlived its rhun')
        if self.sockets is not None:
            shutil.rmtree(self.sockets, ignore_errors=True)

    def claude_section(self, extra='', mode='default'):
        section = f'[claude]\nexecutable = {self.program}\ninitial_mode = {mode}\nenv.HOME = {REAL_HOME}\n'
        if self.recorder:
            section = (f'[claude]\nwrapper = {PYTHON}\nexecutable = {self.recorder}\ninitial_mode = {mode}\n'
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
                    if not kids:
                        return None
                    pid = kids[0]
                self.children.add(int(pid))
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
        self.assertIn(' state=denied', self.command('print-agent-rows 0 1000'))   # phase 3: the call's state
        self.assertIn(thread[-1], ('info Interrupted', 'info Tool interrupted'), thread)   # No interrupts: the turn ends there
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


CHEAP = 'haiku'                     # the model of every test that is not about the model
KEEP = 'User chose to stay in plan mode and continue planning'      # tests/claude-cards.py's words
COMMENTS = '\n\nComments on the plan:\n'
REASON = ("The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file "
          "edit, the new_string was NOT written to the file). The user provided the following reason for the "
          "rejection: ")


class Phase2Test(RealCase):
    """Phase 2's cards and controls against the real CLI. Every line between rhun and the CLI goes to the
    test's wire.jsonl (in its temporary folder, deleted with it; it holds the initialize answer, which
    names the account: nothing here prints a whole line of it). Rules a test saves go to "this session"
    only; nothing sends update_settings; the module's teardown checks ~/.claude/settings.json is byte for
    byte what it was."""
    record_wire = True

    # ---- the wire ----

    def wire(self, direction):
        path = Path(self.env['REC_LOG'])
        if not path.exists():
            return []
        out = []
        for line in path.read_text(encoding='utf-8').splitlines():
            try:
                rec = json.loads(line)
            except ValueError:
                continue                        # a line being written
            if rec['dir'] == direction and isinstance(rec['msg'], dict):
                out.append(rec['msg'])
        return out

    def requests(self, subtype=None):
        """rhun's control requests to the CLI."""
        out = [m['request'] for m in self.wire('out') if m.get('type') == 'control_request']
        return [r for r in out if subtype is None or r.get('subtype') == subtype]

    def answers(self):
        """rhun's answers to the CLI's can_use_tool requests, in order."""
        out = []
        for m in self.wire('out'):
            inner = (m.get('response') or {}).get('response')
            if m.get('type') == 'control_response' and isinstance(inner, dict) and 'behavior' in inner:
                out.append(inner)
        return out

    def asked(self, tool=None):
        """The CLI's can_use_tool requests, in order."""
        out = [m['request'] for m in self.wire('in') if m.get('type') == 'control_request'
               and m['request'].get('subtype') == 'can_use_tool']
        return [r for r in out if tool is None or r.get('tool_name') == tool]

    def statuses(self):
        """The permission modes the CLI reported (system/status and system/init), in order."""
        return [m['permissionMode'] for m in self.wire('in') if m.get('type') == 'system'
                and m.get('subtype') in ('status', 'init') and m.get('permissionMode')]

    def models_replied(self):
        """The models the CLI's assistant messages name, in order (synthetic ones left out)."""
        return [m['message'].get('model') for m in self.wire('in') if m.get('type') == 'assistant'
                and m['message'].get('model') not in (None, '<synthetic>')]

    def last_text(self):
        """The text of the CLI's last assistant message that has text."""
        for m in reversed(self.wire('in')):
            if m.get('type') == 'assistant':
                text = ''.join(b.get('text', '') for b in m['message'].get('content') or []
                               if isinstance(b, dict) and b.get('type') == 'text')
                if text:
                    return text
        return ''

    def no_settings_writes(self):
        self.assertEqual(self.requests('update_settings'), [])
        self.assertNotIn('userSettings', json.dumps(self.requests()))
        for answer in self.answers():
            for update in answer.get('updatedPermissions') or []:
                self.assertEqual(update.get('destination'), 'session', update)
        self.assertFalse((self.project / '.claude').exists())

    # ---- rhun ----

    def begin(self, mode='default', model=CHEAP, effort='low'):
        """rhun with initial_mode MODE, the project's model and effort set as the picker sets them, cards live
        at once, a new conversation (its draft)."""
        self.start(self.claude_section(mode=mode))
        if model:
            self.command(f'agent-cfg-set model {model}')
        if effort:
            self.command(f'agent-cfg-set effort {effort}')
        self.command('agent-timing card=0 advance=0')
        self.command('agent-new claude')

    def head(self):
        """print-agent-card's first line as a dict, or None."""
        lines = self.command('print-agent-card').splitlines()
        return dict(re.findall(r'(\w+)=(.*?)(?= \w+=|$)', lines[0])) if lines else None

    def card_lines(self, word):
        return [line[len(word) + 1:] for line in self.command('print-agent-card').splitlines()[1:]
                if line.startswith(word + ' ')]

    def mode(self):
        return re.search(r' mode=(\S*)', self.live()).group(1)

    def queued(self):
        return [line for line in self.command('print-agents').splitlines() if line.startswith('queued ')]

    def menu_rows(self):
        """print-agent-menu's rows as (section, label, description, trail, flags)."""
        out, section = [], None
        for line in self.command('print-agent-menu').splitlines():
            if line.startswith('section '):
                section = line[len('section '):].split('\t')[0]
            elif line.startswith('row '):
                label, desc, trail, flags = line.split(' ', 2)[2].split('\t')
                out.append((section, label, desc, trail, flags))
        return out

    def card_turn(self, prompt, kind, again=None):
        """Send prompt until a card of kind shows; once more (again, or the same) when Claude did not call
        the tool. The card's head."""
        for n, text in enumerate((prompt, again or prompt)):
            if n:
                print(f'\n{self._testMethodName}: no {kind} card, asked once more', file=sys.stderr)
            self.send(text, 'waiting|ready')
            head = self.head()
            if head and head.get('kind') == kind:
                return head
            self.assertIsNone(head, head)
        self.fail(f'no {kind} card: {self.thread()[-4:]}')

    def until_waiting_or_ready(self, before):
        """After an answer: until a new card (a request after the before-th) or the end of the turn."""
        self.until(lambda: len(self.asked()) > before or self.live().startswith('state=ready'),
                   'a new request or the turn end', WAIT_MS / 1000)
        self.wait('waiting|ready')

    # ---- the tests ----

    def test_permission_card_with_a_session_rule(self):
        """Bash `touch r.txt` in default mode: the rule button with its place cycled to "this session",
        allowed; the same command again, back in default mode, runs without a card. Saves: the rule
        Bash(touch r.txt) and the CLI's other suggestions (a directory, acceptEdits) for this session only
        (destination session), in the CLI's memory; nothing on disk."""
        self.begin()
        command = 'touch r.txt'
        prompt = f'Use the Bash tool to run exactly this command, then reply with the word done: {command}'
        head = self.card_turn(prompt, 'permission')
        self.assertEqual(head['title'], 'Allow this bash command?')
        self.assertEqual(self.card_lines('edit'), [command])
        self.assertEqual(head['dest'], 'localSettings')       # the suggestion's own (finding 15)
        places = []
        while self.head()['dest'] != 'session':
            self.command('agent-card dest')                   # shown only: nothing is sent while it cycles
            places.append(self.head()['dest'])
            self.assertLessEqual(len(places), 3, places)
        self.assertEqual(places, ['userSettings', 'projectSettings', 'session'])
        buttons = [line.split(' ', 1)[1] for line in self.card_lines('button')]
        self.assertEqual(buttons[1], f'Yes, allow {command} for [this session]')
        self.assertEqual(self.answers(), [])
        self.command('agent-card 2')
        self.wait('ready')
        answer = self.answers()[0]
        self.assertEqual(answer['behavior'], 'allow')
        rules = [u for u in answer['updatedPermissions'] if u['type'] == 'addRules']
        self.assertEqual(rules[0]['rules'], [{'toolName': 'Bash', 'ruleContent': command}])
        self.assertTrue((self.project / 'r.txt').exists())
        self.assertIsNone(self.head())
        self.assertEqual(self.errors(), [])
        # the setMode acceptEdits suggestion went with it: back to default, where the rule alone allows it
        if self.mode() != 'default':
            self.command('agent-mode default')
            self.until(lambda: self.mode() == 'default', 'default mode', 30)
        (self.project / 'r.txt').unlink()
        asked = len(self.asked())
        self.send(f'Use the Bash tool to run exactly this command again, then reply with the word done: {command}',
                  'waiting|ready')
        self.assertIsNone(self.head(), self.thread()[-4:])
        self.assertEqual(len(self.asked()), asked)
        self.assertTrue((self.project / 'r.txt').exists(), self.thread()[-4:])
        self.no_settings_writes()

    def test_deny_with_a_reason(self):
        """No with a reason typed in the card's field: the CLI gets the extension's rejection with the reason,
        the turn goes on (no interrupt) and Claude answers. Saves nothing."""
        self.begin()
        head = self.card_turn('Use the Bash tool to run exactly this command: touch denied.txt', 'permission')
        self.assertEqual(head['title'], 'Allow this bash command?')
        reason = 'not now; reply with the word skipped'
        self.command(f'agent-card-text field {reason}')
        n = len(self.card_lines('button'))
        self.command(f'key {n + 1}')                           # the number after the last: the field
        self.assertEqual(self.head()['focus'], 'field')
        self.command('key Return')
        self.wait('ready')
        answer = self.answers()[0]
        self.assertEqual((answer['behavior'], answer['message'], answer['interrupt']),
                         ('deny', REASON + ' ' + reason, False))
        self.assertFalse((self.project / 'denied.txt').exists())
        thread = self.thread()
        self.assertIn(' state=denied', self.command('print-agent-rows 0 1000'))   # phase 3: the call's state
        self.assertNotEqual(thread[-1], 'info Interrupted', thread[-4:])
        self.assertTrue(thread[-1].startswith('agent'), thread[-4:])
        self.assertIn('skipped', self.last_text().lower())
        self.assertEqual(self.errors(), [])
        self.no_settings_writes()

    def test_queued_message(self):
        """A second prompt while the first turn streams: written at once with its uuid, shown queued, then
        its own turn; the rows in order. Saves nothing."""
        self.begin()
        first = 'Count from 1 to 400, one number per line. Nothing else.'
        self.send(first, 'working')
        self.until(lambda: any(r.startswith('agent') and re.search(r'\d', r) for r in self.thread()),
                   'the count streams', 60)
        second = 'Reply with the word two'
        self.command('agent-prompt ' + second)
        self.until(lambda: len([m for m in self.wire('out') if m.get('type') == 'user']) == 2, 'written at once')
        self.assertEqual(self.queued(), ['queued ' + second])
        self.assertNotIn('user ' + second, self.thread())
        self.assertRegex(self.command('print-agent-live'), r' held=1 ')
        self.until(lambda: not self.queued() and 'user ' + second in self.thread(), 'the second turn starts',
                   WAIT_MS / 1000)
        self.until(lambda: re.search(r' held=0 ', self.command('print-agent-live')) and
                   self.live().startswith('state=ready') and self.thread()[-1].startswith('agent'),
                   'the second reply', WAIT_MS / 1000)
        thread = self.thread()
        users = [i for i, row in enumerate(thread) if row.startswith('user')]
        self.assertEqual([thread[i] for i in users], ['user ' + first, 'user ' + second])
        self.assertTrue(all(r.startswith('agent') for r in thread[users[0] + 1:users[1]]), thread)
        self.assertTrue(thread[users[0] + 1:users[1]], thread)
        self.assertIn('two', self.last_text().lower())
        uuids = [m.get('uuid') for m in self.wire('out') if m.get('type') == 'user']
        self.assertEqual(len(uuids), 2)
        for u in uuids:
            self.assertRegex(u or '', chat.UUID4)
        states = [(m.get('command_uuid'), m.get('state')) for m in self.wire('in')
                  if m.get('type') == 'command_lifecycle']
        self.assertIn((uuids[1], 'queued'), states)
        self.assertIn((uuids[1], 'completed'), states)
        self.assertEqual(self.errors(), [])
        self.no_settings_writes()

    def test_mode_picker_and_shift_tab(self):
        """Plan from the modes picker on a running process, then Shift+Tab round to default: the CLI's own
        reports follow. Saves nothing (set_permission_mode changes this process only; rhun keeps the
        conversation's mode in its own state file)."""
        self.begin()
        self.send('Reply with the word ok')
        self.assertEqual(self.mode(), 'default')
        self.command('agent-modes')
        rows = [r for r in self.menu_rows() if not r[4].startswith('levels=')]
        labels = [r[1] for r in rows]
        self.assertEqual(labels[:3], ['Manual', 'Edit automatically', 'Plan'])
        self.assertEqual(rows[0][4], 'check')
        self.command(f'agent-menu-pick {labels.index("Plan") + 1}')
        self.until(lambda: self.mode() == 'plan', 'plan mode', 30)
        self.until(lambda: self.statuses()[-1:] == ['plan'], 'the CLI says plan', 30)
        self.assertEqual(self.requests('set_permission_mode'), [{'subtype': 'set_permission_mode', 'mode': 'plan'}])
        seen = []
        for _ in range(len(labels)):                          # round to Manual: Auto first when offered
            if self.mode() == 'default':
                break
            asked = len(self.requests('set_permission_mode'))
            self.command('key shift+Tab')
            self.until(lambda: len(self.requests('set_permission_mode')) > asked, 'the next mode asked', 30)
            want = self.requests('set_permission_mode')[-1]['mode']
            self.until(lambda: self.mode() == want, f'mode {want}', 30)
            seen.append(want)
        self.assertEqual(seen[-1], 'default')
        self.assertEqual(seen, ['auto', 'default'] if 'Auto' in labels else ['default'])
        self.until(lambda: self.statuses()[-1:] == ['default'], 'the CLI says default', 30)
        self.send('Reply with the word ok')                   # the process goes on, in default
        self.assertRegex(self.thread()[-1], OK)
        self.assertEqual(self.statuses()[-1], 'default')
        self.assertEqual(self.errors(), [])
        self.no_settings_writes()

    def test_model_and_effort_are_rhuns_own(self):
        """A model and effort picked while the CLI runs reach it as apply_flag_settings; picked before a start,
        as --model and --effort; a claude started outside rhun in the same folder afterwards applies what
        it did before (the user's defaults did not move). Saves nothing: apply_flag_settings changes the
        running process only, and update_settings is never sent."""
        before = outside(self.program, self.project)
        self.assertIsNotNone(before)
        self.begin()                                          # haiku, low: passed at the start
        self.send('Reply with the word ok')
        pid = self.child()
        self.assertIsNotNone(pid)
        args = child_args(pid)
        self.assertIn(f'--model={CHEAP}', args)
        self.assertIn('--effort=low', args)
        self.until(lambda: ' model=claude-haiku' in self.command('print-agent-live'), 'haiku applied', 30)
        self.assertTrue(all(m.startswith('claude-haiku') for m in self.models_replied()), self.models_replied())
        # picked while it runs
        self.command('agent-model sonnet')
        self.command('agent-effort medium')
        self.until(lambda: re.search(r' model=claude-sonnet\S* effort=medium ', self.command('print-agent-live')),
                   'sonnet and medium applied', 30)
        self.assertEqual(self.requests('apply_flag_settings'),
                         [{'subtype': 'apply_flag_settings', 'settings': {'model': 'sonnet'}},
                          {'subtype': 'apply_flag_settings', 'settings': {'effortLevel': 'medium'}}])
        self.assertEqual(self.child(), pid)                   # the same process
        self.assertIn('model=sonnet effort=medium', self.command('print-agent-cfg'))
        # picked before a start
        self.command('agent-release')
        self.wait('off', 20000)
        self.until_gone()
        self.command(f'agent-model {CHEAP}')
        self.command('agent-effort low')
        self.send('Reply with the word ok')
        args = child_args(self.child())
        self.assertIn(f'--model={CHEAP}', args)
        self.assertIn('--effort=low', args)
        self.assertRegex(self.thread()[-1], OK)
        self.assertTrue(self.models_replied()[-1].startswith('claude-haiku'), self.models_replied())
        self.assertEqual(len(self.requests('apply_flag_settings')), 2)
        self.command('agent-release')
        self.wait('off', 20000)
        self.until_gone()
        self.assertEqual(outside(self.program, self.project), before)
        self.no_settings_writes()

    def test_question_card(self):
        """AskUserQuestion with two questions, the second multi-select: a tab each, red picked, then both
        sizes, Submit; Claude repeats the answers. Saves nothing."""
        self.begin()
        prompt = ("Call the AskUserQuestion tool once, with exactly two questions in the one call: first "
                  "'Which colour?' (header 'Colour', multiSelect false, options 'red' and 'blue'), second "
                  "'Which sizes?' (header 'Sizes', multiSelect true, options 'small' and 'large'). After my "
                  "answer, reply with my answers only.")
        head = self.card_turn(prompt, 'questions', again='You did not call it. ' + prompt)
        questions = self.asked('AskUserQuestion')[-1]['input']['questions']
        self.assertEqual(len(questions), 2, [q.get('question') for q in questions])
        self.assertEqual([bool(q.get('multiSelect')) for q in questions], [False, True])
        self.assertEqual(len(self.card_lines('tab')), 2)
        self.assertEqual(head['focus'], 'options')
        labels = [[o['label'] for o in q['options']] for q in questions]
        self.command(f'agent-card {labels[0].index("red") + 1}')      # a single choice moves on
        self.until(lambda: self.card_lines('question') == [questions[1]['question']], 'the second tab')
        for size in ('small', 'large'):
            self.command(f'agent-card {labels[1].index(size) + 1}')
        self.assertEqual(self.card_lines('submit'), ['enabled=1'])
        self.command('agent-card submit')
        self.wait('ready')
        answer = self.answers()[-1]
        self.assertEqual(answer['behavior'], 'allow')
        self.assertEqual(answer['updatedInput']['answers'], {questions[0]['question']: 'red',
                                                             questions[1]['question']: 'small, large'})
        self.assertIsNone(self.head())
        self.assertTrue(self.thread()[-1].startswith('agent'), self.thread()[-3:])
        reply = self.last_text().lower()                      # the row shows its first 60 bytes: the wire's
        self.assertTrue('red' in reply and 'small' in reply and 'large' in reply, reply)
        self.assertEqual(self.errors(), [])
        self.no_settings_writes()

    def test_plan_review(self):
        """Plan mode: the plan in a tab, a comment on its text, Send feedback (a deny without interrupt: Claude
        plans again), the second plan accepted with "Yes, and manually approve edits" (set_permission_mode
        default and a setMode for this session), then its Write asks. Saves: the CLI writes each plan to
        ~/.claude/plans/NAME.md (its own place, as in a terminal); the setMode goes to session; the file
        Claude makes lands in the temporary repository."""
        self.begin(mode='plan')
        prompt = ('Make a plan to create the file a.txt containing the word hi. Keep the plan to two short lines, '
                  'then call ExitPlanMode.')
        head = self.card_turn(prompt, 'plan', again='Call ExitPlanMode with your plan now.')
        self.assertEqual(head['title'], 'Accept this plan?')
        tabs = self.command('print-mdtab').splitlines()
        self.assertEqual(sum(line.startswith('mdtab ') for line in tabs), 1, tabs)
        self.assertIn(' comment=1 ', tabs[0])
        phrase = None
        for line in tabs[1:]:
            text = re.sub(r'^\s*(#+|[-*]|\d+\.)\s*', '', line[5:]) if line.startswith('text') else ''
            words = re.findall(r"[A-Za-z][A-Za-z']*", text)
            if len(words) >= 2 and not re.search(r'[*_`\[\]<>]', text):
                phrase = ' '.join(words[:2])
                if phrase in text:
                    break
                phrase = None
        self.assertIsNotNone(phrase, tabs)
        self.command('mdtab-select ' + phrase)
        self.command('mdtab-comment name the file b.txt instead')
        head = self.head()
        self.assertEqual(head['title'], 'Continue planning')
        self.assertEqual(self.card_lines('comment'), [f'1 "{phrase}" name the file b.txt instead'])
        plans = len(self.asked('ExitPlanMode'))
        self.command('agent-card 1')                          # Send feedback and keep planning
        self.until_waiting_or_ready(plans)
        answer = self.answers()[-1]
        self.assertEqual((answer['behavior'], answer['interrupt']), ('deny', False))
        self.assertEqual(answer['message'], KEEP + COMMENTS + f'[Re: "{phrase}"] name the file b.txt instead')
        head = self.head()
        if not head:                                          # it stopped without a second plan: ask once
            head = self.card_turn('Call ExitPlanMode with the revised plan now.', 'plan')
        self.assertEqual((head['kind'], head['title']), ('plan', 'Accept this plan?'))
        self.assertGreater(len(self.asked('ExitPlanMode')), plans)
        asked = len(self.asked())
        self.command('agent-card 2')                          # Yes, and manually approve edits
        self.until_waiting_or_ready(asked)
        answer = self.answers()[-1]
        self.assertEqual(answer['behavior'], 'allow')
        self.assertEqual(answer['updatedPermissions'], [{'type': 'setMode', 'mode': 'default',
                                                         'destination': 'session'}])
        self.assertEqual(self.requests('set_permission_mode')[-1], {'subtype': 'set_permission_mode',
                                                                     'mode': 'default'})
        self.assertEqual(self.mode(), 'default')
        self.assertEqual([line for line in self.command('print-mdtab').splitlines() if line.startswith('mdtab ')],
                         [])
        head = self.head()
        if head is None:                                      # it ended the turn: one more nudge
            head = self.card_turn('Carry out the approved plan now.', 'permission')
        self.assertEqual(head['kind'], 'permission')           # manual: the edit asks
        self.assertIn(self.asked()[-1]['tool_name'], ('Write', 'Edit', 'Bash'))
        self.command('agent-card 1')                          # Yes, once
        self.wait('waiting|ready')
        while self.head():                                    # anything else it asks: once each
            self.command('agent-card 1')
            self.wait('waiting|ready')
        self.assertTrue((self.project / 'b.txt').exists() or (self.project / 'a.txt').exists(),
                        self.thread()[-4:])
        self.assertEqual(self.errors(), [])
        self.no_settings_writes()

    def test_menu_lists_the_cli_commands(self):
        """The command menu (a "/" typed in the box) lists every command the CLI advertised, with its argument
        hint, and rhun's /copy and /plan; its foot names the CLI's version. Saves nothing (one tiny prompt
        starts the process; the menu sends nothing)."""
        self.begin()
        self.send('Reply with the word ok')
        cli = None
        version = None
        for m in self.wire('in'):
            inner = (m.get('response') or {}).get('response') or {}
            if m.get('type') == 'control_response' and 'commands' in inner and 'claude_code_version' in inner:
                cli, version = inner['commands'], inner['claude_code_version']
            elif m.get('type') == 'system' and m.get('subtype') == 'commands_changed':
                cli = m['commands']
        self.assertTrue(cli)
        sent = len(self.wire('out'))
        self.command('agent-type /')
        menu = self.command('print-agent-menu')
        self.assertTrue(menu.startswith('popup=menu '), menu[:200])
        rows = [r for r in self.menu_rows() if r[0] == 'Slash Commands']
        listed = {r[1][1:]: r for r in rows}
        self.assertEqual(len(listed), len(rows))              # each once
        names = {c['name'] for c in cli}
        own = {'copy', 'plan', 'btw', 'tasks', 'chrome', 'export', 'remote-control'}   # rhun's, as the extension's
        self.assertEqual(set(listed) - names, own - names)
        self.assertEqual(sorted(names - set(listed)), [])
        for c in cli:
            hint = c.get('argumentHint') or '-'
            self.assertEqual(listed[c['name']][3], hint, c['name'])
        self.assertIn(f'foot v{version}', menu)
        self.command('key Escape')
        self.assertEqual(len(self.wire('out')), sent)        # the menu sent nothing
        self.no_settings_writes()


if __name__ == '__main__':
    unittest.main()
