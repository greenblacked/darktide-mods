<#
    Tests for Find-ModUpdates.ps1.

    Two halves, tested two ways. The link list touches nothing and runs the script
    for real against a sandbox lockfile. The GitHub half cannot be tested against
    GitHub - a suite that needs the network is a suite that fails on a train - so
    those functions are lifted out with Import-ScriptFunctions and the HTTP call is
    mocked, which is how the rest of this repo handles the same problem.

    The classifier is deliberately not a version *ranking*, so the cases here assert
    'same' or 'differs' and never 'newer'. See the note in the script.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Finder   = Join-Path $script:RepoRoot 'Find-ModUpdates.ps1'

    Import-ScriptFunctions -Path $script:Finder -Name @('Get-VersionComparison', 'Get-LatestGitHubTag')

    function New-Fixture {
        <# A lockfile and a mods-map in a sandbox, so no test reads the real ones. #>
        param([Parameter(Mandatory)][string] $Root, [hashtable] $Map = @{})

        $lock = [ordered]@{
            schemaVersion = 1
            game          = 'warhammer40kdarktide'
            modCount      = 3
            loadOrder     = @()
            mods          = @(
                [ordered]@{ folder = 'alpha_mod'; name = 'Alpha'; modId = 447; version = '2.14.4'
                            url = 'https://www.nexusmods.com/warhammer40kdarktide/mods/447' },
                # No url, so the script has to build one from the id and the game.
                [ordered]@{ folder = 'beta_mod';  name = 'Beta';  modId = 448; version = '1.0.0' },
                [ordered]@{ folder = 'gamma_mod'; name = 'Gamma'; modId = $null; version = '0.1' }
            )
        }
        $lockPath = Join-Path $Root 'test.lock.json'
        $mapPath  = Join-Path $Root 'test.map.json'
        $lock | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $lockPath -Encoding UTF8
        $Map  | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $mapPath  -Encoding UTF8
        return @{ Lock = $lockPath; Map = $mapPath }
    }
}

Describe 'Find-ModUpdates' {

    BeforeEach {
        $script:Root = New-TestSandbox
    }

    AfterEach {
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'the link list, which needs no key and no network' {

        It 'prints the Nexus page for every mod that has an id' {
            $f = New-Fixture -Root $script:Root
            $out = & $script:Finder -LockPath $f.Lock -MapPath $f.Map *>&1 | Out-String

            $out | Should -Match 'mods/447'
            $out | Should -Match 'mods/448'
        }

        It 'builds the page from the id and the game when the lockfile has no url' {
            $f = New-Fixture -Root $script:Root
            $out = & $script:Finder -LockPath $f.Lock -MapPath $f.Map *>&1 | Out-String

            $out | Should -Match 'https://www\.nexusmods\.com/warhammer40kdarktide/mods/448'
        }

        It 'says so rather than inventing a link for a mod with no id' {
            $f = New-Fixture -Root $script:Root
            $out = & $script:Finder -LockPath $f.Lock -MapPath $f.Map *>&1 | Out-String

            $out | Should -Match 'gamma_mod\s+no Nexus id'
        }

        It 'honours -Only' {
            $f = New-Fixture -Root $script:Root
            $out = & $script:Finder -LockPath $f.Lock -MapPath $f.Map -Only 'alpha_mod' *>&1 | Out-String

            $out | Should -Match 'alpha_mod'
            $out | Should -Not -Match 'beta_mod'
        }

        It 'honours -Skip' {
            $f = New-Fixture -Root $script:Root
            $out = & $script:Finder -LockPath $f.Lock -MapPath $f.Map -Skip 'alpha_mod' *>&1 | Out-String

            $out | Should -Not -Match 'alpha_mod'
            $out | Should -Match 'beta_mod'
        }

        It 'writes a markdown list with -OutFile' {
            $f = New-Fixture -Root $script:Root
            $md = Join-Path $script:Root 'list.md'

            & $script:Finder -LockPath $f.Lock -MapPath $f.Map -OutFile $md *>&1 | Out-Null

            $text = Get-Content -LiteralPath $md -Raw -Encoding UTF8
            $text | Should -Match '\[Nexus\]\(https://www\.nexusmods\.com/warhammer40kdarktide/mods/447\)'
            $text | Should -Match '_no Nexus id_'
        }

        It 'refuses a lockfile that is not there rather than reporting an empty list' {
            { & $script:Finder -LockPath (Join-Path $script:Root 'absent.json') } |
                Should -Throw -ExpectedMessage '*No lockfile*'
        }
    }

    Context 'the githubRepo mapping' {

        It 'reports a mapped repo without asking GitHub unless told to' {
            $f = New-Fixture -Root $script:Root -Map @{ alpha_mod = @{ githubRepo = 'owner/repo' } }
            $out = & $script:Finder -LockPath $f.Lock -MapPath $f.Map *>&1 | Out-String

            $out | Should -Match 'repo mapped'
            $out | Should -Match '-CheckGitHub'
        }

        It 'ignores a githubRepo that is not owner/repo, and says which' {
            $f = New-Fixture -Root $script:Root -Map @{ alpha_mod = @{ githubRepo = 'not a repo!' } }
            $out = & $script:Finder -LockPath $f.Lock -MapPath $f.Map *>&1 | Out-String

            $out | Should -Match "ignoring githubRepo"
            $out | Should -Match 'alpha_mod'
        }

        It 'points at the field when nothing is mapped yet' {
            $f = New-Fixture -Root $script:Root
            $out = & $script:Finder -LockPath $f.Lock -MapPath $f.Map *>&1 | Out-String

            $out | Should -Match 'githubRepo'
        }
    }

    Context 'comparing an installed version with a release tag' {
        # Never 'newer'. The two strings are not guaranteed to share a scheme.

        It 'calls <installed> and <tag> <expected>' -ForEach @(
            @{ installed = '2.14.4'; tag = 'v2.14.4'; expected = 'same' }
            @{ installed = '2.14.4'; tag = '2.14.4';  expected = 'same' }
            @{ installed = '2.14.4'; tag = 'v2.15.0'; expected = 'differs' }
            @{ installed = '1.0';    tag = 'v1.0.0';  expected = 'differs' }
            @{ installed = '';       tag = 'v1.0.0';  expected = 'no local version' }
            @{ installed = '1.0.0';  tag = '';        expected = 'no release tag' }
        ) {
            Get-VersionComparison -Installed $installed -Tag $tag | Should -Be $expected
        }
    }

    Context 'reading the latest tag' {

        It 'returns the tag when GitHub answers' {
            Mock Invoke-RestMethod { [pscustomobject]@{ tag_name = 'v3.1.0' } }

            $result = Get-LatestGitHubTag -Repo 'owner/repo'

            $result.Tag  | Should -Be 'v3.1.0'
            $result.Note | Should -BeNullOrEmpty
        }

        It 'reports a repository with no releases as such, not as an error' {
            Mock Invoke-RestMethod { throw 'nope' }

            $result = Get-LatestGitHubTag -Repo 'owner/repo'

            $result.Tag  | Should -BeNullOrEmpty
            $result.Note | Should -Not -BeNullOrEmpty
        }

        It 'never puts the token on the command line' {
            # The header is built inside the function from the environment. This is a
            # guard against someone adding a -Token parameter later: a key on a
            # command line lands in process listings and shell history.
            (Get-Command Get-LatestGitHubTag).Parameters.Keys | Should -Not -Contain 'Token'
            (Get-Command Get-LatestGitHubTag).Parameters.Keys | Should -Not -Contain 'ApiKey'
        }
    }
}
