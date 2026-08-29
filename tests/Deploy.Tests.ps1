<#
    Integration tests for Deploy-DarktideMods.ps1.

    Every test builds a throwaway staging folder and a fake game install under
    $env:TEMP. The real game folder is never touched.

    The core property under test is idempotency: deploying twice must leave the
    game folder byte-identical and must not accumulate backup archives.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:Deployer = Join-Path (Split-Path -Parent $PSScriptRoot) 'Deploy-DarktideMods.ps1'
}

Describe 'Deploy-DarktideMods' {

    BeforeEach {
        $script:Root    = New-TestSandbox
        $script:Game    = New-FakeGameFolder -Root $script:Root
        $script:Staging = New-FakeStaging    -Root $script:Root -Mods @('alpha_mod', 'beta_mod')
        $script:Config  = New-TestConfig -Root $script:Root -StagingMods $script:Staging -GamePath $script:Game
        $script:GameMods   = Join-Path $script:Game 'mods'
        $script:BackupRoot = Join-Path $script:Root 'deploy_backups'
    }

    AfterEach {
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'dry run' {

        It 'writes nothing at all without -Apply' {
            & $script:Deployer -ConfigPath $script:Config *>&1 | Out-Null

            Test-Path -LiteralPath $script:GameMods   | Should -BeFalse
            Test-Path -LiteralPath $script:BackupRoot | Should -BeFalse
        }

        It 'reports that a first deploy has work to do' {
            $out = & $script:Deployer -ConfigPath $script:Config *>&1 | Out-String
            $out | Should -Match 'changes to copy'
        }
    }

    Context 'first deploy' {

        It 'copies staging into the game mods folder' {
            & $script:Deployer -ConfigPath $script:Config -Apply -Confirm:$false *>&1 | Out-Null

            Test-Path (Join-Path $script:GameMods 'alpha_mod\alpha_mod.mod') | Should -BeTrue
            Test-Path (Join-Path $script:GameMods 'beta_mod\beta_mod.mod')   | Should -BeTrue
            Test-Path (Join-Path $script:GameMods 'base')                    | Should -BeTrue
            Test-Path (Join-Path $script:GameMods 'dmf')                     | Should -BeTrue
            Test-Path (Join-Path $script:GameMods 'mod_load_order.txt')      | Should -BeTrue
        }

        It 'takes no backup when there was no live mods folder to back up' {
            & $script:Deployer -ConfigPath $script:Config -Apply -Confirm:$false *>&1 | Out-Null

            $zips = @(Get-ChildItem -LiteralPath $script:BackupRoot -Filter '*.zip' -ErrorAction SilentlyContinue)
            $zips.Count | Should -Be 0
        }
    }

    Context 'idempotency' {

        BeforeEach {
            & $script:Deployer -ConfigPath $script:Config -Apply -Confirm:$false *>&1 | Out-Null
            $script:Fingerprint = Get-TreeFingerprint -Path $script:GameMods
        }

        It 'leaves the game folder byte-identical on a second apply' {
            & $script:Deployer -ConfigPath $script:Config -Apply -Confirm:$false *>&1 | Out-Null

            Get-TreeFingerprint -Path $script:GameMods | Should -Be $script:Fingerprint
        }

        It 'creates no backup archive when there is nothing to sync' {
            & $script:Deployer -ConfigPath $script:Config -Apply -Confirm:$false *>&1 | Out-Null

            $zips = @(Get-ChildItem -LiteralPath $script:BackupRoot -Filter '*.zip' -ErrorAction SilentlyContinue)
            $zips.Count | Should -Be 0
        }

        It 'says so rather than pretending it did work' {
            $out = & $script:Deployer -ConfigPath $script:Config -Apply -Confirm:$false *>&1 | Out-String
            $out | Should -Match 'Already in sync'
        }

        It 'stays identical over several consecutive applies' {
            1..3 | ForEach-Object {
                & $script:Deployer -ConfigPath $script:Config -Apply -Confirm:$false *>&1 | Out-Null
            }
            Get-TreeFingerprint -Path $script:GameMods | Should -Be $script:Fingerprint

            $zips = @(Get-ChildItem -LiteralPath $script:BackupRoot -Filter '*.zip' -ErrorAction SilentlyContinue)
            $zips.Count | Should -Be 0
        }

        It 'a dry run agrees that nothing is pending' {
            $out = & $script:Deployer -ConfigPath $script:Config *>&1 | Out-String
            $out | Should -Match 'already matches staging'
        }

        It 'still redeploys when -Force overrides the no-op' {
            & $script:Deployer -ConfigPath $script:Config -Apply -Force -Confirm:$false *>&1 | Out-Null

            $zips = @(Get-ChildItem -LiteralPath $script:BackupRoot -Filter '*.zip' -ErrorAction SilentlyContinue)
            $zips.Count | Should -Be 1
        }
    }

    Context 'detecting real changes' {

        BeforeEach {
            & $script:Deployer -ConfigPath $script:Config -Apply -Confirm:$false *>&1 | Out-Null
        }

        It 'copies a mod that was edited in staging' {
            $src = Join-Path $script:Staging 'alpha_mod\alpha_mod.mod'
            Set-Content -LiteralPath $src -Value 'return { version = 2 }' -Encoding UTF8

            & $script:Deployer -ConfigPath $script:Config -Apply -Confirm:$false *>&1 | Out-Null

            $live = Get-Content -LiteralPath (Join-Path $script:GameMods 'alpha_mod\alpha_mod.mod') -Raw
            $live | Should -Match 'version = 2'
        }

        It 'copies a mod that was newly added to staging' {
            $new = Join-Path $script:Staging 'gamma_mod'
            New-Item -ItemType Directory -Path $new -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $new 'gamma_mod.mod') -Value 'return {}' -Encoding UTF8

            & $script:Deployer -ConfigPath $script:Config -Apply -Confirm:$false *>&1 | Out-Null

            Test-Path (Join-Path $script:GameMods 'gamma_mod\gamma_mod.mod') | Should -BeTrue
        }

        It 'backs up before overwriting an existing live folder' {
            Set-Content -LiteralPath (Join-Path $script:Staging 'alpha_mod\alpha_mod.mod') `
                        -Value 'changed' -Encoding UTF8

            & $script:Deployer -ConfigPath $script:Config -Apply -Confirm:$false *>&1 | Out-Null

            $zips = @(Get-ChildItem -LiteralPath $script:BackupRoot -Filter '*.zip')
            $zips.Count | Should -Be 1
        }
    }

    Context 'mirror' {

        BeforeEach {
            & $script:Deployer -ConfigPath $script:Config -Apply -Confirm:$false *>&1 | Out-Null

            # A mod that exists live but no longer in staging.
            $stale = Join-Path $script:GameMods 'removed_mod'
            New-Item -ItemType Directory -Path $stale -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $stale 'removed_mod.mod') -Value 'return {}' -Encoding UTF8
        }

        It 'leaves extra live mods alone by default' {
            & $script:Deployer -ConfigPath $script:Config -Apply -Confirm:$false *>&1 | Out-Null

            Test-Path (Join-Path $script:GameMods 'removed_mod') | Should -BeTrue
        }

        It 'deletes extra live mods with -Mirror' {
            & $script:Deployer -ConfigPath $script:Config -Apply -Mirror -Confirm:$false *>&1 | Out-Null

            Test-Path (Join-Path $script:GameMods 'removed_mod') | Should -BeFalse
        }

        It 'is idempotent under -Mirror too' {
            & $script:Deployer -ConfigPath $script:Config -Apply -Mirror -Confirm:$false *>&1 | Out-Null
            $fp = Get-TreeFingerprint -Path $script:GameMods

            & $script:Deployer -ConfigPath $script:Config -Apply -Mirror -Confirm:$false *>&1 | Out-Null

            Get-TreeFingerprint -Path $script:GameMods | Should -Be $fp
        }
    }

    Context 'backup retention' {

        It 'keeps only the newest -KeepBackups archives' {
            & $script:Deployer -ConfigPath $script:Config -Apply -Confirm:$false *>&1 | Out-Null

            # Five forced redeploys would leave five archives without pruning.
            1..5 | ForEach-Object {
                & $script:Deployer -ConfigPath $script:Config -Apply -Force -KeepBackups 2 -Confirm:$false *>&1 | Out-Null
            }

            $zips = @(Get-ChildItem -LiteralPath $script:BackupRoot -Filter 'gamemods-*.zip')
            $zips.Count | Should -BeLessOrEqual 2
        }
    }

    Context 'refusing an unsafe target' {

        It 'refuses a folder that is not a Darktide install' {
            $notGame = Join-Path $script:Root 'somewhere\else\entirely'
            New-Item -ItemType Directory -Path $notGame -Force | Out-Null

            { & $script:Deployer -ConfigPath $script:Config -GamePath $notGame -Apply -Confirm:$false } |
                Should -Throw -ExpectedMessage '*does not look like a Darktide install*'
        }

        It 'refuses a game path that does not exist' {
            { & $script:Deployer -ConfigPath $script:Config -GamePath (Join-Path $script:Root 'nope') -Apply -Confirm:$false } |
                Should -Throw -ExpectedMessage '*does not exist*'
        }

        It 'refuses a drive root' {
            { & $script:Deployer -ConfigPath $script:Config -GamePath 'C:\' -Apply -Confirm:$false } |
                Should -Throw
        }

        It 'refuses a staging folder that is not a mods folder' {
            $bogus = Join-Path $script:Root 'not_mods'
            New-Item -ItemType Directory -Path (Join-Path $bogus 'random') -Force | Out-Null

            { & $script:Deployer -ConfigPath $script:Config -StagingMods $bogus -Apply -Confirm:$false } |
                Should -Throw -ExpectedMessage '*not a mods folder*'
        }

        It 'refuses an empty staging folder' {
            $empty = Join-Path $script:Root 'empty_mods'
            New-Item -ItemType Directory -Path $empty -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $empty 'mod_load_order.txt') -Value '-- nothing' -Encoding UTF8

            { & $script:Deployer -ConfigPath $script:Config -StagingMods $empty -Apply -Confirm:$false } |
                Should -Throw -ExpectedMessage '*no mods in it*'
        }
    }

    Context 'post-checks' {

        It 'reports a load order entry with no matching folder' {
            Add-Content -LiteralPath (Join-Path $script:Staging 'mod_load_order.txt') `
                        -Value 'mod_that_does_not_exist' -Encoding UTF8

            $out = & $script:Deployer -ConfigPath $script:Config -Apply -Confirm:$false *>&1 | Out-String

            $out | Should -Match 'load order references missing folders'
            $out | Should -Match 'mod_that_does_not_exist'
        }

        It 'confirms every load order entry resolves on a clean deploy' {
            $out = & $script:Deployer -ConfigPath $script:Config -Apply -Confirm:$false *>&1 | Out-String
            $out | Should -Match 'all \d+ entries resolve'
        }
    }
}
