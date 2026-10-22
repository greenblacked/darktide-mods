<#
.SYNOPSIS
    One entry point for the whole Darktide mod workflow.

.DESCRIPTION
    Wraps the individual scripts so day-to-day use is a single verb.

        .\darktide.ps1 status     what is installed, staged and deployed
        .\darktide.ps1 check      what is outdated on Nexus (needs an API key)
        .\darktide.ps1 links      where to look for updates with no API key at all
        .\darktide.ps1 links -Open
                                  ...and open those Nexus pages in the browser
        .\darktide.ps1 update     install downloaded archives into staging
        .\darktide.ps1 deploy     push staging into the game folder
        .\darktide.ps1 sync       update + deploy; stops if either step fails
        .\darktide.ps1 rollback   undo the last staging install (needs -Apply)
        .\darktide.ps1 restore    undo the last deploy to the game folder (needs -Apply)
        .\darktide.ps1 lock       regenerate darktide-modpack.lock.json
        .\darktide.ps1 lock -OutFile my-loadout.lock.json
                                  write the lockfile somewhere else, to share it
        .\darktide.ps1 lock -SyncIdsFromMap
                                  copy Nexus ids from mods-map.json into the lockfile
        .\darktide.ps1 init       find the game automatically and write config.json
        .\darktide.ps1 loader     install or update the Darktide Mod Loader
        .\darktide.ps1 loader -PatchOnly
                                  re-apply the bundle patch after a game update
        .\darktide.ps1 loader -RestoreBackup
                                  put a previous loader back from loader_backups
        .\darktide.ps1 export     zip your whole loadout as a personal backup
        .\darktide.ps1 import     restore a loadout zip and deploy it
        .\darktide.ps1 upgrade    the everyday loop: plan, ask once, then update +
                                  deploy + lockfile, with the undo commands at the end
        .\darktide.ps1 patchcheck after a game patch: is the loader patch still in
                                  place, and what to run next
        .\darktide.ps1 diff       how two loadouts differ: lockfile, export zip,
                                  git:<rev> or current staging
        .\darktide.ps1 errors     which mod most likely caused the last crash or error
        .\darktide.ps1 settings   back up or restore your mod settings file
        .\darktide.ps1 changes    per mod, what the last update changed (read-only)
        .\darktide.ps1 disable    switch a mod off in the load order (-Only); lists
                                  what is switched off when -Only is left out
        .\darktide.ps1 enable     switch a disabled mod back on (-Only)
        .\darktide.ps1 pin        list held mods; with -Only, hold them at their version
        .\darktide.ps1 intake     classify the archives in your download folder
                                  and list what is still to download
        .\darktide.ps1 profile    save, list, show, switch or delete a named load order
        .\darktide.ps1 need -Path their.lock.json
                                  what you lack from a friend's lockfile, with links

    Everything is a dry run until you add -Apply, except 'status', 'check',
    'links', 'patchcheck', 'diff', 'intake' and 'need' which never write
    anything (patchcheck -Remember stores a baseline beside staging; need writes
    only an -OutFile you ask for), 'lock' which always writes the manifest,
    'profile -Action save', which writes one new file in the profiles folder and
    will not replace an existing profile without -Force, and 'upgrade', which
    shows its plan and asks before it writes (answering no writes nothing). The
    dry-run default includes rollback, restore and 'profile -Action switch'.

    'enable' and 'disable' edit only the staging mod_load_order.txt. Run
    'deploy -Apply' afterwards to make the change live.

.PARAMETER Verb
    Which action to run. See above.

.PARAMETER CheckGitHub
    With 'links': also ask the public GitHub API for the latest release tag of
    any mod that has a `githubRepo` in mods-map.json. Off by default, because
    the rest of 'links' needs no network.

.PARAMETER Open
    With 'links': after printing the list, open each selected mod's Nexus page in
    the browser. Pages are built from the lockfile's numeric modId only, never its
    free-text url. Opens nothing if there are more than 10 pages; narrow with -Only
    (Find-ModUpdates.ps1 -OpenLimit raises the cap). With -CheckGitHub, only mods
    whose GitHub release differs are opened.

.PARAMETER SyncIdsFromMap
    With 'lock': copy non-null modId/url values from mods-map.json into the
    existing lockfile. Does not need ModsRoot or a full regenerate. With
    -OutFile, that file is the existing lockfile to update in place, instead of
    the repository one; it is edited without asking for -Force.

.PARAMETER Action
    With 'profile': save, list, show, switch or delete. Default: list.

.PARAMETER Name
    With 'profile': the profile to save, show, switch to or delete, e.g. 'full'.

.PARAMETER Apply
    Actually make changes. Without it you get a plan and nothing else.
    'upgrade' does not use it: its question is the gate, and -Yes answers it.

.PARAMETER Yes
    With 'upgrade': apply the plan without asking 'Apply this plan? [y/N]'. Needed
    in a non-interactive session, where upgrade refuses rather than wait.

.PARAMETER PatchOnly
    With 'loader': re-apply the bundle patch with the dtkit-patch.exe already in the
    game folder, after a Steam update replaced the bundle database. No download, no
    file copy, never the toggle. Does nothing if the database is still the one it
    patched last time.

.PARAMETER RestoreBackup
    With 'loader': put a previous loader back from loader_backups. The dry run lists
    the backups; -BackupSet picks one by part of its name, otherwise the newest.

.PARAMETER Remember
    With 'patchcheck': store the current game build and bundle database
    fingerprint as the baseline the next check compares against. The file goes
    beside the staging folder, never into the game folder.

.PARAMETER Left
    With 'diff': the baseline loadout. A lockfile, an export zip, git:<rev> or
    current. Defaults to the repository lockfile.

.PARAMETER Right
    With 'diff': the loadout to compare with it. Same forms as -Left. Defaults to
    current, the staging folder as it is now. Only 'current' needs config.json.

.PARAMETER LogDir
    With 'errors': the folder holding Darktide's console logs. Defaults to
    ConsoleLogDir in config.json, then %APPDATA%\Fatshark\Darktide\console_logs.
    With -LogDir, 'errors' needs no config.json at all.

.PARAMETER Last
    With 'errors': how many of the newest console logs to read. Default 1.

.PARAMETER BackupSet
    With 'rollback' or 'restore': which backup set to restore. With 'settings':
    restore the settings backup whose name contains this text instead of taking a
    new backup; a substring matching more than one backup is refused.

.PARAMETER Unpin
    With 'pin': release the -Only mods instead of holding them.

.PARAMETER Reason
    With 'pin': why the mod is held, e.g. 'crashes on 1.4'. Shown when listing pins.

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

.EXAMPLE
    .\darktide.ps1 loader -PatchOnly -Apply
    Mods stopped loading after a Darktide update: re-patch the bundle database.

.EXAMPLE
    .\darktide.ps1 links
    Every mod and its Nexus page, so checking by hand is a list of links. No key,
    no network.

.EXAMPLE
    .\darktide.ps1 upgrade
    Show what update and deploy would do as one plan, ask once, then apply it and
    print the backup names and the commands that undo it.

.EXAMPLE
    .\darktide.ps1 patchcheck
    After a Fatshark patch: was the game updated since the loader was patched,
    and what to run next. Exits 1 when something needs doing. Writes nothing.

.EXAMPLE
    .\darktide.ps1 diff
    How staging differs from the committed lockfile. Exits 0 when identical, 1 when
    not. Add -Left git:HEAD~1 -Right git:HEAD, or a loadout zip, to compare others.

.EXAMPLE
    .\darktide.ps1 errors -Last 2 -OutFile errors.md
    Reads the two newest console logs and names the mods most likely behind their
    errors. Read-only; the report goes to errors.md as well.

.EXAMPLE
    .\darktide.ps1 links -Open -Only markers_aio,scoreboard
    The same list, then those two mods' Nexus pages open in the browser.

.EXAMPLE
    .\darktide.ps1 settings -Apply
    Back up user_settings.config (your mod settings) before a big update. Skipped
    when nothing changed since the last backup.

.EXAMPLE
    .\darktide.ps1 changes
    After update -Apply: old and new version of each replaced mod and which files
    were added, removed or changed. Writes nothing. -BackupSet picks an older set.

.EXAMPLE
    .\darktide.ps1 disable -Only scoreboard -Apply
    Switch a mod off in staging without deleting it, then deploy to make it live.
    'enable -Only scoreboard -Apply' switches it back on.

.EXAMPLE
    .\darktide.ps1 pin -Only NumericUI -Reason 'crashes on 1.4' -Apply
    Hold NumericUI at its installed version. update reports it as PINNED and leaves
    it alone, -Force included, until: .\darktide.ps1 pin -Only NumericUI -Unpin -Apply

.EXAMPLE
    .\darktide.ps1 intake
    Run after downloading, before update -Apply: what each archive in the download
    folder is, and which lockfile mods are still missing. Exits 1 if an archive
    carries a different Nexus id from the mod it would replace.

.EXAMPLE
    .\darktide.ps1 profile -Action switch -Name minimal -Apply
    Make the saved profile 'minimal' the staging load order and deploy it.

.EXAMPLE
    .\darktide.ps1 lock -OutFile my-loadout.lock.json
    Write your lockfile to a file you can send a friend. The repository lockfile is
    left alone. Refuses to replace an existing file unless -Force is given.

.EXAMPLE
    .\darktide.ps1 need -Path .\their-loadout.lock.json -OutFile need.md
    Compare a friend's lockfile with your staging: what you are missing, with a
    Nexus link for each, and where it goes in their load order. Writes only need.md.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('init', 'status', 'check', 'links', 'update', 'deploy', 'sync', 'rollback', 'restore',
                 'lock', 'loader', 'export', 'import', 'help', 'upgrade', 'patchcheck', 'diff', 'errors', 'settings', 'changes', 'enable', 'disable', 'pin', 'intake', 'profile', 'need')]
    [string]   $Verb = 'help',

    [switch]   $Apply,
    [switch]   $CheckGitHub,
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
    [switch]   $Yes,
    [switch]   $PatchOnly,
    [switch]   $RestoreBackup,
    [switch]   $Remember,
    [string]   $Left,
    [string]   $Right,
    [string]   $LogDir,
    [ValidateRange(1, 1000)]
    [int]      $Last = 1,
    [switch]   $Open,
    [switch]   $Unpin,
    [string]   $Reason,
    [string]   $Action,
    [string]   $Name,
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
$Finder   = Join-Path $PSScriptRoot 'Find-ModUpdates.ps1'
$Upgrader = Join-Path $PSScriptRoot 'Invoke-DarktideUpgrade.ps1'
$BuildState = Join-Path $PSScriptRoot 'Get-DarktideBuildState.ps1'
$Differ   = Join-Path $PSScriptRoot 'Compare-DarktideLoadout.ps1'
$Blamer   = Join-Path $PSScriptRoot 'Get-DarktideErrors.ps1'
$SettingsBackup = Join-Path $PSScriptRoot 'Backup-DarktideSettings.ps1'
$Changer  = Join-Path $PSScriptRoot 'Show-ModChanges.ps1'
$Toggler  = Join-Path $PSScriptRoot 'Set-ModState.ps1'
$Pinner   = Join-Path $PSScriptRoot 'Set-ModPin.ps1'
$Intaker  = Join-Path $PSScriptRoot 'Test-DownloadedMods.ps1'
$Profiler = Join-Path $PSScriptRoot 'Switch-DarktideProfile.ps1'
$Gapper   = Join-Path $PSScriptRoot 'Get-LoadoutGap.ps1'

foreach ($s in @($Updater, $Deployer, $Locker, $Exporter, $Importer, $Initer, $Loaderer, $Finder, $Upgrader, $BuildState, $Differ, $Blamer, $SettingsBackup, $Changer, $Toggler, $Pinner, $Intaker, $Profiler, $Gapper)) {
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

# 'links' reads the lockfile and mods-map only. Neither lives in config.json, and
# someone with no API key is exactly the person least likely to have finished setup.
if ($Verb -eq 'links') {
    Write-Head 'Where to check for updates'
    # Reset first: the finder only sets an exit code when it fails, so a code left by
    # an earlier command would otherwise be passed on as this verb's result.
    $global:LASTEXITCODE = 0
    & $Finder -CheckGitHub:$CheckGitHub -Only $Only -Skip $Skip -OutFile $OutFile -Open:$Open
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
    return
}

# 'diff' compares lockfiles and writes nothing but an optional -OutFile. Only a
# 'current' side needs config.json (for ModsRoot), and the script reads it only
# then, so comparing two lockfiles, zips or git revisions works before 'init'.
# The exit code is the answer - 0 identical, 1 different - so pass it on.
if ($Verb -eq 'diff') {
    Write-Head 'Comparing loadouts'
    & $Differ -Left $Left -Right $Right -ConfigPath $ConfigPath -OutFile $OutFile -Force:$Force
    $code = if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    exit $code
}

# SyncIdsFromMap only touches the lockfile and mods-map.json - no config, no ModsRoot.
if ($Verb -eq 'lock' -and $SyncIdsFromMap) {
    Write-Head 'Syncing lockfile Nexus ids from mods-map'
    $syncArgs = @{ SyncIdsFromMap = $true }
    if ($OutFile) { $syncArgs['OutFile'] = $OutFile }
    & $Locker @syncArgs
    return
}

# 'errors' only reads the console logs. config.json is optional - the script reads it
# if it is there, for staging names and ConsoleLogDir - so it works on a machine that
# never ran init, or on logs someone sent you with -LogDir.
if ($Verb -eq 'errors') {
    Write-Head 'Reading the game console logs'
    & $Blamer -ConfigPath $ConfigPath -LogDir $LogDir -Last $Last -OutFile $OutFile -Force:$Force
    return
}

# 'settings' protects a file that lives in the Windows profile, not in staging or the
# game folder. config.json only supplies where backups go and an optional
# SettingsPath, so the verb works before setup is finished.
if ($Verb -eq 'settings') {
    $what = if ($BackupSet) { 'Restoring your mod settings' } else { 'Backing up your mod settings' }
    Write-Head "$what$(if (-not $Apply) { ' (dry run)' })"
    & $SettingsBackup -ConfigPath $ConfigPath -BackupSet $BackupSet -Apply:$Apply -Confirm:$false
    return
}

# 'pin' edits mods-map.json only. It reads config.json for MapPath and ModsRoot when
# there is one, and works on the map alone when there is not.
if ($Verb -eq 'pin') {
    $listing = -not $Only
    Write-Head "$(if ($listing) { 'Pinned mods' } elseif ($Unpin) { 'Unpinning mods' } else { 'Pinning mods' })$(if (-not $listing -and -not $Apply) { ' (dry run)' })"
    & $Pinner -ConfigPath $ConfigPath -Only $Only -Reason $Reason -Unpin:$Unpin -Apply:$Apply -Confirm:$false
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
        $mapFile = Get-Cfg 'MapPath' (Join-Path $PSScriptRoot 'mods-map.json')
        try {
            $entries = @(if (Test-Path -LiteralPath $mapFile) { (Get-Content -LiteralPath $mapFile -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties })
            $pins = @($entries | Where-Object { $_.Value -is [System.Management.Automation.PSCustomObject] -and
                                                $_.Value.PSObject.Properties.Name -contains 'pinned' -and $_.Value.pinned } |
                      ForEach-Object { $_.Name })
            Write-Host "  pinned (held)      : $($pins.Count)$(if ($pins) { ' - ' + ($pins -join ', ') })"
        } catch { Write-Warn "  pinned (held)      : unknown - $mapFile could not be read" }

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

        # $LASTEXITCODE is global and only a native command or an 'exit' sets it, so a
        # value left over from anything run earlier in this session would read as this
        # step failing. The updater runs no native commands; its 'exit 1' is the signal.
        # (Setting it here also keeps StrictMode happy in a fresh session.)
        $global:LASTEXITCODE = 0
        & $Updater -ConfigPath $ConfigPath -NoApi -Apply:$Apply -Force:$Force -Only $Only -Skip $Skip
        if ($LASTEXITCODE -ne 0) { throw 'Update step failed - not deploying.' }

        # Not $LASTEXITCODE for the deploy: robocopy leaves 1 ('files copied') in it after
        # a good deploy, the same value as the script's own 'exit 1' for a bad one. A
        # failed deploy either throws or reaches 'exit 1' without printing 'Deploy OK.',
        # so that line is the success signal. -InformationVariable collects the deploy's
        # Write-Host records and they still reach the console. A dry run returns before
        # the post-checks and refreshes nothing, so only -Apply needs the signal.
        $deployLog = $null
        & $Deployer -ConfigPath $ConfigPath -Apply:$Apply -Mirror:$Mirror `
                    -InstallLoader:$InstallLoader -RunToggle:$RunToggle -Force:$Force `
                    -InformationVariable deployLog

        if ($Apply) {
            $deployOk = @($deployLog | Where-Object { "$($_.MessageData)".Trim() -eq 'Deploy OK.' }).Count -gt 0
            if (-not $deployOk) { throw 'Deploy step finished with problems - lockfile not refreshed.' }

            # Hashed, not -NoHash: contentSha256 is what lets the lockfile show that an
            # installed mod has drifted, and -NoHash writes null over every one of them.
            Write-Head 'Refreshing lockfile'
            & $Locker -ModsRoot $modsRoot
        }
        # Do not hand robocopy's leftover 1 to whoever called this.
        $global:LASTEXITCODE = 0
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
        & $Deployer -ConfigPath $ConfigPath -Restore -Apply:$Apply -BackupSet $BackupSet -Force:$Force
        return
    }

    'lock' {
        $lockArgs = @{ ModsRoot = $modsRoot }
        if ($OutFile) {
            # A share file goes wherever the caller says, and the repository lockfile
            # is left as it is. New-ModpackLock.ps1 overwrites its -OutFile without
            # asking, so the -Force rule is applied here.
            if ((Test-Path -LiteralPath $OutFile) -and -not $Force) {
                throw "'$OutFile' already exists. Pass -Force to replace it."
            }
            $lockArgs['OutFile'] = $OutFile
            Write-Head "Writing the lockfile to $OutFile"
        } else {
            Write-Head 'Regenerating the lockfile'
        }
        & $Locker @lockArgs
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
        $what = if ($PatchOnly) { 'Re-patching the bundle database' }
                elseif ($RestoreBackup) { 'Restoring a mod loader backup' }
                else { 'Mod loader' }
        Write-Head "$what$(if (-not $Apply) { ' (dry run)' })"
        & $Loaderer -ConfigPath $ConfigPath -Source $Source -Apply:$Apply -Force:$Force `
                    -PatchOnly:$PatchOnly -RestoreBackup:$RestoreBackup -BackupSet $BackupSet -Confirm:$false
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

    'upgrade' {
        Write-Head 'Upgrade: plan, one question, then update + deploy + lockfile'
        if ($Apply) {
            Write-Warn 'upgrade asks before it writes, so -Apply changes nothing here. Pass -Yes to skip the question.'
        }
        & $Upgrader -ConfigPath $ConfigPath -Yes:$Yes -Confirm:$false
        # The script always ends with an explicit exit code; pass a failure on.
        $code = if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { 0 }
        if ($code -ne 0) { exit 1 }
        return
    }

    'patchcheck' {
        # Read-only apart from -Remember (a baseline beside staging) and -OutFile.
        Write-Head 'Game build vs the mod loader patch'
        & $BuildState -ConfigPath $ConfigPath -GamePath $GamePath -Remember:$Remember `
                      -OutFile $OutFile -Force:$Force
        # Passed on so a script can branch: 1 means something needs doing.
        $code = if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { 0 }
        if ($code) { exit $code }
        return
    }

    'changes' {
        # Read-only: compares a staging backup set with staging. -Force only lets
        # -OutFile overwrite an existing report.
        Write-Head 'What the last update changed in staging'
        & $Changer -ConfigPath $ConfigPath -BackupSet $BackupSet -Only $Only -Skip $Skip `
                   -OutFile $OutFile -Force:$Force
        return
    }

    'enable' {
        Write-Head "Enabling mods in the staging load order$(if (-not $Apply) { ' (dry run)' })"
        & $Toggler enable -ConfigPath $ConfigPath -Only $Only -Apply:$Apply -Confirm:$false
        return
    }

    'disable' {
        # With no -Only this only lists what is switched off, so it is not a dry run.
        if ($Only) {
            Write-Head "Disabling mods in the staging load order$(if (-not $Apply) { ' (dry run)' })"
        } else {
            Write-Head 'Mods switched off in the staging load order'
        }
        & $Toggler disable -ConfigPath $ConfigPath -Only $Only -Apply:$Apply -Confirm:$false
        return
    }

    'intake' {
        # Read-only, so no dry-run suffix and no -Apply. The exit code is the point:
        # 1 means an archive would replace a mod with a different Nexus mod.
        Write-Head 'Checking the download folder before update -Apply'
        & $Intaker -ConfigPath $ConfigPath -Only $Only -Skip $Skip -OutFile $OutFile -Force:$Force
        $code = if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { 0 }
        exit $code
    }

    'profile' {
        $act = if ($Action) { $Action } else { 'list' }
        $dry = (-not $Apply) -and ($act -eq 'switch' -or $act -eq 'delete')
        Write-Head "Mod profiles: $act$(if ($dry) { ' (dry run)' })"
        # The profile script always ends with an explicit exit code; pass it on, since a
        # switch whose deploy failed has already changed staging and must not look green.
        & $Profiler -ConfigPath $ConfigPath -Action $act -Name $Name -Apply:$Apply -Force:$Force -Confirm:$false
        $code = if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { 0 }
        if ($code) { exit $code }
        return
    }

    'need' {
        if (-not $Path) {
            throw "Which lockfile? Pass -Path, e.g. .\darktide.ps1 need -Path '.\their-loadout.lock.json'"
        }
        Write-Head 'Comparing their lockfile with your staging'
        # Reset first: the script only sets an exit code when something was dropped,
        # so a code left by an earlier command would otherwise be passed on as this
        # verb's result.
        $global:LASTEXITCODE = 0
        & $Gapper -Path $Path -ModsRoot $modsRoot -ConfigPath $ConfigPath -OutFile $OutFile -Force:$Force
        if ($LASTEXITCODE) { exit $LASTEXITCODE }
        return
    }
}
