#!/bin/sh
# builds test binaries and compares their output with tests/data/*.expected
cd "$(dirname "$0")/.."
./build.sh test || exit 1
fail=0
tmp=$(mktemp) || exit 1
trap 'rm -f "$tmp"' EXIT HUP INT TERM
check() { # name cmd...
    name=$1; shift
    if "$@" > "$tmp" 2>&1 && cmp -s "$tmp" "tests/data/$name.expected"; then
        echo "ok   $name"
    else
        echo "FAIL $name"; fail=1
    fi
}
check keymap-names-us-ru build/xkb_test tests/data/keymap-names-us-ru.txt
check keymap-gnome-us build/xkb_test tests/data/keymap-gnome-us.txt
check keymap-pl-intl build/xkb_test tests/data/keymap-pl-intl.txt
check doc build/doc_test
check config env XDG_CONFIG_HOME=tests/data/config-reload build/config_test
check syntax build/syntax_test
check themes env HOME=/nonexistent XDG_CONFIG_HOME=tests/data/config build/theme_test
check term build/term_test
check diff build/diff_test
check images build/image_test $(ls tests/data/images/* | LC_ALL=C sort)
check cpu build/cpu_test
check cols build/cols_test
check strfind build/str_test tests/data/strfind.txt
check versions build/update_test tests/data/versions.txt
check paths build/path_test tests/data/paths.txt
check grammars env HOME=/nonexistent XDG_CONFIG_HOME=tests/data/config build/grammar_test tests/data/detect.txt tests/data/samples
dups=$(grep -h '^files' runtime/syntax/*.syn | sed 's/^files *= *//' | tr ' ' '\n' | grep -v '^$' | sort | uniq -d)
if [ -z "$dups" ]; then echo "ok   grammar-patterns"; else echo "FAIL grammar-patterns: $dups"; fail=1; fi
check prefix-tag build/grammar_test --try tests/data/prefix-tag.syn tests/data/prefix-tag.txt
if [ "$(build/rhun --version)" = "rhun $(cat VERSION)" ]; then echo "ok   version"; else echo "FAIL version"; fail=1; fi
python3 tests/palette-scroll.py || fail=1
sh tests/files.sh || fail=1
sh tests/update.sh || fail=1
python3 tests/commit-ai.py || fail=1
sh tests/detach.sh || fail=1
sh tests/blink.sh || fail=1
sh tests/session.sh || fail=1
python3 tests/desktop-ux.py || fail=1
python3 tests/theme-chrome.py || fail=1
if [ "$(uname -s)" = Darwin ] || command -v strace >/dev/null; then
    status=0
    sh tests/file-faults.sh || status=$?
    [ "$status" = 0 ] || [ "$status" = 77 ] || fail=1
fi
[ -x tests/ui.sh ] && { tests/ui.sh || fail=1; }
exit $fail
