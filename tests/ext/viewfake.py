#!/usr/bin/env python3
"""The viewfake extension: retained views for the host tests (tests/ext-views-tree.py), standard
library only. It agrees view-tree, fills its declared views when they open and changes them when
its commands run. VIEWFAKE_LOG receives every line rhun sends and every reply, one per line (a
body after its line). VIEWFAKE_MODE: normal, nofeature (agrees nothing).

Commands: rescan (the same ids again, with a new count), renamed (new ids), vanish (removes the
selected node), badpatch (a patch whose third op names a missing node), big (100001 nodes), show
(vshow items focus), empty (state empty with a text and a key), msg (a message line), busy (busy 1),
expand (expands f:main.rs), reveal (vreveal t:lib.rs:1 select,focus after collapsing lib.rs),
multi (items becomes multi-select), delpin (removes the pin action), log (lines of every severity
with SGR colors to the logs view), logmany (12000 lines), logclear, tab (a tree in an editor tab
of its own), untab (unview of that tab), clearmain (f:main.rs keeps no children), loadthen (state loading, then the root's children again),
note, noteask (a
warning with Reload, which runs rescan, and Later), noteerr, notemany (6 sticky), notes17, noteset,
unnote, prog (status, cancellable, then 42% "crates"), prognote, progview (in todo), progbad,
progend (VIEWFAKE_NOTIFY agrees notify and progress), img (a red PNG drawn in pic), badimg,
imgs65, unimg (twice), tabpic (a 12a tab picture; VIEWFAKE_PIC agrees views, view-images and,
unless it is nokeys, view-keys; a vcopy is answered "copied text" or "cut text"), tbsorted,
tbmore, tbadd, tbbad, tbtree (the files table, VIEWFAKE_TABLE: the owner's arrow, paged rows, one
row added, bad columns, columns on the todo tree), fatset (seven 3 MB set patches), fatrelist (the root's children again, smaller, then 3 MB more). VIEWFAKE_NOLOG:
view-log is not asked for. VIEWFAKE_DELAY: seconds before hello.

The items view (panel) has a lazy node "a" (its children come with vkids: VIEWFAKE_LAZY answer,
error, late (after 1 s), or never) and pages of root children (vmore adds two, three pages).
TODO has a title action "rescan" and node actions "pin" (inline) and "pin hide" (menu).
"""
import threading
import time
import os
import struct
import sys
import zlib

MODE = os.environ.get('VIEWFAKE_MODE', 'normal')
LOG = os.environ.get('VIEWFAKE_LOG')
ROOT = os.environ.get('VIEWFAKE_ROOT', '/nonexistent')
out = sys.stdout.buffer
inp = sys.stdin.buffer
LAZY = os.environ.get('VIEWFAKE_LAZY', 'answer')
next_id = 1
lock = threading.Lock()
views = {}              # manifest key -> VIEW
selected = {}           # VIEW -> selected node id
rescans = 0


def log(data):
    if LOG:
        with open(LOG, 'ab') as f:
            f.write(data + b'\n')


def send(line, body=b''):
    with lock:
        out.write(line.encode() + b'\n' + body)
        out.flush()


def request(verb, body=None):
    global next_id
    rid = next_id
    next_id += 1
    if body is None:
        send(f'{rid} {verb}')
    else:
        send(f'{rid} {verb} {len(body)}', body)
    return rid


def rec(name, args='', data=b''):
    head = f'{name} {args} {len(data)}' if args else f'{name} {len(data)}'
    return head.encode() + b'\n' + data


def node(nid, label, kids='leaf', extra=b''):
    nid, label = nid.encode(), label.encode()
    return f'{len(nid)} {len(label)} {len(extra)} {kids}\n'.encode() + nid + label + extra


def kids(parent, nodes, more=0, op='kids'):
    parent = parent.encode()
    data = parent + b''.join(nodes)
    return rec(op, f'{len(parent)} {len(nodes)} {more}', data)


def patch(view, ops):
    body = f'{len(ops)}\n'.encode() + b''.join(ops)
    return request(f'vpatch {view}', body)


def todo_tree(view, prefix='', count=2):
    files = [('main.rs', 'src', 2), ('lib.rs', 'src', 1), ('README.md', '', 1)]
    ops = [rec('title', data=b'TODO'), rec('badge', '4'), rec('action', 'rescan refresh title', b'Rescan'),
           rec('action', 'pin pin node', b'Pin'), rec('action', 'hide - node', b'Hide')]
    top = []
    for name, folder, n in files:
        extra = rec('icon', f'file:{name} -') + rec('badge', f'{n}') + rec('ctx', data=b'file')
        if folder:
            extra = rec('desc', data=folder.encode()) + extra
        top.append(node(f'{prefix}f:{name}', name, 'open', extra))
    ops.append(kids('', top))
    for name, folder, n in files:
        path = os.path.join(ROOT, folder, name) if folder else os.path.join(ROOT, name)
        items = []
        for i in range(n):
            text = f'TODO: item {i + 1} of {name} ({count})'
            extra = rec('hl', '0 4') + rec('icon', 'warning warning') + \
                rec('open', f'{i + 1} 1', path.encode()) + rec('tip', data=f'tip of {i + 1}'.encode()) + \
                rec('inline', data=b'pin') + rec('menu', data=b'pin hide')
            items.append(node(f'{prefix}t:{name}:{i + 1}', text, 'leaf', extra))
        ops.append(kids(f'{prefix}f:{name}', items))
    ops.append(rec('state', 'ready 0'))
    patch(view, ops)


def items_tree(view):
    ops = [kids('', [node('a', 'Alpha', 'closed'), node('b', 'Beta'), node('c', 'Gamma', 'leaf', rec('check', '0'))],
                more=1)]
    ops.append(rec('state', 'ready 0'))
    patch(view, ops)


pages = 0
pending_tab = []        # vtab requests waiting for their view's number
tabs = []
on_reply = {}           # request id -> fn(fields) for its ok
notes = []              # NOTE of each notification rhun took, in order
progs = []              # P of each progress


images = []             # IMG of each image rhun took
PIC = os.environ.get('VIEWFAKE_PIC', '')


def png(w, h, rgba):
    """A w x h PNG of one RGBA color."""
    def chunk(kind, data):
        c = kind + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    raw = b''.join(b'\0' + bytes(rgba) * w for _ in range(h))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


seqs = {}               # a form field's last sequence heard


def frec(key, typ, row, weight, label, extra=b''):
    label = label.encode()
    return f'{key} {typ} {row} {weight} {len(label)} {len(extra)}\n'.encode() + label + extra


def setup_form(view):
    fields = [frec('name', 'text', 1, 2, 'Name', rec('placeholder', data=b'your name') + rec('value', '-', b'Ada')),
              frec('port', 'number', 1, 1, 'Port', rec('range', '1 65535 1') + rec('value', '-', b'8080')),
              frec('notes', 'area', 2, 1, 'Notes', rec('lines', '3')),
              frec('tls', 'check', 3, 1, 'Use TLS', rec('value', '-', b'yes')),
              frec('mode', 'select', 3, 1, 'Mode', rec('options', data=b'fast\nsafe\nslow') + rec('value', '-', b'safe')),
              frec('go', 'button', 4, 1, 'Connect', rec('primary', '0'))]
    patch(view, [rec('form', f'{len(fields)}', b''.join(fields))])


def col(align, width, sort, title):
    return f'{align} {width} {sort} {len(title)}\n{title}'.encode()


def row(nid, label, *cells, kids='leaf'):
    return node(nid, label, kids, b''.join(rec('cell', data=c.encode()) for c in cells))


def files_table(view, more=0):
    cols = [col('left', 0, 'sort', 'Name'), col('right', 6, 'sort', 'Size'), col('left', 8, '-', 'Kind')]
    ops = [rec('columns', '3', b''.join(cols)),
           kids('', [row('b', 'b.txt', '120', 'file'), row('a', 'a.txt', '9', 'file'), row('d', 'dir', '-', 'folder', kids='open'),
                     row('w', 'wide.txt', '7', 'a kind of file whose name is long enough to be cut')], more=more),
           kids('d', [row('d2', 'z.rs', '2', 'file'), row('d1', 'y.rs', '10', 'file')]),
           rec('state', 'ready 0')]
    patch(view, ops)


quick_q = []            # Q of the quick input rhun took


def qitem(iid, label, kind='item', extra=b''):
    iid, label = iid.encode(), label.encode()
    return f'{len(iid)} {len(label)} {len(extra)} {kind}\n'.encode() + iid + label + extra


def qitems(items):
    return rec('items', f'{len(items)}', b''.join(items))


def qbutton(key, icon, tip):
    return f'{key} {icon} {len(tip)}\n{tip}'.encode()


def quick_step1():
    del_btn = rec('button', 'del discard', b'Delete')
    items = [qitem('', 'Local', 'sep'), qitem('main', 'main', extra=rec('desc', data=b'current') + del_btn),
             qitem('dev', 'dev', extra=rec('detail', data=b'3 commits ahead') + del_btn),
             qitem('', 'Remote', 'sep'), qitem('origin/main', 'origin/main', extra=rec('icon', 'cloud -'))]
    return [rec('title', data=b'Branch'), rec('step', '1 3', b''), rec('placeholder', data=b'Pick a branch'),
            rec('flags', 'back', b''), rec('buttons', '1', qbutton('refresh', 'refresh', 'Refresh')), qitems(items)]


def quick_open(ops):
    body = b''.join(ops)
    rid = request('quick', body)

    def took(f):
        quick_q.append(int(f[2]))
    on_reply[rid] = took


def quick_set(ops):
    if quick_q:
        request(f'quick-set {quick_q[-1]}', b''.join(ops))


def quick_event(fields, body):
    """0 quick Q accept SEQ N LEN: text "bad" gets an error message for that sequence, else step 2."""
    if fields[3] == 'accept':
        lines = body.split(b'\n')
        text = lines[-1]
        if text == b'bad':
            quick_set([rec('msg', f'{fields[4]} error', b'not a branch')])
        else:
            quick_set([rec('title', data=b'Step two'), rec('step', '2 3', b''), rec('value', '0', b''),
                       qitems([qitem('x', 'Create x'), qitem('y', 'Create y')])])


opened_docs = []        # DOC of each document rhun said it opened
README = '''# Readme

Some text with [a guide](docs/guide%20one.md), [an anchor](#second-part), [custom](custom:thing) and
[missing](nothing.md).

''' + 'filler paragraph\n\n' * 30 + '''## Second part

The end.
'''


def readme_doc(view, base=True):
    ops = [rec('doc', '', README.encode())]
    if base:
        ops.append(rec('base', '', ROOT.encode()))
    patch(view, ops)


def draw(view, picture):
    request(f'draw {view}', picture.encode())


def vimage(data, then=None):
    rid = request('vimage', data)

    def took(f):
        images.append(int(f[2]))
        if then:
            then(int(f[2]))
    on_reply[rid] = took


def note_body(msg, detail=None, buttons=(), sticky=False):
    extra = b''
    if detail:
        extra += rec('detail', data=detail.encode())
    if sticky:
        extra += rec('sticky', '0')
    for title, command in buttons:
        extra += rec('button', data=title.encode())
        if command:
            extra += rec('command', f'{command}', b'')
    msg = msg.encode()
    return f'{len(msg)} {len(extra)}\n'.encode() + msg + extra


def notify(sev, body):
    rid = request(f'notify {sev}', body)
    on_reply[rid] = lambda f: notes.append(int(f[2]))


def progress(where, cancel, title):
    rid = request(f'progress {where} {cancel}', title.encode())
    on_reply[rid] = lambda f: progs.append(int(f[2]))
    return rid


def answer(rid, body):
    send(f'ok {rid} {len(body)}', body)


def host_request(rid, verb, fields, body):
    """vkids VIEW REV LEN + id, vmore VIEW REV HAVE LEN + id."""
    global pages
    if verb == 'vkids':
        nid = body.decode()
        if LAZY == 'error':
            send(f'error {rid} refused cannot list {nid}')
            return
        if LAZY == 'never':
            return
        reply = f'1\n'.encode() + kids(nid, [node(nid + '1', nid.upper() + ' one'), node(nid + '2', nid.upper() + ' two')])
        if LAZY == 'late':
            threading.Timer(1.0, answer, (rid, reply)).start()
        else:
            answer(rid, reply)
    elif verb == 'vmore' and views.get('files') == int(fields[1]):
        return                  # the files table's next page never comes: it stays paged
    elif verb == 'vmore':
        pages += 1
        have = int(fields[3])
        more = 1 if pages < 3 else 0
        items = [node(f'p{have + i}', f'Page item {have + i}') for i in range(2)]
        answer(rid, b'1\n' + kids('', items, more=more, op='add'))
    else:
        send(f'error {rid} unknown')


def on_command(name):
    global rescans
    todo = views.get('todo')
    if name == 'rescan' and todo:
        rescans += 1
        todo_tree(todo, count=2 + rescans)
    elif name == 'renamed' and todo:
        todo_tree(todo, prefix='n')
    elif name == 'vanish' and todo:
        sel = selected.get(todo)
        if sel:
            patch(todo, [rec('del', data=sel.encode())])
    elif name == 'badpatch' and todo:
        patch(todo, [rec('title', data=b'Changed'), rec('badge', '9'),
                     kids('missing-parent', [node('x', 'X')])])
    elif name == 'big' and todo:
        patch(todo, [kids('', [node(f'n{i}', f'N {i}') for i in range(100001)])])
    elif name == 'show':
        request('vshow items focus')
    elif name == 'empty' and todo:
        patch(todo, [rec('state', 'empty 13', b'Nothing found.rescan')])
    elif name == 'msg' and todo:
        patch(todo, [rec('message', data=b'Scanned 3 files')])
    elif name == 'busy' and todo:
        patch(todo, [rec('busy', '1')])
    elif name == 'expand' and todo:
        patch(todo, [rec('collapse', data=b'f:main.rs'), rec('expand', data=b'f:lib.rs')])
    elif name == 'reveal' and todo:
        patch(todo, [rec('collapse', data=b'f:lib.rs')])
        request(f'vreveal {todo} select,focus', b't:lib.rs:1')
    elif name == 'multi' and views.get('items'):
        patch(views['items'], [rec('select-mode', 'multi')])
    elif name == 'delpin' and todo:
        patch(todo, [rec('action', 'pin - none', b'')])
    elif name == 'log' and views.get('logs'):
        lines = (b'info starting\n'
                 b'warn \x1b[33myellow\x1b[0m and plain\n'
                 b'error failed: \x1b[1;31mred\x1b[0m\n'
                 b'debug details\tafter a tab\n'
                 b'trace \x07bell\x1b]0;title\x07 gone\n'
                 b'- no severity\n')
        patch(views['logs'], [rec('log', '6', lines)])
    elif name == 'logmany' and views.get('logs'):
        lines = b''.join(f'info line {i}\n'.encode() for i in range(12000))
        patch(views['logs'], [rec('log', '12000', lines)])
    elif name == 'logclear' and views.get('logs'):
        patch(views['logs'], [rec('clear', '', b'')])
    elif name == 'clearmain' and todo:
        patch(todo, [kids('f:main.rs', [])])  # expanded, with no children
    elif name == 'loadthen' and todo:
        patch(todo, [rec('state', 'loading 0')])
        patch(todo, [kids('', [node(f'f:{n}', n, 'open') for n in ('main.rs', 'lib.rs', 'README.md')])])
    elif name == 'fatset' and todo:
        # seven nodes given 3,000,000 bytes each, one patch apiece: past 16 MB they are refused
        for nid in ('f:main.rs', 'f:lib.rs', 'f:README.md', 't:main.rs:1', 't:main.rs:2', 't:lib.rs:1',
                    't:README.md:1'):
            kind = 'open' if nid.startswith('f:') else 'leaf'
            patch(todo, [rec('set', '', node(nid, nid, kind, rec('blob', '', b'x' * 3000000)))])
    elif name == 'fatrelist' and todo:
        # after fatset (15 MB kept): the root's three children listed again with 1,200,000 bytes
        # each replace their 3 MB, then 3,000,000 more on another node still fit
        top = [node(f'f:{n}', n, 'open', rec('blob', '', b'y' * 1200000)) for n in ('main.rs', 'lib.rs', 'README.md')]
        patch(todo, [kids('', top)])
        patch(todo, [rec('set', '', node('t:lib.rs:1', 'one', 'leaf', rec('blob', '', b'z' * 3000000)))])
    elif name == 'tbsorted' and views.get('files'):
        patch(views['files'], [rec('sorted', '2 desc', b'')])
    elif name == 'tbmore' and views.get('files'):
        files_table(views['files'], more=1)
    elif name == 'tbadd' and views.get('files'):
        patch(views['files'], [kids('', [row('c', 'c.txt', '50', 'file')], op='add')])
    elif name == 'tbbad' and views.get('files'):
        patch(views['files'], [rec('columns', '2', col('middle', 0, 'sort', 'Name') + col('left', 0, '-', 'X'))])
    elif name == 'tbtree' and todo:
        patch(todo, [rec('columns', '1', col('left', 0, 'sort', 'Name'))])
    elif name == 'quick':
        quick_open(quick_step1())
    elif name == 'quickmulti':
        quick_open([rec('title', data=b'Files'), rec('flags', 'multi', b''),
                    qitems([qitem('a', 'a.rs', extra=rec('picked', '', b'')), qitem('b', 'b.rs'), qitem('c', 'c.rs')])])
    elif name == 'quickinput':
        quick_open([rec('mode', 'input', b''), rec('flags', 'password busy', b''), rec('prompt', data=b'Your token'),
                    rec('value', '-', b'abc')])
    elif name == 'quicknofilter':
        quick_open([rec('flags', 'nofilter', b''),
                    qitems([qitem('s1', 'symbol one', extra=rec('hl', '0 6', b'')), qitem('s2', 'other')])])
    elif name == 'quickmany':
        quick_open([rec('title', data=b'Many'), qitems([qitem(f'i{i}', f'item {i}') for i in range(30)])])
    elif name == 'quickclose' and quick_q:
        request(f'quick-close {quick_q[-1]}')
    elif name == 'quickbad':
        quick_open([rec('step', 'x 3', b'')])
    elif name == 'quickbig':
        quick_open([qitems([qitem(f'i{i}', f'item {i}') for i in range(10001)])])
    elif name == 'quickactive' and quick_q:
        quick_set([rec('active', '', b'origin/main')])
    elif name == 'docfollow' and views.get('readme') and opened_docs:
        with open(os.path.join(ROOT, 'long.md'), 'rb') as f:
            text = f.read()
        patch(views['readme'], [rec('doc', '', text), rec('follow', f'{opened_docs[-1]}', b'')])
    elif name == 'docimg' and views.get('readme'):
        vimage(png(30, 10, (0, 255, 0, 255)),
               lambda img: patch(views['readme'], [rec('doc', '', f'# Pic\n\n![green](img:{img})\n'.encode())]))
    elif name == 'docbad' and views.get('readme'):
        patch(views['readme'], [rec('base', '', b'relative/folder')])
    elif name == 'doccopy' and views.get('readme'):
        code = '# install tools\nprintf "café"\n\techo done\n'
        patch(views['readme'], [rec('doc', '', ('# Commands\n\n```sh\n' + code + '```\n\n```\necho second\n```\n').encode())])
    elif name == 'docbig' and views.get('readme'):
        patch(views['readme'], [rec('doc', '', b'x' * 1048577)])
    elif name == 'doctree' and views.get('readme'):
        patch(views['readme'], [kids('', [node('a', 'A')])])
    elif name == 'notemd':
        notify('info', note_body('**Indexed** 12 files: see `todo` and *more*'))
    elif name == 'note':
        notify('info', note_body('Indexed 12 files', 'workspace'))
    elif name == 'noteask':
        notify('warning', note_body('Reload the window to use the new settings?',
                                    buttons=[('Reload', 'rescan'), ('Later', None)]))
    elif name == 'noteerr':
        notify('error', note_body('The server stopped. ' * 8 + 'Its log has more.\nSecond line.'))
    elif name == 'notemany':
        for i in range(6):
            notify('info', note_body(f'Note {i + 1}', sticky=True))
    elif name == 'notes17':
        for i in range(17):
            notify('info', note_body(f'Note {i + 1}', sticky=True))
    elif name == 'noteset' and notes:
        request(f'notify-set {notes[-1]}', note_body('Indexed 40 files', buttons=[('Open', None)]))
    elif name == 'unnote' and notes:
        request(f'unnotify {notes[-1]}')
    elif name == 'prog':
        rid = progress('status', 'cancel', 'Indexing')
        prev = on_reply[rid]

        def started(f):
            prev(f)
            request(f'progress-set {f[2]} 42', b'crates')
        on_reply[rid] = started
    elif name == 'prognote':
        progress('note', 'cancel', 'Downloading')
    elif name == 'progview' and views.get('todo'):
        progress(f'view:{views["todo"]}', '-', 'Scanning')
    elif name == 'progbad':
        progress('view:999', '-', 'Nowhere')
        progress('status', 'maybe', 'Bad cancel')
    elif name == 'progend' and progs:
        request(f'progress-end {progs[-1]}')
    elif name == 'img' and views.get('pic'):
        vimage(png(2, 2, (255, 0, 0, 255)), lambda img: draw(views['pic'], f'image 0 0 40 40 {img}\n'))
    elif name == 'badimg':
        request('vimage', b'not an image at all')
    elif name == 'imgs65':
        for i in range(65):
            vimage(png(1, 1, (0, 0, 255, 255)))
    elif name == 'unimg' and images:
        request(f'unimage {images[-1]}')
        request(f'unimage {images[-1]}')
    elif name == 'tabpic':
        rid = request('view Pic Tab')

        def opened(f):
            views['tabpic'] = int(f[2])
            draw(int(f[2]), 'rect 0 0 200 100 accent\n')
        on_reply[rid] = opened
    elif name == 'readd' and views.get('items'):
        patch(views['items'], [rec('del', data=b'a')])
        patch(views['items'], [kids('', [node('a', 'Alpha again', 'closed')], op='add')])
    elif name == 'actswap' and todo:
        patch(todo, [rec('action', 'again pin node', b'Again') for _ in range(30)])
    elif name == 'fatsame' and todo:
        big = rec('blob', '', b'q' * 900000)
        patch(todo, [rec('set', '', node('t:lib.rs:1', 'one', 'leaf', big)),
                     rec('set', '', node('t:lib.rs:1', 'one', 'leaf', big))])
    elif name == 'revealmulti' and todo:
        patch(todo, [rec('select-mode', 'multi')])
        request(f'vreveal {todo} select', b't:lib.rs:1')
    elif name == 'noteclose1' and notes:
        request(f'unnotify {notes[0]}')
    elif name == 'prognote2':
        progress('note', '-', 'Copying')
    elif name == 'pictitle' and views.get('pic'):
        patch(views['pic'], [rec('title', data=b'Drawing'), rec('badge', '3')])
    elif name == 'bigunimage':
        request('unimage 4294967297')
    elif name == 'formmsg' and views.get('setup'):
        patch(views['setup'], [rec('field', '', frec('name', 'text', 1, 2, 'Name', rec('msg', 'error', b'taken')))])
    elif name == 'formold' and views.get('setup'):
        patch(views['setup'], [rec('field', '', frec('name', 'text', 1, 2, 'Name', rec('value', '0', b'Old')))])
    elif name == 'formnew' and views.get('setup'):
        seq = seqs.get('name', 0)
        patch(views['setup'], [rec('field', '', frec('name', 'text', 1, 2, 'Name', rec('value', f'{seq}', b'NORMAL')))])
    elif name == 'formbad' and views.get('setup'):
        patch(views['setup'], [rec('field', '', b'bad record\n')])
    elif name == 'formmany' and views.get('setup'):           # 200 fields, then 200 others
        patch(views['setup'], [rec('form', '200', b''.join(frec(f'k{i}', 'text', 1 + i, 1, 'K') for i in range(200)))])
        patch(views['setup'], [rec('form', '200', b''.join(frec(f'j{i}', 'text', 1 + i, 1, 'J') for i in range(200)))])
    elif name == 'formgrow' and views.get('setup'):           # 195 new keys in one patch: 201
        patch(views['setup'], [rec('field', '', frec(f'g{i}', 'text', 5, 1, 'G')) for i in range(195)])
    elif name == 'formsame' and views.get('setup'):           # 195 ops on one new key: 7 fields
        patch(views['setup'], [rec('field', '', frec('g', 'text', 5, 1, f'G{i}')) for i in range(195)])
    elif name == 'formdup' and views.get('setup'):
        patch(views['setup'], [rec('form', '2', frec('a', 'text', 1, 1, 'A') + frec('a', 'text', 2, 1, 'A'))])
    elif name == 'formwrap' and views.get('setup'):
        bad = b'w text 1 1 200 18446744073709551417\nL'
        patch(views['setup'], [rec('field', '', bad)])
    elif name == 'formrev' and views.get('setup'):
        f = [frec('go', 'button', 4, 1, 'Connect'), frec('mode', 'select', 3, 1, 'Mode', rec('options', data=b'fast\nsafe\nslow')),
             frec('tls', 'check', 3, 1, 'Use TLS'), frec('notes', 'area', 2, 1, 'Notes'),
             frec('port', 'number', 1, 1, 'Port'), frec('name', 'text', 1, 2, 'Name')]
        patch(views['setup'], [rec('form', '6', b''.join(f))])
    elif name == 'formdisable' and views.get('setup'):
        patch(views['setup'], [rec('field', '', frec('name', 'text', 1, 2, 'Name', rec('disabled', '', b'')))])
    elif name == 'formless' and views.get('setup'):
        patch(views['setup'], [rec('form', '1', frec('go', 'button', 1, 1, 'Connect'))])
    elif name == 'tab':
        def opened_tab(reply):
            pass
        rid = request('vtab tree Commit 3fa2c1')
        pending_tab.append(rid)
    elif name == 'untab' and tabs:
        request(f'unview {tabs[-1]}')


def main():
    time.sleep(float(os.environ.get('VIEWFAKE_DELAY', '0')))     # a slow start
    features = '' if MODE == 'nofeature' else ' view-tree'
    if features and not os.environ.get('VIEWFAKE_NOLOG'):
        features += ' view-log'
    if os.environ.get('VIEWFAKE_NOTIFY'):
        features += ' notify progress'
    if PIC:
        features += ' views view-images' + ('' if PIC == 'nokeys' else ' view-keys')
    if os.environ.get('VIEWFAKE_KEY_STATE'):
        features += ' view-key-state'
    if os.environ.get('VIEWFAKE_FORM'):
        features += ' view-form'
    if os.environ.get('VIEWFAKE_TABLE'):
        features += ' view-table'
    if os.environ.get('VIEWFAKE_QUICK'):
        features += ' quick-input'
    if os.environ.get('VIEWFAKE_DOC'):
        features += ' view-doc'
    if os.environ.get('VIEWFAKE_MARKDOWN'):
        features += ' markdown'
    send('hello 1' + features)
    while True:
        line = inp.readline()
        if not line:
            return
        line = line.rstrip(b'\n')
        log(line)
        fields = line.decode('utf-8', 'replace').split(' ')
        if fields[:2] == ['0', 'bye']:
            os._exit(0)
        body = b''
        # a line whose last field is a length carries a body
        if fields[0] == '0' and len(fields) >= 3 and fields[1] == 'view' and \
                fields[3] in ('select', 'activate', 'expand', 'collapse', 'check', 'action', 'discarded', 'text', 'paste',
                              'change', 'link'):
            n = int(fields[-1])
            body = inp.read(n)
            log(body)
        elif fields[:2] in (['0', 'opened'], ['0', 'active']) and len(fields) >= 3 and fields[2] != '0':
            opened_docs.append(int(fields[2]))
            continue
        elif fields[:2] == ['0', 'quick'] and len(fields) >= 4:
            if fields[3] in ('value', 'active', 'accept', 'button'):
                n = int(fields[-1])
                body = inp.read(n)
                log(body)
            quick_event(fields, body)
            continue
        elif fields[0] == 'ok' and len(fields) >= 3 and int(fields[1]) in on_reply:
            on_reply.pop(int(fields[1]))(fields)
            continue
        elif fields[0] == 'ok' and len(fields) >= 3 and int(fields[1]) in pending_tab:
            pending_tab.remove(int(fields[1]))
            view = int(fields[2])
            tabs.append(view)
            patch(view, [kids('', [node('m', 'main.rs', 'open', rec('icon', 'file:main.rs -')),
                                  node('r', 'README.md')]),
                         kids('m', [node('m1', '+12 -3')]), rec('state', 'ready 0')])
            continue
        elif fields[0].isdigit() and fields[0] != '0' and len(fields) >= 3 and fields[1] == 'vcopy':
            answer(fields[0], b'copied text' if fields[3] == 'copy' else b'cut text')
            continue
        elif fields[0].isdigit() and fields[0] != '0' and len(fields) >= 3 and fields[1] in ('vkids', 'vmore'):
            n = int(fields[-1])
            body = inp.read(n)
            log(body)
            host_request(fields[0], fields[1], fields[1:], body)
            continue
        if fields[0] == '0' and len(fields) >= 3 and fields[1] == 'view':
            view = int(fields[2])
            what = fields[3]
            if what == 'open':
                key = fields[6]
                views[key] = view
                if key == 'todo':
                    todo_tree(view)
                elif key == 'items':
                    items_tree(view)
                elif key == 'pic':
                    draw(view, 'rect 0 0 300 120 accent\n')
                elif key == 'setup':
                    setup_form(view)
                elif key == 'files':
                    files_table(view)
                elif key == 'readme':
                    readme_doc(view)
            elif what == 'select':
                ids = body.split(b'\n')
                selected[view] = ids[0].decode() if ids and ids[0] else None
            elif what == 'change':
                seqs[fields[5]] = int(fields[6])
        elif fields[0] == '0' and len(fields) >= 3 and fields[1] == 'run':
            name = fields[2].split('.')[-1]
            on_command(name)


main()
