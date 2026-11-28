#!/usr/bin/env python3
"""Breakpoints and the paused line in the editor (src/app/debuggutter.s on the presentation group's
gutter lanes): the glyph of each kind of breakpoint, clicks and the right-click menu in the left
lane, glyphs moving with edits, the current line's arrow and background. The adapter is
tests/dap/fakedap.py."""
import unittest
import debughost

GS_DOT, GS_RING, GS_DIAMOND, GS_ARROW, GS_CIRCLE_BAR, GS_CIRCLE_TRI = 1, 3, 5, 12, 13, 14


class Gutter(debughost.DebugHost):
    def glyphs(self, out):
        """{(line, kind): shape} from print-present glyphs (lines one-based)"""
        res = {}
        for l in out:
            if l.startswith('glyph '):
                parts = l.split()
                res[(int(parts[1]), int(parts[2].split('=')[1]))] = int(parts[3].split('=')[1])
        return res

    def lane_y(self, line, out_xy):
        return int(out_xy.split()[1])

    def test_glyph_per_breakpoint_kind(self):
        a = self.src
        out = self.run_editor(['bp %s 2' % a, 'bp %s 3 cond=b == 1' % a, 'bp %s 6 hits=2' % a,
                               'bp %s 8 log=x' % a, 'bp %s 9' % a, 'bp-enable %s 9 0' % a, 'wait 50',
                               'print-present glyphs'])
        g = self.glyphs(out)
        shapes = {line: shape for (line, kind), shape in g.items()}
        self.assertEqual(shapes, {2: GS_DOT, 3: GS_CIRCLE_BAR, 6: GS_CIRCLE_BAR, 8: GS_DIAMOND, 9: GS_DOT})

    def test_session_states_on_glyphs(self):
        self.launch_ini()
        out = self.run_editor(['bp %s 5' % self.src, 'bp %s 3 cond=b == 1' % self.src, 'bp %s 2' % self.src,
                               'debug-start Run', 'dialog yes', 'wait-debug paused', 'wait 50',
                               'print-present glyphs'], mode='no-cond-caps')
        g = self.glyphs(out)
        kinds = {}
        for (line, kind), shape in g.items():
            kinds.setdefault(line, {})[kind] = shape
        # line 5 has no code: a ring; line 3's condition is rejected; line 2: the arrow over the dot
        self.assertIn(GS_RING, kinds[5].values())
        self.assertIn(GS_CIRCLE_TRI, kinds[3].values())
        self.assertIn(GS_ARROW, kinds[2].values())
        self.assertIn(GS_DOT, kinds[2].values())

    def test_arrow_follows_the_stop(self):
        self.scenario()
        self.launch_ini('[Run]\ntype = fake\nprogram = scenario.json\nstopOnEntry = yes\n')
        out = self.run_editor([*self.start(), 'wait-debug paused', 'wait 50', 'print-present glyphs', 'echo --',
                               'debug-step over', 'wait-debug paused', 'wait 50', 'print-present glyphs', 'echo --',
                               'debug-stop', 'wait-debug ended', 'wait 50', 'print-present glyphs'])
        first = self.glyphs(out[:out.index('--')])
        self.assertEqual([l for (l, k), s in first.items() if s == GS_ARROW], [6])
        rest = out[out.index('--') + 1:]
        second = self.glyphs(rest[:rest.index('--')])
        self.assertEqual([l for (l, k), s in second.items() if s == GS_ARROW], [8])
        third = self.glyphs(rest[rest.index('--') + 1:])
        self.assertEqual([l for (l, k), s in third.items() if s == GS_ARROW], [])

    def test_current_line_background(self):
        self.scenario()
        self.launch_ini('[Run]\ntype = fake\nprogram = scenario.json\nstopOnEntry = yes\n')
        shot = self.work / 'paused.ppm'
        out = self.run_editor([*self.start(), 'wait-debug paused', 'key ctrl+End', 'print-xy 6 1',
                               'print-xy 7 1', 'shot ' + shot.as_posix()])
        x6, y6 = map(int, out[-2].split())
        x7, y7 = map(int, out[-1].split())
        host = __import__('ext-host')
        paused = host.ppm_pixel(shot, x6 + 300, y6)       # past the text: the background alone
        plain = host.ppm_pixel(shot, x7 + 300, y7)
        self.assertNotEqual(paused, plain)

    def test_clicks_in_the_left_lane(self):
        out = self.run_editor(['print-xy 3 1', 'print-xy 4 1'])
        y3 = int(out[0].split()[1])
        y4 = int(out[1].split()[1])
        a = self.src
        out = self.run_editor(['print-hit 6 %d' % y3, 'click 6 %d' % y3, 'print-bps', 'echo --',
                               'click 6 %d' % y3, 'print-bps', 'echo --', 'click 6 %d' % y4,
                               'click 6 %d right' % y4, 'print-menu'])
        self.assertEqual(out[0], 'left-lane 3')
        self.assertEqual(out[1], '%s 3 enabled=1 cond= hits= log= verified=- line=0 msg=' % a)
        self.assertEqual(out[3], '--')                   # the second click removed it
        self.assertEqual(out[-7:], ['Edit Condition...', 'Edit Hit Count...', 'Edit Log Message...',
                                    'Enable or Disable Breakpoint', 'Remove Breakpoint', '-', 'Run to Line'])

    def test_menu_on_an_empty_line(self):
        out = self.run_editor(['print-xy 6 1'])
        y6 = int(out[0].split()[1])
        out = self.run_editor(['click 6 %d right' % y6, 'print-menu', 'menu-pick Add Conditional Breakpoint...',
                               'type total == 2', 'key Return', 'print-bps'])
        self.assertEqual(out[:3], ['Add Breakpoint', 'Add Conditional Breakpoint...', 'Add Logpoint...'])
        self.assertEqual(out[-1], '%s 6 enabled=1 cond=total == 2 hits= log= verified=- line=0 msg=' % self.src)

    def test_menu_remove_and_disable(self):
        out = self.run_editor(['print-xy 6 1'])
        y6 = int(out[0].split()[1])
        out = self.run_editor(['bp %s 6' % self.src, 'click 6 %d right' % y6,
                               'menu-pick Enable or Disable Breakpoint', 'print-bps',
                               'click 6 %d right' % y6, 'menu-pick Remove Breakpoint', 'print-bps', 'echo end'])
        self.assertEqual(out, ['%s 6 enabled=0 cond= hits= log= verified=- line=0 msg=' % self.src, 'end'])

    def test_glyphs_move_with_edits(self):
        out = self.run_editor(['bp %s 3' % self.src, 'key ctrl+Home', 'key Return', 'key Return', 'wait 50',
                               'print-present glyphs', 'print-bps'])
        self.assertEqual(list(self.glyphs(out)), [(5, list(self.glyphs(out))[0][1])])
        self.assertIn('%s 5 enabled=1' % self.src, out[-1])

    def hover_setup(self):
        h = self.proj / 'h.c'
        h.write_text('int f(void) {\n    return p->x + p.y + total;\n}\n')
        steps = [{'file': h.as_posix(), 'line': 2, 'function': 'f',
                  'locals': {'total': 3, 'p': {'x': 1, 'y': 2}}}]
        self.scenario(steps)
        self.launch_ini('[Run]\ntype = fake\nprogram = scenario.json\nstopOnEntry = yes\n')
        return h

    def hover_at(self, col, extra=()):
        self.hover_setup()
        out = self.run_editor([*self.start(), 'wait-debug paused', 'print-xy 2 %d' % col], files=('h.c',))
        x, y = map(int, out[-1].split())
        out = self.run_editor([*self.start(), 'wait-debug paused', *extra, 'move %d %d' % (x + 2, y), 'wait 700',
                               'wait 600', 'print-debug-hover', 'print-tip'], files=('h.c',))
        return out

    def test_hover_on_a_name(self):
        out = self.hover_at(26)                         # total
        # the value shows in the debugger's card (debug-view.py), which takes the tooltip's place
        self.assertEqual(out[-2:], ['total = 3  int', 'tip='])

    def test_hover_on_a_member_chain(self):
        out = self.hover_at(15)                         # the x of p->x
        self.assertEqual(out[-2], 'p->x = 1  int')
        out = self.hover_at(21)                         # the y of p.y
        self.assertEqual(out[-2], 'p.y = 2  int')
        self.assertIn('"context": "hover"', ' '.join(self.requests()))

    def test_no_hover_on_blanks_or_while_running(self):
        out = self.hover_at(2)
        self.assertEqual(out[-2], 'none')
        out = self.hover_at(26, extra=['debug-continue', 'wait-debug ended'])
        self.assertEqual(out[-2], 'none')

    def test_hover_on_the_selection(self):
        out = self.hover_at(19, extra=['key ctrl+Home', 'key Down', *(['key Right'] * 18),
                                       'key shift+Right', 'key shift+Right', 'key shift+Right'])
        self.assertEqual(out[-2], 'p.y = 2  int')        # the selected text, not the word p

if __name__ == '__main__':
    unittest.main()
