<#
.SYNOPSIS
    Builds one redacted zip to attach to a bug report.

.DESCRIPTION
    Collects what someone helping you needs to see - versions, which mods are
    staged and deployed, the load order, the loader state, the tail of the last
    update log and of the game's console log - into a single zip of plain-text
    files. Every file is named explicitly; nothing is gathered by recursing the
    game folder.

    Everything that goes in is redacted first:

      - your profile path (C:\Users\<name>) becomes %USERPROFILE%
      - your user name, and any name passed with -RedactName, becomes <user>.
        A name is only replaced as a whole word, with '_' counted as part of
        the word, so a user 'alpha' does not turn a mod folder 'alpha_mod'
        into '<user>_mod'
      - 17-digit Steam ids (7656119...) become <steamid>
      - email addresses become <email>
      - any config key whose name contains key, token, secret or password is
        dropped from the config copy entirely, and its value is scrubbed from
        every other file as well
      - the values of NEXUS_API_KEY and GITHUB_TOKEN are never written; the
        bundle says only whether NEXUS_API_KEY is set

    What never goes in: mod files (.mod, .lua, archives), the game's bundle data,
    any environment variable's value, your API key.

    Redaction runs on the whole text before anything is cut down to size, so a
    long line or a log tail never ends half-way through a name the redactor
    would otherwise have recognised.

    It is a dry run by default: it prints the entries it would write and their
    sizes. -Apply writes darktide-support-<stamp>.zip.

.PARAMETER ConfigPath
    config.json to read. Optional: without it the bundle still carries the
    environment, the lockfile and the update log, with a note saying the config
    was missing.

.PARAMETER OutFile
    Where to write the zip. An existing folder means "write the default name in
    here". Defaults to a 'support' folder beside the staging folder (the parent
    of ModsRoot), or beside these scripts when there is no config. Refused if it
    lands inside the game folder or the staging folder.

.PARAMETER LogDir
    The Darktide console log folder. Defaults to
    %APPDATA%\Fatshark\Darktide\console_logs. That location is a best guess this
    repository cannot verify; when it does not exist the console log is skipped
    with a note.

.PARAMETER UpdateLogDir
    Where the updater writes update-*.log. Defaults to logs\ beside these scripts.

.PARAMETER RedactName
    More words to replace with <user>: a different account name, your Steam
    display name, a character name.

.PARAMETER TailLines
    How many lines to keep from the end of each log. Default 300.

.PARAMETER Apply
    Write the zip. Without it, print what would go in and stop.

.PARAMETER Force
    Overwrite an existing zip of the same name.

.EXAMPLE
    .\New-SupportBundle.ps1
    Lists every entry the bundle would hold and its size. Writes nothing.

.EXAMPLE
    .\New-SupportBundle.ps1 -Apply
    Writes darktide-support-<stamp>.zip into a 'support' folder beside staging.

.EXAMPLE
    .\New-SupportBundle.ps1 -Apply -OutFile "$HOME\Desktop\darktide-support.zip" -RedactName 'MyPlayerName'

.NOTES
    Read the zip before you post it. Redaction is pattern-based: it catches the
    profile path, the names it is told about and Steam ids, not every possible
    personal detail a mod might print to the console.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]   $ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string]   $OutFile,
    [string]   $LogDir,
    [string]   $UpdateLogDir = (Join-Path $PSScriptRoot 'logs'),
    [string[]] $RedactName,
    [ValidateRange(1, 5000)] [int] $TailLines = 300,
    [switch]   $Apply,
    [switch]   $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue

function Write-Step { param([string]$m) Write-Host $m -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host $m -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host $m -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host $m -ForegroundColor Red }

# The most of any one log that is read. A console log can run to hundreds of MB;
# only its end is wanted, and the window starts on a line boundary so no name is
# cut in half before the redactor sees it.
$script:MaxReadBytes  = 16MB
# Lines longer than this are cut, after redaction.
$script:MaxLineChars  = 2000
# Account folder names under C:\Users that are not a person.
$script:GenericProfiles = @('public', 'default', 'default user', 'all users', 'defaultapppool')

$script:Notes   = New-Object System.Collections.Generic.List[string]
$script:Entries = New-Object System.Collections.Generic.List[object]

# ---- Helpers -----------------------------------------------------------------------

function Test-SecretName {
    <# A config key that must not appear in the bundle at all. #>
    param([string] $Name)
    return ($Name -match '(?i)key|token|secret|password')
}

function Read-SharedText {
    <#
        Reads a text file without taking a lock the game would notice, and only its
        last MaxReadBytes. When the window starts mid-file the first, partial line
        is dropped.
    #>
    param([Parameter(Mandatory)][string] $Path)

    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    try {
        $skipped = $false
        if ($fs.Length -gt $script:MaxReadBytes) {
            [void]$fs.Seek(-$script:MaxReadBytes, [System.IO.SeekOrigin]::End)
            $skipped = $true
        }
        $sr = New-Object System.IO.StreamReader($fs, (New-Object System.Text.UTF8Encoding($false)), $true)
        try {
            $text = $sr.ReadToEnd()
        } finally { $sr.Dispose() }
    } finally { $fs.Dispose() }

    if ($skipped) {
        $nl = $text.IndexOf("`n")
        $text = if ($nl -ge 0) { $text.Substring($nl + 1) } else { '' }
    }
    return $text
}

function Add-NameCandidate {
    <# Adds a word to the redaction list, ignoring generic and very short ones. #>
    param([System.Collections.Generic.HashSet[string]] $Set, [string] $Name)

    if (-not $Name) { return }
    $n = $Name.Trim()
    # Two characters or fewer would replace ordinary words all over a log, and is
    # not much of an identifier in the first place.
    if ($n.Length -lt 3) { return }
    if ($script:GenericProfiles -contains $n.ToLowerInvariant()) { return }
    [void]$Set.Add($n)
}

# C:\Users\<name>, also with forward slashes and with JSON-escaped backslashes.
$script:ProfilePattern = '(?i)\b[A-Za-z]:(?:\\{1,2}|/)Users(?:\\{1,2}|/)([^\\/:*?"<>|\s,;]+)'

function Get-ProfileNames {
    <# Every account name that appears as C:\Users\<name> in the given texts. #>
    param([string[]] $Texts)

    $found = @()
    foreach ($t in $Texts) {
        if (-not $t) { continue }
        foreach ($m in [regex]::Matches($t, $script:ProfilePattern)) {
            $found += $m.Groups[1].Value
        }
    }
    return $found
}

function ConvertTo-RedactedText {
    <#
        The single redaction pass every entry goes through. Order matters:
        literal secrets first, then the profile path (which contains the user
        name), then the bare names, then the patterns.
    #>
    param([AllowEmptyString()][string] $Text)

    if (-not $Text) { return $Text }
    $t = $Text

    foreach ($s in $script:SecretValues) {
        $t = $t.Replace($s, '<redacted>')
    }

    if ($script:ProfileLiteral) {
        foreach ($form in @($script:ProfileLiteral, ($script:ProfileLiteral -replace '\\', '\\'))) {
            $t = [regex]::Replace($t, [regex]::Escape($form), '%USERPROFILE%',
                                  [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        }
    }

    $t = [regex]::Replace($t, $script:ProfilePattern, '%USERPROFILE%')

    # Whole words only, with '_' and digits counted as part of the word: a user
    # 'alpha' must not turn the mod folder 'alpha_mod' into '<user>_mod'. Explicit
    # look-arounds rather than \b, which flips meaning when a name itself starts or
    # ends with a non-word character such as '.' or '-'.
    # Each hit becomes a private-use placeholder first and '<user>' only at the
    # end, so a later, shorter name (an account called 'user', say) cannot match
    # inside a replacement an earlier one already made.
    $mark = [string][char]0xE000
    foreach ($n in $script:RedactWords) {
        $t = [regex]::Replace($t, '(?<![A-Za-z0-9_])' + [regex]::Escape($n) + '(?![A-Za-z0-9_])', $mark,
                              [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    $t = $t.Replace($mark, '<user>')

    $t = [regex]::Replace($t, '(?<!\d)7656119\d{10}(?!\d)', '<steamid>')
    $t = [regex]::Replace($t, '(?i)\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b', '<email>')
    return $t
}

function Get-TailText {
    <#
        The last $Count lines of already-redacted text, with over-long lines cut.
        Cutting happens here, after redaction, never before it.
    #>
    param([AllowEmptyString()][string] $Text, [int] $Count, [string] $Label)

    $lines = @($Text -split '\r?\n')
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
        $lines = @($lines | Select-Object -First ($lines.Count - 1))
    }
    $total = $lines.Count
    if ($total -gt $Count) { $lines = @($lines | Select-Object -Last $Count) }

    $out = New-Object System.Collections.Generic.List[string]
    $out.Add("# $Label - last $($lines.Count) of $total line(s), redacted")
    foreach ($l in $lines) {
        if ($l.Length -gt $script:MaxLineChars) { $l = $l.Substring(0, $script:MaxLineChars) + ' [...cut]' }
        $out.Add($l)
    }
    return ($out -join "`r`n") + "`r`n"
}

function Get-ModVersion {
    <# 'version (source)' for one mod folder, from .nexus-mod.json then info.json. #>
    param([Parameter(Mandatory)][string] $Dir)

    $bad = $null
    foreach ($f in @('.nexus-mod.json', 'info.json')) {
        $p = Join-Path $Dir $f
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        try {
            $j = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j -and $j.PSObject.Properties.Name -contains 'version' -and "$($j.version)".Trim()) {
                $v = "$($j.version)".Trim()
                if ($f -eq '.nexus-mod.json' -and $j.PSObject.Properties.Name -contains 'modId' -and $j.modId) {
                    return "$v ($f, Nexus id $($j.modId))"
                }
                return "$v ($f)"
            }
        } catch {
            $bad = "unreadable $f"
        }
    }
    if ($bad) { return $bad }
    return 'no version recorded'
}

function Get-ModListing {
    <# Top-level folder names and versions. Names only below that - no file content. #>
    param([Parameter(Mandatory)][string] $Root, [Parameter(Mandatory)][string] $Label)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("$Label : $Root")
    $dirs = @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
    $mods  = @($dirs | Where-Object { -not $_.Name.StartsWith('.') })
    $dots  = @($dirs | Where-Object { $_.Name.StartsWith('.') })
    $files = @(Get-ChildItem -LiteralPath $Root -File -ErrorAction SilentlyContinue | Sort-Object Name)

    $lines.Add("Mod folders : $($mods.Count)")
    $width = 10
    foreach ($d in $mods) { if ($d.Name.Length -gt $width) { $width = $d.Name.Length } }
    foreach ($d in $mods) {
        $lines.Add(('  {0}  {1}' -f $d.Name.PadRight($width), (Get-ModVersion -Dir $d.FullName)))
    }
    if ($dots) {
        $lines.Add('')
        $lines.Add("Folders starting with '.' (leftover install or staging folders, not loaded):")
        foreach ($d in $dots) { $lines.Add("  $($d.Name)") }
    }
    $lines.Add('')
    $lines.Add("Top-level files : $(if ($files) { ($files | ForEach-Object { $_.Name }) -join ', ' } else { 'none' })")
    return $lines
}

function Add-Entry {
    param([Parameter(Mandatory)][string] $Name, [AllowEmptyString()][string] $Text, [string] $From)
    $script:Entries.Add([pscustomobject]@{ Name = $Name; Text = $Text; From = $From })
}

function Get-SafeEntryName {
    <# A file name usable as a zip entry, never ending in a mod-like extension. #>
    param([Parameter(Mandatory)][string] $Name)
    $n = $Name -replace '[^A-Za-z0-9._-]', '_'
    if ($n -notmatch '\.(log|txt)$') { $n += '.txt' }
    return $n
}

function Resolve-FullPath {
    <#
        An absolute path resolved against the PowerShell location, not the process
        directory: under Windows PowerShell the two differ, and .\bundle.zip would
        otherwise land in System32 or the profile folder.
    #>
    param([Parameter(Mandatory)][string] $Path)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Test-PathInside {
    <# True when $Child is $Parent or sits anywhere below it. #>
    param([string] $Child, [string] $Parent)
    if (-not $Child -or -not $Parent) { return $false }
    $c = (Resolve-FullPath $Child).TrimEnd('\', '/')
    $p = (Resolve-FullPath $Parent).TrimEnd('\', '/')
    if ($c.Equals($p, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return ($c.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase) -or
            $c.StartsWith($p + '/', [StringComparison]::OrdinalIgnoreCase))
}

function Get-ToolCommit {
    <# HEAD of the tooling checkout, read-only. $null when there is no git or no checkout. #>
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $null }
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot '.git'))) { return $null }
    # Windows PowerShell 5.1 turns native stderr into a terminating error under
    # 'Stop'; drop to 'Continue' and decide on the exit code alone.
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $sha = & git -C $PSScriptRoot rev-parse HEAD 2>$null
        $code = if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { 1 }
        if ($code -ne 0 -or -not $sha) { return $null }
        return "$sha".Trim()
    } finally { $ErrorActionPreference = $eap }
}

# ---- Config (optional) -------------------------------------------------------------

$cfg        = $null
$cfgState   = 'not found'
$modsRoot   = ''
$gamePath   = ''
$cfgSecrets = @()

if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    try {
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
        if ($raw) {
            # Read secret-looking values off the raw text as well as the parsed
            # object, so a config too broken to parse still has its key scrubbed
            # from every log it might have reached.
            foreach ($m in [regex]::Matches($raw, '(?i)"[^"]*(key|token|secret|password)[^"]*"\s*:\s*"([^"]{4,})"')) {
                $cfgSecrets += $m.Groups[2].Value
            }
        }
        if ($raw -and $raw.Trim()) {
            $cfg = $raw | ConvertFrom-Json
            $cfgState = 'found'
        } else {
            $cfgState = 'empty'
        }
    } catch {
        # Never fall back to copying the raw text: it may hold a key.
        $cfgState = 'unreadable (not valid JSON)'
        $cfg = $null
    }
}
if (-not $cfg) {
    $script:Notes.Add("config.json $cfgState - staging and game listings are skipped. Run .\darktide.ps1 init to create one.")
}

function Copy-WithoutSecret {
    <#
        The config with every secret-named key removed at any depth. Values are
        left as they are; the text redaction pass runs over the JSON afterwards.
    #>
    param($Value)

    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $copy = [ordered]@{}
        foreach ($p in $Value.PSObject.Properties) {
            if (Test-SecretName $p.Name) { continue }
            $copy[$p.Name] = Copy-WithoutSecret -Value $p.Value
        }
        return $copy
    }
    if ($Value -is [System.Array]) {
        return , @(foreach ($v in $Value) { Copy-WithoutSecret -Value $v })
    }
    return $Value
}

function Get-SecretValue {
    <# Every string stored under a secret-named key, at any depth, to scrub elsewhere. #>
    param($Value)

    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $Value.PSObject.Properties) {
            if ((Test-SecretName $p.Name) -and $p.Value -is [string]) {
                if ($p.Value.Length -ge 4) { $p.Value }
            } else {
                Get-SecretValue -Value $p.Value
            }
        }
    } elseif ($Value -is [System.Array]) {
        foreach ($v in $Value) { Get-SecretValue -Value $v }
    }
}

function Get-CfgString {
    param([string] $Key)
    if ($cfg -and $cfg.PSObject.Properties.Name -contains $Key -and "$($cfg.$Key)".Trim()) { return "$($cfg.$Key)" }
    return ''
}

if ($cfg) {
    $modsRoot = Get-CfgString 'ModsRoot'
    $gamePath = Get-CfgString 'GamePath'
    $cfgSecrets += @(Get-SecretValue -Value $cfg)
}

# ---- Redaction context -------------------------------------------------------------

$script:SecretValues = @()
foreach ($v in @($cfgSecrets + @($env:NEXUS_API_KEY, $env:GITHUB_TOKEN))) {
    if ($v -and $v.Length -ge 4) { $script:SecretValues += $v }
}
# Longest first, so a secret that contains another is scrubbed whole.
$script:SecretValues = @($script:SecretValues | Select-Object -Unique | Sort-Object -Property Length -Descending)

$script:ProfileLiteral = ''
if ($env:USERPROFILE) { $script:ProfileLiteral = $env:USERPROFILE.TrimEnd('\', '/') }

# ---- Collect raw text --------------------------------------------------------------

$rawConfigText = ''
if ($cfg) {
    $rawConfigText = ConvertTo-Json -InputObject (Copy-WithoutSecret -Value $cfg) -Depth 8
}

$stagingListing = $null
$stagingOrder   = $null
if ($modsRoot) {
    if (Test-Path -LiteralPath $modsRoot -PathType Container) {
        $stagingListing = (Get-ModListing -Root $modsRoot -Label 'Staging (ModsRoot)') -join "`r`n"
        $lo = Join-Path $modsRoot 'mod_load_order.txt'
        if (Test-Path -LiteralPath $lo -PathType Leaf) { $stagingOrder = Read-SharedText -Path $lo }
        else { $script:Notes.Add('No mod_load_order.txt in staging.') }
    } else {
        $script:Notes.Add('ModsRoot from config.json does not exist.')
    }
} elseif ($cfg) {
    $script:Notes.Add('ModsRoot is not set in config.json.')
}

$gameListing = $null
$gameOrder   = $null
$loaderState = $null
if ($gamePath) {
    if (Test-Path -LiteralPath $gamePath -PathType Container) {
        $gl = New-Object System.Collections.Generic.List[string]
        $gl.Add("Game folder : $gamePath")
        foreach ($marker in @('binaries\Darktide.exe', 'bundle\bundle_database.data', 'toggle_darktide_mods.bat')) {
            $gl.Add(('  {0,-30} {1}' -f $marker, $(if (Test-Path -LiteralPath (Join-Path $gamePath $marker)) { 'present' } else { 'missing' })))
        }
        $patches = @(Get-ChildItem -LiteralPath (Join-Path $gamePath 'bundle') -Filter '*.patch_*' -File -ErrorAction SilentlyContinue |
                     ForEach-Object { $_.Name })
        $gl.Add(('  {0,-30} {1}' -f 'bundle\*.patch_*', $(if ($patches) { $patches -join ', ' } else { 'none (mods will not load)' })))
        $gl.Add('')
        $gameMods = Join-Path $gamePath 'mods'
        if (Test-Path -LiteralPath $gameMods -PathType Container) {
            foreach ($l in (Get-ModListing -Root $gameMods -Label 'Game mods folder')) { $gl.Add($l) }
            $lo = Join-Path $gameMods 'mod_load_order.txt'
            if (Test-Path -LiteralPath $lo -PathType Leaf) { $gameOrder = Read-SharedText -Path $lo }
            else { $script:Notes.Add('No mod_load_order.txt in the game mods folder.') }
        } else {
            $gl.Add('Game mods folder : missing - never deployed')
        }
        $gameListing = $gl -join "`r`n"

        $ls = Join-Path $gamePath '.darktide-loader.json'
        if (Test-Path -LiteralPath $ls -PathType Leaf) { $loaderState = Read-SharedText -Path $ls }
        else { $script:Notes.Add('No .darktide-loader.json - the loader is not installed, or was installed by hand.') }
    } else {
        $script:Notes.Add('GamePath from config.json does not exist.')
    }
} elseif ($cfg) {
    $script:Notes.Add('GamePath is not set in config.json.')
}

$lockText = $null
$lockPath = Join-Path $PSScriptRoot 'darktide-modpack.lock.json'
if (Test-Path -LiteralPath $lockPath -PathType Leaf) { $lockText = Read-SharedText -Path $lockPath }
else { $script:Notes.Add('No darktide-modpack.lock.json beside the scripts.') }

$updateLog = $null
$updateLogFile = $null
if ($UpdateLogDir -and (Test-Path -LiteralPath $UpdateLogDir -PathType Container)) {
    $updateLogFile = @(Get-ChildItem -LiteralPath $UpdateLogDir -Filter 'update-*.log' -File -ErrorAction SilentlyContinue |
                       Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
    if ($updateLogFile) {
        $updateLogFile = $updateLogFile[0]
        $updateLog = Read-SharedText -Path $updateLogFile.FullName
    }
}
if (-not $updateLogFile) { $script:Notes.Add('No update-*.log found - the updater has not run from this folder yet.') }

# The console log folder is a best guess this repository cannot check against a
# real install, so its absence is a note, never an error.
$consoleDir = $LogDir
if (-not $consoleDir -and $env:APPDATA) {
    $consoleDir = Join-Path (Join-Path (Join-Path $env:APPDATA 'Fatshark') 'Darktide') 'console_logs'
}
$consoleLog = $null
$consoleLogFile = $null
if ($consoleDir -and (Test-Path -LiteralPath $consoleDir -PathType Container)) {
    $consoleLogFile = @(Get-ChildItem -LiteralPath $consoleDir -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.Extension -in @('.log', '.txt') } |
                        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
    if ($consoleLogFile) {
        $consoleLogFile = $consoleLogFile[0]
        $consoleLog = Read-SharedText -Path $consoleLogFile.FullName
    } else {
        $script:Notes.Add('The console log folder exists but holds no .log or .txt file.')
    }
} else {
    $script:Notes.Add("No Darktide console log folder found$(if ($consoleDir) { " at $consoleDir" }). Pass -LogDir if yours is elsewhere.")
}

# ---- Words to redact ---------------------------------------------------------------

$words = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
Add-NameCandidate -Set $words -Name $env:USERNAME
try { Add-NameCandidate -Set $words -Name ([Environment]::UserName) } catch { Write-Verbose 'no user name available' }
if ($script:ProfileLiteral) { Add-NameCandidate -Set $words -Name (Split-Path -Leaf $script:ProfileLiteral) }
foreach ($n in @($RedactName)) { Add-NameCandidate -Set $words -Name $n }
# A name seen in any C:\Users\<name> path is redacted everywhere it appears,
# not only inside that path.
$allRaw = @($rawConfigText, $stagingListing, $stagingOrder, $gameListing, $gameOrder,
            $loaderState, $lockText, $updateLog, $consoleLog, $ConfigPath, $LogDir, $UpdateLogDir, $consoleDir)
foreach ($n in (Get-ProfileNames -Texts $allRaw)) { Add-NameCandidate -Set $words -Name $n }
$script:RedactWords = @($words | Sort-Object -Property Length -Descending)

# ---- Build the entries -------------------------------------------------------------

$apiState = if ($env:NEXUS_API_KEY) { 'set' } else { 'not set' }
$cfgKeyState = 'absent'
if ($cfg) {
    foreach ($p in $cfg.PSObject.Properties) {
        if ((Test-SecretName $p.Name) -and "$($p.Value)".Trim()) { $cfgKeyState = 'present (value not included)' }
    }
}
$commit = Get-ToolCommit
$running = if (Get-Process -Name Darktide -ErrorAction SilentlyContinue) { 'yes' } else { 'no' }
$osText = [Environment]::OSVersion.VersionString
if ($PSVersionTable.ContainsKey('OS') -and $PSVersionTable['OS']) { $osText = "$($PSVersionTable['OS'])" }

$env1 = New-Object System.Collections.Generic.List[string]
$env1.Add('Darktide mods support bundle')
$env1.Add('')
$env1.Add("Created (UTC)        : $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))")
$env1.Add("Tool commit          : $(if ($commit) { $commit } else { 'unknown (not a git checkout, or git not installed)' })")
$env1.Add("PowerShell           : $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))")
$env1.Add("OS                   : $osText")
$env1.Add("64-bit process       : $([Environment]::Is64BitProcess)")
$env1.Add("Culture              : $((Get-Culture).Name)")
$env1.Add("NEXUS_API_KEY        : $apiState")
$env1.Add("API key in config    : $cfgKeyState")
$env1.Add("Config               : $cfgState ($ConfigPath)")
$env1.Add("ModsRoot             : $(if ($modsRoot) { $modsRoot } else { 'unknown' })")
$env1.Add("GamePath             : $(if ($gamePath) { $gamePath } else { 'unknown' })")
$env1.Add("Darktide running     : $running")
$env1.Add("Update log           : $(if ($updateLogFile) { $updateLogFile.Name } else { 'none' })")
$env1.Add("Console log          : $(if ($consoleLogFile) { $consoleLogFile.Name } else { 'none' })")
$env1.Add('')
$env1.Add('Notes:')
if ($script:Notes.Count -eq 0) { $env1.Add('  none') }
foreach ($n in $script:Notes) { $env1.Add("  - $n") }

Add-Entry -Name 'environment.txt' -Text (ConvertTo-RedactedText (($env1 -join "`r`n") + "`r`n")) -From 'this machine'

if ($cfg) {
    Add-Entry -Name 'config.redacted.json' -Text (ConvertTo-RedactedText $rawConfigText) -From 'config.json, secret keys dropped'
}
if ($stagingListing) {
    Add-Entry -Name 'staging-listing.txt' -Text (ConvertTo-RedactedText ($stagingListing + "`r`n")) -From 'ModsRoot, folder names only'
}
if ($stagingOrder) {
    Add-Entry -Name 'staging/mod_load_order.txt' -Text (ConvertTo-RedactedText $stagingOrder) -From 'ModsRoot'
}
if ($gameListing) {
    Add-Entry -Name 'game-listing.txt' -Text (ConvertTo-RedactedText ($gameListing + "`r`n")) -From 'GamePath, folder names only'
}
if ($gameOrder) {
    Add-Entry -Name 'game/mod_load_order.txt' -Text (ConvertTo-RedactedText $gameOrder) -From 'GamePath\mods'
}
if ($loaderState) {
    Add-Entry -Name 'loader-state.json' -Text (ConvertTo-RedactedText $loaderState) -From 'GamePath\.darktide-loader.json'
}
if ($lockText) {
    Add-Entry -Name 'darktide-modpack.lock.json' -Text (ConvertTo-RedactedText $lockText) -From 'beside the scripts'
}
if ($updateLogFile) {
    # Redact the whole log, then cut it down. Never the other way round.
    $red = ConvertTo-RedactedText $updateLog
    Add-Entry -Name ('logs/' + (Get-SafeEntryName $updateLogFile.Name)) `
              -Text (Get-TailText -Text $red -Count $TailLines -Label $updateLogFile.Name) -From 'update log, tail'
}
if ($consoleLogFile) {
    $red = ConvertTo-RedactedText $consoleLog
    Add-Entry -Name ('console/' + (Get-SafeEntryName $consoleLogFile.Name)) `
              -Text (Get-TailText -Text $red -Count $TailLines -Label (ConvertTo-RedactedText $consoleLogFile.Name)) -From 'game console log, tail'
}

$listed = @($script:Entries | ForEach-Object { $_.Name })
$readme = @(
    'Darktide mods support bundle',
    '============================',
    '',
    'Made by New-SupportBundle.ps1 (.\darktide.ps1 support -Apply) to attach to a bug report.',
    'Every file in here is plain text. Read them before you post this anywhere.',
    '',
    'What is in it:',
    '  environment.txt              tool commit, PowerShell and OS version, whether NEXUS_API_KEY is set',
    '  config.redacted.json         config.json with secret keys dropped and paths redacted',
    '  staging-listing.txt          staged mod folder names and versions',
    '  game-listing.txt             deployed mod folder names and versions, loader markers',
    '  staging/, game/              mod_load_order.txt from each side',
    '  loader-state.json            what the mod loader installer recorded',
    '  darktide-modpack.lock.json   the loadout manifest',
    "  logs/, console/              the last $TailLines lines of the newest update log and game console log",
    '',
    'Files actually present in this bundle:'
) + @($listed | ForEach-Object { "  $_" }) + @(
    '',
    'What is not in it, on purpose:',
    '  - any mod file (.mod, .lua), archive or game bundle data',
    '  - the API key, from config.json or NEXUS_API_KEY, and any other environment variable value',
    '  - config keys whose name contains key, token, secret or password',
    '',
    'Redacted before anything was cut to length:',
    '  - C:\Users\<name> paths       -> %USERPROFILE%',
    '  - your user name               -> <user>  (whole words only; alpha_mod stays alpha_mod)',
    '  - Steam ids (7656119...)       -> <steamid>',
    '  - email addresses              -> <email>',
    '',
    'Redaction is pattern-based. A mod can print anything to the console log, so look',
    'through console/ before sharing.'
)
Add-Entry -Name 'README.txt' -Text (($readme -join "`r`n") + "`r`n") -From 'generated'

# ---- Where it goes -----------------------------------------------------------------

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$defaultName = "darktide-support-$stamp.zip"
if ($OutFile) {
    if (Test-Path -LiteralPath $OutFile -PathType Container) {
        $target = Join-Path $OutFile $defaultName
    } else {
        if ($OutFile -notmatch '(?i)\.zip$') { throw "-OutFile must end in .zip (got '$OutFile')." }
        $target = $OutFile
    }
} else {
    $base = if ($modsRoot) { Split-Path -Parent (Resolve-FullPath $modsRoot) } else { $PSScriptRoot }
    if (-not $base) { $base = $PSScriptRoot }
    $target = Join-Path (Join-Path $base 'support') $defaultName
    # Staging kept as the game's own mods folder puts its parent inside the game
    # folder. The default should still just work, so fall back to the scripts' folder.
    if ((Test-PathInside -Child $target -Parent $gamePath) -or (Test-PathInside -Child $target -Parent $modsRoot)) {
        $target = Join-Path (Join-Path $PSScriptRoot 'support') $defaultName
    }
}
$target = Resolve-FullPath $target

# The game folder is a mirror that deploys and Steam rewrite, and anything in
# staging is read as a mod. A bundle belongs in neither.
if ($gamePath -and (Test-PathInside -Child $target -Parent $gamePath)) {
    throw "Refusing to write the support bundle inside the game folder ('$gamePath'). Pass -OutFile somewhere else."
}
if ($modsRoot -and (Test-PathInside -Child $target -Parent $modsRoot)) {
    throw "Refusing to write the support bundle inside the staging folder ('$modsRoot'). Pass -OutFile somewhere else."
}

$exists = Test-Path -LiteralPath $target

# ---- Plan --------------------------------------------------------------------------

$utf8 = New-Object System.Text.UTF8Encoding($false)
Write-Step '=== Darktide support bundle ==='
Write-Host  "Mode    : $(if ($Apply) { 'APPLY' } else { 'DRY RUN (pass -Apply to write)' })"
Write-Host  "Archive : $target"
Write-Host  ''
$nameWidth = 12
foreach ($e in $script:Entries) { if ($e.Name.Length -gt $nameWidth) { $nameWidth = $e.Name.Length } }
$total = 0
foreach ($e in $script:Entries) {
    $bytes = $utf8.GetByteCount([string]$e.Text)
    $total += $bytes
    Write-Host ('  {0}  {1,9}  {2}' -f $e.Name.PadRight($nameWidth), ('{0:N1} KB' -f ($bytes / 1KB)), $e.From)
}
Write-Host  ''
Write-Host  "$($script:Entries.Count) entries, $('{0:N1}' -f ($total / 1KB)) KB before compression"
foreach ($n in $script:Notes) { Write-Warn "  note: $n" }
Write-Host  ''

if ($exists -and -not $Force) {
    if (-not $Apply) {
        Write-Warn "'$target' already exists; -Apply will refuse without -Force."
    } else {
        throw "'$target' already exists. Pass -Force to overwrite."
    }
}

if (-not $Apply) {
    Write-Host 'Dry run complete. Nothing was written. Re-run with -Apply.'
    return
}

if (-not $PSCmdlet.ShouldProcess($target, "Write support bundle ($($script:Entries.Count) entries)")) { return }

# ---- Write -------------------------------------------------------------------------

$parent = Split-Path -Parent $target
if ($parent) { [void][System.IO.Directory]::CreateDirectory($parent) }

# Build beside the target and move it into place, so a failure half-way leaves no
# truncated zip under the final name and -Force never destroys the old one early.
$partial = "$target.partial"
if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
$now = [DateTimeOffset]::Now
try {
    $fs = [System.IO.File]::Open($partial, [System.IO.FileMode]::CreateNew)
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($e in $script:Entries) {
                # Forward slashes, always: the ZIP format requires them, and
                # .NET Framework would otherwise be free to write '\'.
                $entryName = $e.Name -replace '\\', '/'
                $entry = $zip.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = $now
                $w = New-Object System.IO.StreamWriter($entry.Open(), $utf8)
                try { $w.Write([string]$e.Text) } finally { $w.Dispose() }
            }
        } finally { $zip.Dispose() }
    } finally { $fs.Dispose() }

    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
    [System.IO.File]::Move($partial, $target)
} catch {
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    throw
}

$size = (Get-Item -LiteralPath $target).Length
Write-Ok "Wrote $target ($('{0:N1}' -f ($size / 1KB)) KB)"
Write-Host ''
Write-Host 'Open it and read it before you attach it anywhere - every file inside is plain text.'
Write-Host 'Redaction is pattern-based; the console log in particular can hold whatever a mod printed.'
