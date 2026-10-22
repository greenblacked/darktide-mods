<#
.SYNOPSIS
    After a Darktide patch: was the game updated since the loader was patched, and
    what to run next.

.DESCRIPTION
    A Fatshark patch arrives through Steam, and Steam replaces
    bundle\bundle_database.data while it is at it. That file is the one the mod
    loader patches, so after an update every mod silently stops loading until the
    patch is applied again. This answers "did that happen?" in one command.

    It reads, and never writes to the game folder:

      1. Steam's app manifest (steamapps\appmanifest_1361210.acf, two levels above
         the game folder - no registry needed): build id, target build id, the time
         of the last update, and whether an update is still downloading.
      2. bundle\bundle_database.data: size, last write time and SHA-256.
      3. <game>\.darktide-loader.json, written by the loader install. When it
         records the bundle database's fingerprint from right after a successful
         patch, a different hash now means the database was replaced. When it does
         not, the check falls back to comparing the database's last write time with
         the loader install time, and says it is a guess.
      4. The loader's own files: binaries\mod_loader, bundle\*.patch_999,
         tools\dtkit-patch.exe and toggle_darktide_mods.bat.
      5. A remembered baseline beside the staging folder
         (<ModsRoot parent>\.darktide-gamestate.json), written only with -Remember,
         so the next run can say "the build changed since last time".
      6. Staged mods installed before the game last updated. That is a hint about
         where to look first if something misbehaves. It says nothing about
         whether a mod still works or whether its author has released anything.

    The Steam manifest keys are what Steam writes today; this repository cannot
    verify them against every Steam build. When the manifest is missing or reads
    oddly, the check says so and carries on with the rest.

.PARAMETER ConfigPath
    config.json with GamePath and ModsRoot. Defaults to the one beside this script.

.PARAMETER GamePath
    Override the game folder from config.json.

.PARAMETER StagingMods
    Override the staging folder (ModsRoot) from config.json.

.PARAMETER ManifestPath
    Read this Steam app manifest instead of the one found from the game folder.
    For a library laid out in a way the default guess does not match.

.PARAMETER MapPath
    mods-map.json, read for `pinned` flags. Defaults to the one beside this script.

.PARAMETER Remember
    Store the current build and bundle database fingerprint as the baseline for the
    next run. The file goes beside the staging folder, never inside the game folder.
    Refused while Steam reports an update in progress.

.PARAMETER OutFile
    Also write the full report. A name ending in .json writes JSON; .md writes
    markdown. Refuses to overwrite an existing file without -Force.

.PARAMETER Force
    Overwrite an existing -OutFile.

.EXAMPLE
    .\Get-DarktideBuildState.ps1
    Report only. Writes nothing.

.EXAMPLE
    .\Get-DarktideBuildState.ps1 -Remember
    Report, then record this build as the baseline for the next check.

.EXAMPLE
    .\Get-DarktideBuildState.ps1 -OutFile patchcheck.json
    Report, and keep the full result as JSON.

.NOTES
    Exit codes, so a script can branch on the result:
      0  in sync, or nothing certain to act on (a guess is reported as a warning),
         or Steam is still updating the game (wait; there is nothing to run yet)
      1  something needs doing: the bundle database was replaced, loader files
         are missing, or the database itself is missing

    The full verdict (IN SYNC, ACTION NEEDED, UPDATE PENDING, UNKNOWN) is in the
    -OutFile JSON as 'verdict' for a script that needs more than the exit code.
#>

[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string] $GamePath,
    [string] $StagingMods,
    [string] $ManifestPath,
    [string] $MapPath = (Join-Path $PSScriptRoot 'mods-map.json'),
    [switch] $Remember,
    [string] $OutFile,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$m) Write-Host $m -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host $m -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host $m -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host $m -ForegroundColor Red }

$script:AppId        = '1361210'
$script:LoaderState  = '.darktide-loader.json'
$script:BaselineName = '.darktide-gamestate.json'

function Get-FullPathSafe {
    <#
        An absolute path without touching the disk and without globbing, so a
        folder name with [brackets] or one that does not exist yet still resolves.
    #>
    param([Parameter(Mandatory)][string] $Path)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Test-PathUnder {
    <# True when $Path is $Root or anything inside it. #>
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Root)
    $p = (Get-FullPathSafe -Path $Path).TrimEnd('\', '/')
    $r = (Get-FullPathSafe -Path $Root).TrimEnd('\', '/')
    if ($p.Equals($r, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    foreach ($sep in @('\', '/')) {
        if ($p.StartsWith($r + $sep, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function ConvertTo-UtcDate {
    <#
        A [datetime] in UTC, or $null. Accepts a string (ISO 8601, as the tools
        write it), a [datetime] (pwsh 7's ConvertFrom-Json turns ISO strings into
        those; Windows PowerShell 5.1 does not) or a [datetimeoffset].
    #>
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    if ($Value -is [DateTime]) {
        if ($Value.Kind -eq [DateTimeKind]::Utc) { return $Value }
        return $Value.ToUniversalTime()
    }
    $s = "$Value".Trim()
    if (-not $s) { return $null }
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($s, [Globalization.CultureInfo]::InvariantCulture,
                                   [Globalization.DateTimeStyles]::AssumeLocal, [ref]$parsed)) {
        return $parsed.UtcDateTime
    }
    return $null
}

function ConvertFrom-UnixTime {
    <# Seconds since 1970 as a UTC [datetime], or $null. #>
    param([string] $Seconds)
    $n = [int64]0
    if (-not [int64]::TryParse("$Seconds".Trim(), [ref]$n) -or $n -le 0) { return $null }
    return (New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)).AddSeconds($n)
}

function Format-Utc {
    param($Date)
    if ($null -eq $Date) { return $null }
    return $Date.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-ObjectField {
    <# A property of a parsed JSON object, or $null when it is absent. #>
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    # The indexer, not .Properties.Name: under StrictMode an object with no
    # properties at all ('{}', a bare number) throws on .Name.
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Read-SteamManifest {
    <#
        Reads the top-level key/value pairs of a Steam .acf (Valve KeyValues text).
        Tolerant on purpose: keys are matched case-insensitively, nested blocks
        (InstalledDepots, UserConfig, ...) are skipped, comments and blank lines are
        ignored, and anything that does not look like "key" "value" is passed over
        rather than treated as an error. Returns a hashtable of lower-cased keys.
    #>
    param([Parameter(Mandatory)][string] $Path)

    $values = @{}
    $depth  = 0
    foreach ($line in @(Get-Content -LiteralPath $Path -Encoding UTF8)) {
        $tokens = @([regex]::Matches($line, '"((?:[^"\\]|\\.)*)"') | ForEach-Object { $_.Groups[1].Value })
        $bare   = [regex]::Replace($line, '"((?:[^"\\]|\\.)*)"', '')
        $bare   = [regex]::Replace($bare, '//.*$', '')

        # Pairs belong to AppState itself at depth 1. Depth 0 accepts them too, so
        # a file with its braces stripped still yields what it can.
        if ($tokens.Count -ge 2 -and $depth -le 1) {
            $key = $tokens[0].ToLowerInvariant()
            if (-not $values.ContainsKey($key)) { $values[$key] = $tokens[1] }
        }

        foreach ($ch in $bare.ToCharArray()) {
            if ($ch -eq '{') { $depth++ }
            elseif ($ch -eq '}' -and $depth -gt 0) { $depth-- }
        }
    }
    return $values
}

function Get-FileFingerprint {
    <# Length, last write time and SHA-256 of a file; $null when it is missing. #>
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $item = Get-Item -LiteralPath $Path
    $hash = $null
    $err  = $null
    try {
        $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    } catch { $err = $_.Exception.Message }
    return [pscustomobject]@{
        Length           = [int64]$item.Length
        LastWriteTimeUtc = $item.LastWriteTimeUtc
        Sha256           = $hash
        HashError        = $err
    }
}

# ---- Resolve config ----------------------------------------------------------------

$cfg = @{ ModsRoot = ''; GamePath = '' }
if (Test-Path -LiteralPath $ConfigPath) {
    $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    if ($raw -and $raw.Trim()) {
        $j = $raw | ConvertFrom-Json
        foreach ($k in @($cfg.Keys)) {
            if ($j.PSObject.Properties.Name -contains $k -and "$($j.$k)".Trim()) { $cfg[$k] = "$($j.$k)" }
        }
    }
}
if ($GamePath)    { $cfg.GamePath = $GamePath }
if ($StagingMods) { $cfg.ModsRoot = $StagingMods }

if (-not $cfg.GamePath) { throw "Game folder not set. Run '.\darktide.ps1 init' first, or pass -GamePath." }
if (-not (Test-Path -LiteralPath $cfg.GamePath -PathType Container)) {
    throw "Game folder '$($cfg.GamePath)' does not exist."
}
$game = (Resolve-Path -LiteralPath $cfg.GamePath).Path.TrimEnd('\', '/')

$marker = @('binaries\Darktide.exe', 'binaries_dx12\Darktide.exe', 'bundle\bundle_database.data', 'launcher\Launcher.exe') |
          Where-Object { Test-Path -LiteralPath (Join-Path $game $_) }
if (-not $marker) {
    throw "'$game' does not look like a Darktide install (no Darktide.exe, bundle database or launcher)."
}

$modsRoot = $cfg.ModsRoot

# Everything this script may write is checked before any work, so a refusal never
# arrives after a long report.
$outPath = $null
$outKind = $null
if ($OutFile) {
    $ext = [System.IO.Path]::GetExtension($OutFile).ToLowerInvariant()
    if ($ext -eq '.json') { $outKind = 'json' }
    elseif ($ext -eq '.md') { $outKind = 'md' }
    else { throw "-OutFile must end in .json or .md (got '$OutFile')." }

    $outPath = Get-FullPathSafe -Path $OutFile
    if (Test-PathUnder -Path $outPath -Root $game) {
        throw "Refusing to write '$outPath' inside the game folder. Pick a path outside '$game'."
    }
    if ((Test-Path -LiteralPath $outPath) -and -not $Force) {
        throw "'$outPath' already exists. Pass -Force to overwrite it."
    }
    $outParent = Split-Path -Parent $outPath
    if ($outParent -and -not (Test-Path -LiteralPath $outParent -PathType Container)) {
        throw "Folder '$outParent' does not exist."
    }
}

$baselinePath = $null
if ($modsRoot) {
    $modsParent = Split-Path -Parent (Get-FullPathSafe -Path $modsRoot)
    if ($modsParent) { $baselinePath = Join-Path $modsParent $script:BaselineName }
}
if ($baselinePath -and (Test-PathUnder -Path $baselinePath -Root $game)) {
    # ModsRoot pointed into the game folder. Reading is harmless, but -Remember
    # would write a file Steam does not own into the install, so refuse that.
    if ($Remember) {
        throw "The baseline would land at '$baselinePath', inside the game folder. Point ModsRoot at a staging folder outside '$game'."
    }
}
if ($Remember -and -not $baselinePath) {
    throw "-Remember needs ModsRoot in config.json (or -StagingMods): the baseline is stored beside the staging folder."
}
if ($Remember -and -not (Test-Path -LiteralPath (Split-Path -Parent $baselinePath) -PathType Container)) {
    throw "Folder '$(Split-Path -Parent $baselinePath)' does not exist, so the baseline has nowhere to go. Check ModsRoot in config.json."
}

$findings = New-Object System.Collections.Generic.List[object]
$next     = New-Object System.Collections.Generic.List[string]
function Add-Finding {
    param([ValidateSet('OK', 'INFO', 'WARN', 'ERROR')][string] $Level, [string] $Message)
    $findings.Add([pscustomobject]@{ level = $Level; message = $Message })
    switch ($Level) {
        'OK'    { Write-Ok   "  $Message" }
        'WARN'  { Write-Warn "  $Message" }
        'ERROR' { Write-Err  "  $Message" }
        default { Write-Host "  $Message" }
    }
}

$checkedAt = [DateTime]::UtcNow

Write-Step '=== Darktide build state ==='
Write-Host "Game : $game"
Write-Host ''

# ---- 1. Steam app manifest -----------------------------------------------------------

Write-Step 'Steam manifest'

$acfPath = $ManifestPath
if (-not $acfPath) {
    # <lib>\steamapps\common\<installdir>  ->  <lib>\steamapps\appmanifest_<id>.acf
    $common    = Split-Path -Parent $game
    $steamapps = if ($common) { Split-Path -Parent $common } else { $null }
    if ($steamapps) { $acfPath = Join-Path $steamapps "appmanifest_$($script:AppId).acf" }
}

$steam = [ordered]@{
    manifestPath  = $acfPath
    status        = 'MISSING'
    appid         = $null
    installdir    = $null
    buildid       = $null
    targetBuildId = $null
    stateFlags    = $null
    lastUpdated   = $null
}
$lastUpdatedUtc = $null
$pending = $false

if ($acfPath -and (Test-Path -LiteralPath $acfPath -PathType Leaf)) {
    $acf = $null
    try { $acf = Read-SteamManifest -Path $acfPath } catch {
        Add-Finding WARN "could not read '$acfPath': $($_.Exception.Message)"
    }
    if ($acf) {
        $steam.status        = 'OK'
        $steam.appid         = $acf['appid']
        $steam.installdir    = $acf['installdir']
        $steam.buildid       = $acf['buildid']
        $steam.targetBuildId = $acf['targetbuildid']
        $steam.stateFlags    = $acf['stateflags']
        $lastUpdatedUtc      = ConvertFrom-UnixTime -Seconds $acf['lastupdated']
        $steam.lastUpdated   = Format-Utc $lastUpdatedUtc

        if ($steam.appid -and $steam.appid -ne $script:AppId) {
            Add-Finding WARN "'$acfPath' is for app $($steam.appid), not Darktide ($($script:AppId)). Ignoring it."
            $steam.status = 'WRONG APP'
            # Drop every value read from it, so none reaches the report, the baseline
            # comparison or -Remember.
            $lastUpdatedUtc      = $null
            $steam.lastUpdated   = $null
            $steam.installdir    = $null
            $steam.buildid       = $null
            $steam.targetBuildId = $null
            $steam.stateFlags    = $null
        } else {
            Write-Host "  manifest     : $acfPath"
            Write-Host "  build id     : $(if ($steam.buildid) { $steam.buildid } else { '(not in manifest)' })"
            Write-Host "  last updated : $(if ($steam.lastUpdated) { $steam.lastUpdated } else { '(not in manifest)' })"

            $leaf = Split-Path -Leaf $game
            if ($steam.installdir -and -not $steam.installdir.Equals($leaf, [StringComparison]::OrdinalIgnoreCase)) {
                Add-Finding WARN "manifest installdir '$($steam.installdir)' is not the game folder name '$leaf' - is this the right library?"
            }

            # StateFlags 4 is "fully installed". Anything else (1026, 6, ...) means
            # Steam has an update queued or running. A TargetBuildID of 0 means no
            # target is set, which is not a pending update.
            $reasons = @()
            if ($null -ne $steam.stateFlags -and "$($steam.stateFlags)".Trim() -ne '4') {
                $reasons += "StateFlags is $($steam.stateFlags), not 4 (fully installed)"
            }
            $target = "$($steam.targetBuildId)".Trim()
            if ($steam.buildid -and $target -and $target -ne '0' -and $target -ne "$($steam.buildid)".Trim()) {
                $reasons += "target build $target differs from installed build $($steam.buildid)"
            }
            if ($reasons) {
                $pending = $true
                $steam.status = 'PENDING'
                Add-Finding WARN "Steam reports an update in progress or pending: $($reasons -join '; ')."
            } else {
                Add-Finding OK 'Steam reports the game fully installed, no update pending.'
            }
        }
    }
} else {
    $where = if ($acfPath) { "'$acfPath'" } else { 'next to the game folder' }
    Add-Finding WARN "not a Steam install or manifest not found ($where). Pass -ManifestPath if your library is elsewhere. Continuing without it."
}
Write-Host ''

# ---- 2. Bundle database fingerprint -------------------------------------------------

Write-Step 'Bundle database'

$dbPath = Join-Path $game 'bundle\bundle_database.data'
$db = Get-FileFingerprint -Path $dbPath
$bundleDb = [ordered]@{
    path             = $dbPath
    present          = [bool]$db
    length           = $null
    lastWriteTimeUtc = $null
    sha256           = $null
}
$dbMissing = $false
if ($db) {
    $bundleDb.length           = $db.Length
    $bundleDb.lastWriteTimeUtc = Format-Utc $db.LastWriteTimeUtc
    $bundleDb.sha256           = $db.Sha256
    Write-Host "  size         : $($db.Length) bytes"
    Write-Host "  last written : $($bundleDb.lastWriteTimeUtc)"
    if ($db.Sha256) { Write-Host "  sha256       : $($db.Sha256)" }
    else { Add-Finding WARN "could not hash the bundle database ($($db.HashError)). Is the game running?" }
} else {
    $dbMissing = $true
    Add-Finding ERROR "bundle\bundle_database.data is missing. Verify the game files in Steam."
}
Write-Host ''

# ---- 3. Loader state and patch status -----------------------------------------------

Write-Step 'Mod loader'

$statePath = Join-Path $game $script:LoaderState
$state = $null
$stateReadable = $false
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $stateReadable = ($null -ne $state)
    } catch {
        Add-Finding WARN "$($script:LoaderState) is unreadable: $($_.Exception.Message)"
    }
}

$loaderVersion   = Get-ObjectField $state 'version'
$installedAtUtc  = ConvertTo-UtcDate (Get-ObjectField $state 'installedAt')
$recorded        = Get-ObjectField $state 'bundleDb'
$recordedSha     = "$(Get-ObjectField $recorded 'sha256')".Trim().ToLowerInvariant()
$recordedAtUtc   = ConvertTo-UtcDate (Get-ObjectField $recorded 'recordedAt')
$patchedFlag     = Get-ObjectField $state 'patched'

if ($stateReadable) {
    Write-Host "  version      : $(if ($loaderVersion) { $loaderVersion } else { '(not recorded)' })"
    Write-Host "  installed at : $(if ($installedAtUtc) { Format-Utc $installedAtUtc } else { '(not recorded)' })"
}

# Loader files. The same set Install-DarktideLoader.ps1 copies, item by item.
$loaderFiles = @(
    @{ Name = 'binaries\mod_loader';      Present = (Test-Path -LiteralPath (Join-Path $game 'binaries\mod_loader')) },
    @{ Name = 'bundle\*.patch_999';       Present = (@(Get-ChildItem -LiteralPath (Join-Path $game 'bundle') -Filter '*.patch_999' -File -ErrorAction SilentlyContinue).Count -gt 0) },
    @{ Name = 'tools\dtkit-patch.exe';    Present = (Test-Path -LiteralPath (Join-Path $game 'tools\dtkit-patch.exe') -PathType Leaf) },
    @{ Name = 'toggle_darktide_mods.bat'; Present = (Test-Path -LiteralPath (Join-Path $game 'toggle_darktide_mods.bat') -PathType Leaf) }
)
$missingFiles = @($loaderFiles | Where-Object { -not $_.Present } | ForEach-Object { $_.Name })
$loaderAbsent = ($missingFiles.Count -eq $loaderFiles.Count) -and -not $stateReadable

if ($loaderAbsent) {
    Add-Finding ERROR 'the mod loader is not installed (no loader files, no state file).'
} elseif ($missingFiles) {
    Add-Finding ERROR "loader files missing: $($missingFiles -join ', ')"
} else {
    Add-Finding OK 'loader files present.'
}

# Patch status: certain when the loader recorded the database's hash after
# patching; a guess from timestamps when it did not.
$patchStatus = 'UNKNOWN'
$heuristic   = $false
if ($dbMissing) {
    $patchStatus = 'DB MISSING'
} elseif ($recordedSha -and $db.Sha256) {
    if ($recordedSha -eq $db.Sha256) {
        $patchStatus = 'PATCHED'
        Add-Finding OK "PATCHED: the bundle database matches the hash recorded after the last patch$(if ($recordedAtUtc) { " ($(Format-Utc $recordedAtUtc))" })."
    } else {
        $patchStatus = 'DB REPLACED'
        Add-Finding ERROR 'DB REPLACED: the bundle database differs from the one recorded after the last patch - most likely a Steam update or file verify. Mods will not load until it is patched again.'
    }
} elseif ($recordedSha) {
    Add-Finding WARN 'a patched hash is recorded, but the current database could not be hashed to compare.'
} elseif ($stateReadable -and $installedAtUtc) {
    $heuristic = $true
    if ($db.LastWriteTimeUtc -gt $installedAtUtc) {
        $patchStatus = 'LIKELY UPDATED'
        Add-Finding WARN "LIKELY UPDATED (heuristic): the bundle database was written at $(Format-Utc $db.LastWriteTimeUtc), after the loader was installed at $(Format-Utc $installedAtUtc). A Steam update does that, and so does re-patching by hand, so this is a guess, not a verdict."
    } else {
        $patchStatus = 'LIKELY PATCHED'
        Add-Finding INFO 'LIKELY PATCHED (heuristic): the bundle database has not been written since the loader was installed. No patch hash is recorded, so this is a guess from timestamps.'
    }
} elseif ($stateReadable) {
    Add-Finding WARN "$($script:LoaderState) records neither a patch hash nor an install time - patch state unknown."
} elseif (-not $loaderAbsent) {
    $hint = if ($pending) { '' } else { " Run '.\darktide.ps1 loader -Apply -Force' once to start tracking it." }
    Add-Finding WARN "no $($script:LoaderState) - patch state unknown.$hint"
}
if ($null -ne $patchedFlag -and $patchedFlag -eq $false -and $patchStatus -ne 'DB MISSING') {
    Add-Finding WARN 'the loader was recorded as installed without patching (-SkipPatch).'
}
Write-Host ''

# ---- 4. Remembered baseline --------------------------------------------------------

Write-Step 'Remembered baseline'

$baseline = [ordered]@{
    path       = $baselinePath
    found      = $false
    previous   = $null
    comparison = $null
    remembered = $false
}
$changedSinceBaseline = $false
if (-not $baselinePath) {
    Add-Finding INFO 'no ModsRoot configured, so there is nowhere to keep a baseline.'
} elseif (Test-Path -LiteralPath $baselinePath -PathType Leaf) {
    $prev = $null
    try { $prev = Get-Content -LiteralPath $baselinePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {
        Add-Finding WARN "baseline '$baselinePath' is unreadable: $($_.Exception.Message)"
    }
    if ($prev) {
        $baseline.found = $true
        $prevBuild   = "$(Get-ObjectField $prev 'buildid')".Trim()
        $prevDb      = Get-ObjectField $prev 'bundleDb'
        $prevSha     = "$(Get-ObjectField $prevDb 'sha256')".Trim().ToLowerInvariant()
        $prevChecked = ConvertTo-UtcDate (Get-ObjectField $prev 'checkedAt')
        $when        = if ($prevChecked) { " ($(Format-Utc $prevChecked))" } else { '' }
        $baseline.previous = [ordered]@{
            buildid   = $(if ($prevBuild) { $prevBuild } else { $null })
            sha256    = $(if ($prevSha) { $prevSha } else { $null })
            checkedAt = Format-Utc $prevChecked
        }

        $nowBuild = "$($steam.buildid)".Trim()
        if ($prevBuild -and $nowBuild -and $prevBuild -ne $nowBuild) {
            $changedSinceBaseline = $true
            $baseline.comparison = "build changed since last remembered check$($when): $prevBuild -> $nowBuild"
            Add-Finding WARN $baseline.comparison
        } elseif ($prevSha -and $db -and $db.Sha256 -and $prevSha -ne $db.Sha256) {
            $changedSinceBaseline = $true
            $baseline.comparison = "bundle database changed since last remembered check$when"
            Add-Finding WARN $baseline.comparison
        } elseif ($prevBuild -or $prevSha) {
            $baseline.comparison = "unchanged since last remembered check$when"
            Add-Finding OK $baseline.comparison
        } else {
            $baseline.comparison = 'baseline has nothing to compare against'
            Add-Finding INFO $baseline.comparison
        }
    }
} else {
    Add-Finding INFO "none yet. '.\darktide.ps1 patchcheck -Remember' records one at $baselinePath"
}
Write-Host ''

# ---- 5. Staged mods installed before the last game update ---------------------------

Write-Step 'Staged mods vs the last game update (heuristic)'

$pinned = @{}
if ($MapPath -and (Test-Path -LiteralPath $MapPath -PathType Leaf)) {
    try {
        $rawMap = Get-Content -LiteralPath $MapPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($prop in $rawMap.PSObject.Properties) {
            if ((Get-ObjectField $prop.Value 'pinned') -eq $true) { $pinned[$prop.Name] = $true }
        }
    } catch { Add-Finding WARN "mods-map.json is not valid JSON - pinned flags ignored." }
}

$staleRows = New-Object System.Collections.Generic.List[object]
$stale = [ordered]@{
    basis       = Format-Utc $lastUpdatedUtc
    note        = 'Heuristic: compares each mod''s recorded install time with the time Steam last updated the game. PREDATES-PATCH means installed before the game last updated; it says nothing about whether the mod still works or has an update.'
    mods        = $staleRows
}

if (-not $modsRoot -or -not (Test-Path -LiteralPath $modsRoot -PathType Container)) {
    Add-Finding INFO "staging folder not found$(if ($modsRoot) { " ('$modsRoot')" }) - skipped."
} else {
    $dirs = @(Get-ChildItem -LiteralPath $modsRoot -Directory -ErrorAction SilentlyContinue |
              Where-Object { -not $_.Name.StartsWith('.') -and $_.Name -ne 'base' } |
              Sort-Object Name)
    foreach ($d in $dirs) {
        $status = 'UNKNOWN'
        $installed = $null
        $meta = Join-Path $d.FullName '.nexus-mod.json'
        if ($pinned.ContainsKey($d.Name)) {
            $status = 'PINNED'
        }
        if (Test-Path -LiteralPath $meta -PathType Leaf) {
            try {
                $m = Get-Content -LiteralPath $meta -Raw -Encoding UTF8 | ConvertFrom-Json
                $installed = ConvertTo-UtcDate (Get-ObjectField $m 'installedAt')
            } catch { $installed = $null }
        }
        if ($status -ne 'PINNED' -and $installed -and $lastUpdatedUtc) {
            $status = if ($installed -lt $lastUpdatedUtc) { 'PREDATES-PATCH' } else { 'OK' }
        }
        $staleRows.Add([pscustomobject]@{
            folder      = $d.Name
            status      = $status
            installedAt = Format-Utc $installed
        })
    }

    if (-not $lastUpdatedUtc) {
        Add-Finding INFO 'no game update time from the Steam manifest, so install times cannot be compared.'
    }
    if ($staleRows.Count) {
        Write-Host (($staleRows | Format-Table -AutoSize -Property folder, status, installedAt | Out-String -Width 200).TrimEnd())
    } else {
        Add-Finding INFO 'no staged mods.'
    }
}

$older = @($staleRows | Where-Object { $_.status -eq 'PREDATES-PATCH' } | ForEach-Object { $_.folder })
if ($older) {
    Add-Finding INFO "$($older.Count) mod(s) were installed before the game last updated. If something misbehaves, look at those first."
}
Write-Host ''

# ---- Verdict -----------------------------------------------------------------------

$actionNeeded = $false

if ($pending) {
    # Patching a database Steam is about to replace is wasted at best, so no
    # -Apply step is offered until Steam has finished.
    # Exit 0 on purpose: a script that re-patches on exit 1 must not do it while
    # Steam is still writing the game files.
    $verdict = 'UPDATE PENDING'
    $next.Add('Let Steam finish updating Darktide, then run: .\darktide.ps1 patchcheck')
} else {
    if ($dbMissing) {
        $actionNeeded = $true
        $next.Add('Verify the game files in Steam (Properties > Installed Files), then run: .\darktide.ps1 patchcheck')
    }
    if ($loaderAbsent) {
        $actionNeeded = $true
        $next.Add('.\darktide.ps1 loader -Apply              install the mod loader')
    } elseif ($missingFiles) {
        $actionNeeded = $true
        $next.Add('.\darktide.ps1 loader -Apply -Force       loader files are missing - reinstall them')
    }
    if ($patchStatus -eq 'DB REPLACED') {
        $actionNeeded = $true
        if (-not $missingFiles) {
            $next.Add('.\darktide.ps1 loader -PatchOnly -Apply   re-apply the bundle patch')
        }
    }
    if ($patchStatus -eq 'LIKELY UPDATED') {
        $next.Add('.\darktide.ps1 loader -PatchOnly -Apply   if mods do not load (the check above is a guess)')
    }
    if ($actionNeeded) {
        $verdict = 'ACTION NEEDED'
    } elseif ($patchStatus -eq 'PATCHED') {
        $verdict = 'IN SYNC'
    } else {
        $verdict = 'UNKNOWN'
    }
    if ($older) {
        # Folder names may hold spaces or brackets; quote those so the line pastes.
        $onlyArgs = @($older | ForEach-Object {
            if ($_ -match '^[\w.-]+$') { $_ } else { "'" + ($_ -replace "'", "''") + "'" }
        })
        $next.Add(".\darktide.ps1 links -Only $($onlyArgs -join ',')   Nexus pages for the mods installed before the update")
    }
    if (-not $actionNeeded -and $baselinePath -and -not $Remember -and (-not $baseline.found -or $changedSinceBaseline)) {
        $next.Add('.\darktide.ps1 patchcheck -Remember       record this build as the baseline for next time')
    }
}

$exitCode = if ($actionNeeded) { 1 } else { 0 }

# ---- Remember ----------------------------------------------------------------------

if ($Remember) {
    if ($pending) {
        Add-Finding WARN 'not remembering: Steam is still updating, so this is not a build worth comparing against.'
    } else {
        $record = [ordered]@{
            schemaVersion = 1
            gamePath      = $game
            buildid       = $steam.buildid
            lastUpdated   = $steam.lastUpdated
            bundleDb      = [ordered]@{
                sha256           = $bundleDb.sha256
                length           = $bundleDb.length
                lastWriteTimeUtc = $bundleDb.lastWriteTimeUtc
            }
            checkedAt     = Format-Utc $checkedAt
        }
        $record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $baselinePath -Encoding UTF8
        $baseline.remembered = $true
        Add-Finding OK "remembered this build as the baseline -> $baselinePath"
    }
}

# ---- Summary -----------------------------------------------------------------------

Write-Host ''
switch ($verdict) {
    'IN SYNC'        { Write-Ok   "Result: IN SYNC - the loader patch matches the current game build." }
    'ACTION NEEDED'  { Write-Err  "Result: ACTION NEEDED" }
    'UPDATE PENDING' { Write-Warn "Result: UPDATE PENDING - Steam has not finished. Do not patch yet." }
    default          { Write-Warn "Result: UNKNOWN - nothing certain to act on. See the warnings above." }
}
if ($next.Count) {
    Write-Host ''
    Write-Step 'Next:'
    foreach ($n in $next) { Write-Host "  $n" }
}

$report = [ordered]@{
    schemaVersion = 1
    checkedAt     = Format-Utc $checkedAt
    gamePath      = $game
    verdict       = $verdict
    exitCode      = $exitCode
    steam         = $steam
    bundleDb      = $bundleDb
    loader        = [ordered]@{
        stateFile        = $statePath
        stateFound       = $stateReadable
        version          = $(if ($loaderVersion) { "$loaderVersion" } else { $null })
        installedAt      = Format-Utc $installedAtUtc
        recordedSha256   = $(if ($recordedSha) { $recordedSha } else { $null })
        recordedAt       = Format-Utc $recordedAtUtc
        patchStatus      = $patchStatus
        heuristic        = $heuristic
        missingFiles     = $missingFiles
    }
    baseline      = $baseline
    staleMods     = $stale
    findings      = $findings
    next          = $next
}

if ($outPath) {
    if ($outKind -eq 'json') {
        $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $outPath -Encoding UTF8
    } else {
        $md = New-Object System.Collections.Generic.List[string]
        $md.Add('# Darktide build state')
        $md.Add('')
        $md.Add("Checked $($report.checkedAt). Result: **$verdict**.")
        $md.Add('')
        $md.Add('| | |')
        $md.Add('|---|---|')
        $tick       = [string][char]96
        $mdManifest = $steam.status
        if ($steam.manifestPath) { $mdManifest = "$mdManifest ($tick$($steam.manifestPath)$tick)" }
        $mdSha      = '-'
        if ($bundleDb.sha256) { $mdSha = "$tick$($bundleDb.sha256)$tick" }
        $md.Add("| Game folder | $tick$game$tick |")
        $md.Add("| Steam manifest | $mdManifest |")
        $md.Add("| Build id | $(if ($steam.buildid) { $steam.buildid } else { '-' }) |")
        $md.Add("| Last updated | $(if ($steam.lastUpdated) { $steam.lastUpdated } else { '-' }) |")
        $md.Add("| Bundle database sha256 | $mdSha |")
        $md.Add("| Patch status | $patchStatus$(if ($heuristic) { ' (heuristic)' }) |")
        $md.Add("| Missing loader files | $(if ($missingFiles) { $missingFiles -join ', ' } else { 'none' }) |")
        $md.Add("| Baseline | $(if ($baseline.comparison) { $baseline.comparison } else { 'none' }) |")
        $md.Add('')
        $md.Add('## Findings')
        $md.Add('')
        foreach ($f in $findings) { $md.Add("- **$($f.level)** $($f.message)") }
        $md.Add('')
        $md.Add('## Staged mods vs the last game update')
        $md.Add('')
        $md.Add("_$($stale.note)_")
        $md.Add('')
        if ($staleRows.Count) {
            $md.Add('| Mod | Status | Installed |')
            $md.Add('|---|---|---|')
            foreach ($r in $staleRows) {
                $md.Add("| $($r.folder) | $($r.status) | $(if ($r.installedAt) { $r.installedAt } else { '-' }) |")
            }
        } else {
            $md.Add('No staged mods to compare.')
        }
        if ($next.Count) {
            $md.Add('')
            $md.Add('## Next')
            $md.Add('')
            $md.Add('```powershell')
            foreach ($n in $next) { $md.Add($n) }
            $md.Add('```')
        }
        Set-Content -LiteralPath $outPath -Value $md -Encoding UTF8
    }
    Write-Host ''
    Write-Host "Wrote $outPath"
}

exit $exitCode
