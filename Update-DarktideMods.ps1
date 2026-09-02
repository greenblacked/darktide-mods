<#
.SYNOPSIS
    Darktide mod updater. Checks installed DMF mods against Nexus Mods and installs
    newer versions while preserving the mods/<ModName>/ folder structure.

.DESCRIPTION
    Default mode is a read-only check. Nothing is written to the mods tree unless -Apply
    is passed. Every install is preceded by a zip backup of the existing mod folder, and
    -Rollback -Apply restores from those backups.

    Designed for a NON-PREMIUM Nexus account. The Nexus API refuses to hand direct
    download links to free accounts (HTTP 403 on /download_link.json), so this script:
      1. uses the API for version metadata only (allowed for free accounts), then
      2. installs from archives you downloaded yourself into -DownloadDir.
.PARAMETER Apply
    Actually install updates. Without it the script only reports.

.PARAMETER NoApi
    Work with no Nexus API key and no network at all. The script reads the version out of
    each archive in -DownloadDir (from the info.json inside it, or the stock Nexus filename),
    compares it against what is installed, and installs only what is newer. You lose only
    one thing: it cannot tell you that a newer version exists on Nexus that you have not
    downloaded yet. This mode is selected automatically when no API key is configured.

.PARAMETER Force
    In -NoApi mode, install an archive even when it is the same version or older than what
    is installed, or when its version cannot be determined. Use for repairs and downgrades.

.PARAMETER Rollback
    Restore mod folders from a backup set instead of updating. Writes nothing
    without -Apply; the dry run lists the set.

.PARAMETER KeepBackups
    How many timestamped backup-set folders to keep under BackupRoot. Default 10.
    0 keeps all.

.PARAMETER Resolve
    Try to map local folder names to Nexus mod IDs and write them to mods-map.json.

.PARAMETER BuildCatalog
    Crawl the Nexus mod list for the game into a local cache so -Resolve can match
    names. Resumable and rate-limit aware; safe to run repeatedly.

.PARAMETER OpenPages
    Open the Nexus files page for every outdated mod in the default browser.
    Free-account workflow: click Manual Download on each, then re-run with -Apply.

.EXAMPLE
    .\Update-DarktideMods.ps1
    Read-only check of every mod against Nexus.

.EXAMPLE
    .\Update-DarktideMods.ps1 -OpenPages
    Check, then open the download page for each outdated mod.

.EXAMPLE
    .\Update-DarktideMods.ps1 -Apply
    Install any newer archives found in the download folder, with backups.

.EXAMPLE
    .\Update-DarktideMods.ps1 -NoApi
    No key needed. Reports what the archives in your download folder would do.

.EXAMPLE
    .\Update-DarktideMods.ps1 -NoApi -Apply
    Installs every archive in the download folder that is newer than what you have.

.EXAMPLE
    .\Update-DarktideMods.ps1 -Rollback
    List the newest backup set. Nothing is written.

.EXAMPLE
    .\Update-DarktideMods.ps1 -Rollback -Apply
    Restore every mod folder from the most recent backup set.

.NOTES
    Requires Windows PowerShell 5.1 or PowerShell 7+. No external modules.
    Nexus API endpoints are stable but not versioned aggressively - if a call starts
    failing, verify the shape against https://api-docs.nexusmods.com/
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]   $ConfigPath    = (Join-Path $PSScriptRoot 'config.json'),
    [string]   $ModsRoot,
    [string]   $DownloadDir,
    [string]   $BackupRoot,
    [string]   $GameDomain,
    [string[]] $Only,
    [string[]] $Skip,

    [switch]   $Apply,
    [switch]   $NoApi,
    [switch]   $Force,
    [switch]   $Rollback,
    [string]   $BackupSet,
    [switch]   $Resolve,
    [switch]   $BuildCatalog,
    [switch]   $OpenPages,
    [switch]   $NoLoadOrderUpdate,
    [int]      $CatalogMaxRequests = 400,

    [ValidateRange(0, 1000)]
    [int]      $KeepBackups = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# TLS 1.2 - Windows PowerShell 5.1 still defaults to SSL3/TLS1.0 on some builds.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

# ----------------------------------------------------------------------------------
# Constants
# ----------------------------------------------------------------------------------

$script:ApiBase       = 'https://api.nexusmods.com/v1'
$script:AppName       = 'DarktideModUpdater'
$script:AppVersion    = '1.0.0'
# Folders that ship with the mod loader / framework and are not standalone Nexus mods
# in the same sense. 'dmf' IS on Nexus and IS checked; 'base' is part of the loader.
$script:IgnoreFolders = @('base')
$script:RateLimit     = @{ HourlyRemaining = $null; DailyRemaining = $null }
$script:Stats         = @{ Checked = 0; Outdated = 0; Updated = 0; Failed = 0; Unmapped = 0 }
$script:PinnedFolders = @()
$script:OfflineInstalled = New-Object System.Collections.Generic.List[string]

# ----------------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------------

$script:LogFile = $null

function Initialize-Log {
    param([string] $Root)
    $dir = Join-Path $Root 'logs'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $script:LogFile = Join-Path $dir ('update-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    # Prune logs older than 30 days
    Get-ChildItem -LiteralPath $dir -Filter 'update-*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string] $Message,
        [ValidateSet('INFO','WARN','ERROR','OK','STEP')][string] $Level = 'INFO'
    )
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'OK'    { Write-Host $line -ForegroundColor Green }
        'STEP'  { Write-Host $line -ForegroundColor Cyan }
        default { Write-Host $line }
    }
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 }
}

# ----------------------------------------------------------------------------------
# Config
# ----------------------------------------------------------------------------------

function Get-Configuration {
    param([string] $Path)

    $cfg = [ordered]@{
        ModsRoot    = ''
        DownloadDir = (Join-Path $env:USERPROFILE 'Downloads')
        BackupRoot  = ''
        GameDomain  = 'warhammer40kdarktide'
        ApiKey      = ''
        MapPath     = (Join-Path $PSScriptRoot 'mods-map.json')
        CatalogPath = (Join-Path $PSScriptRoot 'nexus-catalog.json')
    }

    if (Test-Path -LiteralPath $Path) {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ($raw.Trim()) {
            $json = $raw | ConvertFrom-Json
            foreach ($k in @($cfg.Keys)) {
                if ($json.PSObject.Properties.Name -contains $k) {
                    $v = $json.$k
                    if ($null -ne $v -and "$v".Trim() -ne '') { $cfg[$k] = "$v" }
                }
            }
        }
    } else {
        Write-Log "No config at '$Path' - using defaults and parameters." 'WARN'
    }

    # Parameters win over the config file.
    if ($ModsRoot)    { $cfg.ModsRoot    = $ModsRoot }
    if ($DownloadDir) { $cfg.DownloadDir = $DownloadDir }
    if ($BackupRoot)  { $cfg.BackupRoot  = $BackupRoot }
    if ($GameDomain)  { $cfg.GameDomain  = $GameDomain }

    # The key deliberately has no -ApiKey parameter: anything passed on the command line
    # is visible in process listings and lands in shell history. Environment variable
    # first, config file second.
    # Environment variable is the preferred place for the key - keeps it out of the repo.
    if (-not $cfg.ApiKey -and $env:NEXUS_API_KEY) { $cfg.ApiKey = $env:NEXUS_API_KEY }

    if (-not $cfg.ModsRoot) {
        throw "ModsRoot is not set. Put it in config.json or pass -ModsRoot 'D:\Darktide\mods'."
    }
    $cfg.ModsRoot = (Resolve-Path -LiteralPath $cfg.ModsRoot).Path

    if (-not $cfg.BackupRoot) {
        $cfg.BackupRoot = Join-Path (Split-Path -Parent $cfg.ModsRoot) 'mod_backups'
    }

    return $cfg
}

function Test-ModsRoot {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "ModsRoot '$Path' does not exist."
    }
    $loadOrder = Join-Path $Path 'mod_load_order.txt'
    $baseDir   = Join-Path $Path 'base'
    if (-not (Test-Path -LiteralPath $loadOrder) -and -not (Test-Path -LiteralPath $baseDir)) {
        throw "'$Path' does not look like a Darktide Mod Loader mods folder (no mod_load_order.txt and no base\). Refusing to touch it."
    }
}

function Assert-GameNotRunning {
    # Twin of the copy in Deploy-DarktideMods.ps1 - keep the two identical.
    $proc = Get-Process -Name 'Darktide' -ErrorAction SilentlyContinue
    if ($proc) {
        throw "Darktide.exe is running (PID $($proc.Id -join ', ')). Close the game before changing mod files."
    }
}

# ----------------------------------------------------------------------------------
# Nexus API
# ----------------------------------------------------------------------------------

function Update-RateLimit {
    <#
      Reads the X-RL-* budget headers. Handles both header shapes:
      PS 5.1 gives string values, PS 7 gives string collections.
      Also tolerates WebHeaderCollection (no .Keys enumeration on some runtimes).
    #>
    param($Headers)
    if (-not $Headers) { return }
    foreach ($h in @(
        @{ Name = 'X-RL-Hourly-Remaining'; Slot = 'HourlyRemaining' },
        @{ Name = 'X-RL-Daily-Remaining';  Slot = 'DailyRemaining'  })) {
        try {
            $raw = $Headers[$h.Name]
            if ($null -eq $raw) { continue }
            $val = @($raw)[0]
            if ("$val" -match '^\d+$') { $script:RateLimit[$h.Slot] = [int]"$val" }
        } catch { }
    }
}

function Invoke-NexusApi {
    <#
      Thin wrapper over the Nexus v1 REST API.
      Returns $null on 404 / 403 rather than throwing, so callers can degrade gracefully.
    #>
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Key,
        [switch] $AllowFailure
    )

    $uri = "$script:ApiBase/$($Path.TrimStart('/'))"
    $headers = @{
        'apikey'              = $Key
        'Accept'              = 'application/json'
        'Application-Name'    = $script:AppName
        'Application-Version' = $script:AppVersion
    }

    try {
        $resp = Invoke-WebRequest -Uri $uri -Headers $headers -Method Get -UseBasicParsing -TimeoutSec 45
    } catch {
        $status   = $null
        $response = $null
        if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
            $response = $_.Exception.Response
            try { $status = [int]$response.StatusCode } catch { }
        }

        # Error responses still carry the rate-limit headers. Reading them here is what
        # keeps -BuildCatalog honest, since most of its responses are 404s.
        if ($response) { Update-RateLimit -Headers $response.Headers }

        if ($status -eq 429) {
            Write-Log "Nexus rate limit hit (429) on $Path. Stop and retry after the hourly reset." 'ERROR'
            throw 'NEXUS_RATE_LIMIT'
        }
        if ($null -eq $status) {
            # No HTTP response at all: DNS, TLS, proxy or timeout. Never silently
            # report this as "mod not found" or "key rejected".
            throw "Network error calling Nexus ($Path): $($_.Exception.Message)"
        }
        if ($AllowFailure -or $status -in @(403, 404)) {
            Write-Verbose "API $Path -> HTTP $status"
            return $null
        }
        throw
    }

    Update-RateLimit -Headers $resp.Headers

    if (-not $resp.Content) { return $null }
    return ($resp.Content | ConvertFrom-Json)
}

function Test-RateBudget {
    param([int] $Need = 1)
    if ($null -ne $script:RateLimit.HourlyRemaining -and $script:RateLimit.HourlyRemaining -le $Need) {
        Write-Log "Hourly API budget exhausted ($($script:RateLimit.HourlyRemaining) left). Stopping cleanly." 'WARN'
        return $false
    }
    if ($null -ne $script:RateLimit.DailyRemaining -and $script:RateLimit.DailyRemaining -le $Need) {
        Write-Log "Daily API budget exhausted ($($script:RateLimit.DailyRemaining) left). Stopping cleanly." 'WARN'
        return $false
    }
    return $true
}

function Get-NexusAccount {
    param([string] $Key)
    $me = Invoke-NexusApi -Path 'users/validate.json' -Key $Key -AllowFailure
    if (-not $me) { throw "Nexus API key rejected. Regenerate it at https://www.nexusmods.com/users/myaccount?tab=api" }
    $premium = $false
    if ($me.PSObject.Properties.Name -contains 'is_premium') { $premium = [bool]$me.is_premium }
    return [pscustomobject]@{ Name = $me.name; IsPremium = $premium }
}

function Get-NexusMod {
    param([string] $Domain, [int] $ModId, [string] $Key)
    return Invoke-NexusApi -Path "games/$Domain/mods/$ModId.json" -Key $Key -AllowFailure
}

function Get-NexusModFiles {
    param([string] $Domain, [int] $ModId, [string] $Key)
    return Invoke-NexusApi -Path "games/$Domain/mods/$ModId/files.json?category=main,update" -Key $Key -AllowFailure
}

function Get-NexusLatestMainFile {
    <# Newest non-archived MAIN file; falls back to newest of anything returned. #>
    param($FilesResponse)
    if (-not $FilesResponse) { return $null }
    if (-not ($FilesResponse.PSObject.Properties.Name -contains 'files')) { return $null }
    if (-not $FilesResponse.files) { return $null }
    $hasCat = { param($f) $f.PSObject.Properties.Name -contains 'category_name' }
    $files = @($FilesResponse.files) | Where-Object { (& $hasCat $_) -and $_.category_name -and $_.category_name -ne 'ARCHIVED' }
    if (-not $files) { $files = @($FilesResponse.files) }
    $main = @($files) | Where-Object { (& $hasCat $_) -and $_.category_name -eq 'MAIN' }
    if ($main) { $files = $main }
    return @($files | Sort-Object -Property uploaded_timestamp -Descending)[0]
}

# ----------------------------------------------------------------------------------
# Version comparison
# ----------------------------------------------------------------------------------

function Compare-ModVersion {
    <#
      Returns 1 if A > B, -1 if A < B, 0 if equal/indeterminate.
      Handles '2.14.4', '4.7.06', 'v1.2', '26.06.24' - anything Nexus authors invent.
    #>
    param([string] $A, [string] $B)

    if (-not $A -and -not $B) { return 0 }
    if (-not $A) { return -1 }
    if (-not $B) { return 1 }
    if ($A -eq $B) { return 0 }

    $na = [regex]::Matches($A, '\d+') | ForEach-Object { [int64]$_.Value }
    $nb = [regex]::Matches($B, '\d+') | ForEach-Object { [int64]$_.Value }
    $na = @($na); $nb = @($nb)

    if ($na.Count -eq 0 -or $nb.Count -eq 0) {
        return [Math]::Sign([string]::Compare($A, $B, $true))
    }

    $len = [Math]::Max($na.Count, $nb.Count)
    for ($i = 0; $i -lt $len; $i++) {
        $x = if ($i -lt $na.Count) { $na[$i] } else { 0 }
        $y = if ($i -lt $nb.Count) { $nb[$i] } else { 0 }
        if ($x -gt $y) { return 1 }
        if ($x -lt $y) { return -1 }
    }
    return 0
}

# ----------------------------------------------------------------------------------
# Local inventory
# ----------------------------------------------------------------------------------

function Get-LocalMods {
    param([string] $ModsRoot)

    $result = New-Object System.Collections.Generic.List[object]

    foreach ($dir in Get-ChildItem -LiteralPath $ModsRoot -Directory | Sort-Object Name) {
        if ($script:IgnoreFolders -contains $dir.Name) { continue }

        $version   = $null
        $display   = $dir.Name
        $modId     = $null
        $source    = 'unknown'

        # 1. state file written by a previous run of this script
        $state = Join-Path $dir.FullName '.nexus-mod.json'
        if (Test-Path -LiteralPath $state) {
            try {
                $s = Get-Content -LiteralPath $state -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($s.PSObject.Properties.Name -contains 'version' -and $s.version) { $version = "$($s.version)"; $source = 'state' }
                if ($s.PSObject.Properties.Name -contains 'modId'   -and $s.modId)   { $modId   = [int]$s.modId }
                if ($s.PSObject.Properties.Name -contains 'name'    -and $s.name)    { $display = "$($s.name)" }
            } catch { Write-Log "Corrupt .nexus-mod.json in $($dir.Name) - ignoring." 'WARN' }
        }

        # 2. mod-authored info.json (authoritative when present)
        $info = Join-Path $dir.FullName 'info.json'
        if (Test-Path -LiteralPath $info) {
            try {
                $j = Get-Content -LiteralPath $info -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($j.PSObject.Properties.Name -contains 'version' -and $j.version) { $version = "$($j.version)"; $source = 'info.json' }
                if ($j.PSObject.Properties.Name -contains 'name'    -and $j.name)    { $display = "$($j.name)" }
                if ($j.PSObject.Properties.Name -contains 'homepage' -and $j.homepage) {
                    $m = [regex]::Match("$($j.homepage)", '/mods/(\d+)')
                    if ($m.Success) { $modId = [int]$m.Groups[1].Value }
                }
            } catch { Write-Log "Corrupt info.json in $($dir.Name) - ignoring." 'WARN' }
        }

        $result.Add([pscustomobject]@{
            Folder        = $dir.Name
            Path          = $dir.FullName
            DisplayName   = $display
            LocalVersion  = $version
            VersionSource = $source
            ModId         = $modId
        })
    }

    return $result
}

# ----------------------------------------------------------------------------------
# ID mapping
# ----------------------------------------------------------------------------------

function Get-ModMap {
    param([string] $Path)
    if (Test-Path -LiteralPath $Path) {
        try {
            $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
            if ($raw.Trim()) {
                $obj = $raw | ConvertFrom-Json
                $ht = @{}
                foreach ($p in $obj.PSObject.Properties) { $ht[$p.Name] = $p.Value }
                return $ht
            }
        } catch { Write-Log "mods-map.json is not valid JSON - starting from empty." 'WARN' }
    }
    return @{}
}

function Save-ModMap {
    param([hashtable] $Map, [string] $Path)
    $ordered = [ordered]@{}
    foreach ($k in ($Map.Keys | Sort-Object)) { $ordered[$k] = $Map[$k] }
    ($ordered | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-NormalizedName {
    param([string] $Name)
    if (-not $Name) { return '' }
    return ([regex]::Replace($Name.ToLowerInvariant(), '[^a-z0-9]', ''))
}

function Update-NexusCatalog {
    <#
      Builds/extends a local cache of { modId -> name } for the game.
      The v1 API has no search endpoint, so this walks mod IDs. It is resumable:
      each run consumes at most -CatalogMaxRequests calls and records where it stopped.
    #>
    param([string] $Domain, [string] $Key, [string] $CatalogPath, [int] $MaxRequests)

    $catalog = [ordered]@{ maxSeenId = 0; nextId = 1; updated = ''; mods = @{} }
    if (Test-Path -LiteralPath $CatalogPath) {
        try {
            $j = Get-Content -LiteralPath $CatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $catalog.maxSeenId = [int]$j.maxSeenId
            $catalog.nextId    = [int]$j.nextId
            $mods = @{}
            foreach ($p in $j.mods.PSObject.Properties) { $mods[$p.Name] = "$($p.Value)" }
            $catalog.mods = $mods
        } catch { Write-Log "Catalog cache unreadable - rebuilding from scratch." 'WARN' }
    }

    # Discover the current highest mod id so we know where the crawl ends.
    $latest = Invoke-NexusApi -Path "games/$Domain/mods/latest_added.json" -Key $Key -AllowFailure
    if ($latest) {
        $top = (@($latest) | ForEach-Object { [int]$_.mod_id } | Measure-Object -Maximum).Maximum
        if ($top -gt $catalog.maxSeenId) { $catalog.maxSeenId = $top }
    }
    if ($catalog.maxSeenId -le 0) {
        Write-Log 'Could not determine highest mod id - aborting catalog build.' 'ERROR'
        return
    }
    Write-Log "Catalog: highest known mod id is $($catalog.maxSeenId); resuming at $($catalog.nextId); cached $($catalog.mods.Count) entries." 'STEP'

    $used = 0
    while ($catalog.nextId -le $catalog.maxSeenId -and $used -lt $MaxRequests) {
        if (-not (Test-RateBudget -Need 5)) { break }
        $id = $catalog.nextId
        if (-not $catalog.mods.ContainsKey("$id")) {
            $m = Get-NexusMod -Domain $Domain -ModId $id -Key $Key
            $used++
            if ($m -and $m.PSObject.Properties.Name -contains 'name' -and $m.name) {
                $catalog.mods["$id"] = "$($m.name)"
            }
        }
        $catalog.nextId = $id + 1
        # Gate on the id, not $used - on a resumed crawl $used stays 0 over cached ids.
        if ($id % 25 -eq 0) { Write-Host "  ... $id/$($catalog.maxSeenId)" }
    }

    $catalog.updated = (Get-Date).ToString('o')
    ($catalog | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $CatalogPath -Encoding UTF8

    $done = $catalog.nextId -gt $catalog.maxSeenId
    Write-Log ("Catalog now holds {0} mods. {1}" -f $catalog.mods.Count,
        $(if ($done) { 'Crawl complete.' } else { "Run -BuildCatalog again to continue from id $($catalog.nextId)." })) 'OK'
}

function Resolve-ModIds {
    <#
      Fills in missing folder -> modId mappings using, in order:
        1. mod ids already found in info.json
        2. exact normalized-name match against the cached catalog
        3. exact normalized-name match against mods updated in the last month
      Ambiguous or missing matches are left null for you to fill in by hand.
    #>
    param(
        [object[]]  $Mods,
        [hashtable] $Map,
        [string]    $Domain,
        [string]    $Key,
        [string]    $CatalogPath
    )

    # Load catalog -> normalized name -> list of ids
    $byName = @{}
    if (Test-Path -LiteralPath $CatalogPath) {
        try {
            $j = Get-Content -LiteralPath $CatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $j.mods.PSObject.Properties) {
                $n = Get-NormalizedName "$($p.Value)"
                if (-not $n) { continue }
                if (-not $byName.ContainsKey($n)) { $byName[$n] = New-Object System.Collections.Generic.List[int] }
                $byName[$n].Add([int]$p.Name)
            }
        } catch { Write-Log 'Catalog unreadable during resolve - skipping catalog matching.' 'WARN' }
    }

    # Recently updated mods: small set, cheap, and exactly the ones that matter.
    $recent = Invoke-NexusApi -Path "games/$Domain/mods/updated.json?period=1m" -Key $Key -AllowFailure
    $recentIds = @()
    if ($recent) { $recentIds = @($recent | ForEach-Object { [int]$_.mod_id }) }

    $resolved = 0
    foreach ($m in $Mods) {
        if ($Map.ContainsKey($m.Folder) -and
            ($Map[$m.Folder].PSObject.Properties.Name -contains 'modId') -and
            $Map[$m.Folder].modId) { continue }

        $id = $m.ModId
        if (-not $id -and $byName.Count -gt 0) {
            foreach ($candidate in @($m.DisplayName, $m.Folder, ($m.Folder -replace '_', ' '))) {
                $n = Get-NormalizedName $candidate
                if ($n -and $byName.ContainsKey($n) -and $byName[$n].Count -eq 1) { $id = $byName[$n][0]; break }
            }
        }

        if (-not $id -and $recentIds.Count -gt 0 -and $recentIds.Count -le 400) {
            foreach ($rid in $recentIds) {
                if (-not (Test-RateBudget -Need 5)) { break }
                $info = Get-NexusMod -Domain $Domain -ModId $rid -Key $Key
                if (-not $info) { continue }
                if (-not ($info.PSObject.Properties.Name -contains 'name') -or -not $info.name) { continue }
                $n = Get-NormalizedName "$($info.name)"
                if ($n -eq (Get-NormalizedName $m.DisplayName) -or $n -eq (Get-NormalizedName $m.Folder)) { $id = $rid; break }
            }
        }

        # Never clobber a user-set 'pinned' flag on an entry we are only filling in.
        $wasPinned = $false
        if ($Map.ContainsKey($m.Folder)) {
            $prev = $Map[$m.Folder]
            if ($prev.PSObject.Properties.Name -contains 'pinned') { $wasPinned = [bool]$prev.pinned }
        }

        $entry = [ordered]@{
            modId  = $(if ($id) { [int]$id } else { $null })
            name   = $m.DisplayName
            note   = $(if ($id) { '' } else { "unresolved - find the id at https://www.nexusmods.com/games/$Domain/mods?keyword=$([uri]::EscapeDataString($m.DisplayName))" })
            pinned = $wasPinned
        }
        $Map[$m.Folder] = [pscustomobject]$entry
        if ($id) { $resolved++; Write-Log "Mapped $($m.Folder) -> mod $id" 'OK' }
    }

    Write-Log "Resolve pass complete: $resolved new mapping(s)." 'STEP'
    return $Map
}

# ----------------------------------------------------------------------------------
# Archive handling
# ----------------------------------------------------------------------------------

function Get-ArchiveModLayout {
    <#
      Inspects a zip and works out which internal directory is the mod root.
      DMF requires the folder name to equal the name in <Name>.mod, so the .mod
      file is the authority - not the archive's top folder or the file name.
    #>
    param([string] $ZipPath)

    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        $modEntry = $zip.Entries |
            Where-Object { $_.FullName -match '\.mod$' -and $_.FullName -notmatch '(^|/)base/' } |
            Sort-Object { ($_.FullName -split '/').Count } |
            Select-Object -First 1
        if (-not $modEntry) { return $null }

        $parts    = $modEntry.FullName -split '/'
        $modName  = [System.IO.Path]::GetFileNameWithoutExtension($modEntry.Name)
        $prefix   = if ($parts.Count -gt 1) { ($parts[0..($parts.Count - 2)] -join '/') + '/' } else { '' }

        # Hard guard: this name becomes a folder that gets deleted and recreated.
        # Never let a malformed or hostile archive resolve to '.', '..', or a path.
        if ([string]::IsNullOrWhiteSpace($modName) -or
            $modName -in @('.', '..', 'base', 'mods') -or
            $modName -match '[\\/:*?"<>|\[\]]' -or
            $modName -ne [System.IO.Path]::GetFileName($modName)) {
            Write-Log "Archive '$([System.IO.Path]::GetFileName($ZipPath))' resolves to an unsafe mod name '$modName'. Refusing." 'ERROR'
            return $null
        }

        return [pscustomobject]@{
            ModName = $modName
            Prefix  = $prefix
            Entries = @($zip.Entries | ForEach-Object { $_.FullName })
        }
    } catch {
        Write-Log "Cannot read archive '$ZipPath': $($_.Exception.Message)" 'ERROR'
        return $null
    } finally {
        if ($zip) { $zip.Dispose() }
    }
}

function Get-ArchiveModVersion {
    <# Reads version out of an info.json inside the archive. Most reliable source. #>
    param([string] $ZipPath)
    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        $e = $zip.Entries |
             Where-Object { $_.Name -eq 'info.json' } |
             Sort-Object { ($_.FullName -split '/').Count } |
             Select-Object -First 1
        if (-not $e) { return $null }
        $sr = New-Object System.IO.StreamReader($e.Open())
        try { $j = $sr.ReadToEnd() | ConvertFrom-Json } finally { $sr.Dispose() }
        if ($j.PSObject.Properties.Name -contains 'version' -and $j.version) { return "$($j.version)" }
        return $null
    } catch {
        return $null
    } finally {
        if ($zip) { $zip.Dispose() }
    }
}

function Get-ArchiveVersionFromName {
    <#
      Nexus manual downloads are named '<Mod Name>-<modId>-<version with dashes>-<epoch>.zip',
      e.g. 'Markers Improved All-in-one-447-2-14-4-1719209900.zip' -> 2.14.4
    #>
    param([string] $FileName, [int] $ModId)
    if (-not $ModId) {
        $p = Get-NexusFileNameParts -FileName $FileName
        if ($p) { return $p.Version }
        return $null
    }
    $m = [regex]::Match($FileName, "[-_]$ModId[-_](?<v>[0-9]+(?:-[0-9]+)*)[-_](?<ts>\d{9,})")
    if (-not $m.Success) {
        $m = [regex]::Match($FileName, "[-_]$ModId[-_](?<v>[0-9]+(?:-[0-9]+)*)")
    }
    if (-not $m.Success) { return $null }
    return ($m.Groups['v'].Value -replace '-', '.')
}

function Get-NexusFileNameParts {
    <#
      Parses a stock Nexus download filename WITHOUT needing to know the mod id first:
        '<Mod Name>-<modId>-<version with dashes>-<epoch>.zip'
        'Markers Improved All-in-one-447-2-14-4-1719209900.zip' -> id 447, version 2.14.4
      The trailing 9+ digit epoch is what makes this unambiguous, so this only matches
      files that still carry their original Nexus name.
      Returns $null when the name does not fit the pattern.
    #>
    param([string] $FileName)

    $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    # Browsers append ' (1)' on a duplicate download - tolerate it.
    $base = [regex]::Replace($base, '\s*\(\d+\)$', '')

    $m = [regex]::Match($base, '^(?<name>.+?)-(?<id>\d{1,7})-(?<v>\d+(?:-\d+)*)-(?<ts>\d{9,})$')
    if (-not $m.Success) { return $null }

    return [pscustomobject]@{
        Name    = $m.Groups['name'].Value
        ModId   = [int]$m.Groups['id'].Value
        Version = ($m.Groups['v'].Value -replace '-', '.')
    }
}

function Expand-ModArchive {
    <# Extracts only the mod subtree of the zip into <ModsRoot>\<ModName>\. #>
    param([string] $ZipPath, [string] $Destination, [string] $Prefix)

    $zip = $null
    try {
        $zip  = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        $root = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
        foreach ($e in $zip.Entries) {
            if ($Prefix -and -not $e.FullName.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $rel = if ($Prefix) { $e.FullName.Substring($Prefix.Length) } else { $e.FullName }
            if (-not $rel) { continue }

            # Zip-slip guard. Normalise separators FIRST - zip entries may legally use '\',
            # and a '\'-only traversal would otherwise slip past a '/'-only regex.
            $rel = $rel -replace '\\', '/'
            if ($rel -match '(^|/)\.\.(/|$)' -or $rel -match '^([A-Za-z]:|/)') {
                throw "Archive contains an unsafe path: '$($e.FullName)'"
            }

            $target = Join-Path $Destination ($rel -replace '/', '\')
            # Belt and braces: the resolved path must still live under $Destination.
            $full = [System.IO.Path]::GetFullPath($target)
            if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Archive entry '$($e.FullName)' resolves outside the mod folder."
            }

            if ($rel.EndsWith('/')) {
                if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -LiteralPath $target -Force | Out-Null }
                continue
            }
            $parent = Split-Path -Parent $target
            if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -LiteralPath $parent -Force | Out-Null }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
        }
    } finally {
        if ($zip) { $zip.Dispose() }
    }
}

function Find-DownloadedArchive {
    <#
      Finds candidate archives for a mod in the download folder.
      Nexus manual downloads are named like 'Markers Improved All-in-one-447-2-14-4-1719...zip',
      so the mod id sits between dashes. Matching on '-<modId>-' is the reliable signal;
      normalized-name prefix matching is the fallback.
    #>
    param([string] $DownloadDir, [int] $ModId, [string] $DisplayName, [string] $Folder)

    if (-not (Test-Path -LiteralPath $DownloadDir)) { return @() }

    # -Filter uses Win32 matching, which also matches '.zipx' etc. Compare the extension.
    $all = @(Get-ChildItem -LiteralPath $DownloadDir -File -ErrorAction SilentlyContinue |
             Where-Object { $_.Extension -eq '.zip' })

    # Warn if the mod arrived as .7z/.rar - Expand needs a plain zip.
    $other = @(Get-ChildItem -LiteralPath $DownloadDir -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Extension -in @('.7z', '.rar') -and $ModId -and $_.Name -match "[-_]$ModId[-_]" })
    foreach ($o in $other) {
        Write-Log "Found '$($o.Name)' but only .zip archives can be installed automatically. Extract it and re-zip, or install it by hand." 'WARN'
    }

    if (-not $all) { return @() }

    $hits = @()
    if ($ModId) { $hits = @($all | Where-Object { $_.Name -match "[-_]$ModId[-_]" }) }
    if (-not $hits) {
        $targets = @((Get-NormalizedName $DisplayName), (Get-NormalizedName $Folder)) | Where-Object { $_ }
        $hits = @($all | Where-Object {
            $n = Get-NormalizedName $_.BaseName
            $matched = $false
            foreach ($t in $targets) { if ($t -and $n.StartsWith($t)) { $matched = $true } }
            $matched
        })
    }
    return @($hits | Sort-Object LastWriteTime -Descending)
}

# ----------------------------------------------------------------------------------
# Install / backup / rollback
# ----------------------------------------------------------------------------------

function New-ModBackup {
    param([string] $ModPath, [string] $BackupSetDir)
    if (-not (Test-Path -LiteralPath $ModPath)) { return $null }
    if (-not (Test-Path -LiteralPath $BackupSetDir)) { New-Item -ItemType Directory -Path $BackupSetDir -Force | Out-Null }
    $name = Split-Path -Leaf $ModPath
    $zip  = Join-Path $BackupSetDir "$name.zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($ModPath, $zip,
        [System.IO.Compression.CompressionLevel]::Optimal, $false)
    return $zip
}

function Install-ModArchive {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string] $ZipPath,
        [string] $ModsRoot,
        [string] $BackupSetDir,
        [int]    $ModId,
        [string] $Version,
        [string] $DisplayName,
        [int]    $FileId,
        [string] $ExpectedFolder
    )

    $archiveName = [System.IO.Path]::GetFileName($ZipPath)
    $layout = Get-ArchiveModLayout -ZipPath $ZipPath
    if (-not $layout) {
        Write-Log "Archive '$archiveName' contains no *.mod file - not a DMF mod. Skipped." 'ERROR'
        return $false
    }

    # The folder to be deleted must be the folder we set out to update. Archive matching
    # is heuristic, so without this a mis-matched download could wipe an unrelated mod.
    if ($ExpectedFolder -and $layout.ModName -ne $ExpectedFolder) {
        Write-Log "Archive '$archiveName' contains mod '$($layout.ModName)' but '$ExpectedFolder' was being updated. Refusing." 'ERROR'
        return $false
    }

    $target = Join-Path $ModsRoot $layout.ModName
    $stage  = Join-Path $ModsRoot ('.staging-' + $layout.ModName)

    if ($PSCmdlet.ShouldProcess($target, "Install $($layout.ModName) $Version from $archiveName")) {

        # Extract to a staging folder FIRST. Nothing is destroyed until we know the
        # new copy is on disk, so a bad archive can never leave you with no mod.
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        New-Item -ItemType Directory -LiteralPath $stage -Force | Out-Null
        try {
            Expand-ModArchive -ZipPath $ZipPath -Destination $stage -Prefix $layout.Prefix
        } catch {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
            throw
        }

        $backup = $null
        if (Test-Path -LiteralPath $target) {
            $backup = New-ModBackup -ModPath $target -BackupSetDir $BackupSetDir
            Write-Log "Backed up $($layout.ModName) -> $backup"
        }

        try {
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
            Move-Item -LiteralPath $stage -Destination $target -Force
        } catch {
            Write-Log "Swap failed for $($layout.ModName): $($_.Exception.Message)" 'ERROR'
            if ($backup -and -not (Test-Path -LiteralPath $target)) {
                Write-Log "Restoring $($layout.ModName) from backup." 'WARN'
                New-Item -ItemType Directory -LiteralPath $target -Force | Out-Null
                Expand-ModArchive -ZipPath $backup -Destination $target -Prefix ''
            }
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
            throw
        }

        $state = [ordered]@{
            modId         = $ModId
            fileId        = $FileId
            name          = $DisplayName
            version       = $Version
            installedAt   = (Get-Date).ToString('o')
            sourceArchive = $archiveName
            installedBy   = "$script:AppName $script:AppVersion"
        }
        ($state | ConvertTo-Json -Depth 4) |
            Set-Content -LiteralPath (Join-Path $target '.nexus-mod.json') -Encoding UTF8

        Write-Log "Installed $($layout.ModName) $Version" 'OK'
        return $true
    }
    return $false
}

function Update-LoadOrder {
    <# Appends any mod folder that is missing from mod_load_order.txt. Never reorders. #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string] $ModsRoot, [string[]] $ModNames)

    $path = Join-Path $ModsRoot 'mod_load_order.txt'
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Log 'mod_load_order.txt not found - skipping load-order maintenance.' 'WARN'
        return
    }

    $lines   = @(Get-Content -LiteralPath $path -Encoding UTF8)
    $present = @($lines | ForEach-Object { $_.Trim() } |
                 Where-Object { $_ -and -not $_.StartsWith('--') })

    $missing = @($ModNames | Where-Object { $_ -and $present -notcontains $_ -and $_ -notin @('base','dmf') })
    if (-not $missing) { return }

    if ($PSCmdlet.ShouldProcess($path, "Append $($missing -join ', ')")) {
        Copy-Item -LiteralPath $path -Destination "$path.bak" -Force
        # Add-Content appends a terminator AFTER the value, not before. Without this
        # a file saved with no trailing newline would glue 'lastmod' to 'newmod'.
        $existing = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ($existing -and $existing -notmatch '(\r?\n)$') {
            Add-Content -LiteralPath $path -Value '' -Encoding UTF8
        }
        Add-Content -LiteralPath $path -Value $missing -Encoding UTF8
        Write-Log "Added to mod_load_order.txt: $($missing -join ', ')" 'OK'
    }
}

function Invoke-OfflineUpdate {
    <#
      No-API mode. Drives everything from the archives sitting in DownloadDir.

      A Nexus archive is self-describing: the *.mod file inside names the mod folder,
      and the version comes from the archive's own info.json or from the stock Nexus
      filename. So the whole install pipeline works with no key and no network - the
      only thing lost is "is there something newer on Nexus that I haven't downloaded".

      Also installs mods that are not present locally yet, so you can drop a pile of
      zips in one folder and have them land correctly with load-order entries.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]  $ModsRoot,
        [string]  $DownloadDir,
        [string]  $BackupSetDir,
        [object[]]$LocalMods,
        [switch]  $DoApply,
        [switch]  $ForceInstall,
        [string[]]$OnlyFolders,
        [string[]]$SkipFolders
    )

    if (-not (Test-Path -LiteralPath $DownloadDir)) {
        throw "DownloadDir '$DownloadDir' does not exist. Set it in config.json or pass -DownloadDir."
    }

    $archives = @(Get-ChildItem -LiteralPath $DownloadDir -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.Extension -eq '.zip' } |
                  Sort-Object LastWriteTime -Descending)

    Write-Log "Offline mode: $($archives.Count) .zip file(s) in $DownloadDir" 'STEP'
    if (-not $archives) {
        Write-Log 'Nothing to do. Download mod archives from Nexus into that folder first.' 'WARN'
        return @()
    }

    # Index the local mods by folder name for quick lookup.
    $local = @{}
    foreach ($lm in $LocalMods) { $local[$lm.Folder] = $lm }

    # Pass 1: work out what each archive actually is.
    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($a in $archives) {
        $layout = Get-ArchiveModLayout -ZipPath $a.FullName
        if (-not $layout) {
            Write-Log "Skipping '$($a.Name)': no *.mod file inside, so it is not a DMF mod." 'WARN'
            continue
        }

        $parts   = Get-NexusFileNameParts -FileName $a.Name
        $version = Get-ArchiveModVersion -ZipPath $a.FullName
        $vSource = 'info.json'
        if (-not $version -and $parts) { $version = $parts.Version; $vSource = 'filename' }
        if (-not $version) { $vSource = 'unknown' }

        $candidates.Add([pscustomobject]@{
            File          = $a
            Folder        = $layout.ModName
            Version       = $version
            VersionSource = $vSource
            ModId         = $(if ($parts) { $parts.ModId } else { 0 })
        })
    }

    # Pass 2: for each target folder keep only the best archive.
    $byFolder = @{}
    foreach ($c in $candidates) {
        if ($OnlyFolders -and $OnlyFolders -notcontains $c.Folder) { continue }
        if ($SkipFolders -and $SkipFolders -contains $c.Folder)    { continue }
        if (-not $byFolder.ContainsKey($c.Folder)) { $byFolder[$c.Folder] = $c; continue }
        $cur = $byFolder[$c.Folder]
        if ($c.Version -and $cur.Version) {
            if ((Compare-ModVersion $c.Version $cur.Version) -gt 0) { $byFolder[$c.Folder] = $c }
        } elseif ($c.Version -and -not $cur.Version) {
            $byFolder[$c.Folder] = $c
        }
        # else: keep the current one (archives are already newest-mtime first)
    }

    $report = New-Object System.Collections.Generic.List[object]

    foreach ($folder in ($byFolder.Keys | Sort-Object)) {
        $c        = $byFolder[$folder]
        $existing = $(if ($local.ContainsKey($folder)) { $local[$folder] } else { $null })
        $localVer = $(if ($existing) { $existing.LocalVersion } else { $null })

        # Pinned mods are off limits here too.
        if ($existing -and $script:PinnedFolders -contains $folder) {
            Write-Log "$folder`: pinned in mods-map.json, skipped."
            continue
        }

        $status = ''
        $action = ''

        if (-not $c.Version) {
            $status = 'VERSION-UNKNOWN'
            $action = 'no info.json in the zip and the Nexus filename was changed - use -Force to install anyway'
        } elseif (-not $existing) {
            $status = 'NEW'
            $action = 'not installed yet'
        } elseif (-not $localVer) {
            $status = 'UNKNOWN-LOCAL'
            $action = 'no version recorded locally - installing will start tracking it'
        } else {
            $cmp = Compare-ModVersion $c.Version $localVer
            if ($cmp -gt 0)      { $status = 'NEWER';   $action = 'archive is newer' }
            elseif ($cmp -lt 0)  { $status = 'OLDER';   $action = 'archive is older than what is installed - use -Force to downgrade' }
            else                 { $status = 'SAME';    $action = 'already installed' }
        }

        $shouldInstall = $status -in @('NEW', 'NEWER', 'UNKNOWN-LOCAL')
        if ($ForceInstall -and $status -in @('OLDER', 'SAME', 'VERSION-UNKNOWN')) { $shouldInstall = $true }

        if ($DoApply -and $shouldInstall) {
            try {
                if (Install-ModArchive -ZipPath $c.File.FullName -ModsRoot $ModsRoot `
                        -BackupSetDir $BackupSetDir -ModId $c.ModId `
                        -Version $(if ($c.Version) { $c.Version } else { '' }) `
                        -DisplayName $folder -FileId 0 -ExpectedFolder $folder) {
                    $script:Stats.Updated++
                    $script:OfflineInstalled.Add($folder)
                    $action = "installed from $($c.File.Name)"
                }
            } catch {
                $script:Stats.Failed++
                $action = "install failed: $($_.Exception.Message)"
                Write-Log "$folder`: $action" 'ERROR'
            }
        }

        $script:Stats.Checked++
        if ($shouldInstall -and -not $DoApply) { $script:Stats.Outdated++ }

        $report.Add([pscustomobject]@{
            Mod    = $folder
            ModId  = $(if ($c.ModId) { $c.ModId } else { '' })
            Local  = $localVer
            Latest = $c.Version
            Status = $status
            Action = $action
        })
    }

    # Anything installed that no archive covered - just so the picture is complete.
    foreach ($lm in $LocalMods) {
        if ($byFolder.ContainsKey($lm.Folder)) { continue }
        if ($OnlyFolders -and $OnlyFolders -notcontains $lm.Folder) { continue }
        if ($SkipFolders -and $SkipFolders -contains $lm.Folder)    { continue }
        $report.Add([pscustomobject]@{
            Mod    = $lm.Folder
            ModId  = ''
            Local  = $lm.LocalVersion
            Latest = ''
            Status = 'NO-ARCHIVE'
            Action = 'no matching zip in the download folder'
        })
    }

    return $report
}

function Invoke-Rollback {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string] $BackupRoot, [string] $ModsRoot, [string] $SetName)

    if (-not (Test-Path -LiteralPath $BackupRoot)) { throw "No backup root at '$BackupRoot'." }

    # -BackupSet must name a folder directly under BackupRoot, never a path.
    if ($SetName -and [System.IO.Path]::GetFileName($SetName) -ne $SetName) {
        throw "-BackupSet must be a single folder name (e.g. '20260829-181500'), not a path."
    }

    $set = if ($SetName) {
        Get-Item -LiteralPath (Join-Path $BackupRoot $SetName) -ErrorAction Stop
    } else {
        Get-ChildItem -LiteralPath $BackupRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
    }
    if (-not $set) { throw "No backup sets found under '$BackupRoot'." }

    Write-Log "Rolling back from backup set '$($set.Name)'" 'STEP'
    $zips = @(Get-ChildItem -LiteralPath $set.FullName -File |
              Where-Object { $_.Extension -eq '.zip' })
    if (-not $zips) { throw "Backup set '$($set.Name)' is empty." }

    $restored = 0
    foreach ($z in $zips) {
        $name = $z.BaseName

        # Same guard as the install path: this name drives a recursive delete.
        if ([string]::IsNullOrWhiteSpace($name) -or
            $name -in @('.', '..', 'base', 'mods') -or
            $name -match '[\\/:*?"<>|\[\]]' -or
            $name -ne [System.IO.Path]::GetFileName($name)) {
            Write-Log "Backup '$($z.Name)' has an unsafe mod name '$name'. Skipped." 'ERROR'
            continue
        }

        $target = Join-Path $ModsRoot $name
        if ($PSCmdlet.ShouldProcess($target, "Restore from $($z.Name)")) {
            # Stage first, exactly as on install, so a failed extract cannot destroy the mod.
            $stage = Join-Path $ModsRoot ".staging-$name"
            if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
            try {
                New-Item -ItemType Directory -LiteralPath $stage -Force | Out-Null
                Expand-ModArchive -ZipPath $z.FullName -Destination $stage -Prefix ''
            } catch {
                Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
                throw
            }
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
            Move-Item -LiteralPath $stage -Destination $target -Force
            Write-Log "Restored $name" 'OK'
            $restored++
        }
    }
    Write-Log "Rollback complete. $restored mod(s) restored." 'OK'
}

function Remove-StaleBackupSets {
    param([string] $Root, [int] $Keep)
    if ($Keep -le 0) { return }
    if (-not (Test-Path -LiteralPath $Root)) { return }
    $stale = @(Get-ChildItem -LiteralPath $Root -Directory |
               Sort-Object LastWriteTime -Descending | Select-Object -Skip $Keep)
    foreach ($old in $stale) {
        Remove-Item -LiteralPath $old.FullName -Recurse -Force
        Write-Log "Pruned old backup set: $($old.Name)"
    }
}

# ----------------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------------

Initialize-Log -Root $PSScriptRoot
$cfg = Get-Configuration -Path $ConfigPath
Write-Log "=== $script:AppName $script:AppVersion ===" 'STEP'
Write-Log "Mods root : $($cfg.ModsRoot)"
Write-Log "Backups   : $($cfg.BackupRoot)"
Write-Log "Downloads : $($cfg.DownloadDir)"
Write-Log "Log file  : $script:LogFile"

Test-ModsRoot -Path $cfg.ModsRoot

if ($Rollback) {
    if (-not (Test-Path -LiteralPath $cfg.BackupRoot)) { throw "No backup root at '$($cfg.BackupRoot)'." }
    if ($BackupSet -and [System.IO.Path]::GetFileName($BackupSet) -ne $BackupSet) {
        throw "-BackupSet must be a single folder name (e.g. '20260829-181500'), not a path."
    }
    $set = if ($BackupSet) {
        Get-Item -LiteralPath (Join-Path $cfg.BackupRoot $BackupSet) -ErrorAction Stop
    } else {
        Get-ChildItem -LiteralPath $cfg.BackupRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
    }
    if (-not $set) { throw "No backup sets found under '$($cfg.BackupRoot)'." }

    $zips = @(Get-ChildItem -LiteralPath $set.FullName -File |
              Where-Object { $_.Extension -eq '.zip' })
    if (-not $zips) { throw "Backup set '$($set.Name)' is empty." }
    Write-Log "Backup set '$($set.Name)' ($($zips.Count) archive(s))" 'STEP'
    foreach ($z in $zips) { Write-Host "  $($z.Name)" }

    if (-not $Apply) {
        Write-Log 'Dry run. Re-run with -Rollback -Apply to restore.' 'WARN'
        return
    }

    Assert-GameNotRunning
    Invoke-Rollback -BackupRoot $cfg.BackupRoot -ModsRoot $cfg.ModsRoot -SetName $set.Name
    return
}

# ---- Offline mode: no key, no network ----------------------------------------------

if ($NoApi -or -not $cfg.ApiKey) {
    if (-not $NoApi) {
        Write-Log 'No Nexus API key found - falling back to offline mode.' 'WARN'
        Write-Log 'Offline mode installs archives you downloaded yourself but cannot tell you what is newer on Nexus.' 'WARN'
        Write-Log 'To enable version checking: get a key at https://www.nexusmods.com/users/myaccount?tab=api then' 'WARN'
        Write-Log "  [Environment]::SetEnvironmentVariable('NEXUS_API_KEY','<your-key>','User')" 'WARN'
        Write-Host ''
    }

    $mods = @(Get-LocalMods -ModsRoot $cfg.ModsRoot)
    $map  = Get-ModMap -Path $cfg.MapPath
    $script:PinnedFolders = @($map.Keys | Where-Object {
        $e = $map[$_]
        ($e.PSObject.Properties.Name -contains 'pinned') -and $e.pinned
    })
    $script:OfflineInstalled = New-Object System.Collections.Generic.List[string]

    $backupSetDir = Join-Path $cfg.BackupRoot (Get-Date -Format 'yyyyMMdd-HHmmss')
    if ($Apply) { Assert-GameNotRunning }

    $report = @(Invoke-OfflineUpdate -ModsRoot $cfg.ModsRoot -DownloadDir $cfg.DownloadDir `
                    -BackupSetDir $backupSetDir -LocalMods $mods -DoApply:$Apply `
                    -ForceInstall:$Force -OnlyFolders $Only -SkipFolders $Skip)

    if ($script:OfflineInstalled.Count -gt 0 -and -not $NoLoadOrderUpdate) {
        Update-LoadOrder -ModsRoot $cfg.ModsRoot -ModNames @($script:OfflineInstalled | Select-Object -Unique)
    }

    Write-Host ''
    $report | Sort-Object @{ Expression = {
            switch ($_.Status) {
                'NEWER' {0} 'NEW' {1} 'UNKNOWN-LOCAL' {2} 'VERSION-UNKNOWN' {3}
                'OLDER' {4} 'SAME' {5} default {6}
            } } }, Mod |
        Format-Table -AutoSize -Property Mod, ModId, Local, Latest, Status, Action

    $csv = Join-Path $PSScriptRoot ('report-offline-{0}.csv' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $report | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8

    Write-Host ''
    Write-Log ("Archives matched {0} | installed {1} | errors {2}" -f `
        $script:Stats.Checked, $script:Stats.Updated, $script:Stats.Failed) 'STEP'
    Write-Log "Report: $csv"
    if ($script:Stats.Updated -gt 0) {
        Write-Log "Backups for this run: $backupSetDir" 'OK'
        Write-Log "Undo with: .\Update-DarktideMods.ps1 -Rollback -Apply -BackupSet '$(Split-Path -Leaf $backupSetDir)'" 'OK'
        if ((Test-Path -LiteralPath $backupSetDir)) {
            Remove-StaleBackupSets -Root $cfg.BackupRoot -Keep $KeepBackups
        }
    }
    if (-not $Apply -and $script:Stats.Outdated -gt 0) {
        Write-Log "Read-only run. Re-run with -NoApi -Apply to install." 'WARN'
    }
    return
}

$account = Get-NexusAccount -Key $cfg.ApiKey
Write-Log "Nexus account: $($account.Name) (premium: $($account.IsPremium))" 'OK'
if (-not $account.IsPremium) {
    Write-Log 'Free account: the API will not issue download links. Version checking works; installs come from your download folder.' 'WARN'
}

if ($BuildCatalog) {
    Update-NexusCatalog -Domain $cfg.GameDomain -Key $cfg.ApiKey -CatalogPath $cfg.CatalogPath -MaxRequests $CatalogMaxRequests
    return
}

$mods = @(Get-LocalMods -ModsRoot $cfg.ModsRoot)
if ($Only) { $mods = @($mods | Where-Object { $Only -contains $_.Folder }) }
if ($Skip) { $mods = @($mods | Where-Object { $Skip -notcontains $_.Folder }) }
Write-Log "Found $($mods.Count) mod folder(s)." 'STEP'

$map = Get-ModMap -Path $cfg.MapPath

if ($Resolve) {
    $map = Resolve-ModIds -Mods $mods -Map $map -Domain $cfg.GameDomain -Key $cfg.ApiKey -CatalogPath $cfg.CatalogPath
    Save-ModMap -Map $map -Path $cfg.MapPath
    Write-Log "Wrote $($cfg.MapPath)" 'OK'
    return
}

# ---- Check every mod against Nexus -------------------------------------------------

$report       = New-Object System.Collections.Generic.List[object]
$backupSetDir = Join-Path $cfg.BackupRoot (Get-Date -Format 'yyyyMMdd-HHmmss')
$installed     = New-Object System.Collections.Generic.List[string]
$rateExhausted = $false

if ($Apply) { Assert-GameNotRunning }

foreach ($m in $mods) {
    $modId = $m.ModId
    if ($map.ContainsKey($m.Folder)) {
        $e = $map[$m.Folder]
        if ($e.PSObject.Properties.Name -contains 'pinned' -and $e.pinned) {
            Write-Log "$($m.Folder): pinned in mods-map.json, skipped."
            continue
        }
        # An explicit map entry overrides whatever info.json claims.
        if ($e.PSObject.Properties.Name -contains 'modId' -and $e.modId) { $modId = [int]$e.modId }
    }

    if (-not $modId) {
        $script:Stats.Unmapped++
        $report.Add([pscustomobject]@{
            Mod = $m.Folder; ModId = ''; Local = $m.LocalVersion; Latest = ''
            Status = 'UNMAPPED'; Action = 'add id to mods-map.json (or run -BuildCatalog then -Resolve)'
        })
        continue
    }

    # Budget exhausted: record the remaining mods as unchecked instead of silently
    # truncating the report, which would read as "everything else is fine".
    if ($rateExhausted -or -not (Test-RateBudget -Need 5)) {
        $rateExhausted = $true
        $report.Add([pscustomobject]@{
            Mod = $m.Folder; ModId = $modId; Local = $m.LocalVersion; Latest = ''
            Status = 'RATE-LIMITED'; Action = 'not checked - Nexus API budget exhausted, retry later'
        })
        continue
    }

    $nx = $null
    try {
        $nx = Get-NexusMod -Domain $cfg.GameDomain -ModId $modId -Key $cfg.ApiKey
    } catch {
        if ("$($_.Exception.Message)" -eq 'NEXUS_RATE_LIMIT') { $rateExhausted = $true; continue }
        Write-Log "$($m.Folder): $($_.Exception.Message)" 'ERROR'
    }
    $script:Stats.Checked++
    if (-not $nx -or -not ($nx.PSObject.Properties.Name -contains 'name')) {
        $script:Stats.Failed++
        $report.Add([pscustomobject]@{
            Mod = $m.Folder; ModId = $modId; Local = $m.LocalVersion; Latest = ''
            Status = 'API-ERROR'; Action = 'mod hidden/deleted, wrong id, or network problem'
        })
        continue
    }

    $displayName   = "$($nx.name)"
    $latestVersion = if ($nx.PSObject.Properties.Name -contains 'version') { "$($nx.version)" } else { '' }

    $files = $null
    try {
        $files = Get-NexusModFiles -Domain $cfg.GameDomain -ModId $modId -Key $cfg.ApiKey
    } catch {
        if ("$($_.Exception.Message)" -eq 'NEXUS_RATE_LIMIT') { $rateExhausted = $true }
        else { Write-Log "$($m.Folder): file list unavailable - $($_.Exception.Message)" 'WARN' }
    }
    $file = Get-NexusLatestMainFile -FilesResponse $files
    $fileVer = $latestVersion
    $fileId  = 0
    if ($file) {
        if ($file.PSObject.Properties.Name -contains 'version' -and $file.version) { $fileVer = "$($file.version)" }
        if ($file.PSObject.Properties.Name -contains 'file_id') { $fileId = [int]$file.file_id }
    }
    $best = if ((Compare-ModVersion $fileVer $latestVersion) -gt 0) { $fileVer } else { $latestVersion }

    $cmp = Compare-ModVersion $best $m.LocalVersion
    $status =
        if (-not $m.LocalVersion) { 'UNKNOWN-LOCAL' }
        elseif ($cmp -gt 0)       { 'OUTDATED' }
        elseif ($cmp -lt 0)       { 'AHEAD' }
        else                      { 'CURRENT' }

    $action = ''
    if ($status -in 'OUTDATED','UNKNOWN-LOCAL') {
        $script:Stats.Outdated++
        $pageUrl = "https://www.nexusmods.com/$($cfg.GameDomain)/mods/$modId?tab=files"

        if ($OpenPages) { Start-Process $pageUrl | Out-Null }

        if ($Apply) {
            $archives = Find-DownloadedArchive -DownloadDir $cfg.DownloadDir -ModId $modId `
                            -DisplayName $displayName -Folder $m.Folder
            # Evaluate EVERY candidate and keep the highest version, not merely the
            # newest file on disk - a re-downloaded old build must not win on mtime.
            # Version source order: info.json inside the zip > Nexus file name.
            $chosen        = $null
            $chosenVersion = $null
            foreach ($a in $archives) {
                $av = Get-ArchiveModVersion -ZipPath $a.FullName
                if (-not $av) { $av = Get-ArchiveVersionFromName -FileName $a.Name -ModId $modId }
                if (-not $av) {
                    # Refuse to guess. Installing an unknown version would either
                    # downgrade silently or poison .nexus-mod.json with a wrong number.
                    Write-Log "$($m.Folder): cannot determine the version of '$($a.Name)' - skipped. Keep the original Nexus filename, or install it by hand." 'WARN'
                    continue
                }
                if ($m.LocalVersion -and (Compare-ModVersion $av $m.LocalVersion) -le 0) {
                    Write-Log "$($m.Folder): '$($a.Name)' is $av, not newer than installed $($m.LocalVersion) - skipped."
                    continue
                }
                if (-not $chosen -or (Compare-ModVersion $av $chosenVersion) -gt 0) {
                    $chosen = $a; $chosenVersion = $av
                }
            }
            if ($chosen) {
                try {
                    if (Install-ModArchive -ZipPath $chosen.FullName -ModsRoot $cfg.ModsRoot `
                            -BackupSetDir $backupSetDir -ModId $modId -Version $chosenVersion `
                            -DisplayName $displayName -FileId $fileId -ExpectedFolder $m.Folder) {
                        $script:Stats.Updated++
                        # Install-ModArchive guarantees the installed folder equals $m.Folder.
                        $installed.Add($m.Folder)
                        $action = "installed $chosenVersion from $($chosen.Name)"
                    }
                } catch {
                    $script:Stats.Failed++
                    $action = "install failed: $($_.Exception.Message)"
                    Write-Log "$($m.Folder): $action" 'ERROR'
                }
            } else {
                $action = "no archive in $($cfg.DownloadDir) - download from $pageUrl"
            }
        } else {
            $action = $pageUrl
        }
    }

    $report.Add([pscustomobject]@{
        Mod = $m.Folder; ModId = $modId; Local = $m.LocalVersion; Latest = $best
        Status = $status; Action = $action
    })
}

# ---- Output ------------------------------------------------------------------------

if ($installed.Count -gt 0 -and -not $NoLoadOrderUpdate) {
    Update-LoadOrder -ModsRoot $cfg.ModsRoot -ModNames @($installed | Select-Object -Unique)
}

Write-Host ''
$report | Sort-Object @{ Expression = {
        switch ($_.Status) { 'OUTDATED' {0} 'UNKNOWN-LOCAL' {1} 'API-ERROR' {2} 'UNMAPPED' {3} default {4} }
    } }, Mod |
    Format-Table -AutoSize -Property Mod, ModId, Local, Latest, Status, Action

$csv = Join-Path $PSScriptRoot ('report-{0}.csv' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$report | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8

Write-Host ''
Write-Log ("Checked {0} | outdated {1} | updated {2} | unmapped {3} | errors {4}" -f `
    $script:Stats.Checked, $script:Stats.Outdated, $script:Stats.Updated,
    $script:Stats.Unmapped, $script:Stats.Failed) 'STEP'
Write-Log "Report: $csv"
if ($null -ne $script:RateLimit.DailyRemaining) {
    Write-Log "Nexus API budget left - hourly: $($script:RateLimit.HourlyRemaining), daily: $($script:RateLimit.DailyRemaining)"
}
if ($script:Stats.Updated -gt 0) {
    Write-Log "Backups for this run: $backupSetDir" 'OK'
    Write-Log "Undo with: .\Update-DarktideMods.ps1 -Rollback -Apply -BackupSet '$(Split-Path -Leaf $backupSetDir)'" 'OK'
    if ((Test-Path -LiteralPath $backupSetDir)) {
        Remove-StaleBackupSets -Root $cfg.BackupRoot -Keep $KeepBackups
    }
}
if (-not $Apply -and $script:Stats.Outdated -gt 0) {
    Write-Log "Read-only run. Download the archives, then re-run with -Apply to install." 'WARN'
}
