<#
.SYNOPSIS
    Compares two loadouts and says how they differ. Read-only.

.DESCRIPTION
    Each side is a lockfile, from one of four places:

        <path>.json   a lockfile on disk
        <path>.zip    a loadout archive made by 'darktide.ps1 export'. Only the
                      darktide-modpack.lock.json at the root of the archive is read,
                      straight out of the zip. Nothing is extracted.
        git:<rev>     the repository's lockfile as committed at <rev>, read with
                      'git cat-file'. Nothing is checked out, so the working tree and
                      the index are never touched.
        current       what is in staging right now. A lockfile is generated into a
                      temporary file with New-ModpackLock.ps1 -OutFile, read, and
                      deleted. The repository's own lockfile is never written.

    With no arguments the left side is the repository lockfile and the right side is
    'current', which answers "how does what I have differ from what I locked".

    What it reports, per mod folder:

        added / removed     present on one side only
        version             both versions known and different, compared component
                            by component, so '1.0' and '1.0.0' are the same version
        content             the content hash differs while the version is the same
                            or unknown: the mod was changed in place
        mod id, url, name   the recorded Nexus id, page or display name differs
        load order          entries added to or removed from mod_load_order.txt, and
                            entries that genuinely moved. A move is judged by
                            relative order (the longest run of entries that kept
                            their order stays put), so inserting one mod does not
                            report every mod after it as moved.

    A null on either side is unknown, not a change. Most mods in this setup have no
    recorded version, so 'null -> 2.0' is reported as 'now known' and '2.0 -> null'
    as 'now unknown'. Both are informational and do not make the loadouts count as
    different. The same goes for a null content hash, id, url or name.

    Both inputs are treated as untrusted: at most 512 KB, valid JSON, schemaVersion 1,
    a mods array of objects with a folder name, no duplicate folders. Anything else is
    refused with the reason. Control characters in names are replaced before they
    reach the console.

.PARAMETER Left
    The baseline. A lockfile path, a loadout .zip, git:<rev>, or current. Defaults to
    the repository lockfile (-LockPath). The words are matched first, so a file that
    is really called 'current' is given as .\current.

.PARAMETER Right
    What to compare against the baseline. Same forms as -Left. Defaults to current.

.PARAMETER LockPath
    The repository lockfile, used when -Left is not given. Never written.

.PARAMETER ConfigPath
    config.json, read only for a 'current' side, to find ModsRoot.

.PARAMETER StagingMods
    The staging mods folder for a 'current' side. Overrides ModsRoot from config.json,
    and means no config is needed.

.PARAMETER MapPath
    mods-map.json, passed to New-ModpackLock.ps1 when building the 'current' side, so
    it records the same Nexus ids 'darktide.ps1 lock' would.

.PARAMETER NoHash
    Do not hash staging for a 'current' side. Faster, but in-place content changes
    cannot be seen; every mod's content is then reported as unknown.

.PARAMETER OutFile
    Also write the result to a file. A .json name writes the full result with stable
    keys (every list present, empty when nothing changed); a .md name writes a
    markdown table. Refuses to overwrite an existing file without -Force, and refuses
    to write over either input.

.PARAMETER Force
    Overwrite an existing -OutFile.

.EXAMPLE
    .\Compare-DarktideLoadout.ps1
    How staging differs from the committed lockfile.

.EXAMPLE
    .\Compare-DarktideLoadout.ps1 -Left git:HEAD~5 -Right git:HEAD
    What the last five commits changed in the lockfile.

.EXAMPLE
    .\Compare-DarktideLoadout.ps1 -Left 'E:\darktide-loadout-20260829.zip' -Right current
    How staging differs from a loadout you exported earlier.

.EXAMPLE
    .\Compare-DarktideLoadout.ps1 -Left old.lock.json -Right new.lock.json -OutFile diff.json -Force

.NOTES
    Exit codes: 0 when the two loadouts are identical, 1 when they differ. A loadout
    that cannot be read is a terminating error, which also ends non-zero, so a script
    that needs to tell "different" from "could not compare" should check for the
    error, or use -OutFile and check the file was written.

    Writes nothing except -OutFile and the temporary lockfile for 'current', which is
    deleted before the script returns.
#>

[CmdletBinding()]
param(
    [string] $Left,
    [string] $Right,
    [string] $LockPath   = (Join-Path $PSScriptRoot 'darktide-modpack.lock.json'),
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string] $StagingMods,
    [string] $MapPath    = (Join-Path $PSScriptRoot 'mods-map.json'),
    [switch] $NoHash,
    [string] $OutFile,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue

$script:MaxLockBytes = 512KB
$script:LockEntry    = 'darktide-modpack.lock.json'

function Write-Step { param([string]$m) Write-Host $m -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host $m -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host $m -ForegroundColor Yellow }

function Get-SafeText {
    <# Untrusted text for the console: control characters (ANSI escapes included) become '?'. #>
    param($Value)
    if ($null -eq $Value) { return '' }
    return ("$Value" -replace '[\x00-\x1F\x7F]', '?')
}

function Get-VersionComparison {
    <#
        'same', 'differs', or why neither can be said.

        Copied from Find-ModUpdates.ps1, not shared: each script here stands alone.
        Compared component by component, the way Compare-ModVersion in
        Update-DarktideMods.ps1 does, so 'v2.15.0' and '2.15.0' agree and '1.0' and
        'v1.0.0' agree. Not by joining the digits: that made '2.1.44' and '2.14.4'
        the same string, and 'same' is the answer that stops someone looking.

        It deliberately does not rank them. Anything not plainly equal is a
        difference for a person to look at.
    #>
    param([string] $Installed, [string] $Tag)

    if (-not $Tag)       { return 'no release tag' }
    if (-not $Installed) { return 'no local version' }

    $na = @([regex]::Matches($Installed, '\d+') | ForEach-Object { [int64]$_.Value })
    $nb = @([regex]::Matches($Tag,       '\d+') | ForEach-Object { [int64]$_.Value })
    if ($na.Count -eq 0 -or $nb.Count -eq 0) {
        return $(if ($Installed.Trim() -eq $Tag.Trim()) { 'same' } else { 'differs' })
    }

    $len = [Math]::Max($na.Count, $nb.Count)
    for ($i = 0; $i -lt $len; $i++) {
        $x = if ($i -lt $na.Count) { $na[$i] } else { 0 }
        $y = if ($i -lt $nb.Count) { $nb[$i] } else { 0 }
        if ($x -ne $y) { return 'differs' }
    }

    # Same numbers, but '2.14.4-beta' is not the release '2.14.4'. Whatever follows
    # the last digit is the pre-release marker, if there is one.
    $tailA = ($Installed -replace '^.*\d', '') -replace '[^A-Za-z0-9]', ''
    $tailB = ($Tag       -replace '^.*\d', '') -replace '[^A-Za-z0-9]', ''
    if ($tailA -ne $tailB) { return 'differs' }
    return 'same'
}

function ConvertFrom-LockBytes {
    <# UTF-8 bytes (BOM or not) to text, refusing anything over the size cap. #>
    param([byte[]] $Bytes, [string] $Label)

    if ($Bytes.Length -gt $script:MaxLockBytes) {
        throw "$Label is larger than $($script:MaxLockBytes / 1KB) KB - not a lockfile this tool will read."
    }
    $text = (New-Object System.Text.UTF8Encoding($false)).GetString($Bytes)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    return $text
}

function Read-BoundedStream {
    <# Reads at most MaxLockBytes + 1 bytes, so an archive header that lies about size cannot balloon memory. #>
    param([System.IO.Stream] $Stream)

    $limit = $script:MaxLockBytes + 1
    $buffer = New-Object byte[] $limit
    $total = 0
    while ($total -lt $limit) {
        $n = $Stream.Read($buffer, $total, $limit - $total)
        if ($n -le 0) { break }
        $total += $n
    }
    $result = New-Object byte[] $total
    [Array]::Copy($buffer, $result, $total)
    return ,$result
}

function Read-LockFromFile {
    param([string] $Path, [string] $Label)

    $item = Get-Item -LiteralPath $Path
    if ($item.Length -gt $script:MaxLockBytes) {
        throw "$Label is larger than $($script:MaxLockBytes / 1KB) KB - not a lockfile this tool will read."
    }
    return ConvertFrom-LockBytes -Bytes ([System.IO.File]::ReadAllBytes($item.FullName)) -Label $Label
}

function Read-LockFromZip {
    <#
        The lockfile at the root of a loadout archive, read from the entry without
        extracting anything. Entry names are normalised ('\' to '/') before they are
        compared, and only the exact root name matches, so 'sub/...' or '../...'
        never does.
    #>
    param([string] $Path, [string] $Label)

    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    } catch {
        throw "$Label is not a readable zip archive: $($_.Exception.Message)"
    }
    try {
        $hits = @($zip.Entries | Where-Object {
            [string]::Equals(($_.FullName -replace '\\', '/'), $script:LockEntry,
                             [StringComparison]::OrdinalIgnoreCase)
        })
        if ($hits.Count -eq 0) {
            throw "$Label has no $($script:LockEntry) at its root. Was it exported with -NoManifest?"
        }
        if ($hits.Count -gt 1) {
            throw "$Label has $($hits.Count) entries named $($script:LockEntry) - refusing to guess which one is real."
        }
        $entry = $hits[0]
        if ($entry.Length -gt $script:MaxLockBytes) {
            throw "$Label : $($script:LockEntry) is larger than $($script:MaxLockBytes / 1KB) KB - not a lockfile this tool will read."
        }
        $stream = $entry.Open()
        try { $bytes = Read-BoundedStream -Stream $stream } finally { $stream.Dispose() }
        return ConvertFrom-LockBytes -Bytes $bytes -Label "$Label ($($script:LockEntry))"
    } finally {
        $zip.Dispose()
    }
}

function Read-LockFromGit {
    <#
        The lockfile as committed at a revision. 'git cat-file blob' prints the
        stored bytes and nothing else: no checkout, no index update, no textconv
        filter, no pager. Run through Process rather than '& git' so the bytes come
        back as UTF-8 regardless of the console code page, and so the read can stop
        at the size cap.
    #>
    param([string] $Rev, [string] $Label)

    if (-not $Rev) { throw "$Label : give a revision after 'git:', e.g. git:HEAD or git:main." }
    # A revision starting with '-' would be read as an option. Everything else a
    # normal ref, hash or reflog spec uses is in this set.
    if ($Rev.StartsWith('-') -or $Rev -notmatch '^[A-Za-z0-9_./~^@{}-]+$') {
        throw "$Label : '$(Get-SafeText $Rev)' does not look like a git revision."
    }

    $git = Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if (-not $git) {
        throw "$Label needs git, and git is not on PATH. Install Git for Windows, or compare a lockfile or zip instead."
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $git.Path
    # './' resolves against the working directory, which is this script's folder, so
    # the path is right even when the scripts live in a subfolder of a larger repo.
    $psi.Arguments              = "--no-pager cat-file blob `"$($Rev):./$($script:LockEntry)`""
    $psi.WorkingDirectory       = $PSScriptRoot
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
        $errTask = $proc.StandardError.ReadToEndAsync()
        $bytes = Read-BoundedStream -Stream $proc.StandardOutput.BaseStream
        if ($bytes.Length -gt $script:MaxLockBytes) {
            try { $proc.Kill() } catch { Write-Verbose "git already exited: $($_.Exception.Message)" }
            throw "$Label is larger than $($script:MaxLockBytes / 1KB) KB - not a lockfile this tool will read."
        }
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) {
            $why = @("$($errTask.Result)" -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -First 1
            if (-not $why) { $why = "git exited $($proc.ExitCode)" }
            throw "$Label : git could not read $($script:LockEntry) at that revision: $(Get-SafeText $why)"
        }
        return ConvertFrom-LockBytes -Bytes $bytes -Label $Label
    } finally {
        $proc.Dispose()
    }
}

function Read-LockFromStaging {
    <#
        Generates a lockfile from staging into a temporary file and reads it back.
        -OutFile is always passed: New-ModpackLock.ps1 otherwise writes the
        repository lockfile, which this script must never change.
    #>
    param([string] $Label, [hashtable] $Options)

    $staging    = $Options.StagingMods
    $configPath = $Options.ConfigPath
    if (-not $staging) {
        if (-not $configPath -or -not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
            throw "'current' needs your staging folder, and there is no config at '$configPath'. Run .\darktide.ps1 init, or pass -StagingMods."
        }
        $cfg = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg -and $cfg.PSObject.Properties.Name -contains 'ModsRoot' -and "$($cfg.ModsRoot)".Trim()) {
            $staging = "$($cfg.ModsRoot)"
        }
    }
    if (-not $staging) { throw "'current' needs your staging folder: ModsRoot is not set in config.json. Pass -StagingMods." }
    if (-not (Test-Path -LiteralPath $staging -PathType Container)) {
        throw "Staging mods folder '$staging' does not exist."
    }

    $locker = Join-Path $PSScriptRoot 'New-ModpackLock.ps1'
    if (-not (Test-Path -LiteralPath $locker -PathType Leaf)) { throw "Missing script: $locker" }

    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ('dt-diff-' + [guid]::NewGuid().ToString('N').Substring(0, 12) + '.lock.json')
    $noHash = [bool]$Options.NoHash
    Write-Step "Reading staging: $staging$(if ($noHash) { ' (no hashing)' } else { ' (hashing every mod, this can take a moment)' })"
    try {
        & $locker -ModsRoot $staging -OutFile $temp -MapPath $Options.MapPath -NoHash:$noHash 6>$null | Out-Null
        if (-not (Test-Path -LiteralPath $temp -PathType Leaf)) {
            throw "New-ModpackLock.ps1 did not write a lockfile for '$staging'."
        }
        return Read-LockFromFile -Path $temp -Label $Label
    } finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-LoadoutSource {
    <# Works out what a -Left/-Right value names and returns the lockfile text plus a label. #>
    param([string] $Spec, [string] $Side, [hashtable] $CurrentOptions)

    if ($Spec -eq 'current') {
        $label = "$Side (current staging)"
        return @{ Kind = 'current'; Label = $label; Path = $null; Text = (Read-LockFromStaging -Label $label -Options $CurrentOptions) }
    }
    if ($Spec -match '^git:(.*)$') {
        $rev = $Matches[1]
        $label = "$Side (git:$(Get-SafeText $rev))"
        return @{ Kind = 'git'; Label = $label; Path = $null; Text = (Read-LockFromGit -Rev $rev -Label $label) }
    }

    if (Test-Path -LiteralPath $Spec -PathType Container) {
        throw "$Side '$Spec' is a folder. Give a lockfile, a loadout .zip, git:<rev>, or current."
    }
    if (-not (Test-Path -LiteralPath $Spec -PathType Leaf)) {
        throw "$Side '$Spec' does not exist. Give a lockfile, a loadout .zip, git:<rev>, or current."
    }
    # [System.IO] resolves relative paths against the process directory, not the
    # PowerShell location, so resolve here first.
    $full = (Resolve-Path -LiteralPath $Spec).ProviderPath
    if ([System.IO.Path]::GetExtension($full) -ieq '.zip') {
        $label = "$Side (zip $full)"
        return @{ Kind = 'zip'; Label = $label; Path = $full; Text = (Read-LockFromZip -Path $full -Label $label) }
    }
    $label = "$Side ($full)"
    return @{ Kind = 'lockfile'; Label = $label; Path = $full; Text = (Read-LockFromFile -Path $full -Label $label) }
}

function Get-ScalarField {
    <# A mod's field as a string, or $null when it is missing, null or blank. Objects and arrays are malformed. #>
    param($Object, [string] $Name, [string] $Label)

    if ($Object.PSObject.Properties.Name -notcontains $Name) { return $null }
    $v = $Object.$Name
    if ($null -eq $v) { return $null }
    if (-not ($v -is [string] -or $v -is [ValueType])) {
        throw "$Label : field '$Name' of mod '$(Get-SafeText $Object.folder)' is not a plain value."
    }
    $s = "$v".Trim()
    if (-not $s) { return $null }
    return $s
}

function ConvertTo-Loadout {
    <#
        Validates untrusted lockfile text and reduces it to what the comparison
        needs: a case-insensitive table of mods by folder, and the load order.
    #>
    param([string] $Text, [string] $Label)

    if (-not $Text -or -not $Text.Trim()) { throw "$Label is empty." }
    try {
        $lock = $Text | ConvertFrom-Json
    } catch {
        throw "$Label is not valid JSON: $($_.Exception.Message)"
    }
    if (-not ($lock -is [System.Management.Automation.PSCustomObject])) {
        throw "$Label is not a lockfile: the top level is not a JSON object."
    }

    $names = @($lock.PSObject.Properties.Name)
    if ($names -notcontains 'schemaVersion') { throw "$Label has no schemaVersion - not a lockfile this tool understands." }
    $sv = $lock.schemaVersion
    if (-not (($sv -is [int] -or $sv -is [long]) -and $sv -eq 1)) {
        throw "$Label has schemaVersion '$(Get-SafeText $sv)'; only 1 is understood."
    }

    if ($names -notcontains 'mods' -or -not ($lock.mods -is [System.Array])) {
        throw "$Label has no mods array."
    }

    $mods = @{}
    foreach ($m in $lock.mods) {
        if (-not ($m -is [System.Management.Automation.PSCustomObject])) {
            throw "$Label : an entry in mods is not an object."
        }
        $folder = $null
        if ($m.PSObject.Properties.Name -contains 'folder' -and $m.folder -is [string]) { $folder = $m.folder.Trim() }
        if (-not $folder) { throw "$Label : a mod entry has no folder name." }
        if ($mods.ContainsKey($folder)) { throw "$Label lists the mod folder '$(Get-SafeText $folder)' twice." }

        $mods[$folder] = [pscustomobject]@{
            folder        = $folder
            name          = Get-ScalarField -Object $m -Name 'name'          -Label $Label
            modId         = Get-ScalarField -Object $m -Name 'modId'         -Label $Label
            version       = Get-ScalarField -Object $m -Name 'version'       -Label $Label
            url           = Get-ScalarField -Object $m -Name 'url'           -Label $Label
            contentSha256 = Get-ScalarField -Object $m -Name 'contentSha256' -Label $Label
        }
    }

    $order = New-Object System.Collections.Generic.List[string]
    if ($names -contains 'loadOrder' -and $null -ne $lock.loadOrder) {
        if (-not ($lock.loadOrder -is [System.Array])) { throw "$Label : loadOrder is not an array." }
        $seen = @{}
        foreach ($e in $lock.loadOrder) {
            if (-not ($e -is [string])) { throw "$Label : loadOrder holds something that is not a folder name." }
            $t = $e.Trim()
            # A repeated entry loads once; keep its first position.
            if (-not $t -or $seen.ContainsKey($t)) { continue }
            $seen[$t] = $true
            $order.Add($t)
        }
    }

    return [pscustomobject]@{ Mods = $mods; LoadOrder = $order.ToArray() }
}

function Get-KeptByRelativeOrder {
    <#
        Marks the entries of $Sequence that belong to one longest strictly
        increasing subsequence. Fed the right-hand positions of the shared load
        order entries in left-hand order, the marked entries are the ones that kept
        their relative order; everything unmarked genuinely moved. O(n log n).
    #>
    param([int[]] $Sequence)

    $n = $Sequence.Length
    $keep = New-Object bool[] $n
    if ($n -eq 0) { return ,$keep }

    $tails = New-Object System.Collections.Generic.List[int]
    $prev = New-Object int[] $n
    for ($i = 0; $i -lt $n; $i++) {
        $v = $Sequence[$i]
        $lo = 0
        $hi = $tails.Count
        while ($lo -lt $hi) {
            $mid = ($lo + $hi) -shr 1
            if ($Sequence[$tails[$mid]] -lt $v) { $lo = $mid + 1 } else { $hi = $mid }
        }
        $prev[$i] = if ($lo -gt 0) { $tails[$lo - 1] } else { -1 }
        if ($lo -eq $tails.Count) { $tails.Add($i) } else { $tails[$lo] = $i }
    }

    $k = $tails[$tails.Count - 1]
    while ($k -ge 0) {
        $keep[$k] = $true
        $k = $prev[$k]
    }
    return ,$keep
}

function Compare-Loadout {
    <# The whole comparison as an ordered structure whose keys are always present. #>
    param($L, $R)

    $added          = New-Object System.Collections.Generic.List[object]
    $removed        = New-Object System.Collections.Generic.List[object]
    $versionChanged = New-Object System.Collections.Generic.List[object]
    $contentChanged = New-Object System.Collections.Generic.List[object]
    $modIdChanged   = New-Object System.Collections.Generic.List[object]
    $urlChanged     = New-Object System.Collections.Generic.List[object]
    $nameChanged    = New-Object System.Collections.Generic.List[object]
    $nowKnown       = New-Object System.Collections.Generic.List[object]
    $nowUnknown     = New-Object System.Collections.Generic.List[object]

    $all = @(@($L.Mods.Keys) + @($R.Mods.Keys) | Sort-Object -Unique)
    foreach ($folder in $all) {
        $a = if ($L.Mods.ContainsKey($folder)) { $L.Mods[$folder] } else { $null }
        $b = if ($R.Mods.ContainsKey($folder)) { $R.Mods[$folder] } else { $null }

        if (-not $a) {
            $added.Add([ordered]@{ folder = $b.folder; name = $b.name; modId = $b.modId; version = $b.version })
            continue
        }
        if (-not $b) {
            $removed.Add([ordered]@{ folder = $a.folder; name = $a.name; modId = $a.modId; version = $a.version })
            continue
        }

        # null on either side is unknown: never a change, only 'now known' / 'now unknown'.
        foreach ($field in @('name', 'modId', 'version', 'url', 'contentSha256')) {
            $x = $a.$field
            $y = $b.$field
            if ($null -eq $x -and $null -ne $y) { $nowKnown.Add([ordered]@{ folder = $a.folder; field = $field; value = $y }) }
            if ($null -ne $x -and $null -eq $y) { $nowUnknown.Add([ordered]@{ folder = $a.folder; field = $field; was = $x }) }
        }

        $versionDiffers = $false
        if ($null -ne $a.version -and $null -ne $b.version) {
            if ((Get-VersionComparison -Installed $a.version -Tag $b.version) -eq 'differs') {
                $versionDiffers = $true
                $versionChanged.Add([ordered]@{ folder = $a.folder; from = $a.version; to = $b.version })
            }
        }

        # A new version is expected to bring new content; only a hash that moved
        # under the same (or an unknown) version is a change in place.
        if (-not $versionDiffers -and $null -ne $a.contentSha256 -and $null -ne $b.contentSha256 -and
            -not [string]::Equals($a.contentSha256, $b.contentSha256, [StringComparison]::OrdinalIgnoreCase)) {
            $contentChanged.Add([ordered]@{ folder = $a.folder; version = $(if ($null -ne $b.version) { $b.version } else { $a.version }) })
        }

        if ($null -ne $a.modId -and $null -ne $b.modId -and $a.modId -ne $b.modId) {
            $modIdChanged.Add([ordered]@{ folder = $a.folder; from = $a.modId; to = $b.modId })
        }
        if ($null -ne $a.url -and $null -ne $b.url -and $a.url -ne $b.url) {
            $urlChanged.Add([ordered]@{ folder = $a.folder; from = $a.url; to = $b.url })
        }
        if ($null -ne $a.name -and $null -ne $b.name -and -not [string]::Equals($a.name, $b.name, [StringComparison]::Ordinal)) {
            $nameChanged.Add([ordered]@{ folder = $a.folder; from = $a.name; to = $b.name })
        }
    }

    # ---- load order ----
    $lPos = @{}
    for ($i = 0; $i -lt $L.LoadOrder.Length; $i++) { $lPos[$L.LoadOrder[$i]] = $i }
    $rPos = @{}
    for ($i = 0; $i -lt $R.LoadOrder.Length; $i++) { $rPos[$R.LoadOrder[$i]] = $i }

    $orderAdded   = New-Object System.Collections.Generic.List[object]
    $orderRemoved = New-Object System.Collections.Generic.List[object]
    $orderMoved   = New-Object System.Collections.Generic.List[object]

    for ($i = 0; $i -lt $R.LoadOrder.Length; $i++) {
        $e = $R.LoadOrder[$i]
        if (-not $lPos.ContainsKey($e)) { $orderAdded.Add([ordered]@{ folder = $e; position = $i + 1 }) }
    }
    $shared = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $L.LoadOrder.Length; $i++) {
        $e = $L.LoadOrder[$i]
        if ($rPos.ContainsKey($e)) { $shared.Add($e) }
        else { $orderRemoved.Add([ordered]@{ folder = $e; position = $i + 1 }) }
    }
    $seq = New-Object int[] $shared.Count
    for ($i = 0; $i -lt $shared.Count; $i++) { $seq[$i] = $rPos[$shared[$i]] }
    $keep = Get-KeptByRelativeOrder -Sequence $seq
    for ($i = 0; $i -lt $shared.Count; $i++) {
        if (-not $keep[$i]) {
            $e = $shared[$i]
            $orderMoved.Add([ordered]@{ folder = $e; from = $lPos[$e] + 1; to = $rPos[$e] + 1 })
        }
    }

    $different = ($added.Count + $removed.Count + $versionChanged.Count + $contentChanged.Count +
                  $modIdChanged.Count + $urlChanged.Count + $nameChanged.Count +
                  $orderAdded.Count + $orderRemoved.Count + $orderMoved.Count) -gt 0

    return [ordered]@{
        identical      = (-not $different)
        added          = $added.ToArray()
        removed        = $removed.ToArray()
        versionChanged = $versionChanged.ToArray()
        contentChanged = $contentChanged.ToArray()
        modIdChanged   = $modIdChanged.ToArray()
        urlChanged     = $urlChanged.ToArray()
        nameChanged    = $nameChanged.ToArray()
        loadOrder      = [ordered]@{
            added   = $orderAdded.ToArray()
            removed = $orderRemoved.ToArray()
            moved   = $orderMoved.ToArray()
        }
        nowKnown       = $nowKnown.ToArray()
        nowUnknown     = $nowUnknown.ToArray()
    }
}

function Get-DiffRows {
    <# One row per reported fact, for the console table and the markdown. Raw values; callers escape. #>
    param($Diff)

    $rows = New-Object System.Collections.Generic.List[object]
    function Add-Row { param($Change, $Mod, $L, $R)
        $rows.Add([pscustomobject]@{ Change = $Change; Mod = $Mod; Left = $L; Right = $R })
    }
    foreach ($x in $Diff.added)          { Add-Row 'added'          $x.folder ''                  $(if ($x.version) { $x.version } else { 'present' }) }
    foreach ($x in $Diff.removed)        { Add-Row 'removed'        $x.folder $(if ($x.version) { $x.version } else { 'present' }) '' }
    foreach ($x in $Diff.versionChanged) { Add-Row 'version'        $x.folder $x.from              $x.to }
    foreach ($x in $Diff.contentChanged) { Add-Row 'changed in place' $x.folder 'hash differs'     $(if ($x.version) { "same version $($x.version)" } else { 'version unknown' }) }
    foreach ($x in $Diff.modIdChanged)   { Add-Row 'mod id'         $x.folder $x.from              $x.to }
    foreach ($x in $Diff.urlChanged)     { Add-Row 'url'            $x.folder $x.from              $x.to }
    foreach ($x in $Diff.nameChanged)    { Add-Row 'name'           $x.folder $x.from              $x.to }
    foreach ($x in $Diff.loadOrder.added)   { Add-Row 'order: added'   $x.folder ''                "#$($x.position)" }
    foreach ($x in $Diff.loadOrder.removed) { Add-Row 'order: removed' $x.folder "#$($x.position)" '' }
    foreach ($x in $Diff.loadOrder.moved)   { Add-Row 'order: moved'   $x.folder "#$($x.from)"     "#$($x.to)" }
    foreach ($x in $Diff.nowKnown)       { Add-Row "$($x.field) now known"   $x.folder 'unknown' $x.value }
    foreach ($x in $Diff.nowUnknown)     { Add-Row "$($x.field) now unknown" $x.folder $x.was    'unknown' }
    return ,$rows.ToArray()
}

function ConvertTo-MarkdownCell {
    param($Value)
    $s = Get-SafeText $Value
    if (-not $s) { return '-' }
    return ($s -replace '\|', '\|' -replace '<', '&lt;' -replace '>', '&gt;')
}

# ---- Validate the request before doing any work ------------------------------------

$leftSpec  = if ($Left)  { $Left }  else { $LockPath }
$rightSpec = if ($Right) { $Right } else { 'current' }

$outKind = $null
if ($OutFile) {
    $ext = [System.IO.Path]::GetExtension($OutFile).ToLowerInvariant()
    switch ($ext) {
        '.json' { $outKind = 'json' }
        '.md'   { $outKind = 'md' }
        default { throw "-OutFile must end in .json or .md, not '$ext'." }
    }

    # The result must never land on top of something it was compared from; with
    # -Force that would quietly replace a lockfile with a diff. Checked before the
    # overwrite rule so the message does not point at -Force.
    $outFull = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
    foreach ($p in @($leftSpec, $rightSpec, $LockPath)) {
        if (-not $p -or $p -eq 'current' -or $p -match '^git:') { continue }
        $pFull = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p)
        if ([string]::Equals($pFull, $outFull, [StringComparison]::OrdinalIgnoreCase)) {
            throw "-OutFile '$OutFile' is one of the loadouts being compared. Write the result somewhere else."
        }
    }

    if ((Test-Path -LiteralPath $OutFile) -and -not $Force) {
        throw "'$OutFile' already exists. Pass -Force to overwrite."
    }
    $outParent = Split-Path -Parent $OutFile
    if ($outParent -and -not (Test-Path -LiteralPath $outParent -PathType Container)) {
        throw "The folder for -OutFile does not exist: '$outParent'."
    }
}

# ---- Read both sides ---------------------------------------------------------------

# Only a 'current' side reads these.
$currentOptions = @{ StagingMods = $StagingMods; ConfigPath = $ConfigPath; MapPath = $MapPath; NoHash = [bool]$NoHash }
$leftSrc  = Resolve-LoadoutSource -Spec $leftSpec  -Side 'left'  -CurrentOptions $currentOptions
$rightSrc = Resolve-LoadoutSource -Spec $rightSpec -Side 'right' -CurrentOptions $currentOptions
$leftLo   = ConvertTo-Loadout -Text $leftSrc.Text  -Label $leftSrc.Label
$rightLo  = ConvertTo-Loadout -Text $rightSrc.Text -Label $rightSrc.Label

$diff = Compare-Loadout -L $leftLo -R $rightLo
$rows = Get-DiffRows -Diff $diff

# ---- Report ------------------------------------------------------------------------

Write-Host ''
Write-Host "Left  : $(Get-SafeText $leftSrc.Label)  - $($leftLo.Mods.Count) mod(s)"
Write-Host "Right : $(Get-SafeText $rightSrc.Label)  - $($rightLo.Mods.Count) mod(s)"
Write-Host ''

if ($rows.Length -gt 0) {
    $rows | ForEach-Object {
        [pscustomobject]@{
            Change = $_.Change
            Mod    = Get-SafeText $_.Mod
            Left   = Get-SafeText $_.Left
            Right  = Get-SafeText $_.Right
        }
    } | Format-Table -AutoSize -Property Change, Mod, Left, Right | Out-String -Width 220 | Write-Host
}

$informational = $diff.nowKnown.Length + $diff.nowUnknown.Length
if ($diff.identical) {
    if ($informational -gt 0) {
        Write-Ok "Identical. $informational field(s) went between known and unknown, which is not a difference."
    } else {
        Write-Ok 'Identical.'
    }
} else {
    $changes = $rows.Length - $informational
    Write-Warn "Different: $changes change(s)."
}

$unhashed = @($leftLo.Mods.Values  | Where-Object { $null -eq $_.contentSha256 }).Count +
            @($rightLo.Mods.Values | Where-Object { $null -eq $_.contentSha256 }).Count
if ($unhashed -gt 0) {
    Write-Warn "$unhashed mod entr$(if ($unhashed -eq 1) { 'y has' } else { 'ies have' }) no content hash, so an in-place change to those cannot be seen."
}

if ($OutFile) {
    if ($outKind -eq 'json') {
        $doc = [ordered]@{
            schemaVersion = 1
            left          = [ordered]@{ source = $leftSpec;  kind = $leftSrc.Kind;  modCount = $leftLo.Mods.Count }
            right         = [ordered]@{ source = $rightSpec; kind = $rightSrc.Kind; modCount = $rightLo.Mods.Count }
        }
        foreach ($k in $diff.Keys) { $doc[$k] = $diff[$k] }
        ($doc | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $OutFile -Encoding UTF8
    } else {
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add('# Loadout diff')
        $lines.Add('')
        $lines.Add("- Left: $(ConvertTo-MarkdownCell $leftSrc.Label), $($leftLo.Mods.Count) mod(s)")
        $lines.Add("- Right: $(ConvertTo-MarkdownCell $rightSrc.Label), $($rightLo.Mods.Count) mod(s)")
        $lines.Add("- Result: $(if ($diff.identical) { 'identical' } else { 'different' })")
        $lines.Add('')
        if ($rows.Length -gt 0) {
            $lines.Add('| Change | Mod | Left | Right |')
            $lines.Add('|---|---|---|---|')
            foreach ($r in $rows) {
                $lines.Add("| $(ConvertTo-MarkdownCell $r.Change) | $(ConvertTo-MarkdownCell $r.Mod) | $(ConvertTo-MarkdownCell $r.Left) | $(ConvertTo-MarkdownCell $r.Right) |")
            }
        } else {
            $lines.Add('No differences.')
        }
        Set-Content -LiteralPath $OutFile -Value $lines -Encoding UTF8
    }
    Write-Host "Wrote $OutFile"
}

if ($diff.identical) { exit 0 }
exit 1
