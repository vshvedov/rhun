#!/usr/bin/env python3
"""A stand-in for Claude Code 2.1.330 in stream-json mode, for rhun's tests (spec 11).

`claude auth status [--json]` prints the report FAKE_CLAUDE_AUTH names (ok, out, key, garbage; @FILE reads
the name from FILE; profile reads it from <config>/fake-auth, ok without it), FAKE_CLAUDE_AUTH_MS after it
started (default at once).
Stream mode takes the command line rhun passes (tests/data/claude-shapes/README.txt):
  --output-format stream-json --verbose --input-format stream-json --include-partial-messages
  --permission-prompt-tool=stdio --setting-sources=SOURCES --max-thinking-tokens=N | --thinking=disabled
  [--session-id=UUID | --resume=ID | --resume=SRC --fork-session --session-id=UUID] [--permission-mode=MODE]
  [--replay-user-messages] [--allow-dangerously-skip-permissions] [--model=VALUE] [--effort=LEVEL]
every flag as `--flag=value` or `--flag value`, `-p` allowed but not needed; a missing one or a flag it does
not know is refused (status 2, logged as "refused"). Phase 2 (README.txt findings 10 on): bypassPermissions
is taken at a start with or without --allow-dangerously-skip-permissions, by set_permission_mode only with
it or after a bypass start; the mode's status line only when the mode changes. With --replay-user-messages
each user message comes back as its turn starts and each control_response rhun writes comes back as
sent. A user message with a "uuid" gets command_lifecycle queued/started/completed (cancelled: an
interrupt ended its turn); one written during a turn waits for its own turn (system/init comes with every
turn) and interrupt answers {"still_queued": [the waiting uuids]}, which then run. It answers get_settings
(effective, sources, applied from the settings files the sources let in, --model/--effort and
apply_flag_settings), apply_flag_settings (this process only), update_settings (localSettings: outputStyle;
userSettings: effortLevel into modelSettings.<model>; anything else refused as the CLI words it),
set_max_thinking_tokens, get_plan; initialize's promptSuggestions (true: prompt_suggestion "Run the tests"
after a turn that ended by itself with nothing waiting) and supportedDialogKinds are logged. An allow's
updatedPermissions are applied: rules into their destination's file or the session (a later call they
match runs without asking), a setMode changes the mode; a Bash allow runs updatedInput's command.
Commands it answers itself, as the CLI does: /context, /cost, /usage, /status, /compact. --setting-sources (user, project, local) picks the
settings files whose permissions.defaultMode it reads: <config>/settings.json, <cwd>/.claude/settings.json,
<cwd>/.claude/settings.local.json (later ones win; --permission-mode wins over all, FAKE_CLAUDE_MODE is
the default when none sets it). It speaks the control protocol with the records, fields and order of the
recordings (tests/data/claude-shapes); tests/fake-claude.py compares its output with their shapes and the
field order of every record with theirs (keys.txt).
The first word of a prompt picks a scenario (SCENARIOS at the end); any other prompt is answered
"ok: PROMPT". Like the CLI it registers <config>/sessions/<pid>.json before it answers initialize,
removes it on a clean exit (a crash, `exit`, `big` or a SIGTERM leaves it), and appends the conversation
to <config>/projects/<cwd with every non-alphanumeric as '-'>/<session id>.jsonl (config:
CLAUDE_CONFIG_DIR or ~/.claude).

Environment: FAKE_CLAUDE_AUTH; FAKE_CLAUDE_ACCOUNT (ok, bedrock, none: the initialize account);
FAKE_CLAUDE_KEYSRC (system/init apiKeySource, default none); FAKE_CLAUDE_MODE (the user's default
permission mode, default "default"); FAKE_CLAUDE_INIT_MS (a delay before initialize is answered);
FAKE_CLAUDE_RESUME (unknown: every --resume id is unknown, as fixture 11); FAKE_CLAUDE_LINGER_MS (an unknown
--resume exits that long after its result; `mute` runs that long after closing its stdout); FAKE_CLAUDE_FORK_LATE (a copy's file, the source's history, is
written with its first transcript line rather than at its start: unrecorded, so rhun must handle both);
FAKE_CLAUDE_NUMERIC_IDS (its requests' ids are numbers from 7); FAKE_CLAUDE_EOF_MS (how long it takes to exit
once its stdin closed and its turn ended); FAKE_CLAUDE_SCENARIO (every prompt runs
that scenario, whatever its first word); FAKE_CLAUDE_UNSAVED_MARK (`unsaved` stopped saves only the
interrupt mark, not the prompt);
FAKE_CLAUDE_USER_LATE_MS (a turn's user line reaches the transcript only when a SIGTERM stops the process,
that long after the signal: a prompt recorded as it is stopped; or, nobody stopping it, after
FAKE_CLAUDE_USER_LATE_WAIT_MS, default 10000, and the turn goes on);
FAKE_CLAUDE_MODELS (comma-separated: effort, nothink, auto, fast, unavailable, ultra, noeffort; see model_list);
FAKE_CLAUDE_CONTEXT (N: a turn's usage adds up to N tokens); FAKE_CLAUDE_RATE (warning, rejected: a
rate_limit_event before each result); FAKE_CLAUDE_SETTINGS_ERROR (TEXT: get_settings has one error);
FAKE_CLAUDE_AUTH_CONFLICT (initialize has auth_conflict); FAKE_CLAUDE_FAST ("STATE REASON": initialize's
fast_mode_state and fast_mode_disabled_reason, "-" for none, as 2.1.330's "off sdk_opt_in_required"; system/init and
every result carry the state; without it initialize has no reason, as before); FAKE_CLAUDE_FAST_REJECT (unrecorded:
the first turn after /fast turned fast mode on gets system/notification "fast-mode-overage-rejected" and fast mode
goes off, as the CLI binary's text has it); FAKE_CLAUDE_COMMANDS_CHANGED (comma-separated names:
the system/commands_changed that follows initialize lists these instead, the known ones as initialize has
them, the others as skills "Skill NAME", as the real list has skills initialize lacks); FAKE_CLAUDE_REFUSE_HELD (the first message written
with a uuid while another waits or runs is refused: lifecycle refused, never run, logged {"refused": UUID});
FAKE_CLAUDE_DISCARD_HELD (the first such message is queued, then, when its turn would start, lifecycle
discarded, never run, logged {"discarded": UUID}); FAKE_CLAUDE_NO_LIFECYCLE (no command_lifecycle at all:
only the replay says a message started);
FAKE_CLAUDE_ECHO_ENV (comma-separated names whose values the log's start record shows, besides
CLAUDE_CODE_ENTRYPOINT, CLAUDECODE, CLAUDE_CODE_CHILD_SESSION, MCP_CONNECTION_NONBLOCKING, TRACEPARENT and
TRACESTATE);
FAKE_CLAUDE_LOG (a file of JSON lines, each with the fake's pid: {"start": "auth"|"stream"|"refused",
"argv", "cwd", "env": {NAME: value or null for the names above}, "names": [every CLAUDE* and ANTHROPIC*
name it got], "sources": [the --setting-sources], "switches": {replay, allow_bypass, thinking, model, effort}} per
start, {"initialize": {promptSuggestions, supportedDialogKinds}}, {"thinking": {...}} per set_max_thinking_tokens,
{"stdin": LINE} per line read, {"answer": ...} per answer to a single
request, {"questions_kept": ...}, {"many": [...]} and {"unhandled": [...]} from those scenarios, {"error": TRACEBACK} when a
record or answer of a shape it cannot read failed, {"exit": N} at the end).

It never runs the real CLI or touches the network. When its stdin closes it finishes the turn that
runs (a request still waiting is withdrawn, as nobody is left to answer it) and exits; only `deaf`,
an agent that does not stop, runs on (30 s at most) until it is killed; `gone` closes its stdin itself as it
reads that prompt and runs on (FAKE_CLAUDE_LINGER_MS, default 30 s). It exits too when its stdout
is gone. Unrecorded choices (EOF with a request waiting, SIGTERM and the record) are listed in the
fixtures notes under "Not recorded"."""
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
import traceback
import uuid

ENV = os.environ
ARGS = sys.argv[1:]
START = time.time()
LOCK = threading.RLock()            # stdout and the state below
COND = threading.Condition(LOCK)
# Claude Code reads and writes UTF-8 whatever the locale says
sys.stdin.reconfigure(encoding='utf-8', errors='replace')
sys.stdout.reconfigure(encoding='utf-8')


def log(**record):
    """One line in FAKE_CLAUDE_LOG, written by one write() so several fakes and threads never mix lines."""
    path = ENV.get('FAKE_CLAUDE_LOG')
    if path:
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            os.write(fd, (json.dumps(dict(record, pid=os.getpid())) + '\n').encode('utf-8'))
        finally:
            os.close(fd)


def config_dir():
    return ENV.get('CLAUDE_CONFIG_DIR') or os.path.join(ENV['HOME'], '.claude')


ECHOED = ['CLAUDE_CODE_ENTRYPOINT', 'CLAUDECODE', 'CLAUDE_CODE_CHILD_SESSION', 'MCP_CONNECTION_NONBLOCKING',
          'TRACEPARENT', 'TRACESTATE']


def env_shown():
    """The values (None: not set) of the names the log shows: rhun's forced and removed ones, and those
    FAKE_CLAUDE_ECHO_ENV names (a test's `[claude] env.*` pairs)."""
    names = ECHOED + [n for n in ENV.get('FAKE_CLAUDE_ECHO_ENV', '').split(',') if n and n not in ECHOED]
    return {name: ENV.get(name) for name in names}


def claude_env():
    """The CLAUDE* and ANTHROPIC* names the process got."""
    return sorted(name for name in ENV if name.startswith(('CLAUDE', 'ANTHROPIC')))


if ARGS[:2] == ['auth', 'status']:
    MODE_AUTH = ENV.get('FAKE_CLAUDE_AUTH', 'ok')
    if MODE_AUTH.startswith('@'):           # @FILE: the file names the mode (a test changes it mid-run)
        MODE_AUTH = open(MODE_AUTH[1:], encoding='utf-8').read().strip()
    elif MODE_AUTH == 'profile':            # the profile's own: <config>/fake-auth names it (ok without one)
        try:
            MODE_AUTH = open(os.path.join(config_dir(), 'fake-auth'), encoding='utf-8').read().strip()
        except OSError:
            MODE_AUTH = 'ok'
    log(start='auth', argv=ARGS, cwd=os.getcwd(), env=env_shown(), names=claude_env())
    time.sleep(int(ENV.get('FAKE_CLAUDE_AUTH_MS', '0')) / 1000)
    if MODE_AUTH == 'garbage':
        print('???')
        sys.exit(0)
    print(json.dumps({
        'ok': {'loggedIn': True, 'authMethod': 'claude.ai', 'apiProvider': 'firstParty', 'subscriptionType': 'max'},
        'out': {'loggedIn': False, 'authMethod': 'none', 'apiProvider': 'firstParty'},
        'key': {'loggedIn': True, 'authMethod': 'apiKey', 'apiProvider': 'firstParty'}}[MODE_AUTH]))
    sys.exit(1 if MODE_AUTH == 'out' else 0)


VALUED = {'--output-format', '--input-format', '--permission-prompt-tool', '--setting-sources',
          '--max-thinking-tokens', '--resume', '--session-id', '--permission-mode', '--model', '--effort', '--thinking'}
SWITCHES = {'-p', '--print', '--verbose', '--include-partial-messages', '--fork-session', '--replay-user-messages',
            '--allow-dangerously-skip-permissions'}
SOURCES = ('user', 'project', 'local')


def parse(args):
    """{flag: value or True} of a command line whose flags come as `--flag=value` or `--flag value`;
    None when it has something the fake does not know (as the CLI, it refuses an unknown option)."""
    flags = {}
    i = 0
    while i < len(args):
        arg = args[i]
        name, eq, value = arg.partition('=')
        if name in VALUED:
            if not eq:
                if i + 1 >= len(args):
                    return None
                i += 1
                value = args[i]
            flags[name] = value
        elif name in SWITCHES and not eq:
            flags[name] = True
        else:
            return None
        i += 1
    return flags


EFFORTS = ('low', 'medium', 'high', 'xhigh', 'max')


def pinned(flags):
    """The command line rhun pins (README.txt) is all there: the thinking level as --max-thinking-tokens=N or
    --thinking=disabled (one of them), an --effort a level the CLI knows."""
    sources = flags.get('--setting-sources', '').split(',')
    thinking = [re.fullmatch(r'\d+', flags.get('--max-thinking-tokens', '')) is not None,
                flags.get('--thinking') == 'disabled']
    return flags.get('--output-format') == 'stream-json' and flags.get('--input-format') == 'stream-json' \
        and flags.get('--verbose') is True and flags.get('--include-partial-messages') is True \
        and flags.get('--permission-prompt-tool') == 'stdio' \
        and all(s in SOURCES for s in sources) and len(set(sources)) == len(sources) \
        and thinking.count(True) == 1 and ('--thinking' not in flags or thinking[1]) \
        and flags.get('--effort', 'low') in EFFORTS


FLAGS = parse(ARGS)
if FLAGS is None or not pinned(FLAGS):
    sys.stderr.write('fake claude: unexpected arguments %r\n' % (ARGS,))
    log(start='refused', argv=ARGS, cwd=os.getcwd(), env=env_shown(), names=claude_env())
    sys.exit(2)


def option(name):
    return FLAGS.get(name)


def settings_mode(sources, cwd):
    """permissions.defaultMode of the settings files --setting-sources lets in (the later ones win)."""
    files = {'user': os.path.join(config_dir(), 'settings.json'),
             'project': os.path.join(cwd, '.claude', 'settings.json'),
             'local': os.path.join(cwd, '.claude', 'settings.local.json')}
    mode = None
    for source in SOURCES:
        if source not in sources:
            continue
        try:
            with open(files[source], encoding='utf-8') as stream:
                settings = json.load(stream)
        except (OSError, ValueError):
            continue
        value = settings.get('permissions', {}).get('defaultMode') if isinstance(settings, dict) else None
        if isinstance(value, str):
            mode = value
    return mode


CWD = os.getcwd()                   # resolved, as the CLI's: the slug ignores PWD and symbolic links
PROJECTS = os.path.join(config_dir(), 'projects', re.sub(r'[^A-Za-z0-9]', '-', CWD))
SOURCES_GIVEN = option('--setting-sources').split(',')
RESUME = option('--resume')
FORK = '--fork-session' in FLAGS
MODE = option('--permission-mode') or settings_mode(SOURCES_GIVEN, CWD) or ENV.get('FAKE_CLAUDE_MODE', 'default')
MODE = 'default' if MODE == 'manual' else MODE
SID = option('--session-id')
EXIT_STATUS = [0]
CLOSED = threading.Event()          # stdin reached EOF: nobody answers requests any more
CRASH = threading.Event()           # a lost stdout ends the process like a crash (the record stays)
RECORD = os.path.join(config_dir(), 'sessions', '%d.json' % os.getpid())
REPLAY = '--replay-user-messages' in FLAGS          # user messages (finding 17) and answers (finding 18) come back
# bypassPermissions: taken at a start with or without --allow-dangerously-skip-permissions; by
# set_permission_mode only in a process started with the flag or in bypass (finding 10)
BYPASS_OK = '--allow-dangerously-skip-permissions' in FLAGS or MODE == 'bypassPermissions'
THINKING = [0 if option('--thinking') == 'disabled' else int(option('--max-thinking-tokens'))]
SWITCHED = {'replay': REPLAY, 'allow_bypass': '--allow-dangerously-skip-permissions' in FLAGS,
            'thinking': option('--thinking') or option('--max-thinking-tokens'), 'model': option('--model'),
            'effort': option('--effort')}
log(start='stream', argv=ARGS, cwd=CWD, env=env_shown(), names=claude_env(), sources=SOURCES_GIVEN,
    switches=SWITCHED)


def leave(status):
    """A clean exit: the session record goes (C7). Every record went out flushed already (emit); taking
    LOCK here could wait forever on a writer stuck on a full pipe."""
    try:
        os.unlink(RECORD)
    except FileNotFoundError:
        pass
    log(exit=status)
    os._exit(status)


def crash(status):
    """An exit as a crash: the session record stays (C7 removes it only on a clean exit). Like leave() it
    takes no lock (a SIGTERM runs it)."""
    log(exit=status)
    os._exit(status)


def emit(record):
    # raw UTF-8 like the CLI's JSON.stringify (no \u escapes for non-ASCII text)
    line = json.dumps(record, separators=(',', ':'), ensure_ascii=False)
    with LOCK:
        try:
            sys.stdout.write(line + '\n')
            sys.stdout.flush()
        except OSError:             # the reader is gone (EPIPE): nobody is left to talk to
            if CRASH.is_set():
                crash(1)
            leave(1)


def usage(cache=None):
    """A turn's usage. FAKE_CLAUDE_CONTEXT=N: the four token counts add up to N (the context in use).
    cache: (written, read) for the `usage` scenario, with the 1-hour and 5-minute split the CLI reports."""
    used = int(ENV.get('FAKE_CLAUDE_CONTEXT', '0') or 0)
    record = {'input_tokens': 6, 'cache_creation_input_tokens': 0,
              'cache_read_input_tokens': max(0, used - 18) if used else 120, 'output_tokens': 12}
    if cache:
        record.update(cache_creation_input_tokens=cache[0], cache_read_input_tokens=cache[1],
                      cache_creation={'ephemeral_1h_input_tokens': cache[0], 'ephemeral_5m_input_tokens': 0})
    return record


# The models initialize lists (2.1.330's records: tests/data/claude-shapes/README.txt finding 19), shaped by
# FAKE_CLAUDE_MODELS, a comma-separated list of: effort (the default model gets the five levels low..max),
# nothink (supportsThinkingOff), auto (supportsAutoMode), fast (supportsFastMode), unavailable (an
# unavailable_models entry), ultra (get_settings.applied.ultracodeAvailable: no model carries the flag),
# noeffort (sonnet without supportsEffort).
MODEL_KNOBS = set(filter(None, ENV.get('FAKE_CLAUDE_MODELS', '').split(',')))


def model_list():
    models = [{'value': 'default', 'resolvedModel': 'claude-opus-5-5', 'displayName': 'Default (recommended)',
               'description': 'Opus 5.5', 'supportsEffort': True},
              {'value': 'sonnet', 'resolvedModel': 'claude-sonnet-5', 'displayName': 'Sonnet',
               'description': 'Sonnet 5', 'supportsEffort': True}]
    first = models[0]
    if 'effort' in MODEL_KNOBS:
        first['supportedEffortLevels'] = list(EFFORTS)
    if 'fast' in MODEL_KNOBS:
        first['supportsFastMode'] = True
    if 'auto' in MODEL_KNOBS:
        first['supportsAutoMode'] = True
    if 'nothink' in MODEL_KNOBS:
        first['supportsThinkingOff'] = True
    if 'noeffort' in MODEL_KNOBS:           # a model without effort levels (as the older ones are)
        del models[1]['supportsEffort']
    return models


def unavailable_models():
    """Unrecorded (the account had none): the models entries' shape, under the schema's name."""
    return [{'value': 'haiku', 'resolvedModel': 'claude-haiku-5-5', 'displayName': 'Haiku',
             'description': 'Not on your plan'}] if 'unavailable' in MODEL_KNOBS else []


DEFAULT_EFFORT = {'claude-opus-5-5': 'high', 'claude-sonnet-5': 'medium'}   # applied.effort with nothing set
_FAST = (ENV.get('FAKE_CLAUDE_FAST') or 'off -').split(None, 1) + ['-']
FAST = [_FAST[0], None if _FAST[1].strip() == '-' else _FAST[1].strip()]   # fast mode's state and its reason
FLAG_SETTINGS = {}                  # apply_flag_settings: this process only (the flagSettings source)


def resolve(value):
    for model in model_list() + unavailable_models():
        if value in (model['value'], model['resolvedModel']):
            return model['resolvedModel']
    return value


def settings_files():
    """(source, path) of the settings files --setting-sources lets in, in merge order."""
    files = {'user': ('userSettings', os.path.join(config_dir(), 'settings.json')),
             'project': ('projectSettings', os.path.join(CWD, '.claude', 'settings.json')),
             'local': ('localSettings', os.path.join(CWD, '.claude', 'settings.local.json'))}
    return [files[s] for s in SOURCES if s in SOURCES_GIVEN]


def read_settings(path):
    try:
        with open(path, encoding='utf-8') as stream:
            value = json.load(stream)
        return value if isinstance(value, dict) else None
    except (OSError, ValueError):
        return None


def settings_sources():
    out = [{'source': source, 'settings': read_settings(path)} for source, path in settings_files()]
    out = [s for s in out if s['settings'] is not None]
    if FLAG_SETTINGS:
        out.append({'source': 'flagSettings', 'settings': dict(FLAG_SETTINGS)})
    return out


def effective():
    merged = {}
    for source in settings_sources():
        for key, value in source['settings'].items():
            if isinstance(value, dict) and isinstance(merged.get(key), dict):
                merged[key] = dict(merged[key], **value)
            else:
                merged[key] = value
    return merged


def current_model():
    """The resolved model this process uses: apply_flag_settings, --model, the settings' model, default."""
    value = FLAG_SETTINGS.get('model') or option('--model') or effective().get('model') or 'default'
    return resolve(value)


def current_effort():
    """applied.effort: apply_flag_settings, --effort, the model's own (modelSettings, where update_settings
    userSettings writes it), the top-level effortLevel, the model's default (finding 11)."""
    settings = effective()
    model = current_model()
    per_model = (settings.get('modelSettings') or {}).get(model) or {}
    return FLAG_SETTINGS.get('effortLevel') or option('--effort') or per_model.get('effortLevel') \
        or settings.get('effortLevel') or DEFAULT_EFFORT.get(model, 'high')


def applied():
    ultra = 'ultra' in MODEL_KNOBS
    return {'model': current_model(), 'effort': current_effort(), 'advisor': None,
            'ultracode': bool(ultra and FLAG_SETTINGS.get('ultracode')),
            'ultracodeRequested': bool(ultra and FLAG_SETTINGS.get('ultracode')), 'ultracodeAvailable': ultra,
            'ultrathinkAvailable': False}


def get_settings():
    """get_settings' answer (finding 11): errors only when there are some (FAKE_CLAUDE_SETTINGS_ERROR: one,
    {path, message} as the CLI's schema names them; the text is unrecorded)."""
    answer = {'effective': effective(), 'sources': settings_sources(), 'served_settings_state': 'ineligible',
              'applied': applied()}
    if ENV.get('FAKE_CLAUDE_SETTINGS_ERROR'):
        answer['errors'] = [{'path': os.path.join(CWD, '.claude', 'settings.json'),
                             'message': ENV['FAKE_CLAUDE_SETTINGS_ERROR']}]
    return answer


# update_settings (finding 12): the keys each source takes, as far as recorded; any other key is refused
UPDATABLE = {'localSettings': {'outputStyle'}, 'userSettings': {'effortLevel'}}


def update_settings(source, settings):
    """None when done, else the CLI's error text. userSettings' effortLevel goes to modelSettings.<model>."""
    if source not in UPDATABLE:
        return 'update_settings: unsupported source %s' % source
    refused = [key for key in settings if key not in UPDATABLE[source]]
    if refused:
        return 'update_settings keys not allowed: %s' % ', '.join(refused)
    path = dict((s, p) for s, p in [('userSettings', os.path.join(config_dir(), 'settings.json')),
                                    ('localSettings', os.path.join(CWD, '.claude', 'settings.local.json'))])[source]
    current = read_settings(path) or {}
    for key, value in settings.items():
        if source == 'userSettings' and key == 'effortLevel':
            current.setdefault('modelSettings', {}).setdefault(current_model(), {})['effortLevel'] = value
        else:
            current[key] = value
    write_settings(path, current)
    return None


def write_settings(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + '.tmp', 'w', encoding='utf-8') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')
    os.replace(path + '.tmp', path)


def now_iso():
    return time.strftime('%Y-%m-%dT%H:%M:%S.000Z', time.gmtime())


if RESUME is not None and (ENV.get('FAKE_CLAUDE_RESUME') == 'unknown'
                           or not os.path.exists(os.path.join(PROJECTS, RESUME + '.jsonl'))):
    # 11-resume-unknown-id: no initialize answer, one result, EOF, status 1
    emit({'type': 'result', 'subtype': 'error_during_execution', 'duration_ms': 0, 'duration_api_ms': 0,
          'is_error': True, 'num_turns': 0, 'stop_reason': None, 'session_id': RESUME,
          'total_cost_usd': 0, 'usage': usage(), 'modelUsage': {}, 'permission_denials': [],
          'uuid': str(uuid.uuid4()), 'errors': ['No conversation found with session ID: ' + RESUME]})
    sys.stderr.write('No conversation found with session ID: %s\n' % RESUME)
    sys.stdout.flush()
    time.sleep(int(ENV.get('FAKE_CLAUDE_LINGER_MS', '0')) / 1000)
    log(exit=1)
    sys.exit(1)
if SID is not None and RESUME is not None and not FORK:
    sys.stderr.write('Error: --session-id can only be used with --resume if --fork-session is also specified.\n')
    log(exit=1)
    sys.exit(1)
if SID is not None and not re.fullmatch(r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
                                        SID):
    # `--session-id <uuid>`: "must be a valid UUID" (claude --help 2.1.330)
    sys.stderr.write('Error: Invalid session ID. Must be a valid UUID.\n')
    log(exit=1)
    sys.exit(1)
if SID is None:
    SID = str(uuid.uuid4()) if RESUME is None or FORK else RESUME
TRANSCRIPT = os.path.join(PROJECTS, SID + '.jsonl')
FORK_DUE = [RESUME is not None and FORK]    # a copy whose file is not written yet


def fork_copy():
    """A copy: the source's records under the new id (07b-fork's transcript holds the whole history)."""
    if not FORK_DUE[0]:
        return
    FORK_DUE[0] = False
    os.makedirs(PROJECTS, exist_ok=True)
    with open(os.path.join(PROJECTS, RESUME + '.jsonl'), encoding='utf-8') as src, \
            open(TRANSCRIPT, 'a', encoding='utf-8') as dst:
        for line in src:
            if not line.strip():
                continue
            record = json.loads(line)
            if 'sessionId' in record:
                record['sessionId'] = SID
            dst.write(json.dumps(record, ensure_ascii=False) + '\n')


if not ENV.get('FAKE_CLAUDE_FORK_LATE'):
    fork_copy()


def register():
    os.makedirs(os.path.dirname(RECORD), exist_ok=True)
    with open(RECORD + '.tmp', 'w', encoding='utf-8') as stream:
        json.dump({'pid': os.getpid(), 'sessionId': SID, 'cwd': CWD, 'startedAt': int(START * 1000),
                   'procStart': time.strftime('%a %b %d %H:%M:%S %Y', time.localtime(START)),
                   'version': '2.1.330', 'peerProtocol': 1, 'kind': 'interactive',
                   'entrypoint': ENV.get('CLAUDE_CODE_ENTRYPOINT') or 'sdk-cli',
                   'pidDomain': 'darwin' if sys.platform == 'darwin' else 'linux', 'status': 'idle'}, stream)
    os.replace(RECORD + '.tmp', RECORD)


# a SIGTERM ends it as a crash: the recordings show the record removed only on a clean exit (C7), so the
# fake keeps it (conservative for rhun's holder reads; Task 12's live run checks the real CLI)
LATE_USER = []                      # FAKE_CLAUDE_USER_LATE_MS: the user line not yet in the transcript
MUTE = threading.Event()            # `mute`: a SIGTERM is ignored


def terminated(*_):
    if MUTE.is_set():
        return
    if LATE_USER:                   # recorded as it stops (once: the group and the pid both get the signal)
        time.sleep(int(ENV['FAKE_CLAUDE_USER_LATE_MS']) / 1000)
        if LATE_USER:
            transcript(LATE_USER.pop())
    crash(143)


signal.signal(signal.SIGTERM, terminated)
register()


def transcript(record):
    fork_copy()
    os.makedirs(PROJECTS, exist_ok=True)
    record = dict(record, sessionId=SID, cwd=CWD, uuid=str(uuid.uuid4()), timestamp=now_iso())
    with open(TRANSCRIPT, 'a', encoding='utf-8') as stream:
        stream.write(json.dumps(record, ensure_ascii=False) + '\n')


PENDING = {}                        # can_use_tool ids: None until rhun answers
NEXT_ID = [7]                       # FAKE_CLAUDE_NUMERIC_IDS: the next numeric request id


def request_id():
    """A can_use_tool request id: a UUID string as the CLI sends (02), or with FAKE_CLAUDE_NUMERIC_IDS a number
    (7, 8, ...; unrecorded: JSON-RPC peers use numbers, and rhun must echo one as a number)."""
    if not ENV.get('FAKE_CLAUDE_NUMERIC_IDS'):
        return str(uuid.uuid4())
    with LOCK:
        NEXT_ID[0] += 1
        return NEXT_ID[0] - 1
QUEUE = []                          # prompts not started
BUSY = [False]
INTERRUPT = threading.Event()       # the turn running was interrupted
ACKED = threading.Event()           # the interrupt's control_response went out
DEAF = threading.Event()            # this turn ignores interrupts
RACING = []                         # the message id of a turn that ends as the interrupt arrives


# Every record below keeps the field order of the recordings (tests/data/claude-shapes/keys.txt; the
# fake may leave fields out, never add or reorder them): tests/fake-claude.py checks each one.

def stream_event(event, **extra):
    """extra: the top-level fields after uuid (ttft_ms, thinking_display)."""
    emit(dict({'type': 'stream_event', 'event': event, 'session_id': SID, 'parent_tool_use_id': None,
               'uuid': str(uuid.uuid4())}, **extra))


def status(state, mode=None):
    """system/status: the turn's "requesting", or a permission mode change (status null)."""
    if mode is None:
        emit({'type': 'system', 'subtype': 'status', 'status': state, 'session_id': SID, 'uuid': str(uuid.uuid4())})
    else:
        emit({'type': 'system', 'subtype': 'status', 'status': state, 'permissionMode': mode,
              'uuid': str(uuid.uuid4()), 'session_id': SID})


def thinking_tokens(estimate, delta):
    emit({'type': 'system', 'subtype': 'thinking_tokens', 'estimated_tokens': estimate,
          'estimated_tokens_delta': delta, 'session_id': SID, 'uuid': str(uuid.uuid4())})


def message_start():
    mid = 'msg_fake' + uuid.uuid4().hex[:16]
    stream_event({'type': 'message_start', 'message': {
        'model': current_model(), 'id': mid, 'type': 'message', 'role': 'assistant', 'content': [],
        'stop_reason': None, 'usage': usage()}}, ttft_ms=5, thinking_display='updates')
    return mid


def message_end(stop='end_turn'):
    stream_event({'type': 'message_delta', 'delta': {'stop_reason': stop, 'stop_sequence': None}, 'usage': usage()})
    stream_event({'type': 'message_stop'})


def assistant(mid, block, save=True, **extra):
    """The consolidated record of one block (C3): same message id, one block, no index. save=False: not in
    the transcript (yet)."""
    emit(dict({'type': 'assistant', 'message': {
        'model': current_model(), 'id': mid, 'type': 'message', 'role': 'assistant', 'content': [block],
        'stop_reason': None, 'usage': usage()}, 'parent_tool_use_id': None, 'session_id': SID,
        'uuid': str(uuid.uuid4())}, **extra))
    if save and block['type'] != 'thinking':
        transcript({'type': 'assistant', 'message': {'id': mid, 'role': 'assistant', 'model': current_model(),
                                                     'content': [block]}})


def withdrawn():
    """A request waiting for rhun ends: an interrupt withdrew it, or stdin closed (nobody can answer)."""
    return (INTERRUPT.is_set() and not DEAF.is_set()) or CLOSED.is_set()


def interrupted_now():
    if INTERRUPT.is_set() and not DEAF.is_set():
        ACKED.wait(5)               # 05: the interrupt's answer comes before the cut-off records
        return True
    return False


def text(mid, index, pieces, delay=0.0):
    """A text block; False when an interrupt cut it (the partial then went out with aborted: true, C9)."""
    stream_event({'type': 'content_block_start', 'index': index, 'content_block': {'type': 'text', 'text': ''}})
    sent = ''
    for piece in pieces:
        if interrupted_now():
            assistant(mid, {'type': 'text', 'text': sent}, aborted=True)
            CUT.append((mid, index))
            return False
        stream_event({'type': 'content_block_delta', 'index': index, 'delta': {'type': 'text_delta', 'text': piece}})
        sent += piece
        time.sleep(delay)
    assistant(mid, {'type': 'text', 'text': sent})
    stream_event({'type': 'content_block_stop', 'index': index})
    return True


def thirds(words):
    a, b = len(words) // 3, 2 * len(words) // 3
    return [piece for piece in (words[:a], words[a:b], words[b:]) if piece]


def thinking(mid, index, estimates=True):
    """05's thinking block: no text, an estimate in system/thinking_tokens (C8); estimates=False: none (a
    short thought, as 02's closing message in 2.1.330)."""
    stream_event({'type': 'content_block_start', 'index': index,
                  'content_block': {'type': 'thinking', 'thinking': '', 'signature': ''}}, thinking_display='updates')
    if estimates:
        thinking_tokens(50, 50)
    stream_event({'type': 'content_block_delta', 'index': index, 'delta': {'type': 'thinking_delta', 'thinking': ''}},
                 thinking_display='updates')
    if estimates:
        thinking_tokens(243, 193)
    stream_event({'type': 'content_block_delta', 'index': index,
                  'delta': {'type': 'signature_delta', 'signature': 'c2lnbmF0dXJl'}})
    assistant(mid, {'type': 'thinking', 'thinking': '', 'signature': 'c2lnbmF0dXJl'})
    stream_event({'type': 'content_block_stop', 'index': index})


def tool_use(mid, index, name, tool_input):
    tid = 'toolu_fake' + uuid.uuid4().hex[:16]
    stream_event({'type': 'content_block_start', 'index': index, 'content_block': {
        'type': 'tool_use', 'id': tid, 'name': name, 'input': {}, 'caller': {'type': 'direct'}}})
    raw = json.dumps(tool_input, ensure_ascii=False)
    for piece in ('', raw[:len(raw) // 2], raw[len(raw) // 2:]):
        stream_event({'type': 'content_block_delta', 'index': index,
                      'delta': {'type': 'input_json_delta', 'partial_json': piece}})
    assistant(mid, {'type': 'tool_use', 'id': tid, 'name': name, 'input': tool_input, 'caller': {'type': 'direct'}})
    stream_event({'type': 'content_block_stop', 'index': index})
    return tid


def user(block, **extra):
    emit(dict({'type': 'user', 'message': {'role': 'user', 'content': [block]}, 'parent_tool_use_id': None,
               'session_id': SID, 'uuid': str(uuid.uuid4()), 'timestamp': now_iso()}, **extra))
    transcript({'type': 'user', 'message': {'role': 'user', 'content': [block]}})


def tool_result(tid, content, is_error=False, interactive=False, plain=False):
    """The tool's result as the recordings order it: a failure (02 deny, 06 rejection) type, content,
    is_error, tool_use_id; AskUserQuestion and ExitPlanMode (03, 04) type, content, tool_use_id; Bash
    (02, 10) tool_use_id, type, content, is_error; Edit and WebFetch (plain: shape 16-edit) tool_use_id, type, content."""
    if is_error:
        block = {'type': 'tool_result', 'content': content, 'is_error': True, 'tool_use_id': tid}
    elif interactive:
        block = {'type': 'tool_result', 'content': content, 'tool_use_id': tid}
    elif plain:
        block = {'tool_use_id': tid, 'type': 'tool_result', 'content': content}
    else:
        block = {'tool_use_id': tid, 'type': 'tool_result', 'content': content, 'is_error': False}
    user(block)


SESSION_RULES = []                  # allow rules saved with destination "session" (this process only)


def rule_allows(tool, content):
    """An allow rule lets the call run without asking: Tool, Tool(content) or Tool(prefix:*), from the
    session or the permissions.allow of a settings file the sources let in (finding 15)."""
    rules = list(SESSION_RULES)
    for source in settings_sources():
        allow = (source['settings'].get('permissions') or {}).get('allow') or []
        rules += [rule for rule in allow if isinstance(rule, str)]
    for rule in rules:
        if rule == tool:
            return True
        if rule.startswith(tool + '(') and rule.endswith(')'):
            inner = rule[len(tool) + 1:-1]
            if inner == content or (inner.endswith(':*') and content.startswith(inner[:-2])):
                return True
    return False


RULE_FILES = {'localSettings': lambda: os.path.join(CWD, '.claude', 'settings.local.json'),
              'projectSettings': lambda: os.path.join(CWD, '.claude', 'settings.json'),
              'userSettings': lambda: os.path.join(config_dir(), 'settings.json')}


def apply_updates(answer):
    """An allow's updatedPermissions as the CLI applies them (findings 15, 16): addRules into the destination's file
    (permissions.allow "Tool(content)"), or the session's; a setMode changes the mode (its status line
    follows); bypassPermissions only where set_permission_mode would take it; addDirectories: nothing."""
    global MODE
    for update in answer.get('updatedPermissions') or []:
        if not isinstance(update, dict):
            continue
        dest = update.get('destination')
        if update.get('type') == 'addRules' and update.get('behavior') == 'allow':
            texts = ['%s(%s)' % (r.get('toolName'), r['ruleContent']) if r.get('ruleContent') else r.get('toolName')
                     for r in update.get('rules') or []]
            if dest in ('session', 'cliArg'):
                SESSION_RULES.extend(texts)
            elif dest in RULE_FILES:
                path = RULE_FILES[dest]()
                current = read_settings(path) or {}
                allow = current.setdefault('permissions', {}).setdefault('allow', [])
                allow += [t for t in texts if t not in allow]
                write_settings(path, current)
        elif update.get('type') == 'setMode':
            mode = update.get('mode')
            if mode == 'bypassPermissions' and not BYPASS_OK:
                continue
            if mode and mode != MODE:
                MODE = mode
                status(None, MODE)


REJECTED = ("The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a "
            "file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the "
            "user to tell you how to proceed.")


def blocked_path(command):
    """02/06's blocked_path: the file the command touches (the project directory for other commands)."""
    return os.path.join(CWD, command[6:].strip()) if command.startswith('touch ') else CWD


def bash_request(tool_input, tid, suggestions):
    """A Bash can_use_tool request (02's field order)."""
    return {'subtype': 'can_use_tool', 'tool_name': 'Bash', 'display_name': 'Bash', 'input': tool_input,
            'description': tool_input.get('description', ''), 'permission_suggestions': suggestions,
            'blocked_path': blocked_path(tool_input['command']), 'tool_use_id': tid}


def can_use_tool(name, tool_input, tid, suggestions=None):
    """Asks rhun (02, 03, 04); its answer, or None when an interrupt withdrew the request (06) or stdin
    closed. Without suggestions it is an interactive tool's request (03, 04)."""
    rid = request_id()
    if suggestions is None:
        request = {'subtype': 'can_use_tool', 'tool_name': name, 'display_name': name, 'input': tool_input,
                   'tool_use_id': tid, 'requires_user_interaction': True}
    else:
        request = bash_request(tool_input, tid, suggestions)
    with COND:
        PENDING[rid] = None
        emit({'type': 'control_request', 'request_id': rid, 'request': request})
        while rid in PENDING and PENDING[rid] is None and not withdrawn():
            COND.wait(0.05)
        answer = PENDING.pop(rid, None)
    if answer is None and not CLOSED.is_set():
        ACKED.wait(5)
    return answer


DENIALS = []                        # this turn's denied tool calls (02's result.permission_denials)


TURN_UUID = [None]                  # the uuid of the user message whose turn runs (None: it had none)


def model_usage(cache=None):
    entry = {'inputTokens': 6, 'outputTokens': 12, 'contextWindow': 1000000, 'maxOutputTokens': 128000}
    if cache:
        entry = {'inputTokens': 6, 'outputTokens': 12, 'cacheReadInputTokens': cache[1],
                 'cacheCreationInputTokens': cache[0], 'contextWindow': 1000000, 'maxOutputTokens': 128000,
                 'cacheCreationEphemeral5mInputTokens': 0, 'cacheCreationEphemeral1hInputTokens': cache[0]}
    return {current_model() + '[1m]': entry}


def result(final='', subtype='success', errors=None, stop='end_turn', terminal='completed', spent=True, cache=None):
    """A turn's result, in the recordings' field order (type comes late). spent=False: no model call
    finished (total_cost_usd 0, modelUsage {}: `unsaved`); 2.1.330's interrupted turns (05, 06) did spend.
    The turn's message uuid is user_message_uuid (finding 17): before type in an error, after uuid in a success."""
    record = {'duration_api_ms': 10, 'stop_reason': stop, 'session_id': SID, 'total_cost_usd': 0.0 if spent else 0,
              'usage': usage(cache), 'modelUsage': model_usage(cache) if spent else {},
              'permission_denials': list(DENIALS), 'terminal_reason': terminal, 'fast_mode_state': FAST[0],
              'is_error': subtype != 'success', 'num_turns': 1, 'subtype': subtype}
    if errors is None:
        record['result'] = final
    else:
        record['errors'] = errors
        if TURN_UUID[0]:
            record['user_message_uuid'] = TURN_UUID[0]
    record.update(type='result', duration_ms=20, uuid=str(uuid.uuid4()))
    if errors is None and TURN_UUID[0]:
        record['user_message_uuid'] = TURN_UUID[0]
    if ENV.get('FAKE_CLAUDE_RATE'):
        rate_limit(ENV['FAKE_CLAUDE_RATE'])
    emit(record)


def rate_limit(kind):
    """A rate_limit_event before the result (as the recordings place it, finding 20). kind: warning (85 % of
    the five-hour window used), rejected (all of it), else allowed. The recorded event of 2.1.330 had
    status, resetsAt, rateLimitType, overage fields and unifiedWindows; utilization at the top is the
    schema's (ext-host-protocol 2.6), unrecorded."""
    resets = int(time.time()) + 3600
    status_, used = {'warning': ('allowed_warning', 0.85), 'rejected': ('rejected', 1.0)}.get(kind, ('allowed', 0.2))
    emit({'type': 'rate_limit_event', 'rate_limit_info': {
        'status': status_, 'resetsAt': resets, 'rateLimitType': 'five_hour', 'utilization': used,
        'isUsingOverage': False,
        'unifiedWindows': {'five_hour': {'utilization': used, 'resetsAt': resets, 'status': status_}}},
        'uuid': str(uuid.uuid4()), 'session_id': SID})


CUT = []                            # (message id, block index) of the text block an interrupt cut


def cut_off(tool_turn=False):
    """What the CLI sends after an interrupt cut a turn (05, 06); its next EOF exits with status 1 (C9).
    A cut stream is closed after the interrupt mark (05, 2.1.330): its block's stop, a message_delta without
    a stop reason (fields in another order) and a message_stop naming the blocks it abandoned."""
    user({'type': 'text', 'text': '[Request interrupted by user for tool use]' if tool_turn
          else '[Request interrupted by user]'})
    if CUT:
        mid, index = CUT.pop()
        stream_event({'type': 'content_block_stop', 'index': index})
        stream_event({'type': 'message_delta', 'context_management': None,
                      'delta': {'container': None, 'stop_details': None, 'stop_reason': None, 'stop_sequence': None},
                      'usage': usage()})
        stream_event({'type': 'message_stop'}, abandoned_blocks={'api_message_id': mid, 'from_block_index': index + 1})
    stop = 'tool_use' if tool_turn else None
    result(subtype='error_during_execution', stop=stop, terminal='aborted_tools' if tool_turn else 'aborted_streaming',
           errors=['[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=%s' % (stop or 'null')])
    EXIT_STATUS[0] = 1


def final(words, delay=0.0):
    mid = message_start()
    if text(mid, 0, thirds(words), delay):
        message_end()
        result(words)
    else:
        cut_off()


def suggestions(command):
    """02's permission_suggestions: a rule for the command, the directory, acceptEdits."""
    return [{'type': 'addRules', 'rules': [{'toolName': 'Bash', 'ruleContent': command}], 'behavior': 'allow',
             'destination': 'localSettings'},
            {'type': 'addDirectories', 'directories': [CWD], 'destination': 'session'},
            {'type': 'setMode', 'mode': 'acceptEdits', 'destination': 'session'}]


def bash(command, ask=True, extra=None, rules=None):
    """One Bash call in its own message, as 02 has them; False when an interrupt cut the turn. extra: more
    input fields; rules: the suggestions in place of 02's."""
    mid = message_start()
    tool_input = dict({'command': command, 'description': 'Run ' + command}, **(extra or {}))
    tid = tool_use(mid, 0, 'Bash', tool_input)
    message_end('tool_use')
    if not ENV.get('FAKE_CLAUDE_RATE'):     # with the knob, result() sends its own
        emit({'type': 'rate_limit_event', 'rate_limit_info': {'status': 'allowed', 'rateLimitType': 'five_hour'},
              'uuid': str(uuid.uuid4()), 'session_id': SID})
    if ask and (rule_allows('Bash', command) or MODE == 'bypassPermissions'):
        ask = False                 # a saved rule lets it run (finding 15: the same command again did not ask)
    answer = can_use_tool('Bash', tool_input, tid, rules or suggestions(command)) if ask else {'behavior': 'allow'}
    if answer is not None and ask:
        log(answer=answer)
        if answer.get('behavior') == 'allow':
            apply_updates(answer)
    bash_result(tid, tool_input, answer)
    # withdrawn, or a deny that interrupts: the turn ends there (the real 2.1.330, given rhun's No: the
    # rejected tool_result, "[Request interrupted by user for tool use]", result aborted_tools)
    if answer is None or (answer.get('behavior') == 'deny' and answer.get('interrupt') is True):
        cut_off(tool_turn=True)
        return False
    return True


def bash_result(tid, tool_input, answer):
    """The tool_result of a Bash call once rhun answered (None: the request was withdrawn, 06)."""
    if answer is None:
        tool_result(tid, REJECTED, True)
    elif answer.get('behavior') == 'allow':
        # the command that runs is the answer's (finding 15: an edited command ran in place of the asked one)
        ran = answer.get('updatedInput') if isinstance(answer.get('updatedInput'), dict) else tool_input
        command = ran.get('command') if isinstance(ran.get('command'), str) else tool_input['command']
        if command.startswith('touch '):
            open(os.path.join(CWD, command[6:].strip()), 'a').close()
        tool_result(tid, '(Bash completed with no output)')
    else:
        DENIALS.append({'tool_name': 'Bash', 'tool_use_id': tid, 'tool_input': tool_input})
        tool_result(tid, answer.get('message', ''), True)


def interactive(name, tool_input):
    """AskUserQuestion and ExitPlanMode. AskUserQuestion's request comes before its message ends, and
    when the answer is quick (as in tests) the tool's result does too: the caller sends the result, then
    message_end() (03, 2.1.330; 2.1.289 had the answer come after message_stop). ExitPlanMode's request
    comes after the message ended (the plan case of 2.1.330), as a Bash call's."""
    mid = message_start()
    tid = tool_use(mid, 0, name, tool_input)
    if name == 'ExitPlanMode':
        message_end('tool_use')
    answer = can_use_tool(name, tool_input, tid)
    if answer is None:
        tool_result(tid, REJECTED, True)
        cut_off(tool_turn=True)
        return tid, None
    log(answer=answer)
    return tid, answer


QUESTIONS_ONE = [{'question': 'Which color do you prefer?', 'header': 'Color', 'multiSelect': False,
                  'options': [{'label': 'Red', 'description': 'The color red'},
                              {'label': 'Blue', 'description': 'The color blue'}]}]
QUESTIONS_TWO = [{'question': 'Which language?', 'header': 'Language', 'multiSelect': False,
                  'options': [{'label': 'Python', 'description': 'Scripts'}, {'label': 'Go', 'description': 'Services'},
                              {'label': 'Rust', 'description': 'Systems'}]},
                 {'question': 'Which tools?', 'header': 'Tools', 'multiSelect': True,
                  'options': [{'label': 'git', 'description': ''}, {'label': 'make', 'description': ''},
                              {'label': 'docker', 'description': ''}]}]


def s_plain(prompt):
    final('ok: ' + prompt)


def s_tool(prompt):
    """tool [COMMAND]: one Bash call that asks (default touch approved.txt)"""
    words = prompt.split(None, 1)
    if bash(words[1] if len(words) > 1 else 'touch approved.txt'):
        final('done')


def s_tool2(prompt):
    """02-permission: two Bash calls, each asking; the closing message thinks first (as 2.1.330's did)"""
    if bash('touch approved.txt') and bash('touch denied.txt'):
        mid = message_start()
        thinking(mid, 0, estimates=False)
        if text(mid, 1, ['do', 'ne']):
            message_end()
            result('done')
        else:
            cut_off()


def s_auto(prompt):
    """10-auto-mode-bash: a tool that runs without asking"""
    if bash('touch auto.txt', ask=False):
        final('done')


def s_ran(prompt):
    """a tool that runs without asking (as 10), then 1.5 s before the reply: a test looks at the rows"""
    if bash('touch ran.txt', ask=False):
        time.sleep(1.5)
        final('done')


def s_fails(prompt):
    """a Bash call whose result is an error (02's failure shape), then 1.5 s before the reply"""
    mid = message_start()
    tid = tool_use(mid, 0, 'Bash', {'command': 'false', 'description': 'Fail'})
    message_end('tool_use')
    tool_result(tid, 'Exit code 1', True)
    time.sleep(1.5)
    final('done')


MCP_TOOL = 'mcp__a_server_with_a_long_name__a_tool_whose_name_runs_past_sixty_four_bytes'


def s_mcp(prompt):
    """an MCP tool (a name longer than 64 bytes) that runs without asking, then 1.5 s before the reply"""
    mid = message_start()
    tid = tool_use(mid, 0, MCP_TOOL, {'query': 'weather'})
    message_end('tool_use')
    tool_result(tid, 'sunny')
    time.sleep(1.5)
    final('done')


def s_noid(prompt):
    """two tool_use blocks without an id and a result without a tool_use_id (shapes no recording has: the
    fake leaves the fields out), then 1.5 s before the reply"""
    mid = message_start()
    for index, command in enumerate(('echo one', 'echo two')):
        stream_event({'type': 'content_block_start', 'index': index, 'content_block': {
            'type': 'tool_use', 'name': 'Bash', 'input': {}, 'caller': {'type': 'direct'}}})
        assistant(mid, {'type': 'tool_use', 'name': 'Bash', 'input': {'command': command},
                        'caller': {'type': 'direct'}})
        stream_event({'type': 'content_block_stop', 'index': index})
    message_end('tool_use')
    user({'type': 'tool_result', 'content': 'one', 'is_error': False})
    time.sleep(1.5)
    final('done')


def s_pending(prompt):
    """06: a permission left unanswered until an interrupt withdraws it"""
    if bash('touch pending.txt'):
        final('done')


def s_ask(prompt, questions=QUESTIONS_ONE, extra=None):
    """03-ask-user-question; the final text is the answers rhun sent, as sorted JSON. extra: more input
    fields after the questions"""
    tid, answer = interactive('AskUserQuestion', dict({'questions': questions}, **(extra or {})))
    if answer is None:
        return
    if answer.get('behavior') != 'allow':
        tool_result(tid, answer.get('message', ''), True)
        message_end('tool_use')
        final('skipped')
        return
    answers = answer.get('updatedInput', {}).get('answers', {})
    log(questions_kept=answer.get('updatedInput', {}).get('questions') == questions)
    tool_result(tid, 'Your questions have been answered: ' + ', '.join(
        '"%s"="%s"' % pair for pair in answers.items()) + '. You can now continue with these answers in mind.',
                interactive=True)
    message_end('tool_use')
    final(json.dumps(answers, sort_keys=True))


def s_ask2(prompt):
    """two questions, the second multi-select"""
    s_ask(prompt, QUESTIONS_TWO)


def s_askx(prompt):
    """an AskUserQuestion input with fields besides its questions, stale answers among them (no recording
    has one): a reply keeps the others and sets the answers"""
    s_ask(prompt, QUESTIONS_ONE, {'answers': {'Which color do you prefer?': 'Green'}, 'note': 'kept'})


def nested(depth):
    value = 'end'
    for _ in range(depth):
        value = [value]
    return value


def s_deep(prompt):
    """deep [rule]: a Bash call whose input (with rule: whose addRules suggestion) nests 70 levels deep (no
    recording has one): more than rhun's JSON writer echoes"""
    command = 'touch deep.txt'
    if prompt.split()[1:2] == ['rule']:
        rules = suggestions(command)
        rules[0]['rules'][0]['nested'] = nested(70)
        done = bash(command, rules=rules)
    else:
        done = bash(command, extra={'nested': nested(70)})
    if done:
        final('done')


def s_withdraw(prompt):
    """a permission Claude takes back by itself after a second, unanswered (unrecorded: the recordings show
    control_cancel_request only after an interrupt, 06); the call is rejected and, 1.5 s later, the turn ends
    normally"""
    mid = message_start()
    command = 'touch withdrawn.txt'
    tool_input = {'command': command, 'description': 'Run ' + command}
    tid = tool_use(mid, 0, 'Bash', tool_input)
    message_end('tool_use')
    rid = request_id()
    deadline = time.time() + 1
    with COND:
        PENDING[rid] = None
        emit({'type': 'control_request', 'request_id': rid,
              'request': bash_request(tool_input, tid, suggestions(command))})
        while PENDING.get(rid) is None and not withdrawn() and time.time() < deadline:
            COND.wait(0.05)
        answer = PENDING.pop(rid, None)
        if answer is None and not CLOSED.is_set():
            emit({'type': 'control_cancel_request', 'request_id': rid})
    if answer is not None:
        log(answer=answer)
    bash_result(tid, tool_input, answer)
    if answer is None:
        time.sleep(1.5)             # a test looks at the rejected call's row meanwhile
    final('done')


def s_plan(prompt):
    """04-plan-mode's ExitPlanMode; the final text names the mode it ends in"""
    global MODE
    plan = '# Plan\n\n1. Add the file\n2. Test it'
    path = os.path.join(config_dir(), 'plans', 'fake.md')
    PLAN[0] = {'content': plan, 'path': path}     # get_plan's answer from here on (finding 24)
    tid, answer = interactive('ExitPlanMode', {'plan': plan, 'planFilePath': path})
    if answer is None:
        return
    if answer.get('behavior') != 'allow':
        tool_result(tid, answer.get('message', ''), True)
        final('planning')
        return
    modes = [p.get('mode') for p in answer.get('updatedPermissions') or [] if p.get('type') == 'setMode']
    MODE = modes[0] if modes else 'default'
    status(None, MODE)
    tool_result(tid, 'User has approved your plan. You can now start coding.', interactive=True)
    final('approved ' + MODE)


def s_slow(prompt):
    """05-interrupt: thinking, then a long text an interrupt cuts"""
    mid = message_start()
    thinking(mid, 0)
    if text(mid, 1, ['word%d ' % i for i in range(60)], 0.1):
        message_end()
        result('finished')
    else:
        cut_off()


def s_think(prompt):
    """thinking, then a short text"""
    mid = message_start()
    thinking(mid, 0)
    if text(mid, 1, ['thought ', 'about ', 'it']):
        message_end()
        result('thought about it')


def s_early(prompt):
    """thinking whose first estimate comes before its block starts, then an estimate without its number;
    1.5 s before the text"""
    mid = message_start()
    thinking_tokens(120, 120)
    stream_event({'type': 'content_block_start', 'index': 0,
                  'content_block': {'type': 'thinking', 'thinking': '', 'signature': ''}}, thinking_display='updates')
    emit({'type': 'system', 'subtype': 'thinking_tokens', 'estimated_tokens_delta': 0, 'session_id': SID,
          'uuid': str(uuid.uuid4())})
    assistant(mid, {'type': 'thinking', 'thinking': '', 'signature': 'c2lnbmF0dXJl'})
    stream_event({'type': 'content_block_stop', 'index': 0})
    time.sleep(1.5)
    if text(mid, 1, ['early']):
        message_end()
        result('early')


def s_replay(prompt):
    """a user line Claude replays (isReplay: string content in the order 01 recorded for set_model's), here
    an interrupt mark of an earlier turn; 1.5 s before the reply"""
    emit({'type': 'user', 'message': {'role': 'user', 'content': '[Request interrupted by user]'}, 'session_id': SID,
          'parent_tool_use_id': None, 'uuid': str(uuid.uuid4()), 'timestamp': now_iso(), 'isReplay': True})
    time.sleep(1.5)
    final('ok: replay')


def s_deaf(prompt):
    """an agent that does not stop: the interrupt gets no answer at all"""
    DEAF.set()
    mid = message_start()
    text(mid, 0, ['word%d ' % i for i in range(300)], 0.1)
    message_end()
    result('finished')


def racing_end(mid):
    """The end of the racing turn (with COND held). Its lines reach the transcript a second after the result
    (s_racing): a re-read at the result finds none of the turn."""
    assistant(mid, {'type': 'text', 'text': 'almost'}, save=False)
    stream_event({'type': 'content_block_stop', 'index': 0})
    message_end()
    result('almost')


def s_racing(prompt):
    """the turn ends as rhun interrupts it: the completion is already on its way (spec 11); the prompt and the
    reply are saved a second after the result (unrecorded timing)"""
    mid = message_start()
    deadline = time.time() + 30
    with COND:                      # the interrupt finds the turn it ends
        stream_event({'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}})
        stream_event({'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': 'almost'}})
        RACING.append(mid)
        # the stdin side ends the turn before it answers the interrupt; without one (stdin closed, or
        # 30 s) the turn ends by itself
        while mid in RACING and not CLOSED.is_set() and time.time() < deadline:
            COND.wait(0.05)
        if mid in RACING:
            RACING.remove(mid)
            racing_end(mid)
    time.sleep(1)
    transcript({'type': 'user', 'message': {'role': 'user', 'content': [{'type': 'text', 'text': prompt}]}})
    transcript({'type': 'assistant', 'message': {'id': mid, 'role': 'assistant', 'model': current_model(),
                                                 'content': [{'type': 'text', 'text': 'almost'}]}})


def s_unsaved(prompt):
    """a turn an interrupt ends before the prompt was saved (unrecorded: the recordings save it at once, 05):
    no transcript line, then 05's aborted result; "unsaved late": the prompt and the interrupt mark are saved
    a second after that result. Without an interrupt it is saved and answered after 30 s, or at once when
    stdin closes"""
    deadline = time.time() + 30
    with COND:
        while not INTERRUPT.is_set() and not CLOSED.is_set() and time.time() < deadline:
            COND.wait(0.05)
    if interrupted_now():
        if ENV.get('FAKE_CLAUDE_UNSAVED_MARK'):     # the mark is saved before the result reports the end
            transcript({'type': 'user', 'message': {'role': 'user', 'content': [
                {'type': 'text', 'text': '[Request interrupted by user]'}]}})
        result(subtype='error_during_execution', stop=None, terminal='aborted_streaming',
               errors=['[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=null'], spent=False)
        EXIT_STATUS[0] = 1
        if prompt.split()[1:2] == ['late'] and not ENV.get('FAKE_CLAUDE_UNSAVED_MARK'):
            time.sleep(1)
            for text in (prompt, '[Request interrupted by user]'):
                transcript({'type': 'user', 'message': {'role': 'user', 'content': [{'type': 'text', 'text': text}]}})
        return
    transcript({'type': 'user', 'message': {'role': 'user', 'content': [{'type': 'text', 'text': prompt}]}})
    final('ok: ' + prompt)


def s_subagent(prompt):
    """a Task call whose subagent streams under parent_tool_use_id"""
    mid = message_start()
    tid = tool_use(mid, 0, 'Task', {'description': 'look around', 'prompt': 'look'})
    message_end('tool_use')
    emit({'type': 'stream_event', 'event': {'type': 'message_start', 'message': {'id': 'msg_sub', 'content': []}},
          'session_id': SID, 'parent_tool_use_id': tid, 'uuid': str(uuid.uuid4())})
    emit({'type': 'stream_event', 'event': {'type': 'content_block_start', 'index': 0,
                                            'content_block': {'type': 'text', 'text': ''}},
          'session_id': SID, 'parent_tool_use_id': tid, 'uuid': str(uuid.uuid4())})
    emit({'type': 'stream_event', 'event': {'type': 'content_block_delta', 'index': 0,
                                            'delta': {'type': 'text_delta', 'text': 'subagent text'}},
          'session_id': SID, 'parent_tool_use_id': tid, 'uuid': str(uuid.uuid4())})
    emit({'type': 'assistant', 'message': {'id': 'msg_sub', 'role': 'assistant',
                                           'content': [{'type': 'text', 'text': 'subagent text'}]},
          'parent_tool_use_id': tid, 'session_id': SID, 'uuid': str(uuid.uuid4())})
    time.sleep(1.5)                 # a test looks at the conversation meanwhile
    tool_result(tid, 'looked')
    final('done')


def s_exit(prompt):
    """exit [MS]: the process dies mid-turn (MS after its text began: a message can be written meanwhile); a
    crash leaves its session record"""
    CRASH.set()
    message_start()
    stream_event({'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}})
    stream_event({'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': 'partial'}})
    wait = prompt.split()[1:2]
    if wait and wait[0].isdigit():
        time.sleep(int(wait[0]) / 1000)
    crash(2)


def s_mute(prompt):
    """a process that will not exit: it closes its stdout mid-turn, ignores SIGTERM and runs on for
    FAKE_CLAUDE_LINGER_MS (default 30 s); only a SIGKILL ends it before"""
    CRASH.set()
    message_start()
    MUTE.set()                      # (signal.signal works only in the main thread: the handler looks)
    with LOCK:
        sys.stdout.flush()
        os.close(1)
    time.sleep(int(ENV.get('FAKE_CLAUDE_LINGER_MS', '30000')) / 1000)
    crash(1)


def s_gone(prompt):
    """a permission request, while the process has closed its stdin (the main loop does that when it reads
    this prompt) and runs on for FAKE_CLAUDE_LINGER_MS (default 30 s) before it exits: rhun's answer finds
    no reader (unrecorded: the CLI closes its stdin only as it exits); "gone reply": a plain reply instead,
    so the next prompt finds no reader; "gone exit": the process exits once the request is out, while a
    process it started keeps its stdout open"""
    if prompt.split()[1:2] == ['reply']:
        final('ok: ' + prompt)
    else:
        bash('touch gone.txt')


def s_orphan(prompt):
    """a permission request the turn's result overtakes, never withdrawn (unrecorded: the CLI withdraws first,
    06): it waits a second for no answer, then the turn ends"""
    mid = message_start()
    command = 'touch orphan.txt'
    tool_input = {'command': command, 'description': 'Run ' + command}
    tid = tool_use(mid, 0, 'Bash', tool_input)
    message_end('tool_use')
    emit({'type': 'control_request', 'request_id': request_id(),
          'request': bash_request(tool_input, tid, suggestions(command))})
    time.sleep(1)                   # a test sees the card meanwhile
    tool_result(tid, REJECTED, True)
    final('done')


def s_big(prompt):
    """a permission request left waiting, then one record above rhun's 64 MiB limit; then it waits for rhun to
    let go and ends as a crash"""
    CRASH.set()
    mid = message_start()
    command = 'touch big.txt'
    tool_input = {'command': command, 'description': 'Run ' + command}
    tid = tool_use(mid, 0, 'Bash', tool_input)
    rid = request_id()
    with COND:
        PENDING[rid] = None
    emit({'type': 'control_request', 'request_id': rid, 'request': bash_request(tool_input, tid, suggestions(command))})
    stream_event({'type': 'content_block_delta', 'index': 0,
                  'delta': {'type': 'text_delta', 'text': 'x' * (65 << 20)}})
    CLOSED.wait(30)
    crash(1)


def s_error(prompt):
    """the API failed: the CLI's words are shown verbatim (spec 10)"""
    result(subtype='error_during_execution', stop=None, terminal='api_error',
           errors=['API Error: 529 {"type":"overloaded_error","message":"Overloaded"}'])


def s_autherr(prompt):
    """the CLI's credentials were refused (unrecorded: the shape of s_error with an authentication error's
    words, as the CLI prints an API error)"""
    result(subtype='error_during_execution', stop=None, terminal='api_error',
           errors=['Failed to authenticate. API Error: 401 {"type":"error","error":{"type":"authentication_error",'
                   '"message":"OAuth token has expired."}} \u00b7 Please run /login'])


def s_long(prompt):
    """a reply of 120 paragraphs, streamed in pieces (a thread taller than the panel)"""
    final(''.join('Paragraph %d of a long reply.\n\n' % i for i in range(120)), 0.05)


def s_stream(prompt):
    """stream [PIECES [MS]]: a tool that runs without asking, then a Markdown reply (headings, lists, code
    blocks) of PIECES deltas (default 2000), MS milliseconds apart (default 5): a long, fast stream"""
    words = prompt.split()
    pieces = int(words[1]) if len(words) > 1 else 2000
    delay = (int(words[2]) if len(words) > 2 else 5) / 1000
    if not bash('ls src', ask=False):
        return
    parts = []
    for i in range(pieces):
        section = i // 40
        step = i % 40
        if step == 0:
            parts.append('## Part %d\n\n' % section)
        elif step < 12:
            parts.append('the reader keeps each row ' if step % 2 else 'and measures it once. ')
        elif step == 12:
            parts.append('\n\n- a **list** item\n')
        elif step < 16:
            parts.append('- item %d of part %d\n' % (step, section))
        elif step == 16:
            parts.append('\n```python\n')
        elif step < 24:
            parts.append('def f%d_%d(x):\n    return x * %d\n' % (section, step, step))
        elif step == 24:
            parts.append('```\n\n')
        else:
            parts.append('more `code` text ' if step % 3 else 'and a sentence. ')
        if step == 39:
            parts.append('\n\n')
    mid = message_start()
    if text(mid, 0, parts, delay):
        message_end()
        result(''.join(parts))
    else:
        cut_off()


def s_wait(prompt):
    """a reply after a second"""
    time.sleep(1)
    final('ok: ' + prompt)


def s_many(prompt):
    """33 Bash calls in one message, each asking at once: rhun keeps 32 and declines one"""
    mid = message_start()
    calls = []
    for i in range(33):
        tool_input = {'command': 'touch many%d.txt' % i, 'description': 'many'}
        calls.append((tool_use(mid, i, 'Bash', tool_input), tool_input))
    message_end('tool_use')
    ids = []
    with COND:
        for tid, tool_input in calls:
            rid = request_id()
            PENDING[rid] = None
            ids.append(rid)
            emit({'type': 'control_request', 'request_id': rid, 'request': bash_request(tool_input, tid, [])})
        while not (withdrawn() or all(PENDING.get(rid) is not None for rid in ids)):
            COND.wait(0.05)
        answers = [PENDING.pop(rid, None) for rid in ids]
    log(many=[(a or {}).get('behavior') for a in answers])
    cut = INTERRUPT.is_set() or None in answers
    if cut and not CLOSED.is_set():
        ACKED.wait(5)               # 06: the interrupt's answer comes before the cut-off records
    for (tid, tool_input), answer in zip(calls, answers):
        bash_result(tid, tool_input, answer)    # one result per call; a withdrawn one is rejected (06)
    if cut:
        cut_off(tool_turn=True)
    else:
        final('done')


UNHANDLED = [   # control requests of the kinds rhun does not answer yet (ext-host-protocol 2.5; unrecorded)
    {'subtype': 'hook_callback', 'callback_id': 'hook_0', 'input': {'hook_event_name': 'PreToolUse'}},
    {'subtype': 'mcp_message', 'server_name': 'a_server', 'message': {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}},
    {'subtype': 'elicitation', 'mcp_server_name': 'a_server', 'message': 'Sign in?', 'mode': 'url',
     'url': 'https://example.com/sign-in', 'elicitation_id': 'e1'},
    {'subtype': 'request_user_dialog', 'dialog_kind': 'a_dialog', 'payload': {}},
    {'subtype': 'a_subtype_nobody_knows'}]


def s_unhandled(prompt):
    """the control requests of UNHANDLED, sent at once, each waiting for its answer; the answers are logged
    ({"unhandled": [...]}, an error reply as {"behavior": "error", "message": ...}), then the reply"""
    ids = []
    with COND:
        for request in UNHANDLED:
            rid = request_id()
            PENDING[rid] = None
            ids.append(rid)
            emit({'type': 'control_request', 'request_id': rid, 'request': request})
        while not (withdrawn() or all(PENDING.get(rid) is not None for rid in ids)):
            COND.wait(0.05)
        answers = [PENDING.pop(rid, None) for rid in ids]
    log(unhandled=answers)
    final('done')


def s_unknown(prompt):
    """what a newer CLI may send: a record type and a system subtype nobody knows and a line that is not
    JSON (ext-host-protocol 2.6: a reader ignores them), then the plain reply"""
    emit({'type': 'future_record', 'payload': {'kind': 'unknown'}, 'uuid': str(uuid.uuid4()), 'session_id': SID})
    emit({'type': 'system', 'subtype': 'future_subtype', 'detail': 'unknown', 'uuid': str(uuid.uuid4()),
          'session_id': SID})
    with LOCK:
        try:
            sys.stdout.write(NOT_JSON + '\n')
            sys.stdout.flush()
        except OSError:
            leave(1)
    final('ok: ' + prompt)


NOT_JSON = 'fake claude: a line that is not JSON'


def s_held(prompt):
    """held [think]: a 2 s turn, a text in 20 pieces (shapes 13 and 14; "think": a thinking block first, as shape 12's): a
    message written meanwhile is held"""
    mid = message_start()
    index = 0
    if prompt.split()[1:2] == ['think']:
        thinking(mid, 0, estimates=False)
        index = 1
    if text(mid, index, ['%d\n' % i for i in range(1, 21)], 0.1):
        message_end()
        result('counted')
    else:
        cut_off()


def s_usage(prompt):
    """a reply whose usage reports a prompt cache: 2000 tokens written for an hour, 30000 read (the split the
    CLI reports under usage.cache_creation and modelUsage, finding 21)"""
    mid = message_start()
    if text(mid, 0, ['cached']):
        message_end()
        result('cached', cache=(2000, 30000))
    else:
        cut_off()


def s_edit(prompt):
    """edit FILE: one Edit call (finding 16, shape 16-edit): the file's first line gets " (edited)"; it asks with the only
    suggestion 16 had (setMode acceptEdits, session) unless the mode or a rule lets edits run"""
    words = prompt.split(None, 1)
    path = os.path.join(CWD, words[1].strip() if len(words) > 1 else 'notes.txt')
    try:
        with open(path, encoding='utf-8') as stream:
            first = stream.read().split('\n', 1)[0]
    except OSError:
        first = ''
    tool_input = {'file_path': path, 'old_string': first, 'new_string': first + ' (edited)', 'replace_all': False}
    mid = message_start()
    tid = tool_use(mid, 0, 'Edit', tool_input)
    message_end('tool_use')
    if MODE in ('acceptEdits', 'bypassPermissions') or rule_allows('Edit', path):
        answer = {'behavior': 'allow'}
    else:
        rid = request_id()
        request = {'subtype': 'can_use_tool', 'tool_name': 'Edit', 'display_name': 'Edit', 'input': tool_input,
                   'description': os.path.basename(path),
                   'permission_suggestions': [{'type': 'setMode', 'mode': 'acceptEdits', 'destination': 'session'}],
                   'tool_use_id': tid}
        answer = ask_request(rid, request)
        if answer is None:
            tool_result(tid, REJECTED, True)
            cut_off(tool_turn=True)
            return
        log(answer=answer)
    if answer.get('behavior') == 'allow':
        apply_updates(answer)
        edit = answer.get('updatedInput') if isinstance(answer.get('updatedInput'), dict) else tool_input
        try:
            with open(path, encoding='utf-8') as stream:
                content = stream.read()
            with open(path, 'w', encoding='utf-8') as stream:
                stream.write(content.replace(edit.get('old_string', first), edit.get('new_string', ''), 1))
        except OSError:
            pass
        tool_result(tid, 'The file %s has been updated successfully.' % path, plain=True)
        final('edited')
        return
    DENIALS.append({'tool_name': 'Edit', 'tool_use_id': tid, 'tool_input': tool_input})
    tool_result(tid, answer.get('message', ''), True)
    if answer.get('interrupt') is True:
        cut_off(tool_turn=True)
    else:
        final('not edited')


def s_fetch(prompt):
    """fetch URL: one WebFetch call (unrecorded directly: 2.1.330 asked for it from a subagent, whose request
    also had agent_id); its suggestion is the recorded one, a domain rule for localSettings in the field
    order the CLI sent (type, destination, rules, behavior). Nothing is fetched: the result is made up"""
    words = prompt.split(None, 1)
    url = words[1].strip() if len(words) > 1 else 'https://example.com'
    domain = re.sub(r'^[a-z]+://', '', url).split('/')[0]
    tool_input = {'url': url, 'prompt': 'Report the title'}
    mid = message_start()
    tid = tool_use(mid, 0, 'WebFetch', tool_input)
    message_end('tool_use')
    if rule_allows('WebFetch', 'domain:' + domain):
        answer = {'behavior': 'allow'}
    else:
        request = {'subtype': 'can_use_tool', 'tool_name': 'WebFetch', 'display_name': 'WebFetch', 'input': tool_input,
                   'description': url,
                   'permission_suggestions': [{'type': 'addRules', 'destination': 'localSettings', 'rules': [
                       {'toolName': 'WebFetch', 'ruleContent': 'domain:' + domain}], 'behavior': 'allow'}],
                   'tool_use_id': tid}
        answer = ask_request(request_id(), request)
        if answer is None:
            tool_result(tid, REJECTED, True)
            cut_off(tool_turn=True)
            return
        log(answer=answer)
    if answer.get('behavior') == 'allow':
        apply_updates(answer)
        tool_result(tid, 'Fetched %s (HTTP 200 OK, text/html, 172 characters).\nExample Domain' % url, plain=True)
        final('Example Domain')
        return
    DENIALS.append({'tool_name': 'WebFetch', 'tool_use_id': tid, 'tool_input': tool_input})
    tool_result(tid, answer.get('message', ''), True)
    if answer.get('interrupt') is True:
        cut_off(tool_turn=True)
    else:
        final('not fetched')


def ask_request(rid, request):
    """Sends a can_use_tool request and waits for its answer (None: withdrawn or stdin closed)."""
    with COND:
        PENDING[rid] = None
        emit({'type': 'control_request', 'request_id': rid, 'request': request})
        while rid in PENDING and PENDING[rid] is None and not withdrawn():
            COND.wait(0.05)
        answer = PENDING.pop(rid, None)
    if answer is None and not CLOSED.is_set():
        ACKED.wait(5)
    return answer


def synthetic(command, text_, extra=None, local=None):
    """What a command the CLI runs itself answers (finding 22, shape 17-slash): a <synthetic> assistant text, then a result without
    a terminal_reason and with local_command (the command's name; /status, which it does not run here, has
    none)."""
    emit(dict({'type': 'assistant', 'message': {
        'id': str(uuid.uuid4()), 'container': None, 'model': '<synthetic>', 'role': 'assistant',
        'stop_reason': 'end_turn', 'stop_sequence': None, 'type': 'message',
        'usage': {'input_tokens': 0, 'output_tokens': 0, 'cache_creation_input_tokens': 0,
                  'cache_read_input_tokens': 0}, 'content': [{'type': 'text', 'text': text_}],
        'context_management': None},
        'parent_tool_use_id': None, 'local_command_source': '<local-command-stdout>%s</local-command-stdout>' % text_,
        'session_id': SID, 'uuid': str(uuid.uuid4()), 'timestamp': now_iso()}, **(extra or {})))
    local_result(text_, local)


def local_result(text_, local):
    record = {'is_error': False, 'duration_api_ms': 0, 'num_turns': 0, 'stop_reason': None, 'session_id': SID,
              'total_cost_usd': 0, 'usage': {'input_tokens': 0, 'cache_creation_input_tokens': 0,
                                             'cache_read_input_tokens': 0, 'output_tokens': 0},
              'modelUsage': {}, 'permission_denials': [], 'fast_mode_state': FAST[0], 'subtype': 'success',
              'result': text_}
    if local:
        record['local_command'] = local
    record.update(type='result', duration_ms=1, uuid=str(uuid.uuid4()))
    emit(record)


def c_context(prompt):
    used = int(ENV.get('FAKE_CLAUDE_CONTEXT', '0') or 0) or 45600
    synthetic('context', '## Context Usage\n\n**Model:** %s  \n**Tokens:** %.1fk / 1m (%d%%)' % (
        current_model(), used / 1000, used * 100 // 1000000), local='context')


def c_usage(prompt):
    synthetic('cost', 'You are currently using your subscription to power your Claude Code usage\n\n'
              'Current week (all models): 74% used', local=prompt.split()[0][1:])


def c_status(prompt):
    synthetic('status', "/status isn't available in this environment.")


def c_compact(prompt):
    """/compact as finding 22 has it: compacting, the result, system/init, the boundary, the summary as a synthetic user line
    (string content), the "Compacted" output echoed as a replay (with --replay-user-messages), the result"""
    emit({'type': 'system', 'subtype': 'status', 'status': 'compacting', 'session_id': SID, 'uuid': str(uuid.uuid4())})
    time.sleep(0.2)
    emit({'type': 'system', 'subtype': 'status', 'status': None, 'compact_result': 'success', 'session_id': SID,
          'uuid': str(uuid.uuid4())})
    system_init()
    emit({'type': 'system', 'subtype': 'compact_boundary', 'session_id': SID, 'uuid': str(uuid.uuid4()),
          'compact_metadata': {'trigger': 'manual', 'pre_tokens': 45783, 'post_tokens': 14115}})
    emit({'type': 'user', 'message': {'role': 'user', 'content': 'This session is being continued from a previous '
                                      'conversation that ran out of context. Summary: nothing yet.'},
          'session_id': SID, 'parent_tool_use_id': None, 'uuid': str(uuid.uuid4()), 'timestamp': now_iso(),
          'isReplay': False, 'isSynthetic': True})
    if REPLAY:
        emit({'type': 'user', 'message': {'role': 'user', 'content': '<local-command-stdout>Compacted </local-command-stdout>'},
              'session_id': SID, 'parent_tool_use_id': None, 'uuid': str(uuid.uuid4()), 'timestamp': now_iso(),
              'isReplay': True})
    local_result('', 'compact')


def c_fast(prompt):
    """/fast [on|off] (unrecorded: never tried, it may spend usage credits): fast mode on or off (bare: the
    other one), its reason gone; the answer as the other local commands', the result carrying the state."""
    words = prompt.split()
    FAST[0] = words[1] if len(words) > 1 and words[1] in ('on', 'off') else ('off' if FAST[0] == 'on' else 'on')
    FAST[1] = None
    synthetic('fast', 'Fast mode %s' % FAST[0].upper(), local='fast')


# commands the CLI answers itself (finding 22): no requesting status, no replay of the prompt; all but /compact
# send system/init first, as every turn does
LOCAL_COMMANDS = {'/context': c_context, '/cost': c_usage, '/usage': c_usage, '/status': c_status,
                  '/compact': c_compact, '/fast': c_fast}


SCENARIOS = {'tool': s_tool, 'tool2': s_tool2, 'auto': s_auto, 'pending': s_pending, 'ask': s_ask,
             'ask2': s_ask2, 'plan': s_plan, 'slow': s_slow, 'think': s_think, 'deaf': s_deaf,
             'racing': s_racing, 'subagent': s_subagent, 'exit': s_exit, 'big': s_big, 'error': s_error,
             'wait': s_wait, 'many': s_many, 'ran': s_ran, 'fails': s_fails, 'early': s_early,
             'replay': s_replay, 'mcp': s_mcp, 'noid': s_noid, 'askx': s_askx, 'deep': s_deep,
             'withdraw': s_withdraw, 'unsaved': s_unsaved, 'unknown': s_unknown, 'unhandled': s_unhandled,
             'mute': s_mute, 'orphan': s_orphan, 'autherr': s_autherr, 'long': s_long, 'gone': s_gone,
             'stream': s_stream, 'held': s_held, 'usage': s_usage, 'edit': s_edit, 'fetch': s_fetch}


# three of 2.1.330's commands, as its initialize lists them (finding 22; the real list has every built-in,
# skill and plugin command)
COMMANDS = [{'name': 'compact', 'description': 'Clear history but keep a summary', 'argumentHint': ''},
            {'name': 'context', 'description': 'Show current context usage', 'argumentHint': ''},
            {'name': 'usage', 'description': "Show session cost, plan usage, and what's contributing to your limits",
             'argumentHint': '', 'aliases': ['cost', 'stats']}]
COMMANDS_SENT = [False]


def changed_commands():
    """The list commands_changed sends after initialize: COMMANDS, or FAKE_CLAUDE_COMMANDS_CHANGED's names."""
    names = [n for n in ENV.get('FAKE_CLAUDE_COMMANDS_CHANGED', '').split(',') if n]
    if not names:
        return COMMANDS
    known = {c['name']: c for c in COMMANDS}
    return [known.get(n, {'name': n, 'description': 'Skill ' + n, 'argumentHint': ''}) for n in names]

SUGGEST = [False]                   # initialize's promptSuggestions
PLAN = [None]                       # get_plan's plan: {content, path} once `plan` asked


def init_response():
    account = {'ok': {'email': 'user@example.com', 'organization': "user@example.com's Organization",
                      'subscriptionType': 'Claude Max', 'apiProvider': 'firstParty'},
               'bedrock': {'subscriptionType': 'Claude Max', 'apiProvider': 'bedrock'},
               'none': None}[ENV.get('FAKE_CLAUDE_ACCOUNT', 'ok')]
    response = {'commands': COMMANDS, 'agents': [], 'output_style': 'default', 'available_output_styles': ['default'],
                'models': model_list()}
    if unavailable_models():                    # unrecorded member (the schema's, after models)
        response['unavailable_models'] = unavailable_models()
    if account:
        response['account'] = account
    if ENV.get('FAKE_CLAUDE_AUTH_CONFLICT'):    # unrecorded member (the schema's, after account)
        response['auth_conflict'] = {'token_source': 'claude.ai', 'api_key_source': 'ANTHROPIC_API_KEY'}
    response.update(pid=os.getpid(), claude_code_version='2.1.330', current_permission_mode=MODE,
                    fast_mode_state=FAST[0])
    if ENV.get('FAKE_CLAUDE_FAST'):             # 2.1.330 sends the reason (finding 19), after the state
        response['fast_mode_disabled_reason'] = FAST[1]
    response.update(session_state='idle', capabilities=['ui_surface_v1'])
    return response


def respond(rid, response):
    emit({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': rid, 'response': response}})


def respond_empty(rid):
    """The success without a response member that apply_flag_settings, set_max_thinking_tokens and set_model
    get (finding 11)."""
    emit({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': rid}})


def respond_error(rid, text_):
    emit({'type': 'control_response', 'response': {'subtype': 'error', 'request_id': rid, 'error': text_}})


def prompt_text(message):
    """The text of a user message."""
    content = message.get('message', {}).get('content')
    return content if isinstance(content, str) else ''.join(
        block.get('text', '') for block in content or [] if isinstance(block, dict) and block.get('type') == 'text')


def lifecycle(uid, state):
    """command_lifecycle (finding 17): a message written with a uuid is queued at once, started when its turn
    starts, completed, or cancelled when an interrupt ended its turn; without a uuid, none.
    FAKE_CLAUDE_NO_LIFECYCLE (unrecorded): none at all, so only the replay says a message started."""
    if ENV.get('FAKE_CLAUDE_NO_LIFECYCLE'):
        return
    emit({'type': 'command_lifecycle', 'command_uuid': uid, 'state': state, 'uuid': str(uuid.uuid4()),
          'session_id': SID})


REFUSED = [False]                   # FAKE_CLAUDE_REFUSE_HELD: one held message was refused already
DISCARDED = [False]                 # FAKE_CLAUDE_DISCARD_HELD: one held message was marked to be discarded


def handle(message):
    global MODE
    kind = message.get('type')
    if kind == 'control_request':
        rid, request = message.get('request_id'), message.get('request', {})
        sub = request.get('subtype')
        if sub == 'initialize':
            time.sleep(int(ENV.get('FAKE_CLAUDE_INIT_MS', '0')) / 1000)
            SUGGEST[0] = request.get('promptSuggestions') is True
            log(initialize={'promptSuggestions': request.get('promptSuggestions'),
                            'supportedDialogKinds': request.get('supportedDialogKinds')})
            respond(rid, init_response())
            if not COMMANDS_SENT[0]:        # 2.1.330 follows the answer with the full command list
                COMMANDS_SENT[0] = True
                emit({'type': 'system', 'subtype': 'commands_changed', 'commands': changed_commands(),
                      'uuid': str(uuid.uuid4()), 'session_id': SID})
        elif sub == 'interrupt':
            with COND:
                if DEAF.is_set():
                    return
                held = [entry['uuid'] for entry in QUEUE if entry['uuid']]
                if request.get('cancel_queued') is True:    # unrecorded: rhun never sends it
                    for entry in [e for e in QUEUE if e['uuid']]:
                        QUEUE.remove(entry)
                        lifecycle(entry['uuid'], 'cancelled')
                    held = []
                if not BUSY[0] and not QUEUE:       # nothing to interrupt
                    respond(rid, {'still_queued': held})
                    return
                INTERRUPT.set()
                withdrawn = [key for key, value in PENDING.items() if value is None]
                for key in withdrawn:
                    del PENDING[key]
                COND.notify_all()
                if RACING:
                    racing_end(RACING.pop())
                for key in withdrawn:
                    emit({'type': 'control_cancel_request', 'request_id': key})
                # finding 17: the held messages stay queued and run after the interrupted turn
                respond(rid, {'still_queued': held})
                ACKED.set()
        elif sub == 'set_permission_mode':
            mode = 'default' if request.get('mode') == 'manual' else request.get('mode', MODE)
            if mode == 'bypassPermissions' and not BYPASS_OK:
                respond_error(rid, 'Cannot set permission mode to bypassPermissions because the session was not '
                              'launched with --dangerously-skip-permissions')
                return
            old, MODE = MODE, mode
            respond(rid, {'mode': MODE})    # the answer, then the mode's status line (2.1.330)
            if MODE != old:                 # none when the mode does not change (finding 10)
                status(None, MODE)
                if 'bypassPermissions' in (old, MODE):
                    emit({'type': 'system', 'subtype': 'commands_changed', 'commands': COMMANDS,
                          'uuid': str(uuid.uuid4()), 'session_id': SID})
        elif sub == 'set_model':
            respond_empty(rid)
        elif sub == 'get_settings':
            respond(rid, get_settings())
        elif sub == 'apply_flag_settings':
            settings = request.get('settings') if isinstance(request.get('settings'), dict) else {}
            for key, value in settings.items():
                if value is None:
                    FLAG_SETTINGS.pop(key, None)
                else:
                    FLAG_SETTINGS[key] = value
            respond_empty(rid)
        elif sub == 'update_settings':
            settings = request.get('settings') if isinstance(request.get('settings'), dict) else {}
            error = update_settings(request.get('source'), settings)
            if error:
                respond_error(rid, error)
            else:
                respond(rid, {})
        elif sub == 'set_max_thinking_tokens':
            THINKING[0] = request.get('max_thinking_tokens')
            log(thinking={'max_thinking_tokens': request.get('max_thinking_tokens'),
                          'thinking_display': request.get('thinking_display')})
            respond_empty(rid)
        elif sub == 'get_plan':
            respond(rid, dict(exists=True, **PLAN[0]) if PLAN[0] else {'exists': False})
        else:
            respond_error(rid, 'Unsupported control request subtype: %s' % sub)
    elif kind == 'control_response':
        response = message.get('response', {})
        if REPLAY:                          # 18: with --replay-user-messages every answer comes back as sent
            emit(message)
        with COND:
            rid = response.get('request_id')
            if rid in PENDING and PENDING[rid] is None:   # a late answer to a withdrawn id is ignored (C10)
                PENDING[rid] = response.get('response') if response.get('subtype') == 'success' \
                    else {'behavior': 'error', 'message': response.get('error', '')}
                COND.notify_all()
    elif kind == 'user':
        uid = message.get('uuid') if isinstance(message.get('uuid'), str) else None
        content = message.get('message', {}).get('content')
        entry = {'text': prompt_text(message), 'uuid': uid, 'content': content}
        with COND:
            if uid and ENV.get('FAKE_CLAUDE_REFUSE_HELD') and (BUSY[0] or QUEUE) and not REFUSED[0]:
                REFUSED[0] = True           # unrecorded: the state exists in the schema, no run produced it
                log(refused=uid)
                lifecycle(uid, 'refused')
                return
            if uid and ENV.get('FAKE_CLAUDE_DISCARD_HELD') and (BUSY[0] or QUEUE) and not DISCARDED[0]:
                DISCARDED[0] = True         # unrecorded: queued now, discarded when its turn would start
                entry['discard'] = True
            QUEUE.append(entry)
            if uid:
                lifecycle(uid, 'queued')
            COND.notify_all()


def system_init():
    """system/init: sent at the start of every turn (2.1.330, finding 17), not only the first (C4)."""
    emit({'type': 'system', 'subtype': 'init', 'cwd': CWD, 'session_id': SID,
          'tools': ['Task', 'AskUserQuestion', 'Bash', 'ExitPlanMode'], 'mcp_servers': [],
          'model': current_model() + '[1m]', 'permissionMode': MODE, 'slash_commands': ['compact', 'context', 'usage'],
          'apiKeySource': ENV.get('FAKE_CLAUDE_KEYSRC', 'none'), 'claude_code_version': '2.1.330',
          'output_style': 'default', 'capabilities': ['interrupt_receipt_v1', 'msg_lifecycle_v1'],
          'uuid': str(uuid.uuid4()), 'fast_mode_state': FAST[0], 'ultrathink_available': False})


def turn(entry):
    """One message's turn: its records, its transcript lines. A command the CLI answers itself (LOCAL_COMMANDS)
    has no requesting status and no replay."""
    prompt = entry['text']
    words = prompt.split()
    local = LOCAL_COMMANDS.get(words[0]) if words else None
    if local:
        if local is not c_compact:
            system_init()
        local(prompt)
        return False
    if ENV.get('FAKE_CLAUDE_FAST_REJECT') and FAST[0] == 'on':  # unrecorded: credits ran out, fast mode goes
        emit({'type': 'system', 'subtype': 'notification', 'key': 'fast-mode-overage-rejected',
              'text': 'Fast mode disabled \u00b7 Usage credits are unavailable.', 'priority': 'immediate',
              'color': 'error', 'session_id': SID, 'uuid': str(uuid.uuid4())})
        FAST[0] = 'off'
    if ENV.get('FAKE_CLAUDE_USER_LATE_MS'):    # pending from before system/init: a stop finds it
        LATE_USER.append({'type': 'user', 'message': {'role': 'user', 'content': [{'type': 'text', 'text': prompt}]}})
    system_init()
    if LATE_USER:                    # wait for the stop rather than write to a reader that is gone
        CLOSED.wait(int(ENV.get('FAKE_CLAUDE_USER_LATE_WAIT_MS', '10000')) / 1000)
    status('requesting')
    if REPLAY:                       # finding 17: the message comes back, with its uuid (the CLI's own without one)
        emit({'type': 'user', 'message': {'role': 'user', 'content': entry['content']}, 'session_id': SID,
              'parent_tool_use_id': None, 'uuid': entry['uuid'] or str(uuid.uuid4()), 'timestamp': now_iso(),
              'isReplay': True})
    del DENIALS[:]
    scenario = SCENARIOS.get(ENV.get('FAKE_CLAUDE_SCENARIO') or (words[0].lower() if words else ''), s_plain)
    if LATE_USER:                    # nobody stopped it (10 s at most): the line goes in now
        transcript(LATE_USER.pop())
    elif scenario not in (s_unsaved, s_racing):     # (they save it later, if at all)
        transcript({'type': 'user', 'message': {'role': 'user', 'content': [{'type': 'text', 'text': prompt}]}})
    scenario(prompt)
    return True


def worker():
    while True:
        with COND:
            while not QUEUE:
                COND.wait()
            entry = QUEUE.pop(0)
            if entry.get('discard'):        # FAKE_CLAUDE_DISCARD_HELD: it never runs
                log(discarded=entry['uuid'])
                lifecycle(entry['uuid'], 'discarded')
                COND.notify_all()
                continue
            BUSY[0] = True
            TURN_UUID[0] = entry['uuid']
        if entry['uuid']:
            lifecycle(entry['uuid'], 'started')
        model_turn = False
        try:
            model_turn = turn(entry)
        except Exception as error:          # a bug, or an answer of a shape the fake cannot read
            log(error=traceback.format_exc())
            traceback.print_exc()
            result(subtype='error_during_execution', stop=None, terminal='fake_error',
                   errors=['fake claude: %s: %s' % (type(error).__name__, error)])
        finally:
            with COND:                       # an interrupt belongs to the turn it came in
                cut = INTERRUPT.is_set() and not DEAF.is_set()
                if entry['uuid']:
                    lifecycle(entry['uuid'], 'cancelled' if cut else 'completed')
                # a suggestion after a turn that ended by itself with nothing queued (finding 19; the real CLI sends one after some turns only)
                if SUGGEST[0] and model_turn and not cut and not QUEUE:
                    emit({'type': 'prompt_suggestion', 'suggestion': 'Run the tests', 'uuid': str(uuid.uuid4()),
                          'session_id': SID})
                BUSY[0] = False
                TURN_UUID[0] = None
                del CUT[:]
                INTERRUPT.clear()
                ACKED.clear()
                DEAF.clear()
                COND.notify_all()


threading.Thread(target=worker, daemon=True).start()
for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    log(stdin=raw)
    try:
        message = json.loads(raw)
    except ValueError:
        continue
    if not isinstance(message, dict):
        continue
    try:
        handle(message)
    except Exception:                        # a record of a shape the fake does not know
        log(error=traceback.format_exc())
        traceback.print_exc()
    if message.get('type') == 'user' and prompt_text(message).split()[:1] == ['gone']:
        if prompt_text(message).split()[1:2] == ['exit']:
            # `gone exit`: the request goes out, then a process of its own keeps stdout open (10 s) and
            # this one exits as a crash, its stdin closed with it
            with COND:
                while not PENDING:
                    COND.wait(0.05)
            subprocess.Popen(['sleep', '10'], stdin=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            crash(3)
        os.close(sys.stdin.fileno())         # `gone`: nobody reads what rhun writes from here on
        time.sleep(int(ENV.get('FAKE_CLAUDE_LINGER_MS', '30000')) / 1000)
        break
with COND:                                   # at EOF the turn running finishes first
    CLOSED.set()                             # (a request still waiting is withdrawn)
    COND.notify_all()
    while BUSY[0] or QUEUE:
        COND.wait(0.1)
time.sleep(int(ENV.get('FAKE_CLAUDE_EOF_MS', '0')) / 1000)
leave(EXIT_STATUS[0])
