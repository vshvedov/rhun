#!/usr/bin/env python3
"""Read-only project-history audit and isolated pagination/resume integration test.

Example: python3 tests/agents-real.py --project /path/to/project --output /tmp/agents-audit
Real session contents stay out of the report. Config, state, and mutations use temporary paths.
"""
import argparse
from collections import Counter
import ctypes
import json
import os
from pathlib import Path
import re
import shutil
import statistics
import struct
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / 'build/rhun'


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def slug(path):
    units = str(path).encode('utf-16-le')
    return ''.join(chr(unit) if chr(unit).isascii() and chr(unit).isalnum() else '-'
                   for unit in (int.from_bytes(units[i:i + 2], 'little')
                                for i in range(0, len(units), 2)))


def git(project, *args):
    return subprocess.check_output(['git', '-C', str(project), *args],
                                   env=dict(os.environ, GIT_OPTIONAL_LOCKS='0'))


def fingerprint(paths):
    return {str(p): (p.stat().st_size, p.stat().st_mtime_ns) for p in paths}


def inventory(home, roots):
    """Independent reference: Git CLI roots and streamed JSON metadata, not Rhun's cache."""
    rows = {}
    unrelated = 0
    verified = set(roots)
    directories = {}
    for root in roots:
        directories.setdefault(home / '.claude/projects' / slug(root), []).append(root)
        for directory in (home / '.claude/projects').glob(slug(root) + '--claude-worktrees-*'):
            directories.setdefault(directory, [])
    for directory, candidates in directories.items():
        for path in directory.glob('*.jsonl'):
            cwd = None
            with path.open('rb') as stream:
                for line in stream:
                    try:
                        record = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(record, dict) and isinstance(record.get('cwd'), str):
                        candidate = record['cwd']
                        nested = any(candidate.startswith(root + '/.claude/worktrees/') and
                                     '/' not in candidate[len(root + '/.claude/worktrees/'):] and
                                     Path(candidate).name not in ('.', '..') for root in roots)
                        if slug(candidate) == directory.name and (candidate in verified or nested):
                            cwd = candidate
                            verified.add(cwd)
                            break
            if cwd is None and len(candidates) == 1:
                cwd = candidates[0]
            if cwd in verified:
                rows[str(path)] = dict(kind=1, cwd=cwd, mtime=path.stat().st_mtime_ns)
            else:
                unrelated += 1
    for path in (home / '.codex/sessions').rglob('*.jsonl'):
        try:
            with path.open('rb') as stream:
                record = json.loads(stream.readline())
            cwd = record.get('payload', {}).get('cwd')
        except (OSError, ValueError, AttributeError):
            continue
        nested = isinstance(cwd, str) and any(
            cwd.startswith(root + '/.claude/worktrees/') and
            '/' not in cwd[len(root + '/.claude/worktrees/'):] and
            Path(cwd).name not in ('.', '..') for root in roots)
        if cwd in verified or nested:
            rows[str(path)] = dict(kind=2, cwd=cwd, mtime=path.stat().st_mtime_ns)
        else:
            unrelated += 1
    return rows, unrelated


def context(base, name, home):
    folder = base / name
    config = folder / 'config/rhun/config'
    config.parent.mkdir(parents=True, exist_ok=True)
    config.write_text('[updates]\ncheck = false\n[git]\nenabled = false\n'
                      '[editor]\ncursor_blink = false\n[files]\nrestore_session = false\n'
                      'restore_project = false\n')
    env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(folder / 'config'),
               XDG_STATE_HOME=str(folder / 'state'), SHELL='/nonexistent')
    env.pop('GROK_HOME', None)
    return folder, env


def decode(packet):
    count, = struct.unpack_from('<Q', packet, 8)
    offset, rows = 32, []
    for _ in range(count):
        kind, flags, mtime, stamp, *lengths = struct.unpack_from('<9Q', packet, offset)
        offset += 96
        strings = []
        for length in lengths:
            strings.append(packet[offset:offset + length].decode())
            offset += length
        rows.append(dict(kind=kind, flags=flags, mtime=mtime, path=strings[0],
                         cwd=strings[1], title=strings[2], badge=strings[3], model=strings[4]))
    require(offset == len(packet), 'Worker packet has trailing or missing bytes')
    return rows


def worker(project, limit, env):
    started = time.perf_counter()
    process = subprocess.Popen([str(EXE), '--agent-index', str(project), str(limit),
                                'claude,codex'], env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE)
    packets = []
    try:
        while True:
            header = process.stdout.read(32)
            if not header:
                break
            require(len(header) == 32, 'Worker packet has a partial header')
            magic, count, total, size = struct.unpack('<8sQQQ', header)
            require(size <= 2**26, 'Worker packet exceeds its bound')
            payload = process.stdout.read(size)
            require(len(payload) == size, 'Worker packet has a partial payload')
            packets.append(dict(magic=magic, total=total, rows=decode(header + payload),
                                elapsed_ms=(time.perf_counter() - started) * 1000))
        require(process.wait(timeout=30) == 0, 'Worker exited unsuccessfully')
        require(len(packets) == 2 and packets[-1]['magic'] == b'RAHPAGE3',
                'Worker did not publish provisional and final pages')
        return packets, (time.perf_counter() - started) * 1000
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        process.stdout.close()
        process.stderr.close()


def badge(cwd, main):
    if cwd == main:
        return ''
    match = re.search(r'/\.codex/worktrees/([^/]+)/', cwd)
    return match[1] if match else Path(cwd).name


def check_rows(packet, reference, main, limit):
    expected = sorted(reference, key=lambda path: (-reference[path]['mtime'], path))[:limit]
    require(packet['total'] == len(reference), 'Total differs from independent inventory')
    require([row['path'] for row in packet['rows']] == expected,
            'Page membership/order differs from independent inventory')
    for row in packet['rows']:
        source = reference[row['path']]
        require((row['kind'], row['cwd'], row['badge']) ==
                (source['kind'], source['cwd'], badge(source['cwd'], main)),
                'Provider, exact checkout, or worktree badge differs from inventory')


def labels(rows):
    return [{1: 'Claude', 2: 'Codex', 3: 'Grok', 4: 'OpenCode'}[row['kind']] +
            (' [worktree: ' + row['badge'] + ']' if row['badge'] else '') +
            (' [model: ' + row['model'] + ']' if row.get('model') else '') +
            ': ' + (row['title'] or 'Untitled session') for row in rows]


def ui(project, folder, env, actions, size='1280x800'):
    script = folder / 'commands.rsc'
    script.write_text('\n'.join([*actions, 'quit']) + '\n')
    started = time.perf_counter()
    result = subprocess.run([str(EXE), str(project), '--headless', size, '--scale', '1',
                             '--script', str(script)], env=env, capture_output=True, timeout=60)
    require(result.returncode == 0, 'Headless UI exited unsuccessfully')
    return result.stdout.decode().splitlines(), (time.perf_counter() - started) * 1000


def page(shown, total):
    return f'shown={shown} total={total} loading=0 error=0'


def clone(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if sys.platform == 'darwin':
        library = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
        library.clonefile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
        library.clonefile.restype = ctypes.c_int
        if library.clonefile(os.fsencode(source), os.fsencode(destination), 0) == 0:
            return
    shutil.copy2(source, destination)


def thread_header(path):
    magic, dimensions, depth, pixels = path.read_bytes().split(b'\n', 3)
    require((magic, dimensions, depth) == (b'P6', b'1280 800', b'255'), 'Invalid UI screenshot')
    return b''.join(pixels[(y * 1280 + 940) * 3:(y * 1280 + 1190) * 3]
                    for y in range(40, 80))


def resume(project, folder, env, reference):
    target = Path(min(reference, key=lambda path: reference[path]['mtime']))
    listing = folder / 'list-before.ppm'
    before, after = folder / 'thread-before.ppm', folder / 'thread-after.ppm'
    script = folder / 'commands.rsc'
    script.write_text('cmd focus_agents\nwait-agents\n' + f'shot {listing}\n' +
                      'click 1000 130\n' +
                      f'shot {before}\nprint-project\n' +
                      'wait 11000\nwait-agents\n' + f'shot {after}\nclick 922 60\n' +
                      'print-agents-page\nprint-agents\nquit\n')
    process = subprocess.Popen([str(EXE), str(project), '--headless', '1280x800', '--scale',
                                '1', '--script', str(script)], env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE)
    try:
        require(process.stdout.readline().startswith(b'project='), 'UI did not open a thread')
        row = reference[str(target)]
        if row['kind'] == 1:
            record = dict(type='custom-title', customTitle='Isolated resumed session')
        else:
            record = dict(type='response_item', payload=dict(type='message', role='user',
                          content=[dict(type='input_text', text='Isolated resumed session')]))
        with target.open('ab') as stream:
            stream.write(b'\n' + json.dumps(record).encode() + b'\n')
        newest = max(row['mtime'] for row in reference.values()) + 1_000_000_000
        os.utime(target, ns=(newest, newest))
        output, _ = process.communicate(timeout=30)
        require(process.returncode == 0, 'Resume UI exited unsuccessfully')
        require(thread_header(before) != thread_header(listing), 'UI did not open a conversation')
        require(thread_header(before) == thread_header(after), 'Refresh changed the open thread')
        lines = output.decode().splitlines()
        require(lines[0] == page(50, len(reference)), 'Resume changed page size or total')
        refreshed, _ = worker(project, 50, env)
        require(refreshed[-1]['rows'][0]['path'] == str(target), 'Older session did not rise to top')
        require(lines[1] == labels(refreshed[-1]['rows'][:1])[0],
                'UI did not show the resumed session at the top')
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate()
        process.stdout.close()
        process.stderr.close()


def benchmark(base, project, home):
    if sys.platform != 'darwin':
        return {}
    source = ROOT / 'tests/agents-bench.s'
    translated, obj, executable = base / 'bench-a64.s', base / 'bench.o', base / 'bench'
    subprocess.run([sys.executable, str(ROOT / 'tools/arm64.py'), '-I', str(ROOT / 'src'),
                    '-D', 'MACOS', str(source), str(translated)], check=True)
    subprocess.run(['as', '-arch', 'arm64', '-mmacosx-version-min=12.0', '-o', str(obj),
                    str(translated)], check=True)
    objects = [str(p) for p in (ROOT / 'build/obj').glob('*.o')
               if not p.name.startswith(('tests_', 'test_')) and p.name != 'src_main.o']
    subprocess.run(['clang', '-arch', 'arm64', '-mmacosx-version-min=12.0', '-o', str(executable),
                    str(obj), *objects, '-framework', 'AppKit', '-framework', 'QuartzCore',
                    '-framework', 'IOSurface', '-framework', 'CoreServices', '-framework',
                    'Carbon', '-framework', 'Security'], check=True)
    _, env = context(base, 'benchmark', home)
    runs = []
    for _ in range(3):
        result = subprocess.run([str(executable), str(project)], env=env, capture_output=True,
                                timeout=60)
        require(result.returncode == 0, 'Native performance probe failed')
        runs.append({k: int(v) for k, v in (line.split('=')
                     for line in result.stderr.decode().splitlines())})
    return {name: round(statistics.median(run[key] for run in runs) / divisor, 4)
            for name, key, divisor in (('set_project', 'queue_ns', 1e6),
                ('first_page_ready', 'ready_ns', 1e6), ('poll', 'polls100_ns', 1e8),
                ('scan_request', 'requests10_ns', 1e7), ('render', 'frames100_ns', 1e8))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', type=Path, required=True)
    parser.add_argument('--home', type=Path, default=Path.home())
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--copies', type=int, default=8)
    args = parser.parse_args()
    project, home, output = args.project.resolve(), args.home.resolve(), args.output.resolve()
    require(args.copies >= 1, 'Copies must be positive')
    require(not output.exists(), 'Output directory must be new')
    output.mkdir(parents=True)
    status = git(project, 'status', '--porcelain')
    listing = git(project, 'worktree', 'list', '--porcelain').decode()
    roots = [line[9:] for line in listing.splitlines() if line.startswith('worktree ')
             and Path(line[9:]).is_dir()]
    main_root = roots[0]
    reference, unrelated = inventory(home, roots)
    require(reference, 'Project has no matching local session files')
    original = fingerprint(map(Path, reference))
    report = dict(project=str(project), scope='registered and metadata-verified historical worktrees',
                  checkouts=len(roots), sessions=len(reference),
                  providers=dict(Counter('claude' if row['kind'] == 1 else 'codex'
                                         for row in reference.values())),
                  worktree_sessions=sum(row['cwd'] != main_root for row in reference.values()),
                  historical_worktree_sessions=sum(row['cwd'] not in roots for row in reference.values()),
                  transcript_mib=round(sum(size for size, _ in original.values()) / 2**20, 2),
                  unrelated_metadata_excluded=unrelated, checks=[], timings={})
    with tempfile.TemporaryDirectory(prefix='rhun-real-history-') as temporary:
        base = Path(temporary).resolve()
        _, env = context(base, 'worker', home)
        cold, cold_ms = worker(project, 50, env)
        check_rows(cold[-1], reference, main_root, 50)
        warm, warm_ms = worker(project, 50, env)
        check_rows(warm[-1], reference, main_root, 50)
        require(len(warm[0]['rows']) == min(50, len(reference)), 'Warm cache omitted its page')
        complete, _ = worker(project, max(50, len(reference)), env)
        check_rows(complete[-1], reference, main_root, len(reference))
        for root in roots[1:]:
            result, _ = worker(root, 50, env)
            check_rows(result[-1], reference, main_root, 50)
        report['checks'].extend(['independent inventory', 'recency order', 'provider and badges',
                                 'cold and cached discovery', 'main and every linked checkout'])
        report['timings'].update(cold_index_ms=round(cold_ms, 2), warm_index_ms=round(warm_ms, 2),
                                 cached_page_ms=round(warm[0]['elapsed_ms'], 2))
        report['native_real_median_ms'] = benchmark(base, project, home)
        (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        folder, env = context(base, 'ui-real', home)
        lines, elapsed = ui(project, folder, env, ['wait-agents', 'print-agents-page',
            'print-agents', f'shot {output / "real.ppm"}', 'click 1215 752',
            'wait-agents', 'print-agents-page'])
        count = min(50, len(reference))
        require(lines == [page(count, len(reference)), *labels(cold[-1]['rows']),
                           page(min(100, len(reference)), len(reference))],
                'Real UI rows or load-more state differ from worker results')
        worktree_row = next((i for i, row in enumerate(cold[-1]['rows']) if row['badge']), None)
        if worktree_row is not None:
            ui(project, folder, env, ['cmd focus_agents', 'wait-agents', 'move 1100 300',
                f'scroll {max(0, worktree_row - 2) * 56}', f'shot {output / "worktree.ppm"}'])
        historical_row = next((i for i, row in enumerate(cold[-1]['rows'])
                               if row['badge'] and row['cwd'] not in roots), None)
        if historical_row is not None:
            ui(project, folder, env, ['cmd focus_agents', 'wait-agents', 'move 1100 300',
                f'scroll {max(0, historical_row - 2) * 56}', f'shot {output / "historical.ppm"}'])
            report['checks'].append('historical worktree badge in native UI')
        report['timings']['real_ui_launch_and_checks_ms'] = round(elapsed, 2)
        report['checks'].append('real native UI')
        clone_home = base / 'history-copy'
        copied = {}
        for path, row in reference.items():
            for index in range(args.copies):
                source = Path(path)
                relative = source.relative_to(home)
                destination = clone_home / relative.with_name(source.stem + f'-copy-{index}.jsonl')
                clone(source, destination)
                require(not os.path.samefile(source, destination), 'Copy aliases a real session')
                os.utime(destination, ns=(row['mtime'] + index, row['mtime'] + index))
                copied[str(destination)] = dict(row, mtime=row['mtime'] + index)
        require(len(copied) > 100, 'Increase --copies to exercise at least three pages')
        folder, env = context(base, 'ui-copy', clone_home)
        expected, _ = worker(project, max(50, len(copied)), env)
        check_rows(expected[-1], copied, main_root, len(copied))
        actions, wanted = ['wait-agents', 'print-agents-page', 'print-agents',
                            f'shot {output / "first-page.ppm"}'], [page(50, len(copied)),
                            *labels(expected[-1]['rows'][:50])]
        for limit in range(100, len(copied) + 50, 50):
            actions += ['click 1215 752', 'wait-agents', 'print-agents-page', 'print-agents']
            wanted += [page(min(limit, len(copied)), len(copied)),
                       *labels(expected[-1]['rows'][:limit])]
        actions += ['agents-more', 'wait-agents', 'print-agents-page', 'move 600 300',
                    'wait 1000', 'print-frames',
                    'wait 2500', 'print-frames', f'shot {output / "paged.ppm"}']
        wanted += [page(len(copied), len(copied))]
        lines, elapsed = ui(project, folder, env, actions)
        require(lines[:-2] == wanted, 'Copied real-history UI paging has omissions or duplicates')
        require(lines[-2].startswith('frames=') and lines[-1].startswith('frames='),
                'UI did not report idle frames')
        visible_frames = int(lines[-1].removeprefix('frames='))
        require(visible_frames <= 4, 'Visible panel redraws faster than its age-label timer')
        report['visible_idle_frames_in_2_5s'] = visible_frames
        hidden, _ = ui(project, folder, env, ['wait-agents', 'cmd toggle_agents',
            'move 600 300', 'wait 200', 'print-frames', 'wait 2500', 'print-frames'])
        require(hidden[-1] == 'frames=0', 'Hidden panel caused idle redraws')
        report['hidden_idle_frames_in_2_5s'] = 0
        report['timings']['all_pages_and_idle_ui_ms'] = round(elapsed, 2)
        report['copied_sessions'] = len(copied)
        report['native_copied_median_ms'] = benchmark(base, project, clone_home)
        (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        resume(project, folder, env, copied)
        report['checks'].extend(['every load-more page', 'exhausted load-more', 'idle redraws',
                                 'older session resume', 'open thread preserved during refresh'])
    require(fingerprint(map(Path, reference)) == original, 'Real session files changed during audit')
    require(git(project, 'status', '--porcelain') == status, 'Project Git status changed during audit')
    report['checks'].append('original files and Git status unchanged')
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
