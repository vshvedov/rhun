#!/usr/bin/env python3
"""A fake test controller (feature "tests", docs/extensions/v1.1.md) for tests/testing.py.

It publishes a fixed tree: two lazy packages under the roots; resolving go:example/pkg gives a file
whose three tests have ranges in PROJECT/a_test.go. Runs report scripted results. TESTS_MODE picks
the behaviour (comma separated words, see run()); TESTS_LOG names the log (in its state folder,
where a confined program may write): every line rhun sends, and the replies to its requests."""
import os
import queue
import subprocess
import sys
import threading
import time

MODE = set(filter(None, os.environ.get('TESTS_MODE', '').split(',')))
LOG = os.environ.get('TESTS_LOG')
out_lock = threading.Lock()
id_lock = threading.Lock()
inbox = queue.Queue()
replies = {}            # request id -> its reply line (and body)
reply_cv = threading.Condition()
next_id = [0]
project = ['']
execs = {}              # EXEC -> {'out': bytes, 'err': bytes, 'exit': str or None}
exec_cv = threading.Condition()
cancelled = set()


def log(text):
    if LOG:
        with open(LOG, 'a', encoding='utf-8', errors='replace') as f:
            f.write(text + '\n')


def send(data):
    if isinstance(data, str):
        data = data.encode()
    with out_lock:
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()


def request(verb, args, body=b'', wait=True):
    """ID verb args LEN + body; the reply line."""
    with id_lock:
        next_id[0] += 1
        rid = next_id[0]
        line = f'{rid} {verb}' + (f' {args}' if args else '')
        if body is not None:
            line += f' {len(body)}'
        send(line.encode() + b'\n' + (body or b''))
    if not wait:
        return rid
    with reply_cv:
        while rid not in replies:
            if not reply_cv.wait(30):
                return 'timeout'
        r = replies.pop(rid)
    log(f'reply {verb}: {r}')
    return r


def item(kind, iid, label, path='', rng=(0, 0, 0, 0), flags='-', desc=None, error=None):
    extra = b''
    if desc is not None:
        extra += f'desc {len(desc.encode())}\n'.encode() + desc.encode()
    if error is not None:
        extra += f'error {len(error.encode())}\n'.encode() + error.encode()
    i, l, p = iid.encode(), label.encode(), path.encode()
    head = f'{kind} {rng[0]} {rng[1]} {rng[2]} {rng[3]} {flags} {len(i)} {len(l)} {len(p)} {len(extra)}\n'
    return head.encode() + i + l + p + extra


def items_body(parent, items):
    p = parent.encode()
    return f'{len(p)} {len(items)}\n'.encode() + p + b''.join(items)


def move_cap():
    # outer > inner > 40,001 tests; a replace of the roots that moves inner up keeps its 40,001
    request('test-items', 'add', items_body('', [item('group', 'outer', 'outer')]))
    request('test-items', 'add', items_body('outer', [item('group', 'inner', 'inner')]))
    for start in range(0, 40001, 10000):
        n = min(10000, 40001 - start)
        request('test-items', 'add', items_body('inner', [item('test', f't{start + i}', 't') for i in range(n)]))
    def roots(extra):
        return items_body('', [item('group', 'inner', 'inner')] + [item('test', f'n{i}', 'n') for i in range(extra)])
    log('movecap-over ' + request('test-items', 'replace', roots(9999)))
    log('movecap-ok ' + request('test-items', 'replace', roots(9998)))


def tests_file():
    return os.path.join(project[0], 'a_test.go')


def pkg_children():
    return [item('file', 'go:example/pkg#a_test.go', 'a_test.go', tests_file())]


def file_children():
    f = tests_file()
    return [item('test', 'go:example/pkg.TestA', 'TestA', f, (3, 1, 5, 2), desc='fast'),
            item('test', 'go:example/pkg.TestB', 'TestB', f, (7, 1, 9, 2)),
            item('test', 'go:example/pkg.TestC', 'TestC', f, (11, 1, 13, 2), 'nodebug')]


def record(state, ms, iid, *extras):
    ex = b''.join(extras)
    i = iid.encode()
    return f'{state} {ms} {len(i)} {len(ex)}\n'.encode() + i + ex


def x(name, data, args=''):
    if isinstance(data, str):
        data = data.encode()
    return f'{name}{" " + args if args else ""} {len(data)}\n'.encode() + data


def update(run, *records):
    body = f'{len(records)}\n'.encode() + b''.join(records)
    return request('test-update', str(run), body)


def exec_cmd(run, program, args, cwd=None, env=()):
    cwd = project[0] if cwd is None else cwd
    p, c = program.encode(), cwd.encode()
    body = f'{len(p)} {len(c)} {len(args)} {len(env)}\n'.encode() + p + c
    for a in args:
        a = a.encode()
        body += f'{len(a)}\n'.encode() + a
    for e in env:
        e = e.encode()
        body += f'{len(e)}\n'.encode() + e
    return request('test-exec', str(run), body)


def wait_exit(ex, timeout=30):
    with exec_cv:
        end = time.time() + timeout
        while execs.get(ex, {}).get('exit') is None:
            left = end - time.time()
            if left <= 0:
                return None
            exec_cv.wait(left)
        return execs[ex]


def run(run_no, profile, ids):
    """One test-run, in its own thread."""
    tests = ids or ['go:example/pkg.TestA', 'go:example/pkg.TestB', 'go:example/pkg.TestC']
    if 'overlap' in MODE:
        # two runs start the same tests; the first ends first; neither finishes them
        update(run_no, *[record('started', '-', t) for t in tests])
        time.sleep(0.3 if run_no == 1 else 1.0)
        request('test-end', str(run_no), None)
        return
    if 'slow2' in MODE and run_no == 1:
        pass                            # the first run reports as usual (below)
    elif 'survivor' in MODE:
        script = ('import subprocess,sys,time\n'
                  'p=subprocess.Popen([sys.executable,"-c","import signal,time\\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\\ntime.sleep(60)"],'
                  'stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)\n'
                  'print(p.pid,flush=True)\ntime.sleep(60)\n')
        r = exec_cmd(run_no, 'python3', ['-c', script])
        log('survivor ' + r)
        while run_no not in cancelled:
            time.sleep(0.05)
        request('test-end', str(run_no), None)
        return
    elif 'slow' in MODE or 'slow2' in MODE or 'stubborn' in MODE or 'slowexec' in MODE:
        update(run_no, *[record('started', '-', t) for t in tests])
        if 'slowexec' in MODE:
            r = exec_cmd(run_no, 'python3', ['-c', 'import time\nprint("sleeping", flush=True)\ntime.sleep(60)'])
            ex = int(r.split()[2]) if r.startswith('ok ') else None
            log(f'slowexec {r}')
            if ex:
                res = wait_exit(ex, 20)
                log(f'exit {res and res["exit"]}')
        while run_no not in cancelled:
            time.sleep(0.05)
        if 'stubborn' not in MODE:
            request('test-end', str(run_no), None)
        return
    if 'crash' in MODE:
        update(run_no, record('started', '-', tests[0]))
        time.sleep(0.2)
        os._exit(1)
    if 'refuse' in MODE:
        return
    if 'unknown' in MODE:
        update(run_no, record('passed', 1, 'go:example/nope'), record('passed', 2, tests[0]))
        request('test-end', str(run_no), None)
        return
    if 'exec' in MODE:
        r = exec_cmd(run_no, 'python3', ['-c', 'import sys\nprint("out-line")\nprint("err-line", file=sys.stderr)\nsys.exit(3)'],
                     env=['RHUN_FAKE=1'])
        log(f'exec {r}')
        if r.startswith('ok '):
            res = wait_exit(int(r.split()[2]))
            log(f'exec-result exit={res["exit"]} out={res["out"]!r} err={res["err"]!r}')
            update(run_no, record('passed', 5, 'go:example/pkg.TestA', x('output', res['out'] + res['err'])))
        request('test-end', str(run_no), None)
        return
    if 'execbad' in MODE:
        log('bad-prog ' + exec_cmd(run_no, 'ls', []))
        log('bad-name ' + exec_cmd(run_no, '../python3', []))
        log('bad-cwd ' + exec_cmd(run_no, 'python3', ['-c', 'pass'], cwd='/'))
        log('bad-env ' + exec_cmd(run_no, 'python3', ['-c', 'pass'], env=['lower=1']))
        log('missing ' + exec_cmd(run_no, 'python3', ['-c', 'pass'], cwd=os.path.join(project[0], 'nope')))
        oks = [exec_cmd(run_no, 'python3', ['-c', 'import time\ntime.sleep(3)']) for _ in range(5)]
        log('fifth ' + oks[4])
        request('test-end', str(run_no), None)
        log('over ' + exec_cmd(run_no, 'python3', ['-c', 'pass']))
        return
    if 'chatty' in MODE:
        total = int(os.environ.get('TESTS_CHATTY', str(20 << 20)))
        r = exec_cmd(run_no, 'python3', ['-c', f'import sys\nb=b"x"*65536\nn={total}\nwhile n>0:\n sys.stdout.buffer.write(b[:min(n,65536)]); n-=65536\n'])
        res = wait_exit(int(r.split()[2]), 120)
        log(f'chatty exit={res and res["exit"]} bytes={len(res["out"]) if res else -1}')
        request('test-end', str(run_no), None)
        return
    # the default: results for each test
    update(run_no, *[record('queued', '-', t) for t in tests], record('-', '-', '', x('output', 'build ok\n')))
    for t in tests:
        update(run_no, record('started', '-', t))
        if t.endswith('TestA'):
            r = request('test-items', 'add', items_body('go:example/pkg.TestA', [
                item('test', 'go:example/pkg.TestA/sub', 'sub', tests_file(), (4, 2, 4, 9))]))
            update(run_no, record('passed', 1, 'go:example/pkg.TestA/sub'),
                   record('passed', 12, t, x('output', 'ok A\n')))
        elif t.endswith('TestB'):
            f = tests_file()
            update(run_no, record('failed', 30, t, x('message', 'Greet mismatch\nsecond line'),
                                  x('location', f, '8 2 8 10'), x('expected', 'Hello, rhun!\nWelcome.'),
                                  x('actual', 'Hello, rhun'), x('output', '=== RUN TestB\nfail\n')))
        elif t.endswith('TestC'):
            update(run_no, record('skipped', 0, t))
        else:
            update(run_no, record('passed', 3, t))
    if 'bigout' in MODE:
        log('big ' + update(run_no, record('-', '-', tests[0], x('output', 'y' * 300000))))
    if profile == 'coverage':
        f = tests_file().encode()
        body = b'1\n' + f'{len(f)} 3\n'.encode() + f + b'3 3 1\n5 7 2\n6 6 0\n'
        log('coverage ' + request('test-coverage', str(run_no), body))
        if 'covrepeat' in MODE:
            # one path 70 times at the last line: 1 MiB once merged, not 70
            rep = b'/cov/rep.go'
            body = b'70\n' + (f'{len(rep)} 1\n'.encode() + rep + b'1048576 1048576 1\n') * 70
            log('covrepeat ' + request('test-coverage', str(run_no), body))
        if 'cov2' in MODE:
            low = b'/cov/low.go'
            body = b'1\n' + f'{len(low)} 2\n'.encode() + low + b'1 1 1\n2 4 0\n'
            log('cov2 ' + request('test-coverage', str(run_no), body))
        if 'covbig' in MODE:
            # 70 files with one line at the last allowed line: 70 MiB of lines
            files = [f'/cov/big{i}.go'.encode() for i in range(70)]
            body = f'{len(files)}\n'.encode() + b''.join(f'{len(p)} 1\n'.encode() + p + b'1048576 1048576 1\n' for p in files)
            log('covbig ' + request('test-coverage', str(run_no), body))
        if 'covunion' in MODE:
            files = [f'/cov/f{i}.go'.encode() for i in range(12000)]
            body = f'{len(files)}\n'.encode() + b''.join(f'{len(p)} 1\n'.encode() + p + b'1 1 1\n' for p in files)
            log('covunion1 ' + request('test-coverage', str(run_no), body))
            log('covunion2 ' + request('test-coverage', str(run_no), body))
    request('test-end', str(run_no), None)
    if 'replaceafter' in MODE:
        f = tests_file()
        log('replace ' + request('test-items', 'replace', items_body('go:example/pkg#a_test.go', [
            item('test', 'go:example/pkg.TestD', 'TestD', f, (15, 1, 16, 2)),
            item('test', 'go:example/pkg.TestA', 'TestA renamed', f, (3, 1, 5, 2))])))
    if 'late' in MODE:
        log('late ' + update(run_no, record('passed', 1, tests[0])))


def flood(n, parent=''):
    items = [item('test', f'flood{i}', f'flood {i}') for i in range(n)]
    return request('test-items', 'replace' if parent == '' else 'add', items_body(parent, items))


def reader():
    stdin = sys.stdin.buffer
    while True:
        line = stdin.readline()
        if not line:
            os._exit(0)
        text = line.decode(errors='replace').rstrip('\n')
        f = text.split(' ')
        body = b''
        if f[0] == 'ok' and len(f) >= 2:
            rid = int(f[1])
            with reply_cv:
                replies[rid] = text
                reply_cv.notify_all()
            continue
        if f[0] == 'error' and len(f) >= 2:
            with reply_cv:
                replies[int(f[1])] = text
                reply_cv.notify_all()
            continue
        if len(f) >= 3 and f[1] in ('tests-resolve', 'test-run'):
            body = stdin.read(int(f[-1]))
        if f[0] == '0' and len(f) >= 2 and f[1] == 'test-out':
            body = stdin.read(int(f[-1]))
            ex = int(f[2])
            with exec_cv:
                e = execs.setdefault(ex, {'out': b'', 'err': b'', 'exit': None})
                e[f[3]] += body
                exec_cv.notify_all()
            if 'chatty' in MODE:
                time.sleep(0.002)
            else:
                log(f'recv {text} {body!r}')
            continue
        if f[0] == '0' and len(f) >= 2 and f[1] == 'edits':
            body = stdin.read(int(f[-1]))
        log('recv ' + text + (' ' + repr(body) if body and f[1] != 'edits' else ''))
        if f[0] == '0' and len(f) >= 3 and f[1] == 'test-exit':
            with exec_cv:
                e = execs.setdefault(int(f[2]), {'out': b'', 'err': b'', 'exit': None})
                e['exit'] = ' '.join(f[3:])
                exec_cv.notify_all()
            continue
        if f[0] == '0' and len(f) >= 3 and f[1] == 'test-cancel':
            cancelled.add(int(f[2]))
            continue
        if f[0] == '0' and len(f) >= 3 and f[1] == 'ready':
            project[0] = f[2]
            continue
        inbox.put((f, body))


def main():
    send('hello 1 tests\n')
    threading.Thread(target=reader, daemon=True).start()
    while True:
        f, body = inbox.get()
        if f[0] == '0':
            if f[1] == 'bye':
                return
            continue
        rid = f[0]
        if f[1] == 'tests-resolve':
            parent = body.decode()
            if 'resolveslow' in MODE:
                continue                    # never answered: rhun gives up after 30 s
            log('resolve ' + parent)
            if parent == '':
                # pkgpath: the package names its folder, as the real controllers do, so rhun resolves it
                # when a file in it is open
                pkg_path = project[0] if 'pkgpath' in MODE else ''
                send_reply(rid, items_body('', [item('group', 'go:example/pkg', 'pkg', pkg_path, flags='lazy'),
                                                 item('group', 'go:example/other', 'other', flags='lazy')]))
                if 'flood' in MODE:
                    threading.Thread(target=lambda: (log('flood-body ' + flood(10001)),
                                                     log('flood-ok ' + flood(10000)),
                                                     log('flood-add ' + flood_more()),
                                                     log('flood-replace ' + request('test-items', 'replace',
                                                         items_body('', [item('test', 'one', 'one')])))),
                                     daemon=True).start()
                if 'remove' in MODE:
                    threading.Thread(target=removal, daemon=True).start()
                if 'movecap' in MODE:
                    threading.Thread(target=move_cap, daemon=True).start()
            elif parent == 'go:example/pkg':
                send_reply(rid, items_body(parent, pkg_children()))
                threading.Thread(target=lambda: log('file-items ' + request(
                    'test-items', 'replace', items_body('go:example/pkg#a_test.go', file_children()))),
                    daemon=True).start()
                if 'removeb' in MODE:
                    threading.Thread(target=lambda: (time.sleep(1.0), log('removeb ' + request(
                        'test-remove', '1', b'go:example/pkg.TestB\n'))), daemon=True).start()
            elif parent == 'go:example/other':
                send(f'error {rid} refused cannot list other\n')
            else:
                send(f'error {rid} refused unknown\n')
        elif f[1] == 'test-run':
            run_no, profile, n = int(f[2]), f[3], int(f[4])
            ids = [i for i in body.decode().split('\n') if i]
            log(f'run {run_no} {profile} {n} {",".join(ids)}')
            if 'refuse' in MODE:
                send(f'error {rid} busy the build is running\n')
                continue
            send(f'ok {rid} 0\n')
            threading.Thread(target=run, args=(run_no, profile, ids), daemon=True).start()
        else:
            send(f'error {rid} unknown\n')


def flood_more():
    """The per-extension cap: four bodies of 10000 under a group, then one more."""
    request('test-items', 'add', items_body('', [item('group', 'g', 'g')]))
    for k in range(4):
        items = [item('test', f'more{k}-{i}', 'm') for i in range(10000)]
        r = request('test-items', 'add', items_body('g', items))
        if not r.startswith('ok'):
            return f'step {k}: {r}'
    items = [item('test', f'last{i}', 'm') for i in range(2)]
    return request('test-items', 'add', items_body('g', items))


def removal():
    time.sleep(0.3)
    log('unknown-parent ' + request('test-items', 'add', items_body('nope', [item('test', 'x', 'x')])))
    log('cycle ' + request('test-items', 'add', items_body('go:example/pkg', [item('group', 'go:example/pkg', 'pkg')])))
    log('bad-range ' + request('test-items', 'add', items_body('', [item('test', 'r', 'r', '/x', (5, 1, 4, 1))])))
    log('relative ' + request('test-items', 'add', items_body('', [item('test', 'r', 'r', 'x.go', (1, 1, 1, 1))])))
    ids = b'go:example/other\n'
    log('remove ' + request('test-remove', '1', ids))


def send_reply(rid, body):
    send(f'ok {rid} {len(body)}\n'.encode() + body)


if __name__ == '__main__':
    main()
