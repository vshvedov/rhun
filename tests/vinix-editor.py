#!/usr/bin/env python3
"""Core editor qualification inside the Vinix guest, without agent dependencies.

RHUN_TEST_EXE=/path/to/rhun-native python3 tests/vinix-editor.py [--native]
The native mode opens temporary desktop windows and uses their control sockets.
"""
import argparse
import importlib.util
import os
from pathlib import Path
import signal
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location('vinix_' + name.replace('-', '_'),
                                                 ROOT / 'tests' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native', action='store_true')
    parser.add_argument('cases', nargs='*', help='run only these test method names')
    args = parser.parse_args()
    executable = Path(os.environ.get('RHUN_TEST_EXE', ROOT / 'build/vinix/rhun')).resolve()
    if not executable.is_file():
        parser.error('set RHUN_TEST_EXE to the guest editor binary')
    os.environ['RHUN_TEST_EXE'] = str(executable)
    os.environ['RHUN_TEST_NATIVE'] = '1' if args.native else '0'
    reload = load('live-reload')

    class CoreEditing(reload.LiveReload):
        def write_with_same_stamp(self):
            # Keep the notification queued until the timestamp is restored, so
            # the old metadata shortcut cannot pass through a scheduling race.
            stamp = self.file.stat()
            os.kill(self.process.pid, signal.SIGSTOP)
            _, status = os.waitpid(self.process.pid, os.WUNTRACED)
            self.assertTrue(os.WIFSTOPPED(status))
            try:
                self.external_write('after!\n')
                os.utime(self.file, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
            finally:
                os.kill(self.process.pid, signal.SIGCONT)

        @unittest.skipIf(sys.platform == 'darwin', 'Vinix coarse timestamp compatibility')
        def test_same_stamp_same_size_write_reloads(self):
            self.start(self.file)
            self.write_with_same_stamp()
            self.wait_document('after!\n')

        @unittest.skipIf(sys.platform == 'darwin', 'Vinix coarse timestamp compatibility')
        def test_same_stamp_conflict_keeps_local_edits(self):
            self.start(self.file)
            self.command('type local_')
            self.write_with_same_stamp()
            self.settle()
            self.assertEqual(self.document(), 'local_before\n')
            self.command('cmd undo')
            self.wait_document('after!\n')

        @unittest.skipIf(sys.platform == 'darwin', 'Vinix coarse timestamp compatibility')
        def test_same_stamp_settings_apply_live(self):
            config = self.work / 'config/rhun/config'
            text = config.read_text().replace('[editor]\n', '[editor]\nvim_mode = false\n')
            config.write_text(text)
            self.start(self.file)
            stamp = config.stat()
            for enabled, key, expected in ((True, 'x', 'efore\n'),
                                           (False, 'y', 'yefore\n')):
                os.kill(self.process.pid, signal.SIGSTOP)
                _, status = os.waitpid(self.process.pid, os.WUNTRACED)
                self.assertTrue(os.WIFSTOPPED(status))
                try:
                    config.write_text(text.replace('vim_mode = false',
                                                   'vim_mode = ' + str(enabled).lower()))
                    os.utime(config, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
                finally:
                    os.kill(self.process.pid, signal.SIGCONT)
                self.command('wait 200')
                self.command('type ' + key)
                self.assertEqual(self.document(), expected)

        def test_empty_file_reloads_after_confirmation(self):
            self.start(self.file)
            self.external_write('')
            self.wait_document('')
            self.assertIn('dirty=0', self.command('print-state'))

        def test_save_notification_keeps_new_local_edits(self):
            self.start(self.file)
            self.command('type saved_')
            self.command('cmd save')
            self.command('type local_')
            self.settle()
            self.assertEqual(self.document(), 'saved_local_before\n')
            if not args.native:
                self.assertEqual(self.warning_strip(self.shot('own-save')).count(bytes.fromhex('f2c46f')), 0)

        def test_conflict_preserves_edits_and_undo_loads_disk(self):
            self.start(self.file)
            self.command('type local_')
            self.external_write('external café\n')
            self.settle()
            self.assertEqual(self.document(), 'local_before\n')
            self.assertIn('dirty=1', self.command('print-state'))
            self.command('cmd undo')
            self.wait_document('external café\n')
            self.assertIn('dirty=0', self.command('print-state'))

        def test_unicode_save_and_terminal(self):
            self.start(self.file)
            self.command('type café 日本 🙂_')
            self.command('cmd save')
            self.assertEqual(self.file.read_text(), 'café 日本 🙂_before\n')
            self.assertIn('dirty=0', self.command('print-state'))
            self.command('cmd toggle_terminal')
            self.command('wait 300')
            self.command("type printf 'vinix-%s\\n' $((6 * 7))")
            self.command('key Return')
            self.command('wait-term vinix-42')
            self.assertIn('vinix-42', self.command('print-term'))

    suite = unittest.TestSuite()
    if args.native:
        for name in (
            'quick_open_reloads_in_place_and_atomic_writes', 'command_line_reloads',
            'directory_alias_reloads', 'background_tab_reloads_without_switching',
            'save_as_in_new_directory_reloads', 'restored_session_reloads',
            'reload_undo_and_redo_preserve_unchanged_text',
            'symlink_reloads_when_the_file_it_leads_to_changes',
        ):
            suite.addTest(reload.LiveReload('test_' + name))
        for name in ('conflict_preserves_edits_and_undo_loads_disk', 'unicode_save_and_terminal'):
            suite.addTest(CoreEditing('test_' + name))
    else:
        for name, cls in (('live-reload', 'LiveReload'), ('git-untracked', 'GitUntracked'),
                          ('git-reset', 'GitReset')):
            module = reload if name == 'live-reload' else load(name)
            suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(getattr(module, cls)))
        editor = load('editor-matrix')
        for name in ('find_buttons_case_previous_next_and_close',
                     'replace_one_and_all_buttons_and_undo',
                     'closing_settings_restores_document_input',
                     'close_all_tabs_asks_for_each_modified_file'):
            suite.addTest(editor.EditorMatrix('test_' + name))
    for name in ('same_stamp_same_size_write_reloads', 'same_stamp_conflict_keeps_local_edits',
                 'same_stamp_settings_apply_live',
                 'empty_file_reloads_after_confirmation', 'save_notification_keeps_new_local_edits'):
        suite.addTest(CoreEditing('test_' + name))
    if args.cases:
        def cases(group):
            for item in group:
                if isinstance(item, unittest.TestSuite):
                    yield from cases(item)
                else:
                    yield item
        selected = [case for case in cases(suite) if case._testMethodName in args.cases]
        missing = set(args.cases) - {case._testMethodName for case in selected}
        if missing:
            parser.error('unknown test methods: ' + ', '.join(sorted(missing)))
        suite = unittest.TestSuite(selected)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    raise SystemExit(main())
