#!/usr/bin/env python3
"""Exercise bounded output with deterministic native write and mode failures."""
import argparse
import importlib.util
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(command, **kwargs):
    result = subprocess.run(list(map(str, command)), cwd=ROOT, capture_output=True, timeout=120, **kwargs)
    if result.returncode:
        raise AssertionError(f'{command[0]}: exit {result.returncode}, '
                             f'{(result.stdout + result.stderr)[:4000]!r}')
    return result


def fault_fixture(platform, folder):
    """tests/ext_flush_test.s linked with src/app/extflush.s whose system calls are the test's."""
    builder = None
    if platform == 'windows':
        spec = importlib.util.spec_from_file_location('flush_windows_builder', ROOT / 'tools/build-windows.py')
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
    objects = []
    for name, relative in [('transport', 'src/app/extflush.s'), ('fixture', 'tests/ext_flush_test.s')]:
        text = (ROOT / relative).read_text()
        if name == 'transport':
            for original, replacement in [('SYS SYS_write', 'call ef_write'),
                                          ('SYS SYS_fcntl', 'call ef_fcntl'),
                                          ('call watch_set_events', 'call ef_watch'),
                                          ('call time_ms', 'call ef_time')]:
                if original not in text:
                    raise AssertionError('flush fault interception no longer matches: ' + original)
                text = text.replace(original, replacement)
        path = folder / (name + '.s')
        obj = path.with_suffix('.obj' if builder else '.o')
        if builder:
            text = re.sub(r'(?m)^\.section \.rodata$', '.section .rdata,"dr"', text)
        path.write_text(text)
        if platform == 'macos':
            translated = folder / (name + '-a64.s')
            run([sys.executable, ROOT / 'tools/arm64.py', '-I', ROOT / 'src', '-D', 'MACOS', path, translated])
            run(['as', '-arch', 'arm64', '-mmacosx-version-min=12.0', '-o', obj, translated])
        elif builder:
            run([builder.tool('llvm-mc'), '-triple=x86_64-pc-windows-msvc', '-filetype=obj',
                 '-defsym=WINDOWS=1', '-I', ROOT / 'src', '-I', ROOT / 'src/win', path, '-o', obj])
        else:
            run(['as', '--64', '-I', ROOT / 'src', '-o', obj, path])
        objects.append(obj)
    excluded = {'src/main.s', 'src/app/extflush.s'}
    if platform != 'linux':
        excluded.update(('src/start.s', 'src/plat/wayland.s', 'src/plat/x11.s', 'src/plat/xim.s', 'src/plat/ctext.s', 'src/plat/ctdata.s', 'src/plat/appearance.s'))
    build = ROOT / ('build/windows' if builder else 'build/obj')
    for path in sorted((ROOT / 'src').rglob('*.s')):
        relative = path.relative_to(ROOT).as_posix()
        if relative in excluded or relative.startswith('src/mac/') and platform != 'macos' or relative.startswith('src/win/') and not builder:
            continue
        name = relative.replace('/', '_')
        obj = build / (name + '.obj' if builder else name[:-2] + '.o')
        if not obj.is_file():
            raise AssertionError('build runtime first: ' + str(obj))
        objects.append(obj)
    objects.append(build / ('build_windows_assets.s.obj' if builder else 'build_assets.o'))
    executable = folder / ('ext_flush_fault' + ('.exe' if builder else ''))
    if platform == 'macos':
        command = ['clang', '-arch', 'arm64', '-mmacosx-version-min=12.0', '-o', executable, *objects]
        for framework in ('AppKit', 'QuartzCore', 'IOSurface', 'CoreServices', 'Carbon', 'Security'):
            command.extend(('-framework', framework))
    elif builder:
        libraries = [build / (path.stem + '.lib') for path in sorted((ROOT / 'src/win').glob('*.def'))]
        command = [builder.tool('lld-link'), '/nodefaultlib', '/entry:win_start', '/subsystem:console,6.02',
                   '/stack:33554432,33554432', '/dynamicbase', '/nxcompat', '/largeaddressaware',
                   '/out:' + str(executable), *objects, *libraries, build / 'rhun.res']
    else:
        command = ['ld', '-static', '-nostdlib', '--no-dynamic-linker', '-z', 'noexecstack',
                   '-o', executable, *objects]
    run(command)
    return executable


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--wine')
    parser.add_argument('--exe', type=Path, help='prebuilt fixture, or output with --build-only')
    parser.add_argument('--build-only', action='store_true')
    args = parser.parse_args()
    if args.build_only and not args.exe:
        parser.error('--build-only requires --exe output path')
    windows = bool(args.wine) or os.name == 'nt' or args.build_only and args.exe.suffix.lower() == '.exe'
    platform = 'windows' if windows else 'macos' if sys.platform == 'darwin' else 'linux'
    with tempfile.TemporaryDirectory(prefix='rhun-flush-fault-') as temporary:
        executable = (args.exe.resolve() if args.exe and not args.build_only
                      else fault_fixture(platform, Path(temporary)))
        if args.build_only:
            destination = args.exe.resolve()
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(executable, destination)
            print('built bounded flush fixture: ' + str(destination), flush=True)
            return
        command = [args.wine, 'Z:' + executable.as_posix()] if args.wine else [executable]
        result = run(command)
        expected = (ROOT / 'tests/data/ext-flush.expected').read_bytes()
        if result.stdout + result.stderr != expected:
            raise AssertionError('flush fixture output: ' + repr((result.stdout + result.stderr)[:4000]))
    print('ok   bounded flush interruptions, quotas, backpressure and native failures', flush=True)


if __name__ == '__main__':
    main()
