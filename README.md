# rhun

![rhun](assets/social/github@2x.png)

[![Join the Discord community](https://img.shields.io/badge/Discord-Join%20the%20community-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/Aj4drpFbWf)
[![Find rhun on Product Hunt](https://img.shields.io/badge/Product%20Hunt-Find%20rhun-DA552F?style=for-the-badge&logo=producthunt&logoColor=white)](https://www.producthunt.com/products/rhun)
[![Follow updates on X](https://img.shields.io/badge/X-FOLLOW%20UPDATES-000000?style=for-the-badge&logo=x&logoColor=white)](https://x.com/r13)

## Get rhun

On Linux (x86-64) or macOS (Apple silicon), run:

```sh
curl -fsSL https://github.com/vshvedov/rhun/releases/latest/download/install.sh | sh
```

Or use `wget`:

```sh
wget -qO- https://github.com/vshvedov/rhun/releases/latest/download/install.sh | sh
```

On Windows 10 (1809 or later) or Windows 11, download the installer in PowerShell:

```powershell
$rhunInstaller = Join-Path $env:TEMP ('rhun-install-' + [guid]::NewGuid() + '.ps1')
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/vshvedov/rhun/releases/latest/download/install.ps1' -OutFile $rhunInstaller -ErrorAction Stop
```

After the download succeeds, you can [inspect the installer source](https://github.com/vshvedov/rhun/blob/main/install.ps1). Run it in the same PowerShell window:

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File $rhunInstaller
```

The installer checks the release archive's SHA-256, installs for your user, and adds a Start menu shortcut and the `rhun` terminal command. Or [download the Windows ZIP](https://github.com/vshvedov/rhun/releases/latest), extract it, and open `rhun.exe`.

## Why rhun

When coding agents do more of the heavy lifting, you may not need everything that comes with Vim, Sublime, VS Code, or Zed. You need to read and edit code, run commands, find files, and check what changed.

`rhun` is perfect for such tasks: it is blazing fast, has a minimal memory and disk space footprint, and ships with everything you need:

- **Code editing:** Tabs, syntax highlighting, find and replace, and optional Vim mode.
- **Built-in terminal:** Run your shell, tools, and coding agents right beside the code.
- **Git:** Stage, commit, pull, and push; see changed files, read diffs, and browse commit history. Optionally draft commit messages with your Claude or Codex subscription, or a local Ollama model.
- **Fuzzy search:** Jump to a file or search across the whole project.
- **Agents panel:** See Claude Code, Codex, Grok Build, and OpenCode sessions as they work.

<p>
  <img src="assets/social/screenshot-dark.png" width="49%" alt="rhun, dark theme">
  <img src="assets/social/screenshot-light.png" width="49%" alt="rhun, light theme">
</p>

Pick from 40 light and dark themes, one for each mode: rhun switches with your system's dark mode. On Omarchy, choose **Follow Omarchy**, and rhun switches themes with your desktop.

Fast built-in terminal:

<p>
  <img src="assets/social/screenshot-terminal.png" width="49%" alt="Code and the built-in terminal in rhun">
  <img src="assets/social/screenshot-git.png" width="49%" alt="Git history and changed files in rhun">
</p>

[Usage, shortcuts, and configuration](docs/guide.md)

## Contribute

`rhun` welcomes new contributors. Pull requests are open to everyone: it doesn't matter whether a bug fix or a useful addition was created manually or using AI. Every fix matters.
Be reasonable, don't change the core functionality without starting [a discussion](https://github.com/vshvedov/rhun/discussions) first, and include a clear rationale for your PR.

As `rhun` doesn't use any telemetry (and will *never* use it), we rely on users to report bugs. Encountered a crash? Something's not right? Please file a [bug report](https://github.com/vshvedov/rhun/issues) or fix it yourself and submit a PR.

A great place to start a new topic is rhun's [Product Hunt forum](https://www.producthunt.com/p/rhun) or [Discord](https://discord.gg/Aj4drpFbWf). [My X](https://x.com/r13) is the place where you can read human-written updates.

[MIT license](LICENSE).

Built-in font: [SIL Open Font License](assets/fonts/LICENSE-Iosevka.md).
