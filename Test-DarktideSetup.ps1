<#
.SYNOPSIS
    Explains why mods will not load, and whether what you are about to play is what
    you locked. Read-only.

.DESCRIPTION
    One command for the two questions that otherwise take a dozen: "why won't my mods
    load?" and "is the loadout in the game the one in darktide-modpack.lock.json?".

    Every check prints a PASS, WARN, FAIL or INFO line under its section, and every
    problem comes with the command that fixes it. A summary follows.

        Config         config.json present and parseable, ModsRoot and GamePath exist,
                       GamePath looks like a Darktide install.
        Load order     staging and game mod_load_order.txt: entries with no folder,
                       folders nobody listed, duplicates, disabled (--) entries, dmf
                       present and first, byte-order mark and line endings.
        Folder layout  every mod folder holds <folder>\<folder>.mod; archives extracted
                       one level too deep; .mod named differently from its folder;
                       empty folders; leftover .staging-* folders.
        Drift          staging against the lockfile's content hashes, staging against
                       the game folder, the lockfile's load order against staging's.
        Loader         .darktide-loader.json, the bundle\*.patch_999 entry bundle and
                       tools\dtkit-patch.exe.

    It works before 'init': with no config.json it reports that as a FAIL and still runs
    every check it has a path for (pass -StagingMods / -GamePath to give it one).

    It writes nothing except the -OutFile you ask for, never touches the network, and
    only reads the game folder.

    Two things here are heuristics this repository cannot verify, and are reported as
    WARN rather than FAIL for that reason: that dmf should come first when it is listed
    in mod_load_order.txt, and whether the game's bundle database is currently patched
    (that is the 'patchcheck' verb's job, so this only points you at it).

.PARAMETER ConfigPath
    config.json to read. A missing or broken one is reported, not fatal.

.PARAMETER StagingMods
    Check this staging folder instead of the ModsRoot in config.json.

.PARAMETER GamePath
    Check this game install instead of the GamePath in config.json.

.PARAMETER LockPath
    The lockfile to compare staging against. Defaults to darktide-modpack.lock.json
    beside this script.

.PARAMETER Quick
    Skip content hashing. Staging is still compared with the lockfile and the game
    folder by folder name, just not by content. Much faster on a large loadout.

.PARAMETER OutFile
    Also write the results to this file: .json for a machine-readable report, .md for
    markdown. Nothing else is ever written.

.PARAMETER Force
    Overwrite -OutFile if it already exists.

.EXAMPLE
    .\Test-DarktideSetup.ps1
    Every check, with content hashes. Exit 1 if anything FAILs.

.EXAMPLE
    .\Test-DarktideSetup.ps1 -Quick
    The same, comparing folder names only. Seconds rather than minutes.

.EXAMPLE
    .\Test-DarktideSetup.ps1 -OutFile doctor.md
    Also keep the report as markdown, e.g. to paste into a bug report.

.NOTES
    Exit codes: 0 when nothing FAILs (WARN and INFO allowed), 1 when anything FAILs.
    A precondition this script cannot work around - a bad -OutFile - throws.
#>

[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string] $StagingMods,
    [string] $GamePath,
    [string] $LockPath = (Join-Path $PSScriptRoot 'darktide-modpack.lock.json'),
    [switch] $Quick,
    [string] $OutFile,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$m) Write-Host $m -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host $m -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host $m -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host $m -ForegroundColor Red }

# ----------------------------------------------------------------------------------
# Results
# ----------------------------------------------------------------------------------

$script:Results = New-Object System.Collections.Generic.List[object]
$script:Section = ''

function Start-Section {
    param([string] $Name)
    $script:Section = $Name
    Write-Host ''
    Write-Step "== $Name"
}

function Add-Result {
    <#
        Records one finding and prints it. Check is a stable id (e.g. 'loadorder.ghost')
        so a script reading the -OutFile JSON does not have to parse the message.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')][string] $Status,
        [Parameter(Mandatory)][string] $Check,
        [Parameter(Mandatory)][string] $Message,
        [string] $Fix = '',
        [string] $Location = '',
        [string] $Subject = ''
    )

    $script:Results.Add([pscustomobject]@{
        section  = $script:Section
        status   = $Status
        check    = $Check
        location = $Location
        subject  = $Subject
        message  = $Message
        fix      = $Fix
    })

    $line = "  $($Status.PadRight(4))  $Message"
    switch ($Status) {
        'PASS' { Write-Ok   $line }
        'WARN' { Write-Warn $line }
        'FAIL' { Write-Err  $line }
        default { Write-Host $line }
    }
    if ($Fix) { Write-Host "        fix: $Fix" }
}

function Format-Literal {
    <# A path as a single-quoted PowerShell literal, so a fix can be pasted as-is. #>
    param([string] $Text)
    return "'" + $Text.Replace("'", "''") + "'"
}

# ----------------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------------

function Get-FolderHash {
    <#
      Stable content hash of a mod folder: SHA-256 over each file's relative path and
      its own SHA-256, in sorted order. Independent of timestamps and enumeration order.
      DMF keeps user settings in %APPDATA%, not in the mod folder, so this stays stable
      across play sessions.
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

function Get-GameFolderProblem {
    <#
        Same tests as Assert-ValidGamePath in Deploy-DarktideMods.ps1, copied rather than
        shared, but reporting instead of throwing. Returns $null when the folder looks
        like Darktide, otherwise why it does not.
    #>
    param([string] $Path)

    $full = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\', '/')

    if (-not $full -or $full -match '^[A-Za-z]:\\?$') {
        return "'$Path' is a drive root"
    }
    if (@($full -split '[\\/]' | Where-Object { $_ }).Count -lt 3) {
        return "'$full' is suspiciously shallow for a game install"
    }

    $markers = @(
        (Join-Path $full 'binaries\Darktide.exe'),
        (Join-Path $full 'binaries_dx12\Darktide.exe'),
        (Join-Path $full 'bundle\bundle_database.data'),
        (Join-Path $full 'launcher\Launcher.exe')
    )
    $hit = @($markers | Where-Object { Test-Path -LiteralPath $_ })
    if (-not $hit) {
        return "'$full' does not look like Darktide: none of binaries\Darktide.exe, binaries_dx12\Darktide.exe, bundle\bundle_database.data or launcher\Launcher.exe is there"
    }
    return $null
}

function Get-ModDirectory {
    <# Mod folders under a mods root: not dot-folders. -Force so hidden ones are seen too. #>
    param([string] $Root)
    return @(Get-ChildItem -LiteralPath $Root -Directory -Force |
             Where-Object { -not $_.Name.StartsWith('.') } | Sort-Object Name)
}

function Read-LoadOrder {
    <#
        Parses mod_load_order.txt without trimming away the things worth reporting.
        Returns enabled entries (trimmed, in order, with line numbers), disabled
        '--name' entries, and the raw byte-level facts (BOM, line endings).
    #>
    param([string] $Path)

    $bytes = [System.IO.File]::ReadAllBytes((Convert-Path -LiteralPath $Path))
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }

    $crlf = ([regex]::Matches($text, "`r`n")).Count
    $lf   = ([regex]::Matches($text, "(?<!`r)`n")).Count
    $cr   = ([regex]::Matches($text, "`r(?!`n)")).Count

    $enabled  = New-Object System.Collections.Generic.List[object]
    $disabled = New-Object System.Collections.Generic.List[string]
    $lines = [regex]::Split($text, "`r`n|`n|`r")
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        $t = $raw.Trim()
        if (-not $t) { continue }
        if ($t.StartsWith('--')) {
            # '--name' disables a mod; '-- some words' is a comment.
            $rest = $t.Substring(2).Trim()
            if ($rest -and $rest -notmatch '\s') { $disabled.Add($rest) }
            continue
        }
        $enabled.Add([pscustomobject]@{ Name = $t; Raw = $raw; Line = $i + 1 })
    }

    return [pscustomobject]@{
        Bytes    = $bytes
        HasBom   = $hasBom
        CrLf     = $crlf
        Lf       = $lf
        Cr       = $cr
        Enabled  = $enabled.ToArray()
        Disabled = $disabled.ToArray()
    }
}

# ----------------------------------------------------------------------------------
# -OutFile is the one thing this writes; refuse a bad one before doing any work
# ----------------------------------------------------------------------------------

$outFull = $null
$outKind = $null
if ($OutFile) {
    $outFull = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
    $ext = [System.IO.Path]::GetExtension($outFull).ToLowerInvariant()
    if ($ext -eq '.json') { $outKind = 'json' }
    elseif ($ext -eq '.md') { $outKind = 'md' }
    else { throw "-OutFile must end in .json or .md (got '$OutFile')." }

    if ((Test-Path -LiteralPath $outFull) -and -not $Force) {
        throw "'$outFull' already exists. Pass -Force to overwrite it."
    }
    $outDir = Split-Path -Parent $outFull
    if ($outDir -and -not (Test-Path -LiteralPath $outDir -PathType Container)) {
        throw "Folder '$outDir' for -OutFile does not exist."
    }
}

Write-Step '=== Darktide setup doctor ==='
Write-Host  "Mode    : read-only$(if ($Quick) { ', -Quick (no content hashing)' })"

# ----------------------------------------------------------------------------------
# 1. Config
# ----------------------------------------------------------------------------------

Start-Section 'Config'

$modsRoot = ''
$gameRoot = ''
$cfgObj   = $null

if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    try {
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
        if (-not $raw -or -not $raw.Trim()) {
            Add-Result FAIL 'config.empty' "config.json at '$ConfigPath' is empty." `
                -Fix '.\darktide.ps1 init -Force'
        } else {
            $cfgObj = $raw | ConvertFrom-Json
            Add-Result PASS 'config.present' "config.json found and parsed: $ConfigPath"
        }
    } catch {
        Add-Result FAIL 'config.parse' "config.json at '$ConfigPath' is not valid JSON: $($_.Exception.Message)" `
            -Fix "fix it by hand (notepad $(Format-Literal $ConfigPath)), or rewrite it with .\darktide.ps1 init -Force"
    }
} else {
    Add-Result FAIL 'config.missing' "No config.json at '$ConfigPath'." -Fix '.\darktide.ps1 init'
}

if ($cfgObj) {
    $names = @($cfgObj.PSObject.Properties | ForEach-Object { $_.Name })
    if ($names -contains 'ModsRoot' -and "$($cfgObj.ModsRoot)".Trim()) { $modsRoot = "$($cfgObj.ModsRoot)" }
    if ($names -contains 'GamePath' -and "$($cfgObj.GamePath)".Trim()) { $gameRoot = "$($cfgObj.GamePath)" }
}
if ($StagingMods) { $modsRoot = $StagingMods }
if ($GamePath)    { $gameRoot = $GamePath }

$stagingOk = $false
if (-not $modsRoot) {
    Add-Result FAIL 'config.modsroot' 'ModsRoot (your staging mods folder) is not set.' `
        -Fix 'set ModsRoot in config.json, or run .\darktide.ps1 init'
} elseif (-not (Test-Path -LiteralPath $modsRoot -PathType Container)) {
    Add-Result FAIL 'config.modsroot' "ModsRoot '$modsRoot' does not exist." `
        -Fix 'fix ModsRoot in config.json (README, First-time setup step 3 covers creating staging)'
} else {
    $modsRoot = (Resolve-Path -LiteralPath $modsRoot).Path.TrimEnd('\', '/')
    $stagingOk = $true
    Add-Result PASS 'config.modsroot' "staging: $modsRoot"
}

$gameOk = $false
$gameMods = $null
if (-not $gameRoot) {
    Add-Result FAIL 'config.gamepath' 'GamePath (the Darktide install folder) is not set.' `
        -Fix '.\darktide.ps1 init  (or set GamePath in config.json)'
} elseif (-not (Test-Path -LiteralPath $gameRoot -PathType Container)) {
    Add-Result FAIL 'config.gamepath' "GamePath '$gameRoot' does not exist." `
        -Fix '.\darktide.ps1 init -Force  (or fix GamePath in config.json)'
} else {
    $problem = Get-GameFolderProblem -Path $gameRoot
    if ($problem) {
        Add-Result FAIL 'config.gamepath' $problem `
            -Fix 'point GamePath at the folder holding binaries\Darktide.exe: .\darktide.ps1 init -Force'
    } else {
        $gameRoot = (Resolve-Path -LiteralPath $gameRoot).Path.TrimEnd('\', '/')
        $gameMods = Join-Path $gameRoot 'mods'
        $gameOk = $true
        Add-Result PASS 'config.gamepath' "game: $gameRoot"
    }
}

# The report must not land in the game folder (read-only to this script) or in staging
# (where the next deploy would copy it into the game).
if ($outFull) {
    foreach ($guard in @($(if ($gameOk) { $gameRoot }), $(if ($stagingOk) { $modsRoot }))) {
        if (-not $guard) { continue }
        $prefix = $guard.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        if ($outFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to write -OutFile inside '$guard'. Put the report somewhere else."
        }
    }
}

if ($stagingOk -and $gameOk -and (Test-Path -LiteralPath $gameMods -PathType Container)) {
    $gm = (Resolve-Path -LiteralPath $gameMods).Path.TrimEnd('\', '/')
    if ($gm -eq $modsRoot) {
        Add-Result WARN 'config.samefolder' "ModsRoot is the game's own mods folder, so there is no staging copy to deploy from or roll back to." `
            -Fix 'point ModsRoot at a separate folder (README, First-time setup step 3)'
    }
}

# ----------------------------------------------------------------------------------
# 2. Load order
# ----------------------------------------------------------------------------------

Start-Section 'Load order'

$script:LoadOrders = @{}

function Test-LoadOrderAt {
    param(
        [string] $Location,
        [string] $Root,
        [string] $GameFix
    )

    $lo = Join-Path $Root 'mod_load_order.txt'
    if (-not (Test-Path -LiteralPath $lo -PathType Leaf)) {
        $fix = if ($Location -eq 'game') { '.\darktide.ps1 deploy -Apply' } else {
            "create $lo with one mod folder name per line"
        }
        Add-Result FAIL 'loadorder.missing' "$Location has no mod_load_order.txt - the mod loader reads nothing without it." `
            -Fix $fix -Location $Location
        return
    }

    $parsed = Read-LoadOrder -Path $lo
    $script:LoadOrders[$Location] = $parsed
    $dirs = Get-ModDirectory -Root $Root
    $dirNames = @($dirs | ForEach-Object { $_.Name })

    # Entries with no folder: DMF errors on startup.
    $ghosts = @($parsed.Enabled | Where-Object { $dirNames -notcontains $_.Name })
    foreach ($g in $ghosts) {
        $fix = if ($Location -eq 'game') { $GameFix } else {
            "install '$($g.Name)', or delete line $($g.Line) of $lo (or disable it with --)"
        }
        Add-Result FAIL 'loadorder.ghost' "$Location load order line $($g.Line) lists '$($g.Name)' but there is no such folder - the game errors on startup." `
            -Fix $fix -Location $Location -Subject $g.Name
    }
    if (-not $ghosts) {
        Add-Result PASS 'loadorder.resolves' "$Location load order: all $(@($parsed.Enabled).Count) entries have a folder." -Location $Location
    }

    # Duplicates, ignoring case and surrounding whitespace.
    $groups = @($parsed.Enabled | Group-Object { $_.Name.ToLowerInvariant() } | Where-Object { $_.Count -gt 1 })
    foreach ($grp in $groups) {
        $where = ($grp.Group | ForEach-Object { "line $($_.Line) '$($_.Raw)'" }) -join ', '
        Add-Result WARN 'loadorder.duplicate' "$Location load order lists '$($grp.Group[0].Name)' $($grp.Count) times: $where." `
            -Fix "keep one of those lines in $lo" -Location $Location -Subject $grp.Group[0].Name
    }

    # Folders nobody listed. base is the loader, dmf is loaded by it.
    $listed = @($parsed.Enabled | ForEach-Object { $_.Name }) + @($parsed.Disabled)
    $unlisted = @($dirNames | Where-Object { $_ -notin @('base', 'dmf') -and $listed -notcontains $_ })
    foreach ($u in $unlisted) {
        $fix = if ($Location -eq 'game') { $GameFix } else {
            "add '$u' to $lo, or remove the folder if you meant to uninstall it"
        }
        Add-Result WARN 'loadorder.unlisted' "$Location has folder '$u' that mod_load_order.txt does not list, so it will not load." `
            -Fix $fix -Location $Location -Subject $u
    }

    if (@($parsed.Disabled).Count -gt 0) {
        Add-Result INFO 'loadorder.disabled' "$Location disabled with --: $(@($parsed.Disabled) -join ', ')" -Location $Location
    }

    # dmf: the framework nearly every mod depends on.
    if ($dirNames -notcontains 'dmf') {
        $fix = if ($Location -eq 'game') { '.\darktide.ps1 deploy -Apply' } else {
            'download Darktide Mod Framework (Nexus mod 8) into DownloadDir, then .\darktide.ps1 update -Apply -Only dmf'
        }
        Add-Result FAIL 'loadorder.nodmf' "$Location has no dmf folder (Darktide Mod Framework) - almost every mod needs it." `
            -Fix $fix -Location $Location -Subject 'dmf'
    }
    $dmfAt = -1
    $en = @($parsed.Enabled)
    for ($i = 0; $i -lt $en.Count; $i++) { if ($en[$i].Name -eq 'dmf') { $dmfAt = $i; break } }
    if ($dmfAt -gt 0) {
        Add-Result WARN 'loadorder.dmforder' "$Location load order lists dmf at line $($en[$dmfAt].Line), not first. Common advice is dmf first; this tool has not verified that rule." `
            -Fix "move the dmf line to the top of $lo" -Location $Location -Subject 'dmf'
    }

    if ($parsed.HasBom) {
        Add-Result INFO 'loadorder.bom' "$Location mod_load_order.txt starts with a UTF-8 byte-order mark (Windows PowerShell writes one; usually harmless)." -Location $Location
    }
    if ($parsed.Cr -gt 0 -or ($parsed.CrLf -gt 0 -and $parsed.Lf -gt 0)) {
        Add-Result INFO 'loadorder.lineendings' "$Location mod_load_order.txt has mixed line endings ($($parsed.CrLf) CRLF, $($parsed.Lf) LF, $($parsed.Cr) bare CR)." `
            -Fix "re-save $lo with Windows (CRLF) line endings" -Location $Location
    }
}

if ($stagingOk) {
    Test-LoadOrderAt -Location 'staging' -Root $modsRoot -GameFix ''
} else {
    Add-Result INFO 'loadorder.skipped' 'staging load order not checked: no usable ModsRoot.' -Location 'staging'
}
if ($gameOk) {
    if (Test-Path -LiteralPath $gameMods -PathType Container) {
        Test-LoadOrderAt -Location 'game' -Root $gameMods `
            -GameFix 'fix staging first if it shows the same problem, then .\darktide.ps1 deploy -Apply -Mirror'
    } else {
        Add-Result FAIL 'loadorder.nogamemods' "the game folder has no mods\ folder - nothing has been deployed." `
            -Fix '.\darktide.ps1 deploy -Apply' -Location 'game'
    }
} else {
    Add-Result INFO 'loadorder.skipped' 'game load order not checked: no usable GamePath.' -Location 'game'
}

# ----------------------------------------------------------------------------------
# 3. Folder structure
# ----------------------------------------------------------------------------------

Start-Section 'Folder structure'

function Test-StructureAt {
    param(
        [string] $Location,
        [string] $Root,
        [string] $GameFix
    )

    $good = 0
    foreach ($dir in (Get-ChildItem -LiteralPath $Root -Directory -Force | Sort-Object Name)) {
        $name = $dir.Name
        $path = $dir.FullName

        if ($name.StartsWith('.')) {
            if ($name.StartsWith('.staging-')) {
                # In the game it arrived by deploy, so it leaves the same way.
                $fix = if ($Location -eq 'game') {
                    'delete it from staging first if it is there too, then .\darktide.ps1 deploy -Apply -Mirror (which also removes anything else not in staging)'
                } else {
                    "safe to delete when no update is running: Remove-Item -LiteralPath $(Format-Literal $path) -Recurse -Force"
                }
                Add-Result INFO 'structure.leftover' "$Location has '$name', left behind by an interrupted install." `
                    -Fix $fix -Location $Location -Subject $name
            }
            continue
        }
        # base is the loader itself and has no base.mod.
        if ($name -eq 'base') { continue }

        $children = @(Get-ChildItem -LiteralPath $path -Force)
        if ($children.Count -eq 0) {
            $fix = if ($Location -eq 'game') { $GameFix } else {
                "reinstall the mod, or remove the folder: Remove-Item -LiteralPath $(Format-Literal $path)"
            }
            Add-Result WARN 'structure.empty' "$Location folder '$name' is empty." -Fix $fix -Location $Location -Subject $name
            continue
        }

        if (Test-Path -LiteralPath (Join-Path $path "$name.mod") -PathType Leaf) { $good++; continue }

        $inner = Join-Path $path $name
        if (Test-Path -LiteralPath (Join-Path $inner "$name.mod") -PathType Leaf) {
            $fix = if ($Location -eq 'game') { $GameFix } else {
                "Get-ChildItem -LiteralPath $(Format-Literal $inner) -Force | Move-Item -Destination $(Format-Literal $path); Remove-Item -LiteralPath $(Format-Literal $inner)"
            }
            Add-Result FAIL 'structure.nested' "$Location '$name' was extracted one level too deep: the mod is in $name\$name\$name.mod, DMF looks for $name\$name.mod." `
                -Fix $fix -Location $Location -Subject $name
            continue
        }

        $mods = @($children | Where-Object { -not $_.PSIsContainer -and $_.Extension -eq '.mod' })
        if ($mods.Count -gt 0) {
            $modName = [System.IO.Path]::GetFileNameWithoutExtension($mods[0].Name)
            $fix = if ($Location -eq 'game') { $GameFix } else {
                $clash = if (Test-Path -LiteralPath (Join-Path $Root $modName)) {
                    " (a '$modName' folder already exists - remove whichever copy is stale first)"
                } else { '' }
                "Rename-Item -LiteralPath $(Format-Literal $path) -NewName $(Format-Literal $modName), then change '$name' to '$modName' in mod_load_order.txt$clash"
            }
            $found = ($mods | ForEach-Object { $_.Name }) -join ', '
            Add-Result FAIL 'structure.modname' "$Location folder '$name' holds $found, not $name.mod - DMF will not find it." `
                -Fix $fix -Location $Location -Subject $name
            continue
        }

        $fix = if ($Location -eq 'game') { $GameFix } else {
            "reinstall '$name' from its Nexus archive: .\darktide.ps1 update -Apply -Force -Only $name"
        }
        Add-Result FAIL 'structure.nomod' "$Location folder '$name' has files but no $name.mod - it is not a DMF mod as laid out." `
            -Fix $fix -Location $Location -Subject $name
    }
    Add-Result PASS 'structure.ok' "$Location : $good mod folder(s) laid out as <folder>\<folder>.mod." -Location $Location
}

if ($stagingOk) {
    Test-StructureAt -Location 'staging' -Root $modsRoot -GameFix ''
} else {
    Add-Result INFO 'structure.skipped' 'staging layout not checked: no usable ModsRoot.' -Location 'staging'
}
if ($gameOk -and (Test-Path -LiteralPath $gameMods -PathType Container)) {
    Test-StructureAt -Location 'game' -Root $gameMods `
        -GameFix 'fix staging first if it shows the same problem, then .\darktide.ps1 deploy -Apply -Mirror'
} else {
    Add-Result INFO 'structure.skipped' 'game layout not checked: no deployed mods folder.' -Location 'game'
}

# ----------------------------------------------------------------------------------
# 4. Drift
# ----------------------------------------------------------------------------------

Start-Section 'Drift'

$script:StagingHashes = @{}
function Get-StagingHash {
    param([System.IO.DirectoryInfo] $Dir)
    if (-not $script:StagingHashes.ContainsKey($Dir.Name)) {
        $script:StagingHashes[$Dir.Name] = Get-FolderHash -Path $Dir.FullName
    }
    return $script:StagingHashes[$Dir.Name]
}

if ($Quick) {
    Add-Result INFO 'drift.quick' 'content hashing skipped (-Quick): comparing folder names only.'
}

# -- staging against the lockfile --

$lock = $null
if (-not (Test-Path -LiteralPath $LockPath -PathType Leaf)) {
    Add-Result WARN 'drift.nolock' "No lockfile at '$LockPath', so there is nothing to compare staging with." `
        -Fix '.\darktide.ps1 lock'
} else {
    try {
        $lock = Get-Content -LiteralPath $LockPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($lock.PSObject.Properties.Name -notcontains 'mods') { throw 'it has no mods array' }
    } catch {
        Add-Result WARN 'drift.badlock' "Lockfile '$LockPath' could not be read: $($_.Exception.Message)" -Fix '.\darktide.ps1 lock'
        $lock = $null
    }
}

if ($lock -and -not $stagingOk) {
    Add-Result INFO 'drift.skipped' 'lockfile comparison skipped: no usable ModsRoot.'
} elseif ($lock) {
    $stagedDirs = @{}
    foreach ($d in (Get-ModDirectory -Root $modsRoot)) {
        if ($d.Name -ne 'base') { $stagedDirs[$d.Name] = $d }
    }

    $lockedNames = @{}
    $match = 0
    $unknown = New-Object System.Collections.Generic.List[string]
    foreach ($m in @($lock.mods)) {
        if (-not $m -or $m.PSObject.Properties.Name -notcontains 'folder') { continue }
        $folder = "$($m.folder)"
        if (-not $folder) { continue }
        $lockedNames[$folder] = $true
        $ver = if ($m.PSObject.Properties.Name -contains 'version' -and $m.version) { " $($m.version)" } else { '' }

        if (-not $stagedDirs.ContainsKey($folder)) {
            $url = if ($m.PSObject.Properties.Name -contains 'url' -and $m.url) { " from $($m.url)" } else { '' }
            Add-Result WARN 'drift.missing' "MISSING  '$folder'$ver is in the lockfile but not in staging." `
                -Fix "download it$url and run .\darktide.ps1 update -Apply, or accept its removal with .\darktide.ps1 lock" `
                -Location 'staging' -Subject $folder
            continue
        }

        $locked = if ($m.PSObject.Properties.Name -contains 'contentSha256') { "$($m.contentSha256)" } else { '' }
        if (-not $locked) { $unknown.Add($folder); continue }
        if ($Quick) { continue }

        $now = Get-StagingHash -Dir $stagedDirs[$folder]
        if ($now -eq $locked.ToLowerInvariant()) {
            $match++
        } else {
            Add-Result WARN 'drift.changed' "CHANGED  '$folder' in staging differs from the locked content$(if ($ver) { " (locked$ver)" })." `
                -Fix "reinstall the locked version, or accept what is staged with .\darktide.ps1 lock" `
                -Location 'staging' -Subject $folder
        }
    }

    foreach ($n in ($stagedDirs.Keys | Sort-Object)) {
        if (-not $lockedNames.ContainsKey($n)) {
            Add-Result WARN 'drift.extra' "EXTRA  '$n' is staged but not in the lockfile." `
                -Fix 'record it with .\darktide.ps1 lock, or remove the folder if it should not be there' `
                -Location 'staging' -Subject $n
        }
    }

    if ($unknown.Count -gt 0) {
        Add-Result INFO 'drift.unknown' "$($unknown.Count) locked mod(s) have no content hash, so their content is unknown: $($unknown -join ', ')" `
            -Fix '.\darktide.ps1 lock  (hashes everything staged)'
    }
    if (-not $Quick) {
        Add-Result PASS 'drift.lockmatch' "$match staged mod(s) match their locked content hash."
    }

    # Load order in the lockfile against staging's.
    if ($script:LoadOrders.ContainsKey('staging') -and $lock.PSObject.Properties.Name -contains 'loadOrder') {
        # A null loadOrder pipes one $null, which "$_" would turn into an entry named ''.
        $lockOrder = @($lock.loadOrder | Where-Object { $_ } | ForEach-Object { "$_" })
        $stageOrder = @($script:LoadOrders['staging'].Enabled | ForEach-Object { $_.Name })
        $diffAt = -1
        $len = [Math]::Max($lockOrder.Count, $stageOrder.Count)
        for ($i = 0; $i -lt $len; $i++) {
            $a = if ($i -lt $lockOrder.Count) { $lockOrder[$i] } else { '(end)' }
            $b = if ($i -lt $stageOrder.Count) { $stageOrder[$i] } else { '(end)' }
            if ($a -ne $b) { $diffAt = $i; break }
        }
        if ($lockOrder.Count -eq 0 -and $stageOrder.Count -gt 0) {
            Add-Result INFO 'drift.lockorder' "the lockfile records no load order, so staging's ($($stageOrder.Count) entries) was not compared." `
                -Fix 'to record it: .\darktide.ps1 lock'
        } elseif ($diffAt -ge 0) {
            Add-Result INFO 'drift.lockorder' "staging load order differs from the lockfile's, first at position $($diffAt + 1): locked '$a', staged '$b'." `
                -Fix 'if the staged order is what you want: .\darktide.ps1 lock'
        } else {
            Add-Result PASS 'drift.lockorder' "staging load order matches the lockfile ($($stageOrder.Count) entries)."
        }
    }
}

# -- staging against the game folder --

if (-not ($stagingOk -and $gameOk -and (Test-Path -LiteralPath $gameMods -PathType Container))) {
    Add-Result INFO 'drift.skipped' 'staging-vs-game comparison skipped: needs both a staging folder and a deployed game mods folder.'
} else {
    $sDirs = @{}
    foreach ($d in (Get-ModDirectory -Root $modsRoot)) { $sDirs[$d.Name] = $d }
    $gDirs = @{}
    foreach ($d in (Get-ModDirectory -Root $gameMods)) { $gDirs[$d.Name] = $d }

    $problems = 0
    foreach ($n in ($sDirs.Keys | Sort-Object)) {
        if (-not $gDirs.ContainsKey($n)) {
            $problems++
            Add-Result WARN 'drift.notdeployed' "'$n' is staged but not in the game folder." `
                -Fix '.\darktide.ps1 deploy -Apply' -Location 'game' -Subject $n
        }
    }
    foreach ($n in ($gDirs.Keys | Sort-Object)) {
        if (-not $sDirs.ContainsKey($n)) {
            $problems++
            Add-Result WARN 'drift.notstaged' "'$n' is in the game folder but not in staging, so a restore or re-deploy will not bring it back." `
                -Fix '.\darktide.ps1 deploy -Apply -Mirror removes it; copy it into staging first if you want to keep it' `
                -Location 'game' -Subject $n
        }
    }

    $sLo = Join-Path $modsRoot 'mod_load_order.txt'
    $gLo = Join-Path $gameMods 'mod_load_order.txt'
    if ((Test-Path -LiteralPath $sLo -PathType Leaf) -and (Test-Path -LiteralPath $gLo -PathType Leaf)) {
        $sHash = (Get-FileHash -LiteralPath $sLo -Algorithm SHA256).Hash
        $gHash = (Get-FileHash -LiteralPath $gLo -Algorithm SHA256).Hash
        if ($sHash -ne $gHash) {
            $problems++
            Add-Result WARN 'drift.loadorderfile' 'the game mod_load_order.txt differs from staging, so the game is not running the order you staged.' `
                -Fix '.\darktide.ps1 deploy -Apply' -Location 'game' -Subject 'mod_load_order.txt'
        }
    }

    $compared = 0
    if (-not $Quick) {
        foreach ($n in ($sDirs.Keys | Sort-Object)) {
            if (-not $gDirs.ContainsKey($n)) { continue }
            $compared++
            $sh = Get-StagingHash -Dir $sDirs[$n]
            $gh = Get-FolderHash -Path $gDirs[$n].FullName
            if ($sh -ne $gh) {
                $problems++
                Add-Result WARN 'drift.gamecontent' "'$n' in the game folder differs from staging." `
                    -Fix '.\darktide.ps1 deploy -Apply  (add -Mirror to drop files only the game copy has)' `
                    -Location 'game' -Subject $n
            }
        }
    }

    if ($problems -eq 0) {
        $how = if ($Quick) { 'same folders (content not compared: -Quick)' } else { "$compared folder(s) identical" }
        Add-Result PASS 'drift.game' "staging and game match: $how."
    }
}

# ----------------------------------------------------------------------------------
# 5. Loader (light)
# ----------------------------------------------------------------------------------

Start-Section 'Loader'

if (-not $gameOk) {
    Add-Result INFO 'loader.skipped' 'loader not checked: no usable GamePath.'
} else {
    $state = Join-Path $gameRoot '.darktide-loader.json'
    if (Test-Path -LiteralPath $state -PathType Leaf) {
        try {
            $ls = Get-Content -LiteralPath $state -Raw -Encoding UTF8 | ConvertFrom-Json
            $props = @($ls.PSObject.Properties | ForEach-Object { $_.Name })
            $lv = if ($props -contains 'version' -and $ls.version) { "$($ls.version)" } else { 'unknown' }
            if ($props -contains 'patched' -and $ls.patched -eq $false) {
                Add-Result WARN 'loader.unpatched' "mod loader $lv was installed without patching the bundle database." `
                    -Fix '.\darktide.ps1 loader -Apply -Force'
            } elseif ($props -contains 'patched' -and $ls.patched) {
                Add-Result PASS 'loader.state' "mod loader $lv installed and recorded as patched."
            } else {
                Add-Result INFO 'loader.state' "mod loader $lv installed; .darktide-loader.json does not say whether it was patched."
            }
        } catch {
            Add-Result WARN 'loader.state' ".darktide-loader.json is unreadable: $($_.Exception.Message)" -Fix '.\darktide.ps1 loader -Apply -Force'
        }
    } else {
        Add-Result WARN 'loader.nostate' 'no .darktide-loader.json: the mod loader was not installed by this tool, or not at all.' `
            -Fix '.\darktide.ps1 loader -Apply'
    }

    $bundleDir = Join-Path $gameRoot 'bundle'
    $patch = @(Get-ChildItem -LiteralPath $bundleDir -Filter '*.patch_999' -File -ErrorAction SilentlyContinue)
    if ($patch.Count -gt 0) {
        Add-Result PASS 'loader.bundle' "mod entry bundle present: bundle\$($patch[0].Name)"
    } else {
        Add-Result FAIL 'loader.bundle' 'no bundle\*.patch_999 in the game folder - the mod loader is not installed, so no mod loads.' `
            -Fix '.\darktide.ps1 loader -Apply'
    }

    if (Test-Path -LiteralPath (Join-Path $gameRoot 'tools\dtkit-patch.exe') -PathType Leaf) {
        Add-Result PASS 'loader.patcher' 'patcher present: tools\dtkit-patch.exe'
    } else {
        Add-Result WARN 'loader.patcher' 'no tools\dtkit-patch.exe, so the bundle cannot be re-patched after a game update.' `
            -Fix '.\darktide.ps1 loader -Apply'
    }

    if ($gameMods -and (Test-Path -LiteralPath $gameMods -PathType Container) -and
        -not (Test-Path -LiteralPath (Join-Path $gameMods 'base') -PathType Container)) {
        Add-Result FAIL 'loader.base' "the game has no mods\base folder - the loader's own code, without which no mod loads." `
            -Fix '.\darktide.ps1 loader -Apply, then .\darktide.ps1 deploy -Apply'
    }

    Add-Result INFO 'loader.patchcheck' 'whether a game update has since replaced the patched bundle database is not checked here.' `
        -Fix '.\darktide.ps1 patchcheck'
}

# ----------------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------------

$all   = @($script:Results.ToArray())
$fails = @($all | Where-Object { $_.status -eq 'FAIL' })
$warns = @($all | Where-Object { $_.status -eq 'WARN' })
$passes = @($all | Where-Object { $_.status -eq 'PASS' })
$infos = @($all | Where-Object { $_.status -eq 'INFO' })

Write-Host ''
Write-Step '== Summary'
Write-Host "  PASS $($passes.Count)   WARN $($warns.Count)   FAIL $($fails.Count)   INFO $($infos.Count)"
if ($fails.Count -gt 0) {
    Write-Host ''
    Write-Err 'Fix these first - each one can stop mods loading:'
    foreach ($f in $fails) {
        Write-Err "  - $($f.message)"
        if ($f.fix) { Write-Host "      fix: $($f.fix)" }
    }
} elseif ($warns.Count -gt 0) {
    Write-Warn 'Nothing that stops mods loading. The warnings above are worth a look.'
} else {
    Write-Ok 'All checks passed.'
}

if ($outFull) {
    if ($outKind -eq 'json') {
        $report = [pscustomobject]@{
            tool        = 'Test-DarktideSetup.ps1'
            generatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            quick       = [bool]$Quick
            configPath  = $ConfigPath
            modsRoot    = $modsRoot
            gamePath    = $gameRoot
            lockPath    = $LockPath
            summary     = [pscustomobject]@{ pass = $passes.Count; warn = $warns.Count; fail = $fails.Count; info = $infos.Count }
            results     = $all
        }
        $text = $report | ConvertTo-Json -Depth 5
    } else {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('# Darktide setup doctor')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("Generated $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) UTC$(if ($Quick) { ', -Quick (no content hashing)' }).")
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("**PASS $($passes.Count) / WARN $($warns.Count) / FAIL $($fails.Count) / INFO $($infos.Count)**")
        $current = $null
        foreach ($r in $all) {
            if ($r.section -ne $current) {
                $current = $r.section
                [void]$sb.AppendLine('')
                [void]$sb.AppendLine("## $current")
                [void]$sb.AppendLine('')
            }
            [void]$sb.AppendLine("- **$($r.status)** $($r.message)")
            if ($r.fix) { [void]$sb.AppendLine("  - fix: ``$($r.fix)``") }
        }
        $text = $sb.ToString()
    }
    Set-Content -LiteralPath $outFull -Value $text -Encoding UTF8
    Write-Host ''
    Write-Host "Report written to $outFull"
}

if ($fails.Count -gt 0) { exit 1 }
exit 0
