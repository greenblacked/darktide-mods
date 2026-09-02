<#
.SYNOPSIS
    Deploys a staging mods folder into the installed Darktide game folder.

.DESCRIPTION
    Two-stage layout:

        D:\Darktide\mods\                      staging - where you update mods
                  |  Deploy-DarktideMods.ps1
                  v
        <Steam>\Warhammer 40,000 DARKTIDE\mods\    live - what the game loads

    Working in staging means a broken mod never reaches the game folder until you
    deploy, and the pre-deploy backup means one command puts the game back.

    Nothing is written without -Apply. Supports -WhatIf.

.PARAMETER GamePath
    Game install root, e.g. 'D:\Games\Steam\steamapps\common\Warhammer 40,000 DARKTIDE'.
    Validated before anything is touched - the folder must actually look like Darktide.

.PARAMETER Mirror
    Delete mods in the game folder that no longer exist in staging. Off by default,
    because it removes files. The pre-deploy backup is taken either way.

.PARAMETER InstallLoader
    Also copy the Darktide Mod Loader payload (binaries\, bundle\, tools\, toggle bat)
    from -LoaderSource into the game folder. Needed on a fresh install and after Steam
    verifies/repairs the game files.

.EXAMPLE
    .\Deploy-DarktideMods.ps1 -Apply -WhatIf
    Shows exactly what would be copied.

.EXAMPLE
    .\Deploy-DarktideMods.ps1 -Apply
    Backs up the live mods folder, then syncs staging into it.

.NOTES
    After any Darktide patch, Steam replaces the bundle database and the mod loader
    stops working. Re-run toggle_darktide_mods.bat in the game folder - this script
    reminds you and can run it for you with -RunToggle.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string] $ConfigPath   = (Join-Path $PSScriptRoot 'config.json'),
    [string] $StagingMods,
    [string] $GamePath,
    [string] $LoaderSource,
    [string] $BackupRoot,

    [switch] $Apply,
    [switch] $Mirror,
    [switch] $InstallLoader,
    [switch] $RunToggle,
    [switch] $Force,

    [ValidateRange(0, 1000)]
    [int] $KeepBackups = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

function Write-Step { param([string]$m) Write-Host $m -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host $m -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host $m -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host $m -ForegroundColor Red }

# ----------------------------------------------------------------------------------
# Config
# ----------------------------------------------------------------------------------

# Note the key is DeployBackupRoot, kept separate from the updater's BackupRoot so
# staging backups and game-folder backups never land in the same pile.
$cfg = @{
    ModsRoot         = ''
    GamePath         = ''
    LoaderSource     = ''
    DeployBackupRoot = ''
}

if (Test-Path -LiteralPath $ConfigPath) {
    $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    if ($raw.Trim()) {
        $j = $raw | ConvertFrom-Json
        foreach ($k in @($cfg.Keys)) {
            if ($j.PSObject.Properties.Name -contains $k -and "$($j.$k)".Trim()) { $cfg[$k] = "$($j.$k)" }
        }
    }
}

if ($StagingMods)  { $cfg.ModsRoot     = $StagingMods }
if ($GamePath)     { $cfg.GamePath     = $GamePath }
if ($LoaderSource) { $cfg.LoaderSource = $LoaderSource }
if ($BackupRoot)   { $cfg.DeployBackupRoot   = $BackupRoot }

if (-not $cfg.ModsRoot) { throw "Staging mods folder not set. Put ModsRoot in config.json or pass -StagingMods." }
if (-not $cfg.GamePath) { throw "Game folder not set. Put GamePath in config.json or pass -GamePath." }

# ----------------------------------------------------------------------------------
# Validation - this script deletes things, so be paranoid about the target
# ----------------------------------------------------------------------------------

function Assert-ValidGamePath {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Game folder '$Path' does not exist. Check GamePath in config.json."
    }
    $full = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\')

    # Never let this point at a drive root or a top-level folder.
    if ($full -match '^[A-Za-z]:$' -or $full -match '^[A-Za-z]:\\?$') {
        throw "GamePath '$full' is a drive root. Refusing."
    }
    if (($full -split '\\').Count -lt 3) {
        throw "GamePath '$full' is suspiciously shallow. Point it at the Darktide install folder."
    }

    # It must actually be Darktide. Any of these is proof enough.
    $markers = @(
        (Join-Path $full 'binaries\Darktide.exe'),
        (Join-Path $full 'binaries_dx12\Darktide.exe'),
        (Join-Path $full 'bundle\bundle_database.data'),
        (Join-Path $full 'launcher\Launcher.exe')
    )
    $hit = @($markers | Where-Object { Test-Path -LiteralPath $_ })
    if (-not $hit) {
        throw @"
'$full' does not look like a Darktide install - none of these were found:
  binaries\Darktide.exe
  binaries_dx12\Darktide.exe
  bundle\bundle_database.data
  launcher\Launcher.exe
Refusing to write there. Fix GamePath in config.json.
"@
    }
    Write-Verbose "Game folder verified via: $($hit[0])"
    return $full
}

function Assert-ValidStaging {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Staging mods folder '$Path' does not exist."
    }
    $full = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\')
    $lo   = Join-Path $full 'mod_load_order.txt'
    $base = Join-Path $full 'base'
    if (-not (Test-Path -LiteralPath $lo) -and -not (Test-Path -LiteralPath $base)) {
        throw "'$full' is not a mods folder (no mod_load_order.txt, no base\)."
    }
    $count = @(Get-ChildItem -LiteralPath $full -Directory).Count
    if ($count -eq 0) { throw "Staging folder '$full' has no mods in it. Refusing to deploy an empty set." }
    return $full
}

function Assert-GameNotRunning {
    # Twin of the copy in Update-DarktideMods.ps1 - keep the two identical.
    $proc = Get-Process -Name 'Darktide' -ErrorAction SilentlyContinue
    if ($proc) {
        throw "Darktide.exe is running (PID $($proc.Id -join ', ')). Close the game before changing mod files."
    }
}

function Get-SyncPendingCode {
    <#
        Runs the same robocopy in list-only mode (/L) so we can tell whether a deploy
        would actually change anything. This is what makes the deploy idempotent: with
        nothing to copy we take no backup and write nothing at all.

        Returns the robocopy exit code, whose low bits mean:
          1  files would be copied
          2  extra files/dirs exist in the destination (only a change under -Mirror)
          4  mismatched files/dirs
          8+ robocopy could not read one of the trees
    #>
    param(
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $Destination,
        [switch] $WithPurge
    )

    # No destination yet - everything is pending.
    if (-not (Test-Path -LiteralPath $Destination)) { return 1 }

    $rcArgs = @($Source, $Destination, '/E', '/L', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:0', '/W:0')
    if ($WithPurge) { $rcArgs += '/PURGE' }

    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & robocopy.exe @rcArgs | Out-Null
        return $LASTEXITCODE
    } finally { $ErrorActionPreference = $eap }
}

# ----------------------------------------------------------------------------------

$staging = Assert-ValidStaging  -Path $cfg.ModsRoot
$game    = Assert-ValidGamePath -Path $cfg.GamePath
$gameMods = Join-Path $game 'mods'

if (-not $cfg.DeployBackupRoot) { $cfg.DeployBackupRoot = Join-Path (Split-Path -Parent $staging) 'deploy_backups' }

Write-Step '=== Darktide mod deploy ==='
Write-Host  "Staging : $staging"
Write-Host  "Game    : $game"
Write-Host  "Target  : $gameMods"
Write-Host  "Backups : $($cfg.DeployBackupRoot)"
Write-Host  "Mode    : $(if ($Apply) { 'APPLY' } else { 'DRY RUN (pass -Apply to write)' })"
Write-Host  ''

# Only when we are actually going to write. A dry run touches nothing, so there is no
# reason to make someone close the game just to see the plan - and Update-DarktideMods.ps1
# gates the same guard on -Apply.
if ($Apply) { Assert-GameNotRunning }

# ---- Plan --------------------------------------------------------------------------

$stagingDirs = @(Get-ChildItem -LiteralPath $staging -Directory | Where-Object { -not $_.Name.StartsWith('.') })
$liveDirs    = @()
if (Test-Path -LiteralPath $gameMods) {
    $liveDirs = @(Get-ChildItem -LiteralPath $gameMods -Directory | Where-Object { -not $_.Name.StartsWith('.') })
}

$stagingNames = @($stagingDirs | ForEach-Object { $_.Name })
$liveNames    = @($liveDirs    | ForEach-Object { $_.Name })

$toAdd    = @($stagingNames | Where-Object { $liveNames -notcontains $_ })
$toRemove = @($liveNames    | Where-Object { $stagingNames -notcontains $_ })

$pendingCode = Get-SyncPendingCode -Source $staging -Destination $gameMods -WithPurge:$Mirror
if ($pendingCode -ge 8) {
    throw "robocopy could not compare staging with the game folder (exit code $pendingCode). Check both paths are readable."
}

# Extras in the destination (bit 1) are only a change when -Mirror will purge them.
$needsSync = [bool]($pendingCode -band 1) -or
             [bool]($pendingCode -band 4) -or
             ($Mirror -and [bool]($pendingCode -band 2))

Write-Step "Plan"
Write-Host "  staging mods : $($stagingNames.Count)"
Write-Host "  live mods    : $($liveNames.Count)"
if ($toAdd)    { Write-Host "  new in game  : $($toAdd -join ', ')" -ForegroundColor Green }
if ($toRemove) {
    if ($Mirror) { Write-Warn "  will DELETE  : $($toRemove -join ', ')" }
    else         { Write-Host "  only in game : $($toRemove -join ', ')  (left alone; pass -Mirror to delete)" }
}
if ($needsSync) {
    Write-Host "  pending      : changes to copy (robocopy code $pendingCode)"
} else {
    Write-Ok    "  pending      : none - the game folder already matches staging"
}
Write-Host ''

if (-not $Apply) {
    if ($needsSync) { Write-Warn 'Dry run complete. Nothing was written. Re-run with -Apply.' }
    else            { Write-Ok   'Dry run complete. Already in sync - an -Apply run would write nothing.' }
    return
}

# ---- Backup ------------------------------------------------------------------------

$backupZip = $null
if (-not ($needsSync -or $Force)) {
    # Idempotent no-op: re-running a deploy that has nothing to do must not churn the
    # game folder or pile up backup archives.
    Write-Ok 'Already in sync - no backup taken and nothing copied. (Pass -Force to redeploy anyway.)'
}
elseif (Test-Path -LiteralPath $gameMods) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    if (-not (Test-Path -LiteralPath $cfg.DeployBackupRoot)) {
        New-Item -ItemType Directory -Path $cfg.DeployBackupRoot -Force | Out-Null
    }
    # The stamp is only second-resolution, so two deploys in the same second would
    # collide and CreateFromDirectory would fail on the existing file.
    $backupZip = Join-Path $cfg.DeployBackupRoot "gamemods-$stamp.zip"
    $suffix = 1
    while (Test-Path -LiteralPath $backupZip) {
        $backupZip = Join-Path $cfg.DeployBackupRoot "gamemods-$stamp-$suffix.zip"
        $suffix++
    }
    if ($PSCmdlet.ShouldProcess($gameMods, "Back up to $backupZip")) {
        Write-Step "Backing up the live mods folder..."
        [System.IO.Compression.ZipFile]::CreateFromDirectory(
            $gameMods, $backupZip, [System.IO.Compression.CompressionLevel]::Optimal, $false)
        Write-Ok "  -> $backupZip ($([math]::Round((Get-Item -LiteralPath $backupZip).Length / 1MB, 1)) MB)"

        # Keep the backup folder bounded so repeated deploys cannot fill the disk.
        if ($KeepBackups -gt 0) {
            $stale = @(Get-ChildItem -LiteralPath $cfg.DeployBackupRoot -Filter 'gamemods-*.zip' -File |
                       Sort-Object LastWriteTime -Descending | Select-Object -Skip $KeepBackups)
            foreach ($old in $stale) {
                Remove-Item -LiteralPath $old.FullName -Force
                Write-Host "  pruned old backup: $($old.Name)"
            }
        }
    }
} else {
    Write-Warn 'No existing mods folder in the game directory - this is a first deploy.'
}

# ---- Sync --------------------------------------------------------------------------

if (($needsSync -or $Force) -and $PSCmdlet.ShouldProcess($gameMods, "Sync from $staging")) {
    if (-not (Test-Path -LiteralPath $gameMods)) {
        New-Item -ItemType Directory -Path $gameMods -Force | Out-Null
    }

    Write-Step 'Syncing mods...'
    $rcArgs = @($staging, $gameMods, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:2', '/W:2')
    if ($Mirror) { $rcArgs += '/PURGE' }

    & robocopy.exe @rcArgs | Out-Null
    $rc = $LASTEXITCODE

    # robocopy: 0-7 are success//informational, 8+ are real failures.
    if ($rc -ge 8) {
        Write-Err "robocopy failed with exit code $rc."
        if ($backupZip) {
            Write-Warn "The live mods folder may be inconsistent. Restore with:"
            Write-Warn "  Expand-Archive -LiteralPath '$backupZip' -DestinationPath '$gameMods' -Force"
        }
        throw "Deploy aborted: robocopy exit code $rc."
    }
    Write-Ok "  sync complete (robocopy code $rc)"
}

# ---- Mod loader payload ------------------------------------------------------------

if ($InstallLoader) {
    if (-not $cfg.LoaderSource) {
        Write-Warn 'InstallLoader requested but LoaderSource is not set in config.json - skipping.'
    } elseif (-not (Test-Path -LiteralPath $cfg.LoaderSource -PathType Container)) {
        Write-Warn "LoaderSource '$($cfg.LoaderSource)' not found - skipping."
    } else {
        Write-Step 'Installing mod loader payload...'
        foreach ($item in @('binaries', 'bundle', 'tools', 'toggle_darktide_mods.bat')) {
            $src = Join-Path $cfg.LoaderSource $item
            if (-not (Test-Path -LiteralPath $src)) { continue }
            if ($PSCmdlet.ShouldProcess((Join-Path $game $item), "Copy $item from loader")) {
                if (Test-Path -LiteralPath $src -PathType Container) {
                    & robocopy.exe $src (Join-Path $game $item) '/E' '/NFL' '/NDL' '/NJH' '/NJS' '/NP' | Out-Null
                    if ($LASTEXITCODE -ge 8) { throw "Copying loader '$item' failed (robocopy $LASTEXITCODE)." }
                } else {
                    Copy-Item -LiteralPath $src -Destination $game -Force
                }
                Write-Ok "  $item"
            }
        }
    }
}

# ---- Toggle ------------------------------------------------------------------------

$toggle = Join-Path $game 'toggle_darktide_mods.bat'
if ($RunToggle) {
    if (Test-Path -LiteralPath $toggle) {
        if ($PSCmdlet.ShouldProcess($toggle, 'Run mod loader patcher')) {
            Write-Step 'Running toggle_darktide_mods.bat...'
            Push-Location $game
            try { & cmd.exe /c "`"$toggle`"" } finally { Pop-Location }
            Write-Ok '  patcher finished - check its output above'
        }
    } else {
        Write-Warn 'toggle_darktide_mods.bat not found in the game folder. Use -InstallLoader first.'
    }
}

# ---- Post-checks -------------------------------------------------------------------

Write-Host ''
Write-Step 'Post-checks'

$deployed = @(Get-ChildItem -LiteralPath $gameMods -Directory -ErrorAction SilentlyContinue |
              Where-Object { -not $_.Name.StartsWith('.') })
Write-Host "  mod folders in game : $($deployed.Count)"

$ok = $true
foreach ($check in @(
    @{ Path = (Join-Path $gameMods 'mod_load_order.txt'); What = 'mod_load_order.txt' },
    @{ Path = (Join-Path $gameMods 'base');               What = 'mods\base'          },
    @{ Path = (Join-Path $gameMods 'dmf');                What = 'mods\dmf'           })) {
    if (Test-Path -LiteralPath $check.Path) { Write-Ok "  present: $($check.What)" }
    else { Write-Err "  MISSING: $($check.What)"; $ok = $false }
}

# Every folder in the load order must actually exist, or DMF errors on startup.
$loPath = Join-Path $gameMods 'mod_load_order.txt'
if (Test-Path -LiteralPath $loPath) {
    $wanted = @(Get-Content -LiteralPath $loPath -Encoding UTF8 |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ -and -not $_.StartsWith('--') })
    $names   = @($deployed | ForEach-Object { $_.Name })
    $missing = @($wanted | Where-Object { $names -notcontains $_ })
    if ($missing) {
        Write-Err "  load order references missing folders: $($missing -join ', ')"
        Write-Err '  the game will error on startup - remove them from mod_load_order.txt or install them'
        $ok = $false
    } else {
        Write-Ok "  load order: all $($wanted.Count) entries resolve"
    }
}

if (-not (Test-Path -LiteralPath $toggle)) {
    Write-Warn '  toggle_darktide_mods.bat not in the game folder (re-run with -InstallLoader)'
}

Write-Host ''
if ($ok) {
    Write-Ok 'Deploy OK.'
} else {
    Write-Err 'Deploy finished with problems - see above.'
    exit 1
}

if ($backupZip) {
    Write-Host ''
    Write-Host 'Undo this deploy:' -ForegroundColor Cyan
    Write-Host "  Remove-Item -LiteralPath '$gameMods' -Recurse -Force"
    Write-Host "  Expand-Archive -LiteralPath '$backupZip' -DestinationPath '$gameMods'"
}

Write-Host ''
Write-Warn 'Reminder: after any Darktide patch, Steam replaces the bundle database and mods stop loading.'
Write-Warn "Fix with:  cd `"$game`"  ;  .\toggle_darktide_mods.bat"
