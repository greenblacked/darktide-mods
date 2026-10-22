<#
.SYNOPSIS
    Compares a friend's lockfile with your staging folder and lists what you lack.

.DESCRIPTION
    A friend runs `.\darktide.ps1 lock -OutFile my-loadout.lock.json` and sends you
    that one JSON file. It is a manifest: folder names, versions, load order and a
    link to each author's Nexus page. It holds no mod files, so sharing it
    redistributes nothing.

    This script reads it and sorts every mod into one of four rows:

        MISSING    in their loadout, not in your staging. Shows the Nexus page from
                   their lockfile, or says there is no Nexus id to link to.
        DIFFERENT  you both have it, but the version or the content hash differs.
                   A value missing on either side is unknown, not different.
        PRESENT    you both have it and nothing known differs.
        EXTRA      you have it, they do not. Informational; nothing to do.

    Then it prints their load order with your missing mods marked, so you can see
    where each one goes in mod_load_order.txt.

    It never downloads anything and never touches the network. Getting the mods
    stays a browser click on each author's page.

    The lockfile came from someone else, so it is treated as untrusted input:

      - larger than 512 KB, not JSON, or not schemaVersion 1: refused outright.
      - a folder name with a path separator, '..', a wildcard, a character Windows
        does not allow in a file name, a control character, or a reserved device
        name: that entry is dropped and reported. Folder names from the file are
        never used to build a path; your staging is listed once and matched by name.
      - a url that is not a plain https://www.nexusmods.com/ link: dropped and
        reported. A numeric modId still produces a Nexus link.
      - a modId that is not a positive whole number: dropped and reported.
      - control characters in any text (names, versions) are replaced before
        printing, so a crafted file cannot send escape sequences to your terminal.

    Nothing is written except an -OutFile you ask for.

.PARAMETER Path
    The lockfile your friend sent, e.g. .\their-loadout.lock.json.

.PARAMETER ModsRoot
    Your staging mods folder. Defaults to ModsRoot from config.json.

.PARAMETER ConfigPath
    config.json to read ModsRoot from when -ModsRoot is not given.

.PARAMETER OutFile
    Also write the result. A path ending in .md writes a checklist with a link per
    missing mod, ready to click through; .json writes the same data for a script.
    Refuses to replace an existing file unless -Force is given.

.PARAMETER Force
    Allow -OutFile to replace a file that already exists.

.PARAMETER NoHash
    Do not hash your mod folders. Faster; DIFFERENT then rests on versions alone.

.EXAMPLE
    .\Get-LoadoutGap.ps1 -Path .\their-loadout.lock.json
    What you are missing compared with their loadout, and where it goes in the load order.

.EXAMPLE
    .\Get-LoadoutGap.ps1 -Path .\their-loadout.lock.json -OutFile need.md
    The same, plus a markdown checklist of Nexus links to work through.

.NOTES
    Exit code 0 when the comparison finished cleanly, whatever it found. Exit code
    1 when something in their lockfile had to be dropped (a rejected folder name,
    url or modId), so the list may be incomplete. A file that cannot be read as a
    lockfile at all is an error.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Path,

    [string] $ModsRoot,

    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config.json'),

    [string] $OutFile,

    [switch] $Force,

    [switch] $NoHash
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step { param([string] $Message) Write-Host $Message -ForegroundColor Cyan }
function Write-Ok   { param([string] $Message) Write-Host $Message -ForegroundColor Green }
function Write-Warn { param([string] $Message) Write-Host $Message -ForegroundColor Yellow }
function Write-Err  { param([string] $Message) Write-Host $Message -ForegroundColor Red }

$script:MaxLockBytes  = 512KB
$script:DefaultGame   = 'warhammer40kdarktide'
$script:IgnoreFolders = @('base')
$script:Problems      = New-Object System.Collections.Generic.List[object]

# C0 and C1 controls (C1 includes the single-byte CSI, 0x9B), DEL, and the Unicode
# bidirectional overrides that can make a name display as something it is not.
$script:UnsafeTextPattern = '[\u0000-\u001F\u007F-\u009F\u200E\u200F\u202A-\u202E\u2066-\u2069]'

function Get-SafeText {
    <#
        Text from the foreign lockfile, made safe to print: control and bidi
        characters replaced with '?', length capped. Non-strings become their
        string form first, so an object or array cannot slip past.
    #>
    param([AllowNull()] $Value, [int] $Max = 120)

    if ($null -eq $Value) { return '' }
    $s = [regex]::Replace("$Value", $script:UnsafeTextPattern, '?')
    if ($s.Length -gt $Max) { $s = $s.Substring(0, $Max) + '...' }
    return $s
}

function Test-SafeFolderName {
    <#
        $null when $Name is acceptable as a single mod folder name, otherwise the
        reason it is not. Runs before the value is used for anything at all.
    #>
    param([AllowNull()] $Name)

    if ($null -eq $Name)            { return 'missing' }
    if ($Name -isnot [string])      { return 'not a string' }
    if ($Name.Length -eq 0)         { return 'empty' }
    if ($Name.Length -gt 128)       { return 'longer than 128 characters' }
    if ($Name.Contains('..'))       { return "contains '..'" }
    if ($Name -match '[\\/]')       { return 'contains a path separator' }
    if ($Name -match '[*?]')        { return 'contains a wildcard character' }
    if ($Name -match '[<>:"|]')     { return 'contains a character Windows does not allow in a file name' }
    if ($Name -match $script:UnsafeTextPattern) { return 'contains a control character' }
    if ($Name.StartsWith('.'))      { return "starts with '.'" }
    if ($Name -ne $Name.Trim())     { return 'has leading or trailing whitespace' }
    if ($Name.EndsWith('.'))        { return "ends with '.'" }
    if ($Name -match '\A(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\..*)?\z') { return 'is a reserved device name' }
    return $null
}

function Get-SafeModId {
    <# A positive whole number below a billion, as [int], or $null. #>
    param([AllowNull()] $Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [array] -or $Value -is [bool]) { return $null }
    $s = "$Value"
    if ($s -notmatch '\A[0-9]{1,9}\z') { return $null }
    $n = [int]$s
    if ($n -le 0) { return $null }
    return $n
}

function Test-SafeNexusUrl {
    <#
        Only a plain Nexus link survives. The character set is narrow on purpose:
        no spaces, quotes, brackets or parentheses, so a url cannot break out of a
        markdown link in the -OutFile checklist.
    #>
    param([AllowNull()] $Url)

    if ($Url -isnot [string]) { return $false }
    if ($Url.Length -gt 300)  { return $false }
    return ($Url -cmatch '\Ahttps://www\.nexusmods\.com/[A-Za-z0-9._~/?#=&%+-]*\z')
}

function ConvertTo-MdText {
    <# Escape markdown metacharacters so names stay text in the checklist. #>
    param([string] $Text)
    return ([regex]::Replace($Text, '([\\`*_\[\]<>|#!])', '\$1'))
}

function Get-MdLabel {
    <# '**Name** (folder)', or just '**folder**' when the two are the same. #>
    param($Row)
    $label = "**$(ConvertTo-MdText $Row.Name)**"
    if ($Row.Name -ne $Row.Folder) { $label += " ($(ConvertTo-MdText $Row.Folder))" }
    return $label
}

function Add-Problem {
    param([string] $What, [string] $Value, [string] $Reason)
    $script:Problems.Add([pscustomobject]@{
        What   = $What
        Value  = (Get-SafeText -Value $Value -Max 80)
        Reason = $Reason
    })
}

function Get-FolderHash {
    <#
      Stable content hash of a mod folder: SHA-256 over each file's relative path and
      its own SHA-256, in sorted order. A copy of the function in New-ModpackLock.ps1,
      kept identical so the two hashes can be compared; tests/LoadoutNeed.Tests.ps1
      checks that a lockfile from that script reads as PRESENT here.
    #>
    param([string] $Path)

    $files = Get-ChildItem -LiteralPath $Path -File -Recurse -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -ne '.nexus-mod.json' } |
             Sort-Object { $_.FullName.Substring($Path.Length).ToLowerInvariant() }

    if (-not $files) { return $null }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $acc = New-Object System.Text.StringBuilder
        foreach ($f in $files) {
            $rel = $f.FullName.Substring($Path.Length).TrimStart('\').Replace('\', '/').ToLowerInvariant()
            $fh  = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
            [void]$acc.Append("$rel`:$fh`n")
        }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($acc.ToString())
        return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-StagedVersion {
    <#
        Your installed version, by the same precedence New-ModpackLock.ps1 uses:
        info.json wins over .nexus-mod.json. $null when neither says.
    #>
    param([string] $Dir)

    $version = $null
    foreach ($file in @('.nexus-mod.json', 'info.json')) {
        $p = Join-Path $Dir $file
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        try {
            $j = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j -and $j.PSObject.Properties.Name -contains 'version' -and $j.version) { $version = "$($j.version)" }
        } catch {
            Write-Warn "  could not read $p - version treated as unknown"
        }
    }
    return $version
}

function Read-ForeignLockfile {
    <#
        Reads and validates a lockfile someone else produced. Throws when the file
        as a whole is unusable; drops and reports individual bad entries. Returns
        a hashtable of plain, validated values - nothing from the raw object is
        used after this point.
    #>
    param([Parameter(Mandatory = $true)][string] $LiteralPath)

    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        throw "No lockfile at '$LiteralPath'."
    }
    $size = (Get-Item -LiteralPath $LiteralPath).Length
    if ($size -gt $script:MaxLockBytes) {
        throw "Refusing '$LiteralPath': $size bytes is over the $([int]($script:MaxLockBytes / 1KB)) KB limit for a lockfile. A lockfile for a large loadout is well under 100 KB."
    }

    $raw = Get-Content -LiteralPath $LiteralPath -Raw -Encoding UTF8
    $doc = $null
    try {
        $doc = $raw | ConvertFrom-Json
    } catch {
        throw "Refusing '$LiteralPath': it is not valid JSON. If you were sent a loadout zip, that holds mod files; ask for the lockfile instead (.\darktide.ps1 lock -OutFile my-loadout.lock.json)."
    }
    if ($null -eq $doc -or $doc -isnot [System.Management.Automation.PSCustomObject]) {
        throw "Refusing '$LiteralPath': not a lockfile (expected a JSON object)."
    }
    $props = @($doc.PSObject.Properties.Name)

    $schema = if ($props -contains 'schemaVersion') { "$($doc.schemaVersion)" } else { '' }
    if ($schema -ne '1') {
        throw "Refusing '$LiteralPath': schemaVersion '$(Get-SafeText -Value $schema -Max 20)' is not supported (expected 1)."
    }
    if ($props -notcontains 'mods' -or $null -eq $doc.mods -or $doc.mods -isnot [array]) {
        throw "Refusing '$LiteralPath': no 'mods' array."
    }

    $game = $script:DefaultGame
    if ($props -contains 'game' -and $null -ne $doc.game) {
        if ($doc.game -is [string] -and $doc.game -cmatch '\A[a-z0-9]{1,64}\z') {
            $game = $doc.game
            if ($game -ne $script:DefaultGame) {
                Add-Problem -What 'game' -Value $game -Reason "this lockfile is for a different game than $($script:DefaultGame)"
            }
        } else {
            Add-Problem -What 'game' -Value "$($doc.game)" -Reason "not a plain game id; using $($script:DefaultGame)"
        }
    }

    $loadoutName = if ($props -contains 'name') { Get-SafeText -Value $doc.name -Max 80 } else { '' }

    $mods = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($m in @($doc.mods)) {
        if ($m -isnot [System.Management.Automation.PSCustomObject]) {
            Add-Problem -What 'mod entry' -Value "$m" -Reason 'not an object'
            continue
        }
        $mp = @($m.PSObject.Properties.Name)
        $folder = if ($mp -contains 'folder') { $m.folder } else { $null }
        $why = Test-SafeFolderName -Name $folder
        if ($why) {
            Add-Problem -What 'folder' -Value "$folder" -Reason $why
            continue
        }
        if ($seen.ContainsKey($folder)) {
            Add-Problem -What 'folder' -Value $folder -Reason 'listed twice; second entry ignored'
            continue
        }
        $seen[$folder] = $true
        if ($script:IgnoreFolders -contains $folder) { continue }

        $modId = $null
        if ($mp -contains 'modId' -and $null -ne $m.modId) {
            $modId = Get-SafeModId -Value $m.modId
            if ($null -eq $modId) {
                Add-Problem -What "modId of $folder" -Value "$($m.modId)" -Reason 'not a positive whole number; dropped'
            }
        }

        $url = $null
        if ($mp -contains 'url' -and $null -ne $m.url -and "$($m.url)" -ne '') {
            if (Test-SafeNexusUrl -Url $m.url) {
                $url = $m.url
            } else {
                Add-Problem -What "url of $folder" -Value "$($m.url)" -Reason 'not a https://www.nexusmods.com/ link; dropped'
            }
        }
        if (-not $url -and $modId) { $url = "https://www.nexusmods.com/$game/mods/$modId" }

        $hash = $null
        if ($mp -contains 'contentSha256' -and $null -ne $m.contentSha256) {
            if ($m.contentSha256 -is [string] -and $m.contentSha256 -cmatch '\A[0-9a-f]{64}\z') {
                $hash = $m.contentSha256
            } else {
                Add-Problem -What "contentSha256 of $folder" -Value "$($m.contentSha256)" -Reason 'not a SHA-256 hex string; treated as unknown'
            }
        }

        $version = $null
        if ($mp -contains 'version' -and $null -ne $m.version -and "$($m.version)".Trim() -ne '') {
            if ($m.version -is [string] -or $m.version -is [int] -or $m.version -is [long] -or $m.version -is [double] -or $m.version -is [decimal]) {
                $version = Get-SafeText -Value "$($m.version)".Trim() -Max 40
            } else {
                Add-Problem -What "version of $folder" -Value "$($m.version)" -Reason 'not a string; treated as unknown'
            }
        }

        $display = $folder
        if ($mp -contains 'name' -and $null -ne $m.name -and "$($m.name)".Trim() -ne '') {
            $display = Get-SafeText -Value "$($m.name)".Trim() -Max 80
        }

        $mods.Add([pscustomobject]@{
            Folder  = $folder
            Name    = $display
            ModId   = $modId
            Url     = $url
            Version = $version
            Hash    = $hash
        })
    }

    $order = New-Object System.Collections.Generic.List[string]
    if ($props -contains 'loadOrder' -and $null -ne $doc.loadOrder) {
        foreach ($entry in @($doc.loadOrder)) {
            $why = Test-SafeFolderName -Name $entry
            if ($why) {
                Add-Problem -What 'load order entry' -Value "$entry" -Reason $why
                continue
            }
            $order.Add($entry)
        }
    }

    return @{
        Name      = $loadoutName
        Game      = $game
        Mods      = $mods.ToArray()
        LoadOrder = $order.ToArray()
    }
}

# ---- Inputs ------------------------------------------------------------------------

if (-not $ModsRoot) {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "No -ModsRoot given and no config at '$ConfigPath'. Run: .\darktide.ps1 init"
    }
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($cfg.PSObject.Properties.Name -contains 'ModsRoot' -and "$($cfg.ModsRoot)".Trim()) {
        $ModsRoot = "$($cfg.ModsRoot)"
    }
    if (-not $ModsRoot) { throw "ModsRoot is not set in '$ConfigPath'." }
}
if (-not (Test-Path -LiteralPath $ModsRoot -PathType Container)) {
    throw "Staging folder '$ModsRoot' does not exist."
}
$ModsRoot = (Resolve-Path -LiteralPath $ModsRoot).ProviderPath

$outFull = $null
$outKind = $null
if ($OutFile) {
    $outFull = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($OutFile)
    $ext = [System.IO.Path]::GetExtension($outFull).ToLowerInvariant()
    if ($ext -eq '.md')       { $outKind = 'md' }
    elseif ($ext -eq '.json') { $outKind = 'json' }
    else { throw "-OutFile must end in .md (a checklist) or .json (data). Got '$OutFile'." }

    # Refuse targets this script must never replace, whatever -Force says: the
    # lockfile being read, the repository lockfile, and anything inside staging.
    $inFull   = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
    $repoLock = Join-Path $PSScriptRoot 'darktide-modpack.lock.json'
    foreach ($protected in @($inFull, $repoLock)) {
        if ([string]::Equals($outFull, $protected, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to write -OutFile over '$protected'."
        }
    }
    $stagingPrefix = $ModsRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if ($outFull.StartsWith($stagingPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to write -OutFile inside your staging folder '$ModsRoot'."
    }
    if ((Test-Path -LiteralPath $outFull) -and -not $Force) {
        throw "'$outFull' already exists. Pass -Force to replace it."
    }
    $outDir = Split-Path -Parent $outFull
    if ($outDir -and -not (Test-Path -LiteralPath $outDir -PathType Container)) {
        throw "Folder for -OutFile does not exist: '$outDir'."
    }
}

$theirs = Read-ForeignLockfile -LiteralPath $Path
$sourceLeaf = Get-SafeText -Value ([System.IO.Path]::GetFileName($Path)) -Max 80

# ---- Your staging ------------------------------------------------------------------

# Listed once. Their folder names are matched against these by string comparison,
# so nothing they wrote ever becomes part of a path. Case-insensitive, like Windows.
$mine = @{}
foreach ($dir in (Get-ChildItem -LiteralPath $ModsRoot -Directory | Sort-Object Name)) {
    if ($script:IgnoreFolders -contains $dir.Name) { continue }
    if ($dir.Name.StartsWith('.')) { continue }
    $mine[$dir.Name] = $dir
}

# ---- Compare -----------------------------------------------------------------------

$rows = New-Object System.Collections.Generic.List[object]
$theirSet = @{}

foreach ($t in ($theirs.Mods | Sort-Object Folder)) {
    $theirSet[$t.Folder] = $true

    if (-not $mine.ContainsKey($t.Folder)) {
        $rows.Add([pscustomobject]@{
            Status       = 'MISSING'
            Folder       = $t.Folder
            Name         = $t.Name
            Url          = $t.Url
            TheirVersion = $t.Version
            YourVersion  = $null
            Detail       = $(if ($t.Url) { '' } else { 'no Nexus id in their lockfile' })
        })
        continue
    }

    $dir = $mine[$t.Folder]
    $yourVersion = Get-StagedVersion -Dir $dir.FullName

    $notes = New-Object System.Collections.Generic.List[string]
    $differs = $false
    $compared = $false

    if ($t.Version -and $yourVersion) {
        $compared = $true
        if (-not [string]::Equals($t.Version.Trim(), $yourVersion.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
            $differs = $true
            $notes.Add("version: yours $(Get-SafeText -Value $yourVersion -Max 40), theirs $($t.Version)")
        }
    } else {
        $notes.Add('version unknown')
    }

    if ($t.Hash -and -not $NoHash) {
        $yourHash = Get-FolderHash -Path $dir.FullName
        if ($yourHash) {
            $compared = $true
            if ($yourHash -ne $t.Hash) {
                $differs = $true
                $notes.Add('content differs')
            }
        } else {
            $notes.Add('content unknown')
        }
    } else {
        $notes.Add('content not compared')
    }

    $status = if ($differs) { 'DIFFERENT' } else { 'PRESENT' }
    $detail = if ($differs) {
        ($notes | Where-Object { $_ -notmatch 'unknown|not compared' }) -join '; '
    } elseif (-not $compared) {
        'nothing to compare; treated as the same'
    } else {
        ($notes | Where-Object { $_ -match 'unknown|not compared' }) -join '; '
    }

    $rows.Add([pscustomobject]@{
        Status       = $status
        Folder       = $t.Folder
        Name         = $t.Name
        Url          = $t.Url
        TheirVersion = $t.Version
        YourVersion  = $(if ($yourVersion) { Get-SafeText -Value $yourVersion -Max 40 } else { $null })
        Detail       = $detail
    })
}

foreach ($name in ($mine.Keys | Sort-Object)) {
    if ($theirSet.ContainsKey($name)) { continue }
    $rows.Add([pscustomobject]@{
        Status       = 'EXTRA'
        Folder       = $name
        Name         = $name
        Url          = $null
        TheirVersion = $null
        YourVersion  = $(Get-StagedVersion -Dir $mine[$name].FullName)
        Detail       = 'you have it, they do not'
    })
}

$missing   = @($rows | Where-Object { $_.Status -eq 'MISSING' })
$different = @($rows | Where-Object { $_.Status -eq 'DIFFERENT' })
$present   = @($rows | Where-Object { $_.Status -eq 'PRESENT' })
$extra     = @($rows | Where-Object { $_.Status -eq 'EXTRA' })

$statusOf = @{}
foreach ($r in $rows) { $statusOf[$r.Folder] = $r.Status }

$orderRows = New-Object System.Collections.Generic.List[object]
$pos = 0
foreach ($entry in $theirs.LoadOrder) {
    # Skipped here as it is in the mod rows: base belongs to the mod loader, not to
    # a mod, so neither side lists it and the walk would report it MISSING.
    if ($script:IgnoreFolders -contains $entry) { continue }
    $pos++
    $st = if ($statusOf.ContainsKey($entry) -and $statusOf[$entry] -ne 'EXTRA') {
        $statusOf[$entry]
    } elseif ($mine.ContainsKey($entry)) {
        'PRESENT'
    } else {
        'MISSING'
    }
    $orderRows.Add([pscustomobject]@{ Position = $pos; Folder = $entry; Status = $st })
}

# ---- Report ------------------------------------------------------------------------

$label = if ($theirs.Name) { $theirs.Name } else { $sourceLeaf }
Write-Host ''
Write-Host "  their loadout : $label ($(@($theirs.Mods).Count) mods, from $sourceLeaf)"
Write-Host "  your staging  : $ModsRoot"

Write-Host ''
if ($missing.Count) {
    Write-Step "MISSING ($($missing.Count)) - download these from the author's page:"
    foreach ($r in $missing) {
        $where = if ($r.Url) { $r.Url } else { 'no Nexus id in their lockfile' }
        $ver = if ($r.TheirVersion) { " (theirs $($r.TheirVersion))" } else { '' }
        if ($r.Url) { Write-Host "  $($r.Folder.PadRight(34)) $where$ver" }
        else        { Write-Warn "  $($r.Folder.PadRight(34)) $where$ver" }
    }
} else {
    Write-Ok 'MISSING (0) - you have every mod in their loadout.'
}

Write-Host ''
if ($different.Count) {
    Write-Step "DIFFERENT ($($different.Count)) - you have these, but not the same build:"
    foreach ($r in $different) {
        $where = if ($r.Url) { "  $($r.Url)" } else { '' }
        Write-Warn "  $($r.Folder.PadRight(34)) $($r.Detail)$where"
    }
} else {
    Write-Ok 'DIFFERENT (0)'
}

Write-Host ''
Write-Step "PRESENT ($($present.Count))"
foreach ($r in $present) {
    $note = if ($r.Detail) { "  ($($r.Detail))" } else { '' }
    Write-Host "  $($r.Folder)$note"
}

Write-Host ''
Write-Step "EXTRA ($($extra.Count)) - you have these, they do not. Nothing to do."
foreach ($r in $extra) { Write-Host "  $($r.Folder)" }

if ($orderRows.Count) {
    Write-Host ''
    Write-Step 'Their load order (where each missing mod goes in mod_load_order.txt):'
    foreach ($o in $orderRows) {
        $line = "  $(([string]$o.Position).PadLeft(3)). $($o.Folder)"
        if ($o.Status -eq 'MISSING')       { Write-Warn "$line   <- MISSING" }
        elseif ($o.Status -eq 'DIFFERENT') { Write-Host "$line   <- different" }
        else                               { Write-Host $line }
    }
} else {
    Write-Host ''
    Write-Warn 'Their lockfile has no load order.'
}

if ($script:Problems.Count) {
    Write-Host ''
    Write-Err "Dropped from their lockfile ($($script:Problems.Count)) - the list above may be incomplete:"
    foreach ($p in $script:Problems) { Write-Warn "  $($p.What) '$($p.Value)': $($p.Reason)" }
}

Write-Host ''
Write-Host "$($missing.Count) missing, $($different.Count) different, $($present.Count) present, $($extra.Count) extra."
Write-Host 'Nothing was downloaded or changed. The lockfile holds links, not mod files.'

# ---- -OutFile ----------------------------------------------------------------------

if ($outFull) {
    if ($outKind -eq 'json') {
        $data = [ordered]@{
            generatedBy = 'Get-LoadoutGap.ps1'
            source      = $sourceLeaf
            loadout     = $theirs.Name
            game        = $theirs.Game
            counts      = [ordered]@{
                missing   = $missing.Count
                different = $different.Count
                present   = $present.Count
                extra     = $extra.Count
                dropped   = $script:Problems.Count
            }
            mods        = @($rows | ForEach-Object {
                [ordered]@{
                    status       = $_.Status
                    folder       = $_.Folder
                    name         = $_.Name
                    url          = $_.Url
                    theirVersion = $_.TheirVersion
                    yourVersion  = $_.YourVersion
                    detail       = $_.Detail
                }
            })
            loadOrder   = @($orderRows | ForEach-Object {
                [ordered]@{ position = $_.Position; folder = $_.Folder; status = $_.Status }
            })
            dropped     = @($script:Problems | ForEach-Object {
                [ordered]@{ what = $_.What; value = $_.Value; reason = $_.Reason }
            })
        }
        ($data | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $outFull -Encoding UTF8
    } else {
        $md = New-Object System.Collections.Generic.List[string]
        $md.Add("# Mods to get for $(ConvertTo-MdText $label)")
        $md.Add('')
        $md.Add("Compared from ``$(($sourceLeaf -replace '`', ''))`` against your staging folder. The lockfile lists mods and links to each author's Nexus page; it contains no mod files. Download each one from its page, then run ``.\darktide.ps1 update -Apply``.")
        $md.Add('')
        $md.Add("## Missing ($($missing.Count))")
        $md.Add('')
        if ($missing.Count) {
            foreach ($r in $missing) {
                $ver = if ($r.TheirVersion) { " - theirs $(ConvertTo-MdText $r.TheirVersion)" } else { '' }
                $link = if ($r.Url) { "[Nexus page]($($r.Url))" } else { '_no Nexus id in their lockfile_' }
                $md.Add("- [ ] $(Get-MdLabel $r)$ver - $link")
            }
        } else {
            $md.Add('Nothing. You have every mod in their loadout.')
        }
        $md.Add('')
        $md.Add("## Different ($($different.Count))")
        $md.Add('')
        if ($different.Count) {
            foreach ($r in $different) {
                $link = if ($r.Url) { " - [Nexus page]($($r.Url))" } else { '' }
                $md.Add("- [ ] $(Get-MdLabel $r) - $(ConvertTo-MdText $r.Detail)$link")
            }
        } else {
            $md.Add('Nothing known to differ.')
        }
        $md.Add('')
        if ($orderRows.Count) {
            $md.Add('## Their load order')
            $md.Add('')
            foreach ($o in $orderRows) {
                $mark = if ($o.Status -eq 'MISSING') { ' - **missing**' } elseif ($o.Status -eq 'DIFFERENT') { ' - different' } else { '' }
                $md.Add("$($o.Position). $(ConvertTo-MdText $o.Folder)$mark")
            }
            $md.Add('')
        }
        $md.Add("## Present ($($present.Count))")
        $md.Add('')
        foreach ($r in $present) { $md.Add("- $(ConvertTo-MdText $r.Folder)") }
        $md.Add('')
        $md.Add("## Extra ($($extra.Count))")
        $md.Add('')
        $md.Add('You have these and they do not. Nothing to do.')
        $md.Add('')
        foreach ($r in $extra) { $md.Add("- $(ConvertTo-MdText $r.Folder)") }
        if ($script:Problems.Count) {
            $md.Add('')
            $md.Add("## Dropped from their lockfile ($($script:Problems.Count))")
            $md.Add('')
            foreach ($p in $script:Problems) {
                $md.Add("- $(ConvertTo-MdText $p.What) '$(ConvertTo-MdText $p.Value)': $(ConvertTo-MdText $p.Reason)")
            }
        }
        Set-Content -LiteralPath $outFull -Value $md -Encoding UTF8
    }
    Write-Host ''
    Write-Ok "Wrote $outFull"
}

if ($script:Problems.Count) { exit 1 }
