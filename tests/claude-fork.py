#!/usr/bin/env python3
"""Phase 6 of the Claude chat, its second part (claude-chat-p6b): fork a conversation from one of its prompts,
rewind its code to a prompt (the picker, the dialog's dry run and its three choices, a prompt's context menu),
export it (the dialog, /export NAME), and a turn cut off by quitting that goes on after a restart. Against the
fake CLI (tests/scripts/fake-claude.py), over the control socket; it imports tests/claude-chat.py for its cases
(every rhun gets its own HOME and XDG folders, an environment without CLAUDE* or ANTHROPIC* variables)."""
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


class ForkCase(chat.DrivenCase):
    def setUp(self):
        super().setUp()
        self.env['FAKE_CLAUDE_ECHO_ENV'] = ('CLAUDE_CODE_RESUME_INTERRUPTED_TURN,CLAUDE_CODE_RESUME_INTERRUPTED_TURN_MAX_AGE_MS,'
                                            'CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING')

    def head(self):
        first = self.command('print-agent-dialog').splitlines()[0]
        return dict(re.findall(r'(\w+)=(.*?)(?= \w+=|$)', first))

    def body(self):
        return [line for line in self.command('print-agent-dialog').splitlines()[1:] if not line.startswith('box ')]

    def until_state(self, state, seconds=10):
        return self.until(lambda: self.head().get('state') == state and self.head(), 'state ' + state, seconds)

    def folder(self):
        return self.work / '.claude/projects' / chat.slug(self.project)

    def lines(self, sid):
        path = self.folder() / (sid + '.jsonl')
        return [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines() if line.strip()]

    def prompt_lines(self, sid):
        return [r for r in self.lines(sid) if r.get('type') == 'user' and isinstance(r['message']['content'], list)
                and r['message']['content'][0].get('type') == 'text']

    def fork_info(self):
        return self.command('print-agent-fork').splitlines()

    def say(self, *prompts):
        """A new conversation with these prompts, each waited for; its id."""
        self.command('cmd focus_agents')
        self.command('agent-new claude')
        for prompt in prompts:
            self.command('agent-prompt ' + prompt)
            self.command('wait-agent ready')
        return self.sid()

    def rows(self):
        return self.thread()

    def row_of(self, text):
        """The index (print-agent-rows') of the prompt row with that text."""
        for i, line in enumerate(self.thread()):
            if line == 'user ' + text:
                return i
        self.fail('no prompt %r in %r' % (text, self.thread()))

    def box(self):
        out = self.command('print-agent-input')
        return re.match(r'input=(.*?) (?:\w+=|$)', out).group(1)


class MenuTest(ForkCase):
    def test_the_menu_and_the_commands(self):
        self.start()
        self.say('hello')
        self.command('agent-menu')
        menu = self.command('print-agent-menu')
        self.assertIn('Rewind', menu)
        self.assertIn('Restore code and conversation to an earlier point', menu)
        self.assertIn('Export conversation', menu)
        self.assertIn('Copy the conversation as plain text or save it to a file', menu)
        self.command('key Escape')
        self.command('agent-menu /exp')
        menu = self.command('print-agent-menu')
        self.assertIn('/export', menu)
        self.command('key Escape')




class RewindTest(ForkCase):
    """The picker (5.18), the Rewind dialog with its dry run and three choices (5.19), Restore."""

    def written(self):
        self.start(self.claude_section('initial_mode = acceptEdits\n'))
        sid = self.say('write a.txt one', 'write a.txt two')
        self.assertEqual((self.project / 'a.txt').read_text(), 'two')
        return sid

    def test_the_picker_lists_the_prompts_newest_first(self):
        self.written()
        self.command('agent-prompt /rewind')
        self.assertEqual(self.head()['dialog'], 'rewind')
        self.assertEqual(self.head()['title'], 'Rewind to\u2026')
        self.assertEqual(self.body(), [
            'text Select a message to restore the code and/or conversation from that point.',
            'item[1] write a.txt two\t\tjust now', 'item[2] write a.txt one\t\tjust now',
            'text \u2191 \u2193 to navigate \u00b7 Enter to select \u00b7 Esc to close'])
        self.command('key Escape')
        self.assertEqual(self.command('print-agent-dialog'), 'dialog=none\n')

    def test_an_empty_conversation_has_nothing_to_rewind(self):
        self.start()
        self.command('agent-new claude')
        self.command('agent-menu Rewind')          # (a first draft knows no commands yet: the menu's entry)
        self.command('agent-menu-pick 1')
        self.assertEqual(self.body(), ['text No messages to rewind to yet.'])
        self.assertEqual(self.starts(), [])         # nothing started for it

    def test_the_dry_run_and_restore_code(self):
        sid = self.written()
        second = self.prompt_lines(sid)[1]['uuid']
        self.command('agent-prompt /undo')
        self.command('agent-dialog-pick 1')
        self.until(lambda: 'text a.txt' in self.body(), 'the dry run')
        self.assertEqual(self.head()['title'], 'Rewind')
        self.assertEqual(self.body(), [
            'item[1] Restore code and conversation\tThe conversation will be forked.\t check',
            'item[2] Restore conversation\tThe conversation will be forked. The code will be unchanged.\t',
            'item[3] Restore code\tThe conversation will be unchanged.\t',
            'text 1 line will be removed and 1 line will be added across 1 file:', 'text a.txt',
            'text Restored files go back whole, losing later changes by anyone. Bash changes to other files are not '
            'undone.', 'button 1 Restore primary', 'button 2 Never mind'])
        checks = [m['request'] for m in self.stdin() if m.get('type') == 'control_request'
                  and m['request'].get('subtype') == 'rewind_files']
        self.assertEqual(checks, [{'subtype': 'rewind_files', 'user_message_id': second, 'dry_run': True}])
        self.command('agent-dialog-pick 2')      # Restore conversation: no code summary
        self.assertNotIn('text a.txt', self.body())
        self.command('agent-dialog-pick 3')      # Restore code
        self.assertIn('item[3] Restore code\tThe conversation will be unchanged.\t check', self.body())
        self.command('agent-dialog-press 1')
        self.until(lambda: (self.project / 'a.txt').read_text() == 'one', 'the file restored')
        self.until(lambda: 'meta Code rewind successful' in self.thread(), 'the meta row')
        self.assertEqual(self.command('print-agent-dialog'), 'dialog=none\n')
        self.assertEqual(self.sid(), sid)           # the conversation is the same one
        rewinds = [m['request'] for m in self.stdin() if m.get('type') == 'control_request'
                   and m['request'].get('subtype') == 'rewind_files']
        self.assertEqual(rewinds[-1], {'subtype': 'rewind_files', 'user_message_id': second})

    def test_never_mind_goes_back_to_the_list(self):
        self.written()
        self.command('agent-prompt /rewind')
        self.command('agent-dialog-pick 2')
        self.until(lambda: 'text 1 line will be removed and 0 lines will be added across 1 file:' in self.body(),
                   'the dry run')
        self.command('agent-dialog-press 2')
        self.assertEqual(self.head()['title'], 'Rewind to\u2026')
        self.assertIn('item[2] write a.txt one\t\tjust now', self.body())

    def test_unchanged_code_offers_the_conversation_only(self):
        self.start(self.claude_section('initial_mode = acceptEdits\n'))
        self.say('hello', 'again')
        self.command('agent-prompt /rewind')
        self.command('agent-dialog-pick 1')
        self.until(lambda: 'button 1 Restore primary' in self.body() and 'Checking' not in ' '.join(self.body()), 'the dialog')
        self.assertEqual(self.body(), [
            'item[1] Restore conversation\tThe conversation will be forked. The code will be unchanged.\t check',
            'button 1 Restore primary', 'button 2 Never mind'])

    def test_restore_code_and_conversation_forks_after_the_rewind(self):
        sid = self.written()
        parent = self.prompt_lines(sid)[1]['parentUuid']
        self.command('agent-prompt /rewind')
        self.command('agent-dialog-pick 1')
        self.until(lambda: 'button 1 Restore primary' in self.body() and 'Checking' not in ' '.join(self.body()), 'the dialog')
        self.command('agent-dialog-press 1')
        self.until(lambda: self.sid() != sid, 'the fork')
        self.assertEqual((self.project / 'a.txt').read_text(), 'one')
        self.assertEqual(self.fork_info()[0], 'fork=%s at=%s rerun=0' % (sid, parent))
        self.assertEqual(self.box(), 'write a.txt two')
        self.assertEqual(self.thread(), ['user write a.txt one', 'tool(Write) a.txt', chat.REPLY + 'written'])


class ForkTest(ForkCase):
    """Fork conversation from here (3.5, 5.17)."""

    def test_fork_from_a_prompt(self):
        self.start()
        sid = self.say('one', 'two', 'three')
        lines = self.prompt_lines(sid)
        parent = lines[1]['parentUuid']
        self.command('agent-msg-action %d fork' % self.row_of('two'))
        new = self.sid()
        self.assertNotEqual(new, sid)
        self.assertEqual(self.thread(), ['user one', chat.REPLY + 'ok: one'])
        self.assertEqual(self.box(), 'two')
        self.assertEqual(self.fork_info()[0], 'fork=%s at=%s rerun=0' % (sid, parent))
        self.assertIn(' (fork)', self.command('print-agents'))
        self.command('agent-prompt two again')
        self.command('wait-agent ready')
        argv = self.starts()[-1]['argv']
        self.assertEqual(argv, chat.PINNED + ['--resume=' + sid, '--fork-session', '--session-id=' + new,
                                              '--resume-session-at=' + parent])
        texts = [r['message']['content'][0].get('text') for r in self.lines(new) if r.get('type') in
                 ('user', 'assistant')]
        self.assertEqual(texts, ['one', 'ok: one', 'two again', 'ok: two again'])
        self.assertEqual(self.thread()[:3], ['user one', chat.REPLY + 'ok: one', 'user two again'])
        self.assertRegex(self.thread()[3], r'^agent(\(\S+\))? ok: two again$')

    def test_fork_from_the_first_prompt_is_a_new_conversation(self):
        self.start()
        sid = self.say('one', 'two')
        self.command('agent-msg-action 0 fork')
        self.assertNotEqual(self.sid(), sid)
        self.assertEqual(self.thread(), [])
        self.assertEqual(self.box(), 'one')
        self.assertEqual(self.fork_info()[0], 'fork= at= rerun=0')
        self.command('agent-prompt one more')
        self.command('wait-agent ready')
        self.assertNotIn('--fork-session', self.starts()[-1]['argv'])

    def test_the_context_menu_of_a_prompt(self):
        self.start()
        self.say('one', 'two')
        self.assertEqual(self.reply('agent-msg-action 1 fork')[1], False)   # a reply has no such entry
        self.assertEqual(self.reply('agent-msg-action 2 rewind')[1], True)
        self.until(lambda: self.head().get('title') == 'Rewind code', 'the dialog')

    def test_a_left_fork_goes(self):
        self.start()
        self.say('one', 'two')
        before = self.command('print-agents').count('(fork)')
        self.command('agent-msg-action 2 fork')
        self.assertIn('(fork)', self.command('print-agents'))
        self.command('click %d %d' % chat.BACK)
        self.until(lambda: '(fork)' not in self.command('print-agents'), 'the fork gone')
        self.assertEqual(before, 0)


class MessageActionTest(ForkCase):
    """Rewind code to here and Fork conversation and rewind code from a prompt's menu (3.5, 5.19)."""

    def test_rewind_code_to_here(self):
        self.start(self.claude_section('initial_mode = acceptEdits\n'))
        sid = self.say('write a.txt one', 'write a.txt two')
        self.command('agent-msg-action %d rewind' % self.row_of('write a.txt two'))
        self.until(lambda: 'button 1 Rewind primary' in self.body(), 'the dialog')
        self.assertEqual(self.head()['title'], 'Rewind code')
        self.assertEqual(self.body()[:2], ['text 1 line will be removed and 1 line will be added across 1 file:',
                                           'text a.txt'])
        self.command('key 1')
        self.until(lambda: (self.project / 'a.txt').read_text() == 'one', 'the file restored')
        self.until(lambda: 'meta Code rewind successful' in self.thread(), 'the meta row')
        self.assertEqual(self.sid(), sid)

    def test_fork_and_rewind(self):
        self.start(self.claude_section('initial_mode = acceptEdits\n'))
        sid = self.say('write a.txt one', 'write a.txt two')
        self.command('agent-msg-action %d both' % self.row_of('write a.txt one'))
        self.until(lambda: 'button 1 Continue primary' in self.body(), 'the dialog')
        self.assertEqual(self.head()['title'], 'Fork and rewind')
        self.assertEqual(self.body()[0], 'text A new forked conversation will be created after rewinding.')
        self.command('agent-dialog-press 1')
        self.until(lambda: not (self.project / 'a.txt').exists(), 'the file gone (it did not exist then)')
        self.until(lambda: self.sid() != sid, 'the fork')
        self.assertEqual(self.thread(), [])
        self.assertEqual(self.box(), 'write a.txt one')

    def test_rewind_code_without_changes_cannot_go(self):
        self.start()
        self.say('one', 'two')
        self.command('agent-msg-action 2 rewind')
        self.until(lambda: 'button 1 Never mind' in self.body(), 'the dialog')
        self.assertEqual(self.body(), ['text The code has not changed, so no code will be restored.',
                                       'text Restored files go back whole, losing later changes by anyone. Bash '
                                       'changes to other files are not undone.', 'button 1 Never mind'])


class ExportTest(ForkCase):
    """Export conversation (5.20) and /export NAME."""

    def test_the_dialog(self):
        self.start()
        self.say('hello there')
        self.command('agent-prompt /export')
        self.until(lambda: 'button' in self.command('print-agent-dialog'), 'the export')
        self.assertEqual(self.head()['title'], 'Export conversation')
        body = self.body()
        self.assertEqual(body[0], 'text The whole conversation as plain text, 33 characters.')
        self.assertRegex(body[1], r'^text Save to file offers the name \d{4}-\d\d-\d\d-\d{6}-hello-there\.txt$')
        self.assertEqual(body[2:], ['button 1 Copy to clipboard primary', 'button 2 Save to file', 'button 3 Close'])
        self.command('agent-dialog-press 1')
        self.assertIn('text Copied to clipboard', self.body())
        self.command('agent-dialog-press 2')
        self.assertEqual(self.command('print-agent-dialog'), 'dialog=none\n')
        state = self.command('print-state')
        self.assertIn('hello-there.txt', state)

    def test_export_with_a_name_goes_to_the_editor(self):
        self.start()
        self.say('hello there')
        self.command('agent-prompt /export notes/talk')
        self.until(lambda: 'meta Conversation opened in the editor; choose where to save it' in self.thread(),
                   'the meta row')
        self.assertEqual(self.command('print-agent-dialog'), 'dialog=none\n')
        self.assertIn('talk.txt', self.command('print-state'))

    def test_a_failed_export(self):
        self.start(env={'FAKE_CLAUDE_EXPORT_FAIL': 'no export here'})
        self.say('hello')
        self.command('agent-prompt /export')
        self.until(lambda: self.head().get('state') == 'error', 'the error')
        self.assertIn('msg Could not prepare the conversation: no export here',
                      self.command('print-agent-dialog').splitlines())




class RestartTest(ForkCase):
    """A turn cut off by quitting goes on when its conversation opens again ([agents] continue_after_restart)."""

    BASE = chat.ChatCase.BASE.replace('restore_session = false', 'restore_session = true')

    def cut(self, extra=''):
        """A conversation whose second turn quitting cuts off (opened from the list: the one a restart opens)."""
        self.start(extra=extra)
        self.say('hello')
        self.quit()
        self.start(extra=extra)
        self.command('cmd focus_agents')
        self.command('wait-agents')
        self.command('agent-list open Untitled session')
        self.until(lambda: 'user hello' in self.thread(), 'the conversation')
        self.command('agent-prompt linger 30')
        self.command('wait-agent working')
        sid = self.sid()
        self.until(lambda: any(r['message']['content'][0].get('text') == 'linger 30' for r in self.prompt_lines(sid)),
                   'the prompt in the file')             # (the fake writes it as its turn starts)
        self.quit()
        return sid

    def cuts(self):
        files = list((self.work / 'state').rglob('*.agents-cut'))
        return files[0].read_text(encoding='utf-8').splitlines() if files else []

    def reruns(self):
        return [r for r in self.starts() if r['env'].get('CLAUDE_CODE_RESUME_INTERRUPTED_TURN') == '1']

    def test_the_restart_opens_it_and_the_turn_goes_on(self):
        sid = self.cut()
        self.assertEqual([line.split('\t')[0] + '\t' + line.split('\t')[2] for line in self.cuts()], [sid + '\t0'])
        self.start()
        self.command('cmd focus_agents')
        self.until(lambda: 'ok: linger 30' in ' '.join(self.thread()), 'the turn again', 20)
        self.assertEqual(self.thread(), ['user hello', chat.REPLY + 'ok: hello', 'user linger 30',
                                         'meta Continuing the step that was interrupted when rhun quit.',
                                         'agent ok: linger 30'])
        self.assertEqual(len(self.reruns()), 1)
        self.assertEqual(self.reruns()[0]['env'].get('CLAUDE_CODE_RESUME_INTERRUPTED_TURN_MAX_AGE_MS'), '3600000')
        self.assertEqual(self.reruns()[0]['argv'][-1], '--resume=' + sid)
        self.until(lambda: self.cuts() == [], 'the list emptied')
        self.command('wait-agent ready')
        self.assertEqual({r['env'].get('CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING') for r in self.starts()}, {'true'})
        self.assertTrue(self.live().startswith('state=ready '), self.live())

    def test_a_rerun_whose_program_dies_is_forgotten(self):
        """Review 2 finding 11: the re-run's program dies before its result: the record is no longer the re-run
        (a later start of it, or a record at its address, is not routed to the re-run's reading)."""
        self.cut()
        self.start(env={'FAKE_CLAUDE_RERUN_DIE': '1'})
        self.command('cmd focus_agents')
        self.until(lambda: len(self.reruns()) == 1, 'the re-run started', 20)
        self.until(lambda: re.search(r'^state=(failed|off) ', self.live()), 'its program gone', 20)
        self.assertTrue(self.fork_info()[0].endswith(' rerun=0'), self.fork_info())

    def test_switched_off_it_stays_cut(self):
        extra = '[agents]\ncontinue_after_restart = false\n'
        self.cut(extra)
        self.start(extra=extra)
        self.command('cmd focus_agents')
        self.until(lambda: 'user linger 30' in self.thread(), 'the conversation open')
        time.sleep(0.5)
        self.assertEqual(self.reruns(), [])
        self.assertTrue(self.live().startswith('state=off '), self.live())

    def edit_cut(self, n=None, age=None):
        files = list((self.work / 'state').rglob('*.agents-cut'))
        sid, when, runs = files[0].read_text(encoding='utf-8').split('\n')[0].split('\t')
        when = int(when) - (age or 0) * 1000
        files[0].write_text('%s\t%d\t%s\n' % (sid, when, runs if n is None else n), encoding='utf-8')

    def test_two_reruns_that_never_finished_are_the_last(self):
        self.cut()
        self.edit_cut(n=2)
        self.start()
        self.command('cmd focus_agents')
        self.until(lambda: 'user linger 30' in self.thread(), 'the conversation open')
        time.sleep(0.5)
        self.assertEqual(self.reruns(), [])
        self.assertEqual(self.cuts(), [])

    def test_an_hour_old_cut_is_left(self):
        self.cut()
        self.edit_cut(age=3601)
        self.start()
        self.command('cmd focus_agents')
        self.until(lambda: 'user linger 30' in self.thread(), 'the conversation open')
        time.sleep(0.5)
        self.assertEqual(self.reruns(), [])

    def test_a_turn_that_ended_is_not_noted(self):
        self.start()
        self.say('hello')
        self.quit()
        self.assertEqual(self.cuts(), [])




class KeysTest(ForkCase):
    """Escape twice on an empty box (1.9, 7.1) and a prompt's context menu (3.5)."""

    def test_escape_twice_on_an_empty_box_opens_rewind(self):
        self.start()
        self.say('one', 'two')
        self.command('agent-focus box')
        self.command('key Escape')
        self.command('key Escape')
        self.assertEqual(self.head()['title'], 'Rewind to\u2026')
        self.command('key Escape')                 # the dialog closes; the box has the keys again
        self.assertEqual(self.command('print-agent-dialog'), 'dialog=none\n')

    def test_escapes_too_far_apart_or_with_text_do_not(self):
        self.start()
        self.say('one')
        self.command('agent-focus box')
        self.command('key Escape')
        time.sleep(0.9)
        self.command('key Escape')
        self.assertEqual(self.command('print-agent-dialog'), 'dialog=none\n')
        self.command('agent-focus box')
        self.command('type x')
        self.command('key Escape')
        self.command('key Escape')
        self.assertEqual(self.command('print-agent-dialog'), 'dialog=none\n')

    def bubble(self, n):
        place = re.search(r' bubble=(\d+),(\d+),(\d+),(\d+)', self.command('print-agent-row %d' % n))
        x, y, w, h = map(int, place.groups())
        return x + w // 2, y + h // 2

    def test_the_context_menu_of_a_prompt(self):
        self.start()
        sid = self.say('one', 'two')
        self.command('click %d %d right' % self.bubble(3))
        self.command('wait 50')
        menu = self.command('print-menu')
        self.assertIn('Fork conversation from here', menu)
        self.assertIn('Rewind code to here', menu)
        self.assertIn('Fork conversation and rewind code', menu)
        self.command('menu-pick Fork conversation from here')
        self.until(lambda: self.sid() != sid, 'the fork')
        self.assertEqual(self.box(), 'two')

    def msgact(self):
        m = re.search(r'^msgact row=(\d+) (-?\d+),(-?\d+),(\d+),(\d+)$', self.command('print-agent-selection'), re.M)
        return tuple(map(int, m.groups())) if m else None

    def test_message_actions_on_a_hovered_prompt(self):
        """3.5: the pointer on a prompt shows the Message actions button left of its bubble; it opens a menu of the
        prompt's Fork and Rewind entries."""
        self.start()
        sid = self.say('one', 'two')
        self.assertIsNone(self.msgact())
        bx, by = self.bubble(3)
        self.command('move %d %d' % (bx, by))
        self.command('wait 50')
        row, x, y, w, h = self.msgact()
        self.assertEqual(row, 2)
        bubble = re.search(r' bubble=(\d+),', self.command('print-agent-row 3'))
        self.assertLessEqual(x + w, int(bubble.group(1)))
        self.command('move %d %d' % (x + w // 2, y + h // 2))
        self.command('wait 50')
        self.until(lambda: 'Message actions' in self.command('print-tip'), 'its tip')
        self.command('click %d %d' % (x + w // 2, y + h // 2))
        self.command('wait 50')
        menu = self.command('print-menu')
        self.assertIn('Fork conversation from here', menu)
        self.assertIn('Rewind code to here', menu)
        self.assertIn('Fork conversation and rewind code', menu)
        self.assertNotIn('Copy Message', menu)                     # the right click's menu has that
        self.command('menu-pick Fork conversation from here')
        self.until(lambda: self.sid() != sid, 'the fork')
        self.assertEqual(self.box(), 'two')

    def test_no_message_actions_on_a_reply(self):
        self.start()
        self.say('one')
        place = re.search(r' y=(\d+) ', self.command('print-agent-row 2'))
        self.command('move 1000 %d' % (int(place.group(1)) + 20))
        self.command('wait 50')
        self.assertIsNone(self.msgact())

    def test_a_reply_has_no_fork_entries(self):
        self.start()
        self.say('one')
        place = re.search(r' y=(\d+) ', self.command('print-agent-row 2'))
        self.command('click 1000 %d right' % (int(place.group(1)) + 20))
        self.command('wait 50')
        menu = self.command('print-menu')
        self.assertIn('Copy Message', menu)
        self.assertNotIn('Fork conversation from here', menu)


if __name__ == '__main__':
    unittest.main()
