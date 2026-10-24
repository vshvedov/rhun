# rhun guide

rhun draws everything itself: it rasterizes TrueType fonts, icons and widgets into a pixel buffer and hands that buffer to the display server. On Linux it speaks the Wayland and X11 wire protocols directly, without libc, toolkits or libwayland. On macOS the same code runs natively on Apple silicon in an AppKit window. On Windows it runs as native x64 assembly in a Win32 window. Fonts, themes and grammars are built in on all three platforms.

## Features

- Tabs, file explorer with file type icons, command palette, fuzzy file finder, find and replace, find in files, go to line
- Project menu in the title bar: open a folder or a file from anywhere on disk, or a recent folder, in this window or a new one
- Image preview: PNG, JPEG, GIF, BMP, ICO, QOI, PNM and TGA open in a tab, with zoom and pan
- Syntax highlighting for about 125 languages, defined in plain text grammar files
- 40 color themes, dark and light, with a match for every Omarchy theme; add your own. A dark and a light theme switch with the system's dark mode on macOS, Windows and Linux, as in VS Code
- Settings page and a readable config file, both applied while running
- Agents panel: Claude Code, Codex, Grok Build and OpenCode sessions of the project and its Git worktrees, with theme-colored provider badges and icons, updated live as the agent works. Worktree sessions show a branch icon and the worktree name in a badge beside the provider. Each row names the model its session last used, and in a conversation a reply's label names its model where it changed (Grok Build's row shows the session's current model). The list starts with the 50 most recently active sessions across all providers and related worktrees. Load more adds 50. Discovery runs in the background and reuses a saved metadata index; routine refreshes are silent, and pause while the panel is hidden.
  Grok Build sessions come from `~/.grok/sessions` (`$GROK_HOME/sessions` when set) with the titles Grok gives them; one shows once it has a prompt, and a subagent's session stays inside its parent's. The clones Grok makes with `grok --worktree` are not Git worktrees of the project, so their sessions are not listed. Settings has a switch for each provider under Agents, all on by default (`[agents]` `claude`, `codex`, `grok` and `opencode` in the config file). A config from before the switches keeps its `sources` selection for the others and gets OpenCode on.
  Git worktree registrations supply the checkout roots. Rhun remembers verified worktree paths in repository-specific state, so their agent history stays visible after the checkouts are deleted or Git prunes their registrations. Nested Claude worktree history can also be recovered from its exact recorded path without prior Rhun state. If another repository takes over a remembered checkout path, Rhun keeps previously verified sessions and excludes new sessions from that repository. When Git metadata is stored outside the main checkout and contains no reference to its path, open the main checkout to include its sessions.
- Terminal panel: shells with 24-bit color, mouse, scrollback and full-screen programs; Cmd+click (Ctrl+click on Linux and Windows) opens links in the browser and files in a tab
- Git: changed lines in the gutter, file status in tabs and the explorer, diffs, a history of all branches drawn as a graph, and source control as in VS Code: stage, commit, pull, push
- Extensions: native programs in Rust, Go, C or C++ that add commands, edits, marks, hover, settings, completion lists, signature help, go to definition, references, symbols, code actions, rename, format and views (tabs they draw charts and pictures in), installed from GitHub and held to the permissions they declare; first-party ones bring language servers, formatters, `.editorconfig`, snippets and tasks (see [Extensions](#extensions))
- Undo and redo, auto-indent, bracket pairs, comment toggling, moving and duplicating lines, soft word wrap; without it, lines wider than the editor get a horizontal scrollbar along its bottom
- Vim mode, off by default: normal, insert and visual modes, operators, text objects, counts, `.`, search and `:` commands
- Characters missing from the built-in fonts are drawn with the system's fonts
- Every XKB layout, dead keys and the Compose key (the system's Compose rules, `~/.XCompose` or `$XCOMPOSEFILE`)
- Files changed on disk are reloaded, open files are restored per project
- Wayland with fractional scaling; X11 as a fallback
- macOS on Apple silicon: Retina displays, input methods and dead keys, full screen, signed with a Developer ID
- Windows x64: native window, Unicode paths and clipboard, per-monitor scaling, and a ConPTY terminal
- Remote hosts: a window whose project, terminals, git and extensions are on a Linux machine reached by SSH, in a Docker or Podman container, or in WSL
- Installs from GitHub releases; updates itself on Windows, Linux and macOS

Open files follow edits made by agents and other tools. Writes arriving within 100 ms are grouped
into one reload. A file opened through a symlink follows the file it leads to, in whatever folder,
and the link pointed elsewhere. When a file's folder is removed or moved away, the file keeps its
text, and it follows the file again once a folder is back at that path. In the active editor, the changed region briefly fades back to its normal background;
a thin highlight at the top also signals changes outside the visible lines.
**Animate changed text** in Settings > Editor is on by default. Turn it off to hide both highlights;
files still reload. The config key is `animate_disk_changes = true` under `[editor]`.

Opening files from a file manager or with `rhun file.rb` starts a quick edit: the window shows just
those files as tabs, without the explorer or the agents panel, whatever Settings say; that is never
saved to Settings. Ctrl+B and Ctrl+Shift+A bring a panel back, and opening a folder in the window
shows both again. The first file's folder becomes the project: the explorer shows it, and new
files and terminals start there. That folder is not remembered as the last project, and its saved session is
neither restored nor overwritten; open the folder itself (Open Folder) to bring its session back and
make it the project you return to. A window without a project, such as `rhun --empty`, takes up the
folder of the first file opened in it the same way. `rhun --wait file` (for programs that wait for
an editor) opens just the file. The window comes to the foreground. If rhun is already running on
macOS, Finder opens files as tabs in that window and brings it forward, keeping unsaved edits.
Opening a folder still restores that folder's session; starting without a path can restore the last
project.
Use `rhun --empty` to start with an empty window. Updating and restarting preserves standalone file tabs,
including image tabs, and keeps an empty window empty.

Links of the form `rhun://file/PATH`, as VS Code's `vscode://file/`, open in rhun from a browser, a
chat or any other program: `rhun://file/Users/me/app/src/main.rs:42:7` opens the file at line 42,
column 7, in the middle of the view (`:42` alone works too), and a link to a folder opens it as the
project. The path is absolute and percent-encoded where a URL needs it (`%20` for a space); on
Windows a drive is written `rhun://file/C:/work/app/main.c`, and a network path (`\\server\share`)
is refused, so that a page cannot make Windows contact a server it names. A link starts a window as opening the
file would; on macOS, a running rhun opens it as a tab, as it does for Finder. `rhun 'rhun://file/...'`
works from a terminal too. macOS knows the scheme from the app itself; the installers register it on
Linux and Windows (`--no-url-scheme` and `-NoUrlScheme` leave it out, and updates keep that choice).

A repository's own settings can name programs for git to run, and git status runs some of them as
soon as a folder is opened (a clean filter, in a repository unpacked from an archive). So a folder that
a link opens, or the folder of a file it opens, starts with git paused: no status, gutter, history or
diffs, and a bar above the editor says so. **Trust folder** in the bar, or **Trust Folder for Git** in
the command palette, turns git on there and remembers the folder for later links (in
`$XDG_STATE_HOME/rhun/trusted-folders`, one folder a line; remove a line to stop trusting it). Until
then the folder is not reopened by a launch without arguments, kept among the recent folders, or
restarted into after an update as anything but a link. Folders you open yourself, from the command
line, a file manager or Open Folder, work as always, and a link to a file inside the project already
open in the window changes nothing.
If you have unsaved edits, rhun keeps them and shows an inline warning. Use **Revert File** from the
command palette to load the disk version, or save to keep your version. Undoing back to the saved
state loads the disk version too.
Saving a read-only file asks first: **Overwrite** replaces it and it stays read-only, **Cancel** leaves
it as it is, and Save As writes a copy elsewhere. Save As onto a read-only file and Save in the
question about unsaved files when closing or quitting ask the same; Vim's `:wq` closes the file after
Overwrite, and `:wa` leaves read-only files unsaved. In a folder that takes no new file, a save fails
as any other.

## OpenCode sessions

Install the [OpenCode CLI](https://opencode.ai/docs/) and open a terminal in rhun's project.
Run `opencode` there, or `opencode -m provider/model` to pick a model directly. Use `/connect`
for provider sign-in and `/models` to select a model. Local and open weight models use
[OpenCode's provider configuration](https://opencode.ai/docs/providers/), including Ollama,
LM Studio and llama.cpp. Rhun uses OpenCode's saved settings and does not need provider keys.
To resume a session, run `opencode -c` for the last one or `opencode -s SESSION_ID` for a specific one.

The agents panel lists the project's top-level OpenCode sessions and related Git worktrees,
with OpenCode's titles and a provider badge. Click a row to read its prompts, replies, tool calls
and results. Streaming edits replace the stored conversation snapshot; routine background
refreshes pick them up, including a conversation that remains open after leaving the first page.
After `/undo` the undone messages are left out until `/redo`, as in OpenCode.
Archived sessions and subagent sessions are omitted. Use **Refresh** for an immediate scan.
The panel reads history, as it does for the other agents; interact with OpenCode in the terminal.

OpenCode discovery works with OpenCode 1 (verified with 1.19.0) and OpenCode 2 (verified with
2.0.28). It runs local SELECT queries in the background, without starting a server or making
model requests: with `opencode db` on OpenCode 1, and on OpenCode 2, which has no `db` command,
with the Bun runtime the `opencode` binary is built on, which reads OpenCode 2's session tables
without writing to them while OpenCode is open. Discovery follows the database path the CLI
reports (`opencode db path`, or `opencode debug paths` on OpenCode 2), including `XDG_DATA_HOME`
and `OPENCODE_DB`, and asks again after the CLI changes, as an update does, or a query fails.
The CLI runs in Rhun's state folder, so a project's `bunfig.toml` or `.env` is never loaded.
The queries run only after OpenCode has written to its database, and at least every five
minutes; an unchanged database starts no CLI. Discovery waits
until OpenCode has created its data folder, so opening Rhun does not initialize an unused
OpenCode profile. Only visible
conversations and the open conversation are copied into Rhun's local state folder. Unchanged
copies are reused, and the copy of a session OpenCode deletes or archives is removed. A copy
holds what the panel shows, prompts, replies, tool calls and the commands you ran in OpenCode;
a part over 70 KB keeps the first 16,384 characters of its text and 8,192 of a tool's output.
A conversation whose copy would pass about 24 MB is listed without its transcript.
On Linux and macOS the transcript cache folder is accessible only to its owner.
The CLI must be on Rhun's PATH; the usual `~/.opencode/bin`, `~/.local/bin`, Homebrew and
`/usr/local/bin` locations are also checked on Linux and macOS. Windows requires the native
`opencode.exe` on PATH. Once OpenCode has a data folder, a CLI missing from PATH shows setup
guidance in an empty panel;
a failed query shows an OpenCode warning while the other sources still refresh. Check
`opencode --version` and `opencode debug paths` (`opencode db path` on OpenCode 1) in the
terminal, update OpenCode if needed, then refresh the panel.

To hide OpenCode sessions, turn off **OpenCode** under Agents in Settings, or set:

```ini
[agents]
opencode = false
```

## Install and update

On Linux and macOS:

```sh
curl -fsSL https://github.com/vshvedov/rhun/releases/latest/download/install.sh | sh
wget -qO- https://github.com/vshvedov/rhun/releases/latest/download/install.sh | sh   # without curl
```

The installer needs no root. It checks the download against the release's SHA-256 checksums, and on macOS also that the app is signed by rhun's developer.

- Linux: `~/.local/bin/rhun`, the desktop entry in `~/.local/share/applications` (it starts rhun by its full path) and the icons in `~/.local/share/icons/hicolor`; the desktop's menu and icon caches are refreshed.
- macOS: `rhun.app` in `/Applications` (`~/Applications` when that is not writable), and a `rhun` command in `~/.local/bin`.
- So that `rhun` starts from any terminal, every shell you use gets that `bin` folder on its PATH, in a block marked `# rhun`: your login shell, `$SHELL`, and each shell with a configuration in your home folder (zsh `.zshrc`, bash `.bashrc` and `.bash_profile`, sh, dash and ksh `.profile`, fish `conf.d/rhun.fish`, nushell `env.nu`, tcsh `.tcshrc`). The lines check PATH first, so nothing is added twice.

Options go after `sh -s --`, as in `curl -fsSL .../install.sh | sh -s -- --version 0.14.0`:

| Option | |
| --- | --- |
| `--version X` | install X instead of the latest release |
| `--prefix DIR` | Linux: install under DIR instead of `~/.local` |
| `--app-dir DIR` | macOS: put rhun.app in DIR |
| `--no-modify-path` | leave shell startup files alone |
| `--no-url-scheme` | Linux: do not open `rhun://file/` links in rhun |
| `--configure-files` | configure an existing installation without downloading or replacing it |
| `--uninstall` | remove rhun, the PATH line and the editor lines; your settings in `~/.config/rhun` stay |

Installation prints a command you can run manually to make rhun your default editor. It does not
ask about or change your defaults. Supported images, folders and HTML documents appear in Open With;
the manual default-editor command leaves browser, image and folder associations alone.
On Linux, changing defaults needs `xdg-mime` from xdg-utils and a desktop-visible installation
prefix. On macOS, associations are requested through Launch Services; if a request fails, use
Finder's Get Info > Open with > rhun > Change All for that type.

The default-editor command also makes rhun the editor that programs such as git ask for: every shell
you use gets `VISUAL` and `EDITOR` set to `rhun --wait` (by its full path), in a block marked
`# rhun editor` (fish: `conf.d/rhun-editor.fish`). Only where a window can open: on Linux when there
is a display (`DISPLAY` or `WAYLAND_DISPLAY`), on macOS outside SSH sessions; elsewhere your shell
keeps the editor it had. git's own `core.editor` and `GIT_EDITOR` still come first, and the command
says so when one is set. With `--no-modify-path` it only prints the value to set.

Updates refresh file handler registration without asking about or changing defaults. The separate
`--configure-files --make-default` command enables defaults without reinstalling:

```sh
curl -fsSL https://github.com/vshvedov/rhun/releases/latest/download/install.sh | sh -s -- --configure-files --make-default
```

Use `--prefix` or `--app-dir` too if rhun is installed somewhere else. This configures the metadata
already installed, so update rhun first to get the expanded file type list.

rhun looks for a new version a few seconds after it starts and once a day while it runs. The check is one HTTPS request to github.com for a small text file, made with curl (or wget) in the background. When there is a newer version, the status bar shows **Update to X**: clicking it installs the update in the background, and **Restart to update** then restarts rhun into it, asking about unsaved files first and reopening the project. Check for Updates, Install Update and Restart to Update are in the command palette too. On Windows, PowerShell downloads and verifies the release while rhun runs, and stages it in a `.rhun-update-` folder beside the installation; it is installed after rhun exits for the restart. Closing rhun without restarting deletes the staged download, and the next update clears what an interrupted one left behind. Both ZIP and terminal installations can update in place. The installation folder and the folder that contains it must be writable, and other instances using that installation must be closed. Unrelated files in a portable folder are kept. Versions up to 0.16.3 cannot update themselves on Windows: install the next version once with the installer or the ZIP.

**Check for updates** in Settings (`check = false` under `[updates]`) turns the automatic check off; **Check now** below it still works. A rhun built from source checks only when asked and never replaces itself.

## Build

Run the commands below from the repository root.

Linux on x86-64 needs GNU as and ld (binutils). macOS on Apple silicon needs the Xcode command line tools (`xcode-select --install`).

```sh
./build.sh           # build/rhun with debug symbols (and build/rhun.app on macOS)
./build.sh release   # stripped
tests/run.sh         # unit tests and scripted UI tests
tools/install.sh     # release build into ~/.local, with the desktop entry and icon;
                     # on macOS rhun.app into /Applications and the rhun command into ~/.local/bin
```

To test agents against a project's local Claude Code and Codex history after building:

```sh
python3 tests/agents-real.py --project /path/to/project --output /tmp/agents-audit
```

Use a new output directory. The audit compares discovery with an independent inventory, checks every existing Git checkout registered to the repository and metadata-verified historical nested worktrees, and tests pagination and resumed sessions using temporary copies. It reads the original sessions and keeps test state separate. `--copies` controls the number of copies per session (default 8); choose enough to produce more than 100 sessions. The output includes a report and native UI screenshots. On macOS it also measures agents-panel polling, indexing, and rendering.

### macOS

rhun is written in x86-64 assembly, and the sources stay the one description of the editor. On macOS `tools/arm64.py` translates them to AArch64 at build time, instruction by instruction: x86 registers live in fixed AArch64 registers, the x86 stack keeps its layout, and flags are computed only where they are read. `src/mac/` holds what is native to the Mac: the process entry, the Linux system calls rhun makes, carried out on libSystem, file watching on FSEvents, and the AppKit window, which shows each frame through an IOSurface. The tests pass on both systems. `tests/compare-linux.sh` checks the translation itself: it runs random editing sessions (`tests/fuzz.py`) in the Linux binary under Docker and in a translated one built from the same sources for Linux, and compares states, documents and screenshots, which must be identical.

A release for distribution outside the App Store is signed with a Developer ID and the hardened runtime, notarized by Apple and packed in a disk image:

```sh
xcrun notarytool store-credentials rhun-notary --apple-id YOUR_APPLE_ID --team-id TEAM_ID   # once
tools/package-mac.sh   # build/rhun-VERSION-macos-arm64.zip and .dmg
```

`RHUN_SIGN_ID` picks another signing identity. `RHUN_NOTARIZE=0` signs without notarizing for local use and makes no disk image. Distribution builds (`RHUN_DIST=1`) require notarization: Developer ID signing alone does not satisfy Gatekeeper. `tools/verify-mac-release.sh ZIP DMG` checks the signatures, stapled tickets, versions and Gatekeeper acceptance of both downloads, including a quarantined app extracted from the ZIP. `tools/mac-icon.py` draws `assets/icons/rhun.icns` from the Linux icon, `tools/png-icons.py` the PNG icons for Linux.

### Windows

The Windows build targets Windows 10 version 1809 or later and Windows 11, on x64. Native ARM64 and Windows code signing are not included in 0.16.0. Windows may display an unknown-publisher warning for the unsigned download.

Download `rhun-VERSION-windows-x86_64.zip` from [Releases](https://github.com/vshvedov/rhun/releases/latest), extract it, and open `rhun.exe`. Keep `rhun.com` beside it for terminal use. For a Start menu shortcut and a terminal command, paste this into PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = 'Tls12'; & ([scriptblock]::Create((New-Object Net.WebClient).DownloadString('https://github.com/vshvedov/rhun/releases/latest/download/install.ps1')))"
```

The installer verifies SHA-256, installs under `%LOCALAPPDATA%\Programs\rhun`, adds a Start menu shortcut and updates your user PATH. Open a new terminal after installation. Options are `-Version X`, `-InstallDir DIR`, `-NoModifyPath`, `-NoShortcut`, `-NoUrlScheme` (no `rhun://file/` links), and `-Uninstall`. It refuses to replace a running editor or a directory containing unrelated files. Use the status bar to download an update and restart into it, or close rhun and rerun the installer. Automatic checks are enabled for release builds, with installation and restart initiated by you. Uninstalling keeps settings and sessions.

The script is also included in the ZIP. To install from a downloaded script, run `powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1`. No administrator access or package manager is needed.

Installation registers text, source, configuration and supported image extensions in Open With and
Default Apps for the current user. It prints a command you can run manually to open Windows Settings
and choose defaults. Installation never asks about defaults or opens that page. That command also
sets your user `VISUAL` and `EDITOR` to `rhun.com --wait` (by its full path), so git opens commit
messages in rhun; with `-NoModifyPath` it only prints the value. Uninstalling removes them while they
still name rhun.
`-NoFileAssociations` skips registration and remembers that choice across updates. Images remain an
optional separate choice in Windows Settings.

Existing users can run the installed `install.ps1` with `-ConfigureFiles -MakeDefault`, or pass those
options to the downloaded installer. Add `-InstallDir DIR` for a custom or portable installation.
This needs no download, binary replacement or editor restart. The first update from an older Windows
version may use the old embedded installer, so run this step once after upgrading to register the new
handlers. Later updates refresh registration for installed copies without changing defaults or
opening Settings. Portable copies stay unregistered unless you explicitly configure them.

Use `rhun` or `rhun.com` from a terminal. Normal launches return the prompt immediately. Use `rhun --wait` when another program needs to wait for the editor. `rhun.com --version`, `--headless`, and `--script` preserve console output. The Unix `--control` socket is not available on Windows; use a script file instead. `rhun new-extension` and `rhun submit-extension` ask their questions as plain lines there (a number or the first letter for a choice) and run their steps in PowerShell with `curl.exe` and `tar.exe` (and `gh.exe` when it is installed).

Settings, themes and grammars live under `%APPDATA%\rhun`; saved sessions live under `%LOCALAPPDATA%\rhun`. `XDG_CONFIG_HOME` and `XDG_STATE_HOME` override those parent directories. `HOME` defaults to `%USERPROFILE%`. Session filenames encode drive letters, separators and Windows filename restrictions. A project path whose encoded session filename exceeds 240 bytes opens normally but shows a warning and does not persist a session.

The terminal starts `powershell.exe` by default. A configured shell must be a native executable, such as `pwsh.exe` or Git Bash. Install Git for Windows and make `git.exe` available on PATH for Git features. The update check uses `curl.exe`, included with supported Windows versions. Input methods use Windows text input; Ctrl and Alt shortcuts use the current keyboard layout, and AltGr remains available for typing.

Build on Windows, macOS or Linux with Python 3 and LLVM (`llvm-mc`, `llvm-dlltool`, `llvm-rc`, and `lld-link`). On Windows, use the complete `clang+llvm-*-x86_64-pc-windows-msvc` archive from [LLVM releases](https://github.com/llvm/llvm-project/releases), since the normal installer omits `llvm-mc`. `tools/setup-windows-llvm.ps1` downloads and verifies a pinned archive into `build/llvm`. Set `LLVM_BIN` if the tools are not on PATH. No C compiler, Windows SDK or C runtime is needed; the editor and its Windows adapters are assembly.

```sh
python3 tools/build-windows.py test
python3 tools/package-windows.py
```

Outputs are in `build/windows`, separate from Mac and Linux builds. On Windows use `python` in place of `python3`, then run `python tests/windows.py` and `python tests/windows-install.py`. The Windows workflow runs these checks on Windows Server 2022, including file sharing, symlinks, ConPTY, native window input, installer failures and staged updates. This CI target does not validate the oldest supported Windows client. For development on Linux, `tests/windows.py --wine /path/to/wine64` runs the compatible subset; it explicitly skips the native Windows checks.

`src/win/` maps the core's file and process operations to Unicode Windows APIs, presents the shared renderer through a DIB, and integrates directory notifications and ConPTY with the event loop. The PE files reserve and commit a 32 MiB stack because the shared assembly uses large frames without Windows stack probes.

### Releases

`VERSION` holds the version. `tools/release.sh 0.16.0` writes it, commits, tags `v0.16.0` and pushes; the tag starts `.github/workflows/release.yml`, which tests and builds Linux, macOS and Windows, signs the Mac app, and publishes the release with the archives, `SHA256SUMS`, `VERSION`, `install.sh` and `install.ps1`. The release stays a draft until everything is uploaded, so rhun and the installer never see a version without its files. A version with a dash (`0.16.0-rc1`) is published as a prerelease, which they do not take for the latest.

The workflow needs five repository secrets: `MACOS_CERT_P12` and `MACOS_CERT_PASSWORD` (the Developer ID Application certificate with its key, exported as .p12, base64), and `APPLE_API_KEY_P8`, `APPLE_API_KEY_ID` and `APPLE_API_ISSUER_ID` (an App Store Connect API key for notarization, the .p8 in base64). Every Mac release is notarized by Apple and includes a ZIP and disk image with stapled tickets. The packaged downloads must pass signature, ticket and Gatekeeper checks before upload. Missing credentials, rejected notarization or failed verification stop publication.

### Website

`site/` is the website, published on GitHub Pages by `.github/workflows/pages.yml` on every push to main that changes it (Settings → Pages → Source: GitHub Actions). `site/build.sh OUT` builds it: the page with the latest release's version filled in, the brand font, icon and social card from `assets/`, and this guide as `guide.md` and `llms-full.txt`. `site/shots/take.sh` retakes the screenshots on Linux: it builds rhun in a Debian container and runs the scripts in `site/shots/scripts/` headless, on a clone of main and the demo project in `site/shots/demo/`, then writes `site/img/*.webp` (it needs Docker and `cwebp`).

`tests/update.sh` runs rhun's updater against a fake release folder, and `tests/install.sh` the installer; `RHUN_RELEASES_URL` points both at another place for the releases.

## Run

```sh
rhun [folder] [files...]
```

Without files the previous session of the selected project is reopened. The project menu in the title bar opens another folder (see [Folders and files](#folders-and-files)).

**Reopen last project** in Settings > Files is on by default. When launching from a desktop shortcut, the Dock, or without path arguments, rhun reopens the project you closed with. The config key is `restore_project = true` under `[files]`. Explicit file or folder arguments take precedence. If this setting is off, no project is saved yet, or the saved folder no longer exists, rhun uses the current directory (usually your home folder when launched from the desktop). This preference is independent of **Restore open files**.

Hovering a title bar or explorer button for half a second shows its name and, for commands, the
current shortcut in your platform's notation. Once one is showing, the next button's appears at once.
**Tooltips** in Settings > Appearance turns them off (`tooltips = false` under `[ui]`).

Drag the line between the explorer or the agents panel and the editor to resize the panel; a
double-click on it puts the panel back at its default width.

Scrollbars stay out of sight until you scroll or point at them. **Auto-hide scrollbars** in
Settings > Appearance keeps a faint one in view instead (`auto_hide_scrollbars = false` under `[ui]`).

**Scroll sensitivity** in Settings > Appearance multiplies how far the wheel and touchpad scroll
(`scroll_sensitivity = 1.0` under `[ui]`, from 0.1 to 10). While Alt is held, **Fast scroll
sensitivity** applies instead (`fast_scroll_sensitivity = 4.0`).

Shift turns the wheel sideways in the editor and in images, on Linux and Windows as macOS does by
itself. The terminal keeps Shift's wheel for its scrollback.

Settings includes links to [rhun.app](https://rhun.app), [hi@rhun.app](mailto:hi@rhun.app), and [GitHub issues](https://github.com/vshvedov/rhun/issues) for feedback and bug reports in a single row. The email link follows the website and opens the default email app. All three are also available from the command palette.

Started from a terminal, rhun goes on by itself: the prompt comes back at once, and closing the terminal leaves rhun open. `rhun --wait` stays until rhun is closed, which is what programs that wait for an editor need, such as git: `export EDITOR="rhun --wait"`, which the installer's default-editor command sets for you.

rhun uses Wayland when it can and falls back to X11 when there is no Wayland compositor. `RHUN_BACKEND=x11` or `RHUN_BACKEND=wayland` picks one.

The mouse pointer is the desktop's: the compositor draws it when it supports the cursor-shape protocol; otherwise rhun loads your Xcursor theme (`XCURSOR_THEME`, `XCURSOR_SIZE`, `~/.icons/default`, `/usr/share/icons/default`).

On Wayland rhun draws its own title bar with window buttons, except on tiling compositors (Hyprland, Sway, niri, river, dwl, Qtile), where windows stay bare. `decorations = auto | client | server` under `[ui]` overrides this; `client` is rhun's title bar, `server` is the compositor's.

On macOS the title bar is rhun's too, with the window buttons in it. Command works as Ctrl (and so does Control), Option as Alt; Command with the arrows goes to the line or document ends and Option with the arrows and Backspace works by words, as elsewhere on the Mac. Option still types its characters where it has no binding, and input methods and dead keys work as in any Mac app. On a layout that is not Latin, shortcuts use the key's letter. Started from Finder or the Dock, rhun opens your home folder; files and folders can be opened with it from Finder. In the terminal Command copies, pastes and runs rhun's shortcuts while Control types control characters; Control+\` toggles the terminal, as Command+\` belongs to the system. The shell starts as a login shell, as in Terminal.

| Key | Action |
| --- | --- |
| Ctrl+P | Go to file |
| Ctrl+O | Open file |
| Ctrl+Shift+O | Open folder |
| Ctrl+Shift+P, F1 | Command palette |
| Ctrl+Shift+N | New window |
| Ctrl+, | Settings |
| Ctrl+K Ctrl+T | Color theme |
| Ctrl+B | Toggle explorer |
| Ctrl+Shift+A | Toggle agents panel |
| Ctrl+\` | Toggle terminal |
| Ctrl+Shift+\` | New terminal |
| Ctrl+Shift+G | Toggle git history |
| Ctrl+F, Ctrl+H | Find, replace |
| Ctrl+Shift+F | Find in files |
| Ctrl+G | Go to line |
| Ctrl+D | Select word, then next match |
| Ctrl+/ | Toggle comment |
| Alt+Z | Toggle word wrap |
| Alt+Up, Alt+Down | Move lines |
| Ctrl+Shift+D, Ctrl+Shift+K | Duplicate, delete line |
| Ctrl+Tab, Ctrl+W | Next tab, close tab |
| Ctrl+Shift+W | Close all tabs |
| Ctrl+Shift+T | Reopen closed tab |

The **+** after the last tab opens an untitled file at the end of the tabs, and so does a double click on the empty space after them; New File (Ctrl+N) opens one next to the current tab. With more tabs than fit, the + stays at the right end and the wheel scrolls the tabs.

Drag a tab along the strip to move it; the other tabs make room as it goes, and holding it past either end scrolls the strip.

**Pin Tab** (in the tab's right-click menu and the command palette) keeps a tab at the left, before the others, with a pin in place of its close button; clicking the pin unpins it. Pinned tabs stay open: Close All Tabs leaves them, and Ctrl+W, a middle click and vim's `:q` do not close them. The tab's menu still closes one. Dragging a tab among the pinned tabs pins it, and dragging a pinned tab out among the others unpins it. Files open after the pinned tabs, and the project remembers which tabs are pinned.

**Reopen Closed Tab** (Ctrl+Shift+T) brings back the tabs you closed, the last one first, in their place among the tabs and with the cursor, selection and scroll a file had. Pressing it again goes further back, up to 20 tabs; tabs that are already open and files that are gone are skipped. Opening another folder starts the list over.

Find, replace and find in files ignore case until their Aa is on, in every script: `été` finds `Été`, `яблоко` finds `ЯБЛОКО` and `οδος` finds `ΟΔΟΣ`. Accented letters stay apart from plain ones, so `ete` does not find `été`.

All commands are listed in the command palette. In the terminal, Ctrl+Shift+C and Ctrl+Shift+V copy and paste, Ctrl+Shift+W goes to the program instead of closing the editor's tabs, Shift+PageUp and Shift+PageDown scroll back, Ctrl+Tab and Ctrl+Shift+Tab switch between terminals, and Shift keeps the mouse for selecting when a program uses it. A command run from the palette acts where its shortcut would: Zoom In with the terminal focused zooms the terminal.

Links in the terminal open with Cmd+click on macOS and Ctrl+click on Linux and Windows, as in VS Code; a plain click still selects. Hovering a link underlines it, and its tooltip names the click. An `http://` or `https://` URL opens in the default browser, such as the `http://localhost:5173/` a dev server prints. The path of a file that exists opens in a tab: a name from `ls`, a relative or absolute path, or `~/...`, and `file:LINE` or `file:LINE:COL` from a compiler or `grep -n` opens at that place. Relative paths start in the shell's current folder on Linux and macOS, then in the project folder, where they also start on Windows. The click works in programs that take the mouse too.

Programs that turn on the kitty keyboard protocol, such as the Pi agent and fish 4, tell Shift+Enter, Alt+Enter and Ctrl+Enter apart from Enter, so Shift+Enter can start a new line in an agent's prompt instead of sending it. rhun reports those keys, Escape, and Ctrl or Alt with a character as `CSI` codes while a program asks for them (the protocol's first level); other programs get the usual bytes.

Zoom In, Zoom Out and Reset Zoom change the focused editor or terminal independently. On macOS use Command+Plus, Command+Minus and Command+0; on Linux and Windows use Ctrl+Plus, Ctrl+Minus and Ctrl+0. The keypad's plus, minus and 0 work too (its 0 with Num Lock on). Settings > Terminal > Font size controls the terminal separately from Settings > Editor > Font size. The terminal has its own font and line height too: `font` under `[terminal]` names a monospace .ttf file (empty uses the editor's font), and `line_height` is a multiple of the font's own line height, 1.0 by default.

### Folders and files

The explorer shows each file with the icon of its language or type, in the theme's colors: the
grammar the file name gets gives the language's icon, and `assets/icons/files/types.txt` gives the
icons of images, archives, fonts, documents, and names such as `LICENSE` or `package.json`. The
glyphs are from Seti UI (MIT).

The explorer's header has **New File** and **New Folder** buttons. They create in the folder of the
item last selected in the explorer, or in the project folder; the prompt names what it creates and
holds the path, which can include folders that do not exist yet. Right-click a file or folder for its
menu; right-click the empty space below the list for the project folder's: New File, New Folder,
Copy Path and Show in Finder (Show in Explorer, Open in File Manager).

Choose **Delete** from the explorer context menu to remove a file or folder. The confirmation has **Cancel** and **Delete** buttons. Deleting a folder removes its contents, including hidden files; links are removed without deleting their targets. The tabs of deleted files close, except those with unsaved changes. Renaming a file or folder keeps its open tabs on the new path. Both can be undone until rhun quits: `ctrl+z` while the explorer has the focus, or **Undo Last Multi-File Edit**, brings the file or folder back (deleted items wait in `~/.local/state/rhun/edits`).

Right-click a file or directory in the explorer and choose **Show in Finder** (macOS), **Show in Explorer** (Windows), or **Open in File Manager** (Linux). Finder and Explorer select the item in its parent folder. Linux opens the containing folder through `xdg-open`, using your desktop's default file manager. The command palette also has **Show File in System File Manager** for the active file.

Clicking the project name in the title bar opens the project menu: Open Folder…, Open File… and the folders of up to 9 recent sessions, newest first. Opening a folder turns the window to it: rhun remembers the open files, asks about unsaved ones, and brings back the folder's last session. The same happens to a folder opened from Finder or the Dock, or with `:e`. Running terminals keep running; new ones start in the new folder. Shift-click a recent folder to open it in a new window instead; this one keeps its project.

Open Folder and Open File show a browser in the palette. It starts in the project folder, and its field holds a path: the list shows what is in the folder before the last `/`, narrowed by what follows it.

- Enter goes into a folder or opens a file, Tab completes the name, and Backspace past a `/` goes up.
- A path can be typed or pasted, as in `/etc/` or `~/code/`. Hidden entries show once the name typed starts with a dot.
- Open Folder lists only folders, led by **Open** and the folder shown, then **Open … in a new window**, which leaves this window as it is (on macOS the new window has a Dock icon of its own). Ctrl+Enter opens the selected folder without going into it.

A window can hold several folders, a workspace. `rhun app lib` opens both; **Add Folder to
Workspace…** (the project menu, or the palette) adds another, and **Remove Folder from Workspace**
(a folder's menu in the explorer) takes one out. The first folder is the project: the window is named
after the folders (`app + lib`), the explorer shows each folder as a root of its own, quick open and
find in files list every folder's files with the folder's name first (`lib/pkg/p.go`), and a new
terminal starts in the active file's folder. Folders cannot be inside one another, and a window has
16 at most. The folders added to a project come back the next time it is opened. **Save Workspace
As** writes `NAME.rhun-workspace`, which names the folders (and can hold settings for extensions);
opening that file, from the command line or Open File, opens them all. Removing the first folder
makes the next one the project.

Each folder's git repository is followed: the explorer colors every folder's changes, and source
control (the history's work tree row) starts with a line for each repository, with its branch and
number of changes. The repository shown in the history, source control and the status bar is the
active file's folder's; clicking another repository's line shows that one until you switch to
another file. A file in a folder without a repository leaves the one shown as it is.

### Git

In a git repository rhun shows what changed since the last commit. It runs the `git` program in the background, so the editor never waits for it, and follows commits, checkouts and edits made elsewhere, the built-in terminal included.

- The gutter marks added lines green and changed lines amber, and points to deleted lines in red. The marks follow the text as you type, before it is saved.
- File names in tabs and the explorer take the color of their status. The explorer adds a letter: M modified, A added, U untracked, D deleted, R renamed, C conflict; folders take the color of the changes inside them.
- Git: Open Changes (also in the explorer's context menu of a changed file) opens the file's diff against HEAD in a read-only tab, with the old and new line numbers and the file's syntax colors.
- The status bar shows the current branch at its left end (the short commit id when detached), and in a linked work tree (`git worktree add`) the work tree's folder too, as in `main · worktree hotfix`.
- The history (Ctrl+Shift+G, the branch button in the title bar, or the branch in the status bar) shows the latest 3000 commits of all branches as a graph, with branch and tag names. The selected commit's message and changed files are shown on the right, with lines added and deleted; clicking a file opens its diff in that commit.
- The first row of the history is the work tree. Selected, it shows source control on the right, as VS Code does:
  - The branch and its upstream, and the commit message: Enter breaks the line, Ctrl+Enter commits, Esc leaves it. Enter on the work tree row goes to it.
  - **Commit** takes the staged changes; with nothing staged it is **Commit All** and stages every change first. With nothing to commit the button syncs instead: **Sync Changes** pulls, then pushes, and a branch without an upstream gets **Publish Branch**.
  - **Pull**, **Push** and **Fetch**, with the number of commits to pull and to push. Pull merges, unless `pull.rebase`, `pull.ff` or the branch's `rebase` setting say otherwise. Push publishes a branch without an upstream to `origin`, or else the first remote.
  - **Reset All Changes** asks with **Cancel** and **Reset All Changes** buttons. Confirming restores staged and unstaged files on disk to the last commit and permanently deletes untracked files and folders throughout the repository. The cleanup skips ignored files and nested repositories. Before the first commit, it removes staged additions too. Unsaved editor changes are kept, and running agents or terminals can create changes again after the reset.
  - The changes in groups: merge conflicts, staged and not staged. A file shows its buttons when hovered: + stages it, − unstages it, ↶ discards its changes; each group has them for all its files. Discarding asks first, and for a new file it deletes the file. Clicking a file opens its diff.
  - When a pull stops on conflicts, the merge's message fills the message box: resolve the files, stage them and commit. What git reports when something fails is shown under the buttons.
- A right click on a commit in the history copies its id; on a file of a commit or a changed file it offers **Open Changes**, **Open File** and **Copy Path**. Extensions can add items to these menus.
- The command palette has them too: Git: Commit, Commit (Amend), Pull, Push, Sync, Fetch, Stage All Changes, Unstage All Changes, Discard All Changes and Reset All Changes. Discard All Changes only discards unstaged changes; Reset All Changes also clears staged changes. An amend without a message keeps the commit's message.
- git runs without a terminal to ask for passwords: HTTPS remotes need a credential helper, SSH keys an agent.

It stays quick on large repositories: the Linux kernel's history (1.5M commits, 96k files) opens in about a tenth of a second.

Git support is on by default; `enabled = false` under `[git]` in the config, or the Git switch in Settings, turns it off.

#### Commit message AI

In Settings under Git, choose one **Commit message AI** provider: **Off** (the default), **Claude Code**, **Codex**, or **Local (Ollama)**. With a provider enabled, the work tree's commit controls include a sparkle **Generate** button. Click it to draft a message, edit the result, then commit as usual. Click **Cancel** beside the message input to stop. Generation never commits or stages files. If your draft, repository, selected provider, or changes move while it runs, rhun keeps your draft.

Claude Code and Codex use their installed CLI and saved subscription sign-in. Install the relevant CLI and run `claude auth login` or `codex login` in the terminal first. rhun checks the authentication mode and rejects API-key sign-in. It uses `claude -p` or `codex exec`, with tools restricted, in a temporary directory. Recent CLI versions are required. These requests use your subscription allowance and are subject to its limits; they are not unlimited free calls. The diff is sent to the selected provider only when you request generation. There is no automatic fallback to another provider.

For local generation, select **Local (Ollama)** and click **Download** beside **Local model files**. rhun finds existing Ollama installations and reuses local model files. When needed, it downloads a private Ollama runtime and the default `qwen2.5-coder:1.5b` model (about 1 GB). No administrator access or separate harness installation is needed. Setup requires an internet connection, enough free disk space for the runtime and model, and sufficient memory to run the model. The status shows the selected model, runtime bytes received, and model-file download percentages and MiB. Verification is shown separately. Click **Cancel** to stop; retry **Download** to reuse completed model files. Once the model is installed, the same button becomes **Delete**. It asks for confirmation naming the model, then removes it through Ollama and returns to **Download**. This can affect other apps using that model; Ollama and other models remain installed. A different local Ollama model can be entered in **Local model**, then prepared using the same button.

The bundled helper runs an owned Ollama server for each model check, download, deletion, or generation, bound to loopback with remote models blocked. It stops that server afterward and leaves an existing Ollama service alone. Model files remain available for later runs. Runtime downloads come from the official Ollama release, pinned to `v0.13.5` for portable gzip/ZIP archives, and are checked against its SHA-256 manifest. Private runtimes live under `$XDG_DATA_HOME/rhun/ai` (or `~/.local/share/rhun/ai`) on Linux/macOS, and `%LOCALAPPDATA%\rhun\ai` on Windows. The harness is embedded in rhun on all three platforms.

Detection, setup and generation run in background processes. Opening Settings or changing the provider or model refreshes the cached status automatically. **Git: Check AI Provider** in the command palette can also refresh it. Errors and cancellation preserve the current message. Staged changes take priority; with nothing staged, generation includes the tracked and untracked changes that **Commit All** would include. A temporary index leaves the real staging area unchanged. Binary contents are omitted, and the diff sent to the model is bounded, so large changes may need a manual summary. Temporary prompts and responses are removed when the helper exits normally or is cancelled gracefully.

```ini
[git]
commit_ai = off
commit_model = qwen2.5-coder:1.5b
```

An installed extension that writes commit messages is listed after these, by its name. Generate then starts it if needed and sends it the same bounded diff (staged changes, or what **Commit All** would take) and the branch; its answer fills the message box under the same rules, and **Cancel** withdraws the request. The extension needs no access to your files for this: rhun sends the diff only when you click Generate.

`commit_ai` accepts `off`, `claude`, `codex`, `ollama`, or `ext:OWNER/NAME` for an extension. **Git: Generate Commit Message**, **Git: Check AI Provider**, **Git: Download Local Model**, **Git: Delete Local Model**, and **Git: Cancel AI Operation** are also available in the command palette.

CLI references: [Codex noninteractive mode](https://learn.chatgpt.com/docs/non-interactive-mode), [Codex authentication](https://learn.chatgpt.com/docs/auth), [Claude Code CLI](https://code.claude.com/docs/en/cli-reference), and [Ollama](https://docs.ollama.com/quickstart).

### Remote hosts

A remote window works on another machine: its project, files, explorer, Go to File, Find in Files,
terminals, tasks, test runs, debug adapters, git, the agents panel's sessions and extensions are the
host's, while the window, settings, themes, keys, installed extensions and updates stay on this
computer. The host is Linux on x86-64 (a container on Apple silicon must be `linux/amd64`); the
window can be Linux, macOS or Windows.

- Open one from the project menu: **Connect to Host…** lists the `Host` lines of `~/.ssh/config`
  and recent remotes, or takes a typed `user@host`; **Attach to Container…** lists `docker ps` (or
  `podman ps`); on Windows **Connect to WSL…** lists the distributions. Each opens a new window. On
  the command line: `rhun --remote ssh:HOST /path`, `--remote docker:NAME`, `podman:NAME` or
  `wsl:DISTRO` (the path is optional: the host's home folder).
- Connecting runs `ssh HOST sh -s` (or `docker exec -i NAME sh -s`, `wsl.exe -d DISTRO sh -s`) and
  copies rhun's Linux build into `~/.cache/rhun-remote` on the host once; nothing else is installed
  and no port is opened. On macOS and Windows that build is downloaded from the release first and
  checked against its `SHA256SUMS`; `agent_binary = PATH` under `[remote]` names another one (a
  development build). The title bar shows `HOST: folder` and the status bar `SSH: HOST`, whose menu
  has Disconnect, Reconnect, Show Remote Log and the forwarded ports.
- ssh's questions (a password, a passphrase, a new host key) appear in rhun's prompt (OpenSSH 8.4 or
  later). On Windows rhun runs ssh without a prompt for now: use a key or ssh-agent, and accept a new
  host's key in a terminal once.
- When the connection drops, a bar says so and offers **Reconnect**. Documents stay open and
  editable, and a save waits for the connection. Programs keep running on the host meanwhile:
  Reconnect brings back the same terminals and extensions, and files changed there in between are
  compared again. A host nobody reconnects to ends its programs after 3 hours (10 minutes when none
  run); closing the window or **Disconnect** ends them at once. `RHUN_REMOTE_SESSION=0` makes them
  end with the connection instead.
- Extensions run on the host unless their manifest says `where = local`. rhun copies an extension
  there once (its folder, or its release's Linux build when the installed one is for this computer),
  keeps its state folder there, and the host's Linux holds it to its permissions with Landlock; its
  page says when that kernel cannot.
- **Remote: Forward a Port** makes a port of the host's loopback reachable at `localhost` here, with
  the same number when it is free (ports below 1024 at 10000 plus the port); **Stop Forwarding Ports**
  ends them. Pages an extension serves on the host's loopback are forwarded when it opens them.
- `RHUN_SSH` names the ssh program to run, and `RHUN_RELEASES_URL` another place for the release's
  Linux build. **Show Remote Log** opens `remote.log` in the state folder.

### Images

PNG, JPEG (baseline and progressive, EXIF orientation applied), GIF (first frame), BMP, ICO / CUR, QOI, PNM (PBM, PGM, PPM) and TGA open in an image tab; other binary files are not opened. An image is decoded when its tab is first shown and fits the view without being enlarged; transparent parts show a checkerboard. It is decoded again when the file changes on disk.

| Key / mouse | Action |
| --- | --- |
| Ctrl+=, Ctrl+-, `+`, `-` | Zoom in, out (stops at 100% on the way) |
| Ctrl+0, `0` | Fit to the view |
| `1`, double click | 100%; double click again to fit |
| Ctrl+wheel | Zoom at the pointer |
| Wheel (Shift+wheel sideways), drag, arrows | Pan |

The status bar shows the size, the file size, the format and the zoom; clicking the zoom switches between fit and 100%.

### Custom editors

An extension can show a kind of file its own way: a hex editor for binaries, a table for CSV. Such
a file opens in the extension's editor; **Reopen Editor With...** in the palette opens the active
file with another editor or as text, and remembers the choice for files with the same extension
(the config's `[editors]` section). Save, Save As, Undo, Redo, Revert File and the close
question work in the editor's tab as in a text tab. An editor that keeps the file itself (a hex
editor) has its unsaved changes backed up every 30 seconds: if its extension stops, the tab
offers Restore Unsaved Changes, and if rhun stops, the file opens with them the next time.

### Notebooks

A notebook file an extension provides for (the `jupyter` extension reads and writes `.ipynb`)
opens in a notebook tab: its cells one under the other, each with its language's colors and every
editor command, and under a code cell its outputs (text with its colors, errors, images, tables
and other rich documents, pictures). A Markdown cell shows its text rendered until you edit it
(Enter or a double click); a link in it opens its file in a tab, or a web address in the browser. The
toolbar runs all cells, interrupts or restarts the kernel and clears the outputs; the button at
its right picks the kernel. Clicking a cell's `[ ]` column runs it.

| Mode | Key | Action |
| --- | --- | --- |
| edit | Esc | command mode |
| edit | Shift+Enter, Ctrl+Enter, Alt+Enter | run and select the next cell, run, run and insert a cell below |
| edit | Up on the first line, Down on the last | the previous or next cell |
| command | Enter | edit the selected cell |
| command | Up / k, Down / j | select the previous or next cell |
| command | a, b | insert a code cell above, below |
| command | d d, z | delete the cell, undo the last cell operation |
| command | m, y | make the cell Markdown, code |
| command | Alt+Up, Alt+Down | move the cell |
| command | i i, 0 0 | interrupt, restart the kernel (asks) |
| command | o | hide or show the cell's outputs |

Kernels run as you, outside the extension's sandbox: the first time a notebook extension starts
one in a project, rhun shows the command and asks (Allow or Cancel); Forget on the extension's
page takes the permission back. Find (Ctrl+F) searches the cell being edited, and Find Next and Find Previous go on to the next or
previous cell with a match. Ctrl+S saves the notebook through its extension. A long text output shows its first 400 lines
and opens whole in a tab of its own. Every action is in the command palette as Notebook: ....
Notebook: Reopen as Text shows the file itself.

### Multiple cursors

Several selections edit together: typing, Backspace and Delete (by character and by word), Enter, Tab and Shift+Tab, Indent and Outdent, Cut, Copy and Paste act at every one, as one Undo step that also brings the selections back. The newest selection is the primary: the view follows it and the status bar shows its position and how many selections there are.

| Keys | Command |
| --- | --- |
| Ctrl+D | Select the word at the cursor, then add the next match (whole words of the same case after a word; else the exact text) |
| Ctrl+Shift+L | Select All Matches (at most 512, the nearest ones) |
| Ctrl+Alt+Up / Down, Shift+Alt+Up / Down | Add Cursor Above / Below, at the primary's column |
| Ctrl+U | Remove Last Selection |
| Shift+Alt+I | Add Cursors to Line Ends of the selected lines |
| Ctrl+Shift+Alt+arrows | Column Select: a box that grows from the cursor |
| Escape | Back to the primary alone |

On macOS Ctrl is Command and Alt is Option. Move Selection to Next Match (Ctrl+D's old behaviour) is in the command palette without a key.

With the mouse, Alt+click adds a caret (on a caret, removes it), Alt+drag adds a selection, Alt+double-click adds a word, and Shift+Alt+drag selects a box: one selection a line between the two columns, tabs expanded, skipping lines that end left of it. A plain click goes back to one cursor. When the window manager takes Alt+drag, `multi_cursor_modifier = ctrl` under `[editor]` (**Multi-cursor modifier** in Settings) uses Ctrl instead.

Arrows, Home, End, word and page moves move every selection, each keeping its own column on short lines; selections that come to overlap become one. Duplicate Line, Delete Line, Move Line Up/Down, Toggle Comment, Insert Line Below/Above and Select Line act on the lines of every selection. Commands about one place (find next, Go to Line, completion, Go to Definition, rename, code actions) keep the primary alone first, and completion does not open by itself while there are several selections.

In Vim mode, `gb` adds a cursor at the next occurrence of the word under the cursor (of the selection in visual mode); Ctrl+D keeps paging. Motions with counts, `i a I A o O`, visual mode, `x X D C s S dd cc yy`, operators with a motion or text object (`ciw`), `p P` and `.` act at every cursor as one undo step; `u` brings the cursors back. Yanks at several cursors are one copy with a piece each, which `p` puts back paired. Esc in insert mode keeps the cursors, each stepping back a character; Esc in normal mode leaves the primary alone. Searches, `:`, `J`, `r`, `~`, `>` and `<` go back to the primary first.

### Folding

The fold lane right of the line numbers shows a down chevron on each line that starts a foldable
region while the pointer is over the gutter, and a right chevron on folded lines; a click folds or
unfolds. A folded line ends in a ` ⋯ ` pill, which unfolds when clicked. Regions come from
indentation, as in VS Code: a line starts one when the next non-blank line is indented deeper, and
the region ends before the next line indented no deeper, so a closing brace stays visible. An
extension that provides folding ranges for the file's language (a language server's, through the
lsp extension) gives the regions instead, with their own collapsed text in the pill; until it has
answered, and after it stops, indentation decides.

| Keys | Command |
| --- | --- |
| Ctrl+Shift+[ | Fold: the innermost region at the cursor |
| Ctrl+Shift+] | Unfold: the folds on the cursor's line |
| Ctrl+K Ctrl+0 | Fold All, at every depth (unfolding an outer fold shows the inner ones still folded) |
| Ctrl+K Ctrl+J | Unfold All |

Toggle Fold and Fold Level 1 to 3 are in the command palette. In Vim mode `za` toggles, `zc` folds,
`zo` opens, `zM` folds all and `zR` opens all. On macOS Ctrl is Command.

Folded lines are skipped by Up, Down, Page Up, Page Down and `j`/`k`, and the caret never stops
inside a fold: Right at a folded line's end goes to the line after the fold. Anything that puts the
caret inside hidden text opens the fold (Go to Line, find, Go to Definition, undo). Delete Line,
Duplicate Line, Move Line and Copy or Cut without a selection take a folded line with its hidden
lines. An edit inside a fold's hidden lines, or one that joins its first line with the next, removes
the fold. Folds are kept with the session and in reopened tabs. `folding = false` under `[editor]`
(**Folding** in Settings) turns the lane and folding off.

### Inlay hints

An extension that knows the code (a language server, through the lsp extension) can show what is
not written: inferred types after names, parameter names before arguments, the ends of long
blocks. Hints are drawn in a muted pill inside the line but are not part of the text: the cursor
steps over them, and copying, searching and the status bar's column never see them. The pointer
resting on a hint shows its tooltip; a click on a part that has a command runs it, or goes to the
definition it names; a double click writes the hint into the text when it offers that (a type, for
example). `inlay_hints = false` under `[editor]` (**Inlay hints** in Settings) turns them off.

### Inline suggestions

An extension (an AI assistant or a language server) can suggest what comes next as you type: the
suggestion appears after the cursor in a muted color, its further lines below. Tab takes it,
Ctrl+Right takes its next word, Escape or moving the cursor dismisses it, and typing what it shows
keeps the rest. Alt+\ (Trigger Inline Completion) asks for one now. `inline_complete = false`
under `[editor]` (**Inline suggestions** in Settings) stops asking as you type;
`inline_complete_delay` is the pause after typing, in milliseconds.

### Colors

When an extension (a language server) finds colors in the code, a small square in each color sits
before it. A click on the square asks for a new color (`#rrggbb` or `#rrggbbaa`) and the extension
writes it in the code's own notation. `color_swatches = false` under `[editor]` (**Color
swatches** in Settings) turns the squares off.

### Highlights

When the cursor rests on a name, its other places in the file are marked with a soft background,
places that write it a little stronger, when an extension (a language server) knows them;
otherwise rhun marks the same word's other occurrences nearby. The marks go when the cursor moves
away or the text changes. `highlight_occurrences = false` under `[editor]` (**Highlight
occurrences** in Settings) turns off the word marks; a language server's highlights stay.

### Code lens

An extension that knows the code can put a row of small titles above a line: how many references a
function has, a Run or Debug action over a test or a `main`. A click on a title runs it; the
pointer resting on one shows its tip. The rows are not part of the text: the cursor steps over
them, and the text you are looking at does not jump when they appear. `code_lens = false` under
`[editor]` (**Code lens** in Settings) turns them off.

### Semantic highlighting

An extension that knows the code (a language server, through the lsp extension) can color it by
meaning: a name is drawn as the type, function, variable, constant or macro it is, beyond what the
syntax highlighting sees, deprecated names are struck through, and the extension may underline
others (rust-analyzer's mutable variables). The colors are the theme's syntax colors. Until the
extension has answered, and while you type, the syntax colors and the last answer's colors are
shown. `semantic_highlighting = false` under `[editor]` (**Semantic highlighting** in Settings)
turns it off.

### Vim mode

The Vim mode switch in Settings (`vim_mode = true` under `[editor]`) or Toggle Vim Mode in the command palette turns it on. The status bar shows the mode and the keys typed so far; outside insert mode the cursor is a block.

- Normal, insert, visual and visual line mode. Esc or Ctrl+[ goes back to normal mode.
- Motions: `h j k l`, `w b e W B E`, `0 ^ $ _ + -`, `gg G`, `f F t T ; ,`, `%`, `{ }`, `H M L`, `n N * #`, with counts. Ctrl+D and Ctrl+U move half a page; `zz zt zb` scroll.
- Operators `d c y > < gu gU g~` take a motion or a text object: `iw aw iW aW`, quotes (`i" a'` and ``i` ``) and brackets (`i( a) ib i{ aB i[ i<`). Doubled (`dd`, `>>`, `gUU`) they work on lines.
- `x X D C s S Y J r ~ p P u` Ctrl+R `.`, and `i a I A o O` with counts (`3ihi`).
- `/` and `?` search from the command line in the status bar, going to the first match as you type; Enter stays there, Esc goes back, `n` and `N` repeat it. They are motions too (`d/foo`, `v?bar`). The text is found as typed, not as a regular expression, and case matters only when the find bar's Aa is on. `*` and `#` find the word under the cursor as a whole word.
- `:` opens a command line in the status bar: `:w :q :q! :wq :x :wa :qa :qa! :e path :e! :noh`, and `:N` goes to line N.
- Yanks and deletes go to the clipboard. `p` puts text copied in other programs too, as whole lines when it ends with a newline.
- A mouse selection is a visual selection. Keys bound to commands (Ctrl+S, Ctrl+P, ...) keep working, except Ctrl+R, Ctrl+D, Ctrl+U and Ctrl+[ outside insert mode.

Registers, marks, macros, ranges and `:s`, visual block and replace mode are not there.

## Configuration

`~/.config/rhun/config` is written when you change something in Settings; Open Settings File creates it. Edits to the file apply as soon as it is saved.

Settings opens with its search field taking the keys: the page keeps the settings where each word typed starts a word of the title, the description or the config name (`section.key`, or the section's title), ignoring case, such as `terminal font`, `vim_mode` or `ui`. Esc clears the search, a second Esc or Enter leaves the field (the arrows then scroll the page), and Ctrl+F goes back to it.

```ini
[ui]
dark_theme = tokyo-night
light_theme = github-light
scale = 1.25
[editor]
font_size = 15
tab_width = 4
[terminal]
shell = /usr/bin/fish
font_size = 14
[files]
auto_save = after_delay
auto_save_delay = 1000
[git]
enabled = false
[keys]
ctrl+shift+d = duplicate_line
alt+z = none
ctrl+k ctrl+c = toggle_comment when editorFocus
ctrl+alt+g = goto_line
ctrl+alt+p = owner/ext.command some arguments
```

Command names are those of the command palette entries in snake case (see `src/app/keys.s`);
an extension's command is `name.command` or `owner/name.command`. `none` removes every binding of
those keys. A binding is one key or a chord of two (`ctrl+k ctrl+c`): after the first, the status
bar shows `Ctrl+K — waiting for the next key` until the second, Escape, a click or five seconds.
Text after the command is passed to an extension command as its arguments, and `when CLAUSE`
limits the binding to a context (`editorFocus`, `resourceLang == Rust`, `terminalFocus`, ...; the
clause language and its keys are in the extension protocol's "When clauses"). Your bindings win
over extensions', which win over rhun's own. **Keyboard Shortcuts** in the command palette lists
every binding, where it comes from, its clause and what overrides it.

At multiple cursors (see [Multiple cursors](#multiple-cursors)), copied selections stay paired with their destinations. For other multiline text, `multi_cursor_paste = spread` under `[editor]` pastes one line per cursor when the counts match. Set it to `full` to paste all the text at each cursor. The same choice is available as **Paste at multiple cursors** in Settings.

Tab uses each cursor’s own column. Indent and Outdent update each shared line once and preserve selection direction. One Undo restores the whole edit.

Paste waits for clipboard data without changing its destination. If the original document, field, terminal, or selection no longer matches when the data arrives, that Paste is discarded. Repeated Paste requests run in order, using the clipboard contents available when each request starts. Empty clipboard text leaves the destination unchanged.

### Themes

The theme follows the system's dark mode: `dark_theme` shows while the system is in dark mode and `light_theme` while it is in light mode, Rhun Dark and Rhun Light to start with. Pick them in Settings > Appearance, or with the theme picker (Ctrl+K Ctrl+T), which saves the theme for the mode the system is in. Turn off **Follow system dark mode** (`follow_system = false`) to keep one theme, `theme`, whatever the system does; it starts as the theme on screen. **Toggle Light/Dark Theme** in the command palette then switches `theme` between the dark and the light one.

rhun reads the mode as VS Code does and switches as soon as the system does:

- macOS: System Settings > Appearance, Auto included.
- Windows: the app mode in Settings > Personalization > Colors. The title bar is dark with a dark theme.
- Linux: the XDG desktop portal's color scheme over D-Bus: GNOME, KDE Plasma, Cinnamon and COSMIC, and Sway, Hyprland and other window managers with xdg-desktop-portal-gtk (`gsettings set org.gnome.desktop.interface color-scheme prefer-dark`). Without a dark or light answer there the GTK theme decides: `gtk-application-prefer-dark-theme`, or a theme name with "dark" in it, from XSETTINGS (Xfce, MATE, LXDE, xsettingsd), the portal or `~/.config/gtk-3.0/settings.ini` (lxappearance, nwg-look). On X11 the window's `_GTK_THEME_VARIANT` tells the window manager whether the theme is dark.

When the system says nothing, the dark theme shows. A configuration from before 0.17.8 names one `theme`: it becomes the theme for its kind and for the mode the system is in, so the editor looks the same until you pick another.

Choose **Turbo Pascal** in the theme picker for a blue editor with yellow text, white keywords and the DOS terminal palette. To select it in the configuration file, set `dark_theme = turbo-pascal` under `[ui]` (or `theme`, with `follow_system = false`).

A theme is a `name.theme` file in `~/.config/rhun/themes/`. Colors not given are derived from `bg`, `fg` and `accent`, so a theme can be three lines. See `runtime/themes/` for all keys. Extensions bring themes too (an extension with only themes, grammars or icon themes has no program and never runs); `theme`, `dark_theme` and `light_theme` name one by its file name, as a theme of your own.

```ini
name = My Theme
kind = dark
bg = #1e1e2e
fg = #cdd6f4
accent = #f5c2e7
keyword = #cba6f7
string = #a6e3a1
```

Under `[terminal]` a theme can set the 16 terminal colors, `black` to `bright_white`; the ones not given come from the theme's other colors. `git_added`, `git_modified` and `git_deleted` color changes in the gutter, tabs, explorer and diffs.

Extensions' text inside the editor has its own colors: `inlay` and `inlay_bg` for inlay hints, a
fold's pill and other virtual text, `ghost` for inline completion, `codelens` for code lens,
`highlight` and `highlight_write` for the other occurrences of the symbol under the cursor, and
`info` and `hint` for those diagnostics. A theme that leaves them out gets them from its other
colors.

File icons can come from an extension's icon theme: **Select File Icon Theme** in the command
palette previews each one in the explorer and saves the choice as `file_icons` in `[ui]` (`rhun`,
the built-in icons; `none`; or a theme's `OWNER/NAME/THEME`).

The explorer's file icons use ten colors: `icon_red`, `icon_orange`, `icon_yellow`, `icon_green`, `icon_blue`, `icon_purple`, `icon_pink`, `icon_cyan`, `icon_grey` and `icon_white`. Those not given come from the terminal colors (orange and pink as mixes; blue, purple and cyan only when the theme gives them, as the derived ones are syntax colors, and a fixed blue, purple and cyan otherwise), muted text and panel text; a derived color is moved toward the text until it stands out on the panel by at least 3:1.

On Omarchy the theme list starts with Follow Omarchy (`omarchy`): rhun uses the theme Omarchy has set and switches with it. It is the default there, for both modes, until you pick another theme. For an Omarchy theme rhun has no match for, add a rhun theme with the same name; otherwise rhun's own dark or light theme is used.

### Languages

Built-in languages: Ada, Apache, AppleScript, AsciiDoc, Assembly, Astro, AWK, Batch, BibTeX, Blade, C, C#, C++, Cap'n Proto, Clojure, CMake, COBOL, Crontab, Crystal, CSS, CUDA, CUE, D, Dart, Dhall, Diff, Dockerfile, dotenv, EJS, Elixir, Elm, ERB, Erlang, F#, Fish, Fortran, Git attributes, Git Commit, Gleam, GLSL, Go, GraphQL, Graphviz, Groovy, HAML, Handlebars, Haskell, Haxe, HCL, HTML, HTTP, Idris, Ignore, INI, Janet, Java, JavaScript, Jinja, JSON, Jsonnet, Julia, Just, KDL, Kotlin, LaTeX, Lean, Liquid, Lua, Makefile, Markdown, MATLAB, Mermaid, Meson, Mojo, Nginx, Nim, Ninja, Nix, Objective-C, OCaml, Odin, Org, Pascal, Perl, PHP, Pkl, PlantUML, PowerShell, Prisma, Prolog, Properties, Protocol Buffers, Pug, Puppet, PureScript, Python, R, Raku, Razor, Rego, reStructuredText, RON, Ruby, Rust, Scala, Shell, Slim, Solidity, SQL, SSH config, Starlark, Swift, Tcl, Thrift, TOML, Twig, TypeScript, Typst, V, Vala, Verilog, VHDL, Vim script, Visual Basic, XML, YAML, Zig.

A grammar is a `name.syn` file in `~/.config/rhun/syntax/`; your grammars win a tie with built-in ones.

```ini
name = Example
files = *.ex Examplefile
icon = code purple
first_line = example
comment = //
block = /* */
string = " \
mstring = """ \
region = <% %> preproc multiline
line = # heading
region = -- eol comment bol
toggle_comment = --
keywords = if else while return
types = int str
constants = true false
builtins = print
prefix = $v @a #p
ident = -
captypes = yes
case = insensitive
```

`comment`, `block`, `string` and `mstring` are shorthands for `region = start end class [multiline] [bol] [escape=X]`. An escape that is the end itself is doubled: with `escape="`, `""` stands for one quote. Classes: text keyword type function string number comment constant operator punctuation preproc variable builtin attribute tag heading inserted deleted escape link. Words not in a list are colored as functions when followed by `(`, and with `captypes` as types when capitalized.

`comment` also gives the token Toggle Comment adds in front of the selected lines. Where a comment counts only at a line's first non-blank, color it with a `bol` region and give the token with `toggle_comment`, which colors nothing itself (a `comment` would also color the token in the middle of a line). The first `comment` or `toggle_comment` sets the token.

`icon` gives the explorer's icon for the grammar's files: an icon from `assets/icons/files/` (without `.svg`, such as `rust` or `config`; `code` for a language with none) and a color, one of red orange yellow green blue purple pink cyan grey white (grey if left out). Without it the files get the default icon.

`prefix` lists characters that start a colored word, each followed by a letter: `v` variable, `a` attribute, `t` tag, `p` preproc (at the start of a line only). A file gets the grammar whose `files` fit its name best: an exact name first, then the longest `*.suffix`; your grammars win a tie. Only when no pattern fits does rhun look for a `first_line` word in the file's first line; the longest one found wins.

A grammar also says how the language is typed: auto-closing and surrounding pairs, the tokens
that indent the next line and outdent their own, continued lists and comments, doc comment blocks
and folding markers. Without these keys the editor behaves as it always did.

```ini
autoclose = ( ) [ ] { } " " {% %}
autoclose_code = "
indent_open = begin ^when ($
indent_close = end )
indent_middle = else
indent_dedent_after = return
continue = ;;
doc_block = /** * */
fold_markers = #region #endregion
```

`^T` counts T only as a line's first code token and `T$` only as its last; strings and comments
never count. Enter indents one level after a line with more openers than closers and one level
less after a dedent word; typing a closing or middle token on a line Enter indented takes it one
level back. The full list of keys and rules is in the extension spec (docs/extensions/v1.1.md,
"Language configuration"); an extension can set the same keys for an existing language in
`[language.NAME]`.

## Scripting

`rhun --control /path/to/socket` accepts one command per line, and `rhun --headless 1280x800 --script file` runs a file of them without a display. The tests use this.

```
open src/main.s
key ctrl+g
type 40
key Return
cmd toggle_comment
shot /tmp/rhun.ppm
print-state
```

Commands: `key`, `type`, `click x y [right|middle|shift|ctrl]` (ctrl is Cmd+click on macOS), `move`, `down`, `up`, `up-down` (a release and the next press in one frame), `scroll dy [MODS]` (modifiers as a key combination names them: `ctrl`, `shift+alt`), `open`, `cmd`, `shot`, `wait`, `wait-git`, `wait-agents` (until session discovery finishes), `agents-more`, `print-agents-page`, `print-agents-runs` (discovery runs started so far), `print-agents` (sessions and an optional open session number), `wait-grep` (until find in files has read the project), `wait-term TEXT` (until the terminal shows TEXT), `wait-update`, `resize`, `print-doc`, `print-state`, `print-project`, `print-panels` (whether the explorer, the agents panel and the terminal are shown), `print-palette`, `print-menu`, `print-tip` (the tooltip on screen), `print-term`, `print-term-cell ROW COL` (the middle of that terminal cell), `print-link` (the terminal link under the pointer), `print-settings` (the rows the Settings page shows, `section.key` each), `print-scroll` (the editor's horizontal scroll, its vertical one in 1/256 lines, the horizontal limit and the scrollbar's track), `scroll-x dx` (a sideways wheel), `print-git`, `print-gitlog`, `print-scm`, `print-update`, `print-frames`, `print-shape` (the mouse cursor's CUR_* value), `appearance dark|light|unknown` (the system's dark mode changes, as a platform reports it), `print-appearance` (that mode, `follow_system`, the three theme settings and the theme shown), `focus out|in` (the window loses or gets the keyboard, as a platform reports it), `echo`, `quit`. A headless run takes the system's mode from `RHUN_APPEARANCE` (`dark` or `light`). `cmd` runs anything from the command palette by its snake case name.

Managing extensions: `ext-install OWNER/NAME[@VERSION]` and `wait-install` (then `print-dialog`,
`dialog yes|no`), `ext-install-folder PATH [copy|link]`, `ext-install-archive PATH`,
`ext-rollback NAME`, `print-ext-versions NAME` (`version= source= tag= previous= link= fresh=`),
`ext-check-updates`, `wait-ext-updates` (until the check and the updates it queued are done, or a
dialog asks), `print-ext-updates` (a line per extension: `installed= latest=
state=current|available|asks|skipped|error`), `ext-update NAME`, `ext-update-all`, `ext-browse`,
`ext-index-refresh`, `wait-index`, `ext-search TEXT`, `print-ext-browse` (the Browse list with
each card's button), `ext-browse-install NAME` and `print-ext-page-more` (`print-ext-page` with
the newer lines: `updates=N`, `badge= color=`, a pack's members, `versions update= previous=`). `RHUN_EXT_BASE` points installs, checks and the
index at another place than `https://github.com` (tests use a `file://` tree or a local server);
`RHUN_EXT_UPDATE_EVERY=MS` turns on automatic checks in a headless run, every MS milliseconds.

## Extensions

Extensions are separate programs that rhun starts and talks to over their standard input and
output, one text line per message ([the protocol](https://rhun.app/extensions/v1/)). They are
native binaries, written in Rust, Go, C or C++, so they start in milliseconds and need nothing
else installed. One that crashes or hangs cannot take the editor with it, and on Linux and macOS
the kernel holds each one to the permissions its manifest declares.

An extension can also be a single **WebAssembly** module (compiled for `wasm32-wasip1` from Rust,
Go or C), which rhun runs itself: the same file works on Linux, macOS and Windows, and it can
reach only its own state folder and the project and home folders its permissions name, on every
system, Windows included (its page says "It runs as WebAssembly"). A system with a native build
of the extension runs that instead. WebAssembly extensions start as quickly as native ones; heavy
computation is slower. Writing one: [protocol 1.1](extensions/v1.1.md#webassembly-extensions-runwasm32-wasip1).

They can add commands to the palette with their own keys, read and edit the open documents (each
edit one undo step), put marks with messages in the gutter, **decorate** text (colors,
backgrounds, underlines, strikethrough, faded text, icons in the gutter, ticks in the scrollbar,
tips when the pointer rests on them), answer hover, open prompts and pick
lists, suggest terminal commands, set per-document options, ship themes and grammars, and keep
settings on their page. They can also open **views**, tabs they draw in with shapes and text in
the theme's colors (charts, pictures, previews) that hear the pointer, and provide **completion
lists** and **signature help** as you type: `ctrl+space` asks for the list, `ctrl+shift+space`
for the signature, Enter or Tab puts the selected item in. And they answer the language
commands:

| Key | Command | What happens |
| --- | --- | --- |
| F12 | Go to Definition | one definition opens at once; several are listed in the palette |
| ctrl+F12 | Go to Implementation | the same for implementations (Go to Declaration and Go to Type Definition are in the palette) |
| alt+F12 | Peek Definition | the definitions in a box under the cursor's line, without leaving it (also Peek References, Implementation, Declaration, Type Definition) |
| shift+F12 | Find All References | the references in the **Results** panel tab, grouped by file |
| F4, shift+F4 | Next/Previous Result | open the next or previous location of the Results tab |
| shift+alt+h | Show Call Hierarchy | the callers of the function at the cursor in the Results tab (Show Type Hierarchy alike) |
| ctrl+i | Show Hover | the hover card at the cursor; again, to scroll it with the keyboard |
| ctrl+r | Go to Symbol in File | the file's functions, types and variables, indented by nesting; type to filter |
| ctrl+t | Go to Symbol in Project | symbols of the whole project as you type (also `#` first in Go to File) |
| shift+alt+Right, shift+alt+Left | Expand/Shrink Selection | each selection grows to the enclosing expression, statement, block…; shrink goes back |
| F8, shift+F8 | Next/Previous Problem | the next problem in the file, with its message in the hover card |
| ctrl+click | | on a link (an `#include`, a URL in a comment) opens it; on a symbol goes to its definition. Hold ctrl to underline the symbol when a definition is available (cmd on macOS; alt when ctrl adds carets). |
| ctrl+. | Show Code Actions | quick fixes first, then refactorings and other actions |
| shift+alt+. | Auto Fix | applies the preferred quick fix at the cursor, else lists the quick fixes |
| shift+alt+o | Organize Imports | applied at once when the extension offers exactly one |
| ctrl+shift+r | Refactor... | the refactorings at the cursor (Source Action... and Fix All are in the palette) |
| F2 | Rename | on a word, asks for the new name (filled with what the extension says can be renamed there), then renames it in every file (see [Edits across files](#edits-across-files); without a matching rename provider, F2 renames the file) |
| shift+alt+f | Format Document | with the document's tab width and spaces; with a selection, Format Selection when the extension can |

When the pointer rests on a word, extensions that support it show a **hover card**: the problems
there first, then what each extension says, formatted and wrapped to the card's width; move the
pointer onto the card to scroll it (Shift+wheel for a long code line), drag to select text, and click a link to follow it (with the
card focused by `ctrl+i`, `ctrl+a` selects all and `ctrl+c` copies). A **lightbulb** in the gutter marks a line with a problem that has a quick
fix: click it, or press `shift+alt+.`, to fix it. The **Results** tab keeps the last 8 sets of
references, hierarchies and Find in Files results (`ctrl+Enter` in Find in Files moves its list
there; the arrows on its title go back and forth, the cross drops one). While extensions are
still searching its title shows their progress, and **Cancel Language Query** (or Escape in the
editor) stops them and keeps what came;
Enter opens a location, Space opens it and stays in the tab, Escape goes back to the editor. In a
call hierarchy, expanding a row asks for that function's callers; the arrow button switches to
the functions it calls. The **Outline** section of the sidebar (**Focus Outline**) lists the
active file's symbols, follows the cursor, and Enter goes to one. In the peek box, Up/Down choose
a location, Enter opens it, Escape closes it, and typing goes on in the editor. `[editor]
lightbulb = no` turns the lightbulb off; `format_on_type` and `format_on_paste` (both off by
default) let the formatter tidy lines as you type or paste.

Extensions can also fill **trees and logs** that rhun draws and keeps: sections in the sidebar
under the Explorer (click a header to fold it), tabs in the bottom panel after the terminals
(`ctrl+j` **Toggle Panel** shows or hides the panel without starting a shell), tabs in the right
column beside the Agents panel (**Toggle Side Views**), or a tab of their own. Trees keep your
expansion and selection as the extension updates them: arrows move and fold, Enter opens, Space
ticks a checkbox, typing jumps to a label, Shift+F10 opens the item's menu, and the buttons in the
header and on the hovered row run the extension's actions. Logs follow their end while it is in
view; `ctrl+f` finds a line, `ctrl+c` copies the selected lines. Showing a view starts its
extension if it is not running.

**Notifications** from extensions stack at the bottom right: info goes after 8 seconds, warnings
after 12 (the pointer over a card keeps it), errors and questions stay until you answer or close
them. **Focus Notifications** gives them the keyboard (Up/Down between cards, Left/Right between
buttons, Enter, Delete closes, Escape back); **Clear All Notifications** closes them all.
**Progress** shows in the status bar (click it for a card with Cancel), in a card, or as a bar at
the top of the extension's view; nothing shows for work that ends within half a second.

Extensions that declare `git = read` read the project's Git data through rhun: the status, the
blame of a file as you edit it (unsaved lines show as not committed), the history of a file or of
some lines, a file at an older commit, and rhun's diff view of two commits. rhun runs git for them,
so a folder opened from a `rhun://` link stays paused for them too until you trust it. An
extension can also give the base the gutter marks compare a file with, for files outside git
(another version control system, or "compare with" modes), and write commit messages (see
Commit message AI).

An extension for another version control system (the first-party Mercurial extension, for
example) adds its own section to the sidebar: a status line such as the branch, a message box
with its buttons (Ctrl+Enter in the box runs the first, usually Commit), and its changed files in
groups. Click a file to see its changes in a diff tab (against what the extension says the file
was); hover a file or a group for its action buttons, or right-click it for all its actions and
Open File. Other extensions may add buttons to the section's header. Its files and their folders are colored in the explorer and the tab titles as
git's are, and the gutter marks of its files compare with what it says they were.

An edit across files is checked whole before anything changes: if a document changed meanwhile
or a range is off, nothing changes and rhun says why. Each document's changes are one undo
step.

#### Edits across files

A rename, a code action or an extension's edit across files is checked whole before anything
changes: if a document changed meanwhile or a range is off, nothing changes and rhun says why.
Then it is made everywhere at once, and one **Undo** (`ctrl+z`, or `u` in vim) in any tab it
touched takes all of it back: "Undid 'Rename to total' in 5 files". Redo redoes it everywhere.
If one of its files changed since (you typed in it, or it changed on disk), Undo asks whether to
undo in that file only, in the files that did not change, or not at all. **Undo Last Multi-File
Edit** and **Redo Last Multi-File Edit** reach the newest one when none of its files is open.

Extensions that support it (the first-party language server extension does) change files you do
not have open directly on disk, without opening tabs, and save the open files they change that
had no unsaved changes; files with unsaved changes are edited and stay unsaved. They can also
create, rename and delete files: a renamed file's tab follows it, a deleted file's tab closes
and comes back with Undo. When an extension's edit would change files on disk and its manifest
does not ask for `project = write`, rhun asks first in the palette:

```
Language Server: 'Rename to total' changes 3 files that are not open and 1 open file, renames 1
> Apply
  Apply, and let Language Server change project files from now on
  Preview changes
  M  internal/calc.go    2 edits
  R  util.go → helpers.go
```

**Preview changes** (or Enter on a file's row) opens a read-only tab with the changes as a diff,
then the question again. The second row remembers the permission (`edits = yes` in
`extensions.ini`); the extension's page shows it with a switch to take it back. Escape changes
nothing. Every write is first recorded in `~/.local/state/rhun/edits`: a write the system refuses
puts everything back, and an edit cut short by a crash is put back at the next start ("Restored 3
files from a workspace edit that was cut short").

Extensions can also show a read-only **diff tab** of two documents (it follows both as they
change and closes with them; a side may be a document an extension provides, such as a file at a
git revision, which needs no tab of its own), scroll a document to a place without moving its cursor, list
locations in the palette as Find All References does, and offer **linked editing**: in an HTML
tag, renaming the opening tag's name renames the closing one as you type; the linked names are
outlined, and a space, Escape, Undo or moving away ends it.

Formatting, symbol rename, file symbols and signature help use a saved provider for the document's language.
With one matching extension, rhun uses it. With several, a chooser shows their `owner/name`
identities and remembers your choice. **Select Default Formatter**, **Select Rename Provider**,
**Select Symbol Provider** and **Select Signature Provider** change the choice without running the action. **Automatic**
clears this language's choice; a global default can still apply.

A chosen extension starts when needed. If you edit the document, move its cursor or switch tabs
while it starts, the pending action is cancelled. An unavailable saved provider reports an error
so you can enable it or choose another. F2 keeps its symbol-rename meaning while that provider
starts or needs attention.

Choices live in `extensions.ini`, alongside extension settings:

```ini
[providers]
format.Go = rhun-editor/format
format.* = rhun-editor/lsp
rename.Go = rhun-editor/lsp
symbols.Go = rhun-editor/lsp
signature.Go = rhun-editor/lsp
```

An exact language name overrides `*`. Language names match **Change Language Mode**; `-` means
no selected language. Values must include the owner. A missing, disabled, stopped or incompatible
saved provider never causes another extension to run silently.

**Format before saving** in Settings enables formatting on Save, Save As, Save All and save-before-close.
It is off by default. Its configuration is:

```ini
[files]
format_on_save = true
format_on_save_timeout = 2000
code_actions_on_save = source.organizeImports source.fixAll
code_actions_on_save_timeout = 2000
```

Saving uses the default formatter, or the sole eligible formatter, without opening a chooser.
An ambiguous or unavailable choice, formatter error or timeout saves the current text and reports
why formatting was skipped. The wait is in milliseconds, between 250 and 30,000. Typing while a
formatter runs discards its stale result and saves your latest text. Automatic formatting only
changes the document being saved and keeps your current tab and focus.

**Code actions before saving** runs the listed source kinds before formatting. It is empty by default.
Matching providers run in qualified name order, with one total time limit for the source phase.
Source kinds include `source.organizeImports`, `source.fixAll`, or a narrower kind such as
`source.fixAll.eslint`. An ancestor covers its descendants, so listing `source` runs all source
actions once. Invalid kinds keep the previous setting. Source actions can only edit the saving
document. A failure or timeout continues to formatting and saving with a warning. Typing during
this phase saves the latest text and skips further automatic changes.

**Cancel Save**, or Escape in the editor while a save is pending, keeps the document modified
without writing it. **Save Without Formatting** bypasses source actions and formatting, writes the current text, and preserves a pending
save-before-close intent. Save All waits for each document in turn; a failed or cancelled write
stops it. Vim's `:w`, `:wq`, `:wa` and `:wqa` follow the same save pipeline.

The host supports up to 128 running extensions. Busy extensions share a parsing budget and take
turns when that budget is exhausted, keeping time available for editor input and quieter peers.
**Stop** cancels an activation that has not started yet as well as a running extension.

Signature help while typing stays quiet when the provider choice is ambiguous or unavailable.
Use **Show Signature Help** to choose one explicitly. Help that is already open keeps using
its original provider as you type and move between parameters.

Extensions can insert snippets with editable fields. Type to replace the selected field;
repeated copies update together. Tab selects the next numbered field, Shift+Tab selects the
previous one, and Escape finishes field editing. The command palette also offers **Snippet:
Next Field**, **Snippet: Previous Field** and **Snippet: Finish Editing Fields** for custom keys.
Undo includes linked copies, and redo restores the final selection. Switching tabs pauses field
editing in that document. Editing outside the selected field or applying an external document
change finishes its session. A completion list takes Tab before snippet navigation.
Inserting another snippet inside a field preserves the enclosing snippet's linked copies.
Finish its inner fields with Tab, then continue through the enclosing fields. Moving the
selection outside the active field or pressing Escape finishes every nested level.

A field can offer a list of values. Up and Down select a value; Enter or a click applies it,
and Tab applies it and moves to the next field. Shift+Tab leaves the value unchanged and
moves to the previous field. Escape closes the list first. You can also type your own value,
or reopen the list with **Snippet: Choose Value**. Choices keep working after the extension
stops. **Show Completions** opens the provider list from a fully selected field by placing the
caret at its end. Some snippets finish with text selected, ready for an ordinary replacement.
Extensions can read a versioned insertion context with the exact range's text, current line,
file and project paths, indentation, document settings and grammar comment token. It works
with inactive and readonly documents and preserves the editor's selection. See the
[native snippet protocol](extensions/v1.1.md#read-only-insertion-context) for the request and SDKs.

### Agents, reviews and tools

rhun does not drive agents; you talk to them in a terminal. Extensions add to what rhun shows
of them:

- **More agents in the agents panel.** An extension can list the sessions of another agent
  (Gemini CLI, Aider, a local model): they appear with the built-in ones, with the extension's
  badge, the model, the age and whether the agent works or waits for you, and open as the same
  conversation view. Settings > Agents has a switch for each such source.
- **Talk to those agents.** When the extension allows it, its sessions get a box under the
  conversation: Enter sends (Shift+Enter for a new line), Stop interrupts the agent while it
  works, and the agent's questions show as cards with a button per answer (keys 1 to 9 pick, or the arrow keys and Enter).
  The `+` button in the panel's header starts a new session of that agent.
- **The Review tab.** An extension, or an agent through the MCP bridge, can propose a change. rhun
  shows it in a Review tab: each file with its added and removed lines, each change with a few
  lines around it. Accept or reject a file, a single change, or everything: the buttons on each
  line, or `a` and `r` for the file under the cursor, `A` and `R` for the change, `]` `[` and
  `}` `{` to move between files and changes, Ctrl+Enter to accept everything. What you accept is
  one undo step per decision and stays unsaved until you save; a file you changed meanwhile is
  left alone. Closing the tab rejects the rest.
- **Tools.** Extensions can offer tools that other extensions call through rhun (search an index,
  read the open files, propose an edit). A tool that changes anything asks you first: Allow once,
  Allow for this session, or Deny.
- **MCP for terminal agents.** The `rhun-editor/mcp` extension lets Claude Code, Codex, Grok,
  OpenCode and other MCP clients use those tools on the project you have open: what is open and
  selected, unsaved text, the problems shown, open a file, propose changes for the Review tab,
  and put a command in rhun's terminal prompt (it runs when you press Enter). After installing it,
  **MCP: Add rhun to Claude Code** (or **to Codex**) puts the setup command in rhun's prompt.

### Picture extensions and sound

Extensions can draw interactive pictures in a tab or panel, including games and visual tools.
Since rhun 0.18.2, picture extensions can receive key releases and focus changes for smooth
held controls. Input goes to the focused picture, and editor shortcuts keep their bindings.

[DOOM](https://github.com/rhun-editor/doom) runs the original shareware episode in an editor tab,
with sound effects and music. In **Install from GitHub…**, enter `rhun-editor/doom@0.1.0`,
approve its audio access, then run **DOOM: Play** from the command palette. The game data is
included. Click the game to play; W/S move, A/D strafe, arrows turn, Space fires and E opens doors.
P pauses and M mutes. It pauses automatically when focus leaves the game.

An extension that plays sound declares `audio = yes` in `[needs]`. Installation shows
"access local audio devices and services", and adding audio permission during an update asks
again. macOS grants output services. Linux sound devices and services can also expose recording;
this permission does not promise playback-only confinement. Windows extensions currently run
without an OS sandbox. DOOM opens playback streams only.

### Install and manage

The extensions button in the title bar (the puzzle piece) opens a menu of what is installed.
**Install from GitHub…** takes `owner/name` or the repository's URL: rhun downloads the latest
release for your system, checks its checksums, shows what the extension may do (read or change
the files you have open, read your project, use the network, run named programs) and asks. The
**Extensions** page turns each one on or off, pins its badge to the title bar, shows its
settings and its log, and removes it. Installed extensions live in
`~/.config/rhun/extensions/OWNER/NAME/` (`%APPDATA%\rhun\extensions` on Windows).

Each extension's page also shows what it costs: how long it has run and how long it took to
start, its CPU time and use now, the memory and processes of the program and whatever it started,
the messages and bytes each way, and how many of rhun's questions it answered slowly, too late or
with an error. The cards show memory and CPU while an extension runs. An extension whose manifest
says `idle = stop` is stopped after five minutes without work (its page says so) and starts again
by itself the next time it is needed.

Its **Contributions** block lists everything it adds: its commands with the key each runs from,
its key bindings and how each stands (active, overriding a built-in key, shadowed by your own
`[keys]`, or refused, say a bare letter without a `when` guard), its menu items, status bar
items, settings, grammars and language keys, file icon themes and views, and, in red, any lines
of its manifest that were dropped and why.

An extension that signs in to a service keeps its tokens in your system's keychain: the macOS
Keychain, the Windows Credential Manager, or on Linux the Secret Service (GNOME Keyring, KWallet,
KeePassXC); its install dialog says "store passwords and tokens in your keychain". Its page lists
the keys it stored (never the values) with **Forget**, and removing the extension removes them.
Without a keyring (a Linux server, a bare window manager), they last until rhun quits. **Extension
secrets** in Settings changes where they go:

```ini
[extensions]
secrets = system        # or memory (until rhun quits), or file (a file only you can read)
```

`file` keeps them in `~/.local/state/rhun/secrets/`, readable only by you, in plain text: as safe
as a `~/.netrc`.

When an extension wants to open a web page (to sign in, say), rhun asks first: "Auth Demo wants
to open github.com in your browser", with **Open**, **Copy Link**, **Cancel** and **Always open
links from Auth Demo**. Always is remembered, and the switch on the extension's page takes it
back. After you sign in, the browser comes back to the extension through a `rhun://ext/` link
that works once, for ten minutes, or through a page on your own computer that says "Signed in.
You can close this tab." A `rhun://ext/` link nobody is waiting for says so and does nothing.

Extensions that read the project (a TODO list, a linter that checks every file) list its files
and search them through rhun rather than walking the disk themselves: they see the files git sees
(`.gitignore` applies), not the names in **Hidden in explorer**, and the text you have not saved
yet. Their searches run a few milliseconds at a time, so typing never waits for them.

A project can set some of an extension's settings for everyone who opens it, in
`.rhun/extensions.ini` at the top of the folder, in the same form as your own file:

```ini
[rhun-editor/go]
setting.style = goimports
setting.style@Go = gofumpt     # for Go files only
```

Only settings the extension opens to projects take effect (never which program it runs), and only
in a folder you opened yourself or trusted. The extension's page shows "This workspace sets
goimports (.rhun/extensions.ini)" under such a setting, with **Open**.

The command palette shows each extension command's qualified name, `owner/name.command`,
beside its title. You can search that name or use it in `[keys]`. The shorter `name.command`
works when only one installed extension has that name. With two publishers using the same
name, use the qualified name so turning an extension off cannot change which command runs.

#### Versions and roll back

`owner/name@0.1.0` (or `@v0.1.0`) installs that release's tag; without a version rhun asks
GitHub which tag is the latest and installs exactly that one, so the archive and its checksums
always come from one release. The Add dialog says whether the version was reviewed for the rhun
extensions index. Archives that unpack to more than 64 MB, or hold links, devices or paths
outside themselves, are refused.

rhun keeps the version an install or update replaces in
`~/.config/rhun/extensions/.previous/OWNER/NAME/`, one per extension. **Roll back to 0.1.0** on
its page (or `ext-rollback` in a script) swaps the two, so rolling back twice returns to the
newer one; when the older version may do more than the newer, rhun asks first. A new version
that fails its first start (it cannot start, says no `hello` within 5 seconds, or exits before
it) rolls back by itself with a note such as "Showcase 0.1.2 did not start (no hello within
5 s); back to 0.1.0". Its settings stay across versions, including settings only one of them
declares. Each install writes `.rhun-install` into the extension's folder: where it came from
(`source = github`, `archive` or `folder`, the repository and tag or the path), the archive's
SHA-256, whether the index reviewed it, when it was installed, and `started = yes` after its
first start.

#### Updates

rhun checks for extension updates 60 seconds after it starts and then once a day (Settings >
Updates > **Check extensions now**, or **Check for updates** on the Extensions page, checks at
once). An extension the [rhun extensions index](https://github.com/rhun-editor/extensions) lists
is offered only the version the index reviewed (its tag and archive digest); any other extension
is asked about through its repository's latest release on GitHub. Waiting updates put a dot on
the title bar's extensions button and an **Update all** row in its menu; the Extensions page
lists them at the top, each card has **Update to 0.1.2**, and the details page links the
release's notes (**What's new**).

`[updates] extensions` decides what happens on its own: `install` (the default) installs reviewed
versions by themselves, one at a time, with a note such as "Updated Showcase to 0.1.2"; `check`
only shows updates; `off` stops the checks. An update the index has not reviewed is never
installed by itself: **Update** says "Not in the rhun extensions index: nobody has reviewed this
version." first. An update that asks for more access than the installed version (a higher level
for your files or project, home, the network, the terminal, or a new program to run) always asks,
naming what is new, and waits for you; Cancel keeps the installed version and stops automatic
updates from fetching that version again. After **Roll back**, automatic updates leave the
version you went back from alone until a newer one appears. A reviewed version that needs a newer
rhun (the index's `rhun` key) is neither offered nor installed; the Extensions page says which rhun
it needs. Extensions installed from a folder, a link or an archive are never offered updates. What rhun learned is kept in
`$XDG_STATE_HOME/rhun/extension-updates`.

#### Browse

**Browse** on the Extensions page lists the extensions of the
[rhun extensions index](https://github.com/rhun-editor/extensions): each one's version was
reviewed before rhun offers it, its release pinned by tag and archive digest. Type in the search
field (ctrl+f on the page) to narrow the list: each word must start a word of an extension's
title, `owner/name`, description or keywords; featured ones come first. Each card shows what the
extension can do and one button: **Install** (the reviewed version; its download must match the
index's digest, then the usual Add dialog), **Installed**, **Update to 0.2.0**, **Not for this
system** or **Needs rhun 0.19**. rhun fetches the index when Browse opens and its copy is older
than a day, with every update check, and on **Refresh** (never at startup just for Browse); it
keeps the copy in `$XDG_STATE_HOME/rhun/extension-index.ini` and shows it offline with its age.
The website's [catalog](https://rhun.app/extensions/catalog/) lists the same extensions with
Install links that open rhun.

#### Packs

A pack installs several extensions at once: its manifest's `pack = OWNER/NAME …` names them (at
most 16). Installing it downloads the pack and every member you do not have, then asks once:
"Add “Essentials” and 3 extensions?", a line per member with what it can do, and a line for any
that could not be downloaded; **Add** installs everything that downloaded. A pack has no program
of its own. Its page lists its members, each with **Remove** or **Install**; removing the pack
keeps them. An update of a pack that names a new member asks before adding it.

**Remove** stops the extension and deletes its folder, its previous version, its saved data and
log, its settings, pin and on/off choice, the provider choices that name it (rhun asks again
rather than switching silently) and what rhun knew about its updates. Your `[keys]` stay.

#### Development installs

The page's **Install** menu (and the palette commands **Install Extension from Folder**, **Link
Extension Folder (development)** and **Install Extension from Archive**) install what you are building:

- **From a folder** copies a folder holding `extension.ini` (laid out as a release archive)
  through the same checks as a download.
- **Link a folder** runs the extension from your folder: rhun keeps only a stub with its record
  in the extensions folder, so rebuild and **Restart** is the loop. Removing it leaves your
  folder alone. A link that replaces a GitHub install keeps that install as the previous
  version, so **Roll back** returns to the release.
- **From an archive** takes a release `.tar.gz` on this computer; a `sha256sums.txt` beside it is
  checked when there is one.

Archive and folder installs are never checked for updates.

#### New extensions

`rhun new-extension [DIR]` starts an extension of your own from a template. In a terminal it asks
four things: the name (a manifest name: lowercase letters, digits and dashes; DIR's name by
default), the owner (your GitHub user or organization; `git config github.user` by default), the
language (Rust or Go, with the arrow keys or 1 and 2) and whether to add the agent skills (yes by
default). Ctrl+C stops it and leaves the terminal as it was. Then it downloads the current
`main` of [template-rust](https://github.com/rhun-editor/template-rust) or
[template-go](https://github.com/rhun-editor/template-go), checks the archive as an install does
(no links, nothing outside itself, at most 64 MB) and puts it in DIR, a new or empty folder
(`./NAME` without one), renamed: `name`, `owner`, `title` and the programs in `extension.ini`,
the Go module (`github.com/OWNER/NAME`) or the Cargo package, the headless test's script and
expected output, and the README's title. With the skills, the `rhun-extension` skill from
[rhun-editor/skills](https://github.com/rhun-editor/skills) goes into `.claude/skills/` (Claude
Code) and `.agents/skills/` (Codex); without them the template keeps its own copy in
`.claude/skills/`. Last it runs `git init` there (no commit) and prints the next steps: build the
program into `bin/`, `sh tests/run.sh`, then **Link Extension Folder (development)** on the
folder.

For scripts and agents the answers come as flags, and without a terminal they are needed:

```sh
rhun new-extension ~/code/word-count --owner octocat --lang go --no-skills
rhun new-extension --name word-count --owner octocat --lang rust --skills
rhun new-extension word-count --yes      # owner from git config github.user, Rust, the skills
```

In rhun, **Extensions: New Extension…** (also **New Extension…** in the Extensions page's Install
menu) asks the same in five steps, the last one the folder (`~/code/NAME` by default), with Back
(alt+left) between them. The download runs in the background with a progress card and Cancel;
when it is done a notification offers **Open Folder** (this window), **New Window** and **Dev
Install** (Link a Folder on it).

#### Submitting to the index

Once a release is published (tag `vX.Y.Z`, the templates' release workflow), `rhun
submit-extension [DIR]` (DIR is the extension's folder, the current one by default) proposes it to
the [rhun extensions index](https://github.com/rhun-editor/extensions). It reads `owner`, `name`
and `version` from `extension.ini` (the tag is `vVERSION`; `--tag` picks another), the release's
`sha256sums.txt` and the tag's commit, and asks the category (`languages formatters themes testing
debugging tools packs other`), keywords and the maintainer (gh's or git's GitHub user by default).
When the index already lists the extension, its category, keywords and maintainer are the
defaults and what only the index's maintainers set (`featured`, `rhun`) stays. It warns when
`.github/workflows/release.yml` does not attest the archives (`actions/attest-build-provenance`):
the index's check needs that attestation. Then it prints the entry, `OWNER/NAME.ini` as the
index's files are written (the tag, the commit and a `sha256.TARGET` line per archive), and opens
the pull request:

- with [gh](https://cli.github.com) installed and logged in, it offers to do it all: a fork of
  the index, the branch `submit-OWNER-NAME-TAG` with the file, and `gh pr create`;
- otherwise (or when you say no) it opens GitHub's page for the new file with the entry filled in,
  which forks the index for you and proposes the change; for an extension already listed, GitHub's
  editor for its file, where the printed entry replaces the text. The address is printed too.

Without a terminal it takes flags: `--category C --keywords "a b" --maintainer M`, `--gh` for the
pull request through gh (otherwise the browser), `--yes` for the defaults (`other`, and gh when it
is logged in). In rhun, **Extensions: Submit to Index…** (and **Submit to Index…** on a linked
extension's page) asks the folder, then the same questions, with the progress and the result in
notifications (**Open** for the pull request; **Open Again** and **Copy Entry** for the browser).

`rhun://extension/OWNER/NAME` and `rhun://extension/OWNER/NAME@VERSION` links open the same Add
dialog (the site's catalog uses them for its Install buttons).

From [rhun-editor](https://github.com/rhun-editor):

| Extension | What it does |
| --- | --- |
| `rhun-editor/lsp` | completion, signature help, errors, hover text, definitions, references, symbols, code actions, rename and format from the language servers you have installed (gopls, rust-analyzer, clangd, pyright and 18 more) |
| `rhun-editor/format` | Format Document (shift+alt+f) with the formatter you already have, such as gofmt, prettier or ruff |
| `rhun-editor/editorconfig` | applies your `.editorconfig` files |
| `rhun-editor/snippets` | your snippets in the completion list as you type, and Expand Snippet for a short name |
| `rhun-editor/tasks` | puts your project's tasks, such as make targets and npm scripts, in the command palette |
| `rhun-editor/charts` | charts in a tab: the project's lines by language, the open file's line lengths (Rust) |
| `rhun-editor/wordfreq` | the open file's most frequent words as a bar chart that follows your typing (C) |
| `rhun-editor/words` | completion from the words in your open files (C++) |
| `rhun-editor/showcase` | a tour of everything an extension can do |
| `rhun-editor/tests` | Go and Rust tests in the Testing section: run, results, diffs, coverage (Go) |

### Testing

Extensions that run tests (such as `rhun-editor/tests` for Go and Rust) fill the **Testing**
section of the sidebar (command Testing). Its tree shows each extension's tests by module,
package or file, with their state: not run, queued, running, passed, failed, errored, skipped. The
section's buttons run all tests, run them with coverage, run the failed ones again and cancel;
`r` runs the selected test, `d` debugs it, and its menu also goes to the test or its failure,
opens the expected and actual values as a diff tab and shows its output. Under the tree the
selected test's last result: its message, the expected and actual values as a colored line diff,
and the end of its output. The field above the tree filters it (ctrl+f): each word starts a word of
a test's name ("add" finds TestAdd); the button beside it shows only failed tests. After a coverage
run a **Coverage** section lists the files, the least covered first. The status bar counts a run's
progress, then the passed and failed tests (a click shows Testing).

Debugging a test starts the extension's own debugger on it in rhun's debugger (`rhun-editor/tests`:
Delve for Go, lldb-dap for Rust): breakpoints, stepping and the Debug Console work as for any
session, and when the session ends the program's exit status is the test's result.

In the editor each test has a run button in the gutter at its first line (`[testing] gutter =
false` hides them): a click runs it, a right click opens its menu, and after a run the button
shows the result. Buttons, failure marks and coverage follow your edits until the extension lists
the file's tests again. A failure with a place is a problem (the Problems tab, a mark in the file with
the expected and actual values on hover) until the test passes. After a run with coverage the line
numbers are tinted: covered green, missed red, partly covered yellow (Show Test Coverage toggles
them).

Commands, without default keys (bind them in `[keys]`): Run All Tests, Run Tests in Current File,
Run Test at Cursor, Debug Test at Cursor, Run All Tests with Coverage, Re-run Failed Tests, Re-run
Last Test Run, Cancel Test Runs, Show Test Coverage, Go to Next Test Failure.

The test programs (`go test`, `cargo test`) are started by rhun, not by the extension: as you, with
your environment, in your project, only during runs you start. The extension's manifest names
them (`[needs] tests = go cargo`, shown before you install it), and the first run in a project
asks once, showing the command (Forget on the extension's page asks again). A folder opened from
a link runs none until you trust it. Results are kept until rhun quits.

| `rhun-editor/mcp` | lets the agents in your terminal use rhun over MCP: open files, the selection, unsaved text, problems, and changes you review |

### Tasks and problems

Extensions publish tasks: the first-party `rhun-editor/tasks` finds them in your project (Makefile
targets, `justfile` recipes, `package.json` scripts, Cargo and Go builds and tests, and your own in
`.rhun/tasks.ini`). **Run Task** lists them all, recently run first. **Run Build Task**
(ctrl+shift+B) runs the build group's default, **Run Test Task** the test group's, and **Re-run
Last Task**, **Restart Task**, **Stop Task** and **Show Task** do what they say.

A task runs in a tab of the terminal panel, labelled with the task, and the tab is reused when it
runs again. The dot before the label is filled while it runs, then becomes a check (exit 0), a
cross (another code) or a square (stopped). When it ends a footer line says how and how long it
took. The panel's Restart and Stop buttons act on the current task tab. Stop types Ctrl+C and kills
whatever is left 2 seconds later. Closing the tab kills the program and everything it started. While
tasks run, the status bar shows the newest one (a click shows it).

A task can depend on others, which run first, in order or together. A background task, such as a
dev server or a watcher, counts as done when it prints its ready line, and it keeps running.

The first time an extension runs a program in a project, rhun asks, showing the command: Allow
remembers it for that extension and project (Forget on the extension's page asks again). The
programs run as you, with your login shell's environment, outside the extension's sandbox.

Errors and warnings a task prints (Go, gcc and clang, rustc and cargo, TypeScript, MSBuild, or the
task's own patterns) become **problems**: marks in the files (the status bar counts them) and the
**Problems** tab of the panel (ctrl+shift+m), files first, then each problem. Enter or a click goes
to it. A task's problems are replaced when it runs again; Clear Task Problems removes them.
### Debugging

rhun debugs programs through the Debug Adapter Protocol: an extension declares the debuggers
(`rhun-editor/debug`: Go with Delve, Python with debugpy, C and C++ with lldb-dap) and rhun talks
to them itself. The first time an extension's debugger starts in a project, rhun asks once
("Let Debug run programs in proj?", the exact command shown); the adapter then runs as you, outside
any sandbox. Forget on the extension's page asks again.

**Launch configurations** live in `PROJECT/.rhun/launch.ini`, one section per configuration
(Open Launch Configurations creates the file; **Add Configuration** appends one of the installed
debuggers' templates; **Select Configuration** picks the one F5 starts):

```ini
[Run server]
type = go
mode = debug
program = ${project}/cmd/server
args = --port 8080
env.LOG_LEVEL = debug
before = build

[Python file]
type = python
program = ${file}
console = integratedTerminal

[Attach to a running Delve]
type = go
request = attach
mode = remote
server = 127.0.0.1:2345
```

- `type` picks the debugger and `request` is `launch` (the default) or `attach`. Every other key is
  a launch argument, typed as the debugger declares it (`list` keys split into words and repeat;
  `KEY.NAME = value` builds objects; a numeric segment such as `args.0` is an array index).
- Variables: `${project}`, `${projectName}`, `${file}`, `${fileDir}`, `${fileName}`,
  `${fileStem}`, `${fileExt}`, `${relativeFile}`, `${line}`, `${column}`, `${selection}`,
  `${home}`, `${env:NAME}`, and `$$` for a dollar sign. Questions asked at each launch:
  `${ask:Port}` (text), `${pick:Mode|debug|test}` (a list) and `${process}` (the running
  processes, giving the chosen one's id); the same question in one configuration is asked once,
  and Escape abandons the launch.
- `before = TASK` runs a task (Run Task's tasks, by label or id) and launches once it succeeds; if
  it fails, rhun asks whether to debug anyway. `after = TASK` runs one when the session ends.
- `compound = A | B` starts those configurations in turn (each one after the previous one's
  questions are answered).
- `server = HOST:PORT` connects to an adapter that already listens (HOST `localhost` or an IPv4
  address) and starts nothing.
- A debugger can prepare the configuration first (Delve's "Test at cursor" finds the test the cursor
  is in; debugpy picks the project's `.venv`): the console says "Preparing the launch", and Stop
  cancels it.

**Keys** (F5 and friends, as in other editors): F5 Start or Continue, Ctrl+F5 Run without
debugging, Shift+F5 Stop, Ctrl+Shift+F5 Restart, F6 Pause, F10 Step Over, F11 Step Into,
Shift+F11 Step Out, F9 Toggle Breakpoint, Ctrl+Shift+Y the debug view. While a session runs they
also work from the terminal (`[debug] keys_in_terminal`).

**While debugging**, the title bar holds the toolbar (Continue or Pause, Step Over, Into, Out,
Restart, Stop); the sidebar shows Variables, Watch, Call Stack and Breakpoints, and the panel the
Debug Console, where an expression evaluates in the selected frame (Up and Down recall earlier
ones). Call Stack lists the program's threads with the stopped one open; choosing another thread
shows its frames, and Continue and the steps then act on it. Long arrays open in ranges of 100 (`[0..99]`, nested for bigger ones), F2 on a variable sets
its value, and values that changed since the last stop are highlighted. An adapter may start child
sessions of its own (startDebugging); they end with their parent. The paused line is marked in the gutter, and resting the pointer on a name shows its value.
Program output, the adapter's messages and rhun's notes ("Program exited with code 3") go to the
console. A program the adapter starts "in the terminal" (debugpy's `console =
integratedTerminal`) gets a terminal tab of its own, where you type its input.

**Breakpoints**: click the gutter's left lane or press F9; a right click adds a conditional
breakpoint (an expression), a hit count or a logpoint (a message with `{expressions}`), and
disables or removes one. Breakpoints follow edits, are kept per project, and show hollow until the
debugger confirms them. The Breakpoints section also lists function breakpoints and exception
filters (such as Python's "Uncaught Exceptions").

**Settings** (`[debug]`): `show_on_start` opens the debug view when a session starts,
`keys_in_terminal` as above, `console_lines` the lines the console keeps (10000).

| Debugger | macOS | Linux | Windows |
| --- | --- | --- | --- |
| lldb-dap (C, C++) | tested (Xcode's, through `xcrun`) | tested (Ubuntu 24.04's lldb-dap-18, on the release workflow's runner); needs a native machine (no ptrace in Docker under Rosetta) | not tested |
| Delve (Go) | tested (a program, a test at the cursor after a build task) | needs a native machine (as above) | not tested (its TCP connection, and `server =`, tested with a fake adapter under Wine) |
| debugpy (Python) | tested (uncaught exceptions, input in the terminal) | not tested | not tested |

Ubuntu's lldb-dap (lldb-dap-18 and later) looks up the debug info of the libraries a program loads
on https://debuginfod.ubuntu.com (its default, also when `DEBUGINFOD_URLS` is unset) and answers the
launch only after: where that server is slow or unreachable, the session stays "configuring" for
the debuginfod timeout (90 s) before the program starts. To turn the lookups off for a
configuration, add `initCommands = "settings clear plugin.symbol-locator.debuginfod.server-urls"`
when the debugger takes `initCommands`.

In a remote window the adapter runs on the host and launch.ini is the host's file. A debugger
reached over TCP (`transport = tcp`, as Delve is) listens on a port free on the host's loopback, and the host makes
the connection there, again until the adapter listens (10 s at most); `server = PORT` (or
`localhost:PORT`) also means a port on the host. An adapter its extension ships is copied to the
host with the extension's folder before it starts.

Extensions declare debuggers with `[debugger.TYPE]` sections and can start sessions themselves
(feature `debug`, docs/extensions/v1.1.md "Debuggers").

### Write your own

Start from [template-rust](https://github.com/rhun-editor/template-rust) (Rust is the first
choice) or [template-go](https://github.com/rhun-editor/template-go); for C and C++ one header,
[rhunext.h](https://github.com/rhun-editor/extension-protocol/tree/main/c), does the protocol. A
template is a working extension with a headless test and a release workflow that builds Linux,
macOS and Windows binaries: tag `vX.Y.Z` and anyone can install it from GitHub.

Extensions are meant to be written with a coding agent. The protocol is one document written for
people and agents ([v1.md](https://raw.githubusercontent.com/rhun-editor/extension-protocol/main/v1/v1.md),
with a grammar and a JSON Schema of the manifest), the templates carry `AGENTS.md`, and the
[rhun-editor/skills](https://github.com/rhun-editor/skills) plugin gives Claude Code
(`/plugin marketplace add rhun-editor/skills`, then `/plugin install rhun@rhun-editor`) and Codex
(`codex plugin marketplace add rhun-editor/skills`, then `codex plugin add rhun@rhun-editor`) the
workflow, the SDKs' reference and the tests to pass. `rhun-ext-check` plays rhun against an
extension and names every protocol mistake; `rhun --headless --script` drives the real editor
in tests.

## Source

| Path | |
| --- | --- |
| `src/sys.s mem.s lib.s proc.s` | syscalls, allocator, strings, UTF-8, child processes |
| `src/gfx/` | canvas, TrueType parser, rasterizer, icons |
| `src/img/` | image decoders: inflate, PNG, JPEG, GIF, BMP / ICO, QOI, PNM, TGA |
| `src/ui/ui.s` | immediate-mode widgets |
| `src/plat/` | Wayland, XKB keymaps, X11, headless, the system's dark mode (desktop portal over D-Bus, GTK settings) |
| `src/app/` | documents, editor, vim keys, image view, explorer, palette, settings, agents, terminal, git, syntax, themes |
| `src/win/` | Windows x64 assembly: Unicode APIs, Win32 window, directory notifications, ConPTY |
| `src/mac/` | macOS, native AArch64: entry, Linux system calls on libSystem, FSEvents, the AppKit window |
| `tools/arm64.py` | the x86-64 to AArch64 translator for Apple silicon |
| `runtime/` | themes and grammars embedded into the binary |
| `assets/fonts/` | Iosevka Fixed, cut down (SIL Open Font License) |
| `assets/icons/files/` | the explorer's file icons, from Seti UI (MIT), and the file types they go with |

Porting to another platform means another file in `src/plat/` that fills the platform table in `src/rhun.inc`; macOS fills it from `src/mac/cocoa.s`. Code that differs by system is in `.ifdef MACOS` or `.ifdef WINDOWS` blocks.

## License

MIT, see [LICENSE](../LICENSE). The built-in Iosevka font is under the SIL Open Font License ([assets/fonts/LICENSE-Iosevka.md](../assets/fonts/LICENSE-Iosevka.md)). The file icons are from Seti UI, MIT licensed ([assets/icons/files/LICENSE-Seti.md](../assets/icons/files/LICENSE-Seti.md)).
