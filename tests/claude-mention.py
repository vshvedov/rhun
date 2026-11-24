#!/usr/bin/env python3
"""Mentions and the editor's context in the agents panel (phase 4, tasks 7 and 8): the "@" menu over the
project's files, folders and terminals (filelist.s, agentpop.s), the mention text (agentmention.s: the bundle's
rules, tests/mention_test.s checks them against the bundle itself), the chips a mention makes in the box and in a
sent prompt, a terminal's text at Send; the selection chip and what goes with a message (agentctx.s), the
commands that mention. Against the fake CLI (tests/scripts/fake-claude.py), over the control socket; it imports
tests/claude-chat.py for its cases: every rhun gets its own HOME and XDG folders, an environment without CLAUDE*
or ANTHROPIC* variables, and a config whose [claude] section starts the fake. Nothing here writes the user's own
Claude Code settings: the fake's config folder is the test's HOME. What is sent is read from the fake's stdin."""
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location('claude_chat', ROOT / 'tests/claude-chat.py')
chat = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(chat)

GIT_ON = '[git]\nenabled = true\n'


def git(cwd, *args):
    subprocess.run(['git', '-c', 'user.name=t', '-c', 'user.email=t@t', *args], cwd=cwd, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   env=dict(os.environ, GIT_CONFIG_NOSYSTEM='1', HOME=str(cwd)))


class MentionCase(chat.DrivenCase):
    """The box (print-agent-input), the popup (print-agent-menu), the file list (print-filelist)."""

    def put(self, name, data=''):
        path = self.project / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(data, encoding='utf-8')
        return path

    def box(self):
        return re.match(r'input=(.*?) focus=', self.command('print-agent-input'), re.S).group(1)

    def menu(self):
        return self.command('print-agent-menu')

    def head(self):
        first = self.menu().splitlines()[0]
        return dict(w.split('=', 1) for w in first.split(' ') if '=' in w)

    def rows(self):
        """The menu's rows: (label, desc, trail, flags)."""
        out = []
        for line in self.menu().splitlines():
            m = re.match(r'row \d+ (.*)$', line)
            if m:
                out.append(tuple(m.group(1).split('\t')))
        return out

    def labels(self):
        return [r[0] for r in self.rows()]

    def filelist(self):
        return dict(w.split('=', 1) for w in self.command('print-filelist').split())

    def toast(self):
        return self.command('print-toast').strip()

    def users(self):
        return [m for m in self.stdin() if m.get('type') == 'user']

    def blocks(self):
        return self.users()[-1]['message']['content']

    def ready(self, ms=20000):
        self.command(f'wait-agent ready {ms}')

    def type(self, text):
        self.command('agent-type ' + text)

    def settle(self):
        """The list made and the query matched (a few frames)."""
        self.command('filelist-wait 10000')
        for _ in range(40):
            if 'popup=mention' not in self.menu() or self.done():
                break
            self.command('frame')

    def done(self):
        fl = self.filelist()
        return fl['state'] == 'ready'

    def open_box(self, extra='', claude=None, env=None):
        self.start(claude=claude, extra=extra, env=env)
        self.command('agent-new claude')


class MentionTest(MentionCase):
    """The "@" menu (UI 1.19, 7.3), the mention text (1.20), the chips (3.2), terminals (1.21)."""

    def test_no_list_before_the_first_at(self):
        self.put('a.txt', 'a\n')
        self.start()
        self.chat('hello')
        self.assertEqual(self.filelist()['state'], 'none')
        self.assertEqual(self.filelist()['runs'], '0')
        self.type('see @')
        self.settle()
        self.assertEqual(self.filelist()['runs'], '1')

    def test_at_opens_the_menu_with_files_and_folders(self):
        self.put('src/main.c')
        self.put('README.md')
        self.open_box()
        self.type('@')
        self.settle()
        self.assertEqual(self.head()['popup'], 'mention')
        rows = self.rows()
        self.assertIn(('README.md', '-', '-', 'file'), rows)
        self.assertIn(('src/', '-', '-', 'folder'), rows)
        self.assertNotIn('main.c', self.labels())     # an empty query: the root's entries only

    def test_a_pick_puts_the_mention_and_a_space(self):
        self.put('src/main.c')
        self.open_box()
        self.type('look at @mai')
        self.settle()
        self.assertEqual(self.rows()[0], ('main.c', 'src', '-', 'file'))
        self.command('key Return')
        self.assertEqual(self.box(), 'look at @src/main.c ')
        self.assertEqual(self.head()['popup'], 'none')

    def test_exact_names_first_tests_last(self):
        for name in ('src/utility.c', 'test/util.c', 'lib/util.h', 'src/util.c', 'docs/futil.md'):
            self.put(name)
        self.open_box()
        self.type('@util')
        self.settle()
        rows = [r for r in self.rows() if r[3] == 'file']
        names = [(r[1] + '/' + r[0]) for r in rows]
        self.assertEqual(sorted(names[:2]), ['lib/util.h', 'src/util.c'])
        self.assertEqual(names[2], 'test/util.c')
        self.assertEqual(set(names[3:]), {'src/utility.c', 'docs/futil.md'})

    def test_a_folder_prefix_lists_its_entries(self):
        for name in ('src/b.c', 'src/a.c', 'src/sub/deep.c', 'other.c'):
            self.put(name)
        self.open_box()
        self.type('@src/')
        self.settle()
        self.assertEqual(self.labels(), ['a.c', 'b.c', 'src/sub/'])
        self.type('d')                                  # "src/d": fuzzy under src/
        self.settle()
        self.assertEqual(self.labels(), ['deep.c'])

    def test_gitignore_and_the_setting(self):
        self.put('.gitignore', 'out/\n')
        self.put('out/x.o')
        self.put('src/x.c')
        git(self.project, 'init', '-q')
        self.open_box(extra=GIT_ON)
        self.command('wait-git')
        self.type('@x')
        self.settle()
        self.assertEqual([r[1] + '/' + r[0] for r in self.rows() if r[3] == 'file'], ['src/x.c'])

    def test_without_gitignore_the_tree_s_rule_still_holds(self):
        self.put('.gitignore', 'out/\n')
        self.put('out/x.o')
        self.put('node_modules/x.js')
        self.put('src/x.c')
        git(self.project, 'init', '-q')
        self.open_box(extra=GIT_ON + '[agents]\nrespect_gitignore = false\n')
        self.command('wait-git')
        self.type('@x')
        self.settle()
        paths = sorted(r[1] + '/' + r[0] for r in self.rows() if r[3] == 'file')
        self.assertEqual(paths, ['out/x.o', 'src/x.c'])
        self.type('@.git/')
        self.settle()
        self.assertEqual(self.rows(), [])

    def test_the_exclude_setting_without_git(self):
        self.put('node_modules/dep.js')
        self.put('vendor2/dep.js')
        self.put('dep.js')
        self.open_box(extra='[files]\nexclude = vendor2 node_modules\n')
        self.type('@dep')
        self.settle()
        self.assertEqual([r[1] + '/' + r[0] for r in self.rows()], ['-/dep.js'])

    def test_no_project_no_files(self):
        self.start(target='--empty')
        self.command('agent-new claude')
        self.type('@')
        self.settle()
        self.assertIn('empty No files found', self.menu())
        self.assertEqual(self.filelist()['runs'], '0')

    def test_keys_wrap_enter_tab_escape(self):
        for name in ('a1.txt', 'a2.txt', 'a3.txt'):
            self.put(name)
        self.open_box()
        self.type('@a')
        self.settle()
        self.assertEqual(self.head()['sel'], '1')
        self.command('key Up')                          # wraps to the last
        self.assertEqual(self.head()['sel'], '3')
        self.command('key Down')
        self.assertEqual(self.head()['sel'], '1')
        self.command('key Down')
        label = self.rows()[1][0]
        self.command('key Tab')                         # a file by Tab: as Enter
        self.assertEqual(self.box(), '@' + label + ' ')
        self.type('@a')
        self.settle()
        self.command('key Escape')
        self.assertEqual(self.head()['popup'], 'none')
        self.assertEqual(self.box(), '@' + label + ' @a')

    def test_tab_on_a_folder_drills_enter_finishes(self):
        self.put('src/main.c')
        self.put('src/util.c')
        self.open_box()
        self.type('@sr')
        self.settle()
        self.assertEqual(self.rows()[0], ('src/', '-', '-', 'folder'))
        self.command('key Tab')
        self.assertEqual(self.box(), '@src/')
        self.settle()
        self.assertEqual(self.head()['popup'], 'mention')
        self.assertEqual(self.labels(), ['main.c', 'util.c'])
        self.command('key Down')
        self.command('key Return')
        self.assertEqual(self.box(), '@src/util.c ')
        self.assertEqual(self.head()['popup'], 'none')
        self.type('@sr')                                # a folder by Enter: finished, a space after it
        self.settle()
        self.command('key Return')
        self.assertEqual(self.box(), '@src/util.c @src/ ')

    def test_a_pick_is_quoted_when_it_must_be(self):
        self.put('my notes.txt')
        self.open_box()
        self.type('@notes')
        self.settle()
        self.command('key Return')
        self.assertEqual(self.box(), '@"my notes.txt" ')

    def test_a_path_that_cannot_be_mentioned(self):
        self.put('a#b.txt')
        self.open_box()
        self.type('@a#b')
        self.settle()
        self.assertEqual(self.labels(), ['a#b.txt'])
        self.command('key Return')
        self.assertEqual(self.toast(), "toast=This path can't be @-mentioned, because Claude Code would read it as a "
                                       'different mention: a#b.txt')
        self.assertEqual(self.box(), '@a#b')

    def test_the_menu_closes_when_the_caret_leaves(self):
        self.put('a.txt')
        self.open_box()
        self.type('@a')
        self.settle()
        self.assertEqual(self.head()['popup'], 'mention')
        self.command('key space')
        self.type('and')
        self.assertEqual(self.box(), '@a and')
        self.assertEqual(self.head()['popup'], 'none')

    def test_escape_keeps_it_closed_until_the_text_changes(self):
        self.put('a.txt')
        self.open_box()
        self.type('@a')
        self.settle()
        self.command('key Escape')
        self.assertEqual(self.head()['popup'], 'none')
        self.command('key Left')                        # the same text: still closed
        self.command('key Right')
        self.assertEqual(self.head()['popup'], 'none')
        self.type('.')                                  # changed: open again
        self.settle()
        self.assertEqual(self.head()['popup'], 'mention')

    def test_slash_and_at_do_not_fight(self):
        self.put('README.md')
        self.open_box()
        self.type('/comp')
        self.assertEqual(self.head()['popup'], 'menu')
        self.command('key space')
        self.type('@REA')
        self.settle()
        self.assertEqual(self.head()['popup'], 'mention')
        self.assertEqual(self.labels(), ['README.md'])

    def test_rows_while_the_list_is_made(self):
        self.open_box()
        self.command('filelist-test 500 more')
        self.type('@f0000')
        self.assertEqual(self.filelist()['state'], 'listing')
        first = self.labels()
        self.assertTrue(first)
        self.command('filelist-test 500')
        self.settle()
        self.assertEqual(self.filelist()['state'], 'ready')
        self.assertGreaterEqual(len(self.labels()), len(first))

    def test_a_query_never_takes_a_frame(self):
        self.open_box()
        self.command('filelist-test 100000')
        self.type('@')
        query = 'f01234.cxyz'
        for ch in query:
            self.type(ch)
            self.command('wait 1')
        for _ in range(100):
            if self.filelist().get('rows') is not None and 'popup=mention' in self.menu():
                self.command('wait 16')
            fl = self.filelist()
            if int(fl['steps']) > len(query):
                break
        fl = self.filelist()
        self.assertLess(int(fl['maxstep']), 16000, fl)      # a key's work fits in a frame
        self.assertGreater(int(fl['steps']), len(query), fl)

    def test_rows_follow_within_three_frames(self):
        for i in range(200):
            self.put(f'd{i % 10}/file{i}.txt')
        self.open_box()
        self.type('@')
        self.settle()
        self.type('file17')
        self.command('wait 50')                         # three frames at most
        self.assertIn('file17.txt', self.labels())

    def test_narrowing_matches_fewer_candidates(self):
        self.open_box()
        self.command('filelist-test 100000')
        self.type('@f0123')
        self.settle_query()
        wide = int(self.filelist()['candidates'])
        self.type('4')
        self.settle_query()
        narrow = int(self.filelist()['candidates'])
        self.assertEqual(wide, 100000)
        self.assertLess(narrow, wide // 2)

    def settle_query(self):
        for _ in range(200):
            before = self.filelist()['candidates']
            self.command('wait 20')
            if self.filelist()['candidates'] == before:
                return

    def test_the_list_is_not_made_again_without_a_change(self):
        self.put('a.txt')
        self.open_box()
        for _ in range(20):
            self.type('@')
            self.settle()
            self.command('key BackSpace')
            self.command('wait 30')
        self.assertEqual(self.filelist()['runs'], '1')

    def menu_once(self):
        """A menu opened and closed again."""
        self.type('@')
        self.settle()
        self.command('key BackSpace')
        self.command('wait 30')

    def test_a_new_file_makes_it_stale(self):
        # rhun makes a file (a save: the explorer's refresh), git sees one added, the watcher sees one made in
        # a watched folder: each time the next menu lists again, and the old rows answer until the new list is in
        self.put('a.txt')
        git(self.project, 'init', '-q')
        self.open_box(extra=GIT_ON)
        self.command('wait-git')
        self.menu_once()
        self.assertEqual(self.filelist()['runs'], '1')
        self.menu_once()
        self.assertEqual(self.filelist()['runs'], '1')
        new = self.project / 'made-by-rhun.txt'
        self.command(f'open {new}')
        self.command('type x')
        self.command('cmd save')
        self.command('wait 100')
        self.command('cmd focus_agents')
        self.command('agent-focus box')
        self.menu_once()
        self.assertEqual(self.filelist()['runs'], '2')
        self.put('added.txt')
        git(self.project, 'add', 'added.txt')
        self.command('wait 300')
        self.command('wait-git')
        self.menu_once()
        self.assertEqual(self.filelist()['runs'], '3')
        self.type('@adde')
        self.settle()
        self.assertEqual(self.labels(), ['added.txt'])

    def test_a_miss_lists_again_once(self):
        # a file made where nothing watches (or a watcher that has not told yet): a query that matches nothing
        # lists again once when the list is older than 5 s; a second miss within 5 s of that runs nothing
        self.put('a.txt')
        (self.project / 'deep/er').mkdir(parents=True)
        self.open_box()
        self.type('@')
        self.settle()
        self.command('key BackSpace')
        time.sleep(5.2)                                 # the list is older than FL_MISS_MS
        self.put('deep/er/late.txt')
        self.type('@late')
        self.settle()
        self.settle()
        self.assertEqual(self.labels(), ['late.txt'])
        runs = int(self.filelist()['runs'])
        self.assertIn(runs, (2, 3))                     # (3: a watcher saw the file too, as it was made)
        self.type('zzz')                                # a second miss within 5 s: nothing
        self.settle()
        self.assertEqual(self.labels(), [])
        self.assertEqual(int(self.filelist()['runs']), runs)

    def test_the_cap_is_said(self):
        self.open_box()
        self.command('filelist-test 200001')
        self.type('@')
        self.settle()
        self.assertEqual(self.menu().splitlines()[-1].split('\t')[0] if False else
                         [l for l in self.menu().splitlines() if l.startswith('foot ')],
                         ['foot Only the first 200,000 files are listed.'])

    def test_no_menu_without_the_capability(self):
        self.put('a.txt')
        self.open_box()
        self.command('agent-test-caps 4096')            # parts, no mentions
        self.type('@a')
        self.assertEqual(self.head()['popup'], 'none')
        self.assertEqual(self.filelist()['runs'], '0')

    def test_the_menu_fits_every_size_and_width(self):
        self.put('a-very-long-folder-name-that-goes-on/and-a-file-with-a-long-name-too.txt')
        self.put('b.txt')
        self.open_box()
        self.type('@a')
        self.settle()
        lines = self.command('print-agent-menu fit').splitlines()
        self.assertEqual(len(lines), 25 * 34)
        for line in lines:
            f = dict(w.split('=') for w in line.split())
            self.assertLessEqual(int(f['right']), int(f['x']) + int(f['pw']), line)
            self.assertGreaterEqual(int(f['left']), int(f['x']), line)

    def test_a_picked_mention_is_painted(self):
        self.put('src/a.c')
        self.start()
        self.chat('hello')
        self.type('see @a.c')
        self.settle()
        self.command('key Return')
        self.assertEqual(self.box(), 'see @src/a.c ')
        self.assertIn('paint=4-12', self.command('print-agent-composer'))

    def test_bubble_chips_and_which_tokens_are_chips(self):
        self.start()
        prompt = 'x @src/a.c @"a b.txt" @terminal:zsh @types/node @you @x (agent)'
        self.chat(prompt)
        self.command('wait 50')
        chips = self.command('print-agent-bubble-chips').splitlines()
        spans = [prompt[int(c.split()[1].split('-')[0]):int(c.split()[1].split('-')[1])] for c in chips]
        self.assertEqual(spans, ['@src/a.c', '@"a b.txt"', '@terminal:zsh'])
        self.assertEqual([c.split()[2] for c in chips], ['path', 'path', 'terminal'])

    def test_a_bubble_chip_opens_its_file_at_its_lines(self):
        self.put('a.py', ''.join(f'line {i}\n' for i in range(1, 11)))
        self.start()
        self.chat('see @a.py#L2-4 now')
        self.command('wait 50')
        chip = self.command('print-agent-bubble-chips').splitlines()[0]
        x, y, w, h = (int(v) for v in chip.split()[3].split(','))
        self.command(f'click {x + w // 2} {y + h // 2}')
        self.command('wait 50')
        state = self.command('print-state')
        self.assertIn('active=a.py', state)
        self.assertIn('line=2 ', state)
        self.assertRegex(state, r'sel=\S+')

    def test_a_range_link_selects_the_lines(self):
        self.put('a.py', ''.join(f'line {i}\n' for i in range(1, 11)))
        self.start()
        self.chat('see @a.py:3-5 now')
        self.command('wait 50')
        chip = self.command('print-agent-bubble-chips').splitlines()[0]
        x, y, w, h = (int(v) for v in chip.split()[3].split(','))
        self.command(f'click {x + w // 2} {y + h // 2}')
        self.command('wait 50')
        state = self.command('print-state')
        self.assertIn('line=3 ', state)

    def test_terminals_are_rows(self):
        self.start(extra='[terminal]\nshell = /bin/sh\n')
        self.chat('hello')
        self.command('cmd new_terminal')
        self.command("type printf '\\033]0;my shell\\007'; echo titled")
        self.command('key Return')
        self.command('wait-term titled')
        self.command('wait 100')
        self.command('agent-focus box')
        self.type('@terminal:')
        self.settle()
        self.assertIn('terminal:my_shell', self.labels())
        self.command('key Return')
        self.assertEqual(self.box(), '@terminal:my_shell ')

    def test_a_terminal_goes_only_when_mentioned(self):
        self.start(extra='[terminal]\nshell = /bin/sh\n')
        self.chat('hello')
        self.command('cmd new_terminal')
        self.command('type echo marker-$((40+2))')
        self.command('key Return')
        self.command('wait-term marker-42')
        name = re.search(r' title=(\S+)', self.command('print-terminals')).group(1)
        self.command('agent-prompt plain @terminal:nothere')
        self.ready()
        self.assertEqual([b['type'] for b in self.blocks()], ['text'])
        self.command(f'agent-prompt look @terminal:{name} and @terminal:{name}')
        self.ready()
        blocks = self.blocks()
        terms = [b for b in blocks if b['type'] == 'text' and b['text'].startswith('<terminal')]
        self.assertEqual(len(terms), 1, blocks)
        self.assertIn('marker-42', terms[0]['text'])
        self.assertTrue(terms[0]['text'].startswith(f'<terminal name="{name}">\n'))
        self.assertLessEqual(terms[0]['text'].count('\n'), 102)

    def test_a_links_terminal_mention_is_blocked(self):
        """A rhun://NAME/open link's prompt fills the box: its @terminal: names send nothing of the terminal (the
        link's sender chose them, not the user) until the user picks that terminal from the menu."""
        self.start(extra='[terminal]\nshell = /bin/sh\n')
        self.chat('hello')
        self.command('cmd new_terminal')
        self.command('type echo marker-$((40+2))')
        self.command('key Return')
        self.command('wait-term marker-42')
        name = re.search(r' title=(\S+)', self.command('print-terminals')).group(1)
        sid = self.sid()
        self.command('cmd focus_agents')
        self.command(f'click {chat.BACK[0]} {chat.BACK[1]}')     # (a shown conversation keeps its box)
        self.command(f'open rhun://claude/open?session={sid}&prompt=look%20@terminal:{name}')
        self.assertTrue(self.command('print-agent-input').startswith(f'input=look @terminal:{name} '),
                        self.command('print-agent-input'))
        self.command('agent-focus box')
        self.command('key Return')
        self.ready()
        self.assertEqual([b['type'] for b in self.blocks()], ['text'])
        self.assertNotIn('marker-42', repr(self.blocks()))
        self.command(f'agent-prompt again @terminal:{name}')     # the user's own mention goes
        self.ready()
        self.assertIn('marker-42', repr(self.blocks()))

    def test_an_unknown_terminal_adds_nothing(self):
        self.start()
        self.chat('hello')
        self.command('agent-prompt look at @terminal:nothere')
        self.ready()
        self.assertEqual([b['type'] for b in self.blocks()], ['text'])


LINES = ''.join(f'line {i}\n' for i in range(1, 11))
SEL_TAIL = '\n\nThis may or may not be related to the current task.</ide_selection>'


class ContextCase(MentionCase):
    """The selection chip (print-agent-context) and what the fake read."""

    def ctx(self):
        first = self.command('print-agent-context').splitlines()[0]
        out = {}
        for word in re.findall(r'(\w+)=(.*?)(?= \w+=|$)', first):
            out[word[0]] = word[1]
        return out

    def tip(self):
        return [l for l in self.command('print-agent-context').splitlines() if l.startswith('tip ')][0][4:]

    def open_file(self, name='a.py', text=LINES):
        path = self.put(name, text)
        self.command(f'open {path}')
        self.command('wait 20')
        return path

    def select_lines(self, n):
        """From the caret's line start, n lines down (Shift+Down): the selection ends at column 0 of the next."""
        self.command('key Home')
        for _ in range(n):
            self.command('key shift+Down')
        self.command('wait 20')

    def box_send(self, text):
        """Typed into the box and sent with Enter, as the user does."""
        self.command('agent-focus box')
        self.command('agent-type ' + text)
        self.command('key Return')
        self.ready()

    def focused(self):
        """1 when the prompt box has the keys (print-agent-input's focus=)."""
        return self.command('print-agent-input').split(' focus=')[1].split()[0]

    def context_blocks(self):
        return [b['text'] for b in self.blocks() if b['type'] == 'text' and b['text'].startswith('<ide_')]

    def git_project(self, ignored=('.env',)):
        self.put('.gitignore', ''.join(f'{n}\n' for n in ignored))
        git(self.project, 'init', '-q')


class ContextTest(ContextCase):
    """The chip (UI 1.17): its label, tip, x, settings, where it shows, its layout, its cost."""

    def test_the_chip_follows_the_selection(self):
        self.start()
        self.chat('hello')
        self.open_file()
        self.assertEqual(self.ctx()['label'], 'a.py')
        self.command('key shift+End')
        self.assertEqual(self.ctx()['label'], '1 line selected')
        self.select_lines(2)
        self.assertEqual(self.ctx()['label'], '3 lines selected')     # ends at column 0 of line 3: counted
        self.assertEqual(self.ctx()['lines'], '1-3')

    def test_the_tip(self):
        self.start()
        self.chat('hello')
        self.open_file()
        self.command('key shift+End')
        self.assertEqual(self.tip(), 'Showing Claude your current file selection (1 line selected)')

    def test_x_dismisses_until_the_selection_changes(self):
        self.start()
        self.chat('hello')
        self.open_file()
        self.select_lines(1)
        self.command('agent-context dismiss')
        self.assertEqual(self.ctx()['chip'], '0')
        self.assertEqual(self.ctx()['dismissed'], '1')
        self.command('key Down')                        # a caret move without a selection, same file: still gone
        self.command('wait 20')
        self.assertEqual(self.ctx()['chip'], '0')
        self.select_lines(2)                            # another selection: back
        self.assertEqual(self.ctx()['chip'], '1')
        self.command('agent-context dismiss')
        self.open_file('b.py')                          # another file: back
        self.assertEqual(self.ctx()['label'], 'b.py')

    def test_the_two_settings(self):
        self.start(extra='[agents]\nattach_selection = false\n')
        self.chat('hello')
        self.open_file()
        self.select_lines(2)
        self.assertEqual(self.ctx()['label'], 'a.py')
        self.stop()
        self.start(extra='[agents]\nattach_selection = false\nattach_open_file = false\n')
        self.chat('hello')
        self.open_file()
        self.select_lines(2)
        self.assertEqual(self.ctx()['chip'], '0')

    def test_no_chip_without_a_file(self):
        self.start()
        self.chat('hello')
        self.assertEqual(self.ctx()['chip'], '0')       # no tab
        self.command('cmd new_file')                    # an untitled document
        self.assertEqual(self.ctx()['chip'], '0')
        self.command('cmd settings')
        self.assertEqual(self.ctx()['chip'], '0')

    def test_no_chip_without_the_capability(self):
        self.start()
        self.chat('hello')
        self.open_file()
        self.command('agent-test-caps 4096')
        self.assertEqual(self.ctx()['chip'], '0')

    def test_the_chip_in_every_stage_and_width(self):
        self.start()
        self.chat('hello')
        self.open_file('a-file-with-a-rather-long-name-to-cut.py')
        self.command('key shift+End')
        lines = self.command('print-agent-context fit').splitlines()
        self.assertEqual(len(lines), 25 * 34)
        shown = 0
        for line in lines:
            f = {k: int(v) for k, v in (w.split('=') for w in line.split())}
            if f['cw'] == 0:
                continue
            shown += 1
            self.assertLessEqual(f['x'] + f['cw'], f['menu_x'], line)          # left of the menu button
            if f['mode_w']:
                self.assertGreaterEqual(f['x'], f['mode_x'] + f['mode_w'], line)
            self.assertGreaterEqual(f['cw'], 16, line)                       # its x keeps MI_16 at least
        self.assertGreater(shown, 25 * 34 // 2)

    def test_one_ignored_check_a_file(self):
        self.git_project()
        self.put('a.py', LINES)                         # there before git's first status (a file made later
        self.start(extra=GIT_ON)                        #   changes git's set of new files: asked again)
        self.chat('hello')
        self.command('agent-focus box')
        self.command('key x')                           # the user typed in this conversation's box
        self.open_file()
        for _ in range(10):
            self.select_lines(2)
            for _ in range(5):
                self.command('key Down')
                self.command('key Up')
            self.command('wait 20')
        self.until(lambda: self.ctx()['why'] in ('git', '-'), 'the check', 10)
        self.assertEqual(self.ctx()['checks'], '1')

    def test_a_reader_starts_no_git(self):
        self.git_project()
        self.start(extra=GIT_ON)
        self.chat('hello')
        self.open_file()
        self.select_lines(2)
        for _ in range(6):
            self.command('wait 500')
            self.assertEqual(self.ctx()['checks'], '0')
        self.assertEqual(self.ctx()['why'], 'unasked')
        self.assertEqual(self.ctx()['label'], 'a.py')   # unknown: its name only
        self.command('agent-focus box')
        self.command('key x')
        self.command('wait 50')
        self.until(lambda: self.ctx()['checks'] == '1', 'the check', 10)

    def test_a_name_only_chip_needs_no_check(self):
        self.git_project()
        self.start(extra=GIT_ON)
        self.chat('hello')
        self.command('agent-focus box')
        self.command('key x')
        self.open_file()
        self.command('wait 100')
        self.assertEqual(self.ctx()['checks'], '0')
        self.command('key shift+End')
        self.stop()
        self.start(extra=GIT_ON + '[agents]\nattach_selection = false\n')
        self.chat('hello')
        self.command('agent-focus box')
        self.command('key x')
        self.open_file()
        self.command('key shift+End')
        self.command('wait 100')
        self.assertEqual(self.ctx()['checks'], '0')

    def loop_figures(self, extra, seconds):
        self.start(extra=extra)
        self.chat('hello')
        self.open_file()
        self.select_lines(2)
        self.command('agent-focus box')
        self.command('wait 300')
        before = self.command('print-loop-stats').split()
        time.sleep(seconds)
        after = self.command('print-loop-stats').split()
        figures = [int(b.split('=')[1]) - int(a.split('=')[1]) for a, b in zip(before, after)]
        self.stop()
        return figures

    def test_the_chip_adds_no_wake_up(self):
        on = self.loop_figures('', 3)
        off = self.loop_figures('[agents]\nattach_selection = false\nattach_open_file = false\n', 3)
        # rhun wakes about once a second here whatever the chip does (3 or 4 frames in 3 s from run to run): the
        # chip may add nothing beyond that jitter (a wake is one to three passes), and never a busy loop
        self.assertLessEqual(abs(on[0] - off[0]), 3, (on, off))
        self.assertLessEqual(abs(on[1] - off[1]), 1, (on, off))
        self.assertLessEqual(on[0], 10, on)             # passes in 3 s with nothing happening


class PrivacyTest(ContextCase):
    """What goes (UI 1.18), read from the fake's stdin: only what the chip showed, as the extension writes it."""

    def test_a_selection_goes_as_the_extension_writes_it(self):
        self.start()
        self.chat('hello')
        path = self.open_file()
        self.select_lines(2)
        self.box_send('explain')
        self.assertEqual(self.blocks(), [
            {'type': 'text', 'text': f'<ide_selection>The user selected the lines 1 to 3 from {path}:\n'
                                     'line 1\nline 2\n' + SEL_TAIL},
            {'type': 'text', 'text': 'explain'}])

    def test_an_open_file_goes_as_the_extension_writes_it(self):
        self.start()
        self.chat('hello')
        path = self.open_file()
        self.box_send('explain')
        self.assertEqual(self.blocks()[0], {'type': 'text', 'text':
                         f'<ide_opened_file>The user opened the file {path} in the IDE. This may or may not be '
                         'related to the current task.</ide_opened_file>'})

    def test_the_same_context_is_not_sent_twice(self):
        self.start()
        self.chat('hello')
        self.open_file()
        self.select_lines(2)
        self.box_send('one')
        self.assertEqual(len(self.context_blocks()), 1)
        self.box_send('two')
        self.assertEqual(self.context_blocks(), [])

    def test_a_changed_selection_is_sent_again(self):
        self.start()
        self.chat('hello')
        self.open_file()
        self.select_lines(2)
        self.box_send('one')
        self.command('agent-focus editor')              # the box had the keys
        self.command('key Down')
        self.select_lines(1)
        self.box_send('two')
        self.assertEqual(len(self.context_blocks()), 1)
        self.assertIn('lines 4 to 5', self.context_blocks()[0])   # Down from line 3's start, one line

    def test_a_dismissed_chip_sends_nothing(self):
        self.start()
        self.chat('hello')
        self.open_file()
        self.select_lines(2)
        self.command('agent-context dismiss')
        self.box_send('explain')
        self.assertEqual(self.context_blocks(), [])

    def test_an_ignored_file_gives_its_name_only(self):
        self.git_project()
        self.start(extra=GIT_ON)
        self.chat('hello')
        self.command('agent-focus box')
        self.command('key x')
        self.command('key BackSpace')
        path = self.open_file('.env', 'SECRET=hunter2\n')
        self.command('key shift+End')
        self.until(lambda: self.ctx()['why'] == 'git', 'the check', 10)
        self.assertEqual(self.ctx()['ignored'], '1')
        self.box_send('explain')
        self.assertEqual(self.context_blocks(), [f'<ide_opened_file>The user opened the file {path} in the IDE. '
                                                 'This may or may not be related to the current task.'
                                                 '</ide_opened_file>'])
        self.assertNotIn('hunter2', repr(self.stdin()))
        excluded = self.open_file('node_modules/x.js', 'module.exports = "secret-two"\n')
        self.command('key shift+End')
        self.assertEqual(self.ctx()['why'], 'exclude')
        self.box_send('again')
        self.assertIn(str(excluded), self.context_blocks()[0])
        self.assertNotIn('secret-two', repr(self.stdin()))

    def test_until_git_answers_the_text_is_withheld(self):
        self.git_project()
        self.start(extra=GIT_ON)
        self.chat('hello')
        self.open_file('.env', 'SECRET=hunter2\n')
        self.command('key shift+End')
        self.command('agent-focus box')
        self.command('agent-type x')
        self.command('key Return')                      # the frame the first character was typed in
        self.ready()
        self.assertNotIn('hunter2', repr(self.stdin()))

    def unknown(self, why, env=None, bin_mode=None):
        """A .gitignore'd .env selected; the user typed: its text never goes, why= says why."""
        self.git_project()
        if bin_mode:
            real = subprocess.run(['/usr/bin/which', 'git'], capture_output=True, text=True).stdout.strip()
            bindir = self.work / 'bin'
            bindir.mkdir()
            (bindir / 'git').write_text('#!/bin/sh\nfor a; do [ "$a" = check-ignore ] && { %s; }; done\n'
                                        'exec %s "$@"\n' % (bin_mode, real))
            (bindir / 'git').chmod(0o755)
            env = dict(env or {}, PATH=f'{bindir}:{os.environ["PATH"]}')
        self.start(extra=GIT_ON, env=env)
        self.chat('hello')
        self.command('agent-focus box')
        self.command('key x')
        self.command('key BackSpace')
        self.open_file('.env', 'SECRET=hunter2\n')
        self.command('key shift+End')
        self.until(lambda: self.ctx()['why'] == why, f'why={why}', 10)
        self.assertEqual(self.ctx()['ignored'], '1')
        self.box_send('explain')
        self.assertNotIn('hunter2', repr(self.stdin()))
        self.assertIn('<ide_opened_file>', repr(self.blocks()))

    def test_unknown_is_ignored_without_git(self):
        self.unknown('nogit', env={'PATH': '/nonexistent'})

    def test_unknown_is_ignored_when_git_fails(self):
        self.unknown('failed', bin_mode='exit 128')

    def test_unknown_is_ignored_while_git_is_slow(self):
        self.unknown('slow', bin_mode='sleep 5')
        self.until(lambda: self.ctx()['why'] == 'git', 'the late answer', 15)     # then the chip follows it

    def test_no_repository_sends_the_text(self):
        self.start()
        self.chat('hello')
        self.open_file('.env', 'SECRET=hunter2\n')
        self.command('key shift+End')
        self.assertEqual(self.ctx()['why'], 'norepo')
        self.box_send('explain')
        self.assertIn('hunter2', self.context_blocks()[0])

    def test_a_prompt_not_sent_by_the_box_carries_no_context(self):
        self.start()
        self.chat('hello')
        self.open_file()
        self.select_lines(2)
        self.command('agent-prompt explain')
        self.ready()
        self.assertEqual(self.blocks(), [{'type': 'text', 'text': 'explain'}])

    def test_a_selection_over_1_mb_goes_as_the_file(self):
        self.start()
        self.chat('hello')
        path = self.open_file('big.txt', ('x' * 99 + '\n') * 11000)
        self.command('key ctrl+a')
        self.command('wait 20')
        self.box_send('explain')
        self.assertTrue(self.context_blocks()[0].startswith(f'<ide_opened_file>The user opened the file {path}'))

    def test_nothing_goes_with_the_chat_off(self):
        self.start(claude=self.claude_section('chat = false\n'))
        self.open_file()
        self.select_lines(2)
        self.assertEqual(self.ctx()['chip'], '0')
        self.assertEqual(self.stdin(), [])


class CommandsTest(ContextCase):
    """Insert @-Mention (Alt+K), Focus or Unfocus the Message Box (Ctrl/Cmd+Esc), Add to Chat (UI 1.22, 7.6)."""

    def test_alt_k_without_a_selection_one_line_and_a_range(self):
        self.start()
        self.chat('hello')
        self.open_file()
        self.command('key alt+k')
        self.assertEqual(self.box(), '@a.py ')
        self.command('agent-focus editor')
        self.command('key Down')
        self.command('key shift+End')
        self.command('key alt+k')
        self.assertEqual(self.box(), '@a.py @a.py#L2 ')
        self.command('agent-focus editor')
        self.command('key Home')
        self.command('key shift+Down')
        self.command('key shift+Down')
        self.command('key alt+k')
        self.assertEqual(self.box(), '@a.py @a.py#L2 @a.py#L2-4 ')
        self.assertEqual(self.focused(), '1')

    def test_mention_paths_are_relative_to_the_checkout_else_absolute(self):
        outside = self.work / 'outside.py'
        outside.write_text('x\n')
        self.start()
        self.chat('hello')
        self.open_file('src/in.py')
        self.command('key alt+k')
        self.command(f'open {outside}')
        self.command('key alt+k')
        self.assertEqual(self.box(), f'@src/in.py @{outside} ')

    def test_alt_k_with_a_path_that_cannot_be_mentioned(self):
        self.start()
        self.chat('hello')
        self.open_file('a#b.py')
        self.command('key alt+k')
        self.assertEqual(self.box(), '')
        self.assertEqual(self.toast(), "toast=This path can't be @-mentioned, because Claude Code would read it as a "
                                       'different mention: a#b.py')

    def test_a_mention_goes_to_the_shown_conversation_else_a_new_one(self):
        self.start()
        self.open_file()
        self.command('key alt+k')                       # no conversation: a new one of the default driver
        self.assertEqual(self.box(), '@a.py ')
        self.assertEqual(self.focused(), '1')

    def test_ctrl_escape_there_and_back(self):
        self.start()
        self.chat('hello')
        self.open_file()
        self.command('agent-focus editor')
        self.command('key ctrl+Escape')
        self.assertEqual(self.focused(), '1')
        self.assertEqual(self.box(), '')
        self.command('key ctrl+Escape')
        self.assertEqual(self.focused(), '0')
        self.assertIn(' focus=0 ', self.command('print-state'))   # FOCUS_EDITOR

    def test_ctrl_escape_with_a_selection_inserts_its_mention(self):
        self.start()
        self.chat('hello')
        self.open_file()
        self.select_lines(2)
        self.command('key ctrl+Escape')
        self.assertEqual(self.box(), '@a.py#L1-3 ')

    def test_ctrl_escape_does_not_stop_a_turn(self):
        self.start(env={'FAKE_CLAUDE_REPLY_MS': '2000'})
        self.chat('hello')
        self.command('agent-focus box')
        self.command('agent-prompt slow one')
        self.command('wait-agent working 5000')
        self.command('key ctrl+Escape')
        self.assertIn('state=working', self.live())

    def test_alt_k_from_the_box_and_the_panel(self):
        self.start()
        self.chat('hello')
        self.open_file()
        self.command('agent-focus box')
        self.command('key alt+k')
        self.assertEqual(self.box(), '@a.py ')
        self.command('agent-focus panel')
        self.command('key alt+k')
        self.assertEqual(self.box(), '@a.py @a.py ')

    def explorer_pick(self, y):
        """The explorer's menu on the row at y (1280x800, rows 28 px from y 80: sub/, a.py, c#d.py)."""
        self.command(f'click 50 {y} right')
        items = self.command('print-menu').splitlines()
        if 'Add to Chat' in items:
            self.command('menu-pick Add to Chat')
        else:
            self.command('key Escape')
        return items

    def explorer_project(self, **kw):
        self.put('a.py', 'x\n')
        self.put('sub/b.py', 'y\n')
        self.put('c#d.py', 'z\n')
        self.start(**kw)
        self.command('cmd toggle_sidebar')
        self.command('wait 50')

    def test_add_to_chat_in_the_explorers_menu(self):
        self.explorer_project()
        self.chat('hello')
        items = self.explorer_pick(94)                  # a folder: with its "/"
        self.assertEqual(items[-2:], ['-', 'Add to Chat'])          # after the built-in items, a group of its own
        self.assertEqual(items[0], 'New File')
        self.explorer_pick(122)                         # a file
        self.assertEqual(self.box(), '@sub/ @a.py ')
        self.assertEqual(self.focused(), '1')

    def test_add_to_chat_refusal_text(self):
        self.explorer_project()
        self.chat('hello')
        self.explorer_pick(150)
        self.assertEqual(self.box(), '')
        self.assertEqual(self.toast(), 'toast=1 selected path was not added to the chat. Some paths can\'t be '
                                       '@-mentioned, such as one with # or a double quote in it. Describe the '
                                       'file or folder in your message instead.')

    def test_add_to_chat_not_with_the_chat_off(self):
        self.explorer_project(claude=self.claude_section('chat = false\n'))
        self.assertNotIn('Add to Chat', self.explorer_pick(122))

    def test_a_mention_shows_a_hidden_panel(self):
        self.start()
        self.chat('hello')
        self.open_file()
        self.command('cmd toggle_agents')
        self.command('wait 20')
        self.assertIn('agents=0', self.command('print-panels'))
        self.command('key alt+k')
        self.assertIn('agents=1', self.command('print-panels'))
        self.assertEqual(self.box(), '@a.py ')
        self.assertEqual(self.focused(), '1')

    def test_placeholders_c_and_e(self):
        key = '\u2318 Esc' if sys.platform == 'darwin' else 'ctrl esc'
        self.start()
        self.chat('hello')                              # a suggestion: (c) hides it (UI 1.29)
        self.open_file()
        self.select_lines(1)
        self.assertEqual(self.command('print-agent-placeholder').strip(), f'placeholder={key} to attach selected text')
        self.stop()
        self.start(claude=self.claude_section('prompt_suggestions = false\n'))
        self.chat('hello')
        self.box_send('one')                            # the window's first Send: no first-use text (d)
        self.command('agent-focus editor')
        self.open_file()
        self.select_lines(1)
        self.assertEqual(self.command('print-agent-placeholder').strip(), f'placeholder={key} to attach selected text')
        self.command('key Left')                        # no selection, the keys in the box: (e)
        self.command('agent-focus box')
        self.command('wait 20')
        self.assertEqual(self.command('print-agent-placeholder').strip(),
                         f'placeholder={key} to focus or unfocus Claude')

    def test_the_palette_lists_them_and_not_with_the_chat_off(self):
        self.start()
        self.command('cmd command_palette')
        self.command('type Agents: Insert')
        self.assertIn('Agents: Insert @-Mention', self.command('print-palette'))
        self.command('key Escape')
        self.stop()
        self.start(claude=self.claude_section('chat = false\n'))
        self.command('cmd command_palette')
        self.command('type Agents: Insert')
        self.assertNotIn('Agents: Insert @-Mention', self.command('print-palette'))


if __name__ == '__main__':
    unittest.main()
