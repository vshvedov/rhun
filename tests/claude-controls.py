#!/usr/bin/env python3
"""Claude Code's controls in the agents panel (phase 2: settings, the per-project lists, the composer,
menus, modes, models, notices, queueing), against the fake CLI (tests/scripts/fake-claude.py), over the
control socket. It imports tests/claude-chat.py for its cases: every rhun gets its own HOME and XDG
folders, an environment without CLAUDE* or ANTHROPIC* variables, and a config whose [claude] section
starts the fake. Nothing here writes the user's own Claude Code settings: the fake's config folder is the
test's HOME."""
import importlib.util
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location('claude_chat', ROOT / 'tests/claude-chat.py')
chat = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(chat)

LEVELS = 'low:Low,medium:Medium,high:High'


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
                                'claude.allow_bypass_permissions', 'claude.prompt_suggestions'])
        agents = [line for line in out.splitlines() if line.startswith('agents.')]
        self.assertEqual(agents[-3:], ['agents.font_size', 'agents.ctrl_enter_sends', 'agents.scroll_on_send'])
        self.command('cmd toggle_word_wrap')            # a setting changed: the exit writes the file
        self.quit()
        saved = self.config.read_text(encoding='utf-8')
        self.assertEqual(chat.section(saved, 'claude')[3:], [
            'initial_mode =', 'allow_bypass_permissions = false', 'prompt_suggestions = true'])
        self.assertEqual(chat.section(saved, 'agents')[-3:], [
            'font_size = 0', 'ctrl_enter_sends = false', 'scroll_on_send = true'])
        # changed, they are written back as they are; the env pairs still follow the last [claude] row
        claude = self.claude_section('initial_mode = acceptEdits\nallow_bypass_permissions = true\n'
                                     'prompt_suggestions = false\nenv.FOO = bar\n')
        self.start(claude, '[agents]\nctrl_enter_sends = true\nscroll_on_send = false\n')
        out = self.command('print-settings')
        rows = [line for line in out.splitlines() if line.startswith('claude.')]
        self.assertEqual(rows[-3:], ['claude.allow_bypass_permissions', 'claude.prompt_suggestions',
                                     'claude.env.FOO=(set)'])
        self.command('cmd toggle_word_wrap')
        self.quit()
        saved = self.config.read_text(encoding='utf-8')
        self.assertEqual(chat.section(saved, 'claude'), [
            'chat = true', f'executable = {chat.FAKE}', f'wrapper = {chat.PYTHON}', 'initial_mode = acceptEdits',
            'allow_bypass_permissions = true', 'prompt_suggestions = false', 'env.FOO = bar'])
        self.assertEqual(chat.section(saved, 'agents')[-2:], ['ctrl_enter_sends = true', 'scroll_on_send = false'])

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
                      "\t-\tsend\tcli", cmds)
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
        self.assertEqual(names, ['compact', 'usage', 'review', 'clear', 'model', 'plan', 'copy', 'login',
                                 'logout'])
        self.assertIn('review\tSkill review\t-\t-\t-\tsend\tcli', self.lines('cmd'))
        text = self.state_file().read_text(encoding='utf-8')
        self.assertIn('cmd\treview\t', text)
        self.assertNotIn('cmd\tcontext\t', text)

    def test_settings_are_asked_after_initialize(self):
        self.start(env={'FAKE_CLAUDE_MODELS': 'ultra'})
        self.chat('hello')
        requests = [m['request']['subtype'] for m in self.stdin() if m.get('type') == 'control_request']
        self.assertEqual(requests, ['initialize', 'get_settings'])
        live = self.command('print-agent-live')
        self.assertIn(' model=claude-opus-5-5 effort=high ultra=0 think=1 fast=off held=0 ctx=- cache=- '
                      'suggest=0 ', live)
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
        thread = self.thread()
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
        return [r['initialize'] for r in self.records() if 'initialize' in r]

    def test_the_new_flags_are_passed(self):
        self.start(env={'FAKE_CLAUDE_ECHO_ENV': 'CLAUDE_CODE_QUESTION_PREVIEW_FORMAT'})
        self.chat('hello')
        start = self.starts()[-1]
        argv = start['argv']
        self.assertIn('--replay-user-messages', argv)
        self.assertIn('--max-thinking-tokens=31999', argv)
        self.assertEqual([a for a in argv if a.startswith(('--model', '--effort', '--thinking', '--allow-'))], [])
        self.assertEqual(start['env']['CLAUDE_CODE_QUESTION_PREVIEW_FORMAT'], 'markdown')
        self.assertEqual(self.initialize(), [{'promptSuggestions': True, 'supportedDialogKinds': []}])
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
        self.assertEqual(self.initialize(), [{'promptSuggestions': False, 'supportedDialogKinds': []}])


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
        self.assertEqual(slash, ['/compact', '/context', '/usage', '/plan', '/copy'])
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

    def test_typed_dialog_command_goes_to_the_cli(self):
        # the CLI answers /status itself (finding 22): rhun sends it as text
        self.ready()
        self.command('agent-prompt /status')
        self.command('wait-agent ready')
        self.until(lambda: '/status' in self.prompts(), 'sent')
        self.until(lambda: any("/status isn't available in this environment." in row for row in self.thread()),
                   "the CLI's answer")

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
        self.assertEqual([r[1:3] for r in self.rows()], [('Default (recommended)', 'Opus 5.5'), ('Sonnet', 'Sonnet 5')])
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
        """The modes picker's rows (label, flags), opened as its button opens it, then closed."""
        self.command('agent-modes')
        menu = self.menu()
        self.assertTrue(menu.startswith('popup=modes '), menu)
        self.assertIn('\nsection Modes\t⇧ + tab to switch\n', menu)
        rows = self.rows()
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
        head, label = first.split(' label=', 1)
        out = dict(word.split('=', 1) for word in head.split(' '))
        out['label'] = label
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
        self.command('agent-prompt /plan')
        self.assertIn('info Already in plan mode. No plan written yet.', self.thread())
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
            r = {k: int(v) for k, v in (f.split('=') for f in line.split(' label=')[0].split())}
            label = line.split(' label=', 1)[1]
            what = line
            rects = {name: (r[name + '_x'], r[name + '_y'], r[name + '_w'], r[name + '_h'])
                     for name in ('send', 'mode', 'menu')}
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
        self.assertTrue(at[13, 380].endswith(' label=Edit automatically'), at[13, 380])
        self.assertGreater(cut, 0)                                   # a large font in a narrow panel cuts it


class SeamWordsTest(unittest.TestCase):
    """Nothing above the seam knows Claude (decision 2): phase 1's names stay where phase 1 put them."""

    FILES = ['agent_drv.s', 'agents.s', 'agentext.s', 'agentcfg.s', 'agentpop.s', 'agentcard.s',
             'agentcompose.s', 'agentfoot.s', 'mdtab.s']
    # file -> name -> the functions it may appear in
    ALLOWED = {
        'agent_drv.s': {
            'AG_CLAUDE': {'agent_drv_apply', 'agent_drv_for_kind', 'agent_new'},
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
    }
    WORD = re.compile(r'[.\w]*(?:claude|Claude|AG_CLAUDE)[.\w]*')
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
                    if re.search(r'claude|Claude', text) and last_string not in strings | set(allowed):
                        found.append(f'{name}:{number} string {last_string}: {raw.strip()}')
                    continue
                for word in self.WORD.findall(line):
                    if function not in allowed.get(word, ()):
                        found.append(f'{name}:{number} {word} in {function}')
        self.assertEqual(found, [])


if __name__ == '__main__':
    unittest.main()
