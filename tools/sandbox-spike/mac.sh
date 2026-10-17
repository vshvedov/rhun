#!/bin/sh
# Gate 0 confinement spike, macOS side: sandbox-exec (the sandbox_init API with a profile) with
# a default-deny SBPL profile generated from a [needs]-like shape. Runs python3, gofmt and gopls
# (built into build/spike-bin by the caller) against a project folder and a state folder.
# Output: build/spike/mac.log and a summary on stdout. sandbox-exec is deprecated; this records
# what it still does on this macOS version.
set -u
cd "$(dirname "$0")/../.."
OUT=$PWD/build/spike; mkdir -p "$OUT"
rm -rf build/spike-work; W=$PWD/build/spike-work; mkdir -p "$W/project" "$W/state" "$W/ext"
echo hello > "$W/project/hello.txt"; echo secret > "$W/home-secret.txt"
printf 'module spike\n\ngo 1.25\n' > "$W/project/go.mod"
printf 'package main\n\nimport "fmt"\n\nfunc main() { var unused int; fmt.Println("hi") }\n' > "$W/project/main.go"
PY=$(command -v python3); GO=$(command -v go); GOFMT=$(command -v gofmt); GOPLS=$PWD/build/spike-bin/gopls
GOROOT=$(go env GOROOT)
# resolve symlinks: SBPL matches real paths
real() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
PY=$(real "$PY"); GOFMT=$(real "$GOFMT"); GOROOT=$(real "$GOROOT"); GOPLS=$(real "$GOPLS")

# profile(project-mode, net, exec-list...): default deny; reads of the system; the project ro or rw;
# the state folder rw; process-exec only on the listed files or subpaths
profile() {
  mode=$1; net=$2; shift 2
  cat <<EOF
(version 1)
(deny default)
(import "system.sb")
(allow process-fork)
(allow file-read-metadata)
(allow file-read* (subpath "$W/ext"))
(allow sysctl-read)
(allow mach-lookup (global-name "com.apple.system.logger") (global-name "com.apple.system.notification_center"))
(allow file-read* (subpath "/usr") (subpath "/System") (subpath "/Library") (subpath "/private/etc") (subpath "/dev") (literal "/") (subpath "/opt/homebrew") (subpath "/Users/vsh/.local/share/mise"))
(allow file-read* (subpath "$W/project"))
$( [ "$mode" = rw ] && echo "(allow file-write* (subpath \"$W/project\"))" )
(allow file-read* file-write* (subpath "$W/state"))
(allow file-write* (literal "/dev/null") (literal "/dev/stdout") (literal "/dev/stderr"))
(allow file-read* (literal "/dev/null") (literal "/dev/urandom") (literal "/dev/random") (literal "/dev/tty"))
$( [ "$net" = yes ] && echo "(allow network*)" || echo "(deny network*)" )
EOF
  for e in "$@"; do
    if [ -d "$e" ]; then echo "(allow process-exec file-read* (subpath \"$e\"))"; else echo "(allow process-exec file-read* (literal \"$e\"))"; fi
  done
}
run() { name=$1; shift; out=$("$@" 2>&1); rc=$?; printf "%-28s rc=%-3s %s\n" "$name" "$rc" "$(echo "$out" | head -c 200 | tr '\n' ' ')"; }
SB() { mode=$1; net=$2; shift 2; profile "$mode" "$net" "$@" > "$W/p.sb"; }

mkdir -p "$W/state/tmp"; export TMPDIR=$W/state/tmp
cd "$W/ext"
{
echo "--- macOS $(sw_vers -productVersion), sandbox-exec $(ls -la /usr/bin/sandbox-exec | awk '{print $5}') bytes"
echo "--- python3 as the interpreter (exec allowed on python3 only)"
PYDIR=$(dirname "$(dirname "$PY")")
SB ro no "$PY" "$PYDIR"
run read-project      sandbox-exec -f "$W/p.sb" "$PY" -c "print(open('$W/project/hello.txt').read().strip())"
run write-project     sandbox-exec -f "$W/p.sb" "$PY" -c "open('$W/project/new.txt','w').write('x'); print('wrote')"
run truncate-project  sandbox-exec -f "$W/p.sb" "$PY" -c "open('$W/project/hello.txt','w'); print('truncated')"
run write-state       sandbox-exec -f "$W/p.sb" "$PY" -c "open('$W/state/s.txt','w').write('x'); print('wrote')"
run read-home-secret  sandbox-exec -f "$W/p.sb" "$PY" -c "print(open('$W/home-secret.txt').read().strip())"
run exec-ls-denied    sandbox-exec -f "$W/p.sb" "$PY" -c "import subprocess; print(subprocess.run(['/bin/ls','$W/project'],capture_output=True,text=True))"
run net-denied        sandbox-exec -f "$W/p.sb" "$PY" -c "import socket; s=socket.socket(); s.settimeout(3); print(s.connect_ex(('1.1.1.1',80)))"
run tmp-write         sandbox-exec -f "$W/p.sb" "$PY" -c "import tempfile; f=tempfile.NamedTemporaryFile(); print('tmp ok', f.name[:12])"
SB ro yes "$PY" "$PYDIR"
run net-allowed       sandbox-exec -f "$W/p.sb" "$PY" -c "import socket; s=socket.socket(); s.settimeout(3); print(s.connect_ex(('1.1.1.1',80)))"
SB rw no "$PY" "$PYDIR"
run rw-write-project  sandbox-exec -f "$W/p.sb" "$PY" -c "open('$W/project/new.txt','w').write('x'); print('wrote')"
echo "--- gofmt"
SB ro no "$GOFMT"
run gofmt-file        sandbox-exec -f "$W/p.sb" "$GOFMT" -l "$W/project"
run gofmt-stdin       sh -c "printf 'package x\nfunc  f(){}\n' | sandbox-exec -f '$W/p.sb' '$GOFMT'"
echo "--- gopls (exec on gopls and the whole GOROOT; caches under state)"
export HOME=$W/state GOCACHE=$W/state/gocache GOMODCACHE=$W/state/gomod GOPATH=$W/state/gopath GOFLAGS=-mod=mod GOTOOLCHAIN=local GOPROXY=off
SB ro no "$GOPLS"
run gopls-version          sandbox-exec -f "$W/p.sb" "$GOPLS" version
run gopls-check-no-go      sandbox-exec -f "$W/p.sb" "$GOPLS" check "$W/project/main.go"
SB ro no "$GOPLS" "$GOROOT"
run gopls-check-goroot     sandbox-exec -f "$W/p.sb" "$GOPLS" check "$W/project/main.go"
echo "--- state after gopls:"; find "$W/state" -maxdepth 2 | head -10
echo "--- unconfined control"
run control-read-secret   "$PY" -c "print(open('$W/home-secret.txt').read().strip())"
} 2>&1 | tee "$OUT/mac.log"
echo "work dir: $W"
