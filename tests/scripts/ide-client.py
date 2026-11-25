#!/usr/bin/env python3
"""A client that plays terminal claude against rhun's bridge (src/app/ide_server.s), standard library only.
It does what Claude Code 2.1.330 was seen to do (tests/claude-bridge.py's notes): find the lock file of the
port in CLAUDE_CODE_SSE_PORT under <config>/ide, upgrade with x-claude-code-ide-authorization and
Sec-WebSocket-Protocol: mcp, then initialize, notifications/initialized, ide_connected, tools/list, over
masked text frames. Its methods also send what a careless or hostile peer would (raw bytes, unmasked or
oversized frames) for the tests of the server's limits.

As a program: ide-client.py CONFIG_DIR PORT [tools|diag [URI]] prints what the server answered."""
import base64
import hashlib
import json
import os
import socket
import struct
import sys
import time

GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'


def read_lock(config_dir, port):
    """The lock file's fields for that port."""
    with open(os.path.join(config_dir, 'ide', '%d.lock' % port), encoding='utf-8') as f:
        return json.load(f)


class Closed(Exception):
    """The server closed the connection (code, reason)."""


class Client:
    def __init__(self, port, token, protocol='mcp', timeout=10, extra=b'', key=None, connect=True):
        self.port = port
        self.token = token
        self.protocol = protocol
        self.timeout = timeout
        self.buf = b''
        self.messages = []          # every JSON message received, in order
        self.notes = []             # the notifications among them
        self.next_id = 0
        self.sock = socket.create_connection(('127.0.0.1', port), timeout=timeout)
        self.status = None
        self.headers = {}
        if connect:
            self.handshake(extra=extra, key=key)

    # ---- the upgrade ----
    def request(self, token=None, protocol=None, extra=b'', key=None):
        key = key or base64.b64encode(os.urandom(16)).decode()
        self.key = key
        lines = ['GET / HTTP/1.1', 'Host: 127.0.0.1:%d' % self.port, 'Connection: Upgrade', 'Upgrade: websocket',
                 'Sec-WebSocket-Version: 13', 'Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits',
                 'Sec-WebSocket-Key: ' + key, 'User-Agent: claude-code/2.1.330 (cli)']
        if protocol:
            lines.append('Sec-WebSocket-Protocol: ' + protocol)
        if token is not None:
            lines.append('X-Claude-Code-Ide-Authorization: ' + token)
        return ('\r\n'.join(lines) + '\r\n').encode() + extra + b'\r\n'

    def handshake(self, token=None, extra=b'', key=None):
        self.sock.sendall(self.request(self.token if token is None else token, self.protocol, extra, key))
        head = self.read_head()
        first, *rest = head.split('\r\n')
        self.status = int(first.split()[1])
        self.headers = {k.strip().lower(): v.strip() for k, v in (line.split(':', 1) for line in rest if ':' in line)}
        if self.status == 101:
            want = base64.b64encode(hashlib.sha1((self.key + GUID).encode()).digest()).decode()
            if self.headers.get('sec-websocket-accept') != want:
                raise AssertionError('bad Sec-WebSocket-Accept: %r' % self.headers)
        return self.status

    def read_head(self):
        deadline = time.monotonic() + self.timeout
        while b'\r\n\r\n' not in self.buf:
            if time.monotonic() > deadline:
                raise TimeoutError('no response')
            data = self.sock.recv(65536)
            if not data:
                raise Closed(None, 'closed before a response')
            self.buf += data
        head, self.buf = self.buf.split(b'\r\n\r\n', 1)
        return head.decode('latin-1')

    # ---- frames ----
    def frame(self, opcode, payload, fin=True, mask=True, rsv=0):
        header = bytes([(0x80 if fin else 0) | rsv | opcode])
        n = len(payload)
        bit = 0x80 if mask else 0
        if n < 126:
            header += bytes([bit | n])
        elif n < 65536:
            header += bytes([bit | 126]) + struct.pack('>H', n)
        else:
            header += bytes([bit | 127]) + struct.pack('>Q', n)
        if mask:
            key = os.urandom(4)
            payload = bytes(b ^ key[i % 4] for i, b in enumerate(payload)) if n < 65536 else \
                (int.from_bytes(payload, 'big') ^ int.from_bytes((key * (n // 4 + 1))[:n], 'big')).to_bytes(n, 'big')
            header += key
        return header + payload

    def send_frame(self, opcode, payload, **kw):
        self.sock.sendall(self.frame(opcode, payload, **kw))

    def send(self, obj):
        self.send_frame(1, json.dumps(obj).encode())

    def recv_exact(self, n, deadline):
        while len(self.buf) < n:
            left = deadline - time.monotonic()
            if left <= 0:
                raise TimeoutError('nothing came')
            self.sock.settimeout(left)
            try:
                data = self.sock.recv(65536)
            except socket.timeout:
                raise TimeoutError('nothing came')
            if not data:
                raise Closed(None, 'connection closed')
            self.buf += data
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def read_frame(self, timeout=None):
        """(fin, opcode, payload) of the next frame; the server's frames are never masked."""
        deadline = time.monotonic() + (self.timeout if timeout is None else timeout)
        b0, b1 = self.recv_exact(2, deadline)
        if b1 & 0x80:
            raise AssertionError('a masked frame from the server')
        n = b1 & 0x7f
        if n == 126:
            n = struct.unpack('>H', self.recv_exact(2, deadline))[0]
        elif n == 127:
            n = struct.unpack('>Q', self.recv_exact(8, deadline))[0]
        return b0 >> 7, b0 & 15, self.recv_exact(n, deadline)

    def read(self, timeout=None):
        """The next message (a dict); a close frame raises Closed(code, reason)."""
        while True:
            fin, op, payload = self.read_frame(timeout)
            if op == 8:
                code = struct.unpack('>H', payload[:2])[0] if len(payload) >= 2 else None
                raise Closed(code, payload[2:].decode('utf-8', 'replace'))
            if op == 9:
                self.send_frame(10, payload)
                continue
            if op in (1, 2):
                msg = json.loads(payload)
                self.messages.append(msg)
                if 'id' not in msg:
                    self.notes.append(msg)
                return msg

    def close_code(self, timeout=5):
        """Read until the server's close frame: its (code, reason)."""
        try:
            while True:
                self.read(timeout)
        except Closed as e:
            return e.args

    # ---- MCP ----
    def call(self, method, params=None, timeout=None):
        """A request; its response (notifications that come first are kept in notes)."""
        self.next_id += 1
        rid = self.next_id
        msg = {'method': method, 'jsonrpc': '2.0', 'id': rid}
        if params is not None:
            msg['params'] = params
        self.send(msg)
        return self.wait_response(rid, timeout)

    def wait_response(self, rid, timeout=None):
        for msg in self.messages:
            if msg.get('id') == rid:
                return msg
        while True:
            msg = self.read(timeout)
            if msg.get('id') == rid:
                return msg

    def notify(self, method, params=None):
        msg = {'jsonrpc': '2.0', 'method': method}
        if params is not None:
            msg['params'] = params
        self.send(msg)

    def start(self):
        """The CLI's start, as 2.1.330 does it: initialize, initialized, ide_connected, tools/list."""
        init = self.call('initialize', {
            'protocolVersion': '2025-11-25',
            'capabilities': {'roots': {'listChanged': True}, 'elicitation': {},
                             'extensions': {'io.modelcontextprotocol/tasks': {}}},
            'clientInfo': {'name': 'claude-code', 'title': 'Claude Code', 'version': '2.1.330'}})
        self.notify('notifications/initialized')
        self.notify('ide_connected', {'pid': os.getpid()})
        tools = self.call('tools/list')
        return init, tools

    def tool(self, name, arguments, timeout=None):
        return self.call('tools/call', {'name': name, 'arguments': arguments}, timeout)

    def note(self, method, timeout=None):
        """The next notification with that method (one already received is taken first)."""
        for i, msg in enumerate(self.notes):
            if msg.get('method') == method:
                return self.notes.pop(i)
        while True:
            msg = self.read(timeout)
            if msg.get('method') == method:
                self.notes.remove(msg)
                return msg

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def main():
    config, port = sys.argv[1], int(sys.argv[2])
    lock = read_lock(config, port)
    client = Client(port, lock['authToken'])
    init, tools = client.start()
    what = sys.argv[3] if len(sys.argv) > 3 else 'tools'
    if what == 'tools':
        print(json.dumps(init))
        print(json.dumps(tools))
    elif what == 'diag':
        args = {'uri': sys.argv[4]} if len(sys.argv) > 4 else {}
        print(client.tool('getDiagnostics', args)['result']['content'][0]['text'])
    client.close()


if __name__ == '__main__':
    main()
