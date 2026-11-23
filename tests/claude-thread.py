#!/usr/bin/env python3
"""The agents panel's thread engine (phase 3): heights kept per 64 rows so that a frame asks only the rows in
view (print-agent-thread's walked), the view kept as a row and an offset through every height change and a
reread of the conversation's file, the thread's keys. It imports tests/claude-chat.py for its cases: every
rhun gets its own HOME and XDG folders, an environment without CLAUDE* or ANTHROPIC* variables, and a
config whose [claude] section starts the fake (tests/scripts/fake-claude.py); conversations are seeded as
files or made with the test seam (agent-test-row), never with the real CLI. Nothing here writes the user's
own Claude Code settings."""
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
        for role, text in rows:
            if role == 'user':
                lines.append({'type': 'user', 'message': {'role': 'user', 'content': text}, 'cwd': cwd,
                              'sessionId': sid})
            elif role == 'tool':
                lines.append({'type': 'assistant', 'message': {'role': 'assistant', 'content': [
                    {'type': 'tool_use', 'id': text, 'name': 'Bash', 'input': {'command': 'ls ' + text}}]}})
            else:
                lines.append({'type': 'assistant', 'message': {'role': 'assistant',
                                                               'content': [{'type': 'text', 'text': text}]}})
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
            self.command('resize %dx800' % width)
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
        self.command('resize 1100x800')
        narrow = parses()
        self.command('resize 1280x800')
        self.assertEqual(parses(), narrow, 'a width change and back: nothing parsed again')
        self.command('resize 1100x800')
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
        self.command('resize 1100x800')
        self.assertEqual(self.top_row()[0], first, 'width')
        self.command('cmd agents_font_increase')
        self.command('print-frames')
        self.assertEqual(self.top_row()[0], first, 'font')
        self.command('cmd agents_font_reset')
        self.command('resize 1280x800')
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
        self.command('resize 1100x800')
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


if __name__ == '__main__':
    unittest.main()
