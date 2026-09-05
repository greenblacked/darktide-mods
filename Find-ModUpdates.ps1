<#
.SYNOPSIS
    Where to look for updates, without a Nexus API key.

.DESCRIPTION
    A Nexus API key is free and makes `darktide.ps1 check` work, so reach for that
    first if you want the real answer. This is for when you have no key at all.

    It does two things, neither of which touches Nexus:

    1. Prints the Nexus page for every mod in the lockfile, so checking by hand is a
       list of links rather than hunting 45 mods. No network at all.
    2. For any mod that also publishes on GitHub, asks the public GitHub API what its
       latest release tag is. That endpoint needs no authentication, which is the
       whole point - it is the one upstream this repo can query with no key.

    It reports; it does not adjudicate. A GitHub tag and a Nexus version string are
    not guaranteed to be the same scheme for the same mod - one may be 'v2.15.0'
    while Nexus says '2.15', or the release may lag the Nexus upload entirely - so
    this says 'differs' and shows both, and you decide. Calling it NEWER would be a
    guess wearing the clothes of a fact.

    It never downloads. Nothing here can: a free Nexus account gets HTTP 403 from
    /download_link.json, and scraping the site would breach their terms. The browser
    click stays yours.

.PARAMETER LockPath
    The manifest to read. Defaults to darktide-modpack.lock.json beside this script.

.PARAMETER MapPath
    mods-map.json, which is where a mod's optional `githubRepo` lives.

.PARAMETER CheckGitHub
    Query the GitHub API for mods that have a `githubRepo`. Off by default, because
    the rest of this script needs no network at all.

.PARAMETER Only
    Limit to these mod folders.

.PARAMETER Skip
    Exclude these mod folders.

.PARAMETER OutFile
    Also write the list as markdown, so it can be pasted somewhere or kept open.

.EXAMPLE
    .\Find-ModUpdates.ps1
    Every mod and its Nexus page. No network.

.EXAMPLE
    .\Find-ModUpdates.ps1 -CheckGitHub
    The same, plus the latest release tag for mods mapped to a GitHub repository.

.NOTES
    Unauthenticated GitHub allows 60 requests an hour per address. Set GITHUB_TOKEN
    to raise that; it is read from the environment only, never a parameter, for the
    same reason NEXUS_API_KEY is - a command line ends up in process listings and
    shell history.
#>

[CmdletBinding()]
param(
    [string]   $LockPath = (Join-Path $PSScriptRoot 'darktide-modpack.lock.json'),
    [string]   $MapPath  = (Join-Path $PSScriptRoot 'mods-map.json'),
    [switch]   $CheckGitHub,
    [string[]] $Only,
    [string[]] $Skip,
    [string]   $OutFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info { param([string] $Message) Write-Host $Message }
function Write-Warn { param([string] $Message) Write-Host $Message -ForegroundColor Yellow }

if (-not (Test-Path -LiteralPath $LockPath)) {
    throw "No lockfile at '$LockPath'. Generate one with: .\darktide.ps1 lock"
}

$lock = Get-Content -LiteralPath $LockPath -Raw -Encoding UTF8 | ConvertFrom-Json
$game = if ($lock.PSObject.Properties.Name -contains 'game' -and $lock.game) {
    $lock.game
} else {
    'warhammer40kdarktide'
}

$map = @{}
if (Test-Path -LiteralPath $MapPath) {
    $rawMap = Get-Content -LiteralPath $MapPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($prop in $rawMap.PSObject.Properties) { $map[$prop.Name] = $prop.Value }
}

function Get-GitHubRepo {
    <# The optional 'githubRepo' on a mods-map entry, as 'owner/repo', or $null. #>
    param([Parameter(Mandatory)][string] $Folder)

    if (-not $map.ContainsKey($Folder)) { return $null }
    $entry = $map[$Folder]
    if ($entry.PSObject.Properties.Name -notcontains 'githubRepo') { return $null }
    $repo = "$($entry.githubRepo)".Trim()
    if (-not $repo) { return $null }
    if ($repo -notmatch '^[\w.-]+/[\w.-]+$') {
        Write-Warn "  $Folder : ignoring githubRepo '$repo' - expected 'owner/repo'"
        return $null
    }
    return $repo
}

function Get-VersionComparison {
    <#
        'same', 'differs', or why neither can be said. Digits only, so 'v2.15.0' and
        '2.15.0' agree.

        It deliberately does not rank them. A GitHub tag and a Nexus version string
        are not guaranteed to be the same scheme for the same mod, so calling one
        NEWER would be a guess presented as a fact. Anything not plainly equal is a
        difference for a person to look at.
    #>
    param([string] $Installed, [string] $Tag)

    if (-not $Tag)       { return 'no release tag' }
    if (-not $Installed) { return 'no local version' }

    $a = ($Installed -replace '[^0-9]', '')
    $b = ($Tag       -replace '[^0-9]', '')
    if ($a -and $a -eq $b) { return 'same' }
    return 'differs'
}

function Get-LatestGitHubTag {
    <#
        The latest release tag for a public repository, or a short reason it could
        not be read. Distinguishes "no releases" from "rate limited" because the
        two mean completely different things to whoever reads the table.
    #>
    param([Parameter(Mandatory)][string] $Repo)

    $headers = @{
        'Accept'     = 'application/vnd.github+json'
        'User-Agent' = 'darktide-mods'
    }
    # Environment only. A token on a command line lands in process listings.
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)" }

    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    try {
        $resp = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" `
                                  -Headers $headers -TimeoutSec 45
        return @{ Tag = "$($resp.tag_name)"; Note = '' }
    } catch {
        $status = $null
        if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
            try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = $null }
        }
        # 403 is not proof of a rate limit - GitHub also returns it for a blocked or
        # forbidden request, and a proxy in the way can return it too. Say what was
        # observed and what usually fixes it, rather than naming a cause we do not know.
        switch ($status) {
            404     { return @{ Tag = ''; Note = 'no releases' } }
            403     { return @{ Tag = ''; Note = 'refused (403) - rate limit? try GITHUB_TOKEN' } }
            429     { return @{ Tag = ''; Note = 'rate limited (429) - try GITHUB_TOKEN' } }
            default { return @{ Tag = ''; Note = "unreachable$(if ($status) { " ($status)" })" } }
        }
    } finally { $ErrorActionPreference = $eap }
}

$mods = @($lock.mods)
if ($Only) { $mods = @($mods | Where-Object { $Only -contains $_.folder }) }
if ($Skip) { $mods = @($mods | Where-Object { $Skip -notcontains $_.folder }) }
if (-not $mods) { throw 'No mods selected.' }

$rows = New-Object System.Collections.Generic.List[object]

foreach ($mod in ($mods | Sort-Object folder)) {
    $modId = if ($mod.PSObject.Properties.Name -contains 'modId') { $mod.modId } else { $null }
    $url = if ($mod.PSObject.Properties.Name -contains 'url' -and $mod.url) {
        $mod.url
    } elseif ($modId) {
        "https://www.nexusmods.com/$game/mods/$modId"
    } else {
        ''
    }

    $installed = if ($mod.PSObject.Properties.Name -contains 'version' -and $mod.version) { $mod.version } else { '' }
    $repo   = Get-GitHubRepo -Folder $mod.folder
    $tag    = ''
    $status = ''

    if ($repo) {
        if ($CheckGitHub) {
            $result = Get-LatestGitHubTag -Repo $repo
            $tag = $result.Tag
            if (-not $tag) {
                $status = $result.Note
            } else {
                $status = Get-VersionComparison -Installed $installed -Tag $tag
            }
        } else {
            $status = 'repo mapped (-CheckGitHub to ask)'
        }
    }

    $rows.Add([pscustomobject]@{
        Mod       = $mod.folder
        Installed = $installed
        GitHub    = $tag
        Status    = $status
        Page      = $url
    })
}

Write-Info ''
$rows | Format-Table -AutoSize -Property Mod, Installed, GitHub, Status |
    Out-String -Width 200 | Write-Host

$mapped   = @($rows | Where-Object { $_.Status }).Count
$differing = @($rows | Where-Object { $_.Status -eq 'differs' }).Count

Write-Info "$($rows.Count) mod(s); $mapped with a GitHub repository mapped."
if ($CheckGitHub -and $differing -gt 0) {
    Write-Warn "$differing differ from their latest GitHub release - check those pages first."
}
if (-not $CheckGitHub -and $mapped -gt 0) {
    Write-Info 'Re-run with -CheckGitHub to ask GitHub for their latest release tags.'
}
if ($mapped -eq 0) {
    Write-Info "No mod has a 'githubRepo' in $([System.IO.Path]::GetFileName($MapPath)) yet."
    Write-Info "Add one to any entry to have it checked:  ""githubRepo"": ""owner/repo"""
}

Write-Info ''
Write-Info 'Pages to check:'
foreach ($row in $rows) {
    if ($row.Page) { Write-Info "  $($row.Mod.PadRight(34)) $($row.Page)" }
    else           { Write-Warn "  $($row.Mod.PadRight(34)) no Nexus id in the lockfile" }
}

if ($OutFile) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Mods to check")
    $lines.Add('')
    $lines.Add('| Mod | Installed | Page |')
    $lines.Add('|---|---|---|')
    foreach ($row in $rows) {
        $link = if ($row.Page) { "[Nexus]($($row.Page))" } else { '_no Nexus id_' }
        $lines.Add("| $($row.Mod) | $(if ($row.Installed) { $row.Installed } else { '-' }) | $link |")
    }
    Set-Content -LiteralPath $OutFile -Value $lines -Encoding UTF8
    Write-Info ''
    Write-Info "Wrote $OutFile"
}
