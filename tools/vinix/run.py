#!/usr/bin/env python3
"""Run the experimental build in a private full-screen Vinix X11 session."""
import ctypes as c
import fcntl
import mmap
import os
from pathlib import Path
import shlex
import signal
import struct
import subprocess
import sys
import tempfile
import time

def fit_window(display, width, height):
    x = c.CDLL('libX11.so.6')
    D, W = c.c_void_p, c.c_ulong
    x.XOpenDisplay.argtypes = [c.c_char_p]; x.XOpenDisplay.restype = D
    x.XDefaultRootWindow.argtypes = [D]; x.XDefaultRootWindow.restype = W
    x.XQueryTree.argtypes = [D,W,c.POINTER(W),c.POINTER(W),c.POINTER(c.POINTER(W)),c.POINTER(c.c_uint)]
    x.XResizeWindow.argtypes = [D,W,c.c_uint,c.c_uint]
    x.XMoveWindow.argtypes = [D,W,c.c_int,c.c_int]
    x.XSetInputFocus.argtypes = [D,W,c.c_int,c.c_ulong]
    x.XFree.argtypes = [c.c_void_p]
    x.XFlush.argtypes = [D]; x.XCloseDisplay.argtypes = [D]
    connection = x.XOpenDisplay(display.encode())
    if not connection: return False
    root, parent, count = W(), W(), c.c_uint()
    children = c.POINTER(W)()
    try:
        if not x.XQueryTree(connection,x.XDefaultRootWindow(connection),c.byref(root),c.byref(parent),c.byref(children),c.byref(count)):
            return False
        if not count.value: return False
        for i in range(count.value):
            x.XResizeWindow(connection,children[i],width,height)
            x.XMoveWindow(connection,children[i],0,0)
        x.XSetInputFocus(connection,children[0],2,0)
        x.XFlush(connection)
        return True
    finally:
        if children: x.XFree(children)
        x.XCloseDisplay(connection)

def main():
    base = Path(os.environ.get('RHUN_VINIX_DIR', Path(__file__).resolve().parent))
    binary = base / 'rhun'
    if not binary.is_file(): raise SystemExit('Put the ARM64 rhun executable beside this launcher.')
    project = Path(sys.argv[1]).resolve() if len(sys.argv)>1 else base / 'project'
    if not project.is_dir(): raise SystemExit('Project folder does not exist: ' + str(project))
    rows = subprocess.check_output(['ps','-ef'],text=True).splitlines()
    pids = [int(row.split()[0]) for row in rows if row.split()[-1:] == ['/usr/bin/vinix-desktop']]
    if len(pids) != 1: raise SystemExit('Expected one native Vinix compositor.')
    compositor = pids[0]
    counter = base / '.display-next'
    display = int(counter.read_text()) if counter.exists() else 64
    counter.write_text(str(display+1))
    home = base / 'home'; home.mkdir(exist_ok=True)
    env = dict(os.environ, HOME=str(home), RHUN_BACKEND='x11')

    with tempfile.TemporaryDirectory(prefix='rhun-x11-') as directory:
        folder = Path(directory)
        startx = folder / 'startx'
        script = Path('/usr/bin/startx').read_text()
        if '\nd=0\n' not in script: raise SystemExit('Unsupported Vinix startx script.')
        startx.write_text(script.replace('\nd=0\n','\nd='+str(display)+'\n',1))
        control = folder / 'control'
        (base / 'control.path').write_text(str(control))
        args = [str(binary),'--wait','--empty','--control',str(control),str(project)] + sys.argv[2:]
        client = folder / 'client.sh'
        client.write_text('#!/bin/sh\nprintf "%s\\n" "$DISPLAY" > '+shlex.quote(str(folder/'display'))
                          +'\nexec '+shlex.join(args)+'\n')
        fd = os.open('/dev/fb0',os.O_RDWR)
        var = fcntl.ioctl(fd,0x4600,bytes(160))
        fixed = fcntl.ioctl(fd,0x4602,bytes(80))
        width,height = struct.unpack_from('II',var)
        stride = struct.unpack_from('I',fixed,48)[0]
        screen = mmap.mmap(fd,stride*height,flags=mmap.MAP_SHARED,prot=mmap.PROT_READ|mmap.PROT_WRITE)
        child = None
        def interrupted(signum, frame): raise KeyboardInterrupt
        signal.signal(signal.SIGTERM,interrupted)
        os.kill(compositor,signal.SIGSTOP)
        saved = screen[:]
        try:
            with (base/'session.log').open('w') as log:
                child = subprocess.Popen(['/bin/sh',str(startx),str(client)],env=env,
                                         stdin=subprocess.DEVNULL,stdout=log,stderr=log)
                fitted = False
                while child.poll() is None:
                    if not fitted and (folder/'display').exists():
                        fitted = fit_window((folder/'display').read_text().strip(),width,height)
                    time.sleep(.25)
                return child.returncode
        finally:
            if child is not None and child.poll() is None:
                child.terminate()
                try: child.wait(timeout=10)
                except subprocess.TimeoutExpired: child.kill(); child.wait()
            screen[:] = saved
            screen.close(); os.close(fd)
            os.kill(compositor,signal.SIGCONT)

if __name__ == '__main__':
    sys.exit(main())
