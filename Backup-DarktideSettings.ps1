<#
.SYNOPSIS
    Backs up and restores your Darktide mod settings file.

.DESCRIPTION
    DMF and the game keep mod settings (keybinds, toggles, every option you set in the
    mod menu) in user_settings.config, which lives in your Windows profile rather than
    in staging or the game folder. Nothing else in this tooling backs it up: deploy,
    update, export and the loader never touch it. This script does.

    The file is treated as opaque bytes. It is copied, hashed and compared, never
    parsed or merged, because its layout is not something this repository can verify.

    With no -Apply and no -BackupSet it shows the settings file and the backups you
    have, newest first, and says what -Apply would do. With -Apply it takes a
    timestamped copy, unless the file is byte-identical to the newest backup, in which
    case it says so and writes nothing.

    With -BackupSet it shows what a restore would do. With -BackupSet and -Apply it
    refuses while Darktide is running (the game rewrites this file when it exits, which
    would overwrite the restore), backs up the current file first, then restores.

    Backups go to a 'settings_backups' folder beside your staging folder (the parent
    of ModsRoot), next to mod_backups and deploy_backups, unless config.json sets
    SettingsBackupDir. With no config.json they go to
    %LOCALAPPDATA%\darktide-mods\settings_backups. They are never written inside this
    repository, staging or the game folder.

.PARAMETER SettingsPath
    The settings file. Defaults to SettingsPath from config.json if present, else
    %APPDATA%\Fatshark\Darktide\user_settings.config. That default is where the file
    is documented to live; if your install keeps it elsewhere, point this at it.

.PARAMETER BackupDir
    Where backups go. Defaults to SettingsBackupDir from config.json if present, else
    <parent of ModsRoot>\settings_backups.

.PARAMETER BackupSet
    Restore the backup whose file name contains this text. A substring that matches
    more than one backup is refused; pass more of the name. An exact file name always
    wins.

.PARAMETER Apply
    Actually write. Without it you get a report and nothing else.

.PARAMETER KeepBackups
    How many settings backups to keep. Older ones are pruned after a new one is
    written. Default 10; 0 keeps everything.

.PARAMETER ConfigPath
    config.json to read ModsRoot, GamePath and the optional SettingsPath and
    SettingsBackupDir from. Not required: without it the defaults above apply.

.PARAMETER ProcessName
    The process whose presence blocks a restore. Used by the tests; leave it alone.

.EXAMPLE
    .\Backup-DarktideSettings.ps1
    Shows the settings file and lists the backups. Writes nothing.

.EXAMPLE
    .\Backup-DarktideSettings.ps1 -Apply
    Takes a backup, unless nothing changed since the last one.

.EXAMPLE
    .\Backup-DarktideSettings.ps1 -BackupSet 20261022
    Shows what restoring the backup taken on 2026-10-22 would change.

.EXAMPLE
    .\Backup-DarktideSettings.ps1 -BackupSet 'user_settings-20261022-181500.config' -Apply
    Backs up the current file, then restores that backup. Close the game first.

.NOTES
    Run it before a big update, before switching mod profiles, and before anything
    that might reset the mod menu. A restore only helps if a backup exists.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $SettingsPath,
    [string] $BackupDir,
    [string] $BackupSet,
    [switch] $Apply,

    [ValidateRange(0, 1000)]
    [int] $KeepBackups = 10,

    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config.json'),

    [Parameter(DontShow = $true)]
    [string] $ProcessName = 'Darktide'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$m) Write-Host $m -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host $m -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host $m -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host $m -ForegroundColor Red }

# Only files with this shape are listed, restored from or pruned. Anything else a
# user drops into the folder is left alone.
$script:BackupPattern = '^user_settings-(?<stamp>\d{8}-\d{6})(?<tag>-prerestore)?(?:-(?<seq>\d+))?\.config$'

function Resolve-FullPath {
    <#
        An absolute path, with a relative one taken from the PowerShell location. Not
        [IO.Path]::GetFullPath alone: that resolves against the process directory,
        which Windows PowerShell does not move when you cd.
    #>
    param([string] $Path)
    return [System.IO.Path]::GetFullPath(
        $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
}

function Test-PathInside {
    <# True when $Child is $Parent or sits anywhere below it. #>
    param([string] $Child, [string] $Parent)

    if (-not $Child -or -not $Parent) { return $false }
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $c = (Resolve-FullPath $Child).TrimEnd('\', '/') + $sep
    $p = (Resolve-FullPath $Parent).TrimEnd('\', '/') + $sep
    return $c.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-SettingsBackup {
    <# Every backup in $Dir, newest first by the stamp in its name, then by its number. #>
    param([string] $Dir)

    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return @() }
    $list = foreach ($f in @(Get-ChildItem -LiteralPath $Dir -File)) {
        $m = [regex]::Match($f.Name, $script:BackupPattern)
        if (-not $m.Success) { continue }
        # The name, not LastWriteTime: a copy keeps the source file's write time, so
        # LastWriteTime says when the game last saved, not when the backup was taken.
        [pscustomobject]@{
            Name       = $f.Name
            FullName   = $f.FullName
            Length     = $f.Length
            Taken      = [datetime]::ParseExact($m.Groups['stamp'].Value, 'yyyyMMdd-HHmmss',
                                                [System.Globalization.CultureInfo]::InvariantCulture)
            Seq        = $(if ($m.Groups['seq'].Success) { [int]$m.Groups['seq'].Value } else { 0 })
            PreRestore = $m.Groups['tag'].Success
        }
    }
    return @($list | Sort-Object @{ Expression = 'Taken'; Descending = $true },
                                 @{ Expression = 'Seq';   Descending = $true })
}

function Get-NewBackupPath {
    <#
        A name nothing else uses. Two runs in the same second get -1, -2 ... rather
        than overwriting each other, and the number is shared between plain and
        pre-restore backups so 'newest' is never a tie.
    #>
    param([string] $Dir, [string] $Stamp, [switch] $PreRestore)

    $seq = 0
    while ($true) {
        $suffix = if ($seq -gt 0) { "-$seq" } else { '' }
        $plain = Join-Path $Dir "user_settings-$Stamp$suffix.config"
        $pre   = Join-Path $Dir "user_settings-$Stamp-prerestore$suffix.config"
        if (-not (Test-Path -LiteralPath $plain) -and -not (Test-Path -LiteralPath $pre)) {
            if ($PreRestore) { return $pre }
            return $plain
        }
        $seq++
    }
}

function Get-Sha256 {
    param([string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Copy-Verified {
    <#
        Copies $Source to $Destination and confirms the bytes match. With -NoOverwrite
        an existing destination is an error rather than something to replace, which is
        what keeps two backups from ever sharing a name.
    #>
    param([string] $Source, [string] $Destination, [switch] $NoOverwrite)

    [System.IO.File]::Copy($Source, $Destination, (-not $NoOverwrite))
    if ((Get-Sha256 -Path $Source) -ne (Get-Sha256 -Path $Destination)) {
        throw "Copy of '$Source' to '$Destination' does not match the original."
    }
}

function Remove-OldSettingsBackup {
    <# Keeps the newest $Keep (0 keeps all). Never removes a name in $Protect. #>
    param([string] $Dir, [int] $Keep, [string[]] $Protect = @())

    if ($Keep -le 0) { return }
    $stale = @(Get-SettingsBackup -Dir $Dir | Select-Object -Skip $Keep |
               Where-Object { $Protect -notcontains $_.Name })
    foreach ($old in $stale) {
        Remove-Item -LiteralPath $old.FullName -Force
        Write-Host "  pruned old backup: $($old.Name)"
    }
}

function Format-Backup {
    param($Backup, [string] $CurrentHash)

    $note = @()
    if ($Backup.PreRestore) { $note += 'taken before a restore' }
    if ($CurrentHash -and (Get-Sha256 -Path $Backup.FullName) -eq $CurrentHash) { $note += 'same as current' }
    $tail = if ($note) { "  ($($note -join ', '))" } else { '' }
    return ('    {0}  {1,10:N0} bytes  taken {2:yyyy-MM-dd HH:mm:ss}{3}' -f $Backup.Name, $Backup.Length, $Backup.Taken, $tail)
}

# ---- Resolve paths -------------------------------------------------------------------

$cfg = $null
if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
function Get-CfgValue {
    param([string] $Key)
    if ($null -eq $cfg) { return '' }
    if ($cfg.PSObject.Properties.Name -contains $Key -and "$($cfg.$Key)".Trim()) { return "$($cfg.$Key)".Trim() }
    return ''
}

$settingsSource = 'parameter'
if (-not $SettingsPath) {
    $SettingsPath = Get-CfgValue 'SettingsPath'
    $settingsSource = 'config.json'
}
if (-not $SettingsPath) {
    if (-not $env:APPDATA) {
        throw 'Cannot work out where user_settings.config is: APPDATA is not set. Pass -SettingsPath.'
    }
    $SettingsPath = Join-Path (Join-Path (Join-Path $env:APPDATA 'Fatshark') 'Darktide') 'user_settings.config'
    $settingsSource = 'default'
}
$SettingsPath = Resolve-FullPath $SettingsPath
if (Test-Path -LiteralPath $SettingsPath -PathType Container) {
    throw "'$SettingsPath' is a folder. -SettingsPath (or SettingsPath in config.json) must name the file itself."
}

$modsRoot = Get-CfgValue 'ModsRoot'
$gamePath = Get-CfgValue 'GamePath'

if (-not $BackupDir) { $BackupDir = Get-CfgValue 'SettingsBackupDir' }
if (-not $BackupDir) {
    if ($modsRoot) {
        $BackupDir = Join-Path (Split-Path -Parent (Resolve-FullPath $modsRoot)) 'settings_backups'
    } elseif ($env:LOCALAPPDATA) {
        $BackupDir = Join-Path (Join-Path $env:LOCALAPPDATA 'darktide-mods') 'settings_backups'
    } else {
        throw 'Cannot work out where to keep settings backups: no ModsRoot in config.json and LOCALAPPDATA is not set. Pass -BackupDir.'
    }
}
$BackupDir = Resolve-FullPath $BackupDir

# The settings file is personal and is not this repository's to carry. Keep its
# copies out of the checkout (where a commit or the release package could pick them
# up), out of staging (which export zips) and out of the game folder (which deploy
# mirrors and a Steam verify may sweep).
foreach ($forbidden in @(
        @{ Path = $PSScriptRoot; What = 'this repository' },
        @{ Path = $modsRoot;     What = 'staging (ModsRoot)' },
        @{ Path = $gamePath;     What = 'the game folder' })) {
    if ($forbidden.Path -and (Test-PathInside -Child $BackupDir -Parent $forbidden.Path)) {
        throw "Refusing to keep settings backups inside $($forbidden.What): '$BackupDir'. Pass -BackupDir, or set SettingsBackupDir in config.json, to somewhere else."
    }
}

# ---- Report --------------------------------------------------------------------------

# The dispatcher passes an empty -BackupSet when none was given. Whitespace is a
# mistake, and as a substring it would match every backup.
$restoring = [bool]$BackupSet
if ($restoring -and -not $BackupSet.Trim()) { throw '-BackupSet is blank. Pass part of a backup file name.' }
Write-Step "=== Darktide settings $(if ($restoring) { 'restore' } else { 'backup' }) ==="
Write-Host "Settings : $SettingsPath ($settingsSource)"
Write-Host "Backups  : $BackupDir"
Write-Host "Mode     : $(if ($Apply) { 'APPLY' } else { 'DRY RUN (pass -Apply to write)' })"
Write-Host ''

$current = $null
$currentHash = ''
if (Test-Path -LiteralPath $SettingsPath -PathType Leaf) {
    $current = Get-Item -LiteralPath $SettingsPath
    $currentHash = Get-Sha256 -Path $SettingsPath
    Write-Host ('  current file : {0:N0} bytes, last written {1:yyyy-MM-dd HH:mm:ss}' -f $current.Length, $current.LastWriteTime)
} else {
    Write-Warn "  No settings file at '$SettingsPath'."
    if ($settingsSource -eq 'default') {
        Write-Warn '  That is where the file is documented to live, but this tool cannot verify it.'
        Write-Warn '  If the game has not run on this machine yet, or keeps it elsewhere, pass'
        Write-Warn '  -SettingsPath or set SettingsPath in config.json.'
    }
}

$backups = @(Get-SettingsBackup -Dir $BackupDir)
Write-Host ''
if ($backups) {
    Write-Host "  backups ($($backups.Count), newest first):"
    foreach ($b in $backups) { Write-Host (Format-Backup -Backup $b -CurrentHash $currentHash) }
} else {
    Write-Host '  backups : none yet'
}
Write-Host ''

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# ---- Back up -------------------------------------------------------------------------

if (-not $restoring) {
    if (-not $current) {
        if ($Apply) { throw "Nothing to back up: no settings file at '$SettingsPath'." }
        Write-Warn 'Dry run complete. Nothing was written. Re-run with -Apply once the file exists.'
        return
    }

    if ($backups -and (Get-Sha256 -Path $backups[0].FullName) -eq $currentHash) {
        Write-Ok "Unchanged since the newest backup ($($backups[0].Name)). Nothing to back up."
        return
    }

    $target = Get-NewBackupPath -Dir $BackupDir -Stamp $stamp
    if (-not $Apply) {
        Write-Host "  would copy to : $target"
        Write-Warn 'Dry run complete. Nothing was written. Re-run with -Apply.'
        return
    }

    if (@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)) {
        Write-Warn 'Darktide is running. It rewrites this file when it exits, so this backup holds'
        Write-Warn 'the settings as they are now, not any change made in the current session.'
    }

    if ($PSCmdlet.ShouldProcess($SettingsPath, "Back up to $target")) {
        [void][System.IO.Directory]::CreateDirectory($BackupDir)
        Copy-Verified -Source $SettingsPath -Destination $target -NoOverwrite
        Write-Ok "Backed up -> $target"
        Remove-OldSettingsBackup -Dir $BackupDir -Keep $KeepBackups -Protect @((Split-Path -Leaf $target))
    }
    return
}

# ---- Restore -------------------------------------------------------------------------

if (-not $backups) { throw "No settings backups in '$BackupDir' to restore from." }

$wanted = $BackupSet.Trim()
$chosen = @($backups | Where-Object { $_.Name -eq $wanted -or $_.Name -eq "$wanted.config" })
if (-not $chosen) {
    # A plain substring test, not -like: a name with [ or ] in it is not a pattern.
    $chosen = @($backups | Where-Object { $_.Name.IndexOf($wanted, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 })
}
if (-not $chosen) { throw "No settings backup matching '$wanted' in '$BackupDir'." }
if ($chosen.Count -gt 1) {
    throw "'$wanted' matches $($chosen.Count) settings backups ($(($chosen | ForEach-Object { $_.Name }) -join ', ')). Pass more of the name."
}
$source = $chosen[0]
$sourceHash = Get-Sha256 -Path $source.FullName

Write-Host ('  restore from : {0} ({1:N0} bytes, taken {2:yyyy-MM-dd HH:mm:ss})' -f $source.Name, $source.Length, $source.Taken)
if ($current) {
    Write-Host ('  replaces     : {0:N0} bytes, last written {1:yyyy-MM-dd HH:mm:ss}' -f $current.Length, $current.LastWriteTime)
    if ($sourceHash -eq $currentHash) {
        Write-Ok 'The settings file already matches that backup. Nothing to restore.'
        return
    }
    Write-Host '  difference   : the backup differs from the current file'
} else {
    Write-Host '  replaces     : nothing (no current file)'
}

$settingsDir = Split-Path -Parent $SettingsPath
if (-not (Test-Path -LiteralPath $settingsDir -PathType Container)) {
    throw "The folder for the settings file does not exist: '$settingsDir'. Check -SettingsPath; this tool does not create it."
}

# Skip the pre-restore copy only when the current file is already the newest backup.
$preTarget = $null
if ($current) {
    if ((Get-Sha256 -Path $backups[0].FullName) -eq $currentHash) {
        Write-Host "  pre-restore  : not needed, the current file is already saved as $($backups[0].Name)"
    } else {
        $preTarget = Get-NewBackupPath -Dir $BackupDir -Stamp $stamp -PreRestore
        Write-Host "  pre-restore  : the current file is copied to $preTarget first"
    }
}

if (-not $Apply) {
    Write-Warn 'Dry run complete. Nothing was written. Re-run with -Apply.'
    return
}

# Only when actually writing. The game writes this file on exit, so a restore made
# while it runs would be silently undone the moment you quit.
$running = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
if ($running) {
    throw "Darktide is running (PID $(($running | ForEach-Object { $_.Id }) -join ', ')). Close the game first: it rewrites user_settings.config on exit and would overwrite the restore."
}

if ($preTarget) {
    if (-not $PSCmdlet.ShouldProcess($SettingsPath, "Back up to $preTarget before restoring")) { return }
    [void][System.IO.Directory]::CreateDirectory($BackupDir)
    Copy-Verified -Source $SettingsPath -Destination $preTarget -NoOverwrite
    Write-Ok "Current file saved -> $preTarget"
}

if ($PSCmdlet.ShouldProcess($SettingsPath, "Restore from $($source.Name)")) {
    Copy-Verified -Source $source.FullName -Destination $SettingsPath
    Write-Ok "Restored $($source.Name) -> $SettingsPath"
    $protect = @($source.Name)
    if ($preTarget) { $protect += (Split-Path -Leaf $preTarget) }
    Remove-OldSettingsBackup -Dir $BackupDir -Keep $KeepBackups -Protect $protect
}
