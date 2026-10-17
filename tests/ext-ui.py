#!/usr/bin/env python3
"""The extensions as users meet them (docs/extensions/v1.md): the title bar's extensions button and
its dropdown, pinning, the Extensions page, an extension's own settings, on by default, turning
one off, removing one, and installing one from a release server (a local file:// tree laid out
as GitHub's, through RHUN_EXT_BASE): the permission dialog, the checksum, archives that reach
outside themselves. tests/ext-install-github.py does the same against github.com itself."""
import hashlib
import io
import os
from pathlib import Path
import sys
import tarfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
host = __import__('ext-host')

TARGET = 'windows-x64' if os.name == 'nt' else 'macos-arm64' if sys.platform == 'darwin' else 'linux-x86_64'
HELLO_INI = '''name = hello
owner = demo
title = Hello
version = 1.2.0
description = Says hello.
protocol = 1
runtime = python3
run = main.py

[commands]
say = Say Hello | ctrl+alt+8

[settings]
word.type = string
word.default = hi

[needs]
documents = write
project = read
'''
HELLO_PY = r'''import sys
out = sys.stdout
out.write('hello 1\n'); out.flush()
word = 'hi'
doc_version = {}
for line in sys.stdin:
    f = line.rstrip('\n').split(' ')
    if f[:2] == ['0', 'setting'] and f[2] == 'word':
        word = line.rstrip('\n').split(' ', 3)[3]
    elif f[:2] in (['0', 'opened'], ['0', 'changed']):
        doc_version[f[2]] = f[3]
    elif f[:2] == ['0', 'run']:
        doc = f[3]
        out.write('1 insert %s %s %d\n%s' % (doc, doc_version.get(doc, '0'), len(word), word)); out.flush()
    elif f[:2] == ['0', 'bye']:
        break
'''


def archive(files, link=None):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w:gz') as tar:
        for name, text in files.items():
            data = text.encode()
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = 0o644
            tar.addfile(info, io.BytesIO(data))
        if link:
            info = tarfile.TarInfo(link[0])
            info.type = tarfile.SYMTYPE
            info.linkname = link[1]
            tar.addfile(info)
    return buf.getvalue()


def png(w, h, pixel):
    """An RGBA PNG; pixel(x, y) -> (r, g, b, a)."""
    import struct
    import zlib
    raw = b''.join(b'\x00' + b''.join(bytes(pixel(x, y)) for x in range(w)) for y in range(h))

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


def ppm_colors(path):
    """The set of (r, g, b) colors in a binary PPM screenshot."""
    data = path.read_bytes()
    fields, pos = [], 0
    while len(fields) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        start = pos
        while not data[pos:pos + 1].isspace():
            pos += 1
        fields.append(data[start:pos])
    pixels = data[pos + 1:]
    return {tuple(pixels[i:i + 3]) for i in range(0, len(pixels) - 2, 3)}


class UI(host.Host):
    def ui(self, actions, **kw):
        return self.run_editor(actions, drop_waits=True, **kw)

    def ini(self):
        p = self.work / 'config/rhun/extensions.ini'
        return p.read_text(encoding='utf-8') if p.exists() else ''

    # --- the dropdown, pins, the page ---

    def test_the_dropdown_opens_and_escape_closes_it(self):
        out = self.ui(['print-extbar', 'cmd extensions_menu', 'print-extbar', 'key Escape', 'print-extbar'])
        self.assertEqual(out[0], 'menu=closed')
        self.assertEqual(out[2], 'menu=open')
        self.assertEqual(out[4], 'menu=closed')

    def test_dropdown_rows_have_visible_hover_feedback(self):
        empty = self.work / 'empty'
        empty.mkdir()
        for theme in ('dark', 'light'):
            self.env['RHUN_APPEARANCE'] = theme
            for exts, rows in ((empty, (148, 180)), (host.EXTS, (100, 148, 180))):
                with self.subTest(theme=theme, extensions=exts):
                    plain = self.work / 'plain.ppm'
                    away = self.work / 'away.ppm'
                    actions = ['cmd extensions_menu', 'move 500 300', 'shot ' + plain.as_posix()]
                    shots = []
                    for y in rows:
                        shot = self.work / f'hover-{y}.ppm'
                        shots.append(shot)
                        actions += [f'move 900 {y}', 'shot ' + shot.as_posix()]
                    actions += ['move 500 300', 'shot ' + away.as_posix()]
                    self.ui(actions, exts=exts)
                    for y, shot in zip(rows, shots):
                        base = host.ppm_pixel(plain, 900, y)
                        hover = host.ppm_pixel(shot, 900, y)
                        self.assertGreaterEqual(max(abs(a - b) for a, b in zip(base, hover)), 12)
                        self.assertEqual(host.ppm_pixel(away, 900, y), base)

    def test_extension_command_menu_has_visible_hover_feedback(self):
        exts = self.icon_ext('commands', 'on = command\n[commands]\nfirst = First\nsecond = Second\n', {})
        for theme in ('dark', 'light'):
            with self.subTest(theme=theme):
                self.env['RHUN_APPEARANCE'] = theme
                plain, hover, away = (self.work / (name + '.ppm') for name in ('plain', 'hover', 'away'))
                self.ui(['ext-menu pic', 'move 300 300', 'shot ' + plain.as_posix(),
                         'move 650 60', 'shot ' + hover.as_posix(),
                         'move 300 300', 'shot ' + away.as_posix()], exts=exts)
                base = host.ppm_pixel(plain, 650, 60)
                shown = host.ppm_pixel(hover, 650, 60)
                self.assertGreaterEqual(max(abs(a - b) for a, b in zip(base, shown)), 12)
                self.assertEqual(host.ppm_pixel(away, 650, 60), base)

    def test_a_menu_item_runs_its_command_after_more_are_registered(self):
        # the extension's menu is open while it registers twenty commands, which moves the command
        # table; the item clicked afterwards still runs the command it shows
        exts = self.work / 'menu'
        d = exts / 'demo/foo'
        d.mkdir(parents=True)
        (d / 'extension.ini').write_text('name = foo\nowner = demo\ntitle = Foo\nversion = 1\nprotocol = 1\n'
                                         'runtime = python3\nrun = main.py\n[commands]\nfirst = First\n'
                                         'trigger = Trigger\n', encoding='utf-8')
        (d / 'main.py').write_text('import sys, threading, time\n'
                                   'print("hello 1", flush=True)\n'
                                   'def reg():\n'
                                   '    time.sleep(.15)\n'
                                   '    for i in range(20): print(f"{i + 1} register x{i} - X{i}", flush=True)\n'
                                   'for line in sys.stdin:\n'
                                   '    if line.startswith("0 run foo.trigger"): threading.Thread(target=reg).start()\n'
                                   '    if line.startswith("0 run foo.first"): print("99 toast 3\\nran", end="", flush=True)\n'
                                   '    if line.startswith("0 bye"): break\n', encoding='utf-8')
        out = self.ui(['wait-ext foo running', 'wait 100', 'cmd foo.trigger', 'cmd extensions_menu', 'click 700 100',
                       'print-menu', 'wait 500', 'print-extensions', 'click 700 132', 'wait 100', 'print-toast'],
                      exts=exts)
        self.assertEqual(out[:4], ['First', 'Trigger', '-', 'Settings and details'])
        self.assertIn('foo.x19', out[4])
        self.assertEqual(out[5], 'toast=ran')

    def test_menus_of_two_extensions_with_one_name_run_their_own(self):
        exts = self.work / 'twins'
        for owner in ('aaa', 'bbb'):
            d = exts / owner / 'foo'
            d.mkdir(parents=True)
            (d / 'extension.ini').write_text(f'name = foo\nowner = {owner}\ntitle = Foo {owner}\nversion = 1\n'
                                             'protocol = 1\nruntime = python3\nrun = main.py\n[commands]\n'
                                             'first = First\nsecond = Second\n', encoding='utf-8')
            (d / 'main.py').write_text('import sys\nprint("hello 1", flush=True)\nfor line in sys.stdin:\n'
                                       '    if line.startswith("0 run foo.first"):\n'
                                       f'        print("99 toast 8\\nfrom {owner}", end="", flush=True)\n'
                                       '    if line.startswith("0 bye"): break\n', encoding='utf-8')
        out = self.ui(['wait-ext aaa/foo running', 'wait-ext bbb/foo running',
                       'ext-menu aaa/foo', 'print-menu', 'menu-pick First', 'wait 300', 'print-toast',
                       'ext-menu bbb/foo', 'menu-pick First', 'wait 300', 'print-toast'], exts=exts)
        self.assertEqual(out[:4], ['First', 'Second', '-', 'Settings and details'])
        self.assertEqual(out[4], 'toast=from aaa')
        self.assertEqual(out[5], 'toast=from bbb')

    def test_a_command_of_a_turned_off_extension_says_so_and_is_not_kept(self):
        out = self.ui(['ext-set echo disabled 1', 'cmd echo.hi', 'print-toast', 'ext-set echo disabled 0',
                       'wait-ext echo running', 'wait 300', 'wait 300'])
        self.assertEqual(out[0], 'toast=Echo is turned off. Turn it on in Extensions to use its commands.')
        self.assertFalse(any(l.startswith('0 run echo.hi') for l in self.echo_log()), self.echo_log())

    def test_off_on_off_while_it_stops_ends_it(self):
        # the program does not answer bye: it is stopping when the user turns it on and off again
        out = self.ui(['cmd echo.toast', 'wait-ext echo running', 'ext-set echo disabled 1', 'ext-set echo disabled 0',
                       'ext-set echo disabled 1', 'wait 1500', 'wait 1500', 'print-extensions',
                       'ext-set echo disabled 0', 'wait-ext echo running', 'print-extensions'], mode='sleep')
        self.assertIn('state=disabled', out[0])
        self.assertIn(' pid=0 ', out[0])
        self.assertIn('state=running', out[1])

    def test_int_settings_stay_within_32_bits(self):
        exts = self.manifest_variant('bigint', **{'width.max = 8': 'width.max = 4000000000'})
        out = self.ui(['ext-setting echo width 7', 'ext-page echo', 'print-ext-page',
                       'ext-setting echo width 9999999999', 'print-ext-page'], exts=exts)
        widths = [l for l in out if l.startswith('setting width=')]
        self.assertEqual(widths, ['setting width=7', 'setting width=2147483647'])

    # --- badges: an icon on a color ---

    def icon_ext(self, folder, keys, files):
        exts = self.work / folder
        d = exts / 'demo' / 'pic'
        d.mkdir(parents=True)
        (d / 'extension.ini').write_text('name = pic\nowner = demo\ntitle = Pic\nversion = 1\nprotocol = 1\n'
                                         'runtime = python3\nrun = main.py\n' + keys, encoding='utf-8')
        (d / 'main.py').write_text('import sys\nprint("hello 1", flush=True)\nfor line in sys.stdin:\n'
                                   '    if line.startswith("0 bye"): break\n', encoding='utf-8')
        for name, data in files.items():
            (d / name).write_bytes(data)
        return exts

    def test_an_icon_on_its_color_makes_the_badge(self):
        red = (224, 17, 95, 255)
        icon = png(64, 64, lambda x, y: red if 8 <= x < 56 and 8 <= y < 56 else (0, 0, 0, 0))
        exts = self.icon_ext('icon', 'icon = icon.png\ncolor = #112233\n', {'icon.png': icon})
        shot = self.work / 'badge.ppm'
        out = self.ui(['ext-set pic pinned 1', 'ext-page pic', 'print-ext-page', 'shot ' + shot.as_posix()],
                      exts=exts)
        self.assertIn('badge=icon color=#112233', out)
        colors = ppm_colors(shot)
        self.assertIn((224, 17, 95), colors)            # the icon, drawn
        self.assertIn((0x11, 0x22, 0x33), colors)       # on its color

    def test_a_color_alone_colors_the_letter_badge(self):
        exts = self.icon_ext('color', 'color = #2f9e8f\n', {})
        shot = self.work / 'badge.ppm'
        out = self.ui(['ext-page pic', 'print-ext-page', 'shot ' + shot.as_posix()], exts=exts)
        self.assertIn('badge=letter color=#2f9e8f', out)
        self.assertIn((0x2f, 0x9e, 0x8f), ppm_colors(shot))

    def test_an_icon_that_cannot_be_shown_leaves_the_letter(self):
        big = png(300, 300, lambda x, y: (1, 2, 3, 255))
        cases = {'big': ('icon = big.png\n', {'big.png': big}),
                 'notpng': ('icon = x.png\n', {'x.png': b'GIF89a not a png'}),
                 'outside': ('icon = ../x.png\n', {}),
                 'missing': ('icon = nope.png\n', {}),
                 'huge': ('icon = h.png\n', {'h.png': png(64, 64, lambda x, y: (9, 9, 9, 255)) + b'\0' * 70000})}
        for folder, (keys, files) in cases.items():
            with self.subTest(folder):
                exts = self.icon_ext(folder, keys, files)
                out = self.ui(['ext-page pic', 'print-ext-page'], exts=exts)
                self.assertIn('badge=unreadable color=-', out)

    def test_a_pin_is_remembered(self):
        out = self.ui(['ext-set echo pinned 1', 'print-extbar'])
        self.assertEqual(out[1], 'pinned=echo')
        self.assertIn('[rhun-tests/echo]\npinned = yes\n', self.ini())
        out = self.ui(['print-extbar'])
        self.assertEqual(out[1], 'pinned=echo')

    def test_the_page_lists_and_details_without_jargon(self):
        out = self.ui(['cmd extensions', 'print-ext-page', 'ext-page echo', 'print-ext-page', 'print-tabs'])
        self.assertEqual(out[0], 'Echo 0.0.1 on')
        self.assertEqual(out[1], 'Echo 0.0.1 on')
        self.assertEqual(out[2], 'pinned=0')
        self.assertEqual(out[3], 'badge=letter color=-')
        self.assertEqual(out[4], 'can: read and change the files you have open, read the files in your project, suggest terminal commands for you to run')
        self.assertIn('setting greeting=Hello', out)
        self.assertIn('setting loud=no', out)
        self.assertIn('setting width=4', out)
        self.assertIn('setting style=plain', out)
        self.assertTrue(any('Extensions' in l for l in out), out)

    # --- its own settings ---

    def test_settings_reach_the_program_and_are_saved(self):
        out = self.ui(['ext-setting echo greeting Good morning', 'ext-setting echo loud yes', 'cmd echo.greet',
                       'wait-ext echo running', 'wait 300', 'wait 300', 'print-doc'])
        self.assertEqual(out[0], 'GOOD MORNINGhello world')
        log = self.echo_log(settings=True)
        self.assertIn('0 setting greeting Good morning', log)
        self.assertIn('0 setting loud yes', log)
        self.assertIn('setting.greeting = Good morning\n', self.ini())
        # a change while it runs arrives as an event
        self.ui(['cmd echo.toast', 'wait-ext echo running', 'wait 300', 'ext-setting echo width 6', 'wait 300'])
        self.assertIn('0 setting width 6', self.echo_log(settings=True))

    def test_settings_are_checked_against_their_type(self):
        out = self.ui(['ext-setting echo width 99', 'ext-setting echo style shiny', 'ext-setting echo loud maybe',
                       'ext-page echo', 'print-ext-page'])
        self.assertIn('setting width=8', out)          # clamped to its max
        self.assertIn('setting style=plain', out)      # not an option: unchanged
        self.assertIn('setting loud=no', out)          # not yes or no: unchanged

    # --- on by default, off, removed ---

    def test_an_extension_without_on_runs_from_the_start(self):
        exts = self.manifest_variant('startup', **{'on = command\n': ''})
        out = self.ui(['wait-ext echo running', 'print-extensions'], exts=exts)
        self.assertIn('state=running', out[0])

    def test_off_stops_it_and_keeps_it_off(self):
        out = self.ui(['cmd echo.toast', 'wait-ext echo running', 'ext-set echo disabled 1', 'wait 500',
                       'cmd echo.toast', 'wait 300', 'print-ext-page', 'cmd extensions', 'print-ext-page'])
        self.assertTrue(out[-1].startswith('Echo 0.0.1 off'), out)
        self.assertIn('disabled = yes', self.ini())
        out = self.ui(['print-extensions'])
        self.assertIn('state=disabled', out[0])

    def test_remove_asks_and_then_everything_goes(self):
        exts = self.manifest_variant('removable')
        out = self.ui(['cmd echo.toast', 'wait-ext echo running', 'ext-remove echo', 'print-dialog', 'dialog yes',
                       'wait 300', 'print-extensions', 'print-toast', 'key ctrl+shift+p', 'type echo', 'print-palette'],
                      exts=exts)
        self.assertEqual(out[0], 'dialog=Remove “Echo”?')
        self.assertEqual(out[2], 'button=Remove')
        self.assertEqual(out[3], 'toast=Removed Echo')
        self.assertFalse((exts / 'rhun-tests/echo').exists())
        self.assertNotIn('Echo', '\n'.join(out[4:]))     # no command of it left in the palette

    # --- installing ---

    def release(self, files=None, link=None, bad_sum=False, name='hello', owner='demo'):
        base = self.work / 'releases'
        d = base / owner / name / 'releases/latest/download'
        d.mkdir(parents=True, exist_ok=True)
        data = archive(files or {'extension.ini': HELLO_INI, 'main.py': HELLO_PY}, link)
        asset = '%s-%s.tar.gz' % (name, TARGET)
        (d / asset).write_bytes(data)
        digest = hashlib.sha256(data + (b'x' if bad_sum else b'')).hexdigest()
        (d / 'sha256sums.txt').write_text('%s  %s\n' % (digest, asset), encoding='utf-8')
        self.env['RHUN_EXT_BASE'] = base.as_uri()      # file:///tmp/… or file:///C:/…
        return base

    def test_install_asks_with_the_permissions_and_runs_it(self):
        self.release()
        exts = self.manifest_variant('installs')
        out = self.ui(['ext-install demo/hello', 'wait-install', 'print-dialog', 'dialog yes', 'wait-ext hello running',
                       'wait 300', 'print-ext-page', 'cmd hello.say', 'wait 300', 'wait 300', 'print-doc'], exts=exts)
        self.assertEqual(out[0], 'install=asking')
        self.assertEqual(out[1], 'dialog=Add “Hello”?')
        self.assertEqual(out[2], 'text=Version 1.2.0 from github.com/demo/hello. It can read and change the files you have '
                                 'open, read the files in your project.')
        self.assertEqual(out[3], 'button=Add extension')
        self.assertTrue((exts / 'demo/hello/extension.ini').exists())
        self.assertFalse(any(p.name.startswith('.install') for p in exts.iterdir()))
        self.assertIn('hihello world', out)

    def test_cancel_leaves_nothing_behind(self):
        self.release()
        exts = self.manifest_variant('cancels')
        out = self.ui(['ext-install https://github.com/demo/hello', 'wait-install', 'dialog no', 'print-extensions'],
                      exts=exts)
        self.assertEqual(out[0], 'install=asking')
        self.assertFalse((exts / 'demo').exists() and any((exts / 'demo').iterdir()))
        self.assertFalse(any(p.name.startswith('.install') for p in exts.iterdir()))
        self.assertFalse(any(l.startswith('demo/hello') for l in out))

    def test_an_installed_invalid_manifest_keeps_its_failure(self):
        ini = HELLO_INI.replace('runtime = python3\nrun = main.py\n', '')
        self.release({'extension.ini': ini, 'main.py': HELLO_PY})
        exts = self.manifest_variant('invalid-install')
        out = self.ui(['ext-install demo/hello', 'wait-install', 'dialog yes', 'print-extensions',
                       'cmd hello.say', 'ext-set hello restart', 'wait 100', 'print-extensions'], exts=exts)
        states = [line for line in out if line.startswith('demo/hello ')]
        self.assertEqual(len(states), 2, out)
        for state in states:
            self.assertIn('state=failed', state)
            self.assertIn('pid=0', state)

    def test_a_wrong_checksum_is_refused(self):
        self.release(bad_sum=True)
        exts = self.manifest_variant('badsum')
        out = self.ui(['ext-install demo/hello', 'wait-install', 'print-toast'], exts=exts)
        self.assertEqual(out[0], 'install=failed')
        self.assertEqual(out[1], 'toast=Could not install demo/hello: the download does not match its checksum')

    def test_an_archive_with_a_link_is_refused(self):
        self.release(link=('evil', '/etc/passwd'))
        exts = self.manifest_variant('badlink')
        out = self.ui(['ext-install demo/hello', 'wait-install', 'print-toast'], exts=exts)
        self.assertEqual(out[1], 'toast=Could not install demo/hello: the archive holds links or devices')

    def test_a_manifest_for_another_extension_is_refused(self):
        self.release(files={'extension.ini': HELLO_INI.replace('name = hello', 'name = other'), 'main.py': HELLO_PY})
        exts = self.manifest_variant('other')
        out = self.ui(['ext-install demo/hello', 'wait-install', 'print-toast'], exts=exts)
        self.assertEqual(out[0], 'install=failed')
        self.assertEqual(out[1], 'toast=Could not install demo/hello: its extension.ini names a different extension')
        self.assertFalse((exts / 'demo').exists())
        self.assertFalse(any(p.name.startswith('.install') for p in exts.iterdir()))

    def test_the_folders_take_the_manifest_s_spelling(self):
        self.release(owner='Demo')
        exts = self.manifest_variant('spelling')
        out = self.ui(['ext-install Demo/hello', 'wait-install', 'dialog yes', 'wait-ext hello running',
                       'print-extensions'], exts=exts)
        self.assertIn('demo', os.listdir(exts))
        self.assertNotIn('Demo', os.listdir(exts))
        self.assertTrue(any(l.startswith('demo/hello state=running') for l in out), out)

    def test_a_long_title_is_cut_between_characters_in_the_dialogs(self):
        title = 'a' + '€' * 1000             # 3001 bytes; the 120-byte cut falls inside a €
        self.release(files={'extension.ini': HELLO_INI.replace('title = Hello', 'title = ' + title),
                            'main.py': HELLO_PY})
        exts = self.manifest_variant('longtitle')
        out = self.ui(['ext-install demo/hello', 'wait-install', 'print-dialog', 'dialog yes', 'wait-ext hello running',
                       'ext-remove hello', 'print-dialog', 'dialog no'], exts=exts)
        cut = 'a' + '€' * 39 + '…'
        self.assertEqual(out[1], 'dialog=Add “' + cut + '”?')
        self.assertEqual(out[4], 'dialog=Remove “' + cut + '”?')

    def test_the_details_page_follows_a_reinstall(self):
        self.release()
        exts = self.manifest_variant('reinstall')
        out = self.ui(['ext-install demo/hello', 'wait-install', 'dialog yes', 'wait-ext hello running',
                       'ext-page hello', 'ext-install demo/hello', 'wait-install', 'dialog yes', 'wait-ext hello running',
                       'ext-set hello disabled 1', 'print-ext-page'], exts=exts)
        self.assertIn('Hello 1.2.0 off', out)          # the list, with the record that is installed now
        self.assertFalse(any(l.startswith('pinned=') for l in out), out)

    def test_a_dialog_in_its_place_cancels_the_install(self):
        self.release()
        exts = self.manifest_variant('replaced')
        out = self.ui(['ext-install demo/hello', 'wait-install', 'ext-remove echo', 'print-dialog', 'dialog no',
                       'ext-install demo/hello', 'wait-install', 'print-dialog', 'dialog no', 'print-extensions'],
                      exts=exts)
        self.assertEqual(out[0], 'install=asking')
        self.assertEqual(out[1], 'dialog=Remove “Echo”?')
        self.assertEqual(out[4:6], ['install=asking', 'dialog=Add “Hello”?'])
        self.assertFalse(any(p.name.startswith('.install') for p in exts.iterdir()))
        self.assertTrue(any(l.startswith('rhun-tests/echo ') for l in out))     # Cancel kept it

    def test_installing_again_replaces_its_theme_and_grammar(self):
        theme = 'name = Hello Dusk\nkind = dark\nbg = #1d1b26\nfg = #e4def2\n'
        def release(pattern):
            self.release(files={'extension.ini': HELLO_INI, 'main.py': HELLO_PY, 'themes/hello-dusk.theme': theme,
                                'syntax/hello.syn': 'name = Hello Script\nfiles = %s\n' % pattern})
        release('*.hello1')
        exts = self.manifest_variant('again')
        self.ui(['ext-install demo/hello', 'wait-install', 'dialog yes', 'wait-ext hello running'], exts=exts)
        release('*.hello2')                  # the next version's grammar is for other files
        (self.proj / 'x.hello1').write_text('one\n', encoding='utf-8')
        (self.proj / 'x.hello2').write_text('two\n', encoding='utf-8')
        out = self.ui(['ext-install demo/hello', 'wait-install', 'dialog yes', 'wait-ext hello running',
                       'open ' + (self.proj / 'x.hello1').as_posix(), 'print-state',
                       'open ' + (self.proj / 'x.hello2').as_posix(), 'print-state',
                       'cmd select_theme', 'type hello dusk', 'print-palette'], exts=exts)
        states = [l for l in out if l.startswith('tabs=')]
        self.assertNotIn('lang=Hello Script', states[0])
        self.assertIn('lang=Hello Script', states[1])
        self.assertEqual(sum('Hello Dusk' in l for l in out), 1, out)

    def test_a_missing_release_says_so(self):
        self.env['RHUN_EXT_BASE'] = (self.work / 'nothing').as_uri()
        out = self.ui(['ext-install demo/hello', 'wait-install', 'print-toast'])
        self.assertEqual(out[1], 'toast=Could not install demo/hello: no release of demo/hello for ' + TARGET)

    def test_a_bad_name_is_refused_before_anything_runs(self):
        out = self.ui(['ext-install demo/../../etc', 'print-toast'])
        self.assertEqual(out[0], 'toast=Enter owner/repo or a GitHub repository URL')


for _name in dir(host.Host):
    if _name.startswith('test_'):
        setattr(UI, _name, None)

if __name__ == '__main__':
    unittest.main()
