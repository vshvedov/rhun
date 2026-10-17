#!/usr/bin/env python3
"""The extension host (docs/extensions/v1.md, gate 1), driven headlessly with the echo extension
(tests/ext/echo.py): discovery and commands before any process exists, the handshake with its
catch-up, versioned edits, the error replies, and the ways a program can misbehave without
taking the editor with it. Each run gets its own HOME and config; ECHO_MODE and ECHO_LOG reach
the extension through the environment (a --extensions session inherits rhun's)."""
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
EXE = Path(os.environ.get('RHUN_TEST_EXE', ROOT / 'build/rhun')).resolve()
EXTS = ROOT / 'tests/ext/exts'


def ppm_colors(path):
    """The set of (r, g, b) colors in a binary PPM screenshot."""
    data = path.read_bytes()
    fields, pos = [], 0
    while len(fields) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        start = pos
        while not data[pos:pos + 1].isspace():
            pos += 1
        fields.append(data[start:pos])
    pixels = data[pos + 1:]
    return {tuple(pixels[i:i + 3]) for i in range(0, len(pixels) - 2, 3)}


def ppm_pixel(path, x, y):
    """The (r, g, b) at x, y of a binary PPM screenshot."""
    data = path.read_bytes()
    fields, pos = [], 0
    while len(fields) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        start = pos
        while not data[pos:pos + 1].isspace():
            pos += 1
        fields.append(data[start:pos])
    width = int(fields[1])
    i = pos + 1 + 3 * (y * width + x)
    return tuple(data[i:i + 3])


def alive(pid):
    """Whether a process with this id is running (os.kill(pid, 0) does not work on Windows)."""
    if os.name == 'nt':
        import ctypes
        kernel32 = ctypes.windll.kernel32
        handle = kernel32.OpenProcess(0x1000, False, pid)      # PROCESS_QUERY_LIMITED_INFORMATION
        if not handle:
            return False
        code = ctypes.c_ulong()
        kernel32.GetExitCodeProcess(handle, ctypes.byref(code))
        kernel32.CloseHandle(handle)
        return code.value == 259                                # STILL_ACTIVE
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True

CONFIG = ('[ui]\nsidebar = false\nagents_panel = false\n[editor]\ncursor_blink = false\n'
          '[files]\nrestore_session = false\nrestore_project = false\n'
          '[updates]\ncheck = false\n[git]\nenabled = false\n')
CMDS = ('echo.shout,echo.hi,echo.toast,echo.stale,echo.status,echo.open,echo.bad,echo.mb,echo.sel,echo.relopen,'
        'echo.diag,echo.nodiag,echo.baddiag,echo.stalediag,echo.reg,echo.opt,echo.optoff,echo.optsave,'
        'echo.badopt,echo.choose,echo.ask,echo.term,echo.cmd,echo.badcmd,echo.die,echo.termcmd,echo.emptymark,'
        'echo.countdiag,echo.bidi,echo.first,echo.pwrite,echo.hread,echo.swrite,echo.net,echo.exec,echo.greet,'
        'echo.view,echo.badview,echo.unview,echo.manyviews,echo.staleview,echo.faredit,echo.apply,echo.applystale,'
        'echo.applyoverlap')


class Host(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rhun-ext-')
        self.work = Path(self.tmp.name).resolve()
        self.proj = self.work / 'proj'
        self.proj.mkdir()
        (self.proj / 'a.txt').write_text('hello world\nsecond line\n', encoding='utf-8')
        (self.proj / 'b.go').write_text('package b\n', encoding='utf-8')
        (self.proj / 'u.txt').write_text('héllo\n', encoding='utf-8')   # é is two bytes
        config = self.work / 'config/rhun/config'
        config.parent.mkdir(parents=True)
        config.write_text(CONFIG, encoding='utf-8')
        # the log lives in the extension's state folder: that is where a confined program may write
        self.log = self.work / 'state/rhun/extensions/rhun-tests--echo/echo.log'
        self.env = dict(os.environ, HOME=self.work.as_posix(),
                        XDG_CONFIG_HOME=(self.work / 'config').as_posix(),
                        XDG_STATE_HOME=(self.work / 'state').as_posix(),
                        ECHO_LOG=self.log.as_posix())
        self.env.pop('ECHO_MODE', None)

    def tearDown(self):
        self.tmp.cleanup()

    def run_editor(self, actions, mode=None, exts=EXTS, files=('a.txt',), drop_waits=False):
        env = dict(self.env)
        if mode:
            env['ECHO_MODE'] = mode
        opens = ['open ' + (self.proj / name).as_posix() for name in files]
        script = self.work / 'actions.rsc'
        script.write_text('\n'.join(['wait 100', *opens, *actions, 'quit']) + '\n', encoding='utf-8')
        result = subprocess.run([str(EXE), self.proj.as_posix(), '--headless', '1000x600', '--scale', '1',
                                 '--extensions', str(exts), '--script', script.as_posix()],
                                env=env, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
        lines = result.stdout.decode('utf-8', errors='replace').splitlines()
        if drop_waits:
            lines = [l for l in lines if not l.startswith('ext=')]
        return lines

    def echo_log(self, settings=False):
        lines = self.log.read_text(encoding='utf-8', errors='replace').splitlines() if self.log.exists() else []
        return [line for line in lines if not line.startswith('pid ')
                and (settings or not line.startswith('0 setting '))]

    def state_lines(self, out):
        return [line for line in out if line.startswith('rhun-tests/echo ')]

    # --- discovery and commands ---

    def test_manifest_commands_exist_before_any_process(self):
        out = self.run_editor(['print-extensions', 'print-palette'])
        self.assertEqual(out[0], f'rhun-tests/echo state=idle pid=0 cmds={CMDS} confined=0')
        self.assertFalse(self.log.exists(), 'no process was started')

    def test_a_folder_without_manifests_is_fine(self):
        empty = self.work / 'none'
        empty.mkdir()
        out = self.run_editor(['print-extensions', 'print-state'], exts=empty)
        self.assertTrue(out[0].startswith('tabs=1'), out)

    def test_bad_manifests_are_reported_not_fatal(self):
        bad = self.work / 'bad'
        (bad / 'o' / 'notitle').mkdir(parents=True)
        (bad / 'o' / 'notitle' / 'extension.ini').write_text('name = notitle\nowner = o\nversion = 1\nprotocol = 1\nruntime = python3\nrun = x.py\n', encoding='utf-8')
        (bad / 'o' / 'v2').mkdir(parents=True)
        (bad / 'o' / 'v2' / 'extension.ini').write_text('name = v2\nowner = o\nversion = 1\ntitle = V2\nprotocol = 2\nruntime = python3\nrun = x.py\n', encoding='utf-8')
        (bad / 'o' / 'noprog').mkdir(parents=True)
        (bad / 'o' / 'noprog' / 'extension.ini').write_text('name = noprog\nowner = o\nversion = 1\ntitle = No\nprotocol = 1\nrun.linux-x86_64 = none\nrun.macos-arm64 = none\nrun.windows-x64 = none\n', encoding='utf-8')
        (bad / 'o' / 'nortl').mkdir(parents=True)
        (bad / 'o' / 'nortl' / 'extension.ini').write_text('name = nortl\nowner = o\nversion = 1\ntitle = No\nprotocol = 1\nruntime = no-such-runtime-xyz\nrun = x.py\n', encoding='utf-8')
        out = self.run_editor(['print-extensions'], exts=bad)
        states = sorted(line for line in out if line.startswith('o/'))
        self.assertIn('o/noprog state=failed reason=program file missing pid=0 cmds= confined=0', states)
        self.assertIn('o/nortl state=failed reason=runtime not found on PATH pid=0 cmds= confined=0', states)
        self.assertIn('o/notitle state=failed reason=extension.ini has no title pid=0 cmds= confined=0', states)
        self.assertIn('o/v2 state=failed reason=protocol version not supported (rhun speaks 1) pid=0 cmds= confined=0', states)

    # --- handshake and events ---

    def test_overlong_program_names_fail_without_starting(self):
        for field, value in (('runtime = python3', 'runtime = ' + 'x' * 100000),
                             ('project = read', 'project = read\nrun = ' + 'x' * 100000)):
            with self.subTest(field=field):
                exts = self.manifest_variant('long-name-' + field.split()[0], **{field: value})
                out = self.run_editor(['cmd echo.toast', 'ext-set echo restart', 'wait 100',
                                       'print-extensions'], exts=exts)
                self.assertIn('state=failed', self.state_lines(out)[0])
                self.assertIn('pid=0', self.state_lines(out)[0])

    def test_protocol_open_obeys_disk_permissions(self):
        secret = self.work / 'secret.txt'
        secret.write_text('private\n', encoding='utf-8')
        self.env['ECHO_OPEN'] = secret.as_posix()
        out = self.run_editor(['cmd echo.open', 'wait-ext echo running', 'wait 300', 'print-tabs'])
        self.assertIn('error 1 needs file=read', self.echo_log())
        self.assertIn('tabs=*a.txt', out)
        # An already-open file belongs to documents permission, even outside the project.
        out = self.run_editor(['cmd echo.open', 'wait-ext echo running', 'wait 300', 'print-tabs'],
                              files=('a.txt', secret.as_posix()))
        self.assertIn('tabs=a.txt | *secret.txt', out)
        # Explicit home permission allows a closed file there.
        exts = self.manifest_variant('home-open', **{'project = read': 'home = read'})
        out = self.run_editor(['cmd echo.open', 'wait-ext echo running', 'wait 300', 'print-tabs'], exts=exts)
        self.assertIn('tabs=a.txt | *secret.txt', out)

    @unittest.skipIf(os.name == 'nt', 'creating symlinks requires Windows developer mode')
    def test_protocol_open_cannot_follow_a_project_link_outside_its_permissions(self):
        secret = self.work / 'secret.txt'
        secret.write_text('private\n', encoding='utf-8')
        (self.proj / 'outside').symlink_to(self.work, target_is_directory=True)
        self.env['ECHO_OPEN'] = (self.proj / 'outside/secret.txt').as_posix()
        out = self.run_editor(['cmd echo.open', 'wait-ext echo running', 'wait 300', 'print-tabs'])
        self.assertIn('error 1 needs file=read', self.echo_log())
        self.assertIn('tabs=*a.txt', out)

    def test_project_switch_restarts_with_the_new_project(self):
        other = self.work / 'next'
        other.mkdir()
        exts = self.manifest_variant('project-switch', **{'project = read': 'project = write'})
        out = self.run_editor(['cmd echo.toast', 'wait-ext echo running', 'wait 200',
                               'cmd open_folder', 'key ctrl+a', 'type ' + other.as_posix(), 'key ctrl+Return',
                               'wait 300', 'wait-ext echo running', 'wait 300', 'cmd echo.pwrite',
                               'wait 300', 'print-toast'], exts=exts)
        self.assertIn('toast=probe ok', out)
        self.assertTrue((other / 'written-by-echo.txt').exists())
        self.assertFalse((self.proj / 'written-by-echo.txt').exists())
        log = self.echo_log()
        self.assertIn('0 project ' + other.as_posix(), log)
        self.assertIn('0 ready ' + other.as_posix(), log)

    def test_a_command_starts_the_program_and_catch_up_lists_the_open_tabs(self):
        out = self.run_editor(['cmd echo.toast', 'wait-ext echo running', 'wait 300', 'print-toast',
                               'print-extensions'], files=('a.txt', 'b.go'))
        self.assertEqual(out[0], 'ext=echo state=running')
        self.assertEqual(out[1], 'toast=hello there')
        log = self.echo_log()
        self.assertTrue(log[0].startswith('0 ready ' + self.proj.as_posix()), log)
        self.assertEqual(log[1], '0 opened 1 0 - ' + (self.proj / 'a.txt').as_posix())
        self.assertEqual(log[2], '0 opened 2 0 Go ' + (self.proj / 'b.go').as_posix())
        self.assertEqual(log[3], '0 active 2')
        self.assertEqual(log[4], '0 cursor 2 1 1')
        self.assertEqual(log[5], '0 run echo.toast 2')
        self.assertEqual(log[6], 'ok 1')

    def test_typing_saving_and_closing_are_reported(self):
        out = self.run_editor(['cmd echo.toast', 'wait-ext echo running', 'wait 100', 'type xy', 'wait 100',
                               'key ctrl+s', 'wait 200', 'cmd close_tab', 'wait 200', 'print-extensions'])
        self.assertEqual(out[0], 'ext=echo state=running')
        log = self.echo_log()
        self.assertIn('0 changed 1 2', log)     # two keystrokes, one event per frame
        self.assertIn('0 cursor 1 1 3', log)
        saved = [line for line in log if line.startswith('0 saved 1 ')]
        self.assertEqual(len(saved), 1, log)
        self.assertIn('0 closed 1', log)
        self.assertIn('0 active 0', log)

    def test_hello_arrives_before_the_pending_command(self):
        # the command that started the program is delivered after ready and catch-up
        self.run_editor(['cmd echo.hi', 'wait-ext echo running', 'wait 300', 'print-doc'])
        log = self.echo_log()
        self.assertEqual(log[3], '0 cursor 1 1 1')
        self.assertEqual(log[4], '0 run echo.hi 1')

    # --- requests ---

    def test_insert_text_replace_and_the_version_in_replies(self):
        out = self.run_editor(['cmd echo.hi', 'wait-ext echo running', 'wait 300', 'print-doc',
                               'cmd echo.shout', 'wait 400', 'print-doc', 'print-state'])
        self.assertEqual(out[1:3], ['hihello world', 'second line'])
        self.assertEqual(out[5:7], ['HIHELLO WORLD', 'SECOND LINE'])
        self.assertIn('dirty=1', out[-1])
        log = self.echo_log()
        self.assertIn('ok 1 1', log, 'insert replied with the new version')
        self.assertIn('0 changed 1 1', log)
        text_reply = [line for line in log if line.startswith('ok 2 ')]
        self.assertEqual(text_reply, ['ok 2 1 26'])

    def test_an_extension_edit_is_one_undo_step(self):
        out = self.run_editor(['cmd echo.shout', 'wait-ext echo running', 'wait 400', 'print-doc',
                               'cmd undo', 'print-doc'])
        self.assertEqual(out[1:3], ['HELLO WORLD', 'SECOND LINE'])
        self.assertEqual(out[5:7], ['hello world', 'second line'])

    def test_a_stale_version_is_refused(self):
        self.run_editor(['cmd echo.toast', 'wait-ext echo running', 'wait 100', 'type z', 'wait 100',
                         'cmd echo.stale', 'wait 300', 'print-doc'])
        log = self.echo_log()
        self.assertIn('error 2 stale 1', log)

    def test_a_bad_position_is_refused(self):
        self.run_editor(['cmd echo.bad', 'wait-ext echo running', 'wait 300'])
        log = self.echo_log()
        self.assertTrue(any(line.startswith('error 1 badpos') for line in log), log)

    def test_status_text_shows_in_print_extensions(self):
        out = self.run_editor(['cmd echo.status', 'wait-ext echo running', 'wait 300', 'print-extensions'])
        self.assertTrue(out[1].endswith(' status=echo ok'), out)

    def test_open_request_opens_a_tab_at_a_line(self):
        self.env['ECHO_OPEN'] = (self.proj / 'b.go').as_posix()
        out = self.run_editor(['cmd echo.open', 'wait-ext echo running', 'wait 400', 'print-tabs', 'print-state'])
        self.assertEqual(out[1], 'tabs=a.txt | *b.go')
        self.assertIn('line=2', out[2])      # b.go ends in a newline: line 2 is its empty last line
        log = self.echo_log()
        self.assertIn('ok 1 2', log)
        self.assertIn('0 opened 2 0 Go ' + (self.proj / 'b.go').as_posix(), log)

    def test_a_needs_refusal(self):
        ro = self.work / 'ro'
        dst = ro / 'rhun-tests' / 'echo'
        dst.mkdir(parents=True)
        manifest = (EXTS / 'rhun-tests/echo/extension.ini').read_text(encoding='utf-8')
        manifest = manifest.replace('documents = write', 'documents = none')
        manifest = manifest.replace('run = ../../../echo.py', 'run = ' + (ROOT / 'tests/ext/echo.py').as_posix())
        (dst / 'extension.ini').write_text(manifest, encoding='utf-8')
        self.run_editor(['cmd echo.hi', 'wait-ext echo running', 'wait 300', 'print-doc'], exts=ro)
        log = self.echo_log()
        self.assertIn('error 1 needs documents=write', log)

    # --- misbehaviour ---

    def test_no_hello_within_five_seconds(self):
        out = self.run_editor(['cmd echo.toast', 'wait 5500', 'print-extensions'], mode='nohello')
        self.assertIn('state=stopped reason=no hello within 5 s', out[0])

    def test_a_late_hello_is_too_late(self):
        out = self.run_editor(['cmd echo.toast', 'wait 5500', 'print-extensions'], mode='slowhello')
        self.assertIn('state=stopped reason=no hello within 5 s', out[0])

    def test_another_protocol_version(self):
        out = self.run_editor(['cmd echo.toast', 'wait 400', 'print-extensions'], mode='badhello')
        self.assertIn('state=stopped reason=protocol version not supported', out[0])

    def test_three_crashes_stop_it(self):
        out = self.run_editor(['cmd echo.toast', 'wait 400', 'print-extensions', 'cmd echo.toast', 'wait 400',
                               'print-extensions', 'cmd echo.toast', 'wait 400', 'print-extensions',
                               'cmd echo.toast', 'wait 400', 'print-extensions'], mode='crash')
        states = self.state_lines(out)
        self.assertIn('state=crashed reason=exited with status 3', states[0])
        self.assertIn('state=crashed reason=exited with status 3', states[1])
        self.assertIn('state=stopped reason=crashed three times within a minute', states[2])
        self.assertIn('state=stopped reason=crashed three times within a minute', states[3])

    def test_a_sleeping_program_costs_nothing(self):
        out = self.run_editor(['cmd echo.toast', 'wait-ext echo running', 'print-frames', 'type abc',
                               'wait 300', 'print-frames', 'print-doc', 'print-extensions'], mode='sleep')
        self.assertEqual(out[0], 'ext=echo state=running')
        self.assertEqual(out[3], 'abchello world')
        self.assertIn('state=running', out[-1])

    @unittest.skipIf(os.environ.get('RHUN_SLOW_MACHINE'), 'an emulated flooder is too slow to flood')
    def test_a_flood_ends_the_program_and_frames_keep_coming(self):
        # 30 busy windows of 16 ms in a row is half a second; a busy runner can give the flooder a
        # quiet window now and then, which starts the count again, so after the 3 s the test also
        # waits for the stop (up to 10 s more)
        out = self.run_editor(['cmd echo.toast', 'wait-ext echo running', 'wait 3000', 'wait-ext echo stopped',
                               'print-frames',
                               'print-extensions', 'type ok', 'print-doc'], mode='flood')
        self.assertEqual(out[0], 'ext=echo state=running')
        frames = int(out[2].split('=')[1])
        self.assertGreater(frames, 5, out)
        self.assertIn('state=stopped reason=flooding', out[3])
        self.assertEqual(out[4], 'okhello world')

    def test_a_program_that_never_reads_is_stopped(self):
        # whichever rule trips first: the message cap, or the queue it never drains; on a busy runner
        # a quiet window can restart the flood count, so after the 11 s it may take up to 10 s more
        out = self.run_editor(['cmd echo.toast', 'wait-ext echo running', 'wait 11000', 'wait-ext echo stopped',
                               'print-extensions', 'type ok', 'print-doc'], mode='floodnoread')
        self.assertTrue('reason=not reading for 10 s' in out[2] or 'reason=flooding' in out[2], out[2])
        self.assertIn('state=stopped', out[2])
        self.assertEqual(out[3], 'okhello world')

    def test_garbage_without_a_newline(self):
        out = self.run_editor(['cmd echo.toast', 'wait 600', 'print-extensions'], mode='garbage')
        self.assertIn('state=stopped reason=a line over 64 KB without an end', out[0])

    def test_closing_its_output_ends_it(self):
        out = self.run_editor(['cmd echo.toast', 'wait 600', 'print-extensions'], mode='eof')
        self.assertIn('state=crashed reason=exited with status 137', out[0])

    def test_three_unparsable_lines(self):
        out = self.run_editor(['cmd echo.toast', 'wait 600', 'print-extensions'], mode='syntax')
        self.assertIn('state=stopped reason=three unparsable lines in a row', out[0])

    def test_fragmented_writes_are_reassembled(self):
        out = self.run_editor(['cmd echo.hi', 'wait-ext echo running', 'wait 800', 'print-doc'], mode='fragment')
        self.assertEqual(out[1], 'hihello world')

    def test_a_manifest_key_runs_the_command(self):
        out = self.run_editor(['key ctrl+alt+shift+u', 'wait-ext echo running', 'wait 400', 'print-doc'])
        self.assertEqual(out[1:3], ['HELLO WORLD', 'SECOND LINE'])

    def test_catch_up_includes_the_cursor_of_the_active_tab(self):
        self.run_editor(['key ctrl+g', 'type 2', 'key Return', 'cmd echo.toast', 'wait-ext echo running', 'wait 300'])
        log = self.echo_log()
        self.assertEqual(log[2:4], ['0 active 1', '0 cursor 1 2 1'])

    def test_a_change_then_a_save_within_one_frame_report_both(self):
        self.run_editor(['cmd echo.toast', 'wait-ext echo running', 'wait 100', 'type q', 'key ctrl+s', 'wait 300'])
        log = self.echo_log()
        changed = log.index('0 changed 1 1')
        self.assertEqual(log[changed + 1:changed + 3], ['0 saved 1 1', '0 cursor 1 1 2'])

    def test_a_collapsing_selection_is_reported_as_empty(self):
        sel = self.work / 'sel'
        dst = sel / 'rhun-tests' / 'echo'
        dst.mkdir(parents=True)
        manifest = (EXTS / 'rhun-tests/echo/extension.ini').read_text(encoding='utf-8')
        manifest = manifest.replace('cursor = *', 'cursor = no\nselection = *')
        manifest = manifest.replace('run = ../../../echo.py', 'run = ' + (ROOT / 'tests/ext/echo.py').as_posix())
        (dst / 'extension.ini').write_text(manifest, encoding='utf-8')
        self.run_editor(['cmd echo.toast', 'wait-ext echo running', 'wait 100', 'key shift+Right', 'wait 100',
                         'key Left', 'wait 300'], exts=sel)
        log = self.echo_log()
        self.assertIn('0 selection 1 1 1 1 2', log)
        self.assertIn('0 selection 1 1 1 1 1', log)

    def test_a_late_hello_is_caught_without_other_activity(self):
        # nothing else wakes the loop: the deadline itself must
        out = self.run_editor(['cmd echo.toast', 'wait 8000', 'print-extensions'], mode='slowhello')
        self.assertIn('state=stopped reason=no hello within 5 s', out[0])

    def test_three_requests_with_bad_arguments(self):
        out = self.run_editor(['cmd echo.toast', 'wait 600', 'print-extensions'], mode='badargs')
        self.assertIn('state=stopped reason=three unparsable lines in a row', out[0])

    def test_the_error_log_is_kept_under_its_cap(self):
        out = self.run_editor(['cmd echo.toast', 'wait-ext echo running', 'wait 2500', 'print-extensions'], mode='noisy')
        self.assertIn('state=running', out[1])
        logs = list((self.work / 'state/rhun/extensions').glob('*.log'))
        self.assertEqual(len(logs), 1, logs)
        self.assertLess(logs[0].stat().st_size, 1024 * 1024 + 65536)

    def test_a_stopped_extension_is_not_restarted_by_its_command(self):
        out = self.run_editor(['cmd echo.toast', 'wait 400', 'cmd echo.toast', 'wait 400', 'cmd echo.toast', 'wait 400',
                               'print-extensions', 'cmd echo.toast', 'wait 400', 'print-extensions', 'print-toast'],
                              mode='crash')
        states = self.state_lines(out)
        self.assertIn('state=stopped reason=crashed three times within a minute', states[0])
        self.assertIn('pid=0', states[1])
        self.assertEqual(out[-1], 'toast=crashed three times within a minute')

    def test_a_position_inside_a_character_is_refused(self):
        self.run_editor(['cmd echo.mb', 'wait-ext echo running', 'wait 300'], files=('u.txt',))
        log = self.echo_log()
        self.assertTrue(any(line.startswith('error 1 badpos') for line in log), log)

    def test_select_then_range(self):
        out = self.run_editor(['cmd echo.sel', 'wait-ext echo running', 'wait 400', 'print-state'])
        self.assertIn('line=1 col=6 sel=5', out[1])
        log = self.echo_log()
        self.assertIn('ok 1', log)
        self.assertIn('ok 2 0 5', log)
        self.assertIn('hello', log)

    def test_redo_after_an_extension_edit(self):
        out = self.run_editor(['cmd echo.shout', 'wait-ext echo running', 'wait 400', 'cmd undo', 'cmd redo', 'print-doc'])
        self.assertEqual(out[1:3], ['HELLO WORLD', 'SECOND LINE'])

    def test_a_relative_open_is_inside_the_project(self):
        out = self.run_editor(['cmd echo.relopen', 'wait-ext echo running', 'wait 400', 'print-tabs'])
        self.assertEqual(out[1], 'tabs=a.txt | *b.go')

    def manifest_variant(self, folder, **changes):
        dst = self.work / folder / 'rhun-tests' / 'echo'
        dst.mkdir(parents=True)
        manifest = (EXTS / 'rhun-tests/echo/extension.ini').read_text(encoding='utf-8')
        manifest = manifest.replace('run = ../../../echo.py', 'run = ' + (ROOT / 'tests/ext/echo.py').as_posix())
        for old, new in changes.items():
            manifest = manifest.replace(old, new)
        (dst / 'extension.ini').write_text(manifest, encoding='utf-8')
        return self.work / folder

    def test_lang_activation_starts_on_a_matching_document(self):
        exts = self.manifest_variant('lang', **{'on = command': 'on = lang:Go'})
        out = self.run_editor(['wait 300', 'print-extensions'], exts=exts)
        self.assertIn('state=idle', out[0])
        out = self.run_editor(['wait-ext echo running', 'print-extensions'], exts=exts, files=('a.txt', 'b.go'))
        self.assertEqual(out[0], 'ext=echo state=running')

    def test_startup_activation(self):
        exts = self.manifest_variant('startup', **{'on = command': 'on = startup'})
        out = self.run_editor(['wait-ext echo running', 'print-extensions'], exts=exts)
        self.assertEqual(out[0], 'ext=echo state=running')
        log = self.echo_log()
        self.assertTrue(log[0].startswith('0 ready '), log)

    def test_hello_features_are_said_back_before_ready(self):
        self.run_editor(['cmd echo.toast', 'wait-ext echo running', 'wait 300'], mode='features')
        log = self.echo_log()
        self.assertEqual(log[0], '0 features views complete')
        self.assertTrue(log[1].startswith('0 ready '), log)

    # --- views (section 12a) ---

    def view_at(self, out):
        line = next(l for l in out if l.startswith('view='))
        x, y = line.split(' at=')[1].split(',')
        return line, int(x), int(y)

    def test_a_view_draws_every_shape(self):
        shot = self.work / 'view.ppm'
        out = self.run_editor(['cmd echo.view', 'wait-ext echo running', 'wait 300', 'wait 300', 'print-views',
                               'print-tabs', 'shot ' + shot.as_posix()], mode='views')
        line, _, _ = self.view_at(out)
        self.assertTrue(line.startswith('view=1 title=Echo picture shapes=12 size='), line)
        self.assertIn('tabs=a.txt | *Echo picture', out)
        colors = ppm_colors(shot)
        for color in ((255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0), (255, 0, 255), (0, 255, 255),
                      (255, 128, 0), (128, 0, 255), (128, 64, 0)):
            self.assertIn(color, colors)
        log = self.echo_log()
        self.assertIn('0 features views', log)
        self.assertTrue(any(l.startswith('0 view 1 size ') for l in log), log)
        metrics = next(l for l in log if l.startswith('0 view 1 metrics '))
        self.assertRegex(metrics, r'^0 view 1 metrics small [0-9.]+ [0-9.]+ normal [0-9.]+ [0-9.]+ '
                                  r'large [0-9.]+ [0-9.]+ mono [0-9.]+ [0-9.]+$')

    def test_a_view_hears_the_pointer_and_its_closing(self):
        out = self.run_editor(['cmd echo.view', 'wait-ext echo running', 'wait 300', 'wait 300', 'print-views'],
                              mode='views')
        _, x, y = self.view_at(out)
        self.run_editor(['cmd echo.view', 'wait-ext echo running', 'wait 300', 'wait 300',
                         f'move {x + 30} {y + 20}', 'wait 100', f'click {x + 40} {y + 25}', 'wait 100',
                         f'move {x + 5} {y - 30}', 'wait 100', 'cmd close_tab', 'wait 300'], mode='views')
        log = self.echo_log()
        self.assertIn('0 view 1 hover 30 20', log)
        self.assertIn('0 view 1 down 40 25', log)
        self.assertIn('0 view 1 up 40 25', log)
        self.assertIn('0 view 1 click 40 25', log)
        self.assertIn('0 view 1 leave', log)
        self.assertIn('0 view 1 closed', log)

    def test_a_broken_picture_changes_nothing_and_unview_closes(self):
        out = self.run_editor(['cmd echo.view', 'wait-ext echo running', 'wait 300', 'wait 300',
                               'cmd echo.badview', 'wait 300', 'print-views', 'cmd echo.unview', 'wait 300',
                               'print-views', 'print-tabs'], mode='views')
        self.assertTrue(any(l.startswith('view=1 title=Echo picture shapes=12 ') for l in out), out)
        self.assertEqual(out[-1], 'tabs=*a.txt')
        log = self.echo_log()
        self.assertTrue(any(l.startswith('error ') and l.endswith(' syntax line 1') for l in log), log)
        self.assertNotIn('0 view 1 closed', log)

    def test_eight_views_at_most_and_none_without_the_feature(self):
        self.run_editor(['cmd echo.manyviews', 'wait-ext echo running', 'wait 300', 'wait 300'], mode='views')
        log = self.echo_log()
        self.assertEqual(sum(l.startswith('ok ') for l in log if ' ' in l and l.split(' ')[1].isdigit()
                             and int(l.split(' ')[1]) > 0), 8)
        self.assertTrue(any(l.endswith('toobig 8 views') for l in log), log)
        self.run_editor(['cmd echo.view', 'wait-ext echo running', 'wait 300'])
        self.assertTrue(any(l.endswith('unknown no such request') for l in self.echo_log()))

    def test_shapes_past_the_edges_keep_their_geometry(self):
        # a circle far larger than the view as the background; a triangle crossing the top; a wedge
        # running far past the right side; a stroke without width; rounded rectangles that once
        # took minutes to draw
        picture = '|'.join([
            'rrect -100000 -100000 200000 200000 100000 #ffff00',
            'fill #ff0000 100 -100 200 100 0 100',
            'fill #00ff00 350 200 100000 200 350 260',
            'line 10 280 300 280 0 #0000ff',
            'rrect 2000 2000 200000 200000 100000 #ff00ff',
            'rrect 2000 2000 9999999 9999999 9999999 #ff00ff',
        ])
        self.env['ECHO_PICTURE'] = picture
        shot = self.work / 'edges.ppm'
        out = self.run_editor(['cmd echo.view', 'wait-ext echo running', 'wait 300', 'wait 300', 'print-views',
                               'shot ' + shot.as_posix()], mode='views')
        line, x, y = self.view_at(out)
        width = int(line.split(' size=')[1].split('x')[0])
        yellow, red, green = (255, 255, 0), (255, 0, 0), (0, 255, 0)
        # at the view's second row the triangle spans x 49 .. 151
        for px, want in ((44, yellow), (52, red), (100, red), (148, red), (156, yellow)):
            self.assertEqual(ppm_pixel(shot, x + px, y + 2), want, f'{px},2')
        for py in (202, 225, 250):
            for px in (352, 600, width - 2):
                self.assertEqual(ppm_pixel(shot, x + px, y + py), green, f'{px},{py}')
        colors = ppm_colors(shot)
        self.assertNotIn((0, 0, 255), colors)
        self.assertNotIn((255, 0, 255), colors)

    def test_a_long_polyline_is_one_shape(self):
        self.env['ECHO_PICTURE'] = 'poly 1 fg ' + '0 0 9 9 ' * 5000
        out = self.run_editor(['cmd echo.view', 'wait-ext echo running', 'wait 300', 'wait 300', 'print-views'],
                              mode='views')
        line, _, _ = self.view_at(out)
        self.assertIn(' shapes=1 ', line)

    def test_a_tap_clicks_and_a_drag_does_not(self):
        out = self.run_editor(['cmd echo.view', 'wait-ext echo running', 'wait 300', 'wait 300', 'print-views'],
                              mode='views')
        _, x, y = self.view_at(out)
        self.run_editor(['cmd echo.view', 'wait-ext echo running', 'wait 300', 'wait 300',
                         f'tap {x + 40} {y + 25}', 'wait 100',
                         f'move {x + 10} {y + 10}', 'wait 50', 'down', 'wait 50', f'move {x + 60} {y + 50}',
                         'wait 50', 'up', 'wait 100',
                         f'move {x + 100} {y + 100}', 'wait 50', 'down', 'wait 50', f'move {x + 102} {y + 99}',
                         'wait 50', 'up', 'wait 300'], mode='views')
        log = [l for l in self.echo_log() if l.startswith('0 view 1 ') and ' hover ' not in l]
        events = [l[len('0 view 1 '):] for l in log if l.split(' ')[3] in ('down', 'drag', 'up', 'click')]
        self.assertEqual(events, ['down 40 25', 'up 40 25', 'click 40 25',
                                  'down 10 10', 'drag 60 50', 'up 60 50',
                                  'down 100 100', 'drag 102 99', 'up 102 99', 'click 102 99'])

    def test_a_request_does_not_read_an_older_lines_fields(self):
        out = self.run_editor(['cmd echo.view', 'wait-ext echo running', 'wait 300', 'wait 300',
                               'cmd echo.staleview', 'wait 300', 'print-views'], mode='views')
        self.assertTrue(any(l.startswith('view=1 ') for l in out), out)
        log = self.echo_log()
        self.assertTrue(any(l.startswith('error ') and ' syntax ' in l for l in log), log)

    def test_zoom_sends_the_metrics_again(self):
        self.run_editor(['cmd echo.view', 'wait-ext echo running', 'wait 300', 'wait 300', 'cmd zoom_in',
                         'wait 300', 'wait 300'], mode='views')
        metrics = [l for l in self.echo_log() if l.startswith('0 view 1 metrics ')]
        self.assertEqual(len(metrics), 2, metrics)
        self.assertNotEqual(metrics[0], metrics[1])

    # --- completion and signature help (sections 12b and 12c) ---

    def rust(self, text='fn main() {\n    \n}\n'):
        (self.proj / 'p.rs').write_text(text, encoding='utf-8')

    def complete_lines(self, out):
        return [l for l in out if l.startswith('complete ') or l.startswith('signature ')]

    def test_completion_follows_typing_and_accepts_as_one_step(self):
        self.rust()
        out = self.run_editor(['wait-ext echo running', 'wait 300', 'key Down', 'key End', 'type pr', 'wait 300',
                               'wait 300', 'print-complete', 'type i', 'wait 100', 'print-complete', 'key Down',
                               'key Return', 'wait 100', 'print-doc', 'print-complete', 'cmd undo', 'print-doc'],
                              mode='complete', files=('p.rs',))
        lines = self.complete_lines(out)
        self.assertEqual(lines[0], 'complete open=2 items=6 shown=6 sel=0 labels=print|println|printf|process|private|printd')
        self.assertEqual(lines[2], 'complete open=2 items=6 shown=5 sel=0 labels=print|println|printf|private|printd')
        self.assertEqual(lines[4], 'complete open=0 items=0 shown=0 sel=0 labels=')
        docs = [i for i, l in enumerate(out) if l == 'fn main() {']
        self.assertEqual(out[docs[0] + 1], '    println!()')
        self.assertEqual(out[docs[1] + 1], '    pri')
        log = self.echo_log()
        self.assertIn('1 complete 1 2 2 7 typed -', log)
        self.assertEqual(sum(bool(re.match(r'[1-9][0-9]* complete ', l)) for l in log), 1, 'filtering asks nothing more')

    def test_completion_waits_for_a_starting_provider(self):
        self.rust()
        self.env['ECHO_HELLO_DELAY'] = '1'
        out = self.run_editor(['key Down', 'key End', 'type pr', 'wait 300', 'wait-ext echo running',
                               'wait 300', 'wait 300', 'print-complete'], mode='complete', files=('p.rs',))
        self.assertTrue(any(l.startswith('complete open=2 items=6 ') for l in out), out)

    def test_completion_cannot_split_a_utf8_character(self):
        self.rust('é\n')
        self.env['ECHO_COMPLETE_REPLY'] = '1 0\n1 2 1 2 text 1 1 0 0\nxx'
        out = self.run_editor(['wait-ext echo running', 'key ctrl+Space', 'wait 300', 'print-complete',
                               'print-doc'], mode='complete', files=('p.rs',))
        self.assertIn('complete open=1 items=0 shown=0 sel=0 labels=', out)
        self.assertIn('é', out)

    def test_completion_extra_edit_cannot_split_a_utf8_character(self):
        self.rust('é\n\n')
        extra = 'edit 1 2 1 2 1\nx'
        self.env['ECHO_COMPLETE_REPLY'] = f'1 0\n2 1 2 1 text 1 1 0 {len(extra)}\nxx' + extra
        out = self.run_editor(['wait-ext echo running', 'key Down', 'key ctrl+Space', 'wait 300',
                               'key Return', 'print-doc', 'cmd undo', 'print-doc'], mode='complete', files=('p.rs',))
        self.assertEqual(out.count('é'), 2)
        self.assertIn('x', out)

    def test_completion_insertion_precedes_an_extra_replacement_at_its_start(self):
        self.rust('abc\n')
        extra = 'edit 1 1 1 2 1\nY'
        self.env['ECHO_COMPLETE_REPLY'] = f'1 0\n1 1 1 1 text 1 1 0 {len(extra)}\nxx' + extra
        out = self.run_editor(['wait-ext echo running', 'key ctrl+Space', 'wait 300',
                               'key Return', 'print-doc', 'cmd undo', 'print-doc'], mode='complete', files=('p.rs',))
        self.assertIn('xYbc', out)
        self.assertIn('abc', out)

    def test_an_item_can_place_the_cursor_inside_its_text(self):
        self.rust()
        out = self.run_editor(['wait-ext echo running', 'wait 300', 'key Down', 'key End', 'type pri', 'wait 300',
                               'wait 300', 'key Return', 'wait 100', 'print-doc', 'print-state', 'type x',
                               'print-doc', 'key End', 'key Return', 'type print', 'wait 300', 'wait 300', 'key Down', 'key Return',
                               'wait 100', 'print-doc', 'print-state'], mode='completecursor', files=('p.rs',))
        states = [l for l in out if l.startswith('tabs=')]
        self.assertIn(' line=2 col=11 ', states[0])       # print(|)
        self.assertIn('    print(x)', out)
        self.assertIn(' line=3 col=15 ', states[1])       # println!()| : the offset past its text is left out
        self.assertIn('    println!()', out)

    def test_an_item_with_an_import_and_the_cursor_after_it(self):
        self.rust()
        out = self.run_editor(['wait-ext echo running', 'wait 300', 'key Down', 'key End', 'type proc', 'wait 300',
                               'wait 300', 'print-complete', 'key Tab', 'wait 100', 'print-doc', 'print-state',
                               'cmd undo', 'print-doc'], mode='complete', files=('p.rs',))
        self.assertIn('complete open=2 items=6 shown=1 sel=0 labels=process', out)
        start = out.index('use std::process;')
        self.assertEqual(out[start:start + 3], ['use std::process;', 'fn main() {', '    process'])
        state = next(l for l in out if l.startswith('tabs='))
        self.assertIn(' line=3 col=12 ', state)
        last = len(out) - 1 - out[::-1].index('fn main() {')
        self.assertEqual(out[last:last + 2], ['fn main() {', '    proc'])
        self.assertNotIn('use std::process;', out[last - 1:])

    def test_a_trigger_character_asks_at_once_and_escape_closes(self):
        self.rust()
        out = self.run_editor(['wait-ext echo running', 'wait 300', 'key Down', 'key End', 'type x.', 'wait 200',
                               'print-complete', 'key Escape', 'print-complete', 'key ctrl+Space', 'wait 200',
                               'print-complete'], mode='complete', files=('p.rs',))
        lines = self.complete_lines(out)
        self.assertTrue(lines[0].startswith('complete open=2 items=6 shown=6 '), lines)
        self.assertTrue(lines[2].startswith('complete open=0 '), lines)
        self.assertTrue(lines[4].startswith('complete open=2 items=6 shown=6 '), lines)
        log = self.echo_log()
        self.assertTrue(any(' complete 1 ' in l and l.endswith(' 2 7 trigger .') for l in log), log)
        self.assertTrue(any(' complete 1 ' in l and l.endswith(' 2 7 invoked -') for l in log), log)

    def test_moving_away_or_another_character_closes_the_list(self):
        self.rust()
        out = self.run_editor(['wait-ext echo running', 'wait 300', 'key Down', 'key End', 'type pr', 'wait 300',
                               'wait 300', 'print-complete', 'key Left', 'key Left', 'key Left', 'print-complete',
                               'key End', 'key ctrl+Space', 'wait 300', 'print-complete', 'type -',
                               'print-complete'], mode='complete', files=('p.rs',))
        opens = [l.split(' ')[1] for l in self.complete_lines(out) if l.startswith('complete ')]
        self.assertEqual(opens, ['open=2', 'open=0', 'open=2', 'open=0'])

    def test_the_cursor_after_an_item_with_documentation(self):
        self.rust()
        out = self.run_editor(['wait-ext echo running', 'wait 300', 'key Down', 'key End', 'type x.', 'wait 300',
                               'print-complete', 'key Return', 'wait 100', 'print-doc', 'print-state'],
                              mode='complete', files=('p.rs',))
        self.assertIn('    x.print()', out)
        self.assertIn(' line=2 col=14 ', next(l for l in out if l.startswith('tabs=')))

    def test_an_edit_below_the_cursor_lands_where_it_was_meant(self):
        self.rust('fn main() {\n    \n}\n')
        out = self.run_editor(['wait-ext echo running', 'wait 300', 'key Down', 'key End', 'type pr', 'wait 300',
                               'wait 300', 'type intd', 'wait 100', 'print-complete', 'key Return', 'wait 100',
                               'print-doc'], mode='complete', files=('p.rs',))
        self.assertIn('complete open=2 items=6 shown=1 sel=0 labels=printd', out)
        start = out.index('fn main() {')
        self.assertEqual(out[start:start + 4], ['fn main() {', '    printd', '// after', '}'])

    def test_escape_before_the_pause_asks_nothing(self):
        self.rust()
        out = self.run_editor(['wait-ext echo running', 'wait 300', 'key Down', 'key End', 'type pr', 'key Escape',
                               'wait 300', 'wait 300', 'print-complete'], mode='complete', files=('p.rs',))
        self.assertIn('complete open=0 items=0 shown=0 sel=0 labels=', out)
        self.assertFalse(any(re.match(r'[1-9][0-9]* complete ', l) for l in self.echo_log()))

    def test_an_edit_elsewhere_ends_the_list(self):
        self.rust()
        out = self.run_editor(['wait-ext echo running', 'wait 300', 'key Down', 'key End', 'type pr', 'wait 300',
                               'wait 300', 'print-complete', 'cmd echo.faredit', 'wait 300', 'print-complete',
                               'print-doc'], mode='complete', files=('p.rs',))
        opens = [l.split(' ')[1] for l in out if l.startswith('complete ')]
        self.assertEqual(opens, ['open=2', 'open=0'])
        self.assertIn('FN main() {', out)

    def test_a_broken_list_shows_nothing(self):
        self.rust()
        out = self.run_editor(['wait-ext echo running', 'wait 300', 'key Down', 'key End', 'type pr', 'wait 300',
                               'wait 300', 'print-complete'], mode='completebad', files=('p.rs',))
        self.assertIn('complete open=1 items=0 shown=0 sel=0 labels=', out)

    def test_a_list_cut_short_is_asked_for_again(self):
        self.rust()
        self.run_editor(['wait-ext echo running', 'wait 300', 'key Down', 'key End', 'type pr', 'wait 300', 'wait 300',
                         'type i', 'wait 300', 'wait 300'], mode='completemore', files=('p.rs',))
        log = self.echo_log()
        self.assertTrue(any(' complete 1 ' in l and l.endswith(' 2 8 incomplete -') for l in log), log)

    def test_signature_help_follows_the_arguments(self):
        self.rust()
        out = self.run_editor(['wait-ext echo running', 'wait 300', 'key Down', 'key End', 'type add(', 'wait 300',
                               'print-complete', 'type 1,', 'wait 300', 'wait 300', 'print-complete', 'key Escape',
                               'print-complete', 'key ctrl+shift+Space', 'wait 300', 'print-complete'],
                              mode='complete', files=('p.rs',))
        sigs = [l for l in out if l.startswith('signature ')]
        self.assertEqual(sigs[0], 'signature open=1 from=7 to=13 text=fn add(a: i32, b: i32)')
        self.assertEqual(sigs[1], 'signature open=1 from=15 to=21 text=fn add(a: i32, b: i32)')
        self.assertTrue(sigs[2].startswith('signature open=0 '), sigs)
        self.assertEqual(sigs[3], 'signature open=1 from=15 to=21 text=fn add(a: i32, b: i32)')
        log = self.echo_log()
        self.assertTrue(any(' signature 1 ' in l and l.endswith(' 2 9 trigger (') for l in log), log)
        self.assertTrue(any(' signature 1 ' in l and l.endswith(' update -') for l in log), log)
        self.assertTrue(any(l.endswith(' invoked -') and ' signature ' in l for l in log), log)

    def test_no_requests_without_the_features(self):
        self.rust()
        out = self.run_editor(['cmd echo.toast', 'wait-ext echo running', 'wait 300', 'key Down', 'key End',
                               'type pr(', 'wait 300', 'wait 300', 'print-complete'], files=('p.rs',))
        self.assertIn('complete open=0 items=0 shown=0 sel=0 labels=', out)
        self.assertFalse(any(' complete ' in l or ' signature ' in l for l in self.echo_log()))

    # --- definition, references, symbols, actions, rename, format (12d to 12h) ---

    def lang(self):
        (self.proj / 'p.rs').write_text('fn  main( ) {\n    let x = main;\n}\n', encoding='utf-8')
        (self.proj / 'other.rs').write_text('fn main_ref() {}\n', encoding='utf-8')

    def state(self, out, n=0):
        return [l for l in out if l.startswith('tabs=')][n]

    def test_definition_goes_there_and_references_list_them(self):
        self.lang()
        out = self.run_editor(['wait-ext echo running', 'wait 300', 'key Down', 'key Home', 'key ctrl+Right',
                               'key ctrl+Right', 'key ctrl+Right', 'key F12', 'wait 300', 'wait 300', 'print-state',
                               'key shift+F12', 'wait 300', 'wait 300', 'print-palette', 'key Down', 'key Return',
                               'wait 100', 'print-state'], mode='lang', files=('p.rs',))
        self.assertIn(' active=p.rs line=1 col=9 sel=4 ', self.state(out, 0))
        rows = out[out.index('choose=Go to reference') + 1:]
        self.assertTrue(rows[1].startswith('> p.rs:2  let x = main;'), rows)
        self.assertTrue(rows[2].startswith('  other.rs:1  fn main_ref() {}'), rows)
        self.assertIn(' active=other.rs line=1 col=8 sel=4 ', self.state(out, 1))

    def test_symbols_filter_and_go(self):
        self.lang()
        out = self.run_editor(['wait-ext echo running', 'wait 300', 'key ctrl+r', 'wait 300', 'wait 300',
                               'print-palette', 'type x', 'key Return', 'wait 100', 'print-state'],
                              mode='lang', files=('p.rs',))
        rows = out[out.index('choose=Go to symbol') + 1:]
        self.assertTrue(rows[1].startswith('> main'), rows)
        self.assertTrue(rows[2].startswith('    x'), rows)
        self.assertIn(' line=2 col=9 sel=0 ', self.state(out))   # a symbol: the cursor at its start

    def test_code_actions_edit_and_send_their_data(self):
        self.lang()
        out = self.run_editor(['wait-ext echo running', 'wait 300', 'key ctrl+.', 'wait 300', 'wait 300',
                               'print-palette', 'key Return', 'wait 300', 'print-doc', 'key ctrl+.', 'wait 300',
                               'wait 300', 'key Down', 'key Return', 'wait 300', 'wait 300'],
                              mode='lang', files=('p.rs',))
        rows = out[out.index('choose=Code action') + 1:]
        self.assertTrue(rows[1].startswith('> Add a comment'), rows)   # quick fixes first
        self.assertTrue(rows[2].startswith('  Say hello'), rows)
        self.assertEqual(out[out.index('// fixed') + 1], 'fn  main( ) {')
        log = self.echo_log()
        self.assertIn('0 action 5', log)
        self.assertEqual(log[log.index('0 action 5') + 1], 'hello')

    def test_rename_edits_open_and_closed_files_as_one_undo_step_each(self):
        self.lang()
        out = self.run_editor(['wait-ext echo running', 'wait 300', 'key ctrl+End', 'key F2', 'print-palette',
                               'type start', 'key Return', 'wait 300', 'wait 300', 'print-tabs', 'print-doc',
                               'cmd undo', 'print-doc', 'key ctrl+Tab', 'print-state', 'print-doc'],
                              mode='lang', files=('p.rs',))
        self.assertIn('prompt=New name', out)
        state = [l for l in out if l.startswith('tabs=2 ')][0]
        self.assertIn(' active=other.rs ', state)
        self.assertIn(' dirty=1 ', state)
        self.assertIn('fn start_ref() {}', out)
        self.assertIn('tabs=*p.rs | other.rs', out)
        docs = [i for i, l in enumerate(out) if l.startswith('fn ')]
        self.assertEqual(out[docs[0]:docs[0] + 2], ['fn  start( ) {', '    let x = start;'])
        self.assertEqual(out[docs[1]:docs[1] + 2], ['fn  main( ) {', '    let x = main;'])
        self.assertEqual((self.proj / 'other.rs').read_text(), 'fn main_ref() {}\n', 'nothing saved')

    @unittest.skipIf(os.name == 'nt', 'creating symlinks requires Windows developer mode')
    def test_rename_reuses_dirty_tabs_opened_through_symlinks(self):
        self.lang()
        (self.proj / 'alias.rs').symlink_to(self.proj / 'other.rs')
        out = self.run_editor(['wait-ext echo running', 'wait 300', 'type UNSAVED',
                               'key ctrl+Tab', 'key F2', 'type start', 'key Return',
                               'wait 300', 'wait 300', 'print-toast', 'print-tabs', 'print-doc',
                               'key ctrl+Tab', 'print-doc'], mode='lang', files=('p.rs', 'alias.rs'))
        self.assertIn('toast=A document changed since the edit was made: nothing changed', out)
        self.assertIn('tabs=*p.rs | alias.rs', out)
        self.assertIn('fn  main( ) {', out)
        self.assertIn('UNSAVEDfn main_ref() {}', out)

    def test_a_stale_workspace_edit_changes_nothing(self):
        self.lang()
        self.env['ECHO_STALE'] = '1'
        out = self.run_editor(['wait-ext echo running', 'wait 300', 'key F2', 'type start', 'key Return',
                               'wait 300', 'wait 300', 'print-toast', 'print-tabs', 'print-doc'],
                              mode='lang', files=('p.rs',))
        self.assertIn('toast=A document changed since the edit was made: nothing changed', out)
        self.assertIn('tabs=*p.rs', out)
        self.assertIn('fn  main( ) {', out)

    def test_a_rename_the_extension_refuses_says_why(self):
        self.lang()
        self.env['ECHO_LANG'] = 'error'
        out = self.run_editor(['wait-ext echo running', 'wait 300', 'key F2', 'type x', 'key Return',
                               'wait 300', 'print-toast', 'print-doc'], mode='lang', files=('p.rs',))
        self.assertIn('toast="x" is already a name here', out)
        self.assertIn('fn  main( ) {', out)

    def test_edits_that_overlap_or_leave_the_text_change_nothing(self):
        self.lang()
        for twist, toast in (('overlap', "The edit's ranges overlap: nothing changed"),
                             ('outside', "The edit's ranges are not in the text: nothing changed")):
            self.env['ECHO_LANG'] = twist
            out = self.run_editor(['wait-ext echo running', 'wait 300', 'key shift+alt+f', 'wait 300', 'wait 300',
                                   'print-toast', 'print-state', 'print-doc'], mode='lang', files=('p.rs',))
            self.assertIn('toast=' + toast, out)
            self.assertIn(' dirty=0 ', self.state(out))
            self.assertIn('fn  main( ) {', out)

    def test_an_extension_that_exits_while_asked_ends_the_question(self):
        self.lang()
        self.env['ECHO_LANG'] = 'exit'
        out = self.run_editor(['wait-ext echo running', 'wait 300', 'key ctrl+r', 'wait 300', 'wait 300',
                               'print-toast', 'print-palette', 'type abc', 'print-doc'], mode='lang', files=('p.rs',))
        self.assertIn('toast=No symbols in this file', out)
        self.assertIn('abcfn  main( ) {', out)

    def test_an_extension_applies_a_workspace_edit(self):
        self.lang()
        out = self.run_editor(['wait-ext echo running', 'wait 300', 'cmd echo.apply', 'wait 300', 'print-tabs',
                               'print-doc', 'key ctrl+Tab', 'print-doc'], files=('p.rs',))
        self.assertIn('tabs=*p.rs | other.rs', out)
        self.assertIn('FN  main( ) {', out)
        self.assertIn('// applied', out)
        self.assertTrue(any(l.startswith('ok ') and l.count(' ') == 1 for l in self.echo_log()), self.echo_log())

    def test_unsolicited_apply_cannot_open_a_file_outside_its_permissions(self):
        secret = self.work / 'secret.rs'
        secret.write_text('private\n', encoding='utf-8')
        self.env['ECHO_OPEN'] = secret.as_posix()
        out = self.apply_twist('outside')
        self.assertIn('needs ', self.reply_to_apply())
        self.assertIn('tabs=*p.rs', out)
        self.assertIn('fn  main( ) {', out)
        self.assertEqual(secret.read_text(), 'private\n')

    def test_a_refused_apply_says_why_and_changes_nothing(self):
        self.lang()
        out = self.run_editor(['wait-ext echo running', 'wait 300', 'cmd echo.applystale', 'wait 300',
                               'cmd echo.applyoverlap', 'wait 300', 'print-tabs', 'print-doc', 'print-toast'],
                              files=('p.rs',))
        log = self.echo_log()
        self.assertTrue(any(' stale a document changed' in l for l in log), log)
        self.assertTrue(any(' badpos two edits overlap' in l for l in log), log)
        self.assertIn('tabs=*p.rs', out)
        self.assertIn('fn  main( ) {', out)
        self.assertNotIn('toast=', ' '.join(l for l in out if 'nothing changed' in l))

    def apply_twist(self, twist, files=('p.rs',), pre=()):
        self.lang()
        self.env['ECHO_APPLY'] = twist
        return self.run_editor(['wait-ext echo running', 'wait 300', *pre, 'cmd echo.apply', 'wait 300', 'print-tabs',
                                'print-doc'], files=files)

    def reply_to_apply(self):
        return [l for l in self.echo_log() if l.startswith(('ok ', 'error '))][-1]

    def test_apply_refuses_what_it_cannot_make_and_leaves_no_tab(self):
        for twist, code in (('bigcoord', 'badpos'), ('missing', 'nofile'), ('relative', 'nofile'),
                            ('badref', 'nofile')):
            out = self.apply_twist(twist)
            self.assertIn(code, self.reply_to_apply(), twist)
            self.assertIn('tabs=*p.rs', out, twist)
            self.assertIn('fn  main( ) {', out, twist)
            self.assertFalse((self.proj / 'missing.rs').exists())

    def test_a_disk_edit_for_an_open_document_needs_it_unchanged(self):
        out = self.apply_twist('dash')
        self.assertTrue(self.reply_to_apply().startswith('ok '), self.reply_to_apply())
        self.assertIn('FN  main( ) {', out)
        out = self.apply_twist('dash', pre=('key ctrl+End', 'type x'))
        self.assertIn('stale', self.reply_to_apply())
        self.assertIn('fn  main( ) {', out)

    def test_apply_aliases_preserve_unsaved_tabs_and_check_versions(self):
        for twist in ('alias', 'aliasbad'):
            with self.subTest(twist=twist):
                out = self.apply_twist(twist, pre=('type UNSAVED',))
                self.assertIn('stale', self.reply_to_apply())
                self.assertIn('tabs=*p.rs', out)
                self.assertIn('UNSAVEDfn  main( ) {', out)

    @unittest.skipIf(os.name == 'nt', 'creating symlinks requires Windows developer mode')
    def test_apply_reuses_a_dirty_tab_opened_through_a_symlink(self):
        self.lang()
        (self.proj / 'alias.rs').symlink_to(self.proj / 'p.rs')
        self.env['ECHO_APPLY'] = 'alias'
        out = self.run_editor(['wait-ext echo running', 'wait 300', 'type UNSAVED',
                               'cmd echo.apply', 'wait 300', 'print-tabs', 'print-doc'], files=('alias.rs',))
        self.assertIn('stale', self.reply_to_apply())
        self.assertIn('tabs=*alias.rs', out)
        self.assertIn('UNSAVEDfn  main( ) {', out)

    def test_an_insertion_goes_before_a_replacement_at_its_place(self):
        out = self.apply_twist('replins')
        self.assertTrue(self.reply_to_apply().startswith('ok '), self.reply_to_apply())
        self.assertIn('<FN  main( ) {', out)

    def test_many_edits_out_of_order_are_sorted(self):
        out = self.apply_twist('many')
        self.assertTrue(self.reply_to_apply().startswith('ok '), self.reply_to_apply())
        first = out[out.index('tabs=*p.rs | other.rs') + 1]
        # the list is i = 5999 down to 0, even ones at column 1, odd ones at column 2 (after the f):
        # each position's insertions in the list's order
        self.assertEqual(first, ('86420' * 600) + 'f' + ('97531' * 600) + 'n  main( ) {')

    def test_an_untitled_document_is_not_replaced_by_a_file_an_edit_opens(self):
        self.lang()
        self.env['ECHO_APPLY'] = 'untitled'
        out = self.run_editor(['wait-ext echo running', 'wait 300', 'cmd new_file', 'wait 300', 'cmd echo.apply',
                               'wait 300', 'print-tabs', 'print-doc'], files=('p.rs',))
        self.assertTrue(self.reply_to_apply().startswith('ok '), self.reply_to_apply())
        self.assertIn('untitled text', out)
        self.assertEqual(len([l for l in out if l.startswith('tabs=')][0].split(' | ')), 3)

    def test_answers_with_bytes_after_them_or_relative_paths_are_dropped(self):
        self.lang()
        self.env['ECHO_LANG'] = 'trailing'
        out = self.run_editor(['wait-ext echo running', 'wait 300', 'key shift+F12', 'wait 300', 'wait 300',
                               'print-toast'], mode='lang', files=('p.rs',))
        self.assertIn('toast=No references found', out)
        self.env['ECHO_LANG'] = 'relpath'
        out = self.run_editor(['wait-ext echo running', 'wait 300', 'key F12', 'wait 300', 'wait 300',
                               'print-toast'], mode='lang', files=('p.rs',))
        self.assertIn('toast=No definition found', out)

    def test_references_this_file_first_then_by_path(self):
        self.lang()
        (self.proj / 'z.rs').write_text('z\n', encoding='utf-8')
        self.env['ECHO_LANG'] = 'sorted'
        out = self.run_editor(['wait-ext echo running', 'wait 300', 'key shift+F12', 'wait 300', 'wait 300',
                               'print-palette'], mode='lang', files=('p.rs',))
        rows = out[out.index('choose=Go to reference') + 2:][:3]
        self.assertEqual([r[2:].split(':')[0] for r in rows], ['p.rs', 'other.rs', 'z.rs'], rows)

    def test_a_format_edit_for_another_file_changes_nothing(self):
        self.lang()
        self.env['ECHO_LANG'] = 'other'
        out = self.run_editor(['wait-ext echo running', 'wait 300', 'key shift+alt+f', 'wait 300', 'wait 300',
                               'print-toast', 'print-tabs'], mode='lang', files=('p.rs',))
        self.assertIn("toast=The extension's edit names a file it cannot: nothing changed", out)
        self.assertIn('tabs=*p.rs', out)

    def test_format_document(self):
        self.lang()
        out = self.run_editor(['wait-ext echo running', 'wait 300', 'key shift+alt+f', 'wait 300', 'wait 300',
                               'print-doc'], mode='lang', files=('p.rs',))
        self.assertEqual(out[out.index('fn main() {') + 1], '    let x = main;')

    def test_without_a_provider_f2_renames_the_file(self):
        self.lang()
        out = self.run_editor(['wait-ext echo running', 'wait 300', 'key F12', 'wait 100', 'print-toast',
                               'key F2', 'print-palette'], mode='lang', files=('a.txt',))
        self.assertIn('toast=No extension finds definitions in this file', out)
        self.assertTrue(any(l.startswith('prompt=') and 'New name' not in l for l in out), out)

    def test_a_view_closes_with_its_extension(self):
        out = self.run_editor(['cmd echo.view', 'wait-ext echo running', 'wait 300', 'wait 300',
                               'ext-set echo disabled 1', 'wait 300', 'wait 300', 'print-views', 'print-tabs'],
                              mode='views')
        self.assertFalse(any(l.startswith('view=') for l in out), out)
        self.assertEqual(out[-1], 'tabs=*a.txt')

    def test_a_program_that_cannot_run_is_a_failed_start(self):
        exts = self.work / 'noexec'
        d = exts / 'rhun-tests' / 'x'
        d.mkdir(parents=True)
        (d / 'prog').write_text('not a program\n', encoding='utf-8')
        (d / 'extension.ini').write_text('name = x\nowner = rhun-tests\ntitle = X\nversion = 1\nprotocol = 1\n'
                                         'run.linux-x86_64 = prog\nrun.macos-arm64 = prog\nrun.windows-x64 = prog\n'
                                         '[commands]\ngo = Go\n', encoding='utf-8')
        if os.name == 'nt':
            # no executable bit: Windows refuses the file when asked to start it
            out = self.run_editor(['cmd x.go', 'wait 500', 'print-extensions'], exts=exts)
            self.assertIn('state=failed reason=failed to start: the program could not be executed', out[0])
            return
        out = self.run_editor(['print-extensions'], exts=exts)
        self.assertIn('state=failed reason=program is not executable', out[0])
        os.chmod(d / 'prog', 0o755)
        out = self.run_editor(['cmd x.go', 'wait 500', 'print-extensions'], exts=exts)
        self.assertIn('state=failed reason=failed to start: the program could not be executed', out[0])

    def test_a_manifest_whose_name_does_not_match_its_folder(self):
        exts = self.manifest_variant('badname', **{'name = echo': 'name = other'})
        out = self.run_editor(['print-extensions'], exts=exts)
        self.assertIn('state=failed reason=extension.ini name does not match the folder', out[0])

    @unittest.skipUnless(sys.platform.startswith('linux'), 'the parent-death signal is Linux')
    def test_killing_rhun_kills_the_program(self):
        script = self.work / 'k.rsc'
        script.write_text('cmd echo.toast\nwait-ext echo running\nwait 20000\nquit\n', encoding='utf-8')
        proc = subprocess.Popen([str(EXE), self.proj.as_posix(), '--headless', '1000x600', '--extensions', str(EXTS),
                                 '--script', script.as_posix()], env=self.env, stdout=subprocess.PIPE)
        for _ in range(100):
            time.sleep(0.1)
            lines = self.log.read_text(encoding='utf-8').splitlines() if self.log.exists() else []
            if any(line.startswith('0 ready') for line in lines):
                break
        pid = int([line for line in lines if line.startswith('pid ')][0].split()[1])
        proc.kill()
        proc.wait()
        time.sleep(0.5)
        self.assertFalse(alive(pid), pid)

    def test_a_command_right_after_an_open_sees_the_document_first(self):
        # the run event for a document rhun has not yet reported waits behind opened and active
        self.run_editor(['cmd echo.toast', 'wait-ext echo running', 'wait 100',
                         'open ' + (self.proj / 'b.go').as_posix(), 'cmd echo.toast', 'wait 300'])
        log = self.echo_log()
        opened = log.index('0 opened 2 0 Go ' + (self.proj / 'b.go').as_posix())
        active = log.index('0 active 2')
        run = [i for i, line in enumerate(log) if line == '0 run echo.toast 2'][0]
        self.assertLess(opened, run)
        self.assertLess(active, run)

    # --- gate 3: diagnostics, hover, edits ---

    def test_diagnostics_become_marks_that_follow_edits(self):
        out = self.run_editor(['cmd echo.diag', 'wait-ext echo running', 'wait 300', 'print-marks',
                               'key ctrl+Home', 'type ab', 'wait 100', 'print-marks',
                               'cmd echo.nodiag', 'wait 300', 'print-marks'])
        self.assertEqual(out[1:5], ['1 1 1 6 error rhun-tests/echo first word',
                                    '2 1 2 7 warning rhun-tests/echo second word',
                                    '2 8 2 12 info rhun-tests/echo a note', 'errors=1 warnings=1'])
        # two bytes typed at the start of line 1 move the first mark; the others are on line 2
        self.assertEqual(out[5], '1 3 1 8 error rhun-tests/echo first word')
        self.assertEqual(out[6], '2 1 2 7 warning rhun-tests/echo second word')
        self.assertEqual(out[9], 'errors=0 warnings=0')

    def test_deleting_a_marked_range_removes_the_mark(self):
        out = self.run_editor(['cmd echo.diag', 'wait-ext echo running', 'wait 300', 'key ctrl+Home',
                               'key shift+End', 'key Delete', 'wait 100', 'print-marks'])
        self.assertEqual(sorted(out[1:3]), ['2 1 2 7 warning rhun-tests/echo second word',
                                            '2 8 2 12 info rhun-tests/echo a note'])
        self.assertEqual(out[3], 'errors=0 warnings=1')

    def test_a_bad_diagnostics_line_is_a_syntax_error_and_a_stale_version_is_refused(self):
        self.run_editor(['cmd echo.baddiag', 'wait-ext echo running', 'wait 300', 'type q', 'wait 100',
                         'cmd echo.stalediag', 'wait 300'])
        log = self.echo_log()
        self.assertTrue(any(line.startswith('error 1 syntax') for line in log), log)
        self.assertIn('error 2 stale 1', log)

    def test_diagnostics_reject_malformed_and_out_of_range_coordinates(self):
        for coords, code in (('1x 1 1 2', 'syntax'),
                             ('18446744073709551617 1 1 2', 'syntax'),
                             ('999 1 999 2', 'badpos'), ('1 6 1 2', 'badpos')):
            with self.subTest(coords=coords):
                self.env['ECHO_BAD_DIAG'] = coords + ' error invalid\n'
                out = self.run_editor(['cmd echo.baddiag', 'wait-ext echo running', 'wait 300', 'print-marks'])
                self.assertTrue(any(l.startswith('error 1 ' + code) for l in self.echo_log()), self.echo_log())
                self.assertIn('errors=0 warnings=0', out)

    def test_hover_asks_the_extension_and_shows_its_answer(self):
        out = self.run_editor(['cmd echo.toast', 'wait-ext echo running', 'print-text-cell 1 3'])
        x, y = out[1].split()
        out = self.run_editor(['cmd echo.toast', 'wait-ext echo running', f'move {x} {y}', 'wait 800',
                               'print-hover', 'wait 700', 'print-tip', 'move 5 5', 'wait 100', 'print-hover'])
        self.assertEqual(out[1], 'hover=1 1 3 sent=1 text=hovering 1:3')
        self.assertEqual(out[2], 'tip=hovering 1:3')
        self.assertEqual(out[3], 'hover=none')

    def test_a_mark_message_shows_as_a_tooltip(self):
        exts = self.manifest_variant('nohover', **{'hover = *\n': ''})
        out = self.run_editor(['cmd echo.diag', 'wait-ext echo running', 'print-text-cell 2 3'], exts=exts)
        x, y = out[1].split()
        out = self.run_editor(['cmd echo.diag', 'wait-ext echo running', 'wait 200', f'move {x} {y}', 'wait 700',
                               'print-tip'], exts=exts)
        self.assertEqual(out[1], 'tip=second word')

    def test_a_mark_and_a_hover_answer_share_the_tooltip(self):
        out = self.run_editor(['cmd echo.diag', 'wait-ext echo running', 'print-text-cell 2 3'])
        x, y = out[1].split()
        out = self.run_editor(['cmd echo.diag', 'wait-ext echo running', 'wait 200', f'move {x} {y}', 'wait 800',
                               'print-hover', 'wait 700', 'print-tip'])
        self.assertEqual(out[1], 'hover=1 2 3 sent=1 text=hovering 2:3')
        self.assertEqual(out[2], 'tip=second word  ·  hovering 2:3')

    def test_the_edits_stream_describes_every_change(self):
        exts = self.manifest_variant('edits', **{'cursor = *': 'cursor = *\nedits = *'})
        self.run_editor(['cmd echo.toast', 'wait-ext echo running', 'wait 100', 'key ctrl+Home', 'type xy',
                         'wait 100', 'key BackSpace', 'wait 100', 'cmd undo', 'wait 100', 'cmd echo.hi', 'wait 300'],
                        exts=exts)
        log = self.echo_log()
        headers = [line for line in log if line.startswith('0 edits 1 ')]
        bodies = [log[i + 1] for i, line in enumerate(log) if line.startswith('0 edits 1 ')]
        self.assertEqual(headers[0], '0 edits 1 2 14')          # two keystrokes, one event
        self.assertEqual(bodies[0], r'0 0 1\nx1 0 1\ny')          # START DEL INS, then the bytes
        self.assertEqual(bodies[1], r'1 1 0\n')                   # backspace deletes byte 1
        self.assertEqual(bodies[2], r'1 0 1\ny')                 # undo puts the y back
        self.assertTrue(any(b.endswith('hi') for b in bodies), bodies)   # the extension's own insert too

    def test_quitting_leaves_no_program_behind(self):
        out = self.run_editor(['cmd echo.toast', 'wait-ext echo running', 'print-extensions'])
        pid = int(out[1].split('pid=')[1].split()[0])
        time.sleep(0.5)
        self.assertFalse(alive(pid), pid)
        log = self.echo_log()
        self.assertEqual(log[-1], '0 bye')

    # --- gate 4: register, option, prompts, cmd ---

    def test_register_adds_a_command_with_its_key_and_it_runs(self):
        out = self.run_editor(drop_waits=True, actions=['cmd echo.reg', 'wait-ext echo running', 'wait 300', 'print-extensions',
                               'cmd echo.extra', 'wait 300', 'print-toast', 'key ctrl+alt+9', 'wait 300',
                               'cmd echo.reg', 'wait 300'])
        self.assertIn(',echo.extra confined=', out[0])   # after the manifest's last command
        self.assertEqual(out[1], 'toast=extra ran')
        log = self.echo_log()
        self.assertEqual(sum(1 for l in log if l == '0 run echo.extra 1'), 2)   # the palette and the key
        self.assertTrue(any(l.startswith('error 4 refused') for l in log), log)  # registered twice

    def test_runtime_commands_leave_when_the_program_stops(self):
        out = self.run_editor(drop_waits=True, actions=['cmd echo.reg', 'wait-ext echo running', 'wait 300', 'cmd echo.die',
                               'wait 500', 'print-extensions'])
        self.assertIn('state=crashed', out[0])
        self.assertNotIn('echo.extra', out[0])   # gone with the program

    def test_options_override_the_settings_for_one_document(self):
        out = self.run_editor(drop_waits=True, actions=['print-options', 'cmd echo.opt', 'wait-ext echo running', 'wait 300',
                               'print-options', 'key ctrl+End', 'key Tab', 'print-doc', 'cmd echo.optoff',
                               'wait 300', 'print-options', 'cmd echo.badopt', 'wait 300'],
                              files=('a.txt', 'b.go'))
        self.assertEqual(out[0], 'tab_width=4 insert_spaces=1 trim_trailing_whitespace=0 final_newline=1')
        self.assertEqual(out[1], 'tab_width=8 insert_spaces=0 trim_trailing_whitespace=0 final_newline=1')
        self.assertIn('\t', out[2] + out[3])
        self.assertEqual(out[-1], 'tab_width=4 insert_spaces=1 trim_trailing_whitespace=0 final_newline=1')
        log = self.echo_log()
        self.assertEqual(sum(1 for l in log if l.startswith('error ') and ' syntax ' in l), 2)

    def test_options_are_per_document_and_leave_with_the_program(self):
        out = self.run_editor(drop_waits=True, actions=['cmd echo.opt', 'wait-ext echo running', 'wait 300', 'print-options',
                               'key ctrl+Tab', 'print-state', 'print-options', 'key ctrl+Tab', 'print-options',
                               'cmd echo.die', 'wait 500', 'print-options'], files=('a.txt', 'b.go'))
        self.assertTrue(out[0].startswith('tab_width=8 insert_spaces=0'), out[0])
        self.assertIn('active=a.txt', out[1])
        self.assertTrue(out[2].startswith('tab_width=4 insert_spaces=1'), out[2])
        self.assertTrue(out[3].startswith('tab_width=8 insert_spaces=0'), out[3])
        self.assertTrue(out[4].startswith('tab_width=4 insert_spaces=1'), out[4])

    def test_save_options_trim_and_skip_the_final_newline(self):
        self.run_editor(drop_waits=True, actions=['cmd echo.optsave', 'wait-ext echo running', 'wait 300', 'print-options',
                         'key ctrl+End', 'type x', 'key space', 'key space', 'key ctrl+s', 'wait 200'])
        self.assertEqual((self.proj / 'a.txt').read_text(encoding='utf-8'), 'hello world\nsecond line\nx')
        self.run_editor(drop_waits=True, actions=['key ctrl+End', 'type y', 'key space', 'key space', 'key ctrl+s', 'wait 200'])
        self.assertEqual((self.proj / 'a.txt').read_text(encoding='utf-8'), 'hello world\nsecond line\nxy  \n')

    def test_choose_shows_a_pick_list_and_answers_with_the_pick(self):
        out = self.run_editor(drop_waits=True, actions=['cmd echo.choose', 'wait-ext echo running', 'wait 300', 'print-palette',
                               'type be', 'print-palette', 'key Return', 'wait 300', 'print-toast',
                               'print-palette'])
        self.assertEqual(out[:5], ['choose=Pick one', 'field=', '> alpha', '  beta', '  gamma'])
        self.assertEqual(out[5:8], ['choose=Pick one', 'field=be', '> beta'])
        self.assertEqual(out[8], 'toast=chose 2')
        self.assertEqual(out[9], 'none')
        self.assertIn('ok 1 2', self.echo_log())

    def test_escape_cancels_a_prompt_and_a_second_prompt_is_busy(self):
        out = self.run_editor(drop_waits=True, actions=['cmd echo.choose', 'wait-ext echo running', 'wait 300', 'cmd echo.ask',
                               'wait 300', 'print-palette', 'key Escape', 'wait 300', 'print-palette',
                               'cmd echo.ask', 'wait 300', 'print-palette'])
        self.assertEqual(out[0], 'choose=Pick one')          # the ask did not replace it
        self.assertEqual(out[5], 'none')
        self.assertEqual(out[6], 'prompt=Your name?')        # free again
        log = self.echo_log()
        self.assertIn('error 2 busy a prompt is open', log)
        self.assertIn('error 1 cancelled', log)

    def test_ask_returns_the_text_typed(self):
        out = self.run_editor(drop_waits=True, actions=['cmd echo.ask', 'wait-ext echo running', 'wait 300', 'type Bob',
                               'print-palette', 'key Return', 'wait 300', 'print-toast'])
        self.assertEqual(out[:2], ['prompt=Your name?', 'field=Bob'])
        self.assertEqual(out[2], 'toast=answer Bob')
        self.assertIn('ok 1 3', self.echo_log())

    def test_opening_the_palette_cancels_the_prompt(self):
        self.run_editor(drop_waits=True, actions=['cmd echo.ask', 'wait-ext echo running', 'wait 300', 'key ctrl+shift+p', 'wait 300',
                         'key Escape'])
        self.assertIn('error 1 cancelled', self.echo_log())

    def test_term_shows_the_command_and_enter_runs_it(self):
        # the prompt ignores Enter in its first half second (a keystroke meant for the editor)
        out = self.run_editor(drop_waits=True, actions=['cmd echo.term', 'wait-ext echo running', 'wait 300', 'print-palette',
                               'key Return', 'wait 300', 'print-palette', 'key Return', 'wait-term ext-ran-ok',
                               'print-term', 'print-palette'])
        self.assertEqual(out[:2], ['prompt=Run in the terminal: Enter, or Esc', 'field=echo ext-ran-ok'])
        self.assertEqual(out[2:4], ['prompt=Run in the terminal: Enter, or Esc', 'field=echo ext-ran-ok'])  # too early: still open
        self.assertTrue(any('ext-ran-ok' in l for l in out[4:]), out)
        self.assertIn('ok 1', self.echo_log())

    def test_cmd_runs_listed_commands_and_refuses_the_rest(self):
        out = self.run_editor(drop_waits=True, actions=['cmd echo.cmd', 'wait-ext echo running', 'wait 300', 'print-state',
                               'cmd echo.badcmd', 'wait 300', 'print-state'])
        self.assertIn('sel=24', out[0])
        self.assertIn('active=a.txt', out[1])              # still running
        log = self.echo_log()
        self.assertEqual(sum(1 for l in log if l.startswith('error ') and ' refused ' in l), 3)  # quit, unknown, paste

    def test_cmd_needs_the_terminal_capability_for_the_terminal_commands(self):
        # the echo manifest has terminal = yes: toggle_terminal opens the panel
        out = self.run_editor(drop_waits=True, actions=['cmd echo.termcmd', 'wait-ext echo running', 'wait 300',
                                                        'print-panels'])
        self.assertIn('term=1', out[0])
        self.assertIn('ok 1', self.echo_log())

    def test_an_edit_and_a_command_in_one_frame_send_each_record_once(self):
        exts = self.manifest_variant('edits', **{'cursor = *': 'cursor = *\nedits = *'})
        self.run_editor(drop_waits=True, actions=['cmd echo.toast', 'wait-ext echo running', 'wait 300',
                                                  'key ctrl+End', 'type q', 'cmd echo.toast', 'wait 300', 'wait 300'],
                        exts=exts)
        log = self.echo_log()
        records = [l for l in log if l.startswith('24 0 1')]   # "24 0 1\nq": the insert at the end
        self.assertEqual(len(records), 1, log)

    def test_an_empty_mark_survives_edits_elsewhere(self):
        out = self.run_editor(drop_waits=True, actions=['cmd echo.emptymark', 'wait-ext echo running', 'wait 300',
                                                        'print-marks', 'key ctrl+End', 'key BackSpace', 'wait 300',
                                                        'print-marks', 'key ctrl+Home', 'type ab', 'wait 300', 'print-marks'])
        self.assertEqual(out[0], '1 7 1 7 hint rhun-tests/echo here')
        self.assertEqual(out[2], '1 7 1 7 hint rhun-tests/echo here')      # a delete elsewhere left it
        self.assertEqual(out[4], '1 9 1 9 hint rhun-tests/echo here')      # an insert before it moved it whole

    def test_a_miscounted_diagnostics_body_is_refused_and_old_marks_stay(self):
        out = self.run_editor(drop_waits=True, actions=['cmd echo.diag', 'wait-ext echo running', 'wait 300',
                                                        'cmd echo.countdiag', 'wait 300', 'print-marks'])
        self.assertEqual(out[0], '1 1 1 6 error rhun-tests/echo first word')
        self.assertTrue(any(l.startswith('error 2 syntax') for l in self.echo_log()), self.echo_log())

    def test_term_refuses_text_that_does_not_show_as_it_is(self):
        out = self.run_editor(drop_waits=True, actions=['cmd echo.bidi', 'wait-ext echo running', 'wait 300',
                                                        'print-palette'])
        self.assertEqual(out[0], 'none')
        self.assertTrue(any(l.startswith('error 1 syntax') for l in self.echo_log()), self.echo_log())

    # --- the Codex review of the PR ---

    def test_a_syntax_kill_while_a_body_waits_does_not_take_rhun_down(self):
        out = self.run_editor(drop_waits=True, actions=['cmd echo.toast', 'wait-ext echo stopped', 'print-extensions'],
                              mode='badbodies')
        self.assertIn('state=stopped reason=three unparsable lines in a row', out[0])

    def test_a_replace_before_the_cursor_moves_it_once(self):
        out = self.run_editor(drop_waits=True, actions=['key End', 'print-state', 'cmd echo.first', 'wait-ext echo running',
                                                        'wait 300', 'print-state', 'print-doc'])
        self.assertIn('line=1 col=12', out[0])
        self.assertIn('line=1 col=14', out[1])           # "h" became "XYZ": two bytes further
        self.assertEqual(out[2], 'XYZello world')


if __name__ == '__main__':
    unittest.main()
