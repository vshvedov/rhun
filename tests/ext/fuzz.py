#!/usr/bin/env python3
"""The fuzz extension: after hello it writes random, mostly malformed protocol traffic for a while,
seeded by FUZZ_SEED, then valid requests, then exits. rhun must survive it (tests/ext-fuzz.py
checks the process is alive and the document intact afterwards). Standard library only."""
import os
import random
import sys
import time

seed = int(os.environ.get('FUZZ_SEED', '1'))
rounds = int(os.environ.get('FUZZ_ROUNDS', '400'))
out = sys.stdout.buffer
r = random.Random(seed)
VERBS = ['text', 'range', 'replace', 'insert', 'select', 'toast', 'status', 'open', 'cancel', 'register',
         'hello', 'ok', 'error', 'bogus', '']


def num():
    return str(r.choice([0, 1, 2, 3, 7, 99, 2 ** 31 - 1, 2 ** 31, 2 ** 63, -1, 10 ** 30]))


def junk(n):
    return bytes(r.randrange(256) for _ in range(n))


def line():
    kind = r.random()
    if kind < 0.1:
        return junk(r.randrange(0, 300)) + b'\n'
    rid = r.choice([num(), 'x', '', '1.5', ' 1'])
    verb = r.choice(VERBS)
    args = ' '.join(r.choice([num(), 'a b', '-', '\x00', 'é', '*']) for _ in range(r.randrange(0, 9)))
    text = f'{rid} {verb} {args}'.encode(errors='replace')
    if r.random() < 0.3:          # a body, sometimes shorter or longer than announced
        n = r.randrange(0, 50)
        text += f' {n}'.encode()
        body = junk(n + r.choice([0, 0, 0, 1, -1, 5]) if n else 0)
        return text + b'\n' + body
    if r.random() < 0.05:
        return text               # no line end: the next write continues the line
    return text + b'\n'


def main():
    out.write(b'hello 1\n')
    out.flush()
    inp = sys.stdin.buffer
    os.set_blocking(inp.fileno(), False)
    for i in range(rounds):
        try:
            if i % 3 == 2:
                out.write(f'{100000 + i} status 2\nok'.encode())   # a well-formed request resets the syntax streak
            out.write(line())
            out.flush()
        except BrokenPipeError:
            return
        try:
            inp.read()            # drain whatever rhun says
        except Exception:
            pass
        if i % 50 == 0:
            time.sleep(0.02)
    # a well-formed request at the end: rhun should still answer if it kept us
    try:
        out.write(b'900000 toast 5\nfuzzy')
        out.flush()
    except BrokenPipeError:
        pass
    time.sleep(0.3)


if __name__ == '__main__':
    main()
