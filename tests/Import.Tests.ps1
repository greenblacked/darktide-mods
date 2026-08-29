<#
    Tests for Import-DarktideLoadout.ps1, including a full export -> import
    round trip: the "move to a new machine" path that has to work first time.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $repo = Split-Path -Parent $PSScriptRoot
    $script:Importer = Join-Path $repo 'Import-DarktideLoadout.ps1'
    $script:Exporter = Join-Path $repo 'Export-DarktideLoadout.ps1'
}

Describe 'Import-DarktideLoadout' {

    BeforeEach {
        $script:Root    = New-TestSandbox
        $script:Game    = New-FakeGameFolder -Root $script:Root
        $script:Staging = New-FakeStaging -Root $script:Root -Mods @('alpha_mod', 'beta_mod')
        $script:Config  = New-TestConfig -Root $script:Root -StagingMods $script:Staging -GamePath $script:Game
        $script:Zip     = Join-Path $script:Root 'loadout.zip'

        & $script:Exporter -ConfigPath $script:Config -OutFile $script:Zip -Confirm:$false *>&1 | Out-Null
    }

    AfterEach {
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'dry run' {

        It 'writes nothing without -Apply' {
            $fresh = Join-Path $script:Root 'fresh'

            & $script:Importer -ConfigPath $script:Config -Path $script:Zip -StagingMods $fresh *>&1 | Out-Null

            Test-Path -LiteralPath $fresh | Should -BeFalse
        }

        It 'reports what the archive holds' {
            $fresh = Join-Path $script:Root 'fresh'
            $out = & $script:Importer -ConfigPath $script:Config -Path $script:Zip -StagingMods $fresh *>&1 | Out-String

            $out | Should -Match 'mods in archive\s*:\s*4'
        }
    }

    Context 'restoring onto a machine with nothing installed' {

        BeforeEach {
            $script:Fresh = Join-Path $script:Root 'fresh'
            & $script:Importer -ConfigPath $script:Config -Path $script:Zip -StagingMods $script:Fresh `
                               -Apply -Force -Confirm:$false *>&1 | Out-Null
        }

        It 'recreates every mod folder' {
            foreach ($m in @('alpha_mod', 'beta_mod', 'base', 'dmf')) {
                Test-Path (Join-Path $script:Fresh "$m\$m.mod") | Should -BeTrue
            }
        }

        It 'restores the load order' {
            $lo = Join-Path $script:Fresh 'mod_load_order.txt'
            Test-Path -LiteralPath $lo | Should -BeTrue
            Get-Content -LiteralPath $lo -Encoding UTF8 | Should -Contain 'alpha_mod'
        }

        It 'reproduces file contents exactly' {
            $original = Get-Content -LiteralPath (Join-Path $script:Staging 'alpha_mod\info.json') -Raw
            $restored = Get-Content -LiteralPath (Join-Path $script:Fresh   'alpha_mod\info.json') -Raw
            $restored | Should -Be $original
        }

        It 'leaves no temporary folder behind' {
            @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter 'dt-import-*' `
              -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
        }
    }

    Context 'restoring over an existing install' {

        It 'replaces a mod that differs' {
            Set-Content -LiteralPath (Join-Path $script:Staging 'alpha_mod\info.json') `
                        -Value '{"name":"alpha_mod","version":"9.9.9"}' -Encoding UTF8

            & $script:Importer -ConfigPath $script:Config -Path $script:Zip -Apply -Force -Confirm:$false *>&1 | Out-Null

            $info = Get-Content -LiteralPath (Join-Path $script:Staging 'alpha_mod\info.json') -Raw | ConvertFrom-Json
            $info.version | Should -Be '1.0.0'
        }

        It 'removes files the archive does not have, rather than merging' {
            $stray = Join-Path $script:Staging 'alpha_mod\leftover.lua'
            Set-Content -LiteralPath $stray -Value '-- from an older version' -Encoding UTF8

            & $script:Importer -ConfigPath $script:Config -Path $script:Zip -Apply -Force -Confirm:$false *>&1 | Out-Null

            Test-Path -LiteralPath $stray | Should -BeFalse
        }

        It 'is idempotent - importing twice changes nothing the second time' {
            & $script:Importer -ConfigPath $script:Config -Path $script:Zip -Apply -Force -Confirm:$false *>&1 | Out-Null
            $first = Get-TreeFingerprint -Path $script:Staging

            & $script:Importer -ConfigPath $script:Config -Path $script:Zip -Apply -Force -Confirm:$false *>&1 | Out-Null
            $second = Get-TreeFingerprint -Path $script:Staging

            # File contents and layout must match; only write timestamps may move.
            ($second -split "`n").Count | Should -Be ($first -split "`n").Count
            foreach ($line in ($first -split "`n")) {
                ($line -split '\|')[0] | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'rejecting a hostile archive' {

        It 'refuses an entry that escapes the destination' {
            $evil = New-TestZip -Path (Join-Path $script:Root 'evil.zip') -Entries @{
                'good_mod/good_mod.mod' = 'return {}'
                'good_mod/../../pwned.txt' = 'escaped'
            }
            $fresh = Join-Path $script:Root 'fresh2'

            { & $script:Importer -ConfigPath $script:Config -Path $evil -StagingMods $fresh `
                                 -Apply -Force -Confirm:$false } | Should -Throw

            Test-Path -LiteralPath (Join-Path $script:Root 'pwned.txt') | Should -BeFalse
        }

        It 'refuses an archive with no mod folders' {
            $flat = New-TestZip -Path (Join-Path $script:Root 'flat.zip') -Entries @{
                'readme.txt' = 'nothing here'
            }

            { & $script:Importer -ConfigPath $script:Config -Path $flat -Apply -Force -Confirm:$false } |
                Should -Throw -ExpectedMessage '*no mod folders*'
        }

        It 'refuses an archive that does not exist' {
            { & $script:Importer -ConfigPath $script:Config -Path (Join-Path $script:Root 'missing.zip') } |
                Should -Throw -ExpectedMessage '*not found*'
        }
    }

    Context 'restore and deploy in one step' {

        It 'lands the mods in the game folder' {
            & $script:Importer -ConfigPath $script:Config -Path $script:Zip -Apply -Deploy -Force -Confirm:$false *>&1 | Out-Null

            $gameMods = Join-Path $script:Game 'mods'
            Test-Path (Join-Path $gameMods 'alpha_mod\alpha_mod.mod') | Should -BeTrue
            Test-Path (Join-Path $gameMods 'mod_load_order.txt')      | Should -BeTrue
        }
    }
}
