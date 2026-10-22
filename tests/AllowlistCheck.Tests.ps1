<#
    Tests for the validator's 'release allow-list covers every dispatcher script'
    check.

    The failure it guards against is quiet. A new root script that never reaches
    $Include in New-ReleasePackage.ps1 exists in the repository, so every other
    check passes; the released package then lacks it, and the dispatcher's
    existence loop throws 'Missing script' before running any verb at all.

    So each case runs the real validator against a throwaway copy of the
    repository and plants the exact mistake, rather than only watching a clean
    tree stay clean. A check verified only against a passing layout has not been
    verified.

    The copy holds the working-tree validator, packaging script and dispatcher,
    plus a stub for every other root script and allow-listed path. Nothing here
    needs Windows, git or the network.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:Dispatcher = Join-Path $script:RepoRoot 'darktide.ps1'
    $script:Packer     = Join-Path $script:RepoRoot 'New-ReleasePackage.ps1'
    $script:Validator  = Join-Path $script:RepoRoot 'Test-Modpack.ps1'
    $script:CheckName  = 'release allow-list covers every dispatcher script'

    function New-FakeRepo {
        <#
            The real layout in miniature: the three files the check reads are real
            copies, every other root .ps1 and every allow-listed path is a stub.
        #>
        param([Parameter(Mandatory)][string] $Root)

        $real = @('Test-Modpack.ps1', 'New-ReleasePackage.ps1', 'darktide.ps1')
        foreach ($name in $real) {
            Copy-Item -LiteralPath (Join-Path $script:RepoRoot $name) -Destination (Join-Path $Root $name) -Force
        }

        $rootScripts = @(Get-ChildItem -LiteralPath $script:RepoRoot -File |
                         Where-Object { $_.Extension -eq '.ps1' } | ForEach-Object { $_.Name })
        $listed = @(& $script:Packer -ListOnly)

        foreach ($name in @($rootScripts + $listed | Sort-Object -Unique)) {
            if ($real -contains $name) { continue }
            $target = Join-Path $Root $name
            if (Test-Path -LiteralPath (Join-Path $script:RepoRoot $name) -PathType Container) {
                [void][System.IO.Directory]::CreateDirectory($target)
                Set-Content -LiteralPath (Join-Path $target 'Stub.Tests.ps1') -Value '# stub' -Encoding UTF8
            } elseif ($name -like '*.json') {
                # The real manifests, not stubs: the validator reads the lockfile
                # outside any single check, and an empty one stops the run before
                # it reaches this check. They are metadata, not mod content.
                Copy-Item -LiteralPath (Join-Path $script:RepoRoot $name) -Destination $target -Force
            } else {
                Set-Content -LiteralPath $target -Value "# stub $name" -Encoding UTF8
            }
        }
    }

    function Edit-FakeFile {
        <#
            Literal text replacement that fails loudly when the anchor is not there
            exactly once, so a test cannot turn into a no-op when a file changes shape.
        #>
        param(
            [Parameter(Mandatory)][string] $Path,
            [Parameter(Mandatory)][string] $Find,
            [Parameter(Mandatory)][string] $Replace
        )
        $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        $hits = ([regex]::Matches($text, [regex]::Escape($Find))).Count
        if ($hits -ne 1) { throw "expected '$Find' once in $Path, found it $hits time(s)" }
        Set-Content -LiteralPath $Path -Value $text.Replace($Find, $Replace) -Encoding UTF8 -NoNewline
    }

    function Add-DispatcherLine {
        param([Parameter(Mandatory)][string] $Root, [Parameter(Mandatory)][string] $Line)
        Add-Content -LiteralPath (Join-Path $Root 'darktide.ps1') -Value $Line -Encoding UTF8
    }

    function Add-ToInclude {
        param([Parameter(Mandatory)][string] $Root, [Parameter(Mandatory)][string] $Name)
        Edit-FakeFile -Path (Join-Path $Root 'New-ReleasePackage.ps1') -Find '$Include = @(' `
                      -Replace "`$Include = @(`n    '$Name',"
    }

    function Add-ToDevOnly {
        param([Parameter(Mandatory)][string] $Root, [Parameter(Mandatory)][string] $Name)
        Edit-FakeFile -Path (Join-Path $Root 'Test-Modpack.ps1') -Find '$devOnly = @(' `
                      -Replace "`$devOnly = @(`n        '$Name',"
    }

    function Get-AllowListVerdict {
        <#
            The PASS/FAIL for this one check and the message printed under it.
            Deliberately not the validator's exit code: the stub tree can fail
            other checks that have nothing to do with this one.
        #>
        param([Parameter(Mandatory)][string] $Root)

        Push-Location -LiteralPath $Root
        try {
            $eap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                # '*>&1': the validator reports through Write-Host. Each record is
                # turned into its own text rather than piped through Out-String,
                # which on Windows PowerShell 5.1 word-wraps at the host width and
                # would cut the message under FAIL across several lines.
                $out = @(& (Join-Path $Root 'Test-Modpack.ps1') *>&1 | ForEach-Object { [string]$_ }) -join "`n"
            } finally { $ErrorActionPreference = $eap }
        } finally { Pop-Location }

        $lines = @($out -split "`r?`n")
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "^\s+(PASS|FAIL)\s+$([regex]::Escape($script:CheckName))\s*$") {
                $message = ''
                if ($matches[1] -eq 'FAIL' -and $i + 1 -lt $lines.Count) { $message = $lines[$i + 1].Trim() }
                return [pscustomobject]@{ Verdict = $matches[1]; Message = $message }
            }
        }
        return [pscustomobject]@{ Verdict = 'MISSING (the check did not run at all)'; Message = '' }
    }
}

Describe 'Validator: release allow-list covers every dispatcher script' {

    BeforeEach {
        $script:Root = New-TestSandbox
        New-FakeRepo -Root $script:Root
    }

    AfterEach {
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'the layout as it stands' {

        It 'passes on the real allow-list, dispatcher and root scripts' {
            $r = Get-AllowListVerdict -Root $script:Root
            $r.Verdict | Should -Be 'PASS'
        }

        It 'writes nothing into the tree it checks' {
            $before = Get-TreeFingerprint -Path $script:Root
            Get-AllowListVerdict -Root $script:Root | Out-Null
            Get-TreeFingerprint -Path $script:Root | Should -Be $before
        }

        It 'finds every script the real dispatcher resolves on the real allow-list' {
            # Independent of the validator: the same parse, done here, against the
            # real files. Catches the check passing because it saw nothing.
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Dispatcher, [ref]$null, [ref]$null)
            $refs = @($ast.FindAll({ param($n)
                        $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                        $n.Value -match '\.ps1$' -and
                        $n.Parent -is [System.Management.Automation.Language.CommandAst] -and
                        $n.Parent.GetCommandName() -eq 'Join-Path' }, $true) | ForEach-Object { $_.Value })
            $refs.Count | Should -BeGreaterThan 0
            $listed = @(& $script:Packer -ListOnly)
            foreach ($ref in $refs) { $listed | Should -Contain $ref }
        }
    }

    Context 'a root script that never reached the allow-list' {

        It 'fails and names the script' {
            Set-Content -LiteralPath (Join-Path $script:Root 'New-Forgotten.ps1') -Value '# new' -Encoding UTF8

            $r = Get-AllowListVerdict -Root $script:Root
            $r.Verdict | Should -Be 'FAIL'
            $r.Message | Should -Match 'New-Forgotten\.ps1'
            $r.Message | Should -Match 'neither on the release allow-list nor marked dev-only'
        }

        It 'fails for the shape of a new verb: script and dispatcher wiring, no allow-list entry' {
            Set-Content -LiteralPath (Join-Path $script:Root 'Get-Something.ps1') -Value '# new' -Encoding UTF8
            Add-DispatcherLine -Root $script:Root -Line '$Getter = Join-Path $PSScriptRoot ''Get-Something.ps1'''

            $r = Get-AllowListVerdict -Root $script:Root
            $r.Verdict | Should -Be 'FAIL'
            $r.Message | Should -Match 'neither on the release allow-list.*Get-Something\.ps1'
            $r.Message | Should -Match 'darktide\.ps1 needs script\(s\) the release does not ship: Get-Something\.ps1'
        }

        It 'passes once the script is added to $Include, as a complete new-verb change does' {
            Set-Content -LiteralPath (Join-Path $script:Root 'Get-Something.ps1') -Value '# new' -Encoding UTF8
            Add-DispatcherLine -Root $script:Root -Line '$Getter = Join-Path $PSScriptRoot ''Get-Something.ps1'''
            Add-ToInclude -Root $script:Root -Name 'Get-Something.ps1'

            (Get-AllowListVerdict -Root $script:Root).Verdict | Should -Be 'PASS'
        }

        It 'passes when the script is on the dev-only list in the check' {
            Set-Content -LiteralPath (Join-Path $script:Root 'Build-Something.ps1') -Value '# dev' -Encoding UTF8
            Add-ToDevOnly -Root $script:Root -Name 'Build-Something.ps1'

            (Get-AllowListVerdict -Root $script:Root).Verdict | Should -Be 'PASS'
        }

        It 'ignores scripts below the root, which the dispatcher does not front' {
            [void][System.IO.Directory]::CreateDirectory((Join-Path $script:Root 'docs'))
            Set-Content -LiteralPath (Join-Path $script:Root 'docs/example.ps1') -Value '# doc' -Encoding UTF8

            (Get-AllowListVerdict -Root $script:Root).Verdict | Should -Be 'PASS'
        }
    }

    Context 'a script the dispatcher needs that the release does not ship' {

        It 'fails when the dispatcher references an unlisted script positionally' {
            Add-DispatcherLine -Root $script:Root -Line '$Ghost = Join-Path $PSScriptRoot ''Ghost-Tool.ps1'''

            $r = Get-AllowListVerdict -Root $script:Root
            $r.Verdict | Should -Be 'FAIL'
            $r.Message | Should -Match 'darktide\.ps1 needs script\(s\) the release does not ship: Ghost-Tool\.ps1'
            $r.Message | Should -Match 'Missing script'
        }

        It 'fails when the reference uses -Path and -ChildPath' {
            Add-DispatcherLine -Root $script:Root -Line '$Ghost = Join-Path -Path $PSScriptRoot -ChildPath ''Named-Tool.ps1'''

            $r = Get-AllowListVerdict -Root $script:Root
            $r.Verdict | Should -Be 'FAIL'
            $r.Message | Should -Match 'Named-Tool\.ps1'
        }

        It 'fails when the referenced script is marked dev-only, because the dispatcher still needs it' {
            Set-Content -LiteralPath (Join-Path $script:Root 'Build-Something.ps1') -Value '# dev' -Encoding UTF8
            Add-ToDevOnly -Root $script:Root -Name 'Build-Something.ps1'
            Add-DispatcherLine -Root $script:Root -Line '$Builder = Join-Path $PSScriptRoot ''Build-Something.ps1'''

            $r = Get-AllowListVerdict -Root $script:Root
            $r.Verdict | Should -Be 'FAIL'
            $r.Message | Should -Match 'does not ship: Build-Something\.ps1'
            $r.Message | Should -Not -Match 'neither on the release allow-list'
        }

        It 'does not count a name that only appears in a comment or a string' {
            Add-DispatcherLine -Root $script:Root -Line '# $Old = Join-Path $PSScriptRoot ''Retired-Tool.ps1'''
            Add-DispatcherLine -Root $script:Root -Line '$null = "Join-Path `$PSScriptRoot ''Quoted-Tool.ps1''"'

            (Get-AllowListVerdict -Root $script:Root).Verdict | Should -Be 'PASS'
        }

        It 'accepts a reference under a listed folder whichever separator it uses' {
            Add-DispatcherLine -Root $script:Root -Line '$Helper = Join-Path $PSScriptRoot ''tests\Stub.Tests.ps1'''
            Add-DispatcherLine -Root $script:Root -Line '$Helper2 = Join-Path $PSScriptRoot ''tests/Stub.Tests.ps1'''

            (Get-AllowListVerdict -Root $script:Root).Verdict | Should -Be 'PASS'
        }

        It 'fails rather than passing when it can no longer find any dispatcher references' {
            # A check that matches nothing passes on everything.
            Set-Content -LiteralPath (Join-Path $script:Root 'darktide.ps1') -Value 'param() ''nothing here''' -Encoding UTF8

            $r = Get-AllowListVerdict -Root $script:Root
            $r.Verdict | Should -Be 'FAIL'
            $r.Message | Should -Match 'found no Join-Path'
        }
    }
}
