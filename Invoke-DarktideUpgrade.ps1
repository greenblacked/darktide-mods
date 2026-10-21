<#
.SYNOPSIS
    The everyday loop in one command: plan, one question, then update, deploy and
    refresh the lockfile.

.DESCRIPTION
    Does what 'sync' then 'sync -Apply' do, but asks once instead of making you run
    the dry run and the real run separately.

      1. Preflight. config.json is read and its folders checked. If Darktide.exe is
         running you are told now, while you read the plan; applying is refused
         until it is closed.
      2. Plan. Update-DarktideMods.ps1 -NoApi and Deploy-DarktideMods.ps1 both run as
         dry runs, and their results are shown as one plan: which mods would be
         installed or updated in staging, and whether the game folder would change.
         If there is nothing to do it says so and stops with exit code 0, without
         asking anything.
      3. One question: 'Apply this plan? [y/N]'. Anything but y or yes is a no, and
         a no writes nothing. -Yes answers it for you.
      4. Apply. The update installs exactly the mods the plan named (archives that
         arrive while the question is open are left for next time). If it fails,
         the deploy does not run. The deploy keeps all of its own guards: the game
         folder check, the gamemods-*.zip backup, and the refusal while the game
         is running. The lockfile is then regenerated the same way 'sync -Apply'
         does it (New-ModpackLock.ps1 -NoHash).
      5. Summary: what changed, the staging backup set and the game backup zip this
         run created, and the exact commands that undo it.

    There is no -Apply here. The question is the gate, and answering no is the dry
    run. In a session that cannot answer (powershell -NonInteractive, or a
    scheduled task running with no one logged on) it refuses rather than waiting
    forever; pass -Yes there.

.PARAMETER ConfigPath
    config.json to read. Defaults to the one beside this script.

.PARAMETER Yes
    Apply the plan without asking. The plan is still printed first, and the game
    still has to be closed.

.PARAMETER LockFile
    Where to write the regenerated lockfile. Defaults to New-ModpackLock.ps1's own
    default, darktide-modpack.lock.json beside the scripts, which is what
    'sync -Apply' writes.

.EXAMPLE
    .\Invoke-DarktideUpgrade.ps1
    Show the plan and ask before writing anything.

.EXAMPLE
    .\Invoke-DarktideUpgrade.ps1 -Yes
    Show the plan and apply it without asking.

.EXAMPLE
    .\Invoke-DarktideUpgrade.ps1 -WhatIf
    Show the plan only. Nothing is asked and nothing is written.

.NOTES
    Exit codes: 0 when the plan was applied, declined, or there was nothing to do;
    1 when a step failed part way. A missing config, a failed dry run, a running
    game and a session that cannot be asked all stop before anything is written,
    with an error.

    The deploy step's own exit code cannot be trusted on its own: robocopy leaves
    1 ('files copied') in $LASTEXITCODE on success, which is indistinguishable from
    the script's 'exit 1'. Success is read from the 'Deploy OK.' line instead.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [switch] $Yes,
    [string] $LockFile,

    # Test hook: returns the answer to 'Apply this plan?' instead of Read-Host.
    [Parameter(DontShow = $true)]
    [scriptblock] $ConfirmWith
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$m) Write-Host $m -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host $m -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host $m -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host $m -ForegroundColor Red }

$Updater  = Join-Path $PSScriptRoot 'Update-DarktideMods.ps1'
$Deployer = Join-Path $PSScriptRoot 'Deploy-DarktideMods.ps1'
$Locker   = Join-Path $PSScriptRoot 'New-ModpackLock.ps1'
foreach ($s in @($Updater, $Deployer, $Locker)) {
    if (-not (Test-Path -LiteralPath $s)) { throw "Missing script: $s" }
}

# Update statuses that an -Apply run installs without -Force.
$script:InstallStatuses = @('NEWER', 'NEW', 'UNKNOWN-LOCAL')

# ----------------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------------

function Invoke-Child {
    <#
        Runs one of the other scripts and keeps every line it prints, so the plan can
        be read back out of it. With -Show the lines are also echoed as they arrive,
        in their original colours; without it they go to the verbose stream, which
        -Verbose turns on.

        Only the information stream (6, where Write-Host goes) is captured. Merging
        the error stream too could redirect the stderr of robocopy inside Deploy,
        and Windows PowerShell 5.1 can turn a redirected native stderr line into a
        terminating error under 'Stop' (see the validate-change notes on 2>&1).
        Errors and warnings therefore reach the console directly, and a
        terminating one is caught below.
    #>
    param(
        [Parameter(Mandatory)] [scriptblock] $Command,
        [switch] $Show
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $failure = $null
    Set-Variable -Name LASTEXITCODE -Value 0 -Scope Global -WhatIf:$false

    try {
        & $Command 6>&1 | ForEach-Object {
            $item = $_
            # Take the text from the record explicitly rather than trusting ToString.
            $msg  = $null
            if ($item -is [System.Management.Automation.InformationRecord]) {
                if ($item.MessageData -is [System.Management.Automation.HostInformationMessage]) {
                    $msg  = $item.MessageData
                    $text = "$($msg.Message)"
                } else {
                    $text = "$($item.MessageData)"
                }
            } else {
                $text = "$item"
            }
            $text = $text.TrimEnd()
            $lines.Add($text)
            if (-not $Show) { Write-Verbose $text; return }

            if ($msg) {
                $fg  = $msg.ForegroundColor
                if ($null -ne $fg -and [int]$fg -ge 0 -and [int]$fg -le 15) {
                    Write-Host $msg.Message -ForegroundColor $fg -NoNewline:([bool]$msg.NoNewLine)
                } else {
                    Write-Host $msg.Message -NoNewline:([bool]$msg.NoNewLine)
                }
            } else {
                Write-Host $text
            }
        }
    } catch {
        $failure = $_
    }

    $code = if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    return [pscustomobject]@{
        Lines    = $lines.ToArray()
        ExitCode = $code
        Failure  = $failure
    }
}

function Show-ChildOutput {
    <# Prints what a hidden dry run said, for when it failed and the reason is in there. #>
    param([string] $Title, [object] $Result)
    Write-Host ''
    Write-Warn "---- output of $Title ----"
    foreach ($l in $Result.Lines) { Write-Host "  $l" }
    if ($Result.Failure) { Write-Err "  $($Result.Failure.Exception.Message)" }
    Write-Warn "---- end of $Title ----"
}

function Get-RunningGame {
    # Not a third Assert-GameNotRunning: the validator keeps that to the two copies in
    # Deploy and Update. This only asks; the callers decide whether to warn or refuse.
    return @(Get-Process -Name 'Darktide' -ErrorAction SilentlyContinue)
}

function Test-InteractiveSession {
    <#
        Whether Read-Host can get an answer. A session started with -NonInteractive
        makes Read-Host throw, and a service has no one at the keyboard; both are
        refused up front with a message that says what to do instead.
    #>
    if (-not [Environment]::UserInteractive) { return $false }
    if ($Host.Name -eq 'Default Host') { return $false }

    $cmdArgs = @([Environment]::GetCommandLineArgs())
    for ($i = 1; $i -lt $cmdArgs.Count; $i++) {
        $a = "$($cmdArgs[$i])"
        # Everything after -File / -Command belongs to the script, not the host.
        if ($a -match '^[-/](f|file|c|command|e|ec|encodedcommand)$') { break }
        if ($a -match '^[-/]non') { return $false }
    }
    return $true
}

function Get-BackupSnapshot {
    <# Names of the staging backup sets and game backup zips that exist right now. #>
    param([string] $BackupRoot, [string] $DeployBackupRoot)

    $sets = @()
    if (Test-Path -LiteralPath $BackupRoot -PathType Container) {
        $sets = @(Get-ChildItem -LiteralPath $BackupRoot -Directory | ForEach-Object { $_.Name })
    }
    $zips = @()
    if (Test-Path -LiteralPath $DeployBackupRoot -PathType Container) {
        $zips = @(Get-ChildItem -LiteralPath $DeployBackupRoot -File |
                  Where-Object { $_.Name -like 'gamemods-*.zip' } | ForEach-Object { $_.Name })
    }
    return [pscustomobject]@{ Sets = $sets; Zips = $zips }
}

function Get-NewName {
    <# The names in -After that were not in -Before, newest name first. #>
    param([string[]] $Before, [string[]] $After)
    return @($After | Where-Object { $Before -notcontains $_ } | Sort-Object -Descending)
}

function Show-Undo {
    param([string] $StagingSet, [string] $GameZip, [string[]] $NewMods, [switch] $LockRefreshed)

    Write-Host ''
    Write-Step 'Undo'
    if ($GameZip) {
        Write-Host "  .\darktide.ps1 restore -BackupSet '$GameZip' -Apply"
        Write-Host '      puts the game mods folder back as it was before this run'
    }
    if ($StagingSet) {
        Write-Host "  .\darktide.ps1 rollback -BackupSet '$StagingSet' -Apply"
        Write-Host '      puts the replaced mods back in staging'
    }
    if ($NewMods) {
        Write-Host "  new mods have no earlier version to roll back to: $($NewMods -join ', ')"
        Write-Host '      to drop one, delete its staging folder and its line in mod_load_order.txt'
    }
    if ($LockRefreshed -and ($GameZip -or $StagingSet)) {
        Write-Host '  .\darktide.ps1 lock'
        Write-Host '      then regenerate the lockfile so it matches staging again'
    }
    if (-not $GameZip -and -not $StagingSet -and -not $NewMods) {
        Write-Host '  nothing to undo from a backup: this run replaced nothing'
    }
}

# ----------------------------------------------------------------------------------
# 1. Preflight
# ----------------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "No config at '$ConfigPath'. Run .\darktide.ps1 init first."
}
$raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
if (-not "$raw".Trim()) { throw "Config '$ConfigPath' is empty. Run .\darktide.ps1 init." }
try {
    $cfgJson = $raw | ConvertFrom-Json
} catch {
    throw "Config '$ConfigPath' is not valid JSON: $($_.Exception.Message)"
}

function Get-Cfg {
    param([string] $Key)
    if ($cfgJson.PSObject.Properties.Name -contains $Key -and "$($cfgJson.$Key)".Trim()) { return "$($cfgJson.$Key)" }
    return ''
}

$modsRoot = Get-Cfg 'ModsRoot'
$gamePath = Get-Cfg 'GamePath'
if (-not $modsRoot) { throw "ModsRoot is not set in '$ConfigPath'." }
if (-not $gamePath) { throw "GamePath is not set in '$ConfigPath'." }
if (-not (Test-Path -LiteralPath $modsRoot -PathType Container)) {
    throw "Staging folder '$modsRoot' (ModsRoot) does not exist."
}
if (-not (Test-Path -LiteralPath $gamePath -PathType Container)) {
    throw "Game folder '$gamePath' (GamePath) does not exist."
}

# The same defaults the updater and the deployer fall back to, so the before/after
# comparison looks where they actually write.
$stagingFull  = (Resolve-Path -LiteralPath $modsRoot).Path.TrimEnd('\', '/')
$stagingParent = Split-Path -Parent $stagingFull
$backupRoot   = Get-Cfg 'BackupRoot'
if (-not $backupRoot) { $backupRoot = Join-Path $stagingParent 'mod_backups' }
$deployBackup = Get-Cfg 'DeployBackupRoot'
if (-not $deployBackup) { $deployBackup = Join-Path $stagingParent 'deploy_backups' }
$gameMods     = Join-Path $gamePath 'mods'

Write-Step '=== Darktide upgrade ==='
Write-Host  "Staging : $modsRoot"
Write-Host  "Game    : $gamePath"
Write-Host  "Mode    : $(if ($WhatIfPreference) { 'WHAT IF (plan only, nothing is asked or written)' } elseif ($Yes) { 'APPLY without asking (-Yes)' } else { 'ASK (nothing is written unless you answer y)' })"
Write-Host  ''

$running = Get-RunningGame
if ($running) {
    Write-Warn "Darktide.exe is running (PID $(@($running | ForEach-Object { $_.Id }) -join ', '))."
    Write-Warn 'Read the plan, but applying it is refused until the game is closed.'
    Write-Host ''
}

# ----------------------------------------------------------------------------------
# 2. Plan
# ----------------------------------------------------------------------------------

Write-Step 'Working out the plan (dry runs of update and deploy)...'

$planStart = Get-Date
$updPlan = Invoke-Child -Command {
    & $Updater -ConfigPath $ConfigPath -NoApi -WhatIf:$false -Confirm:$false
}
if ($updPlan.Failure -or $updPlan.ExitCode -ne 0) {
    Show-ChildOutput -Title 'the update dry run' -Result $updPlan
    throw 'The update dry run did not finish, so there is no plan. Nothing was written.'
}

# The updater writes its plan to a CSV and logs the path; read the plan from there
# rather than from the printed table.
$reportPath = $null
foreach ($l in $updPlan.Lines) {
    $m = [regex]::Match($l, 'Report: (?<p>.+\.csv)\s*$')
    if ($m.Success) { $reportPath = $m.Groups['p'].Value }
}
if (-not $reportPath -or -not (Test-Path -LiteralPath $reportPath)) {
    # Fallback if the log line ever changes shape: the report this run just wrote.
    $recent = @(Get-ChildItem -LiteralPath (Split-Path -Parent $Updater) -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'report-offline-*.csv' -and $_.LastWriteTime -ge $planStart.AddSeconds(-2) } |
                Sort-Object LastWriteTime -Descending)
    $reportPath = if ($recent) { $recent[0].FullName } else { $null }
}

# An empty download folder is a valid plan with no rows, and may leave no report.
$noArchives = @($updPlan.Lines | Where-Object { $_ -match 'Nothing to do\.' }).Count -gt 0
$rows = @()
if ($reportPath -and (Test-Path -LiteralPath $reportPath)) {
    $rows = @(Import-Csv -LiteralPath $reportPath -Encoding UTF8)
} elseif (-not $noArchives) {
    Show-ChildOutput -Title 'the update dry run' -Result $updPlan
    throw 'Could not find the report the update dry run writes, so there is no plan. Nothing was written.'
}

$installs = @($rows | Where-Object { $script:InstallStatuses -contains $_.Status })
$held     = @($rows | Where-Object { $_.Status -in @('OLDER', 'VERSION-UNKNOWN') })

$depPlan = Invoke-Child -Command {
    & $Deployer -ConfigPath $ConfigPath -WhatIf:$false -Confirm:$false
}
if ($depPlan.Failure) {
    Show-ChildOutput -Title 'the deploy dry run' -Result $depPlan
    throw 'The deploy dry run did not finish, so there is no plan. Nothing was written.'
}

# Deploy's dry run ends with one of two lines; anything else is treated as 'would
# change', which only costs a deploy that finds nothing to copy.
$deployInSync  = [bool]($depPlan.Lines -match 'Dry run complete\. Already in sync')
$deployPending = -not $deployInSync
$newInGame = ''
foreach ($l in $depPlan.Lines) {
    $m = [regex]::Match($l, '^\s*new in game\s*:\s*(?<n>.+)$')
    if ($m.Success) { $newInGame = $m.Groups['n'].Value.Trim() }
}

$gameWillChange = ($installs.Count -gt 0) -or $deployPending

Write-Host ''
Write-Step 'Plan'
Write-Host "  Staging ($modsRoot)"
if ($installs) {
    foreach ($r in ($installs | Sort-Object Mod)) {
        switch ($r.Status) {
            'NEWER'         { Write-Host ("    update  {0}  {1} -> {2}" -f $r.Mod, $r.Local, $r.Latest) -ForegroundColor Green }
            'NEW'           { Write-Host ("    new     {0}  {1}" -f $r.Mod, $r.Latest) -ForegroundColor Green }
            'UNKNOWN-LOCAL' { Write-Host ("    replace {0}  (no version recorded) -> {1}" -f $r.Mod, $r.Latest) -ForegroundColor Green }
        }
    }
} else {
    Write-Host '    nothing to install: no archive in the download folder is newer than staging'
}
foreach ($r in $held) {
    Write-Warn ("    left alone  {0}: {1}" -f $r.Mod, $r.Action)
}

Write-Host "  Game folder ($gameMods)"
if ($deployPending) {
    Write-Host '    will be synced from staging (the current mods folder is zipped first)'
    if ($newInGame) { Write-Host "    new in game: $newInGame" }
} elseif ($installs) {
    Write-Host '    matches staging now; will be synced once the staging changes above are made'
} else {
    Write-Ok '    already matches staging'
}

Write-Host '  Lockfile'
if ($gameWillChange) {
    Write-Host '    regenerated from staging once the deploy succeeds'
} else {
    Write-Host '    unchanged'
}
Write-Host ''

if (-not $gameWillChange) {
    Write-Ok 'Nothing to do: staging is current and the game folder matches it.'
    exit 0
}

if ($WhatIfPreference) {
    Write-Warn 'What if: the plan above was not applied. Nothing was asked and nothing was written.'
    exit 0
}

# ----------------------------------------------------------------------------------
# 3. One question
# ----------------------------------------------------------------------------------

if (-not $Yes) {
    $answer = $null
    if ($ConfirmWith) {
        $answer = & $ConfirmWith
    } else {
        $refusal = 'This session cannot answer ''Apply this plan?'' (it is non-interactive). ' +
                   'Nothing was written. Run it in a PowerShell window, or pass -Yes to apply without asking.'
        if (-not (Test-InteractiveSession)) { throw $refusal }
        try {
            $answer = Read-Host 'Apply this plan? [y/N]'
        } catch {
            throw $refusal
        }
    }

    if ("$answer".Trim() -notmatch '^(?i:y|yes)$') {
        Write-Host ''
        Write-Ok 'Not applied. Nothing was written.'
        exit 0
    }
}

# ----------------------------------------------------------------------------------
# 4. Apply
# ----------------------------------------------------------------------------------

# The game may have been started while the question was open.
$running = Get-RunningGame
if ($running) {
    throw "Darktide.exe is running (PID $(@($running | ForEach-Object { $_.Id }) -join ', ')). Close the game and run upgrade again. Nothing was written."
}

if (-not $PSCmdlet.ShouldProcess("$modsRoot and $gameMods", 'Apply the upgrade plan')) {
    Write-Ok 'Not applied. Nothing was written.'
    exit 0
}

$before = Get-BackupSnapshot -BackupRoot $backupRoot -DeployBackupRoot $deployBackup
$plannedMods = @($installs | ForEach-Object { $_.Mod })
$newMods     = @($installs | Where-Object { $_.Status -eq 'NEW' } | ForEach-Object { $_.Mod })
$problems = New-Object System.Collections.Generic.List[string]

function Get-ThisRunBackups {
    $after = Get-BackupSnapshot -BackupRoot $backupRoot -DeployBackupRoot $deployBackup
    $set = @(Get-NewName -Before $before.Sets -After $after.Sets)
    $zip = @(Get-NewName -Before $before.Zips -After $after.Zips)
    return [pscustomobject]@{
        Set = $(if ($set) { $set[0] } else { '' })
        Zip = $(if ($zip) { $zip[0] } else { '' })
    }
}

# ---- update ----

if ($plannedMods) {
    Write-Host ''
    Write-Step "== Installing into staging: $($plannedMods -join ', ')"
    # -Only pins the install to what was approved; an archive that landed while the
    # question was open waits for the next run.
    $upd = Invoke-Child -Show -Command {
        & $Updater -ConfigPath $ConfigPath -NoApi -Apply -Only $plannedMods -Confirm:$false
    }
    if ($upd.Failure -or $upd.ExitCode -ne 0) {
        if ($upd.Failure) { Write-Err $upd.Failure.Exception.Message }
        $bk = Get-ThisRunBackups
        Write-Host ''
        Write-Err 'Update step failed - not deploying. The game folder was not touched and the lockfile was not refreshed.'
        Write-Err 'Mods that did install stay in staging; fix or remove the archive that failed, then run upgrade again.'
        if ($bk.Set) { Write-Host "  staging backup set : $($bk.Set)  (in $backupRoot)" }
        Show-Undo -StagingSet $bk.Set -GameZip '' -NewMods $newMods
        exit 1
    }
}

# ---- deploy ----

Write-Host ''
Write-Step '== Deploying staging to the game folder'
$dep = Invoke-Child -Show -Command {
    & $Deployer -ConfigPath $ConfigPath -Apply -Confirm:$false
}
# Not $LASTEXITCODE: see .NOTES. 'Deploy OK.' is only printed on the success path.
$deployOk = (-not $dep.Failure) -and [bool]($dep.Lines -contains 'Deploy OK.')
if (-not $deployOk) {
    if ($dep.Failure) { Write-Err $dep.Failure.Exception.Message }
    $bk = Get-ThisRunBackups
    Write-Host ''
    Write-Err 'Deploy step did not finish cleanly - lockfile not refreshed. See the deploy output above.'
    if ($bk.Set) { Write-Host "  staging backup set : $($bk.Set)  (in $backupRoot)" }
    if ($bk.Zip) { Write-Host "  game backup        : $($bk.Zip)  (in $deployBackup)" }
    Show-Undo -StagingSet $bk.Set -GameZip $bk.Zip -NewMods $newMods
    exit 1
}

# ---- lockfile ----

Write-Host ''
Write-Step '== Refreshing the lockfile'
# The same call 'sync -Apply' makes in darktide.ps1.
$lockArgs = @{ ModsRoot = $modsRoot; NoHash = $true }
if ($LockFile) { $lockArgs['OutFile'] = $LockFile }
$lock = Invoke-Child -Show -Command { & $Locker @lockArgs }
if ($lock.Failure -or $lock.ExitCode -ne 0) {
    if ($lock.Failure) { Write-Err $lock.Failure.Exception.Message }
    $problems.Add('the lockfile was not refreshed - run .\darktide.ps1 lock')
}

# ----------------------------------------------------------------------------------
# 5. Summary
# ----------------------------------------------------------------------------------

$bk = Get-ThisRunBackups

Write-Host ''
Write-Step '== Upgrade summary'
if ($installs) {
    $what = @($installs | Sort-Object Mod | ForEach-Object { "$($_.Mod) $($_.Latest)" }) -join ', '
    Write-Host "  staging            : $($installs.Count) mod(s) installed or updated ($what)"
} else {
    Write-Host '  staging            : unchanged'
}
Write-Host  "  game folder        : synced from staging"
Write-Host  "  lockfile           : $(if ($problems.Count) { 'NOT refreshed' } else { 'refreshed' })"
Write-Host  "  staging backup set : $(if ($bk.Set) { "$($bk.Set)  (in $backupRoot)" } else { 'none (nothing in staging was replaced)' })"
Write-Host  "  game backup        : $(if ($bk.Zip) { "$($bk.Zip)  (in $deployBackup)" } else { 'none (first deploy, or nothing to back up)' })"

Show-Undo -StagingSet $bk.Set -GameZip $bk.Zip -NewMods $newMods -LockRefreshed:($problems.Count -eq 0)

Write-Host ''
if ($problems.Count) {
    foreach ($p in $problems) { Write-Err "Problem: $p" }
    exit 1
}
Write-Ok 'Done. Start the game.'
exit 0
