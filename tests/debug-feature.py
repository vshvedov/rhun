#!/usr/bin/env python3
"""Feature `debug` (docs/extensions/v1.1.md "debug"): an extension starts a session of one of its
own debuggers with debug-start within 10 s of one of its commands, once per command, after the
user's approval, and hears debug-ended with the program's exit code. The extension is the fake
debugger's own program (tests/dap/debugfake.py), driven by a mode.json in its state folder."""
import json
import unittest
import debughost


class FeatureHost(debughost.DebugHost):
    def ext_state(self):
        return self.work / 'state/rhun/extensions/rhun-tests--debugfake'

    def mode(self, **mode):
        state = self.ext_state()
        state.mkdir(parents=True, exist_ok=True)
        (state / 'mode.json').write_text(json.dumps(mode), encoding='utf-8')

    def ext_log(self):
        path = self.ext_state() / 'debugfake.log'
        return path.read_text(encoding='utf-8').splitlines() if path.exists() else []

    def leaves(self, **extra):
        program = self.scenario().as_posix()
        leaves = [['s', 'type', 'fake'], ['s', 'program', program]]
        for path, (kind, value) in extra.items():
            leaves.append([kind, path.replace('__', '.'), value])
        return leaves


class Borrowed(FeatureHost):
    """[needs] debuggers: an extension starts a type another extension provides; one nobody provides is
    refused with a toast that says what to install"""
    def ext_state(self):
        return self.work / 'state/rhun/extensions/rhun-tests--debuguser'

    def test_another_extensions_debugger(self):
        self.mode(start=[{'name': 'Borrowed', 'leaves': self.leaves()}])
        out = self.run_editor(['cmd rhun-tests/debuguser.start', 'wait 500', 'print-dialog', 'dialog yes',
                               'wait-debug ended', 'print-debug', 'wait 300'])
        session = self.debug_lines(out)[0]
        self.assertEqual(self.field(session, 'type'), 'fake', out)
        self.assertEqual(self.field(session, 'exit'), '3', out)
        self.assertIn('0 debug-ended 1 3', self.ext_log())

    def test_a_type_nobody_provides(self):
        self.mode(start=[{'leaves': [['s', 'type', 'nosuch'], ['s', 'program', 'x']]}])
        out = self.run_editor(['cmd rhun-tests/debuguser.start', 'wait 500', 'print-toast', 'print-debug'])
        self.assertTrue(any('Debugging needs a debugger for nosuch: install rhun-editor/debug' in l for l in out), out)
        self.assertTrue(any(l.startswith('error 1 missing') for l in self.ext_log()), self.ext_log())

    def test_a_type_not_listed(self):
        self.mode(start=[{'leaves': [['s', 'type', 'faketcp'], ['s', 'program', 'x']]}])
        self.run_editor(['cmd rhun-tests/debuguser.start', 'wait 500'])
        self.assertIn("error 1 refused the configuration's type is not one of your debuggers", self.ext_log())


class Feature(FeatureHost):
    def test_debug_start_runs_a_session_and_reports_its_end(self):
        self.mode(start=[{'name': 'From ext', 'leaves': self.leaves(
            args__0=('s', 'x y'), args__1=('s', '-v'), count=('n', 7), stopOnEntry=('b', 'false'),
            env__LOG=('s', 'debug'), extra=('z', ''))}])
        out = self.run_editor(['cmd rhun-tests/debugfake.start', 'wait 500', 'print-dialog', 'dialog yes',
                               'wait-debug ended', 'print-debug', 'wait 300'])
        dialog = [l for l in out if l.startswith('dialog=')][0]
        self.assertEqual(dialog, 'dialog=Let Debug Fake run programs in proj?', out)
        session = self.debug_lines(out)[0]
        self.assertEqual(self.field(session, 'name'), 'From', out)       # "From ext": print-debug cuts at spaces
        self.assertEqual(self.field(session, 'exit'), '3')
        log = self.ext_log()
        self.assertIn('ok 1 1', log)
        self.assertIn('0 debug-ended 1 3', log)
        self.assertLess(log.index('ok 1 1'), log.index('0 debug-ended 1 3'))
        args = self.args_sent()
        self.assertEqual(args['name'], 'From ext')
        self.assertEqual(args['type'], 'fake')
        self.assertEqual(args['request'], 'launch')
        self.assertEqual(args['args'], ['x y', '-v'])
        self.assertEqual(args['count'], 7)
        self.assertIs(args['stopOnEntry'], False)
        self.assertEqual(args['env'], {'LOG': 'debug'})
        self.assertIsNone(args['extra'])

    def test_declined_approval(self):
        self.mode(start=[{'leaves': self.leaves()}])
        out = self.run_editor(['cmd rhun-tests/debugfake.start', 'wait 500', 'dialog no', 'wait 300', 'print-debug'])
        self.assertIn('error 1 cancelled', self.ext_log())
        self.assertFalse(self.log.exists(), 'the adapter never started')
        self.assertEqual(self.field(self.debug_lines(out)[0], 'reason'), 'cancelled')

    def test_approved_once_per_project(self):
        self.mode(start=[{'leaves': self.leaves()}, {'leaves': self.leaves()}])
        self.run_editor(['cmd rhun-tests/debugfake.start', 'wait 500', 'dialog yes', 'wait-debug ended',
                         'cmd rhun-tests/debugfake.start', 'wait 500', 'print-dialog', 'wait-debug ended',
                         'wait 300'])
        log = self.ext_log()
        self.assertIn('ok 1 1', log)
        self.assertIn('ok 2 2', log)
        self.assertIn('0 debug-ended 2 3', log)

    def test_without_the_feature(self):
        self.mode(features='', start=[{'leaves': self.leaves()}])
        out = self.run_editor(['cmd rhun-tests/debugfake.start', 'wait 500', 'print-debug'])
        self.assertIn('error 1 unknown debug-start needs the debug feature', self.ext_log())
        self.assertEqual(self.debug_lines(out), [])

    def test_a_type_not_its_own(self):
        leaves = self.leaves()
        leaves[0] = ['s', 'type', 'go']
        self.mode(start=[{'leaves': leaves}])
        self.run_editor(['cmd rhun-tests/debugfake.start', 'wait 500'])
        self.assertIn("error 1 refused the configuration's type is not one of your debuggers", self.ext_log())

    def test_one_session_per_command(self):
        self.mode(burst=True, start=[{'leaves': self.leaves()}, {'leaves': self.leaves()}])
        self.run_editor(['cmd rhun-tests/debugfake.start', 'wait 500', 'dialog yes', 'wait-debug ended', 'wait 300'])
        log = self.ext_log()
        self.assertIn('ok 1 1', log)
        self.assertIn('error 2 refused not within 10 s of one of your commands', log)

    def test_busy_while_the_approval_is_asked(self):
        self.mode(start=[{'leaves': self.leaves()}, {'leaves': self.leaves()}])
        self.run_editor(['cmd rhun-tests/debugfake.start', 'wait 500', 'cmd rhun-tests/debugfake.start', 'wait 500',
                         'dialog yes', 'wait-debug ended', 'wait 300'])
        log = self.ext_log()
        self.assertIn('error 2 busy', log)
        self.assertIn('ok 1 1', log)

    def test_debug_stop_ends_its_session(self):
        self.mode(start=[{'leaves': self.leaves(stopOnEntry=('b', 'true'))}])
        out = self.run_editor(['cmd rhun-tests/debugfake.start', 'wait 500', 'dialog yes', 'wait-debug paused',
                               'print-debug', 'cmd rhun-tests/debugfake.stop', 'wait-debug ended', 'wait 300',
                               'print-debug'])
        sessions = self.debug_lines(out)
        self.assertEqual([self.field(l, 'state') for l in sessions], ['paused', 'ended'], out)
        log = self.ext_log()
        self.assertIn('ok 2', log)
        ended = [l for l in log if l.startswith('0 debug-ended 1 ')]
        self.assertTrue(ended, log)
        self.assertLess(log.index('ok 2'), log.index(ended[0]))
        self.assertIn('terminate', ' '.join(self.requests()))

    def test_debug_stop_only_for_its_own_sessions(self):
        self.launch_ini('[Run]\ntype = fake\nprogram = scenario.json\nstopOnEntry = yes\n')
        self.scenario()
        self.mode(stop=['1', '99', 'x', '1 2'])
        out = self.run_editor([*self.start(), 'wait-debug paused', 'cmd rhun-tests/debugfake.stop', 'wait 800',
                               'print-debug'])
        self.assertEqual(self.field(self.debug_lines(out)[0], 'state'), 'paused', out)
        log = self.ext_log()
        self.assertIn('error 1 refused not a session you started', log)
        self.assertIn('error 2 refused not a session you started', log)
        self.assertTrue([l for l in log if l.startswith('error 3 syntax')], log)
        self.assertTrue([l for l in log if l.startswith('error 4 syntax')], log)

    def test_debug_stop_without_the_feature(self):
        self.mode(features='', stop=['1'])
        self.run_editor(['cmd rhun-tests/debugfake.stop', 'wait 500'])
        self.assertIn('error 1 unknown debug-stop needs the debug feature', self.ext_log())

    def test_integer_leaves_by_value(self):
        # review: the length limit refused -9007199254740991 and let 9007199254740992 and 007 through
        self.mode(start=[{'leaves': self.leaves(count=('n', '-9007199254740991'))}])
        self.run_editor(['cmd rhun-tests/debugfake.start', 'wait 500', 'dialog yes', 'wait-debug ended', 'wait 300'])
        self.assertIn('ok 1 1', self.ext_log())
        self.assertEqual(self.args_sent()['count'], -9007199254740991)
        for pair in (('9007199254740992', '007'), ('-0', '0x1')):
            with self.subTest(pair=pair):
                (self.ext_state() / 'debugfake.log').unlink()
                self.mode(burst=True, start=[{'leaves': self.leaves(count=('n', v))} for v in pair])
                self.run_editor(['cmd rhun-tests/debugfake.start', 'wait 500'])
                errors = [l for l in self.ext_log() if l.startswith('error ')]
                self.assertEqual([l.split(' ')[2] for l in errors], ['syntax', 'syntax'], self.ext_log())

    def test_bodies_that_do_not_parse(self):
        bad = ['1\nx 4 4\ntypefake', '2\ns 4 4\ntypefake', '1\ns 4 9\ntypefake', '1\nn 5 2\ncount1x',
               '1\nb 3 3\nyesyes', '1\nz 1 1\naa', 'nope', '3\ns 4 4\ntypefakes 3 1\na.bxs 5 1\na.b.cy',
               '2\ns 4 4\ntypefakes 6 1\nargs.1x', '3\ns 4 4\ntypefakes 6 1\nargs.0xs 6 1\nargs.2y']
        # (the last two: an array that skips an index)
        # two at a time: a third syntax error in a row ends the program (v1)
        for pair in (bad[0:2], bad[2:4], bad[4:6], bad[6:8], bad[8:10]):
            with self.subTest(pair=pair):
                log = self.ext_state() / 'debugfake.log'
                if log.exists():
                    log.unlink()
                self.mode(burst=True, start=[{'raw': body} for body in pair])
                self.run_editor(['cmd rhun-tests/debugfake.start', 'wait 500'])
                errors = [l for l in self.ext_log() if l.startswith('error ')]
                self.assertEqual(len(errors), 2, self.ext_log())
                for i, line in enumerate(errors):
                    self.assertTrue(line.startswith('error %d syntax' % (i + 1)), errors)


class Resolve(FeatureHost):
    """debug-resolve: a debugger with resolve = yes shows the extension the configuration first"""

    def ini(self, extra=''):
        self.scenario()
        self.launch_ini('[Run]\ntype = fakeres\nprogram = scenario.json\ncount = 5\nargs.0 = a\n' + extra)

    def start(self, name='Run', run=False):
        """the approval comes once the extension answered"""
        return [('debug-run ' if run else 'debug-start ') + name, 'wait 800', 'dialog yes']

    def resolve_lines(self):
        return [l for l in self.ext_log() if ' debug-resolve ' in l]

    def body(self):
        line = [l for l in self.ext_log() if l.startswith('BODY ')][0]
        return json.loads(line[5:])

    def test_unchanged(self):
        self.ini()
        self.mode(resolve='unchanged')
        out = self.run_editor([*self.start(), 'wait-debug ended', 'print-debug'])
        (line,) = self.resolve_lines()
        self.assertTrue(line.endswith(' debug-resolve fakeres launch 0 %d' % len(self.body().encode())), line)
        body = self.body()
        for leaf in ('s 4 7\ntypefakeres', 'n 5 1\ncount5', 's 6 1\nargs.0a', 's 4 3\nnameRun'):
            self.assertIn(leaf, body)
        self.assertIn('context 1 1 1 %d\n%s' % (len(self.src.as_posix()), self.src.as_posix()), body)
        self.assertEqual(self.field(self.debug_lines(out)[0], 'exit'), '3', out)
        self.assertEqual(self.args_sent()['count'], 5)

    def test_replaced(self):
        self.ini()
        self.mode(resolve={'set': [['n', 'count', '9'], ['s', 'mode', 'test']], 'remove': ['args']})
        self.run_editor([*self.start(), 'wait-debug ended'])
        args = self.args_sent()
        self.assertEqual(args['count'], 9)
        self.assertEqual(args['mode'], 'test')
        self.assertNotIn('args', args)
        self.assertEqual(args['name'], 'Run')
        self.assertEqual(args['type'], 'fakeres')

    def test_run_without_debugging(self):
        self.ini()
        self.mode(resolve='unchanged')
        self.run_editor([*self.start(run=True), 'wait-debug ended'])
        self.assertTrue(self.resolve_lines()[0].split(' ')[4] == '1', self.resolve_lines())

    def test_cancelled_quietly_and_refused_with_its_text(self):
        for how, console in (('cancel', 'info Launch cancelled'), ('refuse', 'error no Go package in this folder')):
            with self.subTest(how=how):
                self.ini()
                self.mode(resolve=how)
                out = self.run_editor(['debug-start Run', 'wait 800', 'print-debug', 'print-dialog', 'print-console'])
                self.assertEqual(self.debug_lines(out), [], out)
                self.assertIn('dialog=none', out)          # nothing runs, nothing is asked
                self.assertIn(console, out)
                self.assertFalse(self.log.exists())

    def test_an_answer_that_does_not_parse(self):
        self.ini()
        self.mode(resolve='garbage')
        out = self.run_editor(['debug-start Run', 'wait 800', 'print-console'])
        self.assertTrue(any(l.startswith('error the debugger\'s extension answered with a configuration') for l in out), out)

    def test_stop_while_it_prepares(self):
        self.ini()
        self.mode(resolve='silent')
        out = self.run_editor(['debug-start Run', 'wait 500', 'debug-start Run', 'debug-stop', 'wait 300',
                               'print-console', 'print-debug'])
        self.assertIn('error a launch is being prepared by its debugger\'s extension', out)
        self.assertIn('info Launch cancelled', out)
        rid = self.resolve_lines()[0].split(' ')[0]
        self.assertIn('0 cancel %s' % rid, self.ext_log())

    def test_counted_on_the_extensions_page(self):
        self.ini()
        self.mode(resolve='unchanged')
        out = self.run_editor([*self.start(), 'wait-debug ended', 'print-langstats rhun-tests/debugfake'])
        row = [l for l in out if ' debug-resolve ' in l][0]
        self.assertIn(' asked=1 ', row)
        self.assertIn(' empty=1 ', row)                 # ok ID 0: launched unchanged
        self.mode(resolve='silent')
        out = self.run_editor(['debug-start Run', 'wait 500', 'debug-stop', 'wait 200',
                               'print-langstats rhun-tests/debugfake'])
        row = [l for l in out if ' debug-resolve ' in l][0]
        self.assertIn(' cancelled=1', row)

    def test_an_extension_that_crashes(self):
        self.ini()
        self.mode(resolve='crash')
        out = self.run_editor(['debug-start Run', 'wait 1000', 'print-console'])
        self.assertIn("error the debugger's extension stopped while it prepared the launch", out)

    def test_without_the_feature(self):
        self.ini()
        self.mode(features='', resolve='unchanged')
        out = self.run_editor(['debug-start Run', 'wait 800', 'print-console'])
        self.assertIn('error the extension does not answer debug-resolve (feature debug not agreed)', out)


if __name__ == '__main__':
    unittest.main()
