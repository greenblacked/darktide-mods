<#
.SYNOPSIS
    Stages the release package and, unless told otherwise, zips it with a checksum.

.DESCRIPTION
    Publishing is the one irreversible thing this repository does, and until this
    script existed the packaging lived inside the release job's YAML - which meant
    it only ever ran during a real publish, and the validator had to find the
    allow-list by running a regex over the workflow file.

    The allow-list lives here now, once. CI runs this on every push so a broken
    allow-list is a red build rather than a bad release, and the release job calls
    the same code rather than a copy of it.

    Two independent layers decide what ships. The allow-list is the mechanism: only
    what it names is copied. The scan afterwards is what catches a mistake in the
    allow-list itself - it refuses to leave a .mod, a .zip or a config.json in the
    staged output. Keep both.

.PARAMETER Destination
    Where to build. The staged tree goes to <Destination>\darktide-mods and the
    archive beside it. Defaults to .\dist.

.PARAMETER Version
    Version string for the archive name. Required unless -NoArchive or -ListOnly.

.PARAMETER NoArchive
    Stage and scan, but write no zip. What CI runs on an ordinary push.

.PARAMETER ListOnly
    Write nothing; emit the allow-list. The validator uses this so its check cannot
    drift from what actually ships.

.EXAMPLE
    .\New-ReleasePackage.ps1 -NoArchive
    Proves the package can be built. Writes nothing that gets published.

.EXAMPLE
    .\New-ReleasePackage.ps1 -Version 1.2.0
    Builds dist\darktide-mods-1.2.0.zip and its .sha256 sidecar.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $Destination = (Join-Path $PSScriptRoot 'dist'),
    [string] $Version,
    [switch] $NoArchive,
    [switch] $ListOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# What ships. Everything else is deliberately absent: no mod content, no
# config.json, no API key, no nexus-catalog.json, no backups, no logs. The
# lockfile is a manifest that links to each author's Nexus page, which is the
# whole legal basis for this repository being publishable.
#
# tests\ and Invoke-Tests.ps1 are here so anyone can verify the tooling before
# running it against their own game folder. The skills directory is not: it is
# guidance for working on the repo, not part of the tool a user installs.
$Include = @(
    'darktide.ps1',
    'Update-DarktideMods.ps1',
    'Deploy-DarktideMods.ps1',
    'New-ModpackLock.ps1',
    'Export-DarktideLoadout.ps1',
    'Import-DarktideLoadout.ps1',
    'Initialize-DarktideConfig.ps1',
    'Install-DarktideLoader.ps1',
    # The dispatcher checks every script it fronts exists before it runs anything, so
    # a script left out here breaks every verb, not just its own.
    'Find-ModUpdates.ps1',
    'Test-Modpack.ps1',
    'Invoke-Tests.ps1',
    'tests',
    'config.example.json',
    'mods-map.json',
    'darktide-modpack.lock.json',
    'README.md',
    'LICENSE'
)

if ($ListOnly) {
    $Include
    return
}

if (-not $NoArchive -and -not $Version) {
    throw 'Give -Version, or -NoArchive to stage without building an archive.'
}

$stage = Join-Path $Destination 'darktide-mods'
if (Test-Path -LiteralPath $stage) {
    if (-not $PSCmdlet.ShouldProcess($stage, 'Remove the previous staged tree')) { return }
    Remove-Item -LiteralPath $stage -Recurse -Force
}
[void][System.IO.Directory]::CreateDirectory($stage)

foreach ($name in $Include) {
    $source = Join-Path $PSScriptRoot $name
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Missing required file: $name"
    }
    if (Test-Path -LiteralPath $source -PathType Container) {
        Copy-Item -LiteralPath $source -Destination $stage -Recurse -Force
    } else {
        Copy-Item -LiteralPath $source -Destination $stage -Force
    }
}

# The second layer. The allow-list above is the mechanism; this is what notices
# when the allow-list is wrong.
$forbidden = @(Get-ChildItem -LiteralPath $stage -Recurse -File |
               Where-Object { $_.Extension -in @('.mod', '.zip') -or $_.Name -eq 'config.json' })
if ($forbidden) {
    throw "Refusing to package: $(($forbidden | ForEach-Object { $_.Name }) -join ', ')"
}

$staged = @(Get-ChildItem -LiteralPath $stage -Recurse -File)
Write-Host "Staged $($staged.Count) file(s) into $stage"

if ($NoArchive) { return }

$zip = Join-Path $Destination "darktide-mods-$Version.zip"
if ($PSCmdlet.ShouldProcess($zip, 'Create the release archive')) {
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force

    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
    "$hash  darktide-mods-$Version.zip" | Out-File -LiteralPath "$zip.sha256" -Encoding ascii
    Write-Host "SHA-256: $hash"
    Write-Host "Archive: $zip"
}
