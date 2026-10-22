<#
.SYNOPSIS
    Before 'update -Apply': what is each archive in the download folder, and what is
    still left to download.

.DESCRIPTION
    Reads every file in DownloadDir and classifies it against staging (ModsRoot) and
    the lockfile, using the same rules the offline updater uses to decide what to
    install. Read-only: archives are inspected with ZipFile.OpenRead and never
    extracted, and nothing is written except an -OutFile you ask for.

    Per archive:

        UPGRADE             newer than the staged copy; update -Apply installs it
        SAME                the staged copy is already this version
        OLDER               older than staged; update skips it (unless -Force)
        NEW-IN-LOCK         in the lockfile but not staged; update installs it
        NOT-IN-LOCK         a DMF mod that is neither staged nor in the lockfile;
                            update -Apply would install it as a NEW mod
        ID-MISMATCH         the Nexus id in the filename is not the id recorded for
                            the mod folder it would replace. Two different Nexus
                            mods can ship the same folder name, and the updater
                            matches on the folder alone, so this would overwrite one
                            mod with another. Check before applying.
        NOT-DMF             no .mod file inside; update ignores it
        UNSUPPORTED-FORMAT  .7z or .rar. The offline updater only reads .zip and
                            skips these without saying so
        VERSION-UNKNOWN     renamed file and no info.json; update skips it (unless -Force)
        SUPERSEDED          another zip for the same mod wins (newer, or the same
                            version downloaded twice); safe to delete

    Then MISSING: mods in the lockfile that are not staged and have no archive here,
    with their Nexus page, so you know what is left to download.

    No API key and no network are involved at any point.

.PARAMETER ConfigPath
    config.json to read DownloadDir and ModsRoot from. Defaults to the one beside
    this script.

.PARAMETER DownloadDir
    Overrides DownloadDir from the config.

.PARAMETER ModsRoot
    Overrides ModsRoot (staging) from the config.

.PARAMETER LockPath
    The lockfile to compare against. Defaults to darktide-modpack.lock.json beside
    this script.

.PARAMETER MapPath
    mods-map.json, read for Nexus ids the lockfile lacks and for 'pinned' flags.
    Defaults to the one beside this script. Optional.

.PARAMETER Only
    Limit to these mod folders. Archives that resolve to no folder are left out.

.PARAMETER Skip
    Exclude these mod folders.

.PARAMETER OutFile
    Also write the result to this file: .json for machine-readable output, .md for
    a markdown report. Refuses to overwrite an existing file without -Force, and
    refuses a path inside the staging folder.

.PARAMETER Force
    Overwrite an existing -OutFile.

.EXAMPLE
    .\Test-DownloadedMods.ps1
    Classify every archive in the download folder and list what is still missing.

.EXAMPLE
    .\Test-DownloadedMods.ps1 -OutFile intake.md
    The same, and keep it as a markdown report.

.EXAMPLE
    .\Test-DownloadedMods.ps1 -Only markers_aio,scoreboard -OutFile intake.json -Force
    Just two mods, as JSON, replacing an earlier intake.json.

.NOTES
    Exit code 0 when finished, 1 when an ID-MISMATCH was found so it cannot scroll
    past unnoticed. A missing config, download folder, staging folder or lockfile
    is a terminating error.

    The parsers here (Get-NexusFileNameParts, Get-ArchiveModLayout,
    Get-ArchiveModVersion, Compare-ModVersion) are copies of the ones in
    Update-DarktideMods.ps1, which cannot be dot-sourced because it runs on load.
    If the updater's rules change, change these too, or this report stops
    describing what update -Apply will do.
#>

[CmdletBinding()]
param(
    [string]   $ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string]   $DownloadDir,
    [string]   $ModsRoot,
    [string]   $LockPath   = (Join-Path $PSScriptRoot 'darktide-modpack.lock.json'),
    [string]   $MapPath    = (Join-Path $PSScriptRoot 'mods-map.json'),
    [string[]] $Only,
    [string[]] $Skip,
    [string]   $OutFile,
    [switch]   $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

function Write-Step { param([string] $Message) Write-Host $Message -ForegroundColor Cyan }
function Write-Ok   { param([string] $Message) Write-Host $Message -ForegroundColor Green }
function Write-Warn { param([string] $Message) Write-Host $Message -ForegroundColor Yellow }
function Write-Err  { param([string] $Message) Write-Host $Message -ForegroundColor Red }

# ----------------------------------------------------------------------------------
# Parsers copied from Update-DarktideMods.ps1. Logging is returned to the caller
# instead of going through Write-Log; the decisions are the same.
# ----------------------------------------------------------------------------------

function Compare-ModVersion {
    <#
      Returns 1 if A > B, -1 if A < B, 0 if equal/indeterminate.
      Handles '2.14.4', '4.7.06', 'v1.2', '26.06.24' - anything Nexus authors invent.
    #>
    param([string] $A, [string] $B)

    if (-not $A -and -not $B) { return 0 }
    if (-not $A) { return -1 }
    if (-not $B) { return 1 }
    if ($A -eq $B) { return 0 }

    $na = [regex]::Matches($A, '\d+') | ForEach-Object { [int64]$_.Value }
    $nb = [regex]::Matches($B, '\d+') | ForEach-Object { [int64]$_.Value }
    $na = @($na); $nb = @($nb)

    if ($na.Count -eq 0 -or $nb.Count -eq 0) {
        return [Math]::Sign([string]::Compare($A, $B, $true))
    }

    $len = [Math]::Max($na.Count, $nb.Count)
    for ($i = 0; $i -lt $len; $i++) {
        $x = if ($i -lt $na.Count) { $na[$i] } else { 0 }
        $y = if ($i -lt $nb.Count) { $nb[$i] } else { 0 }
        if ($x -gt $y) { return 1 }
        if ($x -lt $y) { return -1 }
    }
    return 0
}

function Get-NexusFileNameParts {
    <#
      Parses a stock Nexus download filename WITHOUT needing to know the mod id first:
        '<Mod Name>-<modId>-<version with dashes>-<epoch>.zip'
        'Markers Improved All-in-one-447-2-14-4-1719209900.zip' -> id 447, version 2.14.4
      The trailing 9+ digit epoch is what makes this unambiguous, so this only matches
      files that still carry their original Nexus name.
      Returns $null when the name does not fit the pattern.
    #>
    param([string] $FileName)

    $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    # Browsers append ' (1)' on a duplicate download - tolerate it.
    $base = [regex]::Replace($base, '\s*\(\d+\)$', '')

    $m = [regex]::Match($base, '^(?<name>.+?)-(?<id>\d{1,7})-(?<v>\d+(?:-\d+)*)-(?<ts>\d{9,})$')
    if (-not $m.Success) { return $null }

    return [pscustomobject]@{
        Name    = $m.Groups['name'].Value
        ModId   = [int]$m.Groups['id'].Value
        Version = ($m.Groups['v'].Value -replace '-', '.')
    }
}

function Get-ArchiveModLayout {
    <#
      Which mod folder a zip installs into, decided the way the updater decides it:
      DMF requires the folder name to equal the name in <Name>.mod, so the shallowest
      .mod outside base/ is the authority - not the archive's top folder or its file
      name. Returns ModName (or $null) and, when $null, the Problem in words.
    #>
    param([string] $ZipPath)

    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        # Same separator normalisation as Expand-ModArchive: Windows tools often
        # write '\', and a backslash-only path would miss the '/' filters below.
        $modEntry = $zip.Entries |
            Where-Object {
                $n = $_.FullName -replace '\\', '/'
                $n -match '\.mod$' -and $n -notmatch '(^|/)base/'
            } |
            Sort-Object { (($_.FullName -replace '\\', '/') -split '/').Count } |
            Select-Object -First 1
        if (-not $modEntry) {
            return [pscustomobject]@{ ModName = $null; Problem = 'no .mod file inside, so it is not a DMF mod' }
        }

        $parts   = ($modEntry.FullName -replace '\\', '/') -split '/'
        $modName = [System.IO.Path]::GetFileNameWithoutExtension($parts[-1])

        # The updater refuses these outright, because the name becomes a folder that
        # gets deleted and recreated.
        if ([string]::IsNullOrWhiteSpace($modName) -or
            $modName -in @('.', '..', 'base', 'mods') -or
            $modName -match '[\\/:*?"<>|\[\]]' -or
            $modName -ne [System.IO.Path]::GetFileName($modName)) {
            return [pscustomobject]@{ ModName = $null; Problem = "resolves to an unsafe mod name '$modName'; update refuses it" }
        }

        return [pscustomobject]@{ ModName = $modName; Problem = '' }
    } catch {
        return [pscustomobject]@{ ModName = $null; Problem = "cannot be read as a zip: $($_.Exception.Message)" }
    } finally {
        if ($zip) { $zip.Dispose() }
    }
}

function Get-ArchiveModVersion {
    <# Reads version out of an info.json inside the archive. Most reliable source. #>
    param([string] $ZipPath)
    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        $e = $zip.Entries |
             Where-Object { $_.Name -eq 'info.json' } |
             Sort-Object { (($_.FullName -replace '\\', '/') -split '/').Count } |
             Select-Object -First 1
        if (-not $e) { return $null }
        $sr = New-Object System.IO.StreamReader($e.Open())
        try { $j = $sr.ReadToEnd() | ConvertFrom-Json } finally { $sr.Dispose() }
        if ($j.PSObject.Properties.Name -contains 'version' -and $j.version) { return "$($j.version)" }
        return $null
    } catch {
        # Same as the updater: an unreadable info.json means "no version from the
        # archive", and the filename is tried next.
        return $null
    } finally {
        if ($zip) { $zip.Dispose() }
    }
}

# ----------------------------------------------------------------------------------
# Inputs
# ----------------------------------------------------------------------------------

function Get-JsonFile {
    <# Parsed JSON, or $null with a warning. A corrupt side file is reported, not fatal. #>
    param([string] $Path, [string] $What)
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if (-not $raw -or -not $raw.Trim()) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch {
        Write-Warn "  $What is not valid JSON - ignoring it: $Path"
        return $null
    }
}

function Get-PropertyValue {
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $null
}

function ConvertTo-ModId {
    <# A positive integer Nexus id, or 0. Zero and null both mean 'not known'. #>
    param($Value)
    if ($null -eq $Value) { return 0 }
    $n = 0
    if ([int]::TryParse("$Value", [ref]$n) -and $n -gt 0) { return $n }
    return 0
}

function Resolve-UserPath {
    <# Relative to the PowerShell location, not the process directory. #>
    param([string] $Path)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

# OutFile is checked before any work, so a mistake costs nothing.
$outFull = $null
$outKind = $null
if ($OutFile) {
    $ext = [System.IO.Path]::GetExtension($OutFile).ToLowerInvariant()
    if ($ext -eq '.json')   { $outKind = 'json' }
    elseif ($ext -eq '.md') { $outKind = 'md' }
    else { throw "-OutFile must end in .json or .md, not '$OutFile'." }

    $outFull = Resolve-UserPath $OutFile
    if ((Test-Path -LiteralPath $outFull) -and -not $Force) {
        throw "'$outFull' already exists. Pass -Force to overwrite it."
    }
    $outParent = Split-Path -Parent $outFull
    if ($outParent -and -not (Test-Path -LiteralPath $outParent -PathType Container)) {
        throw "The folder for -OutFile does not exist: $outParent"
    }
}

# ---- Config: only the two paths this needs. ApiKey is never read. ----------------

$cfgDownload = ''
$cfgMods     = ''
$cfgGame     = ''
if (Test-Path -LiteralPath $ConfigPath) {
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $cfgDownload = "$(Get-PropertyValue $cfg 'DownloadDir')".Trim()
    $cfgMods     = "$(Get-PropertyValue $cfg 'ModsRoot')".Trim()
    $cfgGame     = "$(Get-PropertyValue $cfg 'GameDomain')".Trim()
} elseif (-not ($DownloadDir -and $ModsRoot)) {
    throw "No config at '$ConfigPath'. Run .\darktide.ps1 init, or pass -DownloadDir and -ModsRoot."
}

if ($DownloadDir) { $cfgDownload = $DownloadDir }
if ($ModsRoot)    { $cfgMods     = $ModsRoot }
# The updater's own default, so this looks where update will look.
if (-not $cfgDownload -and $env:USERPROFILE) { $cfgDownload = Join-Path $env:USERPROFILE 'Downloads' }

if (-not $cfgDownload) { throw 'DownloadDir is not set. Put it in config.json or pass -DownloadDir.' }
if (-not (Test-Path -LiteralPath $cfgDownload -PathType Container)) {
    throw "DownloadDir '$cfgDownload' does not exist. Set it in config.json or pass -DownloadDir."
}
if (-not $cfgMods) { throw 'ModsRoot is not set. Put it in config.json or pass -ModsRoot.' }
if (-not (Test-Path -LiteralPath $cfgMods -PathType Container)) {
    throw "ModsRoot '$cfgMods' does not exist."
}
$downloadFull = (Resolve-Path -LiteralPath $cfgDownload).ProviderPath
$modsFull     = (Resolve-Path -LiteralPath $cfgMods).ProviderPath

# Staging is mirrored into the game folder; a report file has no business in it.
if ($outFull) {
    $stagingPrefix = $modsFull.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $outCheck = [System.IO.Path]::GetFullPath($outFull)
    if ($outCheck.StartsWith($stagingPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "-OutFile '$outFull' is inside the staging folder, which deploy mirrors into the game. Write it somewhere else."
    }
}

if (-not (Test-Path -LiteralPath $LockPath)) {
    throw "No lockfile at '$LockPath'. Generate one with: .\darktide.ps1 lock"
}
$lock = Get-Content -LiteralPath $LockPath -Raw -Encoding UTF8 | ConvertFrom-Json
$game = "$(Get-PropertyValue $lock 'game')"
if (-not $game) { $game = $(if ($cfgGame) { $cfgGame } else { 'warhammer40kdarktide' }) }

# Hashtables are case-insensitive, which matches how Windows treats folder names.
$lockByFolder = @{}
$lockById     = @{}
foreach ($m in @(Get-PropertyValue $lock 'mods')) {
    if ($null -eq $m) { continue }
    $folder = "$(Get-PropertyValue $m 'folder')"
    if (-not $folder) { continue }
    $lockByFolder[$folder] = $m
    $id = ConvertTo-ModId (Get-PropertyValue $m 'modId')
    if ($id -and -not $lockById.ContainsKey($id)) { $lockById[$id] = $folder }
}

$mapByFolder = @{}
$mapById     = @{}
if ($MapPath -and (Test-Path -LiteralPath $MapPath)) {
    $rawMap = Get-JsonFile -Path $MapPath -What 'mods-map.json'
    if ($rawMap) {
        foreach ($p in $rawMap.PSObject.Properties) {
            $mapByFolder[$p.Name] = $p.Value
            $id = ConvertTo-ModId (Get-PropertyValue $p.Value 'modId')
            if ($id -and -not $mapById.ContainsKey($id)) { $mapById[$id] = $p.Name }
        }
    }
}

# ---- Staging, read the way Get-LocalMods in the updater reads it ------------------

$staged = @{}
foreach ($dir in @(Get-ChildItem -LiteralPath $modsFull -Directory -ErrorAction SilentlyContinue)) {
    if ($dir.Name.StartsWith('.') -or $dir.Name -eq 'base') { continue }

    $version  = $null
    $modId    = 0
    $idSource = ''

    $state = Join-Path $dir.FullName '.nexus-mod.json'
    if (Test-Path -LiteralPath $state) {
        $s = Get-JsonFile -Path $state -What "$($dir.Name)\.nexus-mod.json"
        $v = Get-PropertyValue $s 'version'
        if ($v) { $version = "$v" }
        $id = ConvertTo-ModId (Get-PropertyValue $s 'modId')
        if ($id) { $modId = $id; $idSource = 'staged .nexus-mod.json' }
    }

    # info.json is the author's own and wins on version, as it does in the updater.
    $info = Join-Path $dir.FullName 'info.json'
    if (Test-Path -LiteralPath $info) {
        $j = Get-JsonFile -Path $info -What "$($dir.Name)\info.json"
        $v = Get-PropertyValue $j 'version'
        if ($v) { $version = "$v" }
        $homepage = "$(Get-PropertyValue $j 'homepage')"
        $hm = [regex]::Match($homepage, '/mods/(\d+)')
        if ($hm.Success) { $modId = [int]$hm.Groups[1].Value; $idSource = 'staged info.json homepage' }
    }

    $staged[$dir.Name] = [pscustomobject]@{ Version = $version; ModId = $modId; IdSource = $idSource }
}

function Get-ExpectedModId {
    <#
      The Nexus id this folder is known by: staging first (what is actually there),
      then the lockfile, then mods-map.json. Returns Id 0 when nobody knows.
    #>
    param([string] $Folder)
    if ($staged.ContainsKey($Folder) -and $staged[$Folder].ModId) {
        return [pscustomobject]@{ Id = $staged[$Folder].ModId; Source = $staged[$Folder].IdSource }
    }
    if ($lockByFolder.ContainsKey($Folder)) {
        $id = ConvertTo-ModId (Get-PropertyValue $lockByFolder[$Folder] 'modId')
        if ($id) { return [pscustomobject]@{ Id = $id; Source = 'lockfile' } }
    }
    if ($mapByFolder.ContainsKey($Folder)) {
        $id = ConvertTo-ModId (Get-PropertyValue $mapByFolder[$Folder] 'modId')
        if ($id) { return [pscustomobject]@{ Id = $id; Source = 'mods-map.json' } }
    }
    return [pscustomobject]@{ Id = 0; Source = '' }
}

$onlyFolders = @($Only | Where-Object { $_ })
$skipFolders = @($Skip | Where-Object { $_ })

function Test-Selected {
    <# -Only / -Skip by folder. An archive with no folder is never 'only' anything. #>
    param([string] $Folder)
    if ($onlyFolders.Count -gt 0 -and (-not $Folder -or $onlyFolders -notcontains $Folder)) { return $false }
    if ($skipFolders.Count -gt 0 -and $Folder -and $skipFolders -contains $Folder) { return $false }
    return $true
}

function Get-PageUrl {
    param([string] $Folder, [int] $ModId)
    if ($Folder -and $lockByFolder.ContainsKey($Folder)) {
        $u = "$(Get-PropertyValue $lockByFolder[$Folder] 'url')"
        if ($u) { return $u }
    }
    if ($ModId) { return "https://www.nexusmods.com/$game/mods/$ModId" }
    return ''
}

# ----------------------------------------------------------------------------------
# Classify
# ----------------------------------------------------------------------------------

# Newest first, the order the updater walks them in: on a version tie it keeps the
# first one it saw, so mtime breaks ties here the same way.
$files = @(Get-ChildItem -LiteralPath $downloadFull -File -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending)

$rows       = New-Object System.Collections.Generic.List[object]
$candidates = New-Object System.Collections.Generic.List[object]
$ignored    = 0

function New-Row {
    param([System.IO.FileInfo] $File)
    $parts = Get-NexusFileNameParts -FileName $File.Name
    return [pscustomobject]@{
        File            = $File.Name
        Status          = ''
        Mod             = ''
        ArchiveVersion  = ''
        VersionSource   = ''
        StagedVersion   = ''
        NexusModId      = $(if ($parts) { $parts.ModId } else { 0 })
        ExpectedModId   = 0
        InLock          = $false
        Staged          = $false
        Url             = ''
        Note            = ''
        FilenameVersion = $(if ($parts) { $parts.Version } else { '' })
    }
}

foreach ($f in $files) {
    $ext = $f.Extension.ToLowerInvariant()

    if ($ext -eq '.7z' -or $ext -eq '.rar') {
        $row = New-Row -File $f
        $row.Status = 'UNSUPPORTED-FORMAT'
        $row.ArchiveVersion = $row.FilenameVersion
        if ($row.ArchiveVersion) { $row.VersionSource = 'filename' }
        if ($row.NexusModId) {
            if ($lockById.ContainsKey($row.NexusModId))    { $row.Mod = $lockById[$row.NexusModId] }
            elseif ($mapById.ContainsKey($row.NexusModId)) { $row.Mod = $mapById[$row.NexusModId] }
        }
        if (-not (Test-Selected $row.Mod)) { continue }
        if ($row.Mod) {
            $row.InLock = $lockByFolder.ContainsKey($row.Mod)
            $row.Staged = $staged.ContainsKey($row.Mod)
            if ($row.Staged) { $row.StagedVersion = "$($staged[$row.Mod].Version)" }
        }
        $row.Url  = Get-PageUrl -Folder $row.Mod -ModId $row.NexusModId
        $row.Note = "update only reads .zip and skips $ext files without a word. Extract it and re-zip, or download the .zip if the page offers one."
        $rows.Add($row)
        continue
    }

    if ($ext -ne '.zip') { $ignored++; continue }

    $row    = New-Row -File $f
    $layout = Get-ArchiveModLayout -ZipPath $f.FullName
    if (-not $layout.ModName) {
        if (-not (Test-Selected '')) { continue }
        $row.Status = 'NOT-DMF'
        $row.Note   = "$($layout.Problem). update ignores it."
        $rows.Add($row)
        continue
    }

    $row.Mod = $layout.ModName
    if (-not (Test-Selected $row.Mod)) { continue }

    $version = Get-ArchiveModVersion -ZipPath $f.FullName
    if ($version) { $row.VersionSource = 'info.json' }
    elseif ($row.FilenameVersion) { $version = $row.FilenameVersion; $row.VersionSource = 'filename' }
    $row.ArchiveVersion = "$version"

    $row.InLock = $lockByFolder.ContainsKey($row.Mod)
    $row.Staged = $staged.ContainsKey($row.Mod)
    if ($row.Staged) { $row.StagedVersion = "$($staged[$row.Mod].Version)" }
    $row.Url = Get-PageUrl -Folder $row.Mod -ModId $row.NexusModId

    $candidates.Add($row)
    $rows.Add($row)
}

# For each folder, the archive update -Apply would pick: highest version, a known
# version over an unknown one, and on a tie the newest file. Pass 2 of
# Invoke-OfflineUpdate, applied to the same ordering.
$winners = @{}
foreach ($c in $candidates) {
    if (-not $winners.ContainsKey($c.Mod)) { $winners[$c.Mod] = $c; continue }
    $cur = $winners[$c.Mod]
    if ($c.ArchiveVersion -and $cur.ArchiveVersion) {
        if ((Compare-ModVersion $c.ArchiveVersion $cur.ArchiveVersion) -gt 0) { $winners[$c.Mod] = $c }
    } elseif ($c.ArchiveVersion -and -not $cur.ArchiveVersion) {
        $winners[$c.Mod] = $c
    }
}

foreach ($c in $candidates) {
    $winner   = $winners[$c.Mod]
    $isWinner = [object]::ReferenceEquals($winner, $c)
    $pinned   = $false
    if ($mapByFolder.ContainsKey($c.Mod)) { $pinned = [bool](Get-PropertyValue $mapByFolder[$c.Mod] 'pinned') }

    # A different mod that happens to use the same folder name. The updater
    # matches on folder alone, so it would install this over the one you have.
    $expected = Get-ExpectedModId -Folder $c.Mod
    $c.ExpectedModId = $expected.Id
    if ($c.NexusModId -and $expected.Id -and $c.NexusModId -ne $expected.Id) {
        $c.Status = 'ID-MISMATCH'
        $what = if ($isWinner) {
            "update -Apply would install it as '$($c.Mod)'$(if ($c.Staged) { ', replacing the staged copy' })"
        } else {
            "another zip wins today, but this one would install as '$($c.Mod)' on its own"
        }
        $c.Note = "filename says Nexus mod $($c.NexusModId), but '$($c.Mod)' is mod $($expected.Id) ($($expected.Source)). Same folder name, different mod: $what. Check you downloaded the right mod."
        continue
    }

    if (-not $isWinner) {
        $c.Status = 'SUPERSEDED'
        $why = if (-not $c.ArchiveVersion) {
            'its version is unknown'
        } elseif ((Compare-ModVersion $c.ArchiveVersion $winner.ArchiveVersion) -eq 0) {
            'same version, downloaded twice'
        } else {
            "older than $($winner.ArchiveVersion)"
        }
        $c.Note = "$why; update uses '$($winner.File)'. Safe to delete."
        continue
    }

    if (-not $c.ArchiveVersion) {
        $c.Status = 'VERSION-UNKNOWN'
        $c.Note   = 'renamed file and no info.json inside, so update skips it. Install deliberately with: update -Apply -Force -Only ' + $c.Mod
    } elseif ($c.Staged) {
        if (-not $c.StagedVersion) {
            $c.Status = 'UPGRADE'
            $c.Note   = 'no version recorded in staging; update installs it and starts tracking the version'
        } else {
            $cmp = Compare-ModVersion $c.ArchiveVersion $c.StagedVersion
            if ($cmp -gt 0)     { $c.Status = 'UPGRADE' }
            elseif ($cmp -lt 0) { $c.Status = 'OLDER'; $c.Note = 'older than staging; update skips it unless -Force' }
            else                { $c.Status = 'SAME' }
        }
        if (-not $c.InLock) {
            $c.Note = (@($c.Note, "staged but not in the lockfile; run: .\darktide.ps1 lock") | Where-Object { $_ }) -join '; '
        }
        if ($pinned) {
            $c.Note = (@($c.Note, 'pinned in mods-map.json, so update leaves it alone') | Where-Object { $_ }) -join '; '
        }
    } elseif ($c.InLock) {
        $c.Status = 'NEW-IN-LOCK'
        $c.Note   = 'in the lockfile but not staged; update installs it'
    } else {
        $c.Status = 'NOT-IN-LOCK'
        $c.Note   = 'not staged and not in the lockfile; update -Apply would install it as a NEW mod and add it to mod_load_order.txt. Delete it if you did not mean to add a mod.'
    }
}

# ---- What is still to download ------------------------------------------------------

$covered = @{}
foreach ($r in $rows) { if ($r.Mod) { $covered[$r.Mod] = $true } }

$missing   = New-Object System.Collections.Generic.List[object]
$restCount = 0
foreach ($m in @(Get-PropertyValue $lock 'mods')) {
    if ($null -eq $m) { continue }
    $folder = "$(Get-PropertyValue $m 'folder')"
    if (-not $folder -or -not (Test-Selected $folder)) { continue }
    if ($covered.ContainsKey($folder)) { continue }
    if ($staged.ContainsKey($folder)) { $restCount++; continue }
    $id = ConvertTo-ModId (Get-PropertyValue $m 'modId')
    $missing.Add([pscustomobject]@{
        Mod     = $folder
        Name    = "$(Get-PropertyValue $m 'name')"
        Version = "$(Get-PropertyValue $m 'version')"
        ModId   = $id
        Url     = Get-PageUrl -Folder $folder -ModId $id
    })
}

# ----------------------------------------------------------------------------------
# Report
# ----------------------------------------------------------------------------------

$order = @('ID-MISMATCH', 'UPGRADE', 'NEW-IN-LOCK', 'NOT-IN-LOCK', 'VERSION-UNKNOWN',
           'UNSUPPORTED-FORMAT', 'NOT-DMF', 'SUPERSEDED', 'OLDER', 'SAME')
$sorted = @($rows | Sort-Object @{ Expression = { [array]::IndexOf($order, $_.Status) } }, Mod, File)

Write-Step "Downloads : $downloadFull"
Write-Step "Staging   : $modsFull"
Write-Step "Lockfile  : $LockPath"
Write-Host ''

if ($sorted.Count -eq 0) {
    Write-Warn 'No .zip, .7z or .rar archives here (for the selected mods).'
} else {
    $sorted | Format-Table -AutoSize -Property Status, Mod,
            @{ Label = 'Staged';  Expression = { $_.StagedVersion } },
            @{ Label = 'Archive'; Expression = { $_.ArchiveVersion } },
            @{ Label = 'Id';      Expression = { if ($_.NexusModId) { $_.NexusModId } else { '' } } },
            File |
        Out-String -Width 250 | Write-Host
}
if ($ignored -gt 0) {
    Write-Host "$ignored other file(s) in the download folder are not archives and were ignored."
}

$attention = @($sorted | Where-Object { $_.Status -in @('ID-MISMATCH', 'NOT-IN-LOCK', 'UNSUPPORTED-FORMAT', 'VERSION-UNKNOWN', 'SUPERSEDED') -or ($_.Note -match 'pinned') })
if ($attention.Count -gt 0) {
    Write-Host ''
    Write-Step 'Needs a look'
    foreach ($r in $attention) {
        $line = "  $($r.Status) $($r.File): $($r.Note)"
        if ($r.Status -eq 'ID-MISMATCH') { Write-Err $line } else { Write-Warn $line }
    }
}

Write-Host ''
Write-Step 'Still to download'
if ($missing.Count -eq 0) {
    Write-Ok '  nothing - every selected lockfile mod is staged or has an archive here'
} else {
    foreach ($m in ($missing | Sort-Object Mod)) {
        $page = if ($m.Url) { $m.Url } else { 'no Nexus id in the lockfile' }
        $ver  = if ($m.Version) { $m.Version } else { '-' }
        Write-Host "  $($m.Mod.PadRight(34)) $($ver.PadRight(10)) $page"
    }
}
Write-Host "  $restCount other lockfile mod(s) are staged and have no archive here - nothing to do for them."

$counts = [ordered]@{}
foreach ($s in $order) {
    $n = @($rows | Where-Object { $_.Status -eq $s }).Count
    if ($n -gt 0) { $counts[$s] = $n }
}
$countText = @($counts.Keys | ForEach-Object { "$($counts[$_]) $_" }) -join ', '
$mismatches = 0
if ($counts.Contains('ID-MISMATCH')) { $mismatches = $counts['ID-MISMATCH'] }

Write-Host ''
Write-Host "$($rows.Count) archive(s)$(if ($countText) { ": $countText" }). $($missing.Count) lockfile mod(s) still to download."
$installable = @($rows | Where-Object { $_.Status -in @('UPGRADE', 'NEW-IN-LOCK', 'NOT-IN-LOCK') }).Count
if ($mismatches -gt 0) {
    Write-Err "$mismatches archive(s) carry a different Nexus id from the mod they would replace. Sort those out before update -Apply."
} elseif ($installable -gt 0) {
    Write-Ok "Next: .\darktide.ps1 update   (dry run), then .\darktide.ps1 update -Apply"
}

if ($outFull) {
    if ($outKind -eq 'json') {
        $archiveOut = @($sorted | ForEach-Object {
            [ordered]@{
                file           = $_.File
                status         = $_.Status
                mod            = $_.Mod
                archiveVersion = $_.ArchiveVersion
                versionSource  = $_.VersionSource
                stagedVersion  = $_.StagedVersion
                nexusModId     = $_.NexusModId
                expectedModId  = $_.ExpectedModId
                inLock         = $_.InLock
                staged         = $_.Staged
                url            = $_.Url
                note           = $_.Note
            }
        })
        $missingOut = @($missing | Sort-Object Mod | ForEach-Object {
            [ordered]@{ mod = $_.Mod; name = $_.Name; version = $_.Version; modId = $_.ModId; url = $_.Url }
        })
        $doc = [ordered]@{
            generatedAt          = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            downloadDir          = $downloadFull
            modsRoot             = $modsFull
            lockPath             = $LockPath
            counts               = $counts
            archives             = $archiveOut
            missing              = $missingOut
            stagedWithoutArchive = $restCount
            ignoredFiles         = $ignored
        }
        # -InputObject, not the pipeline: piping a one-element array unrolls it.
        ConvertTo-Json -InputObject $doc -Depth 6 | Set-Content -LiteralPath $outFull -Encoding UTF8
    } else {
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add('# Download intake')
        $lines.Add('')
        $lines.Add("$($rows.Count) archive(s)$(if ($countText) { ": $countText" }). $($missing.Count) lockfile mod(s) still to download.")
        $lines.Add('')
        $lines.Add('## Archives')
        $lines.Add('')
        if ($sorted.Count -eq 0) {
            $lines.Add('_No archives._')
        } else {
            $lines.Add('| Status | Mod | Staged | Archive | File | Note |')
            $lines.Add('|---|---|---|---|---|---|')
            foreach ($r in $sorted) {
                $cells = @($r.Status, $r.Mod, $r.StagedVersion, $r.ArchiveVersion, $r.File, $r.Note) |
                         ForEach-Object { $t = "$_" -replace '\|', '\|'; if ($t) { $t } else { '-' } }
                $lines.Add('| ' + ($cells -join ' | ') + ' |')
            }
        }
        $lines.Add('')
        $lines.Add('## Still to download')
        $lines.Add('')
        if ($missing.Count -eq 0) {
            $lines.Add('_Nothing._')
        } else {
            $lines.Add('| Mod | Version | Page |')
            $lines.Add('|---|---|---|')
            foreach ($m in ($missing | Sort-Object Mod)) {
                $link = if ($m.Url) { "[Nexus]($($m.Url))" } else { '_no Nexus id_' }
                $ver  = if ($m.Version) { $m.Version } else { '-' }
                $lines.Add("| $($m.Mod) | $ver | $link |")
            }
        }
        $lines.Add('')
        $lines.Add("$restCount other lockfile mod(s) are staged and have no archive here.")
        Set-Content -LiteralPath $outFull -Value $lines -Encoding UTF8
    }
    Write-Host ''
    Write-Host "Wrote $outFull"
}

if ($mismatches -gt 0) { exit 1 }
exit 0
