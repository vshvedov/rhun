#!/usr/bin/env python3
"""Every headless control command name is unique: control.s's ctl_table and the other parts'
tables it lists in ctl_tables are (name, handler) pairs, searched in that order, so a name used
twice leaves the later command unreachable. Reads the sources; prints each duplicate and fails."""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = {p: p.read_text(encoding='utf-8', errors='replace') for p in (ROOT / 'src').rglob('*.s')}


def table(path, label):
    """The command names of the (name, handler) table at label in path."""
    text = SOURCES[path]
    m = re.search(r'^' + re.escape(label) + r':[^\n]*\n', text, re.M)
    if not m:
        sys.exit(f'{path.relative_to(ROOT)}: no table {label}')
    words = []
    for line in text[m.end():].splitlines():
        line = line.split('#', 1)[0].strip()
        if not line:
            continue
        if not line.startswith('.quad'):
            break
        words += [w.strip() for w in line[len('.quad'):].split(',') if w.strip()]
        if words[-2:] == ['0', '0']:
            break
    strings = dict(re.findall(r'^(\.?\w+):\s*\.asciz\s+"([^"]*)"', text, re.M))
    names = []
    for name_label in words[0:-2:2]:
        if name_label not in strings and not name_label.startswith('.'):
            # a global name of another file's (the session list's and the dialogs' own tables' words)
            found = [s for p, t in SOURCES.items()
                     for s in re.findall(r'^' + re.escape(name_label) + r':\s*\.asciz\s+"([^"]*)"', t, re.M)]
            if len(found) == 1:
                strings[name_label] = found[0]
        if name_label not in strings:
            sys.exit(f'{path.relative_to(ROOT)}: {label}: {name_label} is not a string here')
        names.append(strings[name_label])
    return names


control = ROOT / 'src/app/control.s'
seen = {}
order = [(control, 'ctl_table')]
m = re.search(r'^ctl_tables:\n((?:\s*\.quad\s+\w+[^\n]*\n)+)', SOURCES[control], re.M)
if not m:
    sys.exit('control.s: no ctl_tables list')
for label in re.findall(r'\.quad\s+(\w+)', m.group(1)):
    if label == '0':
        continue
    defs = [p for p, t in SOURCES.items() if re.search(r'^' + re.escape(label) + r':', t, re.M)]
    if len(defs) != 1:
        sys.exit(f'ctl_tables: {label} is defined in {len(defs)} files')
    order.append((defs[0], label))
bad = 0
for path, label in order:
    for name in table(path, label):
        where = f'{path.relative_to(ROOT)} {label}'
        if name in seen:
            print(f'duplicate control command {name!r}: {seen[name]} and {where} (the second is unreachable)')
            bad = 1
        else:
            seen[name] = where
if bad:
    sys.exit(1)
print(f'ok   {len(seen)} control commands in {len(order)} tables')
