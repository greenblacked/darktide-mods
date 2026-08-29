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

.PARAMETER AllowNonWindows
    Run the Pester suite anyway on Linux or macOS. Expect large numbers of failures:
    the tools are Windows-only and the suite asserts Windows behaviour.

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
    [switch] $SkipValidator,
    [switch] $AllowNonWindows
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The tools are Windows-only: they shell out to robocopy, read $env:USERPROFILE and the
# Steam registry, and build '\'-separated paths. The suite asserts exactly that, so on
# Linux or macOS it fails in ways that say nothing about the code. The validator, on the
# other hand, is pure parsing and JSON - it runs anywhere, so offer that instead.
$onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
if (-not $onWindows -and -not $AllowNonWindows) {
    Write-Host "The Pester suite needs Windows - $($PSVersionTable.Platform) cannot run robocopy, the Steam registry keys or '\'-separated paths." -ForegroundColor Yellow
    Write-Host 'Use -AllowNonWindows to run it anyway, or push the branch and let CI run it on windows-latest.' -ForegroundColor Yellow
    if ($SkipValidator) { exit 1 }
    Write-Host ''
    Write-Host '--- Repository validator (cross-platform) ---' -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot 'Test-Modpack.ps1')
    exit $LASTEXITCODE
}

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
