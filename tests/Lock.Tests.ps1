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

Describe 'New-ModpackLock -SyncIdsFromMap' {

    BeforeEach {
        $script:Root = New-TestSandbox
        $script:Out  = Join-Path $script:Root 'test.lock.json'
        $script:Map  = Join-Path $script:Root 'mods-map.json'

        # Pre-existing lockfile: some ids missing, one already set, versions/hashes present.
        @{
            schemaVersion = 1
            name          = 'fixture'
            game          = 'warhammer40kdarktide'
            generatedAt   = '2026-01-01T00:00:00Z'
            generatedBy   = 'fixture'
            note          = 'test'
            modCount      = 4
            loadOrder     = @('alpha_mod', 'beta_mod')
            mods          = @(
                [ordered]@{
                    folder = 'alpha_mod'; name = 'Alpha'; modId = $null; version = '1.0.0'
                    versionSource = 'info.json'
                    url = $null
                    contentSha256 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
                }
                [ordered]@{
                    folder = 'beta_mod'; name = 'Beta'; modId = $null; version = $null
                    versionSource = 'none'
                    url = $null
                    contentSha256 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
                }
                [ordered]@{
                    folder = 'afk'; name = 'afk'; modId = $null; version = $null
                    versionSource = 'none'
                    url = $null
                    contentSha256 = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
                }
                [ordered]@{
                    folder = 'already'; name = 'Already'; modId = 99; version = '2.0'
                    versionSource = 'info.json'
                    url = 'https://www.nexusmods.com/warhammer40kdarktide/mods/99'
                    contentSha256 = 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
                }
            )
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:Out -Encoding UTF8

        @{
            alpha_mod = @{ modId = 447; name = 'Alpha Mod' }
            beta_mod  = @{ modId = 252; name = 'Beta Mod' }
            afk       = @{ modId = $null; name = 'afk' }
            already   = @{ modId = 100; name = 'Already Mapped' }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:Map -Encoding UTF8
    }

    AfterEach {
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'fills modId and url from the map without requiring ModsRoot' {
        & $script:Locker -SyncIdsFromMap -OutFile $script:Out -MapPath $script:Map *>&1 | Out-Null
        $lock = Get-Content -LiteralPath $script:Out -Raw -Encoding UTF8 | ConvertFrom-Json

        $alpha = @($lock.mods | Where-Object { $_.folder -eq 'alpha_mod' })[0]
        $alpha.modId | Should -Be 447
        $alpha.url   | Should -Be 'https://www.nexusmods.com/warhammer40kdarktide/mods/447'

        $beta = @($lock.mods | Where-Object { $_.folder -eq 'beta_mod' })[0]
        $beta.modId | Should -Be 252
        $beta.url   | Should -Be 'https://www.nexusmods.com/warhammer40kdarktide/mods/252'
    }

    It 'preserves version, versionSource, contentSha256, loadOrder and entry count' {
        $before = Get-Content -LiteralPath $script:Out -Raw -Encoding UTF8 | ConvertFrom-Json

        & $script:Locker -SyncIdsFromMap -OutFile $script:Out -MapPath $script:Map *>&1 | Out-Null
        $after = Get-Content -LiteralPath $script:Out -Raw -Encoding UTF8 | ConvertFrom-Json

        $after.modCount | Should -Be $before.modCount
        @($after.mods).Count | Should -Be @($before.mods).Count
        ($after.loadOrder | ConvertTo-Json -Depth 5) | Should -Be ($before.loadOrder | ConvertTo-Json -Depth 5)

        foreach ($folder in @('alpha_mod', 'beta_mod', 'afk', 'already')) {
            $b = @($before.mods | Where-Object { $_.folder -eq $folder })[0]
            $a = @($after.mods  | Where-Object { $_.folder -eq $folder })[0]
            "$($a.version)"       | Should -Be "$($b.version)"
            "$($a.versionSource)" | Should -Be "$($b.versionSource)"
            "$($a.contentSha256)" | Should -Be "$($b.contentSha256)"
            "$($a.name)"          | Should -Be "$($b.name)"
        }
    }

    It 'leaves map-null folders unchanged' {
        & $script:Locker -SyncIdsFromMap -OutFile $script:Out -MapPath $script:Map *>&1 | Out-Null
        $lock = Get-Content -LiteralPath $script:Out -Raw -Encoding UTF8 | ConvertFrom-Json

        $afk = @($lock.mods | Where-Object { $_.folder -eq 'afk' })[0]
        $afk.modId | Should -BeNullOrEmpty
        $afk.url   | Should -BeNullOrEmpty
    }

    It 'overwrites an existing modId when the map has a different non-null id' {
        & $script:Locker -SyncIdsFromMap -OutFile $script:Out -MapPath $script:Map *>&1 | Out-Null
        $lock = Get-Content -LiteralPath $script:Out -Raw -Encoding UTF8 | ConvertFrom-Json

        $already = @($lock.mods | Where-Object { $_.folder -eq 'already' })[0]
        $already.modId | Should -Be 100
        $already.url   | Should -Be 'https://www.nexusmods.com/warhammer40kdarktide/mods/100'
    }

    It 'allows modId set with version still null' {
        & $script:Locker -SyncIdsFromMap -OutFile $script:Out -MapPath $script:Map *>&1 | Out-Null
        $lock = Get-Content -LiteralPath $script:Out -Raw -Encoding UTF8 | ConvertFrom-Json

        $beta = @($lock.mods | Where-Object { $_.folder -eq 'beta_mod' })[0]
        $beta.modId   | Should -Be 252
        $beta.version | Should -BeNullOrEmpty
        $beta.versionSource | Should -Be 'none'
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

    Context 'the -LiteralPath check' {
        # A check that matches nothing passes on everything, and reads exactly like
        # a check that works. So these plant each shape and watch what it says,
        # rather than only confirming a clean tree stays clean.

        BeforeAll {
            # Defined here, not in the Context body: that body runs during Pester's
            # discovery pass, and a function created then is gone by the time an It
            # actually executes.
            function Get-Verdict {
                param([string] $Code)
                Set-Content -LiteralPath (Join-Path $script:Sandbox 'Probe-Thing.ps1') -Value $Code -Encoding UTF8
                $eap = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try {
                    $out = & (Join-Path $script:Sandbox 'Test-Modpack.ps1') *>&1 | Out-String
                } finally { $ErrorActionPreference = $eap }
                foreach ($line in ($out -split "`r?`n")) {
                    if ($line -match '^\s+(PASS|FAIL)\s+destructive filesystem calls use -LiteralPath\s*$') {
                        return $matches[1]
                    }
                }
                return 'MISSING'
            }
        }

        BeforeEach {
            $script:Sandbox = New-TestSandbox
            Copy-Item -LiteralPath $script:Validator -Destination (Join-Path $script:Sandbox 'Test-Modpack.ps1') -Force
        }

        AfterEach {
            if ($script:Sandbox -and (Test-Path -LiteralPath $script:Sandbox)) {
                Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'fails <_>' -ForEach @(
            'Remove-Item -Path $x -Recurse -Force',
            'Remove-Item $x -Recurse -Force',
            'Move-Item -Path $a -Destination $b',
            'Copy-Item $a $b'
        ) {
            Get-Verdict $_ | Should -Be 'FAIL'
        }

        It 'passes <_>' -ForEach @(
            'Remove-Item -LiteralPath $x -Recurse -Force',
            'Remove-Item -lit $x -Force',
            'Get-ChildItem -LiteralPath $d | Remove-Item -Force',
            'Remove-Item Env:NEXUS_API_KEY -ErrorAction SilentlyContinue'
        ) {
            Get-Verdict $_ | Should -Be 'PASS'
        }

        It 'ignores a call that only appears inside a string' {
            # darktide.ps1 prints 'Copy-Item ...' as help text. A grep reports it;
            # parsing does not, which is why the check parses.
            Get-Verdict "`$h = @`"`nCopy-Item `$a `$b`n`"@" | Should -Be 'PASS'
        }
    }
}
