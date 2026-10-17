#!/usr/bin/env python3
"""The echo extension: a fake extension for the host tests, standard library only.

It speaks protocol v1 as docs/extensions/v1.md says and does small, testable things when its
commands run. ECHO_LOG names a file that receives every line rhun sends, one per line, so a
test can assert catch-up and events. ECHO_MODE makes it misbehave:

  normal     answer hello, log events, act on commands
  nohello    never say hello
  slowhello  hello after 7 s (past the 5 s deadline)
  badhello   "hello 2"
  crash      exit 3 right after hello
  sleep      hello, then stop reading and writing
  flood      hello, then write toast requests forever as fast as it can (reading the replies)
  floodnoread the same without ever reading its input
  garbage    hello, then 100 KB of bytes with no newline
  fragment   normal, but every write goes out one byte at a time with flushes
  eof        hello, then close stdout and sleep
  syntax     hello, then three unparsable lines
  badargs    hello, then three requests with ids whose arguments cannot be parsed
  noisy      normal, but writes 2 MB to its error output after hello

Commands (from tests/ext/exts/rhun-tests/echo/extension.ini): echo.shout upper-cases the active document,
echo.hi inserts "hi" at the cursor, echo.toast shows a toast, echo.stale sends a replace with a
version one behind, echo.status sets the status text, echo.open opens ECHO_OPEN at line 2,
echo.mb asks for a range inside a character, echo.sel selects then reads the first word, echo.relopen
opens b.go by a relative path, echo.bad asks for a range outside the document.
Gate 4: echo.reg registers the runtime command echo.extra (ctrl+alt+9; it toasts "extra ran"),
echo.opt sets tab_width 8 and insert_spaces no on the active document, echo.optoff removes them,
echo.optsave sets trim_trailing_whitespace yes and final_newline no, echo.badopt sends a bad key,
echo.choose opens a pick list (the reply is toasted as "chose N"), echo.ask a text prompt (the
answer is toasted), echo.term proposes "echo ext-ran-ok" for the terminal, echo.cmd runs
select_all, echo.badcmd asks for quit, echo.die exits.
"""
import os
import sys
import threading
import time

MODE = os.environ.get('ECHO_MODE', 'normal')
LOG = os.environ.get('ECHO_LOG')
out = sys.stdout.buffer
inp = sys.stdin.buffer
next_id = 1
pending = {}            # id -> (verb, what to do with the reply)
SETTINGS = {}           # the extension's own settings, from the setting events


def log(line):
    if LOG:
        with open(LOG, 'ab') as f:
            f.write(line + b'\n')


def send(line, body=b''):
    data = line.encode() + b'\n' + body
    if MODE == 'fragment':
        for i in range(len(data)):
            out.write(data[i:i + 1])
            out.flush()
    else:
        out.write(data)
        out.flush()


def request(verb_and_args, body=b'', then=None):
    global next_id
    rid = next_id
    next_id += 1
    pending[rid] = (verb_and_args.split(' ', 1)[0], then)
    send(f'{rid} {verb_and_args}', body)
    return rid


def read_line():
    line = inp.readline()
    if not line:
        return None
    return line.rstrip(b'\r\n')


def read_body(n):
    data = b''
    while len(data) < n:
        chunk = inp.read(n - len(data))
        if not chunk:
            break
        data += chunk
    return data


# a picture with every shape (section 12a); the colors are ones a test looks for in a screenshot
PICTURE = (
    'rect 10 10 100 40 #ff0000\n'
    'rrect 120 10 100 40 8 #00ff00\n'
    'line 10 70 220 70 4 #0000ff\n'
    'poly 3 #ffff00 10 90 60 120 110 90 160 120\n'
    'fill #ff00ff 230 10 330 10 280 60\n'
    'circle 60 170 30 #00ffff\n'
    'ring 140 170 30 4 #ff8000\n'
    'pie 220 170 30 0 90 #8000ff\n'
    'shape-from-the-future 1 2 3\n'
    'clip 260 140 20 20\n'
    'rect 250 130 60 60 #804000\n'
    'unclip\n'
    'text 10 220 normal left fg Echo draws\n'
    'rect 400 10 50 50 #ff000000\n'
).encode()
if os.environ.get('ECHO_PICTURE'):
    PICTURE = os.environ['ECHO_PICTURE'].replace('|', '\n').encode() + b'\n'
VIEWS = []


def draw(view, picture=None):
    picture = PICTURE if picture is None else picture
    request(f'draw {view} {len(picture)}', picture)


def opened(fields, body):
    VIEWS.append(int(fields[2]))
    draw(int(fields[2]))

def main():
    global next_id
    log(f'pid {os.getpid()}'.encode())
    time.sleep(float(os.environ.get('ECHO_HELLO_DELAY', '0')))
    if MODE == 'exit70once':
        # the exit code rhun's child uses when it cannot confine itself: the program's own must not
        # buy it a second run without confinement
        mark = os.path.join(os.environ['RHUN_STATE'], 'exited-70')
        if not os.path.exists(mark):
            open(mark, 'w').close()
            sys.exit(70)
    if MODE == 'nohello':
        time.sleep(30)
        return
    if MODE == 'slowhello':
        time.sleep(7)
    if MODE == 'badhello':
        send('hello 2')
    elif MODE == 'features':
        send('hello 1 views bogus complete')     # section 12: rhun says back the ones it knows
    elif MODE == 'views':
        send('hello 1 views')
    elif MODE in ('complete', 'completebad', 'completemore', 'completecursor'):
        send('hello 1 complete signature')
    elif MODE == 'lang':
        send('hello 1 definition references symbols actions rename format')
    else:
        send('hello 1')
    if MODE == 'crash':
        sys.exit(3)
    if MODE == 'sleep':
        time.sleep(600)
        return
    if MODE in ('flood', 'floodnoread'):
        if MODE == 'flood':
            threading.Thread(target=lambda: inp.read(), daemon=True).start()
        while True:
            # a thousand requests per write: a flooder is not held back by its own flushes, and the
            # pipe keeps a backlog when the machine is busy
            out.write(b''.join(f'{next_id + i} toast 5\nflood'.encode() for i in range(1000)))
            out.flush()
            next_id += 1000
    if MODE == 'garbage':
        out.write(b'x' * 100000)
        out.flush()
        time.sleep(600)
        return
    if MODE == 'eof':
        os.close(1)             # the stream objects keep fd 1 open when closed; the fd itself must go
        time.sleep(600)
        return
    if MODE == 'syntax':
        for _ in range(3):
            send('this is not a message')
        time.sleep(600)
        return
    if MODE == 'badargs':
        for i in range(1, 4):
            send(f'{i} insert blah')
        time.sleep(600)
        return
    if MODE == 'badbodies':
        # three body requests whose lines cannot be parsed: the third ends the program while its
        # body is still in the buffer
        for i in range(1, 4):
            send(f'{i} insert 1 x 1', b'x')
        time.sleep(600)
        return
    if MODE == 'noisy':
        sys.stderr.write('x' * (2 * 1024 * 1024))
        sys.stderr.flush()

    active = 0
    versions = {}
    while True:
        line = read_line()
        if line is None:
            return
        log(line)
        fields = line.decode(errors='replace').split(' ')
        if fields[0] == 'ok' or fields[0] == 'error':
            rid = int(fields[1])
            verb, then = pending.pop(rid, (None, None))
            body = b''
            if fields[0] == 'ok' and verb in ('text', 'range', 'ask') and len(fields) >= 3:
                body = read_body(int(fields[-1]))
                log(body)
            if then and fields[0] == 'ok':
                then(fields, body)
            continue
        if fields[0] != '0':
            if fields[0].isdigit() and len(fields) >= 6 and MODE == 'lang':
                on_lang_request(int(fields[0]), fields[1], fields[2:])
            elif fields[0].isdigit() and len(fields) >= 8:
                on_host_request(int(fields[0]), fields[1], fields[2:])
            continue
        event = fields[1]
        if event == 'action':
            log(read_body(int(fields[2])))
            continue
        if event == 'ready':
            PROJECT[0] = line.decode(errors='replace').split(' ', 2)[2]
        if event == 'opened':
            parts = line.decode(errors='replace').split(' ', 5)
            PATHS[int(fields[2])] = parts[5]
        if event == 'opened':
            versions[int(fields[2])] = int(fields[3])
        elif event in ('changed', 'saved'):
            versions[int(fields[2])] = int(fields[3])
        elif event == 'active':
            active = int(fields[2])
        elif event == 'bye':
            return
        elif event == 'setting':
            parts = line.decode(errors='replace').split(' ', 3)    # 0 setting KEY VALUE
            SETTINGS[parts[2]] = parts[3] if len(parts) > 3 else ''
        elif event == 'hover':
            d, line, col = int(fields[2]), fields[3], fields[4]
            text = f'hovering {line}:{col}'.encode()
            request(f'hover {d} {line} {col} {len(text)}', text)
        elif event == 'edits':
            body = read_body(int(fields[-1]))
            log(body.replace(b'\n', b'\\n'))
        elif event == 'run':
            command, doc = fields[2], int(fields[3])
            on_run(command, doc, versions)
            if command.endswith('.die'):
                sys.exit(0)


# completion items (section 12b): label, insert, detail, kind, documentation, an extra edit
ITEMS = [
    ('print', 'print()', 'fn print()', 'function', 'Prints a line.', None),
    ('println', 'println!()', 'macro', 'function', '', None),
    ('printf', 'printf("")', '', 'function', '', None),
    ('process', 'process', 'mod process', 'module', '', (1, 1, 1, 1, 'use std::process;\n')),
    ('private', 'private', '', 'keyword', '', None),
    ('printd', 'printd', '', 'function', '', ('NEXT', 1, 'NEXT', 1, '// after\n')),
]
SIGNATURE = b'fn add(a: i32, b: i32)'


def complete_body(line, start, col, more=0):
    out = b''
    for label, insert, detail, kind, doc, edit in ITEMS:
        extra = b''
        if edit:
            l1, c1, l2, c2, text = edit
            l1 = line + 1 if l1 == 'NEXT' else l1     # the line under the cursor's
            l2 = line + 1 if l2 == 'NEXT' else l2
            extra += f'edit {l1} {c1} {l2} {c2} {len(text.encode())}\n'.encode() + text.encode()
        if doc:
            extra += f'doc {len(doc.encode())}\n'.encode() + doc.encode()
        if MODE == 'completecursor' and label == 'print':
            extra += b'cursor 6 0\n'          # between the parentheses
        if MODE == 'completecursor' and label == 'println':
            extra += b'cursor 99 0\n'         # past the text: left out
        lb, ib, db = label.encode(), insert.encode(), detail.encode()
        out += (f'{line} {start} {line} {col} {kind} {len(lb)} {len(ib)} {len(db)} {len(extra)}\n'.encode()
                + lb + ib + db + extra)
    n = len(ITEMS)
    if MODE == 'completebad':
        n += 1                  # says one more item than it sends: the whole list is dropped
    return f'{n} {more}\n'.encode() + out


def on_host_request(rid, verb, args):
    doc, line, col, kind = int(args[0]), int(args[2]), int(args[3]), args[4]

    def answer(fields, body):
        text = body.split(b'\n')[line - 1] if line - 1 < len(body.split(b'\n')) else b''
        if verb == 'complete':
            start = col
            while start > 1 and (text[start - 2:start - 1].isalnum() or text[start - 2:start - 1] == b'_'):
                start -= 1
            reply = complete_body(line, start, col, 1 if MODE == 'completemore' else 0)
            if 'ECHO_COMPLETE_REPLY' in os.environ:
                reply = os.environ['ECHO_COMPLETE_REPLY'].encode()
        elif verb == 'signature':
            before = text[:col - 1]
            open_at = before.rfind(b'(')
            if open_at < 0:
                reply = b''
            else:
                params = [(7, 13), (15, 21)]
                active = params[min(before[open_at:].count(b','), 1)]
                reply = f'{active[0]} {active[1]}\n'.encode() + SIGNATURE + b'\nAdds two numbers.\nOverflow wraps.'
        else:
            send(f'error {rid} unknown no such request')
            return
        send(f'ok {rid} {len(reply)}', reply)
    request(f'text {doc}', then=answer)


PROJECT = ['-']
PATHS = {}


def workspace_edit(groups):
    """A workspace edit body (12g): groups of (path, version or '-', [(l1, c1, l2, c2, text)])."""
    out = f'{len(groups)}\n'.encode()
    for path, version, edits in groups:
        p = path.encode()
        out += f'{len(p)} {version} {len(edits)}\n'.encode() + p
        for l1, c1, l2, c2, text in edits:
            t = text.encode()
            out += f'{l1} {c1} {l2} {c2} {len(t)}\n'.encode() + t
    return out


def on_lang_request(rid, verb, args):
    doc, version = int(args[0]), int(args[1])
    twist = os.environ.get('ECHO_LANG', '')
    if twist == 'exit':
        sys.exit(0)
    if twist == 'error':
        send(f'error {rid} refused "x" is already a name here')
        return
    path = PATHS.get(doc, f'#{doc}')
    other = PROJECT[0] + '/other.rs'

    def answer(fields, body):
        lines = body.decode().split('\n')
        if verb == 'definition' and twist == 'relpath':
            reply = b'1\n' + loc('p.rs', 1, 5, 1, 9, lines[0])
        elif verb == 'definition':
            reply = b'1\n' + loc(path, 1, 5, 1, 9, lines[0])
        elif verb == 'references' and twist == 'trailing':
            reply = b'1\n' + loc(path, 2, 13, 2, 17, lines[1]) + b'junk'
        elif verb == 'references' and twist == 'sorted':
            reply = (b'3\n' + loc(PROJECT[0] + '/z.rs', 1, 1, 1, 2, 'z') + loc(other, 1, 4, 1, 8, 'fn main_ref() {}')
                     + loc(path, 2, 13, 2, 17, lines[1]))
        elif verb == 'references':
            reply = b'2\n' + loc(other, 1, 4, 1, 8, 'fn main_ref() {}') + loc(path, 2, 13, 2, 17, lines[1])
        elif verb == 'symbols':
            reply = b'2\n' + sym(1, 1, 3, 2, 'function', 0, 'main', 'fn()') + sym(2, 9, 2, 10, 'variable', 1, 'x', '')
        elif verb == 'actions':
            title1, title2 = b'Say hello', b'Add a comment'
            edit = workspace_edit([(path, version, [(1, 1, 1, 1, '// fixed\n')])])
            reply = (b'2\n' + f'source {len(title1)} 0 5\n'.encode() + title1 + b'hello'
                     + f'quickfix {len(title2)} {len(edit)} 0\n'.encode() + title2 + edit)
        elif verb == 'rename':
            name = args[5]
            stale = version + 1 if os.environ.get('ECHO_STALE') else version
            edits = []
            for i, text in enumerate(lines):
                start = 0
                while (j := text.find('main', start)) >= 0:
                    edits.append((i + 1, j + 1, i + 1, j + 5, name))
                    start = j + 4
            reply = workspace_edit([(path, stale, edits), (other, '-', [(1, 4, 1, 8, name)])])
        elif verb == 'format' and twist == 'other':
            reply = workspace_edit([(other, '-', [(1, 1, 1, 1, '// formatted\n')])])
        elif verb == 'format' and twist == 'overlap':
            reply = workspace_edit([(path, version, [(1, 1, 1, 6, 'a'), (1, 3, 1, 9, 'b')])])
        elif verb == 'format' and twist == 'outside':
            reply = workspace_edit([(path, version, [(1, 1, 1, 6, 'a'), (9, 1, 9, 1, 'b')])])
        elif verb == 'format':
            reply = workspace_edit([(path, version, [(1, 1, 1, len(lines[0].encode()) + 1, 'fn main() {')])])
        else:
            send(f'error {rid} unknown no such request')
            return
        send(f'ok {rid} {len(reply)}', reply)
    request(f'text {doc}', then=answer)


def loc(path, l1, c1, l2, c2, text):
    p, t = path.encode(), text.encode()
    return f'{l1} {c1} {l2} {c2} {len(p)} {len(t)}\n'.encode() + p + t


def sym(l1, c1, l2, c2, kind, depth, name, detail):
    n, d = name.encode(), detail.encode()
    return f'{l1} {c1} {l2} {c2} {kind} {depth} {len(n)} {len(d)}\n'.encode() + n + d


def on_run(command, doc, versions):
    name = command.split('.', 1)[1]
    if name == 'toast':
        request('toast 11', b'hello there')
    elif name == 'status':
        request('status 7', b'echo ok')
    elif name == 'hi':
        request(f'insert {doc} {versions.get(doc, 0)} 2', b'hi')
    elif name == 'shout':
        def got_text(fields, body):
            version = int(fields[2])
            lines = body.count(b'\n') + 1
            last_len = len(body) - (body.rfind(b'\n') + 1)
            upper = body.upper()
            request(f'replace {doc} {version} 1 1 {lines} {last_len + 1} {len(upper)}', upper)
        request(f'text {doc}', then=got_text)
    elif name == 'stale':
        request(f'replace {doc} {max(versions.get(doc, 1) - 1, 0)} 1 1 1 1 5', b'stale')
    elif name == 'open':
        path = os.environ.get('ECHO_OPEN', '')
        request(f'open 2 1 {path}')
    elif name == 'bad':
        request(f'range {doc} 999 1 999 2')
    elif name == 'mb':
        request(f'range {doc} 1 1 1 3')       # col 3 of "héllo" is inside the é
    elif name == 'sel':
        def selected(fields, body):
            request(f'range {doc} 1 1 1 6')
        request(f'select {doc} 1 1 1 6', then=selected)
    elif name == 'relopen':
        request('open 1 1 b.go')
    elif name == 'diag':
        body = (b'1 1 1 6 error first word\n'
                b'2 1 2 7 warning second word\n'
                b'2 8 2 12 info a note\n')
        request(f'diagnostics {doc} {versions.get(doc, 0)} 3 {len(body)}', body)
    elif name == 'nodiag':
        request(f'diagnostics {doc} {versions.get(doc, 0)} 0 0')
    elif name == 'baddiag':
        body = os.environ.get('ECHO_BAD_DIAG', '1 1 x 6 error nope\n').encode('utf-8')
        request(f'diagnostics {doc} {versions.get(doc, 0)} 1 {len(body)}', body)
    elif name == 'stalediag':
        request(f'diagnostics {doc} 0 0 0')
    elif name == 'reg':
        request('register extra ctrl+alt+9 Extra Command')
    elif name == 'extra':
        request('toast 9', b'extra ran')
    elif name == 'opt':
        request(f'option {doc} tab_width 8')
        request(f'option {doc} insert_spaces no')
    elif name == 'optoff':
        request(f'option {doc} tab_width -')
        request(f'option {doc} insert_spaces -')
    elif name == 'optsave':
        request(f'option {doc} trim_trailing_whitespace yes')
        request(f'option {doc} final_newline no')
    elif name == 'badopt':
        request(f'option {doc} wrap yes')
        request(f'option {doc} tab_width 99')
    elif name == 'choose':
        def chose(fields, body):
            text = f'chose {fields[2]}'.encode()
            request(f'toast {len(text)}', text)
        body = b'Pick one\nalpha\nbeta\ngamma\n'
        request(f'choose {len(body)}', body, then=chose)
    elif name == 'ask':
        def answered(fields, body):
            text = b'answer ' + body
            request(f'toast {len(text)}', text)
        request('ask 10', b'Your name?', then=answered)
    elif name == 'term':
        request('term 15', b'echo ext-ran-ok')
    elif name == 'cmd':
        request('cmd select_all')
    elif name == 'badcmd':
        request('cmd quit')
        request('cmd no_such_command')
        request('cmd paste')
    elif name == 'termcmd':
        request('cmd toggle_terminal')
    elif name == 'emptymark':
        request(f'diagnostics {doc} {versions.get(doc, 0)} 1 17', b'1 7 1 7 hint here\n')
    elif name == 'countdiag':
        body = b'1 1 1 6 error first\n'
        request(f'diagnostics {doc} {versions.get(doc, 0)} 2 {len(body)}', body)   # N says two lines
    elif name == 'bidi':
        request('term 11', 'rm -rf \u202e x'.encode())
    elif name == 'view':
        request('view Echo picture', then=opened)
    elif name == 'badview':
        if VIEWS:
            draw(VIEWS[-1], b'rect 1 2 3\n')
    elif name == 'unview':
        if VIEWS:
            request(f'unview {VIEWS.pop()}')
    elif name in ('apply', 'applystale', 'applyoverlap'):
        version = versions.get(doc, 0) + (1 if name == 'applystale' else 0)
        here = [(1, 1, 1, 3, 'FN')] if name != 'applyoverlap' else [(1, 1, 1, 3, 'FN'), (1, 2, 1, 4, 'x')]
        other = [(1, 1, 1, 1, '// applied\n')]
        twist = os.environ.get('ECHO_APPLY', '')
        target = PATHS.get(doc, f'#{doc}')
        if twist == 'dash':          # made from the disk for a document that is open
            version = '-'
        elif twist == 'bigcoord':    # a column that wraps to 1 in 32 bits
            here = [(1, 4294967297, 1, 4294967298, 'X')]
        elif twist == 'many':        # 6000 insertions, last first
            here = [(1, 1 + (i % 2), 1, 1 + (i % 2), str(i % 10)) for i in range(6000)][::-1]
        elif twist == 'untitled':    # the untitled document by its id, and a file to open
            target = f'#{doc}'
            here = [(1, 1, 1, 1, 'untitled text')]
        elif twist == 'replins':     # a replacement, then an insertion where it starts
            here = [(1, 1, 1, 3, 'FN'), (1, 1, 1, 1, '<')]
        elif twist in ('alias', 'aliasbad'):
            target = PROJECT[0] + '/./p.rs'
            version = '-'
            if twist == 'aliasbad':
                here = [(999, 1, 999, 2, 'X')]
        elif twist == 'badref':
            target = f'#{doc}x'
        groups = [(target, version, here), (PROJECT[0] + ('/missing.rs' if twist == 'missing' else '/other.rs'), '-', other)]
        if twist == 'relative':
            groups[1] = ('other.rs', '-', other)
        elif twist == 'outside':
            groups[1] = (os.environ['ECHO_OPEN'], '-', other)
        body = workspace_edit(groups)
        request(f'apply {len(body)}', body)
    elif name == 'faredit':
        # the same number of bytes, far from the cursor: fn becomes FN on line 1
        request(f'replace {doc} {versions.get(doc, 0)} 1 1 1 3 2', b'FN')
    elif name == 'staleview':
        # a line with a number in field 2, then one without: the second must not see the first's
        request(f'frob {VIEWS[-1] if VIEWS else 1}')
        request('unview')
    elif name == 'manyviews':
        for i in range(9):
            request(f'view View {i + 1}')
    elif name == 'greet':
        text = SETTINGS.get('greeting', '').encode()
        if SETTINGS.get('loud') == 'yes':
            text = text.upper()
        request(f'insert {doc} {versions.get(doc, 0)} {len(text)}', text)
    elif name == 'first':
        request(f'replace {doc} {versions.get(doc, 0)} 1 1 1 2 3', b'XYZ')
    # confinement probes (tests/ext-confine.py): each toasts what happened
    elif name == 'pwrite':
        probe(lambda: open(os.path.join(os.environ['RHUN_PROJECT'], 'written-by-echo.txt'), 'w').write('x'))
    elif name == 'hread':
        probe(lambda: open(os.environ['ECHO_SECRET']).read())
    elif name == 'swrite':
        probe(lambda: open(os.path.join(os.environ['RHUN_STATE'], 'state.txt'), 'w').write('x'))
    elif name == 'net':
        def connect():
            import socket
            s = socket.socket()
            s.settimeout(3)
            rc = s.connect_ex(('1.1.1.1', 80))
            s.close()
            if rc in (1, 13, 101):   # EPERM or EACCES (TCP rules), ENETUNREACH (a network namespace)
                raise PermissionError('errno %d' % rc)
        probe(connect)
    elif name == 'exec':
        def run_ls():
            import subprocess
            subprocess.run(['/bin/ls', '/usr'], capture_output=True, check=True)   # a folder the rules let it read
        probe(run_ls)


def probe(fn):
    try:
        fn()
        text = b'probe ok'
    except PermissionError:
        text = b'probe refused'
    except Exception as e:      # noqa: BLE001 - the kind matters, not the message
        text = ('probe failed ' + type(e).__name__).encode()[:200]
    request(f'toast {len(text)}', text)


if __name__ == '__main__':
    try:
        main()
    except BrokenPipeError:
        pass
