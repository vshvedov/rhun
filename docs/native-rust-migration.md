# Native Rust migration

## Purpose and compatibility contract

Replace Rhun's Assembly implementation with a native Rust implementation, not
a redesign. Preserve existing user-visible behavior, keyboard shortcuts,
workflows, platform integrations, packaging, installers, and updates as closely
as possible. Keep the Assembly tree and its test fixtures as the executable
reference until the Rust replacement passes the relevant compatibility gates.
No Assembly source, translator, or build path is to be removed before that.

## Audit and baseline

The repository has no Rust crate or Cargo manifest. The application is built
from `src/**/*.s` and generated `build/assets.s`. Static inspection found:

- `src/app/` contains application startup, document/editor, Vim, explorer,
  command palette, settings/config, syntax/themes, terminal, Git/SCM, agents,
  sessions, image view, and updater modules.
- `src/gfx/`, `src/ui/`, and `src/img/` provide the raster canvas, fonts/icons,
  immediate-mode widgets, and image decoders. `src/sys.s`, `mem.s`, `lib.s`,
  `proc.s`, `json.s`, `ini.s`, and `casefold.s` provide shared runtime
  primitives. `src/rhun.inc` defines shared layouts and platform conventions.
- `src/plat/` includes Linux Wayland, X11, XKB, headless and appearance
  integrations. `src/mac/` supplies native AppKit/AArch64 glue and the
  translated-core system-call bridge. `src/win/` supplies Win32, Unicode paths,
  clipboard, file watching, ConPTY, and Windows updater integration.
- `runtime/` holds embedded themes, syntax grammars, and AI/update helpers.
  `assets/` includes the built-in font, file/provider icons, and platform
  metadata. Preserve existing assets and licenses.
- `tests/` contains Assembly unit-test drivers, exact-output fixtures,
  headless scripted UI workflows, platform checks, and stress/fuzz tests.
  `tests/run.sh` runs the portable suite; Windows and CI workflows add native
  window, install/update, packaging, and appearance checks.
- `tools/`, root installer scripts, and `.github/workflows/` implement
  platform-specific builds, asset embedding, packaging, signing, release
  publication, installation, and updates. The site is documentation and
  presentation, not application code to translate.

The supported native targets are Linux x86-64 with Wayland and X11, macOS on
Apple silicon (AArch64/AppKit), and Windows x64 (Win32; Windows 10 1809 or
later and Windows 11). Existing build dependencies are GNU `as`/`ld` on Linux;
Python's x86-64-to-AArch64 translator plus Apple tooling on macOS; and Python
plus LLVM tools (`llvm-mc`, `llvm-dlltool`, `lld-link`, `llvm-rc`) on Windows.
Generated assets embed runtime data, fonts, and helper scripts. Features also
integrate with user-installed shells, Git, browsers/file managers, agent CLIs,
and optionally Ollama.

### Original baseline

The first attempt was blocked by workspace command permission. After permission
became available, the Windows toolchain probe found Python 3.13 and Rust/Cargo
1.95, but not LLVM. The repository's pinned tool bootstrap installed LLVM
23.1.2 under ignored `build/llvm/`; it downloaded and checksum-verified the
upstream archive. No tracked Assembly source was modified.

Baseline commands/results on Windows:

| Command | Result |
|---|---|
| `tools/setup-windows-llvm.ps1` | Passed; pinned LLVM 23.1.2 installed |
| `$env:LLVM_BIN = Join-Path (Get-Location) 'build\llvm\bin'; python tools/build-windows.py test` | Passed |
| `$env:LLVM_BIN = Join-Path (Get-Location) 'build\llvm\bin'; python tests/windows.py` | Failed in 5 checks listed below; remaining reported core/UI checks passed, with environment-specific skips |
| `python tools/package-windows.py` | Passed; produced the local versioned ZIP |
| `python tests/windows-install.py` | Failed in the staged-file-lock reinstall scenario: the installer attempted to remove a stage while `LICENSE` was held open; temporary-directory cleanup then reported the same sharing violation |
| `$env:LLVM_BIN = Join-Path (Get-Location) 'build\llvm\bin'; python tests/windows-update.py` | Passed all reported update checks |

Known pre-migration failures from `tests/windows.py`:

- `ui/terminal-tabs`: 3 assertions (terminal selection after closing tabs and
  visible overflow tabs).
- `terminal/cls-keeps-prompt`: expected prompt output differs after `cls`.
- `agents/windows-session-paths`: expected fixture text does not include
  worktree badges that the current implementation emits.
- `window/file-only-background-start-foreground` and
  `window/file-launch-preserves-minimized-unsaved-project`: foreground-window
  race assertions.

The suite also reported documented platform/permission-related skips. These
are original-implementation baseline failures, not Rust regressions. Linux
`./build.sh`/`tests/run.sh` and macOS build/test commands remain unavailable on
this Windows host; those targets are not yet validated here.

## Feature compatibility checklist

This inventory is evidence-based on `README.md`, `docs/guide.md`, source
modules, build scripts, tests, and CI. The Rust GUI currently covers only a
small subset of startup and document editing; the Assembly implementation
remains the production application and compatibility oracle. This summary
supplements rather than replaces the existing regression suite.

| Area | Required behavior |
|---|---|
| Startup and CLI | Paths, files/folders, quick edit, `--wait`, `--empty`, `--headless`, `--scale`, `--script`, Unix `--control`, help/version, project/session restore rules, detach/foreground activation |
| Window/platform | Native window and event loop; Linux Wayland/X11 and XKB/Compose; AppKit/AArch64; Win32; keyboard, pointer, clipboard, file drops/launch, cursors, appearance, DPI/fractional scale, resize/fullscreen |
| Rendering/UI | Software canvas, text/font/icon rasterization and fallback, title bar, tabs, panels, dialogs, status, tooltips, splitters, mouse hit-testing and scrolling |
| Editing/documents | UTF-8 editing, selection/cursor/scroll, tabs, gap-buffer-equivalent behavior, line index, undo/redo grouping, auto-indent/brackets/comments, line operations, wrap/h-scroll, save/reload, read-only prompts, external edits, symlink/moved-file behavior |
| Navigation/workspace | Explorer, file icons, create/delete/context menus, path browser, recent folders, multi-window, palette, fuzzy open/search, find/replace/in-files, go-to-line, live config |
| Syntax/themes | Built-in and user grammars (~125 languages), pattern/first-line selection, theme parsing and 40 built-ins, dark/light/system/Omarchy following, terminal/Git/icon colors |
| Vim | Normal/insert/visual/visual-line modes, motions/counts/operators/text objects, repeat/search/Ex commands, clipboard; preserve documented omissions (registers, marks, macros, ranges, `:s`, visual block, replace mode) |
| Images | PNG, JPEG baseline/progressive and EXIF orientation, GIF first frame, BMP, ICO/CUR, QOI, PNM, TGA; transparency, fit/zoom/pan/status, reload |
| Terminal | PTY/ConPTY, shells, 24-bit color, scrollback, full-screen/mouse apps, tabs/panel, copy/paste, keyboard protocol, links/file navigation, font/zoom, process lifecycle |
| Git/diffs | Async discovery, gutter and file statuses, read-only diffs, all-branch history graph, stage/unstage/discard/reset, commit/amend, pull/push/fetch/sync/publish, upstream/conflicts/errors |
| Commit AI | Off/Claude/Codex/Ollama, authentication checks, bounded/safe diff input, background/cancel/setup/download/delete, temporary index, draft preservation |
| Agents | Claude/Codex/Grok discovery, refresh/index/pagination, Git worktrees and historical/nested paths, provider UI, hidden-panel pause, shutdown |
| Sessions/files/processes | Per-project tabs/state and recent projects, file watching, process/environment handling, Windows Unicode/long paths, clean shutdown |
| Control/regression | Existing line-oriented scripting protocol, headless rendering and all state/document/panel/Git/terminal/agent/appearance output, exact fixture results |
| Install/update/release | Linux/macOS shell installer, Windows PowerShell installer, hashes, associations/default-editor guidance, PATH, configure/uninstall, self-update/restart, archives/signing/notarization/CI |
| Assets/docs | Embedded data and licenses; update build/platform/source documentation as cutover occurs; retain static site behavior |

### AI harness boundary

Rhun is an editing and inspection harness for user-directed work, not an
autonomous coding agent. Its existing Agents panel observes sessions launched
by external Claude Code, Codex, and Grok tools; it does not create or direct
those sessions. Preserve that observer behavior for compatibility. AI
generation remains explicit and reviewable: the existing commit-message
workflow drafts text only, never stages or commits, runs providers with tools
restricted, and rejects results if repository changes move during generation.
Do not add autonomous file editing, command execution, provider fallback, or
background coding-agent behavior to the Rust app.

`tests/run.sh` provides exact-output regressions for keymaps, docs, config,
keys, clipboard, syntax, themes, terminal, diff, images, CPU/render helpers,
columns, text areas, string search, versions, paths, grammars, and file icons,
plus scripted UI, stress, Git, session, agents, terminal, launch, appearance,
installer/update, and file-fault workflows. Windows adds native
input/platform/wheel/path/AI, install, and update tests. CI covers native Linux
X11/Wayland launches, macOS packaging/signing, and Windows workflows. Retain
these as compatibility oracles and add cases when porting uncovers gaps.

## Rust architecture and dependency choice

Use a modular monolith in a new `rust/` directory with an independent Cargo
package so Rust and Assembly can coexist while the migration is incomplete.
Keep app behavior, editor state, the event loop, command/key registry,
software-rendering contract, and control protocol in shared Rust modules.
Place OS-specific windowing, input, filesystem notifications, clipboard,
appearance, terminal, and process behavior behind narrow Linux/macOS/Windows
adapters. Limit and document `unsafe` at native FFI boundaries. Do not adopt a
toolkit or redesign interaction semantics.

The initial no-crate prototype was replaced with a deliberately limited native
GUI experiment using `eframe` 0.31.1 / `egui` 0.31.1. Cargo enables only
`default_fonts`, `glow`, `wayland`, and `x11` in the direct `eframe`
dependency; `Cargo.lock` records the full transitive graph. This provides an
immediately testable desktop window without a browser/webview, but it is not a
parity decision: egui's rendering, widgets, event handling, accessibility,
window behavior, binary size, and packaging still require comparison against
Rhun's software canvas and native platform implementations. Do not remove or
replace the original renderer on the strength of this prototype.

Use `std` for document storage and file operations. Keep OS-specific clipboard,
file-watch, terminal, appearance, process, and window behavior behind narrow
adapters when those subsystems are implemented; constrain `unsafe` to native
FFI boundaries. Continue embedding the current runtime/assets and preserving
their licenses. Before adding more direct or transitive dependencies, record
the subsystem need, license, target support, distribution impact, and
fixture/runtime evidence.

The Rust project-search slice uses `ignore` 0.4.33 (MIT OR Unlicense) for
standard nested `.gitignore` parsing, wildcard rules, and negations rather
than introducing a partial custom matcher. It builds for the current Windows
target and is covered by root/nested ignore and re-include tests. Its glob,
regex, and crossbeam dependencies increase the lockfile and binary build graph;
they should be reconsidered if a later shared traversal layer replaces this
search implementation.

The initial session slice uses `std` only and writes Rhun's existing
tab-delimited per-project `.session` format under the platform state
directory. It restores existing file paths and the active-tab marker on
launch, and saves open file paths, active tab, and cursor byte offsets after
exit prompts are resolved. Cursor byte offsets are converted to egui character
indices with UTF-8 boundary clamping on restore. Pathless launches restore
from the current working directory, not the user's last project. The Windows
filename encoding/length limit and Unix encoding have unit coverage, but only
Windows has been built. It does not yet restore the last project, recent-project
menu, or per-project settings preference.

```text
Linux / macOS / Windows windowing backends
                    |
            eframe / egui prototype
                    |
       app state, commands, documents
                    |
       future Rhun-compatible UI/rendering
```

The current executable uses eframe/egui above the OS windowing layer; it does
not yet provide the former shared software canvas. Linux must continue to
support Wayland and X11 plus existing key layouts; macOS must be native
Apple-silicon AppKit (not translated x86 code); Windows must retain Win32
Unicode paths, clipboard, per-monitor DPI, notifications, ConPTY,
console/editor launches, and updater behavior.

## Migration sequence and acceptance gates

1. **Audit/baseline (this document):** map source, features, assets, tests,
   platforms, packaging and dependencies. Record baseline limits. No source
   changes before this document.
2. **Standalone core:** add the `rust/` Cargo package. Port CLI parsing and
   defaults with table-driven tests, then wire the Rust executable to a native
   window while leaving Assembly unchanged and runnable. Treat the current
   egui shell as a prototype, not as evidence of widget or renderer parity.
3. **Shared primitives/documents:** port UTF-8/string/case-fold/path/config/JSON,
   document buffer/line/undo/save semantics, key bindings, syntax and themes.
   The current slice has only a `String` document buffer, file-level
   open/save/change checks, and basic path/active-tab session persistence.
   Compare existing expected output; run corresponding Assembly and Rust tests.
4. **Graphics/headless harness:** establish a compatibility decision for egui
   versus a Rust port of Rhun's software canvas; port font/icon/image/render/UI
   behavior and the script/control protocol; preserve format coverage and
   snapshot results.
5. **Native platform adapters:** validate Linux headless, Wayland, X11, then
   native macOS and Windows. Cross-compilation/emulation is not native
   verification. Test input, clipboard, appearance, scale, launch, lifecycle.
6. **Application features:** migrate navigation/panels, terminal, Git/SCM,
   sessions/file watching, images, agents, AI, settings, and updates in small
   independently tested increments.
7. **Distribution cutover and retirement:** add Rust builds/tests/install/
   release jobs on all targets. Keep Assembly sources, test paths, and build
   dependencies until parity, platform CI, workflows, package/install/update,
   and clean-checkout builds pass. Only then remove Assembly, its translator,
   assembler/linker paths, and obsolete tests; verify clean clones and all
   release archives no longer need Assembly.

For each subsystem, report exact commands, target OS, pass/fail evidence, and
unverified behavior. Update this checklist only with evidence. Do not claim
parity from a successful compile alone.

## Status

- Repository/build/test/platform inventory: documented.
- Windows Assembly build and baseline: executed; build passed, five test checks
  failed before migration, installer staging-lock check failed, updater suite
  passed (details above).
- Rust package: created at `rust/`; the executable depends on eframe/egui
  0.31.1 and `ignore` 0.4.33 as described above. The Assembly build and
  launch remain unchanged.
- Verified Rust slice: launch argument model/parser for existing option
  spellings, defaults, paths, headless size parsing, scale parsing, help/version
  dispatch, and agent-index worker dispatch; eight parser tests pass. A native
  editor window can open a supplied text file, edit it, save with Ctrl+S, and
  close on Windows. Document open/save/dirty/missing-file tests also pass.
  Direct `--help` and `--version` output were exercised. The parser's reported
  `--headless`, `--script`, and `--control` are explicitly rejected by the new
  application, and agent-index worker mode is not migrated. `--wait` is parsed
  but its distinct launcher/terminal workflow has not been ported or verified.
- Current Rust GUI functionality: multiple in-memory tabs, path-based file and
  folder opening, text editing, saving existing files and path-based Save As,
  an expandable lazy-loaded project tree with directory navigation, refresh and file
  opening, Ctrl+P/Ctrl+E asynchronous fuzzy file search over nested project
  paths, asynchronous case-insensitive text search over project files with
  clickable file results, in-document next/previous find and single/replace-all,
  go-to-line, periodic reload checks for clean files, New/Open/Save/Save As/
  Close/Close All/Quit/Reopen Closed Tab/Find/Replace/Find Next/Find Previous/
  Go to Line/Open File/Open Folder/next-tab/previous-tab shortcuts, and per-document
  save/discard/cancel prompts for dirty-tab close and application exit. Exit
  and close-all prompts are sequenced one dirty document at a time. Basic per-project file
  session restore/save uses the Assembly tab-delimited format, restoring on a
  pathless launch from the current directory or a single-folder launch and
  saving paths, active tab, and cursor byte offsets after application-exit
  prompts are resolved. `--empty` and explicit
  file launches skip initial session restore. A pathless `--empty` launch does
  not adopt the current directory or overwrite its saved session; opening a
  file or saving a new document adopts that file's parent as the project.
- The Rust document model now supports bounded undo/redo history (up to 1,000
  snapshots), coalesces consecutive editor changes within 750 ms, preserves
  UTF-8 text and cursor/selection positions, and routes Ctrl/Cmd+Z and
  Ctrl/Cmd+Y or Shift+Z through the active editor. Find/replace-one and
  replace-all each create undoable edits. Undo/redo history is not yet grouped
  according to the Assembly editor's full edit-kind, cursor-motion, and
  savepoint rules; undo state is not persisted across application restarts.
- Pressing Enter in the focused editor preserves the current leading whitespace,
  adds the configured indentation unit after `{`, `(`, or `[`, and splits an
  immediately matching empty bracket pair across two lines. These edits join
  document undo history. Startup reads the existing `tab_width` and
  `insert_spaces` values from `[editor]` in the user config, defaulting to four
  spaces; settings UI/live reload, language-specific `:` indentation, and the
  full Assembly newline behavior are not migrated.
- Tab in the focused editor inserts to the configured tab stop; a multi-line
  selection indents each selected line while retaining the selection. When
  `insert_spaces` is false, a single-line Tab inserts a literal tab and
  multi-line indentation uses tabs. These operations are undoable. Exact
  Assembly selection and cursor behavior remains unverified.
- Ctrl+[ outdents the current or selected lines by removing one indentation
  unit from each line according to the configured tab width (a leading tab
  counts as one unit); unindented lines are unchanged. The operation is
  undoable. Exact Assembly selection/cursor rules remain unverified.
- Ctrl+] indents each nonempty current/selected line using the configured
  indentation unit and skips blank lines. The operation is undoable. This is
  separate from Tab, which inserts at a single-line caret or indents a
  multi-line selection.
- Ctrl+Shift+D duplicates the current or selected lines below the block,
  Ctrl+Shift+K deletes those lines, and Alt+Up/Down moves the block one line
  while keeping the selection/caret associated with its text. The operations
  create undoable edits. Their behavior around line endings, empty terminal
  lines, and selection-edge cases still needs differential testing against
  Assembly's editor fixtures.
- Ctrl+/ now toggles line comments for a subset of common file extensions
  (including Rust/C/JavaScript, Python/shell/YAML, SQL, JSON, HAML, Pug, and
  Batch) using the existing syntax comment tokens. It skips blank lines,
  removes the comment token plus one following space only when all selected
  nonblank lines are already commented, and creates one undoable edit. This is
  an extension-based subset, not the Assembly grammar-driven language mode:
  custom grammars, first-line detection, multiple comment tokens, and exact
  indentation/selection parity remain unimplemented.
- Ctrl+Enter inserts an indented line below the caret's line; Ctrl+Shift+Enter
  inserts one above, adding the configured indent unit before a leading closing
  bracket. Both operations are undoable and restore the original cursor when
  undone. Exact Assembly cursor and selection behavior for edge cases remains
  unverified.
- Ctrl+L selects the current line, including its trailing line break when one
  exists. Repeating the command on an existing whole-line selection extends it
  by one line. UTF-8 line selection and the shortcut are covered by Rust tests;
  reverse-direction extension and exact behavior at every end-of-file edge
  remain unverified.
- File saving reads the existing `[files]` `trim_trailing_whitespace` and
  `final_newline` config values. Defaults match Rhun: trailing whitespace is
  retained and a final newline is ensured. Normalization edits the open buffer
  as one undoable operation, preserves the caret before an appended newline,
  and marks the normalized text saved only after the write succeeds. A failed
  write returns its I/O error, leaves the normalized buffer dirty, and does not
  adopt the failed target path. The Assembly editor's full savepoint/undo
  grouping semantics remain unverified.
- Config lookup honors `XDG_CONFIG_HOME`; on Windows it falls back to
  `%APPDATA%\rhun\config`, and elsewhere it uses `$HOME/.config/rhun/config`.
  Existing editor and file settings are checked on the Rust app's one-second
  maintenance interval and applied when changed. A removed config file leaves
  the current values in place. The Rust prototype does not yet expose the
  complete Settings UI or Assembly's full config/watch behavior.
- When `[editor] auto_pairs` is enabled (the default), typing `(`, `[`, `{`,
  `"`, `'`, or a backtick inserts its matching closer
  when the following character permits a pair; selected text is wrapped.
  Typing a closer already under the caret advances over it instead of
  duplicating it. Quote pairing is suppressed adjacent to identifier
  characters. The setting is read at startup; live config reload, the Assembly
  `match_brackets` setting, and all lexical-context behavior remain unimplemented.
- The initial Rust project search skips `.git`, `.hg`, `.svn`, `target`,
  `build`, and `node_modules` directories, symlinks, binary/invalid-UTF-8 files,
  and files over 4 MiB; results are capped at 1000, and truncation is reported
  only when a 1001st match exists. A regression test covers exactly 1000
  matches. Root and nested `.gitignore` patterns, directory exclusions, and
  negated re-inclusion rules are honored. Search still does not apply the
  original editor's full Unicode case-fold/search semantics.
- The Rust Go to File search walks nested files asynchronously, honors
  `.gitignore`, skips generated directories and symlinks, uses case-insensitive
  subsequence ranking, and reports when its 100,000-file scan or 200-result
  cap is reached. It searches on Enter or Search rather than filtering live;
  the original palette matching and keyboard-navigation behavior are not yet
  equivalent.
- Reopen Closed Tab stores up to 20 closed file tabs, including their original
  tab index and UTF-8-safe cursor/selection offsets. It skips files that have
  since disappeared or are already open. It does not yet restore scroll
  position, non-file tabs, or untitled documents.
- The project explorer now loads directory contents only when expanded, shows
  nested entries with indentation, and guards against recursive symlink cycles
  and excessive depth. Refresh reloads expanded folders while retaining their
  state, and drops cached entries for folders that have been removed. The original
  explorer's context menus and keyboard navigation remain unimplemented.
- Ctrl+Shift+O focuses the path field in folder-only mode. It opens directories
  as the workspace and rejects files rather than opening them as documents.
  The native/project menu, path browser, recent-folder list, and new-window
  folder workflow are not yet migrated.
- Not yet migrated: native dialogs, project explorer create/delete/context
  menus, project-switch
  workflows, remaining document editing semantics (Assembly-compatible
  undo grouping/savepoint rules, settings UI/live reload, language-specific
  indentation, lexically aware bracket pairing and matching, exact line
  operation and selection semantics, etc.),
  syntax/themes, Vim, images, terminal, Git, agents/AI, last-project and
  recent-project restore, per-project settings, control and
  headless UI protocol, installer/update/release integration, platform
  adapters, or production build cutover. Find navigation wraps and supports
  case-insensitive Unicode lowercase matching; single and replace-all actions,
  go-to-line, Save As, close-all, next/previous tab shortcuts, and basic fuzzy
  Go to File and file-tab reopening are present. Full original search and
  command-palette semantics remain unverified.
- Windows executable smoke: `build\rust-target-msvc-1.99\x86_64-pc-windows-msvc\release\rhun.exe --version`
  printed `rhun 0.17.10`; `--help` printed the usage and options; a live native
  window opened a temporary text file, accepted text input, saved it with
  Ctrl+S, and closed normally. A folder launch displayed its directory and
  file entries in the new explorer. A dirty-file close produced the
  save/discard/cancel UI in an earlier build; the current modal implementation
  is not yet reverified. `Ctrl+Shift+F` opened the project-search panel, ran a
  search, and showed a clickable `sample.rs:1` result on Windows. These are
  interactive visual smokes only; close-prompt actions and explorer navigation/
  open actions are not automated GUI regressions or parity tests.
- AI/agent harness: no Rust provider execution, settings, Ollama setup, Git
  commit-draft integration, or external agent-session observer is wired into
  the GUI yet. The existing Assembly harness remains the reference. Rhun must
  remain a user-directed harness, not an autonomous coding agent.
- Rust verification after case-insensitive find/replace, tab shortcuts, Save As,
  close-all, fuzzy file search, reopening file tabs, lazy explorer expansion
  and refresh, Open Folder path behavior, undo/redo, Enter/Tab indentation,
  Ctrl+[ outdent, Ctrl+] line indent, paired-character insertion, line
  duplicate/delete/move, Ctrl+/ comment-toggle, Ctrl+Enter/Ctrl+Shift+Enter,
  Ctrl+L selection, and configured save normalization, plus startup loading of
  `tab_width`, `insert_spaces`, `auto_pairs`, `trim_trailing_whitespace`, and
  `final_newline`, Windows APPDATA lookup, and config reload parsing:
  - `cargo fmt --manifest-path rust\Cargo.toml -- --check`
  - `cargo test --locked --manifest-path rust\Cargo.toml --target x86_64-pc-windows-msvc` (93 tests)
  - `cargo clippy --locked --manifest-path rust\Cargo.toml --target x86_64-pc-windows-msvc --all-targets -- -D warnings`
  - `cargo build --release --locked --manifest-path rust\Cargo.toml --target x86_64-pc-windows-msvc --bin rhun`
  These checks used `CARGO_TARGET_DIR=build\rust-target-msvc-1.99`, Rust 1.99
  MSVC `cargo`/`rustc`/`rustdoc`, Visual Studio's x64 developer environment,
  and a fresh target directory. No clean-clone or production build has been
  verified.
- Only Windows has been exercised for the Rust executable. Linux, macOS,
  cross-target packaging, accessible operation, keyboard layouts, and release
  installation/update are unverified.
- Build/release cutover and Assembly deletion: not started.
- Product feature parity and all non-Windows Rust targets: unverified.
- Migration phase status: phase 1 audit/baseline is documented; phase 2 is a
  partial Rust startup/editor prototype; phase 3 includes basic document
  open/save, bounded undo/redo, initial indentation, project listing/search,
  and per-project path/active-tab session primitives. Phase 6 has only that
  initial session slice. Phases 4-7 have not passed their acceptance gates.
  The requested complete migration is therefore not complete.
- These Rust checks used the installed MSVC Rust toolchain, Visual Studio 2022
  x64 developer environment, the Windows SDK, and LLVM `lld-link.exe`. The
  default `cargo` on this machine selects a GNU host; linking that Windows GNU
  target failed because MinGW libraries were unavailable.
- Remaining Assembly build dependencies: GNU binutils on Linux; Python
  translation and Apple tooling on macOS; Python and LLVM on Windows.
