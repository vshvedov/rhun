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


def tool(name, optional=False):
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
    if optional:
        return None
    raise SystemExit(f'{name} is required. Install LLVM and set LLVM_BIN to its bin folder.')


def run(args):
    subprocess.run([str(a) for a in args], cwd=ROOT, check=True)


def without_comments(text):
    """PowerShell TEXT without its whole-line comments, here-strings as they are: the update helper,
    the installer included, has to fit a command line"""
    assert '<#' not in text, 'a block comment would have to go as a whole'
    lines, here = [], False
    for line in text.split('\n'):
        if here:
            here = not line.startswith(('"@', "'@"))
        elif line.rstrip().endswith(('@"', "@'")):
            here = True
        elif line.lstrip().startswith('#'):
            continue
        lines.append(line)
    return '\n'.join(lines)


def assets():
    lines = ['.section .rdata,"dr"']

    def emit(label, path):
        lines.extend([f'.globl {label}, {label}_end', '.p2align 4',
                      f'{label}: .incbin "{path.as_posix()}"', f'{label}_end: .byte 0'])

    import base64
    import gzip
    packed = base64.b64encode(gzip.compress((ROOT / 'runtime/ai/commit.ps1').read_bytes(), mtime=0)).decode('ascii')
    # New-Object can load a module before the helper starts. Suppress its first-use
    # progress here so PowerShell cannot mix CLIXML progress into the draft pipe.
    bootstrap = ("$ProgressPreference='SilentlyContinue';$ErrorActionPreference='Stop';"
                 "$b=[Convert]::FromBase64String('" + packed + "');"
                 "$m=New-Object IO.MemoryStream(,$b);"
                 "$g=New-Object IO.Compression.GzipStream($m,[IO.Compression.CompressionMode]::Decompress);"
                 "$r=New-Object IO.StreamReader($g);& ([scriptblock]::Create($r.ReadToEnd()))")
    script = base64.b64encode(bootstrap.encode('utf-16le')).decode('ascii')
    assert len(script) < 30000, 'AI helper exceeds the Windows command-line budget'
    lines += ['.globl commit_ai_script', 'commit_ai_script: .asciz "' + script + '"']
    # Install from GitHub's job (src/app/extinstall.s); its inputs come in RHUN_EI_* variables
    packed_install = base64.b64encode(gzip.compress(
        without_comments((ROOT / 'runtime/windows/extinstall.ps1').read_text(encoding='utf-8')).encode(),
        mtime=0)).decode('ascii')
    bootstrap_install = ("$ProgressPreference='SilentlyContinue';$ErrorActionPreference='Stop';"
                         "$b=[Convert]::FromBase64String('" + packed_install + "');"
                         "$m=New-Object IO.MemoryStream(,$b);"
                         "$g=New-Object IO.Compression.GzipStream($m,[IO.Compression.CompressionMode]::Decompress);"
                         "$r=New-Object IO.StreamReader($g);& ([scriptblock]::Create($r.ReadToEnd()))")
    encoded_install = base64.b64encode(bootstrap_install.encode('utf-16le')).decode('ascii')
    assert len(encoded_install) < 30000, 'Extension installer exceeds the Windows command-line budget'
    lines += ['.globl ext_install_script', 'ext_install_script: .asciz "' + encoded_install + '"']
    # extension management: the update check (src/app/extupdate.s) and the index fetch
    # (src/app/extindexfile.s); their inputs come in RHUN_EC_* and RHUN_EX_* variables
    # and a remote window's Linux agent (src/app/remote.s), its inputs in RHUN_RD_* variables, and
    # New Extension and Submit to Index (src/app/newext.s, submitext.s), their inputs in RHUN_NE_*
    # and RHUN_SX_* variables
    for script, symbol in (('extcheck.ps1', 'ext_check_script'), ('extindex.ps1', 'ext_index_script'),
                           ('remote.ps1', 'remote_download_script'), ('newext.ps1', 'newext_ps_script'),
                           ('submitext.ps1', 'submitext_ps_script')):
        packed = base64.b64encode(gzip.compress(
            without_comments((ROOT / 'runtime/windows' / script).read_text(encoding='utf-8')).encode(),
            mtime=0)).decode('ascii')
        bootstrap = ("$ProgressPreference='SilentlyContinue';$ErrorActionPreference='Stop';"
                     "$b=[Convert]::FromBase64String('" + packed + "');"
                     "$m=New-Object IO.MemoryStream(,$b);"
                     "$g=New-Object IO.Compression.GzipStream($m,[IO.Compression.CompressionMode]::Decompress);"
                     "$r=New-Object IO.StreamReader($g);& ([scriptblock]::Create($r.ReadToEnd()))")
        encoded = base64.b64encode(bootstrap.encode('utf-16le')).decode('ascii')
        assert len(encoded) < 30000, script + ' exceeds the Windows command-line budget'
        lines += ['.globl ' + symbol, symbol + ': .asciz "' + encoded + '"']
    installer = without_comments((ROOT / 'install.ps1').read_text(encoding='utf-8'))
    assert "\n'@" not in installer, 'Installer contains the embedding here-string delimiter'
    update = ("$installer=[scriptblock]::Create(@'\n" + installer + "\n'@);" +
              without_comments((ROOT / 'runtime/windows/update.ps1').read_text(encoding='utf-8')))
    packed_update = base64.b64encode(gzip.compress(update.encode(), mtime=0)).decode('ascii')
    bootstrap_update = ("$ProgressPreference='SilentlyContinue';$ErrorActionPreference='Stop';"
                        "$b=[Convert]::FromBase64String('" + packed_update + "');"
                        "$m=New-Object IO.MemoryStream(,$b);"
                        "$g=New-Object IO.Compression.GzipStream($m,[IO.Compression.CompressionMode]::Decompress);"
                        "$r=New-Object IO.StreamReader($g);& ([scriptblock]::Create($r.ReadToEnd()))")
    encoded_update = base64.b64encode(bootstrap_update.encode('utf-16le')).decode('ascii')
    assert len(encoded_update) < 30000, 'Update helper exceeds the Windows command-line budget'
    lines += ['.globl windows_update_script', 'windows_update_script: .asciz "' + encoded_update + '"']
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
                for key in ('name', 'files', 'first_line', 'icon'):
                    data = values.get(key, '').encode() + b'\0'
                    lines += [f'{label}_g{key}: .byte ' + ','.join(map(str, data))]
        lines += [f'.globl {kind}_table, {kind}_count', '.p2align 3',
                  f'{kind}_count: .quad {len(files)}', f'{kind}_table:']
        for i in range(len(files)):
            label = f'{kind}_{i}'
            fields = [label + '_name', label, label + '_end']
            if kind == 'syntax':
                fields += [label + '_g' + key for key in ('name', 'files', 'first_line', 'icon')]
            lines += ['.quad ' + ','.join(fields)]
    version = (ROOT / 'VERSION').read_text(encoding='utf-8').strip()
    lines += ['.globl rhun_version, rhun_dist', f'rhun_version: .asciz "{version}"',
              '.p2align 2', f'rhun_dist: .long {int(os.environ.get("RHUN_DIST") == "1")}']
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['debug', 'release', 'test'], nargs='?', default='debug')
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    mc = tool('llvm-mc', optional=True)
    clang = tool('clang', optional=True) if not mc else None
    if not mc and not clang:
        raise SystemExit('llvm-mc or clang is required. Install LLVM and set LLVM_BIN to its bin folder.')
    dlltool, link, rc = map(tool, ['llvm-dlltool', 'lld-link', 'llvm-rc'])
    # ICO containers can carry the existing PNG directly, without rerasterizing the artwork.
    png = (ROOT / 'assets/icons/rhun-256.png').read_bytes()
    icon = OUT / 'rhun.ico'
    icon.write_bytes(struct.pack('<HHHBBBBHHII', 0, 1, 1, 0, 0, 0, 0, 1, 32, len(png), 22) + png)
    manifest = OUT / 'rhun.manifest'
    version = (ROOT / 'VERSION').read_text(encoding='utf-8').strip().split('-')[0]
    manifest.write_text(re.sub(r'version="0\.16\.0\.0"', f'version="{version}.0"',
                               (ROOT / 'assets/windows/rhun.manifest').read_text(encoding='utf-8')), encoding='utf-8')
    # Version information names the program in Explorer, Task Manager and antivirus reports; code
    # signing (docs/windows-signing.md) requires the product name on every signed file.
    numbers = ','.join((version.split('.') + ['0'] * 4)[:4])
    full_version = (ROOT / 'VERSION').read_text(encoding='utf-8').strip()
    copyright_line = next(line for line in (ROOT / 'LICENSE').read_text(encoding='utf-8').splitlines()
                          if line.startswith('Copyright'))
    def resources(name):
        strings = {'FileDescription': 'rhun', 'FileVersion': full_version, 'InternalName': 'rhun',
                   'LegalCopyright': copyright_line + '. MIT License.', 'OriginalFilename': name,
                   'ProductName': 'rhun', 'ProductVersion': full_version}
        values = ''.join(f'      VALUE "{key}", "{value}"\n' for key, value in strings.items())
        return (f'1 24 "{manifest.as_posix()}"\n1 ICON "{icon.as_posix()}"\n'
                f'1 VERSIONINFO\nFILEVERSION {numbers}\nPRODUCTVERSION {numbers}\n'
                # VOS_NT_WINDOWS32, VFT_APP
                'FILEOS 0x40004\nFILETYPE 0x1\nBEGIN\n  BLOCK "StringFileInfo"\n  BEGIN\n'
                f'    BLOCK "040904B0"\n    BEGIN\n{values}    END\n  END\n'
                '  BLOCK "VarFileInfo"\n  BEGIN\n    VALUE "Translation", 0x409, 1200\n  END\nEND\n')
    res = {}
    # rhun.res (rhun.com's) also goes into test programs, tests/faults included
    for name, stem in (('rhun.exe', 'rhun-exe'), ('rhun.com', 'rhun')):
        resource = OUT / (stem + '.rc')
        resource.write_text(resources(name), encoding='utf-8')
        res[name] = resource.with_suffix('.res')
        # Relative paths avoid llvm-rc interpreting a POSIX absolute path as a /flag.
        run([rc, '/no-preprocess', '/C', '65001', '/fo', res[name].relative_to(ROOT), resource.relative_to(ROOT)])
    exclude = {'src/start.s', 'src/plat/wayland.s', 'src/plat/x11.s', 'src/plat/appearance.s'}
    sources = [p for p in sorted((ROOT / 'src').rglob('*.s'))
               if 'mac' not in p.relative_to(ROOT).parts and p.relative_to(ROOT).as_posix() not in exclude]
    generated = OUT / 'assets.s'
    generated.write_text(assets(), encoding='utf-8')
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
        if mc:
            run([mc, '-triple=x86_64-pc-windows-msvc', '-filetype=obj', '-defsym=WINDOWS=1',
                 '-I', ROOT / 'src', '-I', ROOT / 'src/win', '-I', OUT, copy, '-o', obj])
        else:
            run([clang, '-target', 'x86_64-pc-windows-msvc', '-c', '-Wa,-defsym,WINDOWS=1',
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
        run([link, '/nodefaultlib', '/entry:win_start', f'/subsystem:{subsystem},6.02',
             '/stack:33554432,33554432', '/dynamicbase', '/nxcompat', '/largeaddressaware',
             f'/out:{path}', f'/map:{path}.map', *objs, res.get(path.name, res['rhun.com']), *libraries])

    executable(OUT / 'rhun.exe', objects, 'windows')
    executable(OUT / 'rhun.com', objects, 'console')
    library = [obj for obj in objects if obj.name != 'src_main.s.obj']
    for test, obj in zip(tests, test_objects):
        executable(OUT / (test.stem + '.exe'), [obj, *library], 'console')
    print(OUT / 'rhun.exe')


if __name__ == '__main__':
    main()
