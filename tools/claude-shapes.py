#!/usr/bin/env python3
"""Shapes of Claude Code stream-json records: one short line per record the CLI sent, so a recording
and the fake's output can be compared without their text. Usage: claude-shapes.py RECORDING.jsonl

`claude-shapes.py --keys RECORDING.jsonl...` prints the field order of every kind of record instead (field
names only, no values): tests/data/claude-shapes/keys.txt, which tests/fake-claude.py holds every record
of the fake to (key_order_ok)."""
import json
import sys

# records whose place depends on timing, not on the protocol (commands_changed comes about 300 ms after
# the initialize answer: before system/init or after it, depending on when the first prompt went out)
SKIP = {'system/hook_started', 'system/hook_response', 'system/status', 'rate_limit_event',
        'system/commands_changed'}


def shape(msg):
    """The shape of one record from the CLI, or None for records the comparison ignores."""
    if not isinstance(msg, dict):
        return 'raw'
    kind = msg.get('type', '?')
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


def shapes(records):
    """Shapes of the records rhun reads, in order, runs of the same shape (deltas) folded into one."""
    out = []
    for msg in records:
        name = shape(msg)
        if name is None or (out and out[-1] == name):
            continue
        out.append(name)
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
    tool_result of the same outcome."""
    kind, parts = parse_key_line(line)
    candidates = [parse_key_line(r) for r in recorded]
    same = [p for k, p in candidates if k == kind]
    if not same and kind.startswith('user:tool_result:'):
        error = kind.endswith(':error')
        same = [p for k, p in candidates if k.startswith('user:tool_result:') and k.endswith(':error') == error]
    return any(all(name in p and subsequence(names, p[name]) for name, names in parts.items()) for p in same)


if __name__ == '__main__':
    if sys.argv[1] == '--keys':          # claude-shapes.py --keys RECORDING... : the recorded field orders
        print('\n'.join(sorted({line for path in sys.argv[2:] for line in key_lines(recording(path))})))
    else:
        print('\n'.join(shapes(recording(sys.argv[1]))))
