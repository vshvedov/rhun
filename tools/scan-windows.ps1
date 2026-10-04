# Explicit Defender scans. A skipped scan or unavailable engine is never a clean verdict.
[CmdletBinding()]
param(
    [string[]]$Path,
    [string]$ReportDir = 'build/defender',
    [switch]$ConfigureRunner,
    [switch]$UseCurrentSignatures,
    [switch]$ReportOnly
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Get-ScanVerdict([int]$Code, [string]$Output) {
    if ($Output -match '(?i)skipp|cancel|abort|failed|error|disabled') { return 'unverified' }
    if ($Code -eq 2 -and $Output -match '(?i)Threat\s*(Name|information|:)') { return 'detected' }
    if ($Code -ne 0 -or $Output -notmatch '(?i)Scan finished') { return 'unverified' }
    # -DisableRemediation leaves detected files untouched, so code 0 cannot mean
    # that a threat was found and successfully remediated by this custom scan.
    if ($Output -notmatch '(?i)found no threats') { return 'unverified' }
    return 'clean'
}

# Dot-sourcing exposes the verdict parser to regression tests without scanning.
if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $Path) { throw 'Specify every binary and archive to scan with -Path.' }
$ReportDir = [IO.Path]::GetFullPath($ReportDir)
$null = New-Item -ItemType Directory -Force $ReportDir
$report = [ordered]@{ started = [DateTime]::UtcNow.ToString('o'); status = 'unverified'; files = @() }
$failure = $null
$started = Get-Date
try {
    # Hash before enabling real-time protection, which can quarantine a sample.
    foreach ($file in $Path) {
        $file = [IO.Path]::GetFullPath($file)
        $report.files += [ordered]@{ path = $file; sha256 = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash; status = 'unverified' }
    }
    if ($ConfigureRunner) {
        if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
            throw '-ConfigureRunner is only for disposable GitHub-hosted runners.'
        }
        # Hosted Windows images disable Defender and exclude C:\ and D:\.
        # Restore protection on this disposable runner, never on a user's PC.
        Start-Service WinDefend
        $preferences = Get-MpPreference
        foreach ($kind in @('Path', 'Extension', 'Process')) {
            $values = $preferences.("Exclusion" + $kind)
            if ($values) {
                $parameters = @{}
                $parameters['Exclusion' + $kind] = $values
                Remove-MpPreference @parameters
            }
        }
        Set-MpPreference -DisableArchiveScanning $false -DisableScriptScanning $false `
            -DisableIOAVProtection $false -DisableBehaviorMonitoring $false `
            -DisableRealtimeMonitoring $false -DisableBlockAtFirstSeen $false `
            -MAPSReporting Advanced -SubmitSamplesConsent SendSafeSamples -ScanAvgCPULoadFactor 50
    }
    $report.signatureUpdate = [ordered]@{ requested = -not $UseCurrentSignatures; errors = @() }
    if (-not $UseCurrentSignatures) {
        for ($attempt = 0; $attempt -lt 3; $attempt++) {
            try { Update-MpSignature; break }
            catch {
                $report.signatureUpdate.errors += $_.Exception.Message
                if ($attempt -eq 2) { throw }
                Start-Sleep -Seconds 2
            }
        }
    }
    $status = Get-MpComputerStatus
    if ($ConfigureRunner) {
        # The service applies protection preferences asynchronously. Wait for the
        # state transition, rather than mistaking it for a disabled engine.
        for ($attempt = 0; $attempt -lt 15 -and -not $status.RealTimeProtectionEnabled; $attempt++) {
            Start-Sleep -Seconds 2
            $status = Get-MpComputerStatus
        }
    }
    $report.engine = $status | Select-Object AMRunningMode, AMServiceEnabled, AntivirusEnabled,
        RealTimeProtectionEnabled, AMProductVersion, AMEngineVersion,
        AntivirusSignatureVersion, AntivirusSignatureLastUpdated
    $age = [DateTime]::UtcNow - $status.AntivirusSignatureLastUpdated.ToUniversalTime()
    if ($age.TotalHours -gt 24) { throw 'Defender signatures are more than 24 hours old.' }
    $report.os = Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber
    $report.preferences = Get-MpPreference | Select-Object ExclusionPath, ExclusionExtension,
        ExclusionProcess, DisableArchiveScanning, DisableScriptScanning, MAPSReporting, SubmitSamplesConsent
    if (-not $status.AMServiceEnabled -or -not $status.AntivirusEnabled -or
        $status.AMRunningMode -ne 'Normal' -or -not $status.RealTimeProtectionEnabled) {
        throw 'Defender must be active in Normal mode with real-time protection enabled.'
    }
    $commands = @(Get-ChildItem -LiteralPath "$env:ProgramData\Microsoft\Windows Defender\Platform" `
        -Filter MpCmdRun.exe -Recurse | Sort-Object FullName -Descending)
    $command = if ($commands.Count) { $commands[0].FullName } else { "$env:ProgramFiles\Windows Defender\MpCmdRun.exe" }
    if (-not (Test-Path -LiteralPath $command)) { throw 'MpCmdRun.exe is unavailable.' }
    $index = 0
    foreach ($file in $report.files) {
        $index++
        if (-not (Test-Path -LiteralPath $file.path)) {
            $file.reason = 'File disappeared before the scan, possibly quarantined.'
            continue
        }
        # This custom scan includes archives and ignores file exclusions.
        $output = (& $command -Scan -ScanType 3 -File $file.path -DisableRemediation 2>&1 | Out-String)
        $code = $LASTEXITCODE
        $output | Set-Content -LiteralPath (Join-Path $ReportDir "scan-$index.txt") -Encoding UTF8
        $file.exitCode = $code
        $file.status = Get-ScanVerdict $code $output
        if (-not (Test-Path -LiteralPath $file.path) -or
            (Get-FileHash -LiteralPath $file.path -Algorithm SHA256).Hash -ne $file.sha256) {
            $file.status = 'unverified'
            $file.reason = 'File disappeared or changed during the scan.'
        }
        Write-Output "$($file.status): $($file.path)"
        Write-Output $output
    }
    if (@($report.files | Where-Object { $_.status -ne 'clean' }).Count -eq 0) { $report.status = 'clean' }
    elseif (@($report.files | Where-Object { $_.status -eq 'detected' }).Count) { $report.status = 'detected' }
} catch {
    $failure = $_.Exception.Message
    $report.error = $failure
} finally {
    $report.finished = [DateTime]::UtcNow.ToString('o')
    try {
        @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Windows Defender/Operational'; StartTime = $started } -ErrorAction Stop |
            Select-Object TimeCreated, Id, Message) | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $ReportDir 'events.json') -Encoding UTF8
    } catch { $report.eventLogError = $_.Exception.Message }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $ReportDir 'report.json') -Encoding UTF8
}
if ($report.status -ne 'clean') {
    if ($ReportOnly) { Write-Warning "Defender result: $($report.status). $failure" }
    else { throw "Defender result: $($report.status). $failure See $ReportDir." }
}
