#!/usr/bin/env python3
"""The bridge for terminal claude (src/app/ide_server.s, mcpsrv.s, edtools.s) and terminal mode (claudeterm.s),
against tests/scripts/ide-client.py, which plays Claude Code 2.1.330 as it was seen with the real CLI: it finds
the lock file of the port in CLAUDE_CODE_SSE_PORT under <Claude folder>/ide, upgrades with
x-claude-code-ide-authorization and Sec-WebSocket-Protocol: mcp, sends initialize, notifications/initialized,
ide_connected and tools/list, and calls openDiff, getDiagnostics, close_tab and closeAllDiffTabs.

Every rhun gets its own HOME and XDG folders (so its Claude folder is $HOME/.claude in the test's folder) and
an environment without CLAUDE* or ANTHROPIC* variables. The real CLI is not used here."""
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
EXE = Path(os.environ.get('RHUN_TEST_EXE', ROOT / 'build/rhun')).resolve()
_spec = importlib.util.spec_from_file_location('ide_client', ROOT / 'tests/scripts/ide-client.py')
ide = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ide)
MOD = 'cmd' if sys.platform == 'darwin' else 'ctrl'
PY = shlex.quote(Path(sys.executable).as_posix())
UUID4 = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')


def clean_env(base):
    return {k: v for k, v in base.items() if not k.startswith(('CLAUDE', 'ANTHROPIC'))}


@unittest.skipIf(os.name == 'nt', 'the control socket is Unix only')
class BridgeCase(unittest.TestCase):
    BASE = ('[files]\nrestore_session = false\nrestore_project = false\n'
            '[updates]\ncheck = false\n[git]\nenabled = false\n'
            '[editor]\ncursor_blink = false\n[ui]\nsidebar = false\n')

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rhun-claude-bridge-')
        self.work = Path(self.tmp.name).resolve()
        self.project = self.work / 'project'
        self.project.mkdir()
        (self.project / 'a.txt').write_text('one\ntwo\nthree\nfour\n', encoding='utf-8')
        self.config = self.work / 'config/rhun/config'
        self.config.parent.mkdir(parents=True)
        self.ide_dir = self.work / '.claude/ide'
        self.env = dict(clean_env(os.environ), HOME=str(self.work), XDG_CONFIG_HOME=str(self.work / 'config'),
                        XDG_STATE_HOME=str(self.work / 'state'), GIT_CONFIG_NOSYSTEM='1', TERM='dumb')
        self.process = self.ctl = self.reader = None
        self.clients = []

    def tearDown(self):
        for c in self.clients:
            c.close()
        self.stop()
        self.tmp.cleanup()

    def start(self, extra='', target='project', env=None):
        self.config.write_text(self.BASE + extra, encoding='utf-8')
        control = self.work / 'control'
        if control.exists():
            control.unlink()
        where = [str(self.project)] if target == 'project' else (['--empty'] if target is None else [str(target)])
        self.process = subprocess.Popen([str(EXE)] + where + ['--headless', '1280x800', '--scale', '1',
                                                              '--control', str(control)],
                                        env=dict(self.env, **(env or {})), stdout=subprocess.DEVNULL,
                                        stderr=subprocess.PIPE)
        self.ctl = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.ctl.settimeout(30)
        deadline = time.monotonic() + 10
        while True:
            try:
                self.ctl.connect(str(control))
                break
            except (FileNotFoundError, ConnectionRefusedError):
                if self.process.poll() is not None or time.monotonic() > deadline:
                    self.fail('editor did not start')
                time.sleep(0.01)
        self.reader = self.ctl.makefile('r', encoding='utf-8')

    def command(self, line):
        self.ctl.sendall((line + '\n').encode('utf-8'))
        output = []
        while True:
            reply = self.reader.readline()
            if reply == 'ok\n':
                return ''.join(output)
            self.assertNotIn(reply, ('', 'error\n'), line)
            output.append(reply)

    def quit(self):
        self.ctl.sendall(b'quit\n')
        self.assertEqual(self.process.wait(timeout=15), 0)
        self.stop()

    def stop(self):
        """Quit (rhun removes its lock file then); by pid when that fails, never by name."""
        if self.process is not None and self.process.poll() is None:
            try:
                self.ctl.sendall(b'quit\n')
                self.process.wait(timeout=10)
            except (OSError, subprocess.TimeoutExpired):
                self.process.kill()
                self.process.wait(timeout=10)
        for closable in (self.reader, self.ctl):
            if closable is not None:
                closable.close()
        if self.process is not None:
            self.process.stderr.close()
        self.process = self.ctl = self.reader = None

    def until(self, check, what, timeout=5):
        deadline = time.monotonic() + timeout
        while True:
            value = check()
            if value:
                return value
            if time.monotonic() > deadline:
                self.fail('timed out: ' + what)
            time.sleep(0.05)

    # ---- the bridge ----
    def ide(self):
        """print-ide's first line as a dict, and the rest of its lines."""
        lines = self.command('print-ide').splitlines()
        head = dict(w.split('=', 1) for w in lines[0].split()[1:])
        return head, lines[1:]

    def port(self):
        """The port, once the server listens (it starts in the loop's first passes)."""
        return int(self.until(lambda: self.ide()[0]['port'] != '0' and self.ide()[0]['port'], 'the server listens'))

    def lock(self):
        return ide.read_lock(self.work / '.claude', self.port())

    def client(self, start=True, **kw):
        c = ide.Client(self.port(), self.lock()['authToken'], **kw)
        self.clients.append(c)
        if start and c.status == 101:
            c.start()
        return c

    def raw(self):
        """A plain TCP connection to the bridge."""
        s = socket.create_connection(('127.0.0.1', self.port()), timeout=10)
        self.clients.append(s)
        return s

    def term_text(self):
        return self.command('print-term')

    def offers(self):
        return [line for line in self.command('print-review').splitlines() if ' offer=1' in line]


class ServerTest(BridgeCase):
    def test_the_lock_file_has_the_extensions_six_fields(self):
        self.start()
        self.port()
        head, _ = self.ide()
        self.assertEqual(head['on'], '1')
        port = int(head['port'])
        self.assertTrue(10000 <= port <= 65535, port)
        path = self.ide_dir / ('%d.lock' % port)
        self.assertEqual(head['lock'], str(path))
        text = path.read_text(encoding='utf-8')
        lock = json.loads(text)
        self.assertEqual(list(lock), ['pid', 'workspaceFolders', 'ideName', 'transport', 'runningInWindows',
                                      'authToken'])
        self.assertEqual(lock['pid'], self.process.pid)
        self.assertEqual(lock['workspaceFolders'], [str(self.project)])
        self.assertEqual(lock['ideName'], 'rhun')
        self.assertEqual(lock['transport'], 'ws')
        self.assertIs(lock['runningInWindows'], False)
        self.assertRegex(lock['authToken'], UUID4)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.ide_dir.stat().st_mode), 0o700)
        self.assertEqual(os.listdir(self.ide_dir), [path.name])     # no temporary file is left
        self.quit()
        self.assertEqual(os.listdir(self.ide_dir), [])

    def test_a_folder_that_was_open_to_others_is_made_the_users_alone(self):
        self.ide_dir.mkdir(parents=True)
        self.ide_dir.chmod(0o755)
        self.start()
        self.port()
        self.assertEqual(stat.S_IMODE(self.ide_dir.stat().st_mode), 0o700)

    def test_it_listens_on_the_loopback_only(self):
        self.start()
        port = self.port()
        try:
            out = subprocess.run(['lsof', '-nP', '-a', '-p', str(self.process.pid), '-iTCP:%d' % port,
                                  '-sTCP:LISTEN'], capture_output=True, text=True).stdout
        except FileNotFoundError:
            out = ''
        if not out:
            self.skipTest('no lsof here')
        self.assertIn('127.0.0.1:%d' % port, out)
        self.assertNotIn('*:%d' % port, out)

    def test_the_token_differs_each_time(self):
        self.start()
        first = self.lock()['authToken']
        self.quit()
        self.start()
        self.assertNotEqual(self.lock()['authToken'], first)

    def test_a_terminals_program_gets_the_port(self):
        self.start()
        port = self.port()
        out = self.command('term-run --title env --sh -- echo port=$CLAUDE_CODE_SSE_PORT end')
        term = out.split('=')[1].strip()
        self.command(f'wait-terminal {term} exited')
        self.assertIn(f'port={port} end', self.term_text())

    def test_the_setting_off_means_no_server(self):
        self.start('[claude]\nide = false\n')
        self.command('wait 300')
        head, _ = self.ide()
        self.assertEqual((head['on'], head['port']), ('0', '0'))
        self.assertFalse(self.ide_dir.exists() and os.listdir(self.ide_dir))
        out = self.command('term-run --title env --sh -- echo port=[$CLAUDE_CODE_SSE_PORT]')
        self.command('wait-terminal %s exited' % out.split('=')[1].strip())
        self.assertIn('port=[]', self.term_text())

    def test_no_project_no_server(self):
        self.start(target=None)
        self.command('wait 300')
        self.assertEqual(self.ide()[0]['on'], '0')
        self.assertFalse(self.ide_dir.exists())

    def test_a_folder_added_rewrites_the_lock(self):
        self.start()
        other = self.work / 'other'
        other.mkdir()
        self.assertTrue(self.command(f'folder-add {other}').startswith('id='))
        self.until(lambda: len(self.lock()['workspaceFolders']) == 2, 'the lock file names both folders')
        self.assertEqual(self.lock()['workspaceFolders'], [str(self.project), str(other)])

    def test_the_locks_of_rhuns_that_are_gone_are_removed(self):
        self.ide_dir.mkdir(parents=True, mode=0o700)
        gone = subprocess.Popen([sys.executable, '-c', 'pass'])
        gone.wait()
        alive = os.getpid()

        def write(name, ide_name, pid):
            (self.ide_dir / name).write_text(json.dumps({'pid': pid, 'workspaceFolders': [], 'ideName': ide_name,
                                                         'transport': 'ws', 'runningInWindows': False,
                                                         'authToken': 'x'}), encoding='utf-8')
        write('20001.lock', 'rhun', gone.pid)
        write('20002.lock', 'Visual Studio Code', gone.pid)
        write('20003.lock', 'rhun', alive)
        (self.ide_dir / '20004.lock').write_text('not json', encoding='utf-8')
        self.start()
        self.port()
        names = set(os.listdir(self.ide_dir))
        self.assertNotIn('20001.lock', names)
        self.assertTrue({'20002.lock', '20003.lock', '20004.lock'} <= names, names)

    def test_settings_rows(self):
        self.start('[claude]\nuse_terminal = true\nide = false\n')
        out = self.command('print-settings')
        self.assertIn('claude.use_terminal\n', out)
        self.assertIn('claude.ide\n', out)

    def test_nothing_runs_while_nothing_happens(self):
        """With a client connected and nothing happening the bridge wakes the loop no more than rhun does
        without it (the panel's clock wakes it about once a second either way)."""
        def passes():
            return int(self.command('print-loop-stats').split()[0].split('=')[1])

        def wakeups():
            time.sleep(1)
            before = passes()
            time.sleep(3)
            return passes() - before - 1
        self.start('[claude]\nide = false\n')
        without = wakeups()
        self.quit()
        self.start()
        self.client()
        self.assertLessEqual(wakeups(), without + 1)


class HandshakeTest(BridgeCase):
    def test_the_upgrade_and_the_clis_start(self):
        self.start()
        c = self.client(start=False)
        self.assertEqual(c.status, 101)
        self.assertEqual(c.headers['sec-websocket-protocol'], 'mcp')
        init, tools = c.start()
        result = init['result']
        self.assertEqual(result['protocolVersion'], '2025-11-25')
        self.assertEqual(result['serverInfo'], {'name': 'Claude Code rhun MCP', 'version': result['serverInfo']['version']})
        self.assertEqual(result['capabilities'], {'tools': {'listChanged': True}})
        listed = {t['name']: t for t in tools['result']['tools']}
        self.assertEqual(list(listed), ['openDiff', 'getDiagnostics', 'close_tab', 'closeAllDiffTabs'])
        self.assertEqual(listed['openDiff']['description'], 'Open a git diff for the file')
        self.assertEqual(listed['openDiff']['inputSchema']['required'],
                         ['old_file_path', 'new_file_path', 'new_file_contents', 'tab_name'])
        self.assertNotIn('annotations', listed['getDiagnostics'])         # the extension's tools have none
        self.assertNotIn('description', listed['close_tab'])
        head, lines = self.ide()
        self.assertEqual(head['client'], '1')
        self.assertIn('conn 1 state=open proto=1 queued=0', lines)

    def test_an_older_protocol_is_answered_in_kind_and_an_unknown_one_with_the_newest(self):
        self.start()
        c = self.client(start=False)
        self.assertEqual(c.call('initialize', {'protocolVersion': '2025-03-26'})['result']['protocolVersion'],
                         '2025-03-26')
        self.assertEqual(c.call('initialize', {'protocolVersion': '1999-01-01'})['result']['protocolVersion'],
                         '2025-11-25')

    def test_without_the_subprotocol_none_is_named(self):
        self.start()
        c = self.client(start=False, protocol=None)
        self.assertEqual(c.status, 101)
        self.assertNotIn('sec-websocket-protocol', c.headers)

    def refused(self, request):
        s = self.raw()
        s.sendall(request)
        data = b''
        while True:
            chunk = s.recv(65536)
            if not chunk:
                return data
            data += chunk

    def test_a_wrong_or_missing_token_is_refused(self):
        self.start()
        token = self.lock()['authToken']
        c = ide.Client(self.port(), token, connect=False)
        self.clients.append(c)
        for bad in ('0' * 36, token[:-1], token + 'x', token.upper() if token.upper() != token else '1' * 36, None):
            with self.subTest(token=bad):
                head = self.refused(c.request(bad, 'mcp'))
                self.assertTrue(head.startswith(b'HTTP/1.1 401 '), head)
        self.assertEqual(self.ide()[0]['client'], 'none')

    def test_a_request_that_is_not_an_upgrade_is_refused(self):
        self.start()
        token = self.lock()['authToken']
        good = ide.Client(self.port(), token, connect=False)
        self.clients.append(good)
        req = good.request(token, 'mcp').decode()
        for name, bad in (('post', req.replace('GET ', 'POST ', 1)),
                          ('no upgrade', req.replace('Upgrade: websocket\r\n', '')),
                          ('version 8', req.replace('Version: 13', 'Version: 8')),
                          ('no key', re.sub(r'Sec-WebSocket-Key: [^\r]*\r\n', '', req)),
                          ('garbage', '\x00\xff' * 50 + '\r\n\r\n')):
            with self.subTest(name):
                head = self.refused(bad.encode('latin-1'))
                self.assertTrue(head.startswith(b'HTTP/1.1 400 '), head)

    def test_header_names_ignore_case(self):
        self.start()
        token = self.lock()['authToken']
        c = ide.Client(self.port(), token, connect=False)
        self.clients.append(c)
        req = c.request(token, 'mcp').decode().replace('X-Claude-Code-Ide-Authorization', 'x-CLAUDE-code-ide-AUTHORIZATION')
        c.sock.sendall(req.encode())
        self.assertTrue(c.read_head().startswith('HTTP/1.1 101 '))

    def test_a_request_too_long_is_refused(self):
        self.start()
        head = self.refused(b'GET / HTTP/1.1\r\nX-Pad: ' + b'a' * 9000)
        self.assertTrue(head.startswith(b'HTTP/1.1 400 '), head[:80])

    def test_a_silent_connection_is_closed_after_five_seconds(self):
        self.start()
        s = self.raw()
        s.settimeout(8)
        t0 = time.monotonic()
        self.assertEqual(s.recv(10), b'')
        self.assertGreater(time.monotonic() - t0, 4)

    def test_more_connections_than_four_are_closed_at_once(self):
        self.start()
        idle = [self.raw() for _ in range(4)]
        time.sleep(0.2)
        extra = self.raw()
        extra.settimeout(3)
        self.assertEqual(extra.recv(10), b'')
        self.assertEqual(self.ide()[0]['refused'], '1')
        for s in idle:
            s.close()

    def test_a_newer_client_replaces_the_older(self):
        self.start()
        first = self.client()
        second = self.client()
        self.assertEqual(first.close_code(), (4001, 'Another Claude Code session connected to this IDE'))
        self.assertEqual(self.ide()[0]['client'], '2')
        self.assertEqual(second.call('ping')['result'], {})


class FramesTest(BridgeCase):
    def setUp(self):
        super().setUp()
        self.start()
        self.c = self.client()

    def test_an_unmasked_frame_ends_the_connection_with_1002(self):
        self.c.send_frame(1, b'{}', mask=False)
        self.assertEqual(self.c.close_code()[0], 1002)

    def test_extension_bits_and_unknown_opcodes_end_it_with_1002(self):
        self.c.send_frame(1, b'{}', rsv=0x40)
        self.assertEqual(self.c.close_code()[0], 1002)
        for opcode in (3, 11):
            with self.subTest(opcode=opcode):
                c = self.client()
                c.send_frame(opcode, b'')
                self.assertEqual(c.close_code()[0], 1002)

    def test_a_continuation_without_a_start_and_a_long_control_frame(self):
        self.c.send_frame(0, b'{}')
        self.assertEqual(self.c.close_code()[0], 1002)
        c = self.client()
        c.send_frame(9, b'x' * 126)
        self.assertEqual(c.close_code()[0], 1002)
        c = self.client()
        c.send_frame(9, b'x', fin=False)
        self.assertEqual(c.close_code()[0], 1002)

    def test_a_message_over_16_mib_ends_it_with_1009_before_it_is_read(self):
        header = bytes([0x81, 0x80 | 127]) + struct.pack('>Q', 16 * 1024 * 1024 + 1) + b'\0\0\0\0'
        self.c.sock.sendall(header)
        self.assertEqual(self.c.close_code()[0], 1009)
        c = self.client()                 # fragments count together
        c.send_frame(1, b' ' * (9 * 1024 * 1024), fin=False)
        c.sock.sendall(bytes([0x80, 0x80 | 127]) + struct.pack('>Q', 8 * 1024 * 1024) + b'\0\0\0\0')
        self.assertEqual(c.close_code(20)[0], 1009)

    def test_fragments_are_joined_and_a_ping_between_them_is_answered(self):
        text = json.dumps({'jsonrpc': '2.0', 'id': 'frag', 'method': 'ping'}).encode()
        self.c.send_frame(1, text[:5], fin=False)
        self.c.send_frame(9, b'hello')
        self.c.send_frame(0, text[5:12], fin=False)
        self.c.send_frame(0, text[12:], fin=True)
        fin, op, payload = self.c.read_frame()
        self.assertEqual((fin, op, payload), (1, 10, b'hello'))
        self.assertEqual(self.c.wait_response('frag'), {'jsonrpc': '2.0', 'id': 'frag', 'result': {}})

    def test_a_binary_message_and_a_large_one(self):
        self.c.send_frame(2, json.dumps({'jsonrpc': '2.0', 'id': 7, 'method': 'ping'}).encode())
        self.assertEqual(self.c.wait_response(7)['result'], {})
        big = {'jsonrpc': '2.0', 'id': 8, 'method': 'ping', 'params': {'pad': 'x' * 200000}}
        self.c.send(big)
        self.assertEqual(self.c.wait_response(8)['result'], {})

    def test_a_close_is_answered_with_its_code(self):
        self.c.send_frame(8, struct.pack('>H', 1000) + b'bye')
        self.assertEqual(self.c.close_code(), (1000, ''))
        self.until(lambda: self.ide()[0]['client'] == 'none', 'the client goes')

    def test_what_is_not_json_is_dropped(self):
        self.c.send_frame(1, b'{not json')
        self.c.send_frame(1, b'\xff\xfe')
        self.assertEqual(self.c.call('ping')['result'], {})

    def test_a_peer_that_goes_away_mid_frame_leaves_nothing(self):
        self.c.sock.sendall(bytes([0x81, 0x80 | 126, 0x10, 0x00]) + b'\0\0\0\0' + b'x' * 100)
        self.c.sock.close()
        self.until(lambda: self.ide()[0]['client'] == 'none', 'the client goes')
        self.assertEqual([l for l in self.ide()[1] if l.startswith('conn ')], [])


class McpTest(BridgeCase):
    def setUp(self):
        super().setUp()
        self.start()
        self.c = self.client()

    def test_errors_as_json_rpc_says(self):
        self.assertEqual(self.c.call('nothing/here')['error'], {'code': -32601, 'message': 'Method not found'})
        self.assertEqual(self.c.tool('executeCode', {'code': '1'})['error'],
                         {'code': -32602, 'message': 'Unknown tool: executeCode'})
        self.c.send([{'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}])
        self.assertEqual(self.c.read(), {'jsonrpc': '2.0', 'id': None,
                                         'error': {'code': -32600, 'message': 'Invalid Request'}})

    def test_ids_come_back_as_they_went_and_notifications_get_nothing(self):
        self.c.send({'jsonrpc': '2.0', 'id': 'a"b', 'method': 'ping'})
        self.assertEqual(self.c.read()['id'], 'a"b')
        self.c.notify('notifications/cancelled', {'requestId': 3})
        self.c.notify('ide_connected', {'pid': 1})
        self.c.send({'jsonrpc': '2.0', 'id': 5, 'result': {}})         # a response: dropped
        self.c.send({'jsonrpc': '2.0', 'id': 9007199254740993, 'method': 'ping'})
        self.assertEqual(self.c.read()['id'], 9007199254740993)
        self.assertEqual(self.ide()[0]['method'], 'ping')


class ToolsTest(BridgeCase):
    def setUp(self):
        super().setUp()
        self.a = self.project / 'a.txt'
        self.start()
        self.c = self.client()

    def open_diff(self, new, tab='✻ [Claude Code] a.txt (1a2b) ⧉', path=None, old=None):
        path = str(path or self.a)
        self.c.next_id += 1
        rid = self.c.next_id
        self.c.send({'jsonrpc': '2.0', 'id': rid, 'method': 'tools/call',
                     'params': {'name': 'openDiff', 'arguments': {
                         'old_file_path': old or path, 'new_file_path': path,
                         'new_file_contents': new, 'tab_name': tab}}})
        self.until(lambda: self.offers(), 'the diff opens')
        return rid

    def answer(self, rid):
        result = self.c.wait_response(rid)['result']
        return [item['text'] for item in result['content']]

    def test_accepting_answers_file_saved_with_the_text_and_writes_nothing(self):
        before = self.a.read_bytes()
        mtime = self.a.stat().st_mtime_ns
        rid = self.open_diff('one\nTWO\nthree\nfour\nfive\n')
        offer = self.offers()[0]
        self.assertIn('label=✻ [Claude Code] a.txt (1a2b) ⧉ done=0', offer)
        self.command('review accept all')
        self.assertEqual(self.answer(rid), ['FILE_SAVED', 'one\nTWO\nthree\nfour\nfive\n'])
        self.assertEqual(self.a.read_bytes(), before)
        self.assertEqual(self.a.stat().st_mtime_ns, mtime)

    def test_a_change_rejected_is_left_out_of_the_text(self):
        rid = self.open_diff('one\nTWO\nthree\nfour\nfive\n')
        review = self.command('print-review')
        self.assertEqual(len([l for l in review.splitlines() if l.startswith('  hunk=')]), 2, review)
        self.command('review accept 1 1')
        self.command('review reject 1 2')
        self.assertEqual(self.answer(rid), ['FILE_SAVED', 'one\nTWO\nthree\nfour\n'])

    def test_rejecting_answers_diff_rejected_with_the_tab_name(self):
        rid = self.open_diff('changed\n', tab='my tab')
        self.command('review reject all')
        self.assertEqual(self.answer(rid), ['DIFF_REJECTED', 'my tab'])

    def test_closing_the_tab_rejects(self):
        rid = self.open_diff('changed\n', tab='closing')
        tabs = self.command('print-tabs')
        self.assertIn('Review: closing', tabs)
        self.command('cmd next_tab')
        self.command('cmd close_tab')
        self.assertEqual(self.answer(rid), ['DIFF_REJECTED', 'closing'])
        self.assertEqual(self.offers(), [])

    def test_the_tab_opens_without_the_keyboard(self):
        self.command('cmd toggle_terminal')
        state = self.command('print-state')
        self.open_diff('x\n')
        self.assertEqual(re.search(r' focus=(\d+) ', self.command('print-state')).group(1),
                         re.search(r' focus=(\d+) ', state).group(1))
        self.command('type a')                      # into the terminal, not an Accept
        self.assertIn('done=0', self.offers()[0])

    def test_close_tab_and_close_all(self):
        first = self.open_diff('1\n', tab='first')
        second = self.open_diff('2\n', tab='second')
        self.assertEqual(self.c.tool('close_tab', {'tab_name': 'first'})['result']['content'][0]['text'], 'TAB_CLOSED')
        self.assertEqual(self.answer(first), ['DIFF_REJECTED', 'first'])
        third = self.open_diff('3\n', tab='third')
        done = self.c.tool('closeAllDiffTabs', {})
        self.assertEqual(done['result']['content'][0]['text'], 'CLOSED_2_DIFF_TABS')
        self.assertEqual(self.answer(second), ['DIFF_REJECTED', 'second'])
        self.assertEqual(self.answer(third), ['DIFF_REJECTED', 'third'])
        self.assertEqual(self.offers(), [])
        self.assertEqual(self.c.tool('close_tab', {'tab_name': 'none'})['result']['content'][0]['text'], 'TAB_CLOSED')

    def test_an_accepted_diff_stays_until_close_tab(self):
        rid = self.open_diff('x\n', tab='kept')
        self.command('review accept all')
        self.answer(rid)
        self.assertIn('done=1', self.offers()[0])
        self.c.tool('close_tab', {'tab_name': 'kept'})
        self.assertEqual(self.offers(), [])

    def test_the_same_tab_name_again_rejects_the_first(self):
        first = self.open_diff('1\n', tab='same')
        second = self.open_diff('2\n', tab='same')
        self.assertEqual(self.answer(first), ['DIFF_REJECTED', 'same'])
        self.assertEqual(len(self.offers()), 1)
        self.command('review accept all')
        self.assertEqual(self.answer(second), ['FILE_SAVED', '2\n'])

    def test_a_file_outside_the_folders_is_not_read(self):
        outside = self.work / 'outside.txt'
        outside.write_text('secret\n', encoding='utf-8')
        for name, path in (('outside', outside), ('dot dot', self.project / '..' / 'outside.txt')):
            with self.subTest(name):
                rid = self.open_diff('new\n', tab=name, path=path)
                files = [l for l in self.command('print-review').splitlines() if ' file=' in l]
                self.assertIn(' -0 ', files[-1])            # nothing removed: the text before is empty
                self.command('review reject all')
                self.answer(rid)
                self.c.tool('close_tab', {'tab_name': name})

    def test_a_client_that_goes_closes_its_diffs(self):
        self.open_diff('x\n')
        self.c.close()
        self.until(lambda: not self.offers(), 'the diff closes')

    def test_bad_arguments(self):
        out = self.c.tool('openDiff', {'old_file_path': 'x'})['result']
        self.assertTrue(out['isError'])
        self.assertIn('must be strings', out['content'][0]['text'])
        big = self.c.tool('openDiff', {'old_file_path': str(self.a), 'new_file_path': str(self.a),
                                       'new_file_contents': 'x' * (4 * 1024 * 1024 + 1), 'tab_name': 't'})
        self.assertTrue(big['result']['isError'])

    def diagnostics(self, uri=None):
        out = self.c.tool('getDiagnostics', {'uri': uri} if uri else {})['result']
        self.assertFalse(out['isError'])
        text = out['content'][0]['text']
        self.assertEqual(text, json.dumps(json.loads(text), indent=2, ensure_ascii=False))
        return json.loads(text)

    def test_diagnostics_from_the_problems_and_the_open_files(self):
        self.assertEqual(self.diagnostics(), [])
        c_file = self.project / 'm.c'
        c_file.write_text('int x\né\U0001d11e y;\n', encoding='utf-8')
        report = self.work / 'cc.txt'
        report.write_text(f'{c_file}:2:5: error: expected token\n{c_file}:1:1: warning: careful\n', encoding='utf-8')
        out = self.command(f'term-run --matcher gcc --title cc -- cat {report}')
        self.command('wait-terminal %s exited' % out.split('=')[1].strip())
        self.until(lambda: 'expected token' in self.command('print-problems'), 'the problems')
        listed = self.diagnostics()
        self.assertEqual([d['uri'] for d in listed], ['file://' + str(c_file)])
        self.assertNotIn('linesInFile', listed[0])
        diags = listed[0]['diagnostics']
        self.assertEqual(diags[0], {'message': 'expected token', 'severity': 'Error',
                                    'range': {'start': {'line': 1, 'character': 4}, 'end': {'line': 1, 'character': 4}},
                                    'source': diags[0]['source']})
        self.assertEqual(diags[1]['severity'], 'Warning')
        # open, the same problems come from its marks: UTF-16 characters, the lines it has
        self.command(f'open {c_file}')
        self.until(lambda: 'linesInFile' in self.diagnostics()[0], 'the file is listed open')
        listed = self.diagnostics('file://' + str(c_file))
        self.assertEqual(listed[0]['linesInFile'], 3)
        starts = sorted((d['range']['start']['line'], d['range']['start']['character']) for d in listed[0]['diagnostics'])
        self.assertEqual(starts[0], (0, 0))
        self.assertEqual(starts[1][0], 1)
        # a file with nothing: its empty entry; a uri that names no file: an error
        self.assertEqual(self.diagnostics(str(self.a)), [{'uri': 'file://' + str(self.a), 'diagnostics': []}])
        bad = self.c.tool('getDiagnostics', {'uri': 'http://example.com/x'})['result']
        self.assertTrue(bad['isError'])
        self.assertEqual(bad['content'][0]['text'], 'uri must name a file')


class NotesTest(BridgeCase):
    def setUp(self):
        super().setUp()
        (self.project / 'u.txt').write_text('é\U0001d11ex\nline two\n', encoding='utf-8')
        self.start()
        self.c = self.client()

    def test_the_selection_goes_300_ms_after_it_last_changed(self):
        self.command(f'open {self.project / "u.txt"}')
        t0 = time.monotonic()
        self.command('key shift+End')
        note = self.c.note('selection_changed', 3)
        self.assertGreater(time.monotonic() - t0, 0.25)
        path = str(self.project / 'u.txt')
        self.assertEqual(note['params'], {'text': 'é\U0001d11ex', 'filePath': path, 'fileUrl': 'file://' + path,
                                          'selection': {'start': {'line': 0, 'character': 0},
                                                        'end': {'line': 0, 'character': 4}, 'isEmpty': False}})

    def test_a_run_of_changes_is_one_notification_and_the_same_selection_none(self):
        self.command(f'open {self.project / "u.txt"}')
        self.c.note('selection_changed', 3)                       # the file opened
        for key in ('Down', 'shift+End', 'shift+Home', 'shift+End'):
            self.command('key ' + key)
        note = self.c.note('selection_changed', 3)
        self.assertEqual(note['params']['text'], 'line two')
        with self.assertRaises(TimeoutError):
            self.c.note('selection_changed', 0.8)
        self.command('key Left')
        self.command('key shift+End')                             # the same selection again: nothing
        with self.assertRaises(TimeoutError):
            self.c.note('selection_changed', 0.8)

    def test_a_new_client_hears_the_selection_after_half_a_second(self):
        self.command(f'open {self.project / "a.txt"}')
        self.command('key shift+Down')
        self.c.note('selection_changed', 3)
        t0 = time.monotonic()
        later = self.client()
        note = later.note('selection_changed', 3)
        self.assertGreater(time.monotonic() - t0, 0.4)
        self.assertEqual(note['params']['text'], 'one\n')

    def test_at_mentioned_with_lines_and_without(self):
        self.command(f'open {self.project / "a.txt"}')
        self.assertEqual(self.command('ide-mention'), 'sent=1\n')
        self.assertEqual(self.c.note('at_mentioned', 3)['params'], {'filePath': str(self.project / 'a.txt')})
        self.command('key Down')
        self.command('key shift+Down')
        self.command('key shift+Down')
        self.command(f'key {MOD}+alt+k')
        self.assertEqual(self.c.note('at_mentioned', 3)['params'],
                         {'filePath': str(self.project / 'a.txt'), 'lineStart': 1, 'lineEnd': 3})

    def test_no_client_no_mention(self):
        self.c.close()
        self.until(lambda: self.ide()[0]['client'] == 'none', 'the client goes')
        self.command(f'open {self.project / "a.txt"}')
        self.assertEqual(self.command('ide-mention'), 'sent=0\n')


class TerminalModeTest(BridgeCase):
    def fake_claude(self):
        """A claude that prints its arguments and the bridge's variable, then waits a little."""
        prog = self.work / 'bin/claude'
        prog.parent.mkdir()
        prog.write_text('#!/bin/sh\necho "fake claude args=[$*] port=$CLAUDE_CODE_SSE_PORT pwd=$(pwd)"\nsleep 30\n',
                        encoding='utf-8')
        prog.chmod(0o755)
        return prog

    def terminals(self):
        return [l for l in self.command('print-terminals').splitlines() if 'title=' in l]

    def test_open_in_terminal_starts_claude_with_the_port(self):
        prog = self.fake_claude()
        self.start(f'[claude]\nexecutable = {prog}\n')
        port = self.port()
        self.command('cmd claude_open_terminal')
        self.until(lambda: self.terminals(), 'a terminal')
        self.assertIn('title=Claude Code', self.terminals()[0])
        self.until(lambda: 'fake claude' in self.term_text(), 'the program runs')
        self.assertIn(f'port={port} pwd={self.project}', self.term_text().replace('\n', ''))
        self.assertIn('focus=%d ' % 8, self.command('print-state'))      # FOCUS_TERMINAL

    def test_the_terminal_title_from_the_environment(self):
        prog = self.fake_claude()
        self.start(f'[claude]\nexecutable = {prog}\n', env={'CLAUDE_CODE_TERMINAL_TITLE': 'Mine'})
        self.command('cmd claude_open_terminal')
        self.until(lambda: self.terminals(), 'a terminal')
        self.assertIn('title=Mine', self.terminals()[0])

    def test_use_terminal_sends_open_and_the_key_to_the_terminal(self):
        prog = self.fake_claude()
        self.start(f'[claude]\nexecutable = {prog}\nuse_terminal = true\n')
        self.command('cmd agents_open')
        self.until(lambda: len(self.terminals()) == 1, 'a terminal')
        self.command(f'open {self.project / "a.txt"}')     # the editor has the keys (a terminal's program has them there)
        self.command(f'key {MOD}+Escape')
        self.until(lambda: len(self.terminals()) == 2, 'a second terminal: one each time, as the extension')

    def test_without_it_the_key_moves_the_keyboard_to_the_panel_and_back(self):
        self.start('[agents]\nclaude = false\ncodex = false\ngrok = false\nopencode = false\n')

        def focus():
            return int(re.search(r' focus=(\d+) ', self.command('print-state')).group(1))
        self.command(f'key {MOD}+Escape')
        self.assertEqual(focus(), 6)                    # FOCUS_AGENTS
        self.command(f'key {MOD}+Escape')
        self.assertEqual(focus(), 0)                    # FOCUS_EDITOR
        self.assertEqual(self.terminals(), [])


REAL = os.environ.get('RHUN_REAL_CLAUDE') == '1'


@unittest.skipUnless(REAL and sys.platform == 'darwin', 'the real CLI: RHUN_REAL_CLAUDE=1, on macOS')
class RealTest(BridgeCase):
    """The real, signed-in claude in rhun's terminal (one small prompt on Haiku, --permission-mode default, a
    temporary git repository): it connects, /ide shows rhun, it shows the selection, and its edit opens in the
    Review tab, is accepted there and written by the CLI. rhun keeps its own HOME, but its Claude folder is the
    real one (the env.HOME pair) and so is the terminal program's HOME: the lock file is in the real
    ~/.claude/ide for the run only. The CLI writes its own records under ~/.claude (session-env, file-history,
    backups, projects/<slug>, and ~/.claude.json's entry for the trusted folder); the projects folder of the
    test's repository is removed after it. ~/.claude/settings.json is compared by its checksum."""

    def test_the_real_cli(self):
        import hashlib
        import pwd
        import shutil
        home = Path(pwd.getpwuid(os.getuid()).pw_dir)
        settings = home / '.claude/settings.json'

        def checksum():
            return hashlib.sha256(settings.read_bytes()).hexdigest() if settings.exists() else None
        before = checksum()
        program = os.environ.get('RHUN_REAL_CLAUDE_EXE') or shutil.which('claude') or str(home / '.local/bin/claude')
        subprocess.run(['git', 'init', '-q'], cwd=self.project, check=True)
        self.start(f'[claude]\nenv.HOME = {home}\n')
        self.port()
        lock = self.ide()[0]['lock']
        self.assertTrue(lock.startswith(str(home / '.claude/ide/')), lock)
        try:
            self.command(f'open {self.project / "a.txt"}')
            self.command('key shift+End')
            self.command(f'term-run --env HOME={home} --title Claude -- {program} --permission-mode default '
                         '--model haiku')
            self.command('cmd toggle_terminal')

            def screen():
                return self.term_text()
            self.until(lambda: 'trust' in screen() or '\u276f' in screen(), 'the CLI starts', 60)
            if 'Yes, I trust this folder' in screen():
                self.command('key Down')
                self.command('key Return')
            self.until(lambda: self.ide()[0]['client'] != 'none', 'the CLI connects', 60)
            self.until(lambda: '1 line selected' in screen(), 'the selection shows', 20)
            self.command('type /ide')
            time.sleep(1)
            self.command('key Return')
            self.until(lambda: '\u2714 rhun' in screen(), '/ide shows rhun', 20)
            self.command('key Escape')
            time.sleep(1)
            self.command('type In a.txt replace the word two with TWO. Use the Edit tool. Do nothing else.')
            self.command('key Return')
            self.until(lambda: self.offers(), 'the edit opens in the Review tab', 180)
            self.assertIn('Opened changes in rhun', screen())
            self.command('review accept all')
            self.until(lambda: 'TWO' in (self.project / 'a.txt').read_text(encoding='utf-8'), 'the CLI writes', 60)
            self.assertEqual((self.project / 'a.txt').read_text(encoding='utf-8'), 'one\nTWO\nthree\nfour\n')
            self.command('type /exit')
            self.command('key Return')
            time.sleep(2)
        finally:
            self.stop()
            slug = re.sub(r'[^A-Za-z0-9]', '-', str(self.project))
            folder = home / '.claude/projects' / slug
            if folder.is_dir() and self.work.name in slug:
                shutil.rmtree(folder)
        self.assertFalse(Path(lock).exists())
        self.assertEqual(checksum(), before)


if __name__ == '__main__':
    unittest.main()
