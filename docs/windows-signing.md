# Windows signing, Defender and winget

[Issue 28](https://github.com/vshvedov/rhun/issues/28): Microsoft Defender on Windows 11 has
quarantined official `rhun.com` downloads as `Trojan:Win32/Wacatac.C!ml` (0.16.6) and
`Trojan:Win32/Bearfoos.A!ml` (0.16.2), and it happened again with 0.18.4. `!ml` names are verdicts
from Defender's machine-learning models, which weigh a file's reputation: an unsigned executable
that few people have run scores badly whatever it contains, and every release is a new file.

## What was measured

On 2026-10-26 a probe workflow ran real Defender (platform 4.18.26090.9, signatures
1.461.217.0, cloud protection and sample submission at the Windows 11 defaults) on Windows Server
2022 and 2025. It scanned the official 0.16.6, 0.17.9 and 0.18.4 ZIPs, their files, and builds of
0.19.0 with and without the embedded PowerShell helpers, with plain-text helpers, with version
information and with a smaller committed stack. It also started each `rhun.com` with a Mark of the
Web. Every file was clean and every run completed, the 0.16.6 `rhun.com` that a user had
quarantined included. Hosted runners cannot reproduce these detections, so a CI scan cannot stop
them from shipping. Reputation is what has to change: the signature below, and the file
submissions after it.

## Signing with SignPath Foundation

SignPath Foundation signs open source projects for free. Its certificate carries the foundation's
name and a reputation of its own across the projects it signs. The release workflow signs
`rhun.exe` and `rhun.com` once the repository variable `SIGNPATH_ORGANIZATION_ID` is set; until
then it releases unsigned files as before. Signing sits after the native tests, so the installer
and updater tests and the ZIP all use the signed files. Each request waits up to four hours for a
person to approve it in SignPath.

Setup, once:

1. Apply at [signpath.org/apply](https://signpath.org/apply). The terms require MFA on GitHub
   and SignPath, the [code signing policy](https://rhun.app/code-signing/) page (source in
   `site/docs/code-signing.html`), and manual approval of every release.
2. In SignPath, once accepted: add the predefined GitHub.com trusted build system and link it to
   the project, and install the SignPath GitHub App on `vshvedov/rhun`. Create the project
   `rhun`, the signing policy `release-signing` (restricted to tags `v*`), and the artifact
   configuration `windows-executables` with the contents of `.signpath/windows-executables.xml`.
   It refuses files whose product name is not `rhun` or whose product version is not the
   release's `VERSION`.
3. In the repository's Actions settings: the secret `SIGNPATH_API_TOKEN` (a SignPath CI user's API
   token with submitter rights) and the variable `SIGNPATH_ORGANIZATION_ID`.

Before enabling production signing, run **SignPath test signing** manually in GitHub Actions,
with the organization ID and the CI token secret in place. It uses `test-signing` and the ZIP
artifact configuration above without publishing any files. Its self-signed certificate is for
setup verification only. After SignPath reviews the trusted-build setup and imports the production
certificate, set `SIGNPATH_ORGANIZATION_ID` to enable signing in the release workflow.

The version resource that `tools/build-windows.py` adds to both executables supplies that product
name and version. Explorer and Defender's reports show it too.

## winget

After publishing a release without a dash in its version, the release workflow's `winget` job
writes the manifests of `rhun.rhun` (`tools/winget-manifests.py`, from the published ZIP) and opens
a pull request to [microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs) with
[Komac](https://github.com/russellbanks/Komac). Microsoft's pipeline validates it, installs it and
scans it with Defender before it merges, which is one more look by Microsoft at each release.
The first version also waits for a moderator. Without the secret the job only says so.

winget installs the ZIP as a portable package and puts its `rhun-VERSION` folder on PATH
(`ArchiveBinariesDependOnPath`): `rhun.com` starts `rhun.exe` from its own folder, which a
symlink in winget's Links folder would hide. A rhun under a `WinGet/Packages` folder offers updates
but leaves installing them to `winget upgrade`. `tests/winget-install.py` installs the build with
real winget in the Windows workflow.

Setup, once: fork microsoft/winget-pkgs to your account, and add the secret `WINGET_TOKEN`, a
classic personal access token of that account with the `public_repo` scope.

## Each release

1. Approve the signing request in SignPath when the release workflow waits for it.
2. Follow the winget pull request the release opened until it merges; a failed validation is
   labelled on it.
3. Submit the new `rhun.com` and `rhun.exe` at
   [Microsoft Security Intelligence](https://www.microsoft.com/en-us/wdsi/filesubmission) as a
   software developer, with "incorrect detection" if someone has reported one. Note the
   submission ID in the issue. Microsoft's verdict also clears the file for other Defender users.
4. When a user reports a detection, ask for the detection name, the Defender security
   intelligence version (`Get-MpComputerStatus`) and the file's SHA-256. Compare the hash with the
   release's before anything else.

The SHA-256 of the 0.16.6 `rhun.com` that Defender quarantined is
`b6dff99386907acd7b4f335aa0d894fe8ec012caee7a1690750877c0af3f77ff`.
