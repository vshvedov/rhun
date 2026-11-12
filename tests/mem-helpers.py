#!/usr/bin/env python3
"""Fallible copy/vector boundaries and private allocation-failure checks."""
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


def build_faults(folder, windows=False):
    source = (ROOT / 'src/memtry.s').read_text()
    assert source.count('call mem_alloc_try') == 2
    source = source.replace('call mem_alloc_try', 'call mht_alloc')
    paths = [folder / 'memtry.s', folder / 'fixture.s']
    paths[0].write_text(source)
    paths[1].write_text('.equ TEST_MEM_HELPERS_FAULT, 1\n' +
                        (ROOT / 'tests/mem_helpers_test.s').read_text())
    objects = []
    if windows:
        spec = importlib.util.spec_from_file_location('windows_build', ROOT / 'tools/build-windows.py')
        build = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(build)
        mc, link = build.tool('llvm-mc'), build.tool('lld-link')
        out = ROOT / 'build/windows'
        for path in paths:
            path.write_text(re.sub(r'(?m)^(\s*\.section) \.rodata[^\n]*', r'\1 .rdata,"dr"', path.read_text()))
            obj = path.with_suffix('.obj')
            subprocess.run([mc, '-triple=x86_64-pc-windows-msvc', '-filetype=obj',
                            '-I', str(ROOT / 'src'), '-I', str(ROOT / 'src/win'),
                            '-I', str(out), '-defsym=WINDOWS=1', '-o', str(obj), str(path)], check=True)
            objects.append(obj)
        excluded = {'src/main.s', 'src/memtry.s', 'src/start.s', 'src/plat/wayland.s',
                    'src/plat/x11.s', 'src/plat/xim.s', 'src/plat/ctext.s', 'src/plat/ctdata.s', 'src/plat/appearance.s'}
        for path in sorted((ROOT / 'src').rglob('*.s')):
            rel = path.relative_to(ROOT).as_posix()
            if rel not in excluded and 'mac' not in path.relative_to(ROOT).parts:
                objects.append(out / (rel.replace('/', '_') + '.obj'))
        objects.append(out / 'build_windows_assets.s.obj')
        executable = folder / 'mem_helpers_fault_test.exe'
        libs = [out / (p.stem + '.lib') for p in sorted((ROOT / 'src/win').glob('*.def'))]
        subprocess.run([link, '/nodefaultlib', '/entry:win_start', '/subsystem:console,6.02',
                        '/stack:33554432,33554432', '/dynamicbase', '/nxcompat', '/largeaddressaware',
                        '/out:' + str(executable), *map(str, objects), str(out / 'rhun.res'),
                        *map(str, libs)], cwd=ROOT, check=True)
    else:
        mac = sys.platform == 'darwin'
        for path in paths:
            obj = path.with_suffix('.o')
            if mac:
                translated = path.with_suffix('.a64.s')
                subprocess.run([sys.executable, str(ROOT / 'tools/arm64.py'), '-I', str(ROOT / 'src'),
                                '-D', 'MACOS', str(path), str(translated)], cwd=ROOT, check=True)
                subprocess.run(['as', '-arch', 'arm64', '-mmacosx-version-min=12.0',
                                '-o', str(obj), str(translated)], check=True)
            else:
                subprocess.run(['as', '--64', '-I', str(ROOT / 'src'), '-I', str(ROOT / 'build'),
                                '-o', str(obj), str(path)], check=True)
            objects.append(obj)
        excluded = {'src/main.s', 'src/memtry.s'}
        if mac:
            excluded |= {'src/start.s', 'src/plat/wayland.s', 'src/plat/x11.s', 'src/plat/xim.s', 'src/plat/ctext.s', 'src/plat/ctdata.s', 'src/plat/appearance.s'}
        for path in sorted((ROOT / 'src').rglob('*.s')):
            rel = path.relative_to(ROOT).as_posix()
            if rel in excluded or 'win' in path.relative_to(ROOT).parts:
                continue
            if 'mac' in path.relative_to(ROOT).parts and not mac:
                continue
            objects.append(ROOT / 'build/obj' / (rel.replace('/', '_')[:-2] + '.o'))
        objects.append(ROOT / 'build/obj/build_assets.o')
        executable = folder / 'mem-helpers-faults'
        if mac:
            command = ['clang', '-arch', 'arm64', '-mmacosx-version-min=12.0', '-o', str(executable),
                       *map(str, objects)]
            for framework in ('AppKit', 'QuartzCore', 'IOSurface', 'CoreServices', 'Carbon', 'Security'):
                command += ['-framework', framework]
        else:
            command = ['ld', '-static', '-nostdlib', '--no-dynamic-linker', '-z', 'noexecstack',
                       '-o', str(executable), *map(str, objects)]
        subprocess.run(command, check=True)
    return executable


def run(executable, runner, label):
    result = subprocess.run([*runner, str(executable)], stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=30)
    expected = (ROOT / 'tests/data/mem-helpers.expected').read_bytes()
    assert result.returncode == 0 and result.stdout == expected, (
        executable, label, result.returncode, result.stdout)
    print('ok mem-helpers/' + label, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path)
    parser.add_argument('--fault-exe', type=Path)
    parser.add_argument('--wine')
    parser.add_argument('--build-windows-only', action='store_true')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='rhun-mem-helpers-') as directory:
        folder = Path(directory)
        if args.build_windows_only:
            executable = build_faults(folder, windows=True)
            shutil.copy2(executable, ROOT / 'build/windows/mem_helpers_fault_test.exe')
            return
        runner = [args.wine] if args.wine else []
        executable = args.exe or ROOT / ('build/windows/mem_helpers_test.exe'
                                         if os.name == 'nt' else 'build/mem_helpers_test')
        run(executable.resolve(), runner, 'boundaries')
        faults = args.fault_exe or build_faults(folder, windows=os.name == 'nt')
        run(faults.resolve(), runner, 'allocation-failure-and-retry')


if __name__ == '__main__':
    main()
