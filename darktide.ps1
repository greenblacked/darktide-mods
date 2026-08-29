<#
.SYNOPSIS
    One entry point for the whole Darktide mod workflow.

.DESCRIPTION
    Wraps the individual scripts so day-to-day use is a single verb.

        .\darktide.ps1 status     what is installed, staged and deployed
        .\darktide.ps1 check      what is outdated on Nexus (needs an API key)
        .\darktide.ps1 update     install downloaded archives into staging
        .\darktide.ps1 deploy     push staging into the game folder
        .\darktide.ps1 sync       update + deploy, the everyday one
        .\darktide.ps1 rollback   undo the last staging install
        .\darktide.ps1 restore    undo the last deploy to the game folder
        .\darktide.ps1 lock       regenerate darktide-modpack.lock.json
        .\darktide.ps1 init       find the game automatically and write config.json
        .\darktide.ps1 export     zip your whole loadout as a personal backup
        .\darktide.ps1 import     restore a loadout zip and deploy it

    Everything is a dry run until you add -Apply, except 'status' and 'check'
    which never write anything.

.PARAMETER Verb
    Which action to run. See above.

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
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('init', 'status', 'check', 'update', 'deploy', 'sync', 'rollback', 'restore', 'lock', 'export', 'import', 'help')]
    [string]   $Verb = 'help',

    [switch]   $Apply,
    [switch]   $Mirror,
    [switch]   $InstallLoader,
    [switch]   $RunToggle,
    [switch]   $Force,
    [string[]] $Only,
    [string[]] $Skip,
    [string]   $BackupSet,
    [string]   $OutFile,
    [string]   $Path,
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

foreach ($s in @($Updater, $Deployer, $Locker, $Exporter, $Importer, $Initer)) {
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
            if (Test-Path -LiteralPath $toggle) { Write-Ok '  mod loader present' }
            else { Write-Warn '  mod loader NOT installed (deploy with -InstallLoader)' }
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

        if ($Apply) {
            Write-Head 'Refreshing lockfile'
            & $Locker -ModsRoot $modsRoot -NoHash
        }
        return
    }

    'rollback' {
        Write-Head 'Rolling back the staging folder'
        & $Updater -ConfigPath $ConfigPath -Rollback -BackupSet $BackupSet
        Write-Warn 'Staging restored. Run: .\darktide.ps1 deploy -Apply   to push it to the game.'
        return
    }

    'restore' {
        Write-Head 'Restoring the game mods folder from a deploy backup'
        if (-not $deployBk -or -not (Test-Path -LiteralPath $deployBk)) {
            throw "No deploy backups at '$deployBk'."
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

        $gm = Join-Path $gamePath 'mods'
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
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip.FullName, $stage)
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
