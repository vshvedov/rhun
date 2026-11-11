#!/bin/sh
# macOS on Apple silicon: tools/arm64.py translates the x86-64 sources to AArch64, src/mac holds
# the native parts (entry, Linux system calls on libSystem, the AppKit window)
# usage: tools/build-mac.sh [release|test]   (RHUN_JOBS=N caps parallel translations; default: all CPUs)
set -e
cd "$(dirname "$0")/.."
mkdir -p build/obj build/a64
tools/gen-assets.sh > build/assets.s.new
cmp -s build/assets.s.new build/assets.s || { mv build/assets.s.new build/assets.s; rm -f build/obj/build_assets.o; }
MINOS=12.0
ASFLAGS="-arch arm64 -mmacosx-version-min=$MINOS"

# stale(obj, deps...): obj is missing or older than a dependency
stale() {
    [ -f "$1" ] || return 0
    o=$1; shift
    for d in "$@"; do [ "$d" -nt "$o" ] && return 0; done
    return 1
}
name() { echo "$1" | sed 's|/|_|g; s|\.s$||'; }
# incs(file): the files under src it includes, directly or through another include
incs() {
    for i in $(sed -n 's/^[[:space:]]*\.include[[:space:]]*"\([^"]*\)".*/\1/p' "$1"); do
        [ -f "src/$i" ] || continue
        echo "src/$i"
        incs "src/$i"
    done
}

# translated sources: everything but the Linux entry and display servers
x86=$(find src -name '*.s' ! -path 'src/mac/*' ! -path 'src/win/*' ! -path src/start.s ! -path src/plat/wayland.s ! -path src/plat/x11.s ! -path src/plat/xim.s ! -path src/plat/ctext.s ! -path src/plat/ctdata.s ! -path src/plat/appearance.s | LC_ALL=C sort)
[ "$1" = test ] && x86="$x86 $(ls tests/*.s)"
todo=
objs=
for s in $x86 build/assets.s; do
    o=build/obj/$(name "$s").o
    if stale "$o" "$s" src/rhun.inc tools/arm64.py $(incs "$s") ||
        { [ "$s" = build/assets.s ] && [ -n "$(find runtime assets/fonts -newer "$o" -print -quit)" ]; }; then
        todo="$todo $s"
    fi
    case $s in tests/*) ;; *) objs="$objs $o" ;; esac
done
if [ -n "$todo" ]; then
    printf '%s\n' $todo | xargs -P "${RHUN_JOBS:-$(sysctl -n hw.ncpu)}" -n 1 sh -c '
        n=$(echo "$1" | sed "s|/|_|g; s|\.s$||")
        python3 tools/arm64.py -I src -D MACOS "$1" "build/a64/$n.s" &&
        as '"$ASFLAGS"' -o "build/obj/$n.o" "build/a64/$n.s"' sh
fi
for s in src/mac/*.s; do
    o=build/obj/$(name "$s").o
    stale "$o" "$s" src/mac/mac.inc && as $ASFLAGS -I src/mac -o "$o" "$s"
    objs="$objs $o"
done

LIBS="-framework AppKit -framework QuartzCore -framework IOSurface -framework CoreServices -framework Carbon -framework Security"
link() { # out objs...
    out=$1; shift
    clang -arch arm64 -mmacosx-version-min=$MINOS -o "$out" "$@" $LIBS
}
link build/rhun $objs
[ "$1" = release ] && strip -x build/rhun

# build/rhun.app, signed ad hoc for this machine (tools/package-mac.sh signs for distribution)
app=build/rhun.app/Contents
mkdir -p $app/MacOS $app/Resources
# a new file, not rewritten in place: a running rhun keeps its code pages
cp build/rhun $app/MacOS/rhun.new && mv -f $app/MacOS/rhun.new $app/MacOS/rhun
[ -f assets/icons/rhun.icns ] && cp assets/icons/rhun.icns $app/Resources/rhun.icns
# the bundle versions are numbers only: a prerelease suffix (-rc1) is left out
sed "s/@VERSION@/$(sed "s/-.*//" VERSION)/" assets/mac/Info.plist > $app/Info.plist
codesign -s - -f build/rhun.app 2>/dev/null
if [ "$1" = test ]; then
    lib=$(echo $objs | tr ' ' '\n' | grep -v 'src_main.o')
    for t in tests/*.s; do
        n=$(basename "$t" .s)
        link "build/$n" build/obj/tests_$n.o $lib
    done
    for t in tests/mac/*.s; do
        [ -f "$t" ] || continue
        n=mac_$(basename "$t" .s)
        o=build/obj/tests_$n.o
        as $ASFLAGS -I src/mac -o "$o" "$t"
        helper="${t%_test.s}_helper.m"
        if [ -f "$helper" ]; then
            h=build/obj/tests_${n}_helper.o
            clang $ASFLAGS -fobjc-arc -Wall -Wextra -Werror -c "$helper" -o "$h"
            link "build/$n" "$o" "$h" $lib
        else
            link "build/$n" "$o" $lib
        fi
    done
fi
