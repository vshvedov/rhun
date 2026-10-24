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
check doc-language build/doc_language_test
check doc-language-choice build/doc_language_choice_test
check doc-selections build/doc_selections_test
check doc-multi-edit build/doc_multi_edit_test
check doc-batch build/doc_batch_test
check doc-batch-guard build/doc_batch_guard_test
check editor-multi-type build/editor_multi_type_test
check editor-multi-newline build/editor_multi_newline_test
check editor-multi-delete build/editor_multi_delete_test
check editor-multi-tab build/editor_multi_tab_test
check clipboard-write build/clipboard_write_test
check clipboard-wire build/clipboard_wire_test
check clipboard-metadata build/clipboard_metadata_test
check clipboard-context build/clipboard_context_test
check clipboard-paste-queue build/clipboard_paste_queue_test
if [ "$(uname -s)" = Darwin ]; then
    check mac-clipboard-read build/mac_clipboard_read_test
    check mac-clipboard-metadata build/mac_clipboard_metadata_test
    if python3 tests/mac-clipboard-metadata.py; then :; else fail=1; fi
fi
if [ "$(uname -s)" = Linux ]; then
    if python3 tests/clipboard-faults.py; then :; else fail=1; fi
    check x11-wire build/x11_wire_test
    check x11-paste build/x11_paste_test
    check x11-string build/x11_string_test
    check x11-send build/x11_send_test
    check x11-metadata build/x11_metadata_test
    check wayland-paste build/wayland_paste_test
    check wayland-send build/wayland_send_test
    check wayland-metadata build/wayland_metadata_test
    check clipboard-async build/clipboard_async_test
fi
check editor-clipboard build/editor_clipboard_test
check editor-paste build/editor_paste_test
check snippet build/snippet_test
check snippet-choice build/snippet_choice_test
check snippet-unicode build/snippet_unicode_test
check snippet-regex build/snippet_regex_test
check snippet-regex-state build/snippet_regex_state_test
check snippet-regex-scope build/snippet_regex_scope_test
check snippet-regex-match build/snippet_regex_match_test
check snippet-regex-limits build/snippet_regex_limits_test
check snippet-replacement build/snippet_replacement_test
check snippet-case build/snippet_case_test
check snippet-case-api build/snippet_case_api_test
check snippet-transform build/snippet_transform_test
check snippet-transform-api build/snippet_transform_api_test
check snippet-transform-indent build/snippet_transform_indent_test
check snippet-transform-payload build/snippet_transform_payload_test
check snippet-indent-capture build/snippet_indent_capture_test
check snippet-transform-leave build/snippet_transform_leave_test
check snippet-base64 build/snippet_base64_test
check config env XDG_CONFIG_HOME=tests/data/config-reload build/config_test
check ext-settings-target env XDG_CONFIG_HOME=tests/data/ext-settings-target build/ext_settings_target_test
check ext-send build/ext_send_test
python3 tests/ext-flush.py || fail=1
python3 tests/ext-events.py --negative-controls || fail=1
python3 tests/ext-pending-commands.py || fail=1
python3 tests/ext-pending-owner.py || fail=1
python3 tests/file-read-limited.py || fail=1
python3 tests/dir-scan.py || fail=1
check config-strings build/config_strings_test
check keys build/keys_test
check ui-clip build/ui_clip_test
check fill build/fill_test
check memmove build/memmove_test
python3 tests/mem-try.py || fail=1
python3 tests/mem-helpers.py || fail=1
check syntax build/syntax_test
check themes build/theme_test
check term build/term_test
check diff build/diff_test
# debugger: the JSON builder and parser
check json build/json_test
check images build/image_test $(ls tests/data/images/* | LC_ALL=C sort)
python3 tests/image-fuzz.py 1 20 || fail=1
check cpu build/cpu_test
check cols build/cols_test
check textarea build/textarea_test
check strfind build/str_test tests/data/strfind.txt
check versions build/update_test tests/data/versions.txt
python3 tests/mac-package.py || fail=1
python3 tests/windows-package.py || fail=1
python3 tests/installer-unicode.py || fail=1
python3 tests/install-command.py || fail=1
check paths build/path_test tests/data/paths.txt
check urls build/url_test tests/data/urls.txt
check grammars env HOME=/nonexistent XDG_CONFIG_HOME=tests/data/config build/grammar_test tests/data/detect.txt tests/data/samples
dups=$(grep -h '^files' runtime/syntax/*.syn | sed 's/^files *= *//' | tr ' ' '\n' | grep -v '^$' | sort | uniq -d)
if [ -z "$dups" ]; then echo "ok   grammar-patterns"; else echo "FAIL grammar-patterns: $dups"; fail=1; fi
check prefix-tag build/grammar_test --try tests/data/prefix-tag.syn tests/data/prefix-tag.txt
check fileicons env HOME=/nonexistent XDG_CONFIG_HOME=tests/data/fileicons-config build/fileicon_test tests/data/fileicons.txt
if [ "$(build/rhun --version)" = "rhun $(cat VERSION)" ]; then echo "ok   version"; else echo "FAIL version"; fail=1; fi
python3 tests/palette-scroll.py || fail=1
python3 tests/commit-wrap.py || fail=1
python3 tests/git-reset.py || fail=1
python3 tests/git-untracked.py || fail=1
python3 tests/git-fsmonitor.py || fail=1
python3 tests/git-trust.py || fail=1
python3 tests/live-reload.py || fail=1
python3 tests/tooltips.py || fail=1
python3 tests/terminal-tabs.py || fail=1
python3 tests/terminal-panel.py || fail=1
python3 tests/terminal-keys.py || fail=1
python3 tests/terminal-links.py || fail=1
python3 tests/terminals.py || fail=1       # tasks and terminals: programs' tabs, run-as-user approval
python3 tests/task-patterns.py || fail=1   # tasks and terminals: patterns, matchers, the Problems store
python3 tests/terminals-feature.py || fail=1   # tasks and terminals: the terminals feature
python3 tests/tasks.py || fail=1           # tasks and terminals: the tasks feature and commands
python3 tests/new-window.py || fail=1
python3 tests/file-launch.py || fail=1
python3 tests/readonly-save.py || fail=1
python3 tests/save.py || fail=1
python3 tests/save-actions.py || fail=1
python3 tests/reopen-tab.py || fail=1
python3 tests/focused-zoom.py || fail=1
python3 tests/agents.py || fail=1
python3 tests/opencode.py || fail=1
python3 tests/agents-refresh.py || fail=1
python3 tests/ext-agents.py || fail=1
python3 tests/ext-review.py || fail=1
python3 tests/ext-tools.py || fail=1
python3 tests/ext-prompts.py || fail=1
sh tests/files.sh || fail=1
sh tests/update.sh || fail=1
python3 tests/commit-ai.py || fail=1
sh tests/detach.sh || fail=1
sh tests/blink.sh || fail=1
python3 tests/field-blink.py || fail=1
sh tests/session.sh || fail=1
python3 tests/desktop-ux.py || fail=1
python3 tests/mac-launch.py || fail=1
python3 tests/x11-auth.py || fail=1
python3 tests/linux-clipboard.py || fail=1
python3 tests/wayland-clipboard.py || fail=1
python3 tests/explorer-delete.py || fail=1
python3 tests/explorer-create.py || fail=1
python3 tests/explorer-tabs.py || fail=1
python3 tests/settings-ui.py || fail=1
python3 tests/settings-search.py || fail=1
python3 tests/appearance.py || fail=1
python3 tests/editor-matrix.py || fail=1
python3 tests/editor-hscroll.py || fail=1
python3 tests/multicursor.py || fail=1
python3 tests/multicursor-vim.py || fail=1
python3 tests/splitter.py || fail=1
python3 tests/scroll-sensitivity.py || fail=1
python3 tests/window-focus.py || fail=1
python3 tests/new-tab.py || fail=1
python3 tests/tab-drag.py || fail=1
python3 tests/tab-pin.py || fail=1
python3 tests/tab-view.py || fail=1
python3 tests/terminal-font.py || fail=1
python3 tests/shift-wheel.py || fail=1
python3 tests/stress.py || fail=1
python3 tests/ext-host.py || fail=1
python3 tests/ext-commands.py || fail=1
# resources, workspaces, secrets and lifecycle
python3 tests/ext-lifecycle.py || fail=1
python3 tests/ext-secrets.py || fail=1
python3 tests/ext-vdoc.py || fail=1
python3 tests/ext-urls.py || fail=1
python3 tests/ext-files.py || fail=1
python3 tests/ext-settings-scoped.py || fail=1
python3 tests/workspace-folders.py || fail=1
# contributions and commands
python3 tests/when.py || fail=1
python3 tests/ext-command-args.py || fail=1
python3 tests/ext-run-command.py || fail=1
python3 tests/keys-chords.py || fail=1
python3 tests/ext-menus.py || fail=1
python3 tests/ext-status-items.py || fail=1
python3 tests/ext-sdk-commands.py || fail=1
python3 tests/langconf.py || fail=1
python3 tests/icon-themes.py || fail=1
python3 tests/ext-contrib-page.py || fail=1
# source control: Git data, commit messages, quick diff, version control panels
python3 tests/ext-scm.py || fail=1
python3 tests/new-extension.py || fail=1   # rhun new-extension and Extensions: New Extension…
python3 tests/submit-extension.py || fail=1   # rhun submit-extension and Extensions: Submit to Index…
# editor presentation
python3 tests/inc-names.py > /dev/null || { python3 tests/inc-names.py; fail=1; }
python3 tests/ctl-names.py > /dev/null || { python3 tests/ctl-names.py; fail=1; }
python3 tests/enum-values.py --negative-control > /dev/null || { python3 tests/enum-values.py --negative-control; fail=1; }
python3 tests/asm-pitfalls.py --negative-control > /dev/null || { python3 tests/asm-pitfalls.py --negative-control; fail=1; }
check edtape build/edtape_test
python3 tests/presentation.py || fail=1
python3 tests/folding.py || fail=1
python3 tests/semantic.py || fail=1
python3 tests/hints.py || fail=1
python3 tests/lens.py || fail=1
python3 tests/highlights.py || fail=1
python3 tests/colors.py || fail=1
python3 tests/ghost.py || fail=1
python3 tests/ext-snapshots.py || fail=1
python3 tests/snippets.py || fail=1
python3 tests/snippet-variants.py || fail=1
python3 tests/snippet-transforms.py || fail=1
python3 tests/snippet-choices.py || fail=1
python3 tests/snippet-final.py || fail=1
python3 tests/snippet-context.py || fail=1
python3 tests/ext-providers.py || fail=1
python3 tests/ext-language.py || fail=1
python3 tests/ext-selections.py || fail=1
python3 tests/ext-scheduling.py || fail=1
python3 tests/ext-watch.py || fail=1
python3 tests/ext-watch-native.py || fail=1
python3 tests/ext-boundaries.py || fail=1
python3 tests/ext-confine.py || fail=1
python3 tests/ext-ui.py || fail=1
# notebooks and custom editors (wider parity A, B)
python3 tests/ext-notebooks.py || fail=1
python3 tests/ext-editors.py || fail=1
# extension management: versions, roll back, updates, removal, development installs
python3 tests/ext-updates.py || fail=1
python3 tests/ext-remove-clean.py || fail=1
python3 tests/ext-dev-install.py || fail=1
python3 tests/ext-browse.py || fail=1
python3 tests/ext-packs.py || fail=1
python3 tests/ext-data.py || fail=1
# views group: places, retained trees, logs, tabs
python3 tests/ext-views-tree.py || fail=1
python3 tests/ext-views-log.py || fail=1
python3 tests/ext-notify.py || fail=1
python3 tests/ext-views-picture.py || fail=1
python3 tests/markdown.py || fail=1
python3 tests/ext-views-form.py || fail=1
python3 tests/ext-views-table.py || fail=1
python3 tests/ext-quick.py || fail=1
python3 tests/ext-views-doc.py || fail=1
python3 tests/ext-fuzz.py 1 4 || fail=1
# debugger (DAP client) with the fake adapter tests/dap/fakedap.py
for t in debug-launch debug-framing debug-config debug-breakpoints debug-step debug-lifetime debug-view debug-gutter debug-transport debug-terminal debug-feature debug-tasks debug-review debug-sessions debug-questions debug-variables debug-configs debug-threads debug-remote debug-real; do
    python3 tests/$t.py || fail=1
done
# testing: the test explorer (feature "tests")
python3 tests/testing.py || fail=1
python3 tests/testing-real.py || fail=1   # skips without TESTS_DIR (a rhun-editor/tests checkout)
# WebAssembly extension host (src/wasm): the core spec suite needs wabt's wast2json
if command -v wast2json >/dev/null; then python3 tests/wasm-spec.py || fail=1; else echo "skip wasm-spec (no wast2json)"; fi
python3 tests/wasm-host.py || fail=1
python3 tests/wasm-wasi.py || fail=1
python3 tests/wasm-fuzz.py 1 2 --count 100 || fail=1
# language features: the query engine, completion items, code actions, rename and formatting,
# file diagnostics, the Results panel and hierarchies, the peek view, the hover card, selection
# ranges, workspace symbols, document links
for t in langfeat-query complete-items code-actions rename-format file-diagnostics results peek hover-query \
         selection-ranges workspace-symbols document-links definition-link; do
    python3 tests/$t.py || fail=1
done
python3 tests/langfeat-real.py || fail=1
# workspace edits and the editor model: transactions, disk edits, file operations
python3 tests/wsedit.py || fail=1
python3 tests/ext-reveal.py || fail=1
python3 tests/ext-linked.py || fail=1
if [ "$(uname -s)" = Darwin ] || command -v strace >/dev/null; then
    status=0
    sh tests/file-faults.sh || status=$?
    [ "$status" = 0 ] || [ "$status" = 77 ] || fail=1
fi
[ -x tests/ui.sh ] && { tests/ui.sh || fail=1; }
exit $fail
