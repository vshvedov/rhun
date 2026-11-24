#!/usr/bin/env python3
"""The agents panel's dialogs (phase 7: the dialog shell, Status, Account & usage, Context usage, Output
styles, the slash commands browser, Memory, Instructions), against the fake CLI
(tests/scripts/fake-claude.py), over the control socket. It imports tests/claude-chat.py for its cases:
every rhun gets its own HOME and XDG folders, an environment without CLAUDE* or ANTHROPIC* variables, and a
config whose [claude] section starts the fake. Requests that write Claude Code's settings (an output style,
a skill's state, a memory switch) go only to the fake, whose Claude folder is the test's HOME."""
import importlib.util
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location('claude_chat', ROOT / 'tests/claude-chat.py')
chat = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(chat)


class DialogCase(chat.DrivenCase):
    """A dialog over the panel, and what it and the fake say."""

    def head(self):
        """print-agent-dialog's first line as a dict."""
        first = self.command('print-agent-dialog').splitlines()[0]
        return dict(re.findall(r'(\w+)=(.*?)(?= \w+=|$)', first))

    def body(self):
        """print-agent-dialog's other lines, without the box's place."""
        return [line for line in self.command('print-agent-dialog').splitlines()[1:] if not line.startswith('box ')]

    def keys(self, *names):
        for name in names:
            self.command('key ' + name)

    def control(self, subtype=None):
        """The control requests the fake read (of one subtype)."""
        return [m['request'] for m in self.stdin() if m.get('type') == 'control_request'
                and (subtype is None or m['request'].get('subtype') == subtype)]

    def until_state(self, state, seconds=10):
        return self.until(lambda: self.head().get('state') == state and self.head(), 'state ' + state, seconds)

    def panel(self):
        """rhun with the panel shown and the fake as Claude Code."""
        self.start()
        self.command('cmd focus_agents')


class ShellTest(DialogCase):
    """Row 6.21: the one modal shell (title, ×, Escape, numbered buttons, focus back to the box), on the
    test dialog that needs no driver (agent-dialog test)."""

    def test_rows_and_buttons(self):
        self.panel()
        self.command('agent-dialog test')
        head = self.head()
        self.assertEqual((head['dialog'], head['title'], head['state'], head['focus'], head['back']),
                         ('test', 'Dialog shell', 'ready', '1', '0'))
        body = self.body()
        self.assertEqual(body[:9], [
            'head Section',
            'pair Working folder\t/a/rather/long/path/to/a/project/that/wraps/at/narrow/widths',
            "text A muted paragraph that wraps at the box's width, as the extension's dialogs say what they show.",
            'bar Weekly (7 day) 42% Resets Tue at 21:00',
            'toggle[2] A switch off',
            'cols Category\tTokens\tUsage',
            'cols System prompt\t3.6k\t0.4%',
            'link[3] A link',
            'head List hint /hint'])
        self.assertEqual(body[9], 'item[4] Item 1\tIts description, muted under it\tOn pill')
        self.assertEqual(body[10], 'item[5] Item 2\tAnother description\t1.2k check')
        self.assertEqual(body[-2:], ['button 1 Cancel', 'button 2 OK primary'])

    def test_keys(self):
        self.panel()
        self.command('agent-dialog test')
        self.keys('Down')                          # from the field to the switch
        self.assertEqual(self.head()['focus'], '2')
        self.keys('Return')
        self.assertIn('toggle[2] A switch on', self.body())
        self.keys('Tab', 'Tab')                    # the link, the first item
        self.assertEqual(self.head()['focus'], '4')
        self.keys('space')                         # Space on a row with a pill: the pill's act
        self.assertEqual(self.head()['acted'], '3')
        self.assertIn('item[4] Item 1\tIts description, muted under it\tOff pill', self.body())
        self.keys('ISO_Left_Tab')
        self.assertEqual(self.head()['focus'], '3')
        self.keys('2')                             # the second numbered button: OK
        self.assertEqual(self.head()['acted'], '4')
        self.assertEqual(self.body(), ['text Saved.', 'button 1 Cancel', 'button 2 OK primary'][:1])
        self.assertEqual(self.head()['back'], '1')
        self.keys('Escape')                        # Escape is the back arrow's act first
        self.assertEqual(self.head()['back'], '0')
        self.assertEqual(self.head()['acted'], '5')
        self.keys('Escape')
        self.assertEqual(self.command('print-agent-dialog'), 'dialog=none\n')

    def test_filter(self):
        self.panel()
        self.command('agent-dialog test')
        self.command('agent-dialog-filter item 1')
        items = [line for line in self.body() if line.startswith('item')]
        # the rows without DGF_FILTER (the switch, the link) stay; the list keeps Item 1 and 10 to 19
        self.assertEqual([i.split('\t')[0] for i in items],
                         ['item[4] Item 1'] + [f'item[{n}] Item {k}' for n, k in zip(range(5, 15), range(10, 20))])
        self.command('type 0')                     # typed text goes to the field (it has the focus)
        self.assertEqual(self.head()['filter'], 'item 10')
        self.keys('Return')                        # Enter in the field: the first row shown
        self.assertEqual(self.head()['acted'], '109')
        self.command('agent-dialog-filter nothing like it')
        self.assertFalse([line for line in self.body() if line.startswith('item')])

    def test_numbered_button_closes_and_focus_returns(self):
        self.panel()
        self.command('agent-new claude')
        self.assertIn(' focus=1', self.command('print-agent-input'))
        self.command('agent-dialog test')
        self.assertIn(' focus=0', self.command('print-agent-input'))
        self.keys('1')                             # typed into the filter (it has the focus)
        self.assertEqual(self.head()['filter'], '1')
        self.keys('Tab', '1')                      # off the field: the first numbered button, Cancel
        self.assertEqual(self.command('print-agent-dialog'), 'dialog=none\n')
        self.assertIn(' focus=1', self.command('print-agent-input'))

    def test_scroll_and_fit(self):
        self.panel()
        self.command('agent-dialog test')
        self.command('shot /dev/null')
        head = self.head()
        self.assertGreater(int(head['max']), 0)
        self.keys('Tab', 'End')                    # (in the field, End is the field's)
        self.assertEqual(self.head()['scroll'], head['max'])
        self.keys('Home')
        self.assertEqual(self.head()['scroll'], '0')
        fit = self.command('print-agent-dialog fit').splitlines()
        self.assertEqual(len(fit), 3 * 12)
        for line in fit:
            self.assertTrue(line.endswith(' in=1'), line)
        narrow = [line for line in fit if ' w=240 ' in line]
        self.assertTrue(all(int(re.search(r'rows=(\d+)', line).group(1)) >= 1 for line in narrow))

    def box(self):
        """The box and the panel in the window: (x, y, w, h) each, from print-agent-dialog."""
        line = [l for l in self.command('print-agent-dialog').splitlines() if l.startswith('box ')][0]
        box, panel = re.match(r'box (\S+) panel (\S+)', line).groups()
        box = [int(v) for v in box.split(',')]
        panel = [int(v) for v in panel.split(',')]
        return (panel[0] + box[0], panel[1] + box[1], box[2], box[3]), panel

    def test_one_dialog_at_a_time_and_mouse(self):
        self.panel()
        self.command('agent-dialog test')
        self.command('key Tab')
        self.command('agent-dialog test')          # a second one replaces the first: its focus is new
        self.assertEqual(self.head()['focus'], '1')
        (x, y, w, h), panel = self.box()
        self.command(f'click {x + w - 20} {y + 20}')   # the ×
        self.assertEqual(self.command('print-agent-dialog'), 'dialog=none\n')
        self.command('agent-dialog test')
        (x, y, w, h), panel = self.box()
        self.command(f'click {x + 40} {y + h - 15}')   # inside the box, on no control: it stays
        self.assertNotEqual(self.command('print-agent-dialog'), 'dialog=none\n')
        self.command(f'click {panel[0] + 12} {panel[1] + panel[3] - 3}')   # outside it, in the panel
        self.assertEqual(self.command('print-agent-dialog'), 'dialog=none\n')


if __name__ == '__main__':
    unittest.main()
