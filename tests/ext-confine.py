#!/usr/bin/env python3
"""Confinement of extension processes (docs/extensions/v1.md section 5): the echo extension probes
what it may do under each [needs] shape, and the editor's print-extensions says how it is held.
Where the kernel cannot confine (no Landlock, as in Docker Desktop's VM or under Rosetta), a
--extensions session runs the program unconfined and says so: those cases are skipped, not
passed. Run on a native x86-64 Linux or on macOS for the real thing."""
import os
import re
import shutil
import subprocess
from pathlib import Path
import sys
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
host = __import__('ext-host')


class Confine(host.Host):
    def setUp(self):
        super().setUp()
        self.secret = self.work / 'secret.txt'          # in HOME, outside the project
        self.secret.write_text('secret\n', encoding='utf-8')
        self.env['ECHO_SECRET'] = self.secret.as_posix()

    def probe(self, command, needs, extra=('print-extensions',)):
        self.probes = getattr(self, 'probes', 0) + 1
        exts = self.manifest_variant('confine-%d' % self.probes, **{'documents = write\nterminal = yes\nproject = read': needs})
        out = self.run_editor(drop_waits=True, actions=[f'cmd {command}', 'wait-ext echo running', 'wait 300',
                                                        'wait 300', 'print-toast', *extra], exts=exts)
        return out

    def confined(self, line):
        for field in line.split():
            if field.startswith('confined='):
                return int(field[9:])
        self.fail(line)

    def skip_unless_confined(self, line):
        if self.confined(line) == 0:
            self.skipTest('the kernel cannot confine here: ' + line.split(' why=', 1)[-1])

    def test_project_read_cannot_write_the_project(self):
        out = self.probe('echo.pwrite', 'documents = read\nproject = read')
        self.skip_unless_confined(out[1])
        self.assertEqual(out[0], 'toast=probe refused')
        self.assertFalse((self.proj / 'written-by-echo.txt').exists())

    def test_project_write_can(self):
        out = self.probe('echo.pwrite', 'documents = read\nproject = write')
        self.skip_unless_confined(out[1])
        self.assertEqual(out[0], 'toast=probe ok')
        self.assertTrue((self.proj / 'written-by-echo.txt').exists())

    def test_home_is_closed_without_home_read(self):
        out = self.probe('echo.hread', 'documents = read')
        self.skip_unless_confined(out[1])
        self.assertEqual(out[0], 'toast=probe refused')
        out = self.probe('echo.hread', 'documents = read\nhome = read')
        self.assertEqual(out[0], 'toast=probe ok')

    def test_an_exit_code_of_its_own_does_not_lift_the_confinement(self):
        self.skip_unless_confined(self.probe('echo.swrite', 'documents = read')[1])
        exts = self.manifest_variant('exit70', **{'documents = write\nterminal = yes\nproject = read': 'documents = read\nproject = read'})
        out = self.run_editor(drop_waits=True, mode='exit70once',
                              actions=['cmd echo.pwrite', 'wait 300', 'wait 300', 'wait 300', 'cmd echo.pwrite',
                                       'wait 300', 'wait 300', 'print-toast', 'print-extensions'], exts=exts)
        self.assertFalse((self.proj / 'written-by-echo.txt').exists(), out)
        self.assertNotIn('why=', out[-1])

    def test_the_state_folder_is_always_writable(self):
        out = self.probe('echo.swrite', 'documents = read')
        self.assertEqual(out[0], 'toast=probe ok')

    def test_network_no_cuts_tcp_off(self):
        out = self.probe('echo.net', 'documents = read')
        self.skip_unless_confined(out[1])
        self.assertEqual(out[0], 'toast=probe refused')

    def test_network_yes_connects_or_times_out(self):
        out = self.probe('echo.net', 'documents = read\nnetwork = yes')
        self.skip_unless_confined(out[1])
        self.assertNotEqual(out[0], 'toast=probe refused')

    def test_exec_only_of_listed_programs(self):
        out = self.probe('echo.exec', 'documents = read')
        self.skip_unless_confined(out[1])
        self.assertEqual(out[0], 'toast=probe refused', out)
        out = self.probe('echo.exec', 'documents = read\nrun = ls')
        self.assertEqual(out[0], 'toast=probe ok', out)

    def xcode_shims(self, names):
        """the names whose PATH program is one of Xcode's /usr/bin shims (macOS), with their real tools"""
        if sys.platform != 'darwin' or not os.path.exists('/usr/bin/xcrun'):
            return {}
        shims = {}
        for name in names:
            if shutil.which(name, path=self.env.get('PATH')) != '/usr/bin/' + name:
                continue
            found = subprocess.run(['/usr/bin/xcrun', '--find', name], capture_output=True, text=True, timeout=60)
            real = found.stdout.strip()
            if found.returncode == 0 and real and os.path.realpath(real) != os.path.realpath('/usr/bin/' + name):
                shims[name] = real
        return shims

    def test_an_xcode_shim_finds_its_tool_without_xcodebuild(self):
        # macOS: /usr/bin/git is Xcode's shim. Inside the sandbox its first lookup would run
        # xcodebuild for seconds (an extension's 10 s timeout killed it under load, every time);
        # rhun fills the extension's xcrun cache outside the sandbox, so git answers from it
        real = self.xcode_shims(['git']).get('git')
        if not real:
            self.skipTest('/usr/bin/git is not an Xcode shim here')
        git = dict(self.env, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@t', GIT_COMMITTER_NAME='t',
                   GIT_COMMITTER_EMAIL='t@t', GIT_CONFIG_NOSYSTEM='1')
        for args in (['init', '-q'], ['add', '.'], ['commit', '-qm', 'one']):
            subprocess.run([real, *args], cwd=self.proj, env=git, check=True, capture_output=True, timeout=60)
        exts = self.manifest_variant('xcshim', **{'documents = write\nterminal = yes\nproject = read':
                                                 'documents = read\nproject = read\nrun = git'})
        polls = [a for _ in range(50) for a in ('wait 500', 'print-toast')]
        out = self.run_editor(drop_waits=True, actions=['cmd echo.git', 'wait-ext echo running', *polls,
                                                        'print-extensions'], exts=exts)
        self.skip_unless_confined(out[-1])
        toasts = [l for l in out if l.startswith('toast=') and l != 'toast=']
        self.assertIn('toast=probe ok', toasts, out)
        self.assertTrue((self.work / 'state/rhun/extensions/rhun-tests--echo/xcrun_db').is_file())

    @unittest.skipUnless(sys.platform == 'darwin' or sys.platform.startswith('linux'), 'native executable fixture')
    def test_build_programs_require_explicit_run_permission(self):
        program = self.work / 'state/rhun/extensions/rhun-tests--echo/compiled-program'
        program.parent.mkdir(parents=True, exist_ok=True)
        if not shutil.which('cc'):
            self.skipTest('no C compiler for generated-program probe')
        source = b'#include <signal.h>\n#include <unistd.h>\nint main(void) { return kill(getppid(), 0) == 0 ? 0 : 1; }\n'
        compiler = ['cc', '-x', 'c']
        if sys.platform == 'darwin':
            compiler = ['cc', '-x', 'objective-c', '-framework', 'Foundation']
            source = b'''#import <Foundation/Foundation.h>
#include <signal.h>
#include <unistd.h>
int main(void) { @autoreleasepool {
    if (kill(getppid(), 0) != 0) return 1;
    NSString *home = [NSString stringWithUTF8String:getenv("HOME")];
    NSString *path = [home stringByAppendingPathComponent:@"atomic-build-file"];
    return [@"build metadata" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil] ? 0 : 1;
} }
'''
        subprocess.run([*compiler, '-o', str(program), '-'], input=source, capture_output=True, check=True)
        self.env['ECHO_MODE'] = 'build'
        out = self.probe('echo.exec', 'documents = read')
        self.skip_unless_confined(out[1])
        self.assertEqual(out[0], 'toast=probe refused', out)
        out = self.probe('echo.exec', 'documents = read\nrun = @build')
        self.assertEqual(out[0], 'toast=probe ok', out)
        self.env.pop('ECHO_MODE')
        out = self.probe('echo.exec', 'documents = read\nrun = @build')
        self.assertEqual(out[0], 'toast=probe refused', out)
        out = self.probe('echo.hread', 'documents = read\nproject = read\nrun = @build')
        self.assertEqual(out[0], 'toast=probe refused', out)

    def test_xcode_shims_do_not_hold_up_the_start(self):
        # filling the cache for several shims takes seconds: the extension says hello meanwhile
        shims = self.xcode_shims(['git', 'clang', 'clangd', 'swift', 'sourcekit-lsp', 'lldb'])
        if len(shims) < 2:
            self.skipTest('fewer than two Xcode shims here')
        exts = self.manifest_variant('xcshims', **{'documents = write\nterminal = yes\nproject = read':
                                                  'documents = read\nrun = ' + ' '.join(shims)})
        out = self.run_editor(drop_waits=True, actions=['cmd echo.toast', 'wait 1500', 'print-extensions'], exts=exts)
        self.skip_unless_confined(out[-1])
        self.assertIn('state=running', out[-1])

    def wait_for_primers(self, cache, seconds=60):
        """the cache once every primer is done: a primer outlives the rhun that started it"""
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            staging = list(cache.parent.parent.glob(cache.parent.name + '.xcrun_db*'))
            if cache.is_file() and not staging:
                return cache.read_bytes()
            time.sleep(0.2)
        self.fail('no xcrun cache, or a primer still running: %s' % sorted(os.listdir(cache.parent.parent)))

    def test_xcode_shim_caches_are_filled_at_rhuns_start(self):
        # an extension that is on but not started yet: its cache is filled anyway, ahead of its
        # first use of a shim
        shims = self.xcode_shims(['git', 'clang', 'clangd', 'swift', 'sourcekit-lsp', 'lldb'])
        if not shims:
            self.skipTest('no Xcode shims here')
        exts = self.manifest_variant('xcstart', **{'documents = write\nterminal = yes\nproject = read':
                                                  'documents = read\nrun = ' + ' '.join(shims)})
        out = self.run_editor(drop_waits=True, actions=['wait 500', 'print-extensions'], exts=exts)
        self.assertNotIn('state=running', out[-1])
        self.assertNotIn('state=starting', out[-1])
        cache = self.wait_for_primers(self.work / 'state/rhun/extensions/rhun-tests--echo/xcrun_db')
        for name in shims:
            self.assertRegex(cache, rb'(^|[^a-z-])' + re.escape(name.encode()) + rb'\|/', name)

    def test_two_windows_primers_stage_apart_and_leave_a_whole_cache(self):
        # two rhun processes start together and each fills the same cache. A shared staging file
        # let one primer move it away while the other was between tools, and the other then put a
        # cache that lacked the earlier tools in its place: each stages STATE.xcrun_db.PID now
        shims = self.xcode_shims(['git', 'clang', 'clangd', 'swift', 'sourcekit-lsp', 'lldb'])
        if len(shims) < 2:
            self.skipTest('fewer than two Xcode shims here')
        exts = self.manifest_variant('xctwo', **{'documents = write\nterminal = yes\nproject = read':
                                                'documents = read\nrun = ' + ' '.join(shims)})
        script = self.work / 'two.rsc'
        script.write_text('wait 2000\nquit\n', encoding='utf-8')
        root = self.work / 'state/rhun/extensions'
        runs, seen = [], set()
        for _ in range(2):
            runs.append(subprocess.Popen([str(host.EXE), self.proj.as_posix(), '--headless', '640x400', '--scale',
                                          '1', '--extensions', str(exts), '--script', script.as_posix()],
                                         env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
            time.sleep(0.3)
        end = time.monotonic() + 60
        while time.monotonic() < end and (any(r.poll() is None for r in runs) or
                                           list(root.glob('rhun-tests--echo.xcrun_db*'))):
            for staged in root.glob('rhun-tests--echo.xcrun_db*'):
                if not re.search(r'-[A-Za-z0-9]{8}$', staged.name):    # not xcrun's own temporary file
                    seen.add(staged.name)
            time.sleep(0.05)
        for run in runs:
            self.assertEqual(run.wait(timeout=60), 0)
        self.assertEqual(len(seen), 2, seen)
        for name in seen:
            self.assertRegex(name, r'^rhun-tests--echo\.xcrun_db\.[0-9]+$')
        cache = self.wait_for_primers(root / 'rhun-tests--echo/xcrun_db')
        for name in shims:
            self.assertRegex(cache, rb'(^|[^a-z-])' + re.escape(name.encode()) + rb'\|/', name)

    def test_disable_stops_and_keeps_it_stopped(self):
        out = self.run_editor(drop_waits=True, actions=['cmd echo.toast', 'wait-ext echo running', 'wait 300',
                                                        'ext-set echo disabled 1', 'wait 500', 'print-extensions',
                                                        'cmd echo.toast', 'wait 500', 'print-extensions',
                                                        'ext-set echo disabled 0', 'print-extensions'])
        self.assertIn('state=disabled', out[0])
        self.assertIn('state=disabled', out[1])
        self.assertIn('state=starting', out[2])      # on again: it starts
        ini = (self.work / 'config/rhun/extensions.ini').read_text(encoding='utf-8')
        self.assertEqual(ini, '')

    def test_a_quote_in_the_extension_path_cannot_break_the_profile(self):
        # the profile quotes paths: a quote and a backslash in the extension's folder are escaped
        exts = self.manifest_variant('con"f\\ine', **{'documents = write\nterminal = yes\nproject = read': 'documents = read'})
        out = self.run_editor(drop_waits=True, actions=['cmd echo.pwrite', 'wait-ext echo running', 'wait 300',
                                                        'wait 300', 'print-toast', 'print-extensions'], exts=exts)
        self.skip_unless_confined(out[1])
        self.assertEqual(out[0], 'toast=probe refused')


# only this file's tests run here: the inherited ones belong to ext-host.py
for _name in dir(host.Host):
    if _name.startswith('test_'):
        setattr(Confine, _name, None)

if __name__ == '__main__':
    unittest.main()
