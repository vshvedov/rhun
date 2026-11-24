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
FAKE_CLAUDE_CONTEXT (N: a turn's usage adds up to N tokens); FAKE_CLAUDE_RATE (warning, rejected, ...: a
rate_limit_event of that kind before each result, see rate_limit; the prompt `rate KIND` sends one once); FAKE_CLAUDE_SETTINGS_ERROR (TEXT: get_settings has one error);
FAKE_CLAUDE_SETTINGS_FAIL (TEXT: get_settings is answered with that error, unrecorded);
FAKE_CLAUDE_AUTH_CONFLICT (initialize has auth_conflict); FAKE_CLAUDE_FAST ("STATE REASON": initialize's
fast_mode_state and fast_mode_disabled_reason, "-" for none, as 2.1.330's "off sdk_opt_in_required"; system/init and
every result carry the state; without it initialize has no reason, as before); FAKE_CLAUDE_FAST_REJECT (unrecorded:
the first turn after /fast turned fast mode on gets system/notification "fast-mode-overage-rejected" and fast mode
goes off, as the CLI binary's text has it); FAKE_CLAUDE_COMMANDS_CHANGED (comma-separated names:
the system/commands_changed that follows initialize lists these instead, the known ones as initialize has
them, claude-api as the real skill with line ends in its description (finding 26), the others as skills
"Skill NAME", as the real list has skills initialize lacks); FAKE_CLAUDE_REFUSE_HELD (the first message written
with a uuid while another waits or runs is refused: lifecycle refused, never run, logged {"refused": UUID});
FAKE_CLAUDE_DISCARD_HELD (the first such message, or with a value other than 1 the held message of that text,
is queued, then, when its turn would start, lifecycle
discarded, never run, logged {"discarded": UUID}); FAKE_CLAUDE_NO_LIFECYCLE (no command_lifecycle at all
("local": none for a command the CLI answers itself, LOCAL_COMMANDS, only):
only the replay says a message started); FAKE_CLAUDE_ULTRATHINK (system/init says ultrathink_available true:
unrecorded, 2.1.330 said false on this account); FAKE_CLAUDE_REFUSE_AUTO (set_permission_mode auto is answered
with an error: unrecorded, the plan review's fallback to acceptEdits);
Phase 3 (README.txt findings 27 on): the conversation's file is written as 2.1.330 writes it (a line a content
block, thinking included, toolUseResult, parentUuid, the compaction and local command records; a subagent's
lines in <id>/subagents/agent-ID.jsonl); scenarios tools, read, write, grep run, glob run, websearch run,
todo, think TEXT, agent [wait], bg, image, toolerror, denied, hooks, unknownblock, echo [NAME] (and /NAME
with <cwd>/.claude/commands/NAME.md), apierror (unrecorded); stop_task and background_tasks are answered;
initialize's perTaskStopAffordance and forwardNestedSubagentToolCalls are logged when sent;
--include-hook-events is taken. FAKE_CLAUDE_TASKS (the task tools in place of TodoWrite); FAKE_CLAUDE_HOOKS
(comma-separated: start, prompt, block, stop, post; see HOOKS_ON); FAKE_CLAUDE_BG_MS (how long `bg` runs
before it ends, default 3000); FAKE_CLAUDE_PRESERVED (/compact sends the last assistant record again, as
20-compact recorded). Task 5: `linger [S]` (a turn that works S seconds), `asklinger [S]` (a call
that asks, then S seconds of work), `pause [S]` (a reply whole only S seconds after its text streamed); FAKE_CLAUDE_HOOK_MS (a hook's
hook_response comes that long after its hook_started); FAKE_CLAUDE_COMPACT_MS (how long /compact's compacting
status lasts, default 200).
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
            '--allow-dangerously-skip-permissions', '--include-hook-events'}
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


TURN_CACHE = [None]                 # the `usage` scenario's (written, read): its messages' usage reports them too


def usage(cache=None):
    """A turn's usage. FAKE_CLAUDE_CONTEXT=N: the four token counts add up to N (the context in use).
    cache: (written, read) for the `usage` scenario, with the 1-hour and 5-minute split the CLI reports
    (finding 21 has them on result.usage; an assistant message's usage is the API's, which has the same
    members); its messages' usage reports the same (TURN_CACHE)."""
    cache = cache or TURN_CACHE[0]
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
    return models + review_models()


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
    value = FALLBACK[0] or FLAG_SETTINGS.get('model') or option('--model') or effective().get('model') or 'default'
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


CHAIN = [None]                      # the uuid of the file's last message line: the next line's parentUuid
CALL_LINES = {}                     # tool_use id -> the uuid of the file line with the call
BLOCK_INDEX = {}                    # message id -> the next block's apiBlockIndex
LAST_ASSISTANT = [None]             # the last assistant record sent (FAKE_CLAUDE_PRESERVED sends it again)


def file_line(record, result=None, chain=CHAIN, agent=None):
    """record (the stream's {type, message, flags...}, or {type: system, subtype, ...}) as a line of the
    conversation's file, in finding 27's field order (file-keys.txt; the fake leaves fields out, never adds
    or reorders them): one content block a line, the uuid its own, parentUuid the line before; a tool's
    result carries toolUseResult (result, the stream's tool_use_result) and the call's line;
    a subagent's line (agent: its id) isSidechain and agentId. System records keep their members' order,
    timestamp and uuid where the CLI puts them."""
    uid = str(uuid.uuid4())
    kind = record['type']
    line = {'parentUuid': chain[0], 'isSidechain': agent is not None}
    if kind == 'system':
        if record['subtype'] == 'compact_boundary':
            line = {'parentUuid': None, 'logicalParentUuid': chain[0], 'isSidechain': False}
        line.update(type='system', subtype=record['subtype'])
        for key, value in record.items():
            if key == 'after':
                line.update(timestamp=now_iso(), uuid=uid)
                line.update(value)
            elif key not in ('type', 'subtype'):
                line[key] = value
    elif kind == 'attachment':
        line.update(attachment=record['attachment'], type='attachment', uuid=uid, timestamp=now_iso())
    else:
        if agent is not None:
            line['agentId'] = agent
        message = record['message']
        content = message.get('content')
        block = content[0] if isinstance(content, list) and content and isinstance(content[0], dict) else {}
        if kind == 'assistant':
            mid = message.get('id')
            line['message'] = {'model': message.get('model'), 'id': mid, 'type': 'message', 'role': 'assistant',
                               'content': content, 'stop_reason': None, 'stop_sequence': None, 'usage': usage()}
            if block.get('type') == 'thinking':
                line.update(thinkingDurationMs=record.get('thinking_duration_ms'),
                            thinkingDisplay=record.get('thinking_display'))
            BLOCK_INDEX[mid] = BLOCK_INDEX.get(mid, -1) + 1
            line.update(apiBlockIndex=BLOCK_INDEX[mid], type='assistant', uuid=uid, timestamp=now_iso())
            if record.get('error'):         # assistant.error (the binary's schema, finding 35: unrecorded)
                line['error'] = record['error']
            if block.get('type') == 'tool_use':
                CALL_LINES[block.get('id')] = uid
        else:
            line.update(type='user', message={'role': 'user', 'content': content})
            for flag in ('isMeta', 'isVisibleInTranscriptOnly', 'isCompactSummary'):
                if record.get(flag):
                    line[flag] = True
            line.update(uuid=uid, timestamp=now_iso())
            if block.get('type') == 'tool_result':
                if result is not None:
                    line['toolUseResult'] = result
                if block.get('tool_use_id') in CALL_LINES:
                    line['sourceToolAssistantUUID'] = CALL_LINES[block.get('tool_use_id')]
            elif agent is None and not record.get('isMeta') and not record.get('isCompactSummary'):
                if isinstance(content, list) or record.get('origin'):
                    line['permissionMode'] = MODE
                if record.get('origin'):
                    line['origin'] = record['origin']
                if isinstance(content, list) and TURN_UUID[0]:
                    line['turnAttributionKey'] = TURN_UUID[0]
    line.update(userType='external', entrypoint=ENV.get('CLAUDE_CODE_ENTRYPOINT') or 'sdk-cli', cwd=CWD,
                sessionId=SID, version='2.1.330', gitBranch='')
    if kind != 'attachment':
        chain[0] = uid
    return line


def transcript(record, result=None, path=None, chain=CHAIN, agent=None):
    """One line in the conversation's file (path: a subagent's file instead), in the CLI's shapes."""
    fork_copy()
    path = path or TRANSCRIPT
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'a', encoding='utf-8') as stream:
        stream.write(json.dumps(file_line(record, result, chain, agent), ensure_ascii=False) + '\n')


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
    the transcript (yet). The file gets a line a block, thinking included (finding 27)."""
    record = dict({'type': 'assistant', 'message': {
        'model': current_model(), 'id': mid, 'type': 'message', 'role': 'assistant', 'content': [block],
        'stop_reason': None, 'usage': usage()}, 'parent_tool_use_id': None, 'session_id': SID,
        'uuid': str(uuid.uuid4())}, **extra)
    emit(record)
    LAST_ASSISTANT[0] = record
    if save:
        transcript(dict(extra, type='assistant', message={'id': mid, 'model': current_model(), 'content': [block]}))


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
    """extra: tool_use_result (the structured result, also the file's toolUseResult) and the like."""
    emit(dict({'type': 'user', 'message': {'role': 'user', 'content': [block]}, 'parent_tool_use_id': None,
               'session_id': SID, 'uuid': str(uuid.uuid4()), 'timestamp': now_iso()}, **extra))
    transcript({'type': 'user', 'message': {'role': 'user', 'content': [block]}}, extra.get('tool_use_result'))


def tool_result(tid, content, is_error=False, interactive=False, plain=False, structured=None):
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
    if structured is None:
        user(block)
    else:
        user(block, tool_use_result=structured)


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


def bash_request(tool_input, tid, suggestions, extra=None):
    """A Bash can_use_tool request (02's field order); extra: members of the schema no recording had
    (suppress_always_allow_rule, default_to_no, decision_reason*: ext-host-protocol 3.1), before tool_use_id."""
    request = {'subtype': 'can_use_tool', 'tool_name': 'Bash', 'display_name': 'Bash', 'input': tool_input,
               'description': tool_input.get('description', ''), 'permission_suggestions': suggestions,
               'blocked_path': blocked_path(tool_input['command'])}
    request.update(extra or {})
    request['tool_use_id'] = tid
    return request


def can_use_tool(name, tool_input, tid, suggestions=None, extra=None):
    """Asks rhun (02, 03, 04); its answer, or None when an interrupt withdrew the request (06) or stdin
    closed. Without suggestions it is an interactive tool's request (03, 04)."""
    rid = request_id()
    if suggestions is None:
        request = {'subtype': 'can_use_tool', 'tool_name': name, 'display_name': name, 'input': tool_input,
                   'tool_use_id': tid, 'requires_user_interaction': True}
    else:
        request = bash_request(tool_input, tid, suggestions, extra)
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
    if ENV.get('FAKE_CLAUDE_RATE') and not RATE_TURN[0]:
        rate_limit(ENV['FAKE_CLAUDE_RATE'])
    if 'stop' in HOOKS_ON:          # finding 32: the Stop hooks' records before the result, their summary in the file
        hook_records('Stop', 'Stop')
    emit(record)


RESETS = [None]                     # when the limits reset: an hour after the first event, the same after it
RATE_TURN = [False]                 # `rate KIND` sent this turn's event: FAKE_CLAUDE_RATE's is not sent too


def rate_limit(kind):
    """A rate_limit_event before the result (as the recordings place it, finding 20). kind: warning (85 % of
    the five-hour window used), rejected (all of it), weekly (75 % of the week), over (past a threshold of
    90 %, no utilization), approaching (neither), paused (the organization's daily cap), spend (the spend
    limit, with an admin request offer), soon (the five-hour limit hit, resetting in 30 s), else allowed. The
    recorded event of 2.1.330 had status, resetsAt, rateLimitType, overage fields and unifiedWindows (only
    allowed was seen); utilization at the top and every other kind are the schema's (ext-host-protocol 2.6),
    unrecorded. Logged as {"rate": rate_limit_info}."""
    if RESETS[0] is None:
        RESETS[0] = int(time.time()) + 3600
    resets = RESETS[0]
    kinds = {'warning': ('allowed_warning', 'five_hour', 0.85), 'rejected': ('rejected', 'five_hour', 1.0),
             'weekly': ('allowed_warning', 'seven_day', 0.75), 'over': ('allowed_warning', 'five_hour', None),
             'approaching': ('allowed_warning', 'five_hour', None), 'paused': ('rejected', 'five_hour', 1.0),
             'spend': ('rejected', 'overage', 1.0), 'soon': ('rejected', 'five_hour', 1.0)}
    status_, window, used = kinds.get(kind, ('allowed', 'five_hour', 0.2))
    if kind == 'soon':
        resets = int(time.time()) + 30
    info = {'status': status_, 'resetsAt': resets, 'rateLimitType': window}
    if used is not None:
        info['utilization'] = used
    if kind == 'over':
        info['surpassedThreshold'] = 0.9
    if kind == 'paused':
        info['dailyCapPaused'] = True
    if kind == 'spend':
        info.update(overageStatus='rejected', adminRequestOffer={'state': 'can_ask'})
    info.update(isUsingOverage=False,
                unifiedWindows={window: {'utilization': used or 0.9, 'resetsAt': resets, 'status': status_}})
    log(rate=info)
    emit({'type': 'rate_limit_event', 'rate_limit_info': info, 'uuid': str(uuid.uuid4()), 'session_id': SID})


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


def bash(command, ask=True, extra=None, rules=None, request=None):
    """One Bash call in its own message, as 02 has them; False when an interrupt cut the turn. extra: more
    input fields; rules: the suggestions in place of 02's; request: more members of the request."""
    mid = message_start()
    tool_input = dict({'command': command, 'description': 'Run ' + command}, **(extra or {}))
    tid = tool_use(mid, 0, 'Bash', tool_input)
    message_end('tool_use')
    if not ENV.get('FAKE_CLAUDE_RATE'):     # with the knob, result() sends its own
        emit({'type': 'rate_limit_event', 'rate_limit_info': {'status': 'allowed', 'rateLimitType': 'five_hour'},
              'uuid': str(uuid.uuid4()), 'session_id': SID})
    if ask and (rule_allows('Bash', command) or MODE == 'bypassPermissions'):
        ask = False                 # a saved rule lets it run (finding 15: the same command again did not ask)
    answer = can_use_tool('Bash', tool_input, tid, suggestions(command) if rules is None else rules,
                          request) if ask else {'behavior': 'allow'}
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


def s_nosave(prompt):
    """a Bash call whose request says suppress_always_allow_rule (the schema's; unrecorded): no rule button"""
    if bash('touch nosave.txt', request={'suppress_always_allow_rule': True}):
        final('done')


def s_defno(prompt):
    """a Bash call whose request says default_to_no (the schema's; unrecorded)"""
    if bash('touch defno.txt', request={'default_to_no': True}):
        final('done')


def s_hook(prompt):
    """a Bash call a PreToolUse hook sent to the user: decision_reason_type hook and its reason (the schema's;
    unrecorded)"""
    if bash('touch hook.txt', request={'decision_reason': 'The policy hook wants a person to look at this.',
                                       'decision_reason_type': 'hook'}):
        final('done')


def s_dirs(prompt):
    """dirs [N]: a Bash call whose only suggestions are N directories (default 1) for the session"""
    words = prompt.split()
    count = int(words[1]) if len(words) > 1 and words[1].isdigit() else 1
    paths = [os.path.join(CWD, 'dir%d' % i) for i in range(1, count + 1)]
    if bash('ls dir1', rules=[{'type': 'addDirectories', 'directories': paths, 'destination': 'session'}]):
        final('done')


def s_modeonly(prompt):
    """a Bash call whose only suggestion is setMode acceptEdits for the session (as 16's Edit had)"""
    if bash('touch modeonly.txt', rules=[{'type': 'setMode', 'mode': 'acceptEdits', 'destination': 'session'}]):
        final('done')


def s_mixed(prompt):
    """a Bash call with a prefix rule, another directory and setMode plan for the session (15's kinds)"""
    rules = [{'type': 'addRules', 'rules': [{'toolName': 'Bash', 'ruleContent': 'git log:*'}], 'behavior': 'allow',
              'destination': 'localSettings'},
             {'type': 'addDirectories', 'directories': [os.path.join(CWD, 'lib')], 'destination': 'session'},
             {'type': 'setMode', 'mode': 'plan', 'destination': 'session'}]
    if bash('git log -1', rules=rules):
        final('done')


def s_sessiononly(prompt):
    """a Bash call with one rule suggested for the session"""
    rules = [{'type': 'addRules', 'rules': [{'toolName': 'Bash', 'ruleContent': 'touch session.txt'}],
              'behavior': 'allow', 'destination': 'session'}]
    if bash('touch session.txt', rules=rules):
        final('done')


def s_bypass(prompt):
    """a Bash call whose suggestions are a rule and setMode bypassPermissions (the schema allows it;
    unrecorded)"""
    rules = [{'type': 'addRules', 'rules': [{'toolName': 'Bash', 'ruleContent': 'touch bypass.txt'}],
              'behavior': 'allow', 'destination': 'localSettings'},
             {'type': 'setMode', 'mode': 'bypassPermissions', 'destination': 'session'}]
    if bash('touch bypass.txt', rules=rules):
        final('done')


def asked(name, tool_input, suggestions=None, outcome=None):
    """One call of NAME that asks, in finding 15's request shape (its description, its suggestions when given);
    the tool's result is made up (outcome: the recorded form, finding 28); a deny that interrupts ends the
    turn as bash's does"""
    mid = message_start()
    tid = tool_use(mid, 0, name, tool_input)
    message_end('tool_use')
    request = {'subtype': 'can_use_tool', 'tool_name': name, 'display_name': name, 'input': tool_input,
               'description': tool_input.get('description', name)}
    if suggestions is not None:
        request['permission_suggestions'] = suggestions
    request['tool_use_id'] = tid
    answer = ask_request(request_id(), request)
    if answer is None:
        tool_result(tid, REJECTED, True)
        cut_off(tool_turn=True)
        return
    log(answer=answer)
    if answer.get('behavior') == 'allow':
        apply_updates(answer)
        if outcome is None:
            tool_result(tid, 'done', plain=True)
        else:
            give(tid, name, outcome)
        final('done')
        return
    DENIALS.append({'tool_name': name, 'tool_use_id': tid, 'tool_input': tool_input})
    tool_result(tid, answer.get('message', ''), True)
    if answer.get('interrupt') is True:
        cut_off(tool_turn=True)
    else:
        final('not done')


def s_pwsh(prompt):
    """a PowerShell call (the tool of Windows; its input is Bash's: unrecorded)"""
    asked('PowerShell', {'command': 'Get-ChildItem', 'description': 'List the folder'},
          [{'type': 'addRules', 'rules': [{'toolName': 'PowerShell', 'ruleContent': 'Get-ChildItem'}],
            'behavior': 'allow', 'destination': 'localSettings'}])


def s_net(prompt):
    """a sandbox's network request (SandboxNetworkAccess {host}: the extension's renderer; unrecorded)"""
    asked('SandboxNetworkAccess', {'host': 'example.com'})


def s_skill(prompt):
    """skill NAME: a Skill call with arguments (the extension's renderer reads skill and args; unrecorded)"""
    words = prompt.split()
    asked('Skill', {'skill': words[1] if len(words) > 1 else 'review', 'args': '--quick'})


def s_project(prompt):
    """a SendToProject call that makes a project (the extension's reader d$; unrecorded)"""
    asked('SendToProject', {'message_from': 'typed', 'proposal': {'summary': 'Here is the plan for the docs.'},
                            'project_name': 'Docs'})


def s_glob(prompt):
    """a Glob call in the project (with its path); `glob run`: without asking (as 2.1.330 ran it, finding 28)"""
    if prompt.split()[1:2] == ['run']:
        return ran_calls([('Glob', {'pattern': '*.txt', 'path': CWD}, glob_outcome(['notes.txt']))])
    asked('Glob', {'pattern': '*.txt', 'path': CWD}, outcome=glob_outcome(['notes.txt']))


def s_grep(prompt):
    """a Grep call without a path; `grep run`: without asking, its three output modes (finding 28)"""
    if prompt.split()[1:2] == ['run']:
        return ran_calls(grep_calls())
    asked('Grep', {'pattern': 'TODO'}, outcome=grep_calls()[1][2])


def s_websearch(prompt):
    """a WebSearch call with allowed and blocked domains; `websearch run`: without asking (finding 28)"""
    tool_input = {'query': 'rhun editor', 'allowed_domains': ['rhun.app', 'github.com'], 'blocked_domains': ['example.com']}
    if prompt.split()[1:2] == ['run']:
        return ran_calls([('WebSearch', tool_input, websearch_outcome('rhun editor'))])
    asked('WebSearch', tool_input, outcome=websearch_outcome('rhun editor'))


def s_other(prompt):
    """a tool rhun has no header for (an MCP server's): the fallback with its input as JSON"""
    asked('mcp__notes__add', {'title': 'Milk', 'tags': ['home', 'list'], 'due': None})


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


# the question card: three questions, the second multi-select, in finding 23's shape (options {label,
# description, preview}, the previews Markdown strings, only on single-choice questions)
QUESTIONS_THREE = [
    {'question': 'Which layout should the page use?', 'header': 'Layout', 'multiSelect': False,
     'options': [{'label': 'Sidebar', 'description': 'The links in a column on the left',
                  'preview': '## Sidebar\n\n- the links in a column\n- the page beside them\n'},
                 {'label': 'Top bar', 'description': 'The links in a row across the top',
                  'preview': 'Top bar\n=======\n\n```\n[a] [b] [c]\n```'},
                 {'label': 'None', 'description': 'No links at all'}]},
    {'question': 'Which checks should run?', 'header': 'Checks', 'multiSelect': True,
     'options': [{'label': 'lint', 'description': 'Style'}, {'label': 'tests', 'description': 'Unit tests'},
                 {'label': 'types', 'description': 'Type checks'}]},
    {'question': 'How big is it?', 'header': 'Size', 'multiSelect': False,
     'options': [{'label': 'small', 'description': 'A page'}, {'label': 'big', 'description': 'A site'}]}]


def s_ask3(prompt):
    """the question card: three questions, one multi-select, previews on the first"""
    s_ask(prompt, QUESTIONS_THREE)


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
    plan_turn(['# Plan\n\n1. Add the file\n2. Test it'])


def plan_turn(plans):
    """ExitPlanMode for each plan in turn (finding 24): a deny with interrupt false gives the tool_result its
    message and Claude plans again in the same turn (the next plan; after the last, the final text
    "planning"); a deny with interrupt true ends the turn as an interrupt does ("[Request interrupted by
    user]", aborted_streaming); an allow leaves plan mode (the mode a set_permission_mode chose before it, a
    setMode among its updatedPermissions, else default) and logs its userFeedback."""
    global MODE
    path = os.path.join(config_dir(), 'plans', 'fake.md')
    for plan in plans:
        PLAN[0] = {'content': plan, 'path': path}     # get_plan's answer from here on (finding 24)
        review_plan_save()
        tid, answer = interactive('ExitPlanMode', {'plan': plan, 'planFilePath': path})
        if answer is None:
            return
        if answer.get('behavior') == 'allow':
            break
        tool_result(tid, answer.get('message', ''), True)
        if answer.get('interrupt') is True:
            cut_off()
            return
    else:
        final('planning')
        return
    log(feedback=(answer.get('updatedInput') or {}).get('userFeedback'))
    modes = [p.get('mode') for p in answer.get('updatedPermissions') or [] if p.get('type') == 'setMode']
    if modes:
        MODE = modes[0]
    elif MODE == 'plan':
        MODE = 'default'
    status(None, MODE)
    tool_result(tid, 'User has approved your plan. You can now start coding.', interactive=True)
    final('approved ' + MODE)


def s_plan2(prompt):
    """plan review's second round (finding 24): up to three plans in one turn, each denied with interrupt
    false planning again; an allow's userFeedback is logged ({"feedback": ...})"""
    plan_turn(['# Plan\n\n1. Add the file\n2. Test it', '# Plan, revised\n\n1. Add notes.txt\n2. Test it',
               '# Plan, third\n\n1. Add notes.txt'])


def s_planwithdraw(prompt):
    """planwithdraw [MS]: an ExitPlanMode Claude takes back by itself after MS (default 1000) unanswered
    (unrecorded, as `withdraw`); then the turn ends normally"""
    words = prompt.split()
    wait = int(words[1]) / 1000 if len(words) > 1 and words[1].isdigit() else 1.0
    plan = '# Plan\n\n1. Add the file\n2. Test it'
    path = os.path.join(config_dir(), 'plans', 'fake.md')
    PLAN[0] = {'content': plan, 'path': path}
    mid = message_start()
    tool_input = {'plan': plan, 'planFilePath': path}
    tid = tool_use(mid, 0, 'ExitPlanMode', tool_input)
    message_end('tool_use')
    rid = request_id()
    deadline = time.time() + wait
    with COND:
        PENDING[rid] = None
        emit({'type': 'control_request', 'request_id': rid, 'request': {
            'subtype': 'can_use_tool', 'tool_name': 'ExitPlanMode', 'display_name': 'ExitPlanMode',
            'input': tool_input, 'tool_use_id': tid, 'requires_user_interaction': True}})
        while PENDING.get(rid) is None and not withdrawn() and time.time() < deadline:
            COND.wait(0.05)
        answer = PENDING.pop(rid, None)
        if answer is None and not CLOSED.is_set():
            emit({'type': 'control_cancel_request', 'request_id': rid})
    if answer is not None:
        log(answer=answer)
    tool_result(tid, 'The user withdrew the plan' if answer is None else 'answered', answer is None)
    final('done')


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
    """thinking, then a short text; `think TEXT`: thinking with that text (finding 29's summarized form)"""
    if len(prompt.split()) > 1:
        think_text(prompt.split(None, 1)[1])
        return
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
    CLI reports under usage.cache_creation and modelUsage, finding 21), on its message and its result"""
    TURN_CACHE[0] = (2000, 30000)
    try:
        mid = message_start()
        if text(mid, 0, ['cached']):
            message_end()
            result('cached', cache=(2000, 30000))
        else:
            cut_off()
    finally:
        TURN_CACHE[0] = None


def s_rate(prompt):
    """rate KIND: a rate_limit_event of that kind (rate_limit) before the reply's result"""
    words = prompt.split()
    mid = message_start()
    if text(mid, 0, ['limits']):
        message_end()
        rate_limit(words[1] if len(words) > 1 else 'allowed')
        RATE_TURN[0] = True
        try:
            result('limits')
        finally:
            RATE_TURN[0] = False
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
    record = dict({'type': 'assistant', 'message': {
        'id': str(uuid.uuid4()), 'container': None, 'model': '<synthetic>', 'role': 'assistant',
        'stop_reason': 'end_turn', 'stop_sequence': None, 'type': 'message',
        'usage': {'input_tokens': 0, 'output_tokens': 0, 'cache_creation_input_tokens': 0,
                  'cache_read_input_tokens': 0}, 'content': [{'type': 'text', 'text': text_}],
        'context_management': None},
        'parent_tool_use_id': None, 'local_command_source': '<local-command-stdout>%s</local-command-stdout>' % text_,
        'session_id': SID, 'uuid': str(uuid.uuid4()), 'timestamp': now_iso()}, **(extra or {}))
    emit(record)
    LAST_ASSISTANT[0] = record
    local_lines(command)
    transcript({'type': 'system', 'subtype': 'local_command',
                'content': '<local-command-stdout>%s</local-command-stdout>' % text_, 'level': 'info',
                'after': {'isMeta': False}})
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
    (string content), the "Compacted" output echoed as a replay (with --replay-user-messages), the result.
    Finding 30: the boundary's metadata as 2.1.330 sends it; FAKE_CLAUDE_PRESERVED: the preserved segment's
    last record (the last assistant record) is sent again after the summary, with its uuid (20-compact); the
    file gets the boundary, the summary (isCompactSummary), the caveat, the command and its output."""
    emit({'type': 'system', 'subtype': 'status', 'status': 'compacting', 'session_id': SID, 'uuid': str(uuid.uuid4())})
    if 'start' in HOOKS_ON:
        hook_records('SessionStart', 'SessionStart:compact')
    time.sleep(int(ENV.get('FAKE_CLAUDE_COMPACT_MS', '200')) / 1000)    # task 5: compacting lasts that long
    emit({'type': 'system', 'subtype': 'status', 'status': None, 'compact_result': 'success', 'session_id': SID,
          'uuid': str(uuid.uuid4())})
    system_init()
    metadata = {'trigger': 'manual', 'pre_tokens': 45783, 'post_tokens': 14115, 'cumulative_dropped_tokens': 31668,
                'duration_ms': 6385}
    kept = LAST_ASSISTANT[0] if ENV.get('FAKE_CLAUDE_PRESERVED') else None
    if kept:
        metadata['preserved_segment'] = {'head_uuid': kept['uuid'], 'anchor_uuid': kept['uuid'], 'tail_uuid': kept['uuid']}
    emit({'type': 'system', 'subtype': 'compact_boundary', 'session_id': SID, 'uuid': str(uuid.uuid4()),
          'compact_metadata': metadata})
    summary = ('This session is being continued from a previous conversation that ran out of context. The summary '
               'below covers the earlier portion of the conversation.\n\nSummary: nothing yet.')
    emit({'type': 'user', 'message': {'role': 'user', 'content': summary},
          'session_id': SID, 'parent_tool_use_id': None, 'uuid': str(uuid.uuid4()), 'timestamp': now_iso(),
          'isReplay': False, 'isSynthetic': True})
    if kept:
        emit(kept)
    if REPLAY:
        emit({'type': 'user', 'message': {'role': 'user', 'content': '<local-command-stdout>Compacted </local-command-stdout>'},
              'session_id': SID, 'parent_tool_use_id': None, 'uuid': str(uuid.uuid4()), 'timestamp': now_iso(),
              'isReplay': True})
    transcript({'type': 'system', 'subtype': 'compact_boundary', 'content': 'Conversation compacted', 'isMeta': False,
                'after': {'level': 'info', 'compactMetadata': {'trigger': 'manual', 'preTokens': 45783, 'durationMs': 6385,
                                                               'postTokens': 14115, 'cumulativeDroppedTokens': 31668}}})
    transcript({'type': 'user', 'message': {'content': summary}, 'isVisibleInTranscriptOnly': True,
                'isCompactSummary': True})
    local_lines('compact')
    transcript({'type': 'user', 'message': {'content': '<local-command-stdout>Compacted </local-command-stdout>'}})
    local_result('', 'compact')


def c_fast(prompt):
    """/fast [on|off] (unrecorded: never tried, it may spend usage credits): fast mode on or off (bare: the
    other one), its reason gone; the answer as the other local commands', the result carrying the state."""
    words = prompt.split()
    FAST[0] = words[1] if len(words) > 1 and words[1] in ('on', 'off') else ('off' if FAST[0] == 'on' else 'on')
    FAST[1] = None
    synthetic('fast', 'Fast mode %s' % FAST[0].upper(), local='fast')


# the dialog cards (task 12): request_user_dialog {subtype, dialog_kind, payload, tool_use_id?}, answered
# {behavior "completed", result} or {behavior "cancelled"} (README.txt finding 25). No recording has one: the
# CLI asks for these only when a server or an account says so, which a test cannot provoke cheaply. The
# payloads below follow the CLI binary's schemas; their wording is the fake's own.
AUTO_DIALOGS = {
    'full': {'gatewayHost': 'gateway.example.com', 'title': 'Auto mode is using a fallback',
             'paragraphs': ['The auto mode service could not be reached from this network.',
                            'Claude Code checks each tool call with its own classifier for now.'],
             'helpUrl': 'https://code.claude.com/docs/en/permission-modes'},
    'empty': {'title': '  ', 'paragraphs': ['', '   ', 7], 'helpUrl': 'https://code.claude.com/docs/en/permission-modes'},
    'badurl': {'title': 'Auto mode is using a fallback', 'paragraphs': ['A paragraph.'],
               'helpUrl': 'http://claude.com.example.net/help'},
}
OVERAGE_DIALOGS = {
    'consent': {'overagesEnabled': True, 'modelName': 'Fable', 'model': 'fable', 'balanceCents': 1234,
                'currency': 'USD'},
    'nobalance': {'overagesEnabled': True, 'modelName': 'Fable', 'model': 'fable'},
    'disabled': {'overagesEnabled': False, 'modelName': 'Fable', 'model': 'fable', 'balanceCents': None},
    'empty': {'overagesEnabled': True, 'balanceCents': 0, 'currency': 'eur'},
    'admin': {'overagesEnabled': False, 'modelName': 'Fable', 'leftOutOf': 'seat', 'member': True, 'request': {}},
    'greyed': {'overagesEnabled': False, 'modelName': 'Fable', 'leftOutOf': 'seat', 'member': True,
               'request': {'greyed': 'Request sent'}},
    'plan': {'overagesEnabled': True, 'modelName': 'Fable', 'leftOutOf': 'plan', 'endedOn': '2026-11-30',
             'balanceCents': 123456, 'currency': 'USD'},
    'seat': {'overagesEnabled': False, 'leftOutOf': 'seat', 'endedOn': 'soon'},
    'ended': {'overagesEnabled': True, 'leftOutOf': 'plan', 'endedOn': False},
    'opus': {'overagesEnabled': True, 'modelName': 'Opus 5', 'balanceCents': 150000, 'currency': 'JPY'},
    'other': {'overagesEnabled': True, 'modelName': 'GPT', 'balanceCents': 99, 'currency': 'chf'},
    'odd': {'overagesEnabled': True, 'modelName': 'Fable', 'balanceCents': 250, 'currency': 'dollars'},
    'bad': {'overagesEnabled': 'yes', 'modelName': 'Fable'},
}
FALLBACK = [None]                   # the model a switch_default answer moved this process to


def dialog(kind, payload):
    """Sends a request_user_dialog and waits for its answer (logged; None: withdrawn or stdin closed)."""
    answer = ask_request(request_id(), {'subtype': 'request_user_dialog', 'dialog_kind': kind, 'payload': payload})
    if answer is not None:
        log(answer=answer)
    return answer


def s_dialog_auto(prompt):
    """dialog-auto [full|empty|badurl]: auto_mode_server_fallback; "continue" goes on, "interrupt" ends the turn"""
    words = prompt.split()
    answer = dialog('auto_mode_server_fallback', AUTO_DIALOGS[words[1] if len(words) > 1 else 'full'])
    if answer is not None:
        final('stopped' if answer.get('result') == 'interrupt' else 'continued')


def s_dialog_overage(prompt):
    """dialog-overage [VARIANT]: fable_overage_consent_prompt with OVERAGE_DIALOGS[VARIANT]; switch_default moves
    the process to the default model and says so as system/model_consent_fallback (the schema's record)"""
    words = prompt.split()
    payload = OVERAGE_DIALOGS[words[1] if len(words) > 1 else 'consent']
    answer = dialog('fable_overage_consent_prompt', payload)
    if answer is None:
        return
    choice = answer.get('result') if answer.get('behavior') == 'completed' else 'cancelled'
    if choice in ('switch_default', 'cancelled'):
        original = current_model()
        FALLBACK[0] = 'default'
        emit({'type': 'system', 'subtype': 'model_consent_fallback', 'choice': choice, 'original_model': original,
              'original_model_name': payload.get('modelName') or 'Fable', 'fallback_model': current_model(),
              'persisted_as_default': False, 'content': 'Switched to your default model.',
              'uuid': str(uuid.uuid4()), 'session_id': SID})
    final('answered ' + str(choice))


def s_dialog_other(prompt):
    """dialog-other: a dialog kind initialize did not declare (the extension's Remote Control offer)"""
    dialog('send_to_project_remote_control_offer', {'title': 'Remote Control is off'})
    final('done')


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
             'stream': s_stream, 'held': s_held, 'usage': s_usage, 'edit': s_edit, 'fetch': s_fetch,
             'rate': s_rate,
             'nosave': s_nosave, 'defno': s_defno, 'hook': s_hook, 'dirs': s_dirs, 'modeonly': s_modeonly,
             'mixed': s_mixed, 'sessiononly': s_sessiononly, 'bypass': s_bypass, 'pwsh': s_pwsh, 'net': s_net,
             'skill': s_skill, 'project': s_project, 'glob': s_glob, 'grep': s_grep, 'websearch': s_websearch,
             'other': s_other,
             'ask3': s_ask3,
             'dialog-auto': s_dialog_auto, 'dialog-overage': s_dialog_overage, 'dialog-other': s_dialog_other}
SCENARIOS.update({'plan2': s_plan2, 'planwithdraw': s_planwithdraw})    # plan review (task 11)


def s_bigcard(prompt):
    """a Bash call whose card has many lines (review finding A10): a long command, a description of 60
    paragraphs, a hook's reason of 20, and the rule with its directory and mode lines"""
    command = 'git log --format=%H ' + ' '.join('path/number/%d/of/a/long/list' % i for i in range(30))
    rules = [{'type': 'addRules', 'rules': [{'toolName': 'Bash', 'ruleContent': command}], 'behavior': 'allow',
              'destination': 'localSettings'},
             {'type': 'addDirectories', 'directories': [os.path.join(CWD, 'lib')], 'destination': 'session'},
             {'type': 'setMode', 'mode': 'plan', 'destination': 'session'}]
    extra = {'description': '\n'.join('Paragraph %d of the description' % i for i in range(60))}
    request = {'decision_reason': '\n'.join('Reason %d of the hook' % i for i in range(20)),
               'decision_reason_type': 'hook'}
    if bash(command, extra=extra, rules=rules, request=request):
        final('done')


def s_askmax(prompt):
    """the question card at its limits (review finding A10): 16 questions of 16 options, long labels and
    descriptions"""
    s_ask(prompt, [{'question': 'Question %d asks about something at some length?' % q, 'header': 'Q%d' % q,
                    'multiSelect': q % 2 == 1,
                    'options': [{'label': 'Option %d of question %d with a long label' % (o, q),
                                 'description': 'What option %d of question %d means, at some length' % (o, q)}
                                for o in range(16)]} for q in range(16)])


SCENARIOS.update({'bigcard': s_bigcard, 'askmax': s_askmax})     # the phase 2 reviews' findings


# ---- Phase 3 (README.txt findings 27 to 37): the tools' results, the file's records, thinking with text,
# subagents and tasks, hooks. Every record keeps the recorded field order (keys.txt, and file-keys.txt for
# the file's lines); what no run recorded says so.

HOOK_EVENTS = '--include-hook-events' in FLAGS      # 32: UserPromptSubmit's and Stop's records too
# FAKE_CLAUDE_HOOKS, comma-separated: start (SessionStart's records before the initialize answer and during
# /compact), prompt (UserPromptSubmit's, with --include-hook-events), block (a prompt holding BLOCKME is
# blocked by it), stop (Stop's before every result, with the flag; the file's stop_hook_summary), post (a
# PostToolUse hook's context after a Read, in the file only)
HOOKS_ON = set(filter(None, ENV.get('FAKE_CLAUDE_HOOKS', '').split(',')))
TASKS = bool(ENV.get('FAKE_CLAUDE_TASKS'))          # 28: the task tools in place of TodoWrite
WAIT_MS = int(ENV.get('FAKE_CLAUDE_BG_MS', '3000'))  # how long `bg` runs in the foreground, a task in the background
NOTES = 'one\ntwo\nthree\nfour\nfive\n'             # what `tools` reads (nothing is read or written there)
A_PY = ''.join('x%d = %d  # line %d\n' % (i, i, i) for i in range(1, 9)) + 'def f(x):\n    return x\n'
DOT = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC'
SAVED = ' (file state is current in your context — no need to Read it back)'
CAVEAT = ("<local-command-caveat>The command below was run directly in Claude Code, not sent to you as a request, "
          "and its output goes straight to the user. It's recorded here as context for later messages."
          "</local-command-caveat>")
# 36: a call stopped while it ran (the bundle's cTt)
STOPPED = (REJECTED + ' Correction to the text above: this call was stopped while running, not refused before it '
           'ran. It may have run in part or in full, and its changes may have been written. No permission prompt '
           'was involved. Work it started elsewhere (a remote command, a background process) may still be running, '
           'so check before starting the same work again. The instruction to stop and wait still stands.')
TODO_DONE = ('Todos have been modified successfully. Ensure that you continue to use the todo list to track your '
             'progress. Please proceed with the current tasks if applicable')
LIVE = {}                           # task id -> a running task (`agent`, `bg`): stop_task and background_tasks find it


def todo_tools():
    """system/init's todo tools (28: on a 5.x model only with an opt-in; the fake lists them always)."""
    return ['TaskCreate', 'TaskGet', 'TaskList', 'TaskUpdate'] if TASKS else ['TodoWrite']


def at(name):
    return os.path.join(CWD, name)


def hook_records(event, name):
    """A hook's hook_started and hook_response (32): SessionStart's always, the others only with
    --include-hook-events; Stop also writes the file's stop_hook_summary."""
    if event == 'SessionStart' or HOOK_EVENTS:
        hid = str(uuid.uuid4())
        emit({'type': 'system', 'subtype': 'hook_started', 'hook_id': hid, 'hook_name': name, 'hook_event': event,
              'uuid': str(uuid.uuid4()), 'session_id': SID})
        time.sleep(int(ENV.get('FAKE_CLAUDE_HOOK_MS', '0')) / 1000)     # task 5: the hook runs that long
        emit({'type': 'system', 'subtype': 'hook_response', 'hook_id': hid, 'hook_name': name, 'hook_event': event,
              'output': 'hi\n', 'stdout': 'hi\n', 'stderr': '', 'exit_code': 0, 'outcome': 'success',
              'uuid': str(uuid.uuid4()), 'session_id': SID})
    if event == 'Stop':
        transcript({'type': 'system', 'subtype': 'stop_hook_summary', 'hookCount': 1,
                    'hookInfos': [{'command': 'echo hi', 'durationMs': 5}], 'hookErrors': [],
                    'failedHookErrorIndexes': [], 'hookAdditionalContext': [], 'preventedContinuation': False,
                    'stopReason': '', 'hasOutput': False, 'level': 'suggestion',
                    'after': {'toolUseID': str(uuid.uuid4())}})


def prompt_hook(prompt):
    """UserPromptSubmit's records; with `block` a prompt holding BLOCKME is blocked (32): system/init,
    system/informational, the result, no prompt line in the file. True: it was blocked."""
    hook_records('UserPromptSubmit', 'UserPromptSubmit')
    if 'block' not in HOOKS_ON or 'BLOCKME' not in prompt:
        return False
    system_init()
    said = 'UserPromptSubmit operation blocked by hook:\n[fake hook]: Blocked by the test hook\n\n\nOriginal prompt: ' + prompt
    emit({'type': 'system', 'subtype': 'informational', 'content': said, 'level': 'warning',
          'prevent_continuation': True, 'prompt_submit_outcome': {'kind': 'blocked_by_hook', 'prompt_kept': False},
          'uuid': str(uuid.uuid4()), 'session_id': SID})
    transcript({'type': 'system', 'subtype': 'informational', 'content': said, 'isMeta': False,
                'after': {'level': 'warning', 'preventContinuation': True, 'promptSubmitEnding': {
                    'ending': {'kind': 'blocked_by_hook', 'reason': 'Blocked by the test hook'}, 'promptKept': False}}})
    local_result(said, None)
    return True


def local_lines(command):
    """A command the CLI ran itself, in the file (31): the caveat (isMeta) and the command's line."""
    transcript({'type': 'user', 'message': {'content': CAVEAT}, 'isMeta': True})
    transcript({'type': 'user', 'message': {'content': '<command-name>/%s</command-name>\n            <command-message>'
                                                      '%s</command-message>\n            <command-args></command-args>'
                                                      % (command, command)}})


def custom_command(prompt, entry):
    """`echo [NAME]` (or /NAME with <cwd>/.claude/commands/NAME.md): a custom command as 31 has it: its
    replayed string (message first, no args), in the file that string and the command's text (isMeta),
    then the reply. True: it was one."""
    words = prompt.split()
    if words[:1] == ['echo']:
        name, body = (words[1] if len(words) > 1 else 'hi'), 'Reply with the word hi.\n'
    elif words and words[0].startswith('/') and os.path.isfile(at('.claude/commands/%s.md' % words[0][1:])):
        name = words[0][1:]
        with open(at('.claude/commands/%s.md' % name), encoding='utf-8') as stream:
            body = stream.read()
    else:
        return False
    said = '<command-message>%s</command-message>\n<command-name>/%s</command-name>' % (name, name)
    if REPLAY:
        emit({'type': 'user', 'message': {'role': 'user', 'content': said}, 'session_id': SID,
              'parent_tool_use_id': None, 'uuid': entry['uuid'] or str(uuid.uuid4()), 'timestamp': now_iso(),
              'isReplay': True})
    transcript({'type': 'user', 'message': {'content': said}})
    transcript({'type': 'user', 'message': {'content': [{'type': 'text', 'text': body}]}, 'isMeta': True})
    final('hi')
    return True


# the tools' outcomes, (content, is_error, structured result), as finding 28 recorded them

def read_text(path, text_, offset=None, limit=None):
    lines = text_.split('\n')
    start = offset or 1
    shown = lines[start - 1:start - 1 + (limit or len(lines))]
    return ('\n'.join('%d\t%s' % (start + i, line) for i, line in enumerate(shown)), False,
            {'type': 'text', 'file': {'filePath': path, 'content': '\n'.join(shown) if offset or limit else text_,
                                      'numLines': len(shown), 'startLine': start, 'totalLines': len(lines)}})


def read_image(path, data):
    return ([{'type': 'image', 'source': {'type': 'base64', 'data': data, 'media_type': 'image/png'}}], False,
            {'type': 'image', 'file': {'base64': data, 'type': 'image/png', 'originalSize': len(data) * 3 // 4,
                                       'dimensions': {'originalWidth': 1, 'originalHeight': 1, 'displayWidth': 1,
                                                      'displayHeight': 1}}})


def read_missing():
    said = 'File does not exist. Note: your current working directory is %s.' % CWD
    return said, True, 'Error: ' + said


def read_call(path, offset=None, limit=None):
    """Read of a file on disk: its lines, an image for a .png, the error for a missing one."""
    try:
        with open(path, 'rb') as stream:
            data = stream.read()
    except OSError:
        return read_missing()
    if path.endswith('.png'):
        import base64
        return read_image(path, base64.b64encode(data).decode())
    return read_text(path, data.decode('utf-8', 'replace'), offset, limit)


def patch(old, new):
    """structuredPatch: one hunk with every line (context, removed, added)."""
    import difflib
    a, b = old.split('\n'), new.split('\n')
    lines = []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b).get_opcodes():
        if tag == 'equal':
            lines += [' ' + line for line in a[i1:i2]]
        else:
            lines += ['-' + line for line in a[i1:i2]] + ['+' + line for line in b[j1:j2]]
    return [{'oldStart': 1, 'oldLines': len(a), 'newStart': 1, 'newLines': len(b), 'lines': lines}]


def edit_outcome(path, text_, old, new, replace_all=False):
    if old not in text_:
        said = 'String to replace not found in file.\nString: %s' % old
        return '<tool_use_error>%s</tool_use_error>' % said, True, 'Error: ' + said
    changed = text_.replace(old, new) if replace_all else text_.replace(old, new, 1)
    said = ('The file %s has been updated. All occurrences were successfully replaced.' % path if replace_all
            else 'The file %s has been updated successfully.%s' % (path, SAVED))
    return said, False, {'filePath': path, 'oldString': old, 'newString': new, 'originalFile': text_,
                         'structuredPatch': patch(text_, changed), 'userModified': False, 'replaceAll': replace_all}


def write_outcome(path, content, old=None):
    if old is None:
        return ('File created successfully at: %s%s' % (path, SAVED), False,
                {'type': 'create', 'filePath': path, 'content': content, 'structuredPatch': [], 'originalFile': None,
                 'userModified': False})
    return ('The file %s has been updated successfully.%s' % (path, SAVED), False,
            {'type': 'update', 'filePath': path, 'content': content, 'structuredPatch': patch(old, content),
             'originalFile': old, 'userModified': False})


def bash_outcome(out, **more):
    return out, False, dict({'stdout': out, 'stderr': '', 'interrupted': False, 'isImage': False,
                             'noOutputExpected': False}, **more)


def bash_failed(said):
    return said, True, 'Error: ' + said


def grep_calls():
    hits = ['a.py:%d:x%d = %d  # row %d' % (i, i, i, i) for i in range(1, 9)]
    return [('Grep', {'pattern': 'row', 'output_mode': 'content'},
             ('\n'.join(hits), False, {'mode': 'content', 'numFiles': 0, 'filenames': [], 'content': '\n'.join(hits),
                                       'numLines': 8, 'totalLines': 8})),
            ('Grep', {'pattern': 'row', 'output_mode': 'files_with_matches'},
             ('Found 1 file\na.py', False, {'mode': 'files_with_matches', 'filenames': ['a.py'], 'numFiles': 1,
                                            'totalFiles': 1})),
            ('Grep', {'pattern': 'row', 'output_mode': 'count'},
             ('a.py:8\n\nFound 8 total occurrences across 1 file.', False,
              {'mode': 'count', 'numFiles': 1, 'filenames': [], 'content': 'a.py:8', 'numMatches': 8}))]


def glob_outcome(names):
    return ('\n'.join(names) or 'No files found', False,
            {'filenames': names, 'durationMs': 13, 'numFiles': len(names), 'truncated': False,
             'totalMatches': len(names), 'countIsComplete': True})


def websearch_outcome(query):
    links = [{'title': 'rhun', 'url': 'https://rhun.app'}, {'title': 'Example Domain', 'url': 'https://example.com'}]
    return ('Web search results for query: "%s"\n\nLinks: %s\n\nThe search found two pages.' % (
        query, json.dumps(links, separators=(',', ':'))), False,
        {'query': query, 'results': [{'tool_use_id': 'srvtoolu_fake' + uuid.uuid4().hex[:12], 'content': links},
                                     'The search found two pages.'], 'durationSeconds': 1.2, 'searchCount': 1})


def toolsearch_outcome(names, query):
    return ([{'type': 'tool_reference', 'tool_name': name} for name in names], False,
            {'matches': names, 'query': query, 'total_deferred_tools': 120})


def give(tid, name, outcome, agent=None):
    """A call's result in the recorded block order (a failure: type, content, is_error, tool_use_id; Bash:
    tool_use_id, type, content, is_error; ToolSearch: type, tool_use_id, content; the others: tool_use_id,
    type, content) with its structured result; agent: a subagent's (no structured result, its own file)."""
    content, is_error, structured = outcome
    if is_error:
        block = {'type': 'tool_result', 'content': content, 'is_error': True, 'tool_use_id': tid}
    elif name == 'Bash':
        block = {'tool_use_id': tid, 'type': 'tool_result', 'content': content, 'is_error': False}
    elif name == 'ToolSearch':
        block = {'type': 'tool_result', 'tool_use_id': tid, 'content': content}
    else:
        block = {'tool_use_id': tid, 'type': 'tool_result', 'content': content}
    if agent is not None:
        sub_record(agent, 'user', block)
    elif structured is None:
        user(block)
    else:
        user(block, tool_use_result=structured)
    if name == 'Read' and 'post' in HOOKS_ON and agent is None:     # 32: the context reaches the file only
        context = 'The test hook saw this read.'
        transcript({'type': 'attachment', 'attachment': {
            'type': 'hook_success', 'hookName': 'PostToolUse:Read', 'toolUseID': tid, 'hookEvent': 'PostToolUse',
            'content': '', 'stdout': json.dumps({'hookSpecificOutput': {'hookEventName': 'PostToolUse',
                                                                        'additionalContext': context}}) + '\n',
            'stderr': '', 'exitCode': 0, 'command': 'fake hook', 'durationMs': 41}})
        transcript({'type': 'attachment', 'attachment': {'type': 'hook_additional_context', 'content': [context],
                                                          'hookName': 'PostToolUse:Read', 'toolUseID': tid,
                                                          'hookEvent': 'PostToolUse'}})


def run_calls(calls):
    """One message with these calls [(name, input, outcome)], as 2.1.330 streams them (18-tools): each call's
    result goes out while the next call streams, the last one's after message_stop. The call ids."""
    mid = message_start()
    tids, waiting = [], []
    for index, (name, tool_input, outcome) in enumerate(calls):
        tid = 'toolu_fake' + uuid.uuid4().hex[:16]
        stream_event({'type': 'content_block_start', 'index': index, 'content_block': {
            'type': 'tool_use', 'id': tid, 'name': name, 'input': {}, 'caller': {'type': 'direct'}}})
        stream_event({'type': 'content_block_delta', 'index': index, 'delta': {'type': 'input_json_delta',
                                                                                'partial_json': ''}})
        while waiting:
            give(*waiting.pop(0))
        stream_event({'type': 'content_block_delta', 'index': index, 'delta': {
            'type': 'input_json_delta', 'partial_json': json.dumps(tool_input, ensure_ascii=False)}})
        assistant(mid, {'type': 'tool_use', 'id': tid, 'name': name, 'input': tool_input, 'caller': {'type': 'direct'}})
        stream_event({'type': 'content_block_stop', 'index': index})
        waiting.append((tid, name, outcome))
        tids.append(tid)
    message_end('tool_use')
    while waiting:
        give(*waiting.pop(0))
    return tids


def ran_calls(calls, words='ok'):
    """Calls that ran without asking, then the reply."""
    run_calls(calls)
    final(words)


def s_tools(prompt):
    """tools: one call of every recorded tool with its result (finding 28), none asks, made-up files (nothing
    is read or written): two Reads in one message as 18-tools, a missing file and an image, three Edits (one
    replace_all, one not found), two Writes (new, over a file), Bash (output, a failure), Grep's three modes,
    Glob (matches, none), ToolSearch, WebSearch, WebFetch (called directly: unrecorded, 2.1.330 sent it to its
    web-fetch agent, whose result has no structured part), the todo tool (FAKE_CLAUDE_TASKS: the task tools)"""
    notes, a_py = at('notes.txt'), at('a.py')
    run_calls([('Read', {'file_path': notes}, read_text(notes, NOTES)),
               ('Read', {'file_path': a_py, 'offset': 2, 'limit': 3}, read_text(a_py, A_PY, 2, 3))])
    run_calls([('Read', {'file_path': at('missing.txt')}, read_missing()),
               ('Read', {'file_path': at('dot.png')}, read_image(at('dot.png'), DOT))])
    edited = NOTES.replace('two', 'TWO', 1)
    run_calls([('Edit', {'replace_all': False, 'file_path': notes, 'old_string': 'two', 'new_string': 'TWO'},
                edit_outcome(notes, NOTES, 'two', 'TWO')),
               ('Edit', {'replace_all': True, 'file_path': a_py, 'old_string': '# line', 'new_string': '# row'},
                edit_outcome(a_py, A_PY, '# line', '# row', True)),
               ('Edit', {'replace_all': False, 'file_path': a_py, 'old_string': 'nothing-here', 'new_string': 'x'},
                edit_outcome(a_py, A_PY, 'nothing-here', 'x'))])
    run_calls([('Write', {'file_path': at('new.txt'), 'content': 'hello'}, write_outcome(at('new.txt'), 'hello')),
               ('Write', {'file_path': notes, 'content': 'only line'}, write_outcome(notes, 'only line', edited))])
    run_calls([('Bash', {'command': 'echo out', 'description': 'Print out'}, bash_outcome('out')),
               ('Bash', {'command': 'ls missing-dir', 'description': 'List missing directory'},
                bash_failed('Exit code 1\nls: missing-dir: No such file or directory'))])
    run_calls(grep_calls())
    run_calls([('Glob', {'pattern': '*.py'}, glob_outcome(['a.py'])), ('Glob', {'pattern': '*.zzz'}, glob_outcome([]))])
    run_calls([('ToolSearch', {'query': 'select:WebSearch', 'max_results': 1},
                toolsearch_outcome(['WebSearch'], 'select:WebSearch'))])
    run_calls([('WebSearch', {'query': 'IANA example domain', 'mode': 'standard'}, websearch_outcome('IANA example domain'))])
    run_calls([('WebFetch', {'url': 'https://example.com', 'prompt': 'Report the title'},
                ('Fetched https://example.com/ from a non-preapproved source (HTTP 200 OK, text/html, 172 characters).'
                 '\n<fetched-web-content>\nExample Domain\n</fetched-web-content>', False, None))])
    todo_calls()
    final('ok')


def todo_calls():
    """The todo list as finding 28 has it: ToolSearch first (deferred), then TodoWrite with the whole list, or
    (FAKE_CLAUDE_TASKS) a TaskCreate a message and a TaskUpdate."""
    if TASKS:
        run_calls([('ToolSearch', {'query': 'select:TaskCreate,TaskUpdate', 'max_results': 2},
                    toolsearch_outcome(['TaskCreate', 'TaskUpdate'], 'select:TaskCreate,TaskUpdate'))])
        for n, subject in enumerate(('a', 'b', 'c'), 1):
            task = {'id': str(n), 'subject': subject, 'description': 'Todo item ' + subject}
            run_calls([('TaskCreate', {'subject': subject, 'description': task['description']},
                        ('Task #%d created successfully: %s' % (n, subject), False, {'task': task}))])
        run_calls([('TaskUpdate', {'taskId': '1', 'status': 'completed'},
                    ('Updated task #1 status', False, {'success': True, 'taskId': '1', 'updatedFields': ['status'],
                                                       'statusChange': {'from': 'pending', 'to': 'completed'}}))])
        return
    run_calls([('ToolSearch', {'query': 'select:TodoWrite', 'max_results': 1},
                toolsearch_outcome(['TodoWrite'], 'select:TodoWrite'))])
    todos = [{'content': 'a', 'status': 'completed', 'activeForm': 'Completing a'},
             {'content': 'b', 'status': 'in_progress', 'activeForm': 'Working on b'},
             {'content': 'c', 'status': 'pending', 'activeForm': 'Working on c'}]
    run_calls([('TodoWrite', {'todos': todos}, (TODO_DONE, False, {'oldTodos': [], 'newTodos': todos}))])


def s_todo(prompt):
    """todo: a todo list of three items, one done (finding 28; FAKE_CLAUDE_TASKS: the task tools)"""
    todo_calls()
    final('ok')


def s_read(prompt):
    """read [FILE]: a Read of a file of the project (default notes.txt): its lines, an image, or the error"""
    words = prompt.split(None, 1)
    path = at(words[1].strip() if len(words) > 1 else 'notes.txt')
    ran_calls([('Read', {'file_path': path}, read_call(path))])


def s_image(prompt):
    """image: a Read of an image (finding 33): dot.png of the project, or a made-up 1x1 one"""
    path = at('dot.png')
    ran_calls([('Read', {'file_path': path}, read_call(path) if os.path.exists(path) else read_image(path, DOT))])


def s_write(prompt):
    """write [FILE [TEXT]]: a Write (default new.txt, "hello"): asks as Edit does unless the mode or a rule lets
    it run (the recorded request had Write's own suggestions; the fake offers acceptEdits); the file is written"""
    words = prompt.split(None, 2)
    path = at(words[1] if len(words) > 1 else 'new.txt')
    content = words[2] if len(words) > 2 else 'hello'
    tool_input = {'file_path': path, 'content': content}
    mid = message_start()
    tid = tool_use(mid, 0, 'Write', tool_input)
    message_end('tool_use')
    if MODE in ('acceptEdits', 'bypassPermissions') or rule_allows('Write', path):
        answer = {'behavior': 'allow'}
    else:
        answer = ask_request(request_id(), {
            'subtype': 'can_use_tool', 'tool_name': 'Write', 'display_name': 'Write', 'input': tool_input,
            'description': os.path.basename(path),
            'permission_suggestions': [{'type': 'setMode', 'mode': 'acceptEdits', 'destination': 'session'}],
            'tool_use_id': tid})
        if answer is None:
            tool_result(tid, REJECTED, True)
            cut_off(tool_turn=True)
            return
        log(answer=answer)
    if answer.get('behavior') == 'allow':
        apply_updates(answer)
        try:
            with open(path, encoding='utf-8') as stream:
                old = stream.read()
        except OSError:
            old = None
        try:
            with open(path, 'w', encoding='utf-8') as stream:
                stream.write(content)
        except OSError:
            pass
        give(tid, 'Write', write_outcome(path, content, old))
        final('written')
        return
    DENIALS.append({'tool_name': 'Write', 'tool_use_id': tid, 'tool_input': tool_input})
    tool_result(tid, answer.get('message', ''), True)
    if answer.get('interrupt') is True:
        cut_off(tool_turn=True)
    else:
        final('not written')


def s_toolerror(prompt):
    """toolerror: two failed calls (finding 36): a missing file (plain text) and an Edit whose string is not
    there (<tool_use_error>)"""
    a_py = at('a.py')
    ran_calls([('Read', {'file_path': at('missing.txt')}, read_missing()),
               ('Edit', {'replace_all': False, 'file_path': a_py, 'old_string': 'nothing-here', 'new_string': 'x'},
                edit_outcome(a_py, A_PY, 'nothing-here', 'x'))], 'Both failed.')


def s_denied(prompt):
    """denied: a Bash call a deny rule refuses without asking (finding 36): system/permission_denied, the
    error result, the result's permission_denials"""
    mid = message_start()
    tool_input = {'command': 'touch d3.txt', 'description': 'Create file d3.txt'}
    tid = tool_use(mid, 0, 'Bash', tool_input)
    message_end('tool_use')
    said = 'Permission to use Bash with command touch d3.txt has been denied.'
    emit({'type': 'system', 'subtype': 'permission_denied', 'tool_name': 'Bash', 'tool_use_id': tid,
          'decision_reason_type': 'rule', 'message': said, 'uuid': str(uuid.uuid4()), 'session_id': SID})
    DENIALS.append({'tool_name': 'Bash', 'tool_use_id': tid, 'tool_input': tool_input})
    give(tid, 'Bash', (said, True, 'Error: ' + said))
    final('The command was denied.')


def think_text(said):
    """Thinking with text (finding 29, the "summarized" display): its deltas carry the text, a thinking_tokens
    record after each, the record has the whole text, its duration and display; then a short reply."""
    mid = message_start()
    stream_event({'type': 'content_block_start', 'index': 0,
                  'content_block': {'type': 'thinking', 'thinking': '', 'signature': ''}}, thinking_display='summarized')
    estimate = 0
    for piece in thirds(said.split(' ')):
        piece = ' '.join(piece) + ' '
        estimate += max(1, len(piece) // 4)
        thinking_tokens(estimate, max(1, len(piece) // 4))
        stream_event({'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'thinking_delta', 'thinking': piece}},
                     thinking_display='summarized')
    thinking_tokens(estimate + 375, 375)
    stream_event({'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'signature_delta', 'signature': 'c2lnbmF0dXJl'}})
    assistant(mid, {'type': 'thinking', 'thinking': said, 'signature': 'c2lnbmF0dXJl'}, thinking_duration_ms=3109,
              thinking_display='summarized')
    stream_event({'type': 'content_block_stop', 'index': 0})
    if text(mid, 1, ['thought ', 'it ', 'through']):
        message_end()
        result('thought it through')
    else:
        cut_off()


def s_unknownblock(prompt):
    """unknownblock: a content block of a type nobody knows ("mystery"; unrecorded), then a text"""
    mid = message_start()
    stream_event({'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'mystery', 'data': 'x'}})
    assistant(mid, {'type': 'mystery', 'data': 'x'})
    stream_event({'type': 'content_block_stop', 'index': 0})
    if text(mid, 1, ['after ', 'it']):
        message_end()
        result('after it')


def s_apierror(prompt):
    """apierror (unrecorded: no run provoked one; the shapes are the CLI binary's schemas, finding 35):
    system/api_retry, then the <synthetic> reply with error "overloaded", then an error result"""
    emit({'type': 'system', 'subtype': 'api_retry', 'attempt': 1, 'max_retries': 10, 'retry_delay_ms': 500,
          'error_status': 529, 'error': 'overloaded', 'uuid': str(uuid.uuid4()), 'session_id': SID})
    said = 'API Error: Repeated 529 Overloaded errors'
    emit({'type': 'assistant', 'message': {'id': str(uuid.uuid4()), 'model': '<synthetic>', 'role': 'assistant',
                                           'type': 'message', 'content': [{'type': 'text', 'text': said}]},
          'parent_tool_use_id': None, 'error': 'overloaded', 'uuid': str(uuid.uuid4()), 'session_id': SID})
    transcript({'type': 'assistant', 'message': {'id': str(uuid.uuid4()), 'model': '<synthetic>',
                                                 'content': [{'type': 'text', 'text': said}]},
                'error': 'overloaded'})     # (the record's own key, kept in the file as the stream has it: unrecorded)
    result(subtype='error_during_execution', errors=[said], stop=None, terminal='api_error')


def s_hooks(prompt):
    """hooks: a Read, so the hooks FAKE_CLAUDE_HOOKS names have their records (finding 32)"""
    notes = at('notes.txt')
    ran_calls([('Read', {'file_path': notes}, read_call(notes))])


def new_task(kind, tid, description, **more):
    task = dict({'task_id': ('a' + uuid.uuid4().hex[:16]) if kind == 'agent' else ('b' + uuid.uuid4().hex[:8]),
                 'run_id': uuid.uuid4().hex[:10], 'kind': kind, 'tid': tid, 'description': description,
                 'background': kind == 'agent', 'moved': threading.Event(), 'stopped': threading.Event()}, **more)
    with COND:
        LIVE[task['task_id']] = task
    return task


def task_entry(task):
    """A task as background_tasks_changed lists it."""
    entry = {'task_id': task['task_id'], 'run_id': task['run_id'],
             'task_type': 'local_agent' if task['kind'] == 'agent' else 'local_bash'}
    if task['kind'] == 'agent':
        entry['subagent_type'] = 'general-purpose'
    entry['description'] = task['description']
    return entry


def tasks_changed():
    with COND:
        live = [task_entry(t) for t in LIVE.values() if t['background']]
    emit({'type': 'system', 'subtype': 'background_tasks_changed', 'tasks': live, 'uuid': str(uuid.uuid4()),
          'session_id': SID})


def task_end(task, status, notified):
    """task_updated (a background task), task_notification, background_tasks_changed (34)."""
    with COND:
        LIVE.pop(task['task_id'], None)
    if task['background']:
        emit({'type': 'system', 'subtype': 'task_updated', 'task_id': task['task_id'], 'run_id': task['run_id'],
              'patch': {'status': status, 'end_time': int(time.time() * 1000)}, 'uuid': str(uuid.uuid4()),
              'session_id': SID})
    summary = task['description']   # task 11: an agent's, as the file's <task-notification> has it
    if task['kind'] == 'agent':
        summary = ('Agent "%s" completed' if notified == 'completed' else 'Agent "%s" was stopped by user') % summary
    emit({'type': 'system', 'subtype': 'task_notification', 'task_id': task['task_id'], 'run_id': task['run_id'],
          'tool_use_id': task['tid'], 'status': notified,
          'output_file': task.get('output', '') if task['background'] else '', 'summary': summary,
          'uuid': str(uuid.uuid4()), 'session_id': SID})
    if task['background']:
        tasks_changed()


def stop_task(rid, task_id):
    """stop_task (34): answered {} after the task's records; an id no task has (unrecorded): an error."""
    with COND:
        task = LIVE.get(task_id)
    if task is None:
        respond_error(rid, 'No task found with ID: %s' % task_id)
        return
    task_end(task, 'killed', 'stopped')
    respond(rid, {})
    task['stopped'].set()


def to_background(rid, tid):
    """background_tasks {tool_use_id} (34): a running foreground call moves ({backgrounded true}); anything
    else answers {backgrounded false}."""
    with COND:
        task = next((t for t in LIVE.values() if t['tid'] == tid and not t['background']), None)
        if task:
            task['background'] = True
    if task:
        tasks_changed()
        emit({'type': 'system', 'subtype': 'task_updated', 'task_id': task['task_id'], 'run_id': task['run_id'],
              'patch': {'is_backgrounded': True}, 'uuid': str(uuid.uuid4()), 'session_id': SID})
    respond(rid, {'backgrounded': task is not None})
    if task:
        task['moved'].set()


def s_bg(prompt):
    """bg: a Bash call ("sleep 20; echo done") that runs in the foreground for FAKE_CLAUDE_BG_MS (default 3 s)
    and ends with "done", unless background_tasks moves it (its result at once, "Command was manually
    backgrounded by user ...", then it ends by itself that long later or stop_task kills it) or an interrupt
    stops it (the bundle's cTt text, tool_use_result "User rejected tool use", aborted_tools) (34, 36)"""
    mid = message_start()
    tool_input = {'command': 'sleep 20; echo done', 'description': 'Sleep 20 seconds then echo done'}
    tid = tool_use(mid, 0, 'Bash', tool_input)
    message_end('tool_use')
    task = new_task('shell', tid, tool_input['description'], background=False)
    task['output'] = os.path.join(CWD, '.fake-tasks', task['task_id'] + '.output')
    emit({'type': 'system', 'subtype': 'task_started', 'task_id': task['task_id'], 'run_id': task['run_id'],
          'tool_use_id': tid, 'description': task['description'], 'is_backgrounded': False, 'task_type': 'local_bash',
          'uuid': str(uuid.uuid4()), 'session_id': SID})
    deadline = time.time() + WAIT_MS / 1000
    while not task['moved'].is_set() and not withdrawn() and time.time() < deadline:
        task['moved'].wait(0.05)
    if not task['moved'].is_set() and interrupted_now():
        task_end(task, 'killed', 'stopped')
        give(tid, 'Bash', (STOPPED, True, 'User rejected tool use'))
        cut_off(tool_turn=True)
        return
    if not task['moved'].is_set():
        task_end(task, 'completed', 'completed')
        give(tid, 'Bash', bash_outcome('done'))
        final('done')
        return
    said = ('Command was manually backgrounded by user with ID: %s. Output is being written to: %s If it is still '
            'running after 30m in the background, it will be stopped and you will be notified.' % (
                task['task_id'], task['output']))
    give(tid, 'Bash', (said, False, bash_outcome('', backgroundTaskId=task['task_id'], backgroundedByUser=True)[2]))
    final('It runs in the background.')
    if not task['stopped'].wait(WAIT_MS / 1000):
        task_end(task, 'completed', 'completed')


# a subagent's own model and context (its records must move neither the reply labels nor the context numbers:
# made different from the main agent's so a test can tell; 21-agent's ran haiku under haiku)
SUB_MODEL = 'claude-haiku-5-5'
SUB_USAGE = {'input_tokens': 6, 'cache_creation_input_tokens': 0, 'cache_read_input_tokens': 34588, 'output_tokens': 12}


def sub_record(agent, kind, block, parent_text=False):
    """A subagent's record (34): in the stream with parent_tool_use_id and agent_id, no stream_event, a tool's
    result without tool_use_result; in its own file (isSidechain, agentId), never the conversation's."""
    record = {'type': kind, 'message': ({'model': SUB_MODEL, 'id': agent['mid'], 'type': 'message',
                                         'role': 'assistant', 'content': [block], 'stop_reason': None,
                                         'usage': SUB_USAGE} if kind == 'assistant'
                                        else {'role': 'user', 'content': [block]}),
              'parent_tool_use_id': agent['tid'], 'agent_id': agent['task_id'], 'session_id': SID,
              'uuid': str(uuid.uuid4()), 'timestamp': now_iso()}
    emit(record)
    message = {'id': agent['mid'], 'model': SUB_MODEL, 'content': [block]} if kind == 'assistant' else \
        {'content': [block]}
    transcript({'type': kind, 'message': message}, path=agent['file'], chain=agent['chain'], agent=agent['task_id'])


def sub_call(agent, name, tool_input, outcome):
    """A subagent's call, its progress record and its result."""
    tid = 'toolu_fake' + uuid.uuid4().hex[:16]
    sub_record(agent, 'assistant', {'type': 'tool_use', 'id': tid, 'name': name, 'input': tool_input,
                                    'caller': {'type': 'direct'}})
    agent['calls'] += 1
    emit({'type': 'system', 'subtype': 'task_progress', 'task_id': agent['task_id'], 'run_id': agent['run_id'],
          'tool_use_id': agent['tid'], 'description': 'Running ' + tool_input.get('description', name),
          'subagent_type': 'general-purpose', 'usage': {'total_tokens': 34606 + agent['calls'],
                                                        'tool_uses': agent['calls'], 'duration_ms': 1209},
          'last_tool_name': name, 'uuid': str(uuid.uuid4()), 'session_id': SID})
    give(tid, name, outcome, agent)


def s_agent(prompt):
    """agent [wait]: an Agent call that runs in the background (finding 34, 21-agent): the task records, the
    call's result at once (async_launched, no count), the turn's reply; the agent's first call before the
    turn's result, its second call and its report after it, then its end (task_updated, task_notification,
    background_tasks_changed) and the turn the notification starts (the <task-notification> string, a reply,
    a result). Its records are in <config>/projects/<slug>/<id>/subagents/agent-<id>.jsonl with a .meta.json.
    `agent wait`: it waits (30 s at most) after its first call, so stop_task can stop it (status killed, its
    "[Request interrupted by user]")."""
    mid = message_start()
    tool_input = {'description': 'List the files', 'prompt': 'List the files in this folder with Bash.',
                  'subagent_type': 'general-purpose'}
    tid = tool_use(mid, 0, 'Agent', tool_input)
    message_end('tool_use')
    agent = new_task('agent', tid, tool_input['description'])
    agent.update(mid='msg_fake' + uuid.uuid4().hex[:16], calls=0, chain=[None],
                 file=os.path.join(PROJECTS, SID, 'subagents', 'agent-%s.jsonl' % agent['task_id']),
                 output=os.path.join(CWD, '.fake-tasks', agent['task_id'] + '.output'))
    os.makedirs(os.path.dirname(agent['file']), exist_ok=True)
    with open(agent['file'][:-len('.jsonl')] + '.meta.json', 'w', encoding='utf-8') as stream:
        json.dump({'agentType': 'general-purpose', 'isBuiltIn': True, 'description': tool_input['description'],
                   'toolUseId': tid, 'spawnDepth': 1, 'requestShape': 'background', 'requestNonInteractive': True,
                   'model': current_model()}, stream)
    transcript({'type': 'user', 'message': {'content': tool_input['prompt']}}, path=agent['file'],
               chain=agent['chain'], agent=agent['task_id'])
    tasks_changed()
    emit({'type': 'system', 'subtype': 'task_started', 'task_id': agent['task_id'], 'run_id': agent['run_id'],
          'tool_use_id': tid, 'description': agent['description'], 'subagent_type': 'general-purpose',
          'is_backgrounded': True, 'spawn_depth': 1, 'task_type': 'local_agent', 'prompt': tool_input['prompt'],
          'uuid': str(uuid.uuid4()), 'session_id': SID})
    give(tid, 'Agent', ([{'type': 'text', 'text': 'Async agent launched successfully.\nagentId: %s\nThe agent is '
                                                  'working in the background.\noutput_file: %s' % (
                                                      agent['task_id'], agent['output'])}], False,
                        {'isAsync': True, 'status': 'async_launched', 'agentId': agent['task_id'],
                         'description': agent['description'], 'resolvedModel': current_model(),
                         'prompt': tool_input['prompt'], 'outputFile': agent['output'], 'canReadOutputFile': True,
                         'canContinueAgent': True}))
    said = mid_reply(['The agent ', 'is working.'])
    sub_call(agent, 'Bash', {'command': 'ls', 'description': 'List the files'}, bash_outcome('a.py\nnotes.txt'))
    result(said)
    stopped = agent['stopped'].wait(30 if prompt.split()[1:2] == ['wait'] else 0.3)
    if stopped:
        sub_record(agent, 'user', {'type': 'text', 'text': '[Request interrupted by user]'})
        status_, summary = 'killed', 'Agent "%s" was stopped by user' % agent['description']
    else:
        sub_record(agent, 'assistant', {'type': 'thinking', 'thinking': '', 'signature': 'c2lnbmF0dXJl'})
        sub_record(agent, 'assistant', {'type': 'text', 'text': 'Now the lines.'})
        sub_call(agent, 'Bash', {'command': 'wc -l notes.txt', 'description': 'Count the lines'},
                 bash_outcome('5 notes.txt'))
        sub_record(agent, 'assistant', {'type': 'text', 'text': 'The folder has a.py and notes.txt.'})
        task_end(agent, 'completed', 'completed')
        status_, summary = 'completed', 'Agent "%s" completed' % agent['description']
    note = ('<task-notification>\n<task-id>%s</task-id>\n<tool-use-id>%s</tool-use-id>\n<output-file>%s'
            '</output-file>\n<status>%s</status>\n<summary>%s</summary>\n</task-notification>' % (
                agent['task_id'], tid, agent['output'], status_, summary))
    system_init()
    time.sleep(OWN_TURN_MS / 1000)  # task 11: the agent's own turn works that long (FAKE_CLAUDE_OWN_TURN_MS)
    origin = {'kind': 'task-notification', 'producer': 'session-task', 'runId': agent['run_id']}
    if REPLAY:
        emit({'type': 'user', 'message': {'role': 'user', 'content': note}, 'session_id': SID,
              'parent_tool_use_id': None, 'uuid': str(uuid.uuid4()), 'timestamp': now_iso(), 'isReplay': True,
              'origin': origin})
    transcript({'type': 'user', 'message': {'content': note}, 'origin': origin})
    mid = message_start()           # the notification's turn thinks first (file-agent)
    thinking(mid, 0, estimates=False)
    said = 'The agent stopped.' if stopped else 'The folder has a.py and notes.txt.'
    if text(mid, 1, [said]):
        message_end()
        result(said)
    else:
        cut_off()


def mid_reply(pieces):
    """A reply message without the result that ends a turn (the turn goes on); its text."""
    mid = message_start()
    text(mid, 0, pieces)
    message_end()
    return ''.join(pieces)


SCENARIOS.update({'tools': s_tools, 'read': s_read, 'write': s_write, 'todo': s_todo, 'agent': s_agent,
                  'bg': s_bg, 'image': s_image, 'toolerror': s_toolerror, 'denied': s_denied,
                  'hooks': s_hooks, 'unknownblock': s_unknownblock, 'apierror': s_apierror})


# ---- task 11: two agents at once; the agent's own turn's length ----
OWN_TURN_MS = int(ENV.get('FAKE_CLAUDE_OWN_TURN_MS', '0'))


def s_agents2(prompt):
    """agents2: two Agent calls in one message, both in the background (34), whose records interleave: A's
    first call, B's first call, A's second call (it fails), B's second call; then both end and the turn the
    notifications start. Each agent's records are in its own file under subagents/ with its .meta.json."""
    mid = message_start()
    agents = []
    for index, (description, prompt_) in enumerate((('Look at a', 'Look at a.py.'), ('Look at b', 'Look at b.py.'))):
        tool_input = {'description': description, 'prompt': prompt_, 'subagent_type': 'general-purpose'}
        tid = tool_use(mid, index, 'Agent', tool_input)
        agent = new_task('agent', tid, description)
        agent.update(mid='msg_fake' + uuid.uuid4().hex[:16], calls=0, chain=[None],
                     file=os.path.join(PROJECTS, SID, 'subagents', 'agent-%s.jsonl' % agent['task_id']),
                     output=os.path.join(CWD, '.fake-tasks', agent['task_id'] + '.output'))
        os.makedirs(os.path.dirname(agent['file']), exist_ok=True)
        with open(agent['file'][:-len('.jsonl')] + '.meta.json', 'w', encoding='utf-8') as stream:
            json.dump({'agentType': 'general-purpose', 'isBuiltIn': True, 'description': description,
                       'toolUseId': tid, 'spawnDepth': 1, 'requestShape': 'background',
                       'requestNonInteractive': True, 'model': current_model()}, stream)
        transcript({'type': 'user', 'message': {'content': prompt_}}, path=agent['file'], chain=agent['chain'],
                   agent=agent['task_id'])
        agents.append(agent)
    message_end('tool_use')
    tasks_changed()
    for agent in agents:
        emit({'type': 'system', 'subtype': 'task_started', 'task_id': agent['task_id'], 'run_id': agent['run_id'],
              'tool_use_id': agent['tid'], 'description': agent['description'], 'subagent_type': 'general-purpose',
              'is_backgrounded': True, 'spawn_depth': 1, 'task_type': 'local_agent', 'prompt': '',
              'uuid': str(uuid.uuid4()), 'session_id': SID})
        give(agent['tid'], 'Agent', ([{'type': 'text', 'text': 'Async agent launched successfully.\nagentId: %s' %
                                       agent['task_id']}], False,
                                     {'isAsync': True, 'status': 'async_launched', 'agentId': agent['task_id'],
                                      'description': agent['description'], 'resolvedModel': current_model(),
                                      'prompt': '', 'outputFile': agent['output'], 'canReadOutputFile': True,
                                      'canContinueAgent': True}))
    a, b = agents
    sub_call(a, 'Bash', {'command': 'cat a.py', 'description': 'Read a'}, bash_outcome('print(1)'))
    sub_call(b, 'Bash', {'command': 'cat b.py', 'description': 'Read b'}, bash_outcome('print(2)'))
    result(mid_reply(['Two agents ', 'are working.']))
    time.sleep(0.2)
    sub_call(a, 'Bash', {'command': 'wc a.py', 'description': 'Count a'},
             ('Exit code 1\nwc: a.py: No such file or directory', True, None))
    sub_call(b, 'Bash', {'command': 'wc b.py', 'description': 'Count b'}, bash_outcome('1 b.py'))
    for agent in agents:
        task_end(agent, 'completed', 'completed')
    system_init()
    for agent in agents:            # the file's <task-notification> strings (34)
        transcript({'type': 'user', 'message': {'content': (
            '<task-notification>\n<task-id>%s</task-id>\n<tool-use-id>%s</tool-use-id>\n<output-file>%s'
            '</output-file>\n<status>completed</status>\n<summary>%s</summary>\n</task-notification>' % (
                agent['task_id'], agent['tid'], agent['output'], 'Agent "%s" completed' % agent['description']))},
            'origin': {'kind': 'task-notification', 'producer': 'session-task', 'runId': agent['run_id']}})
    mid = message_start()
    if text(mid, 0, ['Both agents ended.']):
        message_end()
        result('Both agents ended.')
    else:
        cut_off()


SCENARIOS['agents2'] = s_agents2


# three of 2.1.330's commands, as its initialize lists them (finding 22; the real list has every built-in,
# skill and plugin command)
COMMANDS = [{'name': 'compact', 'description': 'Clear history but keep a summary', 'argumentHint': ''},
            {'name': 'context', 'description': 'Show current context usage', 'argumentHint': ''},
            {'name': 'usage', 'description': "Show session cost, plan usage, and what's contributing to your limits",
             'argumentHint': '', 'aliases': ['cost', 'stats']}]
COMMANDS_SENT = [False]
# a skill whose description has line ends, as 2.1.330 lists the claude-api skill (finding 26): only through
# FAKE_CLAUDE_COMMANDS_CHANGED
SKILLS = [{'name': 'claude-api', 'description': 'Reference for the Claude API\nTRIGGER when the code imports it.\n'
                                               'SKIP otherwise.', 'argumentHint': ''}]


def changed_commands():
    """The list commands_changed sends after initialize: COMMANDS, or FAKE_CLAUDE_COMMANDS_CHANGED's names."""
    names = [n for n in ENV.get('FAKE_CLAUDE_COMMANDS_CHANGED', '').split(',') if n]
    if not names:
        return COMMANDS
    known = {c['name']: c for c in COMMANDS + SKILLS}
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
    return review_init(response)


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
    FAKE_CLAUDE_NO_LIFECYCLE (unrecorded): none at all, so only the replay says a message started; "local":
    none for the commands the CLI answers itself (QUIET), which then have neither lifecycle nor replay."""
    knob = ENV.get('FAKE_CLAUDE_NO_LIFECYCLE')
    if knob and (knob != 'local' or uid in QUIET):
        return
    emit({'type': 'command_lifecycle', 'command_uuid': uid, 'state': state, 'uuid': str(uuid.uuid4()),
          'session_id': SID})


# ---- the protocol review's knobs and scenarios (2026-11-23). No recording is behind any of them: each
# provokes a condition the real CLI could produce (by its schema, or by timing) that no run of it did.
# FAKE_CLAUDE_FOREIGN_ID: get_settings is first answered for another id that starts as rhun's does (rhun's
#   id followed by "abc", applied model "claude-foreign"), then for rhun's own.
# FAKE_CLAUDE_MODE_MS: set_permission_mode is answered that long after it was read, by a thread of its own
#   (the stdin reader goes on); logged {"mode_answer": ID} as it goes out.
# FAKE_CLAUDE_SETTINGS_MS: get_settings is answered that long after it was read ("never": not at all);
#   logged {"settings_answer": ID} as it goes out.
# FAKE_CLAUDE_NO_INIT_MODE: initialize's answer has no current_permission_mode.
# FAKE_CLAUDE_REFUSE_MODEL (VALUE): apply_flag_settings {"model": VALUE} is answered with an error.
# FAKE_CLAUDE_MODELS longresolved: a third model whose resolvedModel is 500 bytes long.
# FAKE_CLAUDE_FLAGS_MS: apply_flag_settings is applied and answered that long after it was read, the requests
#   in the order they came (one thread), the reader going on meanwhile; logged {"flags_answer": ID}.
# The plan a `plan` turn writes is also in <config>/plans/fake-<session id>.md (as finding 24's file): a later
#   process of the same conversation answers get_plan from it (the real CLI read its plan file; resuming was not recorded).
# Scenarios: `rules N [B1] [B2]` (a Bash call whose suggestion has N rules of behavior B1, default allow, and
# with B2 a second suggestion of one rule of that behavior), `planagain [MS]` (an ExitPlanMode Claude takes
# back after MS (default 700) unanswered, then a second one in the same turn, which waits).

def review_later(message, what, env):
    """True when the request is answered later (the knob env names a delay): handle() runs it again in a
    thread of its own after that delay, logging {what: id} first; "never" drops it."""
    delay = ENV.get(env)
    if not delay or message.get('_later'):
        return False
    if delay == 'never':
        return True

    def later():
        log(**{what: message.get('request_id')})
        try:
            handle(dict(message, _later=True))
        except Exception:
            log(error=traceback.format_exc())
    threading.Timer(int(delay) / 1000, later).start()
    return True


def review_settings(message):
    """get_settings' knobs: a foreign answer first (FAKE_CLAUDE_FOREIGN_ID), a late or no answer
    (FAKE_CLAUDE_SETTINGS_MS). True when it is not answered now."""
    rid = message.get('request_id')
    if ENV.get('FAKE_CLAUDE_FOREIGN_ID') and not message.get('_later') and isinstance(rid, str):
        respond(rid + 'abc', dict(get_settings(), applied=dict(applied(), model='claude-foreign')))
    return review_later(message, 'settings_answer', 'FAKE_CLAUDE_SETTINGS_MS')


FLAGS_LATER = []                    # FAKE_CLAUDE_FLAGS_MS: (due, message) in the order read


def review_flags_later(message):
    """FAKE_CLAUDE_FLAGS_MS: True when apply_flag_settings is answered later, in order, by one thread."""
    delay = ENV.get('FAKE_CLAUDE_FLAGS_MS')
    if not delay or message.get('_later'):
        return False

    def later():
        while True:
            with COND:
                while not FLAGS_LATER:
                    COND.wait(0.05)
                due, queued = FLAGS_LATER[0]
            time.sleep(max(0.0, due - time.time()))
            with COND:
                FLAGS_LATER.pop(0)
            log(flags_answer=queued.get('request_id'))
            try:
                handle(dict(queued, _later=True))
            except Exception:
                log(error=traceback.format_exc())
    with COND:
        if not FLAGS_LATER and not getattr(review_flags_later, 'thread', None):
            review_flags_later.thread = threading.Thread(target=later, daemon=True)
            review_flags_later.thread.start()
        FLAGS_LATER.append((time.time() + int(delay) / 1000, message))
        COND.notify_all()
    return True


def review_refuse_flags(rid, settings):
    """FAKE_CLAUDE_REFUSE_MODEL: apply_flag_settings for that model is refused (True: answered)."""
    if ENV.get('FAKE_CLAUDE_REFUSE_MODEL') and settings.get('model') == ENV['FAKE_CLAUDE_REFUSE_MODEL']:
        respond_error(rid, 'Model %s is not available' % settings['model'])
        return True
    return False


def review_models():
    """FAKE_CLAUDE_MODELS longresolved: a model whose resolvedModel is far past what rhun keeps."""
    if 'longresolved' not in MODEL_KNOBS:
        return []
    return [{'value': 'long', 'resolvedModel': 'claude-' + 'x' * 493, 'displayName': 'Long',
             'description': 'A long id', 'supportsEffort': True}]


def review_plan_file():
    return os.path.join(config_dir(), 'plans', 'fake-%s.md' % (RESUME or SID))


def review_plan_save():
    os.makedirs(os.path.dirname(review_plan_file()), exist_ok=True)
    with open(review_plan_file(), 'w', encoding='utf-8') as stream:
        stream.write(PLAN[0]['content'])


def review_plan():
    """get_plan's plan: this process's, else the file an earlier process of the conversation wrote."""
    path = review_plan_file()
    if PLAN[0] is None and os.path.exists(path):
        with open(path, encoding='utf-8') as stream:
            return {'content': stream.read(), 'path': path}
    return PLAN[0]


def review_init(response):
    """FAKE_CLAUDE_NO_INIT_MODE: initialize's answer without current_permission_mode."""
    if ENV.get('FAKE_CLAUDE_NO_INIT_MODE'):
        response.pop('current_permission_mode', None)
    return response


def s_rules(prompt):
    """rules N [B1] [B2]: a Bash call whose first suggestion has N rules (Bash "echo rN") of behavior B1 (allow
    by default); with B2, a second suggestion of one rule of that behavior; both for localSettings"""
    words = prompt.split()
    count = int(words[1]) if len(words) > 1 and words[1].isdigit() else 1
    first = words[2] if len(words) > 2 else 'allow'
    rules = [{'type': 'addRules', 'rules': [{'toolName': 'Bash', 'ruleContent': 'echo r%d' % i}
                                            for i in range(1, count + 1)],
              'behavior': first, 'destination': 'localSettings'}]
    if len(words) > 3:
        rules.append({'type': 'addRules', 'rules': [{'toolName': 'Bash', 'ruleContent': 'echo second'}],
                      'behavior': words[3], 'destination': 'localSettings'})
    if bash('echo r1', rules=rules):
        final('done')


def s_planagain(prompt):
    """planagain [MS]: an ExitPlanMode Claude takes back by itself after MS (default 700) unanswered, then a
    second ExitPlanMode in the same turn, which waits for its answer (logged); then the final text"""
    global MODE
    words = prompt.split()
    wait = int(words[1]) / 1000 if len(words) > 1 and words[1].isdigit() else 0.7
    path = os.path.join(config_dir(), 'plans', 'fake.md')
    for n, plan in enumerate(['# Plan\n\n1. Add the file', '# Plan, again\n\n1. Add notes.txt']):
        PLAN[0] = {'content': plan, 'path': path}
        mid = message_start()
        tool_input = {'plan': plan, 'planFilePath': path}
        tid = tool_use(mid, 0, 'ExitPlanMode', tool_input)
        message_end('tool_use')
        rid = request_id()
        deadline = time.time() + wait if n == 0 else None
        with COND:
            PENDING[rid] = None
            emit({'type': 'control_request', 'request_id': rid, 'request': {
                'subtype': 'can_use_tool', 'tool_name': 'ExitPlanMode', 'display_name': 'ExitPlanMode',
                'input': tool_input, 'tool_use_id': tid, 'requires_user_interaction': True}})
            while PENDING.get(rid) is None and not withdrawn() and (deadline is None or time.time() < deadline):
                COND.wait(0.05)
            answer = PENDING.pop(rid, None)
            if answer is None and not CLOSED.is_set() and n == 0:
                emit({'type': 'control_cancel_request', 'request_id': rid})
        if answer is not None:
            log(answer=dict(answer, plan=n + 1))
        tool_result(tid, 'The user withdrew the plan' if answer is None else 'answered', answer is None)
        if answer is None and n == 1:
            return
    final('done')


def s_manydialog(prompt):
    """32 Bash calls that ask at once, then a dialog (auto_mode_server_fallback) while they wait: rhun keeps 32
    and answers the dialog at once (logged {"answer": ...}, an error comes as {"behavior": "error"}); the turn
    then waits for the 32 (an interrupt ends it)"""
    mid = message_start()
    calls = []
    for i in range(32):
        tool_input = {'command': 'touch md%d.txt' % i, 'description': 'many'}
        calls.append((tool_use(mid, i, 'Bash', tool_input), tool_input))
    message_end('tool_use')
    ids = []
    with COND:
        for tid, tool_input in calls:
            rid = request_id()
            PENDING[rid] = None
            ids.append(rid)
            emit({'type': 'control_request', 'request_id': rid, 'request': bash_request(tool_input, tid, [])})
    dialog('auto_mode_server_fallback', AUTO_DIALOGS['full'])
    with COND:
        while not (withdrawn() or all(PENDING.get(rid) is not None for rid in ids)):
            COND.wait(0.05)
        answers = [PENDING.pop(rid, None) for rid in ids]
    if None in answers and not CLOSED.is_set():
        ACKED.wait(5)
    for (tid, tool_input), answer in zip(calls, answers):
        bash_result(tid, tool_input, answer)
    cut_off(tool_turn=True) if None in answers else final('done')


# a help URL whose host has a percent-escape: new URL() would read another host than the text shows
AUTO_DIALOGS['percent'] = {'title': 'Auto mode is using a fallback', 'paragraphs': ['A paragraph.'],
                           'helpUrl': 'https://evil.example%2F.claude.com/docs'}
SCENARIOS.update({'rules': s_rules, 'planagain': s_planagain, 'manydialog': s_manydialog})


def s_diffs(prompt):
    """diffs: edits and writes past what a row read from a file keeps (phase 3 task 7), none asks, made-up
    files (nothing is read or written): an Edit of 20 lines to 22 with a TAB and a long line, a replace_all,
    a Write of a new file of 30 lines, a Write over a file (its result has originalFile and the patch)"""
    old = ''.join('x%d = %d  # row %d\n' % (i, i, i) for i in range(20))
    new = old.replace('x3 = 3', 'x3 = 33').replace('# row 9\n', '# row 9\n\tdef nine():\n' + '    pass ' * 40 + '\n')
    big_py, a_py, made, notes = at('big.py'), at('a.py'), at('made.py'), at('notes.txt')
    text_ = ''.join('def f%d(x):\n    return x + %d\n' % (i, i) for i in range(15))
    ran_calls([('Edit', {'replace_all': False, 'file_path': big_py, 'old_string': old, 'new_string': new},
                edit_outcome(big_py, old, old, new)),
               ('Edit', {'replace_all': True, 'file_path': a_py, 'old_string': '# line', 'new_string': '# row'},
                edit_outcome(a_py, A_PY, '# line', '# row', True)),
               ('Write', {'file_path': made, 'content': text_}, write_outcome(made, text_)),
               ('Write', {'file_path': notes, 'content': 'one\r\ntwo\r\n'}, write_outcome(notes, 'one\r\ntwo\r\n', NOTES))],
              'edited')


SCENARIOS.update({'diffs': s_diffs})


# Phase 3 task 5 (the spinner): a turn that works long enough to watch it
def s_linger(prompt):
    """linger [S]: the turn works S seconds (default 20, fractions taken) before its reply; an interrupt ends
    it at once"""
    words = prompt.split()
    try:
        seconds = float(words[1]) if len(words) > 1 else 20.0
    except ValueError:
        seconds = 20.0
    if INTERRUPT.wait(seconds):
        cut_off()
    else:
        final('ok: ' + prompt)


def s_asklinger(prompt):
    """asklinger [S]: a Bash call that asks first (a card waits), then the turn works S seconds (default 20)"""
    if not bash('touch spin.txt'):
        return
    s_linger('linger ' + (prompt.split()[1] if len(prompt.split()) > 1 else '20'))


def s_pause(prompt):
    """pause [S]: a reply whose text has all streamed but whose message is whole only S seconds later (its
    assistant record, the block's stop and message_stop then; default 3)"""
    words = prompt.split()
    seconds = float(words[1]) if len(words) > 1 else 3.0
    mid = message_start()
    stream_event({'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}})
    sent = ''
    for piece in ('A reply that ', 'waits before ', 'it is whole.'):
        stream_event({'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': piece}})
        sent += piece
    time.sleep(seconds)
    assistant(mid, {'type': 'text', 'text': sent})
    stream_event({'type': 'content_block_stop', 'index': 0})
    message_end()
    result(sent)


SCENARIOS.update({'linger': s_linger, 'asklinger': s_asklinger, 'pause': s_pause})


# ---- Phase 3 task 6 (thinking and todo lists): thinking that lasts, in finding 29's two displays, with the
# duration its record carries (19-thinking), for the live label and the cost of a streaming thinking row.

def thinking_block(mid, pieces, delay, display):
    """A thinking block of these text pieces (the "updates" display: empty pieces), delay seconds apart: each
    delta then a thinking_tokens record (the "updates" deltas carry their estimate as well, as recorded); the
    record with the whole text, thinking_duration_ms and thinking_display. False when an interrupt cut it."""
    started = time.monotonic()
    stream_event({'type': 'content_block_start', 'index': 0,
                  'content_block': {'type': 'thinking', 'thinking': '', 'signature': ''}}, thinking_display=display)
    estimate, said = 0, ''
    for piece in pieces:
        if interrupted_now():
            return False
        step = max(1, len(piece) // 4) if piece else 50
        estimate += step
        delta = {'type': 'thinking_delta', 'thinking': piece}
        if display == 'updates':
            delta['estimated_tokens'] = estimate
        stream_event({'type': 'content_block_delta', 'index': 0, 'delta': delta}, thinking_display=display)
        thinking_tokens(estimate, step)
        said += piece
        time.sleep(delay)
    stream_event({'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'signature_delta',
                                                                      'signature': 'c2lnbmF0dXJl'}})
    assistant(mid, {'type': 'thinking', 'thinking': said, 'signature': 'c2lnbmF0dXJl'},
              thinking_duration_ms=int((time.monotonic() - started) * 1000), thinking_display=display)
    stream_event({'type': 'content_block_stop', 'index': 0})
    return True


def s_thinkslow(prompt):
    """thinkslow [MS]: the default display's thinking (no text) for about MS ms (default 1500), an estimate
    every 100 ms, then a short reply"""
    words = prompt.split()
    ms = int(words[1]) if len(words) > 1 else 1500
    mid = message_start()
    if thinking_block(mid, [''] * max(1, ms // 100), 0.1, 'updates') and text(mid, 1, ['thought ', 'slowly']):
        message_end()
        result('thought slowly')
    else:
        cut_off()


def s_thinkstream(prompt):
    """thinkstream [PIECES [MS]]: summarized thinking whose Markdown text (paragraphs, lists, code) streams in
    PIECES deltas (default 2000) MS milliseconds apart (default 5), then a short reply"""
    words = prompt.split()
    count = int(words[1]) if len(words) > 1 else 2000
    delay = (int(words[2]) if len(words) > 2 else 5) / 1000
    parts = []
    for i in range(count):
        step = i % 30
        if step == 0:
            parts.append('**Step %d.** ' % (i // 30))
        elif step < 14:
            parts.append('I weigh what the reader needs ' if step % 2 else 'and what it costs. ')
        elif step == 14:
            parts.append('\n\n- a point\n')
        elif step < 18:
            parts.append('- another point %d\n' % step)
        elif step == 18:
            parts.append('\n')
        else:
            parts.append('then `a check` ' if step % 3 else 'and a sentence. ')
        if step == 29:
            parts.append('\n\n')
    mid = message_start()
    if thinking_block(mid, parts, delay, 'summarized') and text(mid, 1, ['thought ', 'it ', 'through']):
        message_end()
        result('thought it through')
    else:
        cut_off()


SCENARIOS.update({'thinkslow': s_thinkslow, 'thinkstream': s_thinkstream})


# ---- phase 3 task 8: hostile error texts (unrecorded: the shapes are 35's and the crash's)

HOSTILE = 'evil \u202ecod.exe\u202c \x1b]0;title\x07\x1b[31mred\x1b[0m \u009b31m '


def s_bigerror(prompt):
    """bigerror: the turn fails with an error text of 1 MiB holding bidi and control characters"""
    result(subtype='error_during_execution', stop=None, terminal='api_error',
           errors=[HOSTILE + 'x' * (1 << 20)])


def s_hostilecrash(prompt):
    """hostilecrash: 1 MiB of standard error holding bidi and control characters, then a crash"""
    CRASH.set()
    sys.stderr.write((HOSTILE + 'y' * 100 + '\n') * 10000)
    sys.stderr.flush()
    crash(2)


SCENARIOS.update({'bigerror': s_bigerror, 'hostilecrash': s_hostilecrash})


# ---- Phase 4 (README.txt findings 38 on; shape files 23 to 26): a message's blocks, rhun's in-process MCP server,
# the SDK hooks and the answers to an edit, as 2.1.330 recorded them.
# initialize's hooks, sdkMcpServers, sdkMcpServerManifests, appendSystemPrompt and systemPromptSnapshot are logged
# with the others; the answer gains hooks_applied true (hooks given) and sdk_mcp_manifests_parked {NAME: "parked"}
# (manifests given). For each server in sdkMcpServers without a manifest the CLI's handshake goes out as recorded:
# the JSON-RPC initialize as an mcp_message request BEFORE the initialize answer, then notifications/initialized
# and tools/list after rhun answered (a JSON-RPC error to tools/list is asked again 250, 500 and 1000 ms later,
# then the server is connected without tools); every answer is logged {"mcp": {server, method, id, answer}}. A
# turn waits for the handshake (FAKE_CLAUDE_MCP_WAIT_MS, default 60000 as recorded; initialize is sent again at
# half of it; past it the server is "failed"). system/init's mcp_servers and tools and mcp_status name the server
# and its tools (mcp__NAME__TOOL). Hook callbacks go out in the phase 4 scenarios only (the older scenarios run
# no callbacks): every matching PreToolUse callback at once, can_use_tool after all were answered, PostToolUse
# after the tool ran; an additionalContext answer becomes the file's hook_additional_context line after the
# result (no stream record); each answer is logged {"hook": {callback_id, event, tool, answer}}; with no
# deadline the fake waits as the CLI did (tool_progress heartbeats every 30 s).
# The replay of a user message: the blocks as sent, except an image whose bytes are not PNG, JPEG, GIF or WebP
# (the recorded text block in its place) and inline_pastes wrapped in <pasted_content> tags (finding 43); the
# file's prompt line holds the same blocks, imagePasteIds, then the isMeta "[Image: source: ...]" line. Not
# mimicked: the CLI's re-encoding of large images (39) and its own expansion of @mentions (42).
# Scenarios: diag [FILE] (a getDiagnostics call of the first server: can_use_tool, tools/call, the tool row with
# what came back; an interrupt while the call waits sends notifications/cancelled), hookedit [FILE] (an Edit of
# the file's first line with the callbacks around it), hookread FILE, editfile FILE OLD NEW and writefile FILE
# TEXT (they ask; an allow's updatedInput is applied as the CLI applies it: CR LF kept, a file changed since the
# call refused), echoblocks (a reply with one line per block of its message: "image image/png BYTES", "document
# text/plain TITLE CHARS", "document application/pdf TITLE BYTES", "text CHARS"; FAKE_CLAUDE_SCENARIO=echoblocks
# when the first text block is not the word), notify (experiment_gates and file_updated to the first server:
# unrecorded, 2.1.330 sends them only to a server named claude-vscode, finding 47).
# Knobs: FAKE_CLAUDE_MCP=off (an older CLI: the new members are ignored), nomanifest (task 9, unrecorded: the
# manifests ignored, so the handshake of 44 runs; slow and error ignore them too), slow (unrecorded: the handshake starts
# 1 s after the initialize answer, 0.5 s between its steps), error (unrecorded: after tools/list the fake also
# asks resources/list and an unknown method, which a server without them answers with JSON-RPC errors);
# FAKE_CLAUDE_HOOK_DEADLINE=MS (unrecorded: a callback not answered within MS counts as {"continue": true}; 2.1.330
# sent no deadline_ms and waited); FAKE_CLAUDE_HOOK_CANCEL_MS=MS (task 10, unrecorded: a callback not answered
# within MS is withdrawn with control_cancel_request, logged {"cancelled": ...}, and counts as {"continue": true});
# FAKE_CLAUDE_MCP_WAIT_MS (above).
P4_MEMBERS = ('hooks', 'sdkMcpServers', 'sdkMcpServerManifests', 'appendSystemPrompt', 'systemPromptSnapshot')
MCP_KNOB = ENV.get('FAKE_CLAUDE_MCP', '')
P4_SERVERS = {}                     # name -> {state: pending|connected|failed, tools: [...], next: JSON-RPC id, done: Event}
P4_HOOKS = {}                       # event -> [(matcher, [callback ids])]
P4_ANSWERS = {}                     # the fake's mcp_message and hook_callback request ids -> None until answered
P4_IMAGES = [0]                     # images of the conversation so far (imagePasteIds)
P4_CONTENT = [None]                 # the blocks of the message whose turn runs (echoblocks)
MCP_CLIENT = {'name': 'claude-code', 'title': 'Claude Code', 'description': "Anthropic's agentic coding tool",
              'websiteUrl': 'https://claude.com/claude-code', 'version': '2.1.330'}
NOT_IMAGE = ('[Image could not be processed: Unable to resize image — image processing is unavailable and '
             'dimensions could not be read from the file header. Please convert the image to PNG, JPEG, GIF, or WebP.]')
CHANGED = ('File content has changed since it was last read. This commonly happens when a linter or formatter run '
           'via Bash rewrites the file. Call Read on this file to refresh, then retry the edit.')


def p4_initialize(request):
    """initialize's phase 4 members: the hooks kept, each server's handshake begun (its first request goes out
    before the answer, as recorded). The answer's extra members, in the recorded order."""
    extra = {}
    if MCP_KNOB == 'off':
        return extra
    hooks = request.get('hooks') if isinstance(request.get('hooks'), dict) else {}
    for event, matchers in hooks.items():
        P4_HOOKS[event] = [(m.get('matcher') or '', list(m.get('hookCallbackIds') or [])) for m in matchers or []
                           if isinstance(m, dict)]
    if hooks:
        extra['hooks_applied'] = True
    manifests = request.get('sdkMcpServerManifests') if isinstance(request.get('sdkMcpServerManifests'), dict) else {}
    for name in request.get('sdkMcpServers') or []:
        if not isinstance(name, str) or name in P4_SERVERS:
            continue
        server = {'state': 'pending', 'tools': [], 'next': 0, 'done': threading.Event()}
        P4_SERVERS[name] = server
        manifest = manifests.get(name)
        if MCP_KNOB in ('nomanifest', 'slow', 'error'):  # task 9 (unrecorded): the manifest ignored, the handshake as 44
            manifest = None
        if isinstance(manifest, dict):          # 45: parked, no handshake; ids still count from the handshake's
            server.update(state='connected', next=2,
                          tools=((manifest.get('toolsListResult') or {}).get('tools') or []),
                          info=(manifest.get('initializeResult') or {}).get('serverInfo'))
            server['done'].set()
            extra.setdefault('sdk_mcp_manifests_parked', {})[name] = 'parked'
            continue
        first = None if MCP_KNOB == 'slow' else p4_send(name, p4_request(name, 'initialize', {
            'protocolVersion': '2025-11-25', 'capabilities': {}, 'clientInfo': MCP_CLIENT}))
        threading.Thread(target=p4_handshake, args=(name, first), daemon=True).start()
    return extra


def p4_answer_members(response, extra):
    """The initialize answer with extra inserted where 2.1.330 puts them (after current_permission_mode)."""
    if not extra:
        return response
    out = {}
    for key, value in response.items():
        out[key] = value
        if key == 'current_permission_mode':
            out.update(extra)
    return out


def p4_request(name, method, params=None):
    """A JSON-RPC request of the CLI's, in the recorded member order (initialize and tools/call carry params)."""
    server = P4_SERVERS[name]
    message = {'method': method}
    if params is not None:
        message['params'] = params
    message.update(jsonrpc='2.0', id=server['next'])
    server['next'] += 1
    return message


def p4_send(name, message):
    """An mcp_message control request; its request id (the answer comes to P4_ANSWERS)."""
    rid = str(uuid.uuid4())
    log(sent={'id': rid, 'subtype': 'mcp_message', 'method': message.get('method')})     # task 9
    with COND:
        P4_ANSWERS[rid] = None
        emit({'type': 'control_request', 'request_id': rid,
              'request': {'subtype': 'mcp_message', 'server_name': name, 'message': message}})
    return rid


def p4_wait(rid, timeout=None, interruptible=False):
    """The answer to one of the fake's requests (the control response's response member, or {"error": TEXT}),
    or None: timeout, stdin closed, or (interruptible) an interrupt."""
    deadline = None if timeout is None else time.time() + timeout
    with COND:
        while P4_ANSWERS.get(rid) is None:
            if CLOSED.is_set() or (interruptible and INTERRUPT.is_set() and not DEAF.is_set()):
                return None
            if deadline is not None and time.time() >= deadline:
                return None
            COND.wait(0.05)
        return P4_ANSWERS.pop(rid)


def p4_answer(response):
    """A control response to one of the fake's own requests: kept for its waiter. True when it was one."""
    rid = response.get('request_id')
    with COND:
        if rid not in P4_ANSWERS:
            return False
        P4_ANSWERS[rid] = response.get('response') if response.get('subtype') == 'success' \
            else {'error': response.get('error', '')}
        if not isinstance(P4_ANSWERS[rid], dict):
            P4_ANSWERS[rid] = {}
        COND.notify_all()
    return True


def p4_ask(name, method, params=None, timeout=5):
    """A request of the handshake: sent, answered (logged), the JSON-RPC reply or None."""
    message = p4_request(name, method, params) if method != 'notifications/initialized' else {
        'jsonrpc': '2.0', 'method': method}
    answer = p4_wait(p4_send(name, message), timeout)
    log(mcp={'server': name, 'method': method, 'id': message.get('id'), 'answer': answer})
    return (answer or {}).get('mcp_response') if isinstance(answer, dict) else None


def p4_handshake(name, first):
    """44: initialize (sent again at half the wait, failed at the whole), notifications/initialized, tools/list
    (asked again 250, 500, 1000 ms after an error reply); 51: a server that never answers is failed."""
    server = P4_SERVERS[name]
    wait = int(ENV.get('FAKE_CLAUDE_MCP_WAIT_MS', '60000')) / 1000
    try:
        if first is None:                       # FAKE_CLAUDE_MCP=slow
            time.sleep(1)
            first = p4_send(name, p4_request(name, 'initialize', {
                'protocolVersion': '2025-11-25', 'capabilities': {}, 'clientInfo': MCP_CLIENT}))
        answer = p4_wait(first, wait / 2)
        if answer is None and not CLOSED.is_set():
            answer = p4_wait(p4_send(name, p4_request(name, 'initialize', {
                'protocolVersion': '2025-11-25', 'capabilities': {}, 'clientInfo': MCP_CLIENT})), wait / 2)
        log(mcp={'server': name, 'method': 'initialize', 'id': 0, 'answer': answer})
        reply = (answer or {}).get('mcp_response') if isinstance(answer, dict) else None
        if not isinstance(reply, dict) or not isinstance(reply.get('result'), dict):
            server['state'] = 'failed'
            return
        server['info'] = reply['result'].get('serverInfo')
        if MCP_KNOB == 'slow':
            time.sleep(0.5)
        p4_ask(name, 'notifications/initialized')
        for delay in (0, 0.25, 0.5, 1.0):
            time.sleep(delay + (0.5 if MCP_KNOB == 'slow' else 0))
            listed = p4_ask(name, 'tools/list', timeout=wait)
            if isinstance(listed, dict) and isinstance(listed.get('result'), dict):
                server['tools'] = [t for t in listed['result'].get('tools') or [] if isinstance(t, dict)]
                break
        server['state'] = 'connected'
        if MCP_KNOB == 'error':                 # unrecorded: methods a server without them refuses
            p4_ask(name, 'resources/list')
            p4_ask(name, 'no/such-method', {})
    finally:
        server['done'].set()


def p4_before_turn():
    """51: a turn waits for every server's handshake (the CLI held system/init until tools/list was answered)."""
    for server in list(P4_SERVERS.values()):
        server['done'].wait(int(ENV.get('FAKE_CLAUDE_MCP_WAIT_MS', '60000')) / 1000 + 1)


def p4_tool_names():
    return ['mcp__%s__%s' % (name, t.get('name')) for name, s in P4_SERVERS.items() if s['state'] == 'connected'
            for t in s['tools']]


def p4_init_servers():
    return [{'name': name, 'status': 'connected' if s['state'] == 'connected' else 'failed', 'source': 'sdk'}
            for name, s in P4_SERVERS.items()]


def p4_status():
    """mcp_status's mcpServers (44, 51)."""
    out = []
    for name, s in P4_SERVERS.items():
        if s['state'] == 'pending':             # 44: absent while its tools/list is unanswered
            continue
        if s['state'] == 'failed':
            out.append({'name': name, 'status': 'failed', 'transport': 'sdk', 'scope': 'user', 'source': 'sdk'})
            continue
        out.append({'name': name, 'status': 'connected', 'serverInfo': s.get('info') or {'name': name},
                    'transport': 'sdk', 'scope': 'dynamic', 'source': 'sdk',
                    'tools': [{'name': t.get('name'), 'annotations': {
                        'readOnly': bool((t.get('annotations') or {}).get('readOnlyHint'))}} for t in s['tools']]})
    return out


def p4_magic(data):
    """The image kind of base64 data by its first bytes, or None."""
    import base64
    try:
        head = base64.b64decode(data[:64] + '=' * (-len(data[:64]) % 4))
    except (ValueError, TypeError):
        return None
    for magic, kind in ((b'\x89PNG\r\n\x1a\n', 'png'), (b'\xff\xd8\xff', 'jpg'), (b'GIF8', 'gif')):
        if head.startswith(magic):
            return kind
    return 'webp' if head[:4] == b'RIFF' and head[8:12] == b'WEBP' else None


def p4_blocks(entry):
    """The message's blocks as the CLI replays and saves them (38, 43)."""
    content = entry.get('content')
    if not isinstance(content, list):
        return content
    blocks = []
    for block in content:
        if isinstance(block, dict) and block.get('type') == 'image':
            if p4_magic(str((block.get('source') or {}).get('data', ''))) is None:
                block = {'type': 'text', 'text': NOT_IMAGE}
        blocks.append(block)
    pastes = [p for p in entry.get('pastes') or [] if isinstance(p, str) and p.strip()][:100]
    if pastes:
        tag = str(1000 + uuid.uuid4().int % 9000)
        texts = [i for i, b in enumerate(blocks) if isinstance(b, dict) and b.get('type') == 'text']
        for paste in pastes:
            for i in texts:
                said = blocks[i].get('text', '')
                at_ = said.find(paste)
                if at_ < 0 or (i != texts[-1] and said != paste):
                    continue
                rest = said[at_ + len(paste):]
                wrapped = '\n\n<pasted_content id="%s">\n%s\n</pasted_content id="%s">\n' % (tag, paste, tag)
                blocks[i] = dict(blocks[i], text=said[:at_] + wrapped + ('\n' + rest if rest else ''))
                break
    return blocks


def p4_prompt_line(entry, prompt):
    """The file's prompt line: as before for a plain text message; with other blocks or pastes the blocks as
    replayed, imagePasteIds after timestamp, then the isMeta image line (38)."""
    blocks = p4_blocks(entry)
    plain = isinstance(blocks, list) and all(isinstance(b, dict) and b.get('type') == 'text' for b in blocks) \
        and not entry.get('pastes')
    if not isinstance(blocks, list) or plain:
        transcript({'type': 'user', 'message': {'role': 'user', 'content': [{'type': 'text', 'text': prompt}]}})
        return
    images = []
    for block in blocks:
        if isinstance(block, dict) and block.get('type') == 'image':
            P4_IMAGES[0] += 1
            images.append((P4_IMAGES[0], p4_magic(str((block.get('source') or {}).get('data', '')))))
    line = file_line({'type': 'user', 'message': {'role': 'user', 'content': blocks}})
    if images:                                  # imagePasteIds comes right after timestamp (file-keys.txt)
        ordered = {}
        for key, value in line.items():
            ordered[key] = value
            if key == 'timestamp':
                ordered['imagePasteIds'] = [n for n, _ in images]
        line = ordered
    fork_copy()
    os.makedirs(os.path.dirname(TRANSCRIPT), exist_ok=True)
    with open(TRANSCRIPT, 'a', encoding='utf-8') as stream:
        stream.write(json.dumps(line, ensure_ascii=False) + '\n')
    if images:
        folder = '/tmp/claude-%d/%s/%s/images' % (os.getuid() if hasattr(os, 'getuid') else 0,
                                                  re.sub(r'[^A-Za-z0-9]', '-', CWD), SID)
        transcript({'type': 'user', 'isMeta': True, 'message': {'role': 'user', 'content': [
            {'type': 'text', 'text': '[Image: source: %s/%d.%s]' % (folder, n, kind)} for n, kind in images]}})


def p4_callbacks(event, tool, tid, tool_input, response=None, agent=None):
    """48: the matching callbacks of event, sent together, then every answer awaited (FAKE_CLAUDE_HOOK_DEADLINE:
    at most that long each; else as long as it takes, tool_progress every 30 s). The answers in order (None:
    withdrawn); [] without hooks. agent: a subagent's id (its input has agent_id and agent_type, task 10)."""
    sent = []
    for matcher, ids in P4_HOOKS.get(event, []):
        try:
            if matcher and not re.fullmatch(matcher, tool):
                continue
        except re.error:
            continue
        for callback in ids:
            hook_input = {'session_id': SID, 'transcript_path': TRANSCRIPT, 'cwd': CWD,
                          'scratchpad_dir': '/tmp/claude-%d/%s/%s/scratchpad' % (
                              os.getuid() if hasattr(os, 'getuid') else 0, re.sub(r'[^A-Za-z0-9]', '-', CWD), SID),
                          'prompt_id': TURN_UUID[0] or SID, 'permission_mode': MODE}
            if agent:                   # task 10: a subagent's call (48: after permission_mode)
                hook_input.update({'agent_id': agent, 'agent_type': 'general-purpose'})
            hook_input.update({'effort': {'level': current_effort() or 'medium'}, 'hook_event_name': event,
                               'tool_name': tool, 'tool_input': tool_input})
            if response is not None:
                hook_input['tool_response'] = response
            hook_input['tool_use_id'] = tid
            if event == 'PostToolUse':
                hook_input['duration_ms'] = 4
            rid = str(uuid.uuid4())
            log(sent={'id': rid, 'subtype': 'hook_callback', 'callback': callback})     # task 10
            with COND:
                P4_ANSWERS[rid] = None
                emit({'type': 'control_request', 'request_id': rid, 'request': {
                    'subtype': 'hook_callback', 'callback_id': callback, 'input': hook_input, 'tool_use_id': tid}})
            sent.append((rid, callback))
    answers = []
    deadline = ENV.get('FAKE_CLAUDE_HOOK_DEADLINE')
    cancel_ms = ENV.get('FAKE_CLAUDE_HOOK_CANCEL_MS')       # task 10 (unrecorded): withdrawn after MS
    for rid, callback in sent:
        if cancel_ms:
            answer = p4_wait(rid, int(cancel_ms) / 1000, interruptible=True)
            if answer is None and not CLOSED.is_set():
                emit({'type': 'control_cancel_request', 'request_id': rid})
                log(cancelled={'id': rid, 'callback': callback})
                answer = {'continue': True}
        elif deadline:
            answer = p4_wait(rid, int(deadline) / 1000, interruptible=True)
            if answer is None and not CLOSED.is_set() and not (INTERRUPT.is_set() and not DEAF.is_set()):
                answer = {'continue': True}     # past the deadline the call goes on
        else:
            beat, answer = 0, None
            while answer is None and not CLOSED.is_set() and not (INTERRUPT.is_set() and not DEAF.is_set()):
                answer = p4_wait(rid, 30, interruptible=True)
                if answer is None and not CLOSED.is_set() and not INTERRUPT.is_set():
                    emit({'type': 'tool_progress', 'tool_use_id': 'hook-%s-%s-heartbeat-%d' % (event, tid, beat),
                          'tool_name': event, 'parent_tool_use_id': tid, 'elapsed_time_seconds': 30 * (beat + 1),
                          'heartbeat': True, 'uuid': str(uuid.uuid4()), 'session_id': SID})
                    beat += 1
        with COND:
            P4_ANSWERS.pop(rid, None)
        log(hook=dict({'callback_id': callback, 'event': event, 'tool': tool, 'answer': answer},
                      **({'agent': agent} if agent else {})))     # agent: task 10
        answers.append(answer)
    return answers


def p4_context_lines(tid, tool, answers):
    """48: each PostToolUse answer's additionalContext as the file's attachment line after the call's result."""
    for answer in answers:
        output = (answer or {}).get('hookSpecificOutput') if isinstance(answer, dict) else None
        context = output.get('additionalContext') if isinstance(output, dict) else None
        if not isinstance(context, str):
            continue
        line = {'parentUuid': CHAIN[0], 'isSidechain': False, 'attachment': {
            'type': 'hook_additional_context', 'content': [context], 'hookName': 'PostToolUse:%s' % tool,
            'toolUseID': tid, 'hookEvent': 'PostToolUse'}, 'type': 'attachment', 'uuid': str(uuid.uuid4()),
            'timestamp': now_iso(), 'rendered': [{'content': '<system-reminder>\nPostToolUse:%s hook additional '
                                                             'context: %s\n</system-reminder>' % (tool, context)}],
            'renderedRole': 'system', 'userType': 'external',
            'entrypoint': ENV.get('CLAUDE_CODE_ENTRYPOINT') or 'sdk-cli', 'cwd': CWD, 'sessionId': SID,
            'version': '2.1.330', 'gitBranch': ''}
        with open(TRANSCRIPT, 'a', encoding='utf-8') as stream:
            stream.write(json.dumps(line, ensure_ascii=False) + '\n')


def p4_withdrawn_call(tid):
    """A call whose callbacks or request an interrupt withdrew (unrecorded for callbacks)."""
    tool_result(tid, REJECTED, True)
    cut_off(tool_turn=True)


def p4_file_call(name, tool_input, ask_input, apply):
    """An Edit or Write that asks (16): PreToolUse callbacks, can_use_tool, the allowed input applied (apply returns
    the outcome), PostToolUse callbacks, the result and the context lines. 'ok', 'error' (the tool failed: the
    turn goes on) or 'ended' (withdrawn, denied: the turn's end was sent)."""
    path = tool_input['file_path']
    mid = message_start()
    tid = tool_use(mid, 0, name, tool_input)
    message_end('tool_use')
    before = p4_lf(path)
    if None in p4_callbacks('PreToolUse', name, tid, ask_input):
        p4_withdrawn_call(tid)
        return 'ended'
    if MODE in ('acceptEdits', 'bypassPermissions') or rule_allows(name, path):
        answer = {'behavior': 'allow'}
    else:
        answer = ask_request(request_id(), {
            'subtype': 'can_use_tool', 'tool_name': name, 'display_name': name, 'input': ask_input,
            'description': os.path.basename(path),
            'permission_suggestions': [{'type': 'setMode', 'mode': 'acceptEdits', 'destination': 'session'}],
            'tool_use_id': tid})
        if answer is None:
            p4_withdrawn_call(tid)
            return 'ended'
        log(answer=answer)
    if answer.get('behavior') != 'allow':
        DENIALS.append({'tool_name': name, 'tool_use_id': tid, 'tool_input': ask_input})
        if answer.get('interrupt') is True:     # 49: Yb, whatever the message said
            user({'type': 'tool_result', 'content': REJECTED, 'is_error': True, 'tool_use_id': tid},
                 tool_use_result='User rejected tool use')
            cut_off(tool_turn=True)
            return 'ended'
        tool_result(tid, answer.get('message', ''), True)
        final('not changed')
        return 'ended'
    apply_updates(answer)
    allowed = answer.get('updatedInput') if isinstance(answer.get('updatedInput'), dict) else ask_input
    outcome = apply(allowed, before)
    posts = p4_callbacks('PostToolUse', name, tid, allowed, outcome[2] if isinstance(outcome[2], dict) else None)
    give(tid, name, outcome)
    p4_context_lines(tid, name, posts)
    return 'error' if outcome[1] else 'ok'


def p4_lf(path):
    """A file's text as the CLI sees it (CR LF read as LF, 49), or None."""
    try:
        with open(path, 'rb') as stream:
            return stream.read().decode('utf-8', 'replace').replace('\r\n', '\n')
    except OSError:
        return None


def p4_apply_edit(edit, before):
    """49: the edit applied to the file's LF text; written back with CR LF when the file had them; refused when the
    file changed since the call."""
    path = edit.get('file_path', '')
    try:
        with open(path, 'rb') as stream:
            raw = stream.read()
    except OSError:
        return read_missing()
    text_ = raw.decode('utf-8', 'replace').replace('\r\n', '\n')
    if before is not None and text_ != before:
        return CHANGED, True, 'Error: ' + CHANGED
    old = str(edit.get('old_string', '')).replace('\r\n', '\n')
    new = str(edit.get('new_string', '')).replace('\r\n', '\n')
    outcome = edit_outcome(path, text_, old, new, edit.get('replace_all') is True)
    if not outcome[1]:
        changed = text_.replace(old, new) if edit.get('replace_all') is True else text_.replace(old, new, 1)
        with open(path, 'wb') as stream:
            stream.write((changed.replace('\n', '\r\n') if b'\r\n' in raw else changed).encode('utf-8'))
    return outcome


def p4_apply_write(edit, before):
    path = edit.get('file_path', '')
    content = str(edit.get('content', ''))
    with open(path, 'w', encoding='utf-8', newline='') as stream:
        stream.write(content)
    return write_outcome(path, content, before)


def p4_path(word, default):
    return os.path.join(CWD, word if word else default)


def s_editfile(prompt, default_old=None):
    """editfile FILE OLD NEW (hookedit [FILE]: its first line gets " (edited)")."""
    words = prompt.split()
    path = p4_path(words[1] if len(words) > 1 else '', 'notes.txt')
    if default_old is not None or len(words) < 4:
        first = (p4_lf(path) or '').split('\n', 1)[0]
        old, new = first, first + ' (edited)'
    else:
        old, new = words[2], words[3]
    ask_input = {'file_path': path, 'old_string': old, 'new_string': new, 'replace_all': False}
    done = p4_file_call('Edit', {'replace_all': False, 'file_path': path, 'old_string': old, 'new_string': new},
                        ask_input, p4_apply_edit)
    if done != 'ended':
        final('edited' if done == 'ok' else 'not edited')


def s_hookedit(prompt):
    s_editfile(prompt, default_old=True)


def s_writefile(prompt):
    """writefile FILE TEXT"""
    words = prompt.split(None, 2)
    path = p4_path(words[1] if len(words) > 1 else '', 'w.txt')
    content = words[2] if len(words) > 2 else 'hi'
    tool_input = {'file_path': path, 'content': content}
    done = p4_file_call('Write', tool_input, dict(tool_input), p4_apply_write)
    if done != 'ended':
        final('written' if done == 'ok' else 'not written')


def s_hookread(prompt):
    """hookread FILE: a Read with its PreToolUse callbacks (48: no can_use_tool)."""
    words = prompt.split()
    path = p4_path(words[1] if len(words) > 1 else '', 'notes.txt')
    mid = message_start()
    tid = tool_use(mid, 0, 'Read', {'file_path': path})
    message_end('tool_use')
    if None in p4_callbacks('PreToolUse', 'Read', tid, {'file_path': path}):
        p4_withdrawn_call(tid)
        return
    give(tid, 'Read', read_call(path))
    final('read')


def s_diag(prompt):
    """diag [FILE]: 46's call of the first server's getDiagnostics."""
    words = prompt.split()
    name = next((n for n, s in P4_SERVERS.items() if s['state'] == 'connected'
                 and any(t.get('name') == 'getDiagnostics' for t in s['tools'])), None)
    if name is None:
        final('There is no getDiagnostics tool.')
        return
    full = 'mcp__%s__getDiagnostics' % name
    args = {'uri': 'file://' + p4_path(words[1], '')} if len(words) > 1 else {}
    mid = message_start()
    tid = tool_use(mid, 0, full, args)
    message_end('tool_use')
    if MODE == 'bypassPermissions' or rule_allows(full, ''):
        answer = {'behavior': 'allow'}
    else:
        answer = ask_request(request_id(), {
            'subtype': 'can_use_tool', 'tool_name': full, 'mcp_server': {'name': name, 'source': 'sdk'},
            'display_name': 'GetDiagnostics', 'input': args,
            'permission_suggestions': [{'type': 'addRules', 'rules': [{'toolName': full}], 'behavior': 'allow',
                                        'destination': 'localSettings'}],
            'server_policy_ask_only': False, 'tool_use_id': tid})
        if answer is None:
            p4_withdrawn_call(tid)
            return
        log(answer=answer)
    if answer.get('behavior') != 'allow':
        DENIALS.append({'tool_name': full, 'tool_use_id': tid, 'tool_input': args})
        tool_result(tid, REJECTED if answer.get('interrupt') is True else answer.get('message', ''), True)
        if answer.get('interrupt') is True:
            cut_off(tool_turn=True)
        else:
            final('not called')
        return
    apply_updates(answer)
    arguments = answer.get('updatedInput') if isinstance(answer.get('updatedInput'), dict) else args
    call_id = P4_SERVERS[name]['next']
    message = p4_request(name, 'tools/call', {'name': 'getDiagnostics', 'arguments': arguments,
                                             '_meta': {'claudecode/toolUseId': tid, 'progressToken': call_id}})
    rid = p4_send(name, message)
    answer = p4_wait(rid, interruptible=True)
    if answer is None:
        if INTERRUPT.is_set() and not DEAF.is_set():    # 46: no control_cancel_request; the server is told
            p4_send(name, {'jsonrpc': '2.0', 'method': 'notifications/cancelled',
                           'params': {'requestId': call_id, 'reason': 'AbortError: remote-cancel'}})
            ACKED.wait(5)
            user({'type': 'tool_result', 'content': STOPPED, 'is_error': True, 'tool_use_id': tid},
                 tool_use_result='User rejected tool use')
            cut_off(tool_turn=True)
        return
    log(mcp={'server': name, 'method': 'tools/call', 'id': call_id, 'answer': answer})
    reply = answer.get('mcp_response') if isinstance(answer.get('mcp_response'), dict) else {}
    found = reply.get('result') if isinstance(reply.get('result'), dict) else None
    if found is None:                           # unrecorded: a JSON-RPC error (or an error control response)
        said = str((reply.get('error') or {}).get('message') if isinstance(reply.get('error'), dict)
                   else answer.get('error', 'no answer'))
        give(tid, full, (said, True, 'Error: ' + said))
        final('The diagnostics tool failed.')
        return
    content = found.get('content') if isinstance(found.get('content'), list) else []
    if found.get('isError') is True:
        said = '\n'.join(str(c.get('text', '')) for c in content if isinstance(c, dict))
        give(tid, full, (said, True, 'Error: ' + said))
        final('The diagnostics tool failed: ' + said)
        return
    give(tid, full, (content, False, content))
    try:
        entries = len(json.loads(content[0]['text'])) if content else 0
    except (ValueError, KeyError, TypeError, IndexError):
        entries = 0
    final('The diagnostics tool returned %d %s.' % (entries, 'entry' if entries == 1 else 'entries'))


def s_echoblocks(prompt):
    """echoblocks: one line per block of the message rhun sent (not the replay's rewrite)."""
    import base64
    lines = []
    for block in P4_CONTENT[0] if isinstance(P4_CONTENT[0], list) else []:
        if not isinstance(block, dict):
            continue
        source = block.get('source') if isinstance(block.get('source'), dict) else {}
        data = str(source.get('data', ''))
        if block.get('type') == 'text':
            lines.append('text %d' % len(block.get('text', '')))
        elif source.get('type') == 'base64':
            try:
                size = len(base64.b64decode(data))
            except ValueError:
                size = -1
            lines.append(' '.join(str(x) for x in (block.get('type'), source.get('media_type'), block.get('title'), size)
                                  if x is not None))
        else:
            lines.append(' '.join(str(x) for x in (block.get('type'), source.get('media_type'), block.get('title'),
                                                   len(data)) if x is not None))
    final('\n'.join(lines) or 'no blocks')


def s_notify(prompt):
    """notify: unrecorded for a server not named claude-vscode (47): experiment_gates, then file_updated."""
    name = next(iter(P4_SERVERS), None)
    if name is not None:
        for method, params in (('experiment_gates', {'gates': {'tengu_vscode_inline_pastes': True}}),
                               ('file_updated', {'filePath': os.path.join(CWD, 'notes.txt'), 'oldContent': 'one\n',
                                                 'newContent': 'two\n'})):
            answer = p4_wait(p4_send(name, {'method': method, 'params': params, 'jsonrpc': '2.0'}), 5)
            log(mcp={'server': name, 'method': method, 'id': None, 'answer': answer})
    final('notified')


SCENARIOS.update({'diag': s_diag, 'hookedit': s_hookedit, 'hookread': s_hookread, 'editfile': s_editfile,
                  'writefile': s_writefile, 'echoblocks': s_echoblocks, 'notify': s_notify})


# ---- phase 4 tasks 11 and 12: proposed changes in the Review tab ----
# editjs JSON (an Edit whose input is that JSON object: file_path relative to the cwd, old_string, new_string,
# replace_all, as p4_file_call asks and applies it), writejs JSON (a Write likewise), editlater MS REST (MS ms,
# then `editfile REST`: a request that comes while the user types), editnowrite FILE OLD NEW (asks as editfile,
# applies nothing: a test that rhun writes no file reads the file's bytes after an allow), edit2 FILE OLD1 NEW1
# OLD2 NEW2 (one message with two Edits whose requests wait at once; each allowed one is applied in order).
def p4_input(prompt):
    rest = prompt.split(None, 1)[1] if len(prompt.split(None, 1)) > 1 else '{}'
    data = json.loads(rest)
    data['file_path'] = p4_path(data.get('file_path', ''), 'notes.txt')
    return data


def s_editjs(prompt):
    data = p4_input(prompt)
    tool_input = {'replace_all': data.get('replace_all', False), 'file_path': data['file_path'],
                  'old_string': data.get('old_string', ''), 'new_string': data.get('new_string', '')}
    ask_input = {'file_path': data['file_path'], 'old_string': tool_input['old_string'],
                 'new_string': tool_input['new_string'], 'replace_all': tool_input['replace_all']}
    done = p4_file_call('Edit', tool_input, ask_input, p4_apply_edit)
    if done != 'ended':
        final('edited' if done == 'ok' else 'not edited')


def s_writejs(prompt):
    data = p4_input(prompt)
    tool_input = {'file_path': data['file_path'], 'content': data.get('content', '')}
    done = p4_file_call('Write', tool_input, dict(tool_input), p4_apply_write)
    if done != 'ended':
        final('written' if done == 'ok' else 'not written')


def s_editlater(prompt):
    words = prompt.split(None, 2)
    time.sleep(int(words[1]) / 1000.0 if len(words) > 1 else 0.3)
    s_editfile('editfile ' + (words[2] if len(words) > 2 else ''))


def s_editnowrite(prompt):
    words = prompt.split()
    path = p4_path(words[1] if len(words) > 1 else '', 'notes.txt')
    old, new = (words[2], words[3]) if len(words) > 3 else ('a', 'b')
    ask_input = {'file_path': path, 'old_string': old, 'new_string': new, 'replace_all': False}
    done = p4_file_call('Edit', dict(ask_input), ask_input,
                        lambda edit, before: ('The file %s has been updated successfully.' % path, False, None))
    if done != 'ended':
        final('edited')


def s_edit2(prompt):
    words = prompt.split()
    path = p4_path(words[1] if len(words) > 1 else '', 'notes.txt')
    edits = [{'file_path': path, 'old_string': words[2], 'new_string': words[3], 'replace_all': False},
             {'file_path': path, 'old_string': words[4], 'new_string': words[5], 'replace_all': False}]
    mid = message_start()
    tids = [tool_use(mid, i, 'Edit', dict(edit)) for i, edit in enumerate(edits)]
    message_end('tool_use')
    rids = [request_id() for _ in edits]
    with COND:
        for rid, edit, tid in zip(rids, edits, tids):
            PENDING[rid] = None
            emit({'type': 'control_request', 'request_id': rid, 'request': {
                'subtype': 'can_use_tool', 'tool_name': 'Edit', 'display_name': 'Edit', 'input': edit,
                'description': os.path.basename(path), 'permission_suggestions': [], 'tool_use_id': tid}})
        answers = {}
        while len(answers) < len(rids) and not withdrawn():
            for rid in rids:
                if rid not in answers and PENDING.get(rid) is not None:
                    answers[rid] = PENDING.pop(rid)
            COND.wait(0.05)
    for rid, edit, tid in zip(rids, edits, tids):
        answer = answers.get(rid)
        log(answer=answer)
        if not answer or answer.get('behavior') != 'allow':
            tool_result(tid, REJECTED, True)
            continue
        allowed = answer.get('updatedInput') if isinstance(answer.get('updatedInput'), dict) else edit
        give(tid, 'Edit', p4_apply_edit(allowed, None))
    final('both')


SCENARIOS.update({'editjs': s_editjs, 'writejs': s_writejs, 'editlater': s_editlater, 'editnowrite': s_editnowrite,
                  'edit2': s_edit2})
# ---- end of tasks 11 and 12 ----


# task 10 (unrecorded as one sequence; each callback's shape is 48's): hooksub FILE: the main Edit's PreToolUse
# callbacks, its can_use_tool (a card: the test changes the problems meanwhile), then a subagent's Edit of the same
# file (agent_id "sub1") with its PreToolUse and PostToolUse callbacks, then the main Edit's PostToolUse. Nothing is
# written to the file.
def s_hooksub(prompt):
    words = prompt.split()
    path = p4_path(words[1] if len(words) > 1 else '', 'notes.txt')
    first = (p4_lf(path) or '').split('\n', 1)[0]
    edit = {'file_path': path, 'old_string': first, 'new_string': first, 'replace_all': False}
    mid = message_start()
    tid = tool_use(mid, 0, 'Edit', dict(edit))
    message_end('tool_use')
    p4_callbacks('PreToolUse', 'Edit', tid, edit)
    answer = ask_request(request_id(), {
        'subtype': 'can_use_tool', 'tool_name': 'Edit', 'display_name': 'Edit', 'input': edit,
        'description': os.path.basename(path), 'tool_use_id': tid})
    if answer is None:
        p4_withdrawn_call(tid)
        return
    sub = 'toolu_sub_' + uuid.uuid4().hex[:12]
    p4_callbacks('PreToolUse', 'Edit', sub, edit, agent='sub1')
    p4_callbacks('PostToolUse', 'Edit', sub, edit, {'filePath': path}, agent='sub1')
    p4_callbacks('PostToolUse', 'Edit', tid, edit, {'filePath': path})
    tool_result(tid, 'The file %s has been updated successfully.' % path, False)
    final('edited')


SCENARIOS['hooksub'] = s_hooksub


REFUSED = [False]                   # FAKE_CLAUDE_REFUSE_HELD: one held message was refused already
DISCARDED = [False]                 # FAKE_CLAUDE_DISCARD_HELD: one held message was marked to be discarded
QUIET = set()                       # FAKE_CLAUDE_NO_LIFECYCLE=local: the uuids of the CLI's own commands


# ---- p7c (claude-chat-p7c: tests/claude-panels.py): the side question, Claude in Chrome, Remote Control ----
def side_question(rid, request):
    """side_question {question, history?} (RECORDED, README finding 100: question a string, history an array of
    {question, response} strings, the answer {response, synthetic: false}, a control_request_progress {status
    started} before it). The answer is "side: QUESTION" (" (N before)" with a history of N) after
    FAKE_CLAUDE_SIDE_MS (default 100; unrecorded timing). Unrecorded knobs by the question's first word: "fail"
    answers an error ("side question failed"), "empty" answers {response: null, synthetic: true} (the binary's
    no_response case), "slow" waits 3 s, "never" never answers. Logged {"side": {question, history}}."""
    question = request.get('question') if isinstance(request.get('question'), str) else ''
    history = request.get('history')
    log(side={'question': question, 'history': history})
    if not isinstance(history, list) or any(not isinstance(h, dict) or not isinstance(h.get('question'), str)
                                            or not isinstance(h.get('response'), str) for h in history):
        if history is not None:     # the CLI's own words for a history it cannot read (finding 100)
            respond_error(rid, "undefined is not an object (evaluating 'q.response.endsWith')")
            return
    emit({'type': 'system', 'subtype': 'control_request_progress', 'request_id': rid, 'status': 'started',
          'uuid': str(uuid.uuid4()), 'session_id': SID})
    word = (question.split() or [''])[0]
    if word == 'never':
        return
    delay = 3.0 if word == 'slow' else int(ENV.get('FAKE_CLAUDE_SIDE_MS', '100')) / 1000

    def answer():
        if word == 'fail':
            respond_error(rid, 'side question failed')
        elif word == 'empty':
            respond(rid, {'response': None, 'synthetic': True})
        else:
            after = ' (%d before)' % len(history) if history else ''
            respond(rid, {'response': 'side: ' + question + after, 'synthetic': False})
    threading.Timer(delay, answer).start()


def chrome_dialog(rid, request):
    """get_chrome_dialog (RECORDED, README finding 101, on an account with the extension not installed).
    FAKE_CLAUDE_CHROME (unrecorded): "installed" says installed, "connected" installed and connected, "denied"
    allowed false."""
    kind = ENV.get('FAKE_CLAUDE_CHROME', '')
    respond(rid, {'allowed': kind != 'denied', 'subscriber': True, 'wsl': False,
                  'installed': kind in ('installed', 'connected'), 'connected': kind == 'connected',
                  'enabled_by_default': True, 'at_startup': True,
                  'urls': {'install': 'https://claude.ai/chrome', 'reconnect': 'https://clau.de/chrome/reconnect',
                           'permissions': 'https://clau.de/chrome/permissions'}})


def remote_control(rid, request):
    """remote_control {enabled} (UNRECORDED: enabling it publishes the session to the account; the shapes are
    the CLI binary's: the answer, then system/bridge_state {state, detail, bridge_epoch}). Enabled: an empty
    success, then after 50 ms bridge_state connected. FAKE_CLAUDE_REMOTE: "fail" answers an error ("Remote
    Control is not available for this account"), "bridgefail" a success and then bridge_state failed with the
    detail "Could not reach claude.ai". Logged {"remote": enabled}."""
    enabled = request.get('enabled') is True
    log(remote=enabled)
    kind = ENV.get('FAKE_CLAUDE_REMOTE', '')
    if enabled and kind == 'fail':
        respond_error(rid, 'Remote Control is not available for this account')
        return
    respond(rid, {'bridge_session_id': 'cse_fake'} if enabled else {})
    if enabled:
        def later():
            state = {'state': 'failed', 'detail': 'Could not reach claude.ai', 'failure_kind': 'terminal'} \
                if kind == 'bridgefail' else {'state': 'connected'}
            emit(dict({'type': 'system', 'subtype': 'bridge_state'}, **state, bridge_epoch=1,
                      uuid=str(uuid.uuid4()), session_id=SID))
        threading.Timer(0.05, later).start()


P7C_REQUESTS = {'side_question': side_question, 'get_chrome_dialog': chrome_dialog, 'remote_control': remote_control}


def s_chrome(prompt):
    """`chrome` (UNRECORDED: no Chrome extension was connected): a call of Claude Code's own browser server,
    mcp__claude-in-chrome__navigate {url}, that runs without asking, then the reply."""
    mid = message_start()
    tid = tool_use(mid, 0, 'mcp__claude-in-chrome__navigate', {'url': 'https://example.com/page', 'tabId': 1})
    message_end('tool_use')
    tool_result(tid, 'Navigated to https://example.com/page')
    final('done')


SCENARIOS.update({'chrome': s_chrome})
# ---- end p7c ----


def handle(message):
    global MODE
    kind = message.get('type')
    if kind == 'control_request':
        rid, request = message.get('request_id'), message.get('request', {})
        sub = request.get('subtype')
        if sub == 'initialize':
            time.sleep(int(ENV.get('FAKE_CLAUDE_INIT_MS', '0')) / 1000)
            SUGGEST[0] = request.get('promptSuggestions') is True
            logged_init = {'promptSuggestions': request.get('promptSuggestions'),
                           'supportedDialogKinds': request.get('supportedDialogKinds')}
            for member in ('perTaskStopAffordance', 'forwardNestedSubagentToolCalls') + P4_MEMBERS:   # phases 3, 4
                if member in request and (member not in P4_MEMBERS or request[member] is not None):
                    logged_init[member] = request[member]
            log(initialize=logged_init)
            if 'start' in HOOKS_ON:         # finding 32: SessionStart's records come before the answer
                hook_records('SessionStart', 'SessionStart:startup')
            extra = p4_initialize(request)  # phase 4: a server's first request goes out before the answer
            respond(rid, p4_answer_members(init_response(), extra))
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
            if review_later(message, 'mode_answer', 'FAKE_CLAUDE_MODE_MS'):
                return
            mode = 'default' if request.get('mode') == 'manual' else request.get('mode', MODE)
            if mode == 'bypassPermissions' and not BYPASS_OK:
                respond_error(rid, 'Cannot set permission mode to bypassPermissions because the session was not '
                              'launched with --dangerously-skip-permissions')
                return
            if mode == 'auto' and ENV.get('FAKE_CLAUDE_REFUSE_AUTO'):   # unrecorded: auto refused
                respond_error(rid, 'Cannot set permission mode to auto')
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
            if review_settings(message):
                return
            if ENV.get('FAKE_CLAUDE_SETTINGS_FAIL'):    # unrecorded: the CLI's error answer, with that text
                respond_error(rid, ENV['FAKE_CLAUDE_SETTINGS_FAIL'])
            else:
                respond(rid, get_settings())
        elif sub == 'apply_flag_settings':
            settings = request.get('settings') if isinstance(request.get('settings'), dict) else {}
            if review_flags_later(message) or review_refuse_flags(rid, settings):
                return
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
            plan = review_plan()
            respond(rid, dict(exists=True, **plan) if plan else {'exists': False})
        elif sub == 'stop_task':
            stop_task(rid, request.get('task_id'))
        elif sub == 'background_tasks':
            to_background(rid, request.get('tool_use_id'))
        elif sub == 'mcp_status':           # phase 4 (44, 51): the SDK servers
            respond(rid, {'mcpServers': p4_status()})
        elif sub in P7C_REQUESTS:           # p7c: the side question, Chrome, Remote Control
            P7C_REQUESTS[sub](rid, request)
        else:
            respond_error(rid, 'Unsupported control request subtype: %s' % sub)
    elif kind == 'control_response':
        response = message.get('response', {})
        if REPLAY:                          # 18: with --replay-user-messages every answer comes back as sent
            emit(message)
        if p4_answer(response):             # phase 4: an answer to the fake's mcp_message or hook_callback
            return
        with COND:
            rid = response.get('request_id')
            if rid in PENDING and PENDING[rid] is None:   # a late answer to a withdrawn id is ignored (C10)
                PENDING[rid] = response.get('response') if response.get('subtype') == 'success' \
                    else {'behavior': 'error', 'message': response.get('error', '')}
                COND.notify_all()
    elif kind == 'user':
        uid = message.get('uuid') if isinstance(message.get('uuid'), str) else None
        content = message.get('message', {}).get('content')
        entry = {'text': prompt_text(message), 'uuid': uid, 'content': content,
                 'pastes': message.get('inline_pastes')}     # phase 4 (43)
        with COND:
            if uid and ENV.get('FAKE_CLAUDE_REFUSE_HELD') and (BUSY[0] or QUEUE) and not REFUSED[0]:
                REFUSED[0] = True           # unrecorded: the state exists in the schema, no run produced it
                log(refused=uid)
                lifecycle(uid, 'refused')
                return
            words = entry['text'].split()
            if uid and words and words[0] in LOCAL_COMMANDS:
                QUIET.add(uid)
            if uid and ENV.get('FAKE_CLAUDE_DISCARD_HELD') in ('1', entry['text']) and (BUSY[0] or QUEUE) \
                    and not DISCARDED[0]:
                DISCARDED[0] = True         # unrecorded: queued now, discarded when its turn would start
                entry['discard'] = True
            QUEUE.append(entry)
            if uid:
                lifecycle(uid, 'queued')
            COND.notify_all()


def system_init():
    """system/init: sent at the start of every turn (2.1.330, finding 17), not only the first (C4)."""
    emit({'type': 'system', 'subtype': 'init', 'cwd': CWD, 'session_id': SID,
          'tools': ['Task', 'AskUserQuestion', 'Bash', 'ExitPlanMode'] + todo_tools() + p4_tool_names(),
          'mcp_servers': p4_init_servers(),
          'model': current_model() + '[1m]', 'permissionMode': MODE, 'slash_commands': ['compact', 'context', 'usage'],
          'apiKeySource': ENV.get('FAKE_CLAUDE_KEYSRC', 'none'), 'claude_code_version': '2.1.330',
          'output_style': 'default', 'capabilities': ['interrupt_receipt_v1', 'msg_lifecycle_v1'],
          'uuid': str(uuid.uuid4()), 'fast_mode_state': FAST[0],
          'ultrathink_available': bool(ENV.get('FAKE_CLAUDE_ULTRATHINK'))})


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
    if 'prompt' in HOOKS_ON or 'block' in HOOKS_ON:     # finding 32
        if prompt_hook(prompt):
            return False
    p4_before_turn()                 # phase 4 (44, 51): system/init waits for the servers' handshakes
    P4_CONTENT[0] = entry['content']
    system_init()
    if LATE_USER:                    # wait for the stop rather than write to a reader that is gone
        CLOSED.wait(int(ENV.get('FAKE_CLAUDE_USER_LATE_WAIT_MS', '10000')) / 1000)
    status('requesting')
    if custom_command(prompt, entry):           # finding 31: `echo`, or /NAME with .claude/commands/NAME.md
        return True
    if REPLAY:                       # finding 17: the message comes back, with its uuid (the CLI's own without one)
        emit({'type': 'user', 'message': {'role': 'user', 'content': p4_blocks(entry)}, 'session_id': SID,
              'parent_tool_use_id': None, 'uuid': entry['uuid'] or str(uuid.uuid4()), 'timestamp': now_iso(),
              'isReplay': True})
    del DENIALS[:]
    scenario = SCENARIOS.get(ENV.get('FAKE_CLAUDE_SCENARIO') or (words[0].lower() if words else ''), s_plain)
    if LATE_USER:                    # nobody stopped it (10 s at most): the line goes in now
        transcript(LATE_USER.pop())
    elif scenario not in (s_unsaved, s_racing):     # (they save it later, if at all)
        p4_prompt_line(entry, prompt)               # phase 4: a message's blocks (38)
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


# ---- phase 7, the dialogs (claude-chat-p7): the requests behind Status, Account & usage, Context usage,
# Output styles, the slash commands browser, Memory and Instructions, in the shapes of README findings 60 to
# 66 (2.1.330's answers, account details made up). Knobs: FAKE_CLAUDE_DIALOG_MS (each answer that late);
# FAKE_CLAUDE_DIALOG_FAIL (comma-separated subtypes answered with "fake: SUBTYPE refused", unrecorded);
# FAKE_CLAUDE_USAGE (claude: bars, as recorded; api: no rate limits, the session's totals; none: no rate
# limits). set_skill_state and set_memory_setting keep their change in this process only and are logged
# (dialog=...); update_settings outputStyle goes to the project's local settings as above.
DIALOG_SUBTYPES = ('get_status', 'get_usage', 'get_context_usage', 'get_skills_dialog', 'set_skill_state',
                   'get_memory_dialog', 'set_memory_setting', 'reload_output_styles')
SKILL_STATES = {}                   # a skill's state set by set_skill_state (this process only)
MEMORY_SETTINGS = {'autoMemoryEnabled': True, 'autoDreamEnabled': False}


def dialog_status():
    """get_status (finding 60): two sections of label/value rows; cwd is the CLI's own label."""
    account = init_response().get('account') or {}
    session = [{'label': 'Version', 'value': '2.1.330'}, {'label': 'Session ID', 'value': SID},
               {'label': 'Session kind', 'value': 'interactive'}, {'label': 'cwd', 'value': CWD}]
    if account.get('email'):
        session += [{'label': 'Login method', 'value': account.get('subscriptionType', '') + ' account'},
                    {'label': 'Organization', 'value': account.get('organization', '')},
                    {'label': 'Email', 'value': account['email']}]
    return {'sections': [{'title': 'Session', 'rows': session},
                         {'title': 'Environment', 'rows': [{'label': 'Model', 'value': 'claude-opus-5-5'},
                                                            {'label': 'MCP servers', 'value': '1 connected · /mcp'},
                                                            {'label': 'Setting sources', 'value': 'User settings'}]}]}


def dialog_usage():
    """get_usage (finding 61): the session's totals, the plan, rate limits (null ones too), behaviors."""
    kind = ENV.get('FAKE_CLAUDE_USAGE', 'claude')
    session = {'total_cost_usd': 0.00449649, 'total_api_duration_ms': 1861, 'total_duration_ms': 3793000,
               'total_lines_added': 1, 'total_lines_removed': 2,
               'model_usage': {'claude-haiku-5-5': {'inputTokens': 1174, 'outputTokens': 16,
                                                    'cacheReadInputTokens': 25929, 'cacheCreationInputTokens': 20559,
                                                    'webSearchRequests': 0, 'costUSD': 0.00449649}}}
    if kind != 'claude':
        return {'session': session, 'subscription_type': None, 'rate_limits_available': False,
                'rate_limits': None, 'behaviors': None}
    resets = time.strftime('%Y-%m-%dT%H:%M:%S.180576+00:00', time.gmtime(time.time() + 2 * 86400))
    return {'session': session, 'subscription_type': 'max', 'rate_limits_available': True,
            'rate_limits': {'five_hour': None,
                            'seven_day': {'utilization': 14, 'resets_at': resets, 'limit_dollars': None},
                            'seven_day_opus': None, 'seven_day_sonnet': None,
                            'model_scoped': [{'display_name': 'Fable', 'utilization': 16.5, 'resets_at': resets}]},
            'behaviors': {'day': {'recommendations': [{'key': 'long_context', 'pct': 93,
                                                       'title': 'Start fresh when you switch tasks',
                                                       'detail': 'run /clear'}]}, 'week': None}}


def dialog_context():
    """get_context_usage (finding 62): categories (deferred ones too), totals, memory files, agents."""
    return {'categories': [{'id': 'system_prompt', 'name': 'System prompt', 'tokens': 3624, 'color': 'promptBorder',
                            'kind': 'used'},
                           {'id': 'system_tools', 'name': 'System tools', 'tokens': 14339, 'color': 'inactive',
                            'kind': 'used'},
                           {'id': 'mcp_tools_deferred', 'name': 'MCP tools (deferred)', 'tokens': 88115,
                            'color': 'inactive', 'isDeferred': True, 'kind': 'deferred'},
                           {'id': 'memory_files', 'name': 'Memory files', 'tokens': 385, 'color': 'claude',
                            'kind': 'used'},
                           {'id': 'messages', 'name': 'Messages', 'tokens': 0, 'color': 'purple', 'kind': 'used'},
                           {'id': 'free_space', 'name': 'Free space', 'tokens': 934008, 'color': 'promptBorder',
                            'kind': 'free'}],
            'totalTokens': 32992, 'maxTokens': 1000000, 'rawMaxTokens': 1000000,
            'autocompactSource': 'model-default', 'percentage': 3, 'gridRows': [], 'model': 'claude-haiku-5-5',
            'memoryFiles': [{'path': ENV['HOME'] + '/.claude/CLAUDE.md', 'type': 'User', 'tokens': 14},
                            {'path': CWD + '/CLAUDE.md', 'type': 'Project', 'tokens': 371}],
            'mcpTools': [], 'agents': [{'agentType': 'reviewer', 'source': 'projectSettings', 'tokens': 404}],
            'isAutoCompactEnabled': True, 'apiUsage': None}


def dialog_skills():
    """get_skills_dialog (finding 64): {skills: [...]} (no "dialog" member), a plugin's skill locked."""
    skills = [{'name': 'review', 'display_name': 'review', 'description': 'Review the diff', 'source': 'user',
               'tokens': 119, 'state': 'on', 'advertised': True, 'handles': {'unqualified_name': 'review',
                                                                            'aliases': ['review']}},
              {'name': 'tools:lint', 'display_name': 'tools:lint', 'source': 'plugin', 'tokens': 1234,
               'state': 'on', 'locked_by': 'plugin', 'advertised': True, 'handles': {'aliases': ['lint']}},
              {'name': 'notes', 'display_name': 'notes', 'source': 'user', 'tokens': 12, 'state': 'off',
               'advertised': False, 'handles': {}}]
    for skill in skills:
        skill['state'] = SKILL_STATES.get(skill['name'], skill['state'])
    return {'skills': skills}


def dialog_memory():
    """get_memory_dialog (finding 65): files, folders, memories, auto_memory, auto_dream."""
    folder = os.path.join(config_dir(), 'projects', re.sub(r'[^A-Za-z0-9]', '-', CWD), 'memory')
    memories = []
    if os.path.isdir(folder):
        for name in sorted(os.listdir(folder)):
            path = os.path.join(folder, name)
            memories.append({'name': name, 'path': path, 'type': 'feedback', 'description': None,
                             'modified_ms': int(os.path.getmtime(path) * 1000)})
    return {'files': [{'kind': 'user', 'path': os.path.join(config_dir(), 'CLAUDE.md'), 'label': 'User instructions',
                       'description': 'Saved in ~/.claude/CLAUDE.md', 'exists': True},
                      {'kind': 'project', 'path': os.path.join(CWD, 'CLAUDE.md'), 'label': 'Project instructions',
                       'description': 'Checked in at ./CLAUDE.md', 'exists': True},
                      {'kind': 'local', 'path': os.path.join(CWD, 'CLAUDE.local.md'), 'label': 'CLAUDE.local.md',
                       'description': '', 'exists': False}],
            'folders': [{'kind': 'auto', 'path': folder + '/', 'label': 'Open auto-memory folder', 'description': ''}],
            'memories': memories,
            'auto_memory': {'enabled': MEMORY_SETTINGS['autoMemoryEnabled'], 'toggleable': True,
                            'status': 'on' if MEMORY_SETTINGS['autoMemoryEnabled'] else 'off'},
            'auto_dream': {'shown': False, 'enabled': MEMORY_SETTINGS['autoDreamEnabled'], 'toggleable': True,
                           'status': 'off', 'detail': ''}}


def dialog_request(rid, sub, request):
    if sub in ENV.get('FAKE_CLAUDE_DIALOG_FAIL', '').split(','):
        respond_error(rid, 'fake: %s refused' % sub)
        return
    if sub == 'set_skill_state':
        SKILL_STATES[request.get('name')] = request.get('state')
        log(dialog={'set_skill_state': {k: request.get(k) for k in ('name', 'state', 'handles')}})
        answer = dialog_skills()
    elif sub == 'set_memory_setting':
        MEMORY_SETTINGS[request.get('setting')] = request.get('enabled')
        log(dialog={'set_memory_setting': {k: request.get(k) for k in ('setting', 'enabled')}})
        answer = {'dialog': dialog_memory()}
    elif sub == 'reload_output_styles':      # finding 63
        answer = {'available_output_styles': ['default', 'Explanatory', 'Learning']}
    else:
        answer = {'get_status': dialog_status, 'get_usage': dialog_usage, 'get_context_usage': dialog_context,
                  'get_skills_dialog': dialog_skills, 'get_memory_dialog': dialog_memory}[sub]()
    delay = int(ENV.get('FAKE_CLAUDE_DIALOG_MS', '0')) / 1000
    if delay:
        threading.Timer(delay, respond, (rid, answer)).start()
    else:
        respond(rid, answer)


_handle_before_dialogs = handle


def handle(message):                        # noqa: F811 (the dialogs' requests first, then the rest)
    request = message.get('request') if message.get('type') == 'control_request' else None
    if isinstance(request, dict) and request.get('subtype') in DIALOG_SUBTYPES and not message.get('_later'):
        dialog_request(message.get('request_id'), request.get('subtype'), request)
        return
    _handle_before_dialogs(message)
# ---- end of phase 7's dialogs ----


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
