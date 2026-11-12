#!/usr/bin/env python3
"""Native allocation boundaries and isolated mapping-failure fixtures."""
import argparse
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def build_faults(folder, windows=False):
    source = (ROOT / 'src/mem.s').read_text()
    assert source.count('FN os_map_try\n') == 1
    source = source.replace('FN os_map_try\n', 'FN mtf_real_os_map_try\n', 1)
    source += '\n.globl free_lists, chunk_ptr, chunk_end\n'
    paths = [folder / 'mem.s', folder / 'fixture.s']
    paths[0].write_text(source)
    paths[1].write_text((ROOT / 'tests/faults/mem_try.s').read_text())
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
        excluded = {'src/main.s', 'src/mem.s', 'src/start.s', 'src/plat/wayland.s',
                    'src/plat/x11.s', 'src/plat/xim.s', 'src/plat/ctext.s', 'src/plat/ctdata.s', 'src/plat/appearance.s'}
        for path in sorted((ROOT / 'src').rglob('*.s')):
            rel = path.relative_to(ROOT).as_posix()
            if rel not in excluded and 'mac' not in path.relative_to(ROOT).parts:
                objects.append(out / (rel.replace('/', '_') + '.obj'))
        objects.append(out / 'build_windows_assets.s.obj')
        executable = folder / 'mem_try_fault_test.exe'
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
        excluded = {'src/main.s', 'src/mem.s'}
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
        executable = folder / 'mem-try-faults'
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


def run(executable, modes, runner=(), fatal=False):
    for mode in modes:
        result = subprocess.run([*runner, str(executable), *([mode] if mode else [])],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
        expected = b'rhun: out of memory\n' if fatal else (
            (ROOT / 'tests/data/mem-try.expected').read_bytes() if not mode else b'ok allocation faults\n')
        assert result.returncode == (1 if fatal else 0) and result.stdout == expected, (
            executable, mode, result.returncode, result.stdout)
        print('ok mem-try/' + (mode or 'boundaries'), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path)
    parser.add_argument('--fault-exe', type=Path)
    parser.add_argument('--wine')
    parser.add_argument('--build-windows-only', action='store_true')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='rhun-mem-try-') as directory:
        folder = Path(directory)
        if args.build_windows_only:
            import shutil
            executable = build_faults(folder, windows=True)
            shutil.copy2(executable, ROOT / 'build/windows/mem_try_fault_test.exe')
            return
        runner = [args.wine] if args.wine else []
        executable = args.exe or ROOT / ('build/windows/mem_try_test.exe' if os.name == 'nt' else 'build/mem_try_test')
        run(executable.resolve(), [''], runner)
        run(executable.resolve(), ['fatal-map', 'fatal-alloc', 'fatal-realloc'], runner, fatal=True)
        faults = args.fault_exe or build_faults(folder, windows=os.name == 'nt')
        run(faults.resolve(), ['small', 'chunk', 'large'], runner)
        run(faults.resolve(), ['fatal-small', 'fatal-large', 'fatal-map'], runner, fatal=True)


if __name__ == '__main__':
    main()
