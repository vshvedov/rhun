#!/usr/bin/env python3
"""Experimental ARM64 ELF build for Vinix's Linux-compatible userspace."""
import argparse
import concurrent.futures
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sysroot', required=True, type=Path, help='ARM64 musl headers and static libc')
    parser.add_argument('--llvm', type=Path, default=Path(os.environ.get('LLVM_BIN', '/opt/homebrew/opt/llvm/bin')))
    parser.add_argument('--jobs', type=int, default=min(8, os.cpu_count() or 1))
    parser.add_argument('--test', action='store_true', help='also build the syscall ABI test')
    parser.add_argument('--window-sdk', type=Path, help='Vinix C window SDK; enables the native desktop backend')
    args = parser.parse_args()
    os.chdir(ROOT)
    out = ROOT / 'build/vinix'
    out.mkdir(parents=True, exist_ok=True)
    clang = str(args.llvm / 'clang')
    linker = shutil.which('ld.lld') or '/opt/homebrew/opt/lld/bin/ld.lld'
    flags = [clang, '--target=aarch64-linux-musl', '--sysroot=' + str(args.sysroot), '-g']
    assets = out / 'assets.s'
    assets.write_bytes(subprocess.check_output(['tools/gen-assets.sh'], env=dict(os.environ, RHUN_DIST='0')))
    sources = sorted(p for p in Path('src').rglob('*.s')
                     if not any(part in ('mac', 'win') for part in p.parts) and p != Path('src/start.s'))
    sources.append(assets)

    def compile_source(source):
        name = str(source.relative_to(ROOT) if source.is_absolute() else source).replace('/', '_').replace('.s','')
        translated = out / (name + '.s')
        obj = out / (name + '.o')
        defines = ['-D', 'VINIX'] if args.window_sdk else []
        subprocess.run([sys.executable, 'tools/arm64.py', '--elf', *defines, '-I', 'src', str(source), str(translated)], check=True)
        subprocess.run(flags + ['-c', str(translated), '-o', str(obj)], check=True)
        return obj

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        objects = list(pool.map(compile_source, sources))
    # These instruction helpers are independent of the Mac's entry and libc glue.
    # Keep one implementation shared with the existing translator target.
    runtime = Path('src/mac/rt.s').read_text()
    helpers = runtime.split('// ---- string instructions', 1)[1].split('// mac_pid_cwd', 1)[0]
    helper_source = out / 'helpers.s'
    helper_source.write_text('.macro FN name\n.text\n.globl \\name\n.p2align 2\n\\name:\n.endm\n'
                            + '// ---- string instructions' + helpers
                            + '\n.section .note.GNU-stack,"",@progbits\n')
    for source in ('tools/vinix/runtime.s', str(helper_source), 'tools/vinix/linux.c'):
        obj = out / (Path(source).stem + '.o')
        optimize = ['-O2'] if source.endswith('.c') else []
        subprocess.run(flags + optimize + ['-c', source, '-o', str(obj)], check=True)
        objects.append(obj)
    if args.window_sdk:
        for source in ('tools/vinix/window.s', 'tools/vinix/window.c', 'tools/vinix/keyboard.c', 'tools/vinix/clipboard.c'):
            obj = out / (Path(source).stem + ('-bridge.o' if source.endswith('.s') else '.o'))
            optimize = ['-O2'] if source.endswith('.c') else []
            subprocess.run(flags + optimize + ['-I' + str(args.window_sdk / 'include'), '-c', source, '-o', str(obj)], check=True)
            objects.append(obj)
        objects.append(args.window_sdk / 'lib/libvinix-window.a')
    lib = args.sysroot / 'usr/lib'
    libgcc = sorted(lib.glob('gcc/aarch64-*/**/libgcc.a'))
    if not libgcc:
        parser.error('the sysroot must include ARM64 libgcc.a')
    def link(name, objs):
        subprocess.run([linker, '-m', 'aarch64elf', '-static', '-z', 'noexecstack', '-o', str(out / name),
                        str(lib / 'crt1.o'), str(lib / 'crti.o'), *map(str, objs),
                        '-L' + str(lib), '--start-group', '-lc', str(libgcc[-1]), '--end-group',
                        str(lib / 'crtn.o')], check=True)
    link('rhun', objects)
    if args.test:
        test_objects = []
        for source in ('tools/vinix/linux.c', 'tests/vinix-abi.c'):
            obj = out / (Path(source).stem + '-test.o')
            subprocess.run(flags + ['-O2', '-DRHUN_SYSCALL_ONLY', '-c', source, '-o', str(obj)], check=True)
            test_objects.append(obj)
        link('vinix-abi-test', test_objects)
    print(out / 'rhun')

if __name__ == '__main__':
    main()
