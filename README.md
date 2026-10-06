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

On Windows 10 (1809 or later) or Windows 11:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing https://github.com/vshvedov/rhun/releases/latest/download/install.ps1).Content))"
```

## Why rhun

When coding agents do more of the heavy lifting, you may not need everything that comes with Vim, Sublime, VS Code, or Zed. You need to read and edit code, run commands, find files, and check what changed.

`rhun` is perfect for such tasks: it is blazing fast, has a minimal memory and disk space footprint, and ships with everything you need:

- **Code editing:** Tabs, syntax highlighting, find and replace, and optional Vim mode.
- **Built-in terminal:** Run your shell, tools, and coding agents right beside the code.
- **Git:** Stage, commit, pull, and push; see changed files, read diffs, and browse commit history. Optionally draft commit messages with your Claude or Codex subscription, or a local Ollama model.
- **Fuzzy search:** Jump to a file or search across the whole project.
- **Agents panel:** See Claude Code and Codex sessions as they work.

<p>
  <img src="assets/social/screenshot-dark.png" width="49%" alt="rhun, dark theme">
  <img src="assets/social/screenshot-light.png" width="49%" alt="rhun, light theme">
</p>

Pick from 40 light and dark themes. Set a separate theme for each appearance, or choose System (Auto) to follow your OS. On Omarchy, choose **Follow Omarchy** to track its theme.

Fast built-in terminal:

<p>
  <img src="assets/social/screenshot-terminal.png" width="49%" alt="Code and the built-in terminal in rhun">
  <img src="assets/social/screenshot-git.png" width="49%" alt="Git history and changed files in rhun">
</p>

[Usage, shortcuts, and configuration](docs/guide.md)

## Contribute

`rhun` welcomes new contributors. Pull requests are open to everyone: it doesn't matter whether a bug fix or a useful addition was created manually or using AI. Every fix matters.
Be reasonable, don't change the core functionality, and include a clear rationale for your PR.

As `rhun` doesn't use any telemetry (and will *never* use it), we rely on users to report bugs. Encountered a crash? Something's not right? Please file a [bug report](https://github.com/vshvedov/rhun/issues) or fix it yourself and submit a PR.

A great place to start a new topic is rhun's [Product Hunt forum](https://www.producthunt.com/p/rhun). It's also the place where you can read human-written updates.

[MIT license](LICENSE).

Built-in font: [SIL Open Font License](assets/fonts/LICENSE-Iosevka.md).
