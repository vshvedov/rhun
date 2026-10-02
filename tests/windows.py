#!/usr/bin/env python3
"""Native Windows test gate. --wine runs the compatible subset on Linux for development."""
import argparse
import ctypes
from ctypes import wintypes
import os
import json
from pathlib import Path
import re
import shutil
import subprocess
import struct
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
os.chdir(ROOT)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--wine', metavar='WINE64')
args = parser.parse_args()
if os.name != 'nt' and not args.wine:
    parser.error('run on Windows, or supply --wine for the compatibility checks')
runner = [args.wine] if args.wine else []
OUT = ROOT / 'build/windows'
failures = []


def winpath(path):
    value = os.path.abspath(path).replace('\\', '/')
    return 'Z:' + value if args.wine else value


def command(exe, *arguments):
    return [*runner, str(OUT / exe), *map(str, arguments)]


def run(exe, *arguments, env=None, success=True, timeout=30):
    result = subprocess.run(command(exe, *arguments), stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, env=env, timeout=timeout)
    if success and result.returncode:
        raise AssertionError(f'{exe} exited {result.returncode}: {result.stdout.decode(errors="replace")}')
    return result


def check(name, fn):
    try:
        fn()
        print('ok   ' + name, flush=True)
    except Exception as error:
        failures.append(name)
        print(f'FAIL {name}: {error}', flush=True)


def equal(actual, expected):
    if actual != expected:
        raise AssertionError(f'expected {expected[:500]!r}, got {actual[:500]!r}')


with tempfile.TemporaryDirectory(prefix='rhun-windows-', dir=OUT) as temporary:
    temp = Path(temporary)

    def environment(name):
        env = dict(os.environ)
        home = temp / name / 'home'
        home.mkdir(parents=True, exist_ok=True)
        env.update(XDG_CONFIG_HOME=winpath(temp / name / 'config'),
                   XDG_STATE_HOME=winpath(temp / name / 'state'),
                   XCOMPOSEFILE=winpath(ROOT / 'tests/data/compose.txt'),
                   XCURSOR_PATH='tests/data/icons', XCURSOR_THEME='child',
                   WINEDEBUG='-all')
        if not args.wine:
            env['HOME'] = winpath(home)
        return env

    def golden(name, exe, arguments=()):
        env = environment(name)
        if name in ('grammars', 'themes'):
            env['XDG_CONFIG_HOME'] = winpath(ROOT / 'tests/data/config')
        if name == 'config':
            env['XDG_CONFIG_HOME'] = winpath(ROOT / 'tests/data/config-reload')
        equal(run(exe + '.exe', *arguments, env=env).stdout,
              (ROOT / 'tests/data' / (name + '.expected')).read_bytes())

    for name, exe in [('cpu', 'cpu'), ('doc', 'doc'), ('syntax', 'syntax'), ('themes', 'theme'),
                      ('term', 'term'), ('diff', 'diff'), ('cols', 'cols'), ('config', 'config')]:
        check(name, lambda name=name, exe=exe: golden(name, exe + '_test'))
    for name, exe, file in [('strfind', 'str', 'strfind'), ('versions', 'update', 'versions'),
                            ('keymap-names-us-ru', 'xkb', 'keymap-names-us-ru'),
                            ('keymap-gnome-us', 'xkb', 'keymap-gnome-us'),
                            ('keymap-pl-intl', 'xkb', 'keymap-pl-intl')]:
        check(name, lambda name=name, exe=exe, file=file:
              golden(name, exe + '_test', ['tests/data/' + file + '.txt']))
    check('images', lambda: golden('images', 'image_test',
                                  sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / 'tests/data/images').iterdir())))
    check('grammars', lambda: golden('grammars', 'grammar_test',
                                     ['tests/data/detect.txt', 'tests/data/samples']))
    check('prefix-tag', lambda: golden('prefix-tag', 'grammar_test',
                                       ['--try', 'tests/data/prefix-tag.syn', 'tests/data/prefix-tag.txt']))
    check('version', lambda: equal(run('rhun.com', '--version').stdout,
                                  b'rhun ' + (ROOT / 'VERSION').read_bytes().strip() + b'\n'))
    check('input/right-alt-and-altgr', lambda: run('input_test.exe'))
    if not args.wine:
        check('desktop/startup', lambda: subprocess.run(
            [sys.executable, str(ROOT / 'tests/desktop-ux.py')], check=True,
            env=dict(os.environ, RHUN_TEST_EXE=str(OUT / 'rhun.com'))))
        check('ui/palette-scroll', lambda: subprocess.run(
            [sys.executable, str(ROOT / 'tests/palette-scroll.py')], check=True,
            env=dict(os.environ, RHUN_TEST_EXE=str(OUT / 'rhun.com'))))
        check('theme/chrome', lambda: subprocess.run(
            [sys.executable, str(ROOT / 'tests/theme-chrome.py')], check=True,
            env=dict(os.environ, RHUN_TEST_EXE=str(OUT / 'rhun.com'))))

    def ui(name):
        result = run('rhun.com', winpath(ROOT), '--headless', '1400x860', '--script',
                     'tests/scripts/' + name + '.rsc', env=environment('ui-' + name))
        equal(result.stdout, (ROOT / 'tests/data' / (name + '.ui.expected')).read_bytes())

    for name in ['editing', 'clipboard', 'movelines', 'find', 'replace', 'tabs', 'vim', 'wrap', 'togglecomment',
                 'highlight', 'image', 'mouse', 'cursor', 'compose', 'contextmenu',
                 'titlebar', 'titlebar-tap']:
        check('ui/' + name, lambda name=name: ui(name))

    def roots():
        source = temp / 'paths.txt'
        paths = ['C:/', 'C:/a/../', 'C:/a/../../b', r'C:\a\..\b',
                 '//server/share/', '//server/share/a/../../b', '//server/share/a/../',
                 'C:/a//./b/../c', 'relative/../path']
        source.write_text('\n'.join(paths) + '\n', encoding='utf-8', newline='\n')
        equal(run('path_test.exe', winpath(source)).stdout,
              b'C:/\nC:/\nC:/b\nC:/b\n//server/share/\n//server/share/b\n//server/share/\nC:/a/c\nrelative/../path\n')
    check('paths/drive-and-unc', roots)

    def files():
        folder = temp / 'spaces café 日本'
        folder.mkdir()
        file = folder / 'file café 日本.txt'
        file.write_bytes(b'original\n')
        run('file_test.exe', 'write', winpath(file))
        equal(file.read_bytes(), b'saved\n')
        run('file_test.exe', 'write', winpath(folder / 'new.txt'))
        equal((folder / 'new.txt').read_bytes(), b'saved\n')
        result = run('file_test.exe', 'write', winpath(folder), success=False)
        assert result.returncode != 0 and folder.is_dir()
        equal(run('file_test.exe', 'error', winpath(folder)).stdout, b'21\n')
        equal(run('file_test.exe', 'error', winpath(folder / 'missing')).stdout, b'2\n')
        source = folder / 'crlf.txt'
        replacement = folder / 'replacement.txt'
        source.write_bytes(b'before\r\n')
        replacement.write_bytes(b'a\rb\r\nc\r\n')
        equal(run('file_test.exe', 'reload', winpath(source), winpath(replacement)).stdout, b'a\rb\nc\n')
        equal(source.read_bytes(), replacement.read_bytes())
        source.write_bytes(b'before\r\n')
        replacement.write_bytes(b'binary\0data\r\n')
        equal(run('file_test.exe', 'reload-binary', winpath(source), winpath(replacement)).stdout, b'before\n')
        equal(source.read_bytes(), replacement.read_bytes())
        long_file = folder / ('x' * 251 + '.txt')
        long_file.write_bytes(b'original\n')
        run('file_test.exe', 'write', winpath(long_file))
        equal(long_file.read_bytes(), b'saved\n')
        assert not list(folder.glob('.rhun-backup-*')), 'recovery directory left after successful save'
        assert not list(folder.glob('.rhun-*.tmp')), 'temporary file left after save'
    check('files/unicode-crlf-replacement', files)

    def readonly():
        file = temp / 'readonly.txt'
        file.write_bytes(b'original\n')
        os.chmod(file, 0o444)
        try:
            assert run('file_test.exe', 'write', winpath(file), success=False).returncode != 0
            equal(file.read_bytes(), b'original\n')
        finally:
            os.chmod(file, 0o666)
    if not args.wine:
        check('files/readonly', readonly)

    def sharing():
        file = temp / 'locked.txt'
        file.write_bytes(b'original\n')
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                      ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
        kernel.CreateFileW.restype = wintypes.HANDLE
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        handle = kernel.CreateFileW(str(file), 0x80000000, 1, None, 3, 0, None)
        assert handle != ctypes.c_void_p(-1).value
        try:
            assert run('file_test.exe', 'write', winpath(file), success=False).returncode != 0
            equal(file.read_bytes(), b'original\n')
        finally:
            kernel.CloseHandle(handle)
        assert not list(temp.glob('.rhun-backup-*'))
    if not args.wine:
        check('files/sharing-violation', sharing)

    def symlinks():
        target = temp / 'link-target.txt'
        target.write_bytes(b'original\n')
        link = temp / 'link.txt'
        os.symlink(target, link)
        equal(run('platform_test.exe', 'link', winpath(link)).stdout, (winpath(target) + '\n').encode())
        run('file_test.exe', 'write', winpath(link))
        assert link.is_symlink(), 'saving replaced the symlink itself'
        equal(target.read_bytes(), b'saved\n')
        dangling = temp / 'dangling.txt'
        os.symlink(temp / 'absent-target.txt', dangling)
        assert run('platform_test.exe', 'link', winpath(dangling), success=False).returncode != 0, 'dangling symlink unexpectedly resolved'
        assert run('file_test.exe', 'write', winpath(dangling), success=False).returncode != 0, 'saving a dangling symlink succeeded'
        assert dangling.is_symlink(), 'saving replaced the dangling symlink itself'
    if not args.wine:
        check('files/symlinks', symlinks)

    check('process/arguments-and-environment', lambda: equal(
        run('platform_test.exe', 'spawn', env=environment('process')).stdout,
        '\ntwo words\na\\"b\\\ncafé 日本\nspace and é\n'.encode()))

    def fonts():
        # A collection stores sfnt directories at an offset, but table offsets remain file-relative.
        ttf = bytearray((ROOT / 'assets/fonts/IosevkaFixed-Regular.ttf').read_bytes())
        count = struct.unpack_from('>H', ttf, 4)[0]
        for index in range(count):
            position = 12 + index * 16 + 8
            offset = struct.unpack_from('>I', ttf, position)[0]
            struct.pack_into('>I', ttf, position, offset + 16)
        ttc = temp / 'collection.ttc'
        ttc.write_bytes(b'ttcf' + struct.pack('>III', 0x10000, 1, 16) + ttf)
        run('platform_test.exe', 'font', winpath(ttc))
        ttc.write_bytes(b'ttcf' + struct.pack('>III', 0x10000, 1, 0xffffffff))
        assert run('platform_test.exe', 'font', winpath(ttc), success=False).returncode != 0
        if not args.wine:
            for name in ['msgothic.ttc', 'msyh.ttc']:
                path = Path(os.environ['SystemRoot']) / 'Fonts' / name
                if path.exists():
                    run('platform_test.exe', 'font', path, 'cjk')
    check('fonts/collection-and-invalid-offset', fonts)

    def terminal(mode, marker):
        # The helper allows 30s for the prompt, then 10s each for command output and exit.
        result = run('platform_test.exe', mode, env=environment('terminal-' + mode), timeout=60)
        assert marker in result.stdout, result.stdout
    if not args.wine:
        check('terminal/conpty-cmd-create-resize-output-close', lambda: terminal('pty', b'RHUN_CONPTY_OK'))
        check('terminal/conpty-powershell-input-output-close', lambda: terminal('pty-input', b'RHUN_INPUT_OK'))
        check('terminal/conpty-powershell-slow-start', lambda: terminal('pty-input-slow-start', b'RHUN_INPUT_OK'))

    def script_file(name, text):
        path = temp / (name + '.rsc')
        path.write_text(text, encoding='utf-8', newline='\n')
        return winpath(path)

    def session():
        project = temp / 'project space % café'
        project.mkdir()
        file = project / 'hello.txt'
        file.write_bytes(b'hello\r\n')
        env = environment('session')
        first = script_file('session-save', 'key End\ntype !\ncmd save\nprint-state\nquit\n')
        run('rhun.com', winpath(project), winpath(file), '--headless', '1000x700', '--script', first, env=env)
        equal(file.read_bytes(), b'hello!\r\n')
        second = script_file('session-restore', 'print-state\nprint-doc\nquit\n')
        out = run('rhun.com', winpath(project), '--headless', '1000x700', '--script', second, env=env).stdout
        assert b'active=hello.txt' in out and b'hello!\n' in out, out
    check('session/drive-unicode-percent-roundtrip', session)

    def path_prompts():
        project = temp / 'path prompts'
        project.mkdir()
        file = project / 'nested' / 'café.txt'
        windows_path = winpath(file).replace('/', '\\')
        script = script_file('path-prompts',
            f'cmd new_file\ntype saved Ω\ncmd save_as\nkey ctrl+a\ntype {windows_path}\nkey Return\n'
            f'cmd close_tab\ncmd open_file\nkey ctrl+a\ntype {windows_path}\nkey Return\nprint-doc\nquit\n')
        output = run('rhun.com', winpath(project), '--headless', '1000x700', '--script', script,
                     env=environment('prompts')).stdout
        equal(file.read_bytes(), 'saved Ω\n'.encode())
        assert 'saved Ω'.encode() in output, output
    check('paths/backslash-save-as-and-open', path_prompts)

    def control():
        result = run('rhun.com', '--headless', '800x600', '--control', winpath(temp / 'control'), success=False,
                     env=environment('control'))
        assert result.returncode != 0 and b'--script' in result.stdout, result.stdout
    check('control/explicit-unsupported-error', control)

    def crlf_script():
        script = temp / 'crlf-script.rsc'
        script.write_bytes(b'cmd new_file\r\ntype Windows script\r\nprint-doc\r\nquit\r\n')
        output = run('rhun.com', '--headless', '800x600', '--script', winpath(script),
                     env=environment('crlf-script')).stdout
        equal(output, b'Windows script\n<eod>\n')
    check('script/crlf-line-endings', crlf_script)

    def watcher():
        project = temp / 'watched project'
        project.mkdir()
        file = project / 'watched.txt'
        file.write_bytes(b'before\n')
        script = script_file('watch', f'open {winpath(file).upper()}\nprint-state\nwait 1600\nprint-doc\nquit\n')
        process = subprocess.Popen(command('rhun.com', winpath(project), winpath(file), '--headless',
                                           '1000x700', '--script', script), stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, env=environment('watch'))
        try:
            # The first state line is emitted after the document and its watch are installed.
            first = []
            reader = threading.Thread(target=lambda: first.append(process.stdout.readline()), daemon=True)
            reader.start()
            reader.join(timeout=10)
            assert first and b'tabs=1 active=' in first[0], 'duplicate tab or document did not become ready'
            replacement = project / 'replacement.txt'
            replacement.write_bytes('after café\n'.encode())
            os.replace(replacement, file)
            output = process.communicate(timeout=15)[0]
            assert process.returncode == 0 and b'after caf' in output, output
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
    check('watch/mixed-case-dedup-and-atomic-replacement', watcher)

    def agents():
        env = environment('agents')
        home = Path(env['HOME'])
        project = temp / 'agent project'
        project.mkdir()
        slug = re.sub('[^A-Za-z0-9]', '-', winpath(project))
        claude = home / '.claude/projects' / slug / 's1.jsonl'
        codex = home / '.codex/sessions/2026/09/26/rollout-c1.jsonl'
        for path in [claude, codex]:
            path.parent.mkdir(parents=True, exist_ok=True)
        claude.write_text((ROOT / 'tests/data/agents/claude.jsonl').read_text(encoding='utf-8').replace('@PROJECT@', winpath(project)), encoding='utf-8')
        spelling = winpath(project).replace('/', '\\').upper()
        codex.write_text((ROOT / 'tests/data/agents/codex.jsonl').read_text(encoding='utf-8').replace('@PROJECT@', json.dumps(spelling)[1:-1]), encoding='utf-8')
        os.utime(claude, (1700000000, 1700000000))
        os.utime(codex, (1700000100, 1700000100))
        output = run('rhun.com', winpath(project), '--headless', '1400x860', '--script',
                     'tests/scripts/agents.rsc', env=env).stdout
        equal(output, (ROOT / 'tests/data/agents.ui.expected').read_bytes())

    def git():
        project = temp / 'git project café'
        project.mkdir()
        def command(*arguments):
            subprocess.run(['git', '-C', str(project), *arguments], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        command('init', '-b', 'main')
        command('config', 'user.name', 'Test')
        command('config', 'user.email', 'test@example.invalid')
        command('config', 'core.autocrlf', 'false')
        file = project / 'a.txt'
        file.write_bytes(b'before\n')
        command('add', 'a.txt')
        command('commit', '-m', 'Initial')
        file.write_bytes(b'after\n')
        script = script_file('git', 'wait-git\nprint-git\ncmd git_changes\nwait-git\nprint-doc\nquit\n')
        output = run('rhun.com', winpath(project), winpath(file), '--headless', '1000x700', '--script', script,
                     env=environment('git')).stdout
        assert b'git on branch=main\nM a.txt' in output and b'before\nafter\n' in output, output
    if not args.wine:
        check('agents/windows-session-paths', agents)
        check('git/status-and-diff', git)

    def commit_ai(provider, cancel=False):
        name = 'commit-ai-' + provider + ('-cancel' if cancel else '')
        project = temp / (name + " 'quoted $; café")
        project.mkdir()
        for arguments in [('init', '-b', 'main'), ('config', 'user.name', 'Test'),
                          ('config', 'user.email', 'test@example.invalid')]:
            subprocess.run(['git', '-C', str(project), *arguments], check=True, capture_output=True)
        (project / 'new.txt').write_text('new content\n', encoding='utf-8')
        env = environment(name)
        config = temp / name / 'config/rhun'
        config.mkdir(parents=True)
        (config / 'config').write_text('[git]\ncommit_ai = ' + provider + '\n', encoding='utf-8')
        bindir = temp / name / 'bin'
        bindir.mkdir()
        shutil.copy2(OUT / 'ai_cli_test.exe', bindir / (provider + '.exe'))
        env['PATH'] = str(bindir.resolve()) + ';' + env['PATH']
        env['OPENAI_API_KEY'] = 'must-not-be-used'
        lines = 'wait-git\nwait-ai\ncmd git_generate_message\n'
        if cancel:
            env['RHUN_AI_TEST_DELAY'] = '1'
            lines += 'wait 500\ncmd ai_cancel\n'
        lines += 'wait-ai\nprint-scm\nprint-ai\n'
        output = run('rhun.com', winpath(project), '--headless', '1400x860', '--script',
                     script_file(name, lines), env=env, timeout=40).stdout
        if cancel:
            assert b'Describe Windows changes' not in output and b'Cancelled' in output, output
        else:
            assert b'message=Describe Windows changes' in output, output

    if not args.wine:
        for provider in ('claude', 'codex'):
            check('ai/' + provider + '-subscription-cli', lambda provider=provider: commit_ai(provider))
        check('ai/cancel', lambda: commit_ai('claude', cancel=True))
        check('ai/local-model-protocol', lambda: subprocess.run(
            [sys.executable, str(ROOT / 'tests/commit-ai-windows.py')], check=True))

    def native_window():
        project = temp / 'native window'
        project.mkdir()
        file = project / 'input.txt'
        file.write_bytes(b'native\n')
        screenshot = temp / 'window.ppm'
        script = script_file('window', 'print-state\nwait 2500\ncmd select_all\ncmd copy\n'
                             'key ctrl+End\ncmd paste\ncmd save\n'
                             f'shot {winpath(screenshot)}\nprint-doc\nquit\n')
        process = subprocess.Popen(command('rhun.exe', winpath(project), winpath(file), '--script', script),
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=environment('window'))
        user = ctypes.WinDLL('user32', use_last_error=True)
        callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
        user.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
        user.SendMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
        user.SendMessageW.restype = wintypes.LPARAM
        found = []
        @callback_type
        def enum(window, unused):
            pid = wintypes.DWORD()
            user.GetWindowThreadProcessId(window, ctypes.byref(pid))
            if pid.value == process.pid:
                found.append(window)
            return True
        try:
            first = []
            reader = threading.Thread(target=lambda: first.append(process.stdout.readline()), daemon=True)
            reader.start()
            reader.join(timeout=10)
            assert first and b'active=input.txt' in first[0], 'document did not become ready'
            deadline = time.monotonic() + 2
            while not found and time.monotonic() < deadline:
                user.EnumWindows(enum, 0)
                time.sleep(0.03)
            assert found, 'native window did not appear'
            # Input goes through the real window procedure and UTF-16 surrogate handling.
            for code in [ord('Ω'), 0xD83D, 0xDE00]:
                user.SendMessageW(found[0], 0x102, code, 0)
            output = process.communicate(timeout=15)[0]
            assert process.returncode == 0, output
            equal(file.read_bytes(), 'Ω😀native\nΩ😀native\n'.encode())
            pixels = screenshot.read_bytes()
            assert pixels.startswith(b'P6\n') and len(set(pixels[100:])) > 16, 'window did not render'
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
    if not args.wine:
        check('window/unicode-input-clipboard-save-and-render', native_window)
    else:
        print('skip native readonly, sharing, symlinks, ConPTY and desktop tests under Wine', flush=True)

if failures:
    print('Failed: ' + ', '.join(failures), file=sys.stderr)
    raise SystemExit(1)
