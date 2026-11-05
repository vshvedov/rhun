#!/usr/bin/env python3
"""Windows download and install steps agree everywhere; windows-install.py runs the README's."""
import html
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent
DOWNLOAD = r'\$rhunInstaller = [^\n]+\n\[Net\.ServicePointManager\]::SecurityProtocol = [^\n]+\nInvoke-WebRequest [^\n]+ -OutFile \$rhunInstaller -ErrorAction Stop'
RUN = r'powershell -NoProfile -ExecutionPolicy RemoteSigned -File \$rhunInstaller'
EXPECTED = {'README.md': 1, 'docs/guide.md': 1, 'site/index.html': 2, 'site/docs/getting-started.html': 1}

for step, pattern in [('download', DOWNLOAD), ('run', RUN)]:
    shown = {}
    for name, count in EXPECTED.items():
        text = (ROOT / name).read_text(encoding='utf-8')
        if name.endswith('.html'):
            text = html.unescape(text)
        found = re.findall(pattern, text)
        assert len(found) == count, f'{name}: {len(found)} Windows {step} steps, expected {count}'
        shown.update((command, name) for command in found)
    assert len(shown) == 1, f'the Windows {step} steps differ:\n' + '\n'.join(f'{n}: {c}' for c, n in shown.items())
    print(f'ok   install-command/{step}-same-everywhere', flush=True)
# Windows PowerShell reads a script without a BOM in the ANSI code page, whether pasted or run with -File.
assert (ROOT / 'install.ps1').read_bytes().isascii(), 'install.ps1 is not ASCII'
print('ok   install-command/ascii-installer', flush=True)
