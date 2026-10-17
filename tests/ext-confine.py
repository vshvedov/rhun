#!/usr/bin/env python3
"""Confinement of extension processes (docs/extensions/v1.md section 5): the echo extension probes
what it may do under each [needs] shape, and the editor's print-extensions says how it is held.
Where the kernel cannot confine (no Landlock, as in Docker Desktop's VM or under Rosetta), a
--extensions session runs the program unconfined and says so: those cases are skipped, not
passed. Run on a native x86-64 Linux or on macOS for the real thing."""
import os
from pathlib import Path
import sys
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
