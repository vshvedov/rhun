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


def same_folder(line, folder):
    # print-project's line names the folder; a file opened by itself brings its folder in as the
    # project (the home folder as ~). TEMP can be an 8.3 short path while rhun reports the long one.
    assert line.startswith(b'project='), line
    value = line[len(b'project='):].strip().decode('utf-8')
    assert value and Path(value).expanduser().resolve() == Path(folder).resolve(), (value, folder)


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
        if name == 'grammars':
            env['XDG_CONFIG_HOME'] = winpath(ROOT / 'tests/data/config')
        if name == 'config':
            env['XDG_CONFIG_HOME'] = winpath(ROOT / 'tests/data/config-reload')
        equal(run(exe + '.exe', *arguments, env=env).stdout,
              (ROOT / 'tests/data' / (name + '.expected')).read_bytes())

    for name, exe in [('cpu', 'cpu'), ('doc', 'doc'), ('syntax', 'syntax'), ('themes', 'theme'),
                      ('term', 'term'), ('diff', 'diff'), ('cols', 'cols'), ('config', 'config'),
                      ('textarea', 'textarea'), ('ui-clip', 'ui_clip'), ('keys', 'keys'), ('config-strings', 'config_strings')]:
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
    check('input/wheel-and-touchpad-steps', lambda: run('wheel_test.exe'))
    if not args.wine:
        check('files/long-paths', lambda: subprocess.run(
            [sys.executable, str(ROOT / 'tests/windows-longpaths.py')], check=True))
        check('clipboard/contention-copy-and-paste', lambda: subprocess.run(
            [sys.executable, str(ROOT / 'tests/windows-clipboard.py')], check=True))
        for name in ('settings-ui', 'appearance', 'editor-matrix', 'stress', 'splitter', 'scroll-sensitivity',
                     'file-launch', 'readonly-save'):
            check('ui/' + name, lambda name=name: subprocess.run(
                [sys.executable, str(ROOT / ('tests/' + name + '.py'))], check=True,
                env=dict(os.environ, RHUN_TEST_EXE=str(OUT / 'rhun.com'))))
        check('desktop/startup', lambda: subprocess.run(
            [sys.executable, str(ROOT / 'tests/desktop-ux.py')], check=True,
            env=dict(os.environ, RHUN_TEST_EXE=str(OUT / 'rhun.com'))))
        check('ui/palette-scroll', lambda: subprocess.run(
            [sys.executable, str(ROOT / 'tests/palette-scroll.py')], check=True,
            env=dict(os.environ, RHUN_TEST_EXE=str(OUT / 'rhun.com'))))
        check('ui/commit-wrap', lambda: subprocess.run(
            [sys.executable, str(ROOT / 'tests/commit-wrap.py')], check=True,
            env=dict(os.environ, RHUN_TEST_EXE=str(OUT / 'rhun.com'))))
        check('git/untracked-refresh', lambda: subprocess.run(
            [sys.executable, str(ROOT / 'tests/git-untracked.py')], check=True,
            env=dict(os.environ, RHUN_TEST_EXE=str(OUT / 'rhun.com'))))
        check('ui/terminal-tabs', lambda: subprocess.run(
            [sys.executable, str(ROOT / 'tests/terminal-tabs.py')], check=True,
            env=dict(os.environ, RHUN_TEST_EXE=str(OUT / 'rhun.com'))))
        check('ui/focused-zoom', lambda: subprocess.run(
            [sys.executable, str(ROOT / 'tests/focused-zoom.py')], check=True,
            env=dict(os.environ, RHUN_TEST_EXE=str(OUT / 'rhun.com'))))
        check('agents/metadata', lambda: subprocess.run(
            [sys.executable, str(ROOT / 'tests/agents.py')], check=True,
            env=dict(os.environ, RHUN_TEST_EXE=str(OUT / 'rhun.com'))))
        check('explorer/create', lambda: subprocess.run(
            [sys.executable, str(ROOT / 'tests/explorer-create.py')], check=True,
            env=dict(os.environ, RHUN_TEST_EXE=str(OUT / 'rhun.com'))))

    def ui(name):
        result = run('rhun.com', winpath(ROOT), '--headless', '1400x860', '--script',
                     'tests/scripts/' + name + '.rsc', env=environment('ui-' + name))
        equal(result.stdout, (ROOT / 'tests/data' / (name + '.ui.expected')).read_bytes())

    for name in ['editing', 'clipboard', 'movelines', 'find', 'findcase', 'replace', 'tabs', 'reopen', 'vim', 'wrap', 'togglecomment',
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
        # Access the fixture independently of the runner's LongPathsEnabled policy.
        # The editor still receives the ordinary path and must handle its length.
        fixture_path = long_file if args.wine else Path('\\\\?\\' + str(long_file.resolve()))
        try:
            fixture_path.write_bytes(b'original\n')
            run('file_test.exe', 'write', winpath(long_file))
            equal(fixture_path.read_bytes(), b'saved\n')
        finally:
            fixture_path.unlink(missing_ok=True)
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

    def cls_keeps_prompt():
        # The pseudoconsole is created at 80x24 and resized to the panel before its first output;
        # if that resize is lost, cls repaints 24 rows into the smaller grid and the prompt scrolls away.
        project = temp / 'cls'
        project.mkdir()
        env = environment('cls')
        config = temp / 'cls' / 'config' / 'rhun' / 'config'
        config.parent.mkdir(parents=True)
        config.write_text('[terminal]\nshell = C:/Windows/System32/cmd.exe\n'
                          '[updates]\ncheck = false\n[git]\nenabled = false\n', encoding='utf-8')
        script = script_file('cls', 'cmd new_terminal\nwait 3000\ntype echo before\nkey Return\nwait 1500\n'
                                    'type cls\nkey Return\nwait 3000\nprint-term\nquit\n')
        out = run('rhun.com', winpath(project), '--headless', '1000x700', '--script', script, env=env).stdout
        screen = out.decode('utf-8', 'replace').splitlines()
        assert b'before' not in out, out
        assert any(line.rstrip().endswith('>') for line in screen[:3]), out
    if not args.wine:
        check('terminal/cls-keeps-prompt', cls_keeps_prompt)

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

    def shift_wheel():
        # Shift turns the editor's wheel sideways, as in other Windows apps (discussion 67)
        project = temp / 'shift wheel'
        project.mkdir()
        wide = project / 'wide.txt'
        wide.write_text(''.join(f'line {i:02d} ' + 'wide ' * 60 + '\n' for i in range(80)),
                        encoding='utf-8', newline='\n')
        script = script_file('shift-wheel', 'move 500 350\nscroll 120 shift\nwait 50\nprint-scroll\n'
                                            'scroll 120\nwait 50\nprint-scroll\nquit\n')
        output = run('rhun.com', winpath(project), winpath(wide), '--headless', '1000x700', '--script',
                     script, env=environment('shift-wheel')).stdout.decode()
        sideways, down = [line.split()[:2] for line in output.splitlines() if line.startswith('x=')]
        assert sideways == ['x=120', 'y=0'], output
        assert down[0] == 'x=120' and down[1] != 'y=0', output
    check('wheel/shift-scrolls-sideways', shift_wheel)

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

    def follow(name, open_path, steps):
        """Opens open_path, then runs each step (a function) once the editor shows what the step before
        it expects; each step returns the text it should then show."""
        project = temp / name
        script = script_file(name, f'open {winpath(open_path)}\nprint-state\n' +
                             'wait 150\nprint-doc\n' * 120 + 'quit\n')
        process = subprocess.Popen(command('rhun.com', winpath(project), winpath(open_path), '--headless',
                                           '1000x700', '--script', script), stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, env=environment(name))

        def documents():
            text = b''
            for line in process.stdout:
                line = line.replace(b'\r\n', b'\n')
                if line == b'<eod>\n':
                    yield text.removesuffix(b'\n')
                    text = b''
                else:
                    text += line
        try:
            first = process.stdout.readline()
            assert b'tabs=1 active=' in first, first
            shown = documents()
            for step in steps:
                expected = step()
                last = None
                for last in shown:
                    if last == expected:
                        break
                else:
                    raise AssertionError(f'never showed {expected!r}, last {last!r}')
        finally:
            process.kill()
            process.wait()

    def folder_made_again():
        sub = temp / 'remade' / 'sub' / 'deeper'
        sub.mkdir(parents=True)
        note = sub / 'note.txt'
        note.write_bytes(b'before\n')

        def remade():
            note.unlink()
            sub.rmdir()
            sub.mkdir()
            note.write_bytes(b'after\n')
            return b'after\n'

        def written():
            note.write_bytes(b'again\n')
            return b'again\n'

        def both_levels():
            shutil.rmtree(temp / 'remade' / 'sub')
            time.sleep(0.5)
            (temp / 'remade' / 'sub').mkdir()
            time.sleep(0.5)
            sub.mkdir()
            time.sleep(0.5)
            note.write_bytes(b'third\n')
            return b'third\n'
        follow('remade', note, [remade, written, both_levels])
    check('watch/folder-made-again', folder_made_again)

    def symlink_elsewhere():
        project = temp / 'linked'
        elsewhere = temp / 'linked-elsewhere'
        project.mkdir()
        elsewhere.mkdir()
        real = elsewhere / 'real.txt'
        real.write_bytes(b'before\n')
        link = project / 'link.txt'
        os.symlink(real, link)

        def written():
            real.write_bytes(b'written\n')
            return b'written\n'

        def replaced():
            replacement = elsewhere / 'replacement.tmp'
            replacement.write_bytes(b'replaced\n')
            os.replace(replacement, real)
            return b'replaced\n'
        def link_on_the_way():
            # link -> hop -> real: the symlink on the way pointed to a file in a folder not watched yet,
            # so only the hop's folder tells
            other = temp / 'linked-other' / 'other.txt'
            other.parent.mkdir()
            other.write_bytes(b'other\n')
            time.sleep(0.5)
            hop.unlink()
            os.symlink(other, hop)
            return b'other\n'
        hop = temp / 'linked-hops' / 'hop.txt'
        hop.parent.mkdir()
        os.symlink(real, hop)
        os.unlink(link)
        os.symlink(hop, link)
        follow('linked', link, [written, replaced, link_on_the_way])

    def file_becomes_symlink():
        project = temp / 'relinked'
        project.mkdir()
        plain = project / 'plain.txt'
        plain.write_bytes(b'plain\n')
        real = temp / 'relinked-elsewhere' / 'real.txt'
        real.parent.mkdir()
        real.write_bytes(b'real\n')

        def relinked():
            plain.unlink()
            os.symlink(real, plain)
            return b'real\n'

        def written():
            real.write_bytes(b'real changed\n')
            return b'real changed\n'
        follow('relinked', plain, [relinked, written])
    if not args.wine:
        check('watch/symlink-to-another-folder', symlink_elsewhere)
        check('watch/file-replaced-by-symlink', file_becomes_symlink)

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
        # Grok Build names the cwd in summary.json, here in the backslash spelling
        grok = home / '.grok/sessions/project/01a11c1e-808b-7263-a007-7a09593740c9'
        grok.mkdir(parents=True)
        (grok / 'updates.jsonl').write_text((ROOT / 'tests/data/agents/grok.jsonl').read_text(encoding='utf-8').replace('@PROJECT@', winpath(project)), encoding='utf-8')
        (grok / 'summary.json').write_text((ROOT / 'tests/data/agents/grok.json').read_text(encoding='utf-8').replace('@PROJECT@', json.dumps(winpath(project).replace('/', '\\'))[1:-1]), encoding='utf-8')
        os.utime(grok / 'updates.jsonl', (1699999900, 1699999900))
        env.pop('GROK_HOME', None)
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

    def native_user():
        user = ctypes.WinDLL('user32', use_last_error=True)
        callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
        user.EnumWindows.argtypes = [callback_type, wintypes.LPARAM]
        user.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
        user.GetWindowThreadProcessId.restype = wintypes.DWORD
        user.GetForegroundWindow.argtypes = []
        user.GetForegroundWindow.restype = wintypes.HWND
        user.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
        user.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
        user.IsWindowVisible.argtypes = [wintypes.HWND]
        user.IsIconic.argtypes = [wintypes.HWND]
        user.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]
        user.SendMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
        user.SendMessageW.restype = wintypes.LPARAM
        user.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
        return user, callback_type

    def native_title(user, window):
        title = ctypes.create_unicode_buffer(1024)
        user.GetWindowTextW(window, title, len(title))
        return title.value

    def native_find_window(user, callback_type, *, pid=None, name=None, timeout=10):
        found = []
        @callback_type
        def enum(window, unused):
            owner = wintypes.DWORD()
            user.GetWindowThreadProcessId(window, ctypes.byref(owner))
            if pid is not None and owner.value != pid:
                return True
            classname = ctypes.create_unicode_buffer(80)
            user.GetClassNameW(window, classname, len(classname))
            if classname.value == 'rhunWindow' and (name is None or native_title(user, window).startswith(name)):
                found.append((window, owner.value))
            return True
        deadline = time.monotonic() + timeout
        while not found and time.monotonic() < deadline:
            user.EnumWindows(enum, 0)
            if not found:
                time.sleep(0.03)
        assert found, 'native editor window did not appear'
        assert len(found) == 1, f'expected one editor window, found {found}'
        return found[0]

    def native_assert_foreground(user, window):
        deadline = time.monotonic() + 2
        while user.GetForegroundWindow() != window and time.monotonic() < deadline:
            time.sleep(0.03)
        assert user.IsWindowVisible(window), 'editor window stayed hidden'
        assert not user.IsIconic(window), 'editor window stayed minimized'
        foreground = user.GetForegroundWindow()
        assert foreground == window, f'editor HWND {window} is not foreground HWND {foreground}'

    def native_file_launch(show):
        name = 'native-file-' + str(show)
        project = temp / name / 'previous project'
        project.mkdir(parents=True)
        previous = project / 'previous.txt'
        previous.write_bytes(b'previous\n')
        file = temp / name / 'standalone café.rb'
        file.write_bytes(b'puts :standalone\n')
        env = environment(name)
        config = Path(env['XDG_CONFIG_HOME']) / 'rhun/config'
        config.parent.mkdir(parents=True)
        config.write_text('[updates]\ncheck = false\n[git]\nenabled = false\n', encoding='utf-8')
        run('rhun.com', winpath(project), winpath(previous), '--headless', '1000x700',
            '--script', script_file(name + '-seed', 'quit\n'), env=env)
        marker = Path(env['XDG_STATE_HOME']) / 'rhun/last-project'
        remembered = marker.read_bytes()
        # a file launch is a quick edit: no explorer or agents panel; CI keeps the window's picture
        shot = ''
        if os.environ.get('RHUN_TEST_ARTIFACTS'):
            visual = Path(os.environ['RHUN_TEST_ARTIFACTS']).resolve() / 'visual'
            visual.mkdir(parents=True, exist_ok=True)
            shot = 'shot ' + (visual / (name + '.ppm')).as_posix() + '\n'
        script = script_file(name, 'print-project\nprint-state\nprint-panels\nwait 5000\n' + shot +
                             'cmd next_tab\nprint-state\nquit\n')
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = show
        process = subprocess.Popen(command('rhun.exe', winpath(file), '--script', script),
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   env=env, startupinfo=startup)
        user, callback_type = native_user()
        try:
            first = []
            reader = threading.Thread(target=lambda: first.extend(
                [process.stdout.readline() for _ in range(3)]), daemon=True)
            reader.start()
            reader.join(timeout=10)
            assert len(first) == 3, first
            same_folder(first[0], file.parent)
            assert b'tabs=1 active=' + file.name.encode() in first[1], first
            assert first[2].strip() == b'explorer=0 agents=0 term=0', first
            window, _ = native_find_window(user, callback_type, pid=process.pid)
            native_assert_foreground(user, window)
            output = process.communicate(timeout=10)[0]
            assert process.returncode == 0, output
            assert b'tabs=1 active=' + file.name.encode() in output, output
            equal(marker.read_bytes(), remembered)
            equal(file.read_bytes(), b'puts :standalone\n')
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()

    def native_cli_file_launch():
        name = 'native-cli-file'
        project = temp / name / 'previous project'
        project.mkdir(parents=True)
        previous = project / 'previous.txt'
        previous.write_bytes(b'previous\n')
        file = temp / name / 'standalone cli café.rb'
        file.write_bytes(b'puts :cli\n')
        env = environment(name)
        config = Path(env['XDG_CONFIG_HOME']) / 'rhun/config'
        config.parent.mkdir(parents=True)
        config.write_text('[updates]\ncheck = false\n[git]\nenabled = false\n', encoding='utf-8')
        run('rhun.com', winpath(project), winpath(previous), '--headless', '1000x700',
            '--script', script_file(name + '-seed', 'quit\n'), env=env)
        marker = Path(env['XDG_STATE_HOME']) / 'rhun/last-project'
        remembered = marker.read_bytes()
        user, callback_type = native_user()
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = 7  # keep the temporary console minimized and inactive
        process = subprocess.Popen(command('rhun.com', winpath(file)), env=env,
                                   startupinfo=startup, creationflags=subprocess.CREATE_NEW_CONSOLE)
        window = None
        try:
            # No --script or --wait: the console entry must exit after spawning the GUI sibling.
            assert process.wait(timeout=10) == 0, 'console launcher failed'
            window, gui_pid = native_find_window(user, callback_type, name=file.name)
            assert gui_pid != process.pid, 'console entry did not respawn the GUI'
            title = native_title(user, window)
            assert title.endswith(file.parent.name) and project.name not in title, title
            native_assert_foreground(user, window)
            user.PostMessageW(window, 0x10, 0, 0)  # WM_CLOSE
            deadline = time.monotonic() + 5
            while user.IsWindowVisible(window) and time.monotonic() < deadline:
                time.sleep(0.03)
            assert not user.IsWindowVisible(window), 'standalone editor did not close'
            equal(marker.read_bytes(), remembered)
            equal(file.read_bytes(), b'puts :cli\n')
        finally:
            if window is not None:
                user.PostMessageW(window, 0x10, 0, 0)
            if process.poll() is None:
                process.kill()
                process.wait()

    def native_window(preserve=False):
        name = 'window-preserve' if preserve else 'window'
        project = temp / ('native ' + name)
        project.mkdir()
        file = project / 'input.txt'
        file.write_bytes(b'native\n')
        screenshot = temp / (name + '.ppm')
        script = script_file(name, f'print-state\nwait {7000 if preserve else 2500}\ncmd select_all\ncmd copy\n'
                             'key ctrl+End\ncmd paste\ncmd save\n'
                             f'shot {winpath(screenshot)}\nprint-doc\nquit\n')
        env = environment(name)
        config = Path(env['XDG_CONFIG_HOME']) / 'rhun/config'
        config.parent.mkdir(parents=True)
        config.write_text('[updates]\ncheck = false\n[git]\nenabled = false\n', encoding='utf-8')
        process = subprocess.Popen(command('rhun.exe', winpath(project), winpath(file), '--script', script),
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
        user, callback_type = native_user()
        try:
            first = []
            reader = threading.Thread(target=lambda: first.append(process.stdout.readline()), daemon=True)
            reader.start()
            reader.join(timeout=10)
            assert first and b'active=input.txt' in first[0], 'document did not become ready'
            window, _ = native_find_window(user, callback_type, pid=process.pid, timeout=2)
            # Input goes through the real window procedure and UTF-16 surrogate handling.
            for code in [ord('Ω'), 0xD83D, 0xDE00]:
                user.SendMessageW(window, 0x102, code, 0)
            if preserve:
                user.ShowWindow(window, 6)  # minimize the project while its changes are unsaved
                assert user.IsIconic(window), 'project window did not minimize'
                standalone = temp / 'preserve standalone café.rb'
                standalone.write_bytes(b'puts :separate\n')
                child_script = script_file('preserve-file', 'print-project\nprint-state\nwait 3000\nquit\n')
                child = subprocess.Popen(command('rhun.exe', winpath(standalone), '--script', child_script),
                                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
                try:
                    child_window, _ = native_find_window(user, callback_type, pid=child.pid,
                                                        name=standalone.name)
                    native_assert_foreground(user, child_window)
                    assert user.IsIconic(window), 'file launch restored the other project window'
                    equal(file.read_bytes(), b'native\n')
                    child_output = child.communicate(timeout=10)[0]
                    assert child.returncode == 0, child_output
                    lines = child_output.split(b'\n')
                    same_folder(lines[0], standalone.parent)
                    assert lines[1].startswith(b'tabs=1 active=' + standalone.name.encode()), child_output
                finally:
                    if child.poll() is None:
                        child.kill()
                        child.wait()
            output = process.communicate(timeout=15)[0]
            assert process.returncode == 0, output
            equal(file.read_bytes(), 'Ω😀native\nΩ😀native\n'.encode())
            pixels = screenshot.read_bytes()
            assert pixels.startswith(b'P6\n') and len(set(pixels[100:])) > 16, 'window did not render'
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
    def native_issue_pictures():
        """In a real window: find ignoring case beyond ASCII, and the question before a read-only file is
        replaced; CI keeps their pictures"""
        name = 'native-issues'
        project = temp / name
        project.mkdir()
        # below the find bar, which covers the first lines of a narrow editor
        (project / 'case.txt').write_bytes('\n\n\n\nÉté été ÉTÉ\nПривет ПРИВЕТ яблоко ЯБЛОКО\n'.encode())
        readonly = project / 'readonly.txt'
        readonly.write_bytes(b'This file is read-only.\n')
        os.chmod(readonly, 0o444)
        env = environment(name)
        config = Path(env['XDG_CONFIG_HOME']) / 'rhun/config'
        config.parent.mkdir(parents=True)
        config.write_text('[updates]\ncheck = false\n[git]\nenabled = false\n', encoding='utf-8')
        visual = temp / name / 'shots'
        if os.environ.get('RHUN_TEST_ARTIFACTS'):
            visual = Path(os.environ['RHUN_TEST_ARTIFACTS']).resolve() / 'visual'
        visual.mkdir(parents=True, exist_ok=True)
        find_shot, readonly_shot = visual / 'native-find.ppm', visual / 'native-readonly.ppm'
        script = script_file(name, f'wait 1500\nopen {winpath(project / "case.txt")}\nkey ctrl+f\ntype été\n'
                                   f'wait 300\nprint-state\nshot {find_shot.as_posix()}\nkey Escape\n'
                                   f'open {winpath(readonly)}\nkey End\ntype  typed\nkey ctrl+s\nwait 300\n'
                                   f'print-state\nshot {readonly_shot.as_posix()}\nkey Escape\nquit\n')
        try:
            output = run('rhun.exe', winpath(project), '--script', script, env=env).stdout
            lines = output.decode('utf-8', 'replace').splitlines()
            assert 'active=case.txt line=5 col=4 sel=5' in lines[0], output
            assert 'active=readonly.txt' in lines[1] and 'focus=5' in lines[1], output
            equal(readonly.read_bytes(), b'This file is read-only.\n')
            for shot in (find_shot, readonly_shot):
                pixels = shot.read_bytes()
                assert pixels.startswith(b'P6\n') and len(set(pixels[100:])) > 16, shot
        finally:
            os.chmod(readonly, 0o644)

    if not args.wine:
        check('window/issue-pictures-find-and-readonly', native_issue_pictures)
        check('window/file-only-background-start-foreground', lambda: native_file_launch(4))
        check('window/file-only-minimized-start-foreground', lambda: native_file_launch(7))
        check('window/file-only-cli-respawn-foreground', native_cli_file_launch)
        check('window/file-launch-preserves-minimized-unsaved-project', lambda: native_window(preserve=True))
        check('window/unicode-input-clipboard-save-and-render', native_window)
    else:
        print('skip native readonly, sharing, symlinks, ConPTY and desktop tests under Wine', flush=True)

if failures:
    print('Failed: ' + ', '.join(failures), file=sys.stderr)
    raise SystemExit(1)
