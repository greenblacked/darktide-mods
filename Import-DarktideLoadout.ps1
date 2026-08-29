<#
.SYNOPSIS
    Restores a loadout archive into staging, and optionally deploys it to the game.

.DESCRIPTION
    The other half of Export-DarktideLoadout.ps1. Takes an archive produced by that
    script (or any zip laid out as one folder per mod) and unpacks it into your
    staging folder, then hands off to the deployer.

    Extraction is guarded the same way mod installs are: entries that try to escape
    the destination are refused outright, and each mod is written to a temporary
    folder first so a bad archive cannot leave you with a half-replaced loadout.

    Nothing is written without -Apply.

.PARAMETER Path
    The loadout .zip to restore.

.PARAMETER Deploy
    After restoring staging, also deploy to the game folder.

.PARAMETER Mirror
    Passed through to the deployer: remove mods from the game folder that are not
    in the restored loadout.

.EXAMPLE
    .\Import-DarktideLoadout.ps1 -Path D:\backup\darktide-loadout-20260829.zip
    Dry run - lists what the archive holds and what would change.

.EXAMPLE
    .\Import-DarktideLoadout.ps1 -Path D:\backup\loadout.zip -Apply -Deploy
    Restores staging and pushes it to the game in one step.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)] [string] $Path,
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string] $StagingMods,
    [switch] $Apply,
    [switch] $Deploy,
    [switch] $Mirror,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue

function Write-Step { param([string]$m) Write-Host $m -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host $m -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host $m -ForegroundColor Yellow }

function Expand-LoadoutArchive {
    <#
        Extracts every entry into $Destination, refusing anything that resolves
        outside it. Zip entry names are attacker-controlled, so both the textual
        form and the resolved path are checked.
    #>
    param(
        [Parameter(Mandatory)] [string] $ZipPath,
        [Parameter(Mandatory)] [string] $Destination
    )

    $root = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    $zip  = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $zip.Entries) {
            # Normalise separators first: a zip may legally use '\', and a
            # backslash-only traversal would slip past a '/'-only check.
            $rel = $entry.FullName -replace '\\', '/'
            if (-not $rel) { continue }
            if ($rel -match '(^|/)\.\.(/|$)' -or $rel -match '^([A-Za-z]:|/)') {
                throw "Archive contains an unsafe path: '$($entry.FullName)'"
            }

            $target = Join-Path $Destination ($rel -replace '/', '\')
            $full   = [System.IO.Path]::GetFullPath($target)
            if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Archive entry '$($entry.FullName)' resolves outside the destination."
            }

            if ($rel.EndsWith('/')) {
                if (-not (Test-Path -LiteralPath $target)) {
                    New-Item -ItemType Directory -Path $target -Force | Out-Null
                }
                continue
            }

            $parent = Split-Path -Parent $target
            if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } finally { $zip.Dispose() }
}

# ---- Resolve inputs ----------------------------------------------------------------

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Loadout archive '$Path' not found."
}
$Path = (Resolve-Path -LiteralPath $Path).Path

$modsRoot = $StagingMods
if (-not $modsRoot -and (Test-Path -LiteralPath $ConfigPath)) {
    $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    if ($raw.Trim()) {
        $j = $raw | ConvertFrom-Json
        if ($j.PSObject.Properties.Name -contains 'ModsRoot' -and "$($j.ModsRoot)".Trim()) {
            $modsRoot = "$($j.ModsRoot)"
        }
    }
}
if (-not $modsRoot) {
    throw "ModsRoot is not set. Run '.\darktide.ps1 init' first, or pass -StagingMods."
}

# ---- Inspect the archive -----------------------------------------------------------

Write-Step '=== Darktide loadout import ==='
Write-Host  "Archive : $Path"
Write-Host  "Staging : $modsRoot"
Write-Host  "Mode    : $(if ($Apply) { 'APPLY' } else { 'DRY RUN (pass -Apply to write)' })"
Write-Host  ''

$zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
try {
    $entries = @($zip.Entries | ForEach-Object { $_.FullName -replace '\\', '/' })
} finally { $zip.Dispose() }

if (-not $entries) { throw "'$Path' is empty." }

# Top-level folders are the mods.
$modFolders = @($entries |
    Where-Object { $_ -match '/' } |
    ForEach-Object { ($_ -split '/')[0] } |
    Where-Object { $_ -and -not $_.StartsWith('.') } |
    Select-Object -Unique | Sort-Object)

if (-not $modFolders) {
    throw "'$Path' has no mod folders in it - is this a loadout archive?"
}

$hasLoadOrder = $entries -contains 'mod_load_order.txt'

$existing = @()
if (Test-Path -LiteralPath $modsRoot) {
    $existing = @(Get-ChildItem -LiteralPath $modsRoot -Directory -ErrorAction SilentlyContinue |
                  ForEach-Object { $_.Name })
}
$new       = @($modFolders | Where-Object { $existing -notcontains $_ })
$replacing = @($modFolders | Where-Object { $existing -contains $_ })

Write-Step 'Plan'
Write-Host "  mods in archive : $($modFolders.Count)"
Write-Host "  new             : $($new.Count)$(if ($new) { '  ' + (($new | Select-Object -First 8) -join ', ') + $(if ($new.Count -gt 8) { ', ...' } else { '' }) })"
Write-Host "  replacing       : $($replacing.Count)"
if ($hasLoadOrder) { Write-Host '  load order      : included' }
else { Write-Warn '  load order      : NOT in the archive - existing mod_load_order.txt is kept' }
Write-Host ''

if (-not $Apply) {
    Write-Warn 'Dry run complete. Nothing was written. Re-run with -Apply.'
    return
}

if ($replacing.Count -gt 0 -and -not $Force -and -not $PSCmdlet.ShouldProcess(
        $modsRoot, "Replace $($replacing.Count) existing mod folder(s) from $([System.IO.Path]::GetFileName($Path))")) {
    return
}

# ---- Restore -----------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $modsRoot)) {
    New-Item -ItemType Directory -Path $modsRoot -Force | Out-Null
}

# Extract to a temporary folder first, so a corrupt archive cannot leave staging
# half-written.
$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-import-" + [guid]::NewGuid().ToString('N').Substring(0, 10))
New-Item -ItemType Directory -Path $stage -Force | Out-Null

try {
    Write-Step 'Extracting...'
    Expand-LoadoutArchive -ZipPath $Path -Destination $stage

    Write-Step 'Restoring into staging...'
    foreach ($folder in $modFolders) {
        $src = Join-Path $stage $folder
        if (-not (Test-Path -LiteralPath $src -PathType Container)) { continue }

        $dst = Join-Path $modsRoot $folder
        if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
        Move-Item -LiteralPath $src -Destination $dst -Force
        Write-Host "  $folder"
    }

    if ($hasLoadOrder) {
        $lo = Join-Path $stage 'mod_load_order.txt'
        if (Test-Path -LiteralPath $lo) {
            Copy-Item -LiteralPath $lo -Destination (Join-Path $modsRoot 'mod_load_order.txt') -Force
            Write-Ok '  mod_load_order.txt restored'
        }
    }
}
finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Ok "Restored $($modFolders.Count) mod(s) into $modsRoot"

# ---- Deploy ------------------------------------------------------------------------

if ($Deploy) {
    Write-Host ''
    $deployer = Join-Path $PSScriptRoot 'Deploy-DarktideMods.ps1'
    if (-not (Test-Path -LiteralPath $deployer)) { throw "Missing script: $deployer" }
    & $deployer -ConfigPath $ConfigPath -Apply -Mirror:$Mirror -Confirm:$false
} else {
    Write-Host ''
    Write-Host 'Now push it to the game:' -ForegroundColor Cyan
    Write-Host '  .\darktide.ps1 deploy -Apply'
}
