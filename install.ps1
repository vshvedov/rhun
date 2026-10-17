# Install or remove rhun for the current Windows user. Close rhun before updating.
[CmdletBinding()]
param(
    [string]$Version,
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\rhun'),
    [string]$ReleasesUrl = 'https://github.com/vshvedov/rhun/releases',
    [switch]$NoModifyPath,
    [switch]$NoShortcut,
    [switch]$MakeDefault,
    [switch]$NoMakeDefault,
    [switch]$NoFileAssociations,
    [switch]$NoUrlScheme,
    [switch]$ConfigureFiles,
    [switch]$Uninstall,
    # Internal updater modes. Preparation never changes a running installation.
    [switch]$PrepareUpdate,
    [switch]$ApplyUpdate,
    [switch]$DiscardUpdate,
    [string]$UpdateStage,
    [int]$WaitPid
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitOperatingSystem) {
    throw 'rhun requires 64-bit Windows 10 version 1809 or later.'
}
if ([Environment]::OSVersion.Version.Build -lt 17763) {
    throw 'rhun requires Windows 10 version 1809 or later.'
}
$InstallDir = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\', '/')
$knownFiles = @('rhun.exe', 'rhun.com', 'LICENSE', 'install.ps1', '.rhun-install')
$shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'rhun.lnk'

if ($MakeDefault -and ($NoMakeDefault -or $NoFileAssociations)) { throw 'Conflicting default editor options.' }
if ($MakeDefault -and -not $ConfigureFiles) {
    throw 'MakeDefault requires ConfigureFiles. Install rhun first, then run the printed command.'
}
if ($ConfigureFiles -and ($Uninstall -or $PrepareUpdate -or $ApplyUpdate -or $DiscardUpdate)) {
    throw 'ConfigureFiles cannot be combined with uninstall or update modes.'
}

# BEGIN FILE ASSOCIATION FUNCTIONS
$associationRoot = 'HKCU:\Software'
# BEGIN TEXT EXTENSIONS
$textExtensions = @(
    'ada', 'adb', 'adoc', 'ads', 'applescript', 'asciidoc', 'asm', 'astro', 'atom', 'awk',
    'bash', 'bat', 'bazel', 'bib', 'bzl', 'c', 'capnp', 'cbl', 'cc', 'cfg',
    'cjs', 'cl', 'clj', 'cljc', 'cljs', 'cls', 'cmake', 'cmd', 'cob', 'cobol',
    'comp', 'conf', 'cpp', 'cppm', 'cpy', 'cr', 'cron', 'crontab', 'cs', 'cshtml',
    'csproj', 'css', 'csx', 'cts', 'cu', 'cue', 'cuh', 'cxx', 'd', 'dart',
    'ddl', 'desktop', 'dhall', 'di', 'diff', 'djhtml', 'dockerfile', 'dot', 'dpk', 'dpr',
    'dtx', 'ebuild', 'editorconfig', 'edn', 'ejs', 'el', 'elm', 'env', 'erb', 'erl',
    'escript', 'ex', 'exs', 'f', 'f03', 'f08', 'f77', 'f90', 'f95', 'fish',
    'fnl', 'for', 'frag', 'fs', 'fsi', 'fsproj', 'fsscript', 'fsx', 'gemspec', 'geojson',
    'geom', 'gleam', 'glsl', 'go', 'gql', 'gradle', 'graphql', 'groovy', 'gv', 'gvy',
    'h', 'haml', 'handlebars', 'hbs', 'hcl', 'hh', 'hlsl', 'hpp', 'hrl', 'hs',
    'htm', 'html', 'http', 'hx', 'hxx', 'idr', 'inc', 'ini', 'ipp', 'itcl',
    'iuml', 'ixx', 'j2', 'jade', 'janet', 'java', 'jinja', 'jinja2', 'jl', 'js',
    'json', 'json5', 'jsonc', 'jsonl', 'jsonnet', 'jsx', 'just', 'kdl', 'ksh', 'kt',
    'kts', 'lean', 'less', 'lhs', 'libsonnet', 'lidr', 'liquid', 'lisp', 'log', 'lpr',
    'ltx', 'lua', 'm', 'mak', 'markdown', 'md', 'mdx', 'mermaid', 'metal', 'mjs',
    'mk', 'ml', 'mli', 'mll', 'mly', 'mm', 'mmd', 'mojo', 'mount', 'mts',
    'mustache', 'nasm', 'ndjson', 'nginx', 'nim', 'nimble', 'nims', 'ninja', 'nix', 'njk',
    'nomad', 'nunjucks', 'odin', 'org', 'p6', 'pas', 'patch', 'php', 'phtml', 'pkl',
    'pl', 'pl6', 'plantuml', 'plist', 'pm', 'pm6', 'pp', 'prisma', 'prolog', 'properties',
    'props', 'proto', 'ps1', 'psd1', 'psm1', 'psql', 'pu', 'pug', 'puml', 'purs',
    'py', 'pyi', 'pyw', 'r', 'rake', 'raku', 'rakumod', 'rakutest', 'razor', 'rb',
    'rego', 'rest', 'rhtml', 'rkt', 'rmd', 'rockspec', 'ron', 'rs', 'rss', 'rst',
    's', 'sass', 'sbt', 'sc', 'scala', 'scm', 'scss', 'service', 'sh', 'slim',
    'socket', 'sol', 'sql', 'ss', 'star', 'sty', 'sv', 'svelte', 'svg', 'svh',
    'swift', 'syn', 't', 'target', 'targets', 'tcl', 'tesc', 'tese', 'tex', 'text',
    'tf', 'tfvars', 'theme', 'thrift', 'timer', 'tk', 'toml', 'tpp', 'ts', 'tsx',
    'twig', 'txt', 'typ', 'v', 'vala', 'vapi', 'vb', 'vbs', 'vcxproj', 'vert',
    'vh', 'vhd', 'vhdl', 'vim', 'vsh', 'vue', 'webmanifest', 'wgsl', 'wsdl', 'xaml',
    'xhtml', 'xml', 'xsd', 'xsl', 'xslt', 'yaml', 'yml', 'zig', 'zon', 'zsh'
)
# END TEXT EXTENSIONS
$imageExtensions = @('png', 'jpg', 'jpeg', 'gif', 'bmp', 'ico', 'cur', 'qoi', 'pbm', 'pgm', 'ppm', 'pnm', 'tga')

function Set-AssociationValue([string]$Key, [string]$Name, [string]$Value) {
    if (-not (Test-Path -LiteralPath $Key)) { New-Item -Path $Key -Force | Out-Null }
    New-ItemProperty -LiteralPath $Key -Name $Name -Value $Value -PropertyType String -Force | Out-Null
}

function Notify-FileAssociations {
    if (-not ('Rhun.ShellAssociations' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace Rhun {
    public static class ShellAssociations {
        [DllImport("shell32.dll")]
        public static extern void SHChangeNotify(uint eventId, uint flags, IntPtr item1, IntPtr item2);
    }
}
"@
    }
    [Rhun.ShellAssociations]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
}

function Register-FileAssociations {
    if ($NoFileAssociations) { return }
    $exe = Join-Path $InstallDir 'rhun.exe'
    $capabilities = "$associationRoot\rhun\Capabilities"
    Set-AssociationValue $capabilities 'ApplicationName' 'rhun'
    Set-AssociationValue $capabilities 'ApplicationDescription' 'Edit text, source and configuration files; view images.'
    Set-AssociationValue $capabilities 'ApplicationIcon' ('"' + $exe + '",0')
    Set-AssociationValue $capabilities 'InstallDir' $InstallDir
    foreach ($kind in @('Text', 'Image')) {
        $progId = 'rhun.' + $kind
        $key = "$associationRoot\Classes\$progId"
        $description = if ($kind -eq 'Text') { 'rhun text document' } else { 'rhun image' }
        Set-AssociationValue $key '(default)' $description
        Set-AssociationValue "$key\DefaultIcon" '(default)' ('"' + $exe + '",0')
        Set-AssociationValue "$key\shell\open\command" '(default)' ('"' + $exe + '" "%1"')
        $extensions = if ($kind -eq 'Text') { $textExtensions } else { $imageExtensions }
        foreach ($extension in $extensions) {
            Set-AssociationValue "$associationRoot\Classes\.$extension\OpenWithProgids" $progId ''
            Set-AssociationValue "$capabilities\FileAssociations" ('.' + $extension) $progId
        }
    }
    Set-AssociationValue "$associationRoot\RegisteredApplications" 'rhun' 'Software\rhun\Capabilities'
    Notify-FileAssociations
}

function Remove-FileAssociations {
    if ($NoFileAssociations) { return }
    $capabilities = "$associationRoot\rhun\Capabilities"
    if (-not (Test-Path -LiteralPath $capabilities)) { return }
    $owner = Get-ItemPropertyValue -LiteralPath $capabilities -Name 'InstallDir' -ErrorAction SilentlyContinue
    if ($owner -ine $InstallDir) { return } # Another installation owns the current registration.
    foreach ($extension in @($textExtensions) + @($imageExtensions)) {
        $key = "$associationRoot\Classes\.$extension\OpenWithProgids"
        if (Test-Path -LiteralPath $key) {
            foreach ($progId in @('rhun.Text', 'rhun.Image')) {
                Remove-ItemProperty -LiteralPath $key -Name $progId -ErrorAction SilentlyContinue
            }
        }
    }
    foreach ($progId in @('rhun.Text', 'rhun.Image')) {
        $key = "$associationRoot\Classes\$progId"
        if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force }
    }
    Remove-Item -LiteralPath $capabilities -Recurse -Force
    Remove-ItemProperty -LiteralPath "$associationRoot\RegisteredApplications" -Name 'rhun' -ErrorAction SilentlyContinue
    Notify-FileAssociations
}

# rhun://file/ links open in rhun.exe, after -- so that a quote in a link cannot start an option. The
# key names this installation's rhun.exe, which Remove-UrlScheme checks, so another installation's
# registration stays. -NoUrlScheme removes this installation's earlier registration.
function Register-UrlScheme {
    if ($NoUrlScheme) { Remove-UrlScheme; return }
    $exe = Join-Path $InstallDir 'rhun.exe'
    $key = "$associationRoot\Classes\rhun"
    Set-AssociationValue $key '(default)' 'URL:rhun file link'
    Set-AssociationValue $key 'URL Protocol' ''
    Set-AssociationValue "$key\DefaultIcon" '(default)' ('"' + $exe + '",0')
    Set-AssociationValue "$key\shell\open\command" '(default)' ('"' + $exe + '" -- "%1"')
}

function Remove-UrlScheme {
    $key = "$associationRoot\Classes\rhun"
    if (-not (Test-Path -LiteralPath "$key\shell\open\command")) { return }
    $command = Get-ItemPropertyValue -LiteralPath "$key\shell\open\command" -Name '(default)' -ErrorAction SilentlyContinue
    # this installation's, also as registered before -- came in
    $exe = '"' + (Join-Path $InstallDir 'rhun.exe') + '"'
    if ($command -ine ($exe + ' -- "%1"') -and $command -ine ($exe + ' "%1"')) { return }
    Remove-Item -LiteralPath $key -Recurse -Force
}

function Choose-DefaultEditor {
    if ($NoMakeDefault -or $NoFileAssociations) { return }
    if ($MakeDefault) {
        Write-Output 'In Default Apps, select rhun and choose the text types to open with it. Images are optional.'
        $uri = if ([Environment]::OSVersion.Version.Build -ge 22000) {
            'ms-settings:defaultapps?registeredAppUser=rhun'
        } else { 'ms-settings:defaultapps' }
        Start-Process $uri
        Set-TerminalEditor
    } else {
        Show-DefaultEditorCommand
    }
}

# The editor programs such as git ask for: rhun.com, which keeps the console until rhun closes. Git's sh
# reads it: forward slashes, and $ and ` escaped, so that the double quotes keep the path as it is.
function Get-EditorValue {
    $path = (Join-Path $InstallDir 'rhun.com').Replace('\', '/').Replace('$', '\$').Replace('`', '\`')
    '"' + $path + '" --wait'
}
function Get-UserVariable([string]$Name) { [Environment]::GetEnvironmentVariable($Name, 'User') }
function Set-UserVariable([string]$Name, $Value) { [Environment]::SetEnvironmentVariable($Name, $Value, 'User') }

# Set-TerminalEditor: VISUAL and EDITOR for the user, so that git opens commit messages in rhun
function Set-TerminalEditor {
    $value = Get-EditorValue
    if ($NoModifyPath) {
        Write-Output "To edit commit messages in rhun, set VISUAL and EDITOR to: $value"
        return
    }
    Set-UserVariable 'VISUAL' $value
    Set-UserVariable 'EDITOR' $value
    Write-Output 'Programs that ask for an editor, such as git, open rhun in new terminals (VISUAL and EDITOR).'
    if ($env:GIT_EDITOR) { Write-Output "GIT_EDITOR ($env:GIT_EDITOR) still comes first for git." }
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $core = & git config --global --get core.editor 2>$null
        if ($core) { Write-Output "git's core.editor ($core) still comes first; git config --global --unset core.editor uses rhun." }
    }
}

# Remove-TerminalEditor: VISUAL and EDITOR, where they still name this installation
function Remove-TerminalEditor {
    $value = Get-EditorValue
    foreach ($name in 'VISUAL', 'EDITOR') {
        if ((Get-UserVariable $name) -eq $value) { Set-UserVariable $name $null }
    }
}

function Show-DefaultEditorCommand {
    if ($NoFileAssociations) { return }
    $script = (Join-Path $InstallDir 'install.ps1').Replace("'", "''")
    $directory = $InstallDir.Replace("'", "''")
    $command = "  powershell -NoProfile -ExecutionPolicy Bypass -File '$script' -ConfigureFiles -MakeDefault -InstallDir '$directory'"
    $color = -not [Console]::IsOutputRedirected -and -not (Test-Path Env:NO_COLOR) -and $env:TERM -ne 'dumb'
    Write-Output ''
    if ($color) {
        Write-Host '  Optional: default editor' -ForegroundColor Cyan
        Write-Host '  ========================' -ForegroundColor Cyan
    } else {
        Write-Output '  Optional: default editor'
        Write-Output '  ========================'
    }
    Write-Output 'To choose rhun as your default editor, for files and for git, run this command manually:'
    if ($color) { Write-Host $command -ForegroundColor Green } else { Write-Output $command }
    Write-Output ''
}
# END FILE ASSOCIATION FUNCTIONS

if ($ConfigureFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $InstallDir 'rhun.exe') -PathType Leaf)) {
        throw "No rhun installation at $InstallDir. Set -InstallDir or run the installer."
    }
    Register-FileAssociations
    $marker = Join-Path $InstallDir '.rhun-install'
    if (Test-Path -LiteralPath $marker) {
        $receipt = [IO.File]::ReadAllText($marker).Replace("file-associations: no`n", '')
        if ($NoFileAssociations) { $receipt += "file-associations: no`n" }
        [IO.File]::WriteAllText($marker, $receipt)
    }
    Choose-DefaultEditor
    return
}

function File-Sha256([string]$Path) {
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead($Path)
        try { return [BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-', '') }
        finally { $stream.Dispose() }
    } finally { $hasher.Dispose() }
}

# Removes a folder without following links: a junction is removed, never its target.
function Remove-Folder([string]$Path) { [IO.Directory]::Delete($Path, $true) }

# Just after the staged rhun.com ran, Windows or a scan can hold a file in the stage for a moment:
# its move is retried for five seconds while it can still happen (the error does not say why).
function Move-StagedFolder([string]$Path, [string]$Destination) {
    for ($i = 1; ; $i++) {
        try { Move-Item -LiteralPath $Path -Destination $Destination; return }
        catch { if ($i -ge 20 -or (Test-Path -LiteralPath $Destination) -or -not (Test-Path -LiteralPath $Path)) { throw } }
        Start-Sleep -Milliseconds 250
    }
}

# Staged updates whose editor is gone (it quit or crashed before restarting, or its process ID now
# belongs to another program), and interrupted downloads and swaps older than an hour.
function Remove-StaleUpdates([string]$Parent) {
    $hourAgo = [DateTime]::UtcNow.AddHours(-1)
    foreach ($dir in @(Get-ChildItem -LiteralPath $Parent -Directory -Force -Filter '.rhun-update-*')) {
        if ($dir.Name -notmatch '^\.rhun-update-(\d{1,9})$') { continue }
        $process = Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue
        if ($process -and $process.ProcessName -match '^rhun(\.com)?$') {
            # A running editor's pending update stays, unless the folder is older than the
            # process: then the editor that staged it is gone and its ID was reused.
            $started = $null
            try { $started = $process.StartTime.ToUniversalTime() } catch { }
            if (-not $started -or $started -le $dir.CreationTimeUtc) { continue }
        }
        Remove-Folder $dir.FullName
    }
    foreach ($dir in @(Get-ChildItem -LiteralPath $Parent -Directory -Force) +
                     @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Force -Filter 'rhun-download-*')) {
        if ($dir.Name -match '^(\.rhun-stage-|\.rhun-old-|rhun-download-)[0-9a-f]{32}$' -and $dir.LastWriteTimeUtc -lt $hourAgo) {
            Remove-Folder $dir.FullName
        }
    }
}

if ($PrepareUpdate -or $ApplyUpdate -or $DiscardUpdate) {
    $modes = @($PrepareUpdate, $ApplyUpdate, $DiscardUpdate | Where-Object { $_ }).Count
    if ($Uninstall -or $modes -ne 1 -or -not $UpdateStage -or $WaitPid -le 0) { throw 'Invalid update arguments.' }
    $expectedStage = Join-Path (Split-Path -Parent $InstallDir) ('.rhun-update-' + $WaitPid)
    $UpdateStage = [IO.Path]::GetFullPath($UpdateStage).TrimEnd('\', '/')
    if ($UpdateStage -ine $expectedStage) { throw 'Invalid update staging directory.' }
    if (-not (Test-Path -LiteralPath (Join-Path $InstallDir 'rhun.exe') -PathType Leaf)) {
        throw 'The running installation was not found.'
    }
}

if ($DiscardUpdate) {
    # The editor quit without restarting: its staged download goes once it has exited.
    $parentProcess = Get-Process -Id $WaitPid -ErrorAction SilentlyContinue
    if ($parentProcess) { [void]$parentProcess.WaitForExit(60000) }
    if (Test-Path -LiteralPath $UpdateStage) { Remove-Folder $UpdateStage }
    return
}

if ($ApplyUpdate) {
    $receipt = Get-Content -LiteralPath (Join-Path $UpdateStage 'update.json') -Raw | ConvertFrom-Json
    if ($receipt.target -ine $InstallDir -or $receipt.version -cne $Version) { throw 'Invalid staged update.' }
    $files = @('rhun.exe', 'rhun.com', 'LICENSE', 'install.ps1')
    foreach ($name in $files) {
        $destination = Join-Path $InstallDir $name
        if (Test-Path -LiteralPath $destination) {
            $item = Get-Item -LiteralPath $destination -Force
            if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'The update destination contains a directory or link in place of an application file.'
            }
        }
        $actual = File-Sha256 (Join-Path $UpdateStage $name)
        if ($actual -ine $receipt.hashes.$name) { throw 'The staged update checksum does not match.' }
    }
    $parentProcess = Get-Process -Id $WaitPid -ErrorAction SilentlyContinue
    if ($parentProcess -and -not $parentProcess.WaitForExit(60000)) { throw 'The editor did not close.' }
    # Check every binary before changing any files. Another editor instance may still own them.
    foreach ($name in @('rhun.exe', 'rhun.com')) {
        $path = Join-Path $InstallDir $name
        if (Test-Path -LiteralPath $path) {
            $probe = [IO.File]::Open($path, 'Open', 'ReadWrite', 'None')
            $probe.Dispose()
        }
    }
    $backupDir = Join-Path $UpdateStage 'backup'
    New-Item -ItemType Directory -Path $backupDir | Out-Null
    $changed = @()
    try {
        foreach ($name in $files) {
            $destination = Join-Path $InstallDir $name
            if (Test-Path -LiteralPath $destination) {
                Move-Item -LiteralPath $destination -Destination (Join-Path $backupDir $name)
            }
            $changed += $name
            Move-Item -LiteralPath (Join-Path $UpdateStage $name) -Destination $destination
        }
        $marker = Join-Path $InstallDir '.rhun-install'
        if (Test-Path -LiteralPath $marker) {
            $receipt = "rhun $Version`n"
            $old = [IO.File]::ReadAllText($marker)
            if ($old.Contains('file-associations: no')) { $receipt += "file-associations: no`n" }
            if ($old.Contains('url-scheme: no')) { $receipt += "url-scheme: no`n" }
            [IO.File]::WriteAllText($marker, $receipt)
        }
    } catch {
        foreach ($name in $changed) {
            $destination = Join-Path $InstallDir $name
            if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Force }
            $old = Join-Path $backupDir $name
            if (Test-Path -LiteralPath $old) { Move-Item -LiteralPath $old -Destination $destination }
        }
        throw
    }
    Remove-Item -LiteralPath $UpdateStage -Recurse -Force
    # Installed copies gain new handlers on update. Portable copies stay unregistered.
    $capabilities = "$associationRoot\rhun\Capabilities"
    $registeredHere = (Test-Path -LiteralPath $capabilities) -and
        ((Get-ItemPropertyValue -LiteralPath $capabilities -Name 'InstallDir' -ErrorAction SilentlyContinue) -ieq $InstallDir)
    $installed = Test-Path -LiteralPath (Join-Path $InstallDir '.rhun-install')
    $optedOut = $installed -and ([IO.File]::ReadAllText((Join-Path $InstallDir '.rhun-install')).Contains('file-associations: no'))
    if (-not $optedOut -and ($installed -or $registeredHere)) {
        try { Register-FileAssociations } catch { Write-Warning "File association registration failed: $($_.Exception.Message)" }
    }
    $urlOptedOut = $installed -and ([IO.File]::ReadAllText((Join-Path $InstallDir '.rhun-install')).Contains('url-scheme: no'))
    if ($installed -and -not $urlOptedOut) {
        try { Register-UrlScheme } catch { Write-Warning "rhun:// link registration failed: $($_.Exception.Message)" }
    }
    return
}

function Update-UserPath([bool]$Remove) {
    $value = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($value -split ';' | Where-Object { $_ -ne '' })
    $matching = @($parts | Where-Object {
        [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\', '/') -ieq $InstallDir
    })
    if ($Remove) {
        $parts = @($parts | Where-Object {
            [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\', '/') -ine $InstallDir
        })
    } elseif ($matching.Count -eq 0) {
        $parts += $InstallDir
    }
    [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
}

function Read-ReleaseText([string]$Url) {
    $content = (Invoke-WebRequest -UseBasicParsing -Uri $Url).Content
    if ($content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($content) }
    return [string]$content
}

# The directory swap below owns only an existing rhun installation, never an arbitrary folder.
if (-not $PrepareUpdate -and (Test-Path -LiteralPath $InstallDir)) {
    if (-not (Test-Path -LiteralPath (Join-Path $InstallDir 'rhun.exe') -PathType Leaf)) {
        throw "The destination is not a rhun installation: $InstallDir"
    }
    $unknown = @(Get-ChildItem -LiteralPath $InstallDir -Force | Where-Object {
        $_.PSIsContainer -or $_.Name -notin $knownFiles
    })
    if ($unknown.Count -gt 0) {
        throw "The installation folder contains other files. Move them before updating: $InstallDir"
    }
}
# a process path may come in the \\?\ form, which .NET Framework's path functions refuse: such a
# path is compared without it, and one that still cannot be read is left to the probe below
$running = @(Get-Process -Name rhun,rhun.com -ErrorAction SilentlyContinue | Where-Object {
    $path = $_.Path
    if (-not $path) { return $false }
    if ($path.StartsWith('\\?\')) { $path = $path.Substring(4) }
    try { [IO.Path]::GetDirectoryName($path) -ieq $InstallDir } catch { $false }
})
if (-not $PrepareUpdate -and $running.Count -gt 0) { throw 'Close rhun before updating or uninstalling it.' }
# Process metadata is not always available. Loaded PE files cannot be opened for writing.
foreach ($name in @('rhun.exe', 'rhun.com') | Where-Object { -not $PrepareUpdate }) {
    $file = Join-Path $InstallDir $name
    if (Test-Path -LiteralPath $file) {
        try {
            $probe = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $probe.Dispose()
        } catch {
            throw 'Close rhun before updating or uninstalling it, and check that its files are writable.'
        }
    }
}

if ($Uninstall) {
    Remove-FileAssociations
    Remove-UrlScheme
    Remove-TerminalEditor
    if (Test-Path -LiteralPath $InstallDir) {
        foreach ($name in $knownFiles) {
            $file = Join-Path $InstallDir $name
            if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
        }
        Remove-Item -LiteralPath $InstallDir
    }
    if (-not $NoModifyPath) { Update-UserPath $true }
    if (-not $NoShortcut -and (Test-Path -LiteralPath $shortcut)) {
        Remove-Item -LiteralPath $shortcut -Force
    }
    Write-Output 'rhun was removed. Settings and saved sessions were kept.'
    return
}

$ReleasesUrl = $ReleasesUrl.TrimEnd('/')
$baseUri = [Uri]$ReleasesUrl
if ($baseUri.Scheme -ne 'https' -and -not ($baseUri.Scheme -eq 'http' -and $baseUri.IsLoopback)) {
    throw 'The release URL must use HTTPS (HTTP is allowed only for a local test server).'
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('rhun-download-' + [Guid]::NewGuid().ToString('N'))
$stage = $null
$backup = $null
New-Item -ItemType Directory -Path $temporary | Out-Null
try {
    if (-not $Version) {
        $Version = (Read-ReleaseText "$ReleasesUrl/latest/download/VERSION").Trim()
    }
    if ($Version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?$' -or $Version.Length -gt 31) {
        throw 'The release version is invalid.'
    }
    $asset = "rhun-$Version-windows-x86_64.zip"
    $download = "$ReleasesUrl/download/v$Version"
    $archive = Join-Path $temporary $asset
    Invoke-WebRequest -UseBasicParsing -Uri "$download/$asset" -OutFile $archive
    $checksums = Read-ReleaseText "$download/SHA256SUMS"
    $pattern = '(?m)^([0-9a-fA-F]{64})\s+\*?' + [Regex]::Escape($asset) + '\r?$'
    $matchesFound = [Regex]::Matches($checksums, $pattern)
    if ($matchesFound.Count -ne 1) { throw 'The archive checksum is missing or ambiguous.' }
    # Use .NET directly, including when Windows PowerShell inherits PowerShell 7's module path.
    $actual = File-Sha256 $archive
    if ($actual -ine $matchesFound[0].Groups[1].Value) { throw 'The archive checksum does not match.' }
    $parent = Split-Path -Parent $InstallDir
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    if ($PrepareUpdate) { Remove-StaleUpdates $parent }
    $stage = Join-Path $parent ('.rhun-stage-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        # Extract only the four known files to explicit destinations, never archive-supplied paths.
        foreach ($name in @('rhun.exe', 'rhun.com', 'LICENSE', 'install.ps1')) {
            $entries = @($zip.Entries | Where-Object { $_.FullName -ceq "rhun-$Version/$name" })
            if ($entries.Count -ne 1) { throw "The archive must contain exactly one $name." }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0], (Join-Path $stage $name), $false)
        }
    } finally { $zip.Dispose() }
    $reported = & (Join-Path $stage 'rhun.com') --version
    if ($LASTEXITCODE -ne 0 -or $reported -cne "rhun $Version") { throw 'The staged executable has the wrong version.' }
    if ($PrepareUpdate) {
        $hashes = @{}
        foreach ($name in @('rhun.exe', 'rhun.com', 'LICENSE', 'install.ps1')) {
            $hashes[$name] = File-Sha256 (Join-Path $stage $name)
        }
        @{ target = $InstallDir; version = $Version; hashes = $hashes } | ConvertTo-Json |
            Set-Content -LiteralPath (Join-Path $stage 'update.json') -Encoding UTF8
        # Stale stages are gone (Remove-StaleUpdates); one that appeared since is not ours to remove.
        if (Test-Path -LiteralPath $UpdateStage) { throw 'An update is already staged for this editor.' }
        Move-StagedFolder $stage $UpdateStage
        $stage = $null
        Write-Output 'The update is ready to install when rhun restarts.'
        return
    }
    $receipt = "rhun $Version`n"
    if ($NoFileAssociations) { $receipt += "file-associations: no`n" }
    if ($NoUrlScheme) { $receipt += "url-scheme: no`n" }
    [IO.File]::WriteAllText((Join-Path $stage '.rhun-install'), $receipt)
    if (Test-Path -LiteralPath $InstallDir) {
        $backup = Join-Path $parent ('.rhun-old-' + [Guid]::NewGuid().ToString('N'))
        Move-Item -LiteralPath $InstallDir -Destination $backup
    }
    try {
        Move-StagedFolder $stage $InstallDir
        $stage = $null
    } catch {
        if ($backup -and -not (Test-Path -LiteralPath $InstallDir)) {
            Move-Item -LiteralPath $backup -Destination $InstallDir
            $backup = $null
        }
        throw
    }
    if ($backup) { Remove-Item -LiteralPath $backup -Recurse -Force; $backup = $null }
    if (-not $NoModifyPath) { Update-UserPath $false }
    if (-not $NoShortcut) {
        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut($shortcut)
        $link.TargetPath = Join-Path $InstallDir 'rhun.exe'
        $link.WorkingDirectory = $env:USERPROFILE
        $link.IconLocation = $link.TargetPath
        $link.Save()
    }
    Write-Output "Installed rhun $Version in $InstallDir. Open a new terminal to use the rhun command."
    try { Register-FileAssociations; Show-DefaultEditorCommand }
    catch { Write-Warning "File association setup failed: $($_.Exception.Message)" }
    try { Register-UrlScheme }
    catch { Write-Warning "rhun:// link registration failed: $($_.Exception.Message)" }
} finally {
    if ($stage -and (Test-Path -LiteralPath $stage)) { Remove-Item -LiteralPath $stage -Recurse -Force }
    Remove-Item -LiteralPath $temporary -Recurse -Force
    # A backup surviving failed rollback is retained for recovery.
    if ($backup) { Write-Warning "The previous installation was retained at $backup" }
}
