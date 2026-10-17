#!/bin/sh
# Lays the local extension repositories out the way rhun installs them, builds their programs for
# this machine, and prints the command that opens rhun with them. For looking at the real thing:
# the palette entries, the extensions button in the title bar and the Extensions page, the confinement at work.
#   tools/ext-dev.sh [SRC_DIR] [OUT_DIR]      SRC_DIR holds one folder per extension (default
#                                             ~/tmp/rhun-editor), OUT_DIR the layout (build/ext-dev)
set -e
cd "$(dirname "$0")/.."
src=${1:-$HOME/tmp/rhun-editor}
out=${2:-$PWD/build/ext-dev}
case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) target=linux-x86_64 ;;
    Darwin-arm64) target=macos-arm64 ;;
    *) echo "no target for $(uname -s)-$(uname -m)"; exit 1 ;;
esac
rm -rf "$out"
for dir in "$src"/*/; do
    [ -f "$dir/extension.ini" ] || continue
    name=$(sed -n 's/^name = //p' "$dir/extension.ini")
    owner=$(sed -n 's/^owner = //p' "$dir/extension.ini")
    [ -n "$name" ] && [ -n "$owner" ] || continue
    dest=$out/$owner/$name
    mkdir -p "$dest/bin"
    cp "$dir/extension.ini" "$dest/"
icon=$(sed -n 's/^icon = //p' "$dir/extension.ini"); [ -z "$icon" ] || cp "$dir/$icon" "$dest/"
    [ -d "$dir/syntax" ] && cp -R "$dir/syntax" "$dest/"
    [ -d "$dir/themes" ] && cp -R "$dir/themes" "$dest/"
    if [ -f "$dir/go.mod" ]; then
        (cd "$dir" && CGO_ENABLED=0 go build -o "$dest/bin/$name-$target" .) && echo "built $owner/$name"
    fi
done
echo
echo "rhun with these extensions (the state folder and extensions.ini stay the user's):"
echo "  ./build/rhun --extensions $out"
echo "then the puzzle button in the title bar: the dropdown, pins, Manage extensions, Install from GitHub…"
