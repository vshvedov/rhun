#!/usr/bin/env python3
"""Check native pipe-mode failures before committing virtual nonblocking flags."""
import argparse
import importlib.util
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/windows'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--wine', help='Wine executable or wrapper for the PE fixture')
    parser.add_argument('--exe', type=Path, help='run a prebuilt fixture, or output path with --build-only')
    parser.add_argument('--build-only', action='store_true', help='build --exe without running it')
    args = parser.parse_args()
    if args.build_only and not args.exe:
        parser.error('--build-only requires --exe output path')
    if args.exe and not args.build_only:
        check(args.exe.resolve(), args.wine)
        return
    spec = importlib.util.spec_from_file_location('rhun_nonblock_builder', ROOT / 'tools/build-windows.py')
    builder = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(builder)
    with tempfile.TemporaryDirectory(prefix='rhun-windows-nonblock-') as directory:
        folder = Path(directory)
        objects = []
        source = (ROOT / 'src/win/sys.s').read_text()
        for api in ('SetNamedPipeHandleState', 'WriteFile'):
            marker = 'API ' + api
            if marker not in source:
                raise AssertionError('native fault interception no longer matches: ' + api)
            source = source.replace(marker, 'call wfn_' + api)
        for name, text in [('sys', source), ('fixture',
                          (ROOT / 'tests/faults/windows_nonblock_flags.s').read_text())]:
            path = folder / (name + '.s')
            path.write_text(re.sub(r'(?m)^\.section \.rodata$', '.section .rdata,"dr"', text))
            obj = path.with_suffix('.obj')
            subprocess.run([builder.tool('llvm-mc'), '-triple=x86_64-pc-windows-msvc',
                            '-filetype=obj', '-defsym=WINDOWS=1', '-I', str(ROOT / 'src'),
                            '-I', str(ROOT / 'src/win'), str(path), '-o', str(obj)],
                           cwd=ROOT, check=True)
            objects.append(obj)
        excluded = {'src/main.s', 'src/start.s', 'src/plat/wayland.s', 'src/plat/x11.s', 'src/plat/xim.s', 'src/plat/ctext.s', 'src/plat/ctdata.s',
                    'src/plat/appearance.s', 'src/win/sys.s'}
        for path in sorted((ROOT / 'src').rglob('*.s')):
            relative = path.relative_to(ROOT).as_posix()
            if relative in excluded or relative.startswith('src/mac/'):
                continue
            obj = OUT / (relative.replace('/', '_') + '.obj')
            if not obj.is_file():
                raise AssertionError('build the Windows runtime first: ' + str(obj))
            objects.append(obj)
        objects.append(OUT / 'build_windows_assets.s.obj')
        libraries = [OUT / (path.stem + '.lib') for path in sorted((ROOT / 'src/win').glob('*.def'))]
        executable = args.exe.resolve() if args.build_only else folder / 'windows_nonblock_flags.exe'
        if args.build_only:
            executable.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([builder.tool('lld-link'), '/nodefaultlib', '/entry:win_start',
                        '/subsystem:console,6.02', '/stack:33554432,33554432', '/dynamicbase',
                        '/nxcompat', '/largeaddressaware', '/out:' + str(executable),
                        *map(str, objects), *map(str, libraries), str(OUT / 'rhun.res')],
                       cwd=ROOT, check=True)
        if args.build_only:
            print('built Windows nonblocking fixture: ' + str(executable), flush=True)
            return
        check(executable, args.wine)


def check(executable, wine):
    command = ([wine, 'Z:' + executable.resolve().as_posix()] if wine
               else [str(executable)])
    result = subprocess.run(command, cwd=ROOT, capture_output=True, timeout=120)
    expected = b'ok Windows nonblocking flags\n'
    if result.returncode or result.stdout + result.stderr != expected:
        raise AssertionError(f'Windows nonblocking flags: exit {result.returncode}, '
                             f'{(result.stdout + result.stderr)[:4000]!r}')
    print('ok   Windows nonblocking native failures and committed flags', flush=True)


if __name__ == '__main__':
    main()
