#!/usr/bin/env python3
"""External writes reload open files, keep local edits, and briefly mark the affected code."""
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
EXE = Path(os.environ.get('RHUN_TEST_EXE', ROOT / 'build/rhun')).resolve()


@unittest.skipIf(os.name == 'nt', 'the control socket is Unix only')
class LiveReload(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rhun-reload-', dir='/tmp')
        self.work = Path(self.tmp.name).resolve()
        self.project = self.work / 'project'
        self.project.mkdir()
        self.file = self.project / 'watched.txt'
        self.file.write_text('before\n', encoding='utf-8')
        config = self.work / 'config/rhun/config'
        config.parent.mkdir(parents=True)
        config.write_text('[files]\nrestore_session = true\nrestore_project = false\n'
                          '[updates]\ncheck = false\n[git]\nenabled = false\n'
                          '[editor]\ncursor_blink = false\n'
                          '[ui]\nagents_panel = false\nsidebar = false\n', encoding='utf-8')
        self.env = dict(os.environ, XDG_CONFIG_HOME=str(self.work / 'config'),
                        XDG_STATE_HOME=str(self.work / 'state'))
        self.process = None
        self.client = None
        self.reader = None

    def tearDown(self):
        self.stop()
        self.tmp.cleanup()

    def start(self, *paths):
        control = self.work / 'control'
        control.unlink(missing_ok=True)
        self.process = subprocess.Popen([str(EXE), str(self.project), *map(str, paths),
                                         '--headless', '1000x700', '--scale', '1',
                                         '--control', str(control)], env=self.env,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.client.settimeout(10)
        deadline = time.monotonic() + 10
        while True:
            try:
                self.client.connect(str(control))
                break
            except (FileNotFoundError, ConnectionRefusedError):
                if self.process.poll() is not None or time.monotonic() > deadline:
                    self.fail('editor did not start')
                time.sleep(0.01)
        self.reader = self.client.makefile('r', encoding='utf-8')
        self.command('wait 150')

    def stop(self):
        if self.process is not None:
            if self.process.poll() is None:
                # A test with local edits can leave a quit confirmation open.
                self.process.terminate()
                self.process.wait(timeout=10)
            self.process.stderr.close()
            self.process = None
        if self.reader is not None:
            self.reader.close()
            self.reader = None
        if self.client is not None:
            self.client.close()
            self.client = None

    def command(self, line):
        self.client.sendall((line + '\n').encode('utf-8'))
        output = []
        while True:
            reply = self.reader.readline()
            if reply == 'ok\n':
                return ''.join(output)
            self.assertNotIn(reply, ('', 'error\n'), line)
            output.append(reply)

    def open_quick(self, name='watched.txt'):
        self.command('cmd quick_open')
        self.command('type ' + name)
        self.command('key Return')
        self.assertIn('active=' + name, self.command('print-state'))

    def external_write(self, text='after café\n', atomic=False, target=None):
        target = target or self.file
        if atomic:
            replacement = target.with_name('replacement.tmp')
            replacement.write_text(text, encoding='utf-8')
            os.replace(replacement, target)
        else:
            target.write_text(text, encoding='utf-8')

    def document(self):
        return self.command('print-doc').removesuffix('\n<eod>\n')

    def settle(self):
        self.command('wait 400')

    def wait_document(self, expected, timeout=5):
        # Disk events can arrive late on a loaded machine: wait for the reload, not a fixed time.
        deadline = time.monotonic() + timeout
        while self.document() != expected and time.monotonic() < deadline:
            self.command('wait 50')
        self.assertEqual(self.document(), expected)

    def shot(self, name):
        path = self.work / (name + '.ppm')
        self.command('shot ' + str(path))
        magic, size, maximum, pixels = path.read_bytes().split(b'\n', 3)
        self.assertEqual((magic, size, maximum), (b'P6', b'1000 700', b'255'))
        return pixels

    def editor_edge(self, pixels):
        # Sample away from the caret and text, which can move after a local edit.
        return b''.join(pixels[(1000 * y + 700) * 3:(1000 * y + 800) * 3]
                        for y in (76, 77))

    def warning_strip(self, pixels):
        return pixels[1000 * 3 * 76:1000 * 3 * 104]

    def test_quick_open_reloads_in_place_and_atomic_writes(self):
        self.start()
        self.open_quick()
        for atomic in (False, True):
            text = 'changed atomically\n' if atomic else 'after café\n'
            self.external_write(text, atomic)
            self.wait_document(text)
            self.assertIn('dirty=0', self.command('print-state'))

    def test_open_file_picker_reloads(self):
        self.start()
        self.command('cmd open_file')
        self.command('type watched.txt')
        self.command('key Return')
        self.assertIn('active=watched.txt', self.command('print-state'))
        self.external_write()
        self.wait_document('after café\n')

    def test_explorer_reloads(self):
        self.start()
        self.command('cmd toggle_sidebar')
        self.command('click 120 94')
        self.assertIn('active=watched.txt', self.command('print-state'))
        self.external_write()
        self.wait_document('after café\n')

    def test_save_as_in_new_directory_reloads(self):
        self.start()
        self.open_quick()
        target = self.project / 'new-directory/new.txt'
        self.command('cmd save_as')
        self.command('key ctrl+a')
        self.command('type ' + str(target))
        self.command('key Return')
        self.assertTrue(target.exists())
        self.external_write(target=target)
        self.wait_document('after café\n')

    def test_reload_undo_and_redo_preserve_unchanged_text(self):
        before = 'first line\nold café\nlast line\n'
        after = 'first line\nnew café\nextra line\nlast line\n'
        self.file.write_text(before, encoding='utf-8')
        self.start()
        self.open_quick()
        # Move the gap into the middle of the text, then return to a clean saved state.
        self.command('key Down')
        self.command('type x')
        self.command('cmd undo')
        self.assertIn('dirty=0', self.command('print-state'))
        self.external_write(after)
        self.wait_document(after)
        self.command('cmd undo')
        self.assertEqual(self.document(), before)
        self.command('cmd redo')
        self.assertEqual(self.document(), after)
        self.assertIn('dirty=0', self.command('print-state'))

    def test_command_line_reloads(self):
        self.start(self.file)
        self.external_write(atomic=True)
        self.wait_document('after café\n')

    def test_directory_alias_reloads(self):
        alias = self.work / 'alias'
        alias.symlink_to(self.project, target_is_directory=True)
        self.start()
        self.command('open ' + str(alias / self.file.name))
        self.external_write()
        self.wait_document('after café\n')

    def test_restored_session_reloads(self):
        self.start()
        self.open_quick()
        self.command('quit')
        self.process.wait(timeout=10)
        self.stop()
        self.start()
        self.assertIn('active=watched.txt', self.command('print-state'))
        self.external_write()
        self.wait_document('after café\n')

    def test_unsaved_edits_stay_and_warning_clears_on_revert(self):
        self.start()
        self.open_quick()
        self.command('type local_')
        self.external_write()
        self.settle()
        self.assertEqual(self.document(), 'local_before\n')
        self.assertIn('dirty=1', self.command('print-state'))
        warning = bytes.fromhex('f2c46f')
        strip = self.warning_strip(self.shot('conflict'))
        self.assertGreater(strip.count(warning), 100)
        self.command('wait 1100')
        self.assertGreater(self.warning_strip(self.shot('still-conflict')).count(warning), 100)
        self.command('cmd reload_file')
        self.assertEqual(self.document(), 'after café\n')
        self.assertEqual(self.warning_strip(self.shot('reverted')).count(warning), 0)

    def test_undo_back_to_saved_state_loads_the_disk_version(self):
        self.start()
        self.open_quick()
        self.command('type local_')
        self.external_write()
        self.settle()
        self.assertEqual(self.document(), 'local_before\n')
        warning = bytes.fromhex('f2c46f')
        self.assertGreater(self.warning_strip(self.shot('conflict')).count(warning), 100)
        self.command('cmd undo')
        self.wait_document('after café\n')
        self.assertIn('dirty=0', self.command('print-state'))
        self.assertEqual(self.warning_strip(self.shot('resolved')).count(warning), 0)

    def test_local_edits_started_during_debounce_stay(self):
        self.start(self.file)
        self.external_write()
        self.command('type local_')
        self.settle()
        self.assertEqual(self.document(), 'local_before\n')

    def test_background_tab_reloads_without_switching(self):
        other = self.project / 'other.txt'
        other.write_text('other\n', encoding='utf-8')
        self.start()
        self.open_quick()
        self.open_quick('other.txt')
        self.external_write(atomic=True)
        self.settle()
        self.assertIn('active=other.txt', self.command('print-state'))
        self.assertEqual(self.document(), 'other\n')
        self.open_quick()
        self.wait_document('after café\n')

    def test_burst_keeps_final_contents_and_cursor(self):
        self.start()
        self.open_quick()
        self.command('key Right')
        self.command('key Right')
        for index in range(20):
            self.external_write(f'change {index:02}\n', atomic=index % 2 == 0)
        self.wait_document('change 19\n')
        self.assertIn('line=1 col=3', self.command('print-state'))

    def test_continuous_writes_update_before_the_writer_stops(self):
        self.start()
        self.open_quick()

        def write_stream():
            for index in range(20):
                self.external_write(f'stream {index:02}\n', atomic=True)
                time.sleep(0.025)

        writer = threading.Thread(target=write_stream)
        writer.start()
        try:
            self.command('wait 260')
            self.assertTrue(writer.is_alive())
            self.assertTrue(self.document().startswith('stream '))
        finally:
            writer.join(timeout=5)
        self.wait_document('stream 19\n')

    def test_changed_line_tint_leaves_neighboring_lines_alone(self):
        self.file.write_text('first\nbefore\nlast\n', encoding='utf-8')
        self.start()
        self.open_quick()
        before = self.shot('before')
        self.external_write('first\nchanged\nlast\n')
        self.wait_document('first\nchanged\nlast\n')
        after = self.shot('after')
        changed = (1000 * 108 + 700) * 3
        unchanged = (1000 * 130 + 700) * 3
        self.assertNotEqual(before[changed:changed + 3], after[changed:changed + 3])
        self.assertEqual(before[unchanged:unchanged + 3], after[unchanged:unchanged + 3])

    def test_wrapped_changed_line_tints_all_its_rows(self):
        before_text = 'first\n' + 'x' * 400 + '\nlast\n'
        self.file.write_text(before_text, encoding='utf-8')
        config = self.work / 'config/rhun/config'
        config.write_text(config.read_text().replace('[editor]\n', '[editor]\nword_wrap = true\n'))
        self.start()
        self.open_quick()
        before = self.shot('before')
        changed_text = 'first\n' + 'x' * 100 + 'Y' + 'x' * 299 + '\nlast\n'
        self.external_write(changed_text)
        self.wait_document(changed_text)
        after = self.shot('after')
        for y in (108, 130):
            # Sample the blank gutter, since opaque glyphs keep their color over the tint.
            pixel = (1000 * y + 10) * 3
            self.assertNotEqual(before[pixel:pixel + 3], after[pixel:pixel + 3])

    def test_wrapped_view_follows_a_file_that_got_shorter(self):
        # Without scrolling past the end, a wrapped view is clamped from its top line's rows: after
        # the file shrinks below that line the view starts inside the new text
        self.file.write_text(''.join(f'line {i}\n' for i in range(1, 401)), encoding='utf-8')
        config = self.work / 'config/rhun/config'
        config.write_text(config.read_text().replace(
            '[editor]\n', '[editor]\nword_wrap = true\nscroll_past_end = false\n'))
        self.start()
        self.open_quick()
        self.command('key ctrl+End')
        self.assertNotIn(' y=0 ', self.command('print-scroll'))
        self.external_write('one\ntwo\nthree\n')
        self.wait_document('one\ntwo\nthree\n')
        self.assertEqual(self.command('print-scroll'), 'x=0 y=0 max=0\n')
        self.command('click 300 108')
        self.assertIn(' line=2 ', self.command('print-state'))

    def test_editor_fades_without_popup_and_idle_stops_drawing(self):
        self.start()
        self.open_quick()
        baseline_image = self.shot('baseline')
        baseline = self.editor_edge(baseline_image)
        self.external_write()
        self.wait_document('after café\n')
        pulse_image = self.shot('pulse')
        pulse = self.editor_edge(pulse_image)
        self.assertNotEqual(pulse, baseline)
        self.assertEqual(pulse_image[1000 * 3 * 600:], baseline_image[1000 * 3 * 600:])
        self.command('wait 100')
        self.assertNotEqual(self.editor_edge(self.shot('fading')), pulse)
        self.command('wait 2300')
        self.assertEqual(self.editor_edge(self.shot('settled')), baseline)
        self.command('print-frames')
        self.command('wait 600')
        self.assertEqual(self.command('print-frames'), 'frames=0\n')

    def test_own_save_does_not_trigger_reload_animation(self):
        self.start()
        self.open_quick()
        baseline = self.editor_edge(self.shot('baseline'))
        self.command('type local_')
        self.command('cmd save')
        self.settle()
        self.assertEqual(self.document(), 'local_before\n')
        self.assertEqual(self.editor_edge(self.shot('saved')), baseline)

    def set_animation(self, enabled):
        config = self.work / 'config/rhun/config'
        lines = [line for line in config.read_text().splitlines()
                 if not line.startswith('animate_disk_changes =')]
        text = '\n'.join(lines) + '\n'
        value = 'true' if enabled else 'false'
        config.write_text(text.replace('[editor]\n',
                                      f'[editor]\nanimate_disk_changes = {value}\n'))

    def test_disabled_animation_still_reloads_without_tint_or_fade_frames(self):
        self.set_animation(False)
        self.file.write_text('first\nbefore\nlast\n')
        self.start(self.file)
        baseline = self.shot('baseline')
        self.external_write('first\nchanged\nlast\n')
        self.wait_document('first\nchanged\nlast\n')
        changed = self.shot('changed')
        self.assertEqual(self.editor_edge(changed), self.editor_edge(baseline))
        pixel = (1000 * 108 + 700) * 3
        self.assertEqual(changed[pixel:pixel + 3], baseline[pixel:pixel + 3])
        self.command('print-frames')
        self.command('wait 200')
        self.assertEqual(self.command('print-frames'), 'frames=0\n')

    def test_animation_setting_applies_live_and_does_not_revive_old_fade(self):
        self.start(self.file)
        baseline = self.editor_edge(self.shot('baseline'))
        self.external_write()
        self.command('wait 180')
        self.wait_document('after café\n')
        self.assertNotEqual(self.editor_edge(self.shot('pulse')), baseline)
        self.set_animation(False)
        # A queued file reload must survive cancellation of the fade timer.
        self.external_write('second\n')
        self.command('wait 200')
        self.wait_document('second\n')
        self.assertEqual(self.editor_edge(self.shot('disabled')), baseline)
        self.command('print-frames')
        self.command('wait 100')
        self.assertEqual(self.command('print-frames'), 'frames=0\n')
        self.set_animation(True)
        self.command('wait 100')
        self.assertEqual(self.editor_edge(self.shot('enabled')), baseline)
        self.external_write('third\n')
        self.command('wait 180')
        self.wait_document('third\n')
        self.assertNotEqual(self.editor_edge(self.shot('new-pulse')), baseline)

    def test_disabled_animation_keeps_unsaved_edit_warning(self):
        self.set_animation(False)
        self.start(self.file)
        baseline = self.warning_strip(self.shot('baseline'))
        self.command('type local_')
        self.external_write()
        self.settle()
        self.assertEqual(self.document(), 'local_before\n')
        self.assertNotEqual(self.warning_strip(self.shot('conflict')), baseline)

    def toggle_animation_in_settings(self, expected):
        """Click the Animate changed text switch, then check that no other setting moved."""
        config = self.work / 'config/rhun/config'

        def settings():
            pairs = (line.partition(' = ') for line in config.read_text().splitlines())
            return {key: value for key, sep, value in pairs if sep}
        before = settings()
        self.command('cmd settings')
        self.command('move 500 350')
        self.command('scroll 1500')
        self.command('click 827 440')
        self.command('quit')
        self.process.wait(timeout=5)
        after = settings()
        # The whole configuration is written on exit; only a value that moved means a wrong click.
        moved = sorted(key for key in before if key in after and before[key] != after[key])
        self.assertEqual(after.get('animate_disk_changes'), expected, after)
        self.assertLessEqual(set(moved), {'animate_disk_changes'},
                             f'the click at 827 296 toggled another setting: {moved}')

    def test_settings_switch_persists_and_controls_next_launch(self):
        self.start(self.file)
        self.toggle_animation_in_settings('false')
        config = self.work / 'config/rhun/config'
        self.assertIn('animate_disk_changes = false\n', config.read_text())
        self.stop()
        self.start(self.file)
        baseline = self.editor_edge(self.shot('baseline'))
        self.external_write()
        self.wait_document('after café\n')
        self.assertEqual(self.editor_edge(self.shot('changed')), baseline)
        self.toggle_animation_in_settings('true')
        self.assertIn('animate_disk_changes = true\n', config.read_text())

    def test_binary_replacement_keeps_text(self):
        self.start()
        self.open_quick()
        self.file.write_bytes(b'binary\x00data\n')
        self.settle()
        self.assertEqual(self.document(), 'before\n')

    def test_symlink_reloads_when_the_file_it_leads_to_changes(self):
        # the file is in another folder, under another name, behind a relative link and an absolute one
        elsewhere = self.work / 'elsewhere'
        elsewhere.mkdir()
        real = elsewhere / 'real.txt'
        real.write_text('before\n', encoding='utf-8')
        (self.work / 'hop.txt').symlink_to(real)
        link = self.project / 'link.txt'
        link.symlink_to(Path('..') / 'hop.txt')
        self.start(link)
        self.assertIn('active=link.txt', self.command('print-state'))
        self.external_write('written\n', target=real)
        self.wait_document('written\n')
        self.external_write('replaced\n', atomic=True, target=real)
        self.wait_document('replaced\n')
        self.assertTrue(link.is_symlink())
        # the link itself pointed elsewhere, then that file written
        other = elsewhere / 'other.txt'
        other.write_text('other\n', encoding='utf-8')
        relinked = self.project / 'relink.tmp'
        relinked.symlink_to(other)
        os.replace(relinked, link)
        self.wait_document('other\n')
        self.external_write('other changed\n', target=other)
        self.wait_document('other changed\n')
        # saving writes the file it leads to, and that is not a change from outside
        self.command('type x')
        self.command('cmd save')
        self.settle()
        self.assertEqual(other.read_text(encoding='utf-8'), 'xother changed\n')
        self.assertIn('dirty=0', self.command('print-state'))

    def test_symlink_chains_and_files_that_become_symlinks(self):
        # link -> hop -> real: the symlink on the way pointed elsewhere is followed too
        elsewhere = self.work / 'elsewhere'
        elsewhere.mkdir()
        real, other = elsewhere / 'real.txt', elsewhere / 'other.txt'
        real.write_text('real\n', encoding='utf-8')
        other.write_text('other\n', encoding='utf-8')
        hops = self.work / 'hops'
        hops.mkdir()
        hop = hops / 'hop.txt'
        hop.symlink_to(real)
        link = self.project / 'link.txt'
        link.symlink_to(hop)
        plain = self.project / 'plain.txt'
        plain.write_text('plain\n', encoding='utf-8')
        self.start(link, plain)
        self.command('cmd prev_tab')
        self.assertIn('active=link.txt', self.command('print-state'))
        swap = hops / 'swap.tmp'
        swap.symlink_to(other)
        os.replace(swap, hop)
        self.wait_document('other\n')
        self.external_write('other changed\n', target=other)
        self.wait_document('other changed\n')
        # replaced as ln -sf does it, removed and made again: the symlink on the way, then the link
        hop.unlink()
        hop.symlink_to(real)
        self.wait_document('real\n')
        link.unlink()
        link.symlink_to(other)
        self.wait_document('other changed\n')
        link.unlink()
        link.symlink_to(hop)
        self.wait_document('real\n')
        # an open file replaced by a symlink: the file it leads to is followed from then on
        self.command('cmd next_tab')
        self.assertIn('active=plain.txt', self.command('print-state'))
        swap = self.project / 'swap.tmp'
        swap.symlink_to(real)
        os.replace(swap, plain)
        self.wait_document('real\n')
        self.external_write('real changed\n', target=real)
        self.wait_document('real changed\n')

    def test_reload_follows_a_folder_made_again(self):
        sub = self.project / 'sub/deeper'
        sub.mkdir(parents=True)
        note = sub / 'note.txt'
        note.write_text('before\n', encoding='utf-8')
        self.start(note)
        # the folder removed and made again at once, then the file written twice
        note.unlink()
        sub.rmdir()
        sub.mkdir()
        self.external_write('after\n', target=note)
        self.wait_document('after\n')
        self.external_write('again\n', target=note)
        self.wait_document('again\n')
        # two levels removed: the file waits while they are gone, and they come back one at a time
        shutil.rmtree(self.project / 'sub')
        self.settle()
        self.assertEqual(self.document(), 'again\n')
        (self.project / 'sub').mkdir()
        self.settle()
        sub.mkdir()
        self.settle()
        self.external_write('third\n', atomic=True, target=note)
        self.wait_document('third\n')
        self.external_write('fourth\n', target=note)
        self.wait_document('fourth\n')
        # all at once, the file written in the same moment
        shutil.rmtree(self.project / 'sub')
        sub.mkdir(parents=True)
        self.external_write('fifth\n', target=note)
        self.wait_document('fifth\n')
        # its folder moved away and made again; then the old one moved back in its place
        moved = self.project / 'sub/moved'
        os.rename(sub, moved)
        sub.mkdir()
        self.external_write('sixth\n', target=note)
        self.wait_document('sixth\n')
        (moved / 'note.txt').write_text('moved\n', encoding='utf-8')
        self.settle()
        self.assertEqual(self.document(), 'sixth\n')
        shutil.rmtree(sub)
        os.rename(moved, sub)
        self.wait_document('moved\n')
        self.external_write('seventh\n', target=note)
        self.wait_document('seventh\n')


if __name__ == '__main__':
    unittest.main(verbosity=2)
