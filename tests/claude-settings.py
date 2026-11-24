#!/usr/bin/env python3
"""Phase 8 (claude-chat-p8): the extension's settings as rhun's, the rows written back and read ([agents]
location, autosave, attach_selection, attach_open_file, respect_gitignore, continue_after_restart), and what
[claude] disable_login_prompt and python_env control; the extension's other commands and keys as rhun's; the
when-clause keys; the agents' log. What the other settings control is tested by the lines that built them:
autosave tests/claude-hooks.py, the selection and the open file tests/claude-mention.py, location
tests/claude-tab.py, continue_after_restart tests/claude-fork.py.
Against the fake CLI (tests/scripts/fake-claude.py), over the control socket; it imports tests/claude-chat.py
for its cases: every rhun gets its own HOME and XDG folders, an environment without CLAUDE* or ANTHROPIC*
variables, and a config whose [claude] section starts the fake. Nothing here writes Claude Code's settings."""
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location('claude_chat', ROOT / 'tests/claude-chat.py')
chat = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(chat)

AGENTS_ROWS = ['agents.location', 'agents.autosave', 'agents.attach_selection', 'agents.attach_open_file',
               'agents.respect_gitignore', 'agents.continue_after_restart']
CLAUDE_ROWS = ['claude.disable_login_prompt', 'claude.python_env']
TERM_PROMPT = 'prompt=Run in the terminal: Enter, or Esc'


class Case(chat.DrivenCase):
    def put(self, name, text):
        path = self.project / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding='utf-8')
        return path

    def users(self):
        return [m for m in self.stdin() if m.get('type') == 'user']

    def blocks(self):
        return self.users()[-1]['message']['content']

    def init(self):
        return next(m['request'] for m in self.stdin() if m.get('type') == 'control_request'
                    and m['request'].get('subtype') == 'initialize')

    def context(self):
        return dict(re.findall(r'(\w+)=(\S*)', self.command('print-agent-context')))

    def box(self):
        return re.match(r'input=(.*?) focus=', self.command('print-agent-input'), re.S).group(1)

    def git(self, *args):
        subprocess.run(['git', *args], cwd=self.project, check=True, capture_output=True,
                       env=dict(self.env, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@e', GIT_COMMITTER_NAME='t',
                                GIT_COMMITTER_EMAIL='t@e'))


class RowsTest(Case):
    """Design 10: the rows, their defaults, the file written back, the page's section."""

    def test_rows_defaults_and_written_back(self):
        self.start()
        out = self.command('print-settings').splitlines()
        for row in AGENTS_ROWS + CLAUDE_ROWS:
            self.assertIn(row, out)
        claude = [r for r in out if r.startswith('claude.') and '=' not in r]
        self.assertEqual(claude[-3:], ['claude.disable_login_prompt', 'claude.python_env', 'claude.spinner_verbs'])
        self.command('cmd toggle_word_wrap')
        self.quit()
        saved = self.config.read_text(encoding='utf-8')
        agents = chat.section(saved, 'agents')
        for line in ('location = panel', 'autosave = true', 'attach_selection = true', 'attach_open_file = true',
                     'respect_gitignore = true', 'continue_after_restart = true'):
            self.assertIn(line, agents)
        self.assertIn('disable_login_prompt = false', chat.section(saved, 'claude'))
        self.assertIn('python_env = true', chat.section(saved, 'claude'))

    def test_values_are_read_and_kept(self):
        self.start(extra='[agents]\nlocation = tab\nautosave = false\nattach_selection = false\n'
                         'attach_open_file = false\nrespect_gitignore = false\ncontinue_after_restart = false\n'
                         '[claude]\ndisable_login_prompt = true\npython_env = false\n')
        self.command('cmd toggle_word_wrap')
        self.quit()
        saved = self.config.read_text(encoding='utf-8')
        agents = chat.section(saved, 'agents')
        for line in ('location = tab', 'autosave = false', 'attach_selection = false', 'attach_open_file = false',
                     'respect_gitignore = false', 'continue_after_restart = false'):
            self.assertIn(line, agents)
        claude = chat.section(saved, 'claude')
        self.assertIn('disable_login_prompt = true', claude)
        self.assertIn('python_env = false', claude)

    def test_the_page_finds_them(self):
        self.start()
        self.command('cmd settings')
        self.command('type attach')
        self.assertEqual(self.command('print-settings').splitlines(),
                         ['agents.attach_selection', 'agents.attach_open_file'])


class LoginTest(Case):
    """[claude] disable_login_prompt: no sign-in question before a start."""

    def test_signed_out_starts_anyway(self):
        self.start(self.claude_section('disable_login_prompt = true\n'), env={'FAKE_CLAUDE_AUTH': 'out'})
        self.chat('hello')
        self.assertEqual([r for r in self.records() if r.get('start') == 'auth'], [])
        self.assertEqual(len(self.starts()), 1)
        self.assertEqual(self.thread(), ['user hello', chat.REPLY + 'ok: hello'])

    def test_off_asks_as_before(self):
        self.start(env={'FAKE_CLAUDE_AUTH': 'out'})
        self.chat('hello', 'failed')
        self.assertEqual(len([r for r in self.records() if r.get('start') == 'auth']), 1)
        self.assertEqual(self.starts(), [])


class PythonEnvTest(Case):
    """[claude] python_env: the project's .venv or venv first on claude's PATH, VIRTUAL_ENV set."""

    ECHO = {'FAKE_CLAUDE_ECHO_ENV': 'VIRTUAL_ENV,PATH'}

    def venv(self, name):
        python = self.project / name / 'bin/python'
        python.parent.mkdir(parents=True)
        python.write_text('#!/bin/sh\n', encoding='utf-8')
        python.chmod(0o755)
        return self.project / name

    def env_of_start(self):
        return self.starts()[0]['env']

    def test_dot_venv(self):
        folder = self.venv('.venv')
        self.start(env=self.ECHO)
        self.chat('hello')
        env = self.env_of_start()
        self.assertEqual(env['VIRTUAL_ENV'], str(folder))
        self.assertTrue(env['PATH'].startswith(str(folder / 'bin') + ':'), env['PATH'])
        self.assertTrue(env['PATH'].endswith(self.env['PATH']), env['PATH'])

    def test_venv_without_a_dot(self):
        folder = self.venv('venv')
        self.start(env=self.ECHO)
        self.chat('hello')
        self.assertEqual(self.env_of_start()['VIRTUAL_ENV'], str(folder))

    def test_off_and_none(self):
        self.venv('.venv')
        self.start(self.claude_section('python_env = false\n'), env=self.ECHO)
        self.chat('hello')
        env = self.env_of_start()
        self.assertIsNone(env['VIRTUAL_ENV'])
        self.assertEqual(env['PATH'], self.env['PATH'])

    def test_a_folder_without_python_is_none(self):
        (self.project / '.venv').mkdir()
        self.start(env=self.ECHO)
        self.chat('hello')
        self.assertIsNone(self.env_of_start()['VIRTUAL_ENV'])

    def test_the_users_pair_wins(self):
        self.venv('.venv')
        self.start(self.claude_section('env.VIRTUAL_ENV = /mine\n'), env=self.ECHO)
        self.chat('hello')
        env = self.env_of_start()
        self.assertEqual(env['VIRTUAL_ENV'], '/mine')
        self.assertEqual(env['PATH'], self.env['PATH'])


class CommandsTest(Case):
    """The extension's commands and keys as rhun's (design 10)."""

    def palette(self, query):
        self.command('cmd command_palette')
        self.command('type ' + query)
        out = self.command('print-palette')
        self.command('key Escape')
        return out

    def test_the_palette_lists_them(self):
        self.start()
        for title in ('Agents: New Conversation', 'Agents: Open in Side Panel', 'Agents: Return to the Editor',
                      'Agents: Insert @-Mention', 'Agents: Add to Chat', 'Agents: Sign In', 'Agents: Sign Out',
                      'Agents: Install Plugin', 'Agents: Mark Conversation as Unread', 'Agents: Rename Conversation',
                      'Agents: Add Conversation to Group', 'Agents: Show Logs', 'Agents: Open',
                      'Agents: Focus or Unfocus the Message Box', 'Agents: Focus Last Message',
                      'Agents: Toggle Focus View', 'Agents: Open in New Tab'):
            self.assertIn(title, self.palette(title))

    def test_add_to_chat_takes_the_editors_file(self):
        self.start()
        path = self.put('b.txt', 'x\n')
        self.command(f'open {path}')
        self.command('cmd agents_add_to_chat')
        self.assertEqual(self.box(), '@b.txt ')

    def test_sign_in_out_and_plugin_in_the_terminal(self):
        self.start()
        for name, words in (('agents_sign_in', ' auth login'), ('agents_sign_out', ' auth logout'),
                            ('agents_install_plugin', ' /plugin')):
            self.command('cmd ' + name)
            self.assertEqual(self.command('print-palette').splitlines()[:2],
                             [TERM_PROMPT, f'field={chat.FAKE}{words}'])
            self.command('key Escape')

    def test_mark_unread_rename_and_group(self):
        self.start()
        self.chat('hello')
        self.command('cmd agents_mark_unread')
        self.assertIn(' flags=4 ', self.command('print-agent-list-state'))    # SF_UNREAD
        self.command('cmd agents_rename')
        self.command('key ctrl+a')
        self.command('type Renamed')
        self.command('key Return')
        self.until(lambda: 'Renamed' in self.command('print-agents'), 'the new title')
        self.command('cmd agents_add_to_group')
        self.command('menu-pick New group…')
        self.assertIn('New group', self.command('print-agent-list-state'))

    def test_open_in_side_panel_writes_location(self):
        self.start(extra='[agents]\nlocation = tab\n')
        self.command('cmd agents_open_panel')
        self.assertIn(' focus=', self.command('print-agent-input'))
        self.quit()
        self.assertIn('location = panel', chat.section(self.config.read_text(encoding='utf-8'), 'agents'))

    def test_return_to_the_editor(self):
        self.start()
        self.command('cmd focus_agents')
        self.command('cmd agents_blur')
        self.assertIn(' focus=0', self.command('print-agent-input'))

    def test_show_logs(self):
        self.start()
        self.chat('hello')
        log = self.command('print-agents-log').splitlines()
        self.assertTrue(any(line.endswith(' claude New conversation starting') or ' starting' in line
                            for line in log), log)
        self.assertTrue(any(line.endswith(' ready') for line in log), log)
        self.command('cmd agents_show_logs')
        self.assertIn('Agents Log', self.command('print-tabs'))

    def test_when_clause_keys(self):
        self.start('[claude]\nuse_terminal = true\n' + self.claude_section()[len('[claude]\n'):],
                   '[keys]\nctrl+shift+y = agents_new_conversation when claudeUseTerminal\n')
        self.command('key ctrl+shift+y')
        self.assertIn(' focus=1', self.command('print-agent-input'))


if __name__ == '__main__':
    unittest.main()
