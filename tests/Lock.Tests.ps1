<#
    Tests for New-ModpackLock.ps1 and for the repository validator.

    The lockfile is the thing that gets published, so two properties matter:
    it must never carry mod file content, and regenerating it from an unchanged
    staging folder must produce an unchanged manifest.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $script:RepoRoot  = Split-Path -Parent $PSScriptRoot
    $script:Locker    = Join-Path $script:RepoRoot 'New-ModpackLock.ps1'
    $script:Validator = Join-Path $script:RepoRoot 'Test-Modpack.ps1'
}

Describe 'New-ModpackLock' {

    BeforeEach {
        $script:Root    = New-TestSandbox
        $script:Staging = New-FakeStaging -Root $script:Root -Mods @('alpha_mod', 'beta_mod')
        $script:Out     = Join-Path $script:Root 'test.lock.json'
        $script:Map     = Join-Path $script:Root 'mods-map.json'

        @{ alpha_mod = @{ modId = 447; name = 'Alpha Mod' } } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:Map -Encoding UTF8
    }

    AfterEach {
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'writes a lockfile with the expected shape' {
        & $script:Locker -ModsRoot $script:Staging -OutFile $script:Out -MapPath $script:Map -NoHash *>&1 | Out-Null

        Test-Path -LiteralPath $script:Out | Should -BeTrue
        $lock = Get-Content -LiteralPath $script:Out -Raw -Encoding UTF8 | ConvertFrom-Json

        $lock.schemaVersion | Should -Be 1
        $lock.modCount      | Should -Be @($lock.mods).Count
        @($lock.mods).Count | Should -BeGreaterThan 0
    }

    It 'picks up the Nexus id from the map' {
        & $script:Locker -ModsRoot $script:Staging -OutFile $script:Out -MapPath $script:Map -NoHash *>&1 | Out-Null
        $lock = Get-Content -LiteralPath $script:Out -Raw -Encoding UTF8 | ConvertFrom-Json

        $alpha = @($lock.mods | Where-Object { $_.folder -eq 'alpha_mod' })[0]
        $alpha.modId | Should -Be 447
        $alpha.url   | Should -Be 'https://www.nexusmods.com/warhammer40kdarktide/mods/447'
    }

    It 'leaves an unmapped mod with no id and no url' {
        & $script:Locker -ModsRoot $script:Staging -OutFile $script:Out -MapPath $script:Map -NoHash *>&1 | Out-Null
        $lock = Get-Content -LiteralPath $script:Out -Raw -Encoding UTF8 | ConvertFrom-Json

        $beta = @($lock.mods | Where-Object { $_.folder -eq 'beta_mod' })[0]
        $beta.modId | Should -BeNullOrEmpty
        $beta.url   | Should -BeNullOrEmpty
    }

    It 'records every load order entry against a real mod' {
        & $script:Locker -ModsRoot $script:Staging -OutFile $script:Out -MapPath $script:Map -NoHash *>&1 | Out-Null
        $lock = Get-Content -LiteralPath $script:Out -Raw -Encoding UTF8 | ConvertFrom-Json

        $folders = @($lock.mods | ForEach-Object { $_.folder })
        foreach ($entry in @($lock.loadOrder)) {
            $folders | Should -Contain $entry
        }
    }

    It 'contains no mod file content' {
        & $script:Locker -ModsRoot $script:Staging -OutFile $script:Out -MapPath $script:Map -NoHash *>&1 | Out-Null

        $text = Get-Content -LiteralPath $script:Out -Raw -Encoding UTF8
        # The fixture .mod files all carry this body; none of it may reach the manifest.
        $text | Should -Not -Match 'run = function'
        (Get-Item -LiteralPath $script:Out).Length | Should -BeLessThan 512KB
    }

    It 'regenerates an identical manifest from an unchanged staging folder' {
        & $script:Locker -ModsRoot $script:Staging -OutFile $script:Out -MapPath $script:Map -NoHash *>&1 | Out-Null
        $first = Get-Content -LiteralPath $script:Out -Raw -Encoding UTF8 | ConvertFrom-Json

        & $script:Locker -ModsRoot $script:Staging -OutFile $script:Out -MapPath $script:Map -NoHash *>&1 | Out-Null
        $second = Get-Content -LiteralPath $script:Out -Raw -Encoding UTF8 | ConvertFrom-Json

        # generatedAt is a timestamp and is expected to move; nothing else may.
        ($first.mods      | ConvertTo-Json -Depth 8) | Should -Be ($second.mods      | ConvertTo-Json -Depth 8)
        ($first.loadOrder | ConvertTo-Json -Depth 8) | Should -Be ($second.loadOrder | ConvertTo-Json -Depth 8)
        $first.modCount | Should -Be $second.modCount
    }

    It 'produces a stable content hash when hashing is enabled' {
        & $script:Locker -ModsRoot $script:Staging -OutFile $script:Out -MapPath $script:Map *>&1 | Out-Null
        $first = Get-Content -LiteralPath $script:Out -Raw -Encoding UTF8 | ConvertFrom-Json

        & $script:Locker -ModsRoot $script:Staging -OutFile $script:Out -MapPath $script:Map *>&1 | Out-Null
        $second = Get-Content -LiteralPath $script:Out -Raw -Encoding UTF8 | ConvertFrom-Json

        $a = @($first.mods  | Where-Object { $_.folder -eq 'alpha_mod' })[0]
        $b = @($second.mods | Where-Object { $_.folder -eq 'alpha_mod' })[0]

        $a.contentSha256 | Should -Not -BeNullOrEmpty
        $a.contentSha256 | Should -Be $b.contentSha256
    }

    It 'changes the content hash when a mod file changes' {
        & $script:Locker -ModsRoot $script:Staging -OutFile $script:Out -MapPath $script:Map *>&1 | Out-Null
        $before = @((Get-Content -LiteralPath $script:Out -Raw -Encoding UTF8 | ConvertFrom-Json).mods |
                    Where-Object { $_.folder -eq 'alpha_mod' })[0].contentSha256

        Set-Content -LiteralPath (Join-Path $script:Staging 'alpha_mod\alpha_mod.mod') `
                    -Value 'return { changed = true }' -Encoding UTF8

        & $script:Locker -ModsRoot $script:Staging -OutFile $script:Out -MapPath $script:Map *>&1 | Out-Null
        $after = @((Get-Content -LiteralPath $script:Out -Raw -Encoding UTF8 | ConvertFrom-Json).mods |
                   Where-Object { $_.folder -eq 'alpha_mod' })[0].contentSha256

        $after | Should -Not -Be $before
    }
}

Describe 'Test-Modpack (the repo validator)' {

    It 'passes against the real repository' {
        & $script:Validator *>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    It 'does not fail merely because the repo is not a git checkout yet' {
        # Regression: git writes to stderr when there is no repo, and under
        # $ErrorActionPreference='Stop' Windows PowerShell turns that into a
        # terminating NativeCommandError.
        $out = & $script:Validator *>&1 | Out-String
        $out | Should -Not -Match 'FAIL  config.json is not tracked by git'
    }
}
