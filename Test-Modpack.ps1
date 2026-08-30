<#
.SYNOPSIS
    Repository validator. Run locally before committing, and by CI on every dispatch.

.DESCRIPTION
    Checks that are cheap and catch the things that actually break:
      - every .ps1 parses (AST parse, no execution)
      - every .json is valid JSON
      - the lockfile matches its schema expectations and is internally consistent
      - no mod content, secrets, or personal paths have leaked into tracked files
      - config.json is not tracked by git

    Exits non-zero on any failure so CI fails loudly.

.PARAMETER Strict
    Also fail on warnings.

.EXAMPLE
    .\Test-Modpack.ps1
#>

[CmdletBinding()]
param([switch] $Strict)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Warnings = New-Object System.Collections.Generic.List[string]

function Test-Case {
    param([string] $Name, [scriptblock] $Body)
    try {
        & $Body
        Write-Host "  PASS  $Name" -ForegroundColor Green
    } catch {
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)" -ForegroundColor Red
        $script:Failures.Add("$Name`: $($_.Exception.Message)")
    }
}

function Add-Warning {
    param([string] $Message)
    Write-Host "  WARN  $Message" -ForegroundColor Yellow
    $script:Warnings.Add($Message)
}

$root = $PSScriptRoot
Write-Host "Validating $root" -ForegroundColor Cyan
Write-Host ''

# ---------------------------------------------------------------------------
Write-Host 'PowerShell syntax' -ForegroundColor Cyan
# ---------------------------------------------------------------------------

$scripts = @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File -Recurse |
             Where-Object { $_.FullName -notmatch '[\\/](dist|out)[\\/]' })

if (-not $scripts) { $script:Failures.Add('No .ps1 files found - wrong directory?') }

foreach ($s in $scripts) {
    Test-Case "parses: $($s.Name)" {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            $s.FullName, [ref]$null, [ref]$errors)
        if ($errors -and $errors.Count -gt 0) {
            $first = $errors[0]
            throw "line $($first.Extent.StartLineNumber): $($first.Message)"
        }
    }.GetNewClosure()
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'JSON validity' -ForegroundColor Cyan
# ---------------------------------------------------------------------------

$jsons = @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File -Recurse |
           Where-Object { $_.FullName -notmatch '[\\/](dist|out|node_modules)[\\/]' })

foreach ($j in $jsons) {
    Test-Case "valid JSON: $($j.Name)" {
        $null = Get-Content -LiteralPath $j.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    }.GetNewClosure()
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Lockfile' -ForegroundColor Cyan
# ---------------------------------------------------------------------------

$lockPath = Join-Path $root 'darktide-modpack.lock.json'

Test-Case 'lockfile exists' {
    if (-not (Test-Path -LiteralPath $lockPath)) { throw 'darktide-modpack.lock.json is missing' }
}

if (Test-Path -LiteralPath $lockPath) {
    $lock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json

    Test-Case 'lockfile has required top-level fields' {
        foreach ($f in @('schemaVersion', 'game', 'generatedAt', 'modCount', 'loadOrder', 'mods')) {
            if ($lock.PSObject.Properties.Name -notcontains $f) { throw "missing field '$f'" }
        }
    }

    Test-Case 'schemaVersion is supported' {
        if ([int]$lock.schemaVersion -ne 1) { throw "unsupported schemaVersion $($lock.schemaVersion)" }
    }

    Test-Case 'modCount matches the mods array' {
        $actual = @($lock.mods).Count
        if ([int]$lock.modCount -ne $actual) { throw "modCount is $($lock.modCount) but mods has $actual entries" }
    }

    Test-Case 'mod entries are well formed' {
        foreach ($m in @($lock.mods)) {
            foreach ($f in @('folder', 'name', 'modId', 'version', 'url')) {
                if ($m.PSObject.Properties.Name -notcontains $f) { throw "mod '$($m.folder)' is missing field '$f'" }
            }
            if (-not $m.folder) { throw 'a mod entry has an empty folder name' }
            if ($m.folder -match '[\\/:*?"<>|]') { throw "mod folder '$($m.folder)' contains an illegal character" }
            if ($m.modId -and -not $m.url) { throw "mod '$($m.folder)' has an id but no url" }
            if ($m.url -and "$($m.url)" -notmatch '^https://www\.nexusmods\.com/') {
                throw "mod '$($m.folder)' has a non-Nexus url: $($m.url)"
            }
        }
    }

    Test-Case 'no duplicate folders' {
        $dupes = @($lock.mods | Group-Object folder | Where-Object { $_.Count -gt 1 })
        if ($dupes) { throw "duplicate folder(s): $(($dupes | ForEach-Object { $_.Name }) -join ', ')" }
    }

    Test-Case 'load order entries all exist in mods' {
        $folders = @($lock.mods | ForEach-Object { $_.folder })
        $missing = @($lock.loadOrder | Where-Object { $folders -notcontains $_ })
        if ($missing) { throw "load order references unknown mods: $($missing -join ', ')" }
    }

    Test-Case 'lockfile contains no mod file content' {
        # A manifest should be small. If it has ballooned, someone has embedded files.
        $sizeKb = [math]::Round((Get-Item -LiteralPath $lockPath).Length / 1KB, 1)
        if ($sizeKb -gt 512) { throw "lockfile is ${sizeKb}KB - a manifest should never be this large" }
    }

    $unmapped = @($lock.mods | Where-Object { -not $_.modId })
    if ($unmapped.Count -gt 0) {
        Add-Warning "$($unmapped.Count) mod(s) have no Nexus id, so they cannot be version-checked or reproduced: $(($unmapped | ForEach-Object { $_.folder }) -join ', ')"
    }
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Hygiene' -ForegroundColor Cyan
# ---------------------------------------------------------------------------

Test-Case 'config.example.json exists' {
    if (-not (Test-Path -LiteralPath (Join-Path $root 'config.example.json'))) {
        throw 'config.example.json is missing - users have nothing to copy'
    }
}

Test-Case 'no mod folders committed' {
    # A tracked *.mod file means third-party mod content has leaked into the repo.
    $leaked = @(Get-ChildItem -LiteralPath $root -Filter '*.mod' -File -Recurse -ErrorAction SilentlyContinue)
    if ($leaked) {
        throw "third-party mod files found in the repo: $(($leaked | ForEach-Object { $_.Name }) -join ', ')"
    }
    if (Test-Path -LiteralPath (Join-Path $root 'mods')) {
        throw "a 'mods' directory exists in the repo - mod content must not be committed"
    }
}

Test-Case 'no API key committed' {
    $suspect = @(Get-ChildItem -LiteralPath $root -File -Recurse -Include '*.json', '*.ps1', '*.md', '*.yml' -ErrorAction SilentlyContinue |
                 Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' })
    foreach ($f in $suspect) {
        $text = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
        # Nexus personal API keys are long base64-ish strings. Flag any long opaque
        # token assigned to something that looks like a key field.
        if ($text -match '(?i)"?(apikey|api_key|nexus_api_key)"?\s*[:=]\s*["'']([A-Za-z0-9+/_\-]{30,})["'']') {
            throw "possible API key in $($f.Name)"
        }
    }
}

Test-Case 'config.json is not tracked by git' {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    Push-Location $root
    try {
        # Windows PowerShell 5.1 turns each stderr line from a native command into a
        # NativeCommandError, which is terminating while $ErrorActionPreference is
        # 'Stop'. Drop to 'Continue' so git's own output cannot fail the check, and
        # decide purely on the exit code.
        $eap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $null = & git rev-parse --git-dir 2>&1
            # Not a git repo (yet). Nothing can be tracked, so nothing to report.
            if ($LASTEXITCODE -ne 0) { return }

            $tracked = & git ls-files --error-unmatch config.json 2>&1
            if ($LASTEXITCODE -eq 0 -and $tracked) {
                throw 'config.json is tracked by git - it holds local paths and possibly a key. Run: git rm --cached config.json'
            }
        } finally { $ErrorActionPreference = $eap }
    } finally { Pop-Location }
}

Test-Case 'no agent attribution committed' {
    # Commits, PR bodies and file content in this repo carry no AI-assistant
    # attribution. Tooling appends footers like this by default, so check rather
    # than trust. Names a model in prose are fine; these are the credit markers.
    # Assembled from fragments on purpose: spelled out in full, this file would
    # match its own check and fail every run.
    $n = [char]0x43 + 'laude'
    $markers = @(
        "Co-Authored-By: $n",
        "Generated with [$n Code]",
        "Generated by [$n Code]",
        "$n Code](https://$n.ai/code"
    )
    $files = @(Get-ChildItem -LiteralPath $root -File -Recurse -Include '*.md', '*.ps1', '*.json', '*.yml', '*.sh' -ErrorAction SilentlyContinue |
               Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' })
    $hits = @()
    foreach ($f in $files) {
        $text = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if (-not $text) { continue }
        foreach ($m in $markers) {
            if ($text -match [regex]::Escape($m)) {
                $hits += "$($f.Name): $m"
            }
        }
    }
    if ($hits) { throw "Agent attribution found in $($hits -join '; ')" }
}

Test-Case 'no agent attribution in commit messages' {
    # The file check above cannot see commit messages, which is how an agent tool's
    # Co-Authored-By trailer once reached this repository and put a bot in the GitHub
    # contributors list. Any agent, not one vendor.
    #
    # The names are assembled from fragments for the same reason the marker list above
    # is: spelled out, this file would be the thing its own check reports. Add to the
    # list when a new tool appears - that is cheaper than another history rewrite.
    Push-Location $root
    try {
        $eap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            # %B (raw body) keeps the original line breaks. A format that packs fields
            # onto one line glues the trailer to the subject, and then the '^' anchor
            # below never matches - which is exactly how an earlier draft passed on a
            # commit it should have caught.
            $log = @(& git log --format='%B%x1e' 2>$null)
            if ($LASTEXITCODE -ne 0 -or -not $log) {
                Add-Warning 'not a git checkout, or no history available - commit messages not scanned'
                return
            }
        } finally { $ErrorActionPreference = $eap }

        $agents = @(
            [char]0x57 + 'arp',
            [char]0x43 + 'laude',
            [char]0x43 + 'opilot',
            [char]0x43 + 'ursor',
            [char]0x44 + 'evin',
            [char]0x43 + 'odex',
            [char]0x41 + 'ider'
        )
        $text   = $log -join "`n"
        $count  = @($text -split "`u{001e}" | Where-Object { $_.Trim() }).Count

        $hits = @()
        foreach ($line in ($text -split "`n")) {
            $l = $line.Trim()
            if ($l -match '^(?i)co-authored-by:\s*(.+)$') {
                $who = $matches[1]
                foreach ($a in $agents) {
                    if ($who -match "(?i)$([regex]::Escape($a))") { $hits += "trailer credits '$who'" }
                }
                if ($who -match '(?i)(agent|bot)@') { $hits += "trailer credits '$who'" }
            }
            if ($l -match '(?i)^generated (by|with) ') { $hits += "message contains '$l'" }
        }

        # A shallow clone sees only what was fetched, so say how much was actually read.
        if ($count -lt 5) {
            Add-Warning "only $count commit(s) reachable - a shallow clone hides the rest of the history"
        }
        if ($hits) {
            throw "Agent attribution in commit messages: $(($hits | Select-Object -Unique) -join '; '). Rewriting published history is the only fix, so keep it out in the first place."
        }
    } finally { Pop-Location }
}

Test-Case '.gitignore covers the important things' {
    $gi = Join-Path $root '.gitignore'
    if (-not (Test-Path -LiteralPath $gi)) { throw '.gitignore is missing' }
    $text = Get-Content -LiteralPath $gi -Raw -Encoding UTF8
    foreach ($needed in @('config.json', 'mods/', 'logs/', 'nexus-catalog.json')) {
        if ($text -notmatch [regex]::Escape($needed)) { throw ".gitignore does not cover '$needed'" }
    }
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'PSScriptAnalyzer' -ForegroundColor Cyan
# ---------------------------------------------------------------------------

if (Get-Module -ListAvailable -Name PSScriptAnalyzer) {
    Import-Module PSScriptAnalyzer -ErrorAction Stop
    $results = @()
    foreach ($s in $scripts) {
        $results += Invoke-ScriptAnalyzer -Path $s.FullName -Severity Error, Warning `
                        -ExcludeRule PSAvoidUsingWriteHost, PSUseShouldProcessForStateChangingFunctions,
                                     PSAvoidUsingInvokeExpression, PSUseSingularNouns
    }
    $errs = @($results | Where-Object { $_.Severity -eq 'Error' })
    $warns = @($results | Where-Object { $_.Severity -eq 'Warning' })

    foreach ($e in $errs) {
        Write-Host "  FAIL  $($e.ScriptName):$($e.Line) $($e.RuleName) - $($e.Message)" -ForegroundColor Red
        $script:Failures.Add("PSScriptAnalyzer $($e.RuleName) in $($e.ScriptName):$($e.Line)")
    }
    foreach ($w in $warns) {
        Add-Warning "$($w.ScriptName):$($w.Line) $($w.RuleName) - $($w.Message)"
    }
    if (-not $errs) { Write-Host '  PASS  no analyzer errors' -ForegroundColor Green }
} else {
    Add-Warning 'PSScriptAnalyzer not installed - skipping lint. Install-Module PSScriptAnalyzer -Scope CurrentUser'
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host ('-' * 60)
Write-Host "Failures: $($script:Failures.Count)   Warnings: $($script:Warnings.Count)"

if ($script:Failures.Count -gt 0) {
    Write-Host ''
    Write-Host 'FAILED' -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

if ($Strict -and $script:Warnings.Count -gt 0) {
    Write-Host ''
    Write-Host 'FAILED (strict mode: warnings are errors)' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'OK' -ForegroundColor Green
exit 0
