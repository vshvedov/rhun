#!/usr/bin/env python3
"""The agents panel's thread engine (phase 3): heights kept per 64 rows so that a frame asks only the rows in
view (print-agent-thread's walked), the view kept as a row and an offset through every height change and a
reread of the conversation's file, the thread's keys. It imports tests/claude-chat.py for its cases: every
rhun gets its own HOME and XDG folders, an environment without CLAUDE* or ANTHROPIC* variables, and a
config whose [claude] section starts the fake (tests/scripts/fake-claude.py); conversations are seeded as
files or made with the test seam (agent-test-row), never with the real CLI. Nothing here writes the user's
own Claude Code settings."""
import calendar
import importlib.util
import itertools
import json
import os
import shutil
import subprocess
from pathlib import Path
import re
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location('claude_chat', ROOT / 'tests/claude-chat.py')
chat = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(chat)
_spec = importlib.util.spec_from_file_location('claude_transcript', ROOT / 'tests/claude-transcript.py')
tr = importlib.util.module_from_spec(_spec)         # its record makers (call, result, thought, todo_call)
_spec.loader.exec_module(tr)

SLACK = 140                     # what a frame may ask beyond the rows in view: two chunks of 64 and a few
SCROLLBAR = (1270, 430)         # the thread's scrollbar track at 1280x800 with the agents panel alone


def turns(n, reply='reply {0}'):
    """n prompts and their replies, as a conversation's file holds them."""
    out = []
    for i in range(n):
        out.append(('user', 'step %d' % i))
        out.append(('assistant', reply.format(i)))
    return out


class ThreadCase(chat.DrivenCase):
    """A seeded conversation, print-agent-thread and print-agent-row read as dicts."""

    def write(self, rows, sid='s1', title='Seeded'):
        """A Claude conversation file of (role, text) rows."""
        folder = self.work / '.claude/projects' / chat.slug(self.project)
        folder.mkdir(parents=True, exist_ok=True)
        cwd = self.project.as_posix()
        lines = []
        for row in rows:
            role, text = row[0], row[1]
            if role == 'user':
                lines.append({'type': 'user', 'message': {'role': 'user', 'content': text}, 'cwd': cwd,
                              'sessionId': sid})
            elif role == 'tool':
                lines.append({'type': 'assistant', 'message': {'role': 'assistant', 'content': [
                    {'type': 'tool_use', 'id': text, 'name': 'Bash', 'input': {'command': 'ls ' + text}}]}})
            else:
                lines.append({'type': 'assistant', 'message': {'role': 'assistant',
                                                               'content': [{'type': 'text', 'text': text}]}})
            if len(row) > 2:                         # (role, text, ISO time): the record's timestamp
                lines[-1]['timestamp'] = row[2]
        lines.append({'type': 'custom-title', 'customTitle': title, 'sessionId': sid})
        path = folder / (sid + '.jsonl')
        path.write_text(''.join(json.dumps(r) + '\n' for r in lines), encoding='utf-8')
        return path

    def open_seeded(self, rows, extra=''):
        self.write(rows)
        self.start(extra=extra)
        self.open_listed()
        self.command('print-frames')

    def engine(self):
        """print-agent-thread as a dict (numbers as ints, "-" as None)."""
        line = self.command('print-agent-thread').strip()
        out = {}
        for word in line.split(' '):
            key, value = word.split('=', 1)
            if key == 'anchor':
                out[key] = None if value == '-' else tuple(int(v) for v in value.split('+', 1))
            else:
                out[key] = None if value == '-' else int(value)
        return out

    def row(self, n):
        """print-agent-row N's first line as a dict (n from 1)."""
        first = self.command('print-agent-row %d' % n).splitlines()[0]
        return dict(word.split('=', 1) for word in first.split(' '))

    def top_row(self):
        """The row under the area's top edge and where its top is on screen: (index from 0, y)."""
        e = self.engine()
        first = e['first']
        return first, int(self.row(first + 1)['y'])

    def assert_walked(self, e, what):
        inview = e['last'] - e['first'] + 1
        self.assertLessEqual(e['walked'], inview + SLACK, (what, e))

    def wheel(self, px):
        self.command('move 1100 400')
        self.command('scroll %d' % px)

    def scrollbar(self, y):
        """The scrollbar's track pressed at y and let go (the thumb jumps there)."""
        self.command('move %d %d' % (SCROLLBAR[0], y))
        self.command('down')
        self.command('up')
        self.command('print-frames')


class EngineTest(ThreadCase):
    """A frame's work does not grow with the conversation."""

    def test_a_frame_asks_only_the_rows_in_view(self):
        self.open_seeded(turns(10000))
        e = self.engine()
        self.assertEqual((e['rows'], e['follow']), (20000, 1), e)
        self.assertEqual(e['last'], 19999, e)
        self.assert_walked(e, 'at the end')
        exact = e['exact']
        self.assertLessEqual(exact, 200, e)          # rows measured: those in view and their chunks', no more
        self.scrollbar(SCROLLBAR[1])                 # the middle
        e = self.engine()
        self.assertEqual(e['follow'], 0, e)
        self.assertGreater(e['first'], 2000, e)
        self.assertLess(e['last'], 18000, e)
        self.assert_walked(e, 'in the middle')
        self.assertLessEqual(e['exact'] - exact, e['last'] - e['first'] + 1 + 4, e)
        exact = e['exact']
        before = e['first']
        self.wheel(-300)
        e = self.engine()
        self.assertLess(e['first'], before, e)
        self.assert_walked(e, 'after a wheel step')
        self.assertLessEqual(e['exact'] - exact, e['last'] - e['first'] + 1, e)

    def test_a_resize_touches_no_row_out_of_view(self):
        self.open_seeded(turns(10000))
        for width in range(1280, 1080, -20):        # the panel narrows by 20 px a frame
            self.command('resize %d 800' % width)
            e = self.engine()
            self.assert_walked(e, width)
            self.assertLessEqual(e['resolved'], 2, (width, e))
            self.assertEqual((e['follow'], e['last']), (1, 19999), (width, e))

    def test_a_reply_is_parsed_once(self):
        reply = '# Step {0}\n\n- one\n- two\n\n```sh\necho {0}\n```\n\nThat is step {0}.'
        self.open_seeded(turns(40, reply))
        parses = lambda: int(self.row(1)['parses'])
        first = parses()
        self.assertGreater(first, 0)
        self.wheel(-300)
        up = parses()
        self.assertGreaterEqual(up, first)
        self.wheel(300)
        self.assertEqual(parses(), up, 'scrolled back: nothing parsed again')
        self.wheel(-300)
        self.assertEqual(parses(), up, 'and up again')
        self.command('resize 1100 800')
        narrow = parses()
        self.command('resize 1280 800')
        self.assertEqual(parses(), narrow, 'a width change and back: nothing parsed again')
        self.command('resize 1100 800')
        self.assertEqual(parses(), narrow)

    def test_a_change_dirties_one_chunk(self):
        self.open_seeded(turns(10000))
        self.command('key Home')                    # the first rows: the last chunk stays summed from its rows
        e = self.engine()
        self.assertEqual((e['first'], e['follow']), (0, 0), e)
        resolved = e['resolved']
        self.assertGreaterEqual(resolved, 2, e)
        self.command('agent-test-append  more')     # the last reply, out of view, changes
        after = self.engine()
        self.assertEqual(after['resolved'], resolved - 1, (e, after))
        self.assertEqual(after['first'], 0, after)
        self.assert_walked(after, 'after a change out of view')

    def test_the_end_is_the_end(self):
        self.open_seeded(turns(3))
        kinds = ['user', 'agent', 'meta', 'thinking', 'compact', 'unknown']
        bottoms = set()
        for i in range(500):
            kind = kinds[i % len(kinds)]
            text = ('line %d ' % i) * (1 + i % 7)
            if i % 11 == 0:
                text += '\\nand a second line'
            self.command('agent-test-row %s %s' % (kind, text.strip()))
            if i % 50 == 49:
                e = self.engine()
                self.assertEqual(e['follow'], 1, e)
                self.assertEqual(e['scroll'], e['max'], e)
                self.assertEqual(e['last'], e['rows'] - 1, e)
                last = self.row(e['rows'])
                self.assertNotEqual(last['y'], '-1', last)
                bottoms.add(int(last['y']) + int(last['height']))
        self.assertEqual(len(bottoms), 1, bottoms)  # the last row's bottom is where the area ends, always

    def test_100k_rows_open(self):
        self.write(turns(50000))
        self.start()
        began = time.monotonic()
        self.open_listed()
        self.command('print-frames')
        took = time.monotonic() - began
        e = self.engine()
        self.assertEqual(e['rows'], 100000, e)
        self.assert_walked(e, '100,000 rows')
        self.assertLess(took, 20, took)
        began = time.monotonic()
        self.wheel(-600)
        self.assertLess(time.monotonic() - began, 2)


class AnchorTest(ThreadCase):
    """The view stays where it was: the row under the area's top edge, at the same place."""

    def assert_stays(self, before, what):
        self.assertEqual(self.top_row(), before, what)

    def test_view_stays_when_rows_above_become_exact(self):
        reply = '# Step {0}\n\n- one\n- two\n\n```sh\necho {0}\necho done\n```\n\nThat is step {0}.'
        self.open_seeded(turns(60, reply))
        for _ in range(4):
            first, y = self.top_row()
            self.wheel(-300)
            # the row that was at the top moved by the wheel alone, however the rows above it measured
            self.assertEqual(int(self.row(first + 1)['y']), y + 300)

    def test_view_stays_when_a_row_above_grows(self):
        self.open_seeded(turns(30))
        for i in range(30):                          # rows after the last reply: it is above the view
            self.command('agent-test-row meta note %d' % i)
        self.wheel(-200)
        before = self.top_row()
        e = self.engine()
        self.assertEqual(e['follow'], 0, e)
        self.command('agent-test-append \\n\\nmore\\nand more\\nand more again')
        self.assert_stays(before, 'a reply above the view grew')

    def test_view_stays_through_a_view_change(self):
        self.open_seeded(turns(200))
        self.wheel(-900)
        before = self.top_row()
        gen = self.engine()['gen']
        self.command('agent-test-view')
        self.assertEqual(self.engine()['gen'], gen + 1)
        self.assert_stays(before, 'ag_gen moved on')

    def test_view_stays_through_width_and_font(self):
        self.open_seeded(turns(200, 'a reply of some words that wraps when the panel is narrow, {0}'))
        self.wheel(-900)
        first, _ = self.top_row()
        self.command('resize 1100 800')
        self.assertEqual(self.top_row()[0], first, 'width')
        self.command('cmd agents_font_increase')
        self.command('print-frames')
        self.assertEqual(self.top_row()[0], first, 'font')
        self.command('cmd agents_font_reset')
        self.command('resize 1280 800')
        self.assertEqual(self.top_row()[0], first, 'back')

    def test_view_stays_through_a_resync(self):
        self.start()
        self.chat('hello')
        for i in range(25):
            self.command('agent-prompt again %d' % i)
            self.command('wait-agent ready')
        self.wheel(-500)
        before = self.top_row()
        e = self.engine()
        self.assertEqual(e['follow'], 0, e)
        rows = self.thread()
        self.command('agent-release')
        self.command('wait-agent off')
        self.until_gone()
        self.assertEqual(self.thread(), rows)
        self.assert_stays(before, 'the file read again')

    def test_resync_with_fewer_rows_lands_in_the_same_turn(self):
        self.start()
        self.chat('hello')
        for i in range(12):
            self.command('agent-prompt again %d' % i)
            self.command('wait-agent ready')
        rows = len(self.thread())
        for i in range(40):                          # rows of the last turn the file does not keep
            self.command('agent-test-row meta kept only live %d' % i)
        self.wheel(-200)
        e = self.engine()
        self.assertEqual(e['follow'], 0, e)
        self.assertGreaterEqual(e['anchor'][0], rows, e)
        self.command('agent-release')
        self.command('wait-agent off')
        self.until_gone()
        e = self.engine()
        self.assertEqual(e['rows'], rows, e)
        # the turn's last row: here the conversation's end, so the thread shows its end
        self.assertEqual(e['last'], rows - 1, e)
        self.assertTrue(e['anchor'] is None or e['anchor'][0] == rows - 1, e)

    def test_view_stays_through_the_timestamps_toggle(self):
        """[agents] timestamps adds a time line above every prompt and a day pill where the day changes: the
        heights above the view change, the row at the top stays where it was (task 5)."""
        rows = []
        for i in range(200):                         # a new day every four turns
            at = '2026-10-%02dT12:%02d:00Z' % (1 + i // 8, i % 60)
            rows += [('user', 'step %d' % i, at), ('assistant', 'reply %d' % i, at)]
        self.open_seeded(rows)
        self.wheel(-870)                             # (a top row whose time line is wholly above the edge:
        first, y = self.top_row()                    #   phase 3 task 8's shorter prompts and task 10's Copy
                                                     #   response lines under the replies moved it)
        height = int(self.row(first + 1)['height'])
        on = self.engine()
        self.assertEqual(on['follow'], 0, on)
        for value in ('false', 'true'):
            gen = self.engine()['gen']
            self.config.write_text(self.BASE + self.claude_section() + '[agents]\ntimestamps = %s\n' % value,
                                   encoding='utf-8')
            self.until(lambda: self.engine()['gen'] != gen, 'the reload', 10)
            self.command('print-frames')
            # the same row at the top, its text where it was: only its time line and pill come or go above it
            now = int(self.row(first + 1)['height'])
            self.assert_stays((first, y + height - now), 'timestamps = ' + value)
            if value == 'false':
                self.assertLess(self.engine()['content'], on['content'])
                self.assertLess(now, height)
        self.assertEqual(self.top_row(), (first, y))

    def test_following_stays_at_the_end_through_all_of_them(self):
        self.start()
        self.chat('hello')
        for i in range(10):
            self.command('agent-prompt again %d' % i)
            self.command('wait-agent ready')

        def at_end(what):
            e = self.engine()
            self.assertEqual((e['follow'], e['scroll'], e['last']), (1, e['max'], e['rows'] - 1), (what, e))

        at_end('replies')
        self.command('agent-test-append \\nmore')
        at_end('a row grew')
        self.command('agent-test-view')
        at_end('a view change')
        self.command('resize 1100 800')
        at_end('width')
        self.command('cmd agents_font_increase')
        self.command('print-frames')
        at_end('font')
        self.command('cmd agents_font_reset')
        self.command('agent-release')
        self.command('wait-agent off')
        self.until_gone()
        self.command('print-frames')
        at_end('a reread')

    # focus view (task 9): a toggle and a fold's open and close keep the view

    def folded_turns(self, n):
        """n turns of a prompt, three calls with their results and a reply of three lines (the file's)."""
        out = [tr.prompt('look')]
        for i in range(n):
            out.append(tr.prompt('step %d' % i))
            for k in range(3):
                tid = 't%d-%d' % (i, k)
                out += [tr.call(tid, 'Bash', {'command': 'ls %d' % k}), tr.result(tid, 'out %d' % k)]
            out.append(tr.reply('reply %d\n\nwith a second paragraph\n\nand a third' % i))
        return out

    def open_folded(self, n, extra=''):
        FoldCase.seed(self, self.folded_turns(n))
        self.start(extra=extra)
        self.open_listed()
        self.command('print-frames')

    def top_kind(self):
        first = self.engine()['first']
        return first, self.command('print-agent-rows %d 1' % first).split(' ')[1]

    def to_a_reply(self):
        """Wheel steps until the row at the top is a reply or a prompt (not one a fold may hide)."""
        for _ in range(40):
            if self.top_kind()[1] in ('agent', 'user'):
                return
            self.wheel(-37)
        self.fail('no reply at the top')

    def test_view_stays_through_the_focus_view_toggle(self):
        self.open_folded(200)
        self.wheel(-3000)
        self.to_a_reply()
        before = self.top_row()
        for how in ('cmd agents_toggle_focus_view', 'key ctrl+alt+f', 'cmd agents_toggle_focus_view',
                    'key ctrl+alt+f'):
            content = self.engine()['content']
            self.command(how)
            self.command('print-frames')
            self.assertNotEqual(self.engine()['content'], content, how)
            self.assert_stays(before, how)

    def test_view_stays_when_a_fold_above_opens_and_closes(self):
        self.open_folded(200, '[agents]\nfocus_view = true\n')
        self.wheel(-3000)
        self.to_a_reply()
        before = self.top_row()
        above = [f for f in FoldCase.folds(self) if f['last'] < before[0]][-3]
        for _ in range(2):
            self.command('agent-fold-click %d' % (above['first'] + 1))
            self.command('print-frames')
            self.assert_stays(before, 'a fold above the view')
        self.assertEqual([f['open'] for f in FoldCase.folds(self) if f['first'] == above['first']], [0])

    def test_a_fold_that_closes_over_the_view_shows_its_line_at_the_top(self):
        self.open_folded(200, '[agents]\nfocus_view = true\n')
        self.wheel(-3000)
        fold = [f for f in FoldCase.folds(self) if f['first'] > self.engine()['first']][0]
        self.command('agent-fold-click %d' % (fold['first'] + 1))
        self.command('print-frames')
        for _ in range(60):                          # its second call at the top
            if self.engine()['first'] >= fold['first'] + 1:
                break
            self.wheel(23)
        first = self.engine()['first']
        self.assertTrue(fold['first'] < first <= fold['last'], (fold, first))
        self.command('agent-fold-click %d' % (fold['first'] + 1))
        self.command('print-frames')
        e = self.engine()
        self.assertEqual((e['first'], e['anchor']), (fold['first'], (fold['first'], 0)), e)


class KeysTest(ThreadCase):
    """The thread's keys, after the popup and a card had theirs."""

    def test_home_end_and_pages(self):
        self.open_seeded(turns(300))
        self.command('cmd focus_agents')
        self.command('key Home')
        e = self.engine()
        self.assertEqual((e['first'], e['follow'], e['anchor']), (0, 0, (0, -12)), e)
        self.command('key Page_Down')
        down = self.engine()
        self.assertGreater(down['scroll'], 0, down)
        self.command('key Page_Down')
        twice = self.engine()
        self.assertGreater(twice['scroll'], down['scroll'], twice)
        self.command('key Page_Up')
        self.assertEqual(self.engine()['scroll'], down['scroll'])
        self.command('key End')
        e = self.engine()
        self.assertEqual((e['follow'], e['last'], e['scroll']), (1, 599, e['max']), e)
        self.command('key ' + chat.MOD + '+Up')
        self.assertEqual(self.engine()['first'], 0)
        self.command('key ' + chat.MOD + '+Down')
        self.assertEqual(self.engine()['follow'], 1)

    def test_tab_and_enter_still_reach_the_box(self):
        self.open_seeded(turns(5))
        self.command('cmd focus_agents')
        self.command('key Tab')
        self.assertIn(' focus=1 ', self.command('print-agent-input'))
        self.command('key Escape')
        self.command('key Return')
        self.assertIn(' focus=1 ', self.command('print-agent-input'))

    def test_focus_last_message(self):
        self.open_seeded(turns(300))
        self.command('cmd focus_agents')
        self.command('key Home')
        self.command('agent-focus editor')
        self.command('cmd agents_focus_last')
        e = self.engine()
        self.assertEqual((e['follow'], e['focus'], e['last']), (1, 599, 599), e)
        self.assertIn(' focus=0 ', self.command('print-agent-input'))    # the panel's keys, not the box's


class TypedEngineTest(ThreadCase):
    """The engine with typed rows (agentrows.s): calls by id, rows cut, a reread, a fork."""

    def test_100k_calls_without_results(self):
        self.open_seeded(turns(2))
        began = time.monotonic()
        self.command('agent-test-tool c name=Bash second=ls repeat=100000')
        took = time.monotonic() - began
        e = self.engine()
        self.assertEqual((e['calls'], e['rows']), (100000, 100004), e)
        self.assert_walked(e, '100,000 calls')
        self.assertLess(took, 30, took)
        self.command('agent-test-tool c-99999 out=done state=ok done=1')
        self.assertEqual(self.engine()['calls'], 99999)

    def test_resync_under_everything(self):
        self.start()
        self.chat('hello')
        self.command('agent-test-tool t1 name=Bash out=' + '\\n'.join('l%d' % i for i in range(9)) + ' state=ok')
        n = self.engine()['rows'] - 1
        self.command('cmd focus_agents')
        self.command('key Up')                       # the focus on the call's row
        self.assertEqual(self.engine()['focus'], n)
        self.command('agent-row-click %d out' % (n + 1))  # a tab from its text
        self.command('cmd focus_agents')
        self.command('agent-row-click %d out' % (n + 1))  # and a click waiting for the frame's end
        rows = [r for r in self.thread() if not r.startswith(('tool', 'result'))]
        self.command('agent-release')
        self.command('wait-agent off')
        self.until_gone()
        e = self.engine()
        self.assertIsNone(e['focus'], e)
        self.assertEqual(self.thread(), rows)
        self.assertEqual(e['calls'], 0, e)

    def test_truncate_cuts_chunks_and_folds(self):
        self.open_seeded(turns(100))
        for i in range(30):
            self.command('agent-test-row meta note %d' % i)
        before = self.engine()
        self.command('agent-test-truncate 150')
        e = self.engine()
        self.assertEqual((e['rows'], e['chunks']), (150, 3), e)
        self.command('key Home')
        self.command('key End')
        e = self.engine()
        total = 0
        for n in range(e['rows']):
            total += int(self.row(n + 1)['height'])
        self.assertLess(e['content'], before['content'])



class TypedKeysTest(ThreadCase):
    """The row focus and its actions."""

    def calls(self):
        self.open_seeded(turns(3))
        self.command('agent-test-tool a name=Bash out=' + 'x' * 300 + ' state=ok')
        self.command('agent-test-row meta between')
        self.command('agent-test-tool b name=Bash out=short state=ok')
        self.command('agent-test-tool c name=Read second=notes.txt link=notes.txt title=Read notes note=Read 9 '
                     'lines out=' + '\\n'.join('l%d' % i for i in range(9)) + ' state=ok')
        self.command('cmd focus_agents')
        return self.engine()['rows']

    def test_up_down_walk_the_rows_with_actions(self):
        rows = self.calls()
        self.command('key Up')
        self.assertEqual(self.engine()['focus'], rows - 1)
        self.command('key Up')                       # past the short call and the meta line
        self.assertEqual(self.engine()['focus'], rows - 4)
        self.command('key Down')
        self.assertEqual(self.engine()['focus'], rows - 1)

    def test_enter_opens_the_text_in_a_tab(self):
        rows = self.calls()
        self.command('key Up')
        self.command('key Up')
        self.command('key Return')
        state = self.command('print-state')
        self.assertIn(' active=Bash tool output ', state)
        self.assertTrue(self.command('print-doc').startswith('x' * 300))

    def test_a_second_click_finds_the_tab(self):
        rows = self.calls()
        tabs = lambda: len([n for n in self.command('print-tabs').strip()[len('tabs='):].split(' | ') if n])
        start = tabs()
        self.command('agent-row-click %d out' % (rows - 3))
        self.assertEqual(tabs(), start + 1)
        self.command('cmd focus_agents')
        self.command('agent-row-click %d out' % (rows - 3))
        self.assertEqual(tabs(), start + 1)
        self.command('cmd close_tab')
        self.assertEqual(tabs(), start)
        self.command('cmd focus_agents')
        self.command('agent-row-click %d out' % (rows - 3))
        self.assertEqual(tabs(), start + 1)

    def test_keys_with_a_card_up_go_to_the_card(self):
        self.start()
        self.command('agent-timing card=0')         # (a new card's lock)
        self.chat('hello')
        self.command('agent-test-tool a name=Bash out=' + 'x' * 300 + ' state=ok')
        self.command('agent-prompt tool')
        self.command('wait-agent waiting')
        self.command('cmd focus_agents')
        for key in ('Up', 'Down', 'Up', 'Return'):
            self.command('key ' + key)
            self.assertIsNone(self.engine()['focus'], key)     # the card's, never a row's
        self.command('agent-card 1')
        self.command('wait-agent ready')
        self.assertIsNone(self.engine()['focus'])
        self.assertNotIn('Bash tool output', self.command('print-tabs'))

    def test_escape_stops_the_turn_before_it_drops_the_focus(self):
        self.start()
        self.chat('hello')
        self.command('agent-test-tool a name=Bash out=' + 'x' * 300 + ' state=ok')
        self.command('cmd focus_agents')
        self.command('key Up')
        n = self.engine()['focus']
        self.assertIsNotNone(n)
        self.command('agent-prompt slow')
        self.command('wait-agent working')
        self.command('cmd focus_agents')
        self.command('key Escape')                   # the turn stops first
        self.command('wait-agent ready 20000')
        self.assertEqual(self.engine()['focus'], n)
        self.command('key Escape')                   # then the focus goes
        self.assertIsNone(self.engine()['focus'])
        self.command('key Escape')                   # then the conversation closes
        self.assertNotIn('rows=', self.command('print-agent-thread'))


def spin_words(line):
    """print-agent-spinner as a dict ("-" as None; "_" in verb and label are spaces)."""
    out = {}
    for word in line.strip().split(' '):
        key, value = word.split('=', 1)
        if key in ('verb', 'label'):
            out[key] = value.replace('_', ' ')
        else:
            out[key] = None if value == '-' else value
    return out


class SpinnerCase(ThreadCase):
    def spin(self):
        return spin_words(self.command('print-agent-spinner'))

    def passes(self):
        return int(self.command('print-loop-stats').split()[0].split('=')[1])

    def wakeups(self, seconds=1.5):
        """main loop passes in that many seconds (the two print-loop-stats add one)"""
        before = self.passes()
        time.sleep(seconds)
        return self.passes() - before - 1

    def ticks(self, n):
        for _ in range(n):
            self.command('agent-spin-tick')

    def working(self, prompt='linger 30', env=None, extra=''):
        """a driven conversation whose turn works (the fake's linger)"""
        self.start(extra=extra, env=env)
        self.chat('hello')
        self.command('agent-prompt ' + prompt)
        self.command('wait-agent working')


class SpinnerTest(SpinnerCase):
    """The line after the last row while the open conversation works: frames, verbs, the typewriter; the one
    tick of 120 ms that serves it and every running dot, armed only by something moving drawn in view."""

    def test_spinner_shows_while_a_turn_runs_and_goes(self):
        self.start()
        self.chat('hello')
        self.assertEqual(self.spin()['shown'], '0')
        self.command('agent-prompt linger 1.5')
        self.command('wait-agent working')
        spin = self.spin()
        self.assertEqual(spin['shown'], '1', spin)
        self.assertEqual(spin['verbs'], '82', spin)
        self.assertIsNotNone(spin['y'], spin)
        self.assertIsNotNone(spin['timeout'], spin)
        self.command('wait-agent ready 10000')
        self.command('print-frames')
        spin = self.spin()
        self.assertEqual((spin['shown'], spin['timeout']), ('0', None), spin)

    def test_frames_step_there_and_back(self):
        self.start()
        self.command('agent-timing spin=0')          # the tick held: steps by agent-spin-tick alone
        self.chat('hello')
        self.command('agent-prompt linger 30')
        self.command('wait-agent working')
        self.assertEqual(self.spin()['frame'], '0')
        frames = []
        for _ in range(13):
            self.ticks(1)
            frames.append(int(self.spin()['frame']))
        self.assertEqual(frames, [1, 2, 3, 4, 5, 5, 4, 3, 2, 1, 0, 0, 1])
        self.assertEqual(self.spin()['tick'], '0')

    def test_verbs_change_at_2_5_10_seconds(self):
        self.start()
        self.command('agent-timing spin=0')
        self.chat('hello')
        self.command('agent-prompt linger 60')
        self.command('wait-agent working')
        verbs = [self.spin()['verb']]
        changed = []
        for n in range(1, 90):
            self.ticks(1)
            verb = self.spin()['verb']
            if verb != verbs[-1]:
                changed.append(n)
                verbs.append(verb)
        # 120 ms a tick: the first change at 2 s, then 3 s and 5 s later
        self.assertEqual(changed, [17, 42, 84], verbs)

    def test_user_verbs_append_and_replace(self):
        self.start(self.claude_section('spinner_verbs = replace\nspinner_verb = Zooming\n'))
        self.assertIn('claude.spinner_verb=Zooming\n', self.command('print-settings'))
        self.chat('hello')
        self.command('agent-prompt linger 30')
        self.command('wait-agent working')
        spin = self.spin()
        self.assertEqual((spin['verbs'], spin['verb']), ('1', 'Zooming'), spin)
        self.command('agent-stop')
        self.command('wait-agent ready 10000')
        self.quit()
        self.start(self.claude_section('spinner_verb = Zooming\nspinner_verb = Whooshing\n'))
        self.chat('hello')
        self.command('agent-prompt linger 30')
        self.command('wait-agent working')
        self.assertEqual(self.spin()['verbs'], '84')
        self.command('agent-stop')
        self.command('wait-agent ready 10000')
        self.quit()
        self.start(self.claude_section('spinner_verbs = replace\n'))   # replace with none: the driver's
        self.chat('hello')
        self.command('agent-prompt linger 30')
        self.command('wait-agent working')
        self.assertEqual(self.spin()['verbs'], '82')

    def test_typewriter_reaches_the_verb(self):
        self.start()
        self.command('agent-timing spin=0')
        self.chat('hello')
        self.command('agent-prompt linger 30')
        self.command('wait-agent working')
        spin = self.spin()
        self.assertEqual(spin['label'], '', spin)            # it starts blank
        self.ticks(1)
        self.assertIn('▌', self.spin()['label'])         # the cursor sweeps, 3 characters a tick
        self.ticks(9)
        spin = self.spin()
        self.assertEqual(spin['label'], spin['verb'] + '...', spin)

    def test_compacting_and_start_hook_words(self):
        self.start(env={'FAKE_CLAUDE_HOOKS': 'start', 'FAKE_CLAUDE_HOOK_MS': '2500',
                        'FAKE_CLAUDE_COMPACT_MS': '2500'})
        self.command('agent-new claude')
        self.command('agent-prompt hello')
        spin = self.until(lambda: (lambda s: s if s['verb'] == 'Running start-up hooks' else None)(self.spin()),
                          'the start-up hook\'s words')
        self.assertEqual(spin['shown'], '1', spin)
        self.command('wait-agent ready 15000')
        self.assertEqual(self.spin()['shown'], '0')
        self.command('agent-prompt /compact')
        spin = self.until(lambda: (lambda s: s if s['verb'] == 'Compacting' else None)(self.spin()), 'Compacting')
        self.assertEqual(spin['static'], '0', spin)
        self.command('wait-agent ready 15000')
        self.command('agent-prompt linger 30')
        self.command('wait-agent working')
        self.assertNotIn(self.spin()['verb'], ('Compacting', 'Running start-up hooks'))

    def test_no_hook_events_flag_is_passed(self):
        self.start(env={'FAKE_CLAUDE_HOOKS': 'start'})
        self.chat('hello')
        self.assertNotIn('--include-hook-events', self.starts()[0]['argv'])

    def test_colour_follows_the_mode(self):
        self.working()
        self.assertEqual(self.spin()['color'], 'd97757')     # the default mode: the driver's own colour
        self.command('agent-stop')
        self.command('wait-agent ready 10000')
        self.command('agent-mode plan')
        self.command('wait-agent ready 10000')
        self.command('agent-prompt linger 30')
        self.command('wait-agent working')
        plan = self.spin()['color']
        self.assertNotEqual(plan, 'd97757')

    def test_spinner_is_before_queued_rows(self):
        self.working()
        self.command('agent-prompt and then this')           # queued while the turn works
        self.until(lambda: self.command('print-agents').splitlines()[-1] == 'queued and then this', 'queued')
        spin = self.spin()
        e = self.engine()
        last = self.row(e['rows'])
        self.assertGreaterEqual(int(spin['y']), int(last['y']) + int(last['height']), (spin, last))

    def test_a_running_dot_blinks_only_when_driven(self):
        self.working()
        self.command('agent-timing spin=0')
        self.command('agent-test-tool a name=Bash second=sleep 9')    # a running call
        states = []
        for _ in range(17):
            states.append(self.spin()['blink'])
            self.ticks(1)
        self.assertEqual(set(states), {'on', 'off'}, states)
        runs = [len(list(g)) for _, g in itertools.groupby(states)]
        self.assertEqual(runs[1:-1], [4] * (len(runs) - 2), states)       # 4 ticks on, 4 off

    def test_a_reader_has_no_tick(self):
        self.open_seeded(turns(3))
        self.command('agent-test-tool a name=Bash second=sleep 9')     # running, in a conversation only read
        self.command('print-frames')
        spin = self.spin()
        self.assertEqual((spin['shown'], spin['seen'], spin['timeout'], spin['blink']), ('0', '0', None, None), spin)
        self.assertLessEqual(self.wakeups(), 4)

    def test_the_tick_stops(self):
        self.write(turns(3), sid='other', title='Other')
        self.start()
        self.chat('hello')
        for i in range(60):                          # a thread taller than the panel
            self.command('agent-test-row meta a note that takes some room in the thread %d' % i)
        self.command('agent-prompt linger 60')
        self.command('wait-agent working')

        def ticking(what):
            self.assertIsNotNone(self.spin()['timeout'], what)
            self.assertGreaterEqual(self.wakeups(), 8, what)

        def still(what):
            time.sleep(1.0)                          # the tick after the last one that drew it, a scrollbar's fade
            self.command('print-frames')
            spin = self.spin()
            self.assertIsNone(spin['timeout'], (what, spin))
            self.assertLessEqual(self.wakeups(), 4, what)

        ticking('the line in view')
        self.wheel(-3000)                            # scrolled up: the line is out of view
        still('scrolled up')
        self.command('cmd focus_agents')
        self.command('key End')
        ticking('back at the end')
        self.command('cmd toggle_agents')            # the panel hidden
        still('the panel hidden')
        self.command('cmd toggle_agents')
        ticking('the panel shown again')
        self.command('click %d %d' % chat.BACK)      # the list
        still('the list')
        rows = self.listed()
        other = [i for i, r in enumerate(rows) if 'Other' in r]
        self.assertEqual(len(other), 1, rows)
        self.command('print-agents %d' % (other[0] + 1))   # another conversation open
        still('another conversation')
        mine = [i for i, r in enumerate(self.listed()) if 'Other' not in r]
        self.command('print-agents %d' % (mine[0] + 1))
        self.command('wait-agent working')
        self.command('key End')
        ticking('the working one again')
        self.command('agent-stop')
        self.command('wait-agent ready 10000')
        still('after the turn')

    def test_a_waiting_request_stops_the_tick(self):
        """While a request waits for the user nothing moves (the extension hides its spinner while a permission
        request is pending, index.js @5944989 `visiblyBusy && !permissionRequests.length`): the line keeps its
        room, blank; a running call's dot is still; the loop's passes are the idle count. The tick comes back
        once the answer lets the turn run on."""
        self.start()
        self.chat('hello')
        self.command('agent-prompt asklinger 30')
        self.command('wait-agent waiting')
        self.command('agent-test-tool a name=Bash second=sleep 9')    # a running call while the card waits
        time.sleep(0.3)
        self.command('print-frames')
        spin = self.spin()
        self.assertEqual((spin['shown'], spin['waiting'], spin['timeout'], spin['y'], spin['blink']),
                         ('1', '1', None, None, None), spin)
        time.sleep(3)                                # settled, as tools/perf-baseline.py measures it
        self.assertLessEqual(self.wakeups(10), 14)   # the idle count (13 in phase 2's baseline), no tick
        self.command('agent-card 1')                 # allowed: the turn works on
        self.command('wait-agent working')
        self.command('print-frames')
        spin = self.until(lambda: (lambda s: s if s['timeout'] is not None else None)(self.spin()), 'the tick again')
        self.assertEqual(spin['waiting'], '0', spin)
        self.assertGreaterEqual(self.wakeups(), 8)

    def test_no_spinner_without_verbs(self):
        """An extension's session that says it works (tests/ext-prompts.py's fixture): no spinner line, no tick,
        the loop's passes as without it."""
        prompts = importlib.util.spec_from_file_location('ext_prompts', ROOT / 'tests/ext-prompts.py')
        module = importlib.util.module_from_spec(prompts)
        import sys
        sys.path.insert(0, str(ROOT / 'tests'))
        prompts.loader.exec_module(module)
        case = module.Prompts('test_a_prompt_goes_to_the_open_session')
        case.setUp()
        try:
            out = case.editor(['print-agents 1', 'wait 300', 'print-agents', 'print-agent-spinner',
                               'print-loop-stats', 'wait 2000', 'print-loop-stats', 'print-agent-spinner'])
        finally:
            case.tearDown()
        spins = [spin_words(line) for line in out if line.startswith('shown=')]
        self.assertEqual(len(spins), 2, out)
        for spin in spins:
            self.assertEqual((spin['shown'], spin['timeout']), ('0', None), spin)
        loops = [int(line.split()[0].split('=')[1]) for line in out if line.startswith('passes=')]
        self.assertLessEqual(loops[1] - loops[0], 6, out)


def zone_env(zone):
    """os.environ with TZ=zone for Python's own local time (restore with the returned value)"""
    saved = os.environ.get('TZ')
    os.environ['TZ'] = zone
    time.tzset()
    return saved


def zone_back(saved):
    if saved is None:
        os.environ.pop('TZ', None)
    else:
        os.environ['TZ'] = saved
    time.tzset()


def ms(iso):
    return calendar.timegm(time.strptime(iso[:19], '%Y-%m-%dT%H:%M:%S')) * 1000


class TimeTest(ThreadCase):
    """Times on prompts and replies, local per timestamp (TZ set for each run), and the day lines."""

    def stamps(self, n):
        """print-agent-row N's time, tip and day ("-" as None, "_" back to spaces)"""
        first = self.command('print-agent-row %d' % n).splitlines()[0]
        words = dict(word.split('=', 1) for word in first.split(' '))
        return tuple(None if words[k] == '-' else words[k].replace('_', ' ') for k in ('time', 'tip', 'day'))

    def rows(self):
        """print-agent-rows: (kind, t, day) a row"""
        out = []
        for line in self.command('print-agent-rows').splitlines():
            if line[:1].isdigit():
                words = dict(w.split('=', 1) for w in line.split(' ')[2:] if '=' in w)
                out.append((line.split(' ')[1], words.get('t'), words.get('day')))
        return out

    def seeded(self, rows, zone, extra=''):
        self.write(rows)
        self.start(extra=extra, env={'TZ': zone})
        self.open_listed()
        self.command('print-frames')

    def zic(self, source):
        zic = shutil.which('zic') or ('/usr/sbin/zic' if Path('/usr/sbin/zic').exists() else None)
        if not zic:
            self.skipTest('no zic here')
        text = self.work / 'zones.txt'
        text.write_text(source, encoding='utf-8')
        made = subprocess.run([zic, '-b', 'slim', '-d', str(self.work / 'zones'), str(text)], capture_output=True)
        if made.returncode != 0:
            self.skipTest('zic failed: %r' % made.stderr)
        return self.work / 'zones'

    def test_iso_forms(self):
        forms = ['2026-11-22T10:00:00.000Z', '2026-11-22T10:00:00Z', '2026-11-22T12:30:00+02:30',
                 '2026-11-22T10:00:00.5Z', 'yesterday', '2026-13-01T00:00:00Z']
        self.seeded([('user', 'p%d' % i, f) for i, f in enumerate(forms)], 'UTC')
        got = [t for _, t, _ in self.rows()]
        base = ms('2026-11-22T10:00:00')
        self.assertEqual(got, [str(base), str(base), str(base), str(base + 500), '-', '-'])

    def test_clock_and_tip(self):
        if not Path('/usr/share/zoneinfo/America/Denver').exists():
            self.skipTest('no zone files here')
        self.seeded([('user', 'winter', '2026-01-15T22:45:07.000Z'), ('assistant', 'w', '2026-01-15T22:45:08.000Z'),
                     ('user', 'summer', '2026-07-15T21:45:07.000Z')], 'America/Denver')
        self.assertEqual(self.stamps(1), ('3:45 PM', '2026-01-15 15:45:07 MST', 'Thu, Jan 15'))
        self.assertEqual(self.stamps(2)[:2], ('3:45 PM', '2026-01-15 15:45:08 MST'))
        self.assertEqual(self.stamps(3), ('3:45 PM', '2026-07-15 15:45:07 MDT', 'Wed, Jul 15'))
        self.quit()
        if Path('/usr/share/zoneinfo/Asia/Kolkata').exists():
            self.seeded([('user', 'india', '2026-01-15T10:15:00Z')], 'Asia/Kolkata')
            self.assertEqual(self.stamps(1)[:2], ('3:45 PM', '2026-01-15 15:45:00 IST'))
            self.quit()
        zones = self.zic('Zone Test/Num 5:30 - <+0530>\nZone Test/Neg -7:00 - <-07>\n')
        self.seeded([('user', 'numeric', '2026-01-15T10:15:00Z')], str(zones / 'Test/Num'))
        self.assertEqual(self.stamps(1)[:2], ('3:45 PM', '2026-01-15 15:45:00 UTC+5:30'))
        self.quit()
        self.seeded([('user', 'numeric', '2026-01-15T22:45:00Z')], str(zones / 'Test/Neg'))
        self.assertEqual(self.stamps(1)[:2], ('3:45 PM', '2026-01-15 15:45:00 UTC-7'))
        self.quit()
        self.seeded([('user', 'utc', '2026-01-15T15:45:00Z')], 'UTC')
        self.assertEqual(self.stamps(1)[:2], ('3:45 PM', '2026-01-15 15:45:00 UTC'))

    def test_day_pill_on_the_first_row_and_at_midnight(self):
        if not Path('/usr/share/zoneinfo/America/Denver').exists():
            self.skipTest('no zone files here')
        self.seeded([('user', 'late', '2026-11-20T06:59:00Z'),        # Nov 19, 11:59 PM
                     ('assistant', 'after midnight', '2026-11-20T07:00:30Z'),   # Nov 20, 12:00 AM
                     ('user', 'morning', '2026-11-20T15:00:00Z')], 'America/Denver')
        self.assertEqual([d for _, _, d in self.rows()], ['1', '1', '0'])
        self.assertEqual(self.stamps(1), ('11:59 PM', '2026-11-19 23:59:00 MST', 'Thu, Nov 19'))
        self.assertEqual(self.stamps(2)[0], '12:00 AM')
        self.assertEqual(self.stamps(2)[2], 'Fri, Nov 20')
        self.assertIsNone(self.stamps(3)[2])

    def test_day_line_across_a_dst_change(self):
        """Each time by its own date's rule: a midnight after the spring change (MDT), and one in 2006, when that
        date was still standard time (the zone file's transitions, not this year's rule)."""
        if not Path('/usr/share/zoneinfo/America/Denver').exists():
            self.skipTest('no zone files here')
        self.seeded([('user', 'before', '2026-03-08T12:00:00Z'), ('assistant', 'after', '2026-03-09T06:30:00Z'),
                     ('user', 'old', '2006-03-19T12:00:00Z'), ('assistant', 'old late', '2006-03-20T06:30:00Z')],
                    'America/Denver')
        self.assertEqual([d for _, _, d in self.rows()], ['1', '1', '1', '0'])
        self.assertEqual(self.stamps(2)[:2], ('12:30 AM', '2026-03-09 00:30:00 MDT'))
        self.assertEqual(self.stamps(4)[:2], ('11:30 PM', '2006-03-19 23:30:00 MST'))
        # a rule-only zone file: past its transitions the POSIX rule, per date
        zones = self.zic('Zone Test/North -5:00 US E%sT\nRule US 2007 max - Mar Sun>=8 2:00 1:00 D\n'
                         'Rule US 2007 max - Nov Sun>=1 2:00 0 S\n')
        self.quit()
        self.seeded([('user', 'summer', '2031-07-01T03:30:00Z'), ('user', 'winter', '2031-12-01T04:30:00Z')],
                    str(zones / 'Test/North'))
        self.assertEqual(self.stamps(1), ('11:30 PM', '2031-06-30 23:30:00 EDT', 'Mon, Jun 30, 2031'))
        self.assertEqual(self.stamps(2), ('11:30 PM', '2031-11-30 23:30:00 EST', 'Sun, Nov 30, 2031'))

    def test_other_year_label(self):
        this = time.gmtime().tm_year
        self.seeded([('user', 'last year', '%d-06-10T12:00:00Z' % (this - 1)),
                     ('user', 'this year', '%d-06-10T12:00:00Z' % this)], 'UTC')
        saved = zone_env('UTC')
        try:
            last = time.strftime('%a, %b 10, ', time.gmtime(ms('%d-06-10T12:00:00' % (this - 1)) / 1000)) + str(this - 1)
            now = time.strftime('%a, %b 10', time.gmtime(ms('%d-06-10T12:00:00' % this) / 1000))
        finally:
            zone_back(saved)
        self.assertEqual(self.stamps(1)[2], last)
        self.assertEqual(self.stamps(2)[2], now)

    def test_no_pills_without_timestamps(self):
        rows = [('user', 'one', '2026-11-20T12:00:00Z'), ('assistant', 'two', '2026-11-20T12:00:01Z'),
                ('user', 'three', '2026-11-21T12:00:00Z')]
        self.seeded(rows, 'UTC')
        on = [int(self.row(n)['height']) for n in (1, 2, 3)]
        self.quit()
        self.seeded(rows, 'UTC', extra='[agents]\ntimestamps = false\n')
        self.assertEqual([self.stamps(n) for n in (1, 2, 3)], [(None, None, None)] * 3)
        off = [int(self.row(n)['height']) for n in (1, 2, 3)]
        self.assertGreater(on[0], off[0])            # a pill and a time line
        self.assertGreater(on[0], on[2] - 1)
        self.assertEqual(on[1], off[1])              # a reply's time is on its label line
        self.assertGreater(on[2], off[2])

    def test_a_prompt_has_its_time_line_and_a_reply_after_a_reply_none(self):
        rows = [('user', 'one', '2026-11-20T12:00:00Z'), ('assistant', 'two', '2026-11-20T12:00:01Z'),
                ('assistant', 'three', '2026-11-20T12:00:02Z'), ('user', 'four', '2026-11-20T12:05:00Z')]
        self.seeded(rows, 'UTC')
        self.assertEqual(self.stamps(1)[0], '12:00 PM')
        self.assertEqual(self.stamps(2)[0], '12:00 PM')
        self.assertIsNone(self.stamps(3)[0])         # a reply after a reply: no time
        self.assertEqual(self.stamps(4), ('12:05 PM', '2026-11-20 12:05:00 UTC', None))
        h1, h4 = int(self.row(1)['height']), int(self.row(4)['height'])
        self.assertGreater(h1, h4)                   # the first has the day pill too

    def test_a_reply_shows_its_time_once_whole(self):
        """The extension stamps a reply only once its message is complete (s4 @3697600: not while partial); its
        time sits on the label line, so the row's height does not change when it appears."""
        self.start(env={'TZ': 'UTC'})
        self.chat('hello')
        self.command('agent-prompt pause 3')
        self.until(lambda: self.thread()[-1].endswith('it is whole.'), 'the text streamed')
        n = self.engine()['rows']
        self.command('print-frames')
        self.assertIsNone(self.stamps(n)[0], 'streaming: no time')
        self.assertIsNotNone(self.stamps(n - 1)[0], 'its prompt has one')
        before = int(self.row(n)['height'])
        y = int(self.row(n)['y'])
        self.command('wait-agent ready 10000')
        self.command('print-frames')
        self.assertRegex(self.stamps(n)[0], r'^\d{1,2}:\d\d [AP]M$')
        self.assertEqual((int(self.row(n)['height']), int(self.row(n)['y'])), (before, y))

    def test_live_rows_get_the_clock(self):
        self.start(env={'TZ': 'UTC'})
        began = time.time() * 1000
        self.chat('hello')
        ended = time.time() * 1000
        stamped = [(k, t) for k, t, _ in self.rows() if k in ('user', 'agent')]
        self.assertTrue(stamped, self.rows())
        for kind, t in stamped:
            self.assertTrue(began - 2000 <= int(t) <= ended + 2000, (kind, t, began, ended))
        n = self.engine()['rows']
        clock = self.stamps(n - 1)[0]
        self.assertRegex(clock, r'^\d{1,2}:\d\d [AP]M$')

    def test_rate_band_still_formats(self):
        """Phase 2's reset texts go through the moved zone code (claude-controls.py has the zones)."""
        self.start(env={'FAKE_CLAUDE_RATE': 'weekly', 'TZ': 'UTC'})
        self.chat('hello')
        bands = self.command('print-agent-bands')
        self.assertRegex(bands, r'resets (at \d{1,2}:\d\d [AP]M|\w{3}, \w{3} \d{1,2}( at|, \d{4} at) \d{1,2}:\d\d [AP]M)')


# ---- focus view (task 9) -------------------------------------------------------------------------------------

def fold_word(line):
    """A print-agent-folds fold line as a dict: numbers as ints, "-" as None, run's "_" as spaces."""
    head, _, label = line.partition(' label=')
    words = head.split(' ')
    out = {'n': int(words[1]), 'label': label}
    first, last = words[2].split('-')
    out['first'], out['last'] = int(first), int(last)
    for word in words[3:]:
        key, value = word.split('=', 1)
        if key == 'run':
            out[key] = None if value == '-' else value.replace('_', ' ')
        else:
            out[key] = None if value == '-' else int(value)
    return out


class FoldCase(ThreadCase):
    """Conversations whose turns hold runs of calls and thinking; print-agent-folds read back."""

    def seed(self, lines, sid='s1'):
        """A Claude conversation file of these records (claude-transcript.py's makers), each stamped."""
        folder = self.work / '.claude/projects' / chat.slug(self.project)
        folder.mkdir(parents=True, exist_ok=True)
        out = []
        for i, line in enumerate(lines):
            line = dict(line, cwd=self.project.as_posix(), sessionId=sid,
                        timestamp='2026-11-23T%02d:%02d:%02d.000Z' % (i // 3600 % 24, i // 60 % 60, i % 60))
            out.append(json.dumps(line) + '\n')
        path = folder / (sid + '.jsonl')
        path.write_text(''.join(out), encoding='utf-8')
        return path

    def open_lines(self, lines, focus=True, extra=''):
        self.seed([tr.prompt('look')] + lines)
        self.start(extra=('[agents]\nfocus_view = true\n' if focus else '') + extra)
        self.open_listed()
        self.command('print-frames')

    def folds_head(self):
        line = self.command('print-agent-folds').splitlines()[0]
        return dict((w.split('=', 1)[0], None if w.split('=', 1)[1] == '-' else int(w.split('=', 1)[1]))
                    for w in line.split(' '))

    def folds(self):
        return [fold_word(line) for line in self.command('print-agent-folds').splitlines()[1:]]

    def heights(self):
        """print-agent-rows' h= of every row."""
        return [int(re.search(r' h=(\d+)', line).group(1)) for line in self.command('print-agent-rows').splitlines()
                if not line.startswith(' ')]

    def kinds(self):
        return [line.split(' ')[1] for line in self.command('print-agent-rows').splitlines()
                if not line.startswith(' ')]

    def drawn_rows(self):
        """The rows the last frame drew (print-agent-row's y is not -1)."""
        out = []
        e = self.engine()
        for n in range(e['first'], e['last'] + 1):
            if self.row(n + 1)['y'] != '-1':
                out.append(n)
        return out

    def fold_lines(self, n):
        """print-agent-row's fold and collapse lines of row n (from 0): {kind: (x, y, w, h, id)}."""
        out = {}
        for line in self.command('print-agent-row %d' % (n + 1)).splitlines()[1:]:
            m = re.match(r'(fold|collapse) (-?\d+),(-?\d+),(-?\d+),(-?\d+) (-?\d+)', line)
            if m:
                out[m.group(1)] = tuple(int(v) for v in m.group(2, 3, 4, 5, 6))
        return out

    def bash(self, tid, out='ok', error=None):
        return [tr.call(tid, 'Bash', {'command': 'ls ' + tid}), tr.result(tid, out, error)]


class FocusViewTest(FoldCase):
    """Focus view: a run of calls and thinking is one line with its counts; the line opens; what a closed fold
    hides is neither drawn, nor hit, nor reached by the keys, nor focused."""

    def test_a_run_is_one_line(self):
        self.open_lines(self.bash('a') + self.bash('b') + self.bash('c') + [tr.reply('done')])
        fold, = self.folds()
        self.assertEqual((fold['first'], fold['last'], fold['calls'], fold['failed'], fold['open'], fold['line']),
                         (1, 3, 3, 0, 0, 1), fold)
        self.assertEqual(fold['label'], '3 tool calls')
        h = self.heights()
        self.assertGreater(h[1], 0)
        self.assertEqual(h[2:4], [0, 0])
        self.assertEqual(self.drawn_rows(), [0, 1, 4])
        lines = self.fold_lines(1)
        self.assertIn('fold', lines)
        self.assertNotIn('collapse', lines)
        self.assertEqual(self.command('print-agent-row 3').split(' y=')[1].split(' ')[0], '-1')
        self.command('cmd agents_toggle_focus_view')
        self.assertEqual(self.folds_head()['focus'], 0)
        self.assertEqual(self.drawn_rows(), [0, 1, 2, 3, 4])
        self.assertEqual(self.fold_lines(1), {})
        self.assertEqual(self.folds()[0]['label'], '3 tool calls')     # kept with the setting off too

    def test_one_call_and_failures(self):
        self.open_lines(self.bash('a', 'no', True) + [tr.reply('one')] + self.bash('b') + self.bash('c', 'x', True))
        one, two = self.folds()
        self.assertEqual((one['label'], two['label']), ('1 tool call \u00b7 1 failed', '2 tool calls \u00b7 1 failed'))

    def test_failed_count_follows_a_late_result(self):
        path = None
        self.open_lines(self.bash('a') + [tr.call('b', 'Bash', {'command': 'ls b'})])
        fold, = self.folds()
        self.assertEqual((fold['calls'], fold['failed'], fold['label']), (2, 0, '2 tool calls'))
        with (self.work / '.claude/projects' / chat.slug(self.project) / 's1.jsonl').open('a') as f:
            f.write(json.dumps(dict(tr.result('b', 'boom', True), cwd=self.project.as_posix(), sessionId='s1')) + '\n')
        self.until(lambda: self.folds()[0]['failed'] == 1, 'the late result')
        self.assertEqual(self.folds()[0]['label'], '2 tool calls \u00b7 1 failed')
        self.command('agent-test-tool b state=ok')                   # a state that changes again
        self.assertEqual(self.folds()[0]['label'], '2 tool calls')

    def test_thinking_alone(self):
        self.open_lines([tr.thought('', 2400, 'updates'), tr.reply('one'),
                         tr.thought('', 300, 'updates'), tr.thought('', 1600, 'updates'), tr.reply('two'),
                         tr.thought('', None, kind='redacted_thinking'), tr.reply('three')])
        labels = [f['label'] for f in self.folds()]
        self.assertEqual(labels, ['Thought for 2s', 'Thought for 2s', 'Thinking'])
        self.assertEqual([f['thinks'] for f in self.folds()], [1, 2, 1])
        self.command('agent-test-row thinking ms=200 short')
        self.assertEqual(self.folds()[-1]['label'], 'Thought for 1s')   # at least 1 s

    def test_thinking_while_it_streams(self):
        self.start(extra='[agents]\nfocus_view = true\n')
        self.chat('hello')
        self.command('agent-prompt thinkslow 5000')
        self.until(lambda: self.folds() and self.folds()[-1]['run'] == 'Thinking\u2026', 'the live label', 15)
        self.assertEqual(self.folds()[-1]['label'], 'Thinking\u2026')
        self.command('wait-agent ready 20000')
        fold = self.folds()[-1]
        self.assertIsNone(fold['run'])
        self.assertRegex(fold['label'], r'^Thought for [4-6]s$')

    def test_hidden_steps(self):
        self.open_lines([tr.reply('one')])
        self.command('agent-test-row thinking ms=1000 hmm')
        self.command('agent-test-row meta notice=1 a notice')
        fold = self.folds()[-1]
        self.assertEqual((fold['thinks'], fold['other'], fold['label']), (1, 1, '2 hidden steps'))
        self.command('agent-test-row agent between')
        self.command('agent-test-row meta notice=1 alone')            # a notice outside a run: no fold
        self.assertEqual(len(self.folds()), 1)
        self.assertEqual(self.heights()[-1], 0)

    def test_running_labels(self):
        self.start(extra='[agents]\nfocus_view = true\n')
        self.chat('hello')
        self.command('agent-prompt linger 30')
        self.command('wait-agent working')
        self.command('agent-test-tool r1 name=Read second=a.txt state=ok ready=1 done=1')
        self.command('agent-test-tool r2 name=Bash second=ls ready=1')
        fold = self.folds()[-1]
        self.assertEqual((fold['run'], fold['label'], fold['calls']), ('Running Bash\u2026', '2 tool calls', 2))
        self.command('agent-stop')
        self.command('wait-agent ready 20000')
        fold = self.folds()[-1]
        self.assertEqual((fold['run'], fold['label']), (None, '2 tool calls \u00b7 1 failed'))   # stopped

    def test_a_permission_opens_its_fold_and_a_question_does_not(self):
        self.start(extra='[agents]\nfocus_view = true\n')
        self.command('agent-timing card=0')
        self.chat('hello')
        self.command('agent-prompt tool')
        self.command('wait-agent waiting 10000')
        fold = self.folds()[-1]
        self.assertEqual((fold['run'], fold['held'], fold['open']), ('Waiting for permission\u2026', 1, 0), fold)
        self.assertIn(fold['first'], self.drawn_rows())
        self.assertGreater(self.heights()[fold['first']], self.fold_lines(fold['first'])['fold'][3])
        self.command('agent-card 1')
        self.command('wait-agent ready 10000')
        fold = self.folds()[-1]
        self.assertEqual((fold['run'], fold['held'], fold['open']), (None, 0, 0), fold)
        self.command('agent-prompt ask')
        self.command('wait-agent waiting 10000')
        fold = self.folds()[-1]
        self.assertEqual((fold['run'], fold['held'], fold['open']), ('Waiting for your answer\u2026', 0, 0), fold)
        self.assertEqual(self.heights()[fold['first']], self.fold_lines(fold['first'])['fold'][3])

    def test_open_and_collapse(self):
        self.open_lines(self.bash('a') + self.bash('b') + self.bash('c') + [tr.reply('done')])
        closed = self.heights()[1]
        self.command('agent-fold-click 2')
        fold, = self.folds()
        self.assertEqual(fold['open'], 1)
        self.assertEqual(self.drawn_rows(), [0, 1, 2, 3, 4])
        self.assertIn('collapse', self.fold_lines(3))
        self.assertIn('fold', self.fold_lines(1))
        self.assertGreater(self.heights()[1], closed)
        self.command('agent-fold-click 4')                           # its Collapse line
        self.assertEqual(self.folds()[0]['open'], 0)
        self.assertEqual(self.drawn_rows(), [0, 1, 4])
        self.command('cmd focus_agents')                             # Enter on the fold's line
        self.command('key Up')
        self.assertEqual(self.engine()['focus'], 1)
        self.command('key Return')
        self.assertEqual(self.folds()[0]['open'], 1)
        self.command('key space')
        self.assertEqual(self.folds()[0]['open'], 0)

    def test_a_click_on_the_line_opens_it_and_hidden_rows_take_no_click(self):
        self.open_lines(self.bash('a', 'x' * 400) + self.bash('b', 'y' * 400) + [tr.reply('done')])
        x, y, w, h, ident = self.fold_lines(1)['fold']
        self.assertGreaterEqual(ident, 0x600000)
        tabs = self.command('print-tabs')
        self.command('click %d %d' % (x + w // 2, y + h // 2))
        self.command('print-frames')
        self.assertEqual(self.folds()[0]['open'], 1)
        self.command('click %d %d' % (x + w // 2, y + h // 2))
        self.command('print-frames')
        self.assertEqual(self.folds()[0]['open'], 0)
        for py in range(y + h + 1, y + h + 60, 8):                   # where the hidden rows were: nothing opens
            self.command('click %d %d' % (x + 10, py))
        self.command('print-frames')
        self.assertEqual(self.command('print-tabs'), tabs)

    def test_keys_never_reach_or_keep_a_hidden_row(self):
        self.open_lines(self.bash('a', 'x' * 400) + self.bash('b', 'y' * 400) + self.bash('c', 'z' * 400) +
                        [tr.reply('done')], focus=False)
        self.command('cmd focus_agents')
        self.command('key Up')
        self.command('key Up')
        self.assertEqual(self.engine()['focus'], 2)
        self.command('cmd agents_toggle_focus_view')                 # the focused row folds away: its line has it
        self.assertEqual(self.engine()['focus'], 1)
        self.command('key Down')
        self.assertNotIn(self.engine()['focus'], (2, 3))
        self.command('key Up')
        self.command('key Up')
        self.assertEqual(self.engine()['focus'], 1)
        self.command('agent-fold-click 2')
        self.command('key Down')
        self.command('key Down')
        self.assertEqual(self.engine()['focus'], 3)
        self.command('agent-fold-click 4')                           # closed under the focus: back to its line
        self.assertEqual(self.engine()['focus'], 1)

    def test_the_latest_todo_list_stays(self):
        first = tr.todo_call('t1', ('completed', 'Plan it'), ('in_progress', 'Do it'))
        last = tr.todo_call('t2', ('completed', 'Plan it'), ('completed', 'Do it'))
        self.open_lines([first, tr.result('t1', 'ok')] + self.bash('a') + [tr.reply('half')] +
                        self.bash('b') + [last, tr.result('t2', 'ok')] + self.bash('c') + [tr.reply('done')])
        one, two = self.folds()
        self.assertEqual((one['calls'], two['calls']), (2, 2))         # the latest list is not a call of its fold
        self.assertEqual(self.folds_head()['todo'], 5)
        h = self.heights()
        self.assertEqual(h[1:3], [h[1], 0])                          # the first list folds with its run
        self.assertGreater(h[5], 0)                                  # the latest shows, as a list alone
        self.command('cmd agents_toggle_focus_view')
        whole = self.heights()[5]
        self.command('cmd agents_toggle_focus_view')
        self.assertLess(h[5], whole)
        self.assertIn(5, self.drawn_rows())
        self.assertNotIn(6, self.drawn_rows())
        self.command('agent-fold-click 6')                           # open: still the list alone
        self.assertEqual(self.heights()[5], h[5])

    def test_notices_are_hidden(self):
        self.open_lines([tr.reply('one')])
        self.command('agent-test-row meta notice=1 a wrapped notice')
        self.command('agent-test-row agent two')
        n = self.engine()['rows']
        self.assertEqual(self.heights()[n - 2], 0)
        self.assertNotIn(n - 2, self.drawn_rows())
        self.command('cmd agents_toggle_focus_view')
        self.assertIn(n - 2, self.drawn_rows())

    def test_a_hidden_call_neither_joins_nor_ends_a_run(self):
        self.open_lines([tr.reply('one')])
        self.command('agent-test-tool a name=Bash state=ok ready=1')
        self.command('agent-test-tool h name=Hidden flags=1 state=ok ready=1')
        self.command('agent-test-tool b name=Bash state=ok ready=1')
        fold, = self.folds()
        self.assertEqual((fold['calls'], fold['label']), (2, '2 tool calls'))
        self.command('agent-test-row agent two')
        self.command('agent-test-tool h2 name=Hidden flags=1 state=ok ready=1')
        self.assertEqual(len(self.folds()), 1)

    def test_a_reply_between_calls_makes_two_folds(self):
        self.open_lines(self.bash('a') + [tr.reply('between')] + self.bash('b') + self.bash('c'))
        self.assertEqual([(f['first'], f['last'], f['calls']) for f in self.folds()], [(1, 1, 1), (3, 4, 2)])

    def test_toggle_by_key_menu_and_setting(self):
        self.start()
        self.chat('hello')
        state = lambda: self.folds_head()['focus']
        self.assertEqual(state(), 0)
        self.command('agent-focus editor')
        self.command('key ctrl+alt+f')
        self.assertEqual(state(), 1)
        self.command('cmd command_palette')
        self.command('type Toggle Focus View')
        self.assertIn('Agents: Toggle Focus View', self.command('print-palette'))
        self.command('key Return')
        self.assertEqual(state(), 0)
        self.command('agent-menu focus')
        menu = self.command('print-agent-menu')
        row = re.search(r'^row (\d+) Focus view\t([^\t]*)\t[^\t]*\t(\S+)', menu, re.M)
        self.assertIsNotNone(row, menu)
        self.assertEqual((row.group(2), row.group(3)), ("Show only your prompts and Claude's responses", 'switch'))
        self.command('agent-menu-pick %s' % row.group(1))
        self.assertEqual(state(), 1)
        menu = self.command('print-agent-menu')                     # the switch's new state reaches the rows
        self.assertRegex(menu, r'(?m)^row \d+ Focus view\t[^\t]*\t[^\t]*\ton,switch')
        self.command('key Escape')
        self.command('cmd settings')
        self.command('type focus view')
        self.assertEqual(self.command('print-settings').split(), ['agents.focus_view'])
        self.command('cmd close_tab')
        self.config.write_text(self.BASE + self.claude_section() + '[agents]\nfocus_view = false\n', encoding='utf-8')
        self.until(lambda: state() == 0, 'the reload', 10)

    def test_the_setting_is_saved(self):
        self.start()
        self.command('cmd agents_toggle_focus_view')
        self.quit()
        self.assertIn('focus_view = true', self.config.read_text(encoding='utf-8'))

    def test_a_when_clause(self):
        self.start(extra='[keys]\nctrl+shift+u = agents_toggle_focus_view when agentsFocus\n')
        self.chat('hello')
        self.command('agent-focus editor')
        self.command('key ctrl+shift+u')
        self.assertEqual(self.folds_head()['focus'], 0)
        self.command('cmd focus_agents')
        self.command('key ctrl+shift+u')
        self.assertEqual(self.folds_head()['focus'], 1)

    def test_folds_survive_a_truncate(self):
        self.open_lines([tr.reply('one')])
        for c in 'abcd':
            self.command('agent-test-tool %s name=Bash state=%s ready=1' % (c, 'failed' if c in 'bd' else 'ok'))
        self.command('agent-test-row agent two')
        for c in 'ef':
            self.command('agent-test-tool %s name=Bash state=ok ready=1' % c)
        self.assertEqual([(f['first'], f['last'], f['calls'], f['failed']) for f in self.folds()],
                         [(2, 5, 4, 2), (7, 8, 2, 0)])
        self.command('agent-test-truncate 4')                       # inside the first run
        self.assertEqual([(f['first'], f['last'], f['calls'], f['failed']) for f in self.folds()], [(2, 3, 2, 1)])
        self.assertEqual(self.folds()[0]['label'], '2 tool calls \u00b7 1 failed')
        self.command('agent-test-tool g name=Bash state=ok ready=1')      # the run goes on
        self.assertEqual([(f['first'], f['last'], f['calls']) for f in self.folds()], [(2, 4, 3)])
        self.command('agent-test-truncate 2')
        self.assertEqual(self.folds(), [])

    def test_both_sources_and_a_reread(self):
        self.start(extra='[agents]\nfocus_view = true\n')
        self.chat('hello')
        self.command('agent-prompt tools')
        self.command('wait-agent ready 20000')
        live = [(f['first'], f['last'], f['calls'], f['failed'], f['label']) for f in self.folds()]
        self.assertTrue(live, self.command('print-agent-folds'))
        self.command('agent-fold-click %d' % (self.folds()[0]['first'] + 1))
        self.assertEqual(self.folds()[0]['open'], 1)
        self.command('agent-release')
        self.command('wait-agent off')
        self.until_gone()
        reread = [(f['first'], f['last'], f['calls'], f['failed'], f['label']) for f in self.folds()]
        self.assertEqual(reread, live)
        self.assertEqual([f['open'] for f in self.folds()], [0] * len(live))   # open folds are not kept

    def test_fold_lines_fit(self):
        self.open_lines([tr.call('r', 'Bash', {'command': 'ls'})] + self.bash('a', 'no', True) + [tr.reply('one')])
        ui = int(re.search(r'points=(\d+)', self.command('print-agents-metrics')).group(1))
        blocks, current = [], None
        for line in self.command('print-agent-folds-fit').splitlines():
            if line.startswith('size='):
                current = (dict(w.split('=', 1) for w in line.split(' ')), [])
                blocks.append(current)
            else:
                current[1].append(line.strip())
        self.assertEqual(len(blocks), 25 * 34 * 3)           # its line, running, its Collapse line
        for head, parts in blocks:
            size, tw, h = int(head['size']), int(head['tw']), int(head['h'])
            boxes = []
            for p in parts:
                kind, box = p.split(' ')[0], p.split(' ')[-1]
                x, y, w, bh = (int(v) for v in box.split(','))
                self.assertGreaterEqual(x, 0, (head, p))
                self.assertLessEqual(x + w, tw, (head, p))
                self.assertLessEqual(y + bh, h, (head, p))
                if kind == 'button':
                    self.assertGreaterEqual(bh, tr.mi(16, size, ui) - 1, (head, p))
                else:
                    boxes.append((kind, x, y, w, bh))
            for i, a in enumerate(boxes):
                for b in boxes[i + 1:]:
                    overlap = (a[1] < b[1] + b[3] and b[1] < a[1] + a[3] and a[2] < b[2] + b[4] and
                               b[2] < a[2] + a[4] and a[3] and b[3])
                    self.assertFalse(overlap, (head, a, b))


class FocusSpeedTest(FoldCase):
    """A fold's line costs nothing that grows with its run or with the conversation."""

    def test_a_fold_of_5000_calls_walks_only_the_view(self):
        self.open_lines([tr.reply('one')])
        began = time.monotonic()
        self.command('agent-test-tool c name=Bash second=ls state=ok ready=1 repeat=5000')
        made = time.monotonic() - began
        self.command('agent-test-row agent done')
        fold, = self.folds()
        self.assertEqual((fold['calls'], fold['last'] - fold['first']), (5000, 4999), fold)
        e = self.engine()
        self.assert_walked(e, 'the end, the fold closed')
        self.assertIn(fold['first'], self.drawn_rows())
        self.command('agent-fold-click %d' % (fold['first'] + 1))
        e = self.engine()
        self.assert_walked(e, 'the end, the fold open')
        self.command('key Home')
        self.command('cmd focus_agents')
        self.command('key Home')
        self.assert_walked(self.engine(), 'the top, open')
        self.scrollbar(SCROLLBAR[1])
        self.assert_walked(self.engine(), 'the middle of the open fold')
        self.command('agent-fold-click %d' % (fold['first'] + 1))
        self.assert_walked(self.engine(), 'closed over the view')
        self.wheel(-300)
        self.assert_walked(self.engine(), 'a wheel step')
        for how in ('cmd agents_toggle_focus_view', 'cmd agents_toggle_focus_view'):
            self.command(how)
            self.assert_walked(self.engine(), how)
        print('\n5000 calls made in %.2f s' % made)

    def test_100k_rows_with_folds(self):
        lines = [tr.prompt('look')]
        for i in range(20000):                       # 100,000 rows: a prompt, three calls, a reply a turn
            lines.append(tr.prompt('step %d' % i))
            for k in range(3):
                lines.append(tr.call('t%d-%d' % (i, k), 'Bash', {'command': 'ls'}))
                lines.append(tr.result('t%d-%d' % (i, k), 'out'))
            lines.append(tr.reply('reply %d' % i))
        self.seed(lines)
        self.start(extra='[agents]\nfocus_view = true\n')
        began = time.monotonic()
        self.open_listed()
        self.command('print-frames')
        opened = time.monotonic() - began
        e = self.engine()
        self.assertEqual((e['rows'], e['folds']), (100001, 20000), e)
        self.assert_walked(e, 'opened')
        steps = []
        for _ in range(5):
            began = time.monotonic()
            self.wheel(-600)
            steps.append(time.monotonic() - began)
            self.assert_walked(self.engine(), 'a wheel step')
        self.scrollbar(SCROLLBAR[1])
        toggles = []
        for _ in range(4):
            began = time.monotonic()
            self.command('cmd agents_toggle_focus_view')
            toggles.append(time.monotonic() - began)
            self.assert_walked(self.engine(), 'a toggle')
        frame = []
        for _ in range(5):
            began = time.monotonic()
            self.command('print-frames')
            frame.append(time.monotonic() - began)
        print('\n100,001 rows, 20,000 folds: open %.2f s, wheel step %.1f ms, toggle %.1f ms, a frame %.1f ms'
              % (opened, 1000 * min(steps), 1000 * min(toggles), 1000 * min(frame)))
        self.assertLess(opened, 20)
        self.assertLess(min(toggles), 1)


if __name__ == '__main__':
    unittest.main()
