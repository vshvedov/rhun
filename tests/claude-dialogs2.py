#!/usr/bin/env python3
"""The agents panel's dialogs that change Claude Code's configuration (phase 7, claude-chat-p7b): MCP servers,
Hooks, Permission rules, Sandbox, Manage Plugins, and the shell's form rows, against the fake CLI
(tests/scripts/fake-claude.py with tests/scripts/fake_claude_config.py), over the control socket. Every rhun
gets its own HOME and XDG folders (tests/claude-chat.py's cases), so whatever the dialogs write goes to the
fake's files under the test's folder: the test's HOME/.claude.json, HOME/.claude/settings.json, the project's
.claude/ and .mcp.json, HOME/.claude/plugins/fake-plugins.json. The tests check that what is written is
exactly what the dialog showed, that removing asks first, that secrets typed or reported never show in a
dump, and that text from the CLI is cleaned."""
import importlib.util
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location('claude_chat', ROOT / 'tests/claude-chat.py')
chat = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(chat)


class Case(chat.DrivenCase):
    """A configuration dialog over the panel, and what the fake wrote."""

    def head(self):
        first = self.command('print-agent-dialog').splitlines()[0]
        return dict(re.findall(r'(\w+)=(.*?)(?= \w+=|$)', first))

    def body(self):
        return [line for line in self.command('print-agent-dialog').splitlines()[1:] if not line.startswith('box ')]

    def keys(self, *names):
        for name in names:
            self.command('key ' + name)

    def control(self, subtype=None):
        """The control requests the fake read (not the subcommands' stdin, which the log keeps too)."""
        lines = [json.loads(r['stdin']) for r in self.records() if 'stdin' in r and 'sub' not in r]
        return [m['request'] for m in lines if m.get('type') == 'control_request'
                and (subtype is None or m['request'].get('subtype') == subtype)]

    def subs(self):
        """The configuration subcommands the fake ran: (argv, stdin)."""
        return [(r['sub'], r.get('stdin', '')) for r in self.records() if 'sub' in r]

    def until_body(self, check, what, seconds=10):
        return self.until(lambda: check(self.body()) and self.body(), what, seconds)

    def until_line(self, line, seconds=10):
        return self.until_body(lambda body: line in body, line, seconds)

    def until_ready(self, seconds=10):
        return self.until(lambda: self.head().get('state') == 'ready' and not self.busy() and self.head(),
                          'ready', seconds)

    def busy(self):
        return any(line.startswith('button ') and line.endswith('…') or '… primary' in line
                   for line in self.body())

    def item(self, text):
        """The focus index of the first focusable row whose line holds text."""
        for line in self.body():
            m = re.match(r'\w+\[(\d+)\] (.*)', line)
            if m and text in m.group(2):
                return int(m.group(1))
        self.fail('no row with %r in %r' % (text, self.body()))

    def pick(self, text):
        self.command('agent-dialog-pick %d' % self.item(text))

    def press(self, label):
        for line in self.body():
            m = re.match(r'button (\d+) (.*?)( primary)?$', line)
            if m and m.group(2) == label:
                self.command('agent-dialog-press ' + m.group(1))
                return
        self.fail('no button %r in %r' % (label, self.body()))

    def field(self, n, text):
        self.command('agent-dialog-field %d %s' % (n, text.replace('\n', '\\n')))

    def panel(self):
        self.start()
        self.command('cmd focus_agents')
        self.command('agent-new claude')

    def open(self, name):
        self.command('agent-dialog ' + name)

    def claude_json(self):
        path = self.work / '.claude.json'
        return json.loads(path.read_text()) if path.exists() else {}

    def settings(self, which):
        path = {'user': self.work / '.claude/settings.json',
                'project': self.project / '.claude/settings.json',
                'local': self.project / '.claude/settings.local.json'}[which]
        return json.loads(path.read_text()) if path.exists() else {}

    def write_json(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value), encoding='utf-8')


class McpTest(Case):
    """6.1, 6.2, 6.3: the servers by scope with their badges, a server's page and its actions by state, the Add
    MCP server form; mcp_status's secrets never shown."""

    def seed(self):
        self.write_json(self.work / '.claude.json', {
            'mcpServers': {'tokens': {'type': 'http', 'url': 'https://api.example.invalid/mcp',
                                      'headers': {'Authorization': 'Bearer s3cr3t-header'}},
                           'needs-auth-srv': {'type': 'http', 'url': 'https://auth.example.invalid/mcp'}},
            'projects': {str(self.project): {'mcpServers': {
                'local-fail': {'type': 'stdio', 'command': 'false', 'env': {'KEY': 's3cr3t-env'}}}}}})
        self.write_json(self.project / '.mcp.json', {'mcpServers': {'shared': {'type': 'stdio', 'command': 'srv'}}})

    def test_list_by_scope(self):
        self.seed()
        self.panel()
        self.open('mcp')
        self.until_ready()
        head = self.head()
        self.assertEqual((head['dialog'], head['title']), ('mcp', 'MCP servers'))
        body = self.body()
        self.assertEqual([l for l in body if l.startswith('head')],
                         ['head Project (1)', 'head Local (1)', 'head User (2)'])
        self.assertIn('item[2] shared\t\t✓ Connected', body)
        self.assertIn('item[3] local-fail\t\t✗ Failed', body)
        self.assertIn('item[5] tokens\t\t✓ Connected', body)
        self.assertIn('item[4] needs-auth-srv\t\t⚠ Needs Auth', body)
        self.assertNotIn('claude-vscode', '\n'.join(body))
        self.assertIn('link[6] Learn more about MCP', body)
        self.assertEqual(body[-1], 'button 1 Add server primary')
        dump = self.command('print-agent-dialog')
        self.assertNotIn('s3cr3t', dump)
        self.command('agent-dialog-filter tok')
        self.assertEqual([l.split('\t')[0] for l in self.body() if l.startswith('item')], ['item[2] tokens'])

    def test_detail_disable_enable_and_tools(self):
        self.seed()
        self.panel()
        self.open('mcp')
        self.until_ready()
        self.pick('tokens')
        body = self.body()
        self.assertEqual(self.head()['back'], '1')
        self.assertIn('head tokens hint ✓ Connected', body)
        self.assertEqual([l for l in body if l.startswith('button')],
                         ['button 1 Reconnect', 'button 2 Clear authentication', 'button 3 Disable',
                          'button 4 Remove'])
        self.pick('View tools (2)')
        body = self.body()
        self.assertIn('item[2] echo\t\tread-only', body)
        self.assertIn('item[3] wipe\t\tdestructive', body)
        self.press('Disable')
        self.until_line('text Disabled tokens')
        self.assertEqual(self.control('mcp_toggle'), [{'subtype': 'mcp_toggle', 'serverName': 'tokens',
                                                       'enabled': False}])
        self.until_body(lambda b: 'item[5] tokens\t\t○ Disabled' in b, 'disabled in the list')
        self.pick('tokens')
        self.assertIn('button 1 Enable primary', self.body())
        self.press('Enable')
        self.until_line('text Enabled tokens')
        self.assertNotIn('s3cr3t', self.command('print-agent-dialog'))

    def test_failed_server_error_and_reconnect(self):
        self.seed()
        self.panel()
        self.open('mcp')
        self.until_ready()
        self.pick('local-fail')
        body = self.body()
        self.assertIn('text Bad gateway: the server said no error', body)    # tags out, its first line
        self.assertEqual([l for l in body if l.startswith('button')],
                         ['button 1 Reconnect', 'button 2 Disable', 'button 3 Remove'])
        self.press('Reconnect')
        self.until_line('text Connection closed error')

    def test_remove_confirms_first(self):
        self.seed()
        self.panel()
        self.open('mcp')
        self.until_ready()
        self.pick('shared')
        self.press('Remove')
        body = self.body()
        self.assertIn('text Remove shared from project config?', body)
        self.assertEqual(body[-2:], ['button 1 Confirm remove primary', 'button 2 Cancel'])
        self.assertEqual(self.subs(), [])
        self.keys('Return')                         # the focus is on Cancel: nothing removed
        self.assertIn('button 3 Remove', self.body())
        self.assertEqual(self.subs(), [])
        self.press('Remove')
        self.press('Confirm remove')
        self.until_line('text Removed shared from project config. Running sessions keep it until restarted.')
        self.assertEqual(self.subs()[-1][0], ['mcp', 'remove', '--scope', 'project', '--', 'shared'])
        self.assertEqual(json.loads((self.project / '.mcp.json').read_text())['mcpServers'], {})

    def test_authenticate_asks_before_the_page_opens(self):
        self.seed()
        self.panel()
        self.open('mcp')
        self.until_ready()
        self.pick('needs-auth-srv')
        self.assertEqual([l for l in self.body() if l.startswith('button')],
                         ['button 1 Authenticate primary', 'button 2 Disable', 'button 3 Remove'])
        self.press('Authenticate')
        body = self.until_line('text Completing authentication in browser…')
        self.assertIn('link[2] Re-open authentication page', body)
        self.assertEqual(self.command('print-palette').splitlines()[0],       # asked, not opened
                         'choose=Claude Code wants to open auth.example.invalid in your browser: '
                         'https://auth.example.invalid/authorize?state=s1')
        self.keys('Escape')
        self.field(1, 'http://localhost:1234/callback?code=c1&state=s1')
        self.press('Submit')
        self.until_body(lambda b: 'head needs-auth-srv hint ✓ Connected' in b, 'connected')
        self.assertEqual(self.control('mcp_oauth_callback_url')[-1]['callbackUrl'],
                         'http://localhost:1234/callback?code=c1&state=s1')

    def test_add_form_checks_and_writes_exactly(self):
        self.panel()
        self.open('mcp')
        self.until_ready()
        self.assertIn('text No MCP servers configured.', self.body())
        self.press('Add server')
        body = self.body()
        self.assertEqual(self.head()['back'], '1')
        self.assertEqual(body[:6], ['head Add MCP server', 'field[1] Name\t\t', 'head Transport',
                                    'option[2] Local command (stdio)\tRuns a command on your machine on',
                                    'option[3] HTTP (remote)\tConnects to a server by URL off',
                                    'option[4] SSE (remote, legacy)\tOlder remote protocol; prefer HTTP off'])
        self.press('Add server')                    # nothing filled: the extension's words
        self.assertIn('text Server name is required. error', self.body())
        self.field(1, 'bad name')
        self.press('Add server')
        self.assertIn('text Invalid name bad name. Names can only contain letters, numbers, hyphens, and '
                      'underscores. error', self.body())
        self.field(1, 'my-tools')
        self.press('Add server')
        self.assertIn('text Command is required. error', self.body())
        self.field(2, 'npx')
        self.field(3, '-y\n  pkg  \n\n')
        self.field(4, 'API_KEY=abc123\nnot a pair')
        self.press('Add server')
        self.assertIn('text Environment variables must be KEY=value (line 2). error', self.body())
        self.field(4, ' API_KEY = abc123 \n')
        dump = self.command('print-agent-dialog')
        self.assertIn('field[7] Environment variables (KEY=value, one per line)\t API_KEY =***\\n\t multi', dump)
        self.assertNotIn('abc123', dump)
        self.pick('User')                           # the scope: user
        self.press('Add server')
        self.until_line('text Added my-tools to user config. It will be available in new sessions.')
        self.assertEqual(self.subs()[-1][0], ['mcp', 'add', '--scope', 'user', '--transport', 'stdio', '--env',
                                              'API_KEY=abc123', '--', 'my-tools', 'npx', '-y', 'pkg'])
        self.assertEqual(self.claude_json()['mcpServers']['my-tools'],
                         {'type': 'stdio', 'command': 'npx', 'args': ['-y', 'pkg'], 'env': {'API_KEY': 'abc123'}})

    def test_add_http_with_headers_and_a_redacted_error(self):
        self.panel()
        self.open('mcp')
        self.until_ready()
        self.press('Add server')
        self.pick('HTTP (remote)')
        body = self.body()
        self.assertIn('field[5] URL\t\t', body)
        self.field(1, 'echo-secret')
        self.field(2, 'https://x.example.invalid/mcp')
        self.field(3, 'Authorization: Bearer topsecret\nX-Other: zz')
        self.pick('Project')
        self.assertIn('text Saved to .mcp.json and shared with everyone who opens this project. In IDE sessions, '
                      'project servers connect without a separate approval step. If no folder is open, this writes '
                      'to your home directory.', self.body())
        self.press('Add server')
        body = self.until_body(lambda b: any(l.endswith(' error') for l in b), 'an error')
        error = [l for l in body if l.endswith(' error')][0]
        self.assertIn('<redacted>', error)
        self.assertNotIn('topsecret', '\n'.join(body))
        self.assertEqual(self.subs()[-1][0], ['mcp', 'add', '--scope', 'project', '--transport', 'http',
                                              '--header', 'Authorization: Bearer topsecret', '--header', 'X-Other: zz',
                                              '--', 'echo-secret', 'https://x.example.invalid/mcp'])

    def test_slash_command_and_menu_open_it(self):
        self.seed()
        self.panel()
        self.command('agent-type /mcp')
        self.keys('Return')
        self.until(lambda: self.head().get('dialog') == 'mcp', 'the /mcp dialog')
        self.command('agent-dialog-close')
        self.assertFalse([p for p in self.prompts() if p.startswith('/mcp')])     # not sent to Claude Code
        self.command('agent-menu')
        menu = self.command('print-agent-menu')
        for label in ('MCP servers', 'Hooks', 'Permissions', 'Sandbox', 'Manage plugins'):
            self.assertIn(label, menu)


class RulesTest(Case):
    """6.9: Allow / Ask / Deny with their sources, Add rule… with Save for, Remove rule asks first."""

    def test_list_add_remove(self):
        self.write_json(self.work / '.claude/settings.json', {'permissions': {'allow': ['Bash(npm test *)'],
                                                                              'deny': ['WebFetch']}})
        self.panel()
        self.open('permissions')
        self.until_ready()
        body = self.body()
        self.assertEqual(self.head()['title'], 'Permission rules')
        self.assertIn('head Allow (1)', body)
        self.assertIn('item[2] Bash(npm test *)\tAny Bash command starting with npm test\tFrom user settings', body)
        self.assertIn('head Ask (0)', body)
        self.assertIn('item[5] WebFetch\t\tFrom user settings', body)
        self.assertIn('head Workspace (1)', body)
        self.pick('Bash(npm test *)')
        body = self.body()
        self.assertEqual(body[:2], ['head Remove allow rule?', 'text Bash(npm test *)'])
        self.assertEqual(body[-2:], ['button 1 Remove rule primary', 'button 2 Cancel'])
        self.press('Remove rule')
        self.until_body(lambda b: 'head Allow (0)' in b, 'removed')
        self.assertEqual(self.subs()[-1], (['edit-permission-rules', '--json'], json.dumps(
            {'op': 'remove', 'rule': 'Bash(npm test *)', 'behavior': 'allow', 'source': 'userSettings'},
            separators=(',', ':'))))
        self.assertEqual(self.settings('user')['permissions']['allow'], [])
        self.pick('Add rule…')                 # Allow's
        body = self.body()
        self.assertEqual(body[0], 'head Add allow rule')
        self.assertIn('option[2] this project (just you)\tSaves to .claude/settings.local.json (gitignored) on', body)
        self.field(1, 'Bash(ls *)')
        self.pick('this project (shared)')
        self.press('Add rule')
        self.until_body(lambda b: 'head Allow (1)' in b, 'added')
        self.assertEqual(json.loads(self.subs()[-1][1]),
                         {'op': 'add', 'rules': ['Bash(ls *)'], 'behavior': 'allow',
                          'destination': 'projectSettings'})
        self.assertEqual(self.settings('project')['permissions']['allow'], ['Bash(ls *)'])

    def test_a_bad_rule_says_why(self):
        self.panel()
        self.open('permissions')
        self.until_ready()
        self.assertIn('text No permission rules are saved.', self.body())
        self.pick('Add rule…')
        self.field(1, 'Bash((')
        self.press('Add rule')
        body = self.until_body(lambda b: any(l.startswith('text Couldn’t add the rule:') for l in b), 'error')
        self.assertTrue(any('Malformed Tool(content) rule' in l for l in body))


class SandboxTest(Case):
    """6.10: Mode, Overrides, Excluded commands, Restrictions; /sandbox exclude PATTERN."""

    def test_modes_fallback_and_exclude(self):
        self.panel()
        self.open('sandbox')
        self.until_ready()
        body = self.body()
        self.assertEqual(self.head()['title'], 'Sandbox')
        self.assertIn('option[3] No sandbox\tCommands run outside the sandbox on', body)
        self.assertIn('toggle Allow unsandboxed fallback on', body)   # no focus: the sandbox is off in the settings
        self.assertIn('pair Allowed domains\texample.com, example.org', body)
        self.pick('Sandbox commands, with regular permissions')
        self.until_body(lambda b: 'option[2] Sandbox commands, with regular permissions\tCommands run inside the '
                        'sandbox; the usual permission prompts apply on' in b, 'regular')
        self.assertEqual(json.loads(self.subs()[-1][1]), {'mode': 'regular'})
        self.assertEqual(self.settings('local')['sandbox']['enabled'], True)
        self.pick('Allow unsandboxed fallback')
        self.until_body(lambda b: any(l.startswith('toggle[4] Allow unsandboxed fallback off') for l in b), 'off')
        self.assertEqual(json.loads(self.subs()[-1][1]), {'allowUnsandboxedCommands': False})
        self.field(1, 'npm run test:*')
        self.press('Exclude')
        self.until_line('text npm run test:*')
        self.assertEqual(json.loads(self.subs()[-1][1]), {'excludeCommand': 'npm run test:*'})

    def test_slash_sandbox_exclude(self):
        self.panel()
        self.command('agent-dialog sandbox exclude make check')
        self.until_line('text Added "make check" to the excluded commands')
        self.assertEqual(self.settings('local')['sandbox']['excludedCommands'], ['make check'])


class HooksTest(Case):
    """6.7, 6.8: the hooks by event and matcher, the editor's fields per type, Save to, Remove asks first."""

    def test_list_edit_and_remove(self):
        self.write_json(self.project / '.claude/settings.local.json', {'hooks': {'PreToolUse': [
            {'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': 'echo hi', 'timeout': 5, 'extra': 1}]}]}})
        self.panel()
        self.open('hooks')
        self.until_ready()
        body = self.body()
        self.assertIn('head PreToolUse hint 1 hook', body)
        self.assertIn('text Matcher: Bash', body)
        self.assertIn('item[1] echo hi\tcommand\tLocal', body)
        self.assertEqual(body[-1], 'button 1 Add hook primary')
        self.pick('echo hi')
        body = self.body()
        self.assertEqual(body[0], 'head Edit hook')
        self.assertIn('field[2] Matcher (leave empty to match everything)\tBash\t', body)
        cmd = [l for l in body if l.startswith('field') and '] Command\t' in l][0]
        self.assertEqual(cmd.split('\t')[1:], ['echo hi', ' multi'])
        timeout = [l for l in body if 'Timeout in seconds' in l][0]
        self.assertEqual(timeout.split('\t')[1], '5')
        fields = [l for l in body if l.startswith('field')]
        self.field(fields.index(cmd) + 1, 'echo bye')
        self.press('Save hook')
        self.until_body(lambda b: 'item[1] echo bye\tcommand\tLocal' in b, 'saved')
        edit = json.loads(self.subs()[-1][1])
        self.assertEqual(edit['op'], 'replace')
        self.assertEqual(edit['target'], {'event': 'PreToolUse', 'matcher': 'Bash',
                                          'hook': {'type': 'command', 'command': 'echo hi', 'timeout': 5, 'extra': 1}})
        self.assertEqual(edit['hook'], {'extra': 1, 'type': 'command', 'command': 'echo bye', 'timeout': 5})
        self.assertEqual(self.settings('local')['hooks']['PreToolUse'][0]['hooks'],
                         [{'extra': 1, 'type': 'command', 'command': 'echo bye', 'timeout': 5}])
        self.pick('echo bye')
        self.press('Remove')
        body = self.body()
        self.assertIn('text Remove this hook from local settings?', body)
        self.press('Confirm remove')
        self.until_line('text No hooks configured')
        self.assertNotIn('hooks', self.settings('local'))

    def test_add_checks_fields(self):
        self.panel()
        self.open('hooks')
        self.until_ready()
        self.press('Add hook')
        body = self.body()
        self.assertEqual(body[:2], ['head Add hook', 'head Save to'])
        self.assertIn('item[4] Event: PreToolUse\tBefore tool execution\t', body)
        self.pick('Event: PreToolUse')              # the events picker
        self.pick('Stop')
        body = self.body()
        self.assertIn('item[4] Event: Stop\tRight before Claude concludes its response\t', body)
        self.assertFalse([l for l in body if 'Matcher (leave empty' in l])    # Stop takes no matcher
        self.pick('HTTP')
        self.press('Add hook')
        self.assertIn('text URL is required. error', self.body())
        fields = [l for l in self.body() if l.startswith('field')]
        url = [i for i, l in enumerate(fields) if '] URL\t' in l][0]
        timeout = [i for i, l in enumerate(fields) if 'Timeout in seconds' in l][0]
        headers = [i for i, l in enumerate(fields) if '] Headers (' in l][0]
        self.field(url + 1, 'https://hooks.example.invalid/x')
        self.field(timeout + 1, 'soon')
        self.press('Add hook')
        self.assertIn('text Timeout in seconds must be a number above 0. error', self.body())
        self.field(timeout + 1, '07')
        self.field(headers + 1, 'X-Key: k1')
        self.pick('User')
        self.press('Add hook')
        self.until_body(lambda b: 'head Stop hint 1 hook' in b, 'added')
        self.assertEqual(json.loads(self.subs()[-1][1]), {
            'op': 'add', 'source': 'userSettings', 'event': 'Stop', 'matcher': '',
            'hook': {'type': 'http', 'url': 'https://hooks.example.invalid/x', 'headers': {'X-Key': 'k1'},
                     'timeout': 7}})
        self.assertNotIn('k1', self.command('print-agent-dialog'))

    def test_a_refusal_offers_the_settings_file(self):
        """edit-hook's {"refusal":{"code","file"}} (README finding 83): the extension's words, Open settings file
        opens that file in a tab, Copy error copies what edit-hook said."""
        local = self.project / '.claude/settings.local.json'
        self.write_json(local, {'hooks': {'Stop': {'not': 'a list'}}})
        self.panel()
        self.open('hooks')
        self.until_ready()
        self.press('Add hook')
        self.pick('Event: PreToolUse')
        self.pick('Stop')
        fields = [l for l in self.body() if l.startswith('field')]
        cmd = [i for i, l in enumerate(fields) if '] Command\t' in l][0]
        self.field(cmd + 1, 'echo done')
        self.press('Add hook')
        body = self.until_body(lambda b: any(l.endswith(' error') for l in b), 'the refusal')
        self.assertIn('text The Stop entry in the local settings file is not a list, so the hook could not be saved. '
                      'error', body)
        links = [l for l in body if l.startswith('link[')]
        self.assertEqual([l.split('] ')[1] for l in links], ['Open settings file', 'Copy error'])
        self.pick('Copy error')
        self.assertEqual(self.command('print-toast').strip(), 'toast=Copied to clipboard')
        self.pick('Open settings file')
        self.assertIn('settings.local.json', self.command('print-tabs'))
        body = self.body()
        self.assertFalse([l for l in body if l.endswith(' error') or l.startswith('link[') and 'settings file' in l])
        self.assertEqual(body[0], 'head Add hook')                  # the dialog stays, on the form
        self.assertEqual(json.loads(local.read_text()), {'hooks': {'Stop': {'not': 'a list'}}})

    def test_an_unloadable_file_and_twins(self):
        local = self.project / '.claude/settings.local.json'
        twin = {'type': 'command', 'command': 'echo twin'}
        self.write_json(local, {'hooks': {'Stop': [{'hooks': [twin, dict(twin)]}]}})
        self.panel()
        self.open('hooks')
        self.until_ready()
        self.pick('echo twin')
        self.press('Remove')
        self.press('Confirm remove')
        body = self.until_body(lambda b: any(l.endswith(' error') for l in b), 'the refusal')
        self.assertIn('text More than one identical hook is in the local settings file, so the dialog cannot tell '
                      'which one to change. error', body)
        self.assertIn('Open settings file', '\n'.join(body))
        local.write_text('{"hooks": [', encoding='utf-8')     # broken since the listing was read
        self.press('Save hook')
        body = self.until_body(lambda b: any('could not be loaded' in l for l in b), 'the second refusal')
        self.assertIn('text The local settings file could not be loaded, so the hook could not be saved. error', body)
        self.pick('Open settings file')
        self.assertIn('settings.local.json', self.command('print-tabs'))


class PluginsTest(Case):
    """6.4, 6.5, 6.6, 4.19: the tabs, Installed and Available, install by scope, the options form, uninstall that
    asks, the marketplaces, a link's plugin and its trust question."""

    def test_install_configure_uninstall(self):
        self.panel()
        self.open('plugins')
        self.until(lambda: any(l.startswith('head Available') for l in self.body()), 'available')
        body = self.body()
        self.assertEqual(self.head()['title'], 'Manage Plugins')
        self.assertEqual(body[0], 'tabs[2] Plugins|Marketplaces 1 shown=0')
        avail = [l for l in body if l.startswith('item')]
        self.assertEqual([l.split('\t')[0].split('] ')[1] for l in avail], ['doc-writer', 'lint-helper', 'broken'])
        self.assertIn('Lints what you write', '\n'.join(body))      # the bidi mark left out
        self.assertNotIn('‮', '\n'.join(body))
        self.pick('doc-writer')
        body = self.body()
        self.assertEqual(body[0], 'head Install doc-writer')
        self.assertIn('option[1] Install for you\tAvailable in all your projects off', body)
        self.pick('Install for this project')
        self.until(lambda: self.head().get('title') == 'Manage Plugins' and
                   any(l.startswith('head Installed') for l in self.body()), 'installed')
        self.assertIn(['plugin', 'install', '--scope', 'project', '--json', '--', 'doc-writer@fake-market'],
                      [s[0] for s in self.subs()])
        self.pick('doc-writer')
        body = self.body()
        self.assertEqual([l for l in body if l.startswith('button')],
                         ['button 1 Disable primary', 'button 2 Configure options', 'button 3 Update',
                          'button 4 Uninstall'])
        self.press('Configure options')
        body = self.until_body(lambda b: b and b[0] == 'head Configure doc-writer', 'the options')
        self.assertIn('field[1] API key *\t\tYour key for the service secret', body)
        self.field(1, 'k-123')
        self.assertIn('field[1] API key *\t*****\tYour key for the service secret', self.body())
        self.field(2, 'mars')
        self.press('Save configuration')
        body = self.until_body(lambda b: any('Region must be eu or us' in l for l in b), 'refused')
        self.field(2, 'eu')
        self.press('Save configuration')
        self.until(lambda: any(l.startswith('tabs[') for l in self.body()), 'saved')
        saved = [s for s in self.subs() if '--values-stdin' in s[0]][-1]
        self.assertEqual(json.loads(saved[1]), {'apiKey': 'k-123', 'region': 'eu', 'level': 'low'})
        self.assertNotIn('k-123', self.command('print-agent-dialog'))
        body = self.until_body(lambda b: any(l.startswith('tabs[') for l in b), 'saved')
        self.assertEqual(body[:2], ['text Restart Claude to apply plugin changes', 'link[2] Restart'])
        self.pick('doc-writer')
        self.until(lambda: self.body()[0].startswith('head doc-writer'), 'its page')
        self.press('Uninstall')
        body = self.body()
        self.assertEqual(body[0], 'head Uninstall doc-writer (project scope)?')
        self.assertEqual(self.head()['focus'], str(len([l for l in body if l.startswith('button')])))
        self.press('Keep')
        self.until(lambda: any(l.startswith('tabs[') for l in self.body()) and
                   not any(l.startswith('head Installed') for l in self.body()), 'uninstalled')
        self.assertIn(['plugin', 'uninstall', '--scope', 'project', '--keep-data', '--json', '--',
                       'doc-writer@fake-market'], [s[0] for s in self.subs()])

    def test_a_failed_reload_offers_try_again(self):
        """reload_plugins that counts an error: the restart notice with the extension's Reload plugins words; Try
        again asks once more, and a reload that works takes the notice away."""
        self.env['FAKE_CLAUDE_RELOAD_FAIL'] = '1'
        self.panel()
        self.open('mcp')                            # the conversation's process up (started quietly)
        self.until_ready()
        self.command('agent-dialog-close')
        self.open('plugins')
        self.until(lambda: any(l.startswith('head Available') for l in self.body()), 'available')
        self.pick('lint-helper')
        self.pick('Install for you')
        body = self.until_body(lambda b: "text This session couldn't reload its plugins. error" in b, 'the failure')
        self.assertEqual(body[:4], ['text Restart Claude to apply plugin changes',
                                    "text This session couldn't reload its plugins. error",
                                    'link[2] Try again', 'link[3] Restart'])
        self.assertEqual(len(self.control('reload_plugins')), 1)
        body = self.until_body(lambda b: any(l.startswith('head Installed') for l in b), 'the lists read again')
        self.assertFalse([l for l in body if l.startswith('item[') and 'lint-helper\tfrom' in l])
        self.pick('Try again')
        self.until(lambda: len(self.control('reload_plugins')) == 2, 'asked again')
        self.until_body(lambda b: not any('Restart' in l for l in b), 'the notice gone')

    def test_thousands_available(self):
        """The official directory lists thousands, as indented JSON over many lines: all of them, each read once."""
        self.env['FAKE_CLAUDE_PLUGINS_MANY'] = '4000'
        self.panel()
        self.open('plugins')
        self.until(lambda: any(l.startswith('head Available') for l in self.body()), 'available', 20)
        items = [l for l in self.body() if l.startswith('item[')]
        self.assertEqual(len(items), 4003)
        self.assertEqual(items[-1].split('] ', 1)[1], 'many-3999\tfrom directory \u00b7 One of many\t')
        self.command('type many-3998')              # the filter
        self.assertEqual([l.split('] ', 1)[1].split('\t')[0] for l in self.body() if l.startswith('item[')],
                         ['many-3998'])

    def test_a_failed_install_says_why(self):
        self.panel()
        self.open('plugins')
        self.until(lambda: any(l.startswith('head Available') for l in self.body()), 'available')
        self.pick('broken')
        self.pick('Install for you')
        self.until_body(lambda b: any("This plugin's dependencies can't be installed." in l for l in b), 'error')

    def test_marketplaces(self):
        self.panel()
        self.open('plugins')
        self.until(lambda: any(l.startswith('tabs[') for l in self.body()), 'tabs')
        self.pick('Marketplaces')                   # the tabs row: Enter shows the next
        self.until(lambda: self.head().get('state') == 'ready' and 'shown=1' in self.body()[0], 'marketplaces')
        body = self.body()
        self.assertIn('field[2] \t\t', body)
        self.assertIn('item[3] fake-market\tfake/market\t', body)
        self.field(1, 'someone/more-plugins')
        self.press('Add')
        self.until_body(lambda b: 'item[4] more-plugins\tsomeone/more-plugins\t' in b, 'added')
        self.assertIn(['plugin', 'marketplace', 'add', '--json', '--', 'someone/more-plugins'],
                      [s[0] for s in self.subs()])
        self.pick('more-plugins')
        self.until(lambda: self.body()[0] == 'head more-plugins', 'its page')
        self.press('Remove marketplace')
        self.assertEqual(self.body()[0], 'text Remove marketplace more-plugins?')
        self.press('Remove marketplace')
        self.until_body(lambda b: 'text Removed marketplace more-plugins' in b and
                        not [l for l in b if l.startswith('item') and 'more-plugins' in l], 'removed')

    def test_link_asks_to_trust_a_new_marketplace(self):
        self.panel()
        self.command('agent-plugin-link linked-tool someone/link-market')
        body = self.until_body(lambda b: 'text Installing plugin' in b, 'the trust question')
        self.assertEqual(body[:5], ['text Installing plugin', 'text linked-tool',
                                    'text requires adding a new marketplace source:', 'text someone/link-market',
                                    'text Plugins from this source can run code on your computer, with access to your '
                                    'files and shell. Only continue if you trust it.'])
        self.assertNotIn(['plugin', 'marketplace', 'add', '--from-link', '--', 'someone/link-market'],
                         [s[0] for s in self.subs()])
        self.press('Trust marketplace and continue')
        self.until_body(lambda b: b and b[0] == 'head Install linked-tool', 'its install page')
        self.assertIn(['plugin', 'marketplace', 'add', '--from-link', '--', 'someone/link-market'],
                      [s[0] for s in self.subs()])


class ShellFormTest(Case):
    """The shell's form rows by keyboard alone, and every page's layout at panel sizes 8, 13, 32 and widths 240 to
    900."""

    def test_keys_in_fields_options_and_tabs(self):
        self.panel()
        self.open('mcp')
        self.until_ready()
        self.press('Add server')
        self.assertEqual(self.head()['focus'], '1')      # the Name field
        self.command('type my-srv')
        self.assertIn('field[1] Name\tmy-srv\t', self.body())
        self.keys('Down', 'Down')                   # Down leaves a one-line field: the HTTP option
        self.keys('space')
        self.assertIn('option[3] HTTP (remote)\tConnects to a server by URL on', self.body())
        self.keys('Tab', 'Tab')                     # the URL field
        self.command('type https://a.example.invalid')
        self.keys('Tab')                            # the headers: Enter is a new line there
        self.command('type A: 1')
        self.keys('Return')
        self.command('type B: 2')
        line = [l for l in self.body() if '] Headers (' in l][0]
        self.assertEqual(line.split('\t')[1], 'A:***\\nB:***')
        self.keys('Escape')                         # back to the list
        self.assertEqual(self.head()['back'], '0')

    def test_fit_at_every_size(self):
        self.panel()
        for name in ('mcp', 'permissions', 'sandbox', 'hooks', 'plugins'):
            self.open(name)
            self.until(lambda: self.head().get('state') == 'ready', name)
            fit = self.command('print-agent-dialog fit').splitlines()
            self.assertEqual(len(fit), 36, name)
            for line in fit:
                self.assertTrue(line.endswith(' in=1'), (name, line))
            self.command('agent-dialog-close')


if __name__ == '__main__':
    unittest.main()
