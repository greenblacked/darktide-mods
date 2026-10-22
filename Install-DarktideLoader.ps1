<#
.SYNOPSIS
    Installs or updates the Darktide Mod Loader, and keeps the bundle patched.

.DESCRIPTION
    The mod loader is the piece that makes DMF mods load at all. It is not a normal
    mod: it drops files into the game folder itself and patches the bundle database,
    so it needs its own install path rather than going through staging.

    What it puts where:

        binaries\mod_loader                the loader itself
        bundle\<hash>.patch_999            the mod entry bundle
        tools\dtkit-patch.exe              the patcher
        toggle_darktide_mods.bat           the patch toggle
        mods\base\                         DMF's base mod -> copied into STAGING,
                                           so a deploy carries it to the game

    Your mod_load_order.txt is never overwritten - the loader ships its own, and
    replacing yours would wipe your mod list.

    Following the loader's own update instructions, an update unpatches the bundle
    database first, copies the new files over, then re-patches. Patching is done with
    'dtkit-patch --patch', never the toggle script: the toggle flips state, so running
    it twice silently disables every mod.

    Before replacing an installed loader it copies the loader's own files - never
    the game's - to loader_backups\loader-<timestamp>\ beside staging, together with
    .darktide-loader.json so a restore can put the version record back too.

    After every successful --patch the SHA-256, size and timestamp of
    bundle\bundle_database.data are recorded in .darktide-loader.json under
    'bundleDb'. A Steam update replaces that file, so a different hash later means
    the patch is gone. -PatchOnly uses that to re-patch, and to do nothing when the
    database is still the one it patched.

    Nothing is written without -Apply. Dry runs work with the game open; -Apply
    refuses to write while Darktide.exe is running.

.PARAMETER Source
    The unzipped loader folder, or the .zip you downloaded. Defaults to LoaderSource
    from config.json, then to the newest loader archive or folder it can find.

.PARAMETER Force
    Reinstall even when the recorded version already matches.

.PARAMETER SkipPatch
    Copy the files but do not run the patcher.

.PARAMETER PatchOnly
    Re-apply the bundle patch after a Steam update, using the dtkit-patch.exe that is
    already in the game's tools folder. Downloads nothing, copies no loader files and
    never runs the toggle. Does nothing when the bundle database still matches the
    fingerprint recorded after the last patch. Under -Apply it copies the database to
    loader_backups\bundledb-<timestamp>.data first. Exits 1, writing nothing, when the
    patcher or the mod entry bundle is missing from the game folder.

.PARAMETER RestoreBackup
    Put a previous loader back from loader_backups\loader-<timestamp>. The dry run
    lists the backups. Under -Apply it backs up the current loader, unpatches, copies
    the backed-up loader files in, patches again and rewrites the version record.
    Only the loader's own files are copied back, so a backup cannot roll back game
    files a Steam update has since replaced.

.PARAMETER BackupSet
    With -RestoreBackup: part of the backup folder name to restore instead of the
    newest. A value matching more than one backup is refused; the full folder name
    always picks exactly that one.

.PARAMETER KeepBackups
    How many loader-* backup folders, and separately how many bundledb-*.data copies,
    to keep. Older ones are pruned after a successful write. Default 10; 0 keeps
    everything.

.PARAMETER PatcherPath
    Override the dtkit-patch executable. Used by the tests.

.EXAMPLE
    .\Install-DarktideLoader.ps1
    Dry run - reports what is installed and what would change.

.EXAMPLE
    .\Install-DarktideLoader.ps1 -Apply
    Installs or updates the loader and patches the bundle database.

.EXAMPLE
    .\Install-DarktideLoader.ps1 -PatchOnly -Apply
    After a Darktide update: re-patch the bundle database with the loader already
    in the game folder.

.EXAMPLE
    .\Install-DarktideLoader.ps1 -RestoreBackup -BackupSet 20261021
    Lists the loader backups and shows which one would be put back.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string] $Source,
    [string] $GamePath,
    [string] $StagingMods,
    [string] $PatcherPath,
    [switch] $Apply,
    [switch] $Force,
    [switch] $SkipPatch,
    [switch] $PatchOnly,
    [switch] $RestoreBackup,
    [string] $BackupSet,

    [ValidateRange(0, 1000)]
    [int] $KeepBackups = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue

function Write-Step { param([string]$m) Write-Host $m -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host $m -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host $m -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host $m -ForegroundColor Red }

# The loader is Nexus mod 19 on the Darktide domain, versioned by date (e.g. 26.06.24).
$script:LoaderModId  = 19
$script:StateFile    = '.darktide-loader.json'
$script:LoaderItems  = @('binaries', 'bundle', 'tools', 'toggle_darktide_mods.bat')
$script:PatcherRel   = 'tools\dtkit-patch.exe'
$script:BundleDbRel  = 'bundle\bundle_database.data'
# The loader's mod entry bundle. The game ships its own <hash>.patch_00x bundles in
# the same folder, so anything that acts on the game side matches patch_999 only.
$script:EntryBundle  = '*.patch_999'

function Get-LoaderVersionFromName {
    <#
        The loader ships no version file, so the download name is the only source.
        Nexus names it like 'Darktide Mod Loader-19-26-06-24-1719209900.zip'; browsers
        and extractors turn that into 'Darktide_Mod_Loader_19_26_06_24_...'. Both give
        the same answer: the run of numbers after the mod id.
    #>
    param(
        [string] $Name,
        # Defaulted rather than read from script scope, so it can be unit-tested
        # in isolation.
        [int]    $ModId = 19
    )

    if (-not $Name) { return $null }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Name)

    $raw = $null

    # Mod id followed by the version groups.
    $m = [regex]::Match($base, "[-_]$ModId[-_](?<v>\d+(?:[-_]\d+)*)")
    if ($m.Success) { $raw = $m.Groups['v'].Value }

    # No id in the name - fall back to any version-looking run.
    if (-not $raw) {
        $m = [regex]::Match($base, '(?<v>\d+(?:[._-]\d+)+)')
        if ($m.Success) { $raw = $m.Groups['v'].Value }
    }
    if (-not $raw) { return $null }

    # The name keeps going after the version: Nexus appends a 10-digit epoch, and
    # browsers append an ISO timestamp ('..._26_06_24_2026_06_24T06_07Z_...').
    # Version components are short, so stop at the first long run of digits and
    # never take more than four.
    $parts = @($raw -split '[-_.]' | Where-Object { $_ })
    $keep  = New-Object System.Collections.Generic.List[string]
    foreach ($p in $parts) {
        if ($keep.Count -ge 4) { break }
        if ($p.Length -ge 4 -and $keep.Count -gt 0) { break }
        $keep.Add($p)
    }
    if ($keep.Count -eq 0) { return $null }

    return ($keep -join '.')
}

function Test-LoaderSource {
    <# A real loader payload, not just any folder. #>
    param([string] $Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $Path 'toggle_darktide_mods.bat'))) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $Path 'tools\dtkit-patch.exe')))    { return $false }
    $patch = @(Get-ChildItem -LiteralPath (Join-Path $Path 'bundle') -Filter '*.patch_*' -File -ErrorAction SilentlyContinue)
    return ($patch.Count -gt 0)
}

function Expand-LoaderArchive {
    <#
        Extracts every entry into $Destination, refusing anything that resolves
        outside it. Copied from Import-DarktideLoadout.ps1; not a shared module.
    #>
    param(
        [Parameter(Mandatory)] [string] $ZipPath,
        [Parameter(Mandatory)] [string] $Destination
    )

    $root = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    $zip  = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $zip.Entries) {
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
                # CreateDirectory, not New-Item: New-Item is the one filesystem cmdlet
                # used here that has no -LiteralPath at all, in any edition, so it
                # cannot follow the house rule. Creating a directory does not glob -
                # the danger is on the read and delete side - but keeping every path
                # literal removes the exception, and CreateDirectory is idempotent
                # without -Force and returns nothing to pipe away.
                [void][System.IO.Directory]::CreateDirectory($target)
                continue
            }

            $parent = Split-Path -Parent $target
            if ($parent) { [void][System.IO.Directory]::CreateDirectory($parent) }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } finally { $zip.Dispose() }
}

function Find-LoaderSource {
    <#
        Looks for a loader payload the user already has: an unzipped folder or a
        downloaded archive. Newest first, so a fresh download wins.
    #>
    param([string[]] $SearchRoots)

    $hits = New-Object System.Collections.Generic.List[object]

    foreach ($root in $SearchRoots) {
        if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) { continue }

        foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                           Where-Object { $_.Name -match '(?i)mod.?loader' })) {
            if (Test-LoaderSource -Path $dir.FullName) {
                $hits.Add([pscustomobject]@{
                    Path = $dir.FullName; IsArchive = $false; Modified = $dir.LastWriteTime
                })
            }
        }

        foreach ($zip in @(Get-ChildItem -LiteralPath $root -File -Filter '*.zip' -ErrorAction SilentlyContinue |
                           Where-Object { $_.Name -match '(?i)mod.?loader' })) {
            $hits.Add([pscustomobject]@{
                Path = $zip.FullName; IsArchive = $true; Modified = $zip.LastWriteTime
            })
        }
    }

    return ,@($hits | Sort-Object Modified -Descending)
}

function Get-InstalledLoaderState {
    param([string] $GameFolder)
    $path = Join-Path $GameFolder $script:StateFile
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch { return $null }
}

function Invoke-Patcher {
    <#
        Runs dtkit-patch with an explicit action. Never the toggle: toggling twice
        turns mods back off, which is exactly the failure people hit by hand.
    #>
    param(
        [Parameter(Mandatory)] [string] $Exe,
        [Parameter(Mandatory)] [ValidateSet('patch', 'unpatch')] [string] $Action,
        [Parameter(Mandatory)] [string] $GameFolder,
        [switch] $TolerateFailure
    )

    $bundle = Join-Path $GameFolder 'bundle'
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $Exe "--$Action" $bundle 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $eap }

    if ($code -ne 0 -and -not $TolerateFailure) {
        throw "dtkit-patch --$Action failed (exit $code): $($output.Trim())"
    }
    return [pscustomobject]@{ ExitCode = $code; Output = $output.Trim() }
}

function Get-LoaderOwnedFiles {
    <#
        Relative paths of the files the loader itself puts into a game folder, found
        under $Root (a game folder or a loader backup). Deliberately a short explicit
        list: binaries\ and bundle\ also hold the game's own files - Darktide.exe,
        bundle_database.data and the game's own *.patch_00x bundles - and a backup
        or restore that swept those up would roll the game back behind Steam's back.
    #>
    param([Parameter(Mandatory)] [string] $Root)

    $rel = New-Object System.Collections.Generic.List[string]

    $modLoader = Join-Path $Root 'binaries\mod_loader'
    if (Test-Path -LiteralPath $modLoader -PathType Leaf) {
        $rel.Add('binaries\mod_loader')
    } elseif (Test-Path -LiteralPath $modLoader -PathType Container) {
        $prefix = (Get-Item -LiteralPath $modLoader).FullName
        foreach ($f in @(Get-ChildItem -LiteralPath $modLoader -Recurse -File)) {
            $tail = $f.FullName.Substring($prefix.Length).TrimStart('\', '/') -replace '/', '\'
            $rel.Add("binaries\mod_loader\$tail")
        }
    }

    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $Root 'bundle') -Filter $script:EntryBundle -File -ErrorAction SilentlyContinue)) {
        $rel.Add("bundle\$($f.Name)")
    }

    foreach ($r in @($script:PatcherRel, 'toggle_darktide_mods.bat')) {
        if (Test-Path -LiteralPath (Join-Path $Root $r) -PathType Leaf) { $rel.Add($r) }
    }

    return $rel.ToArray()
}

function Get-LoaderBackupRoot {
    <#
        Loader backups sit beside the mod and deploy backups, not inside the Steam
        library where a game verify could sweep them up.
    #>
    param([string] $ModsRoot, [Parameter(Mandatory)] [string] $GameFolder)
    $base = if ($ModsRoot) { Split-Path -Parent $ModsRoot } else { Split-Path -Parent $GameFolder }
    return (Join-Path $base 'loader_backups')
}

function Get-BackupOrderKey {
    <#
        Sort key for '<prefix>-<yyyyMMdd-HHmmss>[-n][.data]' names: the stamp, then n
        as a number, so '-10' sorts after '-9'. Names in any other shape sort oldest.
    #>
    param([string] $Name)
    $m = [regex]::Match($Name, '^[A-Za-z]+-(\d{8}-\d{6})(?:-(\d+))?(?:\.data)?$')
    if (-not $m.Success) { return '' }
    $n = if ($m.Groups[2].Success) { $m.Groups[2].Value } else { '0' }
    return "$($m.Groups[1].Value)-$($n.PadLeft(10, '0'))"
}

function New-StampedPath {
    <#
        <Directory>\<Prefix>-<timestamp><Suffix>. When that second is already taken,
        numbered one past the highest number used for it - never into a gap left by
        pruning, which would make the newest backup look like the oldest of its second.
    #>
    param(
        [Parameter(Mandatory)] [string] $Directory,
        [Parameter(Mandatory)] [string] $Prefix,
        [string] $Suffix = ''
    )
    $base  = "$Prefix-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    $taken = @(Get-ChildItem -LiteralPath $Directory -ErrorAction SilentlyContinue |
               Where-Object { $_.Name.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) })
    if ($taken.Count -eq 0) { return (Join-Path $Directory "$base$Suffix") }

    $max = 0
    foreach ($t in $taken) {
        $m = [regex]::Match($t.Name.Substring($base.Length), '^-(\d{1,9})(?:\.|$)')
        if ($m.Success -and [int]$m.Groups[1].Value -gt $max) { $max = [int]$m.Groups[1].Value }
    }
    return (Join-Path $Directory "$base-$($max + 1)$Suffix")
}

function Copy-LoaderFile {
    param([Parameter(Mandatory)] [string] $From, [Parameter(Mandatory)] [string] $To)
    $parent = Split-Path -Parent $To
    if ($parent) { [void][System.IO.Directory]::CreateDirectory($parent) }
    Copy-Item -LiteralPath $From -Destination $To -Force
}

function New-LoaderBackup {
    <#
        Copies the installed loader's files, plus the state file, into a new
        loader-<timestamp> folder. Returns its path, or $null when there is no
        loader to back up. A failed copy throws, so nothing is replaced unbacked.
    #>
    param(
        [Parameter(Mandatory)] [string] $GameFolder,
        [Parameter(Mandatory)] [string] $BackupRoot
    )

    $files    = @(Get-LoaderOwnedFiles -Root $GameFolder)
    $stateSrc = Join-Path $GameFolder $script:StateFile
    $hasState = Test-Path -LiteralPath $stateSrc -PathType Leaf
    if ($files.Count -eq 0 -and -not $hasState) { return $null }

    [void][System.IO.Directory]::CreateDirectory($BackupRoot)
    $dir = New-StampedPath -Directory $BackupRoot -Prefix 'loader'
    [void][System.IO.Directory]::CreateDirectory($dir)

    foreach ($rel in $files) {
        Copy-LoaderFile -From (Join-Path $GameFolder $rel) -To (Join-Path $dir $rel)
    }
    if ($hasState) { Copy-LoaderFile -From $stateSrc -To (Join-Path $dir $script:StateFile) }
    return $dir
}

function Get-LoaderBackupSets {
    <#
        loader-<timestamp> folders, newest first. Ordered by the stamp in the name
        rather than a timestamp attribute, which copying a folder can change.
    #>
    param([Parameter(Mandatory)] [string] $BackupRoot)
    if (-not (Test-Path -LiteralPath $BackupRoot -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $BackupRoot -Directory |
              Where-Object { $_.Name -like 'loader-*' } |
              Sort-Object -Property @{ Expression = { Get-BackupOrderKey -Name $_.Name } }, Name -Descending)
}

function Remove-StaleLoaderBackups {
    <#
        Bounds both kinds of loader backup by -KeepBackups, each counted on its own:
        loader-* folders and bundledb-*.data copies of the bundle database.
    #>
    param([Parameter(Mandatory)] [string] $BackupRoot, [int] $Keep)

    if ($Keep -le 0 -or -not (Test-Path -LiteralPath $BackupRoot -PathType Container)) { return }

    foreach ($old in @(Get-LoaderBackupSets -BackupRoot $BackupRoot | Select-Object -Skip $Keep)) {
        Remove-Item -LiteralPath $old.FullName -Recurse -Force
        Write-Host "  pruned old loader backup: $($old.Name)"
    }

    # Copy-Item keeps the database's own timestamp on the copy, so the name is the
    # only record of when the copy was made.
    $dbCopies = @(Get-ChildItem -LiteralPath $BackupRoot -File -Filter 'bundledb-*.data' |
                  Sort-Object -Property @{ Expression = { Get-BackupOrderKey -Name $_.Name } }, Name -Descending |
                  Select-Object -Skip $Keep)
    foreach ($old in $dbCopies) {
        Remove-Item -LiteralPath $old.FullName -Force
        Write-Host "  pruned old bundle database copy: $($old.Name)"
    }
}

function Get-BundleDbFingerprint {
    <#
        What 'bundleDb' in .darktide-loader.json holds. Other tools read these
        field names; keep them.
    #>
    param([Parameter(Mandatory)] [string] $GameFolder)

    $path = Join-Path $GameFolder $script:BundleDbRel
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $item = Get-Item -LiteralPath $path
    return [ordered]@{
        sha256           = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        length           = [long]$item.Length
        lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
        recordedAt       = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Get-RecordedBundleHash {
    <# The sha256 recorded after the last patch, or $null. State files written before
       the fingerprint existed have no bundleDb at all. #>
    param($State)

    if (-not $State) { return $null }
    if ($State.PSObject.Properties.Name -notcontains 'bundleDb') { return $null }
    $db = $State.bundleDb
    if (-not $db -or $db.PSObject.Properties.Name -notcontains 'sha256' -or -not $db.sha256) { return $null }
    return "$($db.sha256)"
}

function Save-LoaderState {
    <#
        Rewrites .darktide-loader.json from the existing record plus $Set, so fields
        written by other tools survive. $Remove drops keys that would now be wrong.
    #>
    param(
        [Parameter(Mandatory)] [string] $GameFolder,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Set,
        [string[]] $Remove = @()
    )

    $merged   = [ordered]@{}
    $existing = Get-InstalledLoaderState -GameFolder $GameFolder
    if ($existing -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $existing.PSObject.Properties) { $merged[$p.Name] = $p.Value }
    }
    foreach ($k in $Remove) { if ($merged.Contains($k)) { $merged.Remove($k) } }
    foreach ($k in @($Set.Keys)) { $merged[$k] = $Set[$k] }

    $merged | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath (Join-Path $GameFolder $script:StateFile) -Encoding UTF8
}

function Get-MissingLoaderFiles {
    <# What -PatchOnly needs in the game folder before it can patch. #>
    param([Parameter(Mandatory)] [string] $GameFolder)

    $missing = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath (Join-Path $GameFolder $script:PatcherRel) -PathType Leaf)) {
        $missing.Add($script:PatcherRel)
    }
    $entry = @(Get-ChildItem -LiteralPath (Join-Path $GameFolder 'bundle') -Filter $script:EntryBundle -File -ErrorAction SilentlyContinue)
    if ($entry.Count -eq 0) { $missing.Add("bundle\$($script:EntryBundle) (the mod entry bundle)") }
    return $missing.ToArray()
}

function Select-LoaderBackupSet {
    <# Newest by default; otherwise exactly one folder whose name contains $BackupSet. #>
    param([Parameter(Mandatory)] [object[]] $Sets, [string] $BackupSet)

    if (-not $BackupSet) { return $Sets[0] }

    # A full folder name is unambiguous even when it is also a prefix of a later
    # same-second backup (loader-<stamp> vs loader-<stamp>-1).
    $exact = @($Sets | Where-Object { $_.Name -eq $BackupSet })
    if ($exact.Count -eq 1) { return $exact[0] }

    # IndexOf, not -like: a value with [ or ] in it is text, not a wildcard.
    $hits = @($Sets | Where-Object { $_.Name.IndexOf($BackupSet, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    if ($hits.Count -eq 0) { throw "No loader backup matches '$BackupSet'." }
    if ($hits.Count -gt 1) {
        throw "'$BackupSet' matches $($hits.Count) loader backups ($(@($hits | ForEach-Object { $_.Name }) -join ', ')). Give more of the name."
    }
    return $hits[0]
}

# ---- Resolve config ----------------------------------------------------------------

$cfg = @{ ModsRoot = ''; GamePath = ''; LoaderSource = ''; DownloadDir = '' }
if (Test-Path -LiteralPath $ConfigPath) {
    $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    if ($raw.Trim()) {
        $j = $raw | ConvertFrom-Json
        foreach ($k in @($cfg.Keys)) {
            if ($j.PSObject.Properties.Name -contains $k -and "$($j.$k)".Trim()) { $cfg[$k] = "$($j.$k)" }
        }
    }
}
if ($GamePath)    { $cfg.GamePath     = $GamePath }
if ($StagingMods) { $cfg.ModsRoot     = $StagingMods }
if ($Source)      { $cfg.LoaderSource = $Source }

if (-not $cfg.GamePath) { throw "Game folder not set. Run '.\darktide.ps1 init' first, or pass -GamePath." }
if (-not (Test-Path -LiteralPath $cfg.GamePath -PathType Container)) {
    throw "Game folder '$($cfg.GamePath)' does not exist."
}
$game = (Resolve-Path -LiteralPath $cfg.GamePath).Path.TrimEnd('\')

$marker = @('binaries\Darktide.exe', 'binaries_dx12\Darktide.exe', 'bundle\bundle_database.data', 'launcher\Launcher.exe') |
          Where-Object { Test-Path -LiteralPath (Join-Path $game $_) }
if (-not $marker) {
    throw "'$game' does not look like a Darktide install. Refusing to write loader files there."
}

# ---- Modes that work from what is already installed ---------------------------------

if ($PatchOnly -and $RestoreBackup) { throw 'Pass -PatchOnly or -RestoreBackup, not both.' }
if ($BackupSet -and -not $RestoreBackup) {
    throw '-BackupSet picks the loader backup for -RestoreBackup and does nothing without it.'
}
if ($PatchOnly -or $RestoreBackup) {
    $modeName = if ($PatchOnly) { '-PatchOnly' } else { '-RestoreBackup' }
    if ($Source)    { throw "$modeName works from the game folder and the loader backups; -Source does not apply." }
    if ($SkipPatch) { throw "$modeName ends by patching the bundle database; -SkipPatch contradicts it." }
    if ($Force)     { throw "$modeName has nothing to force. To reinstall the loader from its download, drop $modeName." }
}

$backupRoot = Get-LoaderBackupRoot -ModsRoot $cfg.ModsRoot -GameFolder $game
$modeLine   = if ($Apply) { 'APPLY' } else { 'DRY RUN (pass -Apply to write)' }

if ($PatchOnly) {
    Write-Step '=== Darktide Mod Loader: re-patch ==='
    Write-Host "Game : $game"
    Write-Host "Mode : $modeLine"
    Write-Host ''

    # Checked before anything else, and before the dry-run exit, so a dry run already
    # tells you this cannot work.
    $missing = @(Get-MissingLoaderFiles -GameFolder $game)
    if ($PatcherPath -and -not (Test-Path -LiteralPath $PatcherPath -PathType Leaf)) {
        $missing += "patcher override '$PatcherPath'"
    }
    if ($missing.Count -gt 0) {
        foreach ($m in $missing) { Write-Err "  missing: $m" }
        Write-Err 'loader files missing: run .\darktide.ps1 loader -Apply -Force'
        exit 1
    }

    $current = Get-BundleDbFingerprint -GameFolder $game
    if (-not $current) {
        throw "No $($script:BundleDbRel) in '$game'. Verify the game files in Steam, then re-run."
    }
    $recorded = Get-RecordedBundleHash -State (Get-InstalledLoaderState -GameFolder $game)

    Write-Host "Bundle database : $($current.length) bytes, last written $($current.lastWriteTimeUtc)"
    Write-Host "  sha256 now    : $($current.sha256)"
    Write-Host "  after patching: $(if ($recorded) { $recorded } else { 'not recorded' })"
    Write-Host ''

    if ($recorded -and $recorded -eq $current.sha256) {
        Write-Ok 'Already patched: the bundle database is the one recorded after the last patch. Nothing to do.'
        exit 0
    }
    if ($recorded) {
        Write-Warn 'The bundle database changed since the last patch - a game update replaced it.'
    } else {
        Write-Warn 'No patched fingerprint on record (installed before this was tracked) - patching to record one.'
    }

    $patcher = if ($PatcherPath) { $PatcherPath } else { Join-Path $game $script:PatcherRel }

    Write-Step 'Plan'
    Write-Host "  copy $($script:BundleDbRel) -> $(Join-Path $backupRoot 'bundledb-<timestamp>.data')"
    Write-Host "  run  $patcher --patch   (explicit; never the toggle)"
    Write-Host "  record the patched fingerprint in $($script:StateFile)"
    Write-Host ''

    if (-not $Apply) {
        Write-Warn 'Dry run complete. Nothing was written. Re-run with -Apply.'
        return
    }

    $running = Get-Process -Name 'Darktide' -ErrorAction SilentlyContinue
    if ($running) { throw "Darktide.exe is running (PID $($running.Id -join ', ')). Close the game first." }

    if (-not $PSCmdlet.ShouldProcess($game, 'Re-apply the mod loader bundle patch')) { return }

    [void][System.IO.Directory]::CreateDirectory($backupRoot)
    $dbCopy = New-StampedPath -Directory $backupRoot -Prefix 'bundledb' -Suffix '.data'
    Copy-Item -LiteralPath (Join-Path $game $script:BundleDbRel) -Destination $dbCopy -Force
    Write-Ok "Backed up the bundle database -> $dbCopy"
    Remove-StaleLoaderBackups -BackupRoot $backupRoot -Keep $KeepBackups

    Write-Step 'Patching the bundle database...'
    $r = Invoke-Patcher -Exe $patcher -Action 'patch' -GameFolder $game
    Write-Ok '  patched'
    if ($r.Output) { Write-Verbose $r.Output }

    Save-LoaderState -GameFolder $game -Set ([ordered]@{
        patched  = $true
        bundleDb = (Get-BundleDbFingerprint -GameFolder $game)
    })
    Write-Ok "Recorded the patched bundle fingerprint in $($script:StateFile)."
    exit 0
}

if ($RestoreBackup) {
    Write-Step '=== Darktide Mod Loader: restore a backup ==='
    Write-Host "Game    : $game"
    Write-Host "Backups : $backupRoot"
    Write-Host "Mode    : $modeLine"
    Write-Host ''

    $sets = @(Get-LoaderBackupSets -BackupRoot $backupRoot)
    if ($sets.Count -eq 0) {
        throw "No loader backups in '$backupRoot'. One is made each time 'loader -Apply' replaces an installed loader."
    }

    Write-Step 'Loader backups (newest first)'
    foreach ($s in $sets) {
        $st = Get-InstalledLoaderState -GameFolder $s.FullName
        $v  = if ($st -and $st.PSObject.Properties.Name -contains 'version' -and $st.version) { "$($st.version)" } else { 'version not recorded' }
        Write-Host "  $($s.Name)   $v"
    }
    Write-Host ''

    $chosen   = Select-LoaderBackupSet -Sets $sets -BackupSet $BackupSet
    $setFiles = @(Get-LoaderOwnedFiles -Root $chosen.FullName)
    $hasPatcher = $setFiles -contains $script:PatcherRel
    $hasEntry   = @($setFiles | Where-Object { $_ -like "bundle\$($script:EntryBundle)" }).Count -gt 0
    if (-not $hasPatcher -or -not $hasEntry) {
        throw "'$($chosen.Name)' does not hold a complete loader (needs $($script:PatcherRel) and bundle\$($script:EntryBundle)). Pick another with -BackupSet."
    }

    $setState   = Get-InstalledLoaderState -GameFolder $chosen.FullName
    $setVersion = if ($setState -and $setState.PSObject.Properties.Name -contains 'version' -and $setState.version) { "$($setState.version)" } else { $null }

    Write-Step 'Plan'
    Write-Host "  restore $($chosen.Name) (loader $(if ($setVersion) { $setVersion } else { 'version not recorded' }))"
    Write-Host "  back up the current loader to $(Join-Path $backupRoot 'loader-<timestamp>')"
    Write-Host '  dtkit-patch --unpatch, copy these files back, dtkit-patch --patch:'
    foreach ($rel in $setFiles) { Write-Host "    $rel" }
    Write-Host ''

    if (-not $Apply) {
        Write-Warn 'Dry run complete. Nothing was written. Re-run with -Apply.'
        return
    }

    $running = Get-Process -Name 'Darktide' -ErrorAction SilentlyContinue
    if ($running) { throw "Darktide.exe is running (PID $($running.Id -join ', ')). Close the game first." }

    if (-not $PSCmdlet.ShouldProcess($game, "Restore mod loader backup $($chosen.Name)")) { return }

    $preRestore = New-LoaderBackup -GameFolder $game -BackupRoot $backupRoot
    if ($preRestore) { Write-Ok "Backed up the current loader -> $preRestore" }

    $patcher = if ($PatcherPath) { $PatcherPath } else { Join-Path $game $script:PatcherRel }
    if (Test-Path -LiteralPath $patcher -PathType Leaf) {
        Write-Step 'Unpatching the bundle database...'
        # Harmless when it was not patched, so the exit code is advisory here.
        $r = Invoke-Patcher -Exe $patcher -Action 'unpatch' -GameFolder $game -TolerateFailure
        if ($r.ExitCode -eq 0) { Write-Ok '  unpatched' } else { Write-Warn '  was not patched (fine)' }
    }

    Write-Step "Copying $($chosen.Name) back..."
    foreach ($rel in $setFiles) {
        Copy-LoaderFile -From (Join-Path $chosen.FullName $rel) -To (Join-Path $game $rel)
        Write-Ok "  $rel"
    }

    # The restored patcher, unless the caller overrode it.
    $patcher = if ($PatcherPath) { $PatcherPath } else { Join-Path $game $script:PatcherRel }
    Write-Step 'Patching the bundle database...'
    $r = Invoke-Patcher -Exe $patcher -Action 'patch' -GameFolder $game
    Write-Ok '  patched'
    if ($r.Output) { Write-Verbose $r.Output }

    # The backed-up record says which loader this is. Backups made before the record
    # was stored with them cannot say, and a sentinel version makes the next
    # 'loader -Apply' treat the install as out of date rather than current.
    $set    = [ordered]@{}
    $remove = @()
    if ($setState -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $setState.PSObject.Properties) {
            if (@('bundleDb', 'restoredFrom', 'restoredAt') -notcontains $p.Name) { $set[$p.Name] = $p.Value }
        }
    }
    if (-not $setVersion) {
        $set['version'] = 'restored-unknown'
        $remove = @('source', 'installedAt')
    }
    $set['patched']      = $true
    $set['bundleDb']     = Get-BundleDbFingerprint -GameFolder $game
    $set['restoredFrom'] = $chosen.Name
    $set['restoredAt']   = (Get-Date).ToString('o')
    Save-LoaderState -GameFolder $game -Set $set -Remove $remove

    # Pruned last, so a small -KeepBackups cannot delete the set before it is copied.
    Remove-StaleLoaderBackups -BackupRoot $backupRoot -Keep $KeepBackups

    Write-Host ''
    Write-Ok "Restored loader $(if ($setVersion) { $setVersion } else { '(version not recorded)' }) from $($chosen.Name)."
    if ($preRestore) {
        Write-Host "Undo: .\darktide.ps1 loader -RestoreBackup -BackupSet '$(Split-Path -Leaf $preRestore)' -Apply"
    }
    return
}

# ---- Resolve the loader source -----------------------------------------------------

Write-Step '=== Darktide Mod Loader ==='
Write-Host  "Game : $game"

$sourcePath = $cfg.LoaderSource
$sourceName = $null
$tempExtract = $null

if (-not $sourcePath) {
    $roots = @($cfg.DownloadDir, (Split-Path -Parent $PSScriptRoot), (Split-Path -Parent $cfg.ModsRoot)) |
             Where-Object { $_ }
    $candidates = Find-LoaderSource -SearchRoots $roots
    if ($candidates.Count -gt 0) {
        $sourcePath = $candidates[0].Path
        Write-Host "Found: $sourcePath"
    }
}

if (-not $sourcePath) {
    throw @"
No mod loader payload found.

Download 'Darktide Mod Loader' from
  https://www.nexusmods.com/warhammer40kdarktide/mods/$($script:LoaderModId)
into your DownloadDir, or point at it directly:

    .\darktide.ps1 loader -Source 'D:\path\to\Darktide_Mod_Loader_...' -Apply
"@
}

if (-not (Test-Path -LiteralPath $sourcePath)) { throw "Loader source '$sourcePath' not found." }

$sourceName = [System.IO.Path]::GetFileName($sourcePath)

try {
    # An archive gets unpacked to temp; a folder is used where it lies.
    if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
        if ([System.IO.Path]::GetExtension($sourcePath) -ne '.zip') {
            throw "Loader source '$sourcePath' is a file but not a .zip."
        }
        $tempExtract = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-loader-" + [guid]::NewGuid().ToString('N').Substring(0, 10))
        [void][System.IO.Directory]::CreateDirectory($tempExtract)
        Expand-LoaderArchive -ZipPath $sourcePath -Destination $tempExtract

        # Some archives wrap everything in one top folder.
        $payload = $tempExtract
        if (-not (Test-LoaderSource -Path $payload)) {
            $inner = @(Get-ChildItem -LiteralPath $tempExtract -Directory |
                       Where-Object { Test-LoaderSource -Path $_.FullName })
            if ($inner.Count -gt 0) { $payload = $inner[0].FullName }
        }
        $sourcePath = $payload
    }

    if (-not (Test-LoaderSource -Path $sourcePath)) {
        throw @"
'$sourcePath' is not a Darktide Mod Loader payload.

Expected to find toggle_darktide_mods.bat, tools\dtkit-patch.exe and a
bundle\*.patch_* file inside it.
"@
    }

    # ---- Compare versions ----------------------------------------------------------

    $newVersion = Get-LoaderVersionFromName -Name $sourceName
    $state      = Get-InstalledLoaderState -GameFolder $game
    $oldVersion = if ($state -and $state.PSObject.Properties.Name -contains 'version') { "$($state.version)" } else { $null }

    $installed = Test-Path -LiteralPath (Join-Path $game 'toggle_darktide_mods.bat')

    Write-Host  "Source : $sourceName"
    Write-Host  "Version: $(if ($newVersion) { $newVersion } else { 'unknown (name gives no version)' })"
    Write-Host  "Current: $(if ($oldVersion) { $oldVersion } elseif ($installed) { 'installed, version not recorded' } else { 'not installed' })"
    Write-Host  ''

    $needsInstall = $true
    $reason = 'not installed yet'
    if ($installed -and $oldVersion -and $newVersion) {
        if ($oldVersion -eq $newVersion) { $needsInstall = $false; $reason = 'already up to date' }
        else { $reason = "updating $oldVersion -> $newVersion" }
    } elseif ($installed -and -not $oldVersion) {
        $reason = 'installed but untracked - reinstalling to record the version'
    }

    if ($Force -and -not $needsInstall) { $needsInstall = $true; $reason = 'forced reinstall' }

    Write-Step 'Plan'
    if ($needsInstall) { Write-Host "  $reason" } else { Write-Ok "  $reason - nothing to do" }
    if ($needsInstall -and -not $SkipPatch) {
        Write-Host '  bundle database will be unpatched, updated, then re-patched'
    }
    Write-Host ''

    if (-not $needsInstall) {
        Write-Ok 'Mod loader is current.'
        return
    }

    if (-not $Apply) {
        Write-Warn 'Dry run complete. Nothing was written. Re-run with -Apply.'
        return
    }

    # Only when we are actually going to write - same rule as update/deploy.
    $running = Get-Process -Name 'Darktide' -ErrorAction SilentlyContinue
    if ($running) { throw "Darktide.exe is running (PID $($running.Id -join ', ')). Close the game first." }

    if (-not $PSCmdlet.ShouldProcess($game, "Install mod loader $newVersion")) { return }

    # ---- Back up what is there now -------------------------------------------------

    # Only the loader's own files and its state record: binaries\ and bundle\ are
    # mostly the game's, and copying them would be gigabytes per backup.
    $backupDir = New-LoaderBackup -GameFolder $game -BackupRoot $backupRoot
    if ($backupDir) {
        Write-Ok "Backed up the current loader -> $backupDir"
        Remove-StaleLoaderBackups -BackupRoot $backupRoot -Keep $KeepBackups
    }

    # ---- Unpatch before replacing files ---------------------------------------------

    $patcher = $PatcherPath
    if (-not $patcher) { $patcher = Join-Path $game 'tools\dtkit-patch.exe' }

    if (-not $SkipPatch -and $installed -and (Test-Path -LiteralPath $patcher)) {
        Write-Step 'Unpatching the bundle database...'
        # Harmless when it was not patched, so the exit code is advisory here.
        $r = Invoke-Patcher -Exe $patcher -Action 'unpatch' -GameFolder $game -TolerateFailure
        if ($r.ExitCode -eq 0) { Write-Ok '  unpatched' } else { Write-Warn '  was not patched (fine)' }
    }

    # ---- Copy the payload -----------------------------------------------------------

    Write-Step 'Installing loader files...'
    foreach ($item in $script:LoaderItems) {
        $src = Join-Path $sourcePath $item
        if (-not (Test-Path -LiteralPath $src)) { continue }

        if (Test-Path -LiteralPath $src -PathType Container) {
            $eap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                & robocopy.exe $src (Join-Path $game $item) '/E' '/NFL' '/NDL' '/NJH' '/NJS' '/NP' | Out-Null
                if ($LASTEXITCODE -ge 8) { throw "Copying '$item' failed (robocopy $LASTEXITCODE)." }
            } finally { $ErrorActionPreference = $eap }
        } else {
            Copy-Item -LiteralPath $src -Destination $game -Force
        }
        Write-Ok "  $item"
    }

    # DMF's base mod belongs in staging, so that a deploy keeps carrying it and the
    # lockfile records it like any other mod.
    $srcBase = Join-Path $sourcePath 'mods\base'
    if ((Test-Path -LiteralPath $srcBase) -and $cfg.ModsRoot) {
        if (-not (Test-Path -LiteralPath $cfg.ModsRoot)) {
            New-Item -ItemType Directory -Path $cfg.ModsRoot -Force | Out-Null
        }
        $eap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & robocopy.exe $srcBase (Join-Path $cfg.ModsRoot 'base') '/E' '/NFL' '/NDL' '/NJH' '/NJS' '/NP' | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "Copying mods\base failed (robocopy $LASTEXITCODE)." }
        } finally { $ErrorActionPreference = $eap }
        Write-Ok '  mods\base -> staging'
    }

    # The loader ships its own mod_load_order.txt. Never let it replace the user's.
    $stagedOrder = if ($cfg.ModsRoot) { Join-Path $cfg.ModsRoot 'mod_load_order.txt' } else { $null }
    if ($stagedOrder -and -not (Test-Path -LiteralPath $stagedOrder)) {
        $srcOrder = Join-Path $sourcePath 'mods\mod_load_order.txt'
        if (Test-Path -LiteralPath $srcOrder) {
            Copy-Item -LiteralPath $srcOrder -Destination $stagedOrder -Force
            Write-Ok '  mod_load_order.txt created from the loader default (none existed)'
        }
    } else {
        Write-Host '  mod_load_order.txt left alone (yours is kept)'
    }

    # ---- Re-patch --------------------------------------------------------------------

    $didPatch = $false
    if (-not $SkipPatch) {
        $patcher = if ($PatcherPath) { $PatcherPath } else { Join-Path $game 'tools\dtkit-patch.exe' }
        if (Test-Path -LiteralPath $patcher) {
            Write-Step 'Patching the bundle database...'
            $r = Invoke-Patcher -Exe $patcher -Action 'patch' -GameFolder $game
            Write-Ok '  patched'
            if ($r.Output) { Write-Verbose $r.Output }
            $didPatch = $true
        } else {
            Write-Warn "  patcher not found at '$patcher' - run toggle_darktide_mods.bat by hand."
        }
    }

    # ---- Record ----------------------------------------------------------------------

    # Merged into the existing record so fields other tools keep there survive. The
    # bundle fingerprint is only replaced after a patch that actually ran.
    $record = [ordered]@{
        modId       = $script:LoaderModId
        name        = 'Darktide Mod Loader'
        version     = $newVersion
        source      = $sourceName
        installedAt = (Get-Date).ToString('o')
        patched     = $didPatch
    }
    if ($didPatch) { $record['bundleDb'] = Get-BundleDbFingerprint -GameFolder $game }
    Save-LoaderState -GameFolder $game -Set $record -Remove @('restoredFrom', 'restoredAt')

    Write-Host ''
    Write-Ok "Mod loader $(if ($newVersion) { $newVersion } else { '' }) installed."
    Write-Host ''
    Write-Host 'Next:' -ForegroundColor Cyan
    Write-Host '  .\darktide.ps1 deploy -Apply     push your mods (including base) to the game'
}
finally {
    if ($tempExtract -and (Test-Path -LiteralPath $tempExtract)) {
        Remove-Item -LiteralPath $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
    }
}
