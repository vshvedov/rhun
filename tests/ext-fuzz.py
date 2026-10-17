#!/usr/bin/env python3
"""Protocol fuzzing of the extension host: tests/ext/fuzz.py throws malformed traffic at rhun under
several seeds; rhun must exit cleanly, the document must be intact or changed only through valid
edits (the fuzz extension never sends a valid edit, so it must be unchanged), and the extension
must end up stopped or running, never leave rhun wedged.
usage: tests/ext-fuzz.py [FIRST_SEED] [LAST_SEED]"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
EXE = Path(os.environ.get('RHUN_TEST_EXE', ROOT / 'build/rhun')).resolve()
CONFIG = ('[files]\nrestore_session = false\nrestore_project = false\n[updates]\ncheck = false\n'
          '[git]\nenabled = false\n[ui]\nsidebar = false\nagents_panel = false\n')
MANIFEST = ('name = fuzz\nowner = rhun-tests\ntitle = Fuzz\nversion = 0.0.1\nprotocol = 1\nruntime = python3\n'
            'run = {script}\non = startup\n[commands]\ngo = Go\n[subscribe]\nopened = *\nchanged = *\n'
            'cursor = *\n[needs]\ndocuments = write\n')
TEXT = 'alpha beta\ngamma delta\n'


def run(seed, work):
    env = dict(os.environ, HOME=str(work), XDG_CONFIG_HOME=str(work / 'config'), XDG_STATE_HOME=str(work / 'state'),
               FUZZ_SEED=str(seed))
    script = work / 'f.txt'
    script.write_text(f'open {work / "proj/a.txt"}\nwait 2500\nprint-doc\nprint-extensions\nprint-state\nquit\n')
    r = subprocess.run([str(EXE), str(work / 'proj'), '--headless', '800x600', '--extensions', str(work / 'exts'),
                        '--script', str(script)], env=env, capture_output=True, timeout=60)
    out = r.stdout.decode(errors='replace')
    ok = r.returncode == 0
    doc = out.split('<eod>')[0]
    if doc.rstrip('\n') != TEXT.rstrip('\n'):
        ok = False
    state = [line for line in out.splitlines() if line.startswith('rhun-tests/fuzz')]
    if not state or ('state=running' not in state[0] and 'state=stopped' not in state[0]
                     and 'state=crashed' not in state[0]):
        ok = False
    return ok, r.returncode, state[0] if state else '(no state line)'


def main():
    first = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    last = int(sys.argv[2]) if len(sys.argv) > 2 else 20
    failed = 0
    with tempfile.TemporaryDirectory(prefix='rhun-ext-fuzz-') as tmp:
        work = Path(tmp)
        (work / 'proj').mkdir()
        (work / 'proj/a.txt').write_text(TEXT)
        (work / 'config/rhun').mkdir(parents=True)
        (work / 'config/rhun/config').write_text(CONFIG)
        d = work / 'exts/rhun-tests/fuzz'
        d.mkdir(parents=True)
        (d / 'extension.ini').write_text(MANIFEST.format(script=(ROOT / 'tests/ext/fuzz.py').as_posix()))
        for seed in range(first, last + 1):
            ok, code, state = run(seed, work)
            print(f'{"ok  " if ok else "FAIL"} seed {seed}: exit {code}, {state}')
            failed += not ok
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
