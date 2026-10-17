# Install from GitHub on Windows, for src/app/extinstall.s: the steps of its POSIX job, with the
# curl.exe and tar.exe Windows 10 1803 and later ship. The inputs come in RHUN_EI_OWNER,
# RHUN_EI_NAME, RHUN_EI_TARGET, RHUN_EI_ROOT and RHUN_EI_BASE (never through the command line); the
# last output line is "ok DIR", the unpacked extension's folder, or why it failed.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
# native programs report on their own error stream; Stop would turn that into an exception
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
# started from PowerShell 7 (a CI shell, a terminal), Windows PowerShell inherits 7's module path
# and cannot load its own modules; only the machine's own module folders, then
$env:PSModulePath = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
$owner = $env:RHUN_EI_OWNER
$name = $env:RHUN_EI_NAME
$target = $env:RHUN_EI_TARGET
$root = $env:RHUN_EI_ROOT
$base = $env:RHUN_EI_BASE
$tmp = $null
function Fail([string]$why) {
    if ($tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Output $why
    exit 1
}
try { New-Item -ItemType Directory -Force -Path $root -ErrorAction Stop | Out-Null } catch { Fail "cannot create $root" }
$folder = Join-Path $root ('.install-' + [IO.Path]::GetRandomFileName().Replace('.', ''))
try { New-Item -ItemType Directory -Path $folder -ErrorAction Stop | Out-Null } catch { Fail "cannot create a folder in $root" }
$tmp = $folder
$system = Join-Path $env:SystemRoot 'System32'
$curl = Join-Path $system 'curl.exe'
$tar = Join-Path $system 'tar.exe'
if (-not (Test-Path -LiteralPath $curl)) { Fail 'Windows has no curl.exe (it comes with Windows 10 1803 and later)' }
if (-not (Test-Path -LiteralPath $tar)) { Fail 'Windows has no tar.exe (it comes with Windows 10 1803 and later)' }
$url = "$base/$owner/$name/releases/latest/download"
$asset = "$name-$target.tar.gz"
$archive = Join-Path $tmp 'a.tgz'
$sums = Join-Path $tmp 'sums'
& $curl -fsL --max-time 120 --max-filesize 67108864 -o $archive "$url/$asset" 2>$null
if ($LASTEXITCODE -ne 0) { Fail "no release of $owner/$name for $target" }
& $curl -fsL --max-time 120 -o $sums "$url/sha256sums.txt" 2>$null
if ($LASTEXITCODE -ne 0) { Fail 'the release has no sha256sums.txt' }
$want = ''
foreach ($line in Get-Content -LiteralPath $sums) {
    $fields = $line.Trim() -split '\s+', 2
    if ($fields.Count -eq 2 -and ($fields[1] -eq $asset -or $fields[1] -eq "*$asset")) {
        $want = $fields[0].ToLowerInvariant()
    }
}
# .NET directly: no module to load
$have = ''
try {
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($archive)
    try { $have = -join ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) } finally { $stream.Close() }
} catch { Fail 'the download cannot be read' }
if (-not $want) { Fail "the release's sha256sums.txt does not list $asset" }
if ($want -ne $have) { Fail 'the download does not match its checksum' }
# plain files and folders only: a link, hard link or device in the listing ends it
$listing = & $tar -tvzf $archive 2>$null
if ($LASTEXITCODE -ne 0) { Fail 'the archive cannot be read' }
foreach ($line in $listing) { if ($line -notmatch '^[-d]') { Fail 'the archive holds links or devices' } }
$entries = & $tar -tzf $archive 2>$null
foreach ($entry in $entries) {
    if ($entry -match '^([/\\]|[A-Za-z]:)' -or $entry -match '(^|[/\\])\.\.([/\\]|$)') {
        Fail 'the archive reaches outside itself'
    }
}
$unpacked = Join-Path $tmp 'x'
New-Item -ItemType Directory -Path $unpacked | Out-Null
& $tar -xzf $archive -C $unpacked 2>$null
if ($LASTEXITCODE -ne 0) { Fail 'the archive cannot be unpacked' }
if (-not (Test-Path -LiteralPath (Join-Path $unpacked 'extension.ini') -PathType Leaf)) { Fail 'the archive has no extension.ini' }
Remove-Item -LiteralPath $archive, $sums -Force
Write-Output "ok $tmp"
