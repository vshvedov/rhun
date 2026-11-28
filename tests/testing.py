#!/usr/bin/env python3
"""The test explorer (feature "tests", docs/extensions/v1.1.md) driven headlessly with the fake
controller tests/ext/testsfake.py: items and lazy resolution, runs and results, caps, cancel,
test-exec processes and back-pressure, coverage. Each run gets its own HOME and config; TESTS_MODE
and TESTS_LOG reach the fake through the environment."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
EXE = Path(os.environ.get('RHUN_TEST_EXE', ROOT / 'build/rhun')).resolve()
EXTS = ROOT / 'tests/ext/testing'
CONFIG = ('[ui]\nsidebar = false\nagents_panel = false\n[editor]\ncursor_blink = false\n'
          '[files]\nrestore_session = false\nrestore_project = false\n'
          '[updates]\ncheck = false\n[git]\nenabled = false\n')
SOURCE = ('package pkg\n\nfunc TestA(t *testing.T) {\n\tt.Run("sub", nil)\n}\n\n'
          'func TestB(t *testing.T) {\n\tcheck()\n}\n\nfunc TestC(t *testing.T) {\n\tt.Skip()\n}\n')
PKG = 'go:example/pkg'
EXPAND = ['cmd testing', 'wait-test-items 2', 'test-expand testsfake ' + PKG, 'wait-test-items 6', 'wait 150',
          'test-expand testsfake go:example/pkg#a_test.go']


class Testing(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rhun-tests-')
        self.work = Path(self.tmp.name).resolve()
        self.proj = self.work / 'proj'
        self.proj.mkdir()
        (self.proj / 'a_test.go').write_text(SOURCE, encoding='utf-8')
        config = self.work / 'config/rhun/config'
        config.parent.mkdir(parents=True)
        config.write_text(CONFIG, encoding='utf-8')
        self.log = self.work / 'state/rhun/extensions/rhun-tests--testsfake/log.txt'
        self.env = dict(os.environ, HOME=self.work.as_posix(),
                        XDG_CONFIG_HOME=(self.work / 'config').as_posix(),
                        XDG_STATE_HOME=(self.work / 'state').as_posix(),
                        TESTS_LOG=self.log.as_posix())
        self.env.pop('TESTS_MODE', None)

    def tearDown(self):
        self.tmp.cleanup()

    def run_editor(self, actions, mode=None, files=('a_test.go',), timeout=90, exts=EXTS, size='1000x600'):
        env = dict(self.env)
        if mode:
            env['TESTS_MODE'] = mode
        opens = ['open ' + (self.proj / name).as_posix() for name in files]
        script = self.work / 'actions.rsc'
        script.write_text('\n'.join(['wait 100', *opens, *actions, 'quit']) + '\n', encoding='utf-8')
        result = subprocess.run([str(EXE), self.proj.as_posix(), '--headless', size, '--scale', '1',
                                 '--extensions', str(exts), '--script', script.as_posix()],
                                env=env, capture_output=True, timeout=timeout)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
        return result.stdout.decode('utf-8', errors='replace').splitlines()

    def fake_log(self):
        return self.log.read_text(encoding='utf-8', errors='replace').splitlines() if self.log.exists() else []

    def logged(self, prefix):
        return [line for line in self.fake_log() if line.startswith(prefix)]

    def line(self, out, ident):
        hits = [l.strip() for l in out if (' id=' + ident + ' ') in l]
        self.assertTrue(hits, (ident, out))
        return hits[-1]

    # --- items ---

    def test_roots_come_with_tests_and_lazy_items_resolve_when_expanded(self):
        out = self.run_editor(['cmd testing', 'wait-test-items 2', 'print-tests',
                               'test-expand testsfake ' + PKG, 'wait-test-items 6', 'wait 150', 'print-tests all',
                               'test-expand testsfake go:example/other', 'wait 300', 'print-tests'])
        self.assertIn('notrun Fake Tests id=rhun-tests/testsfake kind=controller ms=-', out)
        self.assertIn('  notrun pkg id=go:example/pkg kind=group ms=- lazy', out)
        self.assertIn('      notrun TestA id=go:example/pkg.TestA kind=test ms=- range=3:1-5:2 desc=fast', out)
        self.assertIn('      notrun TestC id=go:example/pkg.TestC kind=test ms=- range=11:1-13:2 nodebug', out)
        # a refused tests-resolve shows its reason on the row; the item stays lazy
        self.assertIn('  notrun other id=go:example/other kind=group ms=- lazy error=refused cannot list other', out)
        self.assertEqual(self.logged('recv 1 tests-resolve 0'), ['recv 1 tests-resolve 0'])
        self.assertIn("recv 2 tests-resolve 14 b'go:example/pkg'", self.fake_log())
        self.assertIn('file-items ok 1', self.fake_log())
        # collapsed items still count
        self.assertEqual(out[-1], 'passed=0 failed=0 errored=0 skipped=0 notrun=3')

    def test_an_unanswered_resolve_gives_up_after_30_s(self):
        out = self.run_editor(['cmd testing', 'wait 31500', 'print-tests'], mode='resolveslow', timeout=120)
        self.assertIn('notrun Fake Tests id=rhun-tests/testsfake kind=controller ms=- error=no answer in time', out)
        self.assertIn('recv 0 cancel 1', self.fake_log())

    def test_bad_bodies_are_refused_and_change_nothing(self):
        out = self.run_editor(['cmd testing', 'wait-test-items 2', 'wait 800', 'print-tests all'], mode='remove')
        log = self.fake_log()
        self.assertTrue(any(l.startswith('unknown-parent error ') and l.endswith('refused unknown parent') for l in log), log)
        self.assertTrue(any(l.startswith('cycle error ') and 'cannot move below itself' in l for l in log), log)
        self.assertTrue(any(l.startswith('bad-range error ') and ' badpos ' in l for l in log), log)
        self.assertTrue(any(l.startswith('relative error ') and 'absolute path' in l for l in log), log)
        self.assertTrue([l for l in log if l.startswith('remove ok ')], log)
        self.assertFalse([l for l in out if 'go:example/other' in l], out)
        self.assertFalse([l for l in out if ' id=x ' in l or ' id=r ' in l], out)

    def test_a_replace_counts_the_subtrees_it_moves_against_the_caps(self):
        self.run_editor(['cmd testing', 'wait-test-items 50000', 'wait 500'], mode='movecap', timeout=120)
        over = self.logged('movecap-over ')
        self.assertTrue(over and over[0].endswith('toobig 50000 items per extension'), self.fake_log()[-5:])
        self.assertTrue(self.logged('movecap-ok ok '), self.fake_log()[-5:])

    def test_item_caps(self):
        self.run_editor(['cmd testing', 'wait-test-items 50000', 'wait 500'], mode='flood')
        log = self.fake_log()
        self.assertTrue(any(l.startswith('flood-body error ') and 'toobig 10000 items' in l for l in log), log)
        self.assertTrue(any(l.startswith('flood-ok ok') for l in log), log)
        self.assertTrue(any(l.startswith('flood-add step 3: error ') and 'toobig 50000 items per extension' in l
                            for l in log), log)
        # replacing the roots counts what goes: one test in place of 40,001 items fits
        self.assertTrue(any(l.startswith('flood-replace ok') for l in log), log)

    def test_replace_keeps_the_results_of_kept_ids(self):
        out = self.run_editor([*EXPAND, 'cmd test_run_all', 'wait-tests', 'wait 300', 'print-tests all'],
                              mode='replaceafter')
        self.assertIn('replace ok 11', self.fake_log())
        self.assertEqual(self.line(out, 'go:example/pkg.TestA'),
                         'passed TestA renamed id=go:example/pkg.TestA kind=test ms=12 range=3:1-5:2')
        self.assertIn('notrun TestD id=go:example/pkg.TestD kind=test ms=- range=15:1-16:2',
                      [l.strip() for l in out])
        self.assertFalse([l for l in out if 'TestB' in l or 'TestC' in l], out)
        # TestA kept its id, so its children (the subtest added during the run) stay with it
        self.assertIn('passed sub id=go:example/pkg.TestA/sub kind=test ms=1 range=4:2-4:9', [l.strip() for l in out])
        self.assertEqual(out[-1], 'passed=1 failed=0 errored=0 skipped=0 notrun=1')

    # --- runs ---

    def test_run_all_reports_states_results_and_counts(self):
        out = self.run_editor([*EXPAND, 'cmd test_run_all', 'wait-tests', 'print-tests all', 'print-test-runs',
                               'print-test-result testsfake go:example/pkg.TestB'])
        self.assertIn('run 1 run 0 ', self.fake_log())
        self.assertEqual(self.line(out, 'rhun-tests/testsfake'), 'failed Fake Tests id=rhun-tests/testsfake kind=controller ms=-')
        self.assertEqual(self.line(out, 'go:example/pkg.TestA/sub'), 'passed sub id=go:example/pkg.TestA/sub kind=test ms=1 range=4:2-4:9')
        self.assertEqual(self.line(out, 'go:example/pkg.TestC'), 'skipped TestC id=go:example/pkg.TestC kind=test ms=0 range=11:1-13:2 nodebug')
        self.assertIn('passed=1 failed=1 errored=0 skipped=1 notrun=0', out)
        runs = [l for l in out if l.startswith('run=')]
        self.assertEqual(len(runs), 1, out)
        self.assertTrue(runs[0].startswith('run=1 ext=rhun-tests/testsfake profile=run state=ended passed=2 failed=1 '
                                           'errored=0 skipped=1 notrun=0 dropped=0 procs=0'), runs)
        at = out.index('state=failed ms=30 run=1 first=Greet mismatch')
        f = (self.proj / 'a_test.go').as_posix()
        self.assertEqual(out[at + 1], 'message=Greet mismatch\\nsecond line at=' + f + ':8:2 '
                         'expected=Hello, rhun!\\nWelcome. actual=Hello, rhun')
        self.assertEqual(out[at + 2], 'output==== RUN TestB\\nfail\\n')

    def test_rerun_failed_runs_only_failed_leaves_and_rerun_last_repeats(self):
        self.run_editor([*EXPAND, 'cmd test_run_all', 'wait-tests', 'cmd test_rerun_failed', 'wait-tests',
                         'cmd test_rerun_last', 'wait-tests'])
        runs = self.logged('run ')
        self.assertEqual(runs, ['run 1 run 0 ', 'run 2 run 1 go:example/pkg.TestB', 'run 3 run 1 go:example/pkg.TestB'])

    def test_selected_item_cursor_and_file_runs(self):
        self.run_editor([*EXPAND, 'test-select testsfake go:example/pkg.TestA', 'test-action run', 'wait-tests',
                         'test-select testsfake', 'test-action run', 'wait-tests',
                         'cmd goto_line', 'type 8', 'key Return', 'cmd test_run_cursor', 'wait-tests',
                         'cmd goto_line', 'type 2', 'key Return', 'cmd test_run_cursor', 'wait-tests',
                         'cmd test_run_file', 'wait-tests'])
        self.assertEqual(self.logged('run '), ['run 1 run 1 go:example/pkg.TestA', 'run 2 run 0 ',
                                               'run 3 run 1 go:example/pkg.TestB',
                                               'run 4 run 1 go:example/pkg#a_test.go',
                                               'run 5 run 1 go:example/pkg#a_test.go'])

    def test_a_kind_the_controller_does_not_offer_is_not_sent(self):
        out = self.run_editor([*EXPAND, 'test-select testsfake go:example/pkg.TestA', 'test-action debug',
                               'print-toast', 'wait 200', 'print-test-runs'])
        self.assertFalse(self.logged('run '))
        self.assertTrue(any('does not offer' in l for l in out), out)

    def test_concurrent_runs_with_the_same_items(self):
        out = self.run_editor([*EXPAND, 'cmd test_run_all', 'cmd test_run_all', 'wait-tests', 'print-test-runs',
                               'print-tests all'])
        runs = [l for l in out if l.startswith('run=')]
        self.assertEqual(len(runs), 2, out)
        self.assertTrue(all(' state=ended passed=2 failed=1 ' in r for r in runs), runs)
        self.assertIn('passed=1 failed=1 errored=0 skipped=1 notrun=0', out)

    def test_cancel_tells_the_controller_and_states_go_back(self):
        out = self.run_editor([*EXPAND, 'cmd test_run_all', 'wait 400', 'print-tests all', 'cmd test_cancel',
                               'wait-tests', 'print-tests all', 'print-test-runs'], mode='slow')
        self.assertIn('recv 0 test-cancel 1', self.fake_log())
        first = out.index('running Fake Tests id=rhun-tests/testsfake kind=controller ms=-')
        self.assertEqual(self.line(out[first:first + 8], 'go:example/pkg.TestB'), 'running TestB id=go:example/pkg.TestB kind=test ms=- range=7:1-9:2')
        self.assertEqual(self.line(out, 'go:example/pkg.TestB'), 'notrun TestB id=go:example/pkg.TestB kind=test ms=- range=7:1-9:2')
        self.assertTrue([l for l in out if l.startswith('run=1 ') and ' state=ended ' in l and ' notrun=3 ' in l], out)

    def test_a_controller_that_ignores_cancel_has_its_run_ended_after_5_s(self):
        t0 = time.time()
        out = self.run_editor([*EXPAND, 'cmd test_run_all', 'wait 300', 'cmd test_cancel', 'wait-tests',
                               'print-test-runs', 'print-tests all'], mode='stubborn')
        self.assertGreater(time.time() - t0, 5)
        self.assertTrue([l for l in out if l.startswith('run=1 ') and ' state=ended ' in l], out)
        self.assertIn('passed=0 failed=0 errored=0 skipped=0 notrun=3', out)

    def test_a_controller_that_stops_ends_its_run_errored(self):
        out = self.run_editor([*EXPAND, 'cmd test_run_all', 'wait-tests', 'wait 300', 'print-test-runs',
                               'print-extensions'], mode='crash')
        self.assertTrue([l for l in out if l.startswith('run=1 ') and ' state=ended errored-run ' in l], out)

    def test_late_updates_are_stale_and_unknown_items_counted(self):
        self.run_editor([*EXPAND, 'cmd test_run_all', 'wait-tests', 'wait 300'], mode='late')
        self.assertTrue([l for l in self.fake_log() if l.startswith('late error ') and l.endswith('stale run over')],
                        self.fake_log())
        out = self.run_editor([*EXPAND, 'cmd test_run_all', 'wait-tests', 'print-test-runs'], mode='unknown')
        self.assertTrue([l for l in out if l.startswith('run=1 ') and ' dropped=1 ' in l and ' passed=1 ' in l], out)

    def test_a_refused_run_ends_errored_and_says_why(self):
        out = self.run_editor([*EXPAND, 'cmd test_run_all', 'wait-tests', 'print-test-runs', 'print-toast'],
                              mode='refuse')
        self.assertTrue([l for l in out if l.startswith('run=1 ') and ' state=ended errored-run ' in l], out)
        self.assertTrue([l for l in out if 'the build is running' in l], out)

    def test_item_output_is_cut_at_256_kib(self):
        out = self.run_editor([*EXPAND, 'cmd test_run_all', 'wait-tests',
                               'print-test-result testsfake go:example/pkg.TestA'], mode='bigout')
        self.assertTrue(self.logged('big ok'), self.fake_log())
        output = [l for l in out if l.startswith('output=')][0]
        self.assertTrue(output.endswith('\\n[output cut]\\n'), output[-80:])
        self.assertEqual(output.count('y'), 262144 - len('ok A\n'))

    def test_expected_and_actual_open_as_a_diff_and_output_as_a_tab(self):
        out = self.run_editor([*EXPAND, 'cmd test_run_all', 'wait-tests',
                               'test-select testsfake go:example/pkg.TestB', 'test-action diff', 'print-tabs',
                               'print-doc', 'test-action output', 'print-doc', 'test-action failure', 'print-state',
                               'test-select testsfake go:example/pkg.TestC', 'test-action goto', 'print-state'])
        at = out.index('@@ -1,2 +1,1 @@')
        self.assertEqual(out[at:at + 5], ['@@ -1,2 +1,1 @@', 'Hello, rhun!', 'Welcome.', 'Hello, rhun', '<eod>'])
        self.assertIn('tabs=a_test.go | *Expected \u2194 Actual: TestB', out)
        at = out.index('=== RUN TestB')
        self.assertEqual(out[at:at + 4], ['=== RUN TestB', 'fail', '', '<eod>'])
        states = [l for l in out if l.startswith('tabs=3 ')]
        self.assertIn(' line=8 col=5 ', states[0])       # 8:2, after a tab four columns wide
        self.assertIn(' line=11 col=1 ', states[1])
        out = self.run_editor([*EXPAND, 'cmd test_run_all', 'wait-tests', 'key ctrl+Home', 'cmd test_next_failure',
                               'print-state'])
        self.assertIn(' line=8 col=5 ', [l for l in out if l.startswith('tabs=')][-1])

    def test_overlapping_runs_leave_no_stale_running_state(self):
        out = self.run_editor([*EXPAND, 'cmd test_run_all', 'cmd test_run_all', 'wait-tests', 'print-tests all',
                               'print-test-runs'], mode='overlap')
        self.assertIn('tests=idle', out)
        self.assertFalse([l for l in out if l.lstrip().startswith('running ')], out)
        self.assertIn('passed=0 failed=0 errored=0 skipped=0 notrun=3', out)

    def test_an_unfinished_rerun_brings_back_the_last_result_and_its_summary(self):
        out = self.run_editor([*EXPAND, 'cmd test_run_all', 'wait-tests', 'cmd test_run_all', 'wait 400',
                               'cmd test_cancel', 'wait-tests', 'print-test-result testsfake go:example/pkg.TestB'],
                              mode='slow2')
        self.assertIn('recv 0 test-cancel 2', self.fake_log())
        self.assertTrue([l for l in out if l.startswith('state=failed ms=30 run=1 first=Greet mismatch')], out)

    def test_nodebug_items_are_not_debugged(self):
        exts = self.work / 'exts'
        dst = exts / 'rhun-tests/testsfake'
        dst.mkdir(parents=True)
        manifest = (EXTS / 'rhun-tests/testsfake/extension.ini').read_text(encoding='utf-8')
        manifest = manifest.replace('tests.profiles = run coverage', 'tests.profiles = run debug coverage')
        manifest = manifest.replace('run = ../../../testsfake.py', 'run = ' + (ROOT / 'tests/ext/testsfake.py').as_posix())
        (dst / 'extension.ini').write_text(manifest, encoding='utf-8')
        out = self.run_editor([*EXPAND, 'test-select testsfake go:example/pkg.TestC', 'test-action debug', 'print-toast',
                               'cmd goto_line', 'type 12', 'key Return', 'cmd test_debug_cursor',
                               'test-select testsfake go:example/pkg.TestA', 'test-action debug', 'wait-tests'],
                              exts=exts, mode='refuse')
        self.assertEqual(self.logged('run '), ['run 1 debug 1 go:example/pkg.TestA'])
        self.assertTrue([l for l in out if 'cannot be debugged' in l], out)

    def test_a_debug_run_opens_the_debug_start_window(self):
        exts = self.work / 'exts'
        dst = exts / 'rhun-tests/testsfake'
        dst.mkdir(parents=True)
        manifest = (EXTS / 'rhun-tests/testsfake/extension.ini').read_text(encoding='utf-8')
        manifest = manifest.replace('tests.profiles = run coverage', 'tests.profiles = run debug coverage')
        manifest = manifest.replace('run = ../../../testsfake.py', 'run = ' + (ROOT / 'tests/ext/testsfake.py').as_posix())
        (dst / 'extension.ini').write_text(manifest, encoding='utf-8')
        out = self.run_editor([*EXPAND, 'test-select testsfake go:example/pkg.TestA', 'test-action run', 'wait 300',
                               'echo @run', 'print-test-runs', 'test-action cancel', 'wait-tests',
                               'test-action debug', 'wait 300', 'echo @debug', 'print-test-runs',
                               'test-action cancel', 'wait-tests', 'echo @over', 'print-test-runs'],
                              exts=exts, mode='slow')
        def runs(a, b):
            seg = out[out.index(a) + 1:out.index(b) if b else len(out)]
            return [l for l in seg if l.startswith('run=')]
        self.assertFalse([l for l in runs('@run', '@debug') if 'debug-window' in l], out)
        debug = runs('@debug', '@over')
        self.assertTrue(debug[-1].startswith('run=2 ') and ' profile=debug state=running debug-window ' in debug[-1], out)
        self.assertFalse([l for l in runs('@over', None) if 'debug-window' in l], out)

    def test_coverage_is_bounded_by_its_lines_and_merges_by_path(self):
        out = self.run_editor([*EXPAND, 'cmd test_coverage_all', 'wait-tests'], mode='covbig,covunion', timeout=120)
        log = self.fake_log()
        self.assertTrue([l for l in log if l.startswith('covbig error ') and ' toobig ' in l], log)
        self.assertTrue([l for l in log if l.startswith('covunion1 ok')], log)
        self.assertTrue([l for l in log if l.startswith('covunion2 ok')], log)

    def test_coverage_run(self):
        f = (self.proj / 'a_test.go').as_posix()
        out = self.run_editor([*EXPAND, 'cmd test_coverage_all', 'wait-tests', 'print-test-runs',
                               'print-coverage ' + f])
        self.assertIn('run 1 coverage 0 ', self.fake_log())
        self.assertTrue(self.logged('coverage ok'), self.fake_log())
        self.assertIn('covered=3 partial=1 missed=0 lines=3:C,5:C,6:P,7:C', out)

    def test_an_expected_actual_tab_is_no_git_diff(self):
        # with Git on, a diff tab of the values beside a changed file: Open Changes finds the file's
        # own diff, and quitting remembers no Git diff for the values' tab
        env = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', HOME=self.work.as_posix())
        for cmd in (['git', 'init', '-q'], ['git', '-c', 'user.name=t', '-c', 'user.email=t@t', 'add', '.'],
                    ['git', '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'one']):
            subprocess.run(cmd, cwd=self.proj, env=env, check=True, capture_output=True)
        (self.proj / 'a_test.go').write_text(SOURCE + '// changed\n', encoding='utf-8')
        config = self.work / 'config/rhun/config'
        config.write_text(CONFIG.replace('[git]\nenabled = false\n', ''), encoding='utf-8')
        out = self.run_editor([*EXPAND, 'cmd test_run_all', 'wait-tests',
                               'test-select testsfake go:example/pkg.TestB', 'test-action diff', 'wait 100',
                               'cmd next_tab', 'cmd git_changes', 'wait 1500', 'print-tabs'])
        tabs = [l for l in out if l.startswith('tabs=')][-1]
        self.assertIn('Expected \u2194 Actual: TestB', tabs)
        self.assertEqual(tabs.count('a_test.go'), 2, tabs)

    def test_failures_become_problems_and_go_with_their_item(self):
        out = self.run_editor([*EXPAND, 'cmd test_run_all', 'wait-tests', 'wait 100', 'print-marks'])
        at = out.index('tests=idle')
        self.assertEqual(out[at + 1:at + 5], ['8 2 8 7 error problems:Fake Tests TestB: Greet mismatch',
                                              'Expected: Hello, rhun!', 'Actual: Hello, rhun', 'errors=1 warnings=0'])
        # the controller replaces the file's tests without TestB: its problem goes
        out = self.run_editor([*EXPAND, 'cmd test_run_all', 'wait-tests', 'wait 400', 'print-marks', 'print-problems'],
                              mode='replaceafter')
        self.assertIn('errors=0 warnings=0', out)

    def test_gutter_glyphs_follow_states_run_on_click_and_coverage_tints(self):
        out = self.run_editor([*EXPAND, 'wait 300', 'print-gutter', 'test-gutter 7', 'print-menu', 'menu-pick Run \'TestB\'',
                               'wait-tests', 'print-gutter',
                               'cmd test_coverage_all', 'wait-tests', 'print-gutter', 'test-gutter 11 right', 'print-menu',
                               'key Escape', 'cmd test_coverage_toggle', 'print-gutter'])
        self.assertEqual(out[2:6], ['line=3 glyph=play item=go:example/pkg.TestA', 'line=7 glyph=play item=go:example/pkg.TestB',
                                    'line=11 glyph=play item=go:example/pkg.TestC', 'cov='])
        # a click opens the play menu, as JetBrains IDEs and the Sublime Debugger: Run, Debug, Run with Coverage
        self.assertEqual(out[6:9], ["Run 'TestB'", "Debug 'TestB'", "Run 'TestB' with Coverage"])
        self.assertIn('run 1 run 1 go:example/pkg.TestB', self.fake_log())
        self.assertIn('line=7 glyph=failed item=go:example/pkg.TestB', out)
        self.assertIn('line=4 glyph=passed item=go:example/pkg.TestA/sub', out)
        self.assertIn('cov=3:C,5:C,6:P,7:C', out)
        self.assertTrue([l for l in out if 'Run with Coverage' in l], out)
        self.assertEqual(out[-1], 'cov=')

    def test_glyphs_problems_and_coverage_follow_edits_until_replaced(self):
        # two lines typed at the top after a coverage run; TestA runs again, so the problems and
        # glyphs are set again from the model: TestB's old place and the coverage move with the text
        out = self.run_editor([*EXPAND, 'cmd test_coverage_all', 'wait-tests', 'wait 100', 'echo @before',
                               'print-gutter', 'print-marks', 'cmd goto_line', 'type 1', 'key Return',
                               'type //a', 'key Return', 'type //b', 'key Return',
                               'test-select testsfake go:example/pkg.TestA', 'test-action run', 'wait-tests',
                               'wait 100', 'echo @after', 'print-gutter', 'print-marks',
                               'test-select testsfake go:example/pkg.TestB', 'test-action failure', 'print-state',
                               'test-select testsfake go:example/pkg.TestC', 'test-action goto', 'print-state',
                               'test-gutter 9', 'menu-pick Run \'TestB\'', 'wait-tests',
                               'cmd goto_line', 'type 10', 'key Return', 'cmd test_run_cursor', 'wait-tests'])
        at = out.index('@after')
        before, after = out[out.index('@before'):at], out[at:]
        self.assertIn('line=7 glyph=failed item=go:example/pkg.TestB', before)
        self.assertIn('cov=3:C,5:C,6:P,7:C', before)
        self.assertIn('line=5 glyph=passed item=go:example/pkg.TestA', after)
        self.assertIn('line=9 glyph=failed item=go:example/pkg.TestB', after)
        self.assertIn('line=13 glyph=skipped item=go:example/pkg.TestC', after)
        self.assertIn('cov=5:C,7:C,8:P,9:C', after)
        self.assertIn('10 2 10 7 error problems:Fake Tests TestB: Greet mismatch', after)
        # TestB's failure and TestC are where they are now; a click on TestB's glyph where it is now
        # runs it, as Run Test at Cursor in its body does
        self.assertIn('run 3 run 1 go:example/pkg.TestB', self.fake_log())
        self.assertIn('run 4 run 1 go:example/pkg.TestB', self.fake_log())
        states = [l for l in after if l.startswith('tabs=')]
        self.assertIn(' line=10 col=5 ', states[0])
        self.assertIn(' line=13 col=1 ', states[1])

    def test_the_status_bar_item_counts_runs_then_results_and_shows_testing(self):
        out = self.run_editor(['wait 200', 'print-test-status', *EXPAND, 'print-test-status', 'cmd test_run_all',
                               'wait 300', 'print-test-status', 'cmd test_cancel', 'wait-tests', 'wait 100',
                               'print-test-status'], mode='slow')
        status = [l for l in out if l.startswith('test-status')]
        self.assertEqual(status[:2], ['test-status none'] * 2)
        self.assertTrue(status[2].endswith(' text=Testing 0/3'), status)
        self.assertTrue(status[3].endswith(' text=passed=0 failed=0'), status)
        out = self.run_editor([*EXPAND, 'cmd test_run_all', 'wait-tests', 'wait 100', 'print-test-status',
                               'key Escape', 'print-sidebar'])
        status = [l for l in out if l.startswith('test-status')][-1]
        self.assertTrue(status.endswith(' text=passed=1 failed=1'), status)
        f = dict(kv.split('=', 1) for kv in status.split(' ')[1:5])
        x, y = int(f['x']) + int(f['w']) // 2, int(f['y']) + int(f['h']) // 2
        out = self.run_editor([*EXPAND, 'cmd test_run_all', 'wait-tests', 'wait 100', 'print-sidebar',
                               'move %d %d' % (x, y), 'click %d %d' % (x, y), 'wait 100', 'print-sidebar'])
        bars = [l for l in out if l.startswith('testing title=Testing')]
        self.assertTrue(bars and ' visible' in bars[-1], out)

    def test_the_filter_keeps_matching_rows_and_failed_only(self):
        out = self.run_editor([*EXPAND, 'cmd test_run_all', 'wait-tests', 'test-collapse testsfake go:example/pkg',
                               'echo @all', 'print-testing', 'test-filter b', 'echo @b', 'print-testing',
                               'test-filter test c', 'echo @c', 'print-testing', 'test-filter', 'test-failed-only on',
                               'echo @failed', 'print-testing', 'test-failed-only off', 'echo @off', 'print-testing'])
        def labels(a, b):
            seg = out[out.index(a) + 1:out.index(b) if b else len(out)]
            return [l.split(' label=')[1].split(' icon=')[0].split(' desc=')[0] for l in seg if l.startswith('row ')]
        self.assertEqual(labels('@all', '@b'), ['Fake Tests', 'pkg', 'other'])
        self.assertEqual(labels('@b', '@c'), ['Fake Tests', 'pkg', 'a_test.go', 'TestB'])
        self.assertEqual(labels('@c', '@failed'), ['Fake Tests', 'pkg', 'a_test.go', 'TestC'])
        self.assertEqual(labels('@failed', '@off'), ['Fake Tests', 'pkg', 'a_test.go', 'TestB'])
        # without a filter the tree is as the user left it
        self.assertEqual(labels('@off', None), ['Fake Tests', 'pkg', 'other'])
        # typing in the field filters; Escape clears it, then leaves it; the buttons say what they do
        out = self.run_editor([*EXPAND, 'cmd test_run_all', 'wait-tests', 'move 80 374', 'click 80 374', 'type c',
                               'wait 50', 'echo @typed', 'print-testing', 'key Escape', 'key Escape', 'echo @cleared',
                               'print-testing', 'move 220 374', 'wait 900', 'print-tip', 'move 152 321', 'wait 900',
                               'print-tip'])
        typed = [l for l in out[out.index('@typed'):out.index('@cleared')] if l.startswith('row ')]
        self.assertTrue(typed[-1].startswith('row 3 ') and ' label=TestC ' in typed[-1], typed)
        self.assertEqual(len([l for l in out[out.index('@cleared'):] if l.startswith('row ')]), 7, out)
        tips = [l for l in out if l.startswith('tip')]
        self.assertTrue(any('Show only failed tests' in l for l in tips), tips)
        self.assertTrue(any('Run All Tests' in l for l in tips), tips)

    def test_the_coverage_section_lists_files_least_covered_first(self):
        out = self.run_editor([*EXPAND, 'print-test-coverage', 'cmd test_coverage_all', 'wait-tests', 'wait 100',
                               'print-test-coverage', 'print-sidebar', 'cmd test_coverage_toggle', 'wait 100',
                               'print-test-coverage'], mode='cov2')
        self.assertIn('coverage-section none', out)
        self.assertEqual([l for l in out if l.startswith('file=')][:2],
                         ['file=/cov/low.go desc=1/4 \u00b7 25%', 'file=a_test.go desc=4/4 \u00b7 100%'])
        self.assertTrue([l for l in out if l.startswith('coverage title=Coverage at=')], out)

    def test_a_path_repeated_in_one_coverage_message_counts_once(self):
        out = self.run_editor([*EXPAND, 'cmd test_coverage_all', 'wait-tests', 'print-coverage /cov/rep.go'],
                              mode='covrepeat', timeout=120)
        self.assertTrue(self.logged('covrepeat ok '), self.fake_log()[-5:])
        self.assertTrue([l for l in out if l.startswith('covered=1 partial=0 missed=0 lines=1048576:C')], out)

    def test_a_reopened_file_keeps_its_glyphs_and_tints(self):
        # discovered and covered after an edit was saved; the file closed and opened again is a new
        # document whose versions start over: its lines are the file's as it is
        p = self.proj / 'a_test.go'
        out = self.run_editor(['cmd goto_line', 'type 14', 'key Return', 'key End', 'type // end', 'cmd save',
                               *EXPAND, 'cmd test_coverage_all', 'wait-tests', 'wait 100', 'print-gutter',
                               'cmd close_tab', 'open ' + p.as_posix(), 'wait 200', 'echo @reopened', 'print-gutter'])
        after = out[out.index('@reopened'):]
        self.assertIn('line=7 glyph=failed item=go:example/pkg.TestB', after)
        self.assertIn('cov=3:C,5:C,6:P,7:C', after)

    def test_a_reopened_file_moves_coverage_and_failures_with_edits(self):
        # covered and failed, closed, opened again unchanged, a line typed at the top: the tints, the
        # failure's mark and Go to Failure all move down a line
        p = self.proj / 'a_test.go'
        out = self.run_editor([*EXPAND, 'cmd test_coverage_all', 'wait-tests', 'wait 100', 'cmd close_tab',
                               'open ' + p.as_posix(), 'wait 200', 'cmd goto_line', 'type 1', 'key Return',
                               'type //top', 'key Return', 'wait 100', 'echo @edited', 'print-gutter', 'print-marks',
                               'test-select testsfake go:example/pkg.TestB', 'test-action failure', 'print-state'])
        after = out[out.index('@edited'):]
        self.assertIn('cov=4:C,6:C,7:P,8:C', after)
        self.assertIn('9 2 9 7 error problems:Fake Tests TestB: Greet mismatch', after)
        self.assertIn(' line=9 col=5 ', [l for l in after if l.startswith('tabs=')][-1])

    def test_idle_after_coverage_draws_nothing(self):
        out = self.run_editor([*EXPAND, 'cmd test_coverage_all', 'wait-tests', 'wait 500', 'print-frames',
                               'wait 1500', 'print-frames'])
        frames = [int(l.split('=')[1].split()[0]) for l in out if l.startswith('frames=')]
        self.assertEqual(frames[1], 0, out)     # print-frames counts since the last one

    def test_coverage_tints_belong_to_their_file(self):
        # a document opened after the covered one closed (its memory may be the same) has none
        (self.proj / 'b.go').write_text(SOURCE.replace('pkg', 'other'), encoding='utf-8')
        out = self.run_editor([*EXPAND, 'cmd test_coverage_all', 'wait-tests', 'wait 100', 'print-gutter',
                               'cmd close_tab', 'open ' + (self.proj / 'b.go').as_posix(), 'wait 100', 'print-gutter'])
        covs = [l for l in out if l.startswith('cov=')]
        self.assertEqual(covs[0], 'cov=3:C,5:C,6:P,7:C')
        self.assertEqual(covs[-1], 'cov=')

    def test_glyphs_go_with_their_item_and_follow_the_setting(self):
        # Settings, searched for the one switch (at 1400x900 its knob is at 1146,348); the second time
        # the page still has the search
        toggle = ['cmd settings', 'type test buttons', 'wait 100', 'click 1146 348', 'wait 100',
                  'open ' + (self.proj / 'a_test.go').as_posix(), 'wait 100']
        out = self.run_editor([*EXPAND, 'wait 200', 'echo @before', 'print-gutter', 'wait 1500', 'echo @removed',
                               'print-gutter', *toggle, 'echo @off', 'print-gutter', *toggle[:1], *toggle[2:],
                               'echo @on', 'print-gutter'], mode='removeb', size='1400x900')
        def seg(a, b):
            return out[out.index(a) + 1:out.index(b) if b else len(out)]
        self.assertIn('line=7 glyph=play item=go:example/pkg.TestB', seg('@before', '@removed'))
        self.assertTrue(self.logged('removeb ok '), self.fake_log())
        removed = seg('@removed', '@off')
        self.assertFalse([l for l in removed if 'TestB' in l], removed)
        self.assertIn('line=3 glyph=play item=go:example/pkg.TestA', removed)
        self.assertFalse([l for l in seg('@off', '@on') if l.startswith('line=')], out)
        self.assertIn('line=3 glyph=play item=go:example/pkg.TestA', seg('@on', None))

    # --- the Testing section ---

    def section(self, out):
        return [l for l in out if l.startswith('row ')]

    def test_the_testing_section_mirrors_the_tree_and_its_buttons_run(self):
        # at 1000x600 the sidebar holds the explorer and Testing; Testing's header is above y=335,
        # its buttons right to left from x=212: Cancel, Re-run Failed, Coverage, Run All
        out = self.run_editor([*EXPAND, 'print-testing', 'move 150 321', 'click 150 321', 'wait-tests',
                               'test-select testsfake go:example/pkg.TestB', 'print-testing', 'print-sidebar',
                               'key r', 'wait-tests'])
        rows = self.section(out)
        self.assertTrue(rows[0].startswith('row 0 '), rows)
        self.assertIn(' open id=00 label=Fake Tests ', rows[0])
        self.assertIn(' leaf id=00go:example/pkg.TestB label=TestB icon=', rows[4])
        self.assertIn('testing title=Testing at=0,335 size=240x239 badge=0 visible focus', out)
        self.assertEqual(self.logged('run '), ['run 1 run 0 ', 'run 2 run 1 go:example/pkg.TestB'])
        after = rows[len(rows) // 2:]
        self.assertTrue([r for r in after if 'id=00go:example/pkg.TestB ' in r and ' cur ' in r and 'desc=30 ms' in r],
                        after)

    def test_a_lazy_item_expanded_in_the_section_is_resolved(self):
        out = self.run_editor(['cmd testing', 'wait-test-items 2', 'print-testing', 'key Down', 'key Down',
                               'key Right', 'wait 300', 'print-testing', 'print-tests'])
        rows = self.section(out)
        self.assertIn(' closed id=00go:example/pkg label=pkg ', rows[1])
        self.assertTrue([r for r in rows if 'id=00go:example/pkg#a_test.go' in r], rows)
        self.assertIn("recv 2 tests-resolve 14 b'go:example/pkg'", self.fake_log())

    # --- test-exec ---

    def test_a_second_exec_while_the_question_is_open_leaves_the_parked_command(self):
        # two runs ask before the user answers: the second is busy, the first runs as asked
        out = self.run_editor([*EXPAND, 'cmd test_run_all', 'wait 300', 'cmd test_run_all', 'wait 500',
                               'dialog yes', 'wait-tests'], mode='exec')
        log = self.fake_log()
        self.assertTrue([l for l in log if l.startswith('exec error ') and ' busy a question is open' in l], log)
        self.assertIn("exec-result exit=3 out=b'out-line\\n' err=b'err-line\\n'", log)

    def test_exec_runs_a_program_as_the_user_and_passes_its_output(self):
        out = self.run_editor([*EXPAND, 'cmd test_run_all', 'wait 500', 'print-dialog', 'dialog yes', 'wait-tests',
                               'print-test-runs', 'print-test-result testsfake go:example/pkg.TestA',
                               'cmd test_run_all', 'wait-tests', 'print-dialog'], mode='exec')
        # the first program in the project asks once, showing the command; the second run does not
        self.assertIn('dialog=Let Fake Tests run programs in proj?', out)
        self.assertTrue([l for l in out if l.startswith("text=python3 -c 'import sys print(")], out)
        self.assertEqual(out[-1], 'dialog=none')
        log = self.fake_log()
        self.assertTrue([l for l in log if l.startswith('exec ok ') and l.endswith(' 1')], log)
        self.assertIn("exec-result exit=3 out=b'out-line\\n' err=b'err-line\\n'", log)
        self.assertIn('output=out-line\\nerr-line\\n', out)
        self.assertTrue([l for l in out if l.startswith('run=1 ') and ' procs=0' in l], out)

    def test_exec_refusals(self):
        self.run_editor([*EXPAND, 'cmd test_run_all', 'wait 500', 'dialog yes', 'wait-tests', 'wait 4000'], mode='execbad')
        log = self.fake_log()
        def reply(prefix):
            hit = [l for l in log if l.startswith(prefix + ' ')]
            self.assertTrue(hit, (prefix, log))
            return hit[0][len(prefix) + 1:]
        self.assertTrue(reply('bad-prog').endswith(' needs tests=ls'))
        self.assertTrue(reply('bad-name').endswith(' refused the program must be a bare name'))
        self.assertTrue(reply('bad-cwd').endswith(' refused the folder is not inside the project'))
        self.assertIn(' syntax a variable is NAME=VALUE', reply('bad-env'))
        self.assertTrue(reply('missing').endswith(' refused the folder is not inside the project'))
        self.assertIn(' busy ', reply('fifth'))
        self.assertTrue(reply('over').endswith(' stale run over'))
        # the four that started were stopped when the run ended
        self.assertEqual(len([l for l in log if l.startswith('recv 0 test-exit ') and l.endswith(' killed')]), 4, log)

    def test_a_declined_approval_answers_cancelled_and_asks_again(self):
        out = self.run_editor([*EXPAND, 'cmd test_run_all', 'wait 500', 'dialog no', 'wait-tests',
                               'cmd test_run_all', 'wait 500', 'print-dialog', 'dialog no', 'wait-tests'], mode='exec')
        self.assertEqual(len([l for l in self.fake_log() if l.startswith('exec error ') and l.endswith(' cancelled')]), 2,
                         self.fake_log())
        self.assertEqual(len([l for l in out if l.startswith('dialog=Let Fake Tests')]), 1, out)

    def test_cancel_stops_processes_after_2_s(self):
        self.run_editor([*EXPAND, 'cmd test_run_all', 'wait 500', 'dialog yes', 'wait 800', 'cmd test_cancel',
                         'wait-tests', 'wait 3000'], mode='slowexec')
        log = self.fake_log()
        self.assertTrue([l for l in log if l.startswith('recv 0 test-out ') and 'sleeping' in l], log)
        self.assertIn('exit killed', log)

    def test_a_stopped_programs_children_go_too(self):
        out = self.run_editor([*EXPAND, 'cmd test_run_all', 'wait 500', 'dialog yes', 'wait 800', 'cmd test_cancel',
                               'wait-tests', 'wait 3500'], mode='survivor')
        log = self.fake_log()
        pid = [l for l in log if l.startswith('recv 0 test-out ') and ' out ' in l]
        self.assertTrue(pid, log)
        child = int(pid[0].split("b'")[1].split('\\n')[0])
        time.sleep(0.5)
        try:
            os.kill(child, 0)
            alive = True
        except ProcessLookupError:
            alive = False
        if alive:
            os.kill(child, 9)
        self.assertFalse(alive, 'the child that ignored SIGTERM outlived the run')

    def test_back_pressure_keeps_a_chatty_process_waiting(self):
        self.env['TESTS_CHATTY'] = str(8 << 20)
        out = self.run_editor([*EXPAND, 'cmd test_run_all', 'wait 500', 'dialog yes', 'wait-tests', 'print-extensions'],
                              mode='chatty', timeout=180)
        self.assertIn('chatty exit=0 bytes=%d' % (8 << 20), self.fake_log())
        self.assertTrue([l for l in out if l.startswith('rhun-tests/testsfake state=running')], out)


if __name__ == '__main__':
    unittest.main()
