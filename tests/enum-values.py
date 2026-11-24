#!/usr/bin/env python3
# Fails when two members of one enumeration (palette modes, focus owners, prompt kinds...) share a
# value: parts written in parallel each took the next free number, and the second silently routed
# into the first one's code (PM_KEYS and PM_WSLIST were both 12).
# usage: tests/enum-values.py [--negative-control]
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# prefix -> files whose `.equ PREFIX_NAME, NUMBER` lines form that enumeration
ENUMS = {
    'PM_': ['src/app/palette.s', 'src/rhun.inc'],
    'FOCUS_': ['src/rhun.inc', 'src/app/*.s'],
    'PROMPT_': ['src/rhun.inc', 'src/app/*.s'],
    'TAB_': ['src/rhun.inc'],
    'PLACE_': ['src/rhun.inc'],
    'INV_': ['src/rhun.inc'],
    'PK_': ['src/rhun.inc'],   # query kinds: index query.s's pk_table
    'QO_': ['src/rhun.inc'],   # query askers: index qo_reply, qo_part, qo_trunc
    'ACT_': ['src/rhun.inc'],  # a command's action: index act_names (agentcfg.s); lines merged in parallel
    'OA_': ['src/app/agent_claude.s'],   # what an answer Claude's driver waits for is for
    'ALF_': ['src/rhun.inc', 'src/app/*.s'],   # a live record's flags (AL_flags), bits
    'CNF_': ['src/rhun.inc', 'src/app/*.s'],   # a connection's flags (CN_flags), bits
    'CN_E_': ['src/rhun.inc'],                  # a connection's error
    'DRVC_': ['src/rhun.inc'],                  # a driver's capabilities, bits
}
# names that share a prefix but belong to another enumeration
SEPARATE = {'PM_RECENT', 'PK_COUNT', 'ACT_COUNT'}  # app.s's project-menu row; the number of query kinds, of actions

def values(prefix, globs, extra=None):
    seen = {}
    lines = []
    for g in globs:
        for f in sorted(ROOT.glob(g)):
            for line in f.read_text(errors='replace').splitlines():
                lines.append((f.relative_to(ROOT), line))
    if extra:
        lines.append(extra)
    out = []
    pat = re.compile(r'^\s*\.equ\s+(' + prefix + r'[A-Z0-9_]+)\s*,\s*(0x[0-9a-fA-F]+|\d+)\b')
    for f, line in lines:
        m = pat.match(line)
        if not m or m.group(1) in SEPARATE:
            continue
        name, val = m.group(1), int(m.group(2), 0)
        if name in seen:
            continue  # the same name twice is inc-names.py's business
        seen[name] = val
        out.append((val, name, f))
    return out

def check(extra_for=None):
    bad = []
    for prefix, globs in ENUMS.items():
        extra = extra_for if extra_for and extra_for[1].lstrip().startswith('.equ ' + prefix) else None
        by_val = {}
        for val, name, f in values(prefix, globs, extra):
            by_val.setdefault(val, []).append(f'{name} ({f})')
        for val, names in sorted(by_val.items()):
            if len(names) > 1:
                bad.append(f'{prefix}* value {val} shared by ' + ', '.join(names))
    return bad

def act_names():
    """ACT_* is 0..ACT_COUNT-1 without a gap, and agentcfg.s's act_names has one name per value."""
    vals = sorted(v for v, _, _ in values('ACT_', ['src/rhun.inc']))
    count = None
    for line in (ROOT / 'src/rhun.inc').read_text().splitlines():
        m = re.match(r'^\s*\.equ\s+ACT_COUNT\s*,\s*(\d+)', line)
        if m:
            count = int(m.group(1))
    bad = []
    if vals != list(range(count)):
        bad.append(f'ACT_* values {vals} are not 0 to ACT_COUNT - 1 ({count - 1})')
    text = (ROOT / 'src/app/agentcfg.s').read_text()
    block = text[text.index('act_names:'):]
    block = block[:block.index('fast_names:')]
    names = sum(len([w for w in line.split('#')[0].replace('.quad', '').split(',') if w.strip()])
                for line in block.splitlines()[1:] if '.quad' in line)
    if names != count:
        bad.append(f'act_names (agentcfg.s) has {names} names for ACT_COUNT {count}')
    return bad

if __name__ == '__main__':
    if '--negative-control' in sys.argv:
        bad = check(('negative-control', '.equ PM_TEST_COLLIDES, 12'))
        if not bad:
            print('FAIL negative control: a planted PM_ collision went unnoticed')
            sys.exit(1)
    bad = check() + act_names()
    for b in bad:
        print('FAIL ' + b)
    if bad:
        sys.exit(1)
    print('ok   no shared values in ' + ' '.join(p + '*' for p in ENUMS))
