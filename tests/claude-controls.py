#!/usr/bin/env python3
"""Claude Code's controls in the agents panel (phase 2: settings, the per-project lists, the composer,
menus, modes, models, notices, queueing), against the fake CLI (tests/scripts/fake-claude.py), over the
control socket. It imports tests/claude-chat.py for its cases: every rhun gets its own HOME and XDG
folders, an environment without CLAUDE* or ANTHROPIC* variables, and a config whose [claude] section
starts the fake. Nothing here writes the user's own Claude Code settings: the fake's config folder is the
test's HOME."""
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location('claude_chat', ROOT / 'tests/claude-chat.py')
chat = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(chat)

LEVELS = 'low:Low,medium:Medium,high:High'
DIALOG_KINDS = ['fable_overage_consent_prompt', 'auto_mode_server_fallback']    # the pinned ones (finding 25)


class CfgCase(chat.DrivenCase):
    """print-agent-cfg and the state file it names."""

    def cfg(self, kind=''):
        return self.command(('print-agent-cfg ' + kind).strip())

    def head(self):
        """print-agent-cfg's first line as a dict."""
        first = self.cfg().splitlines()[0]
        return dict(word.split('=', 1) for word in first.split(' '))

    def lines(self, word):
        return [line[len(word) + 1:] for line in self.cfg().splitlines() if line.startswith(word + ' ')]

    def state_file(self):
        path = self.head()['path']
        self.assertNotEqual(path, '-')
        return Path(path)


class ConfigTest(CfgCase):
    def test_new_settings_round_trip(self):
        self.start()
        out = self.command('print-settings')
        rows = [line for line in out.splitlines() if line.startswith('claude.')]
        self.assertEqual(rows, ['claude.chat', 'claude.executable', 'claude.wrapper', 'claude.initial_mode',
                                'claude.allow_bypass_permissions', 'claude.prompt_suggestions',
                                'claude.use_terminal', 'claude.ide',     # phase 5: two
                                'claude.disable_login_prompt', 'claude.python_env',    # p8: two
                                'claude.spinner_verbs'])
        agents = [line for line in out.splitlines() if line.startswith('agents.')]
        self.assertEqual(agents[-11:], ['agents.ctrl_enter_sends', 'agents.scroll_on_send', 'agents.timestamps',
                                       'agents.focus_view', 'agents.archive_after_days',    # (phase 6)
                                       # phase 4 task 8: the selection chip's two, task 7's mentions
                                       'agents.attach_selection', 'agents.attach_open_file',
                                       'agents.respect_gitignore',
                                       'agents.autosave',           # phase 4 task 10
                                       'agents.location',           # phase 4 task 13
                                       'agents.continue_after_restart'])    # phase 6 (p6b): the last
        self.command('cmd toggle_word_wrap')            # a setting changed: the exit writes the file
        self.quit()
        saved = self.config.read_text(encoding='utf-8')
        self.assertEqual(chat.section(saved, 'claude')[3:], [
            'initial_mode =', 'allow_bypass_permissions = false', 'prompt_suggestions = true',
            'use_terminal = false', 'ide = true', 'disable_login_prompt = false', 'python_env = true',
            'spinner_verbs = append'])
        self.assertEqual(chat.section(saved, 'agents')[-11:], [
            'ctrl_enter_sends = false', 'scroll_on_send = true', 'timestamps = true', 'focus_view = false',
            'archive_after_days = 14',
            'attach_selection = true', 'attach_open_file = true', 'respect_gitignore = true',
            'autosave = true',                          # phase 4 task 10
            'location = panel',                         # (phase 4 task 13)
            'continue_after_restart = true'])           # (phase 6, p6b: the last)
        # changed, they are written back as they are; the env pairs still follow the last [claude] row
        claude = self.claude_section('initial_mode = acceptEdits\nallow_bypass_permissions = true\n'
                                     'prompt_suggestions = false\nspinner_verb = Zooming\nspinner_verbs = replace\n'
                                     'env.FOO = bar\nspinner_verb = Whooshing\n')
        self.start(claude, '[agents]\nctrl_enter_sends = true\nscroll_on_send = false\ntimestamps = false\n'
                           'focus_view = true\nautosave = false\n')
        out = self.command('print-settings')
        rows = [line for line in out.splitlines() if line.startswith('claude.')]
        self.assertEqual(rows[-5:], ['claude.python_env', 'claude.spinner_verbs',     # p8: python_env
                                     'claude.env.FOO=(set)', 'claude.spinner_verb=Zooming',
                                     'claude.spinner_verb=Whooshing'])
        self.command('cmd toggle_word_wrap')
        self.quit()
        saved = self.config.read_text(encoding='utf-8')
        self.assertEqual(chat.section(saved, 'claude'), [
            'chat = true', f'executable = {chat.FAKE}', f'wrapper = {chat.PYTHON}', 'initial_mode = acceptEdits',
            'allow_bypass_permissions = true', 'prompt_suggestions = false', 'use_terminal = false', 'ide = true',
            'disable_login_prompt = false', 'python_env = true',     # p8
            'spinner_verbs = replace',
            'env.FOO = bar', 'spinner_verb = Zooming', 'spinner_verb = Whooshing'])
        self.assertEqual(chat.section(saved, 'agents')[-11:-6], ['ctrl_enter_sends = true', 'scroll_on_send = false',
                                                                 'timestamps = false', 'focus_view = true',
                                                                 'archive_after_days = 14'])
        self.assertEqual(chat.section(saved, 'agents')[-3:], ['autosave = false', 'location = panel',
                                                              'continue_after_restart = true'])

    def mode_passed(self, extra):
        self.start(self.claude_section(extra))
        self.chat('hello')
        argv = self.starts()[-1]['argv']
        self.command('cmd toggle_word_wrap')
        self.quit()
        return [a for a in argv if a.startswith('--permission-mode=')], chat.section(
            self.config.read_text(encoding='utf-8'), 'claude')

    def test_initial_mode_takes_auto_and_bypass(self):
        passed, saved = self.mode_passed('initial_mode = auto\n')
        self.assertEqual(passed, ['--permission-mode=auto'])
        self.assertIn('initial_mode = auto', saved)
        # bypass is rhun's gate alone: without allow_bypass_permissions the conversation starts in default
        passed, saved = self.mode_passed('initial_mode = bypassPermissions\n')
        self.assertEqual(passed, ['--permission-mode=default'])
        self.assertIn('initial_mode = bypassPermissions', saved)
        passed, saved = self.mode_passed('initial_mode = bypassPermissions\nallow_bypass_permissions = true\n')
        self.assertEqual(passed, ['--permission-mode=bypassPermissions'])

    def test_lists_are_cached_after_a_start(self):
        self.start()
        self.assertEqual(self.head()['read'], '0')
        self.chat('hello')
        self.command('agent-release')
        self.until_gone()
        out = self.cfg()
        self.assertEqual(self.head()['read'], '1')
        self.assertEqual(self.lines('model'), [
            f'default\tDefault (recommended)\tOpus 5.5\teffort\t{LEVELS}',
            f'sonnet\tSonnet\tSonnet 5\teffort\t{LEVELS}'])
        cmds = self.lines('cmd')
        self.assertIn('compact\tClear history but keep a summary\t-\t-\t-\tsend\tcli', cmds)
        self.assertIn("usage\tShow session cost, plan usage, and what's contributing to your limits\t-\tcost stats"
                      "\t-\tusage\tlocal,cli", cmds)       # phase 7: the built-in /usage opens Account & usage
        self.assertIn('copy\tCopy the last response to clipboard (/copy 2 for the one before)\t[N]\t-\t-\tcopy\tlocal',
                      cmds)
        self.assertIn('version 2.1.330', out)
        self.assertIn('fast off -', out)
        path = self.state_file()
        self.assertTrue(path.exists(), out)
        self.assertEqual(path.parent, self.work / 'state/rhun')
        self.assertTrue(path.name.endswith('.agents-claude'), path)
        text = path.read_text(encoding='utf-8')
        self.assertTrue(text.startswith('agentcfg\t1\n'), text)
        self.assertIn('cmd\tcompact\t', text)
        self.assertIn('model\tsonnet\tSonnet\tSonnet 5\t32\t' + LEVELS, text)
        self.assertEqual(self.head()['dirty'], '0')

    def test_levels_flags_and_unavailable_models(self):
        self.start(env={'FAKE_CLAUDE_MODELS': 'effort,nothink,auto,fast,unavailable'})
        self.chat('hello')
        self.assertEqual(self.lines('model'), [
            'default\tDefault (recommended)\tOpus 5.5\tthinkoff,auto,fast,effort\t'
            'low:Low,medium:Medium,high:High,xhigh:Extra high,max:Max',
            f'sonnet\tSonnet\tSonnet 5\teffort\t{LEVELS}',
            'haiku\tHaiku\tNot on your plan\toff\t-'])

    def test_a_fresh_rhun_shows_the_lists_without_a_process(self):
        self.start()
        self.chat('hello')
        self.quit()
        self.start()
        self.assertEqual(self.head()['read'], '0')
        self.assertEqual(self.lines('model'), [])        # print-agent-cfg reads nothing
        self.command('agent-new claude')
        self.command('agent-models')
        self.assertEqual(self.head()['read'], '1')
        self.assertEqual([m.split('\t')[0] for m in self.lines('model')], ['default', 'sonnet'])
        self.assertIn('version 2.1.330', self.cfg())
        self.assertEqual(re.findall(r'\b\d+\b', self.command('print-uproc')), [])
        self.assertEqual(len(self.starts()), 1)

    def test_the_cache_holds_no_account(self):
        self.start()
        self.chat('hello')
        self.quit()
        data = (self.state_file_after_quit()).read_bytes()
        self.assertNotIn(b'user@example.com', data)
        self.assertNotIn(b'Organization', data)
        self.assertNotIn(b'Claude Max', data)

    def state_file_after_quit(self):
        files = list((self.work / 'state/rhun').glob('*.agents-claude'))
        self.assertEqual(len(files), 1, files)
        return files[0]

    def test_reading_reads_no_state_file(self):
        for sid in ('s1', 's2', 's3'):
            self.seed(sid)
        self.start()
        path = self.state_file()
        self.assertFalse(path.exists())
        path.write_text('agentcfg\t1\nversion\t9.9.9\nmodel\tseeded\tSeeded\tfrom the file\t0\t\n',
                        encoding='utf-8')
        self.assertEqual(len(self.listed()), 3)
        for n in (1, 2, 3):
            self.command(f'print-agents {n}')
            self.command('move 1000 300')
            self.command('scroll 5')
            self.command('scroll -5')
            self.command(f'click {chat.BACK[0]} {chat.BACK[1]}')
        self.assertEqual(self.head()['read'], '0')
        self.assertNotIn('9.9.9', self.cfg())
        self.assertEqual(self.starts(), [])
        self.command('print-agents 1')
        self.command('agent-models')                    # a picker is a writer's action: now it is read
        self.assertEqual(self.head()['read'], '1')
        self.assertIn('version 9.9.9', self.cfg())
        self.assertEqual(self.lines('model'), ['seeded\tSeeded\tfrom the file\t-\t-'])

    def test_project_switch_flushes_to_the_old_projects_file(self):
        other = self.work / 'other'
        other.mkdir()
        self.start()
        first = self.state_file()
        self.command('agent-new claude')
        self.command('agent-cfg-set model sonnet')
        self.command('agent-cfg-set think 0')
        self.assertEqual(self.head()['dirty'], '1')
        self.assertFalse(first.exists())                # a choice alone is not written yet
        self.command('open ' + str(other))
        self.command('wait 200')
        second = self.state_file()
        self.assertNotEqual(first, second)
        self.assertIn('project\tsonnet\t\t-\t0\n', first.read_text(encoding='utf-8'))
        self.assertIn('project model=- effort=- ultra=- think=-', self.cfg())
        self.quit()
        self.assertFalse(second.exists())               # nothing changed there: nothing written

    def test_no_project_keeps_state_in_memory(self):
        self.start(target='--empty')
        self.assertEqual(self.head()['file'], '0')
        self.assertEqual(self.head()['path'], '-')
        self.command('agent-new claude')
        self.command('agent-models')
        self.command('agent-cfg-set model sonnet')
        self.assertIn('project model=sonnet ', self.cfg())
        self.quit()
        state = self.work / 'state'
        self.assertEqual([p for p in state.rglob('*') if '.agents-' in p.name], [])

    def test_commands_changed_replaces_the_list(self):
        # the list that follows initialize is the whole one: here without context, with a skill
        self.start(env={'FAKE_CLAUDE_COMMANDS_CHANGED': 'compact,usage,review'})
        self.chat('hello')
        names = self.until(lambda: (lambda n: n if 'review' in n else None)(
            [c.split('\t')[0] for c in self.lines('cmd')]), 'the changed list')
        self.assertEqual(names, ['compact', 'usage', 'review', 'resume', 'continue',
                                 'rewind', 'checkpoint', 'undo', 'export', 'clear', 'model', 'plan',
                                 'copy', 'login', 'logout', 'status', 'skills', 'help', 'memory', 'context',
                                 'btw', 'tasks', 'bashes', 'bookmarks', 'remote-control', 'rc', 'chrome', 'agents',
                                 'mcp', 'hooks', 'permissions', 'allowed-tools', 'sandbox', 'plugin', 'plugins',
                                 'marketplace'])
        # (resume, continue: phase 6's history; status to context: phase 7's dialogs; btw to agents: p7c's,
        #   claude-panels.py; mcp to marketplace: p7b's configuration dialogs, claude-dialogs2.py;
        #   rewind to export: p6b's, claude-fork.py)
        self.assertIn('review\tSkill review\t-\t-\t-\tsend\tcli', self.lines('cmd'))
        text = self.state_file().read_text(encoding='utf-8')
        self.assertIn('cmd\treview\t', text)
        self.assertNotIn('cmd\tcontext\tShow current context usage', text)     # rhun's own /context only

    def test_settings_are_asked_after_initialize(self):
        self.start(env={'FAKE_CLAUDE_MODELS': 'ultra'})
        self.chat('hello')
        requests = [m['request']['subtype'] for m in self.stdin() if m.get('type') == 'control_request']
        self.assertEqual(requests, ['initialize', 'get_settings'])
        live = self.command('print-agent-live')
        self.assertRegex(live, ' model=claude-opus-5-5 effort=high ultra=0 think=1 fast=off held=0 ctx=0 cache=- '
                         'suggest=[01] ')            # (the fake suggests a prompt after the turn: ComposerTest)
        self.assertEqual([r for r in self.records() if 'update_settings' in str(r.get('stdin', ''))], [])

    def test_a_settings_error_does_not_stop_the_start(self):
        # the error is kept for the settings band (drawn by a later task); the conversation goes on
        self.start(env={'FAKE_CLAUDE_SETTINGS_ERROR': 'Unexpected token'})
        self.chat('hello')
        live = self.command('print-agent-live')
        self.assertTrue(live.startswith('state=ready pid=1 '), live)
        self.assertIn(' model=claude-opus-5-5 effort=high ultra=- ', live)
        self.assertEqual(self.thread()[-1], chat.REPLY + 'ok: hello')


class QueueTest(CfgCase):
    """Messages sent while Claude works: written at once with a uuid, shown queued until the CLI starts them
    (finding 17), and back in their own conversation's box when they will not run."""

    NOT_SENT = 'toast=A queued message was not sent.'

    def users(self):
        """The user messages the fake read."""
        return [m for m in self.stdin() if m.get('type') == 'user']

    def queued(self):
        """print-agents' queued rows (after the thread)."""
        return [line for line in self.command('print-agents').splitlines() if line.startswith('queued ')]

    def held(self):
        return int(re.search(r' held=(\d+)', self.command('print-agent-live')).group(1))

    def box(self):
        return self.command('print-agent-input').split(' focus=')[0]

    def until_read(self, n):
        """Until the fake read n user messages."""
        return self.until(lambda: (lambda u: u if len(u) >= n else None)(self.users()), f'{n} messages read')

    def test_a_message_during_a_turn_is_written_at_once(self):
        self.start()
        self.chat('held', 'working')
        self.command('agent-prompt more')
        self.assertEqual(self.box(), 'input=')            # the box empties, as for any message that went
        users = self.until_read(2)
        self.assertEqual([m['message']['content'][0]['text'] for m in users], ['held', 'more'])
        for m in users:
            self.assertRegex(m['uuid'], chat.UUID4)
        self.assertNotEqual(users[0]['uuid'], users[1]['uuid'])
        self.assertEqual(self.command('print-agents').splitlines()[-1], 'queued more')
        self.assertNotIn('user more', self.thread())
        self.assertEqual(self.held(), 1)
        self.command('wait-agent ready 20000')
        self.assertEqual(self.thread(), ['user held', chat.REPLY + '1', 'user more', 'agent ok: more'])
        self.assertEqual(self.queued(), [])
        self.assertEqual(self.held(), 0)

    def test_prompts_waiting_for_a_start_show_queued(self):
        self.start(env={'FAKE_CLAUDE_INIT_MS': '800'})
        self.command('agent-new claude')
        self.command('agent-prompt held')
        self.command('agent-prompt two')
        self.assertIn(' queued=2 ', self.live())
        self.assertEqual(self.queued(), ['queued held', 'queued two'])
        self.assertEqual(self.thread(), [])
        # the handshake: the first is a row and runs, the second is written and held
        self.until(lambda: 'user held' in self.thread(), 'the first one runs')
        self.assertEqual(self.queued(), ['queued two'])
        self.assertEqual(self.held(), 1)
        self.command('wait-agent ready 20000')
        self.assertEqual(self.thread(), ['user held', chat.REPLY + '1', 'user two', 'agent ok: two'])
        self.assertEqual([m['message']['content'][0]['text'] for m in self.users()], ['held', 'two'])
        self.assertEqual(self.queued(), [])

    def scroll(self):
        live = self.command('print-agent-live')
        return {k: int(v) for k, v in re.findall(r' (scroll|max|follow)=(\d+)', live)}

    def test_queued_rows_count_in_the_scroll(self):
        self.start(env={'FAKE_CLAUDE_INIT_MS': '3000'})
        self.command('resize 1280 300')             # (a prompt is clipped at 60 px: phase 3 task 8)
        self.command('cmd focus_agents')
        self.command('agent-new claude')
        long = ' '.join('word%d' % i for i in range(400))
        self.command('agent-prompt ' + long)
        self.command('wait 50')
        first = self.scroll()
        self.command('agent-prompt ' + long)
        self.command('wait 50')
        second = self.scroll()
        self.command('agent-prompt ' + long)
        self.command('wait 50')
        third = self.scroll()
        self.assertGreater(second['max'], first['max'])
        self.assertEqual(third['max'] - second['max'], second['max'] - first['max'])
        self.assertEqual(third['follow'], 1)
        self.assertEqual(third['scroll'], third['max'])

    def test_sending_follows_the_end_again(self):
        # [agents] scroll_on_send (default on): scrolled up, a message sent during a turn follows the end
        self.start()
        self.chat('long', 'ready', 20000)
        self.command('agent-prompt held')
        self.command('wait-agent working 5000')
        self.command('move 1000 300')
        self.command('scroll -5')
        self.command('wait 100')
        self.assertEqual(self.scroll()['follow'], 0)
        self.command('agent-prompt more')
        self.command('wait 100')
        self.assertEqual(self.scroll()['follow'], 1)
        self.command('wait-agent ready 20000')

    def test_held_message_survives_stop(self):
        self.start()
        self.chat('held', 'working')
        self.command('agent-prompt more')
        self.until_read(2)
        self.command('agent-stop')
        self.command('wait-agent ready 20000')
        interrupts = [m for m in self.stdin() if m.get('type') == 'control_request'
                      and m['request'].get('subtype') == 'interrupt']
        self.assertEqual(len(interrupts), 1)
        self.assertNotIn('cancel_queued', interrupts[0]['request'])
        # the reply's label names the model where it changed since the last label shown: the interrupted
        #   reply before it shows one only when the stop came after its first text (a race of the test's,
        #   not a rule), so the label is not compared
        thread = [re.sub(r'^agent\(\S+\) ', 'agent ', row) for row in self.thread()]
        self.assertEqual(thread.count('user more'), 1, thread)
        self.assertEqual(thread[-2:], ['user more', 'agent ok: more'])
        self.assertIn('info Interrupted', thread[:-2])
        self.assertEqual([m['message']['content'][0]['text'] for m in self.users()], ['held', 'more'])
        self.assertEqual(self.queued(), [])

    def test_held_message_after_a_crash_is_in_its_box(self):
        self.start()
        self.chat('exit 1500', 'working')
        self.command('agent-prompt more')
        self.until_read(2)
        self.assertEqual(self.queued(), ['queued more'])
        self.command('wait-agent failed 10000')
        self.assertEqual(self.box(), 'input=more')
        self.assertEqual(self.queued(), [])
        self.assertNotIn('user more', self.thread())
        self.assertEqual(self.command('print-toast').strip(), self.NOT_SENT)

    def test_refused_held_message_comes_back(self):
        self.start(env={'FAKE_CLAUDE_REFUSE_HELD': '1'})
        self.chat('held', 'working')
        self.command('agent-prompt more')
        self.until(lambda: self.box() == 'input=more', 'the refused message back in the box')
        self.assertEqual(self.command('print-toast').strip(), self.NOT_SENT)
        self.assertEqual(self.queued(), [])
        self.command('wait-agent ready 20000')     # the held turn's result was the last one waited for
        self.assertNotIn('user more', self.thread())
        self.assertEqual(self.held(), 0)

    def test_discarded_message_goes_back_to_its_own_conversation(self):
        self.start(env={'FAKE_CLAUDE_DISCARD_HELD': '1'})
        self.command('cmd focus_agents')
        self.chat('held', 'working')
        self.command('agent-prompt more')
        self.until_read(2)
        first = self.sid()
        self.command('agent-new claude')                # B, while A's message waits, with text of its own
        self.command('agent-type b')
        self.until(lambda: [r for r in self.records() if 'discarded' in r], 'the discard')
        self.command('wait 100')
        self.assertNotEqual(self.sid(), first)
        self.assertEqual(self.box(), 'input=b')         # B's box is untouched
        self.assertEqual(self.command('print-toast').strip(), self.NOT_SENT)
        self.command(f'click {chat.BACK[0]} {chat.BACK[1]}')
        rows = [line for line in self.command('print-agents').splitlines() if line.startswith('Claude')]
        for n in range(1, len(rows) + 1):
            self.command(f'print-agents {n}')
            if self.sid() == first:
                break
            self.command(f'click {chat.BACK[0]} {chat.BACK[1]}')
        self.assertEqual(self.sid(), first)
        self.command('wait 50')
        self.assertTrue(self.box().startswith('input=more'), self.box())
        self.assertEqual(self.queued(), [])

    def test_the_17th_held_message_is_refused(self):
        self.start()
        self.chat('held', 'working')
        for n in range(1, 17):
            self.command(f'agent-prompt m{n}')
        self.assertEqual(self.held(), 16)
        self.command('agent-prompt m17')
        self.assertEqual(self.box(), 'input=m17')
        self.assertEqual(self.command('print-toast').strip(), 'toast=Sixteen messages are already waiting.')
        self.assertEqual(self.held(), 16)
        self.command('wait-agent ready 30000')
        self.assertEqual([m['message']['content'][0]['text'] for m in self.users()],
                         ['held'] + ['m%d' % n for n in range(1, 17)])
        self.assertEqual(self.thread()[-2:], ['user m16', 'agent ok: m16'])

    def test_replay_alone_starts_it(self):
        self.start(env={'FAKE_CLAUDE_NO_LIFECYCLE': '1'})
        self.chat('held', 'working')
        self.command('agent-prompt more')
        self.until_read(2)
        self.assertEqual(self.queued(), ['queued more'])
        self.command('wait-agent ready 20000')
        self.assertEqual(self.thread(), ['user held', chat.REPLY + '1', 'user more', 'agent ok: more'])
        self.assertEqual(self.queued(), [])

    def initialize(self):
        # phase 4 task 9's members (rhun's in-process server and its note) are tests/claude-mcp.py's, task 10's
        # hooks tests/claude-hooks.py's
        return [{k: v for k, v in r['initialize'].items() if k not in chat.P4_INIT + ('hooks',)}
                for r in self.records() if 'initialize' in r]

    def test_the_new_flags_are_passed(self):
        self.start(env={'FAKE_CLAUDE_ECHO_ENV': 'CLAUDE_CODE_QUESTION_PREVIEW_FORMAT'})
        self.chat('hello')
        start = self.starts()[-1]
        argv = start['argv']
        self.assertIn('--replay-user-messages', argv)
        self.assertIn('--max-thinking-tokens=31999', argv)
        self.assertEqual([a for a in argv if a.startswith(('--model', '--effort', '--thinking', '--allow-'))], [])
        self.assertEqual(start['env']['CLAUDE_CODE_QUESTION_PREVIEW_FORMAT'], 'markdown')
        self.assertEqual(self.initialize(), [{'promptSuggestions': True, 'supportedDialogKinds': DIALOG_KINDS,
                                             'perTaskStopAffordance': True,       # phase 3 task 4
                                             'forwardNestedSubagentToolCalls': True, 'hooks': AUTOSAVE_HOOKS}])
        # the project's choices, the remembered default mode and the bypass setting at the next start
        self.command('agent-cfg-set model sonnet')
        self.command('agent-cfg-set effort low')
        self.command('agent-cfg-set think 0')
        self.command('agent-cfg-set newmode acceptEdits')
        self.command('agent-release')
        self.until_gone()
        self.command('agent-prompt again')
        self.command('wait-agent ready 10000')
        argv = self.starts()[-1]['argv']
        self.assertEqual(len(self.starts()), 2)
        self.assertIn('--model=sonnet', argv)
        self.assertIn('--effort=low', argv)
        self.assertIn('--thinking=disabled', argv)
        self.assertNotIn('--max-thinking-tokens=31999', argv)
        self.assertIn('--permission-mode=acceptEdits', argv)
        self.assertNotIn('--allow-dangerously-skip-permissions', argv)

    def test_bypass_setting_passes_its_flag_and_its_absence_says_so(self):
        self.start(self.claude_section('initial_mode = bypassPermissions\n'))
        self.chat('hello')
        argv = self.starts()[-1]['argv']
        self.assertIn('--permission-mode=default', argv)
        self.assertNotIn('--allow-dangerously-skip-permissions', argv)
        self.assertIn('info Bypass permissions is off in Settings > Claude Code.', self.thread())
        self.quit()
        self.start(self.claude_section('initial_mode = bypassPermissions\nallow_bypass_permissions = true\n'))
        self.chat('hello')
        argv = self.starts()[-1]['argv']
        self.assertIn('--permission-mode=bypassPermissions', argv)
        self.assertIn('--allow-dangerously-skip-permissions', argv)
        self.assertNotIn('info Bypass permissions is off in Settings > Claude Code.', self.thread())

    def test_suggestions_off_in_initialize(self):
        self.start(self.claude_section('prompt_suggestions = false\n'))
        self.chat('hello')
        self.assertEqual(self.initialize(), [{'promptSuggestions': False, 'supportedDialogKinds': DIALOG_KINDS,
                                             'perTaskStopAffordance': True,       # phase 3 task 4
                                             'forwardNestedSubagentToolCalls': True, 'hooks': AUTOSAVE_HOOKS}])


SECTIONS = ['Context', 'Model', 'Customize', 'Settings', 'Support', 'Slash Commands']


class MenuCase(chat.DrivenCase):
    """print-agent-menu read back: the popup's head, its sections, its rows."""

    def menu(self):
        return self.command('print-agent-menu')

    def head(self):
        first = self.menu().splitlines()[0]
        return dict(word.split('=', 1) for word in first.split(' '))

    def sections(self):
        return [line[len('section '):] for line in self.menu().splitlines() if line.startswith('section ')]

    def rows(self):
        """Each row as (section, label, description, trail, flags)."""
        out, section = [], None
        for line in self.menu().splitlines():
            if line.startswith('section '):
                section = line[len('section '):]
            elif line.startswith('row '):
                label, desc, trail, flags = line.split(' ', 2)[2].split('\t')
                out.append((section, label, desc, trail, flags))
        return out

    def labels(self):
        return [r[1] for r in self.rows()]

    def box(self):
        return re.match(r'input=(.*?) focus=', self.command('print-agent-input')).group(1)

    def ready(self, prompt='hello'):
        """A conversation whose program has told its lists (initialize's answer)."""
        self.start()
        self.chat(prompt)
        self.until(lambda: 'compact' in self.command('print-agent-cfg'), 'the lists')


class MenuTest(MenuCase):
    def test_typing_a_slash_opens_the_menu(self):
        self.ready()
        self.assertTrue(self.menu().startswith('popup=none'))
        self.command('agent-type /')
        head = self.head()
        self.assertEqual((head['popup'], head['filter'], head['sel']), ('menu', '/', '0'))
        self.assertEqual(head['owner'], self.sid())
        self.assertEqual(self.sections(), SECTIONS)
        rows = self.rows()
        self.assertIn(('Context', 'Clear conversation', 'Start a new conversation', '-', '-'), rows)
        self.assertNotIn('New conversation', self.labels())          # filter-only
        self.assertIn(('Model', 'Switch model…', 'Change the AI model', 'Default (recommended)', '-'), rows)
        self.assertIn(('Model', 'Effort (High)', 'Set how hard the model tries', '-', 'levels=high'), rows)
        self.assertNotIn('Thinking', self.labels())                  # no model lets it be switched off
        self.assertNotIn('Toggle fast mode', self.labels())          # sdk_opt_in_required
        self.assertIn(('Slash Commands', '/compact', 'Clear history but keep a summary', '-', '-'), rows)
        self.assertIn(('Slash Commands', '/copy', 'Copy the last response to clipboard (/copy 2 for the one before)',
                       '[N]', '-'), rows)
        self.assertIn(('Slash Commands', '/plan', 'Turn on plan mode or view the plan', '[open|<description>]', '-'),
                      rows)
        slash = [r[1] for r in rows if r[0] == 'Slash Commands']
        self.assertEqual(slash, ['/compact', '/context', '/usage', '/export', '/plan', '/copy',
                                 '/btw', '/tasks', '/remote-control', '/chrome'])    # p7c's (claude-panels.py); /export p6b's
        self.assertNotIn('/clear', slash)                            # a target of its own: not listed twice
        self.assertIn('foot v2.1.330', self.menu())
        self.assertEqual([r for r in self.records() if r.get('stdin') and '"/' in r['stdin']], [])

    def test_the_filter_ranks_exact_then_prefix(self):
        self.ready()
        self.command('agent-type /co')
        self.assertEqual(self.head()['sel'], '1')                    # the first row matches what is typed
        rows = self.rows()
        self.assertEqual(rows[0][0], 'Slash Commands')               # the section of the best rows comes first
        self.assertEqual(sorted(r[1] for r in rows[:3]), ['/compact', '/context', '/copy'])
        self.assertIn('Clear conversation', self.labels())           # a word of it starts with "co"
        self.command('key BackSpace')
        self.command('key BackSpace')
        self.command('agent-type copy')
        self.assertEqual(self.head()['filter'], '/copy')
        self.assertEqual(self.labels()[0], '/copy')                  # an exact name first of all
        self.command('key BackSpace')
        self.command('key BackSpace')
        self.command('key BackSpace')
        self.command('key BackSpace')
        self.command('agent-type cost')                              # an alias is a name
        self.assertEqual(self.labels()[0], '/usage')

    def test_button_mode_hides_slash_commands(self):
        self.ready()
        self.command('agent-menu')
        head = self.head()
        self.assertEqual((head['popup'], head['filter'], head['sel']), ('menu', '', '0'))
        self.assertEqual(self.sections(), SECTIONS[:-1])
        self.assertIn('focus=1', self.command('print-agent-input'))
        self.command('agent-type co')                                # the filter has the keys, not the box
        self.assertEqual(self.head()['filter'], 'co')
        self.assertEqual(self.box(), '')
        self.assertNotIn('Slash Commands', self.sections())
        self.assertEqual(self.head()['sel'], '1')
        self.command('key Escape')
        self.assertTrue(self.menu().startswith('popup=none'))
        self.command('agent-menu /co')
        self.assertIn('Slash Commands', self.sections())
        self.command('key Escape')
        self.assertIn('focus=1', self.command('print-agent-input'))  # the box has the keys again

    def test_tab_completes_and_the_hint_shows(self):
        self.ready()
        self.command('agent-type /comp')
        self.command('key Tab')
        self.assertEqual(self.box(), '/compact ')
        menu = self.menu()
        self.assertTrue(menu.startswith('popup=none'), menu)
        self.assertNotIn('hint ', menu)                              # compact has no argument hint
        self.command('key BackSpace')
        for _ in range(len('/compact')):
            self.command('key BackSpace')
        self.command('agent-type /cop')
        self.command('key Tab')
        self.assertEqual(self.box(), '/copy ')
        hint = re.search(r'^hint (.*) at (\d+) (\d+)$', self.menu(), re.M)
        self.assertIsNotNone(hint, self.menu())
        self.assertEqual(hint.group(1), '[N]')
        x, y = int(hint.group(2)), int(hint.group(3))
        self.assertGreater(x, 922 - 100)                             # after the text, in the panel (x 922+)
        self.command('agent-type 2')
        self.assertNotIn('hint ', self.menu())                       # something typed after the space
        self.assertEqual(self.prompts(), ['hello'])

    def test_enter_on_a_whole_command_sends_it(self):
        self.ready()
        self.command('agent-type /compact')
        self.assertEqual(self.labels()[0], '/compact')
        self.command('key Return')
        self.until(lambda: '/compact' in self.prompts(), 'the command is sent')
        self.assertEqual(self.prompts(), ['hello', '/compact'])
        self.assertEqual(self.box(), '')
        self.assertTrue(self.menu().startswith('popup=none'))

    def test_a_path_is_not_a_command(self):
        self.ready()
        self.command('agent-type /usr/bin')
        self.assertTrue(self.menu().startswith('popup=none'))
        self.command('key Return')
        self.until(lambda: '/usr/bin' in self.prompts(), 'the path is sent')

    def test_a_description_with_line_ends_is_one_line(self):
        # the real CLI's claude-api skill has line ends in its description (finding 26): its row shows one
        # line, the line ends as spaces, as the extension's one-line row shows it; the state file keeps that
        self.start(env={'FAKE_CLAUDE_COMMANDS_CHANGED': 'compact,claude-api'})
        self.chat('hello')
        self.until(lambda: 'claude-api' in self.command('print-agent-cfg'), 'the changed list')
        self.command('agent-type /claude')
        flat = 'Reference for the Claude API TRIGGER when the code imports it. SKIP otherwise.'
        self.assertIn(('Slash Commands', '/claude-api', flat, '-', '-'), self.rows())
        self.assertIn(f'claude-api\t{flat}\t', self.command('print-agent-cfg'))

    def test_no_matching_commands_lets_enter_send(self):
        self.ready()
        self.command('agent-type /zzz')
        self.assertIn('\nempty No matching commands\n', self.menu())
        self.assertEqual(self.head()['sel'], '0')
        self.command('key Return')
        self.until(lambda: '/zzz' in self.prompts(), 'sent as text')

    def test_clear_conversation_opens_a_new_draft(self):
        self.ready()
        sid = self.sid()
        self.command('agent-type /clear')
        self.assertEqual(self.labels()[0], 'Clear conversation')
        self.command('key Return')
        self.assertIn(' new=claude ', self.command('print-agent-input'))
        self.assertEqual(self.box(), '')
        self.assertEqual(self.prompts(), ['hello'])
        # through the driver's table too, as Enter sends it (agent-prompt goes by no popup)
        self.command('agent-prompt again')
        self.command('wait-agent ready')
        self.command('agent-prompt /clear')
        self.assertIn(' new=claude ', self.command('print-agent-input'))
        self.assertEqual(self.prompts(), ['hello', 'again'])
        listed = self.until(lambda: (lambda r: r if len(r) == 2 else None)(self.listed()), 'both stay listed')
        self.assertEqual(len(listed), 2)
        self.assertTrue(sid)

    def test_typed_dialog_command_opens_rhuns_dialog(self):
        # phase 7: /status opens rhun's Status dialog (the CLI would answer "isn't available in this
        # environment", finding 22); nothing is sent as text (tests/claude-dialogs.py has the rest)
        self.ready()
        self.command('agent-prompt /status')
        self.assertTrue(self.command('print-agent-dialog').startswith('dialog=status '))
        self.assertEqual(self.prompts(), ['hello'])

    def toast(self):
        return self.command('print-toast').strip()

    def test_copy_takes_the_last_reply(self):
        self.start()
        self.chat('hello')
        self.command('agent-prompt /copy')
        self.assertEqual(self.toast(), 'toast=Copied to clipboard (9 characters, 1 line)')
        self.assertEqual(self.prompts(), ['hello'])
        self.command('agent-prompt /copy 9')
        self.assertEqual(self.toast(), 'toast=Only 1 assistant message available to copy')
        self.command('agent-prompt /copy two')
        self.assertEqual(self.toast(), 'toast=Usage: /copy [N] where N is 1 (latest), 2, 3, … Got: two')
        self.command('agent-prompt again')
        self.command('wait-agent ready')
        self.command('agent-prompt /copy 2')
        self.assertEqual(self.toast(), 'toast=Copied to clipboard (9 characters, 1 line)')
        self.assertEqual(self.prompts(), ['hello', 'again'])

    def test_menu_starts_nothing(self):
        self.ready()
        self.quit()
        self.start()
        rows = self.listed()
        self.assertEqual(len(rows), 1, rows)
        self.command('print-agents 1')
        self.command('agent-menu /')
        self.assertIn('/compact', self.labels())                     # from the project's record
        self.assertIn('read=1', self.command('print-agent-cfg'))
        self.assertEqual(re.findall(r'\b\d+\b', self.command('print-uproc')), [])
        self.assertEqual(len(self.starts()), 1)
        self.assertIn(' pid=0 ', self.command('print-agent-live'))

    def test_menu_closes_when_the_conversation_changes(self):
        self.ready()
        self.command('agent-type /')
        self.assertEqual(self.head()['popup'], 'menu')
        self.command(f'click {chat.BACK[0]} {chat.BACK[1]}')
        self.assertTrue(self.menu().startswith('popup=none'))
        self.command('print-agents 1')
        self.command('agent-menu')
        self.assertEqual(self.head()['popup'], 'menu')
        self.command('agent-new claude')                             # the box is another's
        self.assertTrue(self.menu().startswith('popup=none'))

    def test_menu_fits_every_size(self):
        self.ready()
        for opener in ('agent-menu', 'agent-type /'):
            self.command(opener)
            lines = self.command('print-agent-menu fit').splitlines()
            self.assertEqual(len(lines), 25 * 34)
            for line in lines:
                r = {k: int(v) for k, v in (f.split('=') for f in line.split())}
                what = opener + ' ' + line
                self.assertGreaterEqual(r['x'], 0, what)
                self.assertLessEqual(r['x'] + r['pw'], r['w'], what)
                self.assertGreaterEqual(r['left'], r['x'], what)
                self.assertLessEqual(r['right'], r['x'] + r['pw'], what)
                self.assertGreater(r['label'], 0, what)
                self.assertGreater(r['h'], 0, what)
            self.command('key Escape')

    def test_escape_closes_the_menu_first(self):
        self.start()
        self.chat('slow', wait='working')
        self.command('agent-type /')
        self.assertEqual(self.head()['popup'], 'menu')
        self.command('key Escape')
        self.assertTrue(self.menu().startswith('popup=none'))
        self.assertTrue(self.command('print-agent-live').startswith('state=working '))
        interrupts = [m for m in self.stdin() if m.get('request', {}).get('subtype') == 'interrupt']
        self.assertEqual(interrupts, [])
        self.assertEqual(self.box(), '/')
        self.assertTrue(self.menu().startswith('popup=none'))        # not again while the text is the same
        self.command('key Escape')                                   # then Escape is phase 1's: Stop
        self.until(lambda: [m for m in self.stdin() if m.get('request', {}).get('subtype') == 'interrupt'],
                   'the interrupt')

    def test_a_drafts_slash_belongs_to_its_new_conversation(self):
        self.ready()
        self.command('agent-new claude')
        self.command('agent-type /co')                               # the draft becomes a conversation
        head = self.head()
        self.assertEqual(head['popup'], 'menu')
        self.assertNotEqual(head['owner'], '-')
        self.assertEqual(self.labels()[0][:3], '/co')

    def test_model_command_opens_the_picker(self):
        self.ready()
        self.command('agent-prompt /model')
        head = self.head()
        self.assertEqual(head['popup'], 'models')
        self.assertEqual([r[1:3] for r in self.rows()][:2], [('Default (recommended)', 'Opus 5.5'),
                                                             ('Sonnet', 'Sonnet 5')])
        self.assertEqual(self.prompts(), ['hello'])                  # nothing went to the program
        self.assertEqual(self.box(), '')
        self.command('key Escape')
        self.assertTrue(self.menu().startswith('popup=none'))

    def test_reply_links_ask_before_opening(self):
        opened = self.work / 'opened'
        opener = self.work / 'opener.sh'
        opener.write_text(f'#!/bin/sh\necho "$1" >> {opened}\n', encoding='utf-8')
        opener.chmod(0o755)
        self.start(env={'RHUN_OPEN_URL': str(opener)})
        self.chat('see [the docs](https://example.com/docs)')
        n = len(self.thread())
        where = None
        for line in self.command(f'print-agent-row {n}').splitlines():
            match = re.match(r'link (.*) -> (.*) at (-?\d+) (-?\d+)$', line)
            if match:
                where = (int(match.group(3)), int(match.group(4)))
        self.assertIsNotNone(where)
        self.command('click %d %d' % where)
        self.command('wait 50')
        palette = self.command('print-palette').splitlines()
        self.assertEqual(palette[0], 'choose=Claude Code wants to open example.com in your browser: '
                                     'https://example.com/docs')
        self.assertEqual([line[2:] for line in palette if line.startswith(('  ', '> '))],
                         ['Open', 'Copy Link', 'Cancel'])
        self.command('wait 200')
        self.assertFalse(opened.exists())                            # nothing opens until Open
        self.command('key Escape')
        self.command('wait 200')
        self.assertFalse(opened.exists())
        self.command('click %d %d' % where)
        self.command('wait 50')
        self.command('key Return')                                   # Open
        self.until(lambda: opened.exists() and opened.read_text(encoding='utf-8').strip(), 'opened')
        self.assertEqual(opened.read_text(encoding='utf-8'), 'https://example.com/docs\n')


class BandTest(MenuCase):
    def bands(self):
        return [line for line in self.command('print-agent-bands').splitlines() if line.startswith('band ')]

    def room(self):
        """The room bands_h gives the bands, and the room drawing them took: the same."""
        match = re.search(r'^room=(\d+) drawn=(\d+)$', self.command('print-agent-bands'), re.M)
        self.assertIsNotNone(match)
        self.assertEqual(match.group(1), match.group(2))
        return int(match.group(1))

    def test_bands_skeleton(self):
        self.start()
        self.chat('hello')
        self.assertEqual(self.bands(), [])
        self.command('agent-test-band error Something broke')
        bands = self.bands()
        self.assertEqual(len(bands), 1, bands)
        match = re.match(r'band error lines=1 close=(\d+),(\d+) Something broke$', bands[0])
        self.assertIsNotNone(match, bands)
        self.room()
        self.command('move %s %s' % match.groups())
        self.command('wait 700')
        self.assertIn('Dismiss error', self.command('print-tip'))
        self.command('click %s %s' % match.groups())
        self.assertEqual(self.bands(), [])
        self.command('agent-test-band error Something broke')         # the same text: it stays away
        self.assertEqual(self.bands(), [])
        self.command('agent-test-band error Something else broke')
        self.assertEqual(len(self.bands()), 1)
        self.command('agent-test-band error')                         # no text: it goes
        self.assertEqual(self.bands(), [])
        # a long text wraps at words, at most 4 lines; every kind stacks; the box keeps its room
        self.command('agent-test-band notice ' + ' '.join(['word%d' % i for i in range(200)]))
        self.command('agent-test-band settings Settings file failed to parse')
        bands = self.bands()
        self.assertEqual([b.split(' ')[1] for b in bands], ['settings', 'notice'])
        self.assertIn(' lines=4 ', bands[1])
        self.assertIn(' lines=1 ', bands[0])
        self.assertGreater(self.room(), 0)                            # the room for 5 lines is all drawn
        self.assertIn('box=1', self.command('print-agent-input'))
        self.assertEqual(self.thread()[-1], chat.REPLY + 'ok: hello')


LIMIT = 'Your prompt is %s over the limit of 50000 \u00b7 shorten it to send'
SEND_KEY = '\u2318 Enter' if chat.sys.platform == 'darwin' else 'Ctrl+Enter'


class ComposerTest(MenuCase):
    """The prompt box (agentcompose.s): send keys, history, drafts per conversation, the placeholder, the
    suggestion, the limit, invisible characters, the painted word."""

    bands = BandTest.bands

    def text(self):
        """The box's text (line breaks kept)."""
        return re.match(r'input=(.*?) focus=\d', self.command('print-agent-input'), re.S).group(1)

    def composer(self):
        """print-agent-composer as a dict ({} without a conversation's box)."""
        line = self.command('print-agent-composer').strip()
        return dict(word.split('=', 1) for word in line.split(' ')) if line else {}

    def placeholder(self):
        self.command('wait 50')                         # a frame drawn
        return self.command('print-agent-placeholder').rstrip('\n')[len('placeholder='):]

    def notice(self):
        """The notice band's text, or None."""
        for line in self.bands():
            match = re.match(r'band notice lines=\d+ close=\d+,\d+ (.*)$', line)
            if match:
                return match.group(1)
        return None

    def seed_prompts(self, prompts, sid='s2'):
        """A transcript of the project with these prompts, each answered; opened, the box focused."""
        folder = self.work / '.claude/projects' / chat.slug(self.project)
        folder.mkdir(parents=True, exist_ok=True)
        lines = []
        for n, text in enumerate(prompts):
            lines.append(json.dumps({'type': 'user', 'message': {'role': 'user', 'content': text},
                                     'cwd': self.project.as_posix(), 'sessionId': sid}))
            lines.append(json.dumps({'type': 'assistant', 'message': {
                'role': 'assistant', 'content': [{'type': 'text', 'text': 'reply %d' % n}]}}))
        (folder / (sid + '.jsonl')).write_text('\n'.join(lines) + '\n', encoding='utf-8')

    def open_seeded(self):
        self.open_listed()
        self.command('key Tab')                         # the panel's Tab: into the box

    def open_sid(self, sid):
        """Back to the list, then the conversation with that id."""
        self.command(f'click {chat.BACK[0]} {chat.BACK[1]}')
        rows = [line for line in self.command('print-agents').splitlines() if line.startswith('Claude')]
        for n in range(1, len(rows) + 1):
            self.command(f'print-agents {n}')
            self.command('wait 50')
            if self.sid() == sid:
                return
            self.command(f'click {chat.BACK[0]} {chat.BACK[1]}')
        self.fail('no conversation ' + sid)

    def test_enter_and_ctrl_enter(self):
        self.start()
        self.chat('hello')
        self.command('agent-type one')
        self.command('key shift+Return')
        self.command('agent-type two')
        self.command('key ctrl+j')                      # a line break, never Toggle Panel
        self.command('agent-type three')
        self.assertEqual(self.text(), 'one\ntwo\nthree')
        self.assertIn(' focus=1 ', self.command('print-agent-input'))
        self.assertIn(' term=0', self.command('print-panels'))
        self.command('key Return')
        self.until(lambda: 'one\ntwo\nthree' in self.prompts(), 'Enter sends')
        self.assertEqual(self.text(), '')
        self.command('wait-agent ready')
        self.command('agent-type four')
        self.command('key ctrl+Return')                 # Ctrl+Enter sends too
        self.until(lambda: 'four' in self.prompts(), 'Ctrl+Enter sends')
        self.command('wait-agent ready')
        self.quit()
        self.start(extra='[agents]\nctrl_enter_sends = true\n')
        rows = self.listed()
        self.assertEqual(len(rows), 1, rows)
        self.command('print-agents 1')
        self.command('key Tab')
        self.command('agent-type five')
        self.command('key Return')                      # a new line now
        self.command('agent-type six')
        self.command('key ctrl+j')
        self.assertEqual(self.text(), 'five\nsix\n')
        self.command('key shift+Return')
        self.command('agent-type seven')
        self.command('key ' + chat.MOD + '+Return')     # Ctrl+Enter (Cmd+Enter on macOS) sends
        self.until(lambda: 'five\nsix\n\nseven' in self.prompts(), 'Ctrl+Enter sends')
        self.assertEqual(self.text(), '')
        self.command('wait-agent ready')
        self.command('agent-type eight')
        self.command('key ctrl+Return')
        self.until(lambda: 'eight' in self.prompts(), 'Ctrl+Enter sends on every system')

    def test_history_up_and_down_restore_the_draft(self):
        self.seed_prompts(['first', 'second line one\nsecond line two', '  third  '])
        self.start()
        self.open_seeded()
        self.command('type draft')
        self.command('key Up')                          # the caret is not at the start: the box's own Up
        self.assertEqual(self.text(), 'draft')
        self.command('key Home')
        self.command('key Up')
        self.assertEqual(self.text(), 'third')          # newest first, trimmed
        self.command('key Up')
        self.assertEqual(self.text(), 'second line one\nsecond line two')
        self.command('key Up')
        self.assertEqual(self.text(), 'first')
        self.command('key Up')                          # the oldest stays
        self.assertEqual(self.text(), 'first')
        self.command('key Down')                        # the caret is at the start: the box's own Down
        self.assertEqual(self.text(), 'first')
        self.command('key End')
        self.command('key Down')
        self.assertEqual(self.text(), 'second line one\nsecond line two')
        self.command('key Down')
        self.assertEqual(self.text(), 'third')
        self.command('key Down')                        # past the newest: the draft again
        self.assertEqual(self.text(), 'draft')
        self.command('key Down')
        self.assertEqual(self.text(), 'draft')
        # a recall sent: it is the newest, and the recall starts again from there
        self.command('key Home')
        self.command('key Up')
        self.command('key Up')
        self.command('key Return')
        self.command('wait-agent ready')
        self.assertEqual(self.prompts(), ['second line one\nsecond line two'])
        self.command('key Up')
        self.assertEqual(self.text(), 'second line one\nsecond line two')
        self.command('key Down')                        # the text area's: to the second line, then its end
        self.command('key Down')
        self.assertEqual(self.text(), 'second line one\nsecond line two')
        self.command('key Down')
        self.assertEqual(self.text(), '')               # the draft was the empty box
        # a message waiting to start is the newest of all
        self.command('agent-prompt held')
        self.command('wait-agent working')
        self.command('agent-prompt waiting')
        self.command('key Up')
        self.assertEqual(self.text(), 'waiting')
        self.command('key Up')
        self.assertEqual(self.text(), 'held')
        self.command('wait-agent ready 20000')

    def test_history_holds_100(self):
        self.seed_prompts(['p%d' % n for n in range(120)])
        self.start()
        self.open_seeded()
        for n in range(100):
            self.command('key Up')
            self.assertEqual(self.text(), 'p%d' % (119 - n))
        self.command('key Up')
        self.assertEqual(self.text(), 'p20')            # the 100 newest only
        self.assertEqual(self.prompts(), [])

    def test_draft_survives_switching(self):
        self.start()
        self.chat('one')
        first = self.sid()
        self.chat('two')
        second = self.sid()
        self.open_sid(first)
        self.command('agent-type for one')
        self.open_sid(second)
        self.assertEqual(self.text(), '')               # B's box is its own
        self.command('agent-type for two')
        self.open_sid(first)
        self.assertEqual(self.text(), 'for one')
        self.assertEqual(self.composer()['draft'], '1')
        self.open_sid(second)
        self.assertEqual(self.text(), 'for two')
        self.command('agent-type !')
        self.assertEqual(self.composer()['draft'], '0')  # edited: not the kept draft any more
        self.open_sid(first)
        self.command('agent-prompt ')                   # an emptied box keeps no draft
        self.open_sid(second)
        self.assertEqual(self.text(), 'for two!')
        self.open_sid(first)
        self.assertEqual(self.text(), '')
        self.assertEqual(self.prompts(), ['one', 'two'])

    def test_new_draft_keeps_its_text_across_the_list(self):
        self.start()
        self.chat('one')
        self.command('agent-new claude')
        self.command('agent-type not sent yet')         # the draft becomes its conversation
        self.command(f'click {chat.BACK[0]} {chat.BACK[1]}')
        self.until(lambda: len(self.listed()) == 1, 'the draft left without a prompt goes')
        self.command('agent-new claude')
        self.assertEqual(self.text(), 'not sent yet')
        self.command('key Return')
        self.command('wait-agent ready')
        self.assertEqual(self.prompts(), ['one', 'not sent yet'])
        self.command('agent-new claude')                # sent: nothing is kept
        self.assertEqual(self.text(), '')

    def test_placeholder_priority(self):
        self.seed_prompts(['first'])
        self.start()
        self.open_seeded()
        self.assertEqual(self.placeholder(), 'Ask Claude to edit\u2026')   # until the window's first Send
        self.command('agent-prompt held')
        self.command('wait-agent working')
        self.assertEqual(self.placeholder(), 'Queue another message\u2026')
        self.command('wait-agent ready 20000')
        self.until(lambda: ' suggest=1' in self.command('print-agent-live'), 'the suggestion')
        self.assertEqual(self.placeholder(), 'Run the tests')
        self.command('agent-type x')
        self.assertEqual(self.placeholder(), '')        # none once something is typed
        self.command('key BackSpace')
        self.assertEqual(self.placeholder(), 'Run the tests')
        self.command('agent-prompt held')               # it goes when the user sends
        self.assertIn(' suggest=0', self.command('print-agent-live'))
        self.assertEqual(self.placeholder(), 'Queue another message\u2026')
        self.command('wait-agent ready 20000')
        self.command('agent-new claude')
        self.assertEqual(self.placeholder(), 'Start a conversation')        # a draft keeps its own
        self.command('agent-type x')                    # (the draft's conversation: sent from this window)
        self.command('wait-agent ready')
        self.command('key BackSpace')
        self.assertEqual(self.placeholder(), chat.FOCUS_HINT)

    def test_tab_takes_the_suggestion(self):
        self.start()
        self.chat('hello')
        self.until(lambda: ' suggest=1' in self.command('print-agent-live'), 'the suggestion')
        self.command('key Tab')
        self.assertEqual(self.text(), 'Run the tests')
        self.command('key Return')
        self.until(lambda: 'Run the tests' in self.prompts(), 'sent')
        self.command('wait-agent ready')
        self.command('agent-type x')                    # with text in the box Tab takes nothing
        self.command('key Tab')
        self.assertNotIn('Run the tests', self.text())

    def test_no_suggestion_when_off(self):
        self.start(self.claude_section('prompt_suggestions = false\n'))
        self.chat('hello')
        self.command('wait 300')
        self.assertIn(' suggest=0', self.command('print-agent-live'))
        self.assertEqual(self.placeholder(), chat.FOCUS_HINT)
        self.command('key Tab')
        self.assertEqual(self.text(), '')

    def test_over_the_limit_band_and_no_send(self):
        self.start()
        self.chat('hello')
        over = 'a' * 49999 + '\U0001f600'               # 50,001 UTF-16 units: the emoji counts 2
        self.command('agent-prompt ' + over)
        self.command('wait 50')
        self.assertEqual(self.notice(), LIMIT % '1 character')
        self.assertEqual(self.prompts(), ['hello'])
        self.assertEqual(self.text(), over)              # kept, nothing went
        self.assertEqual(self.command('print-toast').strip(), 'toast=')
        self.command('key Return')
        self.assertEqual(self.prompts(), ['hello'])
        self.command('agent-prompt ' + 'b' * 50100)
        self.command('wait 50')
        self.assertEqual(self.notice(), LIMIT % '100 characters')
        self.command('key BackSpace')                    # the text changed: the notice goes
        self.command('wait 50')
        self.assertIsNone(self.notice())
        fits = 'c' * 49998 + '\U0001f600'               # 50,000 units: it goes
        self.command('agent-prompt ' + fits)
        self.command('wait-agent ready')
        self.assertEqual(self.prompts(), ['hello', fits])
        self.assertIsNone(self.notice())

    def paste(self, text):
        """text pasted into the box: copied from a new file, then the open conversation's box focused."""
        self.command('key ' + chat.MOD + '+n')
        self.command('type ' + text)
        self.command('key ' + chat.MOD + '+a')
        self.command('key ' + chat.MOD + '+c')
        self.command('key ' + chat.MOD + '+w')
        self.command('key Escape')
        self.command('cmd focus_agents')
        self.command('key Tab')
        self.command('key ' + chat.MOD + '+v')

    def test_invisible_characters_on_paste_and_send(self):
        self.start()
        self.chat('hello')
        self.command('agent-prompt a\u200bb\u202ec\ufeff')
        self.command('wait 50')
        self.assertEqual(self.notice(), 'Removed 3 invisible characters \u00b7 review and press Enter to send')
        self.assertEqual(self.text(), 'abc')
        self.assertEqual(self.prompts(), ['hello'])
        self.command('key Return')                       # reviewed: it goes
        self.command('wait-agent ready')
        self.assertEqual(self.prompts(), ['hello', 'abc'])
        self.assertIsNone(self.notice())
        self.command('agent-prompt \u200b\u2060')
        self.command('wait 50')
        self.assertEqual(self.notice(), 'Removed 2 invisible characters \u00b7 nothing left to send')
        self.assertEqual(self.text(), '')
        self.command('agent-prompt ' + 'd' * 50001 + '\U000e0041')
        self.command('wait 50')
        self.assertEqual(self.notice(), 'Removed 1 invisible character from your prompt \u00b7 still over the '
                                        'limit of 50000 characters \u00b7 shorten it to send')
        self.assertEqual(self.text(), 'd' * 50001)
        self.assertEqual(self.prompts(), ['hello', 'abc'])
        self.command('agent-prompt ')
        self.paste('x\u200by')
        self.command('wait 50')
        self.assertEqual(self.text(), 'xy')
        self.assertEqual(self.notice(), 'Removed 1 invisible character from the pasted text')
        self.quit()
        self.start(extra='[agents]\nctrl_enter_sends = true\n')
        self.listed()
        self.command('print-agents 1')
        self.command('agent-prompt e\u200bf')
        self.command('wait 50')
        self.assertEqual(self.notice(), 'Removed 1 invisible character \u00b7 review and press %s to send' % SEND_KEY)

    def test_joiners_in_emoji_survive(self):
        self.start()
        self.chat('hello')
        kept = 'family \U0001f468\u200d\U0001f469\u200d\U0001f467 heart \u2764\ufe0f ok key 1\ufe0f\u20e3 \u0928\u094d\u200d\u0928'
        self.command('agent-prompt ' + kept)
        self.command('wait-agent ready')
        self.assertEqual(self.prompts(), ['hello', kept])
        self.assertIsNone(self.notice())
        self.command('agent-prompt a\u200db\ufe0fc')     # between ASCII letters they go
        self.command('wait 50')
        self.assertEqual(self.notice(), 'Removed 2 invisible characters \u00b7 review and press Enter to send')
        self.assertEqual(self.text(), 'abc')

    def test_ultrathink_is_painted(self):
        self.start(env={'FAKE_CLAUDE_ULTRATHINK': '1'})
        self.chat('hello')
        self.command('agent-type please ultrathink about it')
        self.assertEqual(self.composer()['paint'], '7-17')
        self.command('agent-prompt ')
        self.command('agent-type Ultrathink, ultrathinking or ultra-think: /ultrathink')
        self.assertEqual(self.composer()['paint'], '0-10')
        self.command('agent-prompt ')
        self.command('agent-type /compact ultrathink')    # a command: nothing is painted
        self.assertEqual(self.composer()['paint'], '-')
        self.quit()
        self.start()
        self.chat('hello')
        self.command('agent-type please ultrathink')
        self.assertEqual(self.composer()['paint'], '-')    # the session does not offer it

    def test_scroll_on_send(self):
        self.start()
        self.chat('long', 'ready', 20000)
        self.command('move 1000 300')
        self.command('scroll -5')
        self.command('wait 100')
        self.assertEqual(QueueTest.scroll(self)['follow'], 0)
        self.command('agent-prompt again')
        self.command('wait 100')
        self.assertEqual(QueueTest.scroll(self)['follow'], 1)
        self.command('wait-agent ready')


MODES = ['Manual', 'Edit automatically', 'Plan']
MODE_DESC = {
    "Don't ask": 'Claude will deny actions that need approval instead of asking',
    'Manual': 'Claude will ask for approval before making each edit',
    'Edit automatically': 'Claude will edit your selected text or the whole file',
    'Plan': 'Claude will explore the code and present a plan before editing',
    'Auto': 'Claude will approve actions that pass a safety check and pause for anything risky',
    'Bypass permissions': 'Claude will not ask for approval before running potentially dangerous commands',
}
BYPASS = 'info Bypass permissions is off in Settings > Claude Code.'


class ModeCase(MenuCase):
    """The modes picker, the footer under the box (print-agents-foot) and the requests the fake read."""

    def modes(self):
        """The modes picker's rows (label, flags), opened as its button opens it, then closed (the effort row
        under them is not a mode)."""
        self.command('agent-modes')
        menu = self.menu()
        self.assertTrue(menu.startswith('popup=modes '), menu)
        self.assertIn('\nsection Modes\t⇧ + tab to switch\n', menu)
        rows = [r for r in self.rows() if not r[4].startswith('levels=')]
        for _, label, desc, _, _ in rows:
            self.assertEqual(desc, MODE_DESC[label])
        self.command('key Escape')
        return [(r[1], r[4]) for r in rows]

    def labels_offered(self):
        return [label for label, _ in self.modes()]

    def asked(self):
        """The modes set_permission_mode asked for, in order."""
        return [m['request']['mode'] for m in self.stdin()
                if m.get('type') == 'control_request' and m['request'].get('subtype') == 'set_permission_mode']

    def mode(self):
        return re.search(r' mode=(\S*)', self.live()).group(1)

    def foot(self):
        """print-agents-foot's first line: the mode, the frame's colour, where the buttons are, the label."""
        first = self.command('print-agents-foot').splitlines()[0]
        head, rest = first.split(' label=', 1)
        out = dict(word.split('=', 1) for word in head.split(' '))
        label, pill, title = rest.split('\t')
        out['label'] = label
        out['pill'] = pill[len('pill='):]
        out['title'] = title[len('title='):]
        return out

    def argv_modes(self):
        return [[a for a in s['argv'] if a.startswith('--permission-mode=')] for s in self.starts()]

    def conv_mode(self, sid):
        match = re.search(r'^conv %s\s+(\S+)$' % re.escape(sid), self.command('print-agent-cfg'), re.M)
        return match.group(1) if match else None

    def newmode(self):
        match = re.search(r'^newmode (\S*)$', self.command('print-agent-cfg'), re.M)
        return match.group(1) if match else None


class ModeTest(ModeCase):
    def test_offered_modes(self):
        self.ready()
        rows = self.modes()
        self.assertEqual(rows, [('Manual', 'check'), ('Edit automatically', '-'), ('Plan', '-')])
        self.assertEqual(self.foot()['label'], 'Manual')
        self.quit()
        self.start(env={'FAKE_CLAUDE_MODELS': 'auto'})
        self.chat('hello')
        self.assertEqual(self.labels_offered(), MODES + ['Auto'])
        self.quit()
        self.start(self.claude_section('allow_bypass_permissions = true\n'))
        self.chat('hello')
        self.assertEqual(self.labels_offered(), MODES + ['Bypass permissions'])

    def test_dont_ask_only_when_current(self):
        self.start(env={'FAKE_CLAUDE_MODE': 'dontAsk'})
        self.chat('hello')
        self.assertEqual(self.mode(), 'dontAsk')
        self.assertEqual(self.modes(), [("Don't ask", 'check'), ('Manual', '-'), ('Edit automatically', '-'),
                                        ('Plan', '-')])
        self.assertEqual(self.foot()['label'], "Don't ask")
        self.command('key shift+Tab')
        self.until(lambda: self.mode() == 'default', 'the next mode')
        self.assertEqual(self.asked(), ['default'])
        self.assertEqual(self.labels_offered(), MODES)

    def test_shift_tab_cycles_and_wraps(self):
        self.ready()
        self.assertIn('focus=1', self.command('print-agent-input'))
        for key in ('shift+Tab', 'ISO_Left_Tab'):
            for _ in range(3):
                self.command('key ' + key)
            self.until(lambda: len(self.asked()) % 3 == 0 and self.asked(), 'three requests')
            self.until(lambda: self.mode() == 'default', 'back to Manual')
        self.assertEqual(self.asked(), ['acceptEdits', 'plan', 'default'] * 2)
        self.assertEqual(self.box(), '')                             # nothing typed into the box
        self.assertEqual(self.prompts(), ['hello'])

    def test_same_mode_answer_without_status(self):
        # the CLI answers a request for the mode in force without a system/status line (finding 10): the
        # answer is what the label and the kept mode follow
        self.ready()
        sid = self.sid()
        self.command('agent-mode acceptEdits')
        self.until(lambda: self.mode() == 'acceptEdits', 'the mode')
        self.command('agent-mode acceptEdits')
        self.until(lambda: len(self.asked()) == 2, 'asked again')
        self.command('wait 200')
        self.assertEqual(self.mode(), 'acceptEdits')
        self.assertEqual(self.foot()['label'], 'Edit automatically')
        self.assertEqual(self.conv_mode(sid), 'acceptEdits')
        self.command('key shift+Tab')                                # the next one follows the answer
        self.until(lambda: len(self.asked()) == 3, 'the next mode')
        self.assertEqual(self.asked(), ['acceptEdits', 'acceptEdits', 'plan'])
        self.until(lambda: self.mode() == 'plan', 'plan')

    def test_a_mode_picked_before_a_start_is_passed(self):
        self.seed('s1')
        self.start()
        self.open_listed()
        self.command('agent-mode plan')
        self.assertEqual(self.foot()['label'], 'Plan')
        self.assertEqual(self.starts(), [])
        self.assertEqual(re.findall(r'\b\d+\b', self.command('print-uproc')), [])
        self.assertIn(' pid=0 ', self.command('print-agent-live'))
        self.command('agent-prompt hello')
        self.command('wait-agent ready 10000')
        self.assertEqual(self.argv_modes(), [['--permission-mode=plan']])
        self.assertEqual(self.mode(), 'plan')
        self.assertEqual(self.asked(), [])                           # it was passed, not asked for
        # a new conversation's draft becomes the conversation the pick is for, and nothing starts
        self.command('agent-new claude')
        self.command('agent-mode acceptEdits')
        self.assertEqual(len(self.starts()), 1)
        self.command('agent-prompt again')
        self.command('wait-agent ready 10000')
        self.assertEqual(self.argv_modes()[-1], ['--permission-mode=acceptEdits'])

    def test_a_conversation_keeps_its_mode(self):
        self.ready()
        sid = self.sid()
        self.command('agent-mode plan')
        self.until(lambda: self.mode() == 'plan', 'plan')
        self.command('agent-release')
        self.until_gone()
        self.quit()
        self.start()
        self.open_listed()
        self.command('agent-prompt again')
        self.command('wait-agent ready 10000')
        self.assertIn('--resume=' + sid, self.starts()[-1]['argv'])
        self.assertEqual(self.argv_modes()[-1], ['--permission-mode=plan'])

    def test_the_picked_default_applies_to_new_conversations(self):
        self.ready()
        self.assertEqual(self.newmode(), '-')
        self.command('agent-mode plan')                              # plan is no default for new ones
        self.until(lambda: self.mode() == 'plan', 'plan')
        self.assertEqual(self.newmode(), '-')
        self.command('agent-mode acceptEdits')
        self.until(lambda: self.mode() == 'acceptEdits', 'acceptEdits')
        self.assertEqual(self.newmode(), 'acceptEdits')
        self.chat('again')
        self.assertEqual(self.argv_modes()[-1], ['--permission-mode=acceptEdits'])
        self.quit()
        # with [claude] initial_mode set, that is what new conversations start in, and a pick keeps it so
        self.start(self.claude_section('initial_mode = plan\n'))
        self.chat('hello')
        self.assertEqual(self.argv_modes()[-1], ['--permission-mode=plan'])
        self.command('agent-mode default')
        self.until(lambda: self.mode() == 'default', 'default')
        self.assertEqual(self.newmode(), 'acceptEdits')
        self.chat('third')
        self.assertEqual(self.argv_modes()[-1], ['--permission-mode=plan'])

    def test_bypass_needs_the_setting_everywhere(self):
        self.ready()
        self.assertNotIn('Bypass permissions', self.labels_offered())
        for _ in range(4):
            self.command('key shift+Tab')
        self.until(lambda: len(self.asked()) == 4, 'four requests')
        self.assertEqual(self.asked(), ['acceptEdits', 'plan', 'default', 'acceptEdits'])
        out, ok = self.reply('agent-mode bypassPermissions')
        self.assertFalse(ok, out)
        self.command('wait 200')
        self.assertNotIn('bypassPermissions', self.asked())
        # a remembered default of bypass starts in default, and says why
        self.command('agent-cfg-set newmode bypassPermissions')
        self.chat('again')
        self.assertEqual(self.argv_modes()[-1], ['--permission-mode=default'])
        self.assertIn(BYPASS, self.thread())
        self.quit()
        # initial_mode = bypassPermissions without the setting: default, and the info row
        self.start(self.claude_section('initial_mode = bypassPermissions\n'))
        self.chat('hello')
        self.assertEqual(self.argv_modes()[-1], ['--permission-mode=default'])
        self.assertIn(BYPASS, self.thread())
        self.quit()
        # with the setting: offered, passed with its flag, and asked for
        self.start(self.claude_section('allow_bypass_permissions = true\n'))
        self.chat('hello')
        argv = self.starts()[-1]['argv']
        self.assertIn('--allow-dangerously-skip-permissions', argv)
        self.assertIn('Bypass permissions', self.labels_offered())
        sid = self.sid()
        self.command('agent-mode bypassPermissions')
        self.until(lambda: self.mode() == 'bypassPermissions', 'bypass')
        self.assertEqual(self.conv_mode(sid), 'bypassPermissions')
        self.command('agent-release')
        self.until_gone()
        self.quit()
        # the conversation's remembered bypass mode, the setting gone: default and the info row
        self.start()
        self.listed()
        self.command('print-agents 1')                              # the newest: the one in bypass
        self.command('agent-prompt again')
        self.command('wait-agent ready 10000')
        self.assertIn('--resume=' + sid, self.starts()[-1]['argv'])
        self.assertEqual(self.argv_modes()[-1], ['--permission-mode=default'])
        self.assertIn(BYPASS, self.thread())
        self.assertNotIn('Bypass permissions', self.labels_offered())
        no_setting = [s['argv'] for s in self.starts()
                      if '--allow-dangerously-skip-permissions' not in s['argv']]
        self.assertEqual(len(no_setting), len(self.starts()) - 1)
        for argv in no_setting:
            self.assertNotIn('--permission-mode=bypassPermissions', argv)

    def test_policies_take_auto_and_bypass_away(self):
        # the settings the program reports (get_settings' effective) can forbid both; this is the test's
        # own HOME, the fake's config folder
        (self.work / '.claude').mkdir(exist_ok=True)
        (self.work / '.claude/settings.json').write_text(json.dumps(
            {'permissions': {'disableBypassPermissionsMode': 'disable', 'disableAutoMode': 'disable'}}),
            encoding='utf-8')
        self.start(self.claude_section('allow_bypass_permissions = true\n'), env={'FAKE_CLAUDE_MODELS': 'auto'})
        self.chat('hello')
        self.until(lambda: self.labels_offered() == MODES, 'the policies')
        out, ok = self.reply('agent-mode bypassPermissions')
        self.assertFalse(ok, out)
        self.assertEqual(self.asked(), [])

    def test_a_refused_mode_says_why_and_goes_back(self):
        # a process started without --allow-dangerously-skip-permissions cannot switch to bypass (finding
        # 10): the setting turned on while it runs offers it, the CLI refuses, the toast says so
        self.ready()
        sid = self.sid()
        self.config.write_text(self.BASE + self.claude_section('allow_bypass_permissions = true\n'),
                               encoding='utf-8')
        self.until(lambda: 'Bypass permissions' in self.labels_offered(), 'the reload')
        self.command('agent-mode bypassPermissions')
        self.until(lambda: self.asked() == ['bypassPermissions'], 'asked')
        self.until(lambda: self.mode() == 'default', 'back to the mode before')
        self.assertEqual(self.command('print-toast').strip(),
                         'toast=Failed to set mode: Cannot set permission mode to bypassPermissions because the '
                         'session was not launched with --dangerously-skip-permissions')
        self.assertEqual(self.foot()['label'], 'Manual')
        self.assertIn(self.conv_mode(sid), (None, 'default'))

    def test_mode_button_and_menu_button(self):
        self.ready()
        foot = self.foot()
        self.assertEqual((foot['mode'], foot['label']), ('default', 'Manual'))
        ring = foot['ring']
        x, y = foot['mode_at'].split(',')
        self.command(f'move {x} {y}')
        self.command('wait 700')
        self.assertIn('Claude will ask for approval before making each edit. Click to change, or press '
                      'Shift+Tab to cycle.', self.command('print-tip'))
        self.command(f'click {x} {y}')
        self.assertEqual(self.head()['popup'], 'modes')
        self.command('agent-menu-pick 2')                            # Edit automatically
        self.until(lambda: self.mode() == 'acceptEdits', 'picked')
        self.assertEqual(self.asked(), ['acceptEdits'])
        self.assertTrue(self.menu().startswith('popup=none'))
        foot = self.foot()
        self.assertEqual(foot['label'], 'Edit automatically')
        self.assertNotEqual(foot['ring'], ring)
        mx, my = foot['menu_at'].split(',')
        self.command(f'move {mx} {my}')
        self.command('wait 700')
        self.assertIn('Show command menu (/)', self.command('print-tip'))
        self.command(f'click {mx} {my}')
        head = self.head()
        self.assertEqual((head['popup'], head['filter']), ('menu', ''))
        self.command(f'click {mx} {my}')                            # again: it closes
        self.assertTrue(self.menu().startswith('popup=none'))

    def test_the_frame_takes_the_modes_colour(self):
        self.ready()
        rings = {}
        for mode in ('default', 'acceptEdits', 'plan'):
            self.command('agent-mode ' + mode)
            self.until(lambda: self.mode() == mode, mode)
            rings[mode] = self.foot()['ring']
        self.assertEqual(len(set(rings.values())), 3, rings)

    def test_plan_command_switches_the_mode(self):
        self.ready()
        self.command('agent-prompt /plan')
        self.until(lambda: self.mode() == 'plan', 'plan')
        self.assertEqual(self.asked(), ['plan'])
        self.command('agent-prompt /plan')          # in plan mode: get_plan's answer (task 11), none yet
        self.until(lambda: 'info Already in plan mode. No plan written yet.' in self.thread(), 'the info row')
        self.command('agent-mode default')
        self.until(lambda: self.mode() == 'default', 'default')
        self.command('agent-prompt /plan write the tests')
        self.until(lambda: 'write the tests' in self.prompts(), 'the description goes as a prompt')
        self.assertEqual(self.asked(), ['plan', 'default', 'plan'])

    def test_mode_controls_fit(self):
        self.ready()
        self.command('agent-mode acceptEdits')                       # the longest label of the three
        self.until(lambda: self.mode() == 'acceptEdits', 'acceptEdits')
        lines = self.command('print-agents-foot').splitlines()[1:]
        self.assertEqual(len(lines), 25 * 34)
        cut = 0
        for line in lines:
            r, label, _ = foot_line(line)
            what = line
            rects = {name: (r[name + '_x'], r[name + '_y'], r[name + '_w'], r[name + '_h'])
                     for name in ('send', 'mode', 'menu', 'add')}
            for name, (x, y, w, h) in rects.items():
                self.assertGreater(w, 0, what)
                self.assertGreater(h, 0, what)
                self.assertGreaterEqual(x, 0, what)
                self.assertLessEqual(x + w, r['w'], what)
                self.assertGreaterEqual(y, 0, what)
                self.assertLessEqual(y + h, r['h'], what)
            names = list(rects)
            for i, a in enumerate(names):
                for b in names[i + 1:]:
                    ax, ay, aw, ah = rects[a]
                    bx, by, bw, bh = rects[b]
                    apart = ax + aw <= bx or bx + bw <= ax or ay + ah <= by or by + bh <= ay
                    self.assertTrue(apart, f'{a} and {b} overlap: {what}')
            self.assertGreaterEqual(r['mode_w'], r['menu_w'], what)  # room for its dot and a cut label
            self.assertTrue(label == 'Edit automatically' or label.endswith('…'), what)
            cut += label != 'Edit automatically'
        at = {(int(re.search(r'size=(\d+)', l).group(1)), int(re.search(r' w=(\d+)', l).group(1))): l
              for l in lines}
        self.assertEqual(foot_line(at[13, 600])[1], 'Edit automatically', at[13, 600])
        self.assertGreater(cut, 0)                                   # a large font in a narrow panel cuts it


SCANNED = []                            # the fake's requests ModelCase looked at, over all of its tests


class ModelCase(ModeCase):
    """The model pill and picker, effort, Ultracode, thinking and fast mode. After each test the fake's log is
    read: no update_settings with userSettings may be in it (rhun never writes Claude Code's own settings),
    and the test HOME's Claude Code settings file was never made (the fake's config folder is the test's)."""

    def tearDown(self):
        try:
            requests = [m['request'] for m in self.stdin() if m.get('type') == 'control_request']
            SCANNED.extend(r.get('subtype') for r in requests)
            user = [r for r in requests if r.get('subtype') == 'update_settings' and r.get('source') == 'userSettings']
            self.assertEqual(user, [])
            self.assertFalse((self.work / '.claude/settings.json').exists())
        finally:
            super().tearDown()

    def requests(self, subtype=None):
        out = [m['request'] for m in self.stdin() if m.get('type') == 'control_request']
        return [r for r in out if subtype is None or r.get('subtype') == subtype]

    def flags(self):
        """The settings apply_flag_settings asked for, in order."""
        return [r['settings'] for r in self.requests('apply_flag_settings')]

    def choices(self):
        """print-agent-cfg's project line: the project's model, effort, Ultracode and thinking."""
        return re.search(r'^project (.*)$', self.command('print-agent-cfg'), re.M).group(1)

    def at(self, n):
        """Where print-agent-menu says row n was drawn."""
        match = re.search(r'^at %d (\d+),(\d+)$' % n, self.menu(), re.M)
        self.assertIsNotNone(match, self.menu())
        return match.group(1), match.group(2)

    def pills(self):
        return [l[len('pill '):] for l in self.command('print-agents').splitlines() if l.startswith('pill ')]

    def thinking(self):
        return [r['thinking'] for r in self.records() if 'thinking' in r]

    def released(self):
        self.command('agent-release')
        self.until_gone()


class ModelTest(ModelCase):
    def test_the_pill_names_the_model_and_effort(self):
        self.ready()
        foot = self.foot()
        self.assertEqual(foot['pill'], 'Default (recommended) · High')
        self.assertEqual(foot['title'], 'Switch model (Default (recommended))')
        x, y = foot['pill_at'].split(',')
        self.command(f'move {x} {y}')
        self.command('wait 700')
        self.assertIn('Switch model (Default (recommended))', self.command('print-tip'))
        self.command(f'click {x} {y}')                              # the pill opens the picker
        head = self.head()
        self.assertEqual((head['popup'], head['sel']), ('models', '1'))
        self.assertEqual(self.rows()[0][1:], ('Default (recommended)', 'Opus 5.5', '-', 'check'))
        self.command(f'click {x} {y}')                              # and closes it
        self.assertTrue(self.menu().startswith('popup=none'))
        # a draft names the project's choice, before any program (nothing is read for it)
        self.command('agent-cfg-set model sonnet')
        self.command('agent-new claude')
        self.assertEqual(self.foot()['pill'], 'Sonnet')
        self.assertEqual(len(self.starts()), 1)

    def test_models_picker_rows_and_unavailable(self):
        self.start(env={'FAKE_CLAUDE_MODELS': 'unavailable'})
        self.chat('hello')
        self.command('agent-models')
        menu = self.menu()
        self.assertIn('\nsection Select a model\n', menu)
        self.assertEqual([r[1:] for r in self.rows()], [
            ('Default (recommended)', 'Opus 5.5', '-', 'check'), ('Sonnet', 'Sonnet 5', '-', '-'),
            ('Haiku', 'Not on your plan', '-', 'off'), ('Effort (High)', 'Set how hard the model tries', '-',
                                                        'levels=high')])
        self.command('agent-menu-pick 3')                            # the greyed row is not picked
        self.command('key Return')
        x, y = self.at(3)
        self.command(f'click {x} {y}')
        self.command('key space')
        self.command('wait 200')
        self.assertEqual(self.flags(), [])
        self.assertTrue(self.choices().startswith('model=- '), self.choices())
        out, ok = self.reply('agent-model haiku')
        self.assertFalse(ok, out)
        self.assertEqual(self.foot()['pill'], 'Default (recommended) · High')

    def test_picking_a_model_while_running(self):
        self.ready()
        self.command('agent-models')
        self.command('agent-menu-pick 2')                            # Sonnet
        self.assertTrue(self.menu().startswith('popup=none'))
        self.until(lambda: self.pills() == ['Switched to Sonnet'], 'the pill row')
        subtypes = [r['subtype'] for r in self.requests()]
        self.assertEqual(subtypes[:2], ['initialize', 'get_settings'])
        self.assertEqual(self.flags(), [{'model': 'sonnet'}])
        after = subtypes[subtypes.index('apply_flag_settings'):]
        self.assertEqual(after, ['apply_flag_settings', 'get_settings'])
        self.until(lambda: ' model=claude-sonnet-5 effort=medium ' in self.command('print-agent-live'), 'applied')
        self.assertEqual(self.foot()['pill'], 'Sonnet · Medium')
        self.assertTrue(self.choices().startswith('model=sonnet '), self.choices())
        self.command('agent-prompt again')
        self.command('wait-agent ready 10000')
        self.assertEqual(len(self.starts()), 1)                      # the same process, no start for it

    def test_picking_before_a_start_starts_nothing_and_passes_model_and_effort(self):
        self.ready()
        self.released()
        self.command('agent-model sonnet')
        self.command('agent-effort low')
        self.assertEqual(self.foot()['pill'], 'Sonnet · Low')
        self.assertEqual(len(self.starts()), 1)
        self.assertEqual(re.findall(r'\b\d+\b', self.command('print-uproc')), [])
        self.command('agent-prompt again')
        self.command('wait-agent ready 10000')
        argv = self.starts()[-1]['argv']
        self.assertIn('--model=sonnet', argv)
        self.assertIn('--effort=low', argv)
        self.assertEqual(self.flags(), [])                           # passed, not asked for
        self.assertIn(' model=claude-sonnet-5 effort=low ', self.command('print-agent-live'))
        out, ok = self.reply('agent-effort xhigh')                   # not one of Sonnet's levels
        self.assertFalse(ok, out)
        # a draft's pick: it becomes its conversation, nothing starts
        self.command('agent-new claude')
        self.command('agent-model default')
        self.assertEqual(len(self.starts()), 2)

    def test_choices_never_reach_user_settings(self):
        settings = self.work / '.claude/settings.json'
        self.start(env={'FAKE_CLAUDE_MODELS': 'ultra'})
        self.chat('hello')
        for line in ('agent-model sonnet', 'agent-effort low', 'agent-ultra on', 'agent-ultra off',
                     'agent-model default', 'agent-effort max'):
            self.reply(line)
        self.until(lambda: len(self.flags()) >= 5, 'the picks applied')
        self.released()
        for line in ('agent-model sonnet', 'agent-effort medium', 'agent-ultra on'):
            self.reply(line)
        self.command('agent-prompt again')
        self.command('wait-agent ready 10000')
        self.assertEqual(self.requests('update_settings'), [])
        self.assertFalse(settings.exists())
        self.assertNotIn('modelSettings', json.dumps(self.stdin()))
        self.assertGreater(len(self.flags()), 5)                     # and the same picks went as flags

    def test_choices_are_the_projects(self):
        other = self.work / 'other'
        other.mkdir()
        self.ready()
        self.command('agent-model sonnet')
        self.command('open ' + str(other))
        self.command('wait 200')
        self.chat('there')
        argv = self.starts()[-1]['argv']
        self.assertEqual([a for a in argv if a.startswith(('--model', '--effort'))], [])
        self.assertEqual(self.foot()['pill'], 'Default (recommended) · High')

    def test_effort_levels_follow_the_model(self):
        self.start(env={'FAKE_CLAUDE_MODELS': 'effort,noeffort'})
        self.chat('hello')
        self.command('agent-models')
        self.assertIn('\nlevels low:Low,medium:Medium,high:High,xhigh:Extra high,max:Max\n', self.menu())
        self.assertEqual(self.rows()[-1][1:], ('Effort (High)', 'Set how hard the model tries', '-', 'levels=high'))
        self.command('agent-menu-pick 3')                            # the effort row: the next level round
        self.until(lambda: self.flags() == [{'effortLevel': 'xhigh'}], 'xhigh')
        self.assertTrue(self.menu().startswith('popup=models '))     # the picker stays
        self.until(lambda: self.foot()['pill'] == 'Default (recommended) · Extra high', 'the pill')
        self.command('key Left')                                     # the keys step it
        self.until(lambda: self.flags()[-1:] == [{'effortLevel': 'high'}], 'high')
        track = re.search(r'^track (\d+),(\d+),(\d+),(\d+)$', self.menu(), re.M)
        self.assertIsNotNone(track, self.menu())
        tx, ty, tw, th = map(int, track.groups())
        self.command(f'click {tx + 1} {ty + th // 2}')               # its track's left end: the lowest
        self.until(lambda: self.flags()[-1:] == [{'effortLevel': 'low'}], 'low')
        self.command(f'click {tx + tw - 1} {ty + th // 2}')          # the right end: the highest
        self.until(lambda: self.flags()[-1:] == [{'effortLevel': 'max'}], 'max')
        self.assertTrue(self.choices().startswith('model=- effort=max '), self.choices())
        # a model without levels has no effort row, and the pill names no level
        self.command('agent-menu-pick 2')
        self.until(lambda: self.foot()['pill'] == 'Sonnet', 'Sonnet')
        self.command('agent-models')
        self.assertNotIn('Effort', ' '.join(self.labels()))
        self.command('key Escape')
        self.command('agent-menu')
        self.assertNotIn('Effort', ' '.join(self.labels()))
        self.command('key Escape')
        self.command('agent-modes')
        self.assertNotIn('Effort', ' '.join(self.labels()))

    def test_effort_row_in_the_modes_picker_and_the_menu(self):
        self.ready()
        self.command('agent-modes')
        self.assertEqual(self.rows()[-1][1:], ('Effort (High)', 'Set how hard the model tries', '-', 'levels=high'))
        x, y = self.at(4)
        self.command(f'move {x} {y}')
        self.command('wait 700')
        self.assertIn('Click to cycle effort level', self.command('print-tip'))
        self.command('key Escape')
        self.command('agent-menu effort')
        self.assertEqual(self.labels()[0], 'Effort (High)')
        self.command('key Return')                                   # the round wraps: high -> low
        self.until(lambda: self.flags() == [{'effortLevel': 'low'}], 'low')
        self.assertEqual(self.labels()[0], 'Effort (Low)')

    def test_ultracode_row_and_flag_settings(self):
        self.start(env={'FAKE_CLAUDE_MODELS': 'ultra'})
        self.chat('hello')
        self.command('agent-models')
        rows = self.rows()
        self.assertEqual(rows[-1][1:], ('Ultracode', 'Run dynamic workflows on every task (this session only)', '-',
                                        'switch'))
        self.command('agent-menu-pick %d' % len(rows))
        self.until(lambda: self.flags() == [{'ultracode': True}], 'on')
        self.assertTrue(self.menu().startswith('popup=models '))     # a switch: the picker stays
        self.until(lambda: ' ultra=1 ' in self.command('print-agent-live'), 'applied')
        self.assertEqual(self.foot()['pill'], 'Default (recommended) · High · Ultracode')
        subtypes = [r['subtype'] for r in self.requests()]
        self.assertEqual(subtypes[subtypes.index('apply_flag_settings'):], ['apply_flag_settings', 'get_settings'])
        self.assertIn(' ultra=1 ', ' ' + self.choices() + ' ')
        self.released()
        self.command('agent-prompt again')                           # the next process takes it after its settings
        self.command('wait-agent ready 10000')
        self.until(lambda: self.flags() == [{'ultracode': True}] * 2, 'applied again')
        self.until(lambda: ' ultra=1 ' in self.command('print-agent-live'), 'on again')
        self.command('agent-ultra off')
        self.until(lambda: self.flags()[-1] == {'ultracode': False}, 'off')
        self.until(lambda: ' ultra=0 ' in self.command('print-agent-live'), 'off applied')
        self.assertEqual(self.foot()['pill'], 'Default (recommended) · High')

    def test_ultracode_not_offered(self):
        self.ready()
        self.command('agent-models')
        self.assertNotIn('Ultracode', self.labels())
        out, ok = self.reply('agent-ultra on')
        self.assertFalse(ok, out)
        self.assertEqual(self.flags(), [])

    def test_thinking_switch_and_the_next_start(self):
        self.start(env={'FAKE_CLAUDE_MODELS': 'nothink'})
        self.chat('hello')
        self.command('agent-menu think')
        self.assertEqual(self.rows()[0][1:], ('Thinking', 'Toggle extended thinking mode', '-', 'on,switch'))
        self.command('key Return')
        self.until(lambda: self.thinking() == [{'max_thinking_tokens': 0, 'thinking_display': None}], 'off')
        self.assertEqual(self.rows()[0][1:], ('Thinking', 'Toggle extended thinking mode', '-', 'switch'))
        self.assertIn(' think=0 ', self.command('print-agent-live'))
        self.released()
        self.command('agent-prompt again')
        self.command('wait-agent ready 10000')
        argv = self.starts()[-1]['argv']
        self.assertIn('--thinking=disabled', argv)
        self.assertNotIn('--max-thinking-tokens=31999', argv)
        self.command('agent-thinking on')
        self.until(lambda: self.thinking()[-1:] == [{'max_thinking_tokens': 31999, 'thinking_display': None}], 'on')
        self.assertEqual(self.requests('apply_flag_settings'), [])

    def test_thinking_asks_for_summaries_when_the_settings_say(self):
        local = self.project / '.claude'
        local.mkdir()
        (local / 'settings.local.json').write_text(json.dumps({'showThinkingSummaries': True}), encoding='utf-8')
        self.start(env={'FAKE_CLAUDE_MODELS': 'nothink'})
        self.chat('hello')
        self.command('agent-thinking off')
        self.command('agent-thinking on')
        self.until(lambda: len(self.thinking()) == 3, 'all three')
        # the start asks for summaries too (phase 3 task 6, open point 11), before the first prompt
        self.assertEqual(self.thinking(), [{'max_thinking_tokens': 31999, 'thinking_display': 'summarized'},
                                           {'max_thinking_tokens': 0, 'thinking_display': None},
                                           {'max_thinking_tokens': 31999, 'thinking_display': 'summarized'}])

    def test_no_thinking_switch_by_default(self):
        self.ready()
        self.command('agent-menu')
        self.assertNotIn('Thinking', self.labels())
        out, ok = self.reply('agent-thinking off')
        self.assertFalse(ok, out)
        self.assertEqual(self.thinking(), [])
        self.assertIn('--max-thinking-tokens=31999', self.starts()[-1]['argv'])

    def test_fast_entry_follows_the_reason(self):
        self.start(env={'FAKE_CLAUDE_MODELS': 'fast', 'FAKE_CLAUDE_FAST': 'off sdk_opt_in_required'})
        self.chat('hello')
        self.command('agent-menu')
        self.assertNotIn('Toggle fast mode', self.labels())
        self.assertIn('fast off sdk_opt_in_required', self.command('print-agent-cfg'))
        self.quit()
        self.start(env={'FAKE_CLAUDE_MODELS': 'fast', 'FAKE_CLAUDE_FAST': 'off -', 'FAKE_CLAUDE_FAST_REJECT': '1'})
        self.chat('hello')
        self.assertEqual(self.foot()['fast'], 'off')
        self.command('agent-menu fast')
        self.assertEqual(self.labels()[0], 'Toggle fast mode')
        self.command('key Return')
        self.until(lambda: '/fast' in self.prompts(), '/fast sent')
        self.command('wait-agent ready 10000')
        self.until(lambda: self.foot()['fast'] == 'on', 'the mark')
        foot = self.foot()
        x, y = foot['fast_at'].split(',')
        self.command(f'move {x} {y}')
        self.command('wait 700')
        self.assertIn('Fast mode enabled', self.command('print-tip'))
        self.command('agent-prompt more')                            # usage credits run out: it turns off
        self.command('wait-agent ready 10000')
        self.until(lambda: self.foot()['fast'] == 'off', 'off')
        self.assertEqual(self.command('print-toast').strip(),
                         'toast=Fast mode disabled · Usage credits are unavailable. Type /fast on in the chat to '
                         'turn it back on once usage credits are available again.')
        self.assertNotIn('/fast off', self.prompts())                # rhun sends nothing the user did not ask for
        self.assertEqual(self.prompts().count('/fast'), 1)

    def test_picker_closes_when_the_conversation_changes(self):
        self.ready()
        self.command('agent-models')
        self.assertEqual(self.head()['popup'], 'models')
        self.command(f'click {chat.BACK[0]} {chat.BACK[1]}')
        self.assertTrue(self.menu().startswith('popup=none'))
        self.command('print-agents 1')
        self.command('agent-models')
        self.assertEqual(self.head()['popup'], 'models')
        self.command('agent-new claude')                             # the box is another's
        self.assertTrue(self.menu().startswith('popup=none'))

    def test_loading_models_while_it_starts(self):
        self.start(env={'FAKE_CLAUDE_INIT_MS': '1500'})
        self.command('agent-new claude')
        self.command('agent-prompt hello')
        self.command('agent-models')
        self.assertIn('\nempty Loading models…\n', self.menu())
        self.command('wait-agent ready 10000')
        self.until(lambda: '\nsection Select a model\n' in self.menu(), 'the list')
        self.command('key Escape')
        self.quit()
        self.start(target='--empty')                                 # no list, nothing starting
        self.command('agent-new claude')
        self.command('agent-models')
        self.assertIn('\nempty No models available\n', self.menu())

    def test_model_controls_fit(self):
        self.start(env={'FAKE_CLAUDE_MODELS': 'fast,ultra', 'FAKE_CLAUDE_FAST': 'on -'})
        self.chat('hello')
        self.command('agent-ultra on')
        self.until(lambda: ' ultra=1 ' in self.command('print-agent-live'), 'Ultracode')
        self.command('agent-mode acceptEdits')
        self.until(lambda: self.mode() == 'acceptEdits', 'acceptEdits')
        self.assertEqual(self.foot()['fast'], 'on')
        lines = self.command('print-agents-foot').splitlines()[1:]
        self.assertEqual(len(lines), 25 * 34)
        shown = own_row = fast = 0
        for line in lines:
            r, _, _ = foot_line(line)
            rects = {name: (r[name + '_x'], r[name + '_y'], r[name + '_w'], r[name + '_h'])
                     for name in ('send', 'mode', 'menu', 'pill', 'fast', 'add') if r[name + '_w'] > 0}
            fast += 'fast' in rects
            for name, (x, y, w, h) in rects.items():
                self.assertGreater(h, 0, line)
                self.assertGreaterEqual(x, 0, line)
                self.assertLessEqual(x + w, r['w'], line)
                self.assertLessEqual(y + h, r['h'], line)
            names = list(rects)
            for i, a in enumerate(names):
                for b in names[i + 1:]:
                    ax, ay, aw, ah = rects[a]
                    bx, by, bw, bh = rects[b]
                    apart = ax + aw <= bx or bx + bw <= ax or ay + ah <= by or by + bh <= ay
                    self.assertTrue(apart, f'{a} and {b} overlap: {line}')
            self.assertGreaterEqual(r['mode_w'], r['menu_w'], line)
            self.assertIn('pill', rects, line)                       # the pill never goes: at worst its own row
            shown += 1
            self.assertLess(r['pill_text'], r['pill_w'], line)
            own_row += r['stage'] == 2
        at = {(int(re.search(r'size=(\d+)', l).group(1)), int(re.search(r' w=(\d+)', l).group(1))): l
              for l in lines}
        self.assertEqual(foot_line(at[13, 380])[1], 'Edit automatically', at[13, 380])
        self.assertIn(' pill_w=', at[13, 380])
        self.assertGreater(int(re.search(r' pill_w=(\d+)', at[13, 380]).group(1)), 0)
        self.assertGreater(shown, 0)
        self.assertGreater(own_row, 0)                               # 240 px at 32: the pill takes its own row
        self.assertGreater(int(re.search(r' fast_w=(\d+)', at[13, 380]).group(1)), 0)
        self.assertLess(fast, len(lines))                            # and there the fast mark too
        # the models picker fits every size too
        self.command('agent-models')
        lines = self.command('print-agent-menu fit').splitlines()
        self.assertEqual(len(lines), 25 * 34)
        for line in lines:
            r = {k: int(v) for k, v in (f.split('=') for f in line.split())}
            self.assertLessEqual(r['x'] + r['pw'], r['w'], line)
            self.assertGreaterEqual(r['left'], r['x'], line)
            self.assertLessEqual(r['right'], r['x'] + r['pw'], line)
            self.assertGreater(r['label'], 0, line)


FOOT_RECTS = ('send', 'mode', 'menu', 'pill', 'fast', 'ctx', 'cache', 'add')     # add: the "+" (phase 4 task 3)
WINDOW = 1000000 - 20000 - 13000        # the fake's contextWindow, less min(maxOutputTokens, 20000) and 13000


def foot_line(line):
    """A print-agents-foot layout line: its numbers, the label and the pill as shown."""
    head, rest = line.split(' label=', 1)
    label, pill = rest.split('\tpill=', 1)
    numbers = {k: int(v) for k, v in (f.split('=') for f in head.split())}
    return numbers, label, pill


def local_reset(at, date):
    """The bundle's reset time (index.js @3698835 ex): "at 3:45 PM" within a day for the five-hour limit, else
    "Tue, Nov 24 at 3:45 PM" (the year after the day when it is another year)."""
    when = time.localtime(at)
    clock = '%d:%02d %s' % ((when.tm_hour + 11) % 12 + 1, when.tm_min, 'AM' if when.tm_hour < 12 else 'PM')
    if at - time.time() < 60:
        return 'soon'
    if not date and at - time.time() < 86400:
        return 'at ' + clock
    day = time.strftime('%a, %b ', when) + str(when.tm_mday)
    if when.tm_year != time.localtime().tm_year:
        day += ', %d' % when.tm_year
    return day + ' at ' + clock


class NoticeCase(ModelCase):
    def bands(self):
        return [line for line in self.command('print-agent-bands').splitlines() if line.startswith('band ')]

    def band(self, kind):
        """The text of the band of that kind, or None."""
        for line in self.bands():
            match = re.match(r'band (\S+) lines=\d+ close=\d+,\d+ (.*)$', line)
            if match and match.group(1) == kind:
                return match.group(2)
        return None

    def link(self, kind):
        """A band's link: (x, y, label, url), or None."""
        for line in self.command('print-agent-bands').splitlines():
            match = re.match(r'link (\S+) (\d+),(\d+) (.*)\t(.*)$', line)
            if match and match.group(1) == kind:
                return match.group(2), match.group(3), match.group(4), match.group(5)
        return None

    def close(self, kind):
        for line in self.bands():
            match = re.match(r'band (\S+) lines=\d+ close=(\d+),(\d+) ', line)
            if match and match.group(1) == kind:
                self.command('click %s %s' % match.group(2, 3))
                return
        self.fail('no %s band' % kind)

    def rates(self):
        return [r['rate'] for r in self.records() if 'rate' in r]

    def live_word(self, word):
        return re.search(' %s=(\\S+)' % word, self.command('print-agent-live')).group(1)

    def stats(self):
        passes, draws = (int(w.split('=')[1]) for w in self.command('print-loop-stats').split()[:2])
        return passes, draws

    def runs(self):
        """The panel's discovery runs started so far (print-agents-runs)."""
        return int(self.command('print-agents-runs').split('=')[1])

    def idle(self, seconds=3, samples=1, settle=2.5, again=True):
        """The main loop's passes (without the second command's own) and the frames it drew over that long,
        in windows the panel's discovery stayed out of; of several samples, the one with the fewest passes.
        While the panel shows, discovery runs every 10 s (agents.s, last_scan): a child process whose answer
        costs 3 to 5 passes and 2 or 3 frames within about a second of its start, a wake-up source of the
        panel's own that has nothing to do with what a test measures. So a window counts only when no run
        started in it or in the settle time before it; one that had a run is measured again after the run's
        answer has landed (the next run is 10 s away then); again False: None instead."""
        out = []
        before = self.runs()
        time.sleep(settle)
        for _ in range(samples + 6):
            p0, d0 = self.stats()
            time.sleep(seconds)
            p1, d1 = self.stats()
            after = self.runs()
            if after == before:
                out.append((p1 - p0 - 1, d1 - d0))
                if len(out) == samples:
                    return min(out)
            elif not again:
                return None
            else:
                before = after
                time.sleep(settle)
        self.fail('discovery ran in every window: %s' % out)


class NoticeTest(NoticeCase):
    def test_rate_limit_warning_and_rejection_bands(self):
        opened = self.work / 'opened'
        opener = self.work / 'opener.sh'
        opener.write_text(f'#!/bin/sh\necho "$1" >> {opened}\n', encoding='utf-8')
        opener.chmod(0o755)
        self.start(env={'FAKE_CLAUDE_RATE': 'warning', 'RHUN_OPEN_URL': str(opener)})
        self.chat('hello')
        resets = self.rates()[-1]['resetsAt']
        self.assertEqual(self.band('rate'), "You've used 85% of your 5-hour limit · resets " +
                         local_reset(resets, False))
        x, y, label, url = self.link('rate')                         # the account is a Max plan's (the fake's)
        self.assertEqual((label, url), ('Get more usage', 'https://claude.ai/settings/usage'))
        self.command(f'click {x} {y}')
        self.command('wait 50')
        palette = self.command('print-palette').splitlines()
        self.assertEqual(palette[0], 'choose=Claude Code wants to open claude.ai in your browser: '
                                     'https://claude.ai/settings/usage')
        self.command('key Escape')
        self.command('wait 200')
        self.assertFalse(opened.exists())                            # nothing opens without Open
        self.close('rate')
        self.assertIsNone(self.band('rate'))
        self.command('agent-prompt again')                           # the same notice again: it stays away
        self.command('wait-agent ready 10000')
        self.assertEqual(len(self.rates()), 2)
        self.assertIsNone(self.band('rate'))
        self.command('agent-prompt rate rejected')                   # another one shows
        self.command('wait-agent ready 10000')
        self.assertEqual(self.band('rate'), "You've hit your 5-hour limit · resets " +
                         local_reset(resets, False))
        for kind, text in (('weekly', "You've used 75% of your weekly limit · resets " +
                            local_reset(resets, True)),
                           ('over', 'Over 90% of your 5-hour limit used · resets ' + local_reset(resets, False)),
                           ('approaching', 'Approaching 5-hour limit · resets ' + local_reset(resets, False)),
                           ('paused', 'Usage is paused for your organization. For help, please contact support.'),
                           ('spend', "You've hit your spend limit · resets " + local_reset(resets, True)),
                           ('soon', "You've hit your 5-hour limit · resets soon")):
            self.command('agent-prompt rate ' + kind)
            self.command('wait-agent ready 10000')
            self.assertEqual(self.band('rate'), text, kind)
        self.command('agent-prompt rate allowed')                    # allowed: it goes
        self.command('wait-agent ready 10000')
        self.until(lambda: self.band('rate') is None, 'allowed takes the band away')
        self.assertIsNone(self.link('rate'))

    def test_no_link_without_a_paid_plan(self):
        self.start(env={'FAKE_CLAUDE_RATE': 'warning', 'FAKE_CLAUDE_ACCOUNT': 'none'})
        self.chat('hello')
        self.assertTrue(self.band('rate').startswith("You've used 85% of your 5-hour limit"))
        self.assertEqual(self.link('rate')[2:], ('View usage', 'dialog:usage'))   # phase 7: Account & usage

    def test_settings_error_band(self):
        self.start(env={'FAKE_CLAUDE_SETTINGS_ERROR': 'Unexpected token'})
        self.chat('hello')
        self.until(lambda: self.band('settings'), 'the band')
        self.assertEqual(self.band('settings'), 'Settings file failed to parse: %s — Unexpected token. '
                         'Permission rules and other settings from this file are not in effect.'
                         % (self.project / '.claude/settings.json'))
        self.close('settings')
        self.assertEqual(self.bands(), [])
        self.quit()
        self.start()
        self.chat('hello')
        self.assertEqual(self.bands(), [])

    def test_settings_refused_is_an_error_band(self):
        self.start(env={'FAKE_CLAUDE_SETTINGS_FAIL': 'settings are busy'})
        self.chat('hello')
        self.until(lambda: self.band('error'), 'the band')
        self.assertEqual(self.band('error'), "Couldn't read Claude Code's settings: settings are busy")
        self.assertEqual(self.thread()[-1], chat.REPLY + 'ok: hello')          # the conversation goes on

    def test_reset_times_follow_the_zone(self):
        """The reset's local time: a zone file's transitions, and past them its POSIX rule (a "slim" file, made
        with zic where there is one), each as Python's own local time says."""
        zones = [z for z in ('Australia/Sydney', 'America/New_York', 'Asia/Kolkata')
                 if Path('/usr/share/zoneinfo', z).exists()]
        slim = self.work / 'zones'
        zic = shutil.which('zic') or ('/usr/sbin/zic' if Path('/usr/sbin/zic').exists() else None)
        if zic:
            source = self.work / 'zones.txt'
            source.write_text('Zone Test/South 10:00 AN AE%sT\nRule AN 2008 max - Apr Sun>=1 2:00s 0 S\n'
                              'Rule AN 2008 max - Oct Sun>=1 2:00s 1:00 D\nZone Test/North -5:00 US E%sT\n'
                              'Rule US 2007 max - Mar Sun>=8 2:00 1:00 D\nRule US 2007 max - Nov Sun>=1 2:00 0 S\n',
                              encoding='utf-8')
            made = subprocess.run([zic, '-b', 'slim', '-d', str(slim), str(source)], capture_output=True)
            if made.returncode == 0:
                zones += [str(slim / 'Test/South'), str(slim / 'Test/North')]
        if not zones:
            self.skipTest('no zone files here')
        saved = os.environ.get('TZ')
        try:
            for zone in zones:
                self.start(env={'FAKE_CLAUDE_RATE': 'weekly', 'TZ': zone})
                self.chat('hello')
                resets = self.rates()[-1]['resetsAt']
                os.environ['TZ'] = zone
                time.tzset()
                self.assertEqual(self.band('rate'), "You've used 75% of your weekly limit \u00b7 resets " +
                                 local_reset(resets, True), zone)
                self.quit()
        finally:
            if saved is None:
                os.environ.pop('TZ', None)
            else:
                os.environ['TZ'] = saved
            time.tzset()

    def test_auth_conflict_band(self):
        self.start(env={'FAKE_CLAUDE_AUTH_CONFLICT': '1'})
        self.chat('hello')
        self.assertEqual(self.band('auth'), 'Claude Code has both your claude.ai login and ANTHROPIC_API_KEY, so it '
                         'may not use the credential you expect. Keep one and remove the other, then start a new '
                         'conversation (restart your editor if you removed one from your shell).')
        self.assertIn(' close=', self.bands()[0])
        self.assertFalse('auth_conflict' in self.command('print-agent-cfg'))
        self.quit()
        self.start()
        self.chat('hello')
        self.assertIsNone(self.band('auth'))

    def test_context_pie_appears_below_half(self):
        self.start(env={'FAKE_CLAUDE_CONTEXT': str(WINDOW * 40 // 100)})
        self.chat('hello')
        self.assertEqual(self.live_word('ctx'), '40')
        self.assertEqual(self.foot()['ctx_at'], '0,0')               # more than half left: no pie
        self.quit()
        self.start(env={'FAKE_CLAUDE_CONTEXT': str(WINDOW * 60 // 100)})
        self.chat('hello')
        self.assertEqual(self.live_word('ctx'), '60')
        foot = self.foot()
        self.assertNotEqual(foot['ctx_at'], '0,0')
        x, y = foot['ctx_at'].split(',')
        self.command(f'move {x} {y}')
        self.command('wait 700')
        self.assertIn('40% of context remaining until auto-compact. Click to compact now.',
                      self.command('print-tip'))
        self.command(f'click {x} {y}')                               # /compact goes as a prompt
        self.until(lambda: '/compact' in self.prompts(), '/compact sent')
        self.command('wait-agent ready 10000')
        self.until(lambda: self.foot()['ctx_at'] == '0,0', 'compacted: the context is small again')
        self.assertEqual(self.live_word('cache'), 'cold')            # the cache does not cover the summary
        self.assertEqual(self.foot()['clock'], 'cold')
        x, y = self.foot()['cache_at'].split(',')
        self.command(f'move {x} {y}')
        self.command('wait 700')
        self.assertIn('Prompt cache does not cover the compacted conversation.', self.command('print-tip'))

    def test_a_pie_click_during_a_turn_is_queued(self):
        self.start(env={'FAKE_CLAUDE_CONTEXT': str(WINDOW * 70 // 100)})
        self.chat('hello')
        x, y = self.foot()['ctx_at'].split(',')
        self.command('agent-prompt slow')
        self.command('wait-agent working')
        self.command(f'click {x} {y}')
        self.assertIn('queued /compact', self.command('print-agents'))
        self.until(lambda: '/compact' in self.prompts(), '/compact written at once')

    def test_cache_clock_warm_then_cold(self):
        self.start(extra='[ui]\nagents_width = 480\n')     # (room for the clock beside the "+": phase 4)
        self.chat('hello')
        self.assertEqual(self.live_word('cache'), '-')               # no cache written: no clock
        self.assertEqual(self.foot()['cache_at'], '0,0')
        self.command('agent-prompt usage')
        self.command('wait-agent ready 10000')
        self.assertEqual(self.live_word('cache'), '60m')             # an hour's cache, just written
        foot = self.foot()
        self.assertEqual(foot['clock'], '60m')
        x, y = foot['cache_at'].split(',')
        self.command(f'move {x} {y}')
        self.command('wait 700')
        self.assertIn('Prompt cache warm, about 60 min left.', self.command('print-tip'))
        self.command('agent-timing cache=1500')
        self.command('agent-prompt usage')
        self.command('wait-agent ready 10000')
        self.assertEqual(self.live_word('cache'), '1m')
        self.until(lambda: self.live_word('cache') == 'cold', 'expired', seconds=5)
        self.command('move 1 1')
        self.command(f'move {x} {y}')
        self.command('wait 700')
        self.assertIn('Prompt cache likely expired (idle 0m).', self.command('print-tip'))
        self.assertEqual(self.foot()['clock'], 'cold')

    def test_notices_add_no_timer(self):
        self.start(extra='[ui]\nagents_width = 480\n')     # (room for the clock beside the "+": phase 4)
        self.chat('hello')                                           # a conversation without a cache
        self.command('move 1 1')
        time.sleep(1.5)                                              # what the turn left settles
        plain, _ = self.idle(samples=2)
        plain4, _ = self.idle(4, samples=2)
        self.command('agent-prompt usage')                           # a warm cache: its clock shows
        self.command('wait-agent ready 10000')
        self.assertEqual(self.foot()['clock'], '60m')
        self.command('agent-test-band notice A notice that stays')
        time.sleep(1.5)
        warm, frames = self.idle(samples=2)
        self.assertLessEqual(warm, plain + 1, (warm, plain))         # its minute may turn once in 3 s
        self.assertLessEqual(frames, 1, frames)
        # a clock that changes while measured: a frame for it, no pass of its own. The window starts 2.5 s
        # after the discovery run the turn caused (1 to 3 s after the turn: 3.5 to 5.5 s after it), so the
        # clock goes cold 6 s after the turn, and is drawn at the next second, inside it; a window a
        # discovery run spoilt is measured again with a new turn
        self.command('agent-timing cache=6000')
        for _ in range(4):
            runs = self.runs()
            self.command('agent-prompt usage')
            self.command('wait-agent ready 10000')
            self.assertEqual(self.foot()['clock'], '1m')
            turned = time.time()
            while (self.runs() == runs or time.time() < turned + 1) and time.time() < turned + 3:
                time.sleep(0.1)
            measured = self.idle(4, again=False)
            if measured:
                break
        else:
            self.fail('discovery ran in every window')
        changing, frames = measured
        self.assertLessEqual(changing, plain4 + 1, (changing, plain4))
        self.assertGreaterEqual(frames, 1, 'the clock was redrawn when it went cold')
        self.assertEqual(self.foot()['clock'], 'cold')
        # hidden, the panel draws nothing and has no wake-up: the same as without a cache
        self.command('agent-timing cache=0')
        self.command('agent-prompt usage')
        self.command('wait-agent ready 10000')
        self.assertEqual(self.foot()['clock'], '60m')
        self.command('cmd toggle_agents')
        time.sleep(1.5)
        hidden, frames = self.idle(samples=2)
        self.assertEqual(frames, 0)
        self.command('cmd toggle_agents')
        self.command('agent-new claude')                             # a draft: no clock
        self.command('cmd toggle_agents')
        time.sleep(1.5)
        hidden_plain, _ = self.idle(samples=2)
        self.assertLessEqual(hidden, hidden_plain, (hidden, hidden_plain))

    def test_footer_fits_every_size_and_width(self):
        self.start(env={'FAKE_CLAUDE_MODELS': 'fast,ultra,effort', 'FAKE_CLAUDE_FAST': 'on -'})
        self.chat('hello')
        self.command('agent-ultra on')
        self.until(lambda: ' ultra=1 ' in self.command('print-agent-live'), 'Ultracode')
        self.command('agent-mode acceptEdits')
        self.until(lambda: self.mode() == 'acceptEdits', 'acceptEdits')
        pill = self.foot()['pill']
        self.assertTrue(pill.endswith(' · Ultracode'), pill)
        lines = self.command('print-agents-foot every').splitlines()[1:]
        self.assertEqual(len(lines), 8 * 25 * 34)
        stages = {}
        for line in lines:
            r, label, shown = foot_line(line)
            combo = r['combo']
            rects = {name: (r[name + '_x'], r[name + '_y'], r[name + '_w'], r[name + '_h'])
                     for name in FOOT_RECTS if r[name + '_w'] > 0}
            self.assertIn('mode', rects, line)                       # the mode button never goes
            self.assertIn('menu', rects, line)
            self.assertIn('send', rects, line)
            self.assertIn('pill', rects, line)                       # nor the pill: at worst on its own row
            for name, (x, y, w, h) in rects.items():
                self.assertGreater(h, 0, line)
                self.assertGreaterEqual(x, 0, line)
                self.assertLessEqual(x + w, r['w'], f'{name}: {line}')
                self.assertGreaterEqual(y, 0, line)
                self.assertLessEqual(y + h, r['h'], f'{name}: {line}')
            names = list(rects)
            for i, a in enumerate(names):
                for b in names[i + 1:]:
                    ax, ay, aw, ah = rects[a]
                    bx, by, bw, bh = rects[b]
                    apart = ax + aw <= bx or bx + bw <= ax or ay + ah <= by or by + bh <= ay
                    self.assertTrue(apart, f'{a} and {b} overlap: {line}')
            self.assertGreaterEqual(r['mode_w'], r['menu_w'], line)  # room for its dot or a cut label
            self.assertTrue(label == 'Edit automatically' or label.endswith('…'), line)
            self.assertTrue(shown == pill or shown.endswith('…'), line)
            self.assertLess(r['pill_text'], r['pill_w'], line)
            stage = r['stage']
            stages.setdefault(stage, 0)
            stages[stage] += 1
            if stage == 0:                                           # everything, nothing cut, one row
                self.assertEqual((label, shown), ('Edit automatically', pill), line)
                self.assertEqual(r['pill_y'], r['mode_y'], line)
                self.assertEqual('cache' in rects, bool(combo & 4), line)
                self.assertEqual('ctx' in rects, bool(combo & 2), line)
                self.assertEqual('fast' in rects, bool(combo & 1), line)
            elif stage == 1:                                         # the clock goes, the label may be cut
                self.assertNotIn('cache', rects, line)
                self.assertEqual(shown, pill, line)
                self.assertEqual(r['pill_y'], r['mode_y'], line)
                self.assertEqual('ctx' in rects, bool(combo & 2), line)
                self.assertEqual('fast' in rects, bool(combo & 1), line)
            else:                                                    # the pill on its own row, under it
                self.assertEqual(stage, 2, line)
                self.assertNotIn('cache', rects, line)
                self.assertGreaterEqual(r['pill_y'], r['mode_y'] + r['mode_h'], line)
        self.assertEqual(set(stages), {0, 1, 2}, stages)
        at = {}
        for line in lines:
            r, label, shown = foot_line(line)
            at[r['combo'], r['size'], r['w']] = (r, label, shown)
        for size in (8, 13):                                         # a wide panel holds everything
            r, label, shown = at[7, size, 600]
            self.assertEqual(r['stage'], 0, (size, r))
        r, _, _ = at[7, 32, 240]                                     # the narrowest, largest: two rows
        self.assertEqual(r['stage'], 2, r)
        r, _, _ = at[0, 13, 440]                                     # no extras at the default size (the
        self.assertLessEqual(r['stage'], 1, r)                       #   "+" of phase 4 takes 24 px: 380 is 2)
        # the pill's own row is room the footer takes: more than one row's at the same size
        for size in range(8, 33):
            rows = {r['stage'] == 2: r['h'] - r['mode_y'] for (c, s_, w), (r, _, _) in at.items() if s_ == size}
            if len(rows) == 2:
                self.assertGreater(rows[True], rows[False], size)


class UserSettingsScanTest(unittest.TestCase):
    """After ModelTest (the loader runs the classes in the order of their names): ModelCase's scan read every
    request the fake got in those tests, the picks among them, and update_settings was never one."""

    def test_the_scan_saw_the_model_tests(self):
        if not SCANNED:
            self.skipTest('run with ModelTest')
        self.assertIn('apply_flag_settings', SCANNED)
        self.assertIn('set_max_thinking_tokens', SCANNED)
        self.assertNotIn('update_settings', SCANNED)


AUTOSAVE_HOOKS = {'PreToolUse': [{'matcher': 'Edit|Write|Read', 'hookCallbackIds': ['hook_1']}]}   # p8


class SeamWordsTest(unittest.TestCase):
    """Nothing above the seam knows Claude (decision 2): phase 1's names stay where phase 1 put them."""

    FILES = ['agent_drv.s', 'agents.s', 'agentext.s', 'agentcfg.s', 'agentpop.s', 'agentcard.s',
             'agentcompose.s', 'agentfoot.s', 'mdtab.s',
             # phase 3's generic files: the rows, their diff, the spinner, time, focus view, tasks, selection
             'agentrows.s', 'agentdiff.s', 'agentspin.s', 'agenttime.s', 'agentfold.s', 'agenttask.s',
             'agentsel.s',
             'agentoffer.s',    # phase 4 tasks 11 and 12: a request's proposed change
             # phase 4 task 2: a message's parts, the editor's context
             'agentatt.s', 'agentctx.s',
             # phase 4 task 7: mentions and the project's file list
             'agentmention.s', 'filelist.s',
             # phase 4 tasks 9, 10: the MCP core and the editor's tools, shared by the bridge and the chat
             'edtools.s', 'mcpsrv.s',
             'agenttab.s']      # phase 4 task 13: conversation tabs, the status item
    # file -> name -> the functions it may appear in
    ALLOWED = {
        'agent_drv.s': {
            'AG_CLAUDE': {'agent_drv_apply', 'agent_drv_for_kind', 'agent_new', 'readers'},
            # phase 3: the readers of the kinds that have one (agent_ingest, agent_reader)
            'claude_ingest': {'readers'},
            'claude_text': {'readers'},
            'claude_kids': {'readers'},
            'claude_image': {'readers'},    # phase 4 task 6: the reader's fifth function
            'cfg_claude_chat': {'agent_drv_for_kind'},
            'cfg_claude_wrapper': {'failed_notice'},
            'cfg_agents_claude': {'agent_drv_unlisted'},
            'claude_drv': {'agent_drv_for_kind'},
            'claude_auth_tick': {'agent_drv_tick'},
            'claude_auth_timeout': {'agent_drv_timeout'},
            'claude_auth_end': {'agent_drv_apply', 'agent_drv_shutdown'},
            'claude_fork_dir': {'fork_copy'},
            'claude_transcript': {'new_as'},
            '.Lk_claude': {'kind_names'},
        },
        'agents.s': {
            '.Lclaude_name': {'agent_badge', 'agents_dump'},
            'claude_dir_moved': {'agents_tick'},
            'claude_index_envp': {'index_start'},
        },
        'agentext.s': {
            'AG_CLAUDE': {'agentext_list_buttons', 'agentext_remote_line'},
            'cfg_claude_chat': {'agentext_remote_line'},
            '.Lph_claude': {'agentext_bottom_draw'},
        },
    }
    # file -> the string definitions whose text may name Claude (besides those of the names above)
    STRINGS = {
        'agent_drv.s': {'.Lq_failed', '.Lq_signin', '.Lq_trust', '.Lq_wrapper_tail', '.Lunanswered',
                        '.Lo_terminal'},
        'agents.s': {'.Lclaude_name'},
        'agentext.s': {'.Lph_claude', '.Lsend_refused'},
        # the bridge's (phase 5): the server's name terminal claude shows, the owner its diffs name
        'edtools.s': {'.Ls_name', '.Ls_owner'},
    }
    # Claude itself, and (phase 3) its tools' and records' names: the rows above the seam never read them
    NAMES = (r'claude|Claude|AG_CLAUDE|Bash|TodoWrite|tool_use|tool_result|parent_tool_use_id|mcp__|ExitPlanMode|'
             r'AskUserQuestion|WebFetch|WebSearch|NotebookEdit|MultiEdit|ToolSearch|content_block|isSidechain|'
             r'stream_event|'
             # phase 4: Claude's tags and keys for a message's parts, the editor's server and hooks
             r'ide_selection|ide_opened_file|ide_diagnostics|inline_pastes|sdkMcpServers|hook_callback|mcp_message|'
             r'hookCallbackIds|updatedInput|media_type')
    WORD = re.compile(r'[.\w]*(?:' + NAMES + r')[.\w]*')
    STRING_DEF = re.compile(r'^\s*([.\w]+):\s*\.(?:asciz|ascii|string)\b(.*)$')
    STRING_MORE = re.compile(r'^\s*\.(?:asciz|ascii|string)\b(.*)$')
    LABEL = re.compile(r'^([A-Za-z_][\w]*):')
    FN = re.compile(r'^FN\s+(\w+)')

    def strip_comment(self, line):
        """The line without its comment (a # outside a string)."""
        out, quoted, i = [], False, 0
        while i < len(line):
            ch = line[i]
            if quoted and ch == '\\':
                out.append(line[i:i + 2])
                i += 2
                continue
            if ch == '"':
                quoted = not quoted
            elif ch == '#' and not quoted:
                break
            out.append(ch)
            i += 1
        return ''.join(out)

    def test_generic_files_name_claude_only_where_phase_1_did(self):
        found = []
        for name in self.FILES:
            path = ROOT / 'src/app' / name
            if not path.exists():               # the later tasks' files
                continue
            allowed = self.ALLOWED.get(name, {})
            strings = self.STRINGS.get(name, set())
            function, last_string = '-', None
            for number, raw in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
                line = self.strip_comment(raw)
                m = self.FN.match(line)
                if m:
                    function = m.group(1)
                else:
                    m = self.LABEL.match(line)
                    if m and not m.group(1).startswith('.'):
                        function = m.group(1)
                d = self.STRING_DEF.match(line)
                if d:
                    last_string = d.group(1)
                    text = d.group(2)
                else:
                    more = self.STRING_MORE.match(line)
                    if more and last_string:
                        text = more.group(1)
                    else:
                        last_string, text = None, None
                if text is not None:            # a string's text: its label must be allowed
                    if re.search(self.NAMES, text) and last_string not in strings | set(allowed):
                        found.append(f'{name}:{number} string {last_string}: {raw.strip()}')
                    continue
                for word in self.WORD.findall(line):
                    if function not in allowed.get(word, ()):
                        found.append(f'{name}:{number} {word} in {function}')
        self.assertEqual(found, [])


# ---- the phase 2 reviews' findings, interface side (notes/claude-chat-phase2-review-findings.md) ----
TRUNCATED = '[Message truncated - exceeded 50,000 character limit]'


class ReviewControlsTest(NoticeCase):
    """The review findings S2 (= A3), A4, A7, A8, A9, S5b, and the second round's R6 and R14; the command
    menu's entries and /login, /logout
    (checklist rows 1.24, 1.25; nothing here starts the real claude: the sign-in commands are only put in rhun's
    terminal prompt and left there); the CLI's truncation marker drawn muted (row 1.13)."""

    def pick(self, label):
        """The command menu's row of that label, as Enter takes it (the menu opened with the label as filter)."""
        self.command('agent-menu ' + label)
        n = next(int(m.group(1)) for m in re.finditer(r'^row (\d+) (.*?)\t', self.menu(), re.M)
                 if m.group(2) == label)
        self.command(f'agent-menu-pick {n}')

    def open_sid(self, sid):
        """Back to the list, then the conversation with that id (opening one may reorder the list: each row is
        tried more than once)."""
        for _ in range(3):
            self.command(f'click {chat.BACK[0]} {chat.BACK[1]}')
            rows = [line for line in self.command('print-agents').splitlines() if line.startswith('Claude')]
            for n in range(1, len(rows) + 1):
                self.command(f'print-agents {n}')
                self.command('wait 50')
                if self.sid() == sid:
                    return
                self.command(f'click {chat.BACK[0]} {chat.BACK[1]}')
        self.fail('no conversation ' + sid)

    def test_clear_leaves_no_text_in_its_conversation(self):
        """S2: /clear typed in a conversation: "/clear" is not kept as its draft, the new draft gets the text a
        new conversation left (as + Claude Code would give it), and the conversation's box is empty again."""
        self.start()
        self.chat('first')
        first = self.sid()
        self.chat('second')
        second = self.sid()
        self.command('agent-new claude')
        self.command('agent-type kept draft')       # a new conversation left before its first prompt
        self.open_sid(second)
        self.until(lambda: len(self.listed()) == 2, 'the draft left goes')
        self.open_sid(second)
        self.assertEqual(self.box(), '')
        self.command('agent-prompt /clear')
        self.assertIn(' new=claude ', self.command('print-agent-input'))
        self.assertEqual(self.box(), 'kept draft')
        self.open_sid(first)                        # another conversation, then the one /clear left
        self.open_sid(second)
        self.assertEqual(self.box(), '')
        self.assertEqual(self.prompts(), ['first', 'second'])

    def test_a_drafts_local_command_makes_no_conversation(self):
        """A4: a new draft's local command (/model, /copy) or a prompt the composer refuses makes no
        conversation; its prompt, sent, makes one."""
        self.start()
        self.chat('hello')
        self.command('agent-new claude')
        self.command('agent-prompt /model')
        head = self.head()
        self.assertEqual((head['popup'], head['owner']), ('models', '-'))
        self.command('key Escape')
        self.command('agent-prompt /copy')
        self.assertEqual(self.command('print-toast').strip(), 'toast=No assistant message to copy')
        self.command('agent-prompt a\u200bb')
        self.assertEqual(self.command('print-toast').strip(),
                         'toast=Removed 1 invisible character \u00b7 review and press Enter to send')
        self.assertTrue(self.command('print-agent-input').startswith('input=ab '))
        self.assertIn(' new=claude ', self.command('print-agent-input'))
        self.assertEqual(len(self.listed()), 1)
        self.command('agent-focus box')
        self.command('key Return')
        self.command('wait-agent ready')
        self.assertEqual(self.prompts(), ['hello', 'ab'])
        self.assertEqual(len(self.listed()), 2)

    def test_a_drafts_pickers_stay_open_and_make_nothing(self):
        """A7: in a new draft the effort row of the models picker steps the project's level: the picker stays
        open and no conversation is made; a model picked there is the project's choice."""
        self.start(env={'FAKE_CLAUDE_MODELS': 'effort,noeffort'})
        self.chat('hello')
        self.command('agent-new claude')
        self.command('agent-models')
        self.assertEqual(self.head()['owner'], '-')
        self.assertEqual(self.rows()[-1][4], 'levels=-')            # the project has no level of its own yet
        self.command('agent-menu-pick 3')           # the effort row: the next level round, the first
        self.assertTrue(self.menu().startswith('popup=models '), self.menu())
        self.assertEqual(self.rows()[-1][4], 'levels=low')
        self.command('key Right')
        self.assertTrue(self.menu().startswith('popup=models '))
        self.assertEqual(self.rows()[-1][4], 'levels=medium')
        self.assertTrue(self.choices().startswith('model=- effort=medium '), self.choices())
        self.command('agent-menu-pick 2')           # Sonnet: the picker closes, the draft stays one
        self.assertTrue(self.choices().startswith('model=sonnet '), self.choices())
        self.assertIn(' new=claude ', self.command('print-agent-input'))
        self.assertEqual(len(self.listed()), 1)
        self.assertEqual(len(self.starts()), 1)

    def test_the_pie_sends_one_compact_at_a_time(self):
        """S5b: clicks on the context pie while its /compact is held or runs send nothing more."""
        self.start(env={'FAKE_CLAUDE_CONTEXT': str(WINDOW * 70 // 100)})
        self.chat('hello')
        x, y = self.foot()['ctx_at'].split(',')
        self.command('agent-prompt slow')
        self.command('wait-agent working')
        for _ in range(3):
            self.command(f'click {x} {y}')
        self.assertEqual(self.command('print-agents').count('queued /compact'), 1)
        self.until(lambda: '/compact' in self.prompts(), '/compact written')
        self.command('wait-agent ready 20000')
        self.until(lambda: self.command('print-agents').count('queued') == 0, 'all ran')
        self.assertEqual(self.prompts().count('/compact'), 1)

    def pie_start(self):
        """A conversation whose context pie shows; where to click it."""
        self.start(env={'FAKE_CLAUDE_CONTEXT': str(WINDOW * 70 // 100)})
        self.chat('hello')
        return self.foot()['ctx_at'].split(',')

    def compacts_queued(self):
        return self.command('print-agents').count('queued /compact')

    def held_now(self):
        return int(re.search(r' held=(\d+)', self.command('print-agent-live')).group(1))

    def test_the_pies_guard_is_each_conversations_own(self):
        """R6: a /compact held in one conversation; another's pie sends its own; back in the first, its pie
        still sends no second one."""
        x, y = self.pie_start()
        first = self.sid()
        self.command('agent-prompt slow')
        self.command('wait-agent working')
        self.command(f'click {x} {y}')
        self.assertEqual(self.compacts_queued(), 1)
        self.chat('two')
        bx, by = self.foot()['ctx_at'].split(',')
        self.command(f'click {bx} {by}')                # the second conversation's: sent, it runs at once
        self.until(lambda: self.prompts().count('/compact') == 2, 'its /compact')
        self.open_sid(first)
        self.assertIn('state=working ', self.live())
        self.command(f'click {x} {y}')
        self.assertEqual(self.compacts_queued(), 1)

    def test_a_typed_compact_holds_the_pie(self):
        """R6: a /compact typed while a turn runs is held: the pie sends no second one."""
        x, y = self.pie_start()
        self.command('agent-prompt slow')
        self.command('wait-agent working')
        self.command('agent-prompt /compact')
        self.assertEqual(self.compacts_queued(), 1)
        self.command(f'click {x} {y}')
        self.assertEqual(self.compacts_queued(), 1)

    def test_a_compact_that_ended_unseen_does_not_hold_the_pie(self):
        """R6: the pie's /compact ran and ended while the panel was hidden; during a later ordinary turn the
        pie sends one again (held)."""
        x, y = self.pie_start()
        self.command('agent-prompt held')
        self.command('wait-agent working')
        self.command(f'click {x} {y}')                  # held: it runs after the turn, the panel hidden
        self.assertEqual(self.compacts_queued(), 1)
        self.command('cmd toggle_agents')
        self.until(lambda: '/compact' in self.prompts(), '/compact sent')
        self.command('wait-agent ready 20000')
        self.command('wait 300')
        self.command('agent-prompt slow')
        self.command('wait-agent working')
        self.command('cmd toggle_agents')
        self.until(lambda: self.foot()['ctx_at'] != '0,0', 'the pie again')
        x, y = self.foot()['ctx_at'].split(',')
        self.command(f'click {x} {y}')
        self.assertEqual(self.compacts_queued(), 1)

    def test_a_refused_pie_send_does_not_hold_the_pie(self):
        """R6: a pie click refused (sixteen messages held already) sends nothing and holds nothing: once there
        is room, a click sends it."""
        x, y = self.pie_start()
        self.command('agent-prompt held')
        self.command('wait-agent working')
        self.command('agent-prompt slow')
        for n in range(2, 17):
            self.command(f'agent-prompt m{n}')
        self.assertEqual(self.held_now(), 16)
        self.command(f'click {x} {y}')
        self.assertEqual(self.command('print-toast').strip(), 'toast=Sixteen messages are already waiting.')
        self.assertEqual(self.compacts_queued(), 0)
        self.until(lambda: self.held_now() == 15, 'slow started')
        self.command(f'click {x} {y}')
        self.assertEqual(self.compacts_queued(), 1)

    def test_the_menu_is_built_once_for_many_frames(self):
        """A8: the open command menu's rows are made when what they come from changes, not each frame."""
        self.start()
        self.chat('hello')
        self.command('agent-type /co')
        builds = int(self.head()['builds'])
        self.command('print-frames')
        for i in range(10):
            self.command(f'move {600 + i * 3} 300')
            self.command('wait 20')
        self.assertGreaterEqual(int(self.command('print-frames').split('=')[1]), 5)
        self.assertEqual(int(self.head()['builds']), builds)
        self.command('agent-type m')                # the filter changed: made again, once
        self.assertEqual(int(self.head()['builds']), builds + 1)
        self.assertEqual(self.labels()[0], '/compact')

    def test_the_painted_word_is_found_once_per_text(self):
        """A9: the box's painted word is looked for when the text changes, not on every frame."""
        self.start(env={'FAKE_CLAUDE_ULTRATHINK': '1'})
        self.chat('hello')
        self.command('agent-type ' + 'words ' * 5000 + 'ultrathink')
        self.command('wait 50')
        scans = int(ComposerTest.composer(self)['scans'])
        self.command('print-frames')
        for i in range(10):
            self.command(f'move {600 + i * 3} 300')
            self.command('wait 20')
        self.assertGreaterEqual(int(self.command('print-frames').split('=')[1]), 5)
        self.assertEqual(int(ComposerTest.composer(self)['scans']), scans)
        self.assertEqual(ComposerTest.composer(self)['paint'], '30000-30010')

    def test_reopening_the_menu_selects_its_first_row_again(self):
        """R14: the command menu opened again over itself (its rows unchanged) starts at the top: its first row
        selected, as its scroll is, not the row the keys had moved to."""
        self.ready()
        self.command('agent-menu')
        first = self.head()['sel']
        for _ in range(8):
            self.command('key Down')
        self.assertNotEqual(self.head()['sel'], first)
        self.command('agent-menu')
        self.assertEqual(self.head()['sel'], first)

    def test_menu_entries_without_a_test_before(self):
        """Checklist row 1.24: New conversation, Switch mode…, Open Claude in Terminal, General config…,
        Switch account, Sign out, View help docs, each run from the menu."""
        self.start()
        self.chat('hello')
        self.pick('New conversation')
        self.assertIn(' new=claude ', self.command('print-agent-input'))
        self.command('print-agents 1')
        self.pick('Switch mode\u2026')
        self.assertTrue(self.menu().startswith('popup=modes '), self.menu())
        self.command('key Escape')
        for label, field in (('Open Claude in Terminal', f'field={chat.FAKE}'),
                             ('Switch account', f'field={chat.FAKE} auth login'),
                             ('Sign out', f'field={chat.FAKE} auth logout')):
            self.pick(label)
            self.assertEqual(self.command('print-palette').splitlines()[:2], [chat.TERM_PROMPT, field], label)
            self.command('key Escape')              # left unrun: the terminal's prompt closes
        self.pick('View help docs')
        self.assertEqual(self.command('print-palette').splitlines()[0],
                         'choose=Claude Code wants to open code.claude.com in your browser: '
                         'https://code.claude.com/docs/en/vs-code')
        self.command('key Escape')
        self.pick('General config\u2026')
        self.assertIn('*Settings', self.command('print-tabs'))
        self.assertEqual(self.prompts(), ['hello'])
        self.assertEqual(len(self.starts()), 1)

    def test_login_and_logout_typed(self):
        """Checklist row 1.25: /login and /logout put the CLI's sign-in and sign-out in rhun's terminal prompt
        (not run), and send nothing to the program."""
        self.start()
        self.chat('hello')
        self.command('agent-prompt /login')
        self.assertEqual(self.command('print-palette').splitlines()[:2],
                         [chat.TERM_PROMPT, f'field={chat.FAKE} auth login'])
        self.command('key Escape')
        self.command('print-agents 1')
        self.command('agent-prompt /logout')
        self.assertEqual(self.command('print-palette').splitlines()[:2],
                         [chat.TERM_PROMPT, f'field={chat.FAKE} auth logout'])
        self.command('key Escape')
        self.assertEqual(self.prompts(), ['hello'])
        self.assertEqual(self.box(), '')

    def test_the_truncation_marker_is_muted(self):
        """Checklist row 1.13: a user row whose text holds the CLI's truncation marker draws it muted."""
        folder = self.work / '.claude/projects' / chat.slug(self.project)
        folder.mkdir(parents=True)
        user = 'Fix it\n\n' + TRUNCATED
        (folder / 's1.jsonl').write_text('\n'.join(json.dumps(r) for r in [
            {'type': 'user', 'message': {'role': 'user', 'content': user}, 'cwd': str(self.project),
             'sessionId': 's1'},
            {'type': 'user', 'message': {'role': 'user', 'content': 'plain'}, 'cwd': str(self.project),
             'sessionId': 's1'}]) + '\n', encoding='utf-8')
        self.start()
        self.open_listed()
        self.command('wait 50')
        head = self.command('print-agent-row 1').splitlines()[0]
        self.assertIn(' muted=%d' % len('Fix it\n\n'), head)
        self.assertIn(' muted=-', self.command('print-agent-row 2').splitlines()[0])


class ReviewProtocolTest(ModelCase):
    """The protocol review's findings (2026-11-23, both rounds), each against the fake: its knobs
    FAKE_CLAUDE_FOREIGN_ID, FAKE_CLAUDE_MODE_MS, FAKE_CLAUDE_SETTINGS_MS, FAKE_CLAUDE_NO_INIT_MODE,
    FAKE_CLAUDE_REFUSE_MODEL, FAKE_CLAUDE_FLAGS_MS, FAKE_CLAUDE_NO_LIFECYCLE=local, FAKE_CLAUDE_DISCARD_HELD=TEXT
    and the model knob longresolved have no recording behind them (the fake's docstring block says so).
    Nothing here writes Claude Code's own settings (ModelCase checks it after each test)."""

    def order(self):
        """What the fake read, in order: control requests by subtype, user messages as "user TEXT"."""
        out = []
        for m in self.stdin():
            if m.get('type') == 'control_request':
                out.append(m['request']['subtype'])
            elif m.get('type') == 'user':
                out.append('user ' + m['message']['content'][0]['text'])
        return out

    def open_sid(self, sid):
        """The listed conversation whose id is sid, opened."""
        rows = self.listed()
        for n in range(1, len(rows) + 1):
            self.command(f'print-agents {n}')
            if self.sid() == sid:
                return
        self.fail('no conversation ' + sid)

    def held_count(self):
        return int(re.search(r' held=(\d+)', self.command('print-agent-live')).group(1))

    def head_cfg(self):
        first = self.command('print-agent-cfg').splitlines()[0]
        return dict(word.split('=', 1) for word in first.split(' '))

    def test_a_foreign_answer_is_not_rhuns(self):
        # P4: an answer whose id is rhun's own followed by more ("r2abc") answers nothing of rhun's
        self.start(env={'FAKE_CLAUDE_FOREIGN_ID': '1'})
        self.chat('hello')
        self.until(lambda: ' model=claude-opus-5-5 ' in self.command('print-agent-live'), 'the true answer')
        self.command('wait 200')
        self.assertIn(' model=claude-opus-5-5 ', self.command('print-agent-live'))

    def test_the_kept_choices_go_before_the_first_prompt(self):
        # P2: the project's Ultracode (applied once get_settings answered) is written before the prompt
        self.start(env={'FAKE_CLAUDE_MODELS': 'ultra'})
        self.command('agent-cfg-set ultra 1')
        self.chat('hello')
        order = self.order()
        self.assertEqual(order[:2], ['initialize', 'get_settings'])
        self.assertIn('apply_flag_settings', order)
        self.assertLess(order.index('apply_flag_settings'), order.index('user hello'))
        self.assertEqual(self.flags(), [{'ultracode': True}])
        # a model picked while it starts goes before the prompt too
        self.released()
        self.command('agent-prompt again')
        self.command('agent-model sonnet')
        self.command('wait-agent ready 10000')
        order = self.order()
        second = order[len(order) - 1 - order[::-1].index('initialize'):]
        self.assertEqual(second[:2], ['initialize', 'get_settings'])
        self.assertLess(second.index('apply_flag_settings'), second.index('user again'))
        self.assertIn({'model': 'sonnet'}, self.flags())

    def test_prompts_wait_for_the_settings_at_most_the_bound(self):
        # P2: a get_settings that never answers holds the prompts only for the bound (agent-timing settings=)
        self.start(env={'FAKE_CLAUDE_SETTINGS_MS': 'never'})
        self.command('agent-timing settings=1500')
        began = time.monotonic()
        self.chat('hello')
        self.assertGreaterEqual(time.monotonic() - began, 1.4)
        self.assertEqual(self.thread()[-1], chat.REPLY + 'ok: hello')
        # one that answers late: the prompts go when it does, before the bound
        self.quit()
        self.start(env={'FAKE_CLAUDE_SETTINGS_MS': '400'})
        self.command('agent-timing settings=5000')
        began = time.monotonic()
        self.chat('hello')
        self.assertLess(time.monotonic() - began, 4)
        records = self.records()
        records = records[max(i for i, r in enumerate(records) if r.get('start') == 'stream'):]
        answered = next(i for i, r in enumerate(records) if 'settings_answer' in r)
        user = next(i for i, r in enumerate(records) if 'stdin' in r and json.loads(r['stdin']).get('type') == 'user')
        self.assertLess(answered, user)

    def test_a_refused_settings_answer_lets_the_prompts_go(self):
        self.start(env={'FAKE_CLAUDE_SETTINGS_FAIL': 'no settings'})
        self.chat('hello')
        self.assertEqual(self.thread()[-1], chat.REPLY + 'ok: hello')

    def test_a_refused_pick_during_a_start_goes_back(self):
        # P3: a mode picked while the program starts and refused by it: the label and the kept mode are the
        # program's again, and the refused mode is not the project's default
        self.start(env={'FAKE_CLAUDE_INIT_MS': '800', 'FAKE_CLAUDE_MODELS': 'auto', 'FAKE_CLAUDE_REFUSE_AUTO': '1'})
        self.chat('hello')                              # the lists (auto is offered), then a start again
        self.released()
        self.command('agent-prompt again')
        self.command('agent-mode auto')
        self.command('wait-agent ready 10000')
        self.until(lambda: self.asked() == ['auto'], 'asked')
        self.until(lambda: self.mode() == 'default', 'the mode it reported')
        self.assertEqual(self.foot()['label'], 'Manual')
        self.assertIn(self.conv_mode(self.sid()), (None, 'default'))
        self.assertNotEqual(self.newmode(), 'auto')
        self.assertIn('Failed to set mode', self.command('print-toast'))

    def test_a_pick_during_a_start_without_a_reported_mode_is_sent(self):
        # 4.3 (2): initialize without current_permission_mode still sends the pick before the prompt
        self.start(env={'FAKE_CLAUDE_INIT_MS': '800', 'FAKE_CLAUDE_NO_INIT_MODE': '1'})
        self.command('agent-new claude')
        self.command('agent-prompt hello')
        self.command('agent-mode acceptEdits')
        self.command('wait-agent ready 10000')
        order = self.order()
        self.assertIn('set_permission_mode', order)
        self.assertLess(order.index('set_permission_mode'), order.index('user hello'))
        self.assertEqual(self.asked(), ['acceptEdits'])
        self.until(lambda: self.mode() == 'acceptEdits', 'the mode')

    def test_bypass_picked_during_a_start_goes_through_the_gate_again(self):
        # 4.3 (3): the setting turned off before initialize answered: bypass is neither sent nor shown
        self.start(self.claude_section('allow_bypass_permissions = true\n'), env={'FAKE_CLAUDE_INIT_MS': '8000'})
        self.command('agent-new claude')
        self.command('agent-prompt hello')
        self.command('agent-mode bypassPermissions')
        self.assertEqual(self.foot()['label'], 'Bypass permissions')
        time.sleep(1.1)                                 # (the config's time changes)
        self.config.write_text(self.BASE + self.claude_section('allow_bypass_permissions = false\n'), encoding='utf-8')
        self.until(lambda: not self.reply('agent-mode bypassPermissions')[1], 'the reload', 7)
        self.assertFalse([r for r in self.records() if 'initialize' in r], 'initialize answered too early')
        self.command('wait-agent ready 10000')
        self.command('wait 200')
        self.assertNotIn('bypassPermissions', self.asked())
        self.assertNotEqual(self.mode(), 'bypassPermissions')
        self.assertNotEqual(self.foot()['label'], 'Bypass permissions')

    def test_thinking_switched_during_a_start_is_applied(self):
        # 4.3 (1): as model and effort are, once the program is up
        self.start(env={'FAKE_CLAUDE_MODELS': 'nothink', 'FAKE_CLAUDE_INIT_MS': '800'})
        self.chat('hello', ms=15000)
        self.released()
        self.command('agent-prompt again')
        self.command('agent-thinking off')
        self.command('wait-agent ready 10000')
        self.assertEqual(self.starts()[-1]['switches']['thinking'], '31999')
        self.until(lambda: self.thinking() and self.thinking()[-1]['max_thinking_tokens'] == 0, 'thinking off')
        order = self.order()
        last = len(order) - 1 - order[::-1].index('initialize')
        self.assertLess(order.index('set_max_thinking_tokens', last), order.index('user again'))

    def test_bypass_at_a_start_without_the_setting_is_left(self):
        # P7: the user's own default starts the CLI in bypass; rhun's setting is off: default is asked for
        # before any prompt, the footer follows the CLI's answer, nothing remembers bypass
        self.start(env={'FAKE_CLAUDE_MODE': 'bypassPermissions'})
        self.chat('hello')
        order = self.order()
        self.assertEqual(order[:2], ['initialize', 'get_settings'])
        self.assertIn('set_permission_mode', order)
        self.assertLess(order.index('set_permission_mode'), order.index('user hello'))
        self.assertEqual(self.asked(), ['default'])
        self.until(lambda: self.mode() == 'default', 'default')
        self.assertEqual(self.foot()['label'], 'Manual')
        self.assertNotEqual(self.conv_mode(self.sid()), 'bypassPermissions')
        self.assertNotEqual(self.newmode(), 'bypassPermissions')
        self.quit()
        # with the setting on, the CLI's bypass stays
        self.start(self.claude_section('allow_bypass_permissions = true\n'),
                   env={'FAKE_CLAUDE_MODE': 'bypassPermissions'})
        self.chat('hello')
        self.assertEqual(self.mode(), 'bypassPermissions')

    def test_two_conversations_pick_modes_at_once(self):
        # 4.2: the mode before a pick is each conversation's own: a refusal in one while the other asks puts
        # its own mode back
        self.start(env={'FAKE_CLAUDE_MODELS': 'auto', 'FAKE_CLAUDE_REFUSE_AUTO': '1', 'FAKE_CLAUDE_MODE_MS': '800'})
        self.chat('one')
        first = self.sid()
        self.chat('two')
        second = self.sid()
        self.open_sid(first)
        self.command('agent-mode auto')                 # refused, 800 ms later
        self.open_sid(second)
        self.command('agent-mode acceptEdits')
        self.until(lambda: sorted(self.asked()) == ['acceptEdits', 'auto'], 'both asked')
        self.until(lambda: len([r for r in self.records() if 'mode_answer' in r]) == 2, 'both answered')
        self.command('wait 200')
        self.assertEqual(self.mode(), 'acceptEdits')
        self.open_sid(first)
        self.assertEqual(self.mode(), 'default')
        self.assertIn(self.conv_mode(first), (None, 'default'))

    def test_a_refused_model_is_not_kept(self):
        # 4.2: a model the CLI refuses is not the project's choice, and no pill names it
        self.start(env={'FAKE_CLAUDE_REFUSE_MODEL': 'sonnet'})
        self.chat('hello')
        self.command('agent-model sonnet')
        self.until(lambda: 'Failed to set model' in self.command('print-toast'), 'the refusal')
        self.until(lambda: ' model=claude-opus-5-5 ' in self.command('print-agent-live'), 'back')
        self.assertTrue(self.choices().startswith('model=- '), self.choices())
        self.assertEqual(self.pills(), [])
        self.command('agent-cfg-set ultra 0')
        self.command('agent-model default')             # one that goes: its own pill only
        self.until(lambda: self.pills(), 'a pill')
        self.assertEqual(self.pills(), ['Switched to Default (recommended)'])

    def test_a_refused_first_prompt_is_in_the_box_only(self):
        # P6: the first prompt that waited for the start, refused by the connection's queue without breaking
        # it: back in the box, no row
        # (phase 4 task 9: initialize carries rhun's server and note, about 3 KB: the queue holds it, not the prompt)
        self.start(env={'FAKE_CLAUDE_INIT_MS': '500'})
        self.command('agent-timing queue=6000')
        self.command('agent-new claude')
        long = 'long ' + 'x' * 8000
        self.command('agent-prompt ' + long)
        self.command('wait-agent ready 10000')
        self.command('wait 100')
        self.assertNotIn('user ' + long[:50], ' '.join(self.thread()))
        self.assertTrue(self.command('print-agent-input').startswith('input=' + long + ' '))
        # the same for a prompt sent while it is ready
        self.command('agent-timing queue=%d' % (16 << 20))
        self.command('key ' + chat.MOD + '+a')
        self.command('key BackSpace')
        self.command('agent-prompt hello')
        self.command('wait-agent ready 10000')
        self.command('agent-timing queue=6000')
        self.command('agent-prompt ' + long)
        self.command('wait 100')
        self.assertEqual([r for r in self.thread() if r.startswith('user ')], ['user hello'])
        self.assertTrue(self.command('print-agent-input').startswith('input=' + long + ' '))

    def test_a_held_message_without_a_start_report(self):
        # 4.1: a held message that runs without command_lifecycle or replay (a command the CLI answers itself)
        # is a row once its turn ended; the next message's turn runs (Stop stops it, the idle stop waits);
        # its end puts nothing back in the box
        self.start(env={'FAKE_CLAUDE_NO_LIFECYCLE': '1'})
        self.chat('held', 'working')
        self.command('agent-prompt /cost')            # (phase 7: /context is rhun's dialog)
        self.until(lambda: self.held_count() == 1, 'held')
        self.command('wait-agent ready 20000')
        self.until(lambda: 'user /cost' in self.thread(), 'its row')
        self.assertEqual(self.held_count(), 0)
        self.assertEqual([l for l in self.command('print-agents').splitlines() if l.startswith('queued ')], [])
        # the next one runs, as a turn: working, and Stop interrupts it
        self.command('agent-timing idle=300')
        self.command('agent-prompt held')
        self.command('wait-agent working 5000')
        self.command('wait 600')                        # past the idle stop: a running turn is not idle
        self.assertIn('state=working ', self.live())
        self.command('agent-stop')
        self.until(lambda: [r for r in self.stdin() if r.get('type') == 'control_request'
                            and r['request']['subtype'] == 'interrupt'], 'the interrupt')
        self.command('wait-agent ready 10000')
        self.assertEqual(len(self.starts()), 1)
        # its end (the idle stop) puts nothing back
        self.until_gone()
        self.assertTrue(self.command('print-agent-input').startswith('input= '))
        self.assertNotIn('A queued message was not sent.', self.command('print-toast'))

    def test_a_prompt_ending_with_the_cli_marker_counts_as_the_box_does(self):
        # 3.3: agent_send counts as the box does (UTF-16 units, the CLI's own truncation marker not counted)
        self.start()
        self.chat('hello')
        marker = '[Message truncated - exceeded 50,000 character limit]'
        source = self.project / 'long.txt'             # pasted into the box from a file (two line feeds)
        source.write_text('a' * 50000 + '\n\n' + marker, encoding='utf-8')
        self.command('open ' + str(source))
        self.command('key ' + chat.MOD + '+a')
        self.command('key ' + chat.MOD + '+c')
        self.command('key ' + chat.MOD + '+w')
        self.command('key Escape')
        self.command('cmd focus_agents')
        self.command('key Tab')
        self.command('key ' + chat.MOD + '+v')
        self.assertTrue(self.command('print-agent-input').startswith('input=aaa'))
        self.command('key Return')
        self.until(lambda: len(self.prompts()) == 2, 'sent')
        self.assertEqual(self.prompts()[-1], 'a' * 50000 + '\n\n' + marker)
        self.assertNotIn('50,000', self.command('print-toast'))

    # ---- the second round (2026-11-23, on the fixes) ----

    def last_start(self):
        """order() from the last initialize on: what the latest process read."""
        order = self.order()
        if 'initialize' not in order:
            return []
        return order[len(order) - 1 - order[::-1].index('initialize'):]

    def wake(self):
        return re.search(r' wake=(\S+)', self.command('print-agent-live')).group(1)

    def test_stop_during_the_settings_wait_leaves_no_clock(self):
        # R8 (R3's second half): Stop while the prompts wait for get_settings: the wait's clock goes with the
        # start (no wake-up for it), and nothing is written to the process afterwards (the late answer comes)
        self.start(env={'FAKE_CLAUDE_MODELS': 'ultra', 'FAKE_CLAUDE_SETTINGS_MS': '1500'})
        self.command('agent-cfg-set ultra 1')
        self.chat('hello')
        self.released()
        self.command('agent-prompt again')
        self.command('agent-model sonnet')              # a pick waiting for the settings' answer
        self.until(lambda: self.order().count('initialize') == 2 and 'get_settings' in self.last_start(),
                   'get_settings asked')
        self.assertRegex(self.wake(), r'^\d+$')         # the wait's bound is the loop's next wake-up
        self.command('agent-stop')
        self.assertIn('state=off ', self.live())
        self.assertEqual(self.wake(), '-')
        written = len(self.stdin())
        time.sleep(2)                                   # past the late answer and past the bound
        self.assertEqual(len(self.stdin()), written)
        self.assertNotIn('user again', self.order())
        self.assertEqual(self.wake(), '-')

    def test_a_plan_whose_start_was_stopped_asks_nothing_later(self):
        # R2: /plan in plan mode starts the program for the plan; Stop during that start: a later start for
        # an ordinary prompt shows no plan and asks for none
        self.start(env={'FAKE_CLAUDE_INIT_MS': '800'})
        self.chat('hello', ms=15000)
        self.command('agent-mode plan')
        self.until(lambda: self.mode() == 'plan', 'plan mode')
        self.released()
        self.command('agent-prompt /plan')
        self.assertIn('state=starting ', self.live())
        self.command('agent-stop')
        self.assertIn('state=off ', self.live())
        self.until_gone()
        self.command('agent-mode default')
        self.command('agent-prompt again')
        self.command('wait-agent ready 10000')
        self.command('wait 300')
        self.assertEqual(self.requests('get_plan'), [])
        self.assertNotIn("info Couldn't show the plan", self.thread())

    def test_a_late_settings_answer_still_applies_ultracode(self):
        # R3: get_settings answers after the bound: the prompt went at the bound, and the late answer still
        # asks for the project's Ultracode (it differs from what the process reports)
        self.start(env={'FAKE_CLAUDE_MODELS': 'ultra', 'FAKE_CLAUDE_SETTINGS_MS': '1500'})
        self.command('agent-cfg-set ultra 1')
        self.command('agent-timing settings=300')
        self.chat('hello')
        self.until(lambda: {'ultracode': True} in self.flags(), 'Ultracode asked once the answer came')
        order = self.order()
        self.assertLess(order.index('user hello'), order.index('apply_flag_settings'))

    def test_a_refused_write_before_the_prompts_fails_the_start(self):
        # R9: the process started in bypass (the user's own default) and rhun's gate is shut: default must be
        # asked before any prompt. That write refused (the queue full, the connection up): the start fails
        # with its words, the prompt is back in the box, nothing was sent. agent-timing queue=90 lets the
        # 82-byte get_settings line through and refuses the 106-byte set_permission_mode one
        self.start(env={'FAKE_CLAUDE_MODE': 'bypassPermissions', 'FAKE_CLAUDE_INIT_MS': '800'})
        self.command('agent-new claude')
        self.command('agent-prompt hello')
        self.until(lambda: 'initialize' in self.order(), 'initialize written')
        self.command('agent-timing queue=90')
        self.command('wait-agent failed 10000')
        self.command('agent-timing queue=%d' % (16 << 20))
        order = self.order()                            # (get_settings, if it was read before the stop)
        self.assertEqual(order[0], 'initialize')
        self.assertNotIn('set_permission_mode', order)
        self.assertNotIn('user hello', order)
        self.assertIn('report=Claude Code took no more input before the conversation', self.command('print-agent-live'))
        self.assertTrue(self.command('print-agent-input').startswith('input=hello '))
        self.assertNotIn('user hello', self.thread())

    def test_each_model_answer_settles_its_own_pick(self):
        # R4: Sonnet, then Default picked before the first answer (FAKE_CLAUDE_FLAGS_MS: both answered later, in
        # order); Sonnet applies, Default is refused: the project's model is Sonnet, the only pill names it
        self.start(env={'FAKE_CLAUDE_FLAGS_MS': '600', 'FAKE_CLAUDE_REFUSE_MODEL': 'default'})
        self.chat('hello')
        self.command('agent-model sonnet')
        self.command('agent-model default')
        self.until(lambda: len([r for r in self.records() if 'flags_answer' in r]) == 2, 'both answered')
        self.until(lambda: 'Failed to set model' in self.command('print-toast'), 'the refusal')
        self.until(lambda: ' model=claude-sonnet-5 ' in self.command('print-agent-live'), 'in effect')
        self.assertTrue(self.choices().startswith('model=sonnet '), self.choices())
        self.assertEqual(self.pills(), ['Switched to Sonnet'])

    def test_a_drop_that_ends_the_last_turn_lets_an_unreported_command_join(self):
        # R10: a turn runs; /context (no lifecycle, no replay: FAKE_CLAUDE_NO_LIFECYCLE=local) and p2 are held;
        # the turn ends, /context runs and ends unreported, the CLI discards p2: /context is a row, nothing is
        # queued, p2 is back in the box, and the conversation is idle (its idle stop puts nothing back)
        self.start(env={'FAKE_CLAUDE_NO_LIFECYCLE': 'local', 'FAKE_CLAUDE_DISCARD_HELD': 'p2'})
        self.chat('held', 'working')
        self.command('agent-prompt /cost')            # (phase 7: /context is rhun's dialog)
        self.command('agent-prompt p2')
        self.until(lambda: self.held_count() == 2, 'both held')
        self.until(lambda: [r for r in self.records() if 'discarded' in r], 'the discard')
        self.command('wait-agent ready 20000')
        self.command('wait 100')
        self.assertIn('user /cost', self.thread())
        self.assertEqual(self.held_count(), 0)
        self.assertEqual([l for l in self.command('print-agents').splitlines() if l.startswith('queued ')], [])
        self.assertTrue(self.command('print-agent-input').startswith('input=p2 '))
        self.command('agent-timing idle=300')
        self.until_gone()
        self.assertTrue(self.command('print-agent-input').startswith('input=p2 '))

    def test_plan_waits_for_a_start_and_starts_a_failed_program(self):
        # R11: /plan in plan mode while the program starts (initialize not answered): get_plan goes once it is
        # up, after the settings are asked (not as the second line, before initialize's answer); after the
        # program failed, /plan starts it again and asks for the plan
        self.start(env={'FAKE_CLAUDE_INIT_MS': '800'})
        self.chat('hello', ms=15000)
        self.command('agent-mode plan')
        self.until(lambda: self.mode() == 'plan', 'plan mode')
        self.released()
        self.command('agent-prompt again')
        self.assertIn('state=starting ', self.live())
        self.command('agent-prompt /plan')
        self.command('wait-agent ready 10000')
        self.until(lambda: 'get_plan' in self.last_start(), 'get_plan')
        second = self.last_start()
        self.assertLess(second.index('get_settings'), second.index('get_plan'))
        self.command('agent-prompt exit 300')
        self.command('wait-agent failed 10000')
        starts = len(self.starts())
        self.command('agent-prompt /plan')
        self.until(lambda: len(self.starts()) == starts + 1, 'started again')
        self.command('wait-agent ready 10000')
        self.until(lambda: self.order().count('initialize') == 3 and 'get_plan' in self.last_start(),
                   'get_plan after the failure')

    def test_a_refused_pick_where_no_mode_was_reported_is_not_kept(self):
        # R12: initialize reports no mode; auto picked while it starts is refused: the conversation keeps no
        # mode (not auto), and its next start does not pass auto
        self.start(env={'FAKE_CLAUDE_INIT_MS': '800', 'FAKE_CLAUDE_NO_INIT_MODE': '1', 'FAKE_CLAUDE_MODELS': 'auto',
                        'FAKE_CLAUDE_REFUSE_AUTO': '1'})
        self.chat('hello', ms=15000)                    # the lists (auto is offered), then a start again
        sid = self.sid()
        self.released()
        self.command('agent-prompt again')
        self.command('agent-mode auto')
        self.assertEqual(self.conv_mode(sid), 'auto')   # kept while it is asked
        self.command('wait-agent ready 10000')
        self.until(lambda: 'Failed to set mode' in self.command('print-toast'), 'the refusal')
        self.assertIn(self.conv_mode(sid), (None, '-'))
        self.released()
        self.command('agent-prompt third')
        self.command('wait-agent ready 10000')
        self.assertEqual(self.argv_modes()[-1], [])

    def test_a_long_resolved_id_is_cut(self):
        # 2.1: a model's resolvedModel is kept at most 63 bytes, in memory and in the state file
        self.start(env={'FAKE_CLAUDE_MODELS': 'longresolved'})
        self.chat('hello')
        self.released()
        self.assertNotEqual(self.head_cfg()['path'], '-')
        lines = [l for l in Path(self.head_cfg()['path']).read_text(encoding='utf-8').splitlines() if l.startswith('model\tlong\t')]
        self.assertEqual(len(lines), 1, lines)
        resolved = lines[0].split('\t')[6]
        self.assertTrue(resolved.startswith('claude-xxx'), resolved)
        self.assertLessEqual(len(resolved.encode('utf-8')), 63)


if __name__ == '__main__':
    unittest.main()
