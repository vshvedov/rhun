#!/usr/bin/env python3
"""End to end: rhun-editor/showcase installed the way a user installs it, then every one of its
features used and checked. By default the extension comes from GitHub (Install from GitHub with
rhun-editor/showcase, the real download and checksum); SHOWCASE_DIR=PATH instead lays out a local
build (the showcase repository's folder with bin/ built) so the test runs before a release exists.

Each run gets its own HOME and config. The second session checks what an installed extension
does without being asked: it starts by itself, keeps its settings, and its theme and grammar are
there; then Remove deletes it."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
EXE = Path(os.environ.get('RHUN_TEST_EXE', ROOT / 'build/rhun')).resolve()
LOCAL = os.environ.get('SHOWCASE_DIR')
TARGET = 'windows-x64' if os.name == 'nt' else 'macos-arm64' if sys.platform == 'darwin' else 'linux-x86_64'
# rhun's terminal runs a POSIX shell, or PowerShell on Windows; the showcase suggests each its own form
TERM_DEMO = 'echo "Showcase ran this: $(6 * 7)"' if os.name == 'nt' else 'echo "Showcase ran this: $((6 * 7))"'
CONFIG = ('[ui]\nsidebar = false\nagents_panel = false\n[editor]\ncursor_blink = false\n'
          '[files]\nrestore_session = false\nrestore_project = false\n'
          '[updates]\ncheck = false\n[git]\nenabled = false\n')
NOTES = ('# Notes\n'
         'shopping list and other words\n'
         'TODO: buy milk\n'
         'x = 1  # FIXME off by one\n'
         'NOTE the shop closes early\n'
         'IDEA: a bigger fridge\n')


class Showcase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='rhun-showcase-')
        cls.work = Path(cls.tmp.name).resolve()
        cls.proj = cls.work / 'proj'
        cls.proj.mkdir()
        (cls.proj / 'notes.md').write_text(NOTES, encoding='utf-8')
        (cls.proj / 'README.md').write_text('# The project\n\nRead me first.\n', encoding='utf-8')
        (cls.proj / 'demo.showcase').write_text('# a tour script\nstep "one"\nsay greeting\n', encoding='utf-8')
        cfg = cls.work / 'config/rhun'
        cfg.mkdir(parents=True)
        (cfg / 'config').write_text(CONFIG, encoding='utf-8')
        cls.ext_dir = cfg / 'extensions/rhun-editor/showcase'
        cls.env = dict(os.environ, HOME=cls.work.as_posix(), XDG_CONFIG_HOME=(cls.work / 'config').as_posix(),
                       XDG_STATE_HOME=(cls.work / 'state').as_posix())
        cls.env.pop('RHUN_EXT_BASE', None)
        if LOCAL:
            # a local build laid out as a release would install it
            src = Path(LOCAL).resolve()
            cls.ext_dir.mkdir(parents=True)
            for name in ('extension.ini', 'README.md', 'LICENSE', 'icon.png'):
                shutil.copy(src / name, cls.ext_dir / name)
            for d in ('themes', 'syntax', 'bin'):
                shutil.copytree(src / d, cls.ext_dir / d)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def session(self, lines, size='1100x800'):
        """runs the script; returns the output split at 'echo @label' lines into {label: [lines]}"""
        script = self.work / 'script.rsc'
        script.write_text('\n'.join(['wait 100', *lines, 'quit']) + '\n', encoding='utf-8')
        r = subprocess.run([str(EXE), self.proj.as_posix(), '--headless', size, '--scale', '1',
                            '--script', script.as_posix()], env=self.env, capture_output=True, timeout=600)
        self.assertEqual(r.returncode, 0, r.stderr.decode(errors='replace')[-2000:])
        out, label = {}, None
        for line in r.stdout.decode('utf-8', errors='replace').splitlines():
            if line.startswith('@'):
                label = line[1:]
                out[label] = []
            elif label:
                out[label].append(line)
        return out

    def cell(self, line, col, file='notes.md'):
        out = self.session([f'open {self.proj / file}', 'echo @cell', f'print-text-cell {line} {col}'])
        return out['cell'][0]

    def test_1_install_and_use_everything(self):
        x_y = self.cell(3, 12)              # "milk" on the TODO line
        W = ['wait 300', 'wait 300']
        steps = [f'open {self.proj / "notes.md"}']
        if not LOCAL:
            steps += ['echo @install', 'ext-install rhun-editor/showcase', 'wait-install',
                      'echo @dialog', 'print-dialog', 'dialog yes']
        steps += [
            'wait-ext showcase running', *W, *W,
            'echo @running', 'print-extensions',
            'echo @live_marks', 'print-marks',
            # greet: the Greeting setting at the cursor
            'key ctrl+Home', 'cmd showcase.greet', *W, 'echo @greet', 'print-doc',
            # change case: select "shopping list" on line 2
            'key ctrl+Home', 'key Down', 'key Home', *['key shift+Right'] * 13, *W,
            'cmd showcase.shout', *W, 'echo @shout', 'print-doc',
            # wrap: the same text, still selected after the replace? select again
            'key Home', *['key shift+Right'] * 13, *W,
            'cmd showcase.wrap', *W, 'echo @wrap', 'print-doc',
            'cmd showcase.stats', *W, 'echo @stats', 'print-toast',
            'cmd showcase.clear', *W, 'echo @cleared', 'print-marks',
            'cmd showcase.marks', *W, 'echo @marked', 'print-marks',
            'key ctrl+Home', *W, 'cmd showcase.next', *W, 'echo @next', 'print-state',
            # hover: the pointer rests on "milk"
            f'move {x_y}', 'wait 900', *W, 'echo @hover', 'print-hover', 'wait 700', 'print-tip',
            'move 5 5',
            # ask
            'key ctrl+End', *W, 'cmd showcase.hello', *W, 'echo @ask', 'print-palette',
            'type Ada', 'key Return', *W, 'echo @asked', 'print-doc',
            # the tour's pick list
            'cmd showcase.tour', *W, 'echo @tour', 'print-palette', 'key Escape', *W,
            # option: the tab width from the settings
            'cmd showcase.indent', *W, 'echo @indent', 'print-options', 'print-toast',
            # cmd: rhun's own command
            'cmd showcase.wordwrap', *W, 'echo @wordwrap', 'print-toast',
            # register: a command added while running
            'cmd showcase.more', *W, 'echo @more', 'print-extensions', 'print-toast',
            # a setting changed on its page reaches the program
            'ext-setting showcase greeting Bonjour', *W, 'key ctrl+End', 'cmd showcase.greet', *W,
            'echo @setting', 'print-doc',
            # the extension's page
            'ext-page showcase', *W, 'echo @page', 'print-ext-page',
            # pin it: its button joins the title bar
            'ext-set showcase pinned 1', 'echo @pinned', 'print-extbar',
            # open: the project's README
            'cmd showcase.readme', *W, 'echo @readme', 'print-state',
            # term: a command for the terminal, run with Enter
            'cmd showcase.terminal', *W, 'echo @term', 'print-palette', 'wait 600', 'key Return',
            'wait-term ran this: 42', 'echo @termran', 'print-term',
        ]
        out = self.session(steps, size='1100x800')

        if not LOCAL:
            self.assertEqual(out['install'], ['install=asking'])
            self.assertEqual(out['dialog'][0], 'dialog=Add “Showcase”?')
            self.assertTrue(out['dialog'][1].startswith('text=Version '), out['dialog'])
            self.assertIn('from github.com/rhun-editor/showcase. It can read and change the files you have open, '
                          'read the files in your project, suggest terminal commands for you to run.',
                          out['dialog'][1])
            self.assertEqual(out['dialog'][2], 'button=Add extension')
        self.assertTrue(self.ext_dir.joinpath('extension.ini').exists())

        running = out['running'][0]
        self.assertIn('rhun-editor/showcase state=running', running)
        self.assertIn('status=Showcase: 27 words', running)
        held = ' confined=1' if sys.platform == 'darwin' else ' confined='
        self.assertIn(held, running)
        if os.name == 'nt':
            self.assertIn('why=Windows cannot hold an extension to its permissions yet', running)

        marks = out['live_marks']
        self.assertIn('3 1 3 15 warning rhun-editor/showcase TODO: buy milk', marks)
        self.assertIn('4 10 4 26 error rhun-editor/showcase FIXME: off by one', marks)
        self.assertIn('5 1 5 27 info rhun-editor/showcase NOTE: the shop closes early', marks)
        self.assertIn('6 1 6 22 hint rhun-editor/showcase IDEA: a bigger fridge', marks)
        self.assertIn('errors=1 warnings=1', marks)

        self.assertEqual(out['greet'][0], 'Hello from the Showcase extension!# Notes')
        self.assertEqual(out['shout'][1], 'SHOPPING LIST and other words')
        self.assertEqual(out['wrap'][1], '(SHOPPING LIST) and other words')
        self.assertRegex(out['stats'][0], r'^toast=6 lines, \d+ words, \d+ characters; \d+ edits seen since rhun started$')
        self.assertEqual(out['cleared'], ['errors=0 warnings=0'])
        self.assertIn('errors=1 warnings=1', out['marked'])
        self.assertIn('line=3 col=5', out['next'][0])          # TODO selected: the cursor after it
        self.assertIn('sel=4', out['next'][0])
        self.assertEqual(out['hover'][0], 'hover=1 3 12 sent=1 text=“milk” appears 1 time in this file')
        # the word is under a mark: the tooltip shows the mark's message and the answer together
        self.assertEqual(out['hover'][1], 'tip=TODO: buy milk  ·  “milk” appears 1 time in this file')
        self.assertEqual(out['ask'][:2], ['prompt=Who should the Showcase greet?', 'field='])
        self.assertIn('Hello, Ada!', out['asked'])
        self.assertEqual(out['tour'][0], 'choose=Showcase: pick a demo')
        self.assertIn('> Insert a greeting at the cursor (insert)', out['tour'])
        self.assertIn('  Add a command while running (register)', out['tour'])
        self.assertEqual(out['indent'][0], 'tab_width=2 insert_spaces=1 trim_trailing_whitespace=0 final_newline=1')
        self.assertEqual(out['indent'][1], 'toast=Showcase: this file now indents with 2 spaces')
        self.assertEqual(out['wordwrap'][0], 'toast=Showcase: word wrap toggled through rhun\'s own command')
        self.assertIn(',showcase.more,showcase.time ', out['more'][0])
        self.assertEqual(out['more'][1], 'toast=Showcase: added Insert the Time (Showcase) to the command palette')
        self.assertTrue(any(l.endswith('Bonjour') for l in out['setting']), out['setting'])
        page = out['page']
        self.assertTrue(page[0].startswith('Showcase ') and page[0].endswith(' on'), page)
        self.assertIn('can: read and change the files you have open, read the files in your project, '
                      'suggest terminal commands for you to run', page)
        self.assertIn('setting greeting=Bonjour', page)
        self.assertIn('setting case=upper', page)
        self.assertIn('setting tab_width=2', page)
        self.assertIn('badge=icon color=#2a9d8f', page)     # its icon on its color
        self.assertEqual(out['pinned'], ['menu=closed', 'pinned=showcase'])
        self.assertIn('active=README.md', out['readme'][0])
        self.assertEqual(out['term'][:2], ['prompt=Run in the terminal: Enter, or Esc',
                                          'field=' + TERM_DEMO])
        self.assertTrue(any(l.rstrip().endswith('Showcase ran this: 42') for l in out['termran']), out['termran'])
        ini = (self.work / 'config/rhun/extensions.ini').read_text(encoding='utf-8')
        self.assertIn('[rhun-editor/showcase]\npinned = yes\nsetting.greeting = Bonjour\n', ini)

    def test_2_it_runs_by_itself_keeps_its_settings_and_goes_when_removed(self):
        if not self.ext_dir.exists():
            self.skipTest('the install failed')
        W = ['wait 300', 'wait 300']
        out = self.session([
            f'open {self.proj / "demo.showcase"}', 'wait-ext showcase running', *W,
            'echo @state', 'print-state', 'print-extbar',
            'key ctrl+End', 'cmd showcase.greet', *W, 'echo @greet', 'print-doc',
            'cmd select_theme', 'type showcase dusk', *W, 'echo @themes', 'print-palette', 'key Escape',
            'ext-remove showcase', 'echo @remove', 'print-dialog', 'dialog yes', *W,
            'echo @removed', 'print-extensions', 'print-toast', 'print-extbar',
        ])
        self.assertIn('lang=Showcase Script', out['state'][0])     # its grammar
        self.assertEqual(out['state'][2], 'pinned=showcase')
        self.assertTrue(any(l.endswith('Bonjour') for l in out['greet']), out['greet'])
        self.assertIn('> Showcase Dusk', out['themes'])               # its theme
        self.assertEqual(out['remove'][0], 'dialog=Remove “Showcase”?')
        self.assertFalse(any(l.startswith('rhun-editor/showcase') for l in out['removed']), out['removed'])
        self.assertIn('toast=Removed Showcase', out['removed'])
        self.assertIn('pinned=', out['removed'])
        self.assertFalse(self.ext_dir.exists())
        self.assertFalse((self.work / 'state/rhun/extensions/rhun-editor--showcase').exists())


if __name__ == '__main__':
    unittest.main()
