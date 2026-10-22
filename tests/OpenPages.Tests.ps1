<#
    Tests for Find-ModUpdates.ps1 -Open and the dispatcher's `links -Open`.

    Opening a page is the one thing in the no-key flow that reaches outside the
    terminal, so Start-Process is mocked in every test and the assertions are about
    exactly which addresses would have been handed to it. The property that matters
    most: the address is built from the numeric modId, never copied out of the
    lockfile's free-text url field, because Start-Process passes its argument to the
    shell and the shell will run an executable as readily as open a web page.

    Nothing here builds a game folder or resolves a '\'-separated path, so the file is
    meant to hold up off Windows too.
#>

# The shape Get-LatestGitHubTag reads off Invoke-RestMethod's exception, as in
# FindUpdates.Tests.ps1. Top level because classes cannot live in a script block.
class OpenPagesHttpException : System.Exception {
    [object] $Response
    OpenPagesHttpException([int] $code) : base("HTTP $code") {
        $this.Response = [pscustomobject]@{ StatusCode = $code }
    }
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:Dispatcher = Join-Path $script:RepoRoot 'darktide.ps1'
    $script:Finder     = Join-Path $script:RepoRoot 'Find-ModUpdates.ps1'

    $script:Page = 'https://www.nexusmods.com/warhammer40kdarktide/mods/'

    function New-OpenFixture {
        <#
            A lockfile and a mods-map in a sandbox. -Mods is a list of hashtables in
            lockfile shape; the default is three mods, one of them without an id.
        #>
        param(
            [Parameter(Mandatory)][string] $Root,
            [object[]]  $Mods,
            [hashtable] $Map = @{},
            [object]    $Game = 'warhammer40kdarktide',
            [string]    $LockName = 'test.lock.json',
            [string]    $MapName  = 'test.map.json'
        )

        if (-not $Mods) {
            $Mods = @(
                [ordered]@{ folder = 'alpha_mod'; name = 'Alpha'; modId = 447; version = '2.14.4'
                            url = 'https://www.nexusmods.com/warhammer40kdarktide/mods/447' },
                [ordered]@{ folder = 'beta_mod';  name = 'Beta';  modId = 448; version = '1.0.0' },
                [ordered]@{ folder = 'gamma_mod'; name = 'Gamma'; modId = $null; version = '0.1' }
            )
        }
        $lock = [ordered]@{
            schemaVersion = 1
            modCount      = @($Mods).Count
            loadOrder     = @()
            mods          = @($Mods)
        }
        if ($null -ne $Game) { $lock['game'] = $Game }

        $lockPath = Join-Path $Root $LockName
        $mapPath  = Join-Path $Root $MapName
        $lock | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $lockPath -Encoding UTF8
        $Map  | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $mapPath  -Encoding UTF8
        return @{ Lock = $lockPath; Map = $mapPath }
    }

    function Get-ModEntryList {
        <# $Count mods, all with distinct ids, for the -OpenLimit cases. #>
        param([int] $Count)
        $list = @()
        for ($i = 1; $i -le $Count; $i++) {
            $list += [ordered]@{ folder = ('mod_{0:d3}' -f $i); name = "Mod $i"; modId = 1000 + $i; version = '1.0' }
        }
        return $list
    }

    function Assert-Opened {
        <#
            Start-Process was called exactly once for each of these addresses and for
            nothing else. The exact total plus one call per expected address leaves no
            room for an extra page, a duplicate, or an address that was not asked for.
        #>
        param([string[]] $Expected = @())

        Should -Invoke Start-Process -Scope It -Times $Expected.Count -Exactly
        foreach ($u in $Expected) {
            # Built as text so the filter does not depend on closure capture inside
            # Pester. The addresses are fixed test strings with no quotes in them.
            $filter = [scriptblock]::Create("`$FilePath -ceq '$u'")
            Should -Invoke Start-Process -Scope It -Times 1 -Exactly -ParameterFilter $filter
        }
    }
}

Describe 'Find-ModUpdates -Open' {

    BeforeEach {
        $script:Root = New-TestSandbox
        Mock Start-Process { }
        # No test may reach the network, -CheckGitHub or not.
        Mock Invoke-RestMethod { throw 'network call in a test' }
        Mock Invoke-WebRequest { throw 'network call in a test' }
    }

    AfterEach {
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'which pages open' {

        It 'opens exactly the selected mods, by address built from the id' {
            $f = New-OpenFixture -Root $script:Root

            & $script:Finder -LockPath $f.Lock -MapPath $f.Map -Open -Only alpha_mod, beta_mod *>&1 | Out-Null

            Should -Invoke Start-Process -Times 2 -Exactly
            Assert-Opened @("${script:Page}447", "${script:Page}448")
        }

        It 'opens nothing without -Open' {
            $f = New-OpenFixture -Root $script:Root

            & $script:Finder -LockPath $f.Lock -MapPath $f.Map *>&1 | Out-Null

            Should -Invoke Start-Process -Times 0 -Exactly
        }

        It 'lists a mod with no modId as "no page" and does not open anything for it' {
            $f = New-OpenFixture -Root $script:Root

            $out = & $script:Finder -LockPath $f.Lock -MapPath $f.Map -Open -Only gamma_mod *>&1 | Out-String

            Should -Invoke Start-Process -Times 0 -Exactly
            $out | Should -Match 'gamma_mod\s+no page'
        }

        It 'opens the pages it can and lists the one it cannot' {
            $f = New-OpenFixture -Root $script:Root

            $out = & $script:Finder -LockPath $f.Lock -MapPath $f.Map -Open *>&1 | Out-String

            Assert-Opened @("${script:Page}447", "${script:Page}448")
            $out | Should -Match 'gamma_mod\s+no page'
        }

        It 'opens a page shared by two folders once' {
            $f = New-OpenFixture -Root $script:Root -Mods @(
                [ordered]@{ folder = 'part_one'; modId = 500; version = '1.0' },
                [ordered]@{ folder = 'part_two'; modId = 500; version = '1.0' }
            )

            & $script:Finder -LockPath $f.Lock -MapPath $f.Map -Open *>&1 | Out-Null

            Assert-Opened @("${script:Page}500")
        }

        It 'treats a string id the same as a number and drops leading zeros' {
            $f = New-OpenFixture -Root $script:Root -Mods @(
                [ordered]@{ folder = 'quoted'; modId = ' 0449 '; version = '1.0' }
            )

            & $script:Finder -LockPath $f.Lock -MapPath $f.Map -Open *>&1 | Out-Null

            Assert-Opened @("${script:Page}449")
        }

        It 'uses the lockfile game domain, and the Darktide one when there is none' {
            $other = New-OpenFixture -Root $script:Root -Game 'othergame' -LockName 'other.lock.json'
            & $script:Finder -LockPath $other.Lock -MapPath $other.Map -Open -Only beta_mod *>&1 | Out-Null

            $none = New-OpenFixture -Root $script:Root -Game $null -LockName 'none.lock.json'
            & $script:Finder -LockPath $none.Lock -MapPath $none.Map -Open -Only beta_mod *>&1 | Out-Null

            Assert-Opened @('https://www.nexusmods.com/othergame/mods/448', "${script:Page}448")
        }

        It 'never asks GitHub when -CheckGitHub was not given, even with repos mapped' {
            $f = New-OpenFixture -Root $script:Root -Map @{ alpha_mod = @{ githubRepo = 'owner/alpha' } }

            & $script:Finder -LockPath $f.Lock -MapPath $f.Map -Open *>&1 | Out-Null

            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
            Assert-Opened @("${script:Page}447", "${script:Page}448")
        }

        It 'writes nothing while opening pages' {
            $f = New-OpenFixture -Root $script:Root
            $before = Get-TreeFingerprint -Path $script:Root

            & $script:Finder -LockPath $f.Lock -MapPath $f.Map -Open *>&1 | Out-Null

            Get-TreeFingerprint -Path $script:Root | Should -Be $before
            Should -Invoke Start-Process -Times 2 -Exactly
        }
    }

    Context 'the limit' {

        It 'opens none of them when there are more pages than -OpenLimit, and says how many' {
            $f = New-OpenFixture -Root $script:Root

            # Reset first, so a 1 left over from an earlier test cannot pass this one.
            $global:LASTEXITCODE = 0
            $out = & $script:Finder -LockPath $f.Lock -MapPath $f.Map -Open -OpenLimit 1 *>&1 | Out-String
            $code = $LASTEXITCODE

            Should -Invoke Start-Process -Times 0 -Exactly
            $out  | Should -Match '2 pages; narrow with -Only or raise -OpenLimit'
            $code | Should -Be 1
        }

        It 'defaults to 10' {
            $f = New-OpenFixture -Root $script:Root -Mods (Get-ModEntryList -Count 11)

            $out = & $script:Finder -LockPath $f.Lock -MapPath $f.Map -Open *>&1 | Out-String

            Should -Invoke Start-Process -Times 0 -Exactly
            $out | Should -Match '11 pages; narrow with -Only or raise -OpenLimit'
        }

        It 'opens all of them at exactly the limit' {
            $f = New-OpenFixture -Root $script:Root -Mods (Get-ModEntryList -Count 10)

            & $script:Finder -LockPath $f.Lock -MapPath $f.Map -Open *>&1 | Out-Null

            Should -Invoke Start-Process -Times 10 -Exactly
        }

        It 'counts pages, not folders, against the limit' {
            # Two folders, one page: within a limit of 1.
            $f = New-OpenFixture -Root $script:Root -Mods @(
                [ordered]@{ folder = 'part_one'; modId = 500; version = '1.0' },
                [ordered]@{ folder = 'part_two'; modId = 500; version = '1.0' }
            )

            & $script:Finder -LockPath $f.Lock -MapPath $f.Map -Open -OpenLimit 1 *>&1 | Out-Null

            Should -Invoke Start-Process -Times 1 -Exactly
        }

        It 'says -OpenLimit does nothing on its own, and opens nothing' {
            $f = New-OpenFixture -Root $script:Root

            $out = & $script:Finder -LockPath $f.Lock -MapPath $f.Map -OpenLimit 5 *>&1 | Out-String

            Should -Invoke Start-Process -Times 0 -Exactly
            $out | Should -Match '-OpenLimit does nothing without -Open'
        }

        It 'refuses an -OpenLimit of <limit>' -ForEach @(
            @{ limit = 0 }
            @{ limit = 101 }
        ) {
            $f = New-OpenFixture -Root $script:Root

            { & $script:Finder -LockPath $f.Lock -MapPath $f.Map -Open -OpenLimit $limit } | Should -Throw
            Should -Invoke Start-Process -Times 0 -Exactly
        }
    }

    Context 'with -CheckGitHub' {

        It 'opens only the mods whose GitHub check says differs' {
            # alpha: installed 2.14.4, tag v2.15.0 -> differs.
            # beta:  installed 1.0.0,  tag v1.0.0  -> same.
            # gamma: no repo mapped                -> no claim either way.
            Mock Invoke-RestMethod {
                if ($Uri -match '/owner/alpha/') { return [pscustomobject]@{ tag_name = 'v2.15.0' } }
                if ($Uri -match '/owner/beta/')  { return [pscustomobject]@{ tag_name = 'v1.0.0' } }
                throw "unexpected $Uri"
            }
            $f = New-OpenFixture -Root $script:Root -Map @{
                alpha_mod = @{ githubRepo = 'owner/alpha' }
                beta_mod  = @{ githubRepo = 'owner/beta' }
            }

            $out = & $script:Finder -LockPath $f.Lock -MapPath $f.Map -CheckGitHub -Open *>&1 | Out-String

            Assert-Opened @("${script:Page}447")
            $out | Should -Match "2 mod\(s\) left closed"
        }

        It 'does not open a mod whose GitHub check failed' {
            $code = 403
            Mock Invoke-RestMethod { throw [OpenPagesHttpException]::new($code) }
            $f = New-OpenFixture -Root $script:Root -Map @{ alpha_mod = @{ githubRepo = 'owner/alpha' } }

            & $script:Finder -LockPath $f.Lock -MapPath $f.Map -CheckGitHub -Open *>&1 | Out-Null

            Should -Invoke Start-Process -Times 0 -Exactly
        }

        It 'applies the limit after the differs filter' {
            Mock Invoke-RestMethod { [pscustomobject]@{ tag_name = 'v9.9.9' } }
            $f = New-OpenFixture -Root $script:Root -Map @{ alpha_mod = @{ githubRepo = 'owner/alpha' } }

            & $script:Finder -LockPath $f.Lock -MapPath $f.Map -CheckGitHub -Open -OpenLimit 1 *>&1 | Out-Null

            Assert-Opened @("${script:Page}447")
        }
    }

    Context 'a hostile lockfile' {

        It 'never hands the url field to Start-Process' {
            $evil = @(
                'C:\Windows\System32\calc.exe',
                'file:///C:/Windows/System32/calc.exe',
                'https://evil.example/mods/447',
                'https://www.nexusmods.com/warhammer40kdarktide/mods/447" & calc.exe & "'
            )
            $mods = @()
            for ($i = 0; $i -lt $evil.Count; $i++) {
                $mods += [ordered]@{ folder = "evil_$i"; modId = 700 + $i; version = '1.0'; url = $evil[$i] }
            }
            $mods += [ordered]@{ folder = 'evil_noid'; modId = $null; version = '1.0'; url = $evil[0] }
            $f = New-OpenFixture -Root $script:Root -Mods $mods

            & $script:Finder -LockPath $f.Lock -MapPath $f.Map -Open *>&1 | Out-Null

            Assert-Opened @("${script:Page}700", "${script:Page}701", "${script:Page}702", "${script:Page}703")
            Should -Invoke Start-Process -Scope It -Times 0 -Exactly -ParameterFilter {
                $FilePath -notlike 'https://www.nexusmods.com/*'
            }
        }

        It 'does not open a modId that is not a plain number: <id>' -ForEach @(
            @{ id = '447/../../evil' }
            @{ id = '447?x=1' }
            @{ id = '-5' }
            @{ id = '0' }
            @{ id = '4.47' }
            @{ id = 'calc.exe' }
        ) {
            $f = New-OpenFixture -Root $script:Root -Mods @(
                [ordered]@{ folder = 'odd_id'; modId = $id; version = '1.0' }
            )

            $out = & $script:Finder -LockPath $f.Lock -MapPath $f.Map -Open *>&1 | Out-String

            Should -Invoke Start-Process -Times 0 -Exactly
            $out | Should -Match 'odd_id\s+no page'
        }

        It 'opens nothing when the game field is not a Nexus domain: <game>' -ForEach @(
            @{ game = 'evil.example/x' }
            @{ game = 'darktide?redirect=https://evil.example' }
            @{ game = '..' }
        ) {
            $f = New-OpenFixture -Root $script:Root -Game $game

            $global:LASTEXITCODE = 0
            $out = & $script:Finder -LockPath $f.Lock -MapPath $f.Map -Open *>&1 | Out-String
            $code = $LASTEXITCODE

            Should -Invoke Start-Process -Times 0 -Exactly
            $out  | Should -Match 'not a Nexus game domain'
            $code | Should -Be 1
        }
    }

    Context 'when the browser cannot be started' {

        It 'keeps going, says which did not open, and exits 1' {
            Mock Start-Process { throw 'no browser registered' }
            $f = New-OpenFixture -Root $script:Root

            $global:LASTEXITCODE = 0
            $out = & $script:Finder -LockPath $f.Lock -MapPath $f.Map -Open *>&1 | Out-String
            $code = $LASTEXITCODE

            Should -Invoke Start-Process -Times 2 -Exactly
            $out  | Should -Match 'could not open'
            $out  | Should -Match '2 of 2 page\(s\) did not open'
            $code | Should -Be 1
        }
    }
}

Describe 'darktide.ps1 links -Open' {
    # The dispatcher reads the lockfile beside itself, so it runs from a copy of the
    # scripts in a sandbox with a fixture lockfile, never against the real one.

    BeforeEach {
        $script:Root = New-TestSandbox
        Get-ChildItem -LiteralPath $script:RepoRoot -Filter '*.ps1' -File | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $script:Root $_.Name)
        }
        $null = New-OpenFixture -Root $script:Root -LockName 'darktide-modpack.lock.json' -MapName 'mods-map.json'
        $script:SandboxDispatcher = Join-Path $script:Root 'darktide.ps1'

        Mock Start-Process { }
        Mock Invoke-RestMethod { throw 'network call in a test' }
        Mock Invoke-WebRequest { throw 'network call in a test' }
    }

    AfterEach {
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'passes -Open and -Only through to the finder' {
        & $script:SandboxDispatcher links -Open -Only alpha_mod, beta_mod *>&1 | Out-Null

        Should -Invoke Start-Process -Times 2 -Exactly
        Assert-Opened @("${script:Page}447", "${script:Page}448")
    }

    It 'opens nothing without -Open, and writes nothing either way' {
        $before = Get-TreeFingerprint -Path $script:Root

        & $script:SandboxDispatcher links *>&1 | Out-Null
        Should -Invoke Start-Process -Times 0 -Exactly

        & $script:SandboxDispatcher links -Open *>&1 | Out-Null
        Get-TreeFingerprint -Path $script:Root | Should -Be $before
    }

    It 'needs no config.json' {
        Test-Path -LiteralPath (Join-Path $script:Root 'config.json') | Should -BeFalse

        { & $script:SandboxDispatcher links -Open -Only beta_mod *>&1 | Out-Null } | Should -Not -Throw
        Assert-Opened @("${script:Page}448")
    }
}
