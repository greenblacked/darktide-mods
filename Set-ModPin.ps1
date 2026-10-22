<#
.SYNOPSIS
    Hold mods at their current version: list, pin and unpin entries in mods-map.json.

.DESCRIPTION
    A pin tells Update-DarktideMods.ps1 to leave a mod folder alone. The updater
    reports a pinned mod as PINNED and installs nothing for it - not a newer archive,
    not a first install of a folder that is missing, and not with -Force either.

    With no -Only this lists every pin: the folder, the version it was pinned at, the
    reason given, when, and the version staging holds now.

    With -Only it pins (or, with -Unpin, unpins) those folders. A pin writes
    "pinned": true plus three keys alongside it:

        pinnedVersion   the version staging held at pin time (from info.json or
                        .nexus-mod.json), or null when there is no way to tell
        pinnedReason    the -Reason text, or null
        pinnedAt        local date and time of the pin

    Unpinning sets "pinned": false and removes those three keys again.

    Every other key and the order of the entries are kept exactly as they were, and
    the file is written back in the same layout (two-space indent, same line endings,
    same encoding) so a pin shows up in a diff as the lines it changed and nothing else.

    Like every other write in this repository it is a dry run until -Apply. With
    -Apply the current map is copied to mods-map.json.bak first, then the new map is
    written to a temporary file beside it and moved into place, so an interrupted run
    leaves either the old map or the new one, never half of one.

    A folder has to exist somewhere before it can be pinned: either as an entry in
    mods-map.json or as a folder in staging (ModsRoot from config.json). Anything else
    is a typo and is refused before anything is written.

.PARAMETER Only
    The mod folders to pin or unpin. Accepts a list (-Only a,b) or one comma-separated
    string. Without it the script lists the current pins and writes nothing.

.PARAMETER Reason
    Why the mod is held, e.g. 'crashes on 1.4'. Stored as pinnedReason. When re-pinning
    a mod that is already pinned, leaving this out keeps the reason it already has.

.PARAMETER Unpin
    Remove the pin from the -Only folders instead of adding one.

.PARAMETER Apply
    Write mods-map.json. Without it you get the plan and nothing else.

.PARAMETER MapPath
    The map to edit. Defaults to the MapPath key in config.json when there is one,
    otherwise mods-map.json beside this script - the same file the updater reads.

.PARAMETER ModsRoot
    Staging mods folder, used to read the installed version and to recognise folders
    that have no map entry yet. Defaults to ModsRoot in config.json. Optional: without
    it only folders already in mods-map.json can be pinned.

.PARAMETER ConfigPath
    config.json to read MapPath and ModsRoot from. A missing config is not an error.

.EXAMPLE
    .\Set-ModPin.ps1
    Lists every pinned mod with its pinned version, reason and date.

.EXAMPLE
    .\Set-ModPin.ps1 -Only NumericUI,scoreboard -Reason 'crashes on 1.4'
    Shows what pinning those two would change. Writes nothing.

.EXAMPLE
    .\Set-ModPin.ps1 -Only NumericUI,scoreboard -Reason 'crashes on 1.4' -Apply
    Pins both, after copying the current map to mods-map.json.bak.

.EXAMPLE
    .\Set-ModPin.ps1 -Only NumericUI -Unpin -Apply
    Lets update install new versions of NumericUI again.

.NOTES
    Needs no API key and no network. Never touches staging or the game folder; the
    only files it writes are mods-map.json and mods-map.json.bak (one copy, replaced
    on each -Apply, and gitignored by the *.bak rule).
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string[]] $Only,
    [string]   $Reason,
    [switch]   $Unpin,
    [switch]   $Apply,
    [string]   $MapPath,
    [string]   $ModsRoot,
    [string]   $ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$m) Write-Host $m -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host $m -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host $m -ForegroundColor Yellow }

# The three keys a pin adds next to 'pinned', in the order they are written.
$script:PinKeys = @('pinnedVersion', 'pinnedReason', 'pinnedAt')

# ----------------------------------------------------------------------------------
# JSON writing
# ----------------------------------------------------------------------------------

function ConvertTo-MapJsonString {
    <#
        JSON string literal. Escapes what JSON requires and nothing more, so an
        apostrophe or a URL in a note comes back exactly as it went in. Windows
        PowerShell 5.1's ConvertTo-Json would turn every ' into ' and rewrite
        half the file on the first pin.
    #>
    param([string] $Text)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        switch ($code) {
            34 { [void]$sb.Append('\"'); continue }
            92 { [void]$sb.Append('\\'); continue }
            8  { [void]$sb.Append('\b'); continue }
            9  { [void]$sb.Append('\t'); continue }
            10 { [void]$sb.Append('\n'); continue }
            12 { [void]$sb.Append('\f'); continue }
            13 { [void]$sb.Append('\r'); continue }
            default {
                if ($code -lt 32 -or $code -eq 0x85 -or $code -eq 0x2028 -or $code -eq 0x2029) {
                    [void]$sb.Append(('\u{0:x4}' -f $code))
                } else {
                    [void]$sb.Append($ch)
                }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-MapJson {
    <#
        Serialises a value the way PowerShell 7's ConvertTo-Json lays out mods-map.json
        today: two-space indent, "key": value, empty containers as {} and []. Written
        by hand because the two engines' ConvertTo-Json disagree on indentation and
        escaping, and the map has to come out the same whichever one runs this.
    #>
    param($Value, [int] $Depth = 0)

    $nl   = $script:NewLine
    $pad  = '  ' * ($Depth + 1)
    $tail = '  ' * $Depth
    $inv  = [System.Globalization.CultureInfo]::InvariantCulture

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) { return (ConvertTo-MapJsonString -Text $Value) }
    if ($Value -is [char])   { return (ConvertTo-MapJsonString -Text ([string]$Value)) }
    if ($Value -is [bool])   { return $(if ($Value) { 'true' } else { 'false' }) }
    if ($Value -is [double] -or $Value -is [single]) { return ([double]$Value).ToString('R', $inv) }
    if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int] -or $Value -is [uint32] -or $Value -is [long] -or $Value -is [uint64] -or
        $Value -is [decimal] -or $Value.GetType().FullName -eq 'System.Numerics.BigInteger') {
        return $Value.ToString($null, $inv)
    }
    if ($Value -is [datetime]) {
        # PowerShell 7's ConvertFrom-Json turns an ISO 8601 string into a DateTime.
        # Write it back as ISO 8601 rather than as a culture-formatted date.
        return (ConvertTo-MapJsonString -Text $Value.ToString('yyyy-MM-ddTHH:mm:ss.FFFFFFFK', $inv))
    }

    $pairs = $null
    if ($Value -is [System.Collections.IDictionary]) {
        $pairs = @(foreach ($k in $Value.Keys) { , @([string]$k, $Value[$k]) })
    } elseif ($Value -is [System.Management.Automation.PSCustomObject]) {
        $pairs = @(foreach ($p in $Value.PSObject.Properties) { , @($p.Name, $p.Value) })
    }
    if ($null -ne $pairs) {
        if ($pairs.Count -eq 0) { return '{}' }
        $parts = foreach ($pair in $pairs) {
            $pad + (ConvertTo-MapJsonString -Text $pair[0]) + ': ' + (ConvertTo-MapJson -Value $pair[1] -Depth ($Depth + 1))
        }
        return '{' + $nl + ($parts -join (',' + $nl)) + $nl + $tail + '}'
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value)
        if ($items.Count -eq 0) { return '[]' }
        $parts = foreach ($item in $items) { $pad + (ConvertTo-MapJson -Value $item -Depth ($Depth + 1)) }
        return '[' + $nl + ($parts -join (',' + $nl)) + $nl + $tail + ']'
    }

    return (ConvertTo-MapJsonString -Text ([string]$Value))
}

# ----------------------------------------------------------------------------------
# Reading
# ----------------------------------------------------------------------------------

function Get-EntryDictionary {
    <# One map entry as an ordered dictionary, keys in file order. #>
    param([string] $Folder, $Entry)

    if ($Entry -isnot [System.Management.Automation.PSCustomObject]) {
        throw "mods-map.json entry '$Folder' is not a JSON object. Fix it by hand before pinning."
    }
    $d = [ordered]@{}
    foreach ($p in $Entry.PSObject.Properties) { $d[$p.Name] = $p.Value }
    return , $d
}

function Test-EntryPinned {
    param($Entry)
    if ($Entry -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    if ($Entry.PSObject.Properties.Name -notcontains 'pinned') { return $false }
    return [bool]$Entry.pinned
}

function Get-EntryValue {
    param($Entry, [string] $Name)
    if ($Entry -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    if ($Entry.PSObject.Properties.Name -notcontains $Name) { return $null }
    return $Entry.$Name
}

function Get-StagedModInfo {
    <#
        Version and display name of one staging folder. Same precedence as
        Get-LocalMods in Update-DarktideMods.ps1: .nexus-mod.json first, then the
        author's info.json, which wins when both carry a version.
    #>
    param([string] $Path, [string] $Folder)

    $version = $null
    $name    = $Folder
    foreach ($file in @('.nexus-mod.json', 'info.json')) {
        $f = Join-Path $Path $file
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
        try {
            $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.PSObject.Properties.Name -contains 'version' -and $j.version) { $version = "$($j.version)" }
            if ($j.PSObject.Properties.Name -contains 'name'    -and $j.name)    { $name    = "$($j.name)" }
        } catch {
            Write-Warn "  $Folder : $file is not valid JSON - ignoring it."
        }
    }
    return [pscustomobject]@{ Version = $version; Name = $name }
}

# ----------------------------------------------------------------------------------
# Resolve paths
# ----------------------------------------------------------------------------------

$cfg = $null
if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    $rawCfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    if ($rawCfg.Trim()) { $cfg = $rawCfg | ConvertFrom-Json }
}

function Get-CfgValue {
    param([string] $Key)
    if ($null -eq $cfg) { return '' }
    if ($cfg.PSObject.Properties.Name -notcontains $Key) { return '' }
    return "$($cfg.$Key)".Trim()
}

if (-not $MapPath)  { $MapPath  = Get-CfgValue 'MapPath' }
if (-not $MapPath)  { $MapPath  = Join-Path $PSScriptRoot 'mods-map.json' }
if (-not $ModsRoot) { $ModsRoot = Get-CfgValue 'ModsRoot' }

# .NET file calls resolve relative paths against the process directory, not the
# PowerShell location, so make the map path absolute once, here.
$MapPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($MapPath)

$stagingOk = $false
if ($ModsRoot) {
    if (Test-Path -LiteralPath $ModsRoot -PathType Container) {
        $ModsRoot  = (Resolve-Path -LiteralPath $ModsRoot).Path
        $stagingOk = $true
    }
}

# ----------------------------------------------------------------------------------
# Load the map, keeping its exact shape
# ----------------------------------------------------------------------------------

$mapExists = Test-Path -LiteralPath $MapPath -PathType Leaf
$map       = [ordered]@{}
$script:NewLine = "`n"
$hasBom         = $false
$trailingNl     = $true

if ($mapExists) {
    $bytes  = [System.IO.File]::ReadAllBytes($MapPath)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text   = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($hasBom) { $text = $text.Substring(1) }

    if ($text.Contains("`r`n")) { $script:NewLine = "`r`n" }
    $trailingNl = $text.EndsWith("`n")

    if ($text.Trim()) {
        # Refuse rather than start from empty: writing back an empty map over a
        # file that merely failed to parse would throw away every entry in it.
        try {
            $parsed = $text | ConvertFrom-Json
        } catch {
            throw "'$MapPath' is not valid JSON ($($_.Exception.Message)). Fix it by hand; nothing was written."
        }
        if ($parsed -isnot [System.Management.Automation.PSCustomObject]) {
            throw "'$MapPath' must hold a JSON object of folder -> entry. Nothing was written."
        }
        foreach ($p in $parsed.PSObject.Properties) {
            # The dictionary is case-insensitive, like the folders it describes. Two
            # keys differing only in case would silently become one on the way back.
            if ($map.Contains($p.Name)) {
                throw "'$MapPath' has two entries for '$($p.Name)' (differing only in case). Merge them by hand; nothing was written."
            }
            $map[$p.Name] = $p.Value
        }
    }
}

# Staging inventory, by folder name.
$staged = @{}
if ($stagingOk) {
    foreach ($d in @(Get-ChildItem -LiteralPath $ModsRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name.StartsWith('.')) { continue }
        $staged[$d.Name] = $d.FullName
    }
}

function Get-InstalledVersion {
    param([string] $Folder)
    $key = @($staged.Keys | Where-Object { $_ -ieq $Folder } | Select-Object -First 1)
    if (-not $key) { return $null }
    return (Get-StagedModInfo -Path $staged[$key[0]] -Folder $key[0]).Version
}

Write-Step '=== Darktide mod pins ==='
Write-Host  "Map     : $MapPath$(if (-not $mapExists) { '  (does not exist yet)' })"
Write-Host  "Staging : $(if ($stagingOk) { $ModsRoot } elseif ($ModsRoot) { "$ModsRoot  (not found - installed versions unknown)" } else { 'not configured - installed versions unknown' })"

# ----------------------------------------------------------------------------------
# List mode
# ----------------------------------------------------------------------------------

# An empty -Reason counts as none, so a caller can pass the parameter through
# unconditionally (the dispatcher does) without clearing a stored reason.
$reasonGiven = [bool]("$Reason".Trim())

$targets = @()
if ($Only) {
    $targets = @($Only | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

if (-not $targets) {
    if ($Unpin -or $reasonGiven) {
        throw "Which mods? Pass -Only, e.g. .\darktide.ps1 pin -Only NumericUI$(if ($Unpin) { ' -Unpin' } else { " -Reason 'crashes on 1.4'" }) -Apply"
    }
    Write-Host ''

    $rows = @(foreach ($k in $map.Keys) {
        $e = $map[$k]
        if (-not (Test-EntryPinned $e)) { continue }
        $installed = '-'
        if ($stagingOk) {
            $iv = Get-InstalledVersion -Folder $k
            $installed = $(if ($iv) { $iv } elseif (@($staged.Keys | Where-Object { $_ -ieq $k })) { 'unknown' } else { 'not installed' })
        }
        [pscustomobject]@{
            Folder        = $k
            PinnedVersion = $(if ($null -ne (Get-EntryValue $e 'pinnedVersion')) { "$(Get-EntryValue $e 'pinnedVersion')" } else { '-' })
            Installed     = $installed
            Reason        = $(if (Get-EntryValue $e 'pinnedReason') { "$(Get-EntryValue $e 'pinnedReason')" } else { '-' })
            PinnedAt      = $(if (Get-EntryValue $e 'pinnedAt') { "$(Get-EntryValue $e 'pinnedAt')" } else { '-' })
        }
    })

    if (-not $rows) {
        Write-Ok 'No mods are pinned. update installs every newer archive it finds.'
        Write-Host "Pin one with: .\darktide.ps1 pin -Only <folder> -Reason '<why>' -Apply"
        return
    }

    Write-Step "Pinned: $($rows.Count)"
    $rows | Format-Table -AutoSize -Property Folder, PinnedVersion, Installed, Reason, PinnedAt |
        Out-String -Width 200 | Write-Host
    Write-Host "update reports these as PINNED and installs nothing for them, -Force included."
    Write-Host "Unpin with: .\darktide.ps1 pin -Only <folder> -Unpin -Apply"
    return
}

# ----------------------------------------------------------------------------------
# Plan
# ----------------------------------------------------------------------------------

if ($Unpin -and $reasonGiven) {
    throw '-Reason goes with a pin, not -Unpin. Drop one of them.'
}

Write-Host  "Mode    : $(if ($Apply) { 'APPLY' } else { 'DRY RUN (pass -Apply to write)' })"
Write-Host  ''

# Resolve each name to the spelling already in use. Folder names are
# case-insensitive on Windows, and a second entry differing only in case would be
# one the updater's lookups cannot tell apart.
$unknown  = New-Object System.Collections.Generic.List[string]
$resolved = New-Object System.Collections.Generic.List[string]
foreach ($t in $targets) {
    $hit = @($map.Keys | Where-Object { $_ -ieq $t } | Select-Object -First 1)
    if (-not $hit) { $hit = @($staged.Keys | Where-Object { $_ -ieq $t } | Select-Object -First 1) }
    if (-not $hit) { $unknown.Add($t); continue }
    if (-not ($resolved | Where-Object { $_ -ieq $hit[0] })) { $resolved.Add([string]$hit[0]) }
}

if ($unknown.Count -gt 0) {
    $where = $(if ($stagingOk) { "mods-map.json or the staging folder $ModsRoot" } else { 'mods-map.json (staging is not configured, so only mapped folders can be pinned)' })
    throw "Not a known mod folder: $($unknown -join ', '). Looked in $where. Check the spelling; nothing was written."
}

$now     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
$changes = 0
$plan    = New-Object System.Collections.Generic.List[object]
$newMap  = [ordered]@{}
foreach ($k in $map.Keys) { $newMap[$k] = $map[$k] }

foreach ($folder in $resolved) {
    $entry  = $(if ($newMap.Contains($folder)) { $newMap[$folder] } else { $null })
    $wasPin = Test-EntryPinned $entry

    if ($Unpin) {
        if (-not $wasPin) {
            $plan.Add([pscustomobject]@{ Folder = $folder; Change = 'not pinned - nothing to do'; Version = ''; Reason = '' })
            continue
        }
        $d = Get-EntryDictionary -Folder $folder -Entry $entry
        $d['pinned'] = $false
        foreach ($pk in $script:PinKeys) { if ($d.Contains($pk)) { $d.Remove($pk) } }
        $newMap[$folder] = [pscustomobject]$d
        $changes++
        $plan.Add([pscustomobject]@{
            Folder  = $folder
            Change  = 'unpin'
            Version = "$(Get-EntryValue $entry 'pinnedVersion')"
            Reason  = "$(Get-EntryValue $entry 'pinnedReason')"
        })
        continue
    }

    $version = Get-InstalledVersion -Folder $folder
    $why     = $(if ($reasonGiven) { $Reason.Trim() } else { Get-EntryValue $entry 'pinnedReason' })
    if ($null -ne $why -and "$why".Trim() -eq '') { $why = $null }

    if ($null -eq $entry) {
        # Staged but never mapped. Same shape the updater's -Resolve writes, so a later
        # -Resolve fills in the id around the pin rather than replacing it.
        $staged1 = @($staged.Keys | Where-Object { $_ -ieq $folder })[0]
        $d = [ordered]@{
            modId  = $null
            name   = (Get-StagedModInfo -Path $staged[$staged1] -Folder $folder).Name
            note   = ''
            pinned = $true
        }
        $change = 'pin (new map entry)'
    } else {
        $d = Get-EntryDictionary -Folder $folder -Entry $entry
        $d['pinned'] = $true
        $change = $(if ($wasPin) { 're-pin' } else { 'pin' })
    }

    # The three pin keys go directly after 'pinned', in a fixed order, replacing any
    # earlier copies wherever they were.
    $values = @{ pinnedVersion = $version; pinnedReason = $why; pinnedAt = $now }
    foreach ($pk in $script:PinKeys) { if ($d.Contains($pk)) { $d.Remove($pk) } }
    $at = 0
    foreach ($key in @($d.Keys)) { if ($key -eq 'pinned') { break }; $at++ }
    foreach ($pk in $script:PinKeys) {
        $at++
        $d.Insert($at, $pk, $values[$pk])
    }

    $newEntry = [pscustomobject]$d
    if ($newMap.Contains($folder)) {
        $newMap[$folder] = $newEntry
    } else {
        # Slot a new entry where Save-ModMap's sort would put it, so the next
        # -Resolve does not move it and produce a diff of its own.
        $index = 0
        foreach ($k in @($newMap.Keys)) {
            if ((@($folder, $k) | Sort-Object)[0] -eq $folder) { break }
            $index++
        }
        $newMap.Insert($index, $folder, $newEntry)
    }
    $changes++
    $plan.Add([pscustomobject]@{
        Folder  = $folder
        Change  = $change
        Version = $(if ($version) { $version } else { 'unknown' })
        Reason  = $(if ($why) { "$why" } else { '' })
    })
}

Write-Step 'Plan'
$plan | Format-Table -AutoSize -Property Folder, Change, Version, Reason | Out-String -Width 200 | Write-Host

if ($changes -eq 0) {
    Write-Ok 'Nothing to change. mods-map.json is already in that state.'
    return
}

if (-not $Apply) {
    Write-Warn 'Dry run complete. Nothing was written. Re-run with -Apply.'
    return
}

# ----------------------------------------------------------------------------------
# Write: backup, temp file, move into place
# ----------------------------------------------------------------------------------

$json = ConvertTo-MapJson -Value $newMap
if ($trailingNl) { $json += $script:NewLine }
$encoding = New-Object System.Text.UTF8Encoding($hasBom)

$what = "$(if ($Unpin) { 'Unpin' } else { 'Pin' }) $(@($plan | Where-Object { $_.Change -notlike 'not pinned*' } | ForEach-Object { $_.Folder }) -join ', ')"
if ($PSCmdlet.ShouldProcess($MapPath, $what)) {
    $dir = Split-Path -Parent $MapPath
    if ($dir) { [void][System.IO.Directory]::CreateDirectory($dir) }

    $bak = "$MapPath.bak"
    if ($mapExists) {
        Copy-Item -LiteralPath $MapPath -Destination $bak -Force
    }

    $tmp = "$MapPath.tmp"
    try {
        [System.IO.File]::WriteAllText($tmp, $json, $encoding)
        Move-Item -LiteralPath $tmp -Destination $MapPath -Force
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw
    }

    Write-Ok "Wrote $MapPath"
    if ($mapExists) { Write-Host "Previous copy: $bak" }
    if (-not $Unpin) {
        Write-Host 'update now reports these as PINNED and leaves them alone, -Force included.'
    }
}
