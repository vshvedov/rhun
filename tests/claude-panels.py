#!/usr/bin/env python3
"""Phase 7 part 3 (claude-chat-p7c): the side panels beside a conversation (the side question /btw, the
bookmarks and the reply's bookmark button), how they dock, the agent map (/tasks), the hand-off card
(/agents), Claude in Chrome (/chrome), Remote Control (/remote-control), and the command menu's entries for
them, against the fake CLI (tests/scripts/fake-claude.py), over the control socket. It imports
tests/claude-chat.py for its cases: every rhun gets its own HOME and XDG folders, an environment without
CLAUDE* or ANTHROPIC* variables, and a config whose [claude] section starts the fake. Nothing here writes
Claude Code's settings."""
import importlib.util
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location('claude_chat', ROOT / 'tests/claude-chat.py')
chat = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(chat)


class PanelCase(chat.DrivenCase):
    def side(self):
        """print-agent-side: (its first line as a dict, its other lines)."""
        lines = self.command('print-agent-side').splitlines()
        head = dict(re.findall(r'(\w+)=(\S*)', lines[0]))
        return head, lines[1:]

    def body(self):
        return self.side()[1]

    def until_body(self, line, seconds=10):
        return self.until(lambda: line in self.body(), 'side panel line ' + line, seconds)

    def logged(self, key):
        return [r[key] for r in self.records() if key in r]

    def control(self, subtype):
        return [m['request'] for m in self.stdin() if m.get('type') == 'control_request'
                and m['request'].get('subtype') == subtype]

    def reply_row(self, text):
        """The 1-based row of the open conversation whose reply ends with text."""
        rows = self.thread()
        for i, row in enumerate(rows):
            if row.startswith('agent') and row.endswith(text):
                return i + 1
        self.fail('no reply ' + text + ' in ' + repr(rows))

    def panel(self, env=None):
        self.start(env=env)
        self.command('cmd focus_agents')


class SideQuestionTest(PanelCase):
    """Row 3.27: a side question is a request of its own beside the conversation (README finding 100)."""

    def test_asks_and_answers_with_history(self):
        self.panel()
        self.chat('hello')
        self.command('agent-side btw what is x')
        head, _ = self.side()
        self.assertEqual((head['side'], head['shown'], head['keys']), ('side', '1', '1'))
        self.until_body('a done side: what is x')
        self.assertIn('q what is x', self.body())
        self.command('agent-side btw and y')
        self.until_body('a done side: and y (1 before)')
        sent = self.control('side_question')
        self.assertEqual(sent[0], {'subtype': 'side_question', 'question': 'what is x'})
        self.assertEqual(sent[1]['history'], [{'question': 'what is x', 'response': 'side: what is x'}])
        self.assertEqual(self.prompts(), ['hello'])          # nothing went into the conversation

    def test_a_side_question_starts_the_program(self):
        self.panel()
        self.command('agent-new claude')
        self.command('agent-side btw first')
        self.until_body('a done side: first')
        self.assertEqual(len(self.starts()), 1)
        self.assertEqual(self.prompts(), [])

    def test_typed_and_by_keyboard(self):
        self.panel()
        self.chat('hello')
        self.command('agent-prompt /btw typed one')         # the command the box intercepts
        self.until_body('a done side: typed one')
        self.command('type two')                            # the panel's field has the keys
        self.assertEqual(self.side()[0]['field'], 'two')
        self.command('key Return')
        self.until_body('a done side: two (1 before)')
        self.assertEqual(self.side()[0]['field'], '')
        self.command('key Escape')                          # Escape closes it; the box has the keys
        self.assertEqual(self.side()[0]['side'], 'none')
        self.assertIn(' focus=1', self.command('print-agent-input'))

    def test_errors_and_no_answer(self):
        self.panel()
        self.chat('hello')
        self.command('agent-side btw fail now')
        self.until_body('a error Failed to get an answer: side question failed')
        self.command('agent-side btw empty one')
        self.until_body('a empty')

    def test_a_turn_ending_leaves_it_and_the_program_ending_fails_it(self):
        self.panel()
        self.chat('hello')
        self.command('agent-prompt linger 1')
        self.command('agent-side btw never mind')
        self.until(lambda: self.logged('side'), 'the question reached the fake')
        self.command('wait-agent ready 10000')              # the turn ended: it still waits
        self.assertIn('a pending', self.body())
        self.assertIn(' pid=1 ', self.live())               # and the program is not idle-stopped meanwhile
        self.command('agent-release')                       # rhun ends the program: cancelled
        self.until_body('a cancelled')

    def test_clear_and_kept_across_restart(self):
        self.panel()
        self.chat('hello')
        self.command('agent-side btw keep me')
        self.until_body('a done side: keep me')
        self.quit()
        self.panel()
        self.open_listed()
        self.command('agent-side btw')
        self.assertIn('a done side: keep me', self.body())
        self.command('agent-side clear')
        self.assertEqual([l for l in self.body() if l.startswith('q ')], [])
        self.quit()
        self.panel()
        self.open_listed()
        self.command('agent-side btw')
        self.assertEqual([l for l in self.body() if l.startswith('q ')], [])


class BookmarkTest(PanelCase):
    """Rows 3.28 and 3.9's bookmark: kept per conversation in rhun's state file."""

    def test_bookmark_show_remove(self):
        self.panel()
        self.chat('hello')
        row = self.reply_row('ok: hello')
        self.command(f'agent-bookmark {row}')
        self.command('agent-side bookmarks')
        head, body = self.side()
        self.assertEqual(head['side'], 'bookmarks')
        self.assertIn('bm[1] ok: hello', body)
        self.command('agent-side-pick 1')
        self.assertIn(f'shown row={row}', self.body())
        self.command('agent-side-pick show')
        self.command('agent-side-pick remove')
        self.assertNotIn('bm[1] ok: hello', self.body())
        self.assertIn('store bookmarks=0 exchanges=0', self.body())

    def test_toggle_twice_and_keyboard(self):
        self.panel()
        self.chat('hello')
        self.command('agent-prompt world')
        self.command('wait-agent ready')
        a, b = self.reply_row('ok: hello'), self.reply_row('ok: world')
        self.command(f'agent-bookmark {a}')
        self.command(f'agent-bookmark {b}')
        self.command(f'agent-bookmark {b}')                 # a second press removes it
        self.command(f'agent-bookmark {b}')
        self.command('agent-side bookmarks')
        self.assertEqual([l for l in self.body() if l.startswith('bm[')], ['bm[1] ok: hello', 'bm[2] ok: world'])
        self.command('key Down')
        self.command('key Down')
        self.assertEqual(self.side()[0]['sel'], '1')
        self.command('key Delete')
        self.assertEqual([l for l in self.body() if l.startswith('bm[')], ['bm[1] ok: hello'])
        self.command('agent-side bookmarks')                # a second /bookmarks closes it
        self.assertEqual(self.side()[0]['side'], 'none')

    def test_kept_across_restart_and_gone_from_the_conversation(self):
        path = self.seed()
        self.panel()
        self.open_listed()
        rows = self.thread()
        row = next(i + 1 for i, r in enumerate(rows) if r.startswith('agent'))
        text = rows[row - 1].split(' ', 1)[1]
        self.command(f'agent-bookmark {row}')
        self.quit()
        path.write_text(path.read_text(encoding='utf-8').replace(text, text + ' (edited)'), encoding='utf-8')
        self.panel()
        self.open_listed()
        self.command('agent-side bookmarks')
        self.command('agent-side-pick 1')
        body = self.body()
        self.assertIn('shown row=gone', body)               # its text kept, its row gone
        self.assertTrue(any(l.startswith('bm[1] ') for l in body), body)


class DockTest(PanelCase):
    """Row 7.17: beside the conversation when the panel is wide, above it when not; sizes kept."""

    def test_docks_and_stacks(self):
        self.panel()
        self.chat('hello')
        self.command('agent-side bookmarks')
        self.command('shot /dev/null')
        head, _ = self.side()
        rect = [int(v) for v in head['rect'].split(',')]
        thread = [int(v) for v in head['thread'].split(',')]
        if head['dock'] == 'beside':                        # 576 px at 1x and the panel's text size
            self.assertEqual((rect[0], rect[1], rect[3]), (thread[0] + thread[2], thread[1], thread[3]))
            self.assertGreaterEqual(rect[2] + thread[2], 576)
        else:
            self.assertEqual((rect[0], rect[2], rect[1] + rect[3]), (thread[0], thread[2], thread[1]))
            self.assertLess(rect[2], 576)
        self.command('resize 700 800')
        self.command('cmd focus_agents')
        self.command('shot /dev/null')
        self.command('agent-side-size 300 600')
        self.command('shot /dev/null')
        self.assertEqual(self.side()[0]['sizes'], '300,600')
        self.quit()
        self.panel()
        self.assertEqual(self.side()[0]['sizes'], '300,600')

    def test_fit(self):
        self.panel()
        fit = self.command('print-agent-side fit').splitlines()
        self.assertEqual(len(fit), 3 * 12)
        for line in fit:
            self.assertTrue(line.endswith(' in=1'), line)
        self.assertTrue(all(' dock=stacked ' in l for l in fit if ' w=240 ' in l))
        self.assertTrue(all(' dock=beside ' in l for l in fit if ' w=900 ' in l and not l.startswith('size=32 ')))


class MapTest(PanelCase):
    """Row 3.29: the agent map of the conversation (its Agent calls)."""

    def test_map_lists_the_agent_and_its_details(self):
        self.panel()
        self.chat('agent')
        self.command('agent-prompt /tasks')
        head = self.command('print-agent-dialog').splitlines()
        self.assertTrue(head[0].startswith('dialog=tasks title=Agent map'), head[0])
        self.assertIn('head Agents', head)
        self.assertIn('text 1 agent · click an agent for details', head)
        items = [l for l in head if l.startswith('item')]
        self.assertTrue(items[0].startswith('item This session'), items)
        self.assertEqual(len(items), 2, items)
        self.assertIn('Spawned by This session', items[1])
        self.command('agent-dialog-pick 1')
        detail = self.command('print-agent-dialog').splitlines()
        self.assertIn(' back=1', detail[0])
        self.assertIn('pair Spawned by\tThis session', detail)
        self.assertIn('head Prompt', detail)
        self.command('key Escape')                          # back to the list
        self.assertIn(' back=0', self.command('print-agent-dialog').splitlines()[0])

    def test_no_agents(self):
        self.panel()
        self.chat('hello')
        self.command('agent-prompt /bashes')
        self.assertIn('text No agents in this conversation.', self.command('print-agent-dialog').splitlines())


class HandoffTest(PanelCase):
    """Rows 4.22 and 7.4's part: /agents needs Claude Code's terminal interface."""

    def test_continue_in_terminal_then_refresh(self):
        self.panel()
        self.chat('hello')
        self.command('agent-prompt /agents')
        self.assertEqual(self.card(), 'card=Continue in Terminal to configure agents? '
                                      'options=Continue in Terminal|Never mind')
        self.command('agent-card 1')
        self.assertTrue(self.command('print-palette').splitlines()[1].endswith(' /agents'))
        self.assertEqual(self.card(), 'card=Terminal opened options=Refresh and continue|Continue without refreshing')
        self.command('cmd focus_agents')
        self.command('agent-card 1')                        # the program ends; the next message resumes
        self.until_gone()
        self.assertIsNone(self.card())
        self.assertEqual(self.prompts(), ['hello'])

    def test_never_mind(self):
        self.panel()
        self.chat('hello')
        self.command('agent-prompt /agents')
        self.command('agent-card 2')
        self.assertIsNone(self.card())
        self.assertIn(' pid=1 ', self.live())

    def card(self):
        lines = self.command('print-agent-input').splitlines()
        return lines[1] if len(lines) > 1 else None


class ChromeTest(PanelCase):
    """Row 6.18: get_chrome_dialog as a dialog (README finding 101)."""

    def test_not_installed(self):
        self.panel()
        self.chat('hello')
        self.command('agent-prompt /chrome')
        self.until(lambda: 'state=ready' in self.command('print-agent-dialog'), 'the answer')
        body = self.command('print-agent-dialog').splitlines()
        self.assertTrue(body[0].startswith('dialog=chrome title=Claude in Chrome'), body[0])
        for line in ('pair Chrome extension\tNot detected', 'pair This session\tNot connected',
                     'link[1] Install Chrome extension', 'link[2] Manage permissions', 'link[3] Reconnect extension'):
            self.assertIn(line, body)
        self.assertTrue(any(l.startswith('toggle Enabled by default on') for l in body), body)

    def test_before_the_program_runs(self):
        self.panel(env={'FAKE_CLAUDE_CHROME': 'installed'})
        self.chat('hello')
        self.command('agent-release')                       # its program ends: the dialog starts it again
        self.until_gone()
        self.command('agent-prompt /chrome')
        self.until(lambda: 'state=ready' in self.command('print-agent-dialog'), 'the answer')
        body = self.command('print-agent-dialog').splitlines()
        self.assertIn('pair Chrome extension\tInstalled', body)
        self.assertFalse(any('Install Chrome extension' in l for l in body))


class RemoteTest(PanelCase):
    """Row 2.22's Remote Control: never shown as connected unless the program says so."""

    def bands(self):
        return self.command('print-agent-bands')

    def test_on_and_off(self):
        self.panel()
        self.chat('hello')
        self.command('agent-prompt /remote-control')
        self.until(lambda: 'Remote Control is active' in self.bands(), 'the bridge state')
        self.assertIn('claude.ai/code', self.bands())
        self.assertEqual(self.command('print-agent-remote'), 'remote=on\n')
        self.command('agent-prompt /rc')
        self.until(lambda: 'Remote Control' not in self.bands(), 'the band gone')
        self.assertEqual(self.logged('remote'), [True, False])

    def test_refused(self):
        self.panel(env={'FAKE_CLAUDE_REMOTE': 'fail'})
        self.chat('hello')
        self.command('agent-prompt /remote-control')
        self.until(lambda: 'Remote Control error: Remote Control is not available for this account' in self.bands(),
                   'the error band')
        self.assertEqual(self.command('print-agent-remote'), 'remote=off\n')

    def test_bridge_failed(self):
        self.panel(env={'FAKE_CLAUDE_REMOTE': 'bridgefail'})
        self.chat('hello')
        self.command('agent-prompt /remote-control')
        self.until(lambda: 'Remote Control error: Could not reach claude.ai' in self.bands(), 'the error band')
        self.assertNotIn('is active', self.bands())


class MenuTest(PanelCase):
    """Rows 1.23 to 1.25: the entries and the typed commands."""

    def test_entries(self):
        self.panel()
        self.chat('hello')
        self.command('agent-menu')
        menu = self.command('print-agent-menu')
        self.assertIn('Bookmarks', menu)
        self.assertIn('Claude in Chrome', menu)
        self.command('key Escape')
        for name in ('/btw', '/tasks', '/remote-control', '/chrome'):
            self.command('agent-type ' + name)
            self.assertIn('row 1 ' + name + '\t', self.command('print-agent-menu'))
            for _ in name:
                self.command('key BackSpace')


if __name__ == '__main__':
    unittest.main()
