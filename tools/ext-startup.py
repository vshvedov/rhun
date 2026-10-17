#!/usr/bin/env python3
"""Startup cost of extension discovery: a headless run that quits at once, with no extensions
folder, with an empty one, and with N manifests (none on = startup), repeated and compared.
Usage: python3 tools/ext-startup.py [--runs 30] [--manifests 20] [--binary PATH]"""
import argparse
import os
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ('[files]\nrestore_session = false\nrestore_project = false\n[updates]\ncheck = false\n'
          '[git]\nenabled = false\n[ui]\nsidebar = false\nagents_panel = false\n')
MANIFEST = ('name = x{i}\nowner = o\ntitle = X {i}\nversion = 0.1.0\nprotocol = 1\nruntime = python3\n'
            'run = main.py\non = command\n[commands]\nrun_a = Run A | ctrl+alt+shift+F{k}\nrun_b = Run B\n'
            '[subscribe]\nopened = *.go\n[needs]\ndocuments = read\n')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--runs', type=int, default=30)
    ap.add_argument('--manifests', type=int, default=20)
    ap.add_argument('--binary', default=os.environ.get('RHUN_TEST_EXE', ROOT / 'build/rhun'))
    args = ap.parse_args()
    with tempfile.TemporaryDirectory(prefix='rhun-ext-startup-') as tmp:
        work = Path(tmp)
        (work / 'proj').mkdir()
        (work / 'config/rhun').mkdir(parents=True)
        (work / 'config/rhun/config').write_text(CONFIG)
        (work / 'empty').mkdir()
        many = work / 'many'
        for i in range(args.manifests):
            d = many / 'o' / f'x{i}'
            d.mkdir(parents=True)
            (d / 'extension.ini').write_text(MANIFEST.format(i=i, k=1 + i % 12))
            (d / 'main.py').write_text('')
        script = work / 'q.txt'
        script.write_text('quit\n')
        env = dict(os.environ, HOME=str(work), XDG_CONFIG_HOME=str(work / 'config'),
                   XDG_STATE_HOME=str(work / 'state'))
        cases = [('no extensions folder', None), ('empty folder', work / 'empty'),
                 (f'{args.manifests} manifests', many)]
        results = {}
        for _ in range(3):   # warm up
            subprocess.run([str(args.binary), str(work / 'proj'), '--headless', '800x600', '--script', str(script)],
                           env=env, capture_output=True)
        for name, folder in cases:
            samples = []
            for _ in range(args.runs):
                cmd = [str(args.binary), str(work / 'proj'), '--headless', '800x600', '--script', str(script)]
                if folder:
                    cmd += ['--extensions', str(folder)]
                t0 = time.perf_counter()
                r = subprocess.run(cmd, env=env, capture_output=True)
                samples.append((time.perf_counter() - t0) * 1000)
                if r.returncode != 0:
                    sys.exit(f'{name}: exit {r.returncode}: {r.stderr.decode()}')
            results[name] = samples
        for name, samples in results.items():
            print(f'{name:24s} median {statistics.median(samples):6.2f} ms  min {min(samples):6.2f} ms  '
                  f'p90 {sorted(samples)[int(len(samples) * 0.9)]:6.2f} ms')


if __name__ == '__main__':
    main()
