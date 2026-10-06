#!/usr/bin/env python3
"""Editor controls, palette inventory, theme rendering and narrow-window safety."""
import os
import http.server
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
EXE = Path(os.environ.get('RHUN_TEST_EXE', ROOT / 'build/rhun')).resolve()
COMMANDS = re.findall(r'^\s+COMMAND (\w+), "([^"]+)"',
                      (ROOT / 'src/app/keys.s').read_text(encoding='utf-8'), re.M)


class EditorMatrix(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rhun-editor-matrix-')
        self.work = Path(self.tmp.name).resolve()
        self.file = self.work / 'words.txt'
        self.file.write_text('cat Cat cat\nβeta beta\n', encoding='utf-8')
        config = self.work / 'config/rhun/config'
        config.parent.mkdir(parents=True)
        config.write_text('[ui]\nsidebar = false\nagents_panel = false\n'
                          '[editor]\ncursor_blink = false\n'
                          '[files]\nrestore_session = false\nrestore_project = false\n'
                          '[updates]\ncheck = false\n[git]\nenabled = false\n', encoding='utf-8')
        self.env = dict(os.environ, HOME=self.work.as_posix(),
                        XDG_CONFIG_HOME=(self.work / 'config').as_posix(),
                        XDG_STATE_HOME=(self.work / 'state').as_posix())

    def tearDown(self):
        self.tmp.cleanup()

    def run_editor(self, actions, path=None, size='1000x700', scale='1', project=None):
        script = self.work / 'actions.rsc'
        script.write_text('\n'.join([*actions, 'quit']) + '\n', encoding='utf-8')
        result = subprocess.run([str(EXE), (project or self.work).as_posix(), (path or self.file).as_posix(),
                                 '--headless', size, '--scale', scale, '--script', script.as_posix()],
                                env=self.env, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
        self.assertNotIn(b'unknown\n', result.stdout)
        return result.stdout.decode('utf-8')

    def shot_path(self, name):
        base = Path(os.environ.get('RHUN_TEST_ARTIFACTS', self.work)) / 'visual'
        base.mkdir(parents=True, exist_ok=True)
        return base / (name + '.ppm')

    def test_palette_contains_every_registered_command(self):
        self.assertEqual(len(COMMANDS), len(set(name for name, _ in COMMANDS)))
        actions = []
        for name, title in COMMANDS:
            actions += ['echo command=' + name, 'cmd command_palette', 'type ' + title,
                        'print-palette', 'key Escape']
        sections = self.run_editor(actions).split('command=')[1:]
        self.assertEqual(len(sections), len(COMMANDS))
        for section, (name, title) in zip(sections, COMMANDS):
            titles = [line[2:] for line in section.splitlines() if line[:2] in ('  ', '> ')]
            self.assertIn(title, titles, name)

    def test_large_match_count_does_not_paint_into_find_buttons(self):
        images = []
        for count in (1, 100000):
            file = self.work / f'count-{count}.txt'
            file.write_text('a' * count + '\n', encoding='utf-8')
            shot = self.work / f'count-{count}.ppm'
            self.run_editor(['cmd find', 'type a', 'key Up', 'move 500 400',
                             'shot ' + shot.as_posix()], path=file)
            pixels = shot.read_bytes().split(b'\n', 3)[3]
            images.append(b''.join(pixels[(y * 1000 + 848) * 3:(y * 1000 + 976) * 3]
                                   for y in range(92, 124)))
        self.assertEqual(*images, 'Match count paints over Find controls')

    def test_narrow_find_close_does_not_move_hidden_scrollbar(self):
        file = self.work / 'scroll.txt'
        file.write_text(''.join(f'line {index}\n' for index in range(1, 101)), encoding='utf-8')
        for x in (570, 610):
            with self.subTest(close_x=x):
                output = self.run_editor(['cmd find', f'click {x} 330',
                                         'click 200 300', 'print-state'], path=file,
                                         size='640x480', scale='3')
                self.assertIn('line=2 ', output)
                self.assertIn('focus=0 ', output)

    def test_find_blocks_fractional_scrollbar_writeback_while_held(self):
        config = self.work / 'config/rhun/config'
        config.write_text(config.read_text(encoding='utf-8').replace('[editor]\n',
                          '[editor]\nfont_size = 14\n'), encoding='utf-8')
        file = self.work / 'scroll-held.txt'
        file.write_text(''.join(f'line {index}\n' for index in range(1, 101)), encoding='utf-8')
        states = []
        for frames in (0, 100):
            output = self.run_editor(['cmd find', 'move 990 347', 'down',
                'move 960 108', *(['move 960 108'] * frames), 'up', 'key Escape',
                'click 200 300', 'print-state'], path=file)
            states.append(output.strip())
        self.assertEqual(*states, 'Blocked redraws change the document scroll offset')

    def test_narrow_zoomed_find_field_accepts_mouse_focus(self):
        output = self.run_editor(['cmd find', 'type cat', 'click 500 400',
            'print-state', 'click 60 320', 'print-state', 'print-doc'], size='640x480', scale='3')
        states = [line for line in output.splitlines() if line.startswith('tabs=')]
        self.assertIn('focus=0 ', states[0])
        self.assertIn('focus=2 ', states[1])
        self.assertIn('cat Cat cat\nβeta beta\n', output)

    def test_narrow_zoomed_picker_reveals_selected_row(self):
        for index in range(8):
            (self.work / f'item{index}.txt').write_text('fixture\n', encoding='utf-8')
        output = self.run_editor(['cmd quick_open', 'type item', *(['key Down'] * 5),
                                 'print-palette', 'click 320 336', 'print-state'], size='640x480', scale='3')
        selected = next(line[2:] for line in output.splitlines() if line.startswith('> '))
        self.assertIn('active=' + selected + ' ', output)

    def test_narrow_zoomed_settings_fields_stay_inside_column(self):
        shot = self.shot_path('settings-narrow-field')
        self.run_editor(['cmd settings', 'move 320 320', 'scroll 1200',
                         'shot ' + shot.as_posix()], size='640x480', scale='3')
        header, dimensions, maximum, pixels = shot.read_bytes().split(b"\n", 3)
        width, height = map(int, dimensions.split())
        self.assertEqual((width, height), (640, 480))
        at = lambda x, y: pixels[(y * width + x) * 3:(y * width + x) * 3 + 3]
        self.assertEqual(at(20, 324), bytes.fromhex('1c1e24'), 'a field paints outside its column')
        # The new appearance rows move the Interface font field farther down the scaled page.
        self.run_editor(['cmd settings', 'move 320 320', 'scroll 2712',
                         'click 320 372', 'type narrow-font', 'key Return'], size='640x480', scale='3')
        import configparser
        config = configparser.ConfigParser(interpolation=None)
        config.read(self.work / 'config/rhun/config', encoding='utf-8')
        self.assertEqual(config.get('ui', 'font', fallback=''), 'narrow-font')

    def test_narrow_zoomed_titlebar_buttons_do_not_overlap(self):
        self.run_editor(['click 60 60'], size='640x480', scale='3')
        import configparser
        config = configparser.ConfigParser(interpolation=None)
        config.read(self.work / 'config/rhun/config', encoding='utf-8')
        self.assertTrue(config.getboolean('ui', 'sidebar'))
        self.assertFalse(config.getboolean('ui', 'agents_panel'))

    def test_find_buttons_case_previous_next_and_close(self):
        output = self.run_editor(['cmd find', 'type cat', 'print-state',
                                  'click 928 108', 'print-state',
                                  'click 896 108', 'print-state',
                                  'click 864 108', 'click 928 108', 'print-state',
                                  'click 960 108', 'print-state', 'print-doc'])
        states = [line for line in output.splitlines() if line.startswith('tabs=')]
        for line, column in zip(states[:4], (4, 8, 4, 12)):
            self.assertIn('col=' + str(column) + ' ', line)
            self.assertIn('sel=3 ', line)
        self.assertIn('focus=0', states[-1])
        self.assertIn('cat Cat cat\nβeta beta\n', output)

    def test_closing_settings_restores_document_input(self):
        for close in ('cmd close_tab', 'key ctrl+w', 'click 170 58 middle'):
            with self.subTest(close=close):
                output = self.run_editor(['cmd settings', close, 'print-state',
                    'type resumed_', 'print-doc'])
                self.assertIn('active=words.txt ', output)
                self.assertIn('focus=0 ', output)
                self.assertIn('resumed_cat Cat cat\nβeta beta\n', output)

        output = self.run_editor(['cmd close_tab', 'cmd settings', 'cmd close_tab',
            'print-state', 'cmd new_file', 'type resumed', 'print-doc'])
        self.assertIn('tabs=0 focus=0 ', output)
        self.assertIn('resumed\n<eod>', output)

    def test_closing_inactive_tabs_preserves_focus(self):
        output = self.run_editor(['cmd settings', 'cmd prev_tab', 'cmd find',
            'type cat', 'click 170 58 middle', 'print-state', 'key Escape',
            'type resumed_', 'print-doc'])
        self.assertIn('tabs=1 active=words.txt ', output)
        self.assertIn('focus=2 ', output)
        self.assertIn('resumed_ Cat cat\nβeta beta\n', output)

        output = self.run_editor(['cmd settings', 'click 50 58 middle', 'print-state'])
        self.assertIn('tabs=1 focus=4 ', output)

    def test_replace_one_and_all_buttons_and_undo(self):
        output = self.run_editor(['cmd replace', 'type cat', 'key Tab', 'type dog',
                                  'click 810 148', 'print-doc',
                                  'click 880 148', 'print-doc',
                                  'key Escape', 'cmd undo', 'print-doc',
                                  'cmd undo', 'print-doc'])
        docs = output.split('\n<eod>\n')[:-1]
        self.assertEqual(docs, ['dog Cat cat\nβeta beta\n', 'dog dog dog\nβeta beta\n',
                                'dog Cat cat\nβeta beta\n', 'cat Cat cat\nβeta beta\n'])

    def test_image_edit_commands_keep_image_and_file_intact(self):
        image = ROOT / 'tests/data/images/rgba.png'
        before = image.read_bytes()
        actions = []
        for command in ('undo redo cut copy paste select_all select_line select_next '
                        'duplicate_line delete_line move_line_up move_line_down indent outdent '
                        'toggle_comment newline_below newline_above find replace find_next '
                        'find_prev goto_line select_language reload_file save').split():
            actions += ['cmd ' + command, 'key Escape', 'print-state']
        output = self.run_editor(actions, path=image)
        states = [line for line in output.splitlines() if line.startswith('tabs=')]
        self.assertEqual(len(states), len(actions) // 3)
        self.assertTrue(all('tabs=1 active=rgba.png image=24x16' in line for line in states), output)
        self.assertEqual(image.read_bytes(), before)

    def test_all_builtin_themes_render_and_preserve_document(self):
        actions, expected = [], []
        for theme in sorted((ROOT / 'runtime/themes').glob('*.theme')):
            name = re.search(r'^name\s*=\s*(.+)$', theme.read_text(encoding='utf-8'), re.M)[1]
            expected.append(theme.stem)
            shot = self.shot_path('theme-' + theme.stem)
            actions += ['cmd select_theme', 'type ' + name, 'key Return', 'print-state',
                        'move 500 500', 'shot ' + shot.as_posix()]
        actions += ['print-doc']
        output = self.run_editor(actions)
        states = [line for line in output.splitlines() if line.startswith('tabs=')]
        self.assertEqual(len(states), len(expected))
        for state, theme in zip(states, expected):
            self.assertIn('theme=' + theme, state)
            data = self.shot_path('theme-' + theme).read_bytes()
            self.assertTrue(data.startswith(b'P6\n1000 700\n255\n'))
            self.assertEqual(len(data.split(b'\n', 3)[3]), 1000 * 700 * 3)
        self.assertIn('cat Cat cat\nβeta beta\n\n<eod>', output)

    def test_overlays_survive_sizes_and_fractional_scales(self):
        for size in ('200x160', '640x480', '1400x860'):
            for scale in ('0.5', '1', '1.25', '1.5', '2', '3'):
                with self.subTest(size=size, scale=scale):
                    shot = self.shot_path('layout-' + size + '-' + scale)
                    overlays = {name: self.shot_path(name + '-' + size + '-' + scale)
                                for name in ('find', 'quick-open', 'commands', 'settings')}
                    output = self.run_editor(['cmd find', 'type cat',
                        'shot ' + overlays['find'].as_posix(), 'key Escape',
                        'cmd quick_open', 'type words',
                        'shot ' + overlays['quick-open'].as_posix(), 'key Escape',
                        'cmd command_palette', 'shot ' + overlays['commands'].as_posix(), 'key Escape',
                        'cmd settings', 'shot ' + overlays['settings'].as_posix(), 'cmd close_tab',
                        'print-state', 'print-doc', 'shot ' + shot.as_posix()], size=size, scale=scale)
                    self.assertIn('active=words.txt ', output)
                    self.assertIn('cat Cat cat\nβeta beta\n', output)
                    width, height = map(int, size.split('x'))
                    for image in (shot, *overlays.values()):
                        self.assertEqual(len(image.read_bytes().split(b'\n', 3)[3]), width * height * 3)

    def test_project_names_do_not_paint_over_toolbar_buttons(self):
        def render(project, scale):
            shot = self.work / (project.name + '-' + str(scale) + '.ppm')
            script = self.work / 'title.rsc'
            script.write_text(f'move 500 300\nshot {shot.as_posix()}\n'
                              f'click {640 - 168 * scale} {20 * scale}\n'
                              'print-state\nprint-menu\nquit\n', encoding='utf-8')
            result = subprocess.run([str(EXE), project.as_posix(), '--headless', '640x480',
                                     '--scale', str(scale), '--script', script.as_posix()],
                                    env=self.env, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
            self.assertEqual(result.stdout.decode('utf-8'), 'tabs=1 focus=4 theme=rhun-dark\nnone\n')
            return shot.read_bytes().split(b'\n', 3)[3]
        short, long = self.work / 'a', self.work / ('project-' + 'long-name-' * 15)
        short.mkdir()
        long.mkdir()
        for scale in (1, 2):
            with self.subTest(scale=scale):
                a, b = render(short, scale), render(long, scale)
                start = 640 - 256 * scale
                for y in range(40 * scale):
                    span = slice((640 * y + start) * 3, (640 * y + 640) * 3)
                    self.assertEqual(a[span], b[span], 'Project name paints into toolbar')

    def test_narrow_status_preserves_cursor_label(self):
        for scale in (2, 3):
            images = []
            for width in (640, 1400):
                shot = self.work / f'status-{width}-{scale}.ppm'
                actions = ['cmd find', 'type cat', 'key Escape', 'move 500 200',
                           'shot ' + shot.as_posix()]
                if width == 640:
                    actions += [f'click {100 * scale} {480 - 13 * scale}', 'print-state']
                output = self.run_editor(actions, size=f'{width}x480', scale=str(scale))
                if width == 640:
                    self.assertIn('focus=0 ', output, 'Hidden language label retains a hitbox')
                pixels = shot.read_bytes().split(b'\n', 3)[3]
                images.append(b''.join(pixels[(width * y) * 3:(width * y + 160 * scale) * 3]
                                       for y in range(480 - 26 * scale, 480)))
            self.assertEqual(*images, 'Status details paint over cursor label')

    def test_long_worktree_branch_does_not_take_updater_click(self):
        repository = self.work / 'repository'
        repository.mkdir()
        (repository / 'words.txt').write_text('tracked\n', encoding='utf-8')
        def git(*args):
            subprocess.run(['git', '-C', repository.as_posix(), *args], check=True,
                           env=self.env, capture_output=True, timeout=30)
        git('init', '-q')
        git('add', 'words.txt')
        git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
            '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture')
        worktree = self.work / ('w' * 63)
        git('worktree', 'add', '-q', '-b', 'c' * 60, worktree.as_posix())
        config = self.work / 'config/rhun/config'
        config.write_text(config.read_text(encoding='utf-8').replace('enabled = false', 'enabled = true'),
                          encoding='utf-8')
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                body = b'99.0.0\n'
                self.send_response(200 if self.path == '/latest/download/VERSION' else 404)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            def log_message(self, *args):
                pass
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.env['RHUN_RELEASES_URL'] = f'http://127.0.0.1:{server.server_port}'
        target = self.work / 'owned-update-target'
        target.write_bytes(b'owned fixture\n')
        self.env['RHUN_UPDATE_TARGET'] = target.as_posix()
        try:
            output = self.run_editor(['wait-git', 'cmd check_for_updates', 'wait-update',
                                      'print-update', 'print-git', 'print-state',
                                      'click 750 587', 'wait-update', 'print-state'],
                                     path=worktree / 'words.txt', project=worktree, size='800x600')
            self.assertIn('state=available ', output)
            self.assertIn(' latest=99.0.0 ', output)
            self.assertIn('c' * 60, output)
            states = [line for line in output.splitlines() if line.startswith('tabs=')]
            self.assertEqual(len(states), 2)
            self.assertTrue(all('tabs=1 active=words.txt ' in state for state in states), output)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == '__main__':
    unittest.main(verbosity=2)
