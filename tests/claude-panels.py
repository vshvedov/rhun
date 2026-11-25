#!/usr/bin/env python3
"""Phase 7 part 3 (claude-chat-p7c): the side panels beside a conversation (the side question /btw, the
bookmarks and the reply's bookmark button), how they dock, the agent map (/tasks), the hand-off card
(/agents), Claude in Chrome (/chrome), Remote Control (/remote-control), and the command menu's entries for
them, against the fake CLI (tests/scripts/fake-claude.py), over the control socket. It imports
tests/claude-chat.py for its cases: every rhun gets its own HOME and XDG folders, an environment without
CLAUDE* or ANTHROPIC* variables, and a config whose [claude] section starts the fake. The Remote Control for all
sessions switch writes Claude Code's user settings: the test HOME's .claude/settings.json, never ~/.claude."""
import importlib.util
import json
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
        self.until_body("a empty Claude didn't return an answer for this side question.")   # the driver's words

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


    def test_the_oldest_goes_at_the_limit_and_nothing_points_at_it(self):
        """500 bookmarks at most: the oldest, shown and selected, goes as a removal does (review 2, finding 3)."""
        self.panel()
        self.chat('hello')
        self.command('agent-prompt world')
        self.command('wait-agent ready')
        a = self.reply_row('ok: hello')
        self.command(f'agent-bookmark {a}')
        self.quit()
        files = [p for p in self.work.rglob('*') if p.name.endswith('agents-side')]
        self.assertEqual(len(files), 1, files)
        lines = files[0].read_text(encoding='utf-8').splitlines()
        mine = [l for l in lines if l.startswith('bm\t')]
        self.assertEqual(len(mine), 1, lines)
        others = ['bm\tother%d\t%x\t5\tfiller %d' % (i, i + 1, i) for i in range(499)]
        files[0].write_text('\n'.join([l for l in lines if not l.startswith('bm\t')] + mine + others) + '\n',
                            encoding='utf-8')
        self.panel()
        self.open_listed()
        self.command('agent-side bookmarks')
        self.command('agent-side-pick 1')
        self.assertIn('bm[1] ok: hello', self.body())
        b = self.reply_row('ok: world')
        self.command(f'agent-bookmark {b}')                 # the 501st: "ok: hello" goes
        self.command('key Delete')                          # nothing is selected now: nothing goes
        body = self.body()
        self.assertEqual([l for l in body if l.startswith('bm[')], ['bm[1] ok: world'])
        self.assertNotIn('shown row=', ' '.join(body))
        self.assertEqual(self.side()[0]['sel'], '-1')


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
        self.assertNotIn('head Background tasks', self.command('print-agent-dialog').splitlines())

    def test_background_shell_commands(self):
        """Row 3.29's background tasks: a shell command sent to the background is listed while it runs."""
        self.panel(env={'FAKE_CLAUDE_BG_MS': '6000'})
        self.command('agent-new claude')
        self.command('agent-prompt bg')
        task = self.until(lambda: re.search(r'task \S+ kind=shell \S+ bg=0 \S+ call=(\S+)',
                                            self.command('print-agent-tasks')), 'the task')
        self.command('agent-task-ask bg ' + task.group(1))
        self.until(lambda: ' bg=1 ' in self.command('print-agent-tasks'), 'in the background')
        self.command('wait-agent ready 10000')
        self.command('agent-prompt /tasks')
        self.command('shot /dev/null')
        lines = self.command('print-agent-dialog').splitlines()
        self.assertIn('head Background tasks', lines)
        self.assertIn('text 1 background task \u00b7 click a task for details', lines)
        items = [l for l in lines if l.startswith('item')]
        self.assertTrue(items[-1].startswith('item[1] Sleep 20 seconds then echo done'), items)
        self.assertTrue(items[-1].endswith('Running'), items)
        self.command('agent-dialog-pick 1')                 # its details ("This session" is not picked)
        detail = self.command('print-agent-dialog').splitlines()
        self.assertIn(' back=1', detail[0])
        self.assertIn('pair State\tRunning', detail)
        stop = [l for l in detail if re.match(r'button \d+ Stop', l)]
        self.assertTrue(stop, detail)
        self.command('agent-dialog-press ' + stop[0].split()[1])
        def drawn():
            self.command('shot /dev/null')              # (the map follows the conversation as it is drawn)
            return self.command('print-agent-dialog').splitlines()
        self.until(lambda: 'pair State\tEnded' in drawn(), 'ended', 10)
        self.assertTrue([r for r in self.stdin() if r.get('type') == 'control_request' and
                         r['request'].get('subtype') == 'stop_task'])
        self.command('key Escape')                          # back to the list: no task listed now
        self.assertNotIn('head Background tasks', drawn())


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


class ChromeRowTest(PanelCase):
    """Row 3.31's header: Claude Code's browser server is "Claude in Chrome [action]"."""

    def test_header(self):
        self.panel()
        self.chat('chrome')
        rows = self.thread()
        n = next(i + 1 for i, r in enumerate(rows) if r.startswith('tool'))
        self.assertIn('Claude in Chrome [navigate]', self.command(f'print-agent-row {n}'))


class RemoteTest(PanelCase):
    """Rows 2.22, 4.14 and 1.24: Remote Control's footer pill, the offer card and the menu's entry; never shown as
    connected unless the program says so; its state ends with the program (review 2, finding 2)."""

    def remote(self):
        """print-agent-remote after a frame: ({remote, pill}, tooltip)."""
        self.command('shot /dev/null')
        head, _, tip = self.command('print-agent-remote').rstrip('\n').partition('\ttip=')
        return dict(re.findall(r'(\w+)=(\S+)', head)), tip

    def state(self):
        return self.remote()[0]['remote']

    def card(self):
        lines = self.command('print-agent-input').splitlines()
        return lines[1] if len(lines) > 1 else None

    def replied(self, text):
        return any(r.startswith('agent') and r.endswith(' ' + text) for r in self.thread())

    def test_on_and_off(self):
        self.panel()
        self.chat('hello')
        self.assertEqual(self.remote(), ({'remote': 'off'}, ''))
        self.command('agent-prompt /remote-control')
        self.until(lambda: self.state() == 'on', 'the bridge state')
        head, tip = self.remote()
        self.assertRegex(head['pill'], r'^\d+,\d+$')
        self.assertEqual(tip, 'Remote Control is active \u00b7 Click to open claude.ai/code \u00b7 Run /remote-control '
                              'to turn off')
        self.assertNotIn('Remote Control', self.command('print-agent-bands'))     # a pill now, not a band
        self.command('agent-prompt /rc')
        self.until(lambda: self.state() == 'off', 'off')
        self.assertNotIn('pill', self.remote()[0])
        self.assertEqual(self.logged('remote'), [True, False])

    def test_refused_then_dismissed(self):
        self.panel(env={'FAKE_CLAUDE_REMOTE': 'fail'})
        self.chat('hello')
        self.command('agent-prompt /remote-control')
        self.until(lambda: self.state() == 'error', 'the error')
        self.assertEqual(self.remote()[1], 'Remote Control error: Remote Control is not available for this account '
                                           '\u00b7 Run /remote-control to dismiss')
        self.command('agent-prompt /remote-control')        # dismissed: the extension's toggle off
        self.until(lambda: self.state() == 'off', 'dismissed')
        self.assertEqual(self.logged('remote'), [True, False])

    def test_bridge_failed(self):
        self.panel(env={'FAKE_CLAUDE_REMOTE': 'bridgefail'})
        self.chat('hello')
        self.command('agent-prompt /remote-control')
        self.until(lambda: self.state() == 'error', 'the error')
        self.assertIn('Remote Control error: Could not reach claude.ai', self.remote()[1])

    def test_it_ends_with_its_program(self):
        self.panel()
        self.chat('hello')
        self.command('agent-prompt /remote-control')
        self.until(lambda: self.state() == 'on', 'on')
        self.command('agent-release')                       # the program ends: so does its bridge
        self.until_gone()
        self.assertEqual(self.state(), 'off')
        self.command('agent-prompt again')
        self.command('wait-agent ready')
        self.command('agent-prompt /remote-control')        # a new program: asked on again, not off
        self.until(lambda: self.state() == 'on', 'on again')
        self.assertEqual(self.logged('remote'), [True, True])

    def test_offer_turns_it_on(self):
        self.panel()
        self.command('agent-timing card=0')
        self.chat('dialog-rc', wait='waiting')
        self.assertEqual(self.card(), 'card=Remote Control is off Turn it on so the project can read this session. '
                                      'options=Turn on Remote Control|Not now')
        self.command('agent-card 1')
        self.command('wait-agent ready')
        self.assertTrue(self.replied('answered turned_on'), self.thread())
        self.assertEqual(self.state(), 'on')

    def test_offer_not_now_and_its_own_words(self):
        self.panel()
        self.command('agent-timing card=0')
        self.chat('dialog-rc empty', wait='waiting')
        self.assertEqual(self.card(), 'card=Remote Control is off, so this session can\u2019t be sent This command '
                                      'needs Remote Control so a Claude Project can read this session. '
                                      'options=Turn on Remote Control|Not now')
        self.command('agent-card 2')
        self.command('wait-agent ready')
        self.assertTrue(self.replied('answered declined'), self.thread())
        self.assertEqual(self.logged('remote'), [])

    def test_offer_when_on_and_when_refused(self):
        self.panel()
        self.command('agent-timing card=0')
        self.chat('hello')
        self.command('agent-prompt /remote-control')
        self.until(lambda: self.state() == 'on', 'on')
        self.command('agent-prompt dialog-rc')
        self.command('wait-agent waiting')
        self.command('agent-card 1')
        self.command('wait-agent ready')
        self.assertTrue(self.replied('answered already_on'), self.thread())
        self.quit()
        self.panel(env={'FAKE_CLAUDE_REMOTE': 'fail'})
        self.command('agent-timing card=0')
        self.chat('dialog-rc', wait='waiting')
        self.command('agent-card 1')
        self.command('wait-agent ready')
        self.assertTrue(self.replied('answered failed'), self.thread())

    def test_menu_entry(self):
        """Row 1.24: /remote-control is a Slash Commands entry, a section the extension shows only for a "/" query."""
        self.panel()
        self.chat('hello')
        self.command('agent-menu')
        self.assertNotIn('section Slash Commands', self.command('print-agent-menu').splitlines())
        self.command('key Escape')
        self.command('agent-type /remote')
        menu = self.command('print-agent-menu').splitlines()
        rows = [l for l in menu if l.startswith('row ') and ' /remote-control\t' in l]
        self.assertEqual(len(rows), 1, menu)
        self.assertIn('View and control this session from claude.ai/code', rows[0])
        self.command('agent-menu-pick ' + rows[0].split()[1])  # (a slash command's row: into the box, then sent)
        if '/remote-control' in self.command('print-agent-input').splitlines()[0]:
            self.command('key Return')
        self.until(lambda: self.state() == 'on', 'on from the menu')


class RemoteAllTest(PanelCase):
    """Row 1.24's "Enable Remote Control for all sessions" (rows 2.22, 4.14): as the extension's host, the switch
    writes remoteControlAtStartup into Claude Code's user settings file itself (2.1.330's update_settings refuses
    the key), tells each running program (apply_flag_settings) and turns its Remote Control as the setting says;
    a program that starts turns it on when initialize says remote_control_auto_enable."""
    LABEL = 'Enable Remote Control for all sessions'

    def remote(self):
        self.command('shot /dev/null')
        return dict(re.findall(r'(\w+)=(\S+)', self.command('print-agent-remote').partition('\t')[0]))['remote']

    def user_file(self):
        return self.work / '.claude' / 'settings.json'

    def row(self):
        """The switch's row of the button menu: (its number, its flags), or None."""
        self.command('agent-menu')
        try:
            for line in self.command('print-agent-menu').splitlines():
                if line.startswith('row ') and line.split(' ', 2)[2].startswith(self.LABEL + '\t'):
                    parts = line.split('\t')
                    self.assertEqual(parts[1], 'Connect all sessions to claude.ai/code automatically so you can '
                                               'view and control them from the web.')
                    return line.split()[1], parts[-1]
            return None
        finally:
            self.command('key Escape')

    def flip(self):
        number, _ = self.row()
        self.command('agent-menu')
        self.command('agent-menu-pick ' + number)
        self.command('key Escape')

    def toast(self):
        return self.command('print-toast').strip().partition('toast=')[2]

    def test_the_switch_writes_the_setting_and_follows_it(self):
        self.user_file().parent.mkdir(parents=True, exist_ok=True)
        self.user_file().write_text('{"model": "opus", "permissions": {"allow": ["Bash(ls)"]}, "n": 1.50, '
                                    '"remoteControlAtStartup": false, "z": "\u00e9"}', encoding='utf-8')
        self.panel()
        self.chat('hello')
        self.assertEqual(self.row()[1], 'switch')
        self.flip()
        self.until(lambda: self.remote() == 'on', 'Remote Control on')
        self.assertEqual(self.user_file().read_text(encoding='utf-8'),
                         '{\n  "model": "opus",\n  "permissions": {\n    "allow": [\n      "Bash(ls)"\n    ]\n  },\n'
                         '  "n": 1.50,\n  "remoteControlAtStartup": true,\n  "z": "\u00e9"\n}\n')
        self.assertEqual(self.control('apply_flag_settings')[-1], {'subtype': 'apply_flag_settings',
                                                                   'settings': {'remoteControlAtStartup': True}})
        self.assertEqual(self.control('update_settings'), [])
        self.assertEqual(self.row()[1], 'on,switch')
        self.flip()
        self.until(lambda: self.remote() == 'off', 'Remote Control off')
        self.assertFalse(json.loads(self.user_file().read_text())['remoteControlAtStartup'])
        self.assertEqual(self.logged('remote'), [True, False])
        self.assertEqual(self.row()[1], 'switch')

    def test_no_settings_file_yet(self):
        self.panel()
        self.chat('hello')
        self.flip()
        self.until(lambda: self.remote() == 'on', 'Remote Control on')
        self.assertEqual(self.user_file().read_text(), '{\n  "remoteControlAtStartup": true\n}\n')

    def test_a_start_turns_it_on(self):
        self.user_file().parent.mkdir(parents=True, exist_ok=True)
        self.user_file().write_text('{"remoteControlAtStartup": true}')
        self.panel()
        self.chat('hello')
        self.until(lambda: self.remote() == 'on', 'Remote Control on at the start')
        self.assertEqual(self.logged('remote'), [True])
        self.assertEqual(self.row()[1], 'on,switch')

    def test_a_local_false_wins(self):
        """The binary's resolver: repo-scoped settings cannot turn it on, a false there turns it off."""
        self.user_file().parent.mkdir(parents=True, exist_ok=True)
        self.user_file().write_text('{"remoteControlAtStartup": true}')
        local = self.project / '.claude' / 'settings.local.json'
        local.parent.mkdir(parents=True, exist_ok=True)
        local.write_text('{"remoteControlAtStartup": false}')
        self.panel()
        self.chat('hello')
        self.assertEqual(self.logged('remote'), [])
        self.assertEqual(self.row()[1], 'switch')       # effective: the local false
        self.flip()                                     # on: written, but this project's program stays off
        self.until(lambda: len(self.control('get_settings')) >= 2, 'get_settings again')
        self.command('wait-agent ready')
        self.assertTrue(json.loads(self.user_file().read_text())['remoteControlAtStartup'])
        self.assertEqual(self.logged('remote'), [])
        self.assertEqual(self.remote(), 'off')

    def test_a_bad_settings_file_is_left_alone(self):
        self.user_file().parent.mkdir(parents=True, exist_ok=True)
        self.user_file().write_text('{"model": ')
        self.panel()
        self.chat('hello')
        self.flip()
        self.assertEqual(self.toast(), 'Failed to update "Enable Remote Control for all sessions": Settings file is not '
                                       f'valid JSON: {self.user_file()}')
        self.assertEqual(self.user_file().read_text(), '{"model": ')
        self.assertEqual(self.control('apply_flag_settings'), [])
        self.user_file().write_text('[1]')
        self.flip()
        self.assertEqual(self.toast(), 'Failed to update "Enable Remote Control for all sessions": Settings file is not '
                                       f'a JSON object: {self.user_file()}')

    def test_locked(self):
        self.user_file().parent.mkdir(parents=True, exist_ok=True)
        self.user_file().write_text('{"remoteControlAtStartup": true}')
        self.panel(env={'FAKE_CLAUDE_RC_LOCK': 'Remote Control is turned off by your organization'})
        self.chat('hello')
        self.until(lambda: self.row()[1] == 'on,switch', 'the setting read')
        self.flip()                                     # locked: it can only be turned off
        self.until(lambda: self.remote() == 'off', 'off')
        self.assertFalse(json.loads(self.user_file().read_text())['remoteControlAtStartup'])
        self.assertEqual(self.toast(), "Remote Control turned off. It can't be turned back on while your "
                                       "organization's lock is in place.")
        self.flip()
        self.assertEqual(self.toast(), 'Failed to update "Enable Remote Control for all sessions": Remote Control is '
                                       'turned off by your organization')
        self.assertFalse(json.loads(self.user_file().read_text())['remoteControlAtStartup'])

    def test_hidden_when_unavailable(self):
        self.panel(env={'FAKE_CLAUDE_REMOTE': 'unavailable'})
        self.chat('hello')
        self.assertIsNone(self.row())


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
