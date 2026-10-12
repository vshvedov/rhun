#!/usr/bin/env python3
# holder_claude / holder_grok against a fake home: alive, dead, own, foreign-platform and broken records;
# holder_opencode against processes named opencode in and out of a project
import json, os, platform, shutil, subprocess, sys, tempfile, time, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
IS_MAC = platform.system() == 'Darwin'
DOMAIN = 'darwin' if IS_MAC else 'linux'

def dead_pid():
    p = subprocess.Popen(['true']); p.wait(); return p.pid

class Holders(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rhun-holders-')
        self.home = Path(self.tmp.name)
        self.sessions = self.home / '.claude/sessions'
        self.env = dict(os.environ, HOME=str(self.home))
        self.env.pop('CLAUDE_CONFIG_DIR', None); self.env.pop('GROK_HOME', None)
    def tearDown(self): self.tmp.cleanup()
    def ask(self, kind, sid, own=None):
        args = [str(ROOT / 'build/agent_holder_test'), kind, sid] + ([str(own)] if own else [])
        r = subprocess.run(args, env=self.env, capture_output=True, text=True, timeout=20)
        return r.stderr.strip()
    def claude_record(self, name, **fields):
        self.sessions.mkdir(parents=True, exist_ok=True)
        (self.sessions / name).write_text(json.dumps(fields))
    def grok_records(self, records):
        (self.home / '.grok').mkdir(exist_ok=True)
        (self.home / '.grok/active_sessions.json').write_text(json.dumps(records))

    def test_claude_missing_dir(self): self.assertEqual(self.ask('claude', 's1'), 'holder=0')
    def test_claude_alive_other(self):
        self.claude_record('1.json', sessionId='s1', pid=os.getpid(), pidDomain=DOMAIN, procStart='x')
        self.assertEqual(self.ask('claude', 's1'), 'holder=1')
        self.assertEqual(self.ask('claude', 'other'), 'holder=0')
    def test_claude_own_child(self):
        self.claude_record('1.json', sessionId='s1', pid=os.getpid(), pidDomain=DOMAIN)
        self.assertEqual(self.ask('claude', 's1', own=os.getpid()), 'holder=0')
    def test_claude_dead(self):
        self.claude_record('1.json', sessionId='s1', pid=dead_pid(), pidDomain=DOMAIN)
        self.assertEqual(self.ask('claude', 's1'), 'holder=0')
    def test_claude_other_platform(self):
        self.claude_record('1.json', sessionId='s1', pid=os.getpid(), pidDomain='win32')
        self.assertEqual(self.ask('claude', 's1'), 'holder=0')
    def test_claude_no_pid_is_unknown(self):
        self.claude_record('1.json', sessionId='s1', pidDomain=DOMAIN)
        self.assertEqual(self.ask('claude', 's1'), 'holder=2')
    def test_claude_no_session_id_is_unknown(self):
        self.claude_record('1.json', pid=dead_pid(), pidDomain=DOMAIN)
        self.assertEqual(self.ask('claude', 's1'), 'holder=2')
    def test_claude_number_session_id_is_unknown(self):
        self.claude_record('1.json', sessionId=42, pid=dead_pid(), pidDomain=DOMAIN)
        self.assertEqual(self.ask('claude', 's1'), 'holder=2')
    def test_claude_no_domain_still_holds(self):
        self.claude_record('1.json', sessionId='s1', pid=os.getpid())
        self.assertEqual(self.ask('claude', 's1'), 'holder=1')
    def test_claude_broken_file_is_unknown(self):
        self.claude_record('1.json', sessionId='s1', pid=dead_pid(), pidDomain=DOMAIN)
        (self.sessions / '2.json').write_text('{"sessionId": "s1", "pid":')
        self.assertEqual(self.ask('claude', 's1'), 'holder=2')
    def test_claude_config_dir(self):
        other = self.home / 'elsewhere'; (other / 'sessions').mkdir(parents=True)
        (other / 'sessions/1.json').write_text(json.dumps(dict(sessionId='s1', pid=os.getpid(), pidDomain=DOMAIN)))
        self.env['CLAUDE_CONFIG_DIR'] = str(other)
        self.assertEqual(self.ask('claude', 's1'), 'holder=1')
    def test_grok(self):
        self.assertEqual(self.ask('grok', 'g1'), 'holder=0')
        self.grok_records([{'session_id': 'g1', 'pid': os.getpid(), 'cwd': '/p'}, {'session_id': 'g2', 'pid': dead_pid()}])
        self.assertEqual(self.ask('grok', 'g1'), 'holder=1')
        self.assertEqual(self.ask('grok', 'g1', own=os.getpid()), 'holder=0')
        self.assertEqual(self.ask('grok', 'g2'), 'holder=0')
        self.assertEqual(self.ask('grok', 'g3'), 'holder=0')
        self.grok_records([{'session_id': 'g1'}])
        self.assertEqual(self.ask('grok', 'g1'), 'holder=2')
        self.grok_records([{'pid': dead_pid(), 'cwd': '/p'}])
        self.assertEqual(self.ask('grok', 'g1'), 'holder=2')
        (self.home / '.grok/active_sessions.json').write_text('[{')
        self.assertEqual(self.ask('grok', 'g1'), 'holder=2')
    def test_grok_home(self):
        other = self.home / 'gh'; other.mkdir()
        (other / 'active_sessions.json').write_text(json.dumps([{'session_id': 'g1', 'pid': os.getpid()}]))
        self.env['GROK_HOME'] = str(other)
        self.assertEqual(self.ask('grok', 'g1'), 'holder=1')

class OpenCodeHolders(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # a program named opencode: its name is what the listing sees. macOS kills a copied system binary
        # and names a script after its interpreter, so there it is built; elsewhere a copy of sh will do
        cls.bin = tempfile.TemporaryDirectory(prefix='rhun-oc-bin-')
        cls.exe = Path(cls.bin.name) / 'bin/opencode'; cls.exe.parent.mkdir()
        if IS_MAC:
            src = Path(cls.bin.name) / 'opencode.c'
            src.write_text('#include <unistd.h>\nint main(void) { for (;;) pause(); }\n')
            subprocess.run(['cc', '-o', str(cls.exe), str(src)], check=True)
        else:
            shutil.copy(shutil.which('sh'), cls.exe); cls.exe.chmod(0o755)
    @classmethod
    def tearDownClass(cls): cls.bin.cleanup()
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rhun-oc-')
        self.w = Path(self.tmp.name); self.project = self.w / 'project'; self.project.mkdir()
        (self.w / 'elsewhere').mkdir()
        self.procs = []
    def tearDown(self):
        for p in self.procs: p.kill(); p.wait(); p.stdin.close()
        self.tmp.cleanup()
    def start(self, cwd, *extra):
        # sh waits on a read of its stdin: no child to leave behind, nothing to exec in its place (the
        # macOS program ignores its arguments and waits)
        p = subprocess.Popen([str(self.exe), '-c', 'read x', *extra], cwd=cwd, stdin=subprocess.PIPE)
        self.procs.append(p)
        time.sleep(0.3); return p
    def ask(self, own=None):
        args = [str(ROOT / 'build/agent_holder_test'), 'opencode', str(self.project.resolve())] + ([str(own)] if own else [])
        return subprocess.run(args, capture_output=True, text=True, timeout=30).stderr.strip()
    def test_none(self): self.assertEqual(self.ask(), 'holder=0')
    def test_in_project(self):
        p = self.start(self.project)
        self.assertEqual(self.ask(), 'holder=1')
        self.assertEqual(self.ask(own=p.pid), 'holder=0')
    def test_subdirectory_counts(self):
        sub = self.project / 'src'; sub.mkdir(); self.start(sub)
        self.assertEqual(self.ask(), 'holder=1')
    def test_elsewhere(self):
        self.start(self.w / 'elsewhere')
        # Linux knows the arguments and exempts it; macOS has no arguments, so it holds (spec 5.4)
        self.assertEqual(self.ask(), 'holder=1' if IS_MAC else 'holder=0')
    def test_serve_anywhere(self):
        self.start(self.w / 'elsewhere', 'serve')
        self.assertEqual(self.ask(), 'holder=1')
    def test_sibling_prefix_is_outside(self):
        other = self.w / 'projectile'; other.mkdir(); self.start(other)
        self.assertEqual(self.ask(), 'holder=1' if IS_MAC else 'holder=0')

if __name__ == '__main__': unittest.main()
