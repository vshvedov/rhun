$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../tools/scan-windows.ps1"
$cases = @(
    @(0, "Scan finished.`nFound no threats.", 'clean'),
    @(0, "Scan finished.`nScanning was skipped.`nFound no threats.", 'unverified'),
    @(0, '', 'unverified'),
    @(0, 'Scan finished.', 'unverified'),
    @(2, "Scan finished.`nThreat Name: Trojan:Win32/Wacatac.C!ml", 'detected'),
    @(2, 'Scan failed. Error 0x800106ba', 'unverified'),
    @(0, 'Scan cancelled. Found no threats.', 'unverified'),
    @(5, 'Scan finished. Found no threats.', 'unverified')
)
foreach ($case in $cases) {
    $actual = Get-ScanVerdict $case[0] $case[1]
    if ($actual -ne $case[2]) { throw "Expected $($case[2]), got $actual for $($case[1])" }
}
Write-Output 'ok   defender/clean-detected-skipped-and-failed-verdicts'
