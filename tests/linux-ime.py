#!/usr/bin/env python3
"""Input methods on real X11 and Wayland (issue 121): the composition shows at the editor's caret
(print-preedit) and committed text is typed.
Wayland: headless Sway relays a stand-in input method (tests/wayland-input-method.c, the
input-method-v2 protocol) to rhun's text-input-v3.
X11: IBus's XIM server with the Hangul engine, keys from xdotool; skipped without ibus-daemon and
ibus-hangul. usage: linux-ime.py [--wayland]"""
import json
import os
import select
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time

if sys.platform != 'linux':
    print('skip linux/ime (requires Linux)')
    sys.exit(0)
ROOT = Path(__file__).resolve().parents[1]
EXE = Path(os.environ.get('RHUN_TEST_EXE', ROOT / 'build/rhun')).resolve()
wayland = '--wayland' in sys.argv
if not wayland and not (shutil.which('ibus-daemon') and
                        Path('/usr/share/ibus/component/hangul.xml').exists()):
    print('skip linux/x11-ime (needs ibus-daemon and ibus-hangul)')
    sys.exit(0)


def until(predicate, message, seconds=15):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.05)
    raise AssertionError(message)


with tempfile.TemporaryDirectory(prefix='rhun-ime-') as directory:
    work = Path(directory)
    processes = []
    logs = []
    env = dict(os.environ, HOME=str(work), XDG_CONFIG_HOME=str(work / 'config'),
               XDG_STATE_HOME=str(work / 'state'), XDG_DATA_HOME=str(work / 'data'),
               XDG_CACHE_HOME=str(work / 'cache'))
    config = work / 'config/rhun/config'
    config.parent.mkdir(parents=True)
    config.write_text('[ui]\nsidebar = false\nagents_panel = false\n'
                      '[files]\nrestore_session = false\nrestore_project = false\n'
                      '[updates]\ncheck = false\n[git]\nenabled = false\n')
    file = work / 'a.txt'
    file.write_text('hello\n')
    client = reader = method = None

    def start(args, **kwargs):
        log = open(work / ('process-' + str(len(processes)) + '.log'), 'w')
        logs.append(log)
        kwargs.setdefault('stdout', log)
        p = subprocess.Popen(args, env=env, stderr=log, **kwargs)
        processes.append(p)
        return p

    def output(args):
        return subprocess.check_output(args, env=env, text=True).strip()

    def command(line):
        client.sendall((line + '\n').encode())
        parts = []
        while True:
            reply = reader.readline()
            if reply == 'ok\n':
                return ''.join(parts)
            assert reply not in ('', 'error\n'), (line, reply)
            parts.append(reply)

    def doc():
        return command('print-doc').removesuffix('\n<eod>\n')

    def preedit():
        return command('print-preedit').removesuffix('\n')

    def expect(name, want_doc, want_preedit):
        got = None
        def match():
            nonlocal got
            got = (doc(), preedit())
            return got == (want_doc, want_preedit)
        try:
            until(match, '', 5)
        except AssertionError:
            raise AssertionError(f'{name}: document and composition {got!r}, '
                                 f'expected {(want_doc, want_preedit)!r}') from None
        print('ok   linux/' + ('wayland' if wayland else 'x11') + '-ime-' + name)

    try:
        if wayland:
            runtime = work / 'runtime'
            runtime.mkdir(mode=0o700)
            env.update(XDG_RUNTIME_DIR=str(runtime), WLR_BACKENDS='headless',
                       WLR_LIBINPUT_NO_DEVICES='1', WLR_RENDERER='pixman')
            env.pop('DISPLAY', None)
            env.pop('WAYLAND_DISPLAY', None)
            compositor = work / 'sway.conf'
            compositor.write_text('output * resolution 1280x800\n')
            start(['sway', '-d', '-c', str(compositor)])
            until(lambda: bool(list(runtime.glob('sway-ipc.*.sock'))), 'Sway did not start')
            env['SWAYSOCK'] = str(next(runtime.glob('sway-ipc.*.sock')))
            env['WAYLAND_DISPLAY'] = next(p.name for p in runtime.glob('wayland-*')
                                          if not p.name.endswith('.lock'))

            def nodes(tree):
                yield tree
                for child in tree.get('nodes', []) + tree.get('floating_nodes', []):
                    yield from nodes(child)

            def focused():
                tree = json.loads(output(['swaymsg', '-t', 'get_tree', '-r']))
                return any(n.get('app_id') == 'rhun' and n.get('focused') for n in nodes(tree))
            # a seat keyboard from the start, as on a desktop, then the input method
            programs = {}
            for name in ('wayland-keyboard', 'wayland-input-method'):
                programs[name] = work / name
                subprocess.run(['cc', str(ROOT / 'tests' / (name + '.c')), '-lwayland-client',
                                '-o', str(programs[name])], check=True)
            keyboard = start([str(programs['wayland-keyboard']),
                              str(ROOT / 'tests/data/keymap-gnome-us.txt')],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
            assert keyboard.stdout.readline() == 'ready\n', 'the keyboard did not start'
            method = start([str(programs['wayland-input-method'])], stdin=subprocess.PIPE,
                           stdout=subprocess.PIPE, text=True)
            assert method.stdout.readline() == 'ready\n', 'the input method did not start'
        else:
            read_fd, write_fd = os.pipe()
            start(['Xvfb', '-displayfd', str(write_fd), '-screen', '0', '1280x800x24', '-nolisten', 'tcp'],
                  pass_fds=(write_fd,))
            os.close(write_fd)
            with os.fdopen(read_fd) as pipe:
                env['DISPLAY'] = ':' + pipe.readline().strip()
            env['RHUN_BACKEND'] = 'x11'
            env.pop('WAYLAND_DISPLAY', None)
            started = work / 'openbox-started'
            start(['openbox', '--startup', 'touch ' + str(started)])
            until(started.exists, 'Openbox did not start')
            # IBus on its own session bus; the Hangul engine starts in Hangul mode
            bus = subprocess.check_output(['dbus-daemon', '--session', '--fork', '--print-address=1',
                                           '--print-pid=1'], env=env, text=True).split('\n')
            env['DBUS_SESSION_BUS_ADDRESS'] = bus[0]
            bus_pid = int(bus[1])
            env['GSETTINGS_BACKEND'] = 'keyfile'
            subprocess.run(['gsettings', 'set', 'org.freedesktop.ibus.engine.hangul',
                            'initial-input-mode', 'hangul'], env=env, check=True)
            start(['ibus-daemon', '--xim', '--replace', '--panel=disable'])
            until(lambda: subprocess.run(['ibus', 'engine', 'hangul'], env=env,
                                         capture_output=True).returncode == 0,
                  'IBus did not start', 30)
            # ibus-x11 announces itself on the root window
            until(lambda: '@server=ibus' in subprocess.run(
                ['xprop', '-root', 'XIM_SERVERS'], env=env, capture_output=True, text=True).stdout,
                'IBus XIM server did not start', 30)
            env['XMODIFIERS'] = '@im=ibus'

            def focused():
                result = subprocess.run(['xdotool', 'getactivewindow'], env=env, capture_output=True,
                                        text=True)
                windows = subprocess.run(['xdotool', 'search', '--class', '^rhun$'], env=env,
                                         capture_output=True, text=True)
                return result.returncode == 0 and result.stdout.strip() in windows.stdout.splitlines()

        control = work / 'control'
        editor = start([str(EXE), str(file), '--control', str(control)])
        until(control.exists, 'editor control socket did not appear')
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(15)
        client.connect(str(control))
        reader = client.makefile('r', encoding='utf-8')
        until(lambda: 'tabs=1' in command('print-state'), 'the file did not open')
        until(focused, 'the editor did not get the focus')

        if wayland:
            def method_line(seconds=10):
                ready, _, _ = select.select([method.stdout], [], [], seconds)
                return method.stdout.readline() if ready else ''

            def send(line):
                method.stdin.write(line + '\n')
                method.stdin.flush()
                reply = method_line()
                while reply in ('active\n', 'inactive\n'):
                    reply = method_line()
                assert reply == 'ok\n', (line, reply)
            assert method_line() == 'active\n', 'rhun did not enable its text input'
            send('preedit ㅎ')
            expect('composition', 'hello\n', 'ㅎ')
            send('preedit 하')
            expect('composition-grows', 'hello\n', '하')
            send('commit 한')
            expect('commit', '한hello\n', '')
            send('preedit 글')
            send('commit 글')
            send('commit é!')
            expect('commit-text', '한글é!hello\n', '')
        else:
            def xdotool(*args):
                output(['xdotool', *args])
            # 2-set layout: g k s is 한, r m f is 글
            xdotool('type', '--delay', '60', 'gks')
            expect('composition', 'hello\n', '한')
            xdotool('type', '--delay', '60', 'rmf')
            expect('commit-on-next-syllable', '한hello\n', '글')
            xdotool('key', '--delay', '60', 'space')
            expect('commit-and-space', '한글 hello\n', '')
            xdotool('type', '--delay', '60', 'a1')
            expect('jamo-then-digit', '한글 ㅁ1hello\n', '')
            # the input method quits: keys are rhun's again
            subprocess.run(['ibus', 'exit'], env=env, check=True)
            until(lambda: subprocess.run(['pgrep', '-x', 'ibus-x11'], capture_output=True).returncode,
                  'IBus did not quit')
            command('wait 300')
            xdotool('type', '--delay', '60', 'gk')
            expect('server-quit', '한글 ㅁ1gkhello\n', '')
        command('quit')
        editor.wait(timeout=10)
    except BaseException:
        for process, log in zip(processes, logs):
            log.flush()
            print('Process ' + str(process.args) + ':', file=sys.stderr)
            print(Path(log.name).read_text()[-4000:], file=sys.stderr)
        raise
    finally:
        if reader is not None:
            reader.close()
            client.close()
        for p in (method,):
            if p is not None and p.poll() is None:
                p.stdin.close()
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        if not wayland and 'bus_pid' in dir():
            try:
                os.kill(bus_pid, 15)
            except OSError:
                pass
        for log in logs:
            log.close()
