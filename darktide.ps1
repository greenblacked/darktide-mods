<#
.SYNOPSIS
    One entry point for the whole Darktide mod workflow.

.DESCRIPTION
    Wraps the individual scripts so day-to-day use is a single verb.

        .\darktide.ps1 status     what is installed, staged and deployed
        .\darktide.ps1 check      what is outdated on Nexus (needs an API key)
        .\darktide.ps1 update     install downloaded archives into staging
        .\darktide.ps1 deploy     push staging into the game folder
        .\darktide.ps1 sync       update + deploy; stops if either step fails
        .\darktide.ps1 rollback   undo the last staging install (needs -Apply)
        .\darktide.ps1 restore    undo the last deploy to the game folder (needs -Apply)
        .\darktide.ps1 lock       regenerate darktide-modpack.lock.json
        .\darktide.ps1 lock -SyncIdsFromMap
                                  copy Nexus ids from mods-map.json into the lockfile
        .\darktide.ps1 init       find the game automatically and write config.json
        .\darktide.ps1 loader     install or update the Darktide Mod Loader
        .\darktide.ps1 export     zip your whole loadout as a personal backup
        .\darktide.ps1 import     restore a loadout zip and deploy it

    Everything is a dry run until you add -Apply, except 'status' and 'check'
    which never write anything. That includes rollback and restore.

.PARAMETER Verb
    Which action to run. See above.

.PARAMETER SyncIdsFromMap
    With 'lock': copy non-null modId/url values from mods-map.json into the
    existing lockfile. Does not need ModsRoot or a full regenerate.

.PARAMETER Apply
    Actually make changes. Without it you get a plan and nothing else.

.EXAMPLE
    .\darktide.ps1 sync
    Dry run of the full pipeline - shows what would be installed and deployed.

.EXAMPLE
    .\darktide.ps1 sync -Apply
    Install every newer archive from your download folder, then deploy to the game.

.EXAMPLE
    .\darktide.ps1 deploy -Apply -Mirror
    Deploy and remove mods from the game folder that are no longer in staging.

.EXAMPLE
    .\darktide.ps1 rollback
    Lists the backup set that would be restored. Add -Apply to write.

.EXAMPLE
    .\darktide.ps1 restore -Apply
    Restores the newest deploy backup into the game mods folder.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('init', 'status', 'check', 'update', 'deploy', 'sync', 'rollback', 'restore', 'lock',
                 'loader', 'export', 'import', 'help')]
    [string]   $Verb = 'help',

    [switch]   $Apply,
    [switch]   $Mirror,
    [switch]   $InstallLoader,
    [switch]   $RunToggle,
    [switch]   $Force,
    [switch]   $SyncIdsFromMap,
    [string[]] $Only,
    [string[]] $Skip,
    [string]   $BackupSet,
    [string]   $OutFile,
    [string]   $Path,
    [string]   $Source,
    [string]   $GamePath,
    [switch]   $Deploy,
    [string]   $ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Head { param([string]$m) Write-Host ''; Write-Host "== $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host $m -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host $m -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host $m -ForegroundColor Red }

$Updater = Join-Path $PSScriptRoot 'Update-DarktideMods.ps1'
$Deployer = Join-Path $PSScriptRoot 'Deploy-DarktideMods.ps1'
$Locker  = Join-Path $PSScriptRoot 'New-ModpackLock.ps1'
$Exporter = Join-Path $PSScriptRoot 'Export-DarktideLoadout.ps1'
$Importer = Join-Path $PSScriptRoot 'Import-DarktideLoadout.ps1'
$Initer   = Join-Path $PSScriptRoot 'Initialize-DarktideConfig.ps1'
$Loaderer = Join-Path $PSScriptRoot 'Install-DarktideLoader.ps1'

foreach ($s in @($Updater, $Deployer, $Locker, $Exporter, $Importer, $Initer, $Loaderer)) {
    if (-not (Test-Path -LiteralPath $s)) { throw "Missing script: $s" }
}

# ---- Verbs that must work before there is a config ---------------------------------

# 'init' is what creates config.json, so it cannot require one to exist.
if ($Verb -eq 'init') {
    Write-Head 'Detecting your Darktide install'
    & $Initer -ConfigPath $ConfigPath -GamePath $GamePath -Force:$Force -Confirm:$false
    return
}

if ($Verb -eq 'help') {
    Get-Help -Full $PSCommandPath | Out-String | Write-Host
    return
}

# SyncIdsFromMap only touches the lockfile and mods-map.json - no config, no ModsRoot.
if ($Verb -eq 'lock' -and $SyncIdsFromMap) {
    Write-Head 'Syncing lockfile Nexus ids from mods-map'
    & $Locker -SyncIdsFromMap
    return
}

# ---- Config ------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    $example = Join-Path $PSScriptRoot 'config.example.json'
    if (Test-Path -LiteralPath $example) {
        throw @"
No config.json yet. Let it find your game automatically:

    .\darktide.ps1 init

Or write one by hand from the template:

    Copy-Item '$example' '$ConfigPath'
    notepad '$ConfigPath'
"@
    }
    throw "No config at '$ConfigPath'."
}

$cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
function Get-Cfg {
    param([string] $Key, [string] $Default = '')
    if ($cfg.PSObject.Properties.Name -contains $Key -and "$($cfg.$Key)".Trim()) { return "$($cfg.$Key)" }
    return $Default
}

$modsRoot   = Get-Cfg 'ModsRoot'
$gamePath   = Get-Cfg 'GamePath'
$backupRoot = Get-Cfg 'BackupRoot'
$deployBk   = Get-Cfg 'DeployBackupRoot'

# ---- Verbs -------------------------------------------------------------------------

switch ($Verb) {

    'help' {
        Get-Help -Full $PSCommandPath | Out-String | Write-Host
        return
    }

    'status' {
        Write-Head 'Configuration'
        Write-Host "  staging mods : $modsRoot"
        Write-Host "  game folder  : $gamePath"
        Write-Host "  api key      : $(if ($env:NEXUS_API_KEY -or (Get-Cfg 'ApiKey')) { 'set (version checking enabled)' } else { 'not set (offline mode)' })"

        Write-Head 'Staging'
        if (Test-Path -LiteralPath $modsRoot) {
            $dirs = @(Get-ChildItem -LiteralPath $modsRoot -Directory | Where-Object { -not $_.Name.StartsWith('.') })
            $tracked = @($dirs | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.nexus-mod.json') })
            $withInfo = @($dirs | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'info.json') })
            Write-Host "  mod folders        : $($dirs.Count)"
            Write-Host "  version-tracked    : $($tracked.Count)"
            Write-Host "  with author info   : $($withInfo.Count)"
        } else { Write-Err "  missing: $modsRoot" }

        Write-Head 'Game folder'
        if ($gamePath -and (Test-Path -LiteralPath $gamePath)) {
            $gm = Join-Path $gamePath 'mods'
            if (Test-Path -LiteralPath $gm) {
                $gd = @(Get-ChildItem -LiteralPath $gm -Directory | Where-Object { -not $_.Name.StartsWith('.') })
                Write-Host "  deployed mods : $($gd.Count)"

                # Drift between staging and live
                $sn = @(Get-ChildItem -LiteralPath $modsRoot -Directory -ErrorAction SilentlyContinue |
                        Where-Object { -not $_.Name.StartsWith('.') } | ForEach-Object { $_.Name })
                $gn = @($gd | ForEach-Object { $_.Name })
                $onlyStage = @($sn | Where-Object { $gn -notcontains $_ })
                $onlyGame  = @($gn | Where-Object { $sn -notcontains $_ })
                if ($onlyStage) { Write-Warn "  staged, not deployed : $($onlyStage -join ', ')" }
                if ($onlyGame)  { Write-Warn "  in game, not staged  : $($onlyGame -join ', ')" }
                if (-not $onlyStage -and -not $onlyGame) { Write-Ok '  staging and game are in sync' }
            } else { Write-Warn '  no mods\ folder in the game directory - never deployed' }

            $toggle = Join-Path $gamePath 'toggle_darktide_mods.bat'
            if (Test-Path -LiteralPath $toggle) {
                $lstate = Join-Path $gamePath '.darktide-loader.json'
                if (Test-Path -LiteralPath $lstate) {
                    try {
                        $ls = Get-Content -LiteralPath $lstate -Raw -Encoding UTF8 | ConvertFrom-Json
                        $lv = if ($ls.PSObject.Properties.Name -contains 'version' -and $ls.version) { $ls.version } else { 'unknown' }
                        Write-Ok "  mod loader present (version $lv)"
                    } catch { Write-Ok '  mod loader present (state file unreadable)' }
                } else {
                    Write-Ok '  mod loader present (version not tracked - run: .\darktide.ps1 loader -Apply)'
                }
                $patchFile = @(Get-ChildItem -LiteralPath (Join-Path $gamePath 'bundle') -Filter '*.patch_*' -File -ErrorAction SilentlyContinue)
                if (-not $patchFile) { Write-Warn '  mod entry bundle missing - mods will not load' }
            }
            else { Write-Warn '  mod loader NOT installed (run: .\darktide.ps1 loader -Apply)' }
        } else { Write-Err "  game folder not found: $gamePath" }

        Write-Head 'Backups'
        foreach ($b in @(@{ N = 'staging'; P = $backupRoot }, @{ N = 'deploy'; P = $deployBk })) {
            if ($b.P -and (Test-Path -LiteralPath $b.P)) {
                $sets = @(Get-ChildItem -LiteralPath $b.P -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
                $last = if ($sets) { $sets[0].Name } else { 'none' }
                Write-Host "  $($b.N): $($sets.Count) set(s), latest $last"
            } else { Write-Host "  $($b.N): none yet" }
        }
        Write-Host ''
        return
    }

    'check' {
        Write-Head 'Checking Nexus for updates'
        & $Updater -ConfigPath $ConfigPath -Only $Only -Skip $Skip
        return
    }

    'update' {
        Write-Head "Installing downloaded archives into staging$(if (-not $Apply) { ' (dry run)' })"
        & $Updater -ConfigPath $ConfigPath -NoApi -Apply:$Apply -Force:$Force -Only $Only -Skip $Skip
        return
    }

    'deploy' {
        Write-Head "Deploying staging to the game folder$(if (-not $Apply) { ' (dry run)' })"
        & $Deployer -ConfigPath $ConfigPath -Apply:$Apply -Mirror:$Mirror `
                    -InstallLoader:$InstallLoader -RunToggle:$RunToggle -Force:$Force
        return
    }

    'sync' {
        Write-Head "Full sync: update staging, then deploy$(if (-not $Apply) { ' (dry run)' })"

        & $Updater -ConfigPath $ConfigPath -NoApi -Apply:$Apply -Force:$Force -Only $Only -Skip $Skip
        # $LASTEXITCODE may be undefined in a fresh session, which StrictMode treats as an error.
        $code = if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { 0 }
        if ($code -and $code -ne 0) { throw 'Update step failed - not deploying.' }

        & $Deployer -ConfigPath $ConfigPath -Apply:$Apply -Mirror:$Mirror `
                    -InstallLoader:$InstallLoader -RunToggle:$RunToggle -Force:$Force
        $code = if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { 0 }
        if ($code -and $code -ne 0) { throw 'Deploy step finished with problems - lockfile not refreshed.' }

        if ($Apply) {
            Write-Head 'Refreshing lockfile'
            & $Locker -ModsRoot $modsRoot -NoHash
        }
        return
    }

    'rollback' {
        Write-Head "Rolling back the staging folder$(if (-not $Apply) { ' (dry run)' })"
        & $Updater -ConfigPath $ConfigPath -Rollback -BackupSet $BackupSet -Apply:$Apply
        if ($Apply) {
            Write-Warn 'Staging restored. Run: .\darktide.ps1 deploy -Apply   to push it to the game.'
        }
        return
    }

    'restore' {
        Write-Head "Restoring the game mods folder from a deploy backup$(if (-not $Apply) { ' (dry run)' })"
        if (-not $deployBk -or -not (Test-Path -LiteralPath $deployBk)) {
            throw "No deploy backups at '$deployBk'."
        }
        if (-not $gamePath) { throw 'GamePath is not set in config.json.' }

        # Same shape of checks Deploy-DarktideMods.ps1 uses before writing. Restore
        # used to skip them and extract with no zip-slip guard.
        if (-not (Test-Path -LiteralPath $gamePath -PathType Container)) {
            throw "Game folder '$gamePath' does not exist. Check GamePath in config.json."
        }
        $gameFull = (Resolve-Path -LiteralPath $gamePath).Path.TrimEnd('\')
        if ($gameFull -match '^[A-Za-z]:$' -or $gameFull -match '^[A-Za-z]:\\?$') {
            throw "GamePath '$gameFull' is a drive root. Refusing."
        }
        if (($gameFull -split '\\').Count -lt 3) {
            throw "GamePath '$gameFull' is suspiciously shallow. Point it at the Darktide install folder."
        }
        $markers = @(
            (Join-Path $gameFull 'binaries\Darktide.exe'),
            (Join-Path $gameFull 'binaries_dx12\Darktide.exe'),
            (Join-Path $gameFull 'bundle\bundle_database.data'),
            (Join-Path $gameFull 'launcher\Launcher.exe')
        )
        if (-not (@($markers | Where-Object { Test-Path -LiteralPath $_ }))) {
            throw "'$gameFull' does not look like a Darktide install. Refusing to restore into it."
        }

        # Newest first by write time, not by name: a same-second collision gets a
        # '-1' suffix that would sort before the un-suffixed name.
        $zips = @(Get-ChildItem -LiteralPath $deployBk -File |
                  Where-Object { $_.Extension -eq '.zip' } | Sort-Object LastWriteTime -Descending)
        if (-not $zips) { throw "No deploy backups found in '$deployBk'." }

        $zip = if ($BackupSet) {
            $hit = @($zips | Where-Object { $_.Name -like "*$BackupSet*" })
            if (-not $hit) { throw "No deploy backup matching '$BackupSet'." }
            $hit[0]
        } else { $zips[0] }

        $gm = Join-Path $gameFull 'mods'
        Write-Host "  backup : $($zip.Name)"
        Write-Host "  target : $gm"

        if (-not $Apply) {
            Write-Warn '  dry run - re-run with -Apply to restore.'
            Write-Host ''
            Write-Host '  available backups:'
            $zips | Select-Object -First 10 | ForEach-Object { Write-Host "    $($_.Name)" }
            return
        }

        $p = Get-Process -Name 'Darktide' -ErrorAction SilentlyContinue
        if ($p) { throw "Darktide.exe is running. Close the game first." }

        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $stage = "$gm.restoring"
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        New-Item -ItemType Directory -Path $stage -Force | Out-Null

        # Guarded extract - same rules as Import-DarktideLoadout.ps1.
        $root = [System.IO.Path]::GetFullPath($stage).TrimEnd('\') + '\'
        $archive = [System.IO.Compression.ZipFile]::OpenRead($zip.FullName)
        try {
            foreach ($entry in $archive.Entries) {
                $rel = $entry.FullName -replace '\\', '/'
                if (-not $rel) { continue }
                if ($rel -match '(^|/)\.\.(/|$)' -or $rel -match '^([A-Za-z]:|/)') {
                    throw "Backup contains an unsafe path: '$($entry.FullName)'"
                }
                $target = Join-Path $stage ($rel -replace '/', '\')
                $full = [System.IO.Path]::GetFullPath($target)
                if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Backup entry '$($entry.FullName)' resolves outside the restore folder."
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
        } catch {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
            throw
        } finally {
            $archive.Dispose()
        }

        if (Test-Path -LiteralPath $gm) { Remove-Item -LiteralPath $gm -Recurse -Force }
        Move-Item -LiteralPath $stage -Destination $gm -Force
        Write-Ok "  restored from $($zip.Name)"
        return
    }

    'lock' {
        Write-Head 'Regenerating the lockfile'
        & $Locker -ModsRoot $modsRoot
        return
    }

    'export' {
        Write-Head "Exporting the loadout as a zip$(if (-not $Apply) { ' (dry run)' })"
        if (-not $Apply) {
            Write-Warn 'Dry run: pass -Apply to actually write the archive.'
        }
        & $Exporter -ConfigPath $ConfigPath -OutFile $OutFile -Force:$Force `
                    -WhatIf:(-not $Apply) -Confirm:$false
        return
    }

    'loader' {
        Write-Head "Mod loader$(if (-not $Apply) { ' (dry run)' })"
        & $Loaderer -ConfigPath $ConfigPath -Source $Source -Apply:$Apply -Force:$Force -Confirm:$false
        return
    }

    'import' {
        if (-not $Path) {
            throw "Which archive? Pass -Path, e.g. .\darktide.ps1 import -Path 'D:\backup\darktide-loadout-20260829.zip' -Apply"
        }
        Write-Head "Restoring a loadout archive$(if (-not $Apply) { ' (dry run)' })"
        # Restoring a saved loadout is only 'fully automated' if it lands in the game
        # too, so deploy by default unless the caller says otherwise.
        $alsoDeploy = if ($PSBoundParameters.ContainsKey('Deploy')) { [bool]$Deploy } else { $true }
        & $Importer -ConfigPath $ConfigPath -Path $Path -Apply:$Apply `
                    -Deploy:$alsoDeploy -Mirror:$Mirror -Force:$Force -Confirm:$false
        return
    }
}
