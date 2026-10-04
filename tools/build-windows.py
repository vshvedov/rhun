#!/usr/bin/env python3
"""Build native x64 Windows PE files with LLVM, on Windows, Linux or macOS.

Only LLVM and Python are needed. Import libraries are made from the Windows API
names used by the assembly; no CRT, Windows SDK or third-party runtime is linked.
"""
import argparse
import concurrent.futures
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'build' / 'windows'


def tool(name):
    roots = [os.environ.get('LLVM_BIN', ''), '/opt/homebrew/opt/llvm/bin',
             '/opt/homebrew/opt/lld/bin', r'C:\Program Files\LLVM\bin']
    found = shutil.which(name)
    if found:
        return found
    for root in roots:
        for suffix in ('', '.exe'):
            path = Path(root) / (name + suffix)
            if root and path.is_file():
                return str(path)
    raise SystemExit(f'{name} is required. Install LLVM and set LLVM_BIN to its bin folder.')


def run(args):
    subprocess.run([str(a) for a in args], cwd=ROOT, check=True)


def assets(helper_mode="encoded"):
    lines = ['.section .rdata,"dr"']

    def emit(label, path):
        lines.extend([f'.globl {label}, {label}_end', '.p2align 4',
                      f'{label}: .incbin "{path.as_posix()}"', f'{label}_end: .byte 0'])

    # Diagnostic modes isolate encoding and each payload without changing the
    # process or environment API. Keep the tested encoding in normal builds.
    import base64
    import gzip
    installer = (ROOT / 'install.ps1').read_text(encoding='utf-8')
    assert "\n'@" not in installer, 'Installer contains the embedding here-string delimiter'
    update = ("$installer=[scriptblock]::Create(@'\n" + installer + "\n'@);" +
              (ROOT / 'runtime/windows/update.ps1').read_text(encoding='utf-8'))
    scripts = {
        'commit_ai_script': (ROOT / 'runtime/ai/commit.ps1').read_text(encoding='utf-8'),
        'windows_update_script': update,
    }
    encoded = helper_mode != 'plain'
    flag = '-EncodedCommand' if encoded else '-Command'
    lines += ['.globl windows_helper_flag', f'windows_helper_flag: .asciz "{flag}"']
    for label, script in scripts.items():
        disabled = (helper_mode == 'none' or
                    helper_mode == 'no-ai' and label == 'commit_ai_script' or
                    helper_mode == 'no-updater' and label == 'windows_update_script')
        if disabled:
            script = "Write-Error 'Helper disabled in this diagnostic build'; exit 1"
        if encoded:
            compressed = bytearray(gzip.compress(script.encode('utf-8'), mtime=0))
            compressed[9] = 255  # Python 3.12 delegates the OS header byte to zlib.
            packed = base64.b64encode(compressed).decode('ascii')
            script = ("$ProgressPreference='SilentlyContinue';$ErrorActionPreference='Stop';"
                      "$b=[Convert]::FromBase64String('" + packed + "');"
                      "$m=New-Object IO.MemoryStream(,$b);"
                      "$g=New-Object IO.Compression.GzipStream($m,[IO.Compression.CompressionMode]::Decompress);"
                      "$r=New-Object IO.StreamReader($g);& ([scriptblock]::Create($r.ReadToEnd()))")
            script = base64.b64encode(script.encode('utf-16le')).decode('ascii')
        command = subprocess.list2cmdline(['powershell.exe', '-NoProfile', '-NonInteractive',
                                          '-OutputFormat', 'Text', flag, script])
        # CreateProcessW's limit includes quoting and the UTF-16 terminator. Leave
        # room for a full path to PowerShell rather than counting only the payload.
        assert len(command.encode('utf-16le')) // 2 < 30000, 'Helper exceeds the Windows command-line budget'
        path = OUT / (label + '.txt')
        path.write_bytes(script.encode('utf-8'))
        emit(label, path)
    emit('font_mono', ROOT / 'assets/fonts/IosevkaFixed-Regular.ttf')
    lines += ['.globl font_ui, font_ui_end', '.set font_ui,font_mono',
              '.set font_ui_end,font_mono_end']
    for kind in ('themes', 'syntax'):
        files = sorted((ROOT / 'runtime' / kind).iterdir())
        for i, path in enumerate(files):
            label = f'{kind}_{i}'
            emit(label, path)
            lines += [f'{label}_name: .asciz "{path.name}"']
            if kind == 'syntax':
                values = {}
                for line in path.read_text(encoding='utf-8').splitlines():
                    key, sep, value = line.partition('=')
                    if sep:
                        values[key.strip()] = value.strip()
                for key in ('name', 'files', 'first_line'):
                    data = values.get(key, '').encode() + b'\0'
                    lines += [f'{label}_g{key}: .byte ' + ','.join(map(str, data))]
        lines += [f'.globl {kind}_table, {kind}_count', '.p2align 3',
                  f'{kind}_count: .quad {len(files)}', f'{kind}_table:']
        for i in range(len(files)):
            label = f'{kind}_{i}'
            fields = [label + '_name', label, label + '_end']
            if kind == 'syntax':
                fields += [label + '_g' + key for key in ('name', 'files', 'first_line')]
            lines += ['.quad ' + ','.join(fields)]
    version = (ROOT / 'VERSION').read_text(encoding='utf-8').strip()
    lines += ['.globl rhun_version, rhun_dist', f'rhun_version: .asciz "{version}"',
              '.p2align 2', f'rhun_dist: .long {int(os.environ.get("RHUN_DIST") == "1")}']
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['debug', 'release', 'test'], nargs='?', default='debug')
    parser.add_argument('--helper-mode', choices=['plain', 'encoded', 'no-ai', 'no-updater', 'none'],
                        default='encoded', help='Use plain/disabled helpers only for Defender diagnostics.')
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    mc, dlltool, link, rc = map(tool, ['llvm-mc', 'llvm-dlltool', 'lld-link', 'llvm-rc'])
    # ICO containers can carry the existing PNG directly, without rerasterizing the artwork.
    png = (ROOT / 'assets/icons/rhun-256.png').read_bytes()
    icon = OUT / 'rhun.ico'
    icon.write_bytes(struct.pack('<HHHBBBBHHII', 0, 1, 1, 0, 0, 0, 0, 1, 32, len(png), 22) + png)
    manifest = OUT / 'rhun.manifest'
    version = (ROOT / 'VERSION').read_text(encoding='utf-8').strip().split('-')[0]
    manifest.write_text(re.sub(r'version="0\.16\.0\.0"', f'version="{version}.0"',
                               (ROOT / 'assets/windows/rhun.manifest').read_text(encoding='utf-8')), encoding='utf-8', newline='\n')
    resource = OUT / 'rhun.rc'
    resource.write_text(f'1 24 "{manifest.as_posix()}"\n1 ICON "{icon.as_posix()}"\n', encoding='utf-8')
    res = OUT / 'rhun.res'
    # Relative paths avoid llvm-rc interpreting a POSIX absolute path as a /flag.
    run([rc, '/no-preprocess', '/C', '65001', '/fo', res.relative_to(ROOT), resource.relative_to(ROOT)])
    exclude = {'src/start.s', 'src/plat/wayland.s', 'src/plat/x11.s'}
    sources = [p for p in sorted((ROOT / 'src').rglob('*.s'))
               if 'mac' not in p.relative_to(ROOT).parts and p.relative_to(ROOT).as_posix() not in exclude]
    generated = OUT / 'assets.s'
    generated.write_text(assets(args.helper_mode), encoding='utf-8')
    sources.append(generated)
    tests = sorted((ROOT / 'tests').glob('*.s')) + sorted((ROOT / 'tests/windows').glob('*.s')) if args.mode == 'test' else []

    def assemble(path):
        name = '_'.join(path.relative_to(ROOT).parts)
        obj = OUT / (name + '.obj')
        # COFF has no ELF .type or .rodata section flags. The runtime instructions stay intact.
        source = re.sub(r'(?m)^(\s*\.(?:pushsection|section)) \.rodata(\.\w+)?[^\n]*',
                        lambda m: m[1] + ' .rdata' + ('$' + m[2][1:] if m[2] else '') + ',"dr"',
                        path.read_text(encoding='utf-8'))
        # LLVM treats forward label differences in Intel operands as memory. Name them
        # explicitly as immediate constants, with a unique name per macro expansion.
        converted, in_macro = [], False
        for index, line in enumerate(source.splitlines()):
            if line.strip().startswith('.macro '):
                in_macro = True
            match = re.match(r'(\s*(?:mov|cmp) \w+, )([\w.]+\s*-\s*[\w.]+)(\s*(?:#.*)?)$', line)
            if match:
                name_const = f'.Lwin_length_{index}' + ('\\@' if in_macro else '')
                converted += [f'.set {name_const}, {match[2]}', match[1] + 'offset ' + name_const + match[3]]
            else:
                converted.append(line)
            if line.strip() == '.endm':
                in_macro = False
        source = '\n'.join(converted) + '\n'
        copy = OUT / name
        copy.write_text(source, encoding='utf-8')
        run([mc, '-triple=x86_64-pc-windows-msvc', '-filetype=obj', '-defsym=WINDOWS=1',
             '-I', ROOT / 'src', '-I', ROOT / 'src/win', '-I', OUT, copy, '-o', obj])
        return obj

    with concurrent.futures.ThreadPoolExecutor() as pool:
        objects = list(pool.map(assemble, sources))
        test_objects = list(pool.map(assemble, tests))
    libraries = []
    for definition in sorted((ROOT / 'src/win').glob('*.def')):
        lib = OUT / (definition.stem + '.lib')
        run([dlltool, '-m', 'i386:x86-64', '-d', definition, '-l', lib])
        libraries.append(lib)

    def executable(path, objs, subsystem):
        # Shared assembly deliberately uses large stack frames without Windows guard-page probes.
        # Commit the full stack up front; runtime workers do not call shared editor code.
        run([link, '/nodefaultlib', '/timestamp:0', '/entry:win_start', f'/subsystem:{subsystem},6.02',
             '/stack:33554432,33554432', '/dynamicbase', '/nxcompat', '/largeaddressaware',
             f'/out:{path}', f'/map:{path}.map', *objs, res, *libraries])

    executable(OUT / 'rhun.exe', objects, 'windows')
    executable(OUT / 'rhun.com', objects, 'console')
    library = [obj for obj in objects if obj.name != 'src_main.s.obj']
    for test, obj in zip(tests, test_objects):
        executable(OUT / (test.stem + '.exe'), [obj, *library], 'console')
    print(OUT / 'rhun.exe')


if __name__ == '__main__':
    main()
