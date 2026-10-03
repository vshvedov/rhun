# Windows Defender investigation

[Issue 28](https://github.com/vshvedov/rhun/issues/28) reports that Defender quarantines
the official v0.16.6 `rhun.com` as `Trojan:Win32/Wacatac.C!ml`. The ZIP hash matches
the published checksum. This establishes which release was downloaded, not whether
the detection is correct. No Windows build is considered verified clean solely
because it matches source or passes functional tests.

Normal Windows builds retain the existing compressed, base64-encoded PowerShell
helpers and `-EncodedCommand`. The readable `-Command` variant is diagnostic only.
In the initial Server 2022 comparison, both forms scanned clean, but running the
readable AI helper triggered `Trojan:Win32/ClickFix.PM!MTB` on its command line and
`Behavior:Win32/Execution.A!ml` on the editor. The encoded variant passed the same
runtime tests. This rules out publishing the readable-command experiment as a
fix; it does not explain the original Windows 11 detection.

## Automated comparison

The `windows-defender` workflow compares the original release with five builds of
the same checkout and pinned toolchain:

| Mode | AI helper | Update helper | Execution |
| --- | --- | --- | --- |
| `encoded` | Included | Included | Previous compressed encoding |
| `no-ai` | Disabled | Included | Previous compressed encoding |
| `no-updater` | Included | Disabled | Previous compressed encoding |
| `none` | Disabled | Disabled | Encoded error messages only |
| `plain` | Included | Included | Readable script text |

Disabled helpers exit with an error if called. These diagnostic builds are not
releases. The original release remains the reference sample because rebuilt PE
files, metadata, and file reputation can affect detections independently of helper
contents. Each rebuilt binary is also rebuilt a second time and compared by hash.

GitHub-hosted Windows images disable Defender and exclude their drives. The scan
tool restores protection only when explicitly requested on a disposable
GitHub-hosted runner. Regular and release Windows workflows scan both executables
and the packaged ZIP. A failed, skipped, or unavailable scan stops publication. Definition updates retry
transient failures; the archive scan reuses the definitions already updated for
that job. Signatures older than 24 hours are rejected.
Comparison jobs record all outcomes, including detections, without declaring them
clean. A successful comparison job means evidence was collected, not that its
sample is safe. The original, encoded, and readable variants also run the native
regression suite with Defender enabled. Runtime outcomes and detections are
recorded separately from static scan verdicts. Their artifacts include hashes, engine and signature versions, preferences,
scan output, and Defender events. Windows Server results do not establish the
behavior of a Windows 11 download or installation.

## Check on Windows 11

In an elevated PowerShell window with current Defender protection enabled, run
this from the source checkout, substituting the paths to the downloaded samples:

```powershell
tools/scan-windows.ps1 -Path C:\samples\rhun.exe,C:\samples\rhun.com,C:\samples\rhun-0.16.6-windows-x86_64.zip -ReportDir C:\samples\defender-report
```

The tool does not change a personal machine's protection settings. Custom scans
use `-DisableRemediation`, which Microsoft documents as including archives and
ignoring file exclusions. Real-time protection remains enabled and can still
quarantine a file. Missing files and skipped scans are recorded as unverified.
English scan output is required to produce a clean verdict; other output remains
unverified. After static scans, separately test the browser download, extraction,
launch, installation, and update paths on a disposable Windows 11 machine. Keep
the OS build and the Defender event logs with those results.

Do not disable Defender or add exclusions to install a detected build.

## Microsoft analysis

Submit the original affected `rhun.com`, rather than a modified diagnostic build,
through [Microsoft Security Intelligence](https://www.microsoft.com/en-us/wdsi/filesubmission)
as a software developer. Include the issue, release URL, OS build, definition
version, detection name, and reproducibility evidence. Ask Microsoft to determine
whether the detection is incorrect; wait for the final determination and record
the submission ID before describing the issue as a confirmed false positive.

The original v0.16.6 `rhun.com` SHA-256 is
`b6dff99386907acd7b4f335aa0d894fe8ec012caee7a1690750877c0af3f77ff`.
The original ZIP SHA-256 is
`ca772914f7116fb4f6b469b301559616c6aa204aab656d00bab349d0949d4c5c`.

[Microsoft's scan command reference](https://learn.microsoft.com/en-us/defender-endpoint/command-line-arguments-microsoft-defender-antivirus)
documents scan options and return codes.
[The developer FAQ](https://learn.microsoft.com/en-us/defender-xdr/developer-faq)
describes detection disputes and code signing. Signing can help establish a
publisher's identity; it does not guarantee a clean antivirus verdict.
