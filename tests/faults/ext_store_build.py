"""Private, exact-inventory fault links. Never write product objects."""
import importlib.util
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def build(folder, fixture, replacements, windows=False):
    folder.mkdir(parents=True, exist_ok=True)
    mac = sys.platform == 'darwin' and not windows
    paths = []
    for relative, source in [*replacements.items(), ('fixture.s', fixture)]:
        path = folder / relative.replace('/', '_')
        path.write_text(source)
        paths.append((relative, path))
    objects = {}
    if windows:
        spec = importlib.util.spec_from_file_location('windows_build', ROOT / 'tools/build-windows.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        mc, linker = module.tool('llvm-mc'), module.tool('lld-link')
    for relative, path in paths:
        obj = path.with_suffix('.obj' if windows else '.o')
        if windows:
            path.write_text(re.sub(r'(?m)^(\s*\.section) \.rodata[^\n]*', r'\1 .rdata,"dr"', path.read_text()))
            command = [mc, '-triple=x86_64-pc-windows-msvc', '-filetype=obj', '-I', str(ROOT / 'src'),
                       '-I', str(ROOT / 'src/win'), '-I', str(ROOT / 'build/windows'), '-defsym=WINDOWS=1',
                       '-o', str(obj), str(path)]
        elif mac and relative.startswith('src/mac/'):
            command = ['as', '-arch', 'arm64', '-mmacosx-version-min=12.0', '-I', str(ROOT / 'src/mac'),
                       '-o', str(obj), str(path)]
        elif mac:
            translated = path.with_suffix('.a64.s')
            subprocess.run([sys.executable, str(ROOT / 'tools/arm64.py'), '-I', str(ROOT / 'src'),
                            '-D', 'MACOS', str(path), str(translated)], cwd=ROOT, check=True)
            command = ['as', '-arch', 'arm64', '-mmacosx-version-min=12.0', '-o', str(obj), str(translated)]
        else:
            command = ['as', '--64', '-I', str(ROOT / 'src'), '-I', str(ROOT / 'build'), '-o', str(obj), str(path)]
        subprocess.run(command, cwd=ROOT, check=True)
        objects[relative] = obj
    excluded = {'src/main.s'}
    if mac or windows:
        excluded |= {'src/start.s', 'src/plat/wayland.s', 'src/plat/x11.s', 'src/plat/xim.s', 'src/plat/ctext.s', 'src/plat/ctdata.s', 'src/plat/appearance.s'}
    inventory = [objects.pop('fixture.s')]
    for path in sorted((ROOT / 'src').rglob('*.s')):
        relative = path.relative_to(ROOT).as_posix()
        if relative in excluded or ('win' in path.parts and not windows) or ('mac' in path.parts and not mac):
            continue
        product = ROOT / ('build/windows' if windows else 'build/obj') / (
            relative.replace('/', '_') + '.obj' if windows else relative.replace('/', '_')[:-2] + '.o')
        inventory.append(objects.pop(relative, product))
    assert not objects, objects
    inventory.append(ROOT / ('build/windows/build_windows_assets.s.obj' if windows else 'build/obj/build_assets.o'))
    assert len(inventory) == len(set(inventory)) and all(p.is_file() for p in inventory), inventory
    executable = folder / ('ext_store_fault_test.exe' if windows else 'ext_store_fault_test')
    if windows:
        out = ROOT / 'build/windows'
        command = [linker, '/nodefaultlib', '/entry:win_start', '/subsystem:console,6.02',
                   '/stack:33554432,33554432', '/dynamicbase', '/nxcompat', '/largeaddressaware',
                   '/out:' + str(executable), *map(str, inventory), str(out / 'rhun.res'),
                   *[str(out / (p.stem + '.lib')) for p in sorted((ROOT / 'src/win').glob('*.def'))]]
    elif mac:
        command = ['clang', '-arch', 'arm64', '-mmacosx-version-min=12.0', '-o', str(executable), *map(str, inventory)]
        for framework in ('AppKit', 'QuartzCore', 'IOSurface', 'CoreServices', 'Carbon', 'Security'):
            command += ['-framework', framework]
    else:
        command = ['ld', '-static', '-nostdlib', '--no-dynamic-linker', '-z', 'noexecstack', '-o', str(executable), *map(str, inventory)]
    subprocess.run(command, cwd=ROOT, check=True)
    return executable
