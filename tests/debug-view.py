#!/usr/bin/env python3
"""The debug view (src/app/debugview.s): the Variables, Watch, Call Stack and Breakpoints sidebar
sections and the Debug Console panel tab (views' places and tree widget), driven with the keyboard
as a user would, and the debugger's keys (F5, F9, F10, Shift+F5, Ctrl+Shift+Y) and prompts."""
import re
import unittest
import debughost

IC = {m.group(1): int(m.group(2)) for m in
      re.finditer(r'^\.equ IC_(\w+), (\d+)$', (debughost.ROOT / 'src/rhun.inc').read_text(), re.M)}


class View(debughost.DebugHost):
    def paused(self, extra, mode=None, line=3, files=('a.c',)):
        self.launch_ini()
        return self.run_editor(['bp %s %d' % (self.src, line), *self.start(), 'wait-debug paused', *extra],
                               mode=mode, files=files)

    def rows(self, out, prefix='row '):
        return [l for l in out if l.startswith(prefix)]

    def test_places_appear_with_a_session(self):
        out = self.paused(['print-sidebar', 'print-panel-tabs'])
        names = [l.split(' ')[0] for l in out]
        for name in ('debug.variables', 'debug.watch', 'debug.callstack', 'debug.breakpoints', 'debug.console'):
            self.assertIn(name, names)
        console = [l for l in out if l.startswith('debug.console')][0]
        self.assertIn('chosen', console)

    def test_hide_and_show(self):
        out = self.paused(['key ctrl+shift+y', 'print-sidebar', 'echo --', 'key ctrl+shift+y', 'print-sidebar'])
        first = out[:out.index('--')]
        self.assertFalse([l for l in first if l.startswith('debug.variables') and 'visible' in l], first)
        second = out[out.index('--'):]
        self.assertTrue([l for l in second if l.startswith('debug.variables') and 'visible' in l], second)

    def test_variables_tree(self):
        out = self.paused(['print-debug-tree variables'], line=9)
        rows = self.rows(out)
        self.assertIn('id=Locals label=Locals', rows[0])
        self.assertTrue(any('id=Locals/total label=total = 3 desc=int' in r for r in rows), rows)
        p = [r for r in rows if 'id=Locals/p ' in r][0]
        self.assertIn(' closed ', p)
        self.assertTrue(any('id=Globals' in r and ' closed ' in r for r in rows), rows)

    def test_opening_a_variable_with_the_keyboard(self):
        out = self.paused(['view-focus debug.variables', 'key Down', 'key Down', 'key Down', 'key Right',
                           'wait 300', 'print-debug-tree variables', 'print-vars'], line=9)
        rows = self.rows(out)
        self.assertTrue(any('id=Locals/p/x label=x = 1 desc=int' in r for r in rows), rows)
        self.assertIn('    x = 1 : int', out)

    def test_watch_section(self):
        out = self.paused(['debug-watch add total', 'debug-watch add nosuch', 'wait 300',
                           'print-debug-tree watch', 'view-focus debug.watch', 'key Down', 'key Down', 'key Delete',
                           'wait 200', 'print-debug-tree watch', 'print-watch'], line=9)
        rows = self.rows(out)
        self.assertIn('id=watch:total label=total = 3 desc=int', rows[0])
        self.assertIn("id=watch:nosuch label=nosuch = name 'nosuch' is not defined", rows[1])
        self.assertEqual(len(rows), 3, rows)               # nosuch removed by Delete
        self.assertIn('id=watch:total', rows[2])
        self.assertNotIn('nosuch', rows[2])
        self.assertEqual(out[-1], 'total = 3 : int')

    def test_watch_without_a_session(self):
        out = self.run_editor(['debug-watch add total', 'cmd debug_show', 'print-debug-tree watch'])
        self.assertEqual(self.rows(out), ['row 0 y=%s d=0 leaf id=watch:total label=total desc=not available'
                                          % self.rows(out)[0].split('y=')[1].split(' ')[0]])

    def test_call_stack_focus_frame(self):
        out = self.paused(['print-debug-tree stack', 'view-focus debug.callstack', 'key Down', 'key Down',
                           'key Down', 'key Down', 'key Return', 'wait 300', 'print-debug', 'print-vars'])
        rows = self.rows(out)
        self.assertIn('id=s1 label=Run desc=paused on breakpoint', rows[0])
        self.assertIn('id=s1/t1 label=main', rows[1])
        self.assertIn('id=s1/f0 label=add desc=a.c:3', rows[2])
        self.assertIn('id=s1/f1 label=main desc=a.c:8', rows[3])
        session = self.debug_lines(out)[0]
        self.assertEqual(self.field(session, 'frame'), '1')
        self.assertTrue(self.field(session, 'at').endswith('a.c:8'), session)
        self.assertIn('  total = 0 : int', out)             # main's locals now

    def test_breakpoints_section(self):
        out = self.paused(['bp-function add', 'print-debug-tree breakpoints', 'view-focus debug.breakpoints',
                           'key Down', 'key space', 'print-bps'])
        rows = self.rows(out)
        self.assertIn('check=1 id=b1 label=a.c:3 icon=14', rows[0])
        self.assertIn('check=1 id=b2 label=add()', rows[1])
        self.assertIn('%s 3 enabled=0 ' % self.src, out[-2])

    def test_exception_filters_in_the_breakpoints_section(self):
        out = self.paused(['print-debug-tree breakpoints'], mode='exceptions')
        rows = self.rows(out)
        self.assertTrue(any('check=0 id=x:raised label=Raised Exceptions' in r for r in rows), rows)
        self.assertTrue(any('check=1 id=x:uncaught label=Uncaught Exceptions' in r for r in rows), rows)

    def test_console_input_and_history(self):
        out = self.paused(['view-focus debug.console', 'type a', 'key Return', 'wait 200', 'type b', 'key Return',
                           'wait 200', 'key Up', 'key Up', 'key Return', 'wait 300', 'print-console'])
        self.assertEqual([l for l in out if l.startswith('input') or l.startswith('result')],
                         ['input a', 'result 0', 'input b', 'result 0', 'input a', 'result 0'])

    def test_keys(self):
        self.scenario()
        self.launch_ini('[Run]\ntype = fake\nprogram = scenario.json\nstopOnEntry = yes\n')
        out = self.run_editor(['key ctrl+Home', 'key Down', 'key Down', 'key F9', 'print-bps',
                               'key F5', 'dialog yes', 'wait-debug paused', 'print-debug',
                               'key F10', 'wait-debug paused', 'print-debug',
                               'key F5', 'wait-debug paused', 'print-debug',
                               'key shift+F5', 'wait-debug ended', 'print-debug'])
        self.assertEqual(out[0], '%s 3 enabled=1 cond= hits= log= verified=- line=0 msg=' % self.src)
        sessions = self.debug_lines(out)
        self.assertEqual([self.field(l, 'reason') for l in sessions[:3]], ['entry', 'step', 'breakpoint'])
        self.assertEqual(self.field(sessions[3], 'state'), 'ended')

    def test_condition_prompt(self):
        self.launch_ini()
        out = self.run_editor(['key ctrl+Home', 'key Down', 'key Down', 'cmd debug_condition', 'print-palette',
                               'type b == 1', 'key Return', 'print-bps', 'cmd debug_condition',
                               'key ctrl+a', 'key BackSpace', 'key Return', 'print-bps'])
        self.assertIn('%s 3 enabled=1 cond=b == 1 hits= log=' % self.src, ' '.join(out))
        self.assertEqual(out[-1], '%s 3 enabled=1 cond= hits= log= verified=- line=0 msg=' % self.src)

    def test_add_watch_and_function_prompts(self):
        out = self.run_editor(['cmd debug_add_watch', 'type p.x', 'key Return',
                               'cmd debug_add_function_breakpoint', 'type main', 'key Return',
                               'print-bps', 'cmd debug_show', 'print-debug-tree watch'])
        self.assertIn('function main enabled=1 cond=', out)
        self.assertTrue(any('id=watch:p.x' in l for l in out), out)

    def test_open_configurations(self):
        out = self.run_editor(['cmd debug_open_configurations', 'print-tabs'])
        self.assertIn('launch.ini', [l for l in out if l.startswith('tabs=')][0])
        self.assertTrue((self.proj / '.rhun/launch.ini').read_text().startswith('# Launch configurations'))

    def toolbar(self, out):
        return {int(l.split()[1]): (int(l.split()[2]), int(l.split()[3]), int(l.split()[4]))
                for l in out if l.startswith('button ')}

    def test_toolbar(self):
        self.scenario()
        self.launch_ini('[Run]\ntype = fake\nprogram = scenario.json\nstopOnEntry = yes\n')
        out = self.run_editor([*self.start(), 'wait-debug paused', 'print-debug-toolbar'])
        buttons = self.toolbar(out)
        self.assertEqual(sorted(buttons), sorted(IC[n] for n in ('DBG_RERUN', 'DBG_RESUME', 'DBG_STEP_OVER',
                                                                 'DBG_STEP_INTO', 'DBG_STEP_OUT', 'DBG_STOP2')))
        x, y, size = buttons[IC['DBG_STEP_OVER']]
        sx, sy, _ = buttons[IC['DBG_STOP2']]
        out = self.run_editor([*self.start(), 'wait-debug paused', 'print-debug-toolbar',
                               'click %d %d' % (x + size // 2, y + size // 2), 'wait-debug paused', 'print-debug',
                               'click %d %d' % (sx + size // 2, sy + size // 2), 'wait-debug ended', 'print-debug'])
        sessions = self.debug_lines(out)
        self.assertEqual(self.field(sessions[0], 'reason'), 'step', out)
        self.assertEqual(self.field(sessions[1], 'state'), 'ended', out)

    def test_toolbar_without_debugging(self):
        steps = self.steps()
        steps[3]['block'] = True
        self.scenario(steps)
        self.launch_ini('[Run]\ntype = fake\nprogram = scenario.json\n')
        out = self.run_editor([*self.start(run=True), 'wait-debug running', 'wait 100', 'print-debug-toolbar'])
        self.assertEqual(sorted(self.toolbar(out)), sorted([IC['DBG_RERUN'], IC['DBG_STOP2']]))

    def widget(self, out):
        return {int(l.split()[1]): tuple(int(v) for v in l.split()[2:5]) for l in out if l.startswith('widget ')}

    def test_run_widget(self):
        # the title bar's run widget: the configuration, Run, Debug and More; Stop joins them while a session
        # lives
        self.scenario()
        self.launch_ini('[Run]\ntype = fake\nprogram = scenario.json\nstopOnEntry = yes\n'
                        '[Other]\ntype = fake\nprogram = scenario.json\nstopOnEntry = yes\n')
        out = self.run_editor(['wait 100', 'print-debug-toolbar'])
        parts = self.widget(out)
        self.assertEqual(sorted(parts), sorted([0, IC['RUN_OUTLINE'], IC['DBG_BUG'], IC['MORE']]), out)
        self.assertLess(parts[0][0], parts[IC['RUN_OUTLINE']][0])
        self.assertLess(parts[IC['RUN_OUTLINE']][0], parts[IC['DBG_BUG']][0])
        self.assertLess(parts[IC['DBG_BUG']][0], parts[IC['MORE']][0])
        x, y, w = parts[IC['DBG_BUG']]
        cx, cy, cw = parts[0]
        out = self.run_editor(['wait 100', 'print-debug-toolbar',
                               'click %d %d' % (cx + cw // 2, cy + 4), 'print-menu',
                               'menu-pick Run  \u2713', 'echo --',
                               'click %d %d' % (cx + cw // 2, cy + 4), 'menu-pick Other',
                               'click %d %d' % (x + w // 2, y + w // 2), 'dialog yes', 'wait-debug paused',
                               'wait 100', 'print-debug', 'print-debug-toolbar'])
        first = out[:out.index('--')]
        self.assertIn('Run  \u2713', first)
        self.assertIn('Other', first)
        self.assertIn('Edit Configurations\u2026', first)
        self.assertIn('Add Configuration\u2026', first)
        sessions = self.debug_lines(out)
        self.assertEqual(self.field(sessions[-1], 'state'), 'paused', out)
        self.assertIn('Other', sessions[-1], out)
        second = out[out.index('--'):]
        self.assertIn(IC['DBG_STOP2'], self.widget(second), second)

    def test_run_widget_more_and_spinner(self):
        # More: Run and Debug naming the configuration, Edit and Add Configuration, View Breakpoints; while a
        # session gets ready Debug is a spinner and the status bar says so, with x to stop it
        self.launch_ini()
        out = self.run_editor(['wait 100', 'print-debug-toolbar'])
        x, y, w = self.widget(out)[IC['MORE']]
        out = self.run_editor(['wait 100', 'click %d %d' % (x + w // 2, y + w // 2), 'print-menu'])
        for item in ("Run 'Run'", "Debug 'Run'", 'Edit Configurations\u2026', 'Add Configuration\u2026',
                     'View Breakpoints\u2026'):
            self.assertIn(item, out)
        out = self.run_editor([*self.start(), 'wait 300', 'print-debug', 'print-tips', 'print-status'],
                              mode='no-init-response')
        self.assertTrue(any('state=initializing' in l or 'state=starting' in l for l in self.debug_lines(out)), out)

    def test_run_widget_needs_configurations(self):
        out = self.run_editor(['wait 100', 'print-debug-toolbar'])
        self.assertEqual(self.widget(out), {}, out)

    def toolwindow(self):
        cfg = self.work / 'config/rhun/config'
        cfg.write_text(cfg.read_text() + '\n[debug]\nlayout = toolwindow\n', encoding='utf-8')

    def tw(self, out):
        buttons = {int(l.split()[1]): tuple(int(v) for v in l.split()[2:5]) for l in out if l.startswith('twbutton ')}
        panes = {int(l.split()[1]): tuple(int(v) for v in l.split()[2:6]) for l in out if l.startswith('pane ')}
        return buttons, panes

    def test_tool_window(self):
        # [debug] layout = toolwindow: the Debug tab in the panel (the console one of its tabs) instead of the
        # sidebar's sections, and the title bar keeps only the run widget
        self.toolwindow()
        out = self.paused(['debug-watch add total', 'wait 200', 'print-panel-tabs', 'print-sidebar',
                           'print-debug-toolbar'], line=9)
        tab = [l for l in out if l.startswith('debug.debugger ')][0]
        self.assertIn('title=Debug ', tab)
        self.assertIn('visible', tab)
        self.assertIn('chosen', tab)
        for name in ('debug.variables', 'debug.watch', 'debug.callstack', 'debug.breakpoints'):
            self.assertIn('hidden', [l for l in out if l.startswith(name + ' ')][0])
        self.assertNotIn('visible', [l for l in out if l.startswith('debug.console ')][0])
        self.assertEqual(self.toolbar(out), {}, out)
        buttons, panes = self.tw(out)
        self.assertEqual([b for b in self.bar(out)], [IC[n] for n in (
            'DBG_RERUN', 'DBG_STOP2', 'DBG_RESUME', 'DBG_PAUSE2', 'DBG_STEP_OVER', 'DBG_STEP_INTO', 'DBG_STEP_OUT',
            'DBG_RUN_CURSOR', 'DBG_BPS', 'DBG_MUTE')], out)
        self.assertEqual([l.split()[1] for l in out if l.startswith('chip ')], ['0'], out)
        frames, field, watches, values = (panes[i] for i in range(4))
        self.assertLess(frames[0], field[0])
        self.assertEqual(field[0], watches[0])
        self.assertLess(field[1], watches[1])
        self.assertLess(watches[1], values[1])
        rows = self.rows(self.run_editor(['bp %s 9' % self.src, *self.start(), 'wait-debug paused', 'wait 100',
                                          'print-debug-tree stack'], ))
        self.assertTrue(rows)

    def bar(self, out):
        return [int(l.split()[1]) for l in out if l.startswith('twbutton ')]

    def test_tool_window_buttons_and_panes(self):
        self.toolwindow()
        self.scenario()
        self.launch_ini('[Run]\ntype = fake\nprogram = scenario.json\nstopOnEntry = yes\n')
        out = self.run_editor([*self.start(), 'wait-debug paused', 'debug-watch add total', 'wait 200',
                               'print-debug-toolbar'])
        buttons, panes = self.tw(out)
        x, y, size = buttons[IC['DBG_STEP_OVER']]
        vx, vy, vw, vh = panes[3]
        sx, sy, _ = buttons[IC['DBG_STOP2']]
        out = self.run_editor([*self.start(), 'wait-debug paused', 'debug-watch add total', 'wait 200',
                               'click %d %d' % (x + size // 2, y + size // 2), 'wait-debug paused', 'print-debug',
                               'click %d %d' % (vx + vw // 2, vy + vh - 4), 'wait 100', 'print-debug-toolbar',
                               'key Tab', 'wait 50', 'print-debug-toolbar', 'key Tab', 'wait 50', 'print-debug-toolbar',
                               'key shift+Tab', 'wait 50', 'print-debug-toolbar',
                               'click %d %d' % (sx + size // 2, sy + size // 2), 'wait-debug ended', 'print-debug'])
        sessions = self.debug_lines(out)
        self.assertEqual(self.field(sessions[0], 'reason'), 'step', out)
        self.assertEqual(self.field(sessions[1], 'state'), 'ended', out)
        self.assertEqual([l for l in out if l.startswith('twpane=')], ['twpane=3', 'twpane=0', 'twpane=1', 'twpane=0'])

    def test_tool_window_console_and_session_chip(self):
        self.toolwindow()
        out = self.paused(['wait 200', 'print-debug-toolbar'], line=9)
        sub = {int(l.split()[1]): [int(v) for v in l.split()[2:5]] for l in out if l.startswith('sub ')}
        chip = [[int(v) for v in l.split()[2:5]] for l in out if l.startswith('chip ')][0]
        x, y, w = sub[1]
        out = self.paused(['wait 200', 'click %d %d' % (x + w // 2, y + 8), 'wait 100', 'type 1+1', 'key Return',
                           'wait 300', 'print-console', 'print-debug-toolbar'], line=9)
        self.assertIn('twsub=1', out)
        self.assertTrue(any('1+1' in l for l in out), out)
        cx, cy, cw = chip
        size = 16
        out = self.paused(['wait 200', 'click %d %d' % (cx + cw - 6 - size // 2, cy + 12), 'wait-debug ended',
                           'wait 100', 'print-debug-toolbar', 'print-debug'], line=9)
        self.assertFalse([l for l in out if l.startswith('chip ')], out)

    def test_inline_values_skip_prose_and_other_functions(self):
        # a variable's name in a comment or a string is prose, and one in another function (above the
        # paused line's top-level definition) is another variable: no value for it there
        text = self.src.read_text()
        lines = text.split('\n')
        lines[1] = '    int total = a + b;'
        lines[4] = 'int main(void) { const char *t = "total"; /* the total */'
        lines[6] = '    for (int i = 0; i < 3; i++) // total so far'
        self.src.write_text('\n'.join(lines))
        out = self.paused(['wait 300', 'print-inline-values'], line=9)
        self.assertIn('inline 6     total = 3', out)
        self.assertFalse([l for l in out if (l.startswith('inline 5 ') or l.startswith('inline 7 ')) and 'total' in l], out)
        self.assertFalse([l for l in out if l.startswith('inline 2 ')], out)

    def test_inline_values(self):
        # the paused frame's lines up to the paused one show the values of the variables they name
        out = self.paused(['wait 300', 'print-inline-values'], line=9)
        self.assertIn('inline 6     total = 3', out)
        self.assertIn('inline 8     total = 3', out)
        self.assertFalse([l for l in out if l.startswith('inline 9 ') or l.startswith('inline 10 ')], out)
        cfg = self.work / 'config/rhun/config'
        text = cfg.read_text()
        cfg.write_text(text + '\n[debug]\ninline_values_lines = 2\n', encoding='utf-8')
        out = self.paused(['wait 300', 'print-inline-values'], line=9)
        self.assertEqual([l for l in out if l.startswith('inline ')], ['inline 8     total = 3'], out)
        cfg.write_text(text, encoding='utf-8')
        cfg = self.work / 'config/rhun/config'
        cfg.write_text(cfg.read_text() + '\n[debug]\ninline_values = false\n', encoding='utf-8')
        out = self.paused(['wait 300', 'print-inline-values'], line=9)
        self.assertFalse([l for l in out if l.startswith('inline ')], out)

    def test_run_to_cursor(self):
        # a breakpoint for the time it takes, gone at the stop
        out = self.paused(['wait 200', 'key ctrl+Home', *['key Down'] * 8, 'cmd debug_run_to_cursor',
                           'wait 100', 'wait-debug paused', 'wait 100', 'print-debug', 'print-bps'], line=6)
        session = self.debug_lines(out)[-1]
        self.assertEqual(self.field(session, 'reason'), 'breakpoint', out)
        self.assertTrue(self.field(session, 'at').endswith('a.c:9'), session)
        bps = [l for l in out if l.endswith('msg=') or ' enabled=' in l]
        self.assertEqual(len(bps), 1, bps)
        self.assertIn(' 6 enabled=1', bps[0])

    def test_evaluate_expression(self):
        # the identifier at the cursor in the Debug tab's field; Enter puts its result at the top of the
        # watches, the next one replaces it, and it is not kept with the watches
        self.toolwindow()
        out = self.paused(['debug-watch add p', 'wait 200', 'key ctrl+Home', *['key Down'] * 5, *['key Right'] * 9,
                           'cmd debug_evaluate', 'print-debug-toolbar', 'key Return', 'wait 300',
                           'print-watch', 'echo --', 'cmd debug_evaluate', 'key ctrl+a', 'type total + 1',
                           'key Return', 'wait 300', 'print-watch', 'print-debug-toolbar'], line=9)
        first = out[:out.index('--')]
        self.assertIn('twpane=1', first)
        self.assertEqual([l for l in first if ' : ' in l][0], 'total = 3 : int', first)
        second = out[out.index('--'):]
        watches = [l for l in second if ' : ' in l or ' = ' in l]
        self.assertTrue(watches[0].startswith('total + 1 = '), second)
        self.assertFalse([l for l in watches if l.startswith('total = ')], second)
        self.assertIn('twpane=2', second)
        kept = [f.read_text(errors='replace') for f in self.work.rglob('*') if f.is_file() and '\tw\t' in
                ('\t' + f.read_text(errors='replace').replace('\n', '\t'))]
        self.assertEqual(len(kept), 1, kept)
        self.assertIn('w\tp\n', kept[0])
        self.assertNotIn('w\ttotal', kept[0])

    def test_add_watch_from_the_field(self):
        self.toolwindow()
        out = self.paused(['wait 200', 'cmd debug_evaluate', 'key ctrl+a', 'type total', 'key shift+ctrl+Return',
                           'wait 300', 'print-watch'], line=9)
        self.assertIn('total = 3 : int', out)
        kept = [f.read_text(errors='replace') for f in self.work.rglob('*') if f.is_file() and '\tw\t' in
                ('\t' + f.read_text(errors='replace').replace('\n', '\t'))]
        self.assertTrue(kept and 'w\ttotal\n' in kept[0], kept)

    def test_breakpoints_dialog(self):
        # View Breakpoints: the dialog; the list's cursor shows the breakpoint's options, a field applies
        # with Enter, Space turns it off, Delete removes it, Escape closes
        out = self.paused(['bp %s 3 cond=total>1' % self.src, 'wait 100', 'cmd debug_view_breakpoints', 'wait 100',
                           'key Down', 'wait 100', 'print-bp-dialog', 'key Tab', 'key Tab', 'type 2', 'key Return',
                           'wait 100', 'print-bps', 'key shift+Tab', 'key shift+Tab', 'key space', 'wait 100',
                           'print-bps', 'echo --', 'key Delete', 'wait 100', 'print-bps', 'key Escape', 'wait 50',
                           'print-bp-dialog'], line=9)
        first = out[:out.index('--')]
        self.assertIn('head=a.c:3', first)
        self.assertIn('field 1 total>1', first)
        self.assertTrue(any(l.startswith('preview 3 ') and 'return s;' in l for l in first), first)
        bp3 = [l for l in first if ' 3 enabled=' in l]
        self.assertIn('hits=2', bp3[0], bp3)
        self.assertIn('enabled=0', bp3[1], bp3)
        second = out[out.index('--'):]
        self.assertFalse([l for l in second if ' 3 enabled=' in l], second)
        self.assertTrue([l for l in second if ' 9 enabled=' in l], second)
        self.assertIn('bpdialog open=0', ' '.join(second))

    def test_mute_breakpoints(self):
        self.toolwindow()
        out = self.paused(['wait 100', 'cmd debug_mute_breakpoints', 'wait 200', 'print-dap-log', 'echo --',
                           'cmd debug_mute_breakpoints', 'wait 200', 'print-dap-log'], line=9)
        first = out[:out.index('--')]
        sent = [l for l in first if '"command":"setBreakpoints"' in l]
        self.assertIn('"breakpoints":[]', sent[-1], sent)
        second = out[out.index('--'):]
        sent = [l for l in second if '"command":"setBreakpoints"' in l]
        self.assertIn('"breakpoints":[{"line":9}]', sent[-1], sent)

    def hover_card(self, col, extra=()):
        h = self.proj / 'h.c'
        h.write_text('int f(void) {\n    return use(cfg) + total;\n}\n')
        locals_ = {'total': 3, 'cfg': {'arch': 'arm64', 'enabled': True, 'timeout': 30,
                                       'plugin': {'apiKey': 'abcd', 'retries': 3, 'overrides': {}}}}
        self.scenario([{'file': h.as_posix(), 'line': 2, 'function': 'f', 'locals': locals_}])
        self.launch_ini('[Run]\ntype = fake\nprogram = scenario.json\nstopOnEntry = yes\n')
        out = self.run_editor([*self.start(), 'wait-debug paused', 'print-xy 2 %d' % col], files=('h.c',))
        x, y = map(int, out[-1].split())
        return self.run_editor([*self.start(), 'wait-debug paused', 'wait 300', 'move %d %d' % (x + 2, y),
                                'wait 700', 'wait 600', *extra, 'print-value-card', 'print-tip'], files=('h.c',))

    def test_hover_card(self):
        # the value under the pointer as code: its type, its members two levels down
        out = self.hover_card(16)                       # cfg
        lines = [l for l in out if l.startswith('hover ')]
        self.assertEqual(lines[0], 'hover 0 dict', out)
        for line in ("hover 1   arch: \"arm64\"", 'hover 1   enabled: true', 'hover 1   timeout: 30',
                     'hover 4   plugin: dict', 'hover 1     apiKey: "abcd"', 'hover 1     retries: 3'):
            self.assertIn(line, lines)
        self.assertFalse([l for l in out if l.startswith('tip=') and 'cfg' in l], out)   # no tooltip besides

    def test_hover_card_of_a_plain_value(self):
        out = self.hover_card(25)                       # total
        self.assertIn('hover 2 total = 3', out)

    def test_close_the_debug_tab(self):
        # its x (shown while the pointer is on the tab) hides the debug view; Show or Hide brings it back
        self.toolwindow()
        out = self.paused(['wait 100', 'print-panel-tabs'], line=9)
        tab = [l for l in out if l.startswith('tab debug.debugger ')][0]
        x, w = int(tab.split('x=')[1].split()[0]), int(tab.split('w=')[1].split()[0])
        y = int([l for l in out if l.startswith('debug.debugger ')][0].split('at=')[1].split(',')[1].split()[0]) - 16
        out = self.paused(['wait 100', 'move %d %d' % (x + 10, y), 'wait 50', 'click %d %d' % (x + w - 20 + 8, y),
                           'wait 100', 'print-panel-tabs', 'print-panels', 'echo --', 'cmd debug_show', 'wait 100',
                           'print-panel-tabs'],
                          line=9)
        first = out[:out.index('--')]
        self.assertNotIn('visible', [l for l in first if l.startswith('debug.debugger ')][0], first)
        # with no terminal and no other tab the panel closes rather than staying open and empty
        self.assertIn('terminals=0 chosen open=0', first)
        second = out[out.index('--'):]
        self.assertIn('visible', [l for l in second if l.startswith('debug.debugger ')][0], second)

    def test_full_width_panel(self):
        # [ui] panel_full_width: the panel spans the window, the explorer above it
        self.toolwindow()
        cfg = self.work / 'config/rhun/config'
        cfg.write_text(cfg.read_text().replace('[ui]\n', '[ui]\npanel_full_width = true\n', 1), encoding='utf-8')
        out = self.paused(['cmd toggle_sidebar', 'wait 200', 'print-panel-tabs', 'print-sidebar'], line=9)
        tab = [l for l in out if l.startswith('debug.debugger ')][0]
        self.assertIn('at=0,', tab)
        self.assertIn('size=1000x', tab)
        explorer = [l for l in out if l.startswith('explorer ')][0]
        ey, eh = int(explorer.split('at=')[1].split(',')[1].split()[0]), int(explorer.split('size=')[1].split('x')[1].split()[0])
        self.assertLessEqual(ey + eh, int(tab.split('at=0,')[1].split()[0]), out)

    def test_drag_the_frames_divider(self):
        # the line between the frames and the values is a handle: a drag sets [debug] frames_width
        self.toolwindow()
        out = self.paused(['wait 100', 'print-debug-toolbar'], line=9)
        _, panes = self.tw(out)
        fx, fy, fw, fh = panes[0]
        out = self.paused(['wait 100', 'move %d %d' % (fx + fw, fy + fh // 2), 'down', 'wait 50',
                           'move %d %d' % (fx + 500, fy + fh // 2), 'wait 50', 'up', 'wait 200', 'print-debug-toolbar'],
                          line=9)
        _, panes = self.tw(out)
        self.assertEqual(panes[0][2], 500, panes)
        cfg = (self.work / 'config/rhun/config').read_text()
        self.assertIn('frames_width = 50', cfg)

    def test_run_spins_its_own_button(self):
        # a run without debugging that gets ready spins Run, not Debug; it opens on the Console
        self.toolwindow()
        self.launch_ini()
        out = self.run_editor([*self.start(run=True), 'wait 300', 'print-debug-toolbar'], mode='no-init-response')
        icons = [int(l.split()[1]) for l in out if l.startswith('widget ')]
        spin = range(IC['SPINA0'], IC['SPINA15'] + 1)
        self.assertTrue(any(i in spin for i in icons[1:2]), icons)          # Run
        self.assertIn(IC['DBG_BUG'], icons, icons)                          # Debug as it is
        self.assertIn('twsub=1', out)
        out = self.run_editor([*self.start(), 'wait 300', 'print-debug-toolbar'], mode='no-init-response')
        icons = [int(l.split()[1]) for l in out if l.startswith('widget ')]
        self.assertIn(IC['RUN_OUTLINE'], icons, icons)
        self.assertTrue(any(i in spin for i in icons[2:3]), icons)          # Debug
        self.assertIn('twsub=1', out)                                       # it starts on the Console

    def test_a_stop_shows_threads_and_variables_and_a_step_keeps_the_console(self):
        # a session starts on the Console; a breakpoint's stop brings Threads & Variables; with the Console
        # chosen again a step leaves it there
        self.toolwindow()
        out = self.paused(['wait 200', 'print-debug-toolbar'], line=9)
        self.assertIn('twsub=0', out)
        self.assertIn('twpane=0', out)                  # the call stack's pane
        sub = [l for l in out if l.startswith('sub 1 ')][0].split()
        x, y, w = int(sub[2]), int(sub[3]), int(sub[4])
        out = self.paused(['wait 200', 'click %d %d' % (x + w // 2, y + 10), 'wait 100', 'cmd debug_step_over',
                           'wait-debug paused', 'wait 200', 'print-debug-toolbar'], line=9)
        self.assertIn('twsub=1', out)

    def test_console_lines_select_and_copy(self):
        # the Debug Console's lines: a click selects one, Ctrl+C (Cmd+C) copies it when the field has no
        # selection
        self.toolwindow()
        out = self.paused(['wait 200', 'print-debug-toolbar'], line=9)
        sub = [l for l in out if l.startswith('sub 1 ')][0].split()
        sx, sy, sw = int(sub[2]), int(sub[3]), int(sub[4])
        tab = ['click %d %d' % (sx + sw // 2, sy + 10), 'wait 200']
        out = self.paused(['wait 200', *tab, 'print-debug-toolbar', 'print-console'], line=9)
        x, y, w, h = map(int, [l for l in out if l.startswith('conrect ')][0].split()[1:])
        out = self.paused(['wait 200', *tab, 'click %d %d' % (x + 40, y + 6), 'wait 100', 'key ctrl+c',
                           'wait 100', 'print-console', 'print-clip'], line=9)
        lines = [l for l in out if l.startswith('console ') or l.startswith('info ') or l.startswith('stdout ')]
        self.assertTrue(lines, out)
        text = lines[0].split(' ', 1)[1]                 # the clipboard holds the line and its newline
        self.assertTrue([l for l in out if l.startswith('text=%d ' % (len(text.encode()) + 1))], out)

    def test_clear_console(self):
        # Console's bin at the toolbar's right empties it; the command does too
        self.toolwindow()
        out = self.paused(['wait 200', 'print-debug-toolbar'], line=9)
        sub = {int(l.split()[1]): [int(v) for v in l.split()[2:5]] for l in out if l.startswith('sub ')}
        x, y, w = sub[1]
        out = self.paused(['wait 200', 'click %d %d' % (x + w // 2, y + 8), 'wait 100', 'print-debug-toolbar',
                           'print-console'], line=9)
        buttons, _ = self.tw(out)
        self.assertTrue([l for l in out if 'total=' in l], out)
        bx, by, size = buttons[IC['DBG_TRASH']]
        out = self.paused(['wait 200', 'click %d %d' % (x + w // 2, y + 8), 'wait 100',
                           'click %d %d' % (bx + size // 2, by + size // 2), 'wait 100', 'print-console'], line=9)
        self.assertFalse([l for l in out if 'total=' in l], out)

    def test_context_keys(self):
        out = self.paused(['print-context', 'echo --', 'debug-stop', 'wait-debug ended', 'wait 50', 'print-context'])
        first = out[:out.index('--')]
        self.assertIn('debugState=stopped', first)
        self.assertIn('inDebugMode=true', first)
        self.assertIn('debugType=fake', first)
        second = out[out.index('--'):]
        self.assertIn('debugState=inactive', second)
        self.assertIn('inDebugMode=false', second)

    def test_keys_reach_the_debugger_from_the_terminal(self):
        self.scenario()
        self.launch_ini('[Run]\ntype = fake\nprogram = scenario.json\nstopOnEntry = yes\n')
        out = self.run_editor([*self.start(), 'wait-debug paused', 'cmd toggle_terminal', 'wait 300', 'print-state',
                               'key F10', 'wait-debug paused', 'print-debug'])
        state = [l for l in out if l.startswith('tabs=')][0]
        self.assertIn(' focus=8 ', state)            # the terminal has the keyboard
        self.assertEqual(self.field(self.debug_lines(out)[0], 'reason'), 'step', out)


if __name__ == '__main__':
    unittest.main()
