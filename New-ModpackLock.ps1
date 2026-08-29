<#
.SYNOPSIS
    Generates darktide-modpack.lock.json from an installed Darktide mods folder.

.DESCRIPTION
    The lockfile is a MANIFEST, not a mod archive. It records which mods a setup uses,
    at which versions, and in which load order - enough for anyone to reproduce the
    loadout by downloading the mods themselves from Nexus.

    No third-party mod content is ever copied or published by this script.

    Version, for each mod, comes from the first of:
      1. .nexus-mod.json  - written by Update-DarktideMods.ps1 on install
      2. info.json        - shipped by the mod author
      3. nothing          - recorded as null, which is honest rather than guessed

.PARAMETER ModsRoot
    The Darktide Mod Loader mods folder, e.g. D:\Darktide\mods

.PARAMETER OutFile
    Where to write the lockfile. Defaults to darktide-modpack.lock.json next to this script.

.PARAMETER Name
    Human-readable name for the loadout.

.PARAMETER NoHash
    Skip per-mod content hashing. Faster, but the lockfile can no longer be used to
    detect that an installed mod folder has drifted from what was locked.

.EXAMPLE
    .\New-ModpackLock.ps1 -ModsRoot D:\Darktide\mods
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $ModsRoot,
    [string] $OutFile = (Join-Path $PSScriptRoot 'darktide-modpack.lock.json'),
    [string] $MapPath = (Join-Path $PSScriptRoot 'mods-map.json'),
    [string] $Name    = 'Darktide loadout',
    [string] $GameDomain = 'warhammer40kdarktide',
    [switch] $NoHash
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:IgnoreFolders = @('base')

function Get-FolderHash {
    <#
      Stable content hash of a mod folder: SHA-256 over each file's relative path and
      its own SHA-256, in sorted order. Independent of timestamps and enumeration order.
      DMF keeps user settings in %APPDATA%, not in the mod folder, so this stays stable
      across play sessions.
    #>
    param([string] $Path)

    $files = Get-ChildItem -LiteralPath $Path -File -Recurse -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -ne '.nexus-mod.json' } |
             Sort-Object { $_.FullName.Substring($Path.Length).ToLowerInvariant() }

    if (-not $files) { return $null }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $acc = New-Object System.Text.StringBuilder
        foreach ($f in $files) {
            $rel = $f.FullName.Substring($Path.Length).TrimStart('\').Replace('\', '/').ToLowerInvariant()
            $fh  = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
            [void]$acc.Append("$rel`:$fh`n")
        }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($acc.ToString())
        return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $ModsRoot -PathType Container)) {
    throw "ModsRoot '$ModsRoot' does not exist."
}
$ModsRoot = (Resolve-Path -LiteralPath $ModsRoot).Path

# Load the folder -> Nexus id map, if present.
$map = @{}
if (Test-Path -LiteralPath $MapPath) {
    $raw = Get-Content -LiteralPath $MapPath -Raw -Encoding UTF8
    if ($raw.Trim()) {
        foreach ($p in ($raw | ConvertFrom-Json).PSObject.Properties) { $map[$p.Name] = $p.Value }
    }
}

# Load order, comments stripped.
$loadOrder = @()
$loPath = Join-Path $ModsRoot 'mod_load_order.txt'
if (Test-Path -LiteralPath $loPath) {
    $loadOrder = @(Get-Content -LiteralPath $loPath -Encoding UTF8 |
                   ForEach-Object { $_.Trim() } |
                   Where-Object { $_ -and -not $_.StartsWith('--') })
}

$mods = New-Object System.Collections.Generic.List[object]

foreach ($dir in (Get-ChildItem -LiteralPath $ModsRoot -Directory | Sort-Object Name)) {
    if ($script:IgnoreFolders -contains $dir.Name) { continue }
    if ($dir.Name.StartsWith('.')) { continue }

    $display  = $dir.Name
    $version  = $null
    $modId    = $null
    $source   = 'none'

    $state = Join-Path $dir.FullName '.nexus-mod.json'
    if (Test-Path -LiteralPath $state) {
        $s = Get-Content -LiteralPath $state -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($s.PSObject.Properties.Name -contains 'version' -and $s.version) { $version = "$($s.version)"; $source = '.nexus-mod.json' }
        if ($s.PSObject.Properties.Name -contains 'modId'   -and $s.modId)   { $modId   = [int]$s.modId }
        if ($s.PSObject.Properties.Name -contains 'name'    -and $s.name)    { $display = "$($s.name)" }
    }

    $info = Join-Path $dir.FullName 'info.json'
    if (Test-Path -LiteralPath $info) {
        $j = Get-Content -LiteralPath $info -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.PSObject.Properties.Name -contains 'version' -and $j.version) { $version = "$($j.version)"; $source = 'info.json' }
        if ($j.PSObject.Properties.Name -contains 'name'    -and $j.name)    { $display = "$($j.name)" }
        if ($j.PSObject.Properties.Name -contains 'homepage' -and $j.homepage) {
            $m = [regex]::Match("$($j.homepage)", '/mods/(\d+)')
            if ($m.Success) { $modId = [int]$m.Groups[1].Value }
        }
    }

    # An explicit map entry wins - it is the hand-verified one.
    if ($map.ContainsKey($dir.Name)) {
        $e = $map[$dir.Name]
        if ($e.PSObject.Properties.Name -contains 'modId' -and $e.modId) { $modId = [int]$e.modId }
        if ($e.PSObject.Properties.Name -contains 'name'  -and $e.name -and $display -eq $dir.Name) { $display = "$($e.name)" }
    }

    $hash = $null
    if (-not $NoHash) {
        Write-Host "  hashing $($dir.Name)..."
        $hash = Get-FolderHash -Path $dir.FullName
    }

    $mods.Add([ordered]@{
        folder        = $dir.Name
        name          = $display
        modId         = $modId
        version       = $version
        versionSource = $source
        url           = $(if ($modId) { "https://www.nexusmods.com/$GameDomain/mods/$modId" } else { $null })
        contentSha256 = $hash
    })
}

$lock = [ordered]@{
    schemaVersion = 1
    name          = $Name
    game          = $GameDomain
    generatedAt   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    generatedBy   = 'New-ModpackLock.ps1'
    note          = 'This is a manifest of which mods this loadout uses. It contains no mod files. Download each mod from its Nexus page.'
    modCount      = $mods.Count
    loadOrder     = $loadOrder
    mods          = $mods
}

($lock | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $OutFile -Encoding UTF8

$mapped   = @($mods | Where-Object { $_.modId }).Count
$versioned = @($mods | Where-Object { $_.version }).Count
Write-Host ''
Write-Host "Wrote $OutFile" -ForegroundColor Green
Write-Host "  mods:      $($mods.Count)"
Write-Host "  with id:   $mapped"
Write-Host "  with ver:  $versioned"
Write-Host "  loadOrder: $($loadOrder.Count) entries"
