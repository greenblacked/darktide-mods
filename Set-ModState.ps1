<#
.SYNOPSIS
    Switches a mod off or back on in the staging load order, without deleting it.

.DESCRIPTION
    The Darktide Mod Loader skips any line in mod_load_order.txt that starts with
    '--'. Disabling a mod rewrites its line from 'name' to '--name'; enabling turns
    '--name' back into 'name'. The mod folder stays where it is, so switching a mod
    back on needs no download and no reinstall.

    Only the STAGING mod_load_order.txt is edited. Staging is the source of truth and
    the game folder is rebuilt from it, so the change reaches the game on the next
    deploy:

        .\darktide.ps1 deploy -Apply

    That step is left to you rather than run automatically, so a run of several
    toggles costs one deploy.

    Every other line of the file is kept byte for byte: comments, order, blank lines,
    line endings, and the encoding and byte-order mark the file already had.

    A mod that is staged but missing from the file entirely is appended: as 'name'
    by 'enable', and as '--name' by 'disable', so the updater sees it as present and
    does not add it back as an active line.

    Nothing is written without -Apply. With -Apply, the current mod_load_order.txt
    is copied to the load-order backup folder first.

.PARAMETER Action
    'disable' or 'enable'. 'disable' with no -Only lists what is currently switched
    off and writes nothing.

.PARAMETER Only
    The mod folder name(s) to switch, as they appear in staging. Accepts an array or
    a comma-separated list. 'base' and 'dmf' are refused: the loader and the
    framework are not optional.

.PARAMETER Apply
    Actually write the change. Without it you get the plan and nothing else.

.PARAMETER ConfigPath
    config.json to read ModsRoot and BackupRoot from.

.PARAMETER ModsRoot
    Staging mods folder. Overrides ModsRoot in config.json.

.PARAMETER BackupDir
    Where backups of mod_load_order.txt go. Defaults to a 'loadorder_backups'
    folder beside the staging backup root (BackupRoot in config.json). It is kept
    out of BackupRoot itself because every folder in there is treated as an
    updater backup set: 'rollback' would pick it as the newest set, and the
    updater's pruning would delete it.

.PARAMETER KeepBackups
    How many mod_load_order.txt backups to keep. Older ones are pruned after a
    successful backup. Default 10; 0 keeps everything.

.EXAMPLE
    .\Set-ModState.ps1 disable
    Lists the mods that are switched off. Writes nothing.

.EXAMPLE
    .\Set-ModState.ps1 disable -Only scoreboard
    Shows the line that would change. Nothing is written.

.EXAMPLE
    .\Set-ModState.ps1 disable -Only scoreboard,markers_aio -Apply
    Backs up mod_load_order.txt, then switches both mods off in staging.

.EXAMPLE
    .\Set-ModState.ps1 enable -Only scoreboard -Apply
    Switches the mod back on.

.NOTES
    Writes nothing in the game folder, so it does not need the game to be closed.
    Deploy afterwards (with the game closed) to make the change live.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('disable', 'enable')]
    [string]   $Action,

    [string[]] $Only,
    [switch]   $Apply,
    [string]   $ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string]   $ModsRoot,
    [string]   $BackupDir,

    [ValidateRange(0, 1000)]
    [int]      $KeepBackups = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$m) Write-Host $m -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host $m -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host $m -ForegroundColor Yellow }

# The loader and the framework every other mod depends on. Switching either off
# breaks every mod at once, which is never what a bisect wants.
$script:Protected = @('base', 'dmf')

# ----------------------------------------------------------------------------------
# Config
# ----------------------------------------------------------------------------------

$cfg = @{ ModsRoot = ''; BackupRoot = '' }
if (Test-Path -LiteralPath $ConfigPath) {
    $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    if ($raw.Trim()) {
        $j = $raw | ConvertFrom-Json
        foreach ($k in @($cfg.Keys)) {
            if ($j.PSObject.Properties.Name -contains $k -and "$($j.$k)".Trim()) { $cfg[$k] = "$($j.$k)" }
        }
    }
}
if ($ModsRoot) { $cfg.ModsRoot = $ModsRoot }

if (-not $cfg.ModsRoot) {
    throw "Staging mods folder not set. Put ModsRoot in config.json or pass -ModsRoot."
}
if (-not (Test-Path -LiteralPath $cfg.ModsRoot -PathType Container)) {
    throw "ModsRoot '$($cfg.ModsRoot)' does not exist."
}
$modsRoot = (Resolve-Path -LiteralPath $cfg.ModsRoot).ProviderPath
$loadOrderPath = Join-Path $modsRoot 'mod_load_order.txt'
if (-not (Test-Path -LiteralPath $loadOrderPath -PathType Leaf)) {
    throw "No mod_load_order.txt in '$modsRoot'. Installing the loader creates one: .\darktide.ps1 loader -Apply"
}

# ----------------------------------------------------------------------------------
# Reading and writing the file without disturbing it
# ----------------------------------------------------------------------------------

function Read-LoadOrderFile {
    <#
        Decodes the file the way it was written, so writing it back changes only the
        lines that were edited. Returns the preamble bytes, the encoding, and the
        text split into alternating line / terminator pieces.
    #>
    param([Parameter(Mandatory)][string] $Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $preamble = 0
    $encoding = $null

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $preamble = 3
        $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $preamble = 2
        $encoding = New-Object System.Text.UnicodeEncoding($false, $false, $true)
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $preamble = 2
        $encoding = New-Object System.Text.UnicodeEncoding($true, $false, $true)
    }

    if ($encoding) {
        $text = $encoding.GetString($bytes, $preamble, $bytes.Length - $preamble)
    } else {
        # No BOM: UTF-8 if it decodes cleanly (that round-trips exactly), otherwise
        # Latin-1, which maps every byte to one character and back, so a file in a
        # legacy code page survives untouched apart from the edited lines.
        try {
            $encoding = New-Object System.Text.UTF8Encoding($false, $true)
            $text = $encoding.GetString($bytes)
        } catch {
            $encoding = [System.Text.Encoding]::GetEncoding(28591)
            $text = $encoding.GetString($bytes)
        }
    }

    $preambleBytes = New-Object byte[] $preamble
    if ($preamble -gt 0) { [Array]::Copy($bytes, $preambleBytes, $preamble) }

    # The capture group keeps each terminator, so even indexes are line content and
    # odd indexes are the exact CRLF / LF / CR that ended it.
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($p in [regex]::Split($text, '(\r\n|\n|\r)')) { $parts.Add($p) }

    $newline = "`r`n"
    $m = [regex]::Match($text, '\r\n|\n|\r')
    if ($m.Success) { $newline = $m.Value }

    return [pscustomobject]@{
        Bytes     = $bytes
        Preamble  = $preambleBytes
        Encoding  = $encoding
        Parts     = $parts
        Newline   = $newline
    }
}

function Get-LoadOrderEntry {
    <# What a line names, and whether it is switched off. $null for blanks. #>
    param([string] $Line)

    $t = $Line.Trim()
    if (-not $t) { return $null }
    if ($t.StartsWith('--')) {
        $name = $t.Substring(2).Trim()
        if (-not $name) { return $null }
        return [pscustomobject]@{ Name = $name; Disabled = $true }
    }
    return [pscustomobject]@{ Name = $t; Disabled = $false }
}

function Get-EntryIndex {
    <# Indexes (into Parts) of the lines naming $Name, split by state. #>
    param($File, [string] $Name)

    $active = New-Object System.Collections.Generic.List[int]
    $disabled = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $File.Parts.Count; $i += 2) {
        $e = Get-LoadOrderEntry -Line $File.Parts[$i]
        if (-not $e -or $e.Name -ine $Name) { continue }
        if ($e.Disabled) { $disabled.Add($i) } else { $active.Add($i) }
    }
    return [pscustomobject]@{ Active = @($active); Disabled = @($disabled) }
}

function Add-LoadOrderLine {
    <# Appends a line, keeping the file's terminator style and its trailing-newline habit. #>
    param($File, [string] $Line)

    $last = $File.Parts.Count - 1
    if ($File.Parts[$last] -eq '') {
        # Ends with a terminator (or is empty): the new line gets one too.
        $File.Parts[$last] = $Line
        $File.Parts.Add($File.Newline)
        $File.Parts.Add('')
    } else {
        # No trailing terminator: start a new line, and leave it unterminated as well.
        $File.Parts.Add($File.Newline)
        $File.Parts.Add($Line)
    }
}

function Get-StagedMod {
    <# The real staging folder for a requested name, or a throw saying why not. #>
    param([string] $Name)

    if ($script:Protected -contains $Name) {
        throw "Refusing to $Action '$Name': it is the mod loader or the framework, and every other mod depends on it."
    }
    if ($Name -in @('.', '..') -or $Name.StartsWith('.') -or
        $Name -match '[\\/:*?"<>|]' -or $Name -ne [System.IO.Path]::GetFileName($Name)) {
        throw "'$Name' is not a mod folder name. Pass the folder name as it appears in staging, e.g. -Only scoreboard"
    }
    $dir = @(Get-ChildItem -LiteralPath $modsRoot -Directory -Force -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -ieq $Name })
    if (-not $dir) {
        throw "No mod folder '$Name' in staging ($modsRoot). Check the spelling: .\darktide.ps1 disable lists the load order state."
    }
    return $dir[0].Name
}

# ----------------------------------------------------------------------------------
# Listing
# ----------------------------------------------------------------------------------

$file = Read-LoadOrderFile -Path $loadOrderPath

$names = @()
foreach ($o in @($Only)) {
    if (-not $o) { continue }
    foreach ($piece in ($o -split ',')) {
        $n = $piece.Trim()
        if ($n -and -not ($names | Where-Object { $_ -ieq $n })) { $names += $n }
    }
}

if (-not $names) {
    $staged = @(Get-ChildItem -LiteralPath $modsRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { -not $_.Name.StartsWith('.') -and $script:Protected -notcontains $_.Name } |
                Sort-Object Name | ForEach-Object { $_.Name })
    $off = @()
    $absent = @()
    foreach ($s in $staged) {
        $idx = Get-EntryIndex -File $file -Name $s
        if ($idx.Active.Count -gt 0) { continue }
        if ($idx.Disabled.Count -gt 0) { $off += $s } else { $absent += $s }
    }

    Write-Step "Load order: $loadOrderPath"
    if ($off) {
        Write-Host "  disabled ($($off.Count)):"
        foreach ($s in $off) { Write-Host "    $s" }
    } else {
        Write-Ok '  no mods are disabled'
    }
    if ($absent) {
        Write-Warn "  staged but not in the load order, so not loaded either ($($absent.Count)):"
        foreach ($s in $absent) { Write-Warn "    $s" }
    }
    Write-Host ''

    if ($Action -eq 'enable') {
        throw 'Which mod? Pass -Only <folder>, e.g. .\darktide.ps1 enable -Only scoreboard -Apply'
    }
    Write-Host 'Switch one off with: .\darktide.ps1 disable -Only <folder> -Apply'
    return
}

# ----------------------------------------------------------------------------------
# Plan
# ----------------------------------------------------------------------------------

# Validate every name before touching anything, so a typo in the third name does
# not leave the first two half-applied.
$targets = @(foreach ($n in $names) { Get-StagedMod -Name $n })

Write-Step "Load order : $loadOrderPath"
if ($Apply) { Write-Host 'Mode       : APPLY' }
else        { Write-Warn 'Mode       : DRY RUN (pass -Apply to write)' }
Write-Host ''

$changes = 0
foreach ($t in $targets) {
    $idx = Get-EntryIndex -File $file -Name $t

    if ($Action -eq 'disable') {
        if ($idx.Active.Count -gt 0) {
            # Every active line, so a mod listed twice cannot keep loading.
            foreach ($i in $idx.Active) {
                $before = $file.Parts[$i]
                $file.Parts[$i] = [regex]::Replace($before, '^(\s*)', '$1--')
                Write-Host "  $t : '$before' -> '$($file.Parts[$i])'"
                $changes++
            }
        } elseif ($idx.Disabled.Count -gt 0) {
            Write-Ok "  $t : already disabled"
        } else {
            Add-LoadOrderLine -File $file -Line "--$t"
            Write-Host "  $t : not in the load order - appending '--$t' so an update does not switch it on"
            $changes++
        }
    } else {
        if ($idx.Active.Count -gt 0) {
            Write-Ok "  $t : already enabled"
        } elseif ($idx.Disabled.Count -gt 0) {
            # Only the first: two '--name' lines must not become a duplicate entry.
            $i = $idx.Disabled[0]
            $before = $file.Parts[$i]
            $file.Parts[$i] = [regex]::Replace($before, '^(\s*)--\s*', '$1')
            Write-Host "  $t : '$before' -> '$($file.Parts[$i])'"
            $changes++
        } else {
            Add-LoadOrderLine -File $file -Line $t
            Write-Host "  $t : not in the load order - appending '$t'"
            $changes++
        }
    }
}
Write-Host ''

if ($changes -eq 0) {
    Write-Ok 'Nothing to change.'
    return
}

if (-not $Apply) {
    Write-Host 'After -Apply, push it to the game with: .\darktide.ps1 deploy -Apply'
    Write-Warn 'Dry run complete. Nothing was written. Re-run with -Apply.'
    return
}

# ----------------------------------------------------------------------------------
# Apply
# ----------------------------------------------------------------------------------

if (-not $BackupDir) {
    $bkRoot = if ($cfg.BackupRoot) { $cfg.BackupRoot } else { Join-Path (Split-Path -Parent $modsRoot) 'mod_backups' }
    $bkRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($bkRoot)
    $bkParent = Split-Path -Parent $bkRoot
    if (-not $bkParent) {
        throw "BackupRoot '$bkRoot' has no parent folder to put load-order backups beside. Pass -BackupDir."
    }
    $BackupDir = Join-Path $bkParent 'loadorder_backups'
}
$BackupDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BackupDir)

$text = ($file.Parts -join '')
$newBytes = $file.Encoding.GetBytes($text)
$out = New-Object byte[] ($file.Preamble.Length + $newBytes.Length)
[Array]::Copy($file.Preamble, 0, $out, 0, $file.Preamble.Length)
[Array]::Copy($newBytes, 0, $out, $file.Preamble.Length, $newBytes.Length)

$written = $false
if ($PSCmdlet.ShouldProcess($loadOrderPath, "$Action $($targets -join ', ')")) {
    [void][System.IO.Directory]::CreateDirectory($BackupDir)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $BackupDir "mod_load_order-$stamp.txt"
    $suffix = 1
    while (Test-Path -LiteralPath $backup) {
        $backup = Join-Path $BackupDir "mod_load_order-$stamp-$suffix.txt"
        $suffix++
    }
    # Written from the bytes read above rather than copied, so the backup is exactly
    # what this run replaced and its write time is when the backup was taken.
    [System.IO.File]::WriteAllBytes($backup, $file.Bytes)
    Write-Ok "Backed up mod_load_order.txt -> $backup"

    $tmp = "$loadOrderPath.tmp"
    try {
        [System.IO.File]::WriteAllBytes($tmp, $out)
        Move-Item -LiteralPath $tmp -Destination $loadOrderPath -Force
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    $written = $true
    Write-Ok "Updated $loadOrderPath"

    if ($KeepBackups -gt 0) {
        $stale = @(Get-ChildItem -LiteralPath $BackupDir -Filter 'mod_load_order-*.txt' -File |
                   Sort-Object @{ Expression = { $_.LastWriteTimeUtc }; Descending = $true },
                               @{ Expression = { $_.Name }; Descending = $true } |
                   Select-Object -Skip $KeepBackups)
        foreach ($old in $stale) {
            Remove-Item -LiteralPath $old.FullName -Force
            Write-Host "Pruned old load-order backup: $($old.Name)"
        }
    }
}

if ($written) {
    Write-Host ''
    Write-Host 'Staging changed; the game folder has not. Next step:'
    Write-Host ''
    Write-Host '    .\darktide.ps1 deploy -Apply'
    Write-Host ''
}
