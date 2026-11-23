#!/usr/bin/env python3
"""Claude Code's controls in the agents panel (phase 2: settings, the per-project lists, the composer,
menus, modes, models, notices, queueing), against the fake CLI (tests/scripts/fake-claude.py), over the
control socket. It imports tests/claude-chat.py for its cases: every rhun gets its own HOME and XDG
folders, an environment without CLAUDE* or ANTHROPIC* variables, and a config whose [claude] section
starts the fake. Nothing here writes the user's own Claude Code settings: the fake's config folder is the
test's HOME."""
import importlib.util
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
