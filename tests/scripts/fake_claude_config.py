"""The fake Claude Code's configuration (claude-chat-p7b), for tests/scripts/fake-claude.py: the subcommands that
change it (`mcp add|remove`, `edit-hook --json`, `edit-permission-rules --json`, `edit-sandbox-settings --json`,
`plugin ...`) and the control requests that read or toggle it (mcp_status, mcp_toggle, mcp_reconnect,
mcp_clear_auth, mcp_authenticate, mcp_oauth_callback_url, get_hooks_listing, list_permission_rules,
get_sandbox_dialog, reload_plugins), with the shapes the real 2.1.330 printed (tests/data/claude-shapes/README.txt
findings 80 to 88).

Where it keeps things, as the real CLI does: MCP servers in <claude.json> (CLAUDE_CONFIG_DIR/.claude.json, else
$HOME/.claude.json; user scope: mcpServers, local: projects[cwd].mcpServers, disabled ones:
projects[cwd].disabledMcpServers) and <cwd>/.mcp.json (project scope); hooks, permission rules and the sandbox in
the settings files (<config>/settings.json, <cwd>/.claude/settings.json, <cwd>/.claude/settings.local.json; the
sandbox in the local one); plugins and marketplaces in <config>/plugins/fake-plugins.json (seeded on first use:
one marketplace "fake-market" with lint-helper, doc-writer (it has options) and broken (its install fails);
a link's "link-market" adds linked-tool). Every subcommand is logged ({"sub": ARGS, "stdin": TEXT, "cwd"}); every
control request is in the stream log already.

Server names pick their state in mcp_status: one with "fail" in it failed (its error has a tag and a second line),
"auth" needs authentication (until mcp_oauth_callback_url), anything else is connected with two tools (echo,
read-only; wipe, destructive). FAKE_CLAUDE_MCP_SLOW (ms) delays mcp_status."""
import json
import os
import re
import sys
import time

CONFIG_SUBS = ('mcp', 'plugin', 'plugins', 'edit-hook', 'edit-permission-rules', 'edit-sandbox-settings')
CONTROL = {'mcp_status', 'mcp_toggle', 'mcp_reconnect', 'mcp_clear_auth', 'mcp_authenticate',
           'mcp_oauth_callback_url', 'get_hooks_listing', 'list_permission_rules', 'get_sandbox_dialog',
           'reload_plugins'}
SOURCE_LABEL = {'userSettings': 'User settings (~/.claude/settings.json)',
                'projectSettings': 'Project settings (.claude/settings.json)',
                'localSettings': 'Local settings (.claude/settings.local.json)'}
CATALOG = [{'name': 'PreToolUse', 'summary': 'Before tool execution', 'supportsMatcher': True},
           {'name': 'PostToolUse', 'summary': 'After tool execution', 'supportsMatcher': True},
           {'name': 'UserPromptSubmit', 'summary': 'When the user submits a prompt', 'supportsMatcher': False},
           {'name': 'Stop', 'summary': 'Right before Claude concludes its response', 'supportsMatcher': False},
           {'name': 'SessionStart', 'summary': 'When a new session is started', 'supportsMatcher': True}]
CONTENT_LABEL = {'command': 'Command', 'prompt': 'Prompt', 'agent': 'Prompt', 'http': 'URL', 'mcp_tool': 'MCP tool'}


def is_subcommand(args):
    return bool(args) and args[0] in CONFIG_SUBS


def handles(sub):
    return sub in CONTROL


# ---- files ----

def home():
    return os.environ.get('HOME', '')


def claude_json_path(config):
    return os.path.join(os.environ['CLAUDE_CONFIG_DIR'], '.claude.json') if os.environ.get('CLAUDE_CONFIG_DIR') \
        else os.path.join(home(), '.claude.json')


def read(path, default):
    try:
        with open(path, encoding='utf-8') as stream:
            value = json.load(stream)
        return value if isinstance(value, type(default)) else default
    except (OSError, ValueError):
        return default


def write(path, value):
    os.makedirs(os.path.dirname(path) or '.', exist_ok=True)
    with open(path + '.tmp', 'w', encoding='utf-8') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')
    os.replace(path + '.tmp', path)


def settings_path(source, cwd, config):
    return {'userSettings': os.path.join(config, 'settings.json'),
            'projectSettings': os.path.join(cwd, '.claude', 'settings.json'),
            'localSettings': os.path.join(cwd, '.claude', 'settings.local.json')}[source]


SOURCES = ('userSettings', 'projectSettings', 'localSettings')


# ---- MCP ----

def servers(cwd, config):
    """[(name, scope, config)] of every server, user then project then local."""
    data = read(claude_json_path(config), {})
    out = [(n, 'user', c) for n, c in (data.get('mcpServers') or {}).items()]
    out += [(n, 'project', c) for n, c in (read(os.path.join(cwd, '.mcp.json'), {}).get('mcpServers') or {}).items()]
    project = (data.get('projects') or {}).get(cwd) or {}
    out += [(n, 'local', c) for n, c in (project.get('mcpServers') or {}).items()]
    return out


def disabled(cwd, config):
    data = read(claude_json_path(config), {})
    return list(((data.get('projects') or {}).get(cwd) or {}).get('disabledMcpServers') or [])


def set_disabled(cwd, config, names):
    path = claude_json_path(config)
    data = read(path, {})
    data.setdefault('projects', {}).setdefault(cwd, {})['disabledMcpServers'] = names
    write(path, data)


AUTHED = set()                      # servers whose sign-in finished in this process
RELOADS = []                        # the reload_plugins requests of this process


def mcp_status(cwd, config):
    off = disabled(cwd, config)
    out = []
    for name, scope, conf in servers(cwd, config):
        entry = {'name': name, 'status': 'connected', 'config': conf, 'transport': conf.get('type', 'stdio'),
                 'scope': scope, 'source': scope}
        if name in off:
            entry['status'] = 'disabled'
        elif 'fail' in name:
            entry['status'] = 'failed'
            entry['error'] = '<b>Bad</b> gateway: the server said no\nsecond line'
        elif 'auth' in name and name not in AUTHED:
            entry['status'] = 'needs-auth'
        else:
            entry['tools'] = [{'name': 'echo', 'annotations': {'readOnly': True}},
                              {'name': 'wipe', 'annotations': {'destructive': True}}]
        out.append(entry)
    out.append({'name': 'claude-vscode', 'status': 'connected', 'config': {'type': 'sdk'}, 'scope': 'dynamic'})
    return {'mcpServers': out}


def mcp_sub(args):
    """`mcp add --scope S --transport T [--env K=V]... [--header H]... -- NAME CMD|URL ARGS...`, `mcp remove --scope S
    -- NAME`, as the extension calls them; the real CLI's words."""
    cwd, config = os.getcwd(), None
    verb = args[1] if len(args) > 1 else ''
    opts, rest, i = {'--env': [], '--header': []}, [], 2
    while i < len(args):
        if args[i] == '--':
            rest = args[i + 1:]
            break
        if args[i] in ('--env', '--header'):
            opts[args[i]].append(args[i + 1])
        else:
            opts[args[i]] = args[i + 1]
        i += 2
    scope = opts.get('--scope', 'local')
    if not rest:
        sys.stderr.write('error: missing server name\n')
        return 1
    name = rest[0]
    if not re.fullmatch(r'[A-Za-z0-9_-]+', name):
        sys.stderr.write('Invalid name %s. Names can only contain letters, numbers, hyphens, and underscores.\n' % name)
        return 1
    path = claude_json_path(config)
    data = read(path, {})
    project_path = os.path.join(cwd, '.mcp.json')
    if verb == 'add':
        transport = opts.get('--transport', 'stdio')
        if name == 'echo-secret':           # an error that repeats what was typed (the extension redacts it)
            sys.stderr.write('Error: could not start it with %s and %s\n'
                             % (' '.join(opts['--env']), ' '.join(opts['--header'])))
            return 1
        if transport == 'stdio':
            conf = {'type': 'stdio', 'command': rest[1] if len(rest) > 1 else '', 'args': rest[2:],
                    'env': dict(e.split('=', 1) for e in opts['--env'])}
        else:
            conf = {'type': transport, 'url': rest[1] if len(rest) > 1 else ''}
            if opts['--header']:
                conf['headers'] = {h.split(':', 1)[0].strip(): h.split(':', 1)[1].strip() for h in opts['--header']}
        if scope == 'user':
            table = data.setdefault('mcpServers', {})
        elif scope == 'local':
            table = data.setdefault('projects', {}).setdefault(cwd, {}).setdefault('mcpServers', {})
        else:
            project = read(project_path, {})
            table = project.setdefault('mcpServers', {})
        if name in table:
            sys.stderr.write('MCP server %s already exists in %s config\n' % (name, scope))
            return 1
        table[name] = conf
        if scope == 'project':
            write(project_path, project)
        else:
            write(path, data)
        if transport == 'stdio':
            print('Added stdio MCP server %s with command: %s to %s config'
                  % (name, ' '.join(rest[1:]), scope))
        else:
            print('Added %s MCP server %s with URL: %s to %s config'
                  % ({'http': 'HTTP', 'sse': 'SSE'}.get(transport, transport), name, conf['url'], scope))
        print('File modified: %s' % (project_path if scope == 'project' else path))
        return 0
    if verb == 'remove':
        if scope == 'user':
            table = data.get('mcpServers') or {}
        elif scope == 'local':
            table = ((data.get('projects') or {}).get(cwd) or {}).get('mcpServers') or {}
        else:
            project = read(project_path, {})
            table = project.get('mcpServers') or {}
        if name not in table:
            sys.stderr.write('No MCP server named "%s" in %s scope\n' % (name, scope))
            return 1
        del table[name]
        if scope == 'project':
            write(project_path, project)
        else:
            write(path, data)
        print('Removed MCP server %s from %s config' % (name, scope))
        return 0
    sys.stderr.write('error: unknown mcp command %s\n' % verb)
    return 1


# ---- hooks ----

def hooks_listing(cwd, config):
    hooks, counts = [], {}
    for source in SOURCES:
        settings = read(settings_path(source, cwd, config), {})
        for event, groups in (settings.get('hooks') or {}).items():
            for group in groups if isinstance(groups, list) else []:
                for hook in group.get('hooks') or []:
                    text = hook.get('command') or hook.get('prompt') or hook.get('url') or \
                        '%s/%s' % (hook.get('server'), hook.get('tool'))
                    row = {'event': event, 'matcher': group.get('matcher', ''), 'source': source,
                           'sourceLabel': SOURCE_LABEL[source], 'type': hook.get('type'),
                           'displayText': hook.get('statusMessage') or text, 'commandText': text,
                           'contentLabel': CONTENT_LABEL.get(hook.get('type'), 'Definition')}
                    for key in ('timeout', 'statusMessage'):
                        if key in hook:
                            row[key] = hook[key]
                    row['editable'] = {'matcher': group.get('matcher', ''), 'config': hook}
                    hooks.append(row)
                    counts[event] = counts.get(event, 0) + 1
    if os.environ.get('FAKE_CLAUDE_PLUGIN_HOOK'):
        hooks.append({'event': 'SessionStart', 'matcher': 'compact', 'source': 'pluginHook',
                      'sourceLabel': 'Plugin hooks (~/.claude/plugins/*/hooks/hooks.json)', 'pluginName': 'fake@market',
                      'type': 'command', 'displayText': 'reminder.sh', 'commandText': 'reminder.sh',
                      'contentLabel': 'Command'})
        counts['SessionStart'] = counts.get('SessionStart', 0) + 1
    events = [dict(e, hookCount=counts[e['name']]) for e in CATALOG if e['name'] in counts]
    return {'events': events, 'hooks': hooks, 'eventCatalog': CATALOG,
            'policy': {'disabledByPolicy': False, 'managedOnly': False, 'pluginOnly': False, 'allDisabled': False,
                       'policyHookCount': 0}}


def edit_hook(edit, cwd, config):
    """{op: add|replace|remove, source, event, matcher, hook, target}; the real CLI's answers."""
    source = edit.get('source')
    if source not in SOURCES:
        return fail({'ok': False, 'error': 'edit_hook: source must be userSettings, projectSettings, or localSettings',
                     'code': 'bad_request'})
    path = settings_path(source, cwd, config)
    try:
        with open(path, encoding='utf-8') as stream:
            settings = json.load(stream)
    except OSError:
        settings = {}
    except ValueError:
        return fail({'ok': False, 'error': 'edit_hook: the %s file has errors and could not be loaded; fix it by hand '
                     'first' % source, 'code': 'file_unloadable', 'refusal': {'code': 'unloadable', 'file': path}})
    table = settings.setdefault('hooks', {})
    op = edit.get('op')
    for event in {edit.get('event'), (edit.get('target') or {}).get('event')} - {None}:
        if event in table and not isinstance(table[event], list):
            return fail({'ok': False, 'error': 'edit_hook: the %s entry in %s is not a list; fix the file by hand'
                         % (event, source), 'code': 'not_a_list', 'refusal': {'code': 'not-a-list', 'file': path}})
    if op in ('replace', 'remove'):
        target = edit.get('target') or {}
        groups = table.get(target.get('event'), [])
        same = [h for g in groups if g.get('matcher', '') == target.get('matcher', '')
                for h in g.get('hooks', []) if h == target.get('hook')]
        if len(same) > 1:
            return fail({'ok': False, 'error': 'edit_hook: more than one identical hook is configured for %s in %s; '
                         'edit the file by hand' % (target.get('event'), source), 'code': 'target_ambiguous',
                         'refusal': {'code': 'twins', 'file': path}})
        for group in groups:
            if group.get('matcher', '') == target.get('matcher', '') and target.get('hook') in group.get('hooks', []):
                group['hooks'].remove(target['hook'])
                break
        else:
            return fail({'ok': False, 'error': 'edit_hook: that hook is no longer in %s; it may have been changed '
                         'outside this dialog' % source, 'code': 'target_missing'})
        table[target.get('event')] = [g for g in groups if g.get('hooks')]
        if not table[target.get('event')]:
            del table[target.get('event')]
    if op in ('add', 'replace'):
        groups = table.setdefault(edit['event'], [])
        for group in groups:
            if group.get('matcher', '') == edit.get('matcher', ''):
                group['hooks'].append(edit['hook'])
                break
        else:
            group = {'hooks': [edit['hook']]}
            if edit.get('matcher'):
                group = {'matcher': edit['matcher'], 'hooks': [edit['hook']]}
            groups.append(group)
    if not table:
        del settings['hooks']
    write(path, settings)
    print(json.dumps({'ok': True}))
    return 0


def fail(answer):
    print(json.dumps(answer))
    sys.stderr.write(answer.get('error', '') + '\n')
    return 1


# ---- permission rules ----

def rules_state(cwd, config):
    rules = []
    for source in SOURCES:
        perms = read(settings_path(source, cwd, config), {}).get('permissions') or {}
        for behavior in ('allow', 'ask', 'deny'):
            for rule in perms.get(behavior) or []:
                entry = {'behavior': behavior, 'source': source, 'rule': rule}
                m = re.fullmatch(r'Bash\((.+?)( \*|:\*)\)', rule)
                if m:
                    entry['description'] = {'prefix': 'Any Bash command starting with ', 'emphasis': m.group(1)}
                entry['editability'] = 'persistent'
                rules.append(entry)
    if os.environ.get('FAKE_CLAUDE_SESSION_RULE'):
        rules.append({'behavior': 'allow', 'source': 'session', 'rule': os.environ['FAKE_CLAUDE_SESSION_RULE'],
                      'editability': 'session'})
    return {'state': {'rules': rules, 'workspaceDirectories': [], 'originalCwd': cwd, 'managedOnly': False}}


def edit_rules(edit, cwd, config):
    op = edit.get('op')
    if op == 'add':
        for rule in edit.get('rules') or []:
            if rule.count('(') != rule.count(')'):
                sys.stderr.write('Malformed Tool(content) rule — Rules take the form Tool or Tool(content) and '
                                 'must end at the closing ")"; parentheses inside the content are literal\n')
                return 1
        path = settings_path(edit.get('destination'), cwd, config)
        settings = read(path, {})
        listed = settings.setdefault('permissions', {}).setdefault(edit.get('behavior'), [])
        for rule in edit['rules']:
            if rule not in listed:
                listed.append(rule)
        write(path, settings)
        print(json.dumps({'ok': True, 'warnings': [], 'stored': edit['rules']}))
        return 0
    if op == 'remove':
        path = settings_path(edit.get('source'), cwd, config)
        settings = read(path, {})
        listed = (settings.get('permissions') or {}).get(edit.get('behavior')) or []
        if edit.get('rule') in listed:
            listed.remove(edit['rule'])
        write(path, settings)
        print(json.dumps({'ok': True, 'warnings': [], 'stored': []}))
        return 0
    sys.stderr.write('Unknown op\n')
    return 1


# ---- sandbox ----

def sandbox_dialog(cwd, config):
    sandbox = read(settings_path('localSettings', cwd, config), {}).get('sandbox') or {}
    enabled = sandbox.get('enabled') is True
    mode = ('auto-allow' if sandbox.get('autoAllowBashIfSandboxed', True) else 'regular') if enabled else 'disabled'
    return {'supported': True, 'locked': False, 'overrides_locked': False, 'policy_origins': [], 'enabled': enabled,
            'enabled_in_settings': enabled, 'mode': mode, 'auto_allow_available': True, 'no_sandbox_allowed': True,
            'unsandboxed_fallback': sandbox.get('allowUnsandboxedCommands', True) is not False,
            'dependencies': {'errors': [], 'warnings': []},
            'excluded_commands': list(sandbox.get('excludedCommands') or []),
            'restrictions': {'fs_deny_read': [], 'fs_allow_read': [], 'fs_allow_write': ['/tmp/build'],
                             'fs_deny_write': [], 'network_allowed_domains': ['example.com', 'example.org'],
                             'network_denied_domains': [], 'network_managed': False, 'unix_sockets': [],
                             'allow_all_unix_sockets': False, 'ignored_glob_patterns': [], 'ignored_unix_sockets': []}}


def edit_sandbox(edit, cwd, config):
    path = settings_path('localSettings', cwd, config)
    settings = read(path, {})
    sandbox = settings.setdefault('sandbox', {})
    if 'mode' in edit:
        sandbox['enabled'] = edit['mode'] != 'disabled'
        sandbox['autoAllowBashIfSandboxed'] = edit['mode'] == 'auto-allow'
    if 'allowUnsandboxedCommands' in edit:
        sandbox['allowUnsandboxedCommands'] = edit['allowUnsandboxedCommands']
    if 'excludeCommand' in edit:
        sandbox.setdefault('excludedCommands', [])
        if edit['excludeCommand'] not in sandbox['excludedCommands']:
            sandbox['excludedCommands'].append(edit['excludeCommand'])
    write(path, settings)
    print(json.dumps({'ok': True, 'written': edit}))
    return 0


# ---- plugins ----

SEED = {'installed': [],
        'available': [{'pluginId': 'lint-helper@fake-market', 'name': 'lint-helper', 'marketplaceName': 'fake-market',
                       'description': 'Lints‮ what you write', 'installCount': 120},
                      {'pluginId': 'doc-writer@fake-market', 'name': 'doc-writer', 'marketplaceName': 'fake-market',
                       'description': 'Writes docs', 'installCount': 4200},
                      {'pluginId': 'broken@fake-market', 'name': 'broken', 'marketplaceName': 'fake-market',
                       'description': 'Its dependencies are missing', 'installCount': 3}],
        'marketplaces': [{'name': 'fake-market', 'source': 'github', 'repo': 'fake/market'}],
        'options': {}}
OPTIONS = {'schema': {'apiKey': {'title': 'API key', 'description': 'Your key for the service', 'required': True,
                                 'sensitive': True},
                      'region': {'title': 'Region', 'description': 'Where it runs'},
                      'level': {'title': 'Level'}},
           'choices': {'level': ['low', 'high']}}


def plugins_path(config):
    return os.path.join(config, 'plugins', 'fake-plugins.json')


def plugins_state(config):
    return read(plugins_path(config), json.loads(json.dumps(SEED)))


def result(command, outcome, **extra):
    print(json.dumps(dict({'command': command, 'outcome': outcome}, **extra)))


def plugin_sub(args, config, stdin):
    state = plugins_state(config)
    words = args[1:]
    flags = [w for w in words if w.startswith('--')]
    rest = words[words.index('--') + 1:] if '--' in words else []
    verbs = [w for w in words if not w.startswith('--')]
    scope = None
    if '--scope' in words:
        scope = words[words.index('--scope') + 1]
        verbs.remove(scope)
    verbs = [v for v in verbs if v not in rest]
    target = rest[0] if rest else None
    if verbs[:1] == ['list']:               # the real CLI prints these lists indented, over many lines
        installed = [dict(p) for p in state['installed']]
        if '--available' in flags:
            available = list(state['available'])
            for n in range(int(os.environ.get('FAKE_CLAUDE_PLUGINS_MANY', '0'))):  # the official directory's size
                available.append({'pluginId': 'many-%04d@directory' % n, 'name': 'many-%04d' % n,
                                  'description': 'One of many', 'marketplaceName': 'directory', 'version': '1.0.0',
                                  'source': {'source': 'url', 'url': 'https://example.invalid/many-%04d.git' % n}})
            print(json.dumps({'installed': installed, 'available': available}, indent=2))
        else:
            print(json.dumps(installed, indent=2))
        return 0
    if verbs[:2] == ['marketplace', 'list']:
        print(json.dumps(state['marketplaces'], indent=2))
        return 0
    if verbs[:2] == ['marketplace', 'add']:
        source = target or ''
        name = re.sub(r'[^A-Za-z0-9_-]', '-', source.rstrip('/').split('/')[-1]) or 'market'
        known = [m for m in state['marketplaces'] if m.get('repo') == source or m.get('url') == source]
        if '--resolve-only' in flags:
            print(json.dumps({'existing': known[0]['name'] if known else None}))
            return 0
        if known:
            print(json.dumps({'refused': {'kind': 'same_address', 'name': known[0]['name']}}))
            return 1
        if source.startswith('bad'):
            sys.stderr.write('Failed to add marketplace: %s is not a marketplace\n' % source)
            result('marketplace-add', 'failed', message='not a marketplace', failureCode='not_a_marketplace')
            return 1
        entry = {'name': name, 'source': 'github', 'repo': source}
        state['marketplaces'].append(entry)
        if 'link-market' in source:
            state['available'].append({'pluginId': 'linked-tool@%s' % name, 'name': 'linked-tool',
                                       'marketplaceName': name, 'description': 'From a link', 'installCount': 1})
        write(plugins_path(config), state)
        print(json.dumps({'name': name, 'added': True}))
        return 0
    if verbs[:2] in (['marketplace', 'remove'], ['marketplace', 'update']):
        names = [m['name'] for m in state['marketplaces']]
        if target not in names:
            result('marketplace-' + verbs[1], 'failed', marketplace=target, message="Marketplace '%s' not found" % target,
                   failureCode='not_configured')
            sys.stderr.write("Failed: Marketplace '%s' not found\n" % target)
            return 1
        if verbs[1] == 'remove':
            state['marketplaces'] = [m for m in state['marketplaces'] if m['name'] != target]
            state['available'] = [p for p in state['available'] if p['marketplaceName'] != target]
            write(plugins_path(config), state)
        result('marketplace-' + verbs[1], 'ok', marketplace=target)
        return 0
    if verbs[:1] == ['install']:
        found = [p for p in state['available'] if p['pluginId'] == target]
        if not found:
            result('install', 'failed', plugin=target, message='Plugin "%s" not found' % target, failureCode='not_found')
            return 1
        if found[0]['name'] == 'broken':
            result('install', 'failed', plugin=target, message='dependency missing-dep is not in any marketplace',
                   failureCode='dependency_resolution_failed')
            sys.stderr.write('Failed to install plugin\n')
            return 1
        state['available'] = [p for p in state['available'] if p['pluginId'] != target]
        entry = {'id': target, 'version': '1.0.0', 'scope': scope or 'user', 'enabled': True,
                 'installPath': '/fake/%s' % target}
        if found[0]['name'] == 'doc-writer':
            entry['hasUserConfig'] = True
            entry['description'] = found[0]['description']
        state['installed'].append(entry)
        write(plugins_path(config), state)
        result('install', 'ok', plugin=target, scope=scope)
        return 0
    if verbs[:1] in (['enable'], ['disable'], ['update'], ['uninstall']):
        verb = verbs[0]
        matches = [p for p in state['installed'] if p['id'] == target and (scope is None or p['scope'] == scope)]
        if not matches:
            result(verb, 'failed', plugin=target, message='Plugin "%s" not found in installed plugins' % target,
                   failureCode='not_installed')
            return 1
        if verb == 'uninstall':
            state['installed'].remove(matches[0])
            name = target.split('@')[0]
            state['available'].append({'pluginId': target, 'name': name, 'marketplaceName': target.split('@')[-1],
                                       'description': 'Back again', 'installCount': 0})
            state.setdefault('kept_data', {})[target] = '--keep-data' in flags
        elif verb in ('enable', 'disable'):
            matches[0]['enabled'] = verb == 'enable'
        write(plugins_path(config), state)
        result(verb, 'ok', plugin=target, scope=scope)
        return 0
    if verbs[:1] == ['configure']:
        installed = [p for p in state['installed'] if p['id'] == target]
        if not installed:
            sys.stderr.write('No installed plugin has the id "%s".\n' % target)
            return 1
        values = state.setdefault('options', {}).setdefault(target, {})
        if '--values-stdin' in flags:
            given = json.loads(stdin or '{}')
            if given.get('region') == 'mars':
                print(json.dumps({'refused': {'option': 'region', 'message': 'Region must be eu or us'}}))
                return 1
            values.update(given)
            write(plugins_path(config), state)
            print(json.dumps({'saved': sorted(given)}))
            return 0
        shown = {k: v for k, v in values.items() if k != 'apiKey'}
        configured = sorted(values)
        print(json.dumps(dict(OPTIONS, inputs=shown, configured=configured,
                              unconfigured=[k for k in OPTIONS['schema'] if k not in values]), indent=2))
        return 0
    sys.stderr.write('error: unknown plugin command %s\n' % ' '.join(words))
    return 1


# ---- the entry points ----

def subcommand(args, config, log):
    """One of the configuration subcommands: its exit status."""
    stdin = sys.stdin.read() if args[0] in ('edit-hook', 'edit-permission-rules', 'edit-sandbox-settings') or \
        '--values-stdin' in args else ''
    log(sub=args, stdin=stdin, cwd=os.getcwd())
    cwd = os.getcwd()
    if args[0] == 'mcp':
        return mcp_sub(args)
    if args[0] in ('plugin', 'plugins'):
        return plugin_sub(args, config, stdin)
    try:
        edit = json.loads(stdin)
    except ValueError:
        sys.stderr.write('Error: the edit is not JSON\n')
        return 1
    if args[0] == 'edit-hook':
        return edit_hook(edit, cwd, config)
    if args[0] == 'edit-permission-rules':
        return edit_rules(edit, cwd, config)
    return edit_sandbox(edit, cwd, config)


def control(rid, sub, request, respond, respond_error, cwd, config):
    """A control request of the configuration's."""
    name = request.get('serverName')
    known = [n for n, _, _ in servers(cwd, config)]
    if sub == 'mcp_status':
        time.sleep(int(os.environ.get('FAKE_CLAUDE_MCP_SLOW', '0')) / 1000)
        respond(rid, mcp_status(cwd, config))
    elif sub in ('mcp_toggle', 'mcp_reconnect', 'mcp_clear_auth', 'mcp_authenticate', 'mcp_oauth_callback_url') \
            and name not in known:
        respond_error(rid, 'Server not found: %s' % name)
    elif sub == 'mcp_toggle':
        off = [n for n in disabled(cwd, config) if n != name]
        if request.get('enabled') is False:
            off.append(name)
        set_disabled(cwd, config, off)
        respond(rid, {})
    elif sub == 'mcp_reconnect':
        if 'fail' in name:
            respond_error(rid, 'Connection closed')
        else:
            respond(rid, {})
    elif sub == 'mcp_clear_auth':
        AUTHED.discard(name)
        respond(rid, {})
    elif sub == 'mcp_authenticate':
        respond(rid, {'authUrl': 'https://auth.example.invalid/authorize?state=s1', 'requiresUserAction': True,
                      'localhostRedirectMayFail': True})
    elif sub == 'mcp_oauth_callback_url':
        AUTHED.add(name)
        respond(rid, {})
    elif sub == 'get_hooks_listing':
        respond(rid, hooks_listing(cwd, config))
    elif sub == 'list_permission_rules':
        respond(rid, rules_state(cwd, config))
    elif sub == 'get_sandbox_dialog':
        respond(rid, sandbox_dialog(cwd, config))
    elif sub == 'reload_plugins':           # FAKE_CLAUDE_RELOAD_FAIL: the first N reloads count an error
        failing = int(os.environ.get('FAKE_CLAUDE_RELOAD_FAIL', '0'))
        RELOADS.append(rid)
        respond(rid, {'commands': [], 'agents': [], 'plugins': [], 'mcpServers': [],
                      'error_count': 1 if len(RELOADS) <= failing else 0})
