<#
.SYNOPSIS
    Packages your installed mod loadout into a single zip, for your own backup.

.DESCRIPTION
    Produces one archive containing every mod folder in your staging root, plus
    mod_load_order.txt and the manifest, so a whole loadout can be carried to
    another machine or restored after a reinstall in one step.

    Run 'darktide.ps1 sync -Apply' first if you want the newest versions in it -
    this packages what is installed, it does not fetch anything.

    This archive is LOCAL. It is deliberately not produced or published by CI, and
    the repository's .gitignore excludes it: it contains other authors' mod files,
    which are theirs to distribute, not yours or mine. Keep it as a personal backup.

    Restore it with:
        Expand-Archive -LiteralPath <zip> -DestinationPath <ModsRoot>
        .\darktide.ps1 deploy -Apply

.PARAMETER OutDir
    Where to write the archive. Defaults to the staging folder's parent.

.PARAMETER OutFile
    Full path for the archive. Overrides -OutDir.

.PARAMETER Force
    Overwrite an existing archive of the same name.

.PARAMETER IncludeManifest
    Also write darktide-modpack.lock.json into the archive. On by default.

.EXAMPLE
    .\Export-DarktideLoadout.ps1
    Writes darktide-loadout-<date>.zip next to your staging folder.

.EXAMPLE
    .\Export-DarktideLoadout.ps1 -OutFile 'E:\backup\my-loadout.zip' -Force
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string] $StagingMods,
    [string] $OutDir,
    [string] $OutFile,
    [switch] $Force,
    [switch] $NoManifest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue

function Write-Step { param([string]$m) Write-Host $m -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host $m -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host $m -ForegroundColor Yellow }

function New-PortableZip {
    <#
        Builds the zip entry by entry instead of using ZipFile.CreateFromDirectory.

        On .NET Framework - which is what Windows PowerShell 5.1 runs on -
        CreateFromDirectory writes entry names with backslashes. The ZIP format
        specifies forward slashes, so those archives come out flat or with
        literally-named files in 7-Zip, macOS Archive Utility and Linux unzip.
        This archive is meant to be carried to another machine, so it has to be
        correct everywhere, not just here.
    #>
    param(
        [Parameter(Mandatory)] [string] $SourceDir,
        [Parameter(Mandatory)] [string] $ZipPath
    )

    $src = (Resolve-Path -LiteralPath $SourceDir).Path.TrimEnd('\')
    $fs  = [System.IO.File]::Open($ZipPath, [System.IO.FileMode]::CreateNew)
    try {
        $zip = New-Object System.IO.Compression.ZipArchive(
            $fs, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($f in @(Get-ChildItem -LiteralPath $src -Recurse -File)) {
                $rel = $f.FullName.Substring($src.Length + 1) -replace '\\', '/'
                $entry = $zip.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = $f.LastWriteTime

                $in = [System.IO.File]::OpenRead($f.FullName)
                try {
                    $out = $entry.Open()
                    try { $in.CopyTo($out) } finally { $out.Dispose() }
                } finally { $in.Dispose() }
            }
        } finally { $zip.Dispose() }
    } finally { $fs.Dispose() }
}

# ---- Resolve the staging folder ----------------------------------------------------

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
if (-not $modsRoot) { throw "ModsRoot is not set. Put it in config.json or pass -StagingMods." }
if (-not (Test-Path -LiteralPath $modsRoot -PathType Container)) {
    throw "Staging mods folder '$modsRoot' does not exist."
}
$modsRoot = (Resolve-Path -LiteralPath $modsRoot).Path.TrimEnd('\')

# ---- Work out what goes in ---------------------------------------------------------

# Skip the updater's half-finished extract folders - they are not mods.
$modDirs = @(Get-ChildItem -LiteralPath $modsRoot -Directory |
             Where-Object { -not $_.Name.StartsWith('.') })

if (-not $modDirs) { throw "No mod folders in '$modsRoot' - nothing to export." }

$loadOrder = Join-Path $modsRoot 'mod_load_order.txt'
$manifest  = Join-Path $PSScriptRoot 'darktide-modpack.lock.json'

if (-not $OutFile) {
    if (-not $OutDir) { $OutDir = Split-Path -Parent $modsRoot }
    $stamp   = Get-Date -Format 'yyyyMMdd'
    $OutFile = Join-Path $OutDir "darktide-loadout-$stamp.zip"
}
$outParent = Split-Path -Parent $OutFile
if ($outParent -and -not (Test-Path -LiteralPath $outParent)) {
    New-Item -ItemType Directory -Path $outParent -Force | Out-Null
}

# Refuse to write the archive inside the folder being archived - it would try to
# include itself as it grows.
$outFull = [System.IO.Path]::GetFullPath($OutFile)
if ($outFull.StartsWith($modsRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to write the archive inside the mods folder being archived. Use -OutDir."
}

if ((Test-Path -LiteralPath $OutFile) -and -not $Force) {
    throw "'$OutFile' already exists. Pass -Force to overwrite."
}

# ---- Report ------------------------------------------------------------------------

$totalBytes = 0
foreach ($d in $modDirs) {
    $totalBytes += (Get-ChildItem -LiteralPath $d.FullName -Recurse -File -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum).Sum
}

Write-Step '=== Darktide loadout export ==='
Write-Host  "Staging : $modsRoot"
Write-Host  "Archive : $OutFile"
Write-Host  "Mods    : $($modDirs.Count)  ($([math]::Round($totalBytes / 1MB, 1)) MB on disk)"

$versioned = @($modDirs | Where-Object {
    Test-Path -LiteralPath (Join-Path $_.FullName '.nexus-mod.json') }).Count
Write-Host  "Tracked : $versioned of $($modDirs.Count) have a recorded version"
Write-Host  ''

if (-not $PSCmdlet.ShouldProcess($OutFile, "Export $($modDirs.Count) mod folder(s)")) { return }

# ---- Build -------------------------------------------------------------------------

# Stage the exact set we want, then zip that. Simpler and safer than filtering
# entries out of an archive after the fact.
$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-export-" + [guid]::NewGuid().ToString('N').Substring(0, 10))
New-Item -ItemType Directory -Path $stage -Force | Out-Null

try {
    Write-Step 'Collecting mods...'
    foreach ($d in $modDirs) {
        $rc = @($d.FullName, (Join-Path $stage $d.Name), '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1')
        $eap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & robocopy.exe @rc | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "Could not copy '$($d.Name)' (robocopy $LASTEXITCODE)." }
        } finally { $ErrorActionPreference = $eap }
    }

    if (Test-Path -LiteralPath $loadOrder) {
        Copy-Item -LiteralPath $loadOrder -Destination (Join-Path $stage 'mod_load_order.txt') -Force
    } else {
        Write-Warn 'No mod_load_order.txt in staging - the archive will not carry one.'
    }

    if (-not $NoManifest -and (Test-Path -LiteralPath $manifest)) {
        Copy-Item -LiteralPath $manifest -Destination (Join-Path $stage 'darktide-modpack.lock.json') -Force
    }

    # A note for whoever opens this later, including you in a year.
    $readme = @(
        'Darktide loadout backup',
        '=======================',
        '',
        "Exported : $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC",
        "Mods     : $($modDirs.Count)",
        '',
        'Restore:',
        '  Expand-Archive -LiteralPath <this zip> -DestinationPath <your staging mods folder>',
        '  .\darktide.ps1 deploy -Apply',
        '',
        'These mod files are the work of their individual authors, published on Nexus Mods.',
        'This archive is a personal backup. Do not redistribute it. darktide-modpack.lock.json',
        'lists each mod and links to its page.'
    )
    $readme | Set-Content -LiteralPath (Join-Path $stage 'README.txt') -Encoding UTF8

    Write-Step 'Compressing...'
    if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force }
    New-PortableZip -SourceDir $stage -ZipPath $OutFile
}
finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

$size = [math]::Round((Get-Item -LiteralPath $OutFile).Length / 1MB, 1)
Write-Host ''
Write-Ok "Wrote $OutFile ($size MB)"
Write-Host ''
Write-Host 'Restore it on another machine with:' -ForegroundColor Cyan
Write-Host "  Expand-Archive -LiteralPath '$OutFile' -DestinationPath '<ModsRoot>'"
Write-Host '  .\darktide.ps1 deploy -Apply'
Write-Host ''
Write-Warn 'Personal backup only - it holds other authors'' mod files. Do not republish it.'
