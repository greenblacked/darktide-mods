<#
.SYNOPSIS
    Reads Darktide's console logs and names the mod most likely behind an error or crash.

.DESCRIPTION
    Turns "the game crashed" or "a mod errored" into "most likely mod X", from the
    console logs the game writes while it runs.

    It reads the newest log (or the newest -Last N), finds the error and traceback
    lines, and maps each error to a mod by what the lines contain: a path fragment
    such as mods/<folder>/ or scripts/mods/<folder>/, or a DMF tag such as
    [<mod name>]. Names are matched against your staging folder and the lockfile,
    case-insensitively. The result is a ranked list with an error count, the first
    error line, and the version and Nexus page from the lockfile where it has them.

    It says "most likely", never "this is the one". A mod that hooks another mod's
    function can make its error surface in the other mod's stack, so the top of the
    list is where to look first, not a verdict.

    Read-only. It writes nothing except an -OutFile you ask for, never touches the
    game folder, and uses no network.

    The log folder and the log format are not verified by anything in this
    repository. The default folder, %APPDATA%\Fatshark\Darktide\console_logs, is
    where the game is known to keep them, and the patterns in $Patterns below are
    deliberately tolerant. If your logs live elsewhere, pass -LogDir or set
    ConsoleLogDir in config.json; if a pattern misses, it is one line to adjust.

    Logs contain your Windows user profile path and user name. Both are replaced
    with %USERPROFILE% and <user> in everything this prints or writes.

.PARAMETER LogDir
    The folder holding the console logs. Defaults to ConsoleLogDir from config.json
    when that key is present, then to %APPDATA%\Fatshark\Darktide\console_logs.

.PARAMETER Last
    How many of the newest log files to read, by last write time. Default 1, the
    log of the most recent session.

.PARAMETER Top
    How many mods to list. Default 10.

.PARAMETER TailLines
    How many lines to read from the end of each file. Default 20000, so a log that
    has grown very large is not read in full.

.PARAMETER OutFile
    Also write the report. A path ending in .json writes JSON; .md writes markdown.
    The same redaction applies.

.PARAMETER Force
    Overwrite -OutFile if it already exists.

.PARAMETER ConfigPath
    Optional. Read for ModsRoot (the staging folder, used to recognise mod names),
    GamePath (so -OutFile can refuse to land in the game folder) and ConsoleLogDir.
    Everything works without it when -LogDir is given.

.PARAMETER LockPath
    The lockfile, read for folder names, display names, versions and Nexus pages.

.EXAMPLE
    .\Get-DarktideErrors.ps1
    Reads the newest console log and lists the mods that most likely caused its errors.

.EXAMPLE
    .\Get-DarktideErrors.ps1 -Last 3 -OutFile errors.md
    The three newest logs, also written as markdown to paste into a bug report.

.EXAMPLE
    .\Get-DarktideErrors.ps1 -LogDir 'D:\from-a-friend\console_logs' -OutFile errors.json
    Someone else's logs, with no config.json needed.

.NOTES
    Exit 0 when the logs were read, whatever they contain. A missing log folder, no
    log files, or an -OutFile that already exists without -Force is a terminating
    error.
#>

[CmdletBinding()]
param(
    [string] $LogDir,
    [ValidateRange(1, 1000)]
    [int]    $Last = 1,
    [ValidateRange(1, 100)]
    [int]    $Top = 10,
    [ValidateRange(100, 10000000)]
    [int]    $TailLines = 20000,
    [string] $OutFile,
    [switch] $Force,
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string] $LockPath   = (Join-Path $PSScriptRoot 'darktide-modpack.lock.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---- Patterns ----------------------------------------------------------------------
#
# Every regex this script uses to read a log lives in this table, so adjusting it for
# a log format that has drifted is one edit in one place. None of them is verified
# against a specification - Fatshark does not publish one - so they are written to be
# tolerant rather than exact. All are matched case-insensitively unless marked.
#
#   ErrorLine     A line that starts a new error. Any one of these is enough.
#   TraceHeader   'stack traceback:' - joins the error above it rather than starting one.
#   Timestamp     A leading time stamp, stripped before the continuation tests.
#   Continuation  After an error, a line that is still part of it (a stack frame, a
#                 Lua stack marker). An indented line always counts as continuation.
#   ModPath       A path fragment naming a mod folder: mods/<folder>/ (which also
#                 covers scripts/mods/<folder>/), and the form Lua chunk names take
#                 inside a stack frame, [string "scripts/mods/<folder>"]. Folder names
#                 may contain brackets and spaces, so the folder stops only at a
#                 separator or a quote.
#   ModTag        A bracketed tag, as DMF prints them: [MOD][<mod name>][ERROR]. A tag
#                 only counts when it names a mod you actually have.
#   ModActivity   Any sign that mods were loaded at all. A log with none of these
#                 suggests the loader never ran.
#   UsersPath     A Windows profile path, for redaction. The name may contain spaces
#                 when a separator follows it ('C:\Users\Jane Doe\AppData'). The name it
#                 captures is also redacted wherever it appears on its own.
$Patterns = [ordered]@{
    ErrorLine    = @(
        '<+\s*(?:lua\s+)?error\s*>+'          # <error>, <<Lua Error>>  (closing tags excluded)
        '(?-i)\bERROR\b'                      # [ERROR], ERROR:  - upper case only, so 'errors: 0' is not one
        '\bscript\s+error\b'                  # Script Error
        '\[MOD\]\[[^\r\n]*\]\s*\[(?:error|fatal)\]'   # [MOD][name][ERROR], DMF's own error format
        '\bunhandled\s+exception\b'
    )
    TraceHeader  = '^\s*(?:\S+\s+)?stack\s+traceback\b'
    Timestamp    = '^\s*(?:\[?\d{4}-\d{2}-\d{2}[ T])?\d{1,2}:\d{2}:\d{2}(?:[.,]\d+)?\]?\s*'
    Continuation = @(
        '^\[string\s'                         # [string "scripts/mods/x/x"]:12: in function ...
        '^\[\d+\]'                            # [1] numbered frame
        '^\[C\]'                              # [C]: in function 'pcall'
        '^\(tail call\)'
        '^(?:in function|in main chunk)\b'
        '^<+\s*/?\s*lua\s+(?:stack|error)\s*>+'   # <<Lua Stack>>, <</Lua Stack>>, <</Lua Error>>
        '\.lua:\d+:\s*in\s'                   # mods/x/y.lua:12: in function ...
    )
    ModPath      = @(
        '(?:^|[^A-Za-z0-9_])mods[\\/]+(?<folder>[^\\/"''\s][^\\/"''\r\n]{0,63}?)[\\/]'
        'scripts[\\/]+mods[\\/]+(?<folder>[^\\/"''\s][^\\/"''\r\n]{0,63}?)["'']'
    )
    ModTag       = '\[(?<tag>[^\[\]\r\n]{2,80})\]'
    ModActivity  = '\[MOD\]|(?:^|[^A-Za-z0-9_])mods[\\/]|\bdmf\b|mod_loader|\bDarktide Mod Framework\b'
    UsersPath    = '\b[A-Za-z]:[\\/]+Users[\\/]+(?:(?<name>[^\\/"''<>|:*?\r\n]{1,64}?)(?=[\\/])|(?<name>[^\\/\s"''<>|:*?]+))'
}

# DMF and the loader's base mod sit in nearly every hook's stack. They are blamed only
# when nothing else in the error names a mod.
$FrameworkFolders = @('dmf', 'base')

# Profile folders that are not a person.
$NotAUser = @('Public', 'Default', 'Default User', 'All Users', 'defaultuser0')

$MaxBlockLines = 60
$MaxLineChars  = 200

# ---- Output -------------------------------------------------------------------------

$script:UserNames = [System.Collections.Generic.List[string]]::new()

function Protect-Text {
    <#
        Replaces the profile path with %USERPROFILE% and the user name with <user>.
        Idempotent: the two placeholders are split out before the name is replaced,
        so a user called 'user' cannot turn '<user>' into '<<user>>' on a second pass.
    #>
    param([AllowNull()][AllowEmptyString()][string] $Text)

    if (-not $Text) { return $Text }
    $out = $Text

    $userProfile = "$env:USERPROFILE".Trim()
    if ($userProfile.Length -ge 4) {
        # Either separator, any run of them, so the escaped form inside JSON matches too.
        $segments = @($userProfile -split '[\\/]+' | Where-Object { $_ } | ForEach-Object { [regex]::Escape($_) })
        if ($segments.Count -ge 2) {
            $rx = '(?i)' + ($segments -join '[\\/]+') + '(?![^\\/\s"''<>|:*?])'
            $out = [regex]::Replace($out, $rx, '%USERPROFILE%')
        }
    }

    # Anyone's profile path, not just this machine's: a log copied from a friend's PC
    # carries their name, not yours.
    $out = [regex]::Replace($out, "(?i)$($Patterns.UsersPath)", '%USERPROFILE%')

    $names = @($script:UserNames | Sort-Object Length -Descending)
    if ($names.Count -gt 0) {
        $alt = ($names | ForEach-Object { [regex]::Escape($_) }) -join '|'
        # '_' counts as part of a word, so a user called 'alpha' leaves the folder 'alpha_mod' alone.
        $rxName = "(?i)(?<![A-Za-z0-9_])(?:$alt)(?![A-Za-z0-9_])"
        $parts = [regex]::Split($out, '(%USERPROFILE%|<user>)')
        for ($i = 0; $i -lt $parts.Count; $i++) {
            if ($parts[$i] -eq '%USERPROFILE%' -or $parts[$i] -eq '<user>') { continue }
            $parts[$i] = [regex]::Replace($parts[$i], $rxName, '<user>')
        }
        $out = $parts -join ''
    }
    return $out
}

function Add-UserName {
    param([string] $Name)
    $n = "$Name".Trim()
    if ($n.Length -lt 2) { return }
    foreach ($skip in $NotAUser) { if ($n -ieq $skip) { return } }
    foreach ($have in $script:UserNames) { if ($have -ieq $n) { return } }
    $script:UserNames.Add($n)
}

function Write-Step { param([string] $Message) Write-Host (Protect-Text $Message) -ForegroundColor Cyan }
function Write-Info { param([string] $Message) Write-Host (Protect-Text $Message) }
function Write-Ok   { param([string] $Message) Write-Host (Protect-Text $Message) -ForegroundColor Green }
function Write-Warn { param([string] $Message) Write-Host (Protect-Text $Message) -ForegroundColor Yellow }

function Get-ShortLine {
    <# Redacted first, then cut, so a cut can never leave half a profile path behind. #>
    param([string] $Text)
    $t = (Protect-Text "$Text").Trim()
    if ($t.Length -gt $MaxLineChars) { $t = $t.Substring(0, $MaxLineChars - 3) + '...' }
    return $t
}

function ConvertTo-NormalKey {
    <# 'Beta Mod', 'beta_mod' and 'BetaMod' all become 'betamod'. #>
    param([string] $Text)
    return (("$Text".ToLowerInvariant()) -replace '[^a-z0-9]', '')
}

Add-UserName $env:USERNAME
if ("$env:USERPROFILE" -match "(?i)$($Patterns.UsersPath)") { Add-UserName $Matches['name'] }

# ---- Config (optional) -------------------------------------------------------------

$cfg = $null
if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    try {
        $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Warn "Could not read $ConfigPath ($($_.Exception.Message)). Carrying on without it."
        $cfg = $null
    }
}

function Get-CfgValue {
    param([string] $Key)
    if ($null -eq $cfg) { return '' }
    if ($cfg.PSObject.Properties.Name -contains $Key -and "$($cfg.$Key)".Trim()) { return "$($cfg.$Key)".Trim() }
    return ''
}

# ---- -OutFile, checked before any work so a bad path fails fast -------------------

$target = ''
$ext = ''
if ($OutFile) {
    $target = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
    $ext = [System.IO.Path]::GetExtension($target).ToLowerInvariant()
    if ($ext -ne '.json' -and $ext -ne '.md') {
        throw "-OutFile must end in .json or .md, not '$ext'."
    }
    # Read-only means read-only: the report never lands in the game folder.
    $gamePath = Get-CfgValue 'GamePath'
    if ($gamePath) {
        $g = [System.IO.Path]::GetFullPath($gamePath).TrimEnd('\', '/')
        $sep = [System.IO.Path]::DirectorySeparatorChar
        if ($target.StartsWith($g + $sep, [StringComparison]::OrdinalIgnoreCase) -or
            $target.StartsWith($g + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw (Protect-Text "Refusing to write '$target' inside the game folder. Pick somewhere else.")
        }
    }
    $parent = Split-Path -Parent $target
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw (Protect-Text "The folder for -OutFile does not exist: '$parent'.")
    }
    if ((Test-Path -LiteralPath $target) -and -not $Force) {
        throw (Protect-Text "'$target' already exists. Pass -Force to overwrite.")
    }
}

# ---- Where the logs are ------------------------------------------------------------

$logSource = '-LogDir'
if (-not $LogDir) {
    $fromCfg = Get-CfgValue 'ConsoleLogDir'
    if ($fromCfg) {
        $LogDir = $fromCfg
        $logSource = 'ConsoleLogDir in config.json'
    } elseif ("$env:APPDATA".Trim()) {
        $LogDir = Join-Path $env:APPDATA 'Fatshark\Darktide\console_logs'
        $logSource = 'the default location'
    } else {
        throw 'No console log folder: APPDATA is not set, so the default location cannot be worked out. Pass -LogDir.'
    }
}

if (-not (Test-Path -LiteralPath $LogDir -PathType Container)) {
    throw (Protect-Text ("Console log folder not found: '$LogDir' (from $logSource). " +
        'Darktide writes its logs to %APPDATA%\Fatshark\Darktide\console_logs as far as is known, but ' +
        'this repository cannot verify that. Start the game once so it writes a log, or point at the ' +
        'right folder with -LogDir (or ConsoleLogDir in config.json).'))
}

$allLogs = @(Get-ChildItem -LiteralPath $LogDir -File -ErrorAction Stop |
             Where-Object { $_.Extension -ieq '.log' -or $_.Extension -ieq '.txt' })
if ($allLogs.Count -eq 0) {
    throw (Protect-Text "No .log or .txt files in '$LogDir'. Start the game once so it writes a log, or check -LogDir.")
}

$newestFirst = @($allLogs | Sort-Object -Property @{ Expression = { $_.LastWriteTimeUtc }; Descending = $true },
                                                  @{ Expression = { $_.Name }; Descending = $true })
$picked = @($newestFirst | Select-Object -First $Last)
if ($picked.Count -lt $Last) {
    Write-Warn "Asked for $Last log(s); the folder has $($picked.Count)."
}
# Oldest first, so 'first error' means the earliest one.
[array]::Reverse($picked)

# ---- Known mods: staging and the lockfile ------------------------------------------

$mods     = @{}   # folder -> record (PowerShell hashtables compare keys case-insensitively)
$byName   = @{}   # display name -> folder
$byNormal = @{}   # normalised folder or name -> folder

function Add-KnownMod {
    param([string] $Folder, [string] $Name, [string] $Version, [string] $Url, [string] $Source)

    if (-not $Folder) { return }
    if (-not $mods.ContainsKey($Folder)) {
        $mods[$Folder] = [pscustomobject]@{ Folder = $Folder; Name = ''; Version = ''; Url = ''; Sources = @() }
    }
    $rec = $mods[$Folder]
    if ($Name    -and -not $rec.Name)    { $rec.Name = $Name }
    if ($Version -and -not $rec.Version) { $rec.Version = $Version }
    if ($Url     -and -not $rec.Url)     { $rec.Url = $Url }
    if ($rec.Sources -notcontains $Source) { $rec.Sources = @($rec.Sources) + $Source }

    if ($Name -and -not $byName.ContainsKey($Name)) { $byName[$Name] = $rec.Folder }
    foreach ($k in @($Folder, $Name)) {
        $n = ConvertTo-NormalKey $k
        if ($n.Length -ge 3 -and -not $byNormal.ContainsKey($n)) { $byNormal[$n] = $rec.Folder }
    }
}

# The lockfile first, so its display names and versions win over info.json.
if ($LockPath -and (Test-Path -LiteralPath $LockPath -PathType Leaf)) {
    try {
        $lock = Get-Content -LiteralPath $LockPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $game = if ($lock.PSObject.Properties.Name -contains 'game' -and $lock.game) { "$($lock.game)" } else { 'warhammer40kdarktide' }
        foreach ($m in @($lock.mods)) {
            if ($null -eq $m -or $m.PSObject.Properties.Name -notcontains 'folder') { continue }
            $p = $m.PSObject.Properties.Name
            $ver = if ($p -contains 'version' -and $m.version) { "$($m.version)" } else { '' }
            $url = if ($p -contains 'url' -and $m.url) {
                "$($m.url)"
            } elseif ($p -contains 'modId' -and $m.modId) {
                "https://www.nexusmods.com/$game/mods/$($m.modId)"
            } else { '' }
            $nm = if ($p -contains 'name' -and $m.name) { "$($m.name)" } else { '' }
            Add-KnownMod -Folder "$($m.folder)" -Name $nm -Version $ver -Url $url -Source 'lockfile'
        }
    } catch {
        Write-Warn "Could not read the lockfile $LockPath ($($_.Exception.Message)). No versions or pages will be shown."
    }
}

$stagingRoot = Get-CfgValue 'ModsRoot'
if ($stagingRoot) {
    if (Test-Path -LiteralPath $stagingRoot -PathType Container) {
        foreach ($d in @(Get-ChildItem -LiteralPath $stagingRoot -Directory -ErrorAction SilentlyContinue |
                         Where-Object { -not $_.Name.StartsWith('.') })) {
            $name = ''
            $info = Join-Path $d.FullName 'info.json'
            if (Test-Path -LiteralPath $info -PathType Leaf) {
                try {
                    $ij = Get-Content -LiteralPath $info -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($ij.PSObject.Properties.Name -contains 'name' -and $ij.name) { $name = "$($ij.name)" }
                } catch {
                    Write-Verbose "Unreadable info.json in $($d.Name): $($_.Exception.Message)"
                }
            }
            Add-KnownMod -Folder $d.Name -Name $name -Source 'staging'
        }
    } else {
        Write-Warn "Staging folder not found: $stagingRoot. Matching against the lockfile only."
    }
}

# Names that contain brackets cannot be found by the ModTag pattern (it stops at the
# first ']'), so they are looked for literally.
$bracketKeys = @(@($mods.Keys) + @($byName.Keys) | Where-Object { $_ -match '[\[\]]' } | Select-Object -Unique)

# ---- Matching ----------------------------------------------------------------------

# Each list becomes one compiled alternation: a 20,000-line log is tested line by line,
# and one regex call per line is several times faster than one per pattern. Each
# pattern keeps its own group, so an inline option such as (?-i) stays scoped to it.
$rxOpt = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
         [System.Text.RegularExpressions.RegexOptions]::Compiled
function New-Alternation {
    param([string[]] $Pattern)
    return (New-Object regex((($Pattern | ForEach-Object { "(?:$_)" }) -join '|'), $rxOpt))
}
$rxError      = New-Alternation $Patterns.ErrorLine
$rxContinue   = New-Alternation $Patterns.Continuation
$rxModPaths   = @($Patterns.ModPath | ForEach-Object { New-Object regex($_, $rxOpt) })
$rxTrace      = New-Object regex($Patterns.TraceHeader, $rxOpt)
$rxStamp      = New-Object regex($Patterns.Timestamp,   $rxOpt)
$rxTag        = New-Object regex($Patterns.ModTag,      $rxOpt)
$rxActivity   = New-Object regex($Patterns.ModActivity, $rxOpt)
$rxUsersPath  = New-Object regex($Patterns.UsersPath,   $rxOpt)

function Resolve-Folder {
    <# The known folder a candidate names, or '' if it names none. #>
    param([string] $Candidate, [switch] $Fuzzy)

    $c = "$Candidate".Trim()
    if (-not $c) { return '' }
    if ($mods.ContainsKey($c))   { return $mods[$c].Folder }
    if ($byName.ContainsKey($c)) { return $byName[$c] }
    if ($Fuzzy) {
        $n = ConvertTo-NormalKey $c
        if ($n.Length -ge 3 -and $byNormal.ContainsKey($n)) { return $byNormal[$n] }
    }
    return ''
}

function Get-ModMention {
    <# Every mod one line names, in the order they appear, as @{ Folder; Known; At }. #>
    param([string] $Text)

    $found = [System.Collections.Generic.List[object]]::new()

    foreach ($rx in $rxModPaths) {
        foreach ($m in $rx.Matches($Text)) {
            $raw = $m.Groups['folder'].Value.Trim()
            if (-not $raw) { continue }
            $known = Resolve-Folder $raw -Fuzzy
            if ($known) {
                $found.Add(@{ Folder = $known; Known = $true; At = $m.Groups['folder'].Index })
            } elseif ($raw -notmatch '^\d+$' -and $raw -notmatch '^\.') {
                # A folder you have not got - still worth naming, but say so.
                $found.Add(@{ Folder = $raw; Known = $false; At = $m.Groups['folder'].Index })
            }
        }
    }

    foreach ($m in $rxTag.Matches($Text)) {
        $known = Resolve-Folder $m.Groups['tag'].Value -Fuzzy
        if ($known) { $found.Add(@{ Folder = $known; Known = $true; At = $m.Index }) }
    }

    foreach ($k in $bracketKeys) {
        $at = $Text.IndexOf("[$k]", [StringComparison]::OrdinalIgnoreCase)
        if ($at -ge 0) {
            $known = Resolve-Folder $k
            if ($known) { $found.Add(@{ Folder = $known; Known = $true; At = $at }) }
        }
    }

    if ($found.Count -le 1) { return $found.ToArray() }
    return @($found | Sort-Object { $_.At })
}

# ---- Reading -----------------------------------------------------------------------

$stats         = @{}   # folder -> tally
$unattributedRaw = [System.Collections.Generic.List[string]]::new()
$unattribCount = 0
$blockCount    = 0
$sawModLines   = $false
$filesRead     = [System.Collections.Generic.List[object]]::new()
$mentionCache  = @{}

function Complete-Block {
    param([System.Collections.Generic.List[string]] $Lines, [string] $File)

    $script:blockCount++

    # Mentions across the whole error, in order, each mod once.
    $order = [System.Collections.Generic.List[object]]::new()
    $seen  = @{}
    foreach ($l in $Lines) {
        # A mod that errors every frame writes the same line thousands of times with
        # only the time stamp changing, so the answer is cached per stamp-less line.
        $key = $rxStamp.Replace($l, '', 1)
        if ($mentionCache.ContainsKey($key)) {
            $hits = $mentionCache[$key]
        } else {
            $hits = @(Get-ModMention $l)
            if ($mentionCache.Count -lt 20000) { $mentionCache[$key] = $hits }
        }
        foreach ($hit in $hits) {
            if ($seen.ContainsKey($hit.Folder)) { continue }
            $seen[$hit.Folder] = $true
            $order.Add($hit)
        }
    }

    if ($order.Count -eq 0) {
        $script:unattribCount++
        # Kept raw: redaction needs every user name in every log, and the last log
        # has not been read yet. Get-ShortLine runs at report time.
        if ($unattributedRaw.Count -lt 3 -and $unattributedRaw -notcontains $Lines[0]) { $unattributedRaw.Add($Lines[0]) }
        return
    }

    $primary = $null
    foreach ($hit in $order) { if ($FrameworkFolders -notcontains $hit.Folder) { $primary = $hit; break } }
    if ($null -eq $primary) { $primary = $order[0] }

    foreach ($hit in $order) {
        if (-not $stats.ContainsKey($hit.Folder)) {
            $stats[$hit.Folder] = [pscustomobject]@{
                Folder = $hit.Folder; Known = $hit.Known; Errors = 0; AlsoInStack = 0
                FirstErrorRaw = ''; FirstFile = ''
            }
        }
        $s = $stats[$hit.Folder]
        if ($hit.Folder -eq $primary.Folder) {
            $s.Errors++
            if (-not $s.FirstFile) {
                $s.FirstErrorRaw = $Lines[0]
                $s.FirstFile     = $File
            }
        } else {
            $s.AlsoInStack++
        }
    }
}

# One file at a time, so -Last on a folder of huge logs never holds more than one
# file's tail in memory. Nothing from a log is printed until all of them have been
# read, because every profile-path name in every log has to be known to redact it.
foreach ($f in $picked) {
    try {
        $lines = @(Get-Content -LiteralPath $f.FullName -Tail $TailLines -Encoding UTF8 -ErrorAction Stop)
    } catch {
        Write-Warn "Could not read $($f.Name): $($_.Exception.Message)"
        continue
    }
    $filesRead.Add([pscustomobject]@{
        Name          = $f.Name
        LastWriteTime = $f.LastWriteTime
        LinesRead     = $lines.Count
        Tail          = ($lines.Count -ge $TailLines)
    })

    $block = $null
    foreach ($raw in $lines) {
        $l = "$raw".TrimStart([char]0xFEFF)
        if (-not $sawModLines -and $rxActivity.IsMatch($l)) { $sawModLines = $true }
        if ($l.IndexOf('Users', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            foreach ($m in $rxUsersPath.Matches($l)) { Add-UserName $m.Groups['name'].Value }
        }

        $isError = $rxError.IsMatch($l)
        $isTrace = $rxTrace.IsMatch($l)
        if ($null -ne $block -and $block.Count -lt $MaxBlockLines) {
            # An indented line or 'stack traceback:' always belongs to the error above.
            # Anything else does only if it is not itself a new error and looks like a frame.
            $joins = $isTrace -or ($l.Length -gt 0 -and ($l[0] -eq ' ' -or $l[0] -eq "`t"))
            if (-not $joins -and -not $isError) { $joins = $rxContinue.IsMatch($rxStamp.Replace($l, '', 1)) }
            if ($joins) {
                $block.Add($l)
                continue
            }
        }
        if ($null -ne $block) { Complete-Block -Lines $block -File $f.Name; $block = $null }
        if ($isError -or $isTrace) {
            $block = [System.Collections.Generic.List[string]]::new()
            $block.Add($l)
        }
    }
    if ($null -ne $block) { Complete-Block -Lines $block -File $f.Name }
    $lines = $null
}
if ($filesRead.Count -eq 0) { throw (Protect-Text "None of the selected logs in '$LogDir' could be read.") }

# Every name is known now: redact, then cut.
$unattributed = @($unattributedRaw | ForEach-Object { Get-ShortLine $_ } | Select-Object -Unique)

# ---- Ranking -----------------------------------------------------------------------

$ranked = @($stats.Values | Where-Object { $_.Errors -gt 0 } |
            Sort-Object -Property @{ Expression = { $_.Errors };      Descending = $true },
                                  @{ Expression = { $_.AlsoInStack }; Descending = $true },
                                  @{ Expression = { $_.Folder };      Descending = $false })
$attributed = $blockCount - $unattribCount

$rows = [System.Collections.Generic.List[object]]::new()
$rank = 0
foreach ($s in ($ranked | Select-Object -First $Top)) {
    $rank++
    $rec = if ($mods.ContainsKey($s.Folder)) { $mods[$s.Folder] } else { $null }
    $rows.Add([pscustomobject]@{
        Rank        = $rank
        Folder      = $s.Folder
        Name        = $(if ($rec -and $rec.Name) { $rec.Name } else { '' })
        Known       = [bool]$s.Known
        Errors      = $s.Errors
        AlsoInStack = $s.AlsoInStack
        FirstError  = (Get-ShortLine $s.FirstErrorRaw)
        FirstFile   = $s.FirstFile
        Version     = $(if ($rec -and $rec.Version) { $rec.Version } else { '' })
        Url         = $(if ($rec -and $rec.Url) { $rec.Url } else { '' })
    })
}

$caveat = 'Most likely, not certain: a mod that hooks another mod''s function can make its error show up in the other mod''s stack. Start with the top of the list.'
$loaderHint = 'No mod lines at all in the log. The mod loader may not have run - after a game update Steam replaces the patched bundle. Check it with: .\darktide.ps1 patchcheck   (re-apply the patch with: .\darktide.ps1 loader -Apply)'

# ---- Report ------------------------------------------------------------------------

Write-Info ''
Write-Info "  Log folder : $LogDir"
foreach ($fr in $filesRead) {
    $how = if ($fr.Tail) { "last $($fr.LinesRead) lines" } else { "$($fr.LinesRead) lines" }
    Write-Info "  Read       : $($fr.Name)  ($($fr.LastWriteTime.ToString('yyyy-MM-dd HH:mm')), $how)"
}
Write-Info "  Mods known : $($mods.Count) (staging and lockfile)"
Write-Info ''

if ($blockCount -eq 0) {
    Write-Ok 'No errors found in the log.'
} else {
    Write-Info "$blockCount error(s) in the log ($attributed naming a mod, $unattribCount naming none)."
    Write-Info ''
    if ($rows.Count -gt 0) {
        Write-Step 'Most likely culprits:'
        foreach ($r in $rows) {
            $label = $r.Folder
            if ($r.Name -and $r.Name -ne $r.Folder) { $label = "$label ($($r.Name))" }
            $ver = if ($r.Version) { "   version $($r.Version)" } else { '' }
            Write-Warn ("  {0,2}. {1}   {2} error(s){3}" -f $r.Rank, $label, $r.Errors, $ver)
            Write-Info "      first : $($r.FirstError)"
            Write-Info "      in    : $($r.FirstFile)"
            if ($r.Url) { Write-Info "      page  : $($r.Url)" }
            if ($r.AlsoInStack -gt 0) { Write-Info "      also named in the stack of $($r.AlsoInStack) other error(s)" }
            if (-not $r.Known) { Write-Info '      (not in staging or the lockfile)' }
        }
        if ($ranked.Count -gt $rows.Count) {
            Write-Info "  ... and $($ranked.Count - $rows.Count) more. Raise -Top to see them."
        }
        Write-Info ''
        Write-Warn $caveat
        Write-Info 'If it started after an update: .\darktide.ps1 rollback   lists what would be put back.'
    }
    if ($unattribCount -gt 0) {
        Write-Info ''
        Write-Info "Errors that name no mod ($unattribCount), first few:"
        foreach ($u in $unattributed) { Write-Info "  $u" }
    }
}

if (-not $sawModLines) {
    Write-Info ''
    Write-Warn $loaderHint
}

# ---- -OutFile ----------------------------------------------------------------------

if ($OutFile) {
    if ($ext -eq '.json') {
        $doc = [ordered]@{
            generatedAt        = (Get-Date).ToString('s')
            logDir             = $LogDir
            files              = @($filesRead | ForEach-Object {
                                    [ordered]@{ name = $_.Name; lastWriteTime = $_.LastWriteTime.ToString('s')
                                                linesRead = $_.LinesRead; tail = $_.Tail } })
            errors             = $blockCount
            attributed         = $attributed
            unattributed       = $unattribCount
            modLinesSeen       = $sawModLines
            note               = $caveat
            offenders          = @($rows | ForEach-Object {
                                    [ordered]@{ rank = $_.Rank; folder = $_.Folder; name = $_.Name
                                                known = $_.Known; errors = $_.Errors; alsoInStack = $_.AlsoInStack
                                                firstError = $_.FirstError; firstFile = $_.FirstFile
                                                version = $_.Version; url = $_.Url } })
            unattributedSample = @($unattributed)
        }
        if (-not $sawModLines) { $doc['hint'] = $loaderHint }
        $text = $doc | ConvertTo-Json -Depth 6
    } else {
        $md = [System.Collections.Generic.List[string]]::new()
        $md.Add('# Darktide errors')
        $md.Add('')
        $md.Add("Log folder: ``$LogDir``")
        $md.Add('')
        foreach ($fr in $filesRead) { $md.Add("- $($fr.Name) ($($fr.LastWriteTime.ToString('yyyy-MM-dd HH:mm')), $($fr.LinesRead) lines read)") }
        $md.Add('')
        if ($blockCount -eq 0) {
            $md.Add('No errors found in the log.')
        } else {
            $md.Add("$blockCount error(s) ($attributed naming a mod, $unattribCount naming none).")
            $md.Add('')
            if ($rows.Count -gt 0) {
                $md.Add('| # | Mod | Errors | Also in stack | Version | First error | Page |')
                $md.Add('|---|---|---|---|---|---|---|')
                foreach ($r in $rows) {
                    $first = ($r.FirstError -replace '\|', '\|') -replace '`', "'"
                    $page  = if ($r.Url) { "[Nexus]($($r.Url))" } else { '-' }
                    $ver   = if ($r.Version) { $r.Version } else { '-' }
                    $md.Add("| $($r.Rank) | $($r.Folder) | $($r.Errors) | $($r.AlsoInStack) | $ver | ``$first`` | $page |")
                }
                $md.Add('')
                $md.Add($caveat)
            }
            if ($unattributed.Count -gt 0) {
                $md.Add('')
                $md.Add('Errors that name no mod:')
                $md.Add('')
                foreach ($u in $unattributed) {
                    $plain = $u -replace '`', "'"
                    $md.Add("- ``$plain``")
                }
            }
        }
        if (-not $sawModLines) { $md.Add(''); $md.Add($loaderHint) }
        $text = $md -join [Environment]::NewLine
    }

    Set-Content -LiteralPath $target -Value (Protect-Text $text) -Encoding UTF8
    Write-Info ''
    Write-Info "Wrote $target"
}
