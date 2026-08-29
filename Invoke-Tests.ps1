<#
.SYNOPSIS
    Runs the Pester suite and the repository validator.

.DESCRIPTION
    Everything runs against throwaway fixtures under $env:TEMP. No test touches the
    real staging folder, the real game install, or the network.

    Requires Pester 5 or newer:
        Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck

.PARAMETER Path
    Run only the test files matching this filter, e.g. -Path Deploy.

.PARAMETER Output
    Pester verbosity: None, Normal, Detailed or Diagnostic. Default Normal.

.PARAMETER SkipValidator
    Run the Pester suite only, without Test-Modpack.ps1.

.EXAMPLE
    .\Invoke-Tests.ps1

.EXAMPLE
    .\Invoke-Tests.ps1 -Path Deploy -Output Detailed
#>

[CmdletBinding()]
param(
    [string] $Path,
    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
    [string] $Output = 'Normal',
    [switch] $SkipValidator
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$pester = Get-Module -ListAvailable -Name Pester |
          Where-Object { $_.Version.Major -ge 5 } |
          Sort-Object Version -Descending | Select-Object -First 1

if (-not $pester) {
    Write-Host 'Pester 5+ is not installed. Install it with:' -ForegroundColor Red
    Write-Host '  Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck' -ForegroundColor Yellow
    exit 1
}

Import-Module $pester.Path -Force
Write-Host "Pester $($pester.Version)" -ForegroundColor Cyan

$testDir = Join-Path $PSScriptRoot 'tests'
$targets = if ($Path) {
    @(Get-ChildItem -LiteralPath $testDir -Filter '*.Tests.ps1' -File |
      Where-Object { $_.Name -like "*$Path*" } | ForEach-Object { $_.FullName })
} else {
    @($testDir)
}

if (-not $targets) { Write-Host "No test files match '$Path'." -ForegroundColor Red; exit 1 }

$cfg = New-PesterConfiguration
$cfg.Run.Path        = $targets
$cfg.Run.PassThru    = $true
$cfg.Output.Verbosity = $Output

$result = Invoke-Pester -Configuration $cfg

$failed = $result.FailedCount

if (-not $SkipValidator) {
    Write-Host ''
    Write-Host '--- Repository validator ---' -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot 'Test-Modpack.ps1')
    if ($LASTEXITCODE -ne 0) { $failed++ }
}

Write-Host ''
if ($failed -eq 0) {
    Write-Host "All tests passed ($($result.PassedCount) assertions)." -ForegroundColor Green
    exit 0
}

Write-Host "$failed test group(s) failed." -ForegroundColor Red
exit 1
