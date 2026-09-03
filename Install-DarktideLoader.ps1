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

    Nothing is written without -Apply. Dry runs work with the game open; -Apply
    refuses to write while Darktide.exe is running.

.PARAMETER Source
    The unzipped loader folder, or the .zip you downloaded. Defaults to LoaderSource
    from config.json, then to the newest loader archive or folder it can find.

.PARAMETER Force
    Reinstall even when the recorded version already matches.

.PARAMETER KeepBackups
    How many loader-* backup folders to keep. Default 10. 0 keeps all.

.PARAMETER SkipPatch
    Copy the files but do not run the patcher.

.PARAMETER KeepBackups
    How many loader backup folders to keep. Older ones are pruned after a successful
    install. Default 10; 0 keeps everything.

.PARAMETER PatcherPath
    Override the dtkit-patch executable. Used by the tests.

.EXAMPLE
    .\Install-DarktideLoader.ps1
    Dry run - reports what is installed and what would change.

.EXAMPLE
    .\Install-DarktideLoader.ps1 -Apply
    Installs or updates the loader and patches the bundle database.
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
                # CreateDirectory, not New-Item -Path: 5.1 has no -LiteralPath on New-Item,
                # and -Path globs on [] in folder names.
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

    # Keep loader backups beside the mod and deploy backups, not inside the Steam
    # library where a game verify could sweep them up.
    $backupBase = if ($cfg.ModsRoot) { Split-Path -Parent $cfg.ModsRoot } else { Split-Path -Parent $game }
    $backupRoot = Join-Path $backupBase 'loader_backups'
    if ($installed) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backupDir = Join-Path $backupRoot "loader-$stamp"
        $n = 1
        while (Test-Path -LiteralPath $backupDir) { $backupDir = Join-Path $backupRoot "loader-$stamp-$n"; $n++ }
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

        foreach ($item in $script:LoaderItems) {
            $src = Join-Path $game $item
            if (-not (Test-Path -LiteralPath $src)) { continue }
            if (Test-Path -LiteralPath $src -PathType Container) {
                $eap = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try {
                    & robocopy.exe $src (Join-Path $backupDir $item) '/E' '/NFL' '/NDL' '/NJH' '/NJS' '/NP' | Out-Null
                    if ($LASTEXITCODE -ge 8) { throw "Backing up '$item' failed (robocopy $LASTEXITCODE). Refusing to overwrite the loader without a backup." }
                } finally { $ErrorActionPreference = $eap }
            } else {
                Copy-Item -LiteralPath $src -Destination $backupDir -Force
            }
        }
        Write-Ok "Backed up the current loader -> $backupDir"

        if ($KeepBackups -gt 0 -and (Test-Path -LiteralPath $backupRoot)) {
            $stale = @(Get-ChildItem -LiteralPath $backupRoot -Directory |
                       Where-Object { $_.Name -like 'loader-*' } |
                       Sort-Object LastWriteTime -Descending | Select-Object -Skip $KeepBackups)
            foreach ($old in $stale) {
                Remove-Item -LiteralPath $old.FullName -Recurse -Force
                Write-Host "  pruned old loader backup: $($old.Name)"
            }
        }
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

    if (-not $SkipPatch) {
        $patcher = if ($PatcherPath) { $PatcherPath } else { Join-Path $game 'tools\dtkit-patch.exe' }
        if (Test-Path -LiteralPath $patcher) {
            Write-Step 'Patching the bundle database...'
            $r = Invoke-Patcher -Exe $patcher -Action 'patch' -GameFolder $game
            Write-Ok '  patched'
            if ($r.Output) { Write-Verbose $r.Output }
        } else {
            Write-Warn "  patcher not found at '$patcher' - run toggle_darktide_mods.bat by hand."
        }
    }

    # ---- Record ----------------------------------------------------------------------

    [ordered]@{
        modId       = $script:LoaderModId
        name        = 'Darktide Mod Loader'
        version     = $newVersion
        source      = $sourceName
        installedAt = (Get-Date).ToString('o')
        patched     = (-not $SkipPatch)
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $game $script:StateFile) -Encoding UTF8

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
