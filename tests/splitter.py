#!/usr/bin/env python3
"""Panel dividers keep their presses and cursors, scrollbars hide when idle (unless that setting is
off), and nearby tooltips skip the delay. A press inside a divider's strip resizes the panel and
must not turn into a text selection, open the file under it or lose the next click."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
EXE = Path(os.environ.get('RHUN_TEST_EXE', ROOT / 'build/rhun')).resolve()
CUR_TEXT, CUR_EW, CUR_NS, CUR_ARROW = 1, 3, 4, 7
W = 1000


class SidebarSplit(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rhun-splitter-')
        self.work = Path(self.tmp.name).resolve()
        # project is a clean subdir: config/state churn in work would redraw the explorer
        self.proj = self.work / 'proj'
        self.proj.mkdir()
        self.file = self.proj / 'words.txt'
        self.file.write_text('\n'.join('word%d some text to select and drag over' % i
                                     for i in range(200)), encoding='utf-8')
        self.config = self.work / 'config/rhun/config'
        self.config.parent.mkdir(parents=True)
        self.env = dict(os.environ, HOME=self.work.as_posix(),
                        XDG_CONFIG_HOME=(self.work / 'config').as_posix(),
                        XDG_STATE_HOME=(self.work / 'state').as_posix())

    def tearDown(self):
        # Windows releases a child's handle on the project dir a beat after the
        # process exits; retry instead of erroring out of cleanup (WinError 32)
        for attempt in range(25):
            try:
                self.tmp.cleanup()
                return
            except PermissionError:
                if attempt == 24:
                    raise
                time.sleep(0.2)

    def run_editor(self, actions, agents=False, autohide=True):
        self.config.write_text('[ui]\nsidebar = true\nsidebar_width = 240\nagents_panel = %s\n'
                               'auto_hide_scrollbars = %s\n'
                               '[editor]\ncursor_blink = false\n'
                               '[files]\nrestore_session = false\nrestore_project = false\n'
                               '[updates]\ncheck = false\n[git]\nenabled = false\n'
                               % (str(agents).lower(), str(autohide).lower()), encoding='utf-8')
        script = self.work / 'actions.rsc'
        script.write_text('\n'.join([*actions, 'quit']) + '\n', encoding='utf-8')
        result = subprocess.run([str(EXE), self.proj.as_posix(), self.file.as_posix(),
                                 '--headless', '%dx700' % W, '--scale', '1',
                                 '--script', script.as_posix()],
                                env=self.env, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
        out = result.stdout.decode('utf-8')
        self.assertNotIn('unknown command', out)
        return out

    def values(self, actions, **options):
        """echo NAME= before a print command; returns {NAME: its output line}"""
        lines = self.run_editor(actions, **options).splitlines()
        return {lines[i][:-1]: lines[i + 1]
                for i in range(len(lines) - 1) if lines[i].endswith('=')}

    def shots(self, actions, **options):
        """shot{N} in actions takes screenshot N; returns their pixels"""
        paths = {}
        def shot(action):
            if action.startswith('shot{'):
                n = int(action[5:-1])
                paths[n] = self.work / ('%d.ppm' % n)
                return 'shot ' + paths[n].as_posix()
            return action
        self.run_editor([shot(a) for a in actions], **options)
        return [paths[n].read_bytes().split(b'\n', 3)[3] for n in sorted(paths)]

    def config_value(self, key):
        return int(next(l.split('=')[1] for l in self.config.read_text(encoding='utf-8').splitlines()
                        if l.strip().startswith(key)))

    @staticmethod
    def px(pixels, x, y):
        return pixels[(y * W + x) * 3:(y * W + x) * 3 + 3]

    @staticmethod
    def changed(a, b):
        return {(i // 3 % W, i // 3 // W) for i in range(0, len(a), 3) if a[i:i + 3] != b[i:i + 3]}

    # the sidebar divider at x=240

    def test_drag_from_editor_side_resizes_without_selecting(self):
        # the handle's last ~3 px overlap the editor: the press must stay the splitter's
        out = self.run_editor(['wait 200', 'move 242 400', 'down', 'wait 60',
                               'move 330 400', 'wait 60', 'print-state', 'up', 'wait 50'])
        self.assertIn('sel=0', out)
        self.assertEqual(self.config_value('sidebar_width'), 330)

    def test_drag_from_panel_side_resizes(self):
        out = self.run_editor(['wait 200', 'move 238 400', 'down', 'wait 60',
                               'move 330 400', 'wait 60', 'print-state', 'up', 'wait 50'])
        self.assertIn('sel=0', out)
        self.assertEqual(self.config_value('sidebar_width'), 330)

    def test_drag_over_text_keeps_resize_cursor(self):
        # issue #48: the editor's I-beam took over while the drag crossed the text
        v = self.values(['wait 200', 'move 238 400', 'down', 'wait 60', 'move 500 400', 'wait 60',
                         'echo shape=', 'print-shape', 'echo state=', 'print-state', 'up', 'wait 50'])
        self.assertEqual(int(v['shape']), CUR_EW)
        self.assertIn('sel=0', v['state'])
        self.assertEqual(self.config_value('sidebar_width'), 500)

    def test_press_on_explorer_half_does_not_open_a_file(self):
        # the explorer is drawn before the divider: its row under the strip must not take the press
        for i in range(80):
            (self.proj / ('f%02d.txt' % i)).write_text('x\n', encoding='utf-8')
        v = self.values(['wait 200', 'move 238 100', 'down', 'wait 60', 'up', 'wait 60',
                         'echo state=', 'print-state'])
        self.assertIn('tabs=1 ', v['state'])
        self.assertIn('active=words.txt', v['state'])

    def test_editor_drag_still_selects(self):
        out = self.run_editor(['wait 200', 'move 400 400', 'down', 'wait 60',
                               'move 600 400', 'wait 60', 'print-state', 'up', 'wait 50'])
        self.assertNotIn('sel=0', out)

    def test_splitter_hover_draws_accent_line(self):
        a, b = self.shots(['wait 200', 'move 500 400', 'shot{0}', 'move 242 400', 'wait 60', 'shot{1}'])
        diffs = self.changed(a, b)
        self.assertTrue(diffs, 'no divider line on splitter hover')
        self.assertTrue(all(235 <= x <= 246 for x, _ in diffs),
                        'splitter hover changed pixels away from the divider')

    def test_splitter_drag_keeps_ew_cursor_over_scrollbar(self):
        # dragging the splitter across the scrollbar track must not lose the resize cursor
        v = self.values(['wait 200', 'move 238 400', 'down', 'wait 60',
                         'move 990 400', 'wait 60', 'echo split=', 'print-shape', 'up'])
        self.assertEqual(int(v['split']), CUR_EW)

    # the agents panel divider at x=620 (380 pt wide): its editor half overlaps the editor's scrollbar

    def test_agents_divider_drag_from_editor_side(self):
        v = self.values(['wait 300', 'move 618 400', 'down', 'wait 60', 'move 520 400', 'wait 60',
                         'echo shape=', 'print-shape', 'echo state=', 'print-state', 'up', 'wait 50'],
                        agents=True)
        self.assertEqual(int(v['shape']), CUR_EW)
        self.assertIn('sel=0', v['state'])
        self.assertEqual(self.config_value('agents_width'), 480)

    def test_agents_divider_hover_shows_resize_cursor_on_both_halves(self):
        v = self.values(['wait 300', 'move 618 400', 'wait 60', 'echo left=', 'print-shape',
                         'move 621 400', 'wait 60', 'echo right=', 'print-shape'], agents=True)
        self.assertEqual(int(v['left']), CUR_EW, 'the editor scrollbar took the divider hover')
        self.assertEqual(int(v['right']), CUR_EW)

    def test_agents_divider_line_is_as_wide_as_the_sidebar_one(self):
        a, b = self.shots(['wait 300', 'move 500 400', 'shot{0}', 'move 621 300', 'wait 60', 'shot{1}'],
                          agents=True)
        line = {x for x, y in self.changed(a, b) if y == 300}
        self.assertEqual(line, {619, 620})

    def test_terminal_edge_drag_keeps_its_cursor_and_selects_nothing(self):
        v = self.values(['cmd toggle_terminal', 'wait 400', 'move 500 412', 'down', 'wait 60',
                         'move 500 250', 'wait 60', 'echo shape=', 'print-shape',
                         'echo state=', 'print-state', 'up', 'wait 50'])
        self.assertEqual(int(v['shape']), CUR_NS)
        self.assertIn('sel=0', v['state'])

    # a release and the next press can reach one frame (a slow frame, a busy event queue): up-down
    # queues both before the frame, while the first press's owner is still the active widget

    def test_batched_double_click_selects_word(self):
        out = self.run_editor(['wait 200', 'move 420 300', 'down', 'wait 60', 'up-down', 'wait 60',
                               'up', 'wait 60', 'print-state'])
        self.assertIn('sel=2', out)

    def test_batched_press_moves_focus_to_terminal(self):
        out = self.run_editor(['cmd toggle_terminal', 'wait 400', 'move 420 300', 'down', 'wait 60',
                               'move 420 520', 'up-down', 'wait 60', 'up', 'wait 60', 'print-state'])
        self.assertIn('focus=8', out)

    # scrollbars

    def test_cursor_shapes_over_editor_chrome(self):
        v = self.values([
            'wait 200',
            'move 500 400', 'wait 60', 'echo text=', 'print-shape',
            'move 990 300', 'wait 60', 'echo track=', 'print-shape',
            'down', 'wait 60', 'move 500 400', 'wait 60', 'echo sbdrag=', 'print-shape', 'up', 'wait 60'])
        self.assertEqual(int(v['text']), CUR_TEXT, 'I-beam over editor text')
        self.assertEqual(int(v['track']), CUR_ARROW, 'arrow over the scrollbar')
        self.assertEqual(int(v['sbdrag']), CUR_ARROW, 'arrow keeps during the scrollbar drag')

    def test_scrollbar_thumb_shows_on_hover(self):
        # the right 6 px of the track belong to the window-resize edge in CSD mode;
        # hover the left half of the 12 px track (988..994 of a 1000 px window)
        a, b = self.shots(['wait 200', 'move 500 400', 'shot{0}', 'move 990 300', 'wait 60', 'shot{1}'])
        diffs = self.changed(a, b)
        self.assertTrue(diffs, 'thumb did not show on hover')
        self.assertTrue(all(x >= 985 for x, _ in diffs),
                        'hover changed pixels outside the scrollbar track')

    def test_scrollbar_thumb_drag_scrolls(self):
        v = self.values(['wait 200', 'move 990 100', 'down', 'wait 60', 'move 990 500', 'wait 60',
                         'echo shape=', 'print-shape', 'up', 'wait 60', 'click 500 300', 'wait 60',
                         'echo state=', 'print-state'])
        self.assertEqual(int(v['shape']), CUR_ARROW)
        self.assertGreater(int(v['state'].split('line=')[1].split()[0]), 50, v['state'])
        self.assertIn('sel=0', v['state'])

    def test_scrollbar_flashes_on_scroll_then_hides(self):
        a, b, c = self.shots(['wait 200', 'move 500 400', 'shot{0}', 'scroll 600', 'wait 60', 'shot{1}',
                              'wait 1000', 'shot{2}'])
        thumb = [(x, y) for y in (200, 300, 400, 500) for x in range(985, 1000)]
        # scrolling alone reveals the thumb without hovering the track
        self.assertTrue(any(self.px(a, *t) != self.px(b, *t) for t in thumb), 'no thumb flash on scroll')
        self.assertTrue(all(self.px(a, *t) == self.px(c, *t) for t in thumb),
                        'thumb still shown after the flash window')

    def test_scroll_flash_costs_one_frame(self):
        v = self.values(['wait 500', 'print-frames', 'move 500 400', 'scroll 300', 'wait 1500',
                         'print-frames', 'wait 1500', 'echo idle=', 'print-frames'])
        self.assertEqual(v['idle'], 'frames=0')

    def test_without_auto_hide_a_faint_thumb_stays(self):
        hidden, = self.shots(['wait 200', 'move 500 400', 'wait 60', 'shot{0}'])
        shown, hover = self.shots(['wait 200', 'move 500 400', 'wait 60', 'shot{0}',
                                   'move 990 300', 'wait 60', 'shot{1}'], autohide=False)
        resting = self.changed(hidden, shown)
        self.assertTrue(resting, 'no thumb at rest with auto_hide_scrollbars = false')
        self.assertTrue(all(x >= 985 for x, _ in resting))
        # the hovered thumb is wider than the resting one
        self.assertGreater(len(self.changed(hidden, hover)), len(resting))

    # tooltips and buttons

    def test_tooltip_instant_after_first(self):
        # adjacent toolbar tips skip the delay once one is open
        v = self.values(['wait 200', 'move 770 14', 'wait 650', 'echo first=', 'print-tip',
                         'move 810 14', 'wait 60', 'echo second=', 'print-tip'])
        self.assertIn('Terminal', v['first'])
        self.assertIn('Agents', v['second'])

    def test_tooltip_instant_across_the_gap_between_buttons(self):
        actions = ['wait 200', 'move 770 14', 'wait 650']
        actions += ['move %d 14' % x for x in range(772, 812, 4)]
        actions += ['wait 60', 'echo second=', 'print-tip']
        self.assertIn('Agents', self.values(actions)['second'])

    def test_icon_button_press_darkens(self):
        a, b = self.shots(['wait 200', 'move 12 14', 'wait 60', 'shot{0}', 'down', 'wait 60', 'shot{1}',
                           'move 500 400', 'up'])
        self.assertNotEqual(self.px(a, 12, 8), self.px(b, 12, 8), 'button bg did not change on press')


if __name__ == '__main__':
    unittest.main()
