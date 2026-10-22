<#
.SYNOPSIS
    Shows, mod by mod, what the last staging update changed. Read-only.

.DESCRIPTION
    Run it after `update -Apply` and before `deploy`. Every mod that update -Apply
    replaces is first zipped to <BackupRoot>\<yyyyMMdd-HHmmss>\<mod>.zip, so the
    backup set from that run holds the previous copy of each one. This compares
    each of those zips against the mod folder now in staging and reports:

      - the old version (from the zip) and the new one (from staging), read from
        info.json first and .nexus-mod.json second, the same order the updater uses;
      - which files were added, removed or changed. Files are compared by SHA-256 of
        their content. Zip entries are hashed as a stream and never extracted.
        .nexus-mod.json is ignored, as it is for the lockfile's content hash,
        because it is rewritten on every install;
      - NEW for a mod in staging that has no zip in the set but was installed after
        the set was taken (and before the next set, if there is one);
      - REMOVED for a mod that has a zip in the set but no folder in staging.

    Only file names are printed, never file content. The console shows at most 50
    file lines per mod; -OutFile writes every line.

    It writes nothing except the -OutFile you ask for, and it never reads or writes
    the game folder. Staging is the source of truth; the game folder is whatever the
    next deploy makes it.

.PARAMETER ConfigPath
    config.json to read ModsRoot and BackupRoot from. BackupRoot defaults to
    <parent of ModsRoot>\mod_backups, the same default the updater uses.

.PARAMETER BackupSet
    Which backup set to compare. Either its full folder name (20261020-181500) or any
    part of it that matches exactly one set (1020-18, 20261020). Defaults to the
    newest set, which is the one `rollback` would restore.

.PARAMETER Only
    Limit the report to these mod folders.

.PARAMETER Skip
    Leave these mod folders out of the report.

.PARAMETER OutFile
    Also write the full report to this file. A name ending in .json writes JSON; one
    ending in .md writes markdown. The file lists are not capped. Refuses to write
    inside the staging folder or the backup root.

.PARAMETER Force
    Overwrite -OutFile if it already exists.

.EXAMPLE
    .\Show-ModChanges.ps1
    What the newest backup set says the last update changed.

.EXAMPLE
    .\Show-ModChanges.ps1 -BackupSet 1020-18 -Only markers_aio
    One mod, against the backup set whose name contains '1020-18'.

.EXAMPLE
    .\Show-ModChanges.ps1 -OutFile changes.md -Force
    The same report, with every file listed, written as markdown.

.NOTES
    A backup set is only created when update -Apply replaces at least one existing
    mod. A run that only added brand-new mods leaves no set of its own, so those mods
    show up as NEW against whichever set came before it.

    NEW is decided by the installedAt time update -Apply writes into .nexus-mod.json.
    A mod without that file falls back to its folder's last-write time, so a mod you
    copied into staging by hand after the update also shows as NEW.

    Comparing an older set reports the difference between that set and staging as it
    is now, which includes every update made since. The script says so when the set
    you picked is not the newest.
#>

[CmdletBinding()]
param(
    [string]   $ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string]   $BackupSet,
    [string[]] $Only,
    [string[]] $Skip,
    [string]   $OutFile,
    [switch]   $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue

# Console listing cap per mod. -OutFile is never capped.
$script:ListCap = 50

function Write-Step { param([string] $Message) Write-Host $Message -ForegroundColor Cyan }
function Write-Ok   { param([string] $Message) Write-Host $Message -ForegroundColor Green }
function Write-Warn { param([string] $Message) Write-Host $Message -ForegroundColor Yellow }

# ----------------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------------

function Test-PathInside {
    <# True when $Path is $Root or sits anywhere under it. Both are resolved first. #>
    param([string] $Path, [string] $Root)

    $p = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $r = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    if ($p.Equals($r, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    foreach ($sep in @('\', '/')) {
        if ($p.StartsWith($r + $sep, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-SetTimeUtc {
    <#
      When a backup set was taken. The updater names each set after the moment its
      run started (local time, yyyyMMdd-HHmmss), so the name is the authority; the
      folder's creation time is the fallback for a set someone renamed.
    #>
    param([System.IO.DirectoryInfo] $Dir)

    $t = [datetime]::MinValue
    if ([datetime]::TryParseExact($Dir.Name, 'yyyyMMdd-HHmmss',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeLocal, [ref]$t)) {
        return $t.ToUniversalTime()
    }
    return $Dir.CreationTimeUtc
}

function Resolve-BackupSet {
    <#
      Picks the backup set. No name: the newest by name, which is the one rollback
      restores. A name: an exact folder match, else the one set whose name contains it.
      Never a path - the value is only ever compared against folder names.
    #>
    param([System.IO.DirectoryInfo[]] $Sets, [string] $Name, [string] $BackupRoot)

    if (-not $Name) { return $Sets[-1] }

    if ($Name -match '[\\/]' -or [System.IO.Path]::GetFileName($Name) -ne $Name) {
        throw "-BackupSet must be a backup set name or part of one (e.g. '20260829-181500'), not a path."
    }

    $exact = @($Sets | Where-Object { $_.Name -eq $Name })
    if ($exact.Count -eq 1) { return $exact[0] }

    $hits = @($Sets | Where-Object { $_.Name.IndexOf($Name, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    if ($hits.Count -eq 1) { return $hits[0] }

    if ($hits.Count -eq 0) {
        $recent = @($Sets | Sort-Object Name -Descending | Select-Object -First 10 | ForEach-Object { $_.Name })
        throw "No backup set under '$BackupRoot' matches '$Name'. Newest sets: $($recent -join ', ')"
    }
    $names = @($hits | Sort-Object Name -Descending | ForEach-Object { $_.Name })
    throw "'$Name' matches $($hits.Count) backup sets: $($names -join ', '). Give more of the name."
}

function Get-JsonVersion {
    <# The 'version' field of a JSON document, or $null. Says so when the JSON is broken. #>
    param([string] $Text, [string] $Label)

    if (-not $Text -or -not $Text.Trim()) { return $null }
    try {
        $j = $Text | ConvertFrom-Json
    } catch {
        Write-Warn "  $Label is not valid JSON - version not read."
        return $null
    }
    if ($null -ne $j -and $j.PSObject.Properties.Name -contains 'version' -and "$($j.version)".Trim()) {
        return "$($j.version)".Trim()
    }
    return $null
}

function Get-FolderVersion {
    <# info.json first, .nexus-mod.json second: the order Get-LocalMods in the updater uses. #>
    param([string] $Path, [string] $Mod)

    foreach ($name in @('info.json', '.nexus-mod.json')) {
        $file = Join-Path $Path $name
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        $v = Get-JsonVersion -Text (Get-Content -LiteralPath $file -Raw -Encoding UTF8) -Label "$Mod\$name"
        if ($v) { return $v }
    }
    return $null
}

function Get-InstallTimeUtc {
    <#
      When a staging mod was installed. Install-ModArchive records installedAt in
      .nexus-mod.json; a mod without one falls back to its folder's last-write time.
    #>
    param([System.IO.DirectoryInfo] $Dir)

    $state = Join-Path $Dir.FullName '.nexus-mod.json'
    if (Test-Path -LiteralPath $state -PathType Leaf) {
        try {
            $s = Get-Content -LiteralPath $state -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            $s = $null
            Write-Warn "  $($Dir.Name)\.nexus-mod.json is not valid JSON - using the folder time."
        }
        if ($null -ne $s -and $s.PSObject.Properties.Name -contains 'installedAt' -and $s.installedAt) {
            # pwsh 7 turns an ISO string into a [datetime] during ConvertFrom-Json;
            # Windows PowerShell 5.1 leaves it a string. Handle both, never via the
            # current culture's idea of what a date looks like.
            if ($s.installedAt -is [datetime]) { return $s.installedAt.ToUniversalTime() }
            $dto = [DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse("$($s.installedAt)",
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::AssumeLocal, [ref]$dto)) {
                return $dto.UtcDateTime
            }
        }
    }
    return $Dir.LastWriteTimeUtc
}

function Get-StagingFiles {
    <#
      Every file in a staging mod folder, keyed by its lower-cased relative path with
      '/' separators. .nexus-mod.json is left out, as Get-FolderHash in
      New-ModpackLock.ps1 leaves it out.
    #>
    param([string] $Path)

    $table = @{}
    $root  = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    foreach ($f in @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction Stop)) {
        if ($f.Name -eq '.nexus-mod.json') { continue }
        $rel = $f.FullName.Substring($root.Length).TrimStart('\', '/') -replace '\\', '/'
        $table[$rel.ToLowerInvariant()] = [pscustomobject]@{
            Rel      = $rel
            Length   = $f.Length
            FullName = $f.FullName
        }
    }
    return $table
}

function Compare-BackupZip {
    <#
      Compares one backup zip with the current files of its mod. Reads the zip with
      ZipFile.OpenRead and hashes each entry's stream; nothing is extracted.
      Pass an empty table to list everything in the zip as removed.
    #>
    param([string] $ZipPath, [hashtable] $Current, [string] $Mod)

    $added   = New-Object System.Collections.Generic.List[string]
    $removed = New-Object System.Collections.Generic.List[string]
    $changed = New-Object System.Collections.Generic.List[string]
    $infoVersion  = $null
    $stateVersion = $null
    $seen = @{}

    $zip = $null
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        foreach ($e in $zip.Entries) {
            # Separators first, as in Expand-ModArchive: an archive may use either.
            $rel = ($e.FullName -replace '\\', '/').TrimStart('/')
            if (-not $rel -or $rel.EndsWith('/')) { continue }
            $leaf = ($rel -split '/')[-1]

            if ($rel -eq 'info.json' -or $rel -eq '.nexus-mod.json') {
                $sr = New-Object System.IO.StreamReader($e.Open())
                try { $text = $sr.ReadToEnd() } finally { $sr.Dispose() }
                $v = Get-JsonVersion -Text $text -Label "$Mod.zip:$rel"
                if ($rel -eq 'info.json') { $infoVersion = $v } else { $stateVersion = $v }
            }
            if ($leaf -eq '.nexus-mod.json') { continue }

            $key = $rel.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true

            if (-not $Current.ContainsKey($key)) { $removed.Add($rel); continue }

            $now = $Current[$key]
            if ($e.Length -ne $now.Length) { $changed.Add($now.Rel); continue }

            $s = $e.Open()
            try { $old = [BitConverter]::ToString($sha.ComputeHash($s)) -replace '-', '' } finally { $s.Dispose() }
            $new = (Get-FileHash -LiteralPath $now.FullName -Algorithm SHA256).Hash
            if ($old -ne $new) { $changed.Add($now.Rel) }
        }
    } finally {
        if ($zip) { $zip.Dispose() }
        $sha.Dispose()
    }

    foreach ($key in $Current.Keys) {
        if (-not $seen.ContainsKey($key)) { $added.Add($Current[$key].Rel) }
    }

    $version = if ($infoVersion) { $infoVersion } else { $stateVersion }
    return [pscustomobject]@{
        OldVersion = $version
        Added      = @($added | Sort-Object)
        Removed    = @($removed | Sort-Object)
        Changed    = @($changed | Sort-Object)
    }
}

function Test-Selected {
    param([string] $Mod)
    if ($Only -and $Only -notcontains $Mod) { return $false }
    if ($Skip -and $Skip -contains $Mod)    { return $false }
    return $true
}

function Format-Version {
    param($Value, [string] $Missing = '?')
    if ($Value) { return "$Value" }
    return $Missing
}

# ----------------------------------------------------------------------------------
# Preconditions. All of them before any work, so a bad -OutFile costs nothing.
# ----------------------------------------------------------------------------------

$outFull = $null
if ($OutFile) {
    $outFull = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
    $ext = [System.IO.Path]::GetExtension($outFull).ToLowerInvariant()
    if ($ext -ne '.json' -and $ext -ne '.md') {
        throw "-OutFile must end in .json or .md, not '$ext'."
    }
    if (Test-Path -LiteralPath $outFull -PathType Container) {
        throw "-OutFile '$outFull' is a folder."
    }
    if ((Test-Path -LiteralPath $outFull) -and -not $Force) {
        throw "'$outFull' already exists. Pass -Force to overwrite it."
    }
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "No config at '$ConfigPath'. Create one with: .\darktide.ps1 init"
}
$cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

$modsRoot = ''
if ($cfg.PSObject.Properties.Name -contains 'ModsRoot' -and "$($cfg.ModsRoot)".Trim()) { $modsRoot = "$($cfg.ModsRoot)".Trim() }
if (-not $modsRoot) { throw "ModsRoot is not set in '$ConfigPath'." }
if (-not (Test-Path -LiteralPath $modsRoot -PathType Container)) { throw "ModsRoot '$modsRoot' does not exist." }
$modsRoot = (Resolve-Path -LiteralPath $modsRoot).Path

$backupRoot = ''
if ($cfg.PSObject.Properties.Name -contains 'BackupRoot' -and "$($cfg.BackupRoot)".Trim()) { $backupRoot = "$($cfg.BackupRoot)".Trim() }
if (-not $backupRoot) { $backupRoot = Join-Path (Split-Path -Parent $modsRoot) 'mod_backups' }

if ($outFull) {
    # A report inside staging would be deployed with the mods; one inside the backup
    # root sits among the sets that rollback and pruning walk. Neither is its place.
    if (Test-PathInside -Path $outFull -Root $modsRoot) {
        throw "-OutFile must not be inside the staging folder '$modsRoot'."
    }
    if (Test-PathInside -Path $outFull -Root $backupRoot) {
        throw "-OutFile must not be inside the backup root '$backupRoot'."
    }
}

if (-not (Test-Path -LiteralPath $backupRoot -PathType Container)) {
    throw "No backup root at '$backupRoot'. Nothing has been backed up yet: update -Apply makes a backup set when it replaces a mod."
}

$sets = @(Get-ChildItem -LiteralPath $backupRoot -Directory | Sort-Object Name)
if ($sets.Count -eq 0) {
    throw "No backup sets under '$backupRoot'. update -Apply makes one when it replaces a mod."
}

$set      = Resolve-BackupSet -Sets $sets -Name $BackupSet -BackupRoot $backupRoot
$setIndex = [Array]::IndexOf(@($sets | ForEach-Object { $_.Name }), $set.Name)
$isNewest = ($setIndex -eq $sets.Count - 1)
$setTime  = Get-SetTimeUtc -Dir $set
$nextTime = $null
if (-not $isNewest) { $nextTime = Get-SetTimeUtc -Dir $sets[$setIndex + 1] }

$undo = ".\darktide.ps1 rollback -BackupSet $($set.Name) -Apply"

Write-Step "Changes recorded by backup set $($set.Name)"
Write-Host "  backup set : $($set.FullName)"
Write-Host "  taken      : $($setTime.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "  staging    : $modsRoot"
if (-not $isNewest) {
    Write-Warn "  This is not the newest set ($($sets[-1].Name) is). Staging as it is now includes every update since, so later changes show here too."
}

# ----------------------------------------------------------------------------------
# Compare
# ----------------------------------------------------------------------------------

$zips = @(Get-ChildItem -LiteralPath $set.FullName -File | Where-Object { $_.Extension -eq '.zip' } | Sort-Object Name)
$zipNames = @($zips | ForEach-Object { $_.BaseName })

$results = New-Object System.Collections.Generic.List[object]

foreach ($z in $zips) {
    $mod = $z.BaseName
    if (-not (Test-Selected -Mod $mod)) { continue }

    $folder = Join-Path $modsRoot $mod
    $hasFolder = Test-Path -LiteralPath $folder -PathType Container
    $current = @{}
    $newVersion = $null
    if ($hasFolder) {
        $current    = Get-StagingFiles -Path $folder
        $newVersion = Get-FolderVersion -Path $folder -Mod $mod
    }

    try {
        $cmp = Compare-BackupZip -ZipPath $z.FullName -Current $current -Mod $mod
    } catch {
        Write-Warn "  $mod : cannot read $($z.Name): $($_.Exception.Message)"
        $results.Add([pscustomobject]@{
            Mod = $mod; Status = 'UNREADABLE'; Old = $null; New = $newVersion
            Added = @(); Removed = @(); Changed = @()
        })
        continue
    }

    $status = if (-not $hasFolder) {
        'REMOVED'
    } elseif (($cmp.Added.Count + $cmp.Removed.Count + $cmp.Changed.Count) -gt 0) {
        'CHANGED'
    } else {
        'UNCHANGED'
    }

    $results.Add([pscustomobject]@{
        Mod     = $mod
        Status  = $status
        Old     = $cmp.OldVersion
        New     = $newVersion
        Added   = @($cmp.Added)
        Removed = @($cmp.Removed)
        Changed = @($cmp.Changed)
    })
}

# Mods installed by this run that had nothing to back up. 'base' is the loader's, not
# a mod, and dot-folders are crash leftovers - the updater skips both too.
foreach ($dir in @(Get-ChildItem -LiteralPath $modsRoot -Directory | Sort-Object Name)) {
    if ($dir.Name.StartsWith('.') -or $dir.Name -eq 'base') { continue }
    if ($zipNames -contains $dir.Name) { continue }
    if (-not (Test-Selected -Mod $dir.Name)) { continue }

    $installed = Get-InstallTimeUtc -Dir $dir
    if ($installed -lt $setTime) { continue }
    if ($null -ne $nextTime -and $installed -ge $nextTime) { continue }

    $files = Get-StagingFiles -Path $dir.FullName
    $results.Add([pscustomobject]@{
        Mod     = $dir.Name
        Status  = 'NEW'
        Old     = $null
        New     = (Get-FolderVersion -Path $dir.FullName -Mod $dir.Name)
        Added   = @($files.Values | ForEach-Object { $_.Rel } | Sort-Object)
        Removed = @()
        Changed = @()
    })
}

$rows = @($results | Sort-Object Mod)

if ($Only) {
    $reported = @($rows | ForEach-Object { $_.Mod })
    $missing  = @($Only | Where-Object { $reported -notcontains $_ })
    if ($missing) { Write-Warn "  Not in this backup set and not new since it: $($missing -join ', ')" }
}

# ----------------------------------------------------------------------------------
# Console report
# ----------------------------------------------------------------------------------

Write-Host ''
if ($rows.Count -eq 0) {
    Write-Ok 'Nothing to report: no backed-up or newly installed mod matched.'
} else {
    $rows | ForEach-Object {
        [pscustomobject]@{
            Mod    = $_.Mod
            Status = $_.Status
            Old    = Format-Version $_.Old $(if ($_.Status -eq 'NEW') { '-' } else { '?' })
            New    = Format-Version $_.New $(if ($_.Status -eq 'REMOVED') { '-' } else { '?' })
            '+'    = $_.Added.Count
            '-'    = $_.Removed.Count
            '~'    = $_.Changed.Count
        }
    } | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

    foreach ($r in $rows) {
        $lines = @()
        $lines += @($r.Added   | ForEach-Object { "  + $_" })
        $lines += @($r.Removed | ForEach-Object { "  - $_" })
        $lines += @($r.Changed | ForEach-Object { "  ~ $_" })
        if ($lines.Count -eq 0) { continue }

        $old = Format-Version $r.Old '-'
        $new = Format-Version $r.New '-'
        Write-Step "$($r.Mod)  [$($r.Status)]  $old -> $new"
        $lines | Select-Object -First $script:ListCap | ForEach-Object { Write-Host $_ }
        if ($lines.Count -gt $script:ListCap) {
            $more = $lines.Count - $script:ListCap
            if ($outFull) { Write-Host "  ... and $more more, listed in $outFull" }
            else          { Write-Host "  ... and $more more. Pass -OutFile changes.md for the full list." }
        }
        Write-Host ''
    }
}

$count = @{}
foreach ($s in @('CHANGED', 'UNCHANGED', 'NEW', 'REMOVED', 'UNREADABLE')) {
    $count[$s] = @($rows | Where-Object { $_.Status -eq $s }).Count
}
Write-Host ("{0} mod(s): {1} changed, {2} unchanged, {3} new, {4} removed{5}." -f $rows.Count,
    $count['CHANGED'], $count['UNCHANGED'], $count['NEW'], $count['REMOVED'],
    $(if ($count['UNREADABLE']) { ", $($count['UNREADABLE']) unreadable" } else { '' }))
if ($count['UNREADABLE']) { Write-Warn 'An unreadable backup zip cannot be compared, and rollback may not be able to restore it either.' }

Write-Host ''
if ($zips.Count -gt 0) {
    Write-Host 'To undo this update in staging, then push the old copies to the game:'
    Write-Host "  $undo"
    Write-Host '  .\darktide.ps1 deploy -Apply'
    if ($Only -or $Skip) { Write-Warn '  rollback restores every mod in the set, not only the ones shown here.' }
    if ($count['NEW'])   { Write-Warn '  rollback does not remove mods marked NEW; they had no earlier copy to restore.' }
    # The same name guard Invoke-Rollback applies before it deletes a mod folder.
    # A zip it refuses is one the undo above will not restore, so say so here.
    $refused = @($zipNames | Where-Object {
        [string]::IsNullOrWhiteSpace($_) -or $_ -in @('.', '..', 'base', 'mods') -or $_ -match '[\\/:*?"<>|\[\]]'
    })
    if ($refused) { Write-Warn "  rollback skips these names and will not restore them: $($refused -join ', ')" }
} else {
    Write-Warn 'This backup set holds no mod zips, so there is nothing for rollback to restore.'
}
Write-Host 'If the changes look right:  .\darktide.ps1 deploy -Apply'

# ----------------------------------------------------------------------------------
# -OutFile
# ----------------------------------------------------------------------------------

if ($outFull) {
    $parent = Split-Path -Parent $outFull
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }

    if ($outFull.ToLowerInvariant().EndsWith('.json')) {
        $mods = @($rows | ForEach-Object {
            [ordered]@{
                mod        = $_.Mod
                status     = $_.Status
                oldVersion = $_.Old
                newVersion = $_.New
                added      = @($_.Added)
                removed    = @($_.Removed)
                changed    = @($_.Changed)
            }
        })
        $report = [ordered]@{
            generatedAt  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            generatedBy  = 'Show-ModChanges.ps1'
            backupSet    = $set.Name
            backupSetDir = $set.FullName
            takenAt      = $setTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
            newestSet    = $isNewest
            modsRoot     = $modsRoot
            undo         = $(if ($zips.Count -gt 0) { $undo } else { $null })
            summary      = [ordered]@{
                mods       = $rows.Count
                changed    = $count['CHANGED']
                unchanged  = $count['UNCHANGED']
                new        = $count['NEW']
                removed    = $count['REMOVED']
                unreadable = $count['UNREADABLE']
            }
            mods         = $mods
        }
        ConvertTo-Json -InputObject $report -Depth 6 | Set-Content -LiteralPath $outFull -Encoding UTF8
    } else {
        $md = New-Object System.Collections.Generic.List[string]
        $md.Add("# Mod changes from backup set $($set.Name)")
        $md.Add('')
        $md.Add("- Backup set: ``$($set.FullName)``")
        $md.Add("- Taken: $($setTime.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss'))")
        $md.Add("- Staging: ``$modsRoot``")
        if ($zips.Count -gt 0) { $md.Add("- Undo: ``$undo``, then ``.\darktide.ps1 deploy -Apply``") }
        if (-not $isNewest) { $md.Add("- Not the newest set: later updates are included in the comparison.") }
        $md.Add('')
        $md.Add('| Mod | Status | Old | New | + | - | ~ |')
        $md.Add('|---|---|---|---|---|---|---|')
        foreach ($r in $rows) {
            $md.Add("| $($r.Mod) | $($r.Status) | $(Format-Version $r.Old '-') | $(Format-Version $r.New '-') | $($r.Added.Count) | $($r.Removed.Count) | $($r.Changed.Count) |")
        }
        foreach ($r in $rows) {
            if (($r.Added.Count + $r.Removed.Count + $r.Changed.Count) -eq 0) { continue }
            $md.Add('')
            $md.Add("## $($r.Mod) ($(Format-Version $r.Old '-') -> $(Format-Version $r.New '-'))")
            foreach ($part in @(@{ T = 'Added'; L = $r.Added }, @{ T = 'Removed'; L = $r.Removed }, @{ T = 'Changed'; L = $r.Changed })) {
                if (@($part.L).Count -eq 0) { continue }
                $md.Add('')
                $md.Add("$($part.T):")
                $md.Add('')
                foreach ($f in $part.L) { $md.Add("- ``$f``") }
            }
        }
        Set-Content -LiteralPath $outFull -Value $md -Encoding UTF8
    }
    Write-Host ''
    Write-Ok "Wrote $outFull"
}

exit 0
