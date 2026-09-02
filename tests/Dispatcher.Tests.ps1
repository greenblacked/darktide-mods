<#
    Wiring tests for darktide.ps1. The verbs are what people actually run, so the
    dispatcher has to pass -Apply through and must not start a later step when an
    earlier one failed.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $script:RepoRoot    = Split-Path -Parent $PSScriptRoot
    $script:Dispatcher  = Join-Path $script:RepoRoot 'darktide.ps1'
    $script:Updater     = Join-Path $script:RepoRoot 'Update-DarktideMods.ps1'
    $script:Deployer    = Join-Path $script:RepoRoot 'Deploy-DarktideMods.ps1'

    $script:PreExistingReports = @(Get-ChildItem -LiteralPath $script:RepoRoot -Filter 'report-*.csv' -File `
                                   -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
}

AfterAll {
    Get-ChildItem -LiteralPath $script:RepoRoot -Filter 'report-*.csv' -File -ErrorAction SilentlyContinue |
        Where-Object { $script:PreExistingReports -notcontains $_.Name } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

Describe 'darktide.ps1 dispatcher' {

    BeforeEach {
        $script:PrevConfirm = $ConfirmPreference
        $ConfirmPreference  = 'None'

        $script:Root    = New-TestSandbox
        $script:Game    = New-FakeGameFolder -Root $script:Root
        $script:Staging = New-FakeStaging -Root $script:Root -Mods @('alpha_mod', 'beta_mod')
        $script:Config  = New-TestConfig -Root $script:Root -StagingMods $script:Staging -GamePath $script:Game
        $script:Downloads = Join-Path $script:Root 'downloads'
        $script:GameMods  = Join-Path $script:Game 'mods'

        $null = New-TestZip -Path (Join-Path $script:Downloads 'Alpha Mod-447-2-0-0-1719209900.zip') -Entries @{
            'alpha_mod/alpha_mod.mod'   = 'return { version = 2 }'
            'alpha_mod/info.json'       = '{"name":"Alpha Mod","version":"2.0.0"}'
            'alpha_mod/scripts/new.lua' = '-- added in 2.0.0'
        }
    }

    AfterEach {
        $ConfirmPreference = $script:PrevConfirm
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'rollback' {

        BeforeEach {
            & $script:Updater -ConfigPath $script:Config -NoApi -Apply -Confirm:$false *>&1 | Out-Null
        }

        It 'does not mutate staging without -Apply' {
            $before = Get-TreeFingerprint -Path $script:Staging

            & $script:Dispatcher rollback -ConfigPath $script:Config *>&1 | Out-Null

            Get-TreeFingerprint -Path $script:Staging | Should -Be $before
            $info = Get-Content -LiteralPath (Join-Path $script:Staging 'alpha_mod\info.json') -Raw -Encoding UTF8 |
                    ConvertFrom-Json
            $info.version | Should -Be '2.0.0'
        }

        It 'restores staging when -Apply is given' {
            & $script:Dispatcher rollback -ConfigPath $script:Config -Apply *>&1 | Out-Null

            $info = Get-Content -LiteralPath (Join-Path $script:Staging 'alpha_mod\info.json') -Raw -Encoding UTF8 |
                    ConvertFrom-Json
            $info.version | Should -Be '1.0.0'
        }
    }

    Context 'restore' {

        BeforeEach {
            & $script:Deployer -ConfigPath $script:Config -Apply -Confirm:$false *>&1 | Out-Null
            & $script:Deployer -ConfigPath $script:Config -Apply -Force -Confirm:$false *>&1 | Out-Null
        }

        It 'does not delete the game mods folder without -Apply' {
            Test-Path -LiteralPath $script:GameMods | Should -BeTrue
            $before = Get-TreeFingerprint -Path $script:GameMods

            & $script:Dispatcher restore -ConfigPath $script:Config *>&1 | Out-Null

            Test-Path -LiteralPath $script:GameMods | Should -BeTrue
            Get-TreeFingerprint -Path $script:GameMods | Should -Be $before
        }

        It 'restores the game mods folder when -Apply is given' {
            $marker = Join-Path $script:GameMods 'alpha_mod\alpha_mod.mod'
            Remove-Item -LiteralPath $marker -Force

            & $script:Dispatcher restore -ConfigPath $script:Config -Apply *>&1 | Out-Null

            Test-Path -LiteralPath $marker | Should -BeTrue
        }
    }

    Context 'sync' {

        It 'does not deploy when the update step fails' {
            $bad = Join-Path $script:Root 'not_a_mods_folder'
            New-Item -ItemType Directory -Path $bad -Force | Out-Null
            $cfg = New-TestConfig -Root $script:Root -StagingMods $bad -GamePath $script:Game

            { & $script:Dispatcher sync -ConfigPath $cfg -Apply } | Should -Throw

            Test-Path -LiteralPath $script:GameMods | Should -BeFalse
        }
    }
}
