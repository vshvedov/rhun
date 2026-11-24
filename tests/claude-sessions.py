#!/usr/bin/env python3
"""The session list (phase 6 of the Claude chat): sections, search, the status filter, groups, archiving,
unread marks, renaming, the keys, the chat header's history dropdown, a restart's open conversation, and the
cost with 5,000 conversations. Sessions are files as Claude Code writes them under a temporary HOME; rhun is
driven over the control socket (tests/claude-chat.py's ChatCase: its own HOME and XDG folders, the fake CLI)."""
import importlib.util
import json
import os
from pathlib import Path
import re
import statistics
import sys
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location('claude_chat', ROOT / 'tests/claude-chat.py')
chat = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(chat)

DAY = 86400


class ListCase(chat.ChatCase):
    """A project with Claude Code conversations written as files, the panel showing its list."""

    def folder(self):
        path = self.work / '.claude/projects' / chat.slug(self.project)
        path.mkdir(parents=True, exist_ok=True)
        return path

    def session(self, title, age=60, sid=None, custom=None, cwd=None):
        """A conversation whose first prompt is title, written age seconds ago; its id."""
        sid = sid or str(uuid.uuid4())
        path = self.folder() / (sid + '.jsonl')
        lines = [{'type': 'user', 'cwd': str(cwd or self.project), 'sessionId': sid, 'uuid': str(uuid.uuid4()),
                  'message': {'role': 'user', 'content': title}},
                 {'type': 'assistant', 'cwd': str(cwd or self.project), 'sessionId': sid,
                  'message': {'role': 'assistant', 'model': 'claude-haiku-4-5', 'content': [
                      {'type': 'text', 'text': 'Done: ' + title}]}}]
        if custom:
            lines.append({'type': 'custom-title', 'customTitle': custom, 'sessionId': sid})
        path.write_text(''.join(json.dumps(line) + '\n' for line in lines), encoding='utf-8')
        when = time.time() - age
        os.utime(path, (when, when))
        return sid

    def open_list(self, extra=''):
        self.start(extra=extra)
        self.command('cmd focus_agents')
        self.command('wait-agents')

    def listed(self, which=''):
        """print-agent-list without its first line's counters that change with time: the lines."""
        return self.command(('print-agent-list ' + which).strip()).splitlines()

    def head(self, which=''):
        return self.listed(which)[0]

    def rows(self, which=''):
        """The titles of the rows shown, in order."""
        out = []
        for line in self.listed(which)[1:]:
            m = re.match(r'  row (.*?) kind=', line)
            if m:
                out.append(m.group(1))
        return out

    def row(self, title, which=''):
        for line in self.listed(which)[1:]:
            if line.startswith('  row ' + title + ' kind='):
                return line
        self.fail(f'no row {title!r}: {self.listed(which)}')

    def state(self):
        return self.command('print-agent-list-state').splitlines()

    def until(self, check, what, seconds=10):
        deadline = time.monotonic() + seconds
        while True:
            value = check()
            if value:
                return value
            if time.monotonic() > deadline:
                self.fail('timed out waiting for ' + what)
            self.command('wait 50')


class Sections(ListCase):
    def test_newest_first_then_archived(self):
        self.session('Oldest recent', age=3 * 3600)
        self.session('Newest', age=60)
        self.session('Middle', age=3600)
        self.session('Quiet for a month', age=30 * DAY)
        self.open_list()
        lines = self.listed()
        self.assertTrue(lines[0].startswith('list shown=3 total=4 archived=1 filter=0 search=- '), lines[0])
        self.assertEqual(self.rows(), ['Newest', 'Middle', 'Oldest recent'])
        self.assertEqual(lines[-1], 'archived (1) closed')
        self.assertIn('age=1m', self.row('Newest'))
        self.assertIn('age=3h', self.row('Oldest recent'))
        self.command('agent-list toggle archived')
        self.assertEqual(self.rows(), ['Newest', 'Middle', 'Oldest recent', 'Quiet for a month'])
        self.assertIn('age=1mo', self.row('Quiet for a month'))
        self.assertEqual(self.listed()[-2], 'archived (1)')
        self.assertIn('show=2', self.state()[0])

    def test_archive_after_days_never(self):
        self.session('Old one', age=400 * DAY)
        self.open_list(extra='[agents]\narchive_after_days = 0\n')
        self.assertEqual(self.rows(), ['Old one'])
        self.assertIn('age=1y', self.row('Old one'))

    def test_no_sessions_and_states(self):
        self.open_list()
        self.assertEqual(self.listed(), [self.head()])
        self.assertTrue(self.head().startswith('list shown=0 total=0 archived=0'))


class Search(ListCase):
    def test_search_marks_matches_and_clears(self):
        self.session('Fix the parser', age=60)
        self.session('Write docs', age=120)
        self.session('fix tests too', age=180)
        self.open_list()
        self.command('agent-list search FIX')
        self.assertEqual(self.rows(), ['Fix the parser', 'fix tests too'])
        self.assertIn('match=0-3', self.row('Fix the parser'))
        self.assertIn(' search=FIX field=1 ', self.head())
        self.command('agent-list search nothing like it')
        self.assertEqual(self.listed()[1:], ['none found'])
        self.command('key Escape')               # the search goes, then the row
        self.assertIn(' search=- ', self.head())
        self.assertEqual(len(self.rows()), 3)

    def test_typing_starts_a_search_and_keys_move(self):
        self.session('Alpha one', age=60)
        self.session('Beta two', age=120)
        self.session('Alpha three', age=180)
        self.open_list()
        self.command('type alp')
        self.assertEqual(self.rows(), ['Alpha one', 'Alpha three'])
        self.command('key Down')
        self.command('key Down')
        self.assertIn(' sel=Alpha_three ', self.head())
        self.command('key Up')
        self.assertIn(' sel=Alpha_one ', self.head())
        self.command('key BackSpace')
        self.assertEqual(self.rows(), ['Alpha one', 'Alpha three'])
        self.assertIn(' search=al ', self.head())
        self.command('key Return')               # opens the selected one
        self.until(lambda: 'user Alpha one' in self.command('print-agents'), 'the conversation')

    def test_a_search_asks_for_every_session(self):
        for i in range(60):
            self.session(f'Session {i:02d}', age=60 + i)
        self.session('Needle far down', age=10 * 3600)
        self.open_list()
        self.assertEqual(self.command('print-agents-page'), 'shown=50 total=61 loading=0 error=0\n')
        self.command('agent-list search needle')
        self.command('wait-agents')
        self.until(lambda: self.rows() == ['Needle far down'], 'the whole list')
        self.assertEqual(self.command('print-agents-page'), 'shown=61 total=61 loading=0 error=0\n')


class Groups(ListCase):
    def test_new_group_rename_move_collapse_delete(self):
        self.session('First', age=60)
        self.session('Second', age=120)
        self.session('Third', age=180)
        self.open_list()
        self.command('agent-list new-group')
        self.assertIn(' rename=New_group ', self.head())
        self.command('key ctrl+a')
        self.command('type Parser work')
        self.command('key Return')
        self.assertIn(' rename=- ', self.head())
        self.assertEqual(self.listed()[1:3], ['group Parser work (0)', 'ungrouped (3)'])
        self.command('agent-list drag Second -> Parser work')
        self.command('agent-list drag Third -> Parser work')
        lines = self.listed()[1:]
        self.assertEqual([re.sub(r' kind=.*', '', l) for l in lines],
                         ['group Parser work (2)', '  row Second', '  row Third', 'ungrouped (1)', '  row First'])
        self.command('agent-list toggle Parser work')
        self.assertEqual(self.listed()[1], 'group Parser work (2) closed')
        self.assertEqual(self.rows(), ['First'])
        self.command('agent-list group-menu Parser work')
        self.assertEqual(self.command('print-menu'),
                         'Rename group\nDelete group\n-\nStart new session in this group\n')
        self.command('menu-pick Delete group')
        self.assertEqual(self.rows(), ['First', 'Second', 'Third'])
        self.assertFalse([l for l in self.listed() if l.startswith(('group', 'ungrouped'))])

    def test_row_menu_new_group_from_two(self):
        self.session('One', age=60)
        self.session('Two', age=120)
        self.session('Three', age=180)
        self.open_list()
        self.command('agent-list select One ctrl')
        self.command('agent-list select Three ctrl')
        self.assertIn(' multi=2 ', self.head())
        self.command('agent-list menu Three')
        self.assertEqual(self.command('print-menu'),
                         'Resume session\nRename session\n-\nNew group from 2 sessions\n-\n'
                         'Mark as unread\nArchive 2 sessions\n')
        self.command('menu-pick New group from 2 sessions')
        self.command('type Pair')
        self.command('key Return')
        self.assertEqual([re.sub(r' kind=.*', '', l) for l in self.listed()[1:]],
                         ['group Pair (2)', '  row One', '  row Three', 'ungrouped (1)', '  row Two'])
        self.command('agent-list menu Two')
        self.assertIn('Add to group ▸\n', self.command('print-menu'))
        self.command('menu-pick Add to group ▸')
        self.assertEqual(self.command('print-menu'), 'Pair\n')
        self.command('menu-pick Pair')
        self.assertEqual(self.listed()[1], 'group Pair (3)')
        self.command('agent-list menu Two')
        self.command('menu-pick Remove from group')
        self.assertEqual(self.listed()[1], 'group Pair (2)')

    def test_groups_survive_a_restart(self):
        self.session('Kept', age=60)
        self.open_list()
        self.command('agent-list new-group')
        self.command('key ctrl+a')
        self.command('type Later')
        self.command('key Return')
        self.command('agent-list drag Kept -> Later')
        self.quit()
        self.open_list()
        self.assertEqual([re.sub(r' kind=.*', '', l) for l in self.listed()[1:]], ['group Later (1)', '  row Kept'])
        state = self.state()
        self.assertTrue(state[1].startswith('group 1 Later flags=0'), state)


class Marks(ListCase):
    def test_archive_unarchive_and_unarchive_all(self):
        self.session('Keep me', age=60)
        self.session('Put away', age=120)
        self.session('Old a', age=20 * DAY)
        self.session('Old b', age=21 * DAY)
        self.open_list()
        self.command('agent-list menu Put away')
        self.command('menu-pick Archive session')
        self.assertEqual(self.rows(), ['Keep me'])
        self.assertEqual(self.listed()[-1], 'archived (3) closed')
        self.command('agent-list toggle archived')
        self.command('agent-list menu Old a')
        self.assertEqual(self.command('print-menu'), 'Resume session\nUnarchive session\n')
        self.command('menu-pick Unarchive session')
        self.assertEqual(self.rows()[:2], ['Keep me', 'Old a'])
        self.command('agent-list unarchive-all')
        self.assertEqual(self.rows(), ['Keep me', 'Put away', 'Old a', 'Old b'])
        self.assertFalse([l for l in self.listed() if l.startswith('archived')])

    def test_unread_marks_and_reading(self):
        self.session('Busy elsewhere', age=600)
        self.session('Other', age=700)
        self.open_list()
        self.assertIn(' dot=idle', self.row('Busy elsewhere'))
        self.command('agent-list grew Busy elsewhere')
        self.assertIn(' dot=unread', self.row('Busy elsewhere'))
        self.command('agent-list menu Busy elsewhere')
        self.assertIn('Mark as read\n', self.command('print-menu'))
        self.command('menu-pick Mark as read')
        self.assertIn(' dot=idle', self.row('Busy elsewhere'))
        self.command('agent-list menu Other')
        self.command('menu-pick Mark as unread')
        self.assertIn(' dot=unread', self.row('Other'))
        self.command('agent-list open Other')
        self.until(lambda: 'user Other' in self.command('print-agents'), 'the conversation')
        self.command('key Escape')
        self.assertIn(' dot=idle', self.row('Other'))

    def test_a_file_that_grows_is_unread(self):
        sid = self.session('Written by a terminal', age=600)
        self.open_list()
        path = self.folder() / (sid + '.jsonl')
        with path.open('a', encoding='utf-8') as f:
            f.write(json.dumps({'type': 'user', 'sessionId': sid, 'message': {'role': 'user', 'content': 'more'}}) + '\n')
        # (the dot says running while the file was written in the last 20 seconds; the mark is there at once)
        self.until(lambda: [l for l in self.state() if l.startswith('s claude:' + sid) and 'flags=4' in l],
                   'the unread mark', 15)

    def test_filter_by_status(self):
        self.session('Idle one', age=60)
        self.session('Idle two', age=120)
        self.open_list()
        self.command('agent-list filter-menu')
        self.assertEqual(self.command('print-menu'),
                         'Needs input · 0\nWorking · 0\nCompleted · 2\n-\nOpen · 0\nClosed · 2\n-\n'
                         'Active · 0\n')
        self.command('menu-pick Working · 0')
        self.assertTrue(self.head().startswith('list shown=0 total=0 archived=0 filter=2 '), self.head())
        self.assertEqual(self.listed()[1:], ['none found'])
        self.command('agent-list filter-menu')
        self.assertEqual(self.command('print-menu').splitlines()[1], '✓ Working · 0')
        self.command('menu-pick Clear filters')
        self.assertEqual(len(self.rows()), 2)
        self.command('agent-list filter-menu')
        self.command('menu-pick Completed · 2')
        self.assertEqual(len(self.rows()), 2)
        self.assertIn('filter=4', self.state()[0])


class Rename(ListCase):
    def test_rename_writes_claudes_own_title_line(self):
        sid = self.session('Before', age=60)
        self.open_list()
        self.command('agent-list rename Before')
        self.assertIn(' rename=Before ', self.head())
        self.command('key ctrl+a')
        self.command('type After "it"')
        self.command('key Return')
        self.assertEqual(self.rows(), ['After "it"'])
        last = (self.folder() / (sid + '.jsonl')).read_text(encoding='utf-8').splitlines()[-1]
        self.assertEqual(json.loads(last), {'type': 'custom-title', 'customTitle': 'After "it"', 'sessionId': sid})
        self.command('agents-more')                # discovery reads it back the same
        self.command('wait-agents')
        self.assertEqual(self.rows(), ['After "it"'])

    def test_escape_cancels_and_paste_goes_in(self):
        sid = self.session('Stays', age=60)
        self.open_list()
        self.command('agent-list rename Stays')
        self.command('key ctrl+a')
        self.command('type Gone')
        self.command('key Escape')
        self.assertEqual(self.rows(), ['Stays'])
        self.assertIn(' rename=- ', self.head())
        self.assertEqual(len((self.folder() / (sid + '.jsonl')).read_text().splitlines()), 2)

    def test_a_session_that_goes_while_renamed(self):
        sid = self.session('Doomed', age=60)
        self.session('Survivor', age=120)
        self.open_list()
        self.command('agent-list rename Doomed')
        (self.folder() / (sid + '.jsonl')).unlink()
        self.command('cmd focus_agents')
        self.command('agents-more')
        self.command('wait-agents')
        self.until(lambda: self.rows() == ['Survivor'], 'the row to go')
        self.assertIn(' rename=- ', self.head())
        self.command('type x')                     # the keys are the list's again
        self.assertIn(' search=x ', self.head())


class Header(ListCase):
    def chat_open(self, title):
        self.command(f'agent-list open {title}')
        self.until(lambda: f'user {title}' in self.command('print-agents'), 'the conversation')

    def test_history_dropdown_lists_and_resumes(self):
        self.session('Current', age=60)
        self.session('Earlier', age=3600)
        self.open_list()
        self.chat_open('Current')
        self.command('agent-list drop-open')
        self.assertIn(' drop=1', self.head('drop'))
        self.assertEqual(self.rows('drop'), ['Current', 'Earlier'])
        self.assertIn(' selected', self.row('Current', 'drop'))
        self.command('type earl')
        self.assertEqual(self.rows('drop'), ['Earlier'])
        self.command('key Return')
        self.until(lambda: 'user Earlier' in self.command('print-agents'), 'the other conversation')
        self.assertIn(' drop=0', self.head('drop'))

    def test_escape_closes_the_dropdown_then_resume_opens_it(self):
        self.session('Here', age=60)
        self.open_list()
        self.chat_open('Here')
        self.command('agent-list drop-open')
        self.command('type zz')
        self.command('key Escape')                 # the search first
        self.assertIn(' drop=1', self.head('drop'))
        self.command('key Escape')
        self.assertIn(' drop=0', self.head('drop'))
        self.command('agent-menu')
        self.command('type Resume')
        self.assertIn('Resume conversation', self.command('print-agent-menu'))

    def test_header_title_click_renames(self):
        sid = self.session('Header title', age=60)
        self.open_list()
        self.chat_open('Header title')
        self.command('click 1000 60')              # the title (1280x800: the panel's header row)
        self.assertIn(' rename=Header_title ', self.head())
        self.command('key ctrl+a')
        self.command('type Renamed here')
        self.command('key Return')
        last = (self.folder() / (sid + '.jsonl')).read_text(encoding='utf-8').splitlines()[-1]
        self.assertEqual(json.loads(last)['customTitle'], 'Renamed here')
        self.command('click 922 60')               # Back
        self.assertEqual(self.rows(), ['Renamed here'])

    def test_a_restart_opens_the_conversation_again(self):
        self.session('Open at quit', age=60)
        self.session('Not this', age=120)
        self.BASE = self.BASE.replace('restore_session = false', 'restore_session = true')
        self.open_list()
        self.chat_open('Open at quit')
        self.quit()
        self.open_list()
        self.until(lambda: 'user Open at quit' in self.command('print-agents'), 'the conversation again')


    def test_a_restore_that_never_finished_is_not_tried_a_third_time(self):
        self.session('Crashy', age=60)
        self.BASE = self.BASE.replace('restore_session = false', 'restore_session = true')
        self.open_list()
        self.chat_open('Crashy')
        self.quit()
        files = list((self.work / 'state').rglob('*.agents-list'))
        self.assertEqual(len(files), 1, files)
        text = files[0].read_text(encoding='utf-8')
        self.assertIn('\ntries\t0\n', text)
        files[0].write_text(text.replace('\ntries\t0\n', '\ntries\t2\n'), encoding='utf-8')
        self.open_list()
        self.until(lambda: ' reopen=Crashy ' in self.head(), 'the notice')
        self.assertNotIn('user Crashy', self.command('print-agents'))
        self.command('agent-list reopen')
        self.until(lambda: 'user Crashy' in self.command('print-agents'), 'the conversation')
        self.assertIn(' tries=0 ', self.state()[0])
        self.assertNotIn(' reopen=', self.head())


class Speed(ListCase):
    COUNT = 5000

    def timed(self, commands, n=30):
        """The median round trip of the commands, in turn (each ends with a frame when something changed), ms."""
        samples = []
        for i in range(n):
            start = time.perf_counter()
            self.command(commands[i % len(commands)])
            samples.append((time.perf_counter() - start) * 1000)
        return statistics.median(samples)

    def test_five_thousand_sessions(self):
        folder = self.folder()
        now = time.time()
        for i in range(self.COUNT):
            sid = f'{i:08d}-0000-4000-8000-000000000000'
            path = folder / (sid + '.jsonl')
            path.write_text(json.dumps({'type': 'user', 'cwd': str(self.project), 'sessionId': sid,
                                        'message': {'role': 'user', 'content': f'Task number {i} of the project'}})
                            + '\n', encoding='utf-8')
            os.utime(path, (now - i * 60, now - i * 60))
        t0 = time.perf_counter()
        self.start(extra='[agents]\narchive_after_days = 0\n')
        self.command('cmd focus_agents')
        self.command('wait-agents')
        self.assertTrue(self.head().startswith('list shown=50 '))
        opened = (time.perf_counter() - t0) * 1000
        hover50 = self.timed(['move 1100 300', 'move 1100 301'])
        t0 = time.perf_counter()
        self.command('agent-list search Task')     # every session asked for, then listed
        self.command('wait-agents')
        self.until(lambda: self.head().startswith(f'list shown={self.COUNT} '), 'every session', 60)
        whole = (time.perf_counter() - t0) * 1000
        hover = self.timed(['move 1100 300', 'move 1100 301'])
        keys = self.timed(['type  ', 'key BackSpace'])     # a key that keeps all 5,000, and back
        none = self.timed(['type z', 'key BackSpace'])     # a key that leaves none, and back
        self.command('move 1100 400')
        scroll = self.timed(['scroll 3', 'scroll 3', 'scroll -3', 'scroll -3'])
        self.command('key Down')
        down = self.timed(['key Down', 'key Up'])
        info = (f'{self.COUNT} sessions: the panel open with its first page {opened:.0f} ms; every session listed '
                f'{whole:.0f} ms after the search asked for them; medians: a frame (hover) {hover50:.2f} ms with 50 '
                f'rows, {hover:.2f} ms with {self.COUNT}; a search key {keys:.2f} ms (all kept), {none:.2f} ms '
                f'(none kept); a scroll step {scroll:.2f} ms; a key Down/Up {down:.2f} ms')
        print(info, file=sys.stderr)
        self.assertLess(hover, hover50 + 5)
        self.assertLess(scroll, hover50 + 5)
        self.assertLess(keys, 50)


if __name__ == '__main__':
    unittest.main()
