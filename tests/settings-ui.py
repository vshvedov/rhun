#!/usr/bin/env python3
"""Click every settings control, verify saved values, cancellation and limits.

Run against the native binary on each OS. A tall offscreen window makes every
row reachable without depending on wheel timing. Normal-height scrolling is
checked separately. No real user configuration or providers are used.
"""
import configparser
import http.server
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
EXE = Path(os.environ.get('RHUN_TEST_EXE', ROOT / 'build/rhun')).resolve()
MOD = 'cmd' if sys.platform == 'darwin' else 'ctrl'
ROWS = []
for line in (ROOT / 'src/app/config.s').read_text(encoding='utf-8').splitlines():
    match = re.match(r'\s+SETTING(?:_ACTION)? \.Ls_(\w+), (\w+), (\w+)', line)
    if match:
        ROWS.append(match.groups())

# These values are the public settings contract, independent of UI step logic.
BOOLS = {
    'ui': 'sidebar agents_panel tooltips',
    'editor': ('insert_spaces line_numbers highlight_line animate_disk_changes match_brackets '
               'indent_guides word_wrap whitespace cursor_blink smooth_caret auto_pairs '
               'scroll_past_end vim_mode'),
    'files': 'trim_trailing_whitespace final_newline restore_session restore_project',
    'git': 'enabled', 'updates': 'check',
}
INTS = {
    ('ui', 'scale'): (.5, 3., .1), ('ui', 'font_size'): (9, 24, 1),
    ('ui', 'sidebar_width'): (140, 600, 10), ('ui', 'agents_width'): (240, 900, 10),
    ('editor', 'font_size'): (8, 40, 1), ('editor', 'line_height'): (1., 2.5, .05),
    ('editor', 'tab_width'): (1, 16, 1), ('terminal', 'font_size'): (8, 40, 1),
    ('terminal', 'scrollback'): (0, 100000, 1000), ('terminal', 'height'): (80, 2000, 10),
}
STRINGS = {
    ('ui', 'font'): 'missing font café.ttf', ('editor', 'font'): 'missing mono café.ttf',
    ('files', 'exclude'): '.git hidden café', ('agents', 'sources'): 'claude codex',
    ('terminal', 'shell'): 'missing shell café', ('git', 'commit_model'): 'model:café',
}
CHOICES = {('ui', 'decorations'): ('auto', 'client', 'server'),
           ('ui', 'theme_mode'): ('light', 'dark', 'system'),
           ('git', 'commit_ai'): ('off', 'claude', 'codex', 'ollama')}


class SettingsUI(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rhun-settings-')
        self.work = Path(self.tmp.name).resolve()
        self.config = self.work / 'config/rhun/config'
        self.config.parent.mkdir(parents=True)
        self.env = dict(os.environ, HOME=self.work.as_posix(),
                        XDG_CONFIG_HOME=(self.work / 'config').as_posix(),
                        XDG_STATE_HOME=(self.work / 'state').as_posix())

    def tearDown(self):
        self.tmp.cleanup()

    def configure(self, section='', key='', value=''):
        data = {'ui': {'sidebar': 'false', 'agents_panel': 'false'},
                'editor': {'cursor_blink': 'false'},
                'git': {'enabled': 'false', 'commit_ai': 'off'},
                'updates': {'check': 'false'},
                'files': {'restore_session': 'false', 'restore_project': 'false'}}
        if section:
            data.setdefault(section, {})[key] = str(value)
        self.config.write_text(''.join('[' + s + ']\n' + ''.join(
            k + ' = ' + v + '\n' for k, v in values.items()) for s, values in data.items()),
            encoding='utf-8')

    def run_editor(self, actions, height=3800, width=1400):
        script = self.work / 'actions.rsc'
        script.write_text('\n'.join(['cmd settings', *actions, 'quit']) + '\n', encoding='utf-8')
        result = subprocess.run([str(EXE), self.work.as_posix(), '--headless', f'{width}x{height}',
                                 '--scale', '1', '--script', script.as_posix()],
                                env=self.env, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
        self.assertNotIn(b'unknown', result.stdout)
        return result.stdout.decode('utf-8')

    def value(self, section, key):
        config = configparser.ConfigParser(interpolation=None, strict=False)
        config.read(self.config, encoding='utf-8')
        return config.get(section, key)

    def row_y(self, section, key):
        y, previous = 228, None
        for sec, name, _ in ROWS:
            if sec != previous:
                y += 48
                previous = sec
            if (sec, name) == (section, key):
                return y + 32
            y += 72
        self.fail(f'unknown row {section}.{key}')

    def compact_row_y(self, section, key):
        y, previous = 228, None
        for sec, name, kind in ROWS:
            if sec != previous:
                y += 48
                previous = sec
            if (sec, name) == (section, key):
                return y + 88
            y += (80 + 32 * len(CHOICES[(sec, name)]) if kind == 'ST_CHOICE' else 112) + 8
        self.fail(f'unknown row {section}.{key}')

    def test_compact_rows_keep_strings_and_every_choice_reachable(self):
        for (section, key), value in STRINGS.items():
            with self.subTest(setting=f'{section}.{key}'):
                self.configure(section, key, 'original')
                y = self.compact_row_y(section, key)
                self.run_editor([f'click 240 {y}', f'key {MOD}+a', 'type ' + value,
                                 'key Return'], width=480, height=6500)
                self.assertEqual(self.value(section, key), value)
        for (section, key), choices in CHOICES.items():
            for index, value in enumerate(choices):
                with self.subTest(setting=f'{section}.{key}', value=value):
                    self.configure()
                    y = self.compact_row_y(section, key) + index * 32
                    self.run_editor([f'click 240 {y}'], width=480, height=6500)
                    self.assertEqual(self.value(section, key), value)

    def test_inventory_requires_cases_for_every_setting(self):
        expected = {(s, k) for s, names in BOOLS.items() for k in names.split()}
        expected |= set(INTS) | set(STRINGS) | set(CHOICES)
        expected |= {('ui', 'light_theme'), ('ui', 'dark_theme'), ('git', 'ai_setup'),
                     ('updates', 'check_now')}
        self.assertEqual(expected, {(s, k) for s, k, _ in ROWS})

    def test_every_boolean_toggles_both_ways(self):
        for section, names in BOOLS.items():
            for key in names.split():
                for initial in ('false', 'true'):
                    with self.subTest(setting=f'{section}.{key}', initial=initial):
                        # Keep panels closed when locating other controls.
                        self.configure(section, key, initial)
                        x = 1027
                        if section == 'ui' and key == 'sidebar' and initial == 'true':
                            x += 120
                        if section == 'ui' and key == 'agents_panel' and initial == 'true':
                            x -= 190
                        self.run_editor([f'click {x} {self.row_y(section, key)}'])
                        self.assertEqual(self.value(section, key),
                                         'true' if initial == 'false' else 'false')

    def test_every_stepper_increases_decreases_and_clamps(self):
        for (section, key), (minimum, maximum, step) in INTS.items():
            for initial, direction, expected in [(minimum, '+', minimum + step),
                                                  (maximum, '-', maximum - step),
                                                  (minimum, '-', minimum),
                                                  (maximum, '+', maximum)]:
                with self.subTest(setting=f'{section}.{key}', value=initial, direction=direction):
                    self.configure(section, key, initial)
                    # Scale changes geometry before the first click.
                    scale = float(initial) if (section, key) == ('ui', 'scale') else 1.
                    column = min(round(720 * scale), 1400 - round(64 * scale))
                    compact = column < round(640 * scale)
                    if compact:
                        column = 1400 - round(16 * scale)
                    right = (1400 + column) // 2 - round(16 * scale)
                    x = right - round((14 if direction == '+' else 106) * scale)
                    base_y = self.compact_row_y(section, key) if compact else self.row_y(section, key)
                    y = round(base_y * scale)
                    self.run_editor([f'click {x} {y}'])
                    self.assertAlmostEqual(float(self.value(section, key)), expected, places=2)

    def test_every_string_commits_enter_cancels_escape_and_commits_blur(self):
        for (section, key), value in STRINGS.items():
            for finish, expected in [('key Return', value), ('key Escape', 'original'),
                                     ('click 350 90', value)]:
                with self.subTest(setting=f'{section}.{key}', finish=finish):
                    self.configure(section, key, 'original')
                    self.run_editor([f'click 900 {self.row_y(section, key)}', f'key {MOD}+a',
                                     'type ' + value, finish])
                    self.assertEqual(self.value(section, key), expected)

    def test_every_choice_segment(self):
        # Pixel widths of the built-in 13 point font plus the documented 24 point padding.
        widths = {('ui', 'decorations'): (55, 55, 78),
                  ('ui', 'theme_mode'): (54, 53, 106),
                  ('git', 'commit_ai'): (45, 92, 59, 116)}
        for (section, key), options in CHOICES.items():
            for index, option in enumerate(options):
                with self.subTest(setting=f'{section}.{key}', option=option):
                    self.configure(section, key, options[(index + 1) % len(options)])
                    parts = widths[section, key]
                    x = 1044 - sum(parts) + sum(parts[:index]) + parts[index] // 2
                    self.run_editor([f'click {x} {self.row_y(section, key)}'])
                    self.assertEqual(self.value(section, key), option)

    def test_light_and_dark_theme_settings_accept_matching_themes(self):
        self.configure()
        light_y = self.row_y('ui', 'light_theme')
        dark_y = self.row_y('ui', 'dark_theme')
        self.run_editor([f'click 1000 {light_y}', 'type github', 'key Return'])
        self.assertEqual(self.value('ui', 'light_theme'), 'github-light')
        self.assertEqual(self.value('ui', 'dark_theme'), 'rhun-dark')
        self.run_editor([f'click 1000 {dark_y}', 'type github', 'key Return'])
        self.assertEqual(self.value('ui', 'dark_theme'), 'github-dark')
        self.assertEqual(self.value('ui', 'theme_mode'), 'dark')

    def test_global_theme_picker_updates_mode_and_cancel_restores_selection(self):
        self.configure()
        output = self.run_editor(['cmd select_theme', 'type github', 'key Down', 'print-state',
                                  'key Escape', 'print-state', 'cmd select_theme',
                                  'type github light', 'key Return', 'print-state'])
        states = [line for line in output.splitlines() if line.startswith('tabs=')]
        self.assertIn('theme=github-light', states[0])
        self.assertIn('theme=rhun-dark', states[1])
        self.assertIn('theme=github-light', states[2])
        self.assertEqual(self.value('ui', 'light_theme'), 'github-light')
        self.assertEqual(self.value('ui', 'theme_mode'), 'light')

    def test_theme_mode_uses_the_matching_theme_setting(self):
        self.configure()
        self.config.write_text('[ui]\nlight_theme = github-light\ndark_theme = github-dark\n'
                               'theme_mode = dark\nsidebar = false\nagents_panel = false\n',
                               encoding='utf-8')
        parts = (54, 53, 106)
        row_y = self.row_y('ui', 'theme_mode')
        x_light = 1044 - sum(parts) + parts[0] // 2
        x_dark = 1044 - sum(parts) + parts[0] + parts[1] // 2
        x_system = 1044 - parts[2] // 2
        output = self.run_editor([f'click {x_light} {row_y}', 'print-state',
                                  f'click {x_dark} {row_y}', 'print-state',
                                  f'click {x_system} {row_y}', 'print-state'])
        states = [line for line in output.splitlines() if line.startswith('tabs=')]
        self.assertIn('theme=github-light', states[0])
        self.assertIn('theme=github-dark', states[1])
        self.assertRegex(states[2], r'theme=github-(?:light|dark)')
        self.assertEqual(self.value('ui', 'theme_mode'), 'system')

    def test_legacy_theme_setting_migrates_on_startup(self):
        self.config.write_text('[ui]\ntheme = github-light\n', encoding='utf-8')
        output = self.run_editor(['print-state'])
        self.assertIn('theme=github-light', output)

    def test_open_settings_file_button(self):
        self.configure()
        output = self.run_editor(['click 995 162', 'print-state', 'print-doc'])
        self.assertIn('active=config ', output)
        self.assertIn('[editor]', output)

    def test_scroll_reaches_last_row_and_returns_to_top(self):
        self.configure()
        shot = self.work / 'bottom.ppm'
        top = self.work / 'top.ppm'
        returned = self.work / 'returned.ppm'
        output = self.run_editor(['move 900 400', f'shot {top.as_posix()}',
                                  'scroll 10000', f'shot {shot.as_posix()}',
                                  'scroll -10000', f'shot {returned.as_posix()}',
                                  'click 995 162', 'print-state'], height=700)
        self.assertNotEqual(top.read_bytes(), shot.read_bytes(), 'scroll never reached lower rows')
        self.assertEqual(top.read_bytes(), returned.read_bytes(), 'scroll never returned to top')
        self.assertIn('active=config ', output)

    def test_local_model_button_with_provider_off(self):
        self.configure()
        output = self.run_editor([f'click 1000 {self.row_y("git", "ai_setup")}', 'print-ai'])
        self.assertIn('AI commit messages are off.', output)

    def test_check_now_button_uses_local_release_fixture(self):
        self.configure()
        requests = []
        version = (ROOT / 'VERSION').read_bytes()
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append(self.path)
                self.send_response(200)
                self.send_header('Content-Length', str(len(version)))
                self.end_headers()
                self.wfile.write(version)
            def log_message(self, *args):
                pass
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.env['RHUN_RELEASES_URL'] = f'http://127.0.0.1:{server.server_port}'
        try:
            output = self.run_editor([f'click 1000 {self.row_y("updates", "check_now")}',
                                      'wait-update', 'print-update'])
            self.assertIn('/latest/download/VERSION', requests)
            self.assertIn('desc=The latest version (checked just now)', output)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == '__main__':
    unittest.main(verbosity=2)
