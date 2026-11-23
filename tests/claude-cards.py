#!/usr/bin/env python3
"""Claude Code's rich cards in the agents panel (phase 2: permission, questions, plan review in a tab, the
CLI's dialogs), against the fake CLI (tests/scripts/fake-claude.py), over the control socket. It imports
tests/claude-chat.py for its cases: every rhun gets its own HOME and XDG folders, an environment without
CLAUDE* or ANTHROPIC* variables, and a config whose [claude] section starts the fake. Rules a test saves
go to destination session, or to localSettings and projectSettings inside its temporary project (the
fake writes them under the project's .claude folder): never the user's own. The fake's Claude folder is
the test's HOME, so even a userSettings rule would land there; no test here sends one."""
import importlib.util
import json
from pathlib import Path
import re
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location('claude_chat', ROOT / 'tests/claude-chat.py')
chat = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(chat)

# the extension's rejection with a reason (webview index.js @5214814 `Xb`, its trailing space included)
REASON = ("The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file "
          "edit, the new_string was NOT written to the file). The user provided the following reason for the "
          "rejection: ")
LOCAL = 'this project (just you)'


class CardCase(chat.DrivenCase):
    """A conversation whose request is on a rich card, and what the card and the fake say."""

    def ask(self, prompt, lock=0, start=True, env=None, claude=None, extra=''):
        """rhun (when start), the cards' lock in ms, a new conversation and its prompt, until its card shows."""
        if start:
            self.start(claude, extra=extra, env=env)
        self.command(f'agent-timing card={lock}')
        self.chat(prompt, 'waiting')

    def card(self):
        """print-agent-card: its first line as a dict, then its other lines."""
        lines = self.command('print-agent-card').splitlines()
        if not lines:
            return None, []
        head = dict(re.findall(r'(\w+)=(.*?)(?= \w+=|$)', lines[0]))
        return head, lines[1:]

    def head(self):
        return self.card()[0]

    def lines(self, word):
        return [line[len(word) + 1:] for line in self.card()[1] if line.startswith(word + ' ')]

    def buttons(self):
        return [line.split(' ', 2)[2] for line in self.card()[1] if line.startswith('button ')]

    def answers(self):
        return [r['answer'] for r in self.records() if 'answer' in r]

    def control(self):
        """The control requests and responses the fake read, in order."""
        return [m for m in self.stdin() if m.get('type') in ('control_request', 'control_response')]

    def mode_requests(self):
        return [m['request'] for m in self.stdin()
                if m.get('type') == 'control_request' and m['request'].get('subtype') == 'set_permission_mode']

    def suggestions(self, command):
        """The fake's suggestions for a Bash call (finding 15's three)."""
        return [{'type': 'addRules', 'rules': [{'toolName': 'Bash', 'ruleContent': command}], 'behavior': 'allow',
                 'destination': 'localSettings'},
                {'type': 'addDirectories', 'directories': [str(self.project)], 'destination': 'session'},
                {'type': 'setMode', 'mode': 'acceptEdits', 'destination': 'session'}]

    def until_answered(self, n=1):
        return self.until(lambda: len(self.answers()) >= n and self.answers(), 'the answer')

    def keys(self, *names):
        for name in names:
            self.command('key ' + name)


class PermissionCardTest(CardCase):
    """Task 9: the permission card (ext-webview-ui.md 4.1 to 4.7, 7.4; the real CLI's findings 15 and 16)."""

    def test_bash_card_layout(self):
        self.ask('tool')
        head, lines = self.card()
        self.assertEqual(head['kind'], 'permission')
        self.assertEqual(head['title'], 'Allow this bash command?')
        self.assertEqual((head['live'], head['focus'], head['dest'], head['folded'], head['keys']),
                         ('1', '1', 'localSettings', '0', '1'))
        self.assertEqual(lines, [
            'edit touch approved.txt',
            'desc Run touch approved.txt',
            'button 1 Yes',
            f'button 2 Yes, allow touch approved.txt for [{LOCAL}]',
            f'extra Also allows access to {self.project}/',
            'extra Also switches to “Edit automatically” for this session',
            'button 3 No',
            'field '])
        fit = self.command('print-agent-card-fit')
        self.assertIn('size=13 w=380 ', fit)

    def test_rule_goes_back_with_the_chosen_place(self):
        self.ask('tool')
        self.keys('Down', 'Right', 'Right')         # the rule button, then the place twice round
        self.assertEqual(self.head()['dest'], 'projectSettings')
        self.assertIn('button 2 Yes, allow touch approved.txt for [this project (shared)]', self.card()[1])
        self.keys('2')
        answer = self.until_answered()[0]
        sent = self.suggestions('touch approved.txt')
        sent[0]['destination'] = sent[1]['destination'] = 'projectSettings'
        self.assertEqual(answer['updatedPermissions'], sent)          # the setMode keeps its own
        self.assertEqual(answer['updatedInput'], {'command': 'touch approved.txt',
                                                  'description': 'Run touch approved.txt'})
        # the setMode for this session went first, as its own request (its line finished before the allow)
        kinds = [m.get('request', {}).get('subtype') or m['response']['response']['behavior']
                 for m in self.control() if m.get('type') == 'control_request' or 'response' in m.get('response', {})]
        self.assertEqual(kinds[-2:], ['set_permission_mode', 'allow'])
        self.assertEqual(self.mode_requests()[-1], {'subtype': 'set_permission_mode', 'mode': 'acceptEdits'})
        saved = json.loads((self.project / '.claude/settings.json').read_text(encoding='utf-8'))
        self.assertEqual(saved, {'permissions': {'allow': ['Bash(touch approved.txt)']}})
        self.assertFalse((self.project / '.claude/settings.local.json').exists())

    def test_the_places_link_cycles_them(self):
        self.ask('tool')
        places = []
        for _ in range(4):
            self.command('agent-card dest')         # a click on the place in the button
            places.append(self.head()['dest'])
        self.assertEqual(places, ['userSettings', 'projectSettings', 'session', 'localSettings'])
        self.assertEqual(self.buttons()[1], f'Yes, allow touch approved.txt for [{LOCAL}]')
        self.keys('Down', 'Left')                   # and Left on the focused button, back round
        self.assertEqual(self.head()['dest'], 'session')
        self.command('agent-card 3')
        self.until_answered()

    def test_only_suggested_rules_go_back(self):
        self.ask('tool')
        self.command('agent-card 2')
        answer = self.until_answered()[0]
        self.assertEqual(list(answer), ['behavior', 'updatedInput', 'updatedPermissions', 'toolUseID'])
        self.assertEqual(answer['updatedPermissions'], [dict(s, destination='localSettings') if s['type'] != 'setMode'
                                                        else s for s in self.suggestions('touch approved.txt')])
        # Yes sends no rule at all
        self.command('wait-agent ready')
        self.command('agent-prompt tool touch other.txt')
        self.command('wait-agent waiting')
        self.command('agent-card 1')
        answer = self.until_answered(2)[1]
        self.assertEqual(list(answer), ['behavior', 'updatedInput', 'toolUseID'])

    def test_rule_dir_and_mode_are_shown_and_sent(self):
        self.ask('mixed')
        self.assertEqual(self.buttons()[1], f'Yes, allow git log for [{LOCAL}]')
        self.assertEqual(self.lines('extra'), [f'Also allows access to {self.project}/lib/',
                                               'Also switches to “Plan” for this session'])
        self.command('agent-card 2')
        answer = self.until_answered()[0]
        self.assertEqual(answer['updatedPermissions'], [
            {'type': 'addRules', 'rules': [{'toolName': 'Bash', 'ruleContent': 'git log:*'}], 'behavior': 'allow',
             'destination': 'localSettings'},
            {'type': 'addDirectories', 'directories': [str(self.project / 'lib')], 'destination': 'localSettings'},
            {'type': 'setMode', 'mode': 'plan', 'destination': 'session'}])
        self.assertEqual(self.mode_requests(), [{'subtype': 'set_permission_mode', 'mode': 'plan'}])

    def test_a_session_suggestion_stays_session(self):
        self.ask('sessiononly')
        self.assertEqual(self.head()['dest'], 'session')
        self.assertEqual(self.buttons()[1], 'Yes, allow touch session.txt for [this session]')
        self.command('agent-card 2')
        answer = self.until_answered()[0]
        self.assertEqual([u['destination'] for u in answer['updatedPermissions']], ['session'])
        self.assertFalse((self.project / '.claude').exists())

    def test_an_invalid_remembered_place_falls_back_to_session(self):
        self.start()
        self.chat('hello')
        self.command('agent-cfg-set dest bogusSettings')
        self.command('agent-timing card=0')
        self.command('agent-prompt tool')
        self.command('wait-agent waiting')
        self.assertEqual(self.head()['dest'], 'session')
        self.assertEqual(self.buttons()[1], 'Yes, allow touch approved.txt for [this session]')
        self.command('agent-card 2')
        answer = self.until_answered()[0]
        self.assertEqual([u['destination'] for u in answer['updatedPermissions']],
                         ['session', 'session', 'session'])

    def test_the_place_is_remembered(self):
        self.ask('tool')
        self.keys('Down', 'Right')                  # all projects: kept, though nothing is saved here
        self.assertEqual(self.head()['dest'], 'userSettings')
        self.keys('3')                              # No
        self.command('wait-agent ready')
        self.assertIn('dest userSettings', self.command('print-agent-cfg'))
        self.command('agent-prompt tool touch again.txt')
        self.command('wait-agent waiting')
        self.assertEqual(self.head()['dest'], 'userSettings')
        self.command('agent-card 3')
        self.command('wait-agent ready')
        self.assertEqual([a['behavior'] for a in self.answers()], ['deny', 'deny'])

    def test_no_rule_button_when_suppressed(self):
        self.ask('nosave')
        self.assertEqual(self.buttons(), ['Yes', 'No'])
        self.assertEqual(self.lines('extra'), [])
        self.assertEqual(self.head()['dest'], '-')
        self.keys('2')
        self.assertEqual(self.until_answered()[0]['behavior'], 'deny')

    def test_default_to_no(self):
        self.ask('defno')
        self.assertEqual(self.head()['focus'], '3')    # No
        self.keys('1', '2')                         # no numbers on such a card
        time.sleep(0.2)
        self.assertEqual(self.answers(), [])
        self.keys('Return')
        answer = self.until_answered()[0]
        self.assertEqual((answer['behavior'], answer['interrupt']), ('deny', True))

    def test_deny_with_text_continues(self):
        self.ask('tool')
        self.command('agent-card-text field try ls')
        self.keys('4')                              # the number after the last: the field
        self.assertEqual(self.head()['focus'], 'field')
        self.assertEqual(self.lines('field'), ['try ls'])
        self.keys('Return')
        answer = self.until_answered()[0]
        self.assertEqual(answer['message'], REASON + ' try ls')
        self.assertIs(answer['interrupt'], False)
        self.command('wait-agent ready')
        self.assertEqual(self.thread()[-1], chat.REPLY + 'done')        # Claude went on

    def test_deny_without_text_interrupts(self):
        self.ask('tool')
        self.keys('3')
        answer = self.until_answered()[0]
        self.assertEqual((answer['message'], answer['interrupt']), (chat.REJECTED, True))
        self.command('wait-agent ready')
        self.assertEqual(self.thread()[-1], 'info Interrupted')

    def test_escape_denies_with_the_fields_text(self):
        self.ask('tool')
        self.command('agent-card-text field not now')
        self.keys('Escape')
        answer = self.until_answered()[0]
        self.assertEqual((answer['message'], answer['interrupt']), (REASON + ' not now', False))

    def test_edited_command_is_sent(self):
        self.ask('tool')
        self.command('agent-card-text edit touch edited.txt')
        self.assertEqual(self.lines('edit'), ['touch edited.txt'])
        self.command('agent-card 1')
        answer = self.until_answered()[0]
        self.assertEqual(answer['updatedInput'], {'command': 'touch edited.txt', 'description': 'Run touch approved.txt'})
        self.command('wait-agent ready')
        self.assertTrue((self.project / 'edited.txt').exists())
        self.assertFalse((self.project / 'approved.txt').exists())

    def test_the_command_is_edited_by_keys(self):
        self.ask('tool')
        self.keys('Up')                             # from Yes up to the command
        self.assertEqual(self.head()['focus'], 'edit')
        self.keys('End', 'BackSpace', 'BackSpace', 'BackSpace', 'm', 'd')
        self.assertEqual(self.lines('edit'), ['touch approved.md'])
        self.keys('Down', 'Return')                 # Yes
        answer = self.until_answered()[0]
        self.assertEqual(answer['updatedInput']['command'], 'touch approved.md')

    def test_hook_note(self):
        self.ask('hook')
        self.assertEqual(self.lines('note'), ['The policy hook wants a person to look at this.'])
        self.command('agent-card 3')
        self.until_answered()

    def test_bypass_suggestion_is_dropped(self):
        self.ask('bypass')
        self.assertEqual(self.buttons()[1], f'Yes, allow touch bypass.txt for [{LOCAL}]')
        self.assertEqual(self.lines('extra'), [])
        self.command('agent-card 2')
        answer = self.until_answered()[0]
        self.assertEqual(answer['updatedPermissions'], [
            {'type': 'addRules', 'rules': [{'toolName': 'Bash', 'ruleContent': 'touch bypass.txt'}],
             'behavior': 'allow', 'destination': 'localSettings'}])
        self.assertEqual(self.mode_requests(), [])
        self.assertNotIn('bypassPermissions', json.dumps(self.stdin()))

    def test_bypass_suggestion_goes_back_through_the_gate(self):
        self.ask('bypass', claude=self.claude_section('allow_bypass_permissions = true\n'))
        self.assertEqual(self.lines('extra'), ['Also switches to “Bypass permissions” for this session'])
        self.command('agent-card 2')
        answer = self.until_answered()[0]
        self.assertEqual([u['type'] for u in answer['updatedPermissions']], ['addRules', 'setMode'])
        self.assertEqual(self.mode_requests(), [{'subtype': 'set_permission_mode', 'mode': 'bypassPermissions'}])

    def test_mode_suggestion_sets_the_mode_first(self):
        self.ask('modeonly')
        self.assertEqual(self.buttons(), ['Yes', 'Yes, allow all edits this session', 'No'])
        self.assertEqual(self.lines('extra'), [])
        self.command('agent-card 2')
        answer = self.until_answered()[0]
        self.assertEqual(answer['updatedPermissions'], [{'type': 'setMode', 'mode': 'acceptEdits',
                                                         'destination': 'session'}])
        lines = self.control()
        self.assertEqual(lines[-2]['request'], {'subtype': 'set_permission_mode', 'mode': 'acceptEdits'})
        self.assertEqual(lines[-1]['response']['response']['behavior'], 'allow')
        self.command('wait-agent ready')
        self.assertIn(' mode=acceptEdits ', self.live())

    def test_dirs_wording(self):
        self.ask('dirs')
        self.assertEqual(self.buttons()[1], 'Yes, allow access to dir1/ for [this session]')
        self.assertEqual(self.lines('extra'), [])
        self.command('agent-card 3')
        self.command('wait-agent ready')
        self.command('agent-prompt dirs 2')
        self.command('wait-agent waiting')
        self.assertEqual(self.buttons()[1], 'Yes, allow access to 2 directories for [this session]')
        self.assertEqual(self.lines('extra'), [f'Also allows access to {self.project}/dir1/',
                                               f'Also allows access to {self.project}/dir2/'])
        self.command('agent-card 3')

    def test_rule_wording(self):
        self.ask('tool touch a-file-with-a-rather-long-name.txt')
        self.assertEqual(self.buttons()[1], f'Yes, allow touch a-file-with… for [{LOCAL}]')
        self.command('agent-card 3')

    def test_a_suggestion_that_cannot_be_echoed_offers_no_rule(self):
        self.ask('deep rule')
        self.assertEqual(self.buttons(), ['Yes', 'No'])
        self.command('agent-card 2')
        self.until_answered()

    def test_headers_per_tool(self):
        (self.project / 'notes.txt').write_text('first\n', encoding='utf-8')
        self.start()
        self.command('agent-timing card=0')
        cases = [
            ('edit', 'Make this edit to notes.txt?', []),
            ('fetch', 'Allow fetching this url?', ['detail https://example.com']),
            ('pwsh', 'Allow this PowerShell command?', ['edit Get-ChildItem', 'desc List the folder']),
            ('net', 'Allow network connection to this host?', ['detail example.com']),
            ('skill review', 'Use skill /review?', [
                'desc Claude may use instructions, code, or files from this skill.', 'desc Arguments: --quick']),
            ('project', 'Create the Claude Project “Docs” and send this message?', [
                'detail Here is the plan for the docs.', 'desc Scroll to the end of the message before approving it.']),
            ('glob', f'Allow glob search in {self.project}?', []),
            ('grep', 'Allow this grep command', []),
            ('websearch', 'Allow searching for this query?', [
                'detail rhun editor', 'desc Allowed: rhun.app, github.com · Blocked: example.com']),
            ('other', 'Do you want to proceed with mcp__notes__add?', ['details 0'])]
        for prompt, title, lines in cases:
            with self.subTest(prompt):
                self.chat(prompt, 'waiting')
                head, got = self.card()
                self.assertEqual(head['title'], title)
                self.assertEqual([line for line in got if not line.startswith(('button', 'field', 'extra'))], lines)
                buttons = self.buttons()
                self.command(f'agent-card {len(buttons)}')      # No
                self.command('wait-agent ready')
        self.assertEqual([a['behavior'] for a in self.answers()], ['deny'] * len(cases))

    def test_details_open_and_close(self):
        self.ask('other')
        self.assertEqual(self.lines('details'), ['0'])
        before = self.command('print-agent-card-fit').splitlines()[0]
        self.command('agent-card details')
        self.assertEqual(self.lines('details'), ['1'])
        after = self.command('print-agent-card-fit').splitlines()[0]
        self.assertGreater(int(re.search(r' h=(\d+)', after).group(1)), int(re.search(r' h=(\d+)', before).group(1)))
        self.command('agent-card 2')
        self.until_answered()

    def test_typing_in_the_box_never_answers_a_card(self):
        self.start()
        self.command('agent-timing card=0 keyed=5000')
        self.command('agent-new claude')
        self.command('agent-focus box')
        self.command('agent-type tool')             # the program starts meanwhile
        self.command('wait-agent ready')
        self.keys('Return')                         # sent from the box by its key: the box had a key just now
        self.command('wait-agent waiting')
        self.assertEqual(self.head()['keys'], '0')
        self.assertIn(' focus=1 ', self.command('print-agent-input'))
        self.keys('1', '2')
        self.command('agent-type 3')
        self.assertTrue(self.command('print-agent-input').startswith('input=123 '))
        self.assertEqual(self.lines('waiting'), ['Waiting for permission…'])
        time.sleep(0.3)
        self.assertEqual(self.answers(), [])
        self.assertIn(' requests=1 ', self.live())
        self.command('agent-focus panel')           # the panel (a click on the card): now it has the keys
        self.assertEqual(self.head()['keys'], '1')
        self.keys('3')
        self.assertEqual(self.until_answered()[0]['behavior'], 'deny')
        self.assertTrue(self.command('print-agent-input').startswith('input=123 '))

    def test_a_card_takes_the_keys_from_an_idle_box(self):
        self.start()
        self.command('agent-timing card=0')
        self.command('agent-new claude')
        self.command('agent-focus box')
        self.command('agent-prompt tool')
        self.command('wait-agent waiting')
        self.assertEqual(self.head()['keys'], '1')
        self.assertIn(' focus=0 ', self.command('print-agent-input'))
        self.keys('Tab')                            # Tab goes back to the box, and the card waits
        self.assertEqual(self.head()['keys'], '0')
        self.assertIn(' focus=1 ', self.command('print-agent-input'))
        self.command('agent-card 3')

    def test_focus_in_the_editor_stays_there(self):
        (self.project / 'notes.txt').write_text('notes\n', encoding='utf-8')
        self.start(env={'FAKE_CLAUDE_INIT_MS': '800'})
        self.command(f'open {self.project / "notes.txt"}')
        self.command('agent-timing card=0')
        self.command('agent-new claude')
        self.command('agent-prompt tool')
        self.command('agent-focus editor')          # before the program is ready
        state = self.command('print-state')
        self.assertIn(' focus=0 ', state)
        self.command('wait-agent waiting')
        self.assertEqual(self.head()['keys'], '0')
        self.keys('1', '2', '3')
        self.assertIn(' focus=0 ', self.command('print-state'))
        self.assertIn('123', self.command('print-doc'))
        time.sleep(0.3)
        self.assertEqual(self.answers(), [])
        self.assertIn(' requests=1 ', self.live())

    def test_card_of_another_conversation_takes_no_keys(self):
        self.start(env={'FAKE_CLAUDE_INIT_MS': '800'})
        self.command('agent-timing card=0')
        self.command('agent-new claude')
        self.command('agent-prompt tool')           # its card comes once the program is ready
        self.command('agent-new claude')            # meanwhile another conversation is open
        self.command('agent-focus panel')
        time.sleep(1.5)
        self.assertIn(' focus=6 ', self.command('print-state'))
        self.keys('1', '2', '3')
        self.assertEqual(self.answers(), [])
        self.keys('Escape')                         # the new one is left: the first is open again
        head = self.head()
        self.assertEqual((head['title'], head['live']), ('Allow this bash command?', '1'))
        self.assertEqual(self.answers(), [])
        self.assertIn(' requests=1 ', self.live())
        self.keys('3')                              # opened, its card has the keys of the panel
        self.assertEqual(self.until_answered()[0]['behavior'], 'deny')

    def test_buttons_are_dead_for_half_a_second(self):
        self.ask('tool', lock=1500)
        self.assertEqual(self.head()['live'], '0')
        self.keys('1', '3', 'Escape', 'Return')
        self.assertEqual(self.answers(), [])
        self.assertIn(' requests=1 ', self.live())
        self.until(lambda: self.head()['live'] == '1', 'the lock ends')
        self.keys('1')
        self.assertEqual(self.until_answered()[0]['behavior'], 'allow')

    def test_the_lock_is_half_a_second(self):
        self.start()
        self.chat('tool', 'waiting')                # agent-timing untouched: 500 ms
        self.assertEqual(self.head()['live'], '0')
        self.keys('1')
        self.assertEqual(self.answers(), [])
        time.sleep(0.6)
        self.assertEqual(self.head()['live'], '1')
        self.keys('1')
        self.until_answered()

    def test_a_withdrawn_card_sends_nothing(self):
        self.ask('withdraw')
        self.assertEqual(self.head()['title'], 'Allow this bash command?')
        self.until(lambda: 'info Withdrawn by Claude' in self.thread(), 'the withdrawn row')
        self.assertEqual(self.card(), (None, []))
        self.keys('1', 'Return')
        self.command('agent-card 1')
        self.command('wait-agent ready')
        self.assertEqual(self.answers(), [])
        self.assertEqual([m for m in self.stdin() if m.get('type') == 'control_response'], [])

    def test_fold_and_unfold(self):
        self.ask('tool')
        open_h = int(re.search(r' h=(\d+)', self.command('print-agent-card-fit').splitlines()[0]).group(1))
        self.command('agent-card fold')
        self.assertEqual(self.head()['folded'], '1')
        folded = self.command('print-agent-card-fit').splitlines()[0]
        self.assertLess(int(re.search(r' h=(\d+)', folded).group(1)), open_h)
        self.assertEqual(re.findall(r'(?<=[;=])([a-zA-Z])\d*:', folded), ['f', 't'])      # its header only
        self.keys('1')
        time.sleep(0.2)
        self.assertEqual(self.answers(), [])
        self.keys('Return')                         # opens it again
        self.assertEqual(self.head()['folded'], '0')
        self.keys('3')
        self.assertEqual(self.until_answered()[0]['behavior'], 'deny')

    def test_card_fits_and_every_button_is_reachable(self):
        self.ask('mixed')
        for line in self.command('print-agent-card-fit').splitlines():
            size, width, h = map(int, re.match(r'size=(\d+) w=(\d+) h=(\d+) ', line).groups())
            fx, fy, fw, fh = map(int, re.search(r' frame=([\d,]+)', line).group(1).split(','))
            items = [(m.group(1), int(m.group(2) or 0), *map(int, m.group(3).split(',')))
                     for m in re.finditer(r'([a-zA-Z])(\d*):([\d,]+);', line)]
            what = f'size {size} width {width}'
            self.assertEqual(fx + fw + fx, width, what)
            for kind, n, x, y, w, ih in items:
                self.assertGreaterEqual(x, fx, (what, kind, n))
                self.assertLessEqual(x + w, fx + fw, (what, kind, n))
                self.assertGreaterEqual(y, fy, (what, kind, n))
                self.assertLessEqual(y + ih, fy + fh, (what, kind, n))
            boxes = [i for i in items if i[0] != 'l']
            for i, a in enumerate(boxes):           # nothing overlaps
                for b in boxes[i + 1:]:
                    apart = (a[2] + a[4] <= b[2] or b[2] + b[4] <= a[2] or a[3] + a[5] <= b[3] or b[3] + b[5] <= a[3])
                    self.assertTrue(apart, (what, a, b))
            for kind, n, x, y, w, ih in items:      # a label's lines inside their button
                if kind == 'l':
                    button = next(i for i in items if i[0] == 'b' and i[1] == n)
                    self.assertTrue(button[2] <= x and x + w <= button[2] + button[4] and
                                    button[3] <= y and y + ih <= button[3] + button[5], (what, n))
            labels = [i for i in items if i[0] == 'l']
            self.assertTrue(all(w >= 8 for _, _, _, _, w, _ in labels), what)
            self.assertEqual(sorted({i[1] for i in items if i[0] == 'b'}), [1, 2, 3], what)
        # at the largest text in the narrowest panel the card is cut: Down reaches every control, in view
        self.stop()
        self.ask('mixed', extra='[agents]\nfont_size = 32\n[ui]\nagents_width = 240\n')
        head = self.head()
        narrow = next(line for line in self.command('print-agent-card-fit').splitlines()
                      if line.startswith('size=32 w=240 '))
        self.assertLess(int(head['room']), int(re.search(r' h=(\d+)', narrow).group(1)))
        seen = []
        for _ in range(5):
            self.keys('Down')
            head = self.head()
            seen.append(head['focus'])
            scroll, room, fy, fh = (int(head[k]) for k in ('scroll', 'room', 'fy', 'fh'))
            if fh <= room:
                self.assertTrue(scroll <= fy and fy + fh <= scroll + room, head)
            else:
                self.assertTrue(scroll <= fy <= scroll + room, head)
        self.assertEqual(seen, ['2', '3', 'field', 'edit', '1'])
        self.keys('Down', 'Down')                   # No, by the keys alone
        self.keys('Return')
        self.assertEqual(self.until_answered()[0]['behavior'], 'deny')


if __name__ == '__main__':
    unittest.main()
