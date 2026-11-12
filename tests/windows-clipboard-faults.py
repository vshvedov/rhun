#!/usr/bin/env python3
"""Build isolated Windows clipboard API/allocator faults without changing product objects."""
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
    parser.add_argument('--build-only', action='store_true')
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location('windows_build', ROOT / 'tools/build-windows.py')
    build = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(build)
    mc, link = build.tool('llvm-mc'), build.tool('lld-link')
    executable = OUT / 'clipboard_metadata_fault_test.exe'
    apis = ('RegisterClipboardFormatW', 'GlobalAlloc', 'GlobalLock', 'GlobalUnlock',
            'GlobalFree', 'EmptyClipboard', 'SetClipboardData')
    with tempfile.TemporaryDirectory(prefix='rhun-win-clipboard-faults-') as directory:
        temporary = Path(directory)

        def assemble(name, source):
            source = re.sub(r'(?m)^(\s*\.(?:pushsection|section)) \.rodata[^\n]*',
                            r'\1 .rdata,"dr"', source)
            path = temporary / (name + '.s')
            path.write_text(source, encoding='utf-8')
            obj = temporary / (name + '.obj')
            subprocess.run([mc, '-triple=x86_64-pc-windows-msvc', '-filetype=obj',
                '-I', str(ROOT / 'src'), '-I', str(ROOT / 'src/win'), '-I', str(ROOT / 'build'),
                '-defsym=WINDOWS=1', '-o', str(obj), str(path)], cwd=ROOT, check=True)
            return obj

        replacements = {}
        for relative in ('src/win/clipboard.s', 'src/win/window.s', 'src/mem.s', 'src/app/editor.s'):
            source = (ROOT / relative).read_text(encoding='utf-8')
            if relative.startswith('src/win/'):
                for api in apis:
                    source = re.sub(r'\bAPI ' + api + r'\b', 'call wf_' + api, source)
            elif relative == 'src/mem.s':
                assert source.count('FN mem_alloc_try\n') == 1
                source = source.replace('FN mem_alloc_try\n', 'FN wf_real_mem_alloc_try\n', 1)
            else:
                source += '\n.globl clip_sb\n'
            replacements[relative] = assemble(relative.replace('/', '_'), source)
        common = (ROOT / 'tests/windows/clipboard_native_metadata_test.s').read_text(encoding='utf-8')
        assert common.count('FN main\n') == 1
        fixture = assemble('fixture', common.replace('FN main\n', 'FN wm_regular_main\n', 1) + '\n' +
                           (ROOT / 'tests/faults/windows_clipboard_metadata.s').read_text(encoding='utf-8'))
        exclude = {'src/main.s', 'src/start.s', 'src/plat/wayland.s', 'src/plat/x11.s', 'src/plat/xim.s', 'src/plat/ctext.s', 'src/plat/ctdata.s', 'src/plat/appearance.s'}
        objects = []
        for path in sorted((ROOT / 'src').rglob('*.s')):
            relative = path.relative_to(ROOT).as_posix()
            if relative in exclude or 'mac' in path.relative_to(ROOT).parts:
                continue
            objects.append(replacements.get(relative, OUT / (relative.replace('/', '_') + '.obj')))
        objects.append(OUT / 'build_windows_assets.s.obj')
        assert all(path.is_file() for path in objects), 'run tools/build-windows.py test first'
        libraries = [OUT / (path.stem + '.lib') for path in sorted((ROOT / 'src/win').glob('*.def'))]
        subprocess.run([link, '/nodefaultlib', '/entry:win_start', '/subsystem:console,6.02',
            '/stack:33554432,33554432', '/dynamicbase', '/nxcompat', '/largeaddressaware',
            '/out:' + str(executable), str(fixture), *map(str, objects), str(OUT / 'rhun.res'),
            *map(str, libraries)], cwd=ROOT, check=True)
    if not args.build_only:
        result = subprocess.run([str(executable)], capture_output=True, timeout=60)
        assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
        assert result.stdout == b'ok Windows clipboard failures\n', result.stdout
        assert not result.stderr, result.stderr
        print(result.stdout.decode(), end='')


if __name__ == '__main__':
    main()
