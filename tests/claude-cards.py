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


# ---- the question card (task 10) ----

LAYOUT_Q, CHECKS_Q, SIZE_Q = 'Which layout should the page use?', 'Which checks should run?', 'How big is it?'


def fenced(preview):
    """A preview as the extension shows it (webview index.js @5232059 `_8n`): its trailing line feeds cut, then
    in a ```text fence unless a line of it opens a fence of its own."""
    text = preview.rstrip('\n')
    if re.search(r'^ {0,3}`{3,}[^`]*$', text, re.M):
        return text
    ticks = '`' * (max([2] + [len(run) for run in re.findall(r'`+', text)]) + 1)
    return f'{ticks}text\n{text}\n{ticks}'


class QuestionCardTest(CardCase):
    """Task 10: AskUserQuestion as a card (ext-webview-ui.md 4.12, 4.13, 7.4; the real CLI's finding 23): a tab
    per question, radio and checkbox rows, Other with its field, previews, "Submit answers"."""

    def ask3(self, extra='', advance=0):
        self.ask('ask3', extra=extra)
        self.command(f'agent-timing advance={advance}')

    def tabs(self):
        """(header, answered, current) per tab."""
        return [tuple(re.match(r'\d+ (.*) answered=(\d) current=(\d)$', line).groups())
                for line in self.lines('tab')]

    def current(self):
        return next(i for i, (_, _, cur) in enumerate(self.tabs(), 1) if cur == '1')

    def options(self):
        """(label, picked, sel) per row of the current tab, Other last."""
        return [tuple(re.match(r'\d+ (.*) picked=(\d) sel=(\d)$', line).groups()) for line in self.lines('option')]

    def picked(self):
        return [label for label, picked, _ in self.options() if picked == '1']

    def preview(self):
        """(place, caption, body) or None."""
        line = self.lines('preview')[0]
        return None if line == 'none' else tuple(line.split('\t'))

    def submit_enabled(self):
        return self.lines('submit') == ['enabled=1']

    def test_tabs_and_answered_marks(self):
        self.ask3()
        head = self.head()
        self.assertEqual((head['kind'], head['title'], head['focus'], head['keys']),
                         ('questions', 'Questions', 'options', '1'))
        self.assertEqual(self.tabs(), [('Layout', '0', '1'), ('Checks', '0', '0'), ('Size', '0', '0')])
        self.assertEqual(self.lines('question'), [LAYOUT_Q])
        self.assertEqual(self.options(), [('Sidebar', '0', '1'), ('Top bar', '0', '0'), ('None', '0', '0'),
                                          ('Other', '0', '0')])
        self.assertEqual(self.command('print-agent-input').splitlines()[1],
                         f'card={LAYOUT_Q} options=Sidebar|Top bar|None|Other')
        self.command('agent-card 2')                # Top bar: answered, on to the next tab
        self.assertEqual(self.tabs(), [('Layout', '1', '0'), ('Checks', '0', '1'), ('Size', '0', '0')])
        self.assertEqual(self.lines('question'), [CHECKS_Q])
        self.keys('Left')
        self.assertEqual(self.tabs(), [('Layout', '1', '1'), ('Checks', '0', '0'), ('Size', '0', '0')])
        self.assertEqual(self.picked(), ['Top bar'])
        self.keys('Right', 'Right', 'Right')        # no further than the last
        self.assertEqual(self.current(), 3)
        self.command('agent-card 1')                # the last tab: no move
        self.assertEqual(self.tabs(), [('Layout', '1', '0'), ('Checks', '0', '0'), ('Size', '1', '1')])
        self.command('agent-focus box')             # text in the box while it waits
        self.command('agent-type hi')
        self.assertEqual((self.lines('waiting'), self.head()['keys']), (['Waiting for your answer…'], '0'))
        self.command('agent-card close')
        self.until_answered()

    def test_single_choice_advances(self):
        self.ask3(advance=300)
        self.command('agent-card 1')
        self.assertEqual((self.current(), self.picked()), (1, ['Sidebar']))     # it shows the pick a moment
        self.until(lambda: self.current() == 2, 'the move to the next tab', 3)
        self.assertEqual(self.head()['focus'], 'options')
        self.command('agent-card 1')                # a multi-select row stays
        time.sleep(0.5)
        self.assertEqual((self.current(), self.picked()), (2, ['lint']))
        self.command('agent-timing advance=0')
        self.keys('Left', 'Down', 'Space')          # at once with advance=0
        self.assertEqual(self.current(), 2)
        self.keys('Left')
        self.assertEqual(self.picked(), ['Top bar'])
        self.command('agent-card close')
        self.until_answered()

    def test_multi_select_joins_with_commas(self):
        self.ask3()
        self.command('agent-card 1')                # Sidebar
        self.command('agent-card 3')                # types
        self.command('agent-card 1')                # lint
        self.command('agent-card 2')                # tests, then off again
        self.command('agent-card 2')
        self.assertEqual(self.picked(), ['lint', 'types'])
        self.keys('Right')
        self.command('agent-card 2')                # big
        self.command('agent-card submit')
        answer = self.until_answered()[0]
        self.assertEqual(list(answer), ['behavior', 'updatedInput', 'toolUseID'])
        self.assertEqual(answer['behavior'], 'allow')
        self.assertEqual(answer['updatedInput'], {
            'questions': self.fake_questions(),
            'answers': {LAYOUT_Q: 'Sidebar', CHECKS_Q: 'lint, types', SIZE_Q: 'big'}})
        self.command('wait-agent ready')            # the fake's reply is the answers it took
        self.assertTrue(self.thread()[-1].startswith(chat.REPLY + f'{{"{SIZE_Q}": "big", "{CHECKS_Q}": "lint,'),
                        self.thread())
        self.assertEqual(self.card(), (None, []))

    def fake_questions(self):
        spec = importlib.util.spec_from_file_location('fake_claude_questions', chat.FAKE)
        source = chat.FAKE.read_text(encoding='utf-8')
        block = source[source.index('QUESTIONS_THREE = ['):source.index('\n\n\ndef s_ask3')]
        scope = {}
        exec(block, scope)
        return scope['QUESTIONS_THREE']

    def test_other_free_text(self):
        self.ask3()
        self.command('agent-card 4')                # Other on a single choice: its field takes the keys
        self.assertEqual(self.head()['focus'], 'field')
        self.assertEqual(self.picked(), ['Other'])
        self.assertEqual(self.lines('other'), [''])
        self.assertEqual(self.tabs()[0][1], '1')    # Other counts as an answer (the extension's rule)
        self.keys('m', 'i', 'n', 'e')
        self.assertEqual(self.lines('other'), ['mine'])
        self.keys('Return')                         # Enter in Other: the next question
        self.assertEqual((self.current(), self.head()['focus']), (2, 'options'))
        self.command('agent-card 1')                # lint and Other on a multi-select
        self.command('agent-card 4')
        self.command('agent-card-text other and docs')
        self.assertEqual(self.picked(), ['lint', 'Other'])
        self.keys('Return')
        self.command('agent-card 3')                # the last question: Other, and blanks are no answer
        self.keys('Space', 'Space')
        self.assertEqual(self.lines('other'), ['  '])
        self.assertFalse(self.submit_enabled())
        self.command('agent-card 1')                # a label instead: Other goes, its text stays
        self.assertEqual(self.picked(), ['small'])
        self.assertTrue(self.submit_enabled())
        self.command('agent-card 3')
        self.assertEqual(self.lines('other'), ['  '])
        self.command('agent-card-text other huge')
        self.assertTrue(self.submit_enabled())
        self.command('agent-card submit')
        answer = self.until_answered()[0]
        self.assertEqual(answer['updatedInput']['answers'], {LAYOUT_Q: 'mine', CHECKS_Q: 'lint, and docs',
                                                             SIZE_Q: 'huge'})

    def test_submit_waits_for_every_answer(self):
        self.ask3()
        self.assertFalse(self.submit_enabled())
        self.command('agent-card 1')
        self.command('agent-card 1')
        self.assertFalse(self.submit_enabled())
        self.command('agent-card submit')
        self.keys('1')
        self.keys('Up')                             # Submit answers, from the first row up
        self.assertEqual(self.head()['focus'], '1')
        self.keys('Return')
        time.sleep(0.3)
        self.assertEqual(self.answers(), [])
        self.assertIn(' requests=1 ', self.live())
        self.keys('Right')                          # not from Submit
        self.assertEqual(self.current(), 2)
        self.keys('Down', 'Right')                  # the first row again, then the last tab
        self.command('agent-card 1')
        self.assertTrue(self.submit_enabled())
        self.keys('1')
        answer = self.until_answered()[0]
        self.assertEqual(answer['updatedInput']['answers'], {LAYOUT_Q: 'Sidebar', CHECKS_Q: 'lint', SIZE_Q: 'small'})

    def test_preview_beside_and_under(self):
        questions = self.fake_questions()
        sidebar, top = (fenced(o['preview']).replace('\n', '\\n') for o in questions[0]['options'][:2])
        self.ask3(extra='[ui]\nagents_width = 480\n')
        self.assertEqual(self.preview(), ('beside', 'Preview: Sidebar', sidebar))
        self.keys('Down')
        self.assertEqual(self.preview(), ('beside', 'Preview: Top bar', top))
        self.assertEqual(top, 'Top bar\\n=======\\n\\n```\\n[a] [b] [c]\\n```')     # its own fence: as it is
        self.keys('Down')
        self.assertEqual(self.preview(), ('beside', 'Preview: None', 'No preview for this option'))
        self.keys('Down')
        self.assertEqual(self.preview(), ('beside', 'Preview: Other', 'No preview for this option'))
        fit = self.command('print-agent-card-fit').splitlines()
        self.keys('Right')                          # a multi-select question has none
        self.assertIsNone(self.preview())
        for line in fit:
            if ' items=' not in line or 'p:' not in line:
                continue
            width = int(re.match(r'size=\d+ w=(\d+) ', line).group(1))
            items = [(m.group(1), *map(int, m.group(3).split(','))) for m in
                     re.finditer(r'([a-zA-Z])(\d*):([\d,]+);', line)]
            pane = next(i for i in items if i[0] == 'p')
            rows = [i for i in items if i[0] == 'o']
            if width >= 480:
                self.assertGreaterEqual(pane[1], max(r[1] + r[3] for r in rows), line)
                self.assertLess(pane[2], max(r[2] + r[4] for r in rows), line)
            else:
                self.assertGreaterEqual(pane[2], max(r[2] + r[4] for r in rows), line)
        self.command('agent-card close')
        self.until_answered()
        self.stop()
        self.ask3(extra='[ui]\nagents_width = 240\n')
        self.assertEqual(self.preview(), ('under', 'Preview: Sidebar', sidebar))
        self.command('agent-card close')
        self.until_answered()

    def test_question_keys(self):
        self.ask3()
        self.keys('Down', 'Down', 'Down', 'Down')   # round the rows: Other, then Submit, then the first again
        self.assertEqual(self.head()['focus'], '1')
        self.keys('Down')
        self.assertEqual((self.head()['focus'], self.options()[0][2]), ('options', '1'))
        self.keys('Up', 'Up')                       # Submit, then Other
        self.assertEqual([sel for _, _, sel in self.options()], ['0', '0', '0', '1'])
        self.keys('Up', 'Return')                   # None, picked by Enter: on to Checks
        self.assertEqual((self.current(), self.tabs()[0][1]), (2, '1'))
        self.keys('Space', 'Down', 'Down', 'Space')     # lint and types
        self.assertEqual(self.picked(), ['lint', 'types'])
        self.keys('Space')                          # types off again
        self.assertEqual(self.picked(), ['lint'])
        self.keys('Down', 'Space')                  # Other: its field
        self.assertEqual(self.head()['focus'], 'field')
        self.keys('2', 'Left', 'x')                 # keys in the field are the field's
        self.assertEqual((self.lines('other'), self.current()), (['x2'], 2))
        self.keys('Return')                         # the next question
        self.assertEqual(self.current(), 3)
        self.keys('Left', 'Left', 'Left')
        self.assertEqual(self.current(), 1)
        self.keys('Right', 'Right', 'Down', 'Return')
        self.assertTrue(self.submit_enabled())
        self.keys('Down', 'Down')                   # Other, Submit
        self.assertEqual(self.head()['focus'], '1')
        self.keys('Return')
        answer = self.until_answered()[0]
        self.assertEqual(answer['updatedInput']['answers'], {LAYOUT_Q: 'None', CHECKS_Q: 'lint, x2', SIZE_Q: 'big'})

    def test_close_denies(self):
        self.ask3()
        self.command('agent-card 1')
        self.command('agent-card close')            # the ×: No, as the extension's onClose
        answer = self.until_answered()[0]
        self.assertEqual((answer['behavior'], answer['message'], answer['interrupt']), ('deny', chat.REJECTED, True))
        self.command('wait-agent ready')
        self.command('agent-prompt ask3')           # and Escape does the same
        self.command('wait-agent waiting')
        self.keys('Escape')
        answer = self.until_answered(2)[1]
        self.assertEqual((answer['behavior'], answer['interrupt']), ('deny', True))
        self.command('wait-agent ready')
        self.command('agent-timing card=1500')      # nothing in the first moments, × included
        self.command('agent-prompt ask3')
        self.command('wait-agent waiting')
        self.assertEqual(self.head()['live'], '0')
        self.command('agent-card close')
        self.keys('Escape')
        time.sleep(0.2)
        self.assertEqual(len(self.answers()), 2)
        self.until(lambda: self.head()['live'] == '1', 'the lock ends')
        self.command('agent-card close')
        self.assertEqual(self.until_answered(3)[2]['behavior'], 'deny')

    def test_question_card_fits(self):
        self.ask3()
        for tab in (1, 2):
            for line in self.command('print-agent-card-fit').splitlines():
                size, width, h = map(int, re.match(r'size=(\d+) w=(\d+) h=(\d+) ', line).groups())
                fx, fy, fw, fh = map(int, re.search(r' frame=([\d,]+)', line).group(1).split(','))
                items = [(m.group(1), int(m.group(2) or 0), *map(int, m.group(3).split(',')))
                         for m in re.finditer(r'([a-zA-Z])(\d*):([\d,]+);', line)]
                what = f'tab {tab} size {size} width {width}'
                self.assertEqual(fx + fw + fx, width, what)
                for kind, n, x, y, w, ih in items:
                    self.assertTrue(fx <= x and x + w <= fx + fw and fy <= y and y + ih <= fy + fh,
                                    (what, kind, n, x, y, w, ih))
                    self.assertGreaterEqual(w, 8, (what, kind, n))
                boxes = [i for i in items if i[0] not in 'lk']
                for i, a in enumerate(boxes):       # nothing overlaps
                    for b in boxes[i + 1:]:
                        apart = (a[2] + a[4] <= b[2] or b[2] + b[4] <= a[2] or a[3] + a[5] <= b[3] or
                                 b[3] + b[5] <= a[3])
                        self.assertTrue(apart, (what, a, b))
                for kind, n, x, y, w, ih in items:  # a row's lines inside it, the button's in the button
                    if kind in 'lk':
                        box = next(i for i in items if i[0] == ('b' if kind == 'l' else 'o') and i[1] == n)
                        self.assertTrue(box[2] <= x and x + w <= box[2] + box[4] and
                                        box[3] <= y and y + ih <= box[3] + box[5], (what, kind, n))
                kinds = [i[0] for i in items]
                self.assertEqual(kinds.count('T'), 3, what)
                self.assertEqual(kinds.count('o'), 4, what)
                self.assertEqual((kinds.count('x'), kinds.count('f'), kinds.count('b')), (1, 1, 1), what)
                self.assertEqual(kinds.count('p'), 1 if tab == 1 else 0, what)
            self.keys('Right')
        # at the largest text in the narrowest panel the card is cut: Down keeps the focused control in view
        self.stop()
        self.ask3(extra='[agents]\nfont_size = 32\n[ui]\nagents_width = 240\n')
        head = self.head()
        narrow = next(line for line in self.command('print-agent-card-fit').splitlines()
                      if line.startswith('size=32 w=240 '))
        self.assertLess(int(head['room']), int(re.search(r' h=(\d+)', narrow).group(1)))
        for _ in range(5):
            self.keys('Down')
            head = self.head()
            scroll, room, fy, fh = (int(head[k]) for k in ('scroll', 'room', 'fy', 'fh'))
            if fh <= room:
                self.assertTrue(scroll <= fy and fy + fh <= scroll + room, head)
            else:
                self.assertTrue(scroll <= fy <= scroll + room, head)
        self.assertEqual(self.head()['focus'], 'options')
        self.command('agent-card close')
        self.until_answered()


# ---- plan review (task 11) ----
PLAN = '# Plan\n\n1. Add the file\n2. Test it'
# the extension's words (webview index.js @5214753 `zIe`, @5657000-5662000)
KEEP = 'User chose to stay in plan mode and continue planning'
COMMENTS = '\n\nComments on the plan:\n'
PLAN_BUTTONS = ['Yes, and auto-accept', 'Yes, and manually approve edits', 'No, keep planning']


class PlanTest(CardCase):
    """Task 11: plan review (ext-webview-ui.md 4.10, 4.11; finding 24): the plan in an editor tab of its own
    (TAB_MDDOC), comments on text selected there, the card's answers as the extension sends them. Nothing
    here saves a rule: the manual answer's setMode goes to destination session."""

    def plan(self, prompt='plan', env=None, extra=''):
        """rhun in plan mode, the cards' lock off, a conversation whose prompt asks for a plan's review."""
        self.ask(prompt, env=env, claude=self.claude_section('initial_mode = plan\n' + extra))

    def tabs(self):
        """print-mdtab: a dict per Markdown tab (tab, title, active, comment, selected) with its 'text' lines."""
        tabs = []
        for line in self.command('print-mdtab').splitlines():
            if line.startswith('mdtab '):
                tabs.append(dict(re.findall(r'(\w+)=(.*?)(?= \w+=|$)', line[6:]), text=[]))
            elif line.startswith('text'):
                tabs[-1]['text'].append(line[5:])
        return tabs

    def comment(self, phrase, text):
        self.command('mdtab-select ' + phrase)
        self.command('mdtab-comment ' + text)

    def answer(self, n=1):
        return self.until_answered(n)[n - 1]

    def test_plan_opens_in_a_tab(self):
        self.plan()
        tabs = self.tabs()
        self.assertEqual(len(tabs), 1, tabs)
        self.assertEqual((tabs[0]['title'], tabs[0]['active'], tabs[0]['comment'], tabs[0]['selected']),
                         ('Plan', '1', '1', '-'))
        self.assertEqual(tabs[0]['text'], PLAN.split('\n'))
        self.assertIn('activeTab=markdown', self.command('print-context activeTab'))
        head, lines = self.card()
        self.assertEqual((head['kind'], head['title'], head['focus']), ('plan', 'Accept this plan?', '1'))
        self.assertEqual(lines, ['hint Select text in the preview to add comments',
                                 *(f'button {i} {label}' for i, label in enumerate(PLAN_BUTTONS, 1)), 'field '])
        self.assertNotIn('agent # Plan', self.thread())             # phase 3: the plan is the call's row
        self.assertIn('\n  in 4/34 # Plan\n', self.command('print-agent-rows content 1 1'))
        self.assertEqual(self.command('print-agent-input').splitlines()[1],
                         'card=Accept this plan? options=' + '|'.join(PLAN_BUTTONS))
        self.command('agent-card 3')
        self.command('wait-agent ready')
        self.assertEqual(self.tabs(), [])                           # the answer closes it

    def test_selecting_and_commenting(self):
        self.plan()
        self.command('mdtab-select Add the')
        self.assertEqual(self.tabs()[0]['selected'], 'Add the')
        self.command('mdtab-comment fix this')
        head, lines = self.card()
        self.assertEqual((head['title'], head['focus']), ('Continue planning', '1'))
        self.assertEqual(lines, ['hint 1 comment will be included as feedback',
                                 'button 1 Send feedback and keep planning', 'field ',
                                 'comment 1 "Add the" fix this'])
        self.assertEqual(self.tabs()[0]['selected'], '-')            # a comment's text is no longer selected
        self.comment('the file 2. Test', 'and this')                 # across two lines of the plan
        self.assertEqual(self.lines('hint'), ['2 comments will be included as feedback'])
        self.assertEqual(self.lines('comment'), ['1 "Add the" fix this', '2 "the file\\n2. Test" and this'])
        self.assertEqual(self.answers(), [])
        _, ok = self.reply('mdtab-select no such words')
        self.assertFalse(ok)
        self.keys('1')                                              # the panel has the keys: Send feedback
        answer = self.answer()
        self.assertEqual(answer['message'], KEEP + COMMENTS + '[Re: "Add the"] fix this\n'
                                            '[Re: "the file\n2. Test"] and this')

    def test_the_quote_is_taken_when_comment_is_pressed(self):
        self.plan()
        self.command('mdtab-select Test it')
        self.command('mdtab-comment')                               # the button: the prompt opens
        self.assertEqual(self.command('print-palette').splitlines()[:2],
                         ['prompt=Comment on the selection', 'field='])
        self.command('resize 1000 700')                            # laid out again: the selection is gone
        self.until(lambda: self.tabs()[0]['selected'] == '-', 'the selection cleared by the new layout')
        self.command('type fix later')
        self.keys('Return')
        self.assertEqual(self.lines('comment'), ['1 "Test it" fix later'])
        self.assertTrue(self.command('print-palette').startswith('none'))
        self.command('mdtab-comment')                               # nothing selected: no prompt
        self.assertTrue(self.command('print-palette').startswith('none'))

    def test_feedback_with_comments_goes_back(self):
        self.plan('plan2')
        self.comment('Add the file', 'name it notes.txt')
        self.comment('Test it', 'with the fake')
        self.command('agent-card-text field try again')
        self.command('agent-card 1')
        answer = self.answer()
        self.assertEqual(answer['message'], REASON + ' try again' + COMMENTS +
                         '[Re: "Add the file"] name it notes.txt\n[Re: "Test it"] with the fake')
        self.assertIs(answer['interrupt'], False)
        # Claude plans again in the same turn (finding 24): a second card and its own tab
        self.until(lambda: self.head() and self.head()['title'] == 'Accept this plan?', 'the second plan')
        tabs = self.tabs()
        self.assertEqual(len(tabs), 1, tabs)
        self.assertEqual(tabs[0]['text'][0], '# Plan, revised')
        self.comment('revised', 'shorter')                          # comments only
        self.command('agent-card 1')
        answer = self.answer(2)
        self.assertEqual((answer['message'], answer['interrupt']), (KEEP + COMMENTS + '[Re: "revised"] shorter', False))
        self.until(lambda: self.head() and self.head()['title'] == 'Accept this plan?', 'the third plan')
        self.command('agent-card 2')                                # Yes, and manually approve edits
        self.command('wait-agent ready')
        self.assertEqual([r['feedback'] for r in self.records() if 'feedback' in r], [None])   # no userFeedback
        self.assertEqual(self.thread()[-1], chat.REPLY + 'approved default')
        self.assertEqual(self.tabs(), [])

    def test_yes_auto_accept_sets_the_mode_first(self):
        self.plan()
        self.command('agent-card 1')
        answer = self.answer()
        self.assertEqual(list(answer), ['behavior', 'updatedInput', 'toolUseID'])
        self.assertEqual(answer['updatedInput']['plan'], PLAN)
        lines = self.control()
        self.assertEqual(lines[-2]['request'], {'subtype': 'set_permission_mode', 'mode': 'acceptEdits'})
        self.assertEqual(lines[-1]['response']['response']['behavior'], 'allow')
        self.command('wait-agent ready')
        self.assertIn(' mode=acceptEdits ', self.live())
        self.assertEqual(self.tabs(), [])
        # a model with auto mode: "use auto mode", and auto first
        self.stop()
        self.fake_log.unlink()
        self.plan(env={'FAKE_CLAUDE_MODELS': 'auto'})
        self.assertEqual(self.buttons()[0], 'Yes, and use auto mode')
        self.command('agent-card 1')
        self.answer()
        self.assertEqual(self.mode_requests(), [{'subtype': 'set_permission_mode', 'mode': 'auto'}])
        self.command('wait-agent ready')
        self.assertIn(' mode=auto ', self.live())
        # auto refused: acceptEdits, then the allow
        self.stop()
        self.fake_log.unlink()
        self.plan(env={'FAKE_CLAUDE_MODELS': 'auto', 'FAKE_CLAUDE_REFUSE_AUTO': '1'})
        self.command('agent-card 1')
        self.answer()
        lines = self.control()
        self.assertEqual([m['request'] for m in lines[-3:-1]], [{'subtype': 'set_permission_mode', 'mode': 'auto'},
                                                              {'subtype': 'set_permission_mode', 'mode': 'acceptEdits'}])
        self.assertEqual(lines[-1]['response']['response']['behavior'], 'allow')
        self.command('wait-agent ready')
        self.assertIn(' mode=acceptEdits ', self.live())

    def test_yes_manual_sends_the_set_mode_update(self):
        self.plan()
        self.command('agent-card 2')
        answer = self.answer()
        self.assertEqual(answer['updatedPermissions'], [{'type': 'setMode', 'mode': 'default', 'destination': 'session'}])
        self.assertEqual(answer['updatedInput']['plan'], PLAN)
        lines = self.control()
        self.assertEqual(lines[-2]['request'], {'subtype': 'set_permission_mode', 'mode': 'default'})
        self.assertEqual(lines[-1]['response']['response']['behavior'], 'allow')
        self.command('wait-agent ready')
        self.assertEqual(self.thread()[-1], chat.REPLY + 'approved default')
        self.assertIn(' mode=default ', self.live())
        self.assertFalse((self.project / '.claude').exists())

    def test_no_without_anything_interrupts(self):
        self.plan()
        self.command('agent-card 3')
        answer = self.answer()
        self.assertEqual((answer['message'], answer['interrupt']), (KEEP, True))
        self.command('wait-agent ready')
        self.assertEqual(self.thread()[-1], 'info Interrupted')
        self.assertEqual(self.mode_requests(), [])
        # with text only: the extension's reason, and Claude goes on
        self.command('agent-prompt plan')
        self.command('wait-agent waiting')
        self.command('agent-card-text field not yet')
        self.keys('4', 'Return')                                    # the field, then Enter in it
        answer = self.answer(2)
        self.assertEqual((answer['message'], answer['interrupt']), (REASON + ' not yet', False))
        self.command('wait-agent ready')
        self.assertEqual(self.thread()[-1], chat.REPLY + 'planning')

    def test_remove_comment(self):
        self.plan()
        self.comment('Add the file', 'one')
        self.comment('Test it', 'two')
        self.command('agent-card-uncomment 1')
        self.assertEqual(self.lines('comment'), ['1 "Test it" two'])
        self.assertEqual(self.lines('hint'), ['1 comment will be included as feedback'])
        self.comment('Plan', 'three')
        self.command('agent-focus panel')
        self.keys('Up')                                             # from Send feedback up to the last ×
        self.assertEqual(self.head()['focus'], 'x2')
        self.keys('Return')
        self.assertEqual(self.lines('comment'), ['1 "Test it" two'])
        self.command('agent-card-uncomment 1')
        head, lines = self.card()
        self.assertEqual((head['title'], head['focus']), ('Accept this plan?', '1'))
        self.assertEqual(self.buttons(), PLAN_BUTTONS)
        self.assertEqual(self.lines('comment'), [])
        _, ok = self.reply('agent-card-uncomment 1')
        self.assertFalse(ok)
        self.command('agent-card 3')
        self.assertEqual(self.answer()['message'], KEEP)

    def test_closing_the_tab_sends_nothing(self):
        self.plan()
        self.command('cmd close_tab')
        self.assertEqual(self.tabs(), [])
        time.sleep(0.2)
        self.assertEqual(self.answers(), [])
        self.assertIn(' requests=1 ', self.live())
        self.assertEqual(self.head()['title'], 'Accept this plan?')
        _, ok = self.reply('mdtab-select Add the')
        self.assertFalse(ok)
        self.command('agent-card 2')
        self.assertEqual(self.answer()['behavior'], 'allow')

    def test_withdrawn_plan_closes_its_tab_and_prompt(self):
        self.plan('planwithdraw 2500')
        self.command('mdtab-select Add the file')
        self.command('mdtab-comment')
        self.assertTrue(self.command('print-palette').startswith('prompt=Comment on the selection'))
        self.command('type too late')
        self.until(lambda: 'info Withdrawn by Claude' in self.thread(), 'the withdrawn row')
        self.assertEqual(self.tabs(), [])
        self.assertTrue(self.command('print-palette').startswith('none'))
        self.keys('Return')
        self.command('agent-card 1')
        self.command('wait-agent ready')
        self.assertEqual(self.answers(), [])
        self.assertEqual([m for m in self.stdin() if m.get('type') == 'control_response'], [])
        self.assertEqual(self.card(), (None, []))

    def test_plan_open_command(self):
        self.plan()
        self.command('agent-card-text field later')
        self.command('agent-card 3')                                # keeps planning, in plan mode
        self.command('wait-agent ready')
        self.assertEqual(self.tabs(), [])
        self.command('agent-prompt /plan open')
        self.until(lambda: self.tabs(), 'the plan in a tab')
        tab = self.tabs()[0]
        self.assertEqual((tab['title'], tab['comment'], tab['text']), ('Plan', '0', PLAN.split('\n')))
        self.assertIn({'subtype': 'get_plan'}, [m['request'] for m in self.control() if 'request' in m])
        self.command('mdtab-select Add the')
        _, ok = self.reply('mdtab-comment no button here')
        self.assertFalse(ok)
        self.assertEqual(self.prompts(), ['plan'])                  # /plan open is no prompt
        # again: the same tab, not a second one
        self.command('agent-prompt /plan open')
        time.sleep(0.3)
        self.assertEqual(len(self.tabs()), 1)
        # a conversation of its own, still without a plan: the extension's info row
        self.command('agent-new claude')
        self.command('agent-prompt hello')
        self.command('wait-agent ready')
        self.command('agent-prompt /plan open')
        self.until(lambda: 'info Already in plan mode. No plan written yet.' in self.thread(), 'the info row')

    def test_mdtab_is_not_reopened_or_saved(self):
        self.plan()
        before = sorted(p.name for p in self.project.iterdir())
        self.command('cmd save')
        self.command('cmd save_as')
        self.assertTrue(self.command('print-palette').startswith('none'))
        self.assertEqual(sorted(p.name for p in self.project.iterdir()), before)
        self.command('cmd close_tab')
        self.command('cmd reopen_closed_tab')
        self.assertEqual(self.tabs(), [])
        self.command('agent-card 2')
        self.command('wait-agent ready')
        self.quit()
        sessions = [p for p in (self.work / 'state').rglob('*') if p.is_file()]
        self.assertFalse(any('Plan' in p.read_text(encoding='utf-8', errors='replace') for p in sessions
                             if p.suffix == '.session' or p.name.endswith('.session')), sessions)

    def test_the_tab_leaves_a_document_being_typed_in(self):
        """With the keyboard in a text document the plan's tab opens behind the active tab; else it shows, and
        the keyboard stays where it was (the panel's card keeps it)."""
        (self.project / 'notes.txt').write_text('notes\n', encoding='utf-8')
        self.start(self.claude_section('initial_mode = plan\n'), env={'FAKE_CLAUDE_INIT_MS': '800'})
        self.command(f'open {self.project / "notes.txt"}')
        self.command('agent-timing card=0')
        self.command('agent-new claude')
        self.command('agent-prompt plan')
        self.command('agent-focus editor')
        self.command('wait-agent waiting')
        tab = self.tabs()[0]
        self.assertEqual((tab['title'], tab['active']), ('Plan', '0'))
        self.assertIn(' focus=0 ', self.command('print-state'))
        self.keys('x')
        self.assertIn('xnotes', self.command('print-doc'))
        self.command('cmd next_tab')                                # the user goes to it
        self.assertEqual(self.tabs()[0]['active'], '1')
        self.command('agent-card 3')
        self.answer()
        self.command('wait-agent ready')
        # the keyboard in the panel: the tab shows, the keyboard stays in the panel
        self.command('agent-focus panel')
        self.command('agent-prompt plan')
        self.command('wait-agent waiting')
        self.assertEqual(self.tabs()[0]['active'], '1')
        self.assertIn(' focus=6 ', self.command('print-state'))
        self.assertEqual(self.head()['keys'], '1')

    def test_plan_card_and_tab_fit(self):
        """The plan card with two comments at panel font sizes 8 to 32 and widths 240 to 900: nothing overlaps,
        everything inside the frame."""
        self.plan()
        self.comment('Add the file', 'a comment long enough to wrap in a narrow panel at a large size')
        self.comment('Test it', 'two')
        for line in self.command('print-agent-card-fit').splitlines():
            size, width = map(int, re.match(r'size=(\d+) w=(\d+) ', line).groups())
            fx, fy, fw, fh = map(int, re.search(r' frame=([\d,]+)', line).group(1).split(','))
            items = [(m.group(1), *map(int, m.group(3).split(',')))
                     for m in re.finditer(r'([a-zA-Z])(\d*):([\d,]+);', line)]
            what = f'size {size} width {width}'
            self.assertIn('x', [i[0] for i in items], what)
            for kind, x, y, w, ih in items:
                self.assertTrue(fx <= x and x + w <= fx + fw and fy <= y and y + ih <= fy + fh, (what, kind))
            boxes = [i for i in items if i[0] != 'l']
            for i, a in enumerate(boxes):
                for b in boxes[i + 1:]:
                    apart = (a[1] + a[3] <= b[1] or b[1] + b[3] <= a[1] or a[2] + a[4] <= b[2] or b[2] + b[4] <= a[2])
                    self.assertTrue(apart, (what, a, b))
        self.command('agent-card 1')
        self.answer()


# the dialog cards: the bundle's strings (webview index.js: YPe and XPe @3423169, oOe, aOe, que, eOe, nOe, sOe,
# iOe, lOe @3426000-3429000, the cards FMt and zMt @5561231-5564700, ij @3595371)
DIALOG_KINDS = ['fable_overage_consent_prompt', 'auto_mode_server_fallback']
SWITCH = 'Switch to the default model and continue'
BUY = 'Buy usage credits on claude.ai'
LEARN = 'https://support.claude.com/en/articles/12429409-extra-usage-for-paid-claude-plans'
AUTO_HELP = 'https://code.claude.com/docs/en/permission-modes'
AUTO_DEFAULT = ("Auto mode is using Claude Code's built-in classifier in this session, and those classifier requests "
                "are billed. Continue to keep going in auto mode, or Stop to end this turn.")
OVERAGE = {     # variant: title, body, buttons (the fake's payloads: tests/scripts/fake-claude.py OVERAGE_DIALOGS)
    'consent': ('Continue on Fable with usage credits?', 'Fable runs on usage credits. You have $12.34 in credits. '
                'Your other models remain included in your plan.', [SWITCH, 'Continue with Fable']),
    'nobalance': ('Continue on Fable with usage credits?', 'Fable runs on usage credits, billed separately from your '
                  'plan. Your other models remain included in your plan.', [SWITCH, 'Continue with Fable']),
    'disabled': ('Fable requires usage credits', "Fable runs on usage credits, billed separately from your plan. You "
                 "don't have usage credits yet.", [SWITCH, BUY]),
    'empty': ('Fable requires usage credits', 'Fable runs on usage credits. You have €0.00 in credits.', [SWITCH, BUY]),
    'admin': ('Fable now runs on usage credits', 'Fable runs on usage credits, purchased separately from your plan.',
              [SWITCH, 'Request usage credits from your admin']),
    'plan': ('Fable now runs on usage credits', 'Fable was included in Pro as a promotion until November 30, and now '
             'runs on your usage credits. If you continue, Fable will use credits without asking again.',
             [SWITCH, 'Continue with usage credits']),
    'seat': ('Fable now runs on usage credits', 'Fable was included in standard seats for a limited time, and now '
             'requires usage credits.', [SWITCH, BUY]),
    'ended': ('Fable now runs on usage credits', 'Fable runs on usage credits. If you continue, Fable will use '
              'credits without asking again.', [SWITCH, 'Continue with usage credits']),
    'opus': ('Continue on Opus 5 with usage credits?', 'Opus 5 runs on usage credits. You have ¥150,000 in credits. '
             'Your other models remain included in your plan.', [SWITCH, 'Continue with Opus 5']),
    'other': ('Continue on Fable with usage credits?', 'Fable runs on usage credits. You have CHF 0.99 in '
              'credits. Your other models remain included in your plan.', [SWITCH, 'Continue with Fable']),
    'odd': ('Continue on Fable with usage credits?', 'Fable runs on usage credits. You have $2.50 in credits. Your '
            'other models remain included in your plan.', [SWITCH, 'Continue with Fable']),
}


class DialogTest(CardCase):
    """Task 12: the CLI's dialogs (ext-webview-ui.md 2.21 and 4.14; README.txt finding 25: the payloads and
    results are the CLI binary's schemas, no run produced one, so the fake's dialog scenarios have no recording
    behind them). Nothing here saves a setting: the model a switch_default answer clears is rhun's own choice."""

    def dialog(self, prompt):
        self.command('agent-prompt ' + prompt)
        self.command('wait-agent waiting')
        return self.card()

    def answered(self, n):
        return self.until_answered(n)[n - 1]

    def test_only_pinned_kinds_are_declared(self):
        self.start()
        self.chat('hello')
        self.assertEqual([r['initialize']['supportedDialogKinds'] for r in self.records() if 'initialize' in r],
                         [DIALOG_KINDS])

    def test_auto_mode_fallback_card(self):
        self.ask('dialog-auto')
        head, lines = self.card()
        self.assertEqual((head['kind'], head['title'], head['live'], head['focus'], head['keys']),
                         ('dialog', 'Auto mode is using a fallback', '1', '1', '1'))
        self.assertEqual(lines, ['detail The auto mode service could not be reached from this network.',
                                 'detail Claude Code checks each tool call with its own classifier for now.',
                                 'link ' + AUTO_HELP, 'button 1 Continue', 'button 2 Stop'])
        self.assertIn(' options=Continue|Stop', self.command('print-agent-input'))
        self.command('agent-card 1')
        self.assertEqual(self.answered(1), {'behavior': 'completed', 'result': 'continue'})
        self.command('wait-agent ready')
        self.assertEqual(self.card(), (None, []))
        self.assertTrue(self.thread()[-1].endswith(' continued'), self.thread())
        # no title and no paragraphs: the extension's own words (Escape is not Stop here: ReviewCardsTest)
        head, lines = self.dialog('dialog-auto empty')
        self.assertEqual(head['title'], '')
        self.assertEqual(lines, ['detail ' + AUTO_DEFAULT, 'link ' + AUTO_HELP, 'button 1 Continue', 'button 2 Stop'])
        self.keys('2')
        self.assertEqual(self.answered(2), {'behavior': 'completed', 'result': 'interrupt'})
        self.command('wait-agent ready')
        # a help link off claude.com and anthropic.com is not shown; a card without a × ignores "close"
        head, lines = self.dialog('dialog-auto badurl')
        self.assertEqual(lines, ['detail A paragraph.', 'button 1 Continue', 'button 2 Stop'])
        self.command('agent-card close')
        time.sleep(0.3)
        self.assertEqual(len(self.answers()), 2)
        self.keys('2')
        self.assertEqual(self.answered(3), {'behavior': 'completed', 'result': 'interrupt'})

    def test_overage_consent_variants(self):
        self.start()
        self.command('agent-timing card=0')
        self.chat('hello')
        n = 0
        for variant, (title, body, buttons) in OVERAGE.items():
            head, lines = self.dialog('dialog-overage ' + variant)
            self.assertEqual((head['kind'], head['title']), ('dialog', title), variant)
            self.assertEqual(lines, ['detail ' + body, 'link ' + LEARN] +
                             ['button %d %s' % (i + 1, b) for i, b in enumerate(buttons)] + ['close'], variant)
            self.command('agent-card close')
            n += 1
            self.assertEqual(self.answered(n), {'behavior': 'cancelled'}, variant)
            self.command('wait-agent ready')
        # consent: the toast says the credits are in use
        self.dialog('dialog-overage consent')
        self.command('agent-card 2')
        n += 1
        self.assertEqual(self.answered(n), {'behavior': 'completed', 'result': 'consent'})
        self.command('wait-agent ready')
        pills = [l[5:] for l in self.command('print-agents').splitlines() if l.startswith('pill ')]
        self.assertEqual(pills, ['Now using usage credits for Fable'])
        # an admin's member asks the admin
        self.dialog('dialog-overage admin')
        self.keys('2')
        n += 1
        self.assertEqual(self.answered(n), {'behavior': 'completed', 'result': 'request_admin'})
        self.command('wait-agent ready')
        # a request already sent: its button is greyed and does nothing
        head, lines = self.dialog('dialog-overage greyed')
        self.assertEqual(lines[-3:], ['button 1 ' + SWITCH, 'off 2 Request sent', 'close'])
        self.command('agent-card 2')
        self.keys('2')
        time.sleep(0.3)
        self.assertEqual(len(self.answers()), n)
        self.keys('Down')                                   # round to "Learn more": the greyed button is no stop
        self.assertEqual(self.head()['focus'], 'link')
        self.command('agent-card close')
        n += 1
        self.assertEqual(self.answered(n), {'behavior': 'cancelled'})
        self.command('wait-agent ready')
        self.assertEqual(len(pills), 1)

    def test_buying_asks_before_claude_ai_opens(self):
        opened = self.work / 'opened'
        opener = self.work / 'opener.sh'
        opener.write_text(f'#!/bin/sh\necho "$1" >> {opened}\n', encoding='utf-8')
        opener.chmod(0o755)
        self.ask('dialog-overage disabled', env={'RHUN_OPEN_URL': str(opener)})
        self.command('agent-card 2')
        self.assertEqual(self.answered(1), {'behavior': 'completed', 'result': 'consent'})
        self.command('wait 50')
        palette = self.command('print-palette').splitlines()
        self.assertEqual(palette[0], 'choose=Claude Code wants to open claude.ai in your browser: '
                                     'https://claude.ai/settings/usage')
        self.command('key Escape')
        self.command('wait-agent ready')
        self.assertFalse(opened.exists())
        self.assertNotIn('pill Now using usage credits for Fable', self.command('print-agents'))

    def test_switch_to_the_default_model_clears_rhuns_choice(self):
        self.start()
        self.command('agent-timing card=0')
        self.command('agent-cfg-set model sonnet')
        self.chat('hello')
        self.assertIn('--model=sonnet', self.starts()[-1]['argv'])
        self.dialog('dialog-overage consent')
        self.command('agent-card 1')
        self.assertEqual(self.answered(1), {'behavior': 'completed', 'result': 'switch_default'})
        self.command('wait-agent ready')
        self.assertIn('project model=- ', self.command('print-agent-cfg'))     # rhun's own choice, cleared
        subtypes = [m['request']['subtype'] for m in self.stdin() if m.get('type') == 'control_request']
        self.assertEqual(subtypes[-1], 'get_settings')       # what is in effect now: the pill follows it
        self.assertNotIn('update_settings', subtypes)        # Claude Code's own settings are never asked to change
        self.until(lambda: ' model=claude-opus-5-5 ' in self.command('print-agent-live'), 'the default model')
        self.chat('again')                                   # a new conversation starts without --model
        self.assertEqual([a for a in self.starts()[-1]['argv'] if a.startswith('--model')], [])

    def test_unknown_dialog_kind_gets_an_error_reply(self):
        self.start()
        self.chat('dialog-other')
        self.assertEqual(self.answers(), [{'behavior': 'error', 'message': 'not supported by rhun yet'}])
        self.assertEqual(self.thread(), ['user dialog-other', chat.REPLY + 'done'])
        self.assertEqual(self.card(), (None, []))
        # a payload the extension's reader refuses is dismissed at once, as its card does: no card shows
        self.command('agent-prompt dialog-overage bad')
        self.assertEqual(self.answered(2), {'behavior': 'cancelled'})
        self.command('wait-agent ready')
        self.assertEqual(self.card(), (None, []))

    def test_close_sends_cancelled(self):
        self.ask('dialog-overage consent')
        self.assertEqual(self.card()[1][-1], 'close')
        self.command('agent-card close')                     # the ×: the user dismissed it
        self.assertEqual(self.answered(1), {'behavior': 'cancelled'})
        self.command('wait-agent ready')
        self.dialog('dialog-overage consent')
        self.keys('Escape')                                  # Escape is the ×
        self.assertEqual(self.answered(2), {'behavior': 'cancelled'})

    def test_dialog_buttons_locked(self):
        self.ask('dialog-overage consent', lock=1500)
        self.assertEqual(self.head()['live'], '0')
        self.command('agent-card close')
        self.keys('2', 'Escape', 'Return')
        time.sleep(0.2)
        self.assertEqual(self.answers(), [])
        self.until(lambda: self.head()['live'] == '1', 'the lock ends')
        self.keys('2')
        self.assertEqual(self.answered(1), {'behavior': 'completed', 'result': 'consent'})
        self.command('wait-agent ready')
        self.command('agent-prompt dialog-auto')
        self.command('wait-agent waiting')
        self.assertEqual(self.head()['live'], '0')
        self.command('agent-card 1')                         # headless: once the lock is over, as a click then
        self.assertEqual(self.answered(2), {'behavior': 'completed', 'result': 'continue'})

    def test_learn_more_asks_before_opening(self):
        opened = self.work / 'opened'
        opener = self.work / 'opener.sh'
        opener.write_text(f'#!/bin/sh\necho "$1" >> {opened}\n', encoding='utf-8')
        opener.chmod(0o755)
        self.ask('dialog-overage consent', env={'RHUN_OPEN_URL': str(opener)})
        self.command('agent-card link')                      # a click on "Learn more"
        self.command('wait 50')
        palette = self.command('print-palette').splitlines()
        self.assertEqual(palette[0], 'choose=Claude Code wants to open support.claude.com in your browser: ' + LEARN)
        self.command('key Escape')
        self.command('wait 200')
        self.assertFalse(opened.exists())                    # nothing opens without Open
        self.assertEqual(self.answers(), [])                 # and the card still waits
        self.assertEqual(self.head()['kind'], 'dialog')
        self.command('agent-focus panel')
        self.keys('Up')                                      # the keyboard reaches it too: Up from the first button
        self.assertEqual(self.head()['focus'], 'link')
        self.keys('Return')
        self.command('wait 50')
        self.assertEqual(self.command('print-palette').splitlines()[0],
                         'choose=Claude Code wants to open support.claude.com in your browser: ' + LEARN)
        self.command('key Return')                           # Open
        self.until(lambda: opened.exists() and opened.read_text(encoding='utf-8').strip() == LEARN, 'the page opened')
        self.assertEqual(self.answers(), [])

    def test_dialog_card_fits(self):
        for prompt, close in (('dialog-overage plan', 1), ('dialog-auto', 0)):
            self.ask(prompt)
            buttons = len(self.buttons())
            for line in self.command('print-agent-card-fit').splitlines():
                size, width, h = map(int, re.match(r'size=(\d+) w=(\d+) h=(\d+) ', line).groups())
                fx, fy, fw, fh = map(int, re.search(r' frame=([\d,]+)', line).group(1).split(','))
                items = [(m.group(1), int(m.group(2) or 0), *map(int, m.group(3).split(',')))
                         for m in re.finditer(r'([a-zA-Z])(\d*):([\d,]+);', line)]
                what = f'{prompt} size {size} width {width}'
                for kind, n, x, y, w, ih in items:
                    self.assertTrue(fx <= x and x + w <= fx + fw and fy <= y and y + ih <= fy + fh,
                                    (what, kind, n, x, y, w, ih))
                    self.assertGreaterEqual(w, 8, (what, kind, n))
                boxes = [i for i in items if i[0] not in 'lt']
                for i, a in enumerate(boxes):
                    for b in boxes[i + 1:]:
                        apart = (a[2] + a[4] <= b[2] or b[2] + b[4] <= a[2] or a[3] + a[5] <= b[3] or
                                 b[3] + b[5] <= a[3])
                        self.assertTrue(apart, (what, a, b))
                for kind, n, x, y, w, ih in items:
                    if kind == 'l':
                        box = next(i for i in items if i[0] == 'b' and i[1] == n)
                        self.assertTrue(box[2] <= x and x + w <= box[2] + box[4] and
                                        box[3] <= y and y + ih <= box[3] + box[5], (what, kind, n))
                kinds = [i[0] for i in items]
                self.assertEqual((kinds.count('b'), kinds.count('x'), kinds.count('f'), kinds.count('L')),
                                 (buttons, close, 1 - close, 1), what)
            self.command('agent-card close' if close else 'agent-card 1')
            self.until_answered()
            self.stop()
        # the largest text in the narrowest panel: the card scrolls, the keys keep the focused control in view
        self.ask('dialog-overage plan', extra='[agents]\nfont_size = 32\n[ui]\nagents_width = 240\n')
        for key in ('Up', 'Up', 'Down', 'Down'):
            self.keys(key)
            head = self.head()
            scroll, room, fy, fh = (int(head[k]) for k in ('scroll', 'room', 'fy', 'fh'))
            if fh <= room:
                self.assertTrue(scroll <= fy and fy + fh <= scroll + room, head)
        self.command('agent-card close')
        self.until_answered()


# ---- the phase 2 reviews' findings, interface side (notes/claude-chat-phase2-review-findings.md) ----
SIZED = '[agents]\nfont_size = 13\n[ui]\nagents_width = 380\n'


class ReviewCardsTest(CardCase):
    """The review findings S1, S3, S4, S5a, S5d, A1, A2, A5, A6, A10 (cards, plan tabs, dialogs). Nothing here
    saves a rule: every answer is a Yes without a rule, a No, a question's answer or a dialog's."""

    def fit_items(self, size, width):
        """print-agent-card-fit's items at that size and width: (kind, n, x, y, w, h)."""
        line = next(l for l in self.command('print-agent-card-fit').splitlines()
                    if l.startswith(f'size={size} w={width} '))
        return [(m.group(1), int(m.group(2) or 0), *map(int, m.group(3).split(',')))
                for m in re.finditer(r'([a-zA-Z])(\d*):([\d,]+);', line)]

    def click_item(self, kind, n=0):
        """A click in the middle of the card's item (as drawn last: at the panel's size 13 and width 380)."""
        self.command('wait 50')
        ax, ay = map(int, self.head()['at'].split(','))
        _, _, x, y, w, h = next(i for i in self.fit_items(13, 380) if i[0] == kind and i[1] == n)
        self.command(f'click {ax + x + w // 2} {ay + y + h // 2}')

    def copy(self, text):
        """text in the clipboard: typed in a new file, copied, the file closed unsaved."""
        self.command('key ' + chat.MOD + '+n')
        self.command('type ' + text)
        self.command('key ' + chat.MOD + '+a')
        self.command('key ' + chat.MOD + '+c')
        self.command('key ' + chat.MOD + '+w')
        self.command('key Escape')

    def test_a_click_answers_a_card_while_the_box_has_text(self):
        """S1: a click on a card's button answers inside the drawing; the line "Waiting for…" under it, drawn
        while the box has text, must not read the card the answer freed."""
        for prompt, kind, n, claude in (('tool', 'b', 3, None), ('ask3', 'x', 0, None),
                                        ('plan', 'b', 3, self.claude_section('initial_mode = plan\n')),
                                        ('dialog-auto', 'b', 1, None)):
            self.ask(prompt, claude=claude, extra=SIZED)
            self.command('agent-focus box')
            self.command('agent-type hi')
            self.assertTrue(self.lines('waiting'), prompt)
            self.click_item(kind, n)
            self.until_answered()
            self.assertEqual(self.card(), (None, []), prompt)
            self.assertTrue(self.command('print-agent-input').startswith('input=hi '), prompt)
            self.stop()
            self.fake_log.unlink()

    def test_a_card_without_room_takes_no_keys(self):
        """S5a: a window so short that the bottom area has no room for the card: it is not drawn, and the keys
        do not answer it; with room again they do."""
        self.ask('tool')
        self.command('agent-focus panel')
        self.assertEqual(self.head()['keys'], '1')
        self.command('resize 1280 150')
        self.command('wait 100')
        self.assertEqual(self.head()['keys'], '0')
        self.keys('3', 'Return')                    # (Escape is the panel's: Stop while the turn waits)
        time.sleep(0.3)
        self.assertEqual(self.answers(), [])
        self.assertIn(' requests=1 ', self.live())
        self.command('resize 1280 800')
        self.command('wait 100')
        self.command('agent-focus panel')
        self.assertEqual(self.head()['keys'], '1')
        self.keys('3')
        self.assertEqual(self.until_answered()[0]['behavior'], 'deny')

    def test_escape_leaves_a_dialog_without_a_close_button_unanswered(self):
        """A2: the auto-mode card has no ×: Escape is not its last button (Stop); it does what Escape does in the
        panel without a card (here, with the turn running: Stop, which withdraws the dialog unanswered)."""
        self.ask('dialog-auto')
        self.assertEqual(self.head()['keys'], '1')
        self.keys('Escape')
        self.until(lambda: self.card() == (None, []), 'the dialog withdrawn')
        self.until(lambda: {'subtype': 'interrupt'} in [m.get('request') for m in self.control()], 'Stop')
        time.sleep(0.3)
        self.assertEqual(self.answers(), [])
        self.assertEqual([m for m in self.control() if m.get('type') == 'control_response'
                          and m['response'].get('response', {}).get('behavior') == 'completed'], [])

    def test_a_tab_chosen_during_the_advance_stays(self):
        """A6: a single choice arms the move to the next question; a tab chosen within the 300 ms is not undone
        when they pass."""
        self.ask('ask3')
        self.command('agent-timing advance=300')
        self.command('agent-card 1')                # Sidebar: the move to Checks is armed
        self.keys('Right', 'Right')                 # Size, at once
        time.sleep(0.6)
        tabs = [re.match(r'\d+ (.*) answered=\d current=(\d)$', l).groups() for l in self.lines('tab')]
        self.assertEqual([h for h, cur in tabs if cur == '1'], ['Size'])
        self.command('agent-card close')
        self.until_answered()

    def test_the_thumb_stays_in_a_short_room(self):
        """A1: at font 32 in a short window the card's room is less than the thumb's minimum: the thumb stays in
        the room, scrolled to the end or not."""
        self.ask('mixed', extra='[agents]\nfont_size = 32\n[ui]\nagents_width = 240\n')
        self.command('agent-focus panel')
        short = 0
        for height in range(640, 380, -3):
            self.command(f'resize 1280 {height}')
            self.keys('4')                          # the field: the card scrolls to its end
            self.command('wait 30')
            head = self.head()
            if head['keys'] == '0':                 # no room at all: not drawn
                continue
            room, scroll = int(head['room']), int(head['scroll'])
            ty, th = map(int, head['thumb'].split(','))
            self.assertTrue(th > 0 and 0 <= ty and ty + th <= room, (height, head))
            if room < 39 and scroll:                # less than the thumb's minimum (MI_16 at size 32)
                short += 1
        self.assertGreater(short, 0)
        self.command('resize 1280 800')
        self.command('agent-card 3')
        self.until_answered()

    def test_a_card_too_big_for_its_items_keeps_its_buttons(self):
        """A10: at 240 px and font 32 a card with many lines (the Details open, long labels, many paragraphs)
        and a question card with the most questions and options: every button, field and row is laid out."""
        self.ask('bigcard')
        self.command('agent-card details')
        items = self.fit_items(32, 240)
        kinds = [i[0] for i in items]
        self.assertGreater(len(items), 200)
        self.assertEqual(sorted({i[1] for i in items if i[0] == 'b'}), [1, 2, 3])
        self.assertEqual(kinds.count('F'), 1)
        self.assertEqual(kinds[-1], 't')            # "Esc to cancel", the last
        self.command('agent-card 3')
        self.until_answered()
        self.command('wait-agent ready')
        self.command('agent-prompt askmax')
        self.command('wait-agent waiting')
        kinds = [i[0] for i in self.fit_items(32, 240)]        # (about 150 items: under the old cap too)
        self.assertEqual((kinds.count('T'), kinds.count('o'), kinds.count('b')), (16, 17, 1))
        self.command('agent-card close')
        self.until_answered(2)

    def plan_tab_x(self, n):
        """The middle of the strip's tab n (from 0), as print-tabs-at puts it."""
        return self.command('print-tabs-at').split()[n].split(',')

    def test_the_tab_menu_acts_on_the_tab_it_was_opened_for(self):
        """S3: two plan tabs (TAB_MDDOC, no document): the menu of the second pins and closes the second."""
        claude = self.claude_section('initial_mode = plan\n')
        self.ask('plan', claude=claude)
        self.command('agent-new claude')
        self.command('agent-prompt plan')
        self.command('wait-agent waiting')
        self.until(lambda: len(PlanTest.tabs(self)) == 2, 'two plan tabs')
        self.assertEqual(self.command('print-tabs').strip(), 'tabs=Plan | *Plan')
        x, y = self.plan_tab_x(1)
        self.command(f'click {x} {y} right')
        self.command('menu-pick Pin Tab')
        self.assertEqual(self.command('print-tabs').strip(), 'tabs=^*Plan | Plan')
        x, y = self.plan_tab_x(0)
        self.command(f'click {x} {y} right')
        self.command('menu-pick Unpin Tab')
        self.assertEqual(self.command('print-tabs').strip(), 'tabs=*Plan | Plan')
        # Close Tab on the second conversation's tab (first since its pin): it goes, the first's stays
        x, y = self.plan_tab_x(0)
        self.command(f'click {x} {y} right')
        self.command('menu-pick Close Tab')
        self.assertEqual(len(PlanTest.tabs(self)), 1)
        self.command('agent-card 3')                # the open (second) conversation's No: no tab of its left
        self.until_answered()
        time.sleep(0.2)
        self.assertEqual(len(PlanTest.tabs(self)), 1)

    def test_the_seventeenth_comment_keeps_its_selection(self):
        """S4: a plan takes 16 comments; the 17th is refused with a notice and its text stays selected."""
        self.ask('plan', claude=self.claude_section('initial_mode = plan\n'))
        for i in range(16):
            PlanTest.comment(self, 'Add the', f'comment {i + 1}')
        self.assertEqual(len(self.lines('comment')), 16)
        self.command('mdtab-select Test it')
        self.command('mdtab-comment one too many')
        self.assertEqual(len(self.lines('comment')), 16)
        self.assertEqual(PlanTest.tabs(self)[0]['selected'], 'Test it')
        self.assertEqual(self.command('print-toast').strip(), 'toast=A plan takes 16 comments')
        self.command('agent-card 1')
        self.until_answered()

    def test_a_plan_open_tab_lets_enter_through(self):
        """S5d: a tab /plan open opened takes no comments: Ctrl+Enter, and Enter without a link, go on to the
        keys' bindings."""
        self.ask('plan', claude=self.claude_section('initial_mode = plan\n'),
                 extra='[keys]\nctrl+Enter = rhun.toggle_sidebar\nEnter = rhun.toggle_sidebar\n')
        self.command('agent-card-text field later')
        self.command('agent-card 3')
        self.command('wait-agent ready')
        self.command('agent-prompt /plan open')
        self.until(lambda: PlanTest.tabs(self), 'the plan in a tab')
        self.command('agent-focus editor')
        self.assertIn('explorer=0', self.command('print-panels'))
        self.keys('ctrl+Return')
        self.assertIn('explorer=1', self.command('print-panels'))
        self.keys('Return')
        self.assertIn('explorer=0', self.command('print-panels'))

    def test_paste_reaches_a_cards_fields(self):
        """A5: Ctrl/Cmd+V in the reject field, the editable command, a question's Other and the plan's field,
        cleaned as the box cleans a paste; characters an input method commits reach them too."""
        self.ask('tool')
        self.copy('x​y')
        self.command('agent-focus panel')
        self.keys('4')                              # the reject field
        self.assertEqual(self.head()['focus'], 'field')
        self.keys(chat.MOD + '+v')
        self.command('type é✓한')
        self.assertEqual(self.lines('field'), ['xyé✓한'])
        self.keys('Up', 'Up', 'Up', 'Up')           # No, Yes with the rule, Yes, the command
        self.assertEqual(self.head()['focus'], 'edit')
        self.keys('End', chat.MOD + '+v')
        self.assertEqual(self.lines('edit'), ['touch approved.txtxy'])
        self.command('agent-card 3')
        self.until_answered()
        self.command('wait-agent ready')
        self.command('agent-prompt ask3')
        self.command('wait-agent waiting')
        self.command('agent-focus panel')
        self.command('agent-card 4')                # Other: its field has the keys
        self.keys(chat.MOD + '+v')
        self.assertEqual(self.lines('other'), ['xy'])
        self.command('agent-card close')
        self.until_answered(2)
        self.stop()
        self.ask('plan', claude=self.claude_section('initial_mode = plan\n'))
        self.copy('more⁠ tests')
        self.command('agent-focus panel')
        self.keys('4')
        self.keys(chat.MOD + '+v')
        self.assertEqual(self.lines('field'), ['more tests'])
        self.command('agent-card 3')
        self.until_answered()


class ReviewRulesTest(CardCase):
    """The protocol review's findings on the permission card's rules (P5) and on the CLI's requests
    (2026-11-23). The fake's scenarios `rules`, `planagain` and `manydialog`, its auto dialog variant
    `percent` and its knob FAKE_CLAUDE_MODE_MS have no recording behind them. Rules go to localSettings
    inside the test's project only."""

    def test_a_suggestion_past_the_cap_is_not_sent(self):
        # a suggestion whose rules the card cannot all show is dropped whole; the count is the shown one
        self.ask('rules 70 allow allow')
        self.assertEqual(self.buttons()[1], f'Yes, allow echo second for [{LOCAL}]')
        self.assertEqual(self.lines('extra'), [])
        self.command('agent-card 2')
        self.assertEqual(self.until_answered()[0]['updatedPermissions'], [
            {'type': 'addRules', 'rules': [{'toolName': 'Bash', 'ruleContent': 'echo second'}], 'behavior': 'allow',
             'destination': 'localSettings'}])
        self.command('wait-agent ready')
        self.command('agent-prompt rules 64')            # 64: every one shown, every one sent
        self.command('wait-agent waiting')
        self.assertEqual(self.buttons()[1], f'Yes, allow echo r1 and 63 more for [{LOCAL}]')
        self.assertEqual(len(self.lines('extra')), 63)
        self.command('agent-card 2')
        self.assertEqual(len(self.until_answered(2)[1]['updatedPermissions'][0]['rules']), 64)
        self.command('wait-agent ready')
        self.command('agent-prompt dirs 70')              # directories past the cap: the same
        self.command('wait-agent waiting')
        self.assertEqual(self.buttons(), ['Yes', 'No'])
        self.command('agent-card 2')
        self.until_answered(3)

    def test_rules_say_what_they_do(self):
        # a rule that denies or asks never reads "Yes, allow"
        self.ask('rules 1 deny')
        self.assertEqual(self.buttons()[1], f'Yes, and deny echo r1 for [{LOCAL}]')
        self.command('agent-card 3')
        self.command('wait-agent ready')
        self.command('agent-prompt rules 2 ask')
        self.command('wait-agent waiting')
        self.assertEqual(self.buttons()[1], f'Yes, and ask before echo r1 and echo r2 for [{LOCAL}]')
        self.command('agent-card 3')
        self.command('wait-agent ready')
        self.command('agent-prompt rules 1 allow deny')   # two rules that do different things: each in its words
        self.command('wait-agent waiting')
        self.assertEqual(self.buttons()[1], f'Yes, allow echo r1 and 1 more for [{LOCAL}]')
        self.assertEqual(self.lines('extra'), ['Also denies Bash(echo second)'])
        self.command('agent-card 2')
        sent = self.until_answered(3)[2]['updatedPermissions']
        self.assertEqual([(u['behavior'], u['destination']) for u in sent], [('allow', 'localSettings'),
                                                                              ('deny', 'localSettings')])

    def test_a_late_mode_answer_releases_no_other_plan(self):
        # 3.4: plan 1's "Yes, and use auto mode" waits for its set_permission_mode answer; plan 1 is withdrawn
        # and plan 2 answered the same way before that answer comes: only plan 2's own answer releases it
        self.ask('planagain 700', env={'FAKE_CLAUDE_MODELS': 'auto', 'FAKE_CLAUDE_MODE_MS': '2000'})
        self.assertEqual(self.buttons()[0], 'Yes, and use auto mode')
        self.command('agent-card 1')
        time.sleep(1.2)                                   # plan 1 withdrawn, plan 2 shown
        self.assertEqual(self.head()['kind'], 'plan')
        self.command('agent-card 1')
        self.command('wait-agent ready 10000')
        self.until(lambda: len([r for r in self.records() if 'mode_answer' in r]) == 2, 'both answers')
        records = self.records()
        modes = [json.loads(r['stdin'])['request_id'] for r in records
                 if 'stdin' in r and '"set_permission_mode"' in r['stdin']]
        self.assertEqual(len(modes), 2, modes)
        answered = next(i for i, r in enumerate(records) if r.get('mode_answer') == modes[1])
        allow = next(i for i, r in enumerate(records) if 'stdin' in r and '"control_response"' in r['stdin']
                     and '"allow"' in r['stdin'])
        self.assertGreater(allow, answered)
        self.assertEqual([(a['plan'], a['behavior']) for a in self.answers()], [(2, 'allow')])

    def test_a_dialog_past_the_limit_is_told_rhun_is_busy(self):
        # Smaller: a dialog of a declared kind while AQ_MAX requests wait gets the busy error, not "not supported"
        self.ask('manydialog')
        error = self.until(lambda: [a for a in self.answers() if a.get('behavior') == 'error'], 'the error')[0]
        self.assertEqual(error['message'], 'too many requests are waiting in rhun')
        self.command('agent-stop')
        self.command('wait-agent ready 10000')

    def test_plan_without_a_process_starts_it_and_shows_the_plan(self):
        # /plan in plan mode after the idle stop: the program starts again (nothing is sent) and the plan the
        # conversation has shows in a tab, as with a running program (the extension always has one)
        self.ask('plan', claude=self.claude_section('initial_mode = plan\n'))
        self.command('agent-card-text field later')
        self.command('agent-card 3')                    # keeps planning, in plan mode
        self.command('wait-agent ready')
        self.command('agent-release')
        self.until(lambda: ' pid=1 ' not in self.live(), 'its end')
        self.command('agent-prompt /plan')
        self.until(lambda: PlanTest.tabs(self), 'the plan in a tab')
        self.assertEqual(PlanTest.tabs(self)[0]['text'], PLAN.split('\n'))
        self.assertEqual(len(self.starts()), 2)
        self.assertEqual(self.prompts(), ['plan'])
        self.assertNotIn('info Already in plan mode. No plan written yet.', self.thread())

    def test_a_help_url_with_a_percent_escape_is_not_shown(self):
        # Smaller: help_url_ok refuses a percent-escape in the host
        self.ask('dialog-auto percent')
        self.assertEqual(self.card()[1], ['detail A paragraph.', 'button 1 Continue', 'button 2 Stop'])
        self.keys('2')
        self.until_answered()


if __name__ == '__main__':
    unittest.main()
