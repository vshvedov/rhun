#!/usr/bin/env python3
# A stand-in agent for tests/agent_conn_test.s: one scenario per run, named by argv[1].
import os, signal, sys, time
s = sys.argv[1]
out = sys.stdout
if s == 'echo':                 # one reply per stdin line, with the line's length; exit at EOF
    for line in sys.stdin:
        out.write('echo:%d\n' % (len(line) - 1)); out.flush()
    sys.exit(0)
if s == 'exit':                 # two lines, a partial third, exit code 3
    out.write('one\ntwo\nthree'); out.flush(); sys.exit(3)
if s == 'stderr':               # a stderr tail longer than rhun keeps
    sys.stderr.write('oops\n'); sys.stderr.write('e' * (100 << 10)); sys.stderr.write('\ntail\n')
    sys.stderr.flush(); sys.exit(0)
if s == 'bigline':              # one record over the 64 MiB limit
    out.write('x' * (65 << 20)); out.write('\n'); out.flush(); sys.exit(0)
if s == 'fill':                 # never reads stdin
    time.sleep(60)
if s == 'stop':                 # ignores SIGTERM
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    out.write('ready\n'); out.flush(); time.sleep(60)
if s == 'linger':               # closes stdout but keeps running
    out.write('ready\n'); out.flush(); os.close(1); time.sleep(60)
