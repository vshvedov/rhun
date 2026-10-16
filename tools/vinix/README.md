# Vinix experiment

This is an experimental native ARM64 ELF build. The X11 backend was tested on
Vinix `iso-2026-10-12-3` in QEMU on Apple silicon. The native window backend
requires a newer kernel and desktop with Vinix's C window API version 2.
It is not a release
target or a replacement for the existing Linux, macOS, and Windows builds.

`tools/arm64.py --elf` translates the shared assembly and uses ELF relocations.
Translated symbols have a `rhun_` prefix so they cannot collide with libc
functions that use a different calling convention. `runtime.s` bridges the
private x86 stack and preserves registers around C calls. `linux.c` adapts the
editor's Linux x86-64 syscall numbers and structure layouts to ARM64 through
musl. The string and division instruction helpers remain shared with the Mac
target. Both backends use the editor's existing software renderer.

## Build on macOS

Install LLVM and LLD. Obtain Vinix's ARM64 ISO from the
[official releases](https://github.com/vlang/vinix/releases).
The tested ISO contains musl and GCC 14.2.0. Extract its headers and static
libraries with macOS's `tar`:

```sh
mkdir -p build/vinix/sysroot
tar -xOf /path/to/vinix-arm64.iso boot/initramfs.tar |
  tar -xf - -C build/vinix/sysroot \
    ./usr/include ./usr/lib/libc.a \
    ./usr/lib/crt1.o ./usr/lib/crti.o ./usr/lib/crtn.o \
    ./usr/lib/gcc/aarch64-alpine-linux-musl/14.2.0/libgcc.a
python3 tools/build-vinix.py --sysroot "$PWD/build/vinix/sysroot" --test
```

Outputs are `build/vinix/rhun` and `build/vinix/vinix-abi-test`. They are static
ELF binaries. `--llvm DIR` or `LLVM_BIN` selects the LLVM binaries. The normal
Mac translator output and build are unchanged.

## Native desktop build

Build the SDK from a matching Vinix checkout. The SDK's build also needs the
full GCC runtime directory and `usr/lib/libc.so` pointing to its ARM64 musl
loader. See Vinix's [C window SDK instructions](https://github.com/vlang/vinix/blob/master/desktop/windowfb/capi/README.md).

```sh
# From the Vinix checkout, with a current host V compiler:
V=/path/to/v/v VINIX_AARCH64_SYSROOT=/path/to/sysroot \
  /path/to/v/v run desktop/tools/build-window-capi.v \
  --arch=arm64 --out=/path/to/window-sdk

# From this rhun worktree:
python3 tools/build-vinix.py --sysroot /path/to/sysroot \
  --window-sdk /path/to/window-sdk --test
```

Deploy the matching kernel and desktop together before running the result.
The desktop should expose `/run/vinix-session.<uid>/windows`. Vinix's
[framebuffer protocol](https://github.com/vlang/vinix/blob/master/desktop/FRAMEBUFFER.md)
also documents the socket overrides. The October 12 ISO alone lacks this
service. Omitting `--window-sdk` builds the previous X11 backend.

Clipboard sharing additionally requires the bundled compositor patch, applied
to Vinix commit `69d2faac9fc2f6516b1a3e1cdf0a115da39b779d` before building its desktop:

```sh
git -C /path/to/vinix apply \
  /path/to/rhun/tools/vinix/patches/0001-framebuffer-session-clipboard.patch
```

The patch records a framebuffer client's authenticated Unix peer PID and lets
it use the existing session clipboard broker after recent input in its focused
window. It keeps the existing user identity, focus, gesture expiry and app
clipboard permission checks. It adds a compositor regression test for those
conditions. The patch retains Vinix's GPL-2.0-or-later licensing. The window
SDK ABI remains version 2; this clipboard change requires only rebuilding and
deploying the desktop, not changing the kernel or window SDK.
While a framebuffer window has recent input, queued session actions are
polled at most once per 20 ms. Notifications and service state retain their
existing one-second refresh, and inactive windows do not enable fast polling.

File reloads additionally require the bundled kernel patch on that same Vinix
base. Apply it before building and deploying the kernel:

```sh
git -C /path/to/vinix apply \
  /path/to/rhun/tools/vinix/patches/0002-inotify-parent-events.patch
V=/path/to/v/v /path/to/v/v run /path/to/vinix/tests/inotify-route/run.v
```

Vinix previously sent direct-write events only to watches on the file itself.
The patch also sends file activity to a watch on its containing directory,
with the child's name. It preserves direct watches and one-shot handling,
avoids duplicating named namespace events, and respects `IN_EXCL_UNLINK`.
This patch also retains Vinix's GPL-2.0-or-later licensing.

The native build checks contents after a file notification because Vinix ext2
timestamps have whole-second precision. A saved-byte fingerprint distinguishes
same-size edits from late notifications of rhun's own saves, including when
there are new unsaved edits. An empty reload is checked again after 100 ms
before replacing nonempty text, to avoid losing the caret during a brief
in-place truncation. A file left genuinely empty still reloads normally.
Settings use a content fingerprint too, so quick external config changes apply
even when their timestamps match the previous read or save.

`window.s` bridges platform calls and editor callbacks while retaining the
translated stack across nested C calls. `window.c` integrates the native
event FD with rhun's poll loop, draws into XRGB8888 buffers, waits for frame
acknowledgements, and reacquires buffers on resize. `keyboard.c` decodes Kitty
keyboard input, including modifiers, Unicode text, repeats and releases.
Vinix owns the title bar, movement, resizing, minimization and maximization.

Install the native binary as `/root/rhun-vinix/rhun-native` and copy
`run-native.sh` to `/usr/local/bin/rhun-vinix-native`, then make both executable:

```sh
rhun-vinix-native /path/to/project
```

The launcher keeps preferences under `/root/rhun-vinix/home`. `RHUN_VINIX_DIR`
and `RHUN_VINIX_BIN` override those paths. The native compositor keeps running
and other applications remain usable. `clipboard.c` shares plain text with
native apps through `/run/vinix-session.<uid>/broker`, using
`VINIX_SESSION_RUNTIME` when set. It publishes explicit copy offers and
requests single-use paste tokens, then reads the authorized data. Requests
are asynchronous and bounded to 64 KiB of text without NUL bytes. Unsupported
data, denied access, missing services and timeouts show a toast; there is no
fallback to a stale private clipboard. Focus loss, new typing or a mouse press
cancel a pending paste. Rich clipboard formats and sharing with the Mac host
are outside this experiment. The window API does not provide cursor-shape
requests. Vinix removes a window immediately on title-bar close,
so when rhun needs an unsaved-file confirmation it recreates the window to
keep that dialog available. EOF and sends racing with the close follow the
same confirmation path. Rhun's own window-management menu requests are not
wired to the window API; use the native title bar.

The test VM uses a separate disk copy and a custom 1920 by 1080 ISO based on
the original userland, with kernel and desktop from Vinix commit
`69d2faac9fc2f6516b1a3e1cdf0a115da39b779d`. The kernel was built with V commit
`f6358ecff9cffbf2d8b03e6a09269aac7707e26c`; the desktop and SDK used
`b3bebd3`. This is a local experiment, not an official Vinix release image.
The test desktop includes the compositor patch, and the current kernel includes
the directory notification patch. Earlier native images lack this kernel fix.
Use 8 GiB of VM memory for the desktop, rhun and native test applications.

## Full-screen X11 fallback

Copy `build/vinix/rhun` and `tools/vinix/run.py` into `/root/rhun-vinix` in the
VM. Make the executable runnable, then launch a project from Vinix's terminal:

```sh
chmod +x /root/rhun-vinix/rhun
python3 /root/rhun-vinix/run.py /path/to/project
```

Additional arguments name files to open. `RHUN_VINIX_DIR` can select another
installation folder. Run one test session at a time.

The launcher temporarily pauses the native compositor while Vinix's Xorg and
input bridge own the display. It fits and focuses rhun at the framebuffer's
resolution. On exit it restores the saved desktop pixels and resumes the
compositor. Preferences use a separate `home` directory beside the binary.
`session.log` records X11 and editor output.

Fresh X11 display numbers and control socket names avoid reopening errors
observed in this Vinix image. This is a full-screen X11 session, not a window
integrated into the native compositor. Wayland,
clipboard exchange with native applications, and release installation and
updates have not been qualified.

## Validation

The guest passed `vinix-abi-test` for writev, poll, pread, the x86 stat buffer,
and negative errno returns. The existing editing control script passed in
headless mode. The graphical run exercised mouse and keyboard input, saving
with Ctrl+S, resizing to 1920 by 1080, and a real zsh command in the terminal.
The Git panel detected the test repository and its staged files. Closing the
launcher restored the native desktop, and reopening it succeeded.
Eleven existing Mac unit suites also matched their expected output: CPU,
memmove, fill, documents, columns, syntax, terminal, diff, clipping, text areas,
and themes.

The native backend's host tests exercise fragmented Kitty records, Unicode,
shortcuts, releases, frame ownership across resize, queued-write poll interests,
paste cancellation and unsaved-close window recreation. The broker client test
uses real Unix sockets to check fragmented records, Unicode and multiline
text, the 64 KiB limit, denied requests, malformed records, cancellation and
deadlines. Run them with:

```sh
clang -Wall -Wextra -Werror -fsanitize=address,undefined \
  tools/vinix/keyboard.c tests/vinix-keyboard.c -o /tmp/vinix-keyboard-test
/tmp/vinix-keyboard-test
clang -Wall -Wextra -Werror -fsanitize=address,undefined \
  -I /path/to/window-sdk/include tools/vinix/window.c tools/vinix/keyboard.c \
  tests/vinix-window.c -o /tmp/vinix-window-test
/tmp/vinix-window-test
clang -Wall -Wextra -Werror -fsanitize=address,undefined \
  tools/vinix/clipboard.c tests/vinix-clipboard.c -o /tmp/vinix-clipboard-test
/tmp/vinix-clipboard-test
```

The upstream Vinix C API qualification also passed for its shared and static
libraries, including split records, resize during a pending frame and errors.

In the updated VM, the native backend passed real mouse/keyboard editing and
Ctrl+S, native dragging, resizing, maximizing/restoring, minimizing/restoring,
and close/reopen. A framebuffer dump after maximization confirmed a 1920 by
1000 content buffer. The terminal executed a shell expression and the Git
panel listed staged files. Closing a modified document presented its save
confirmation in a recreated window; cancelling preserved the edit, and undo
returned it to the saved contents. The native service and other desktop apps
stayed running throughout. The syscall ABI test and headless editing script
also passed on the updated kernel.

Clipboard qualification used real Ctrl+A/C/V/S input in rhun and Vinix's
Text Editor. Copying from rhun into the native editor preserved UTF-8 accents,
an emoji, tabs and multiple lines exactly in the saved file. Native editing
then added distinct text, copied it back into rhun, and saved it. The bytes
matched apart from rhun's existing final-newline-on-save setting. This test
used the patched desktop on an ARM64 QEMU VM with 8 GiB of memory.

Core editor qualification runs in the guest without agent CLIs or network
provider requests. Copy this worktree's `tests` directory, `assets/fonts`,
`src/app/keys.s` and `src/app/config.s` to the guest with their relative paths
intact, then run:

```sh
RHUN_TEST_EXE=/root/rhun-vinix/rhun-native python3 tests/vinix-editor.py
RHUN_TEST_EXE=/root/rhun-vinix/rhun-native python3 tests/vinix-editor.py --native
```

The first mode checks file reloads and conflicts, symlinks, directory recreation,
session restoration, undo/redo, live settings, search/replace and Git operations
in the guest's headless renderer. The second opens temporary native windows to
check reloads, saves, conflicts, Unicode editing and a real terminal command.
Both include same-size, same-timestamp edits, genuinely empty files and late
save notifications, plus live Vim settings changes with restored timestamps.
Projects, configuration and state are temporary; the tests leave the user's
editing files alone.

After merging main at `f2c0ca5` (0.17.15), all 48 headless guest checks and 15
native-window checks passed. These cover reloads, conflicts, Unicode saving
and a real shell command. The deterministic timestamp checks pause the editor
while writing and restoring the old timestamp. The settings regression failed
before the config fingerprint fix and passed afterward in both modes. On
macOS, 45 core checks passed and three Vinix timestamp checks were skipped;
15 unit suites matched their expected output, and all four terminal panel
checks passed. Native and X11 static ARM64 builds succeeded, and the keyboard,
window and clipboard host fixtures passed AddressSanitizer and
UndefinedBehaviorSanitizer checks.

Another 45 guest checks passed for pinned tabs, settings search, Git trust,
terminal fonts and terminal panels. They require `stty` on `PATH`; the tested
image includes the BusyBox applet but needs a `stty` symlink to `/bin/busybox`.
The terminal panel fixture also finds Python on `PATH` when Vinix's Python
leaves `sys.executable` empty. Run these checks with:

```sh
for name in tab-pin settings-search git-trust terminal-font terminal-panel; do
  RHUN_TEST_EXE=/root/rhun-vinix/rhun-native python3 "tests/$name.py" || exit
done
```

This does not establish full feature parity or production readiness. Keep
this work isolated until the guest compatibility and desktop integration have
been tested more broadly.
