#!/usr/bin/env python3
"""rhun's hooks for Claude Code's chat (phase 4 task 10), against the fake CLI (tests/scripts/fake-claude.py), over
the control socket, with tests/claude-mcp.py's cases (each rhun its own HOME and XDG folders, no CLAUDE* or
ANTHROPIC* variables; the fake's config folder is the test's HOME). HooksTest: saving before a read or an edit,
the problems that are new after an edit (the extension's areDiagnosticsEqual), the waits and their bounds, a
subagent's own base, the diagnostics row live and read again."""
import importlib.util
import json
import os
from pathlib import Path
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location('claude_mcp', ROOT / 'tests/claude-mcp.py')
mcp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mcp)
chat = mcp.chat
McpCase = mcp.McpCase

HOOKS = chat.HOOKS
CONTINUE = {'continue': True}
# areDiagnosticsEqual's table: made by the bundle's own findNewDiagnostics and areDiagnosticsEqual
# (extension.js of 2.1.328, the class hne at EXT@3183400, run under node on these pairs); each case is a
# base problem (line 2, columns 1 to 5, Warning, source lint, code c1, message "unused total", the file 6
# lines) and one problem after: old or new
EQUAL_TABLE = [('the same', 'old'), ('another start column', 'new'), ('another end column', 'new'),
               ('three lines lower, three lines added', 'old'), ('three lines lower, as many lines', 'new'),
               ('another source', 'new'), ('another code', 'new'), ('another severity', 'new'),
               ('a message that differs after byte 200', 'new')]
FORMATTER = """import sys
sys.stdout.reconfigure(encoding='utf-8', newline='\\n')
print('hello 1 format', flush=True)
for raw in sys.stdin.buffer:
    line = raw.decode(errors='replace')
    words = line.split()
    if len(words) > 4 and words[:2] == ['0', 'edits']:
        sys.stdin.buffer.read(int(words[4]))
    if line.startswith('0 bye'):
        break
"""


class HooksTest(McpCase):
    def hook_log(self):
        return self.logged('hook')

    def transcript(self):
        path = self.work / '.claude/projects' / chat.slug(self.project) / (self.sid() + '.jsonl')
        return [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines() if line]

    def hooks_state(self):
        first = self.command('print-agent-hooks').splitlines()[0]
        return {k: int(v) for k, v in (w.split('=', 1) for w in first.split(' '))}   # (timeout -1: none)

    def dirty_notes(self, text='ZULU'):
        """notes.txt open, with text typed at its start (unsaved)."""
        self.command(f'open {self.notes}')
        self.command('key ctrl+Home')
        self.command('type ' + text)
        self.assertIn('dirty=1', self.command('print-state'))

    def hanging_formatter(self):
        """An extension that formats every file and never answers: a save waits for it."""
        root = self.work / 'formatters'
        folder = root / 'alice' / 'format'
        folder.mkdir(parents=True)
        (folder / 'extension.ini').write_text(
            'name = format\nowner = alice\ntitle = Formatter\nversion = 1\nprotocol = 1\nruntime = python3\n'
            'run = main.py\non = command\n[needs]\ndocuments = write\n[provides]\nformat = *\n', encoding='utf-8')
        (folder / 'main.py').write_text(FORMATTER, encoding='utf-8')
        return root

    def test_initialize_has_the_three_hooks(self):
        self.start()
        self.chat('hello')
        self.assertEqual(self.initialize()[0]['hooks'], HOOKS)
        self.assertIn('rhun saves it', self.initialize()[0]['appendSystemPrompt'])

    def test_a_changed_open_file_is_saved_before_the_answer(self):
        self.start()
        self.dirty_notes()
        self.chat('hookread notes.txt')
        self.assertEqual(self.notes.read_text(encoding='utf-8'), 'ZULUalpha\nbravo\ncharlie\ndelta\necho\n')
        self.assertIn('dirty=0', self.command('print-state'))
        self.assertEqual([h['answer'] for h in self.hook_log()], [CONTINUE])
        # the Read ran after the answer: it read what the editor had
        results = [r for r in self.transcript() if r.get('type') == 'user' and 'toolUseResult' in r]
        self.assertIn('ZULUalpha', json.dumps(results[-1]['toolUseResult']))

    def test_autosave_off_saves_nothing(self):
        self.start(extra='[agents]\nautosave = false\n')
        self.dirty_notes()
        self.chat('hookread notes.txt')
        self.assertEqual(self.notes.read_text(encoding='utf-8'), 'alpha\nbravo\ncharlie\ndelta\necho\n')
        self.assertIn('dirty=1', self.command('print-state'))
        self.assertEqual([h['answer'] for h in self.hook_log()], [CONTINUE])

    def test_a_file_that_is_not_open_is_answered_at_once(self):
        self.start()
        self.chat('hookread notes.txt')
        self.assertEqual([h['answer'] for h in self.hook_log()], [CONTINUE])
        self.assertEqual(self.hooks_state()['waiting'], 0)

    @unittest.skipIf(hasattr(os, 'geteuid') and os.geteuid() == 0, 'root writes a read-only file')
    def test_a_read_only_document_is_not_saved(self):
        self.start()
        self.notes.chmod(0o444)
        self.dirty_notes()
        self.chat('hookread notes.txt')
        self.assertEqual(self.notes.read_text(encoding='utf-8'), 'alpha\nbravo\ncharlie\ndelta\necho\n')
        self.assertEqual([h['answer'] for h in self.hook_log()], [CONTINUE])
        self.notes.chmod(0o644)

    def test_a_save_that_cannot_finish_is_answered_at_its_deadline(self):
        self.start_ext(extra='[files]\nformat_on_save = true\nformat_on_save_timeout = 30000\n',
                       exts=self.hanging_formatter())
        self.command('agent-timing hooksave=800')
        self.dirty_notes()
        self.command('agent-new claude')
        began = time.monotonic()
        self.command('agent-prompt hookread notes.txt')
        self.until(lambda: self.hooks_state()['waiting'] == 1, 'the save waits')
        self.assertIn(' kind=save file=' + str(self.notes), self.command('print-agent-hooks'))
        self.command('wait-agent ready 10000')
        self.assertGreaterEqual(time.monotonic() - began, 0.75)
        self.assertEqual([h['answer'] for h in self.hook_log()], [CONTINUE])
        self.assertEqual(self.notes.read_text(encoding='utf-8'), 'alpha\nbravo\ncharlie\ndelta\necho\n')
        self.assertEqual(self.hooks_state()['waiting'], 0)

    def edit_with_a_new_problem(self):
        """hookedit notes.txt with a problem added between its base and its end (its card up)."""
        self.chat('hookedit notes.txt', 'waiting')
        self.problem(self.notes, 2, 1, 'warning', 'spell', 'Unknown word: BRAVO', code='spell', end=(2, 6))
        self.command('agent-card 1')
        self.command('wait-agent ready')

    def test_new_problems_are_reported(self):
        self.start()
        self.edit_with_a_new_problem()
        base, save, after = self.hook_log()
        self.assertEqual((base['answer'], save['answer']), (CONTINUE, CONTINUE))
        found = [{'filePath': str(self.notes), 'line': 2, 'column': 1, 'message': 'Unknown word: BRAVO',
                  'code': 'spell', 'severity': 'Warning'}]
        self.assertEqual(after['answer'], {'continue': True, 'hookSpecificOutput': {
            'hookEventName': 'PostToolUse',
            'additionalContext': '<ide_diagnostics>' + json.dumps(found, indent=2) + '</ide_diagnostics>'}})
        self.assertEqual(self.hooks_state()['contexts'], 1)

    def test_old_problems_are_not_reported(self):
        self.start()
        self.problem(self.notes, 2, 1, 'warning', 'spell', 'Unknown word: bravo', code='spell')
        self.chat('hookedit notes.txt', 'waiting')
        self.command('agent-card 1')
        self.command('wait-agent ready')
        self.assertEqual([h['answer'] for h in self.hook_log()], [CONTINUE] * 3)
        self.assertFalse([r for r in self.thread() if 'Diagnostics' in r], self.thread())

    def test_old_and_new_as_the_extension_compares(self):
        self.start()
        self.notes.write_text('one\ntwo\nthree\nfour\nfive\n', encoding='utf-8')
        self.command(f'open {self.notes}')
        long = 'x' * 200
        base = (2, 1, 'warning', 'lint', 'unused total', 'c1', (2, 5))
        cases = {'the same': base,
                 'another start column': (2, 2, 'warning', 'lint', 'unused total', 'c1', (2, 5)),
                 'another end column': (2, 1, 'warning', 'lint', 'unused total', 'c1', (2, 6)),
                 'three lines lower, three lines added': (5, 1, 'warning', 'lint', 'unused total', 'c1', (5, 5)),
                 'three lines lower, as many lines': (5, 1, 'warning', 'lint', 'unused total', 'c1', (5, 5)),
                 'another source': (2, 1, 'warning', 'spell', 'unused total', 'c1', (2, 5)),
                 'another code': (2, 1, 'warning', 'lint', 'unused total', 'c2', (2, 5)),
                 'another severity': (2, 1, 'error', 'lint', 'unused total', 'c1', (2, 5))}
        for name, expected in EQUAL_TABLE:
            with self.subTest(name):
                self.command('agent-test-problems-clear')
                before, after = base, cases.get(name)
                if name.startswith('a message'):
                    before = (2, 1, 'warning', 'lint', long + ' tail one', 'c1', (2, 5))
                    after = (2, 1, 'warning', 'lint', long + ' tail two', 'c1', (2, 5))
                line, col, sev, src, msg, code, end = before
                self.problem(self.notes, line, col, sev, src, msg, code=code, end=end)
                self.assertEqual(self.command(f'agent-diag-base {self.notes}'), 'base=1\n')
                self.command('agent-test-problems-clear')
                if name == 'three lines lower, three lines added':
                    self.command('key ctrl+Home')
                    for _ in range(3):
                        self.command('key Return')
                line, col, sev, src, msg, code, end = after
                self.problem(self.notes, line, col, sev, src, msg, code=code, end=end)
                out = self.command(f'agent-diag-new {self.notes}')
                self.assertEqual(out.split('\n', 1)[0], 'new=%d' % (expected == 'new'), out)
                if name == 'three lines lower, three lines added':
                    self.command('key ctrl+z')
                    self.command('key ctrl+z')
                    self.command('key ctrl+z')
        self.assertEqual(self.command(f'agent-diag-base {self.work / "outside.txt"}'), 'base=0\n')

    def test_no_wait_for_a_file_that_is_not_open(self):
        self.start()
        self.chat('hookedit notes.txt', 'waiting')
        began = time.monotonic()
        self.command('agent-card 1')
        self.command('wait-agent ready')
        self.assertLess(time.monotonic() - began, 0.9)

    def marked_and_open(self):
        """notes.txt open and its language marked once (a problem's mark came and went)."""
        self.command(f'open {self.notes}')
        self.problem(self.notes, 1, 1, 'hint', 'lint', 'marks this language')
        self.until(lambda: 'lint' in self.command('print-marks'), 'the mark')
        self.command('agent-test-problems-clear')

    def test_the_wait_ends_at_its_bound_with_nothing(self):
        self.start()
        self.marked_and_open()
        self.command('agent-timing hookwait=700')
        self.command('agent-new claude')
        self.command('agent-prompt hookedit notes.txt')
        self.command('wait-agent waiting')
        began = time.monotonic()
        self.command('agent-card 1')
        self.until(lambda: self.hooks_state()['waiting'] == 1, 'the wait')
        self.assertIn(' kind=problems file=' + str(self.notes), self.command('print-agent-hooks'))
        self.command('wait-agent ready')
        self.assertGreaterEqual(time.monotonic() - began, 0.65)
        self.assertEqual(self.hook_log()[-1]['answer'], CONTINUE)
        self.assertEqual(self.hooks_state()['waiting'], 0)

    def test_the_wait_ends_when_the_problems_come(self):
        # finding 48: there is no deadline_ms; rhun's wait ends at its bound or once the edited document was
        # read again and the problems changed after that
        self.start()
        self.marked_and_open()
        self.command('agent-timing hookwait=8000')
        self.command('agent-new claude')
        self.command('agent-prompt hookedit notes.txt')
        self.command('wait-agent waiting')
        began = time.monotonic()
        self.command('agent-card 1')
        self.until(lambda: self.hooks_state()['waiting'] == 1, 'the wait')
        self.until(lambda: 'alpha (edited)' in self.command('print-doc'), 'the edit read again')
        self.problem(self.notes, 1, 1, 'error', 'lint', 'new after the edit')
        self.command('wait-agent ready')
        self.assertLess(time.monotonic() - began, 6)
        context = self.hook_log()[-1]['answer']['hookSpecificOutput']['additionalContext']
        self.assertIn('new after the edit', context)

    def test_the_hook_timer_stops(self):
        # claude_hooks_timeout (what the main loop sleeps for, print-agent-hooks timeout=): a time only while an
        # answer waits, -1 after it, and after a death with an answer waiting
        self.start()
        self.marked_and_open()
        self.command('agent-timing hookwait=600')
        self.assertEqual(self.hooks_state()['timeout'], -1)
        self.chat('hookedit notes.txt', 'waiting')
        self.command('agent-card 1')
        self.until(lambda: self.hooks_state()['waiting'] == 1, 'the wait')
        self.assertIn(self.hooks_state()['timeout'], range(0, 601))
        self.command('wait-agent ready')
        self.assertEqual((self.hooks_state()['waiting'], self.hooks_state()['timeout']), (0, -1))
        self.command('agent-timing hookwait=8000')
        self.command('agent-prompt hookedit notes.txt')
        self.command('wait-agent waiting')
        self.command('agent-card 1')
        self.until(lambda: self.hooks_state()['waiting'] == 1, 'the second wait')
        os.kill(self.starts()[-1]['pid'], 9)      # the fake this test started (by its pid)
        self.until(lambda: self.hooks_state()['waiting'] == 0, 'gone with its process')
        self.assertEqual(self.hooks_state()['timeout'], -1)

    def test_an_answer_never_crosses_a_restart(self):
        self.start_ext(extra='[files]\nformat_on_save = true\nformat_on_save_timeout = 30000\n',
                       exts=self.hanging_formatter())
        self.dirty_notes()
        self.command('agent-new claude')
        self.command('agent-prompt hookread notes.txt')
        self.until(lambda: self.hooks_state()['waiting'] == 1, 'the save waits')
        hook_id = self.sent('hook_callback')[0]['id']
        pid = self.starts()[-1]['pid']
        os.kill(pid, 9)                           # the fake this test started (by its pid)
        self.until(lambda: self.hooks_state()['waiting'] == 0, 'the waiting answer goes with its process')
        self.command('wait-agent failed|ready|off 10000')
        self.command('agent-prompt hello')
        self.command('wait-agent ready 10000')
        later = [r for r in self.records() if 'stdin' in r and r['pid'] != pid]
        ids = [json.loads(r['stdin']).get('response', {}).get('request_id') for r in later]
        self.assertNotIn(hook_id, ids)

    def test_a_cancelled_hook_is_dropped(self):
        self.start_ext(extra='[files]\nformat_on_save = true\nformat_on_save_timeout = 30000\n',
                       exts=self.hanging_formatter(), env={'FAKE_CLAUDE_HOOK_CANCEL_MS': '500'})
        self.dirty_notes()
        self.chat('hookread notes.txt')
        cancelled = self.logged('cancelled')
        self.assertEqual(len(cancelled), 1)
        self.assertEqual(self.hooks_state()['waiting'], 0)
        self.assertNotIn(cancelled[0]['id'], self.answered_ids())

    def test_an_unknown_callback_and_an_input_without_a_file(self):
        self.start()
        self.chat('unhandled')
        self.assertEqual(self.logged('unhandled')[0][0], CONTINUE)    # hook_0 without a tool_input

    def test_a_subagents_edit_has_its_own_base(self):
        # bases are kept by (path, session_id, agent_id): the subagent's base, taken after a problem came, holds
        # it (nothing new for its edit); the main call's base, taken before, does not (new for it), while the
        # problem both had stays old for both (one shared base would leave the main call none: all new)
        self.start()
        self.problem(self.notes, 4, 1, 'warning', 'spell', 'Unknown word: delta', code='spell')
        self.chat('hooksub notes.txt', 'waiting')
        self.problem(self.notes, 2, 1, 'warning', 'spell', 'Unknown word: bravo', code='spell')
        self.command('agent-card 1')
        self.command('wait-agent ready')
        log = self.hook_log()
        self.assertEqual([(h['callback_id'], h.get('agent')) for h in log],
                         [('hook_0', None), ('hook_1', None), ('hook_0', 'sub1'), ('hook_1', 'sub1'),
                          ('hook_2', 'sub1'), ('hook_2', None)])
        self.assertEqual(log[4]['answer'], CONTINUE)
        context = log[5]['answer']['hookSpecificOutput']['additionalContext']
        self.assertIn('Unknown word: bravo', context)
        self.assertNotIn('Unknown word: delta', context)
        self.assertEqual(self.hooks_state()['bases'], 0)

    def test_the_diagnostics_row_comes_from_rhuns_answer(self):
        self.start()
        self.edit_with_a_new_problem()
        rows = self.thread()
        at = [i for i, r in enumerate(rows) if r.startswith('tool(Diagnostics)')]
        self.assertEqual(len(at), 1, rows)
        call = [i for i, r in enumerate(rows) if r.startswith('tool(Edit)')]
        self.assertLess(call[0], at[0])
        out = self.command('print-agent-row %d' % (at[0] + 1))
        self.assertIn('Diagnostics', out)
        self.assertIn('Found 1 new problem', out)
        text = str(self.notes) + ':\n  \u26a0 [Line 2:1] Unknown word: BRAVO [spell] (Warning)\n'
        self.assertEqual(self.row_text(at[0] + 1), text + '\n<eod>\n')     # print-doc's end
        # the stream had no record of it: the file has its attachment line, after the call's result
        lines = self.transcript()
        attach = [r for r in lines if r.get('type') == 'attachment']
        self.assertEqual(len(attach), 1)
        self.assertIn('<ide_diagnostics>', attach[0]['attachment']['content'][0])

    def row_text(self, n):
        """The text the row's note opens in a tab (print-agent-row's OUT lines are its preview): read back
        from the opened tab."""
        self.command('agent-row-click %d note' % n)
        self.command('wait 100')
        doc = self.command('print-doc')
        return doc

    def test_no_answer_no_row(self):
        self.start()
        self.chat('hookedit notes.txt', 'waiting')
        self.command('agent-card 1')
        self.command('wait-agent ready')
        self.assertFalse([r for r in self.thread() if r.startswith('tool(Diagnostics)')])

    def test_the_row_once_after_the_reread(self):
        self.start()
        self.edit_with_a_new_problem()
        live = [r for r in self.thread() if r.startswith('tool(Diagnostics)')]
        self.assertEqual(len(live), 1)
        self.command('agent-release')
        self.until_gone()
        self.command('cmd focus_agents')
        self.command('wait-agents')
        self.command('print-agents 1')
        reread = [r for r in self.thread() if r.startswith('tool(Diagnostics)')]
        self.assertEqual(reread, live)

    def test_every_request_is_answered_or_cancelled(self):
        self.start_ext(extra='[files]\nformat_on_save = true\nformat_on_save_timeout = 30000\n',
                       exts=self.hanging_formatter())
        self.dirty_notes()
        self.command('agent-new claude')
        self.command('agent-prompt hookedit notes.txt')
        self.until(lambda: self.hooks_state()['waiting'] == 1, 'the save waits')
        self.command('agent-stop')
        self.command('wait-agent ready 10000')
        sent = [s['id'] for s in self.sent('hook_callback')]
        self.assertEqual(len(sent), 2)
        self.assertEqual(set(sent) - self.answered_ids(), set())
        self.assertEqual(self.hooks_state()['waiting'], 0)


if __name__ == '__main__':
    unittest.main()
