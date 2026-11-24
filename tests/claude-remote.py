#!/usr/bin/env python3
"""Claude Code's chat in a remote window (docs/guide.md "Talk to Claude Code"): claude runs on the host,
started through the remote agent (src/app/agent_conn.s over vfs_uproc_spawn), in the project's folder there
with the host's login environment; everything that reads Claude Code's files reads the host's (the list,
the transcripts, the sessions records of the "open somewhere else" check, CLAUDE_CONFIG_DIR as the host's
login shell sets it); a missing or signed-out claude is named with the host; a dropped connection ends the
turn plainly and a reconnect lets the conversation go on.

DockerHost: a Linux container reached with `docker exec`, python3 in it, the fake CLI
(tests/scripts/fake-claude.py) installed there as /usr/local/bin/claude. A macOS client needs a Linux build
to send (RHUN_TEST_LINUX_EXE); the window's own HOME has no Claude folder, so a file read here instead of
there shows. LocalHost (Linux only): the `local:` transport, with RHUN_REMOTE_STRICT=1, which stops rhun
when a local file function is given a path of the project."""
import importlib.util
import json
import os
from pathlib import Path
import shlex
import socket
import subprocess
import sys
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location('claude_chat', ROOT / 'tests/claude-chat.py')
chat = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(chat)

EXE = chat.EXE
FAKE = chat.FAKE
LINUX_EXE = os.environ.get('RHUN_TEST_LINUX_EXE') or (str(EXE) if sys.platform.startswith('linux') else '')
IMAGE = os.environ.get('RHUN_TEST_CLAUDE_HOST_IMAGE', 'python:3.12-slim')
HOST = 'rhun-test-claude-host-%d' % os.getpid()
PROJ = '/root/proj'
SLUG = '-root-proj'
REPLY = chat.REPLY


def have_docker():
    try:
        return subprocess.run(['docker', 'info'], capture_output=True, timeout=20).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def docker(*args, check=True, input=None):
    return subprocess.run(['docker', *args], capture_output=True, check=check, input=input, timeout=600)


def sh(script, check=True, input=None):
    """A shell command on the host; its output as text."""
    return docker('exec', '-i', HOST, 'sh', '-c', script, check=check, input=input).stdout.decode(errors='replace')


def fixture(project):
    return (ROOT / 'tests/data/agents/claude.jsonl').read_bytes().replace(b'@PROJECT@', project.encode())


# the host's processes whose command line runs the fake in stream mode (no ps in the image)
STREAMING = ("import os\n"
             "for p in os.listdir('/proc'):\n"
             "    try: c = open('/proc/%s/cmdline' % p, 'rb').read().split(b'\\0')\n"
             "    except OSError: continue\n"
             "    if b'stream-json' in c and any(x.endswith(b'claude') for x in c): print(p)\n")


@unittest.skipIf(os.name == 'nt', 'the control socket is Unix only')
@unittest.skipUnless(have_docker(), 'needs docker')
@unittest.skipUnless(LINUX_EXE, 'needs a Linux rhun to send (RHUN_TEST_LINUX_EXE)')
class DockerHost(chat.DrivenCase):
    @classmethod
    def setUpClass(cls):
        docker('rm', '-f', HOST, check=False)
        docker('run', '-d', '--platform', 'linux/amd64', '--name', HOST, IMAGE, 'sleep', 'infinity')
        docker('exec', '-i', HOST, 'sh', '-c', 'cat > /usr/local/bin/claude && chmod 755 /usr/local/bin/claude',
               input=FAKE.read_bytes())
        sh('mkdir -p %s/src && printf "hello\\n" > %s/a.txt' % (PROJ, PROJ))

    @classmethod
    def tearDownClass(cls):
        docker('rm', '-f', HOST, check=False)

    def setUp(self):
        super().setUp()
        # every test starts from the same host: s1 seeded, no records, no log, the default profile
        sh('rm -rf /root/.claude /root/cc /root/fake.log /root/.profile /root/.local; '
           'mkdir -p /root/.claude/projects/%s' % SLUG)
        sh('cat > /root/.claude/projects/%s/s1.jsonl' % SLUG, input=fixture(PROJ))

    def start(self, claude='', extra='', env=None, target=None, remote=True):
        """rhun with a remote window on the container's project; claude: lines of [claude] (the fake is the
        host's `claude`, its log /root/fake.log)."""
        conf = (self.BASE + '[remote]\nagent_binary = %s\n' % LINUX_EXE +
                '[claude]\nenv.FAKE_CLAUDE_LOG = /root/fake.log\n' + claude + extra)
        self.config.write_text(conf, encoding='utf-8')
        control = self.work / 'control'
        if control.exists():
            control.unlink()
        self.process = subprocess.Popen([str(EXE), '--remote', 'docker:' + HOST, PROJ, '--headless', '1280x800',
                                         '--scale', '1', '--control', str(control)],
                                        env=dict(self.env, **(env or {})),
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.client.settimeout(120)
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
        self.command('wait-remote 90')
        self.assertIn('state=connected', self.command('print-remote'))

    def records(self):
        text = sh('cat /root/fake.log 2>/dev/null', check=False)
        return [json.loads(line) for line in text.splitlines() if line]

    def card(self):
        lines = self.command('print-agent-input').splitlines()
        return lines[1] if len(lines) > 1 else None

    def streaming(self):
        return sh('python3 -c %s' % shlex.quote(STREAMING), check=False).split()

    def test_a_conversation_runs_on_the_host(self):
        self.start()
        rows = self.listed()                        # the host's ~/.claude: this machine has none
        self.assertEqual(len(rows), 1, rows)
        self.command('print-agents 1')
        self.assertTrue(self.command('print-agent-input').splitlines()[0].endswith(' box=1'))
        self.command('agent-prompt hello')
        self.command('wait-agent ready 30000')
        self.assertEqual(self.thread()[-2:], ['user hello', REPLY + 'ok: hello'])
        starts = self.starts()
        self.assertEqual(len(starts), 1, starts)
        self.assertEqual(starts[0]['cwd'], PROJ)
        self.assertIn('--resume=s1', starts[0]['argv'])
        self.assertEqual(starts[0]['env']['CLAUDE_CODE_ENTRYPOINT'], 'rhun')
        self.assertEqual(starts[0]['env']['MCP_CONNECTION_NONBLOCKING'], 'true')
        auths = [r for r in self.records() if r.get('start') == 'auth']
        self.assertEqual(len(auths), 1, auths)      # the sign-in question ran there too
        self.assertIn('"text":"hello"', sh('cat /root/.claude/projects/%s/s1.jsonl' % SLUG).replace(' ', ''))
        self.assertEqual(len(self.streaming()), 1)
        self.assertIn('state=ready pid=1 sid=s1 ', self.live())
        # a new conversation: its file is the host's, under the project's slug there
        self.command('agent-new claude')
        self.command('agent-prompt again')
        self.command('wait-agent ready 30000')
        sid = self.sid()
        self.assertEqual(sh('ls /root/.claude/projects/%s/' % SLUG).split(), sorted(['s1.jsonl', sid + '.jsonl']))
        self.assertIn(' new=0', self.live())        # its file was found there
        self.assertEqual(len(self.streaming()), 2)
        self.quit()
        deadline = time.monotonic() + 10            # the window's end ends them on the host
        while self.streaming():
            self.assertLess(time.monotonic(), deadline, self.streaming())
            time.sleep(0.2)

    def test_the_hosts_login_environment_names_the_claude_folder(self):
        sh('printf "export CLAUDE_CONFIG_DIR=/root/cc\\n" > /root/.profile && mkdir -p /root/cc/projects/%s' % SLUG)
        sh('cat > /root/cc/projects/%s/s2.jsonl' % SLUG, input=fixture(PROJ))
        sh('rm /root/.claude/projects/%s/s1.jsonl' % SLUG)
        self.start('env.FAKE_CLAUDE_ECHO_ENV = CLAUDE_CONFIG_DIR\n')
        self.assertEqual(len(self.listed()), 1)     # s2, from the folder the host's login shell names
        self.command('print-agents 1')
        self.command('agent-prompt hello')
        self.command('wait-agent ready 30000')
        start = self.starts()[0]
        self.assertIn('--resume=s2', start['argv'])
        self.assertEqual(start['env']['CLAUDE_CONFIG_DIR'], '/root/cc')
        self.command('agent-new claude')
        self.command('agent-prompt fresh')
        self.command('wait-agent ready 30000')
        self.assertIn(self.sid() + '.jsonl', sh('ls /root/cc/projects/%s/' % SLUG).split())
        self.assertIn(' new=0', self.live())

    def test_claude_in_a_usual_place_of_the_host(self):
        # not on the host's PATH, in ~/.local/bin as its installer puts it
        sh('mkdir -p /root/.local/bin && cp /usr/local/bin/claude /root/.local/bin/claude && '
           'mv /usr/local/bin/claude /usr/local/bin/claude.away')
        try:
            self.start()
            self.chat('hello', 'ready', 30000)
            self.assertEqual(self.thread()[-1], REPLY + 'ok: hello')
            self.assertTrue(self.starts())
        finally:
            sh('mv /usr/local/bin/claude.away /usr/local/bin/claude')

    def test_claude_missing_on_the_host_says_so(self):
        self.start('executable = ~/nowhere/claude\n')
        self.chat('hello', 'failed', 30000)
        text = ('Claude Code was not found on %s. Install it there, or set its path on that machine in '
                'Settings > Claude Code.' % HOST)
        self.assertIn('report=' + text, self.live())
        self.assertTrue(self.thread()[-1].startswith('error Claude Code was not found on %s.' % HOST), self.thread())
        self.assertEqual(self.starts(), [])

    def test_not_signed_in_on_the_host(self):
        self.start('env.FAKE_CLAUDE_AUTH = out\n')
        self.chat('hello', 'failed', 30000)
        self.assertEqual(self.card(), 'card=Claude Code is not signed in on %s. options=Sign In' % HOST)
        self.assertEqual(self.starts(), [])
        self.assertTrue(self.command('print-agent-input').startswith('input=hello '))

    def test_held_on_the_host(self):
        # a record of the host's for s1 whose pid lives there (the container's own first process)
        sh('mkdir -p /root/.claude/sessions && printf %s > /root/.claude/sessions/1.json' % shlex.quote(json.dumps(
            {'pid': 1, 'sessionId': 's1', 'cwd': PROJ, 'pidDomain': 'linux', 'status': 'idle'})))
        self.start()
        self.command('agent-timing hold=300')
        self.open_listed()
        self.command('agent-prompt hello')
        self.command('wait-agent held 10000')
        self.assertEqual(self.card(), chat.HELD_CARD)
        self.assertEqual(self.starts(), [])
        # a record of a pid the host does not have holds nothing
        sh('mv /root/.claude/sessions/1.json /root/.claude/sessions/999999.json && '
           'sed -i "s/\\"pid\\": 1,/\\"pid\\": 999999,/" /root/.claude/sessions/999999.json')
        self.command('agent-card 3')                # Cancel: the prompt is back in the box
        self.assertTrue(self.command('print-agent-input').startswith('input=hello '))
        self.command('agent-prompt again')
        self.command('wait-agent ready 30000')
        self.assertTrue(self.starts())

    def test_a_drop_mid_turn_ends_it_and_a_reconnect_resumes(self):
        self.start()
        self.open_listed()
        self.command('agent-prompt slow')           # a reply streamed for 6 s
        self.command('wait-agent working 30000')
        self.until(lambda: self.streaming(), 'claude runs on the host')
        self.command('remote-drop')
        self.command('wait-agent failed 5000')
        lost = 'The connection to %s was lost.' % HOST
        self.assertIn('report=' + lost, self.live())
        self.assertIn('error ' + lost, self.thread())
        self.assertIn(' pid=0 ', self.live())
        self.command('remote-reconnect')
        self.command('wait-remote 90')
        self.assertIn('state=connected', self.command('print-remote'))
        # its program ends on the host (its input ended), the file is read again there
        deadline = time.monotonic() + 15
        while self.streaming():
            self.assertLess(time.monotonic(), deadline, self.streaming())
            time.sleep(0.2)
        self.until(lambda: 'user slow' in self.thread(), 'the file read again', 10)
        self.command('agent-prompt hello')
        self.command('wait-agent ready 30000')
        self.assertEqual(self.thread()[-1], REPLY + 'ok: hello')
        starts = self.starts()
        self.assertEqual(len(starts), 2, starts)
        self.assertIn('--resume=s1', starts[1]['argv'])

    def test_a_send_while_the_host_is_gone(self):
        self.start()
        self.open_listed()
        self.command('remote-drop')
        self.command('agent-prompt hello')
        self.command('wait-agent failed 10000')
        self.assertIn('report=Not connected to %s. Reconnect, then send again.' % HOST, self.live())
        self.assertEqual(self.starts(), [])
        self.command('remote-reconnect')
        self.command('wait-remote 90')
        self.command('agent-prompt hello')
        self.command('wait-agent ready 30000')
        self.assertEqual(self.thread()[-1], REPLY + 'ok: hello')


@unittest.skipUnless(sys.platform.startswith('linux'), 'the local: remote transport is Linux only')
class LocalHost(chat.DrivenCase):
    """A remote window on this machine: no local file function is given a project path (strict)."""

    def test_round_trip_and_a_new_conversation(self):
        self.seed()
        self.start(remote=True, env={'RHUN_REMOTE_STRICT': '1'})
        self.command('wait-remote 60')
        self.open_listed()
        self.command('agent-prompt hello')
        self.command('wait-agent ready 20000')
        self.assertEqual(self.thread()[-2:], ['user hello', REPLY + 'ok: hello'])
        self.assertEqual(self.starts()[0]['cwd'], str(self.project))
        self.command('agent-new claude')
        self.command('agent-prompt fresh')
        self.command('wait-agent ready 20000')
        sid = self.sid()
        self.assertTrue((self.work / '.claude/projects' / chat.slug(self.project) / (sid + '.jsonl')).exists())
        self.quit()
        self.assertNotIn(b'RHUN_REMOTE_STRICT', self.process.stderr.read())


if __name__ == '__main__':
    unittest.main()
