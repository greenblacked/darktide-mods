<#
    End-to-end tests for the offline install path of Update-DarktideMods.ps1.

    This is the code that deletes and replaces a mod folder, so it gets exercised
    for real: a sandbox staging folder, a sandbox download folder holding archives
    we build ourselves, and no network or API key anywhere.

    Offline mode is the only mode that can be tested honestly - a Nexus free account
    cannot obtain download links from the API, so there is no live download path.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Updater  = Join-Path $script:RepoRoot 'Update-DarktideMods.ps1'

    # The updater writes its CSV report next to itself. Remember what was there so
    # the suite can leave the repo as it found it.
    $script:PreExistingReports = @(Get-ChildItem -LiteralPath $script:RepoRoot -Filter 'report-*.csv' -File `
                                   -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
}

AfterAll {
    Get-ChildItem -LiteralPath $script:RepoRoot -Filter 'report-*.csv' -File -ErrorAction SilentlyContinue |
        Where-Object { $script:PreExistingReports -notcontains $_.Name } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

Describe 'Offline update' {

    BeforeEach {
        $script:Root    = New-TestSandbox
        $script:Game    = New-FakeGameFolder -Root $script:Root
        $script:Staging = New-FakeStaging -Root $script:Root -Mods @('alpha_mod', 'beta_mod')
        $script:Config  = New-TestConfig -Root $script:Root -StagingMods $script:Staging -GamePath $script:Game
        $script:Downloads = Join-Path $script:Root 'downloads'
        $script:Backups   = Join-Path $script:Root 'mod_backups'

        # The fixture installs every mod at 1.0.0; this archive is a genuine upgrade.
        $script:NewerZip = New-TestZip -Path (Join-Path $script:Downloads 'Alpha Mod-447-2-0-0-1719209900.zip') -Entries @{
            'alpha_mod/alpha_mod.mod'  = 'return { version = 2 }'
            'alpha_mod/info.json'      = '{"name":"Alpha Mod","version":"2.0.0"}'
            'alpha_mod/scripts/new.lua' = '-- added in 2.0.0'
        }
    }

    AfterEach {
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'dry run' {

        It 'reports the upgrade without writing anything' {
            $before = Get-TreeFingerprint -Path $script:Staging

            $out = & $script:Updater -ConfigPath $script:Config -NoApi *>&1 | Out-String

            $out | Should -Match 'alpha_mod'
            Get-TreeFingerprint -Path $script:Staging | Should -Be $before
            Test-Path -LiteralPath $script:Backups | Should -BeFalse
        }
    }

    Context 'installing an upgrade' {

        BeforeEach {
            & $script:Updater -ConfigPath $script:Config -NoApi -Apply -Confirm:$false *>&1 | Out-Null
        }

        It 'replaces the mod folder with the archive contents' {
            $info = Get-Content -LiteralPath (Join-Path $script:Staging 'alpha_mod\info.json') -Raw -Encoding UTF8 |
                    ConvertFrom-Json
            $info.version | Should -Be '2.0.0'
            Test-Path (Join-Path $script:Staging 'alpha_mod\scripts\new.lua') | Should -BeTrue
        }

        It 'records the installed version so the next run knows what it has' {
            $statePath = Join-Path $script:Staging 'alpha_mod\.nexus-mod.json'
            Test-Path -LiteralPath $statePath | Should -BeTrue

            $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $state.version | Should -Be '2.0.0'
            $state.modId   | Should -Be 447
        }

        It 'backs the old folder up before replacing it' {
            $zips = @(Get-ChildItem -LiteralPath $script:Backups -Recurse -Filter '*.zip' -ErrorAction SilentlyContinue)
            $zips.Count | Should -BeGreaterThan 0
        }

        It 'leaves the other mods untouched' {
            $beta = Get-Content -LiteralPath (Join-Path $script:Staging 'beta_mod\info.json') -Raw -Encoding UTF8 |
                    ConvertFrom-Json
            $beta.version | Should -Be '1.0.0'
        }

        It 'does not leave a staging directory behind' {
            @(Get-ChildItem -LiteralPath $script:Staging -Directory -Force |
              Where-Object { $_.Name -like '.staging-*' }) | Should -BeNullOrEmpty
        }
    }

    Context 'idempotency' {

        BeforeEach {
            & $script:Updater -ConfigPath $script:Config -NoApi -Apply -Confirm:$false *>&1 | Out-Null
            $script:AfterFirst = Get-TreeFingerprint -Path $script:Staging
            $script:BackupsAfterFirst = @(Get-ChildItem -LiteralPath $script:Backups -Recurse -File `
                                          -ErrorAction SilentlyContinue).Count
        }

        It 'changes nothing when the same archive is installed again' {
            & $script:Updater -ConfigPath $script:Config -NoApi -Apply -Confirm:$false *>&1 | Out-Null

            Get-TreeFingerprint -Path $script:Staging | Should -Be $script:AfterFirst
        }

        It 'takes no further backup on the second run' {
            & $script:Updater -ConfigPath $script:Config -NoApi -Apply -Confirm:$false *>&1 | Out-Null

            @(Get-ChildItem -LiteralPath $script:Backups -Recurse -File -ErrorAction SilentlyContinue).Count |
                Should -Be $script:BackupsAfterFirst
        }

        It 'reports the mod as already installed' {
            $out = & $script:Updater -ConfigPath $script:Config -NoApi -Apply -Confirm:$false *>&1 | Out-String
            $out | Should -Match 'SAME|already installed'
        }

        It 'stays unchanged over several consecutive runs' {
            1..3 | ForEach-Object {
                & $script:Updater -ConfigPath $script:Config -NoApi -Apply -Confirm:$false *>&1 | Out-Null
            }
            Get-TreeFingerprint -Path $script:Staging | Should -Be $script:AfterFirst
        }
    }

    Context 'installing a mod that is not staged yet' {

        BeforeEach {
            $null = New-TestZip -Path (Join-Path $script:Downloads 'Gamma Mod-900-1-0-0-1719209999.zip') -Entries @{
                'gamma_mod/gamma_mod.mod' = 'return {}'
                'gamma_mod/info.json'     = '{"name":"Gamma Mod","version":"1.0.0"}'
            }
        }

        It 'installs it into staging' {
            & $script:Updater -ConfigPath $script:Config -NoApi -Apply -Confirm:$false *>&1 | Out-Null

            Test-Path (Join-Path $script:Staging 'gamma_mod\gamma_mod.mod') | Should -BeTrue
        }

        It 'adds it to mod_load_order.txt' {
            & $script:Updater -ConfigPath $script:Config -NoApi -Apply -Confirm:$false *>&1 | Out-Null

            $order = Get-Content -LiteralPath (Join-Path $script:Staging 'mod_load_order.txt') -Encoding UTF8
            $order | Should -Contain 'gamma_mod'
        }

        It 'does not duplicate the load order entry on a second run' {
            & $script:Updater -ConfigPath $script:Config -NoApi -Apply -Confirm:$false *>&1 | Out-Null
            & $script:Updater -ConfigPath $script:Config -NoApi -Apply -Confirm:$false *>&1 | Out-Null

            $order = @(Get-Content -LiteralPath (Join-Path $script:Staging 'mod_load_order.txt') -Encoding UTF8 |
                       Where-Object { $_.Trim() -eq 'gamma_mod' })
            $order.Count | Should -Be 1
        }
    }

    Context 'refusing to downgrade' {

        BeforeEach {
            # Install 2.0.0 first, then offer an older archive.
            & $script:Updater -ConfigPath $script:Config -NoApi -Apply -Confirm:$false *>&1 | Out-Null
            Remove-Item -LiteralPath $script:NewerZip -Force

            $null = New-TestZip -Path (Join-Path $script:Downloads 'Alpha Mod-447-1-5-0-1719209800.zip') -Entries @{
                'alpha_mod/alpha_mod.mod' = 'return { version = 1.5 }'
                'alpha_mod/info.json'     = '{"name":"Alpha Mod","version":"1.5.0"}'
            }
        }

        It 'leaves the newer install in place' {
            & $script:Updater -ConfigPath $script:Config -NoApi -Apply -Confirm:$false *>&1 | Out-Null

            $info = Get-Content -LiteralPath (Join-Path $script:Staging 'alpha_mod\info.json') -Raw -Encoding UTF8 |
                    ConvertFrom-Json
            $info.version | Should -Be '2.0.0'
        }

        It 'downgrades only when -Force is given' {
            & $script:Updater -ConfigPath $script:Config -NoApi -Apply -Force -Confirm:$false *>&1 | Out-Null

            $info = Get-Content -LiteralPath (Join-Path $script:Staging 'alpha_mod\info.json') -Raw -Encoding UTF8 |
                    ConvertFrom-Json
            $info.version | Should -Be '1.5.0'
        }
    }

    Context 'rejecting a hostile or malformed archive' {

        It 'skips an archive with no .mod file and installs nothing from it' {
            $null = New-TestZip -Path (Join-Path $script:Downloads 'not-a-mod-1-0-0-1719200000.zip') -Entries @{
                'readme.txt' = 'nothing to see'
            }
            $before = @(Get-ChildItem -LiteralPath $script:Staging -Directory).Count

            & $script:Updater -ConfigPath $script:Config -NoApi -Apply -Confirm:$false *>&1 | Out-Null

            @(Get-ChildItem -LiteralPath $script:Staging -Directory).Count | Should -Be $before
        }

        It 'does not write outside the mods root for a traversal archive' {
            $escape = Join-Path $script:Root 'escaped.txt'
            $null = New-TestZip -Path (Join-Path $script:Downloads 'evil_mod-1-0-0-1719200001.zip') -Entries @{
                'evil_mod/evil_mod.mod'  = 'return {}'
                'evil_mod/info.json'     = '{"version":"1.0.0"}'
                'evil_mod/../../escaped.txt' = 'pwned'
            }

            & $script:Updater -ConfigPath $script:Config -NoApi -Apply -Confirm:$false *>&1 | Out-Null

            Test-Path -LiteralPath $escape | Should -BeFalse
        }

        It 'does not destroy an existing mod when its replacement archive is unsafe' {
            # alpha_mod must survive an archive that fails partway through extraction.
            $null = New-TestZip -Path (Join-Path $script:Downloads 'Alpha Mod-447-3-0-0-1719209950.zip') -Entries @{
                'alpha_mod/alpha_mod.mod'    = 'return {}'
                'alpha_mod/info.json'        = '{"version":"3.0.0"}'
                'alpha_mod/../../escaped.txt' = 'pwned'
            }

            & $script:Updater -ConfigPath $script:Config -NoApi -Apply -Confirm:$false *>&1 | Out-Null

            Test-Path (Join-Path $script:Staging 'alpha_mod\alpha_mod.mod') | Should -BeTrue
            @(Get-ChildItem -LiteralPath $script:Staging -Directory -Force |
              Where-Object { $_.Name -like '.staging-*' }) | Should -BeNullOrEmpty
        }
    }

    Context 'no archives at all' {

        It 'does nothing and says so' {
            Get-ChildItem -LiteralPath $script:Downloads -File | Remove-Item -Force
            $before = Get-TreeFingerprint -Path $script:Staging

            $out = & $script:Updater -ConfigPath $script:Config -NoApi -Apply -Confirm:$false *>&1 | Out-String

            $out | Should -Match 'Nothing to do'
            Get-TreeFingerprint -Path $script:Staging | Should -Be $before
        }
    }
}
