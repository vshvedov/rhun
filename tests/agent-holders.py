#!/usr/bin/env python3
# holder_claude / holder_grok against a fake home: alive, dead, own, foreign-platform and broken records
import json, os, platform, subprocess, sys, tempfile, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
DOMAIN = 'darwin' if platform.system() == 'Darwin' else 'linux'

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
        (self.home / '.grok/active_sessions.json').write_text('[{')
        self.assertEqual(self.ask('grok', 'g1'), 'holder=2')
    def test_grok_home(self):
        other = self.home / 'gh'; other.mkdir()
        (other / 'active_sessions.json').write_text(json.dumps([{'session_id': 'g1', 'pid': os.getpid()}]))
        self.env['GROK_HOME'] = str(other)
        self.assertEqual(self.ask('grok', 'g1'), 'holder=1')

if __name__ == '__main__': unittest.main()
