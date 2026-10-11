#!/usr/bin/env python3
# auth_preflight against stub CLIs: results, the scrubbed environment, the deadline
import os, subprocess, sys, tempfile, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
STUB = r'''#!/usr/bin/env python3
import os, sys, time
name = os.path.basename(sys.argv[0]); mode = os.environ.get('STUB', 'ok')
# the keys each agent's scrub removes (spec 5.3); the others pass through on purpose
scrubbed = {'claude': ('ANTHROPIC_API_KEY',), 'codex': ('OPENAI_API_KEY', 'CODEX_API_KEY'),
            'opencode': ('ANTHROPIC_API_KEY', 'OPENAI_API_KEY', 'CODEX_API_KEY', 'XAI_API_KEY', 'FOO_API_TOKEN')}[name]
for key in scrubbed:
    if key in os.environ: open(os.environ['MARK'], 'a').write('leak:' + key + '\n')
open(os.environ['MARK'], 'a').write('ran:' + name + ' ' + ' '.join(sys.argv[1:]) + ' cwd=' + os.getcwd() + '\n')
if mode == 'hang': time.sleep(30)
if mode == 'garbage': print('???'); sys.exit(0)
if name == 'claude':
    out = {'ok': '{"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty"}',
           'out': '{"loggedIn": false, "authMethod": "none", "apiProvider": "firstParty"}',
           'key': '{"loggedIn": true, "authMethod": "apiKey", "apiProvider": "firstParty"}'}[mode]
elif name == 'codex':
    out = {'ok': 'Logged in using ChatGPT', 'out': 'Not logged in', 'key': 'Logged in using an API key'}[mode]
else:
    out = {'ok': '[{"id":"openai","name":"OpenAI","connections":[{"type":"credential","label":"OAuth"}]}]',
           'out': '[]', 'key': '[{"id":"openai","name":"OpenAI","connections":[{"type":"credential","label":"API key"}]}]'}[mode]
print(out, file=sys.stderr if name == 'codex' else sys.stdout)  # where each CLI writes its report
'''

class Preflight(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rhun-auth-')
        self.w = Path(self.tmp.name); self.bin = self.w / 'bin'; self.bin.mkdir()
        for name in ('claude', 'codex', 'opencode'):
            p = self.bin / name; p.write_text(STUB); p.chmod(0o755)
        (self.w / 'project').mkdir()
    def tearDown(self): self.tmp.cleanup()
    def run_pf(self, agent, mode, ms=None):
        mark = self.w / 'mark'; mark.unlink(missing_ok=True)
        env = dict(os.environ, HOME=str(self.w), PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                   STUB=mode, MARK=str(mark), ANTHROPIC_API_KEY='x', OPENAI_API_KEY='x', CODEX_API_KEY='x',
                   XAI_API_KEY='x', FOO_API_TOKEN='x')
        args = [str(ROOT / 'build/agent_auth_test'), 'preflight', agent] + ([str(ms)] if ms else [])
        r = subprocess.run(args, cwd=self.w / 'project', env=env, capture_output=True, text=True, timeout=40)
        return r.stderr, (mark.read_text() if mark.exists() else '')
    def test_results(self):
        for agent, expect in (('claude', 'claude auth status'), ('codex', 'codex login status'),
                              ('opencode', 'opencode auth list --format json')):
            for mode, code in (('ok', 0), ('out', 1), ('key', 2), ('garbage', 3)):
                if agent == 'opencode' and mode == 'key': code = 1  # an API key alone allows no provider
                out, mark = self.run_pf(agent, mode)
                self.assertIn('preflight:%s=%d' % (agent, code), out, (agent, mode, out))
                self.assertIn('ran:' + expect + ' cwd=' + str((self.w / 'project').resolve()), mark)
                self.assertNotIn('leak:', mark, (agent, mode, mark))
        out, mark = self.run_pf('opencode', 'ok')
        self.assertIn('preflight:opencode=0 openai', out)
    def test_grok_needs_no_preflight(self):
        out, mark = self.run_pf('grok', 'ok')
        self.assertIn('preflight:grok=0', out); self.assertEqual(mark, '')
    def test_deadline(self):
        out, mark = self.run_pf('claude', 'hang', 500)
        self.assertIn('preflight:claude=3', out)
    def test_missing_cli(self):
        (self.bin / 'claude').unlink()
        env_path = str(self.bin)
        r = subprocess.run([str(ROOT / 'build/agent_auth_test'), 'preflight', 'claude'],
                           cwd=self.w, env=dict(os.environ, HOME=str(self.w), PATH=env_path),
                           capture_output=True, text=True, timeout=20)
        self.assertIn('preflight:claude=3', r.stderr)

if __name__ == '__main__': unittest.main()
