# rhun guide

rhun draws everything itself: it rasterizes TrueType fonts, icons and widgets into a pixel buffer and hands that buffer to the display server. On Linux it speaks the Wayland and X11 wire protocols directly, without libc, toolkits or libwayland. On macOS the same code runs natively on Apple silicon in an AppKit window. On Windows it runs as native x64 assembly in a Win32 window. Fonts, themes and grammars are built in on all three platforms.

## Features

- Tabs, file explorer with file type icons, command palette, fuzzy file finder, find and replace, find in files, go to line
- Project menu in the title bar: open a folder or a file from anywhere on disk, or a recent folder, in this window or a new one
- Image preview: PNG, JPEG, GIF, BMP, ICO, QOI, PNM and TGA open in a tab, with zoom and pan
- Syntax highlighting for about 125 languages, defined in plain text grammar files
- 40 color themes, dark and light, with a match for every Omarchy theme; add your own. A dark and a light theme switch with the system's dark mode on macOS, Windows and Linux, as in VS Code
- Settings page and a readable config file, both applied while running
- Agents panel: Claude Code, Codex and Grok Build sessions of the project and its Git worktrees, with theme-colored provider badges and icons, updated live as the agent works. Worktree sessions show a branch icon and the worktree name in a badge beside the provider. The list starts with the 50 most recently active sessions across all providers and related worktrees. Load more adds 50. Discovery runs in the background and reuses a saved metadata index; routine refreshes are silent, and pause while the panel is hidden.
  Grok Build sessions come from `~/.grok/sessions` (`$GROK_HOME/sessions` when set) with the titles Grok gives them; one shows once it has a prompt, and a subagent's session stays inside its parent's. The clones Grok makes with `grok --worktree` are not Git worktrees of the project, so their sessions are not listed. `[agents] sources` picks the providers: `claude codex grok` by default.
  Git worktree registrations supply the checkout roots. Rhun remembers verified worktree paths in repository-specific state, so their agent history stays visible after the checkouts are deleted or Git prunes their registrations. Nested Claude worktree history can also be recovered from its exact recorded path without prior Rhun state. If another repository takes over a remembered checkout path, Rhun keeps previously verified sessions and excludes new sessions from that repository. When Git metadata is stored outside the main checkout and contains no reference to its path, open the main checkout to include its sessions.
- Terminal panel: shells with 24-bit color, mouse, scrollback and full-screen programs; Cmd+click (Ctrl+click on Linux and Windows) opens links in the browser and files in a tab
- Git: changed lines in the gutter, file status in tabs and the explorer, diffs, a history of all branches drawn as a graph, and source control as in VS Code: stage, commit, pull, push
- Undo and redo, auto-indent, bracket pairs, comment toggling, moving and duplicating lines, soft word wrap; without it, lines wider than the editor get a horizontal scrollbar along its bottom
- Vim mode, off by default: normal, insert and visual modes, operators, text objects, counts, `.`, search and `:` commands
- Characters missing from the built-in fonts are drawn with the system's fonts
- Every XKB layout, dead keys and the Compose key (the system's Compose rules, `~/.XCompose` or `$XCOMPOSEFILE`)
- Files changed on disk are reloaded, open files are restored per project
- Wayland with fractional scaling; X11 as a fallback
- macOS on Apple silicon: Retina displays, input methods and dead keys, full screen, signed with a Developer ID
- Windows x64: native window, Unicode paths and clipboard, per-monitor scaling, and a ConPTY terminal
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
If you have unsaved edits, rhun keeps them and shows an inline warning. Use **Revert File** from the
command palette to load the disk version, or save to keep your version. Undoing back to the saved
state loads the disk version too.
Saving a read-only file asks first: **Overwrite** replaces it and it stays read-only, **Cancel** leaves
it as it is, and Save As writes a copy elsewhere. Save As onto a read-only file and Save in the
question about unsaved files when closing or quitting ask the same; Vim's `:wq` closes the file after
Overwrite, and `:wa` leaves read-only files unsaved. In a folder that takes no new file, a save fails
as any other.

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
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing https://github.com/vshvedov/rhun/releases/latest/download/install.ps1).Content))"
```

The installer verifies SHA-256, installs under `%LOCALAPPDATA%\Programs\rhun`, adds a Start menu shortcut and updates your user PATH. Open a new terminal after installation. Options are `-Version X`, `-InstallDir DIR`, `-NoModifyPath`, `-NoShortcut`, and `-Uninstall`. It refuses to replace a running editor or a directory containing unrelated files. Use the status bar to download an update and restart into it, or close rhun and rerun the installer. Automatic checks are enabled for release builds, with installation and restart initiated by you. Uninstalling keeps settings and sessions.

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

Use `rhun` or `rhun.com` from a terminal. Normal launches return the prompt immediately. Use `rhun --wait` when another program needs to wait for the editor. `rhun.com --version`, `--headless`, and `--script` preserve console output. The Unix `--control` socket is not available on Windows; use a script file instead.

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
| Ctrl+, | Settings |
| Ctrl+K | Color theme |
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

**Reopen Closed Tab** (Ctrl+Shift+T) brings back the tabs you closed, the last one first, in their place among the tabs and with the cursor, selection and scroll a file had. Pressing it again goes further back, up to 20 tabs; tabs that are already open and files that are gone are skipped. Opening another folder starts the list over.

Find, replace and find in files ignore case until their Aa is on, in every script: `été` finds `Été`, `яблоко` finds `ЯБЛОКО` and `οδος` finds `ΟΔΟΣ`. Accented letters stay apart from plain ones, so `ete` does not find `été`.

All commands are listed in the command palette. In the terminal, Ctrl+Shift+C and Ctrl+Shift+V copy and paste, Ctrl+Shift+W goes to the program instead of closing the editor's tabs, Shift+PageUp and Shift+PageDown scroll back, Ctrl+Tab and Ctrl+Shift+Tab switch between terminals, and Shift keeps the mouse for selecting when a program uses it. A command run from the palette acts where its shortcut would: Zoom In with the terminal focused zooms the terminal.

Links in the terminal open with Cmd+click on macOS and Ctrl+click on Linux and Windows, as in VS Code; a plain click still selects. Hovering a link underlines it, and its tooltip names the click. An `http://` or `https://` URL opens in the default browser, such as the `http://localhost:5173/` a dev server prints. The path of a file that exists opens in a tab: a name from `ls`, a relative or absolute path, or `~/...`, and `file:LINE` or `file:LINE:COL` from a compiler or `grep -n` opens at that place. Relative paths start in the shell's current folder on Linux and macOS, then in the project folder, where they also start on Windows. The click works in programs that take the mouse too.

Programs that turn on the kitty keyboard protocol, such as the Pi agent and fish 4, tell Shift+Enter, Alt+Enter and Ctrl+Enter apart from Enter, so Shift+Enter can start a new line in an agent's prompt instead of sending it. rhun reports those keys, Escape, and Ctrl or Alt with a character as `CSI` codes while a program asks for them (the protocol's first level); other programs get the usual bytes.

Zoom In, Zoom Out and Reset Zoom change the focused editor or terminal independently. On macOS use Command+Plus, Command+Minus and Command+0; on Linux and Windows use Ctrl+Plus, Ctrl+Minus and Ctrl+0. Settings > Terminal > Font size controls the terminal separately from Settings > Editor > Font size.

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

Choose **Delete** from the explorer context menu to remove a file or folder. The confirmation has **Cancel** and **Delete** buttons. Deleting a folder permanently removes its contents, including hidden files. Links are removed without deleting their targets.

Right-click a file or directory in the explorer and choose **Show in Finder** (macOS), **Show in Explorer** (Windows), or **Open in File Manager** (Linux). Finder and Explorer select the item in its parent folder. Linux opens the containing folder through `xdg-open`, using your desktop's default file manager. The command palette also has **Show File in System File Manager** for the active file.

Clicking the project name in the title bar opens the project menu: Open Folder…, Open File… and the folders of up to 9 recent sessions, newest first. Opening a folder turns the window to it: rhun remembers the open files, asks about unsaved ones, and brings back the folder's last session. The same happens to a folder opened from Finder or the Dock, or with `:e`. Running terminals keep running; new ones start in the new folder. Shift-click a recent folder to open it in a new window instead; this one keeps its project.

Open Folder and Open File show a browser in the palette. It starts in the project folder, and its field holds a path: the list shows what is in the folder before the last `/`, narrowed by what follows it.

- Enter goes into a folder or opens a file, Tab completes the name, and Backspace past a `/` goes up.
- A path can be typed or pasted, as in `/etc/` or `~/code/`. Hidden entries show once the name typed starts with a dot.
- Open Folder lists only folders, led by **Open** and the folder shown, then **Open … in a new window**, which leaves this window as it is (on macOS the new window has a Dock icon of its own). Ctrl+Enter opens the selected folder without going into it.

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

`commit_ai` accepts `off`, `claude`, `codex`, or `ollama`. **Git: Generate Commit Message**, **Git: Check AI Provider**, **Git: Download Local Model**, **Git: Delete Local Model**, and **Git: Cancel AI Operation** are also available in the command palette.

CLI references: [Codex noninteractive mode](https://learn.chatgpt.com/docs/non-interactive-mode), [Codex authentication](https://learn.chatgpt.com/docs/auth), [Claude Code CLI](https://code.claude.com/docs/en/cli-reference), and [Ollama](https://docs.ollama.com/quickstart).

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
[git]
enabled = false
[keys]
ctrl+shift+d = duplicate_line
alt+z = none
```

Key names are those of the command palette entries in snake case (see `src/app/keys.s`). `none` removes a binding.

### Themes

The theme follows the system's dark mode: `dark_theme` shows while the system is in dark mode and `light_theme` while it is in light mode, Rhun Dark and Rhun Light to start with. Pick them in Settings > Appearance, or with the theme picker (Ctrl+K), which saves the theme for the mode the system is in. Turn off **Follow system dark mode** (`follow_system = false`) to keep one theme, `theme`, whatever the system does; it starts as the theme on screen. **Toggle Light/Dark Theme** in the command palette then switches `theme` between the dark and the light one.

rhun reads the mode as VS Code does and switches as soon as the system does:

- macOS: System Settings > Appearance, Auto included.
- Windows: the app mode in Settings > Personalization > Colors. The title bar is dark with a dark theme.
- Linux: the XDG desktop portal's color scheme over D-Bus: GNOME, KDE Plasma, Cinnamon and COSMIC, and Sway, Hyprland and other window managers with xdg-desktop-portal-gtk (`gsettings set org.gnome.desktop.interface color-scheme prefer-dark`). Without a dark or light answer there the GTK theme decides: `gtk-application-prefer-dark-theme`, or a theme name with "dark" in it, from XSETTINGS (Xfce, MATE, LXDE, xsettingsd), the portal or `~/.config/gtk-3.0/settings.ini` (lxappearance, nwg-look). On X11 the window's `_GTK_THEME_VARIANT` tells the window manager whether the theme is dark.

When the system says nothing, the dark theme shows. A configuration from before 0.17.8 names one `theme`: it becomes the theme for its kind and for the mode the system is in, so the editor looks the same until you pick another.

Choose **Turbo Pascal** in the theme picker for a blue editor with yellow text, white keywords and the DOS terminal palette. To select it in the configuration file, set `dark_theme = turbo-pascal` under `[ui]` (or `theme`, with `follow_system = false`).

A theme is a `name.theme` file in `~/.config/rhun/themes/`. Colors not given are derived from `bg`, `fg` and `accent`, so a theme can be three lines. See `runtime/themes/` for all keys.

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

Commands: `key`, `type`, `click x y [right|middle|shift|ctrl]` (ctrl is Cmd+click on macOS), `move`, `down`, `up`, `up-down` (a release and the next press in one frame), `scroll dy [MODS]` (modifiers as a key combination names them: `ctrl`, `shift+alt`), `open`, `cmd`, `shot`, `wait`, `wait-git`, `wait-agents` (until session discovery finishes), `agents-more`, `print-agents-page`, `print-agents-runs` (discovery runs started so far), `print-agents` (sessions and an optional open session number), `wait-grep` (until find in files has read the project), `wait-term TEXT` (until the terminal shows TEXT), `wait-update`, `resize`, `print-doc`, `print-state`, `print-project`, `print-panels` (whether the explorer, the agents panel and the terminal are shown), `print-palette`, `print-menu`, `print-tip` (the tooltip on screen), `print-term`, `print-term-cell ROW COL` (the middle of that terminal cell), `print-link` (the terminal link under the pointer), `print-scroll` (the editor's horizontal scroll, its vertical one in 1/256 lines, the horizontal limit and the scrollbar's track), `scroll-x dx` (a sideways wheel), `print-git`, `print-gitlog`, `print-scm`, `print-update`, `print-frames`, `print-shape` (the mouse cursor's CUR_* value), `appearance dark|light|unknown` (the system's dark mode changes, as a platform reports it), `print-appearance` (that mode, `follow_system`, the three theme settings and the theme shown), `echo`, `quit`. A headless run takes the system's mode from `RHUN_APPEARANCE` (`dark` or `light`). `cmd` runs anything from the command palette by its snake case name.

## Extensions (planned)

Extensions will be separate programs, in any language, that talk to rhun over the control socket. rhun starts each one found in `~/.config/rhun/extensions/` and passes the socket path in `RHUN_SOCKET`. Two additions to the protocol cover most needs:

- `register name title [keys]` adds a command to the palette; invoking it sends `run name` back to the extension.
- `subscribe open save change cursor` streams events as lines (`saved /path/file.c`), so formatters, linters and language servers can run outside the editor.

An extension that crashes or hangs cannot take the editor with it.

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
