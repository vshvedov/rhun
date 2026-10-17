#!/bin/sh
# Gate 0 confinement spike, Linux side. Builds confine statically in Alpine, then runs the
# matrix in several distro images and in the Go image (gofmt, gopls). Output: build/spike/*.log
# and a summary on stdout. Docker's default seccomp profile blocks unshare(CLONE_NEWUSER) and
# may block the landlock syscalls, so each image is tried plain first, then with the seccomp
# and AppArmor profiles off; the summary says which was needed. That is a fact about Docker,
# not about the distro: whether a distro allows unprivileged user namespaces is a host kernel
# policy and has to be checked on real installs (see the spike note).
set -u
cd "$(dirname "$0")/../.."
OUT=build/spike; mkdir -p "$OUT" build/spike-gopath
SPIKE=$PWD/tools/sandbox-spike

echo "== build confine (alpine, static)"
docker run --rm -v "$SPIKE:/src:ro" -v "$PWD/$OUT:/out" alpine:3.20 sh -c \
  'apk add -q gcc musl-dev linux-headers >/dev/null && gcc -static -O2 -Wall -o /out/confine /src/confine.c && echo built' \
  2>&1 | tail -2

# inner(): the matrix inside one container; needs /out/confine, writes to stdout
INNER='
set -u
C=/out/confine
mkdir -p /work/project /work/state /work/ext
echo "hello" > /work/project/hello.txt
echo "secret" > /work/home-secret.txt
echo "--- probe"; $C probe
RULES="--ro /usr --ro /etc --ro /proc/self --ro /work/project --rw /work/state --rw /dev/null"
[ -d /lib ] && RULES="$RULES --ro /lib"; [ -d /lib64 ] && RULES="$RULES --ro /lib64"; [ -d /bin ] && RULES="$RULES --ro /bin"
SH=$(command -v sh); CAT=$(command -v cat); LS=$(command -v ls)
run() { name=$1; shift; out=$("$@" 2>&1); rc=$?; printf "%-28s rc=%-3s %s\n" "$name" "$rc" "$(echo "$out" | head -c 160 | tr "\n" " ")"; }
echo "--- files (sh as the interpreter, exec allowed on sh and cat only)"
run read-project      $C $RULES --exec $SH --exec $CAT -- $SH -c "$CAT /work/project/hello.txt"
run write-project     $C $RULES --exec $SH --exec $CAT -- $SH -c "echo x > /work/project/new.txt && echo wrote"
run truncate-project  $C $RULES --exec $SH --exec $CAT -- $SH -c ": > /work/project/hello.txt && echo truncated"
run write-state       $C $RULES --exec $SH --exec $CAT -- $SH -c "echo x > /work/state/s.txt && echo wrote"
run read-home-secret  $C $RULES --exec $SH --exec $CAT -- $SH -c "$CAT /work/home-secret.txt"
run exec-ls-denied    $C $RULES --exec $SH --exec $CAT -- $SH -c "$LS /work/project"
run exec-ls-allowed   $C $RULES --exec $SH --exec $CAT --exec $LS -- $SH -c "$LS /work/project"
run tmp-write         $C $RULES --exec $SH --exec $CAT -- $SH -c "echo x > /tmp/t.txt && echo wrote"
echo "--- network (nettest connects to 1.1.1.1:80 with a 3 s timeout)"
run net-unconfined    $C nettest 1.1.1.1 80
run net-no-net        $C $RULES --no-net --exec $C -- $C nettest 1.1.1.1 80
run net-landlock-only $C $RULES --exec $C -- $C nettest 1.1.1.1 80
echo "--- limits"
run limits-ok         $C $RULES --limits --exec $SH --exec $CAT -- $SH -c "echo alive"
echo "--- project rw"
RW=$(echo "$RULES" | sed "s|--ro /work/project|--rw /work/project|")
run rw-write-project  $C $RW --exec $SH --exec $CAT -- $SH -c "echo x > /work/project/new.txt && echo wrote"
cat /work/project/hello.txt | head -1
'

try_image() {
  img=$1; tag=$(echo "$img" | tr '/:' '__'); log=$OUT/$tag.log
  echo "== $img"
  for mode in plain unconfined privileged; do
    case $mode in
      plain) flags="";;
      unconfined) flags="--security-opt seccomp=unconfined --security-opt apparmor=unconfined";;
      privileged) flags="--privileged";;
    esac
    docker run --rm $flags -v "$PWD/$OUT:/out:ro" "$img" sh -c "$INNER" > "$log.$mode" 2>&1
    if grep -q 'userns_netns=yes' "$log.$mode" && grep -q 'landlock=abi' "$log.$mode"; then
      echo "   confinement possible with docker mode: $mode"; cp "$log.$mode" "$log"; break
    fi
    echo "   mode $mode: $(grep -E 'landlock=|userns_netns=' "$log.$mode" | tr '\n' ' ')"
  done
  [ -f "$log" ] || cp "$log.privileged" "$log"
  sed -n '/--- files/,$p' "$log" | sed 's/^/   /'
}

for img in ubuntu:24.04 debian:12 fedora:41 archlinux:latest alpine:3.20; do try_image "$img"; done

echo "== golang:1.25 (gofmt, then gopls check on a tiny module)"
GO_INNER='
set -u
C=/out/confine; GO=/usr/local/go
mkdir -p /work/project /work/state && cd /work/project
printf "module spike\n\ngo 1.25\n" > go.mod
printf "package main\n\nimport \"fmt\"\n\nfunc main() { var unused int; fmt.Println(\"hi\") }\n" > main.go
RULES="--ro /usr --ro /etc --ro /proc/self --ro /lib --ro /work/project --rw /work/state --rw /dev/null --no-net"
export HOME=/work/state GOCACHE=/work/state/gocache GOMODCACHE=/work/state/gomod GOPATH=/work/state/gopath GOFLAGS=-mod=mod GOTOOLCHAIN=local GOPROXY=off
run() { name=$1; shift; out=$("$@" 2>&1); rc=$?; printf "%-28s rc=%-3s %s\n" "$name" "$rc" "$(echo "$out" | head -c 240 | tr "\n" " ")"; }
echo "--- gofmt"
run gofmt-stdin       sh -c "echo \"package x\nfunc  f(){}\" | $C $RULES --exec $GO/bin/gofmt -- $GO/bin/gofmt"
run gofmt-file        $C $RULES --exec $GO/bin/gofmt -- $GO/bin/gofmt -l /work/project
echo "--- gopls (installed into /go/bin outside confinement; GOPATH volume caches it)"
[ -x /go/bin/gopls ] || GOFLAGS= GOPROXY=https://proxy.golang.org,direct GOTOOLCHAIN=auto HOME=/root GOCACHE=/root/.cache/go-build GOMODCACHE=/go/pkg/mod GOPATH=/go go install golang.org/x/tools/gopls@latest 2>&1 | tail -2
ls -la /go/bin/gopls 2>&1 | tail -1
run gopls-version-exec-file $C $RULES --exec /go/bin/gopls -- /go/bin/gopls version
run gopls-check-no-go-exec  $C $RULES --exec /go/bin/gopls -- /go/bin/gopls check /work/project/main.go
run gopls-check-go-dir-exec $C $RULES --exec /go/bin/gopls --exec $GO -- /go/bin/gopls check /work/project/main.go
run gopls-check-rw-project  $C $(echo $RULES | sed "s|--ro /work/project|--rw /work/project|") --exec /go/bin/gopls --exec $GO -- /go/bin/gopls check /work/project/main.go
echo "--- what gopls wrote under state:"; find /work/state -maxdepth 2 | head -12
'
docker run --rm --security-opt seccomp=unconfined --security-opt apparmor=unconfined -v "$PWD/$OUT:/out:ro" -v "$PWD/build/spike-gopath:/go" golang:1.25 sh -c "$GO_INNER" > "$OUT/golang.log" 2>&1
sed 's/^/   /' "$OUT/golang.log"
