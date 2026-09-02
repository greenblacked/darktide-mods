<#
.SYNOPSIS
    Finds your Darktide install automatically and writes config.json.

.DESCRIPTION
    Removes the one manual step in setting this up on a new machine. It locates the
    game by asking Steam where it is, rather than guessing at drive letters:

      1. Steam's install path from the registry.
      2. Every Steam library from steamapps\libraryfolders.vdf - games are often on
         a different drive from Steam itself.
      3. Darktide's own appmanifest (app id 1361210) in each library, which names the
         install folder exactly.
      4. A fallback scan of each library's common\ folder.

    Each candidate is then verified by looking for real game files, so a leftover
    manifest from an uninstalled copy cannot produce a bad config.

    Nothing is overwritten without -Force.

.PARAMETER ModsRoot
    Staging folder to record. Defaults to <parent of the game folder's drive layout>,
    i.e. a 'Darktide\mods' folder beside this repository.

.PARAMETER GamePath
    Skip detection and use this path.

.PARAMETER Force
    Overwrite an existing config.json.

.EXAMPLE
    .\Initialize-DarktideConfig.ps1
    Detects everything and writes config.json.

.EXAMPLE
    .\Initialize-DarktideConfig.ps1 -WhatIf
    Shows what it found and what it would write.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string] $GamePath,
    [string] $ModsRoot,
    [string] $DownloadDir,
    [string] $LoaderSource,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$m) Write-Host $m -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host $m -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host $m -ForegroundColor Yellow }

# Darktide's Steam application id. This is what makes the lookup exact.
$script:DarktideAppId = '1361210'

function Test-DarktideFolder {
    <# Real game files, not just a folder with the right name. #>
    param([string] $Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    foreach ($marker in @('binaries\Darktide.exe', 'binaries_dx12\Darktide.exe',
                          'bundle\bundle_database.data', 'launcher\Launcher.exe')) {
        if (Test-Path -LiteralPath (Join-Path $Path $marker)) { return $true }
    }
    return $false
}

function Get-SteamRoot {
    foreach ($key in @('HKCU:\Software\Valve\Steam',
                       'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
                       'HKLM:\SOFTWARE\Valve\Steam')) {
        if (-not (Test-Path $key)) { continue }
        $props = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        foreach ($name in @('SteamPath', 'InstallPath')) {
            $value = $null
            if ($props -and $props.PSObject.Properties.Name -contains $name) { $value = "$($props.$name)" }
            if (-not $value) { continue }
            # The registry stores this with forward slashes and lower case.
            $value = $value -replace '/', '\'
            if (Test-Path -LiteralPath $value -PathType Container) { return $value.TrimEnd('\') }
        }
    }
    return $null
}

function Get-SteamLibrary {
    <#
        Every library folder Steam knows about. Games are routinely installed on a
        different drive from Steam, so the Steam root alone is not enough.
    #>
    param([string] $SteamRoot)

    $libraries = New-Object System.Collections.Generic.List[string]
    if ($SteamRoot) { $libraries.Add($SteamRoot) }

    if ($SteamRoot) {
        foreach ($name in @('libraryfolders.vdf', 'config\libraryfolders.vdf')) {
            $vdf = if ($name -like 'config\*') {
                Join-Path $SteamRoot $name
            } else {
                Join-Path $SteamRoot "steamapps\$name"
            }
            if (-not (Test-Path -LiteralPath $vdf)) { continue }

            # The VDF is a small nested key/value text format. Only "path" matters here,
            # so a targeted regex beats writing a parser for it.
            foreach ($line in (Get-Content -LiteralPath $vdf -ErrorAction SilentlyContinue)) {
                $m = [regex]::Match($line, '"path"\s+"(?<p>[^"]+)"')
                if (-not $m.Success) { continue }
                $p = $m.Groups['p'].Value -replace '\\\\', '\'
                if (Test-Path -LiteralPath $p -PathType Container) { $libraries.Add($p.TrimEnd('\')) }
            }
        }
    }

    return @($libraries | Select-Object -Unique)
}

function Find-DarktideInstall {
    <# Returns every plausible install, best evidence first. #>

    $found = New-Object System.Collections.Generic.List[object]

    $steamRoot = Get-SteamRoot
    if ($steamRoot) { Write-Verbose "Steam: $steamRoot" } else { Write-Verbose 'Steam not found in the registry.' }

    foreach ($lib in (Get-SteamLibrary -SteamRoot $steamRoot)) {
        # Best evidence: Darktide's own app manifest names its install folder.
        $manifest = Join-Path $lib "steamapps\appmanifest_$($script:DarktideAppId).acf"
        if (Test-Path -LiteralPath $manifest) {
            foreach ($line in (Get-Content -LiteralPath $manifest -ErrorAction SilentlyContinue)) {
                $m = [regex]::Match($line, '"installdir"\s+"(?<d>[^"]+)"')
                if (-not $m.Success) { continue }
                $candidate = Join-Path $lib "steamapps\common\$($m.Groups['d'].Value)"
                if (Test-DarktideFolder -Path $candidate) {
                    $found.Add([pscustomobject]@{ Path = $candidate; Source = 'Steam app manifest' })
                }
            }
        }

        # Fallback: the folder name, for installs whose manifest is missing.
        $common = Join-Path $lib 'steamapps\common'
        if (Test-Path -LiteralPath $common) {
            foreach ($dir in @(Get-ChildItem -LiteralPath $common -Directory -ErrorAction SilentlyContinue |
                               Where-Object { $_.Name -like '*DARKTIDE*' -or $_.Name -like '*Darktide*' })) {
                if (Test-DarktideFolder -Path $dir.FullName) {
                    $found.Add([pscustomobject]@{ Path = $dir.FullName; Source = 'Steam library scan' })
                }
            }
        }
    }

    # Last resort: the same relative path on every fixed drive. Covers a game moved
    # out of Steam's view entirely.
    if ($found.Count -eq 0) {
        foreach ($drive in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
                             Where-Object { $null -ne $_.Free })) {
            foreach ($rel in @('SteamLibrary\steamapps\common\Warhammer 40,000 DARKTIDE',
                               'Games\Steam\steamapps\common\Warhammer 40,000 DARKTIDE',
                               'Program Files (x86)\Steam\steamapps\common\Warhammer 40,000 DARKTIDE')) {
                $candidate = Join-Path "$($drive.Root)" $rel
                if (Test-DarktideFolder -Path $candidate) {
                    $found.Add([pscustomobject]@{ Path = $candidate; Source = 'drive scan' })
                }
            }
        }
    }

    # Unique by path, keeping the first (best) source for each.
    $seen = @{}
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($f in $found) {
        $key = $f.Path.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $result.Add($f)
    }

    # Return a real array, not the List. Windows PowerShell 5.1 under
    # 'Set-StrictMode -Version Latest' throws "Argument types do not match" when a
    # generic List is wrapped in @(), and callers here do exactly that. The leading
    # comma stops a single result being unrolled into a bare object.
    return ,$result.ToArray()
}

# ------------------------------------------------------------------------------------

Write-Step '=== Darktide setup ==='
Write-Host ''

# ---- Game folder -------------------------------------------------------------------

if ($GamePath) {
    if (-not (Test-DarktideFolder -Path $GamePath)) {
        throw "'$GamePath' does not look like a Darktide install (no binaries\Darktide.exe or bundle\bundle_database.data)."
    }
    $resolvedGame = (Resolve-Path -LiteralPath $GamePath).Path.TrimEnd('\')
    Write-Ok "Game folder (given): $resolvedGame"
} else {
    Write-Step 'Looking for Darktide...'
    $candidates = Find-DarktideInstall

    if ($candidates.Count -eq 0) {
        throw @"
Could not find a Darktide install automatically.

Looked in every Steam library listed in libraryfolders.vdf, and for the game's Steam
app manifest ($($script:DarktideAppId)). Pass the folder explicitly:

    .\darktide.ps1 init -GamePath 'D:\Games\Steam\steamapps\common\Warhammer 40,000 DARKTIDE'

It is the folder containing binaries\Darktide.exe.
"@
    }

    foreach ($c in $candidates) { Write-Host "  found: $($c.Path)   [$($c.Source)]" }
    $resolvedGame = $candidates[0].Path
    if ($candidates.Count -gt 1) {
        Write-Warn "  more than one install found - using the first. Pass -GamePath to choose another."
    }
    Write-Ok "Game folder: $resolvedGame"
}

# ---- Staging folder ----------------------------------------------------------------

if (-not $ModsRoot) {
    # Default to a sibling of the repo, so staging is never inside the game folder
    # and never inside the repository (where it would risk being committed).
    $ModsRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'mods'
}
Write-Ok "Staging   : $ModsRoot"

# ---- Downloads ---------------------------------------------------------------------

if (-not $DownloadDir) {
    $DownloadDir = Join-Path $env:USERPROFILE 'Downloads'
    # Honour a relocated Downloads folder if the shell knows about one.
    $shell = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'
    if (Test-Path $shell) {
        $props = Get-ItemProperty -Path $shell -ErrorAction SilentlyContinue
        $key = '{374DE290-123F-4565-9164-39C4925E467B}'
        if ($props -and $props.PSObject.Properties.Name -contains $key -and "$($props.$key)") {
            $moved = "$($props.$key)"
            if (Test-Path -LiteralPath $moved -PathType Container) { $DownloadDir = $moved }
        }
    }
}
Write-Ok "Downloads : $DownloadDir"

# ---- Mod loader --------------------------------------------------------------------

# The loader is a separate download that drops files into the game folder. Record it
# if the user already has it unzipped somewhere obvious, so 'darktide.ps1 loader'
# needs no arguments.
if (-not $LoaderSource) {
    $searchRoots = @((Split-Path -Parent $PSScriptRoot), (Split-Path -Parent $ModsRoot), $DownloadDir) |
                   Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } |
                   Select-Object -Unique

    foreach ($root in $searchRoots) {
        foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                           Where-Object { $_.Name -match '(?i)mod.?loader' } |
                           Sort-Object LastWriteTime -Descending)) {
            $looksRight = (Test-Path -LiteralPath (Join-Path $dir.FullName 'toggle_darktide_mods.bat')) -and
                          (Test-Path -LiteralPath (Join-Path $dir.FullName 'tools\dtkit-patch.exe'))
            if ($looksRight) { $LoaderSource = $dir.FullName; break }
        }
        if ($LoaderSource) { break }
    }
}

if ($LoaderSource) { Write-Ok "Loader    : $LoaderSource" }
else { Write-Warn "Loader    : not found - download it from https://www.nexusmods.com/warhammer40kdarktide/mods/19" }

$parent = Split-Path -Parent $ModsRoot
$config = [ordered]@{
    ModsRoot         = $ModsRoot
    GamePath         = $resolvedGame
    LoaderSource     = $LoaderSource
    DownloadDir      = $DownloadDir
    BackupRoot       = (Join-Path $parent 'mod_backups')
    DeployBackupRoot = (Join-Path $parent 'deploy_backups')
    GameDomain       = 'warhammer40kdarktide'
    ApiKey           = ''
}

Write-Host ''

if ((Test-Path -LiteralPath $ConfigPath) -and -not $Force) {
    Write-Warn "config.json already exists - not overwriting it."
    Write-Host  "  $ConfigPath"
    Write-Host  '  Pass -Force to replace it, or edit it by hand.'
    Write-Host ''
    Write-Host 'Detected settings, for reference:' -ForegroundColor Cyan
    ($config | ConvertTo-Json) | Write-Host
    return
}

if ($PSCmdlet.ShouldProcess($ConfigPath, 'Write configuration')) {
    ($config | ConvertTo-Json) | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    Write-Ok "Wrote $ConfigPath"

    # Create staging if it is missing, so 'status' has something to report.
    if (-not (Test-Path -LiteralPath $ModsRoot)) {
        New-Item -ItemType Directory -Path $ModsRoot -Force | Out-Null
        Write-Ok "Created $ModsRoot"
    }

    Write-Host ''
    Write-Host 'Next:' -ForegroundColor Cyan
    Write-Host '  .\darktide.ps1 status                       see what is installed'
    Write-Host '  .\darktide.ps1 loader -Apply                install the Darktide Mod Loader'
    Write-Host '  .\darktide.ps1 import -Path <loadout.zip> -Apply   restore a saved loadout'
}
