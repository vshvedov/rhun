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


class ClaudeDialogCase(DialogCase):
    """A conversation of the fake's and a dialog of Claude Code's over it."""

    def ready(self, env=None):
        """rhun, a conversation whose process is up (a first prompt answered)."""
        self.start(env=env)
        self.command('cmd focus_agents')
        self.chat('hello')

    def draft(self, env=None):
        """rhun, a new conversation's draft (no process)."""
        self.start(env=env)
        self.command('cmd focus_agents')
        self.command('agent-new claude')

    def opened(self, name, state='ready'):
        self.command('agent-dialog ' + name)
        return self.until_state(state)

    def rows(self, kind):
        return [line for line in self.body() if line.split(' ')[0].split('[')[0] == kind]


class StatusTest(ClaudeDialogCase):
    """Row 6.14 (and 1.25's /status): get_status's sections as label/value rows (finding 60)."""

    def test_rows_with_the_extensions_labels(self):
        self.ready()
        head = self.opened('status')
        self.assertEqual(head['title'], 'Status')
        body = self.body()
        self.assertEqual(body[0], 'head Session')
        self.assertIn(f'pair Working folder\t{self.project}', body)         # the CLI's "cwd"
        self.assertIn('pair Session type\tinteractive', body)               # its "Session kind"
        self.assertIn('pair Email\tuser@example.com', body)
        self.assertIn('head Environment', body)
        self.assertEqual(self.control('get_status'), [{'subtype': 'get_status'}])

    def test_typed_command_opens_it_and_sends_nothing(self):
        self.ready()
        self.command('agent-prompt /status')
        self.until_state('ready')
        self.assertEqual(self.prompts(), ['hello'])                         # /status never went as text

    def test_a_draft_starts_its_process_quietly(self):
        self.draft()
        self.command('agent-dialog status')
        head = self.until_state('ready')
        self.assertEqual(head['dialog'], 'status')
        self.assertEqual(len(self.starts()), 1)
        self.assertEqual(self.prompts(), [])

    def test_loading(self):
        self.draft(env={'FAKE_CLAUDE_DIALOG_MS': '1500'})
        self.command('agent-dialog status')
        head = self.head()
        self.assertEqual(head['state'], 'loading')
        self.assertIn('msg Loading status…', self.command('print-agent-dialog'))
        self.until_state('ready')

    def test_error_and_retry(self):
        self.draft(env={'FAKE_CLAUDE_DIALOG_FAIL': 'get_status'})
        self.command('agent-dialog status')
        self.until_state('error')
        self.assertEqual(self.body(), ['msg Could not load status: fake: get_status refused',
                                       'button 1 Retry primary'])
        self.command('agent-dialog-press 1')
        self.until(lambda: len(self.control('get_status')) == 2, 'the second get_status')
        self.until_state('error')
        self.assertEqual(self.body(), ['msg Could not load status: fake: get_status refused',
                                       'button 1 Retry primary'])

    def test_closes_with_its_process_and_its_conversation(self):
        self.ready()
        self.opened('status')
        self.command('agent-release')                                       # the process ends
        self.until(lambda: self.command('print-agent-dialog') == 'dialog=none\n', 'closed')
        self.opened('status')
        self.command(f'click {chat.BACK[0]} {chat.BACK[1]}')                # the panel's back arrow, under it:
        self.assertEqual(self.command('print-agent-dialog'), 'dialog=none\n')   # the press closes the dialog
        self.assertIn(' box=1', self.command('print-agent-input'))          # and the conversation stays open
        self.opened('status')
        self.command('agent-new claude')                                    # another conversation shows
        self.command('shot /dev/null')
        self.assertEqual(self.command('print-agent-dialog'), 'dialog=none\n')

    def test_menu_entries(self):
        self.ready()
        self.command('agent-menu')
        menu = self.command('print-agent-menu')
        for label in ('Account & usage…', 'Status', 'Slash commands', 'Memory', 'Instructions', 'Output styles'):
            self.assertIn('\t' + label if False else label, menu)
        self.command('agent-menu Status')
        self.command('agent-menu-pick 1')
        self.assertEqual(self.until_state('ready')['dialog'], 'status')


class UsageTest(ClaudeDialogCase):
    """Rows 6.15 and 2.18's part: Account (initialize's), the usage bars, the session's totals (finding 61)."""

    def test_account_and_bars(self):
        self.ready()
        self.opened('usage')
        body = self.body()
        self.assertEqual(body[:5], ['head Account', 'pair Auth method\tClaude AI', 'pair Email\tuser@example.com',
                                    "pair Organization\tuser@example.com's Organization", 'pair Plan\tClaude Max'])
        self.assertEqual(body[5], 'head Usage')
        self.assertTrue(body[6].startswith('bar Weekly (7 day) 14% Resets '), body[6])
        self.assertTrue(body[7].startswith('bar Weekly Fable 16% Resets '), body[7])
        self.assertEqual(body[8], 'link[1] Manage usage on claude.ai')
        self.assertEqual(self.control('get_usage'), [{'subtype': 'get_usage'}])

    def test_loading_shows_the_account_first(self):
        self.draft(env={'FAKE_CLAUDE_DIALOG_MS': '1500'})
        self.command('agent-dialog usage')
        body = self.body()
        self.assertEqual(body[1], 'pair Auth method\tNot authenticated')    # (no initialize answer yet)
        self.assertEqual(body[-1], 'text Loading usage data…')
        self.until(lambda: 'bar Weekly (7 day) 14%' in self.command('print-agent-dialog'), 'the bars')

    def test_session_totals_without_rate_limits(self):
        self.ready(env={'FAKE_CLAUDE_USAGE': 'api', 'FAKE_CLAUDE_ACCOUNT': 'bedrock'})
        self.opened('usage')
        body = self.body()
        self.assertIn('pair Auth method\tAmazon Bedrock', body)
        self.assertNotIn('pair Email\tuser@example.com', body)
        self.assertIn('pair Estimated cost\t$0.0045', body)
        self.assertIn('pair Total duration (API)\t1s', body)
        self.assertIn('pair Total duration (wall)\t1h 3m 13s', body)
        self.assertIn('pair Total code changes\t1 line added, 2 lines removed', body)
        self.assertIn('pair claude-haiku-5-5\t1.2k input, 16 output, 25.9k cache read, 20.6k cache write ($0.0045)',
                      body)

    def test_no_limits_for_this_login(self):
        self.ready(env={'FAKE_CLAUDE_USAGE': 'none'})
        self.opened('usage')
        self.assertIn("text Plan limits aren't available for this login method.", self.body())

    def test_failure_and_retry(self):
        self.ready(env={'FAKE_CLAUDE_DIALOG_FAIL': 'get_usage'})
        self.command('agent-dialog usage')
        self.until(lambda: 'text Failed to load usage data' in self.body(), 'the failure')
        self.assertIn('link[1] Retry', self.body())
        self.command('agent-dialog-pick 1')
        self.until(lambda: len(self.control('get_usage')) == 2, 'the second get_usage')

    def test_rate_band_view_usage(self):
        self.ready(env={'FAKE_CLAUDE_RATE': 'warning', 'FAKE_CLAUDE_ACCOUNT': 'none'})   # no Pro or Max plan
        link = None
        for line in self.command('print-agent-bands').splitlines():
            match = re.match(r'link rate (\d+),(\d+) (.*)\t(.*)$', line)
            if match:
                link = match.groups()
        self.assertEqual(link[2:], ('View usage', 'dialog:usage'))
        self.command(f'click {link[0]} {link[1]}')
        self.assertEqual(self.until_state('ready')['dialog'], 'usage')

    def test_list_section(self):
        self.ready()
        self.assertEqual(self.command('print-agent-usage'), 'usage open=0\n')
        self.assertEqual(self.command('print-agent-usage toggle'),
                         'usage open=1\nemail user@example.com\ndetails\n')   # no usage asked yet
        self.opened('usage')
        self.command('agent-dialog-close')
        self.assertEqual(self.command('print-agent-usage'),
                         'usage open=1\nemail user@example.com\nmeter Weekly (7 day) 14%\n'
                         'meter Weekly Fable 16%\ndetails\n')

    def test_typed_usage_opens_it(self):
        self.ready()
        self.command('agent-prompt /usage')
        self.assertEqual(self.until_state('ready')['dialog'], 'usage')
        self.assertEqual(self.prompts(), ['hello'])


class ContextTest(ClaudeDialogCase):
    """Row 2.16: Context usage from get_context_usage (finding 62)."""

    def test_table(self):
        self.ready()
        self.opened('context')
        self.assertEqual(self.body(), [
            'head claude-haiku-5-5 hint 33.0k / 1.0M tokens (3%)',
            'bar  3% ',
            'cols Category\tTokens\tUsage',
            'cols System prompt\t3.6k\t0.4%',
            'cols System tools\t14.3k\t1.4%',
            'cols Memory files\t385\t<0.1%',
            'cols Free space\t934.0k\t93.4%',
            'head Memory files hint /memory',
            f'cols {self.project}/CLAUDE.md\t371\t',
            f'cols {self.work}/.claude/CLAUDE.md\t14\t',
            'head Custom agents hint /agents',
            'cols reviewer\t404\t'])
        self.command('agent-dialog-close')
        self.command('agent-prompt /context')
        self.assertEqual(self.until_state('ready')['dialog'], 'context')
        self.assertEqual(self.prompts(), ['hello'])


class OutputStyleTest(ClaudeDialogCase):
    """Row 6.16: the styles Claude Code lists (finding 63), the one in effect checked; a pick goes to the
    project's local settings (update_settings localSettings outputStyle, finding 12; the fake's only)."""

    def test_pick(self):
        self.ready()
        self.opened('output-style')
        self.assertEqual(self.body(), ['head Select an output style', 'item[1] default\t\t check',
                                       'item[2] Explanatory\t\t', 'item[3] Learning\t\t'])
        self.assertEqual(self.head()['focus'], '1')
        self.keys('Down', 'Return')
        self.until(lambda: self.command('print-agent-dialog') == 'dialog=none\n', 'closed')
        self.assertEqual(self.control('update_settings'), [{'subtype': 'update_settings', 'source': 'localSettings',
                                                            'settings': {'outputStyle': 'Explanatory'}}])
        self.opened('output-style')
        self.assertIn('item[2] Explanatory\t\t check', self.body())


class SkillsTest(ClaudeDialogCase):
    """Row 6.13 (/skills, /help): the commands Claude Code offers, filtered; a skill's source, size and state
    (finding 64), cycled with set_skill_state (the fake's only)."""

    def test_rows_filter_and_select(self):
        self.ready()
        self.opened('skills')
        self.assertEqual(self.head()['focus'], '1')                          # the filter
        items = self.rows('item')
        self.assertIn('item[2] /compact\tClear history but keep a summary\t', items)
        self.assertIn('item[26] /tools:lint\tplugin · ~1.2k tokens\tOn · locked', items)    # (after phase 6's
        self.assertIn('item[27] /notes\tuser · < 20 tokens\tOff pill', items)                #   /resume, /continue
        self.assertIn('item[17] /btw\tAsk a quick side question without interrupting the main conversation\t',
                      items)                                                                 #   and p7c's /btw to /agents)
        self.command('type comp')                                           # /compact, and /logout's "computer"
        self.assertEqual([i.split('\t')[0] for i in self.rows('item')], ['item[2] /compact', 'item[3] /logout'])
        self.keys('Return')
        self.assertEqual(self.command('print-agent-dialog'), 'dialog=none\n')
        self.assertIn('input=/compact ', self.command('print-agent-input'))

    def test_state(self):
        self.ready()
        self.opened('skills')
        self.command('agent-dialog-filter review')
        self.keys('Tab', 'space')
        self.until(lambda: 'item[2] /review\tuser · ~120 tokens\tName only pill' in self.body(), 'the new state')
        logged = [r['dialog'] for r in self.records() if 'dialog' in r]
        self.assertEqual(logged, [{'set_skill_state': {'name': 'review', 'state': 'name-only',
                                                       'handles': {'unqualified_name': 'review',
                                                                   'aliases': ['review']}}}])

    def test_no_process_starts(self):
        self.draft()
        self.command('agent-dialog skills')
        self.assertEqual(self.head()['state'], 'ready')
        self.assertEqual(self.body(), ['text No slash commands available.'])   # none known yet
        self.assertEqual(self.starts(), [])
        self.command('agent-dialog-close')
        self.chat('hello')                                                  # the commands are kept now
        self.command('agent-release')
        self.until_gone()
        self.command('agent-dialog skills')
        self.assertIn('item[2] /compact\tClear history but keep a summary\t', self.rows('item'))
        self.assertNotIn('pill', self.command('print-agent-dialog'))       # no process: no skills' states
        self.assertEqual(len(self.starts()), 1)
        self.command('agent-prompt /help')                                  # /help is the same browser
        self.assertEqual(self.head()['dialog'], 'skills')


class MemoryTest(ClaudeDialogCase):
    """Rows 6.11 and 6.12: get_memory_dialog (finding 65): Memory's switches, memories and folder;
    Instructions' CLAUDE.md files, opened in a tab with the extension's note."""

    def test_memory(self):
        self.ready()
        self.opened('memory')
        self.assertEqual(self.body(), ['toggle[1] Auto-memory on', 'text No memories saved for this project yet.',
                                       'item[2] Open auto-memory folder\t\t',
                                       'text ↑ ↓ to navigate · Enter to select · Esc to close'])
        self.command('agent-dialog-pick 1')
        self.until(lambda: 'toggle[1] Auto-memory off' in self.body(), 'switched off')
        logged = [r['dialog'] for r in self.records() if 'dialog' in r]
        self.assertEqual(logged, [{'set_memory_setting': {'setting': 'autoMemoryEnabled', 'enabled': False}}])

    def test_instructions(self):
        self.ready()
        (self.project / 'CLAUDE.md').write_text('Reply briefly.\n', encoding='utf-8')
        self.opened('instructions')
        self.assertEqual(self.body(), ['item[1] User instructions\tSaved in ~/.claude/CLAUDE.md\t',
                                       'item[2] Project instructions\tChecked in at ./CLAUDE.md\t',
                                       'item[3] CLAUDE.local.md\tLocal, not checked in\t',
                                       'text ↑ ↓ to navigate · Enter to select · Esc to close'])
        self.keys('Down', 'Return')
        self.assertEqual(self.command('print-agent-dialog'), 'dialog=none\n')
        self.assertIn('Reply briefly.', self.command('print-doc'))
        self.assertEqual(self.command('print-toast').strip(),
                         'toast=Claude reads Project instructions when a session starts. After editing, reload to '
                         'apply changes to the current session.')


class FitTest(ClaudeDialogCase):
    """Every dialog lies inside the panel at every size and width."""

    def test_fit(self):
        self.ready()
        for name in ('status', 'usage', 'context', 'output-style', 'skills', 'memory', 'instructions'):
            self.opened(name)
            for line in self.command('print-agent-dialog fit').splitlines():
                self.assertTrue(line.endswith(' in=1'), (name, line))


if __name__ == '__main__':
    unittest.main()
