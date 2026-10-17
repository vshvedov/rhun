#!/usr/bin/env python3
"""Exercise the editor's embedded Windows updater and detached restart with local releases."""
import functools
import ctypes
from ctypes import wintypes
import hashlib
import http.server
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import zipfile

ROOT = Path(__file__).resolve().parent.parent
if os.name != 'nt':
    raise SystemExit('Run updater tests on Windows.')
CURRENT = (ROOT / 'VERSION').read_text().strip()
LATEST = '.'.join('9' * len(part) for part in CURRENT.split('.'))
assert len(LATEST) == len(CURRENT) and LATEST != CURRENT


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


with tempfile.TemporaryDirectory(prefix='rhun-update-') as temporary:
    # resolve(): the runner's TEMP is an 8.3 short path, but running editors report the long one
    temp = Path(temporary).resolve()
    portable = temp / "Portable café ' $ &" / 'rhun'
    portable.mkdir(parents=True)
    project = temp / "Project café ' $ &"
    project.mkdir()
    (project / 'example.txt').write_text('saved\n')
    personal = portable / 'personal.txt'
    personal.write_bytes(b'keep this')
    for name in ('rhun.exe', 'rhun.com', 'LICENSE', 'install.ps1'):
        source = ROOT / ('build/windows/' + name if name.startswith('rhun.') else name)
        shutil.copyfile(source, portable / name)
    original = (portable / 'rhun.exe').read_bytes()
    release = temp / 'releases/download' / ('v' + LATEST)
    release.mkdir(parents=True)
    latest = temp / 'releases/latest/download'
    latest.mkdir(parents=True)
    (latest / 'VERSION').write_text(LATEST + '\n')
    asset = f'rhun-{LATEST}-windows-x86_64.zip'
    with zipfile.ZipFile(release / asset, 'w', zipfile.ZIP_DEFLATED) as archive:
        for name in ('rhun.exe', 'rhun.com', 'LICENSE', 'install.ps1'):
            data = (portable / name).read_bytes()
            if name.startswith('rhun.'):
                # Change only the embedded version string for this synthetic release.
                assert data.count(CURRENT.encode() + b'\0') == 1
                data = data.replace(CURRENT.encode() + b'\0', LATEST.encode() + b'\0')
            archive.writestr(f'rhun-{LATEST}/{name}', data)
    digest = hashlib.sha256((release / asset).read_bytes()).hexdigest()
    checksums = release / 'SHA256SUMS'
    checksums.write_text(f'{digest}  {asset}\n')
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=temp))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ, XDG_CONFIG_HOME=str(temp / 'config'), XDG_STATE_HOME=str(temp / 'state'),
               RHUN_RELEASES_URL=f'http://127.0.0.1:{server.server_port}/releases',
               RHUN_UPDATE_TARGET=str(portable / 'rhun.com'))

    def run(name, lines, environment=env, cwd=None, paths=None, installation=portable):
        script = temp / (name + '.rsc')
        # UTF-8 as rhun reads it: the ANSI code page would garble the project's path
        script.write_text('\n'.join(lines) + '\n', encoding='utf-8')
        launch_paths = [project] if paths is None else paths
        return subprocess.run([str(installation / 'rhun.com'), *map(str, launch_paths), '--headless', '800x600',
                               '--script', str(script)], env=environment, cwd=cwd,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)

    def stages_gone(seconds=30):
        # the helper deletes a stage once its editor has exited
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if not list(portable.parent.glob('.rhun-update-*')):
                return True
            time.sleep(0.2)
        return False

    def restarted_window(installation, expected_name):
        deadline = time.monotonic() + 20
        ids = []
        while not ids and time.monotonic() < deadline:
            # The helper can be between the old process exiting and the new one starting.
            # PowerShell otherwise exits with status 1 when Get-Process finds no rhun.
            ids = subprocess.check_output(['powershell.exe', '-NoProfile', '-Command',
                "Get-Process -Name rhun -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $env:TEST_EXE } | Select-Object -ExpandProperty Id; exit 0"],
                env=dict(os.environ, TEST_EXE=str(installation / 'rhun.exe'))).split()
            if not ids:
                time.sleep(0.2)
        assert ids, 'updated editor did not restart'
        user = ctypes.WinDLL('user32', use_last_error=True)
        found = []
        callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
        user.EnumWindows.argtypes = [callback_type, wintypes.LPARAM]
        user.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
        user.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
        def inspect_window(window, _):
            owner = wintypes.DWORD()
            user.GetWindowThreadProcessId(window, ctypes.byref(owner))
            if owner.value in [int(value) for value in ids]:
                title = ctypes.create_unicode_buffer(4096)
                user.GetWindowTextW(window, title, len(title))
                if expected_name in title.value:
                    found.append(window)
            return True
        deadline = time.monotonic() + 10
        while not found and time.monotonic() < deadline:
            user.EnumWindows(callback_type(inspect_window), 0)
            if not found:
                time.sleep(0.1)
        assert found, 'updated editor did not reopen the requested path'
        return user, found[0], ids

    def adopted(output, folder):
        # print-project names the folder the files were opened from (the home folder as ~)
        for line in output.split(b'\n'):
            if line.startswith(b'project='):
                value = line[len(b'project='):].strip().decode('utf-8')
                return bool(value) and Path(value).expanduser().resolve() == Path(folder).resolve()
        return False

    def stop_restarted(ids):
        # a restarted editor may already have exited (taskkill: 128, no such process); any other
        # failure leaves it running and is an error
        for process_id in ids:
            result = subprocess.run(['taskkill', '/F', '/PID', process_id.decode()],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode not in (0, 128):
                raise AssertionError('taskkill %s: %d %s' % (process_id.decode(), result.returncode,
                                                             result.stderr.decode(errors='replace')))

    def standalone_restart(name, paths, before=(), after=(), expected=None):
        # Each scenario applies the same synthetic release to a fresh portable installation.
        installation = temp / (name + " portable café ' $ &") / 'rhun'
        installation.mkdir(parents=True)
        for filename in ('rhun.exe', 'rhun.com', 'LICENSE', 'install.ps1'):
            shutil.copyfile(portable / filename, installation / filename)
        restart_env = dict(env, RHUN_UPDATE_TARGET=str(installation / 'rhun.com'))
        result = run(name, [*check, 'cmd install_update', 'wait-update', 'print-update',
                     *before, 'cmd restart_to_update', *after], restart_env,
                     paths=paths, installation=installation)
        assert result.returncode == 0 and b'state=ready' in result.stdout, result.stdout
        reopened = list(paths) if expected is None else expected
        user, window, ids = restarted_window(installation, reopened[-1].name if reopened else 'rhûn')
        try:
            title = ctypes.create_unicode_buffer(4096)
            if reopened:
                user.GetForegroundWindow.restype = wintypes.HWND
                deadline = time.monotonic() + 2
                while user.GetForegroundWindow() != window and time.monotonic() < deadline:
                    time.sleep(0.03)
                assert user.GetForegroundWindow() == window, 'restarted standalone editor is not foreground'
                user.keybd_event.argtypes = [wintypes.BYTE, wintypes.BYTE, wintypes.DWORD, ctypes.c_size_t]
                # Cycle the native shortcut to verify every requested text or image tab, and no others.
                for file in reopened:
                    user.keybd_event(0x11, 0, 0, 0)
                    user.keybd_event(0x22, 0, 0, 0)
                    user.keybd_event(0x22, 0, 2, 0)
                    user.keybd_event(0x11, 0, 2, 0)
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline:
                        user.GetWindowTextW(window, title, len(title))
                        if file.name in title.value:
                            break
                        time.sleep(0.03)
                    # a file opened by itself brings its folder in as the project
                    assert file.name in title.value and title.value.endswith(reopened[0].parent.name), title.value
            else:
                user.GetWindowTextW(window, title, len(title))
                assert title.value == 'rhûn', f'empty restart restored a project or tab: {title.value}'
            reported = subprocess.check_output([str(installation / 'rhun.com'), '--version']).strip()
            assert reported == ('rhun ' + LATEST).encode(), reported
            assert marker.read_bytes() == remembered_project
            assert not list(installation.parent.glob('.rhun-update-*'))
        finally:
            stop_restarted(ids)

    check = ['cmd check_for_updates', 'wait-update']
    try:
        # Release CI builds opt into self-updating; development CI checks the source guard.
        if os.environ.get('RHUN_DIST') != '1':
            source_env = dict(env, RHUN_UPDATE_TARGET='')
            result = run('source', [*check, 'cmd install_update', 'wait-update', 'print-update'], source_env)
            assert result.returncode == 0 and b'state=idle' in result.stdout, result.stdout
            assert not list(portable.parent.glob('.rhun-update-*'))
            print('ok   update/source-build-does-not-replace-itself', flush=True)

        checksums.write_text(f'{"0" * 64}  {asset}\n')
        result = run('bad-checksum', [*check, 'cmd install_update', 'wait-update', 'print-update'])
        assert result.returncode == 0 and b'state=available' in result.stdout, result.stdout
        assert b'checksum does not match' in result.stdout, result.stdout
        assert (portable / 'rhun.exe').read_bytes() == original
        assert not list(portable.parent.glob('.rhun-update-*'))
        checksums.write_text(f'{digest}  {asset}\n')
        print('ok   update/editor-reports-failed-download', flush=True)

        # Cancel an unsaved-file prompt after preparation. The installation stays untouched.
        result = run('cancel', [*check, 'cmd install_update', 'wait-update', 'open ' + str(project / 'example.txt'),
                                'type changed', 'cmd restart_to_update', 'key Escape', 'print-update'])
        assert result.returncode == 0 and b'state=ready' in result.stdout, result.stdout
        assert f'desc={LATEST} is downloaded; restart to install it'.encode() in result.stdout, result.stdout
        assert (portable / 'rhun.exe').read_bytes() == original
        print('ok   update/cancel-restart-keeps-running-version', flush=True)
        # Quitting without the restart leaves no staged copy behind.
        assert stages_gone(), list(portable.parent.glob('.rhun-update-*'))
        assert (portable / 'rhun.exe').read_bytes() == original
        print('ok   update/quit-discards-staged-download', flush=True)

        standalone_directory = temp / "Standalone café ' $ &"
        standalone_directory.mkdir()
        standalone_files = [standalone_directory / "first café ' $ &.rb",
                            standalone_directory / 'second café % ; (value).rb']
        for file in standalone_files:
            file.write_bytes(b'puts :standalone\n')
        marker = temp / 'state/rhun/last-project'
        remembered_project = marker.read_bytes()
        result = run('standalone-cancel', [*check, 'cmd install_update', 'wait-update', 'type changed',
                     'cmd restart_to_update', 'key Escape', 'print-project', 'print-state', 'print-update'],
                     paths=standalone_files)
        assert result.returncode == 0 and b'state=ready' in result.stdout, result.stdout
        assert b'\ntabs=2 active=' + standalone_files[-1].name.encode() in result.stdout, result.stdout
        assert adopted(result.stdout, standalone_directory), result.stdout
        assert (portable / 'rhun.exe').read_bytes() == original
        assert marker.read_bytes() == remembered_project
        assert all(file.read_bytes() == b'puts :standalone\n' for file in standalone_files)
        assert stages_gone(), list(portable.parent.glob('.rhun-update-*'))
        print('ok   update/standalone-tabs-prepare-cancel-and-discard', flush=True)

        result = run('standalone-empty', ['cmd close_tab', 'cmd close_tab', *check, 'cmd install_update',
                     'wait-update', 'print-project', 'print-state', 'print-update'], paths=standalone_files)
        assert result.returncode == 0 and b'state=ready' in result.stdout, result.stdout
        assert b'\ntabs=0 ' in result.stdout and adopted(result.stdout, standalone_directory), result.stdout
        assert marker.read_bytes() == remembered_project
        assert stages_gone(), list(portable.parent.glob('.rhun-update-*'))
        print('ok   update/standalone-empty-window-prepare-and-discard', flush=True)

        # Preparing removes what crashed or interrupted editors left (a stage whose process is gone,
        # an hour-old swap) and keeps a recent one, which may be another installer's.
        stale = portable.parent / '.rhun-update-999999999'
        (stale / 'backup').mkdir(parents=True)
        (stale / 'update.json').write_text('{}')
        old_swap = portable.parent / ('.rhun-stage-' + 'a' * 32)
        new_swap = portable.parent / ('.rhun-stage-' + 'b' * 32)
        old_swap.mkdir()
        new_swap.mkdir()
        hour_ago = time.time() - 7200
        os.utime(old_swap, (hour_ago, hour_ago))
        # Programs are found on PATH only, never in the working directory: a project there could
        # plant powershell.exe. This one would leave a mark.
        planted = temp / 'planted'
        planted.mkdir()
        mark = temp / 'planted-ran.txt'
        source = ('public static class P { public static void Main() { System.IO.File.WriteAllText('
                  'System.Environment.GetEnvironmentVariable("PLANTED_MARK"), "ran"); } }')
        subprocess.run([os.path.join(os.environ['SystemRoot'], r'System32\WindowsPowerShell\v1.0\powershell.exe'),
                        '-NoProfile', '-Command',
                        'Add-Type -TypeDefinition $env:SOURCE -OutputAssembly $env:OUT -OutputType ConsoleApplication'],
                       env=dict(os.environ, SOURCE=source, OUT=str(planted / 'powershell.exe')),
                       check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        assert (planted / 'powershell.exe').exists()
        result = run('stale', [*check, 'cmd install_update', 'wait-update', 'print-update'],
                     dict(env, PLANTED_MARK=str(mark)), cwd=planted)
        assert result.returncode == 0 and b'state=ready' in result.stdout, result.stdout
        assert not mark.exists(), 'a powershell.exe in the working directory ran'
        assert not stale.exists() and not old_swap.exists() and new_swap.exists()
        shutil.rmtree(new_swap)
        assert stages_gone()
        print('ok   update/prepare-removes-stale-stages', flush=True)
        print('ok   update/programs-come-from-path-only', flush=True)

        standalone_restart('standalone-restart', standalone_files, before=['type saved_'], after=['key Return'])
        assert standalone_files[-1].read_bytes() == b'saved_puts :standalone\n'
        print('ok   update/standalone-tabs-detached-restart', flush=True)

        standalone_restart('empty-restart', standalone_files,
                           before=['cmd close_tab', 'cmd close_tab'], expected=[])
        print('ok   update/standalone-empty-window-detached-restart', flush=True)

        image = standalone_directory / "image café ' $ &.png"
        image.write_bytes((ROOT / 'tests/data/images/rgba.png').read_bytes())
        image_bytes = image.read_bytes()
        standalone_restart('image-restart', [image])
        assert image.read_bytes() == image_bytes
        print('ok   update/standalone-image-detached-restart', flush=True)

        standalone_restart('mixed-restart', [standalone_files[0], image, standalone_files[-1]])
        assert image.read_bytes() == image_bytes
        print('ok   update/standalone-mixed-tabs-detached-restart', flush=True)

        result = run('restart', [*check, 'cmd install_update', 'wait-update', 'print-update',
                                 'cmd restart_to_update'])
        assert result.returncode == 0 and b'state=ready' in result.stdout, result.stdout
        # The detached helper waits for the old process, applies, then opens the GUI sibling.
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                if (portable / 'rhun.exe').read_bytes() != original and not list(portable.parent.glob('.rhun-update-*')):
                    break
            except (FileNotFoundError, PermissionError):
                pass  # The old file has been moved aside and its replacement is next, or is being written.
            time.sleep(0.1)
        else:
            raise AssertionError('detached updater did not install the release')
        reported = subprocess.check_output([str(portable / 'rhun.com'), '--version']).strip()
        assert reported == ('rhun ' + LATEST).encode(), reported
        assert personal.read_bytes() == b'keep this'
        assert not (portable / '.rhun-install').exists(), 'portable update registered an installation'
        # Read the native title to verify the original project reopened after restart.
        _, _, ids = restarted_window(portable, project.name)
        stop_restarted(ids)
        print('ok   update/detached-apply-version-and-restart', flush=True)
    finally:
        # Kill any surviving recovery dialog or editor before TemporaryDirectory removes PE files.
        subprocess.run(['powershell.exe', '-NoProfile', '-Command',
            "Get-Process -Name rhun,rhun.com -ErrorAction SilentlyContinue | Where-Object { $_.Path -like ($env:TEST_DIR + '*') } | Stop-Process -Force"],
            env=dict(os.environ, TEST_DIR=str(temp)), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        server.shutdown()
        server.server_close()
