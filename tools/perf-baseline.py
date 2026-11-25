#!/usr/bin/env python3
"""Headless performance baseline: times rhun on fixed workloads, so a version can be compared with
the last. Standard library only. Every run has its own HOME and XDG folders; fixtures are made in a
temporary folder from fixed seeds.

    python3 tools/perf-baseline.py                       # build/rhun
    python3 tools/perf-baseline.py --binary OLD --binary NEW
    python3 tools/perf-baseline.py --json results.json   # medians, for a later comparison
    python3 tools/perf-baseline.py --samples all.json    # every round's value, and every key's time
    python3 tools/perf-baseline.py --chat                # and Claude Code's chat, with the fake CLI

Times are medians of --runs rounds (default 5); each round times every build once, in turns, so
caches and the machine's load treat them alike. A time is a whole headless process, less a run of
the same setup without the measured steps where that makes sense; it includes the scripted
commands' own frames, not putting frames on a screen. The idle counts (frames, main loop passes)
are counts, not times.

A Claude conversation open in the panel (an old one, nothing started) is measured on every build;
--chat adds what needs the chat (a build that has it), with tests/scripts/fake-claude.py as the CLI:
loop passes once a process ran and was released, and the time from a key in the prompt box to the
frame that shows it (control `key`: sent, handled, then the command's frame, then `ok`) while the
fake streams a long Markdown reply (scenario `stream`) and with nothing streaming; with a process running,
the time from a new conversation's first prompt to its answer (a cold start: the process, initialize,
get_settings, the turn) and the wake-ups of a ready conversation and of a permission request waiting; on a
build with phase 2's controls (it knows print-agent-cfg), the wake-ups of a band with a warm prompt-cache
clock and of the open command menu, and the command menu's open time with 500 cached commands; on a build
with phase 3's spinner (print-agent-spinner), the wake-ups of a working turn with its spinner in view and
scrolled away.
"""
import argparse
import json
import os
from pathlib import Path
import random
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ('[ui]\nagents_panel = {agents}\nsidebar = {sidebar}\n[editor]\ncursor_blink = false\n'
          '[terminal]\nshell = /bin/sh\n[files]\nrestore_session = false\nrestore_project = false\n'
          '[updates]\ncheck = false\n[git]\nenabled = false\n')
FAKE = ROOT / 'tests/scripts/fake-claude.py'
# the chat's runs start the fake, never a claude of the machine's
CLAUDE = '[claude]\nwrapper = %s\nexecutable = %s\n' % (Path(sys.executable).resolve().as_posix(), FAKE.as_posix())


class Bench:
    def __init__(self, exe, work, runs):
        self.exe, self.work, self.runs = exe, work, runs

    def environment(self, home, agents, sidebar, chat=False):
        """the environment of a run with its own HOME and XDG folders, the config written afresh; chat: the
        fake as Claude Code, its log in HOME, none of a surrounding Claude Code session's variables"""
        (home / 'config/rhun').mkdir(parents=True, exist_ok=True)
        (home / 'config/rhun/config').write_text(
            CONFIG.format(agents=str(agents).lower(), sidebar=str(sidebar).lower()) + (CLAUDE if chat else ''),
            encoding='utf-8')
        shutil.rmtree(home / 'state', ignore_errors=True)
        env = dict(os.environ, HOME=home.as_posix(), XDG_CONFIG_HOME=(home / 'config').as_posix(),
                   XDG_STATE_HOME=(home / 'state').as_posix())
        if chat:
            env = {k: v for k, v in env.items() if not k.startswith(('CLAUDE', 'ANTHROPIC'))}
            env.update(TERM='dumb', FAKE_CLAUDE_LOG=(home / 'fake-claude.log').as_posix())
        return env

    def run(self, target, actions=(), size='1280x800', scale='1', agents=False, sidebar=True, home=None):
        """seconds for one run of rhun TARGET with the script's actions, then quit"""
        env = self.environment(home or self.work / 'home', agents, sidebar)
        script = self.work / 'actions.rsc'
        script.write_text('\n'.join([*actions, 'quit']) + '\n', encoding='utf-8')
        start = time.perf_counter()
        result = subprocess.run([self.exe, *[t.as_posix() for t in target], '--headless', size, '--scale', scale,
                                 '--script', script.as_posix()], env=env, capture_output=True, timeout=300)
        elapsed = time.perf_counter() - start
        if result.returncode:
            raise RuntimeError(result.stderr.decode(errors='replace'))
        self.out = result.stdout.decode('utf-8', errors='replace')
        return elapsed

    def median(self, *args, **kwargs):
        return statistics.median(self.run(*args, **kwargs) for _ in range(self.runs))

    def per_step(self, target, setup, step, n, **kwargs):
        """ms per step: (setup + n steps) less setup alone"""
        return (self.median(target, setup + step * n, **kwargs) - self.median(target, setup, **kwargs)) / n * 1000

    def controlled(self, target, home, agents, body, chat=False, env=None):
        """body(command) on a window on TARGET driven through the control socket; command(line) sends one
        command and returns its output (an error answer raises). The window is quit at the end. env: more
        variables (the fake's knobs)."""
        env = dict(self.environment(home, agents, True, chat), **(env or {}))
        # a socket's path is short (104 bytes on macOS): its own folder under /tmp
        with tempfile.TemporaryDirectory(prefix='rhun-perf-', dir='/tmp') as sockets:
            control = Path(sockets) / 'control'
            process = subprocess.Popen([self.exe, *[t.as_posix() for t in target], '--headless', '1280x800',
                                        '--scale', '1', '--control', control.as_posix()], env=env,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                client.settimeout(60)
                deadline = time.monotonic() + 30
                while True:
                    try:
                        client.connect(control.as_posix())
                        break
                    except (FileNotFoundError, ConnectionRefusedError):
                        if process.poll() is not None or time.monotonic() > deadline:
                            raise RuntimeError('rhun did not start')
                        time.sleep(0.01)
                reader = client.makefile('r', encoding='utf-8')

                def command(line):
                    client.sendall((line + '\n').encode('utf-8'))
                    output = []
                    while True:
                        reply = reader.readline()
                        if reply == 'ok\n':
                            return ''.join(output)
                        if reply in ('', 'error\n'):
                            raise RuntimeError('%s: %r' % (line, ''.join(output) + reply))
                        output.append(reply)

                value = body(command)
                client.sendall(b'quit\n')
                process.wait(timeout=30)
                reader.close()
            finally:
                client.close()
                if process.poll() is None:
                    process.kill()
                    process.wait()
        return value

    def idle_passes(self, target, home, agents, settle=3, seconds=10, setup=(), chat=False):
        """main loop passes in SECONDS of an idle window on TARGET, SETTLE seconds after it started (and
        after the SETUP commands), run through the control socket (a script's waits poll on their own,
        not in the main loop). The pass the second print-loop-stats wakes is not counted: a window that
        never woke shows 0. setup may be a function of command."""
        def body(command):
            def passes():
                reply = command('print-loop-stats')
                if not reply.startswith('passes='):
                    raise RuntimeError('print-loop-stats: %r' % reply)
                return int(reply.split()[0].split('=')[1])
            if callable(setup):
                setup(command)
            else:
                for line in setup:
                    command(line)
            time.sleep(settle)
            before = passes()
            time.sleep(seconds)
            return passes() - before - 1
        return self.controlled(target, home, agents, body, chat)

    def key_to_frame(self, target, home, keys=100, seed=3):
        """ms from sending a key in a new Claude conversation's prompt box to the answer that follows the
        frame showing it, KEYS times while the fake streams a long reply, then KEYS times once it ended;
        the keys alternate a letter and BackSpace, 20 to 60 ms apart"""
        rng = random.Random(seed)

        def body(command):
            def live():
                return command('print-agent-live').split('\n')[0]

            def times():
                out = []
                for i in range(keys):
                    time.sleep(rng.uniform(0.02, 0.06))
                    start = time.perf_counter()
                    command('key a' if i % 2 == 0 else 'key BackSpace')
                    out.append((time.perf_counter() - start) * 1000)
                return out
            command('agent-new claude')
            command('agent-prompt stream 3000 5')
            command('wait-agent working 20000')
            deadline = time.monotonic() + 20         # until the reply streams (after the tool's row)
            while not any(line.startswith('agent') for line in command('print-agents').splitlines()):
                if time.monotonic() > deadline:
                    raise RuntimeError('no reply streamed: ' + live())
                time.sleep(0.05)
            if ' focus=1 ' not in command('print-agent-input'):
                command('key Tab')
            if ' focus=1 ' not in command('print-agent-input'):
                raise RuntimeError('the prompt box has not the keys')
            streaming = times()
            if not live().startswith('state=working '):
                raise RuntimeError('the stream ended before the keys did: ' + live())
            command('wait-agent ready 120000')
            if ' focus=1 ' not in command('print-agent-input'):
                raise RuntimeError('the prompt box lost the keys')
            quiet = times()
            return streaming, quiet
        return self.controlled(target, home, True, body, chat=True)


def fixtures(work):
    rng = random.Random(7)
    empty = work / 'empty'
    empty.mkdir()
    folder = work / 'folder'
    folder.mkdir()
    for i in range(20000):
        (folder / ('f%.12f' % rng.random())).write_bytes(b'')
    big = work / 'big.txt'
    big.write_text(''.join('x' * rng.randint(0, 80) + '\n' for _ in range(250000)), encoding='utf-8')
    code = work / 'code.c'
    code.write_text(''.join('static int value_%d(int a) { return a * %d + 1; } // %s\n' % (i, i, 'x' * (i % 40))
                            for i in range(50000)), encoding='utf-8')
    line = work / 'line.json'
    line.write_text('{' + ','.join('"k%d":[%d,"v%d",true]' % (i, i, i) for i in range(90000)) + '}\n',
                    encoding='utf-8')
    lines = work / 'lines.txt'
    lines.write_text(''.join('line %d needle text\n' % i for i in range(1000000)), encoding='utf-8')
    matches = work / 'matches.txt'
    matches.write_text('needle xyz\n' * 80000, encoding='utf-8')
    nested = work / 'nested.rs'           # editor presentation: 20,000 foldable blocks
    nested.write_text(''.join('fn f%d() {\n    let a = %d;\n    if a > 1 {\n        a + 1;\n    }\n}\n' % (i, i)
                              for i in range(20000)), encoding='utf-8')
    output = work / 'output.txt'
    output.write_text(''.join('line %d of the output, some text to fill it\n' % i for i in range(400000)),
                      encoding='utf-8')
    return locals()


def long_conversation(project, seed=0):
    """a Claude Code transcript of 400 turns (about 750 KB): a prompt, a reply in Markdown (a heading,
    a list, a table, a code block, links), a tool call and its result each"""
    rng = random.Random(11 + seed)
    words = ('the panel layout code reads each row once and keeps its height until the width '
             'changes so scrolling stays smooth while replies stream in').split()
    cwd = project.as_posix()
    lines = []
    for i in range(400):
        prose = lambda n: ' '.join(rng.choice(words) for _ in range(n))
        reply = '\n'.join(['## Step %d' % i, '', prose(40) + ' **' + prose(3) + '** ' + prose(20) + '.', '',
                            '- ' + prose(8), '- ' + prose(10), '- `src/app/f%d.s` ' % i + prose(6), '',
                            '| file | lines |', '| --- | ---: |', '| a.s | %d |' % i, '| b.s | %d |' % (i * 3), '',
                            '```python', *('def f%d_%d(x):\n    return x * %d' % (i, j, j) for j in range(6)), '```',
                            '', 'See [the code](src/app/f%d.s:%d) and [the notes](https://example.com/%d).'
                            % (i, i + 1, i)])
        lines.append({'type': 'user', 'message': {'role': 'user', 'content': 'step %d: ' % i + prose(25)},
                      'cwd': cwd, 'sessionId': 'long%d' % seed})
        lines.append({'type': 'assistant', 'message': {'role': 'assistant', 'content': [
            {'type': 'text', 'text': reply},
            {'type': 'tool_use', 'id': 't%d' % i, 'name': 'Bash', 'input': {'command': 'grep -n f%d src' % i}}]}})
        lines.append({'type': 'user', 'message': {'role': 'user', 'content': [
            {'type': 'tool_result', 'tool_use_id': 't%d' % i, 'content': '\n'.join(prose(12) for _ in range(6))}]}})
    lines.append({'type': 'custom-title', 'customTitle': 'Long conversation %d' % seed, 'sessionId': 'long%d' % seed})
    return ''.join(json.dumps(line) + '\n' for line in lines)


def measure(exe, work, chat=False):
    """one sample of every workload (chat: and the chat's)"""
    f = FIXTURES
    b = Bench(exe, work, 1)
    moves = lambda n: ['move %d 600' % (500 + i % 2) for i in range(n)]
    results = {}
    # startups after one not timed, so the file cache holds what they read
    for name, target in (('startup, empty folder (ms)', f['empty']), ('startup, folder of 20,000 files (ms)',
                         f['folder']), ('open a 20 MB file (ms)', f['big'])):
        b.run([target])
        results[name] = b.median([target]) * 1000
    # each step is two moves, a frame each
    results['editor frame, 2560x1600 @2x (ms)'] = b.per_step(
        [f['code']], [], ['move 500 600', 'move 501 600'], 50, size='2560x1600', scale='2') / 2
    results['palette frame, 2560x1600 @2x (ms)'] = b.per_step(
        [f['code']], ['cmd command_palette'], ['move 500 900', 'move 501 900'], 50, size='2560x1600',
        scale='2') / 2
    results['frame, caret at the end of a 2.7 MB line (ms)'] = b.per_step(
        [f['line']], ['key End'], ['move 500 600', 'move 501 600'], 20) / 2
    results['find field keystroke, 1M lines (ms)'] = b.per_step(
        [f['lines']], ['cmd find'], ['type e', 'key BackSpace'], 5) / 2
    results['replace all, 80,000 matches (ms)'] = (
        b.median([f['matches']], ['key ctrl+h', 'key ctrl+a', 'type needle', 'key Tab', 'key ctrl+a',
                                  'type replacement', 'key ctrl+Return'])
        - b.median([f['matches']], ['key ctrl+h', 'key ctrl+a', 'type needle', 'key Tab', 'key ctrl+a',
                                    'type replacement'])) * 1000
    # editor presentation: Fold All over 120,000 lines, then frames that scroll by rows over the folds
    results['fold all, 20,000 blocks (ms)'] = (b.median([f['nested']], ['cmd fold_all'])
                                               - b.median([f['nested']], [])) * 1000
    results['frame scrolled by rows over 40,000 folds (ms)'] = b.per_step(
        [f['nested']], ['cmd fold_all', 'move 500 400'], ['scroll 3', 'scroll -3'], 30) / 2
    if os.name != 'nt':
        results['terminal: cat 18 MB (ms)'] = (
            b.median([f['empty']], ['cmd toggle_terminal', 'wait-term $', 'type cat %s; echo DO""NE'
                                    % f['output'].as_posix(), 'key Return', 'wait-term DONE'])
            - b.median([f['empty']], ['cmd toggle_terminal', 'wait-term $', 'type true; echo DO""NE',
                                      'key Return', 'wait-term DONE'])) * 1000
    # idle: frames in 3 s with the agents panel showing an old session
    home = work / 'agents-home'
    project = work / 'agents-project'
    project.mkdir(exist_ok=True)
    slug = ''.join(c if c.isalnum() else '-' for c in project.as_posix())
    sessions = home / '.claude/projects' / slug
    sessions.mkdir(parents=True, exist_ok=True)
    session = sessions / 's1.jsonl'
    session.write_text((ROOT / 'tests/data/agents/claude.jsonl').read_text(encoding='utf-8')
                       .replace('@PROJECT@', project.as_posix()), encoding='utf-8')
    old = time.time() - 86400 * 3
    os.utime(session, (old, old))
    b.run([project], ['wait-agents', 'wait 300', 'print-frames', 'wait 3000', 'print-frames'], agents=True, home=home)
    results['idle frames in 3 s, agents panel shown'] = int(b.out.strip().splitlines()[-1].split('=')[1])
    # opening a long conversation in the agents panel: its file read, its rows measured, the replies
    # in view drawn as Markdown (the largest fixture, made here; 8 of them, each opened once)
    long_home = work / 'long-home'
    long_project = work / 'long-project'
    long_project.mkdir(exist_ok=True)
    long_slug = ''.join(c if c.isalnum() else '-' for c in long_project.as_posix())
    long_sessions = long_home / '.claude/projects' / long_slug
    long_sessions.mkdir(parents=True, exist_ok=True)
    for i in range(8):
        (long_sessions / ('long%d.jsonl' % i)).write_text(long_conversation(long_project, i), encoding='utf-8')
    setup = ['wait-agents', 'wait 300']
    results['open a conversation of 400 turns (ms)'] = (
        b.median([long_project], setup + ['print-agents %d' % (i + 1) for i in range(8)], agents=True,
                 home=long_home)
        - b.median([long_project], setup, agents=True, home=long_home)) * 1000 / 8
    # idle wake-ups: main loop passes in 10 s on the same project, the panel shown and hidden
    if os.name != 'nt':
        results['idle loop passes in 10 s, agents panel shown'] = b.idle_passes([project], home, True)
        results['idle loop passes in 10 s, agents panel hidden'] = b.idle_passes([project], home, False)
        # the old conversation open in the panel (a build with the chat: its box, nothing started)
        home, project = claude_project(work, 'open')
        results['idle loop passes in 10 s, a Claude conversation open'] = b.idle_passes(
            [project], home, True, setup=['wait-agents', 'print-agents 1'], chat=True)
        log = home / 'fake-claude.log'
        results['Claude processes started, conversation open'] = len(
            log.read_text(encoding='utf-8').splitlines()) if log.exists() else 0
    if chat and os.name != 'nt' and has_chat(b, work):
        home, project = claude_project(work, 'released')

        def released(command):
            command('wait-agents')
            command('print-agents 1')
            command('agent-prompt hello')
            command('wait-agent ready 20000')
            command('agent-release')
            command('wait-agent off 20000')
            deadline = time.monotonic() + 20
            while ' pid=1 ' in command('print-agent-live'):
                if time.monotonic() > deadline:
                    raise RuntimeError('the process was not reaped')
                time.sleep(0.05)
            time.sleep(5)                       # discovery reads the file that changed
        results['idle loop passes in 10 s, the conversation after a process ran and was released'] = (
            b.idle_passes([project], home, True, setup=released, chat=True))
        home, project = claude_project(work, 'keys')
        streaming, quiet = b.key_to_frame([project], home)
        KEYS.setdefault(exe, []).append({'streaming': streaming, 'quiet': quiet})
        results['key to frame while a reply streams, median (ms)'] = statistics.median(streaming)
        results['key to frame while a reply streams, worst (ms)'] = max(streaming)
        results['key to frame, nothing streaming, median (ms)'] = statistics.median(quiet)
        results['key to frame, nothing streaming, worst (ms)'] = max(quiet)
        results.update(chat_live(b, work))
    return results


def chat_live(b, work):
    """--chat with a process running: a cold start's first answer, wake-ups of a ready conversation, of a
    permission request waiting (its card after its 500 ms lock), and, on a build with phase 2's controls
    (print-agent-cfg), of a band with a warm prompt-cache clock and of the open command menu; the command
    menu's open time with 500 cached commands"""
    results = {}
    home, project = claude_project(work, 'first')

    def first(command):
        command('wait-agents')
        out = []
        for _ in range(5):                      # each a new conversation: a new process, its first prompt
            command('agent-new claude')
            start = time.perf_counter()
            command('agent-prompt hello')
            command('wait-agent ready 20000')
            out.append((time.perf_counter() - start) * 1000)
            command('agent-release')
            command('wait-agent off 20000')
        return out
    times = b.controlled([project], home, True, first, chat=True)
    FIRST.setdefault(b.exe, []).append(times)
    results['first prompt to its answer at a cold start, median of 5 (ms)'] = statistics.median(times)

    def chatted(prompt, wait, *more):
        def setup(command):
            command('wait-agents')
            command('print-agents 1')
            command('agent-prompt ' + prompt)
            command('wait-agent %s 20000' % wait)
            for line in more:
                command(line)
        return setup
    home, project = claude_project(work, 'ready')
    results['idle loop passes in 10 s, a conversation ready, its process running'] = b.idle_passes(
        [project], home, True, setup=chatted('hello', 'ready'), chat=True)
    home, project = claude_project(work, 'card')
    results['idle loop passes in 10 s, a permission request waiting'] = b.idle_passes(
        [project], home, True, setup=chatted('tool', 'waiting'), chat=True)
    if not has_controls(b, work):
        return results
    home, project = claude_project(work, 'band')
    results['idle loop passes in 10 s, a band and a warm cache clock shown'] = b.idle_passes(
        [project], home, True, setup=chatted('usage', 'ready', 'agent-test-band notice A notice that stays'),
        chat=True)
    home, project = claude_project(work, 'menu')
    results['idle loop passes in 10 s, the command menu open'] = b.idle_passes(
        [project], home, True, setup=chatted('hello', 'ready', 'agent-menu /'), chat=True)
    if has_spinner(b, work):
        # phase 3 task 5: a turn that works (the fake's linger) with its spinner line in view ticks every
        # 120 ms; scrolled away, nothing moving is drawn and the tick stops
        home, project = claude_project(work, 'spin')
        results['idle loop passes in 10 s, a turn working, the spinner in view'] = b.idle_passes(
            [project], home, True, setup=chatted('linger 40', 'working'), chat=True)
        home, project = claude_project(work, 'spinaway')
        notes = ['agent-test-row meta a note that takes some room in the thread %d' % i for i in range(60)]
        results['idle loop passes in 10 s, a turn working, the spinner scrolled away'] = b.idle_passes(
            [project], home, True, setup=chatted('linger 40', 'working', *notes, 'move 1100 400', 'scroll -4000'),
            chat=True)
    home, project = claude_project(work, 'commands')

    def menu(command):
        def timed(line):
            start = time.perf_counter()
            command(line)
            return (time.perf_counter() - start) * 1000
        command('wait-agents')
        path = Path(dict(w.split('=', 1) for w in command('print-agent-cfg').splitlines()[0].split(' '))['path'])
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(commands_record(500), encoding='utf-8')
        command('print-agents 1')
        opened = timed('agent-menu /')          # the first: the record read from the file
        rows = [line for line in command('print-agent-menu').splitlines() if line.startswith('row ')]
        if sum(' /cmd' in row for row in rows) != 500:
            raise RuntimeError('the menu does not list the 500 commands: %d rows' % len(rows))
        command('key Escape')
        again, keys, frames = [], [], []
        for i in range(20):
            again.append(timed('agent-menu /'))
            keys.append(timed('agent-type c'))  # a key in the filter: every command still matches
            command('key Escape')
            frames.append(timed('key a'))       # a frame of the box alone, for reference
            command('key BackSpace')
        return opened, again, keys, frames
    opened, again, keys, frames = b.controlled([project], home, True, menu, chat=True)
    results['open the command menu of 500 cached commands, first (reads the file) (ms)'] = opened
    results['open the command menu of 500 cached commands, again, median (ms)'] = statistics.median(again)
    results['open the command menu of 500 cached commands, again, worst (ms)'] = max(again)
    results['a key in the filter of 500 commands, median (ms)'] = statistics.median(keys)
    results['a key in the box, the menu closed, median (ms)'] = statistics.median(frames)
    return results


def commands_record(n):
    """the project's Claude record (agentcfg.s) with N commands, as the state file holds it"""
    return 'agentcfg\t1\nversion\t2.1.330\n' + ''.join(
        'cmd\tcmd%d\tCommand number %d does something with the files of the project\t\t\t\t0\t2\n'
        % (i + 1, i + 1) for i in range(n))


FIRST = {}                                  # every cold start's time of the --chat runs, by build
CONTROLS = {}                               # whether a build has phase 2's controls, by build


def has_spinner(b, work):
    """whether b's build has the spinner (phase 3 task 5: print-agent-spinner)"""
    if ('spin', b.exe) not in CONTROLS:
        def probe(command):
            try:
                command('print-agent-spinner')
                return True
            except RuntimeError:
                return False
        home, project = claude_project(work, 'probe3')
        CONTROLS[('spin', b.exe)] = b.controlled([project], home, True, probe, chat=True)
    return CONTROLS[('spin', b.exe)]


def has_controls(b, work):
    """whether b's build has phase 2's bands, menu and cards (it knows print-agent-cfg)"""
    if b.exe not in CONTROLS:
        def probe(command):
            try:
                command('print-agent-cfg')
                return True
            except RuntimeError:
                return False
        home, project = claude_project(work, 'probe2')
        CONTROLS[b.exe] = b.controlled([project], home, True, probe, chat=True)
    return CONTROLS[b.exe]


KEYS = {}                                   # every key's time of the --chat runs, by build
CHAT = {}                                   # whether a build has the chat, by build


def has_chat(b, work):
    """whether b's build has Claude Code's chat (it knows print-agent-live): --chat skips one without"""
    if b.exe not in CHAT:
        def probe(command):
            try:
                command('print-agent-live')
                return True
            except RuntimeError:
                return False
        home, project = claude_project(work, 'probe')
        CHAT[b.exe] = b.controlled([project], home, True, probe, chat=True)
    return CHAT[b.exe]


def claude_project(work, name):
    """a fresh HOME and project, the project's one old Claude conversation (the agents fixture)"""
    home = work / ('chat-home-' + name)
    project = work / ('chat-project-' + name)
    shutil.rmtree(home, ignore_errors=True)
    shutil.rmtree(project, ignore_errors=True)
    project.mkdir()
    slug = ''.join(c if c.isalnum() else '-' for c in project.as_posix())
    sessions = home / '.claude/projects' / slug
    sessions.mkdir(parents=True)
    session = sessions / 's1.jsonl'
    session.write_text((ROOT / 'tests/data/agents/claude.jsonl').read_text(encoding='utf-8')
                       .replace('@PROJECT@', project.as_posix()), encoding='utf-8')
    old = time.time() - 86400 * 3
    os.utime(session, (old, old))
    return home, project


def main():
    global FIXTURES
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--binary', action='append', help='rhun to time (repeat to compare)')
    parser.add_argument('--runs', type=int, default=5)
    parser.add_argument('--json', help='write the results here')
    parser.add_argument('--samples', help="write every round's value here (and every key's and cold start's time)")
    parser.add_argument('--chat', action='store_true', help="measure Claude Code's chat too (the fake CLI)")
    args = parser.parse_args()
    binaries = args.binary or [str(ROOT / 'build/rhun')]
    with tempfile.TemporaryDirectory(prefix='rhun-perf-') as temporary:
        work = Path(temporary).resolve()
        print('making fixtures...', file=sys.stderr)
        FIXTURES = fixtures(work)
        names = {exe: '%s (%s)' % (subprocess.run([exe, '--version'], capture_output=True,
                                                   text=True).stdout.strip(), exe) for exe in binaries}
        samples = {exe: {} for exe in binaries}
        for round in range(args.runs):
            print('round %d of %d...' % (round + 1, args.runs), file=sys.stderr)
            order = binaries[round % len(binaries):] + binaries[:round % len(binaries)]
            for exe in order:
                for name, value in measure(exe, work, args.chat).items():
                    samples[exe].setdefault(name, []).append(value)
        table = {names[exe]: {name: statistics.median(values) for name, values in samples[exe].items()}
                 for exe in binaries}
        if args.samples:
            Path(args.samples).write_text(json.dumps(
                {names[exe]: {'rounds': samples[exe], 'keys': KEYS.get(exe, []), 'first': FIRST.get(exe, [])}
                 for exe in binaries},
                indent=1) + '\n', encoding='utf-8')
    names = list(dict.fromkeys(name for column in table.values() for name in column))  # a build without the chat
    width = max(map(len, names))                                                      # has no chat rows
    print(' ' * width + ''.join('  %18s' % k.split(' (')[0] for k in table))
    for name in names:
        print(name.ljust(width) + ''.join('  %18.2f' % column[name] if name in column else '  %18s' % '-'
                                          for column in table.values()))
    if args.json:
        Path(args.json).write_text(json.dumps(table, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
