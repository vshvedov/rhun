#!/usr/bin/env python3
"""Language features with real language servers through the first-party lsp extension
(github.com/rhun-editor/lsp). Skipped unless RHUN_TEST_LSP names the lsp extension's binary for
this platform (built from a checkout with the matching SDK) and the server is on PATH (gopls,
clangd, rust-analyzer; RHUN_TEST_SERVER_PATH may add a folder to PATH for them).

  RHUN_TEST_LSP=/path/to/lsp-macos-arm64 RHUN_TEST_LSP_INI=/path/to/extension.ini \\
      python3 tests/langfeat-real.py
"""
import os
from pathlib import Path
import errno
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
EXE = Path(os.environ.get('RHUN_TEST_EXE', ROOT / 'build/rhun')).resolve()
LSP = os.environ.get('RHUN_TEST_LSP', '')
INI = os.environ.get('RHUN_TEST_LSP_INI', '')
EXTRA = os.environ.get('RHUN_TEST_SERVER_PATH', '')
TARGET = {'darwin': 'macos-arm64', 'linux': 'linux-x86_64'}.get(os.uname().sysname.lower(), '')
CONFIG = ('[ui]\nsidebar = false\nagents_panel = false\n[editor]\ncursor_blink = false\n'
          '[files]\nrestore_session = false\nrestore_project = false\n[updates]\ncheck = false\n'
          '[git]\nenabled = false\n')


def have(tool):
    path = os.pathsep.join(p for p in (EXTRA, os.environ.get('PATH', '')) if p)
    return shutil.which(tool, path=path) is not None


@unittest.skipUnless(LSP and INI and Path(LSP).exists(), 'RHUN_TEST_LSP and RHUN_TEST_LSP_INI are not set')
class Real(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rhun-real-')
        self.work = Path(self.tmp.name).resolve()
        self.proj = self.work / 'proj'
        self.proj.mkdir()
        (self.work / 'config/rhun').mkdir(parents=True)
        (self.work / 'config/rhun/config').write_text(CONFIG)
        ext = self.work / 'exts/rhun-editor/lsp'
        (ext / 'bin').mkdir(parents=True)
        shutil.copy(INI, ext / 'extension.ini')
        shutil.copy(LSP, ext / 'bin' / f'lsp-{TARGET}')
        # the go toolchain's caches stay in the run's home
        self.env = dict(os.environ, HOME=str(self.work), XDG_CONFIG_HOME=str(self.work / 'config'),
                        XDG_STATE_HOME=str(self.work / 'state'), XDG_DATA_HOME=str(self.work / 'data'),
                        GOFLAGS='-mod=mod', GOTOOLCHAIN='local', GOWORK='off')
        if EXTRA:
            self.env['PATH'] = EXTRA + os.pathsep + self.env['PATH']

    def tearDown(self):
        # Xcode cache primers can finish just after the editor exits.
        for attempt in range(30):
            try:
                self.tmp.cleanup()
                return
            except OSError as error:
                if error.errno != errno.ENOTEMPTY or attempt == 29:
                    raise
                time.sleep(0.1)

    def run_editor(self, files, actions, timeout=180):
        script = self.work / 'script.rsc'
        opens = ['open ' + str(self.proj / f) for f in files]
        script.write_text('\n'.join(['wait 100', *opens, *actions, 'quit']) + '\n')
        r = subprocess.run([str(EXE), str(self.proj), '--headless', '1000x600', '--scale', '1',
                            '--extensions', str(self.work / 'exts'), '--script', str(script)],
                           env=self.env, capture_output=True, timeout=timeout)
        self.assertEqual(r.returncode, 0, r.stderr.decode(errors='replace')[-2000:])
        return r.stdout.decode(errors='replace').splitlines()

    def log(self):
        p = self.work / 'state/rhun/extensions/rhun-editor--lsp.log'
        return p.read_text(errors='replace') if p.exists() else ''

    def doc(self, out, marker='==='):
        i = len(out) - 1 - out[::-1].index(marker)
        return '\n'.join(out[i + 1:out.index('<eod>', i)]).rstrip('\n')

    def warm(self, wait=12000):
        """Until the server answers: completion asked a few times while it indexes."""
        return ['wait-ext rhun-editor/lsp running', f'wait {wait}']

    def test_missing_server_offers_install_instructions_once(self):
        # Hide installed servers without changing the machine's actual installations.
        empty = self.work / 'empty-path'
        empty.mkdir()
        self.env['PATH'] = str(empty)
        (self.proj / 'main.go').write_text('package main\n')
        (self.proj / 'other.go').write_text('package main\n')
        out = self.run_editor(['main.go', 'other.go'], [
            *self.warm(1200), 'print-notes', 'note-press 0 1', 'wait 300',
            'print-docview 1', 'print-tabs', 'print-side-tabs', 'print-extensions'])
        text = '\n'.join(out)
        notes = [line for line in out if line.startswith('note=')]
        self.assertEqual(len(notes), 1, text + self.log())
        self.assertIn('Install instructions', notes[0])
        self.assertIn('Go language server is missing', notes[0])
        self.assertIn('go install golang.org/x/tools/gopls@latest', text, text + self.log())
        rendered = ' '.join(line.split(' text=', 1)[1] for line in out
                            if line.startswith('item text ') and ' text=' in line)
        self.assertIn('Executable missing:', rendered)
        self.assertIn('https://go.dev/gopls/', text)
        self.assertIn('Language Server Setup', next(line for line in out if line.startswith('tabs=')))
        self.assertNotIn('place=side name=setup', text)

    def test_setup_uses_the_configured_alternative(self):
        state = self.work / 'state/rhun/extensions/rhun-editor--lsp'
        state.mkdir(parents=True)
        (state / 'lsp.ini').write_text('[servers]\nPython = ruff server\n')
        (self.proj / 'main.py').write_text('answer = 42\n')
        out = self.run_editor(['main.py'], [
            *self.warm(1200), 'cmd rhun-editor/lsp.setup', 'wait 300', 'print-docview 1'])
        text = '\n'.join(out)
        self.assertIn('uv tool install ruff', text, text + self.log())
        self.assertNotIn('npm install -g pyright', text)

    def test_setup_command_copies_the_install_command(self):
        (self.proj / 'main.go').write_text('package main\n')
        (self.proj / 'paste.txt').write_text('')
        out = self.run_editor(['main.go'], [
            *self.warm(1200), 'cmd rhun-editor/lsp.setup', 'wait 300',
            'key Tab', 'key Return', f'open {self.proj / "paste.txt"}',
            'key ctrl+v', 'echo ===', 'print-doc'])
        self.assertEqual(self.doc(out), 'go install golang.org/x/tools/gopls@latest', '\n'.join(out) + self.log())

    def test_reopening_setup_keeps_one_editor_tab(self):
        (self.proj / 'main.go').write_text('package main\n')
        out = self.run_editor(['main.go'], [
            *self.warm(1200), 'cmd rhun-editor/lsp.setup', 'wait 200',
            'cmd rhun-editor/lsp.setup', 'wait 200', 'print-tabs', 'print-views'])
        text = '\n'.join(out)
        tabs = next(line for line in out if line.startswith('tabs='))
        self.assertEqual(tabs.count('Language Server Setup'), 1, text + self.log())
        self.assertEqual(len([line for line in out if line.startswith('view=') and 'kind=doc place=tab' in line]), 1, text)

    @unittest.skipUnless(have('gopls'), 'gopls is not on PATH')
    def test_gopls_completion_adds_the_import_and_a_native_field(self):
        (self.proj / 'go.mod').write_text('module example.com/demo\n\ngo 1.22\n')
        (self.proj / 'main.go').write_text('package main\n\nfunc main() {\n\ts := "a"\n\t_ = s\n\t\n}\n')
        out = self.run_editor(['main.go'], [
            *self.warm(), 'key ctrl+Home', 'key Down', 'key Down', 'key Down', 'key Down', 'key Down',
            'key End', 'type strings.Cl', 'wait 2500', 'print-complete', 'key Return', 'wait 1500',
            'echo ===', 'print-doc', 'print-state', 'key ctrl+z', 'echo ===', 'print-doc'])
        text = '\n'.join(out)
        self.assertIn('labels=Clone', text, text + self.log())
        accepted = text.split('===')[1]
        self.assertIn('import "strings"', accepted, text)
        self.assertIn('strings.Clone()', accepted, text)
        self.assertIn('line=8 col=19', accepted, text)  # in the native field between the parentheses (tab = 4)
        self.assertNotIn('import "strings"', text.split('===')[2], text)


    @unittest.skipUnless(have('gopls'), 'gopls is not on PATH')
    def test_gopls_references_hover_and_rename_with_prepare(self):
        (self.proj / 'go.mod').write_text('module example.com/demo\n\ngo 1.22\n')
        (self.proj / 'main.go').write_text('package main\n\nfunc total() int { return 1 }\n\n'
                                           'func main() { _ = total() }\n')
        (self.proj / 'other.go').write_text('package main\n\nfunc use() int { return total() }\n')
        out = self.run_editor(['main.go'], [
            *self.warm(), 'key ctrl+Home', 'key Down', 'key Down', 'key Home', 'key ctrl+Right', 'key Right',
            'key shift+F12', 'wait 3000', 'print-results', 'key Escape', 'hover-at 3 7', 'wait 3000',
            'print-hover-card', 'key F2', 'wait 2000', 'print-palette', 'key ctrl+a', 'type sum', 'key Return',
            'wait 3000', 'print-palette', 'wait 2000', 'print-tabs', 'echo ===', 'print-doc'])
        text = '\n'.join(out)
        refs = [l for l in out if l.startswith('row ') and ' leaf ' in l]
        self.assertGreaterEqual(len(refs), 2, text + self.log())
        self.assertTrue(any('label=other.go' in l for l in out if l.startswith('row ')), text)
        self.assertIn('section ext rhun-editor/lsp: ', text)
        self.assertIn('func total() int', text)
        self.assertIn('field=total', text)                   # prepare-rename's placeholder
        self.assertIn('func sum() int', self.doc(out), text)
        # the closed file: written on disk (or opened in a tab when the extension may not write)
        on_disk = 'sum()' in (self.proj / 'other.go').read_text()
        self.assertTrue(on_disk or any('other.go' in l for l in out if l.startswith('tabs=')), text)

    @unittest.skipUnless(have('pyright-langserver') and have('node'), 'pyright or node is not on PATH')
    def test_pyright_survives_the_parent_process_poll_and_reports_types(self):
        (self.proj / 'main.py').write_text('answer: int = "wrong"\n')
        out = self.run_editor(['main.py'], [
            *self.warm(7000), 'print-marks', 'print-extensions',
            'hover-at 1 3', 'wait 2000', 'print-hover-card'])
        text = '\n'.join(out)
        self.assertIn('not assignable', text, text + self.log())
        self.assertNotIn('pyright-langserver exited', text, text + self.log())
        self.assertIn('confined=1', text, text)

    @unittest.skipUnless(have('terraform-ls'), 'terraform-ls is not on PATH')
    def test_terraform_activates_for_the_hcl_grammar(self):
        (self.proj / 'main.tf').write_text('variable "example" {\n  type = string\n}\n')
        out = self.run_editor(['main.tf'], [
            *self.warm(7000), 'print-extensions', 'print-state',
            'key ctrl+r', 'wait 2000', 'print-palette'])
        text = '\n'.join(out)
        self.assertIn('lang=HCL', text, text)
        self.assertIn('status=terraform-ls', text, text + self.log())
        self.assertIn('example', text, text + self.log())

    @unittest.skipUnless(have('clangd'), 'clangd is not on PATH')
    def test_clangd_auto_fix_inserts_the_missing_semicolon(self):
        (self.proj / 'a.c').write_text('int main(void) {\n    int x = 1\n    return x;\n}\n')
        out = self.run_editor(['a.c'], [
            'wait-ext rhun-editor/lsp running', 'wait 4000', 'print-marks', 'key ctrl+Home', 'key Down', 'key Down',
            'key End', 'wait 1500', 'print-lightbulb', 'key shift+alt+.', 'wait 2000', 'echo ===', 'print-doc'])
        text = '\n'.join(out)
        # clangd's diagnostic is on the line after the declaration and its fix is on the line before:
        # it comes only when the diagnostic goes back in the request (DIAGS ids)
        self.assertTrue(any(l.startswith('lightbulb line=3 count=') for l in out), text + self.log())
        self.assertIn('int x = 1;', self.doc(out), text + self.log())

    @unittest.skipUnless(have('clangd'), 'clangd is not on PATH')
    def test_clangd_formats_the_selection(self):
        (self.proj / 'b.c').write_text('int f(void) {\n    int   y   =   2 ;\n    return y;\n}\n')
        out = self.run_editor(['b.c'], [
            'wait-ext rhun-editor/lsp running', 'wait 3000', 'key ctrl+Home', 'key Down', 'key Home',
            'key shift+End', 'cmd format_selection', 'wait 2000', 'echo ===', 'print-doc'])
        self.assertIn('int y = 2;', self.doc(out), '\n'.join(out) + self.log())


if __name__ == '__main__':
    unittest.main()
