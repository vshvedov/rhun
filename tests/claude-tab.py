#!/usr/bin/env python3
"""A conversation in an editor tab (phase 4 task 13; open point 7's one view): Open in New Tab and Open in Side
Panel, the tab taking and giving back the view, Agents: Open and New Conversation by [agents] location, the
tab's label and its dots, the status bar item, the session file and Reopen Closed Tab. Against the fake CLI,
over the control socket, with claude-chat.py's harness (every rhun gets its own HOME and XDG folders)."""
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


class TabCase(chat.DrivenCase):
    def tabs(self):
        """print-agent-tabs: the conversation tabs as dicts, the status line, the location line."""
        out = self.command('print-agent-tabs').splitlines()
        tabs = []
        for line in out:
            if line.startswith('tab '):
                fields = dict(f.split('=', 1) for f in line.split(' ')[2:])
                fields['index'] = int(line.split(' ')[1])
                tabs.append(fields)
        status = next(l for l in out if l.startswith('status='))
        where = next(l for l in out if l.startswith('location='))
        return tabs, status, where

    def hosting(self):
        return self.tabs()[2].endswith('hosting=1')

    def to_tab(self):
        """A conversation of the fake ("hello" answered), moved to a tab."""
        self.chat('hello')
        self.command('cmd agents_open_tab')

    def file_tab(self, name='a.txt'):
        path = self.project / name
        path.write_text('text\n', encoding='utf-8')
        self.command('open ' + str(path))
        return path

    def config_text(self):
        return self.config.read_text(encoding='utf-8')


class OpenInTabTest(TabCase):
    def test_open_in_new_tab_moves_the_conversation(self):
        self.start()
        self.to_tab()
        tabs, _, where = self.tabs()
        self.assertEqual(len(tabs), 1, tabs)
        self.assertEqual((tabs[0]['host'], tabs[0]['active'], tabs[0]['dot']), ('1', '1', 'none'))
        self.assertEqual(tabs[0]['label'], 'New_conversation')
        self.assertEqual(tabs[0]['file'], self.sid() + '.jsonl')
        self.assertEqual(where, 'location=tab hosting=1')
        self.assertIn('focus=1', self.command('print-agent-input'))     # its box has the keys
        self.command('agent-prompt more')                                 # the view is the tab's: it sends
        self.command('wait-agent ready 10000')
        self.assertEqual([r.split(' ', 1)[1] for r in self.thread()], ['hello', 'ok: hello', 'more', 'ok: more'])
        self.assertEqual(len(self.starts()), 1)                           # the same program
        self.quit()
        self.assertIn('location = tab', chat.section(self.config_text(), 'agents'))

    def test_open_in_new_tab_with_nothing_open_is_a_new_conversation(self):
        self.start()
        self.command('cmd agents_open_tab')
        tabs, _, _ = self.tabs()
        self.assertEqual([(t['label'], t['host'], t['file']) for t in tabs], [('Claude_Code', '1', '-')])
        self.assertIn(' new=claude ', self.command('print-agent-input'))
        self.command('agent-prompt hi')                                   # the draft sends: the tab follows it
        self.command('wait-agent ready 10000')
        tabs, _, _ = self.tabs()
        self.assertEqual(tabs[0]['file'], self.sid() + '.jsonl')
        self.assertEqual(tabs[0]['label'], 'New_conversation')
        self.assertEqual(self.thread()[-2:], ['user hi', chat.REPLY + 'ok: hi'])

    def test_open_in_side_panel_closes_the_tab(self):
        self.start()
        self.to_tab()
        self.command('cmd agents_open_panel')
        tabs, _, where = self.tabs()
        self.assertEqual(tabs, [])
        self.assertEqual(where, 'location=panel hosting=0')
        self.assertEqual([r.split(' ', 1)[1] for r in self.thread()], ['hello', 'ok: hello'])
        self.assertIn('state=ready pid=1', self.live())                    # nothing stopped
        self.command('agent-prompt again')
        self.command('wait-agent ready 10000')
        self.assertEqual(self.thread()[-1], 'agent ok: again')

    def test_open_in_new_tab_from_a_tab_is_a_new_conversation(self):
        self.start()
        self.to_tab()
        self.file_tab()
        self.command('cmd agents_open_panel')       # (no conversation tab is active: the panel, nothing closes)
        self.assertEqual(len(self.tabs()[0]), 1)
        self.command('print-agents 1')              # the panel's list opens it: its tab comes forward
        tabs, _, _ = self.tabs()
        self.assertEqual((tabs[0]['active'], tabs[0]['host']), ('1', '1'))
        self.command('cmd agents_open_tab')         # the view is a tab's already: a new conversation's tab
        tabs, _, _ = self.tabs()
        self.assertEqual([(t['label'], t['host'], t['active']) for t in tabs],
                         [('New_conversation', '0', '0'), ('Claude_Code', '1', '1')])


class ViewTest(TabCase):
    def test_another_tab_gives_the_view_back_and_takes_it_again(self):
        self.start()
        self.to_tab()
        self.file_tab()
        tabs, _, _ = self.tabs()
        self.assertEqual((tabs[0]['active'], tabs[0]['host']), ('0', '0'))
        self.assertEqual(self.thread(), [])         # the panel shows its list
        self.command('cmd prev_tab')
        tabs, _, _ = self.tabs()
        self.assertEqual((tabs[0]['active'], tabs[0]['host']), ('1', '1'))
        self.assertEqual([r.split(' ', 1)[1] for r in self.thread()], ['hello', 'ok: hello'])
        self.assertIn('focus=1', self.command('print-agent-input'))

    def test_the_panel_opening_another_takes_the_view_and_a_press_takes_it_back(self):
        self.seed('s1')
        self.start()
        self.to_tab()
        self.command('wait-agents')
        rows = [l for l in self.command('print-agents').splitlines() if l.startswith('Claude')]
        self.assertEqual(len(rows), 2, rows)
        seeded = next(i for i, r in enumerate(rows) if 'New conversation' not in r)
        self.command(f'print-agents {seeded + 1}')
        tabs, _, where = self.tabs()
        self.assertEqual((tabs[0]['active'], tabs[0]['host']), ('1', '0'))
        self.assertTrue(where.endswith('hosting=0'))
        self.assertNotIn('user hello', self.thread())
        self.command('click 300 400')               # a press in the tab: the view comes back to it
        tabs, _, _ = self.tabs()
        self.assertEqual(tabs[0]['host'], '1')
        self.assertIn('user hello', self.thread())

    def test_closing_the_tab_gives_the_view_back(self):
        self.start()
        self.to_tab()
        self.command('cmd close_tab')
        tabs, _, where = self.tabs()
        self.assertEqual(tabs, [])
        self.assertTrue(where.endswith('hosting=0'))
        self.assertEqual(self.thread(), [])
        listed = [l for l in self.command('print-agents').splitlines() if l.startswith('Claude')]
        self.assertEqual(len(listed), 1, listed)
        self.command('print-agents 1')              # its program still runs
        self.assertIn('state=ready pid=1', self.live())

    def test_escape_in_a_tab_keeps_the_conversation(self):
        self.start()
        self.to_tab()
        self.command('agent-focus panel')
        self.command('key Escape')
        self.command('key Escape')
        self.assertTrue(self.hosting())
        self.assertEqual([r.split(' ', 1)[1] for r in self.thread()], ['hello', 'ok: hello'])

    def test_the_header_has_no_back_in_a_tab(self):
        self.start()
        self.to_tab()
        self.command('click 70 96')                 # where Back is in the panel's header
        self.assertTrue(self.hosting())
        self.assertEqual(len(self.thread()), 2)

    def test_active_tab_clause(self):
        self.start(extra='[keys]\nctrl+alt+y = agents_open_panel when activeTab == agent\n')
        self.to_tab()
        self.file_tab()
        self.command('key ctrl+alt+y')              # a file is active: the clause is false
        self.assertEqual(len(self.tabs()[0]), 1)
        self.command('cmd prev_tab')
        self.command('key ctrl+alt+y')
        self.assertEqual(self.tabs()[0], [])


class LocationTest(TabCase):
    def test_agents_open_follows_location(self):
        self.start()
        self.command('cmd agents_open')              # panel (the default): no tab
        self.assertEqual(self.tabs()[0], [])
        self.stop()
        self.start(extra='[agents]\nlocation = tab\n')
        self.command('cmd agents_open')              # tab, none yet: a new conversation in a tab
        tabs, _, _ = self.tabs()
        self.assertEqual([t['label'] for t in tabs], ['Claude_Code'])
        self.file_tab()
        self.command('cmd agents_open')              # the one there is comes forward
        tabs, _, _ = self.tabs()
        self.assertEqual([(t['active'], t['host']) for t in tabs], [('1', '1')])

    def test_new_conversation_in_the_view_with_the_keys(self):
        self.start()
        self.to_tab()
        self.command('cmd agents_new_conversation')  # the tab hosts: the new draft is the tab's
        tabs, _, _ = self.tabs()
        self.assertEqual([(t['label'], t['file']) for t in tabs], [('Claude_Code', '-')])
        self.assertIn(' new=claude ', self.command('print-agent-input'))
        self.file_tab()
        self.command('cmd agents_open_panel')        # (back to the panel's location)
        self.command('cmd agents_new_conversation')  # panel: no new tab
        self.assertEqual(len(self.tabs()[0]), 1)
        self.assertIn(' new=claude ', self.command('print-agent-input'))

    def test_location_follows_the_users_last_choice(self):
        self.start()
        self.to_tab()
        self.assertTrue(self.tabs()[2].startswith('location=tab'))
        self.command('cmd agents_open_panel')
        self.assertTrue(self.tabs()[2].startswith('location=panel'))
        self.quit()
        self.assertNotIn('location = tab', chat.section(self.config_text(), 'agents'))


class LabelTest(TabCase):
    def test_the_label_is_cut_at_24_characters(self):
        path = self.seed('s1')
        title = 'A title that is much longer than the tab can show'
        with path.open('a', encoding='utf-8') as f:
            f.write(json.dumps({'type': 'custom-title', 'customTitle': title, 'sessionId': 's1'}) + '\n')
        self.start()
        self.open_listed()
        self.command('cmd agents_open_tab')
        tabs, _, _ = self.tabs()
        self.assertEqual(tabs[0]['label'], (title[:24] + '…').replace(' ', '_'))
        self.assertEqual(len(self.starts()), 0)      # a reader starts nothing

    def test_a_turn_ended_behind_another_tab_is_unseen_until_shown(self):
        self.start()
        self.to_tab()
        self.command('agent-prompt linger 1')
        self.file_tab()
        self.assertEqual(self.tabs()[0][0]['dot'], 'none')       # still working
        self.until(lambda: self.tabs()[0][0]['dot'] == 'unseen', 'the turn ended unseen')
        self.command('cmd prev_tab')
        self.assertEqual(self.tabs()[0][0]['dot'], 'none')

    def test_a_turn_ended_in_view_is_seen(self):
        self.start()
        self.to_tab()
        self.command('agent-prompt again')
        self.command('wait-agent ready 10000')
        self.assertEqual(self.tabs()[0][0]['dot'], 'none')

    def test_a_card_waiting_shows_on_the_tab_and_the_status_item(self):
        self.start()
        self.to_tab()
        self.command('agent-prompt tool')
        self.command('wait-agent waiting 10000')
        tabs, status, _ = self.tabs()
        self.assertEqual(tabs[0]['dot'], 'wait')
        self.assertTrue(status.endswith(' dot=1'), status)
        self.file_tab()
        self.assertEqual(self.tabs()[0][0]['dot'], 'wait')
        self.command('cmd prev_tab')
        self.command('agent-card 1')
        self.command('wait-agent ready 10000')
        tabs, status, _ = self.tabs()
        self.assertEqual(tabs[0]['dot'], 'none')
        self.assertTrue(status.endswith(' dot=0'), status)


class StatusTest(TabCase):
    def test_the_status_item(self):
        self.start()
        _, status, _ = self.tabs()
        self.assertEqual(status, 'status=Claude Code tip=Open_Claude Code dot=0')

    def test_no_status_item_with_the_chat_off(self):
        self.start(claude=self.claude_section('chat = false\n'))
        _, status, _ = self.tabs()
        self.assertEqual(status, 'status=none')

    def test_a_click_on_the_item_opens(self):
        self.start(extra='[agents]\nlocation = tab\n')
        shot = self.work / 'bar.ppm'
        self.command(f'shot {shot}')
        x = self.item_x(shot)
        self.command(f'click {x} 790')
        tabs, _, _ = self.tabs()
        self.assertEqual(len(tabs), 1)

    def item_x(self, shot):
        """The middle of the status bar's rightmost item that is not the background (the agents' item)."""
        data = shot.read_bytes()
        header, w, h = data.split(b'\n', 3)[:3], None, None
        parts = data.split(b'\n', 3)
        w, h = map(int, parts[1].split())
        px = parts[3]
        y = 787
        row = px[(y * w) * 3:(y * w + w) * 3]
        bg = row[(w - 2) * 3:(w - 1) * 3]
        xs = [x for x in range(w - 40, w // 2, -1) if row[x * 3:x * 3 + 3] != bg]
        self.assertTrue(xs, 'no status item drawn')
        return xs[0] - 20


class SessionTest(TabCase):
    BASE = chat.ChatCase.BASE.replace('restore_session = false', 'restore_session = true')

    def test_tabs_are_in_the_session_file_and_come_back_without_a_process(self):
        self.start()
        self.to_tab()
        sid = self.sid()
        self.file_tab()
        self.command('cmd prev_tab')
        self.quit()
        starts = len(self.starts())
        self.start()
        self.command('wait-agents')
        tabs, _, _ = self.tabs()
        self.assertEqual([(t['file'], t['active']) for t in tabs], [(sid + '.jsonl', '1')])
        self.until(lambda: self.tabs()[0][0]['host'] == '1' and self.thread(), 'the conversation in its tab')
        self.assertEqual([r.split(' ', 1)[1] for r in self.thread()][:2], ['hello', 'ok: hello'])
        self.assertEqual(len(self.starts()), starts)     # nothing started
        self.assertIn('a.txt', self.command('print-tabs'))

    def test_reopen_closed_tab_brings_a_conversation_back(self):
        self.start()
        self.to_tab()
        sid = self.sid()
        self.command('cmd close_tab')
        self.assertEqual(self.tabs()[0], [])
        self.command('cmd reopen_closed_tab')
        tabs, _, _ = self.tabs()
        self.assertEqual([(t['file'], t['host'], t['active']) for t in tabs], [(sid + '.jsonl', '1', '1')])
        self.assertEqual([r.split(' ', 1)[1] for r in self.thread()], ['hello', 'ok: hello'])


class LinkTest(TabCase):
    def back(self):
        self.command(f'click {chat.BACK[0]} {chat.BACK[1]}')

    def test_the_link_opens_a_conversation_and_fills_the_box_without_sending(self):
        self.start()
        self.chat('hello')
        sid = self.sid()
        self.back()
        self.assertEqual(self.thread(), [])
        sent = len(self.stdin())
        self.command(f'open rhun://claude/open?session={sid}&prompt=fix%20the+bug%21')
        self.assertEqual([r.split(' ', 1)[1] for r in self.thread()], ['hello', 'ok: hello'])
        self.assertTrue(self.command('print-agent-input').startswith('input=fix the bug! focus=1 '))
        self.assertEqual(self.tabs()[0], [])        # [agents] location = panel
        time.sleep(0.3)
        self.assertEqual(len(self.stdin()), sent)    # nothing sent

    def test_the_link_opens_in_a_tab_by_location(self):
        self.start(extra='[agents]\nlocation = tab\n')
        self.chat('hello')
        sid = self.sid()
        self.back()
        self.command(f'open rhun://claude/open?prompt=more&session={sid}')
        tabs, _, _ = self.tabs()
        self.assertEqual([(t['file'], t['host']) for t in tabs], [(sid + '.jsonl', '1')])
        self.assertTrue(self.command('print-agent-input').startswith('input=more '))

    def test_the_link_with_an_unknown_id_is_a_new_conversation(self):
        self.start()
        self.command('open rhun://claude/open?session=0b8d6f2e-1111-4222-8333-444455556666&prompt=hi')
        # (an id waits for discovery's list, then the link applies)
        self.until(lambda: self.command('print-agent-input').startswith('input=hi focus=1 new=claude '),
                   self.command('print-agent-input'))
        self.assertEqual(self.starts(), [])

    def test_the_link_to_a_shown_conversation_keeps_its_box(self):
        self.start()
        self.chat('hello')
        sid = self.sid()
        self.command('agent-type mine')
        self.command(f'open rhun://claude/open?session={sid}&prompt=theirs')
        self.assertTrue(self.command('print-agent-input').startswith('input=mine '))
        self.assertIn('Session is already open. Your prompt was not applied \u2014 enter it manually.',
                      self.command('print-toast'))

    def test_another_name_is_not_an_agents_link(self):
        self.start()
        self.command('open rhun://nobody/open?prompt=hi')
        self.assertTrue(self.command('print-agent-input').startswith('input= '))

    def test_a_link_in_a_reply_does_nothing(self):
        """The fake answers "ok: " and the prompt: a reply whose link is rhun://claude/open. A click on it in
        the tab opens nothing and fills no box; the same link from outside does (so the test can fail)."""
        self.start()
        self.chat('[x](rhun://claude/open?prompt=hi)')
        self.command('cmd agents_open_tab')
        self.command('cmd agents_open_tab')          # (a second tab, a draft: so a link that worked would show)
        self.command('cmd prev_tab')
        shot = self.work / 'reply.ppm'
        self.command(f'shot {shot}')
        x, y = self.link_at(shot)
        self.command(f'click {x} {y}')
        self.command(f'click {x} {y}')
        time.sleep(0.2)
        self.assertEqual(len(self.tabs()[0]), 2)
        self.assertTrue(self.command('print-agent-input').startswith('input= '))
        self.assertNotIn('toast=Session', self.command('print-toast'))
        self.command('open rhun://claude/open?prompt=hi')
        self.assertTrue(self.command('print-agent-input').startswith('input=hi '))

    def link_at(self, shot):
        """The first pixel of the reply's link (the accent's blue) in the conversation's column."""
        parts = shot.read_bytes().split(b'\n', 3)
        w, h = map(int, parts[1].split())
        px = parts[3]
        for y in range(240, 330):
            for x in range(60, 400):
                r, g, b = px[(y * w + x) * 3:(y * w + x) * 3 + 3]
                if b > 180 and b > r + 50 and g > 100:
                    return x + 1, y + 1
        self.fail('no link drawn')


class WindowTest(TabCase):
    def test_open_in_new_window(self):
        log = self.work / 'new-window.log'
        script = self.work / 'new-window.sh'
        script.write_text(f'#!/bin/sh\nprintf "%s\\n" "$@" > {log}\n', encoding='utf-8')
        script.chmod(0o755)
        self.start(env={'RHUN_NEW_WINDOW': str(script)})
        self.chat('hello')
        sid = self.sid()
        self.command('cmd agents_open_window')
        self.until(lambda: log.exists() and log.read_text().strip(), 'the new window started')
        self.assertEqual(log.read_text().splitlines(), [str(self.project), f'rhun://claude/open?session={sid}'])
        self.assertIn('state=ready pid=1', self.live())      # nothing closed here


class IdleTest(TabCase):
    def passes(self, seconds=3):
        def count():
            return int(self.command('print-loop-stats').split()[0].split('=')[1])
        before = count()
        time.sleep(seconds)
        return count() - before - 1

    def test_idle_with_a_tab_and_the_item(self):
        """A conversation shown in a tab and the status item add no wake-up to the panel's."""
        self.start()
        self.chat('hello')
        time.sleep(1.5)
        panel = self.passes()
        self.command('cmd agents_open_tab')
        time.sleep(1.5)
        tab = self.passes()
        self.assertLessEqual(tab, panel + 1, (tab, panel))


if __name__ == '__main__':
    unittest.main()
