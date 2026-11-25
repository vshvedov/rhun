#!/usr/bin/env python3
"""Menus with extensions' items (docs/extensions/v1.1.md "Menus"): [menu.explorer], [menu.editor],
[menu.tab], [menu.terminal] and [menu.extension] items, filtered by when clauses on the menu's
target, grouped and ordered across extensions, one level of submenus, the TARGET body of
"0 run ... menu", caps and problems, a command gone at click time, and v1 extensions."""
import unittest

contribhost = __import__('contribhost')
CONFIG = ('[ui]\nagents_panel = false\n[editor]\ncursor_blink = false\n'
          '[files]\nrestore_session = false\nrestore_project = false\n'
          '[updates]\ncheck = false\n[git]\nenabled = false\n')
CHEVRON = ' ›'
# explorer rows at 1000x600, scale 1: 28 px from y 80: sub/, a.txt, b.go, Makefile, u.txt
ROW = {'sub': 94, 'a.txt': 122, 'b.go': 150, 'Makefile': 178}

ALICE = '''[command-options]
hidden.when = false
[menu.explorer]
copy_relative.command = copyrel
copy_relative.group = copy
copy_relative.order = 10
copy_relative.when = !explorerResourceIsRoot
run_make.command = make
run_make.when = resourceFilename == Makefile
more.submenu = tools
more.group = 9_tools
off.command = hidden
xtra.command = extra
[submenu.tools]
title = Demo Tools
lint.command = lint
lint.when = resourceExt in '.js .txt'
[menu.editor]
hello.command = ping
hello.args = from editor
[menu.tab]
tabitem.command = ping
tabitem.when = tabKind == doc
[menu.terminal]
termitem.command = ping
[menu.extension]
one.command = ping
two.command = make
two.group = z
'''
BOB = '''[menu.explorer]
first.command = early
first.group = copy
first.order = 5
'''


class MenuBase(contribhost.Contrib):
    def setUp(self):
        super().setUp()
        (self.work / 'config/rhun/config').write_text(CONFIG, encoding='utf-8')
        (self.proj / 'Makefile').write_text('all:\n', encoding='utf-8')
        (self.proj / 'sub').mkdir()

    def exts(self, alice=ALICE, hello='hello 1 command-args commands'):
        root = self.work / 'exts'
        self.make_ext(root, hello=hello, extra=alice,
                      commands=('copyrel = Copy Relative', 'make = Run Make Target', 'lint = Lint File',
                                'ping = Ping', 'hidden = Hidden', 'reg = Reg', 'unreg = Unreg'),
                      actions={'reg': ['register extra - Extra'], 'unreg': ['unregister extra']})
        self.make_ext(root, owner='bob', name='other', hello=hello, extra=BOB, commands=('early = Early',))
        return root

    def runs(self, owner='alice', name='demo'):
        lines = self.contrib_log(owner, name)
        return [(l, lines[i + 1]) for i, l in enumerate(lines) if l.startswith('0 run ')]

    def explorer(self, row):
        return 'click 50 %d right' % ROW[row]


class Menus(MenuBase):
    def test_explorer_groups_order_and_when(self):
        out = self.run_editor(exts=self.exts(), files=(), drop_waits=True, actions=[
            self.explorer('Makefile'), 'print-menu', 'key Escape',
            self.explorer('sub'), 'print-menu', 'key Escape',
            'click 50 400 right', 'print-menu'])
        builtin = ['New File', 'New Folder', 'Rename', 'Delete', 'Copy Path', 'Show in Finder'
                   if contribhost.host.sys.platform == 'darwin' else out[5]]
        chat = ['-', 'Add to Chat']     # rhun's own group after the built-in items (with the agents' chat on)
        makefile = out[:out.index('New File', 1)]
        self.assertEqual(makefile[:6], builtin)
        self.assertEqual(makefile[6:8], chat)
        self.assertEqual(makefile[8:], ['-', 'Demo Tools' + CHEVRON + ' >', '-',
                                        'Early [bob/other]', 'Copy Relative [alice/demo]', '-',
                                        'Run Make Target [alice/demo]'])
        rest = out[len(makefile):]
        folder = rest[:rest.index('New File', 1)]
        self.assertEqual(folder[6:8], chat)
        self.assertEqual(folder[8:], ['-', 'Demo Tools' + CHEVRON + ' >', '-',
                                      'Early [bob/other]', 'Copy Relative [alice/demo]'])
        root = rest[len(folder):]
        self.assertNotIn('Copy Relative [alice/demo]', root)
        self.assertIn('Early [bob/other]', root)

    def test_click_sends_the_target(self):
        mk = (self.proj / 'Makefile').as_posix()
        sub = (self.proj / 'sub').as_posix()
        exts = self.exts()
        self.run_editor(exts=exts, files=(), drop_waits=True, actions=[
            self.explorer('Makefile'), 'menu-pick Run Make Target', 'wait-ext demo running', 'wait 300'])
        self.run_editor(exts=exts, files=(), drop_waits=True, actions=[
            self.explorer('sub'), 'menu-pick Copy Relative', 'wait-ext demo running', 'wait 300'])
        self.run_editor(exts=exts, files=(), drop_waits=True, actions=[
            'click 50 400 right', 'menu-pick Early', 'wait-ext other running', 'wait 300'])
        self.assertEqual(self.runs(), [
            ('0 run demo.make 0 menu %d' % (len('file ' + mk) + 1), 'body=file ' + mk),
            ('0 run demo.copyrel 0 menu %d' % (len('folder ' + sub) + 1), 'body=folder ' + sub)])
        self.assertEqual(self.runs('bob', 'other')[0][0],
                         '0 run other.early 0 menu %d' % (len('root ' + self.proj.as_posix()) + 1))

    def test_submenu(self):
        out = self.run_editor(exts=self.exts(), files=(), drop_waits=True, actions=[
            self.explorer('a.txt'), 'menu-pick Demo Tools' + CHEVRON, 'print-menu', 'menu-pick Lint File',
            'wait-ext demo running', 'wait 300',
            self.explorer('Makefile'), 'menu-pick Demo Tools' + CHEVRON, 'print-menu'])
        self.assertEqual(out[0], 'Lint File [alice/demo]')
        self.assertEqual(out[1], 'none')        # the submenu has nothing for a Makefile: no menu
        a = (self.proj / 'a.txt').as_posix()
        self.assertEqual(self.runs()[0][1], 'body=file ' + a)

    def test_editor_tab_and_terminal(self):
        self.run_editor(exts=self.exts(), drop_waits=True, actions=[
            'click 500 300 right', 'menu-pick Ping', 'wait-ext demo running', 'wait 300',
            'click 700 20 right', 'print-menu', 'key Escape'])
        a = (self.proj / 'a.txt').as_posix()
        line, body = self.runs()[0]
        self.assertTrue(line.startswith('0 run demo.ping 1 menu '), line)
        self.assertTrue(body.startswith('body=editor 0 '), body)

    def test_tab_menu(self):
        # the strip is y 40 to 76; the first tab starts after the explorer (240 px)
        out = self.run_editor(exts=self.exts(), drop_waits=True, actions=[
            'click 300 58 right', 'print-menu', 'menu-pick Ping', 'wait-ext demo running', 'wait 300'])
        self.assertIn('Ping [alice/demo]', out)
        a = (self.proj / 'a.txt').as_posix()
        self.assertEqual(self.runs()[0][1], 'body=tab doc 1 ' + a)

    def test_extension_menu_replaces_its_command_list(self):
        out = self.run_editor(exts=self.exts(), drop_waits=True, actions=['ext-menu alice/demo', 'print-menu'])
        self.assertEqual(out, ['Ping [alice/demo]', '-', 'Run Make Target [alice/demo]', '-',
                               'Settings and details'])

    def test_command_gone_at_click_time(self):
        out = self.run_editor(exts=self.exts(), files=(), drop_waits=True, actions=[
            'cmd demo.reg', 'wait-ext demo running', 'wait 300', self.explorer('a.txt'), 'print-menu',
            'cmd demo.unreg', 'wait 300', 'menu-pick Extra', 'print-toast'])
        self.assertIn('Extra [alice/demo]', out)
        self.assertEqual(out[-1], 'toast=This command is no longer available')

    def test_problems_and_caps(self):
        bad = ALICE + '[menu.nowhere]\nx.command = ping\n[menu.editor]\nw.command = ping\nw.when = editorFocus ==\n'
        bad += ''.join('i%d.command = ping\n' % i for i in range(16))
        bad += '[submenu.tools]\ninner.submenu = deeper\nodd = 1\n'
        out = self.run_editor(exts=self.exts(bad), files=(), drop_waits=True,
                              actions=['print-contrib-problems alice/demo'])
        self.assertIn('problem=[menu.nowhere] x.command: unknown menu location', out)
        self.assertIn('problem=[menu.editor] w.when: when: expected a value at byte 14', out)
        self.assertTrue(any(l.startswith('problem=[menu.editor] i') and 'more than 16 items' in l for l in out), out)
        self.assertIn('problem=[submenu.tools] inner.submenu: a submenu inside a submenu', out)
        self.assertIn('problem=[submenu.tools] odd: not ITEM.command, .group, .order, .when, .args or .submenu', out)

    def test_v1_extension_gets_no_target(self):
        self.run_editor(exts=self.exts(hello='hello 1'), files=(), drop_waits=True, actions=[
            self.explorer('Makefile'), 'menu-pick Run Make Target', 'wait-ext demo running', 'wait 300'])
        self.assertEqual(self.runs()[0][0], '0 run demo.make 0')


TITLE = '''[command-options]
ping.icon = play
lint.icon = ext:nosuch
[menu.editor_title]
a.command = ping
a.args = from title
a.order = 1
b.command = lint
b.order = 2
b.when = resourceExt == .txt
'''


class TitleButtons(MenuBase):
    """[menu.editor_title]: icon buttons at the tab strip's end for the active tab, "…" for more."""

    def buttons(self, out):
        res = []
        for line in out:
            if line.startswith(('button ', 'more ')):
                words = line.split()
                x, y, w, h = map(int, words[-1][3:].split(','))
                res.append((words[1] if words[0] == 'button' else 'more', x + w // 2, y + h // 2))
        return res

    def test_buttons_follow_the_active_tab(self):
        out = self.run_editor(exts=self.exts(TITLE), files=('a.txt', 'b.go'), drop_waits=True, actions=[
            'print-title-buttons', 'key ctrl+Page_Up', 'print-title-buttons'])
        b = self.buttons(out)
        go = [n for n, *_ in b[:1]]
        self.assertEqual(go, ['demo.ping'], out)            # b.go is active first: no lint
        self.assertEqual([n for n, *_ in b[1:]], ['demo.ping', 'demo.lint'], out)
        self.assertLess(b[1][1], b[2][1])                   # in order, ending at the strip's end
        self.assertGreater(b[2][1], 900)

    def test_click_runs_with_the_tab_target(self):
        out = self.run_editor(exts=self.exts(TITLE), drop_waits=True, actions=['print-title-buttons'])
        (_, x, y), _ = self.buttons(out)
        self.run_editor(exts=self.exts(TITLE), drop_waits=True, actions=[
            f'click {x} {y}', 'wait-ext demo running', 'wait 300'])
        a = (self.proj / 'a.txt').as_posix()
        line, body = self.runs()[0]
        self.assertEqual(line, '0 run demo.ping 1 menu %d' % len('tab doc 1 %s\nfrom title' % a))
        self.assertEqual(body, 'body=tab doc 1 ' + a)

    def test_tooltip_is_the_title(self):
        out = self.run_editor(exts=self.exts(TITLE), drop_waits=True, actions=['print-title-buttons'])
        (_, x, y), _ = self.buttons(out)
        out = self.run_editor(exts=self.exts(TITLE), drop_waits=True, actions=[
            f'move {x} {y}', 'wait 700', 'wait 300', 'print-tip'])
        self.assertEqual(out[-1], 'tip=Ping')

    def test_more_than_three_go_into_the_overflow_menu(self):
        many = TITLE + ''.join('m%d.command = %s\nm%d.order = %d\n' % (i, c, i, 10 + i)
                               for i, c in enumerate(('make', 'copyrel', 'reg')))
        out = self.run_editor(exts=self.exts(many), drop_waits=True, actions=['print-title-buttons'])
        b = self.buttons(out)
        self.assertEqual([n for n, *_ in b], ['demo.ping', 'demo.lint', 'demo.make', 'more'], out)
        _, x, y = b[-1]
        out = self.run_editor(exts=self.exts(many), drop_waits=True, actions=[
            f'click {x} {y}', 'print-menu', 'menu-pick Copy Relative', 'wait-ext demo running', 'wait 300'])
        self.assertEqual(out, ['Copy Relative [alice/demo]', 'Reg [alice/demo]'])
        a = (self.proj / 'a.txt').as_posix()
        self.assertEqual(self.runs()[0], ('0 run demo.copyrel 1 menu %d' % (len('tab doc 1 ' + a) + 1),
                                          'body=tab doc 1 ' + a))

    def test_no_buttons_without_items(self):
        out = self.run_editor(exts=self.exts(), drop_waits=True, actions=['print-title-buttons'])
        self.assertEqual(self.buttons(out), [])


VIEWS = '''[menu.view_item]
open.command = ping
open.args = row
open.when = view == alice/demo.files && viewItem == folder
other.command = make
other.when = view == bob/other.files
[menu.view_title]
refresh.command = lint
'''


class ViewMenus(MenuBase):
    """[menu.view_item]: a tree row's menu, its target "item VIEW ID", the keys view and viewItem."""

    def test_view_item_menu(self):
        out = self.run_editor(exts=self.exts(VIEWS), drop_waits=True, actions=[
            'move 300 300', 'view-item-menu alice/demo.files src/lib folder', 'print-menu', 'key Escape',
            'view-item-menu alice/demo.files src/lib file', 'print-menu',
            'view-item-menu bob/other.files x', 'print-menu', 'key Escape',
            'view-item-menu alice/demo.files src/lib folder', 'menu-pick Ping', 'wait-ext demo running',
            'wait 300'])
        self.assertEqual(out, ['Ping [alice/demo]', 'none', 'Run Make Target [alice/demo]'])
        self.assertEqual(self.runs()[0], ('0 run demo.ping 1 menu %d' % len('item alice/demo.files src/lib\nrow'),
                                          'body=item alice/demo.files src/lib'))


if __name__ == '__main__':
    unittest.main()
