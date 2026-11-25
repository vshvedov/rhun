#!/usr/bin/env python3
"""Shapes of Claude Code stream-json records: one short line per record the CLI sent, so a recording
and the fake's output can be compared without their text. Usage: claude-shapes.py RECORDING.jsonl

`claude-shapes.py --keys RECORDING.jsonl...` prints the field order of every kind of record instead (field
names only, no values): tests/data/claude-shapes/keys.txt, which tests/fake-claude.py holds every record
of the fake to (key_order_ok).

The conversation's own file (<config>/projects/<slug>/<id>.jsonl, and a subagent's <id>/subagents/agent-ID.jsonl)
has records of its own (README.txt finding 27): `claude-shapes.py --file FILE.jsonl` prints the shapes of the
records a reader of the file reads (user, assistant and system lines; the bookkeeping types are left out), and
`claude-shapes.py --file-keys FILE.jsonl...` the field order of every kind of line: file-keys.txt.
`--fold` (with a recording or --file) also folds a repeated pair of shapes (thinking_tokens and thinking_delta
alternate once per delta) into one; `--hooks` keeps the hook records shape() leaves out.
`--cut-data RECORDING.jsonl` prints the phase 4 shape files (23 to 26): one line per record, both directions,
`DIR SHAPE` or, for the records whose content the protocol pins (DETAIL), `DIR SHAPE JSON` with every base64
`data` string cut to 16 characters, the run's folder written $CWD, its slug $SLUG and the home folder ~
(records that carry the user's own setup, such as system/init or the initialize answer, keep only their shape)."""
import json
import re
import sys

# records whose place depends on timing, not on the protocol (commands_changed comes about 300 ms after
# the initialize answer: before system/init or after it, depending on when the first prompt went out)
SKIP = {'system/hook_started', 'system/hook_response', 'system/status', 'rate_limit_event',
        'system/commands_changed'}


HOOKS = {'system/hook_started', 'system/hook_progress', 'system/hook_response'}


def shape(msg, hooks=False):
    """The shape of one record from the CLI, or None for records the comparison ignores (hooks: the hook
    records are kept)."""
    if not isinstance(msg, dict):
        return 'raw'
    kind = msg.get('type', '?')
    if hooks and kind == 'system' and 'system/' + str(msg.get('subtype')) in HOOKS:
        return 'system/%s:%s' % (msg.get('subtype'), msg.get('hook_event'))
    if kind == 'stream_event':
        event = msg.get('event', {})
        name = 'stream_event/' + event.get('type', '?')
        if event.get('type') == 'content_block_start':
            name += ':' + event.get('content_block', {}).get('type', '?')
        if event.get('type') == 'content_block_delta':
            name += ':' + event.get('delta', {}).get('type', '?')
        return name
    if kind in ('system', 'result'):
        name = kind + '/' + str(msg.get('subtype'))
        return None if name in SKIP else name
    if kind == 'assistant':
        content = msg.get('message', {}).get('content') or [{}]
        name = 'assistant:' + content[0].get('type', '?')
        if content[0].get('type') == 'tool_use':
            name += ':' + content[0].get('name', '?')
        return name + (':aborted' if msg.get('aborted') else '')
    if kind == 'user':
        content = msg.get('message', {}).get('content')
        if isinstance(content, list) and content:
            return 'user:' + content[0].get('type', '?')
        return 'user:string'
    if kind == 'control_request':
        request = msg.get('request', {})
        return 'control_request/' + request.get('subtype', '?') + ':' + request.get('tool_name', '')
    if kind == 'control_response':
        return 'control_response/' + msg.get('response', {}).get('subtype', '?')
    if kind in SKIP:
        return None
    return kind


def shapes(records, hooks=False):
    """Shapes of the records rhun reads, in order, runs of the same shape (deltas) folded into one."""
    out = []
    for msg in records:
        name = shape(msg, hooks)
        if name is None or (out and out[-1] == name):
            continue
        out.append(name)
    return out


def fold_pairs(names):
    """names with a repeated pair (A B A B ...) folded into one A B: thinking_tokens and thinking_delta
    alternate once per delta, as many times as the model thought."""
    out = []
    for name in names:
        out.append(name)
        while len(out) >= 4 and out[-4:-2] == out[-2:]:
            del out[-2:]
    return out


# the conversation's file (finding 27): the types a reader reads; everything else is the CLI's bookkeeping
# (attachment, queue-operation, api-request, api-request-blob, api-request-shape, session-owner, atis-latch,
# ai-title, last-prompt, tools-used, cost-state, ...), and api-request-blob even carries copies of messages
FILE_READ = ('user', 'assistant', 'system')


def file_kind(rec, tools):
    """The kind of one line of the conversation's file: user and assistant by their first block (a tool_result
    by its tool's name and outcome, as key_kind), system by subtype, attachment by its type, else the type.
    tools maps tool_use ids to names (filled from assistant lines)."""
    kind = rec.get('type', '?')
    if kind == 'system':
        return 'system/' + str(rec.get('subtype'))
    if kind == 'attachment':
        return 'attachment/' + str((rec.get('attachment') or {}).get('type'))
    if kind in ('user', 'assistant'):
        content = part(rec, 'message.content')
        if isinstance(content, str):
            return kind + ':string'
        block = content[0] if isinstance(content, list) and content and isinstance(content[0], dict) else {}
        name = kind + ':' + str(block.get('type', '?'))
        if block.get('type') == 'tool_use':
            tools[block.get('id')] = block.get('name')
            name += ':' + str(block.get('name'))
        if block.get('type') == 'tool_result':
            name += ':' + str(tools.get(block.get('tool_use_id'))) + (':error' if block.get('is_error') else '')
        return name
    return kind


def file_records(path):
    """The lines of a conversation's file, parsed."""
    return [json.loads(line) for line in open(path, encoding='utf-8') if line.strip()]


def file_shapes(records):
    """The kinds of the lines a reader reads, in order, runs of the same kind folded."""
    out, tools = [], {}
    for rec in records:
        name = file_kind(rec, tools)
        if rec.get('type') not in FILE_READ or (out and out[-1] == name):
            continue
        out.append(name)
    return out


FILE_PARTS = ('message', 'message.content.0', 'attachment', 'toolUseResult', 'compactMetadata')


def file_key_lines(records):
    """KIND top=a,b PART=c,d of every line (names only), as key_line for the stream."""
    tools, out = {}, []
    for rec in records:
        if not isinstance(rec, dict):
            continue
        fields = ['top=' + ','.join(rec)]
        for path in FILE_PARTS:
            value = part(rec, path)
            if isinstance(value, dict):
                fields.append(path + '=' + ','.join(value))
        out.append(file_kind(rec, tools) + ' ' + ' '.join(fields))
    return out


def recording(path):
    """The records the CLI sent in a recording ({"dir": "in", "msg": ...} lines)."""
    records = []
    for line in open(path, encoding='utf-8'):
        item = json.loads(line)
        if item.get('dir') == 'in':
            records.append(item.get('msg', item.get('raw')))
    return records


PARTS = ('request', 'response', 'response.response', 'message', 'message.content.0', 'event', 'event.message',
         'event.delta', 'event.content_block')


def part(msg, path):
    """The object at a dotted path (a number indexes a list), or None."""
    for name in path.split('.'):
        if isinstance(msg, list) and name.isdigit() and int(name) < len(msg):
            msg = msg[int(name)]
        elif isinstance(msg, dict) and not name.isdigit():
            msg = msg.get(name)
        else:
            return None
    return msg


def key_kind(msg, tools):
    """The kind whose field order key_line records: finer than shape(), since the CLI orders the fields of
    one record type differently by case (a tool_result by tool and outcome, a result by whether a turn ran,
    a control_response by what it answers). tools maps tool_use ids to tool names (filled from assistant
    records)."""
    kind = msg.get('type', '?')
    content = part(msg, 'message.content.0')
    if kind == 'stream_event':
        return shape(msg)
    if kind == 'system':
        return 'system/' + str(msg.get('subtype')) + (':mode' if 'permissionMode' in msg and
                                                      msg.get('subtype') == 'status' else '')
    if kind == 'result':
        return 'result/' + str(msg.get('subtype')) + ('' if 'terminal_reason' in msg else ':early')
    if kind == 'assistant':
        if isinstance(content, dict) and content.get('type') == 'tool_use':
            tools[content.get('id')] = content.get('name')
        return 'assistant:' + (content.get('type', '?') if isinstance(content, dict) else '?')
    if kind == 'user':
        if not isinstance(content, dict):
            return 'user:string'
        name = 'user:' + content.get('type', '?')
        if content.get('type') == 'tool_result':
            name += ':' + str(tools.get(content.get('tool_use_id'))) + (':error' if content.get('is_error') else '')
        return name
    if kind == 'control_request':
        return shape(msg)
    if kind == 'control_response':
        answer = part(msg, 'response.response')
        return 'control_response/' + str(part(msg, 'response.subtype')) + ':' + (
            next(iter(answer), '') if isinstance(answer, dict) else '')
    return kind


def key_line(msg, tools):
    """One record's kind and the order of its fields: KIND top=a,b,c PART=d,e ... (names only, no values)."""
    fields = ['top=' + ','.join(msg)]
    for path in PARTS:
        value = part(msg, path)
        if isinstance(value, dict):
            fields.append(path + '=' + ','.join(value))
    return key_kind(msg, tools) + ' ' + ' '.join(fields)


def key_lines(records):
    """key_line of every record (objects only), in order."""
    tools = {}
    return [key_line(msg, tools) for msg in records if isinstance(msg, dict)]


def parse_key_line(line):
    """(kind, {part: [names]}) of a key_line."""
    kind, *fields = line.split(' ')
    return kind, {name: value.split(',') if value else [] for name, value in (f.split('=', 1) for f in fields)}


def subsequence(short, long):
    """short's names appear in long, in the same order."""
    names = iter(long)
    return all(name in names for name in short)


def key_order_ok(line, recorded):
    """A record of the fake (its key_line) keeps the order of a recorded record of its kind: every part it
    has is in that record, and its names are a subsequence of the recorded ones (the fake may leave fields
    out, never add or reorder them). A tool the recordings never ran is compared with every recorded
    tool_result of the same outcome (and, in the file's lines, every recorded call)."""
    kind, parts = parse_key_line(line)
    candidates = [parse_key_line(r) for r in recorded]
    same = [p for k, p in candidates if k == kind]
    if not same and kind.startswith('user:tool_result:'):
        error = kind.endswith(':error')
        same = [p for k, p in candidates if k.startswith('user:tool_result:') and k.endswith(':error') == error]
        if any('toolUseResult' in p for p in same):     # a file's line: its result's own keys are its tool's
            same = [dict(p, toolUseResult=parts.get('toolUseResult', [])) for p in same]
    if not same and kind.startswith('assistant:tool_use:'):
        same = [p for k, p in candidates if k.startswith('assistant:tool_use:')]
    return any(all(name in p and subsequence(names, p[name]) for name, names in parts.items()) for p in same)


CUT = 16


def cut(value, places):
    """value with base64 data cut to CUT characters and the places (text, name) replaced, recursively."""
    if isinstance(value, dict):
        return {k: (v[:CUT] + '…' if k == 'data' and isinstance(v, str) and len(v) > CUT else cut(v, places))
                for k, v in value.items()}
    if isinstance(value, list):
        return [cut(v, places) for v in value]
    if isinstance(value, str):
        for text, name in places:
            value = value.replace(text, name)
    return value


def detailed(direction, msg):
    """Whether a record's content goes into a phase 4 shape file: everything rhun wrote, the CLI's requests,
    withdrawals, user records (replays, tool results) and its echoes of rhun's answers to its own requests."""
    kind = msg.get('type')
    if direction == 'out':
        return True
    if kind in ('control_request', 'control_cancel_request', 'user', 'tool_progress'):
        return True
    return kind == 'control_response' and isinstance(part(msg, 'response.response'), dict) \
        and 'mcp_response' in part(msg, 'response.response')


def cut_lines(path, home):
    """The lines of a phase 4 shape file from a recording ({"dir", "msg"} lines)."""
    items = [json.loads(line) for line in open(path, encoding='utf-8')]
    cwd = next((i['msg'].get('cwd') for i in items if isinstance(i.get('msg'), dict)
                and i['msg'].get('subtype') == 'init' and i['msg'].get('cwd')), None) or next(
        (part(i['msg'], 'request.input.cwd') for i in items if isinstance(i.get('msg'), dict)
         and isinstance(part(i['msg'], 'request.input.cwd'), str)), None)
    places = []
    if cwd:
        places += [(cwd, '$CWD'), (re.sub(r'[^A-Za-z0-9]', '-', cwd), '$SLUG')]
    places.append((home, '~'))
    out = []
    for item in items:
        msg, direction = item.get('msg'), item.get('dir')
        if direction not in ('in', 'out') or not isinstance(msg, dict):
            continue
        name = shape(msg, hooks=True) or ((msg.get('type') or '?') + '/' + str(msg.get('subtype')))
        if detailed(direction, msg):
            out.append('%s %s %s' % (direction, name, json.dumps(cut(msg, places), ensure_ascii=False)))
        elif not out or out[-1] != '%s %s' % (direction, name):     # runs of one shape (deltas) folded
            out.append('%s %s' % (direction, name))
    return out


def parse_cut_line(line):
    """(dir, shape, record or None) of a phase 4 shape file's line."""
    direction, name, *rest = line.split(' ', 2)
    return direction, name, json.loads(rest[0]) if rest else None


if __name__ == '__main__':
    args = sys.argv[1:]
    fold = '--fold' in args
    hooks = '--hooks' in args
    args = [a for a in args if a not in ('--fold', '--hooks')]
    if args[0] == '--cut-data':      # the phase 4 shape files: both directions, pinned contents with data cut
        import os.path
        print('\n'.join(cut_lines(args[1], os.path.expanduser('~'))))
    elif args[0] == '--keys':          # claude-shapes.py --keys RECORDING... : the recorded field orders
        print('\n'.join(sorted({line for path in args[1:] for line in key_lines(recording(path))})))
    elif args[0] == '--file-keys':   # the field orders of the conversation files' lines
        print('\n'.join(sorted({line for path in args[1:] for line in file_key_lines(file_records(path))})))
    elif args[0] == '--file':
        names = file_shapes(file_records(args[1]))
        print('\n'.join(fold_pairs(names) if fold else names))
    else:
        names = shapes(recording(args[0]), hooks)
        print('\n'.join(fold_pairs(names) if fold else names))
