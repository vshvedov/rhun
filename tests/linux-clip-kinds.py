#!/usr/bin/env python3
"""Phase 4 tasks 4 and 5 on a private X server: the clipboard's TARGETS round, text/uri-list and image/png
transfers, a refused list falling back to the text, an owner that never answers not blocking rhun, and a
whole XDND exchange (enter, position and status, drop, the XdndSelection's list, finished) from a ctypes Xlib
source. rhun runs without the agents' panel: clip-request asks for the kinds the box would, and print-clip
says what came; a drop nobody takes opens its files. Nothing touches the desktop's display."""
import ctypes as c
import ctypes.util
import os
from pathlib import Path
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
EXE = Path(os.environ.get('RHUN_TEST_EXE', ROOT / 'build/rhun')).resolve()


class Selection(c.Structure):
    _fields_ = [('type', c.c_int), ('serial', c.c_ulong), ('send_event', c.c_int),
                ('display', c.c_void_p), ('requestor', c.c_ulong), ('selection', c.c_ulong),
                ('target', c.c_ulong), ('property', c.c_ulong), ('time', c.c_ulong)]


class Request(c.Structure):
    _fields_ = [('type', c.c_int), ('serial', c.c_ulong), ('send_event', c.c_int),
                ('display', c.c_void_p), ('owner', c.c_ulong), ('requestor', c.c_ulong),
                ('selection', c.c_ulong), ('target', c.c_ulong), ('property', c.c_ulong),
                ('time', c.c_ulong)]


class Client(c.Structure):
    _fields_ = [('type', c.c_int), ('serial', c.c_ulong), ('send_event', c.c_int),
                ('display', c.c_void_p), ('window', c.c_ulong), ('message_type', c.c_ulong),
                ('format', c.c_int), ('l', c.c_long * 5)]


class Event(c.Union):
    _fields_ = [('type', c.c_int), ('selection', Selection), ('request', Request),
                ('client', Client), ('pad', c.c_long * 24)]


@unittest.skipUnless(sys.platform == 'linux' and shutil.which('Xvfb'), 'Linux Xvfb required')
class ClipKinds(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server_log = tempfile.TemporaryFile()
        cls.addClassCleanup(cls.server_log.close)
        read_fd, write_fd = os.pipe()
        cls.server = subprocess.Popen(['Xvfb', '-displayfd', str(write_fd), '-screen', '0', '1280x800x24',
                                       '-nolisten', 'tcp', '-ac', '-noreset'], pass_fds=(write_fd,),
                                      stdout=cls.server_log, stderr=cls.server_log)
        cls.addClassCleanup(cls.stop_server)
        os.close(write_fd)
        assert select.select([read_fd], [], [], 10)[0], 'private X server did not start'
        cls.display_name = ':' + os.read(read_fd, 64).decode().strip()
        os.close(read_fd)
        x = cls.x = c.CDLL(ctypes.util.find_library('X11'))
        for name, args, res in (
                ('XOpenDisplay', [c.c_char_p], c.c_void_p), ('XCloseDisplay', [c.c_void_p], c.c_int),
                ('XDefaultRootWindow', [c.c_void_p], c.c_ulong),
                ('XCreateSimpleWindow', [c.c_void_p, c.c_ulong, c.c_int, c.c_int, c.c_uint, c.c_uint, c.c_uint,
                                         c.c_ulong, c.c_ulong], c.c_ulong),
                ('XSelectInput', [c.c_void_p, c.c_ulong, c.c_long], c.c_int),
                ('XInternAtom', [c.c_void_p, c.c_char_p, c.c_int], c.c_ulong),
                ('XSetSelectionOwner', [c.c_void_p, c.c_ulong, c.c_ulong, c.c_ulong], c.c_int),
                ('XChangeProperty', [c.c_void_p, c.c_ulong, c.c_ulong, c.c_ulong, c.c_int, c.c_int, c.c_void_p,
                                     c.c_int], c.c_int),
                ('XGetWindowProperty', [c.c_void_p, c.c_ulong, c.c_ulong, c.c_long, c.c_long, c.c_int, c.c_ulong,
                                        c.POINTER(c.c_ulong), c.POINTER(c.c_int), c.POINTER(c.c_ulong),
                                        c.POINTER(c.c_ulong), c.POINTER(c.c_void_p)], c.c_int),
                ('XQueryTree', [c.c_void_p, c.c_ulong, c.POINTER(c.c_ulong), c.POINTER(c.c_ulong),
                                c.POINTER(c.POINTER(c.c_ulong)), c.POINTER(c.c_uint)], c.c_int),
                ('XSendEvent', [c.c_void_p, c.c_ulong, c.c_int, c.c_long, c.POINTER(Event)], c.c_int),
                ('XPending', [c.c_void_p], c.c_int), ('XNextEvent', [c.c_void_p, c.POINTER(Event)], c.c_int),
                ('XFlush', [c.c_void_p], c.c_int), ('XSync', [c.c_void_p, c.c_int], c.c_int),
                ('XFree', [c.c_void_p], c.c_int)):
            f = getattr(x, name)
            f.argtypes, f.restype = args, res

    @classmethod
    def stop_server(cls):
        cls.server.terminate()
        try:
            cls.server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            cls.server.kill()
            cls.server.wait(timeout=5)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rhun-x11-kinds-')
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.env = dict(os.environ, DISPLAY=self.display_name, HOME=str(self.work),
                        XDG_CONFIG_HOME=str(self.work / 'config'), XDG_STATE_HOME=str(self.work / 'state'),
                        XDG_RUNTIME_DIR=str(self.work), SHELL='/nonexistent')
        for name in ('WAYLAND_DISPLAY', 'WAYLAND_SOCKET'):
            self.env.pop(name, None)
        config = self.work / 'config/rhun/config'
        config.parent.mkdir(parents=True)
        config.write_text('[files]\nrestore_session = false\nrestore_project = false\n'
                          '[ui]\nagents_panel = false\nsidebar = false\n[updates]\ncheck = false\n'
                          '[git]\nenabled = false\n')
        self.d = self.x.XOpenDisplay(self.display_name.encode())
        self.assertTrue(self.d)
        self.addCleanup(self.x.XCloseDisplay, self.d)
        self.root = self.x.XDefaultRootWindow(self.d)
        self.win = self.x.XCreateSimpleWindow(self.d, self.root, 0, 0, 1, 1, 0, 0, 0)
        self.x.XSelectInput(self.d, self.win, 0x420000)
        self.events = []
        self.process = self.client = self.reader = None
        self.addCleanup(self.stop_editor)
        self.document = self.work / 'document.txt'
        self.document.write_bytes(b'original')
        self.a = self.work / 'a b.txt'
        self.a.write_text('aye\n')

    def atom(self, name):
        return self.x.XInternAtom(self.d, name.encode(), 0)

    def start_editor(self):
        control = self.work / 'control'
        self.log = open(self.work / 'editor.log', 'wb')
        self.addCleanup(self.log.close)
        self.process = subprocess.Popen([str(EXE), str(self.document), '--control', str(control)], env=self.env,
                                        stdout=self.log, stderr=self.log)
        deadline = time.monotonic() + 10
        while not control.exists():
            self.assertIsNone(self.process.poll())
            self.assertLess(time.monotonic(), deadline)
            time.sleep(.01)
        self.client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.client.settimeout(10)
        self.client.connect(str(control))
        self.reader = self.client.makefile('rb')
        self.command('wait 50')

    def stop_editor(self):
        if self.process is not None and self.process.poll() is None:
            try:
                self.command('quit')
                self.process.wait(timeout=5)
            except (OSError, AssertionError, subprocess.TimeoutExpired):
                self.process.kill()
                self.process.wait(timeout=5)
        for closable in (self.reader, self.client):
            if closable:
                closable.close()

    def command(self, line):
        self.client.sendall(line.encode() + b'\n')
        out = []
        while True:
            reply = self.reader.readline()
            self.assertNotIn(reply, (b'', b'error\n'), line)
            if reply == b'ok\n':
                return b''.join(out).decode()
            out.append(reply)

    def clip(self):
        return dict(w.split('=', 1) for w in self.command('print-clip').split())

    def event(self, kind, predicate=lambda e: True, seconds=10):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            for i, e in enumerate(self.events):
                if e.type == kind and predicate(e):
                    return self.events.pop(i)
            if self.x.XPending(self.d):
                e = Event()
                self.x.XNextEvent(self.d, c.byref(e))
                self.events.append(e)
            else:
                time.sleep(.005)
        self.fail(f'X event {kind} did not arrive')

    def answer(self, request, target_type, fmt, data):
        """Serve a SelectionRequest: the property set and a SelectionNotify; data None refuses."""
        prop = request.property
        if data is None:
            prop = 0
        elif fmt == 32:
            array = (c.c_long * len(data))(*data)
            self.x.XChangeProperty(self.d, request.requestor, request.property, target_type, 32, 0, array,
                                   len(data))
        else:
            self.x.XChangeProperty(self.d, request.requestor, request.property, target_type, 8, 0, data,
                                   len(data))
        reply = Event()
        reply.selection = Selection(31, 0, 1, self.d, request.requestor, request.selection, request.target,
                                    prop, request.time)
        self.x.XSendEvent(self.d, request.requestor, 0, 0, c.byref(reply))
        self.x.XFlush(self.d)

    def own(self, selection):
        self.x.XSetSelectionOwner(self.d, self.atom(selection), self.win, 0)
        self.x.XSync(self.d, 0)

    def until(self, check, seconds=10):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            value = check()
            if value:
                return value
            time.sleep(.01)
        self.fail('condition not reached')

    def text_request(self):
        """The next request for the owner's text: rhun asks for its own format first; refused, the UTF-8."""
        request = self.event(30).request
        if request.target == self.atom('application/x-rhun-clipboard-v1'):
            self.answer(request, 0, 8, None)
            request = self.event(30).request
        return request

    def serve_targets(self, offered):
        request = self.event(30).request
        self.assertEqual(request.target, self.atom('TARGETS'))
        self.answer(request, 4, 32, [self.atom('TARGETS')] + [self.atom(t) for t in offered])
        return self.event(30).request

    # ---- the clipboard ----

    def test_files_after_targets(self):
        self.start_editor()
        self.own('CLIPBOARD')
        self.command('clip-request 7')
        request = self.serve_targets(['UTF8_STRING', 'image/png', 'text/uri-list'])
        self.assertEqual(request.target, self.atom('text/uri-list'))
        self.answer(request, self.atom('text/uri-list'), 8,
                    b'# a comment\r\nfile://' + str(self.a).replace(' ', '%20').encode() + b'\r\nhttp://x/y\r\n')
        clip = self.until(lambda: (lambda d: d if d['kind'] == '2' else None)(self.clip()))
        self.assertEqual(int(clip['read']), len(str(self.a)) + 1)

    def test_an_image_when_no_files(self):
        self.start_editor()
        self.own('CLIPBOARD')
        self.command('clip-request 7')
        request = self.serve_targets(['UTF8_STRING', 'image/png'])
        self.assertEqual(request.target, self.atom('image/png'))
        data = b'\x89PNG\r\n\x1a\n' + bytes(200)
        self.answer(request, self.atom('image/png'), 8, data)
        clip = self.until(lambda: (lambda d: d if d['kind'] == '4' else None)(self.clip()))
        self.assertEqual(int(clip['read']), len(data))

    def test_a_refused_list_falls_back_to_text(self):
        self.start_editor()
        self.own('CLIPBOARD')
        self.command('clip-request 7')
        request = self.serve_targets(['text/uri-list', 'UTF8_STRING'])
        self.assertEqual(request.target, self.atom('text/uri-list'))
        self.answer(request, 0, 8, None)
        request = self.text_request()
        self.assertEqual(request.target, self.atom('UTF8_STRING'))
        self.answer(request, self.atom('UTF8_STRING'), 8, b'hello')
        self.until(lambda: 'hello' in self.command('print-doc'))
        self.assertEqual(self.clip()['kind'], '1')

    def test_text_alone_asks_no_targets(self):
        self.start_editor()
        self.own('CLIPBOARD')
        self.command('clip-request 1')
        request = self.text_request()
        self.assertEqual(request.target, self.atom('UTF8_STRING'))
        self.answer(request, self.atom('UTF8_STRING'), 8, b'plain')
        self.until(lambda: 'plain' in self.command('print-doc'))

    def test_an_owner_that_never_answers_blocks_nothing(self):
        self.start_editor()
        self.own('CLIPBOARD')
        self.command('clip-request 7')
        request = self.serve_targets(['text/uri-list'])
        self.assertEqual(request.target, self.atom('text/uri-list'))
        started = time.monotonic()                  # no answer: the loop goes on
        for _ in range(20):
            self.command('print-state')
        self.assertLess(time.monotonic() - started, 2)
        self.assertEqual(self.clip()['kind'], '0')

    # ---- XDND ----

    def rhun_window(self):
        aware = self.atom('XdndAware')
        root, parent = c.c_ulong(), c.c_ulong()
        children, count = c.POINTER(c.c_ulong)(), c.c_uint()
        self.x.XQueryTree(self.d, self.root, c.byref(root), c.byref(parent), c.byref(children), c.byref(count))
        found = None
        for i in range(count.value):
            kind, fmt, n, after, ptr = c.c_ulong(), c.c_int(), c.c_ulong(), c.c_ulong(), c.c_void_p()
            self.x.XGetWindowProperty(self.d, children[i], aware, 0, 1, 0, 4, c.byref(kind), c.byref(fmt),
                                      c.byref(n), c.byref(after), c.byref(ptr))
            if n.value == 1:
                self.assertEqual(c.cast(ptr, c.POINTER(c.c_ulong))[0], 5)
                found = children[i]
            if ptr:
                self.x.XFree(ptr)
        if children:
            self.x.XFree(children)
        self.assertIsNotNone(found, 'no window with XdndAware')
        return found

    def send(self, target, name, l0, l1=0, l2=0, l3=0, l4=0):
        e = Event()
        e.client = Client(33, 0, 1, self.d, target, self.atom(name), 32, (c.c_long * 5)(l0, l1, l2, l3, l4))
        self.x.XSendEvent(self.d, target, 0, 0, c.byref(e))
        self.x.XFlush(self.d)

    def drag(self, types):
        self.start_editor()
        target = self.rhun_window()
        self.own('XdndSelection')
        self.send(target, 'XdndEnter', self.win, 5 << 24, *[self.atom(t) for t in types])
        self.send(target, 'XdndPosition', self.win, 0, (300 << 16) | 200, 0, self.atom('XdndActionCopy'))
        status = self.event(33, lambda e: e.client.message_type == self.atom('XdndStatus')).client
        self.assertEqual(status.l[0], target)
        return target, status

    def test_a_whole_xdnd_exchange(self):
        target, status = self.drag(['text/uri-list', 'UTF8_STRING'])
        self.assertEqual(status.l[1] & 1, 1)
        self.assertEqual(status.l[4], self.atom('XdndActionCopy'))
        self.assertEqual(self.command('print-drop').split()[0], 'over=1')
        self.send(target, 'XdndDrop', self.win, 0, 0)
        request = self.event(30).request
        self.assertEqual((request.selection, request.target),
                         (self.atom('XdndSelection'), self.atom('text/uri-list')))
        self.answer(request, self.atom('text/uri-list'), 8,
                    ('file://' + str(self.a).replace(' ', '%20') + '\r\n').encode())
        finished = self.event(33, lambda e: e.client.message_type == self.atom('XdndFinished')).client
        self.assertEqual((finished.l[0], finished.l[1] & 1), (target, 1))
        self.until(lambda: 'active=a b.txt' in self.command('print-state'))     # nobody took it: opened

    def test_a_list_larger_than_the_input_buffer(self):
        # 400 KB in one property, more than the X input buffer holds: it is read in pages, not the end of rhun
        target, status = self.drag(['text/uri-list'])
        self.send(target, 'XdndDrop', self.win, 0, 0)
        request = self.event(30).request
        self.answer(request, self.atom('text/uri-list'), 8,
                    ('#' + 'x' * 400000 + '\r\nfile://' + str(self.a).replace(' ', '%20') + '\r\n').encode())
        finished = self.event(33, lambda e: e.client.message_type == self.atom('XdndFinished')).client
        self.assertEqual((finished.l[0], finished.l[1] & 1), (target, 1))
        self.until(lambda: 'active=a b.txt' in self.command('print-state'))

    def test_a_refused_conversion_ends_the_drag(self):
        target, status = self.drag(['text/uri-list'])
        self.send(target, 'XdndDrop', self.win, 0, 0)
        self.answer(self.event(30).request, self.atom('text/uri-list'), 8, None)
        finished = self.event(33, lambda e: e.client.message_type == self.atom('XdndFinished')).client
        self.assertEqual(finished.l[1] & 1, 0)
        self.until(lambda: self.command('print-drop').startswith('over=0'))

    def test_a_drag_of_text_alone_is_refused(self):
        target, status = self.drag(['UTF8_STRING'])
        self.assertEqual(status.l[1] & 1, 0)
        self.send(target, 'XdndDrop', self.win, 0, 0)
        finished = self.event(33, lambda e: e.client.message_type == self.atom('XdndFinished')).client
        self.assertEqual(finished.l[1] & 1, 0)
        self.assertEqual(self.command('print-drop').split()[0], 'over=0')

    def test_leave_ends_the_drag(self):
        target, status = self.drag(['text/uri-list'])
        self.send(target, 'XdndLeave', self.win)
        self.until(lambda: self.command('print-drop').startswith('over=0'))


if __name__ == '__main__':
    unittest.main(verbosity=2)
