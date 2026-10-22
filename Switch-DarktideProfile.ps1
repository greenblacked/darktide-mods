<#
.SYNOPSIS
    Saves, lists and switches named mod profiles (variants of the staging load order).

.DESCRIPTION
    A profile is a saved copy of the staging mod_load_order.txt under a name, such as
    'full', 'minimal' or 'solo'. Every mod stays installed in staging; the Darktide Mod
    Framework only loads what the load order lists, so switching profiles is a matter
    of swapping that one file and deploying.

        save    snapshot the current staging load order as a profile
        list    every profile, its mod count, and which one matches staging right now
        show    a profile's contents, and any mod it names that is not in staging
        switch  make a profile the staging load order, then deploy it to the game
        delete  remove a profile

    Profiles live in '<parent of ModsRoot>\profiles\<name>.txt' (or ProfilesRoot in
    config.json). They are kept out of the staging folder on purpose: every folder in
    staging is treated as a mod by deploy and export.

    'switch' prints its plan and writes nothing without -Apply. Under -Apply it first
    copies the current staging load order to '<profiles>\backups\', then writes the
    profile as the new load order, then runs Deploy-DarktideMods.ps1 -Apply. The game
    folder is only ever written by the deployer, which owns the game-folder checks and
    the gamemods-*.zip backup. A profile that names a mod missing from staging is
    refused, unless that line is commented out with '--'.

    'delete' needs -Apply. 'save' writes a new file in the profiles folder straight
    away and refuses to replace an existing profile without -Force. 'list' and 'show'
    never write anything.

.PARAMETER Action
    save, list, show, switch or delete. Default: list.

.PARAMETER Name
    The profile to act on: letters, digits, '.', '_' and '-', at most 40 characters.
    For 'switch' and 'show' it may also name a load-order backup
    (mod_load_order-<stamp>) from '<profiles>\backups\', which is how a switch is
    undone.

.PARAMETER ConfigPath
    config.json to read ModsRoot, GamePath, DeployBackupRoot and ProfilesRoot from.

.PARAMETER StagingMods
    Override ModsRoot from the config.

.PARAMETER ProfilesRoot
    Override where profiles are kept. Must not be inside the staging folder.

.PARAMETER Apply
    Actually switch or delete. Without it you get the plan and nothing is written.

.PARAMETER Force
    With 'save': replace a profile that already exists.

.PARAMETER KeepBackups
    How many load-order backups to keep under '<profiles>\backups'. Also passed to the
    deploy that 'switch -Apply' runs, which bounds its gamemods-*.zip the same way.
    Default 10; 0 keeps everything.

.EXAMPLE
    .\Switch-DarktideProfile.ps1 -Action save -Name full
    Saves the current staging load order as the profile 'full'.

.EXAMPLE
    .\Switch-DarktideProfile.ps1 -Action list
    Lists every profile and marks the one staging currently matches.

.EXAMPLE
    .\Switch-DarktideProfile.ps1 -Action switch -Name minimal
    Shows which mods would be enabled and disabled. Nothing is written.

.EXAMPLE
    .\Switch-DarktideProfile.ps1 -Action switch -Name minimal -Apply
    Backs up the staging load order, writes 'minimal' over it, and deploys.

.EXAMPLE
    .\Switch-DarktideProfile.ps1 -Action delete -Name solo -Apply
    Deletes the profile 'solo'. Staging and the game folder are not touched.

.NOTES
    Exit codes: 0 when the action completed, 1 when a switch changed staging but the
    deploy did not finish. Bad input (an invalid name, a missing profile, a mod that is
    not in staging, the game running) throws before anything is written.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('save', 'list', 'show', 'switch', 'delete')]
    [string] $Action = 'list',

    [string] $Name,

    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string] $StagingMods,
    [string] $ProfilesRoot,

    [switch] $Apply,
    [switch] $Force,

    [ValidateRange(0, 1000)]
    [int] $KeepBackups = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$m) Write-Host $m -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host $m -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host $m -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host $m -ForegroundColor Red }

# ----------------------------------------------------------------------------------
# Config
# ----------------------------------------------------------------------------------

$cfg = @{
    ModsRoot         = ''
    GamePath         = ''
    DeployBackupRoot = ''
    BackupRoot       = ''
    ProfilesRoot     = ''
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
if ($ProfilesRoot) { $cfg.ProfilesRoot = $ProfilesRoot }

if (-not $cfg.ModsRoot) { throw 'Staging mods folder not set. Put ModsRoot in config.json or pass -StagingMods.' }

function Get-FullPath {
    <# Absolute form of a path, resolved against the PowerShell location, existing or not. #>
    param([Parameter(Mandatory)][string] $Path)
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    return $full.TrimEnd('\', '/')
}

if (-not (Test-Path -LiteralPath $cfg.ModsRoot -PathType Container)) {
    throw "Staging mods folder '$($cfg.ModsRoot)' does not exist. Check ModsRoot in config.json."
}
$staging = Get-FullPath -Path $cfg.ModsRoot

$profilesDir = if ($cfg.ProfilesRoot) {
    Get-FullPath -Path $cfg.ProfilesRoot
} else {
    Join-Path (Split-Path -Parent $staging) 'profiles'
}

# Deploy and export treat every folder in staging as a mod, so a profiles folder in
# there would be copied into the game and archived as one.
$sep = [System.IO.Path]::DirectorySeparatorChar
if ($profilesDir.Equals($staging, [StringComparison]::OrdinalIgnoreCase) -or
    $profilesDir.StartsWith($staging + $sep, [StringComparison]::OrdinalIgnoreCase) -or
    $profilesDir.StartsWith($staging + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "ProfilesRoot '$profilesDir' is inside the staging folder '$staging'. Deploy would copy it into the game as a mod. Point ProfilesRoot somewhere outside staging."
}

# The updater's rollback takes the newest folder in BackupRoot as a staging backup set,
# so the load-order backups below must never become a folder in there.
$stagingBackupRoot = if ($cfg.BackupRoot) { Get-FullPath -Path $cfg.BackupRoot } else {
    Join-Path (Split-Path -Parent $staging) 'mod_backups'
}
if ($profilesDir.Equals($stagingBackupRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "ProfilesRoot '$profilesDir' is the staging BackupRoot. Rollback would mistake the profile backups for a backup set. Point ProfilesRoot somewhere else."
}

$backupDir     = Join-Path $profilesDir 'backups'
$loadOrderPath = Join-Path $staging 'mod_load_order.txt'

# ----------------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------------

function Get-ProfileNameProblem {
    <# Why a profile name is unusable, or $null. The name becomes a file name. #>
    param([string] $Value)

    if (-not $Value) { return 'no name given' }
    if ($Value -cnotmatch '^[A-Za-z0-9._-]{1,40}$') {
        return "'$Value' is not a valid profile name. Use letters, digits, '.', '_' and '-', at most 40 characters."
    }
    if ($Value.Contains('..')) { return "'$Value' is not a valid profile name: '..' is not allowed." }
    if ($Value.StartsWith('.')) { return "'$Value' is not a valid profile name: it may not start with '.'." }
    # Windows device names cannot be used as file names, with or without an extension.
    if ($Value.Split('.')[0] -match '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])$') {
        return "'$Value' is a reserved Windows device name and cannot be a profile name."
    }
    return $null
}

function Assert-ProfileName {
    param([string] $Value)
    $problem = Get-ProfileNameProblem -Value $Value
    if ($problem -eq 'no name given') {
        throw "Which profile? Pass -Name, e.g. -Action $Action -Name full"
    }
    if ($problem) { throw $problem }
}

function Get-LoadOrderEntry {
    <# The mods a load-order file enables: trimmed, non-empty, not commented with '--'. #>
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    return @(Get-Content -LiteralPath $Path -Encoding UTF8 |
             ForEach-Object { "$_".Trim() } |
             Where-Object { $_ -and -not $_.StartsWith('--') })
}

function Test-SameEntry {
    <# Same mods in the same order. Load order matters to DMF, so order counts. #>
    param([string[]] $Left, [string[]] $Right)

    $l = @($Left); $r = @($Right)
    if ($l.Count -ne $r.Count) { return $false }
    for ($i = 0; $i -lt $l.Count; $i++) {
        if (-not [string]::Equals($l[$i], $r[$i], [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

function Get-MissingMod {
    <#
        Load-order entries that do not name a folder in staging. An entry that is not a
        plain folder name (a path, a wildcard) can never resolve, so it counts too.
    #>
    param([string[]] $Entries)

    $missing = @()
    foreach ($e in @($Entries)) {
        $unsafe = $e -in @('.', '..') -or $e -match '[\\/:*?"<>|]'
        if ($unsafe -or -not (Test-Path -LiteralPath (Join-Path $staging $e) -PathType Container)) {
            $missing += $e
        }
    }
    return @($missing)
}

function Get-SavedProfile {
    <# Every valid profile in the profiles folder, sorted by name. #>
    if (-not (Test-Path -LiteralPath $profilesDir -PathType Container)) { return @() }

    $found = @()
    $files = @(Get-ChildItem -LiteralPath $profilesDir -File |
               Where-Object { $_.Extension -eq '.txt' } | Sort-Object Name)
    foreach ($f in $files) {
        $n = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        if (Get-ProfileNameProblem -Value $n) {
            Write-Verbose "Ignoring '$($f.Name)': not a valid profile name."
            continue
        }
        $found += [pscustomobject]@{
            Name    = $n
            Path    = $f.FullName
            Entries = @(Get-LoadOrderEntry -Path $f.FullName)
        }
    }
    return @($found)
}

function Resolve-ProfileFile {
    <#
        The file a name refers to. A saved profile wins; with -AllowBackup a load-order
        backup name (mod_load_order-<stamp>) also resolves, so a switch can be undone
        with the same verb that made it.
    #>
    param([Parameter(Mandatory)][string] $ProfileName, [switch] $AllowBackup)

    $p = Join-Path $profilesDir "$ProfileName.txt"
    if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }

    if ($AllowBackup -and $ProfileName -match '^mod_load_order-\d{8}-\d{6}(-\d+)?$') {
        $b = Join-Path $backupDir "$ProfileName.txt"
        if (Test-Path -LiteralPath $b -PathType Leaf) { return $b }
    }

    $names = @(Get-SavedProfile | ForEach-Object { $_.Name })
    $known = if ($names) { "Saved profiles: $($names -join ', ')." } else { 'There are no saved profiles yet.' }
    throw "No profile named '$ProfileName' in '$profilesDir'. $known"
}

function Get-FileText {
    <# Byte-exact content as a comparable string; '' for a missing file. #>
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    return [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Path))
}

function Remove-OldLoadOrderBackup {
    <# Keeps '<profiles>\backups' bounded, the same way deploy bounds its zips. #>
    param([int] $Keep)

    if ($Keep -le 0) { return }
    if (-not (Test-Path -LiteralPath $backupDir -PathType Container)) { return }

    $stale = @(Get-ChildItem -LiteralPath $backupDir -File |
               Where-Object { $_.Name -like 'mod_load_order-*.txt' } |
               Sort-Object @{ Expression = { $_.LastWriteTimeUtc }; Descending = $true },
                           @{ Expression = { $_.Name };             Descending = $true } |
               Select-Object -Skip $Keep)
    foreach ($old in $stale) {
        Remove-Item -LiteralPath $old.FullName -Force
        Write-Host "  pruned old load-order backup: $($old.Name)"
    }
}

function Get-GameFolderProblem {
    <#
        Pre-flight only: say why a switch could not reach the game, before staging is
        touched. The deployer still runs its own full validation and is the only thing
        that writes the game folder. Every refusal in Assert-ValidGamePath in
        Deploy-DarktideMods.ps1 is repeated here (existence, drive root, too few path
        segments, markers); one that is missing lets a switch rewrite staging and then
        stop at the deploy. Keep the two in step.

        Deploy splits on '\' only. This splits on '\' or '/', which is the same on
        Windows (a resolved path there never contains '/') and keeps the check
        meaningful where the separator is '/'.
    #>
    param([string] $Path)

    if (-not $Path) { return 'Game folder not set. Put GamePath in config.json.' }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return "Game folder '$Path' does not exist. Check GamePath in config.json."
    }
    $full = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\', '/')

    if ($full -match '^[A-Za-z]:$') {
        return "GamePath '$full' is a drive root. Refusing."
    }
    if (@($full -split '[\\/]').Count -lt 3) {
        return "GamePath '$full' is suspiciously shallow. Point it at the Darktide install folder."
    }

    $markers = @('binaries\Darktide.exe', 'binaries_dx12\Darktide.exe',
                 'bundle\bundle_database.data', 'launcher\Launcher.exe')
    $hit = @($markers | Where-Object { Test-Path -LiteralPath (Join-Path $full $_) })
    if (-not $hit) { return "'$full' does not look like a Darktide install. Fix GamePath in config.json." }
    return $null
}

function Get-DeployZipName {
    param([string] $Root)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $Root -File |
             Where-Object { $_.Name -like 'gamemods-*.zip' } | ForEach-Object { $_.Name })
}

function Get-InfoText {
    <# The text of Write-Host records captured with -InformationVariable. #>
    param($Records)
    return @(@($Records) | Where-Object { $null -ne $_ } | ForEach-Object {
        if ($_.MessageData -is [System.Management.Automation.HostInformationMessage]) {
            "$($_.MessageData.Message)"
        } else { "$($_.MessageData)" }
    })
}

# ----------------------------------------------------------------------------------
# Actions
# ----------------------------------------------------------------------------------

function Invoke-Save {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string] $ProfileName, [switch] $Overwrite)
    Assert-ProfileName -Value $ProfileName

    if (-not (Test-Path -LiteralPath $loadOrderPath -PathType Leaf)) {
        throw "No load order to save: '$loadOrderPath' does not exist."
    }
    $target  = Join-Path $profilesDir "$ProfileName.txt"
    $entries = @(Get-LoadOrderEntry -Path $loadOrderPath)

    Write-Step "=== Save profile '$ProfileName' ==="
    Write-Host "From : $loadOrderPath"
    Write-Host "To   : $target"
    Write-Host "Mods : $($entries.Count)"
    Write-Host ''

    if ((Test-Path -LiteralPath $target) -and -not $Overwrite) {
        throw "Profile '$ProfileName' already exists at '$target'. Pass -Force to replace it."
    }

    $missing = @(Get-MissingMod -Entries $entries)
    if ($missing) {
        Write-Warn "  the current load order names mods that are not in staging: $($missing -join ', ')"
        Write-Warn '  switching to this profile will be refused until they are installed or commented out with --'
    }

    if ($PSCmdlet.ShouldProcess($target, 'Save the staging load order as a profile')) {
        [void][System.IO.Directory]::CreateDirectory($profilesDir)
        # Copy the bytes, not the lines, so comments, order and encoding survive as-is.
        [System.IO.File]::WriteAllBytes($target, [System.IO.File]::ReadAllBytes($loadOrderPath))
        Write-Ok "Saved profile '$ProfileName' ($($entries.Count) mods)."
    }
    return 0
}

function Invoke-List {
    param()
    $current  = @(Get-LoadOrderEntry -Path $loadOrderPath)
    $profiles = @(Get-SavedProfile)

    Write-Step '=== Mod profiles ==='
    Write-Host "Profiles : $profilesDir"
    Write-Host "Staging  : $loadOrderPath ($($current.Count) mods)"
    Write-Host ''

    if (-not $profiles) {
        Write-Warn 'No profiles saved yet. Save the current load order with:'
        Write-Warn '  .\darktide.ps1 profile -Action save -Name full'
        return 0
    }

    $width   = ($profiles | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
    $matched = $false
    foreach ($p in $profiles) {
        $isCurrent = Test-SameEntry -Left $p.Entries -Right $current
        if ($isCurrent) { $matched = $true }
        $mark    = if ($isCurrent) { '*' } else { ' ' }
        $missing = @(Get-MissingMod -Entries $p.Entries)
        $line    = "  $mark $($p.Name.PadRight($width))  $($p.Entries.Count) mods"
        if ($missing) { $line += "  ($($missing.Count) not in staging)" }

        if ($isCurrent)   { Write-Ok $line }
        elseif ($missing) { Write-Warn $line }
        else              { Write-Host $line }
    }
    Write-Host ''
    if ($matched) { Write-Host '* = matches the current staging load order' }
    else          { Write-Host 'The current staging load order matches none of these profiles.' }
    return 0
}

function Invoke-Show {
    param([string] $ProfileName)
    Assert-ProfileName -Value $ProfileName
    $path    = Resolve-ProfileFile -ProfileName $ProfileName -AllowBackup
    $entries = @(Get-LoadOrderEntry -Path $path)
    $current = @(Get-LoadOrderEntry -Path $loadOrderPath)
    $missing = @(Get-MissingMod -Entries $entries)

    Write-Step "=== Profile '$ProfileName' ==="
    Write-Host "File    : $path"
    Write-Host "Mods    : $($entries.Count)"
    Write-Host "Current : $(if (Test-SameEntry -Left $entries -Right $current) { 'yes - staging uses this load order' } else { 'no' })"
    Write-Host ''
    foreach ($line in @(Get-Content -LiteralPath $path -Encoding UTF8)) { Write-Host "  $line" }
    Write-Host ''

    if ($missing) {
        Write-Warn "Not in staging ($($missing.Count)): $($missing -join ', ')"
        Write-Warn 'Install them, or comment them out with -- in the profile, before switching to it.'
    } else {
        Write-Ok "Every listed mod is in staging."
    }
    return 0
}

function Invoke-Delete {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string] $ProfileName, [switch] $Commit)
    Assert-ProfileName -Value $ProfileName
    $path    = Join-Path $profilesDir "$ProfileName.txt"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        [void](Resolve-ProfileFile -ProfileName $ProfileName)   # throws with the list of profiles
    }
    $entries = @(Get-LoadOrderEntry -Path $path)

    Write-Step "=== Delete profile '$ProfileName' ==="
    Write-Host "File : $path"
    Write-Host "Mods : $($entries.Count)$(if ($entries) { ' - ' + ($entries -join ', ') })"
    Write-Host "Mode : $(if ($Commit) { 'APPLY' } else { 'DRY RUN (pass -Apply to write)' })"
    Write-Host ''
    Write-Host '  Staging and the game folder are not touched; only the profile file goes.'
    Write-Host ''

    if (-not $Commit) {
        Write-Warn 'Dry run complete. Nothing was written. Re-run with -Apply.'
        return 0
    }

    if ($PSCmdlet.ShouldProcess($path, 'Delete profile')) {
        Remove-Item -LiteralPath $path -Force
        Write-Ok "Deleted profile '$ProfileName'."
    }
    return 0
}

function Invoke-Switch {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string] $ProfileName, [switch] $Commit, [int] $Keep)
    Assert-ProfileName -Value $ProfileName
    $source     = Resolve-ProfileFile -ProfileName $ProfileName -AllowBackup
    $wanted     = @(Get-LoadOrderEntry -Path $source)
    $current    = @(Get-LoadOrderEntry -Path $loadOrderPath)
    $hadCurrent = Test-Path -LiteralPath $loadOrderPath -PathType Leaf
    $identical  = $hadCurrent -and ((Get-FileText -Path $source) -eq (Get-FileText -Path $loadOrderPath))

    $enable  = @($wanted  | Where-Object { $current -notcontains $_ })
    $disable = @($current | Where-Object { $wanted  -notcontains $_ })
    $missing = @(Get-MissingMod -Entries $wanted)

    # Which saved profile staging matches now, so the undo can name it.
    $previous = @(Get-SavedProfile | Where-Object {
        $_.Name -ne $ProfileName -and (Test-SameEntry -Left $_.Entries -Right $current) })

    Write-Step "=== Switch to profile '$ProfileName' ==="
    Write-Host "Profile    : $source"
    Write-Host "Load order : $loadOrderPath"
    Write-Host "Backups    : $backupDir"
    Write-Host "Mode       : $(if ($Commit) { 'APPLY' } else { 'DRY RUN (pass -Apply to write)' })"
    Write-Host ''

    Write-Step 'Plan'
    Write-Host "  current    : $($current.Count) mods$(if ($previous) { " (matches profile '$($previous[0].Name)')" })"
    Write-Host "  profile    : $($wanted.Count) mods"
    if ($enable)  { Write-Host "  enable     : $($enable -join ', ')" -ForegroundColor Green }
    if ($disable) { Write-Host "  disable    : $($disable -join ', ')" -ForegroundColor Yellow }
    if (-not $enable -and -not $disable -and -not (Test-SameEntry -Left $wanted -Right $current)) {
        Write-Host '  order      : same mods, different load order'
    }
    if ($identical) {
        Write-Ok   '  load order : already this profile - staging will not be rewritten'
    } elseif (-not $enable -and -not $disable -and (Test-SameEntry -Left $wanted -Right $current)) {
        Write-Host '  load order : same mods in the same order; only comments or spacing differ'
    }
    if (-not $wanted) { Write-Warn '  this profile enables no mods at all' }
    Write-Host ''

    if ($missing) {
        Write-Err "  not in staging: $($missing -join ', ')"
        Write-Err '  DMF errors on startup when the load order names a folder that is not there.'
        Write-Err '  Install those mods, or comment them out with -- in the profile, then try again.'
        throw "Profile '$ProfileName' names $($missing.Count) mod(s) that are not in staging: $($missing -join ', '). Nothing was written."
    }

    if (-not $Commit) {
        if (-not $identical) {
            if ($hadCurrent) { Write-Host "  would back up : $loadOrderPath -> $backupDir" }
            Write-Host "  would write   : $source -> $loadOrderPath"
        }
        Write-Host '  would deploy  : Deploy-DarktideMods.ps1 -Apply (backs up and updates the game mods folder)'
        Write-Host ''
        Write-Warn 'Dry run complete. Nothing was written. Re-run with -Apply.'
        return 0
    }

    # ---- Pre-flight: refuse before touching staging, so a refusal leaves both sides as they were.

    $deployer = Join-Path $PSScriptRoot 'Deploy-DarktideMods.ps1'
    if (-not (Test-Path -LiteralPath $deployer)) {
        throw "Deploy-DarktideMods.ps1 not found next to this script (looked for '$deployer'). Nothing was written."
    }
    $gameProblem = Get-GameFolderProblem -Path $cfg.GamePath
    if ($gameProblem) { throw "$gameProblem Nothing was written." }
    # The deployer refuses too, but only after staging would already be switched.
    $running = Get-Process -Name 'Darktide' -ErrorAction SilentlyContinue
    if ($running) {
        throw "Darktide.exe is running (PID $(@($running | ForEach-Object { $_.Id }) -join ', ')). Close the game before switching profiles. Nothing was written."
    }

    if (-not $PSCmdlet.ShouldProcess($loadOrderPath, "Switch the staging load order to profile '$ProfileName' and deploy")) {
        return 0
    }

    # ---- Staging side

    $backupFile = $null
    if ($identical) {
        Write-Ok 'Staging already uses this load order - not rewritten.'
    } else {
        if ($hadCurrent) {
            [void][System.IO.Directory]::CreateDirectory($backupDir)
            $stamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
            $backupFile = Join-Path $backupDir "mod_load_order-$stamp.txt"
            $suffix = 1
            while (Test-Path -LiteralPath $backupFile) {
                $backupFile = Join-Path $backupDir "mod_load_order-$stamp-$suffix.txt"
                $suffix++
            }
            Copy-Item -LiteralPath $loadOrderPath -Destination $backupFile -Force
            Write-Ok "  backed up the load order -> $backupFile"
        }

        # Write the bytes, not a copy of the file: a fresh write time guarantees the
        # deploy sees the change even when two profiles happen to be the same size.
        [System.IO.File]::WriteAllBytes($loadOrderPath, [System.IO.File]::ReadAllBytes($source))
        Write-Ok "  staging load order is now profile '$ProfileName' ($($wanted.Count) mods)"
        Remove-OldLoadOrderBackup -Keep $Keep
    }

    $undoStaging = $null
    if ($backupFile) {
        $backupName  = [System.IO.Path]::GetFileNameWithoutExtension($backupFile)
        $undoStaging = ".\darktide.ps1 profile -Action switch -Name $backupName -Apply"
        if ($previous) {
            $undoStaging += "   # or: -Name $($previous[0].Name)"
        }
    }

    # ---- Game side: the deployer owns every write to the game folder.

    $deployBackupRoot = if ($cfg.DeployBackupRoot) { $cfg.DeployBackupRoot } else {
        Join-Path (Split-Path -Parent $staging) 'deploy_backups'
    }
    $zipsBefore = @(Get-DeployZipName -Root $deployBackupRoot)

    Write-Host ''
    Write-Step 'Deploying to the game folder...'
    $deployArgs = @{
        ConfigPath  = $ConfigPath
        StagingMods = $staging
        GamePath    = $cfg.GamePath
        Apply       = $true
        KeepBackups = $Keep
        Confirm     = $false
    }
    if ($cfg.DeployBackupRoot) { $deployArgs['BackupRoot'] = $cfg.DeployBackupRoot }

    # Success is judged by what the deployer says, not by $LASTEXITCODE: robocopy
    # leaves 1 behind after a successful copy, and the deployer's own failure exit is
    # also 1. It throws on a refusal and prints 'Deploy OK.' only when every
    # post-check passed.
    $deployInfo  = $null
    $deployError = $null
    try {
        & $deployer @deployArgs -InformationVariable deployInfo | Out-Host
    } catch {
        $deployError = $_
    }
    $deployText = @(Get-InfoText -Records $deployInfo | ForEach-Object { $_.Trim() })
    $deployOk   = (-not $deployError) -and ($deployText -contains 'Deploy OK.')

    $newZips = @(Get-DeployZipName -Root $deployBackupRoot | Where-Object { $zipsBefore -notcontains $_ })

    Write-Host ''
    if ($deployOk) {
        if ($identical) {
            Write-Ok "Profile '$ProfileName' was already active; staging unchanged and the game folder checked."
        } else {
            Write-Ok "Switched to profile '$ProfileName'. Staging and the game folder both use it now."
        }
        if ($undoStaging -or $newZips) {
            Write-Host ''
            Write-Host 'Undo this switch:' -ForegroundColor Cyan
            if ($undoStaging) {
                Write-Host "  both sides : $undoStaging"
            }
            if ($newZips) {
                Write-Host "  game only  : .\darktide.ps1 restore -Apply -BackupSet '$($newZips[-1])'"
            }
        }
        return 0
    }

    if ($identical) {
        Write-Err 'The deploy did not finish. Staging was not changed by this switch.'
    } else {
        Write-Err "Staging WAS switched to profile '$ProfileName', but the game folder was NOT updated."
    }
    if ($deployError) {
        Write-Err "  deploy stopped: $($deployError.Exception.Message)"
    } else {
        Write-Err '  the deploy reported problems - see its output above.'
    }
    Write-Host ''
    Write-Host 'To finish the switch once the problem is fixed:' -ForegroundColor Cyan
    Write-Host '  .\darktide.ps1 deploy -Apply'
    if ($undoStaging) {
        Write-Host 'To put staging back the way it was instead:' -ForegroundColor Cyan
        Write-Host "  $undoStaging"
    }
    if ($newZips) {
        Write-Host 'The game folder was backed up before the deploy started. To put it back:' -ForegroundColor Cyan
        Write-Host "  .\darktide.ps1 restore -Apply -BackupSet '$($newZips[-1])'"
    }
    return 1
}

# ----------------------------------------------------------------------------------

$result = @(switch ($Action) {
    'save'   { Invoke-Save   -ProfileName $Name -Overwrite:$Force }
    'list'   { Invoke-List }
    'show'   { Invoke-Show   -ProfileName $Name }
    'switch' { Invoke-Switch -ProfileName $Name -Commit:$Apply -Keep $KeepBackups }
    'delete' { Invoke-Delete -ProfileName $Name -Commit:$Apply }
})
$code = if ($result.Count -gt 0) { [int]$result[-1] } else { 0 }

# Always leave an explicit exit code. A deploy that succeeded still leaves robocopy's
# 1 in $LASTEXITCODE, and a caller reading that would take success for failure.
exit $code
