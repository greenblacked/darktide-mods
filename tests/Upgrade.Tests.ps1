<#
    Tests for Invoke-DarktideUpgrade.ps1, the 'upgrade' verb: one plan, one
    question, then update, deploy and the lockfile.

    The question is the only thing standing between the plan and the game folder,
    so most of this file is about what happens on each answer: a no writes nothing,
    a yes (or -Yes) does the whole loop and says how to undo it, and every way the
    loop can fail stops before the step after it. The answer is injected through the
    hidden -ConfirmWith hook; nothing here reads stdin.

    Windows-only like the rest of the suite: the deploy underneath shells out to
    robocopy and checks '\'-separated paths. See the validate-change skill.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:Dispatcher = Join-Path $script:RepoRoot 'darktide.ps1'
    $script:Upgrader   = Join-Path $script:RepoRoot 'Invoke-DarktideUpgrade.ps1'
    $script:Deployer   = Join-Path $script:RepoRoot 'Deploy-DarktideMods.ps1'

    # The updater writes a CSV report beside itself; leave the repo as we found it.
    $script:PreExistingReports = @(Get-ChildItem -LiteralPath $script:RepoRoot -Filter 'report-*.csv' -File `
                                   -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })

    function Get-InstalledVersion {
        param([Parameter(Mandatory)][string] $ModFolder)
        $info = Join-Path $ModFolder 'info.json'
        if (-not (Test-Path -LiteralPath $info)) { return $null }
        (Get-Content -LiteralPath $info -Raw -Encoding UTF8 | ConvertFrom-Json).version
    }

    function Get-AllFingerprints {
        # Everything an upgrade could write: staging, the game, both backup roots.
        @(
            (Get-TreeFingerprint -Path $script:Staging),
            (Get-TreeFingerprint -Path $script:GameMods),
            (Get-TreeFingerprint -Path $script:StagingBackups),
            (Get-TreeFingerprint -Path $script:GameBackups)
        ) -join "`n----`n"
    }

    function Invoke-DispatcherNonInteractive {
        <#
            Runs darktide.ps1 in a separate -NonInteractive host, the way a scheduled
            task would. If upgrade ever reached Read-Host here it would refuse rather
            than hang the suite, which is the property under test.
        #>
        param([Parameter(Mandatory)][string] $ArgumentText)

        $exe  = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $disp = $script:Dispatcher -replace "'", "''"
        $cmd  = "try { & '$disp' $ArgumentText; exit `$LASTEXITCODE } " +
                "catch { Write-Output ('THROWN: ' + `$_.Exception.Message); exit 1 }"
        $out  = & $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $cmd
        [pscustomobject]@{ Output = (@($out) -join "`n"); ExitCode = $LASTEXITCODE }
    }
}

AfterAll {
    Get-ChildItem -LiteralPath $script:RepoRoot -Filter 'report-*.csv' -File -ErrorAction SilentlyContinue |
        Where-Object { $script:PreExistingReports -notcontains $_.Name } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

Describe 'upgrade' {

    BeforeEach {
        $script:PrevConfirm = $ConfirmPreference
        $ConfirmPreference  = 'None'

        $script:Root     = New-TestSandbox
        $script:Game     = New-FakeGameFolder -Root $script:Root
        $script:Staging  = New-FakeStaging -Root $script:Root -Mods @('alpha_mod', 'beta_mod')
        $script:Config   = New-TestConfig -Root $script:Root -StagingMods $script:Staging -GamePath $script:Game
        $script:GameMods = Join-Path $script:Game 'mods'
        $script:Downloads      = Join-Path $script:Root 'downloads'
        $script:StagingBackups = Join-Path $script:Root 'mod_backups'
        $script:GameBackups    = Join-Path $script:Root 'deploy_backups'
        # Never the repository's own lockfile.
        $script:Lock     = Join-Path $script:Root 'test.lock.json'

        # Already deployed and running at 1.0.0.
        & $script:Deployer -ConfigPath $script:Config -Apply -Confirm:$false *>&1 | Out-Null

        $script:AlphaZip = New-TestZip -Path (Join-Path $script:Downloads 'Alpha Mod-447-2-0-0-1719209900.zip') -Entries @{
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

    It 'starts from a deployed 1.0.0 with no backups yet' {
        Get-InstalledVersion (Join-Path $script:GameMods 'alpha_mod') | Should -Be '1.0.0'
        Test-Path -LiteralPath $script:StagingBackups | Should -BeFalse
        Test-Path -LiteralPath $script:GameBackups    | Should -BeFalse
    }

    Context 'the plan, and answering no' {

        It 'shows the mod, both versions and that the game folder will change' {
            $out = & $script:Upgrader -ConfigPath $script:Config -LockFile $script:Lock -ConfirmWith { 'n' } *>&1 |
                   Out-String

            $out | Should -Match 'alpha_mod\s+1\.0\.0 -> 2\.0\.0'
            $out | Should -Match 'will be synced once the staging changes above are made'
        }

        It 'writes nothing to staging, the game or either backup folder' {
            $before = Get-AllFingerprints

            $out = & $script:Upgrader -ConfigPath $script:Config -LockFile $script:Lock -ConfirmWith { 'n' } *>&1 |
                   Out-String

            Get-AllFingerprints | Should -Be $before
            Test-Path -LiteralPath $script:Lock | Should -BeFalse
            $out | Should -Match 'Nothing was written'
            $LASTEXITCODE | Should -Be 0
        }

        It 'treats an empty answer as no' {
            $before = Get-AllFingerprints

            & $script:Upgrader -ConfigPath $script:Config -LockFile $script:Lock -ConfirmWith { '' } *>&1 | Out-Null

            Get-AllFingerprints | Should -Be $before
            Get-InstalledVersion (Join-Path $script:Staging 'alpha_mod') | Should -Be '1.0.0'
        }

        It 'shows the plan under -WhatIf without asking or writing' {
            $before = Get-AllFingerprints

            $out = & $script:Upgrader -ConfigPath $script:Config -LockFile $script:Lock -WhatIf `
                       -ConfirmWith { throw 'should not have asked' } *>&1 | Out-String

            Get-AllFingerprints | Should -Be $before
            $out | Should -Match 'alpha_mod'
            $out | Should -Match 'What if'
        }
    }

    Context 'applying' {

        It 'applies with -Yes, without asking' {
            $out = & $script:Upgrader -ConfigPath $script:Config -LockFile $script:Lock -Yes `
                       -ConfirmWith { throw 'should not have asked' } *>&1 | Out-String

            $LASTEXITCODE | Should -Be 0
            Get-InstalledVersion (Join-Path $script:Staging 'alpha_mod')  | Should -Be '2.0.0'
            Get-InstalledVersion (Join-Path $script:GameMods 'alpha_mod') | Should -Be '2.0.0'
            Test-Path -LiteralPath (Join-Path $script:GameMods 'alpha_mod\scripts\new.lua') | Should -BeTrue
            Get-InstalledVersion (Join-Path $script:GameMods 'beta_mod')  | Should -Be '1.0.0'
            $out | Should -Match 'Start the game'
        }

        It 'applies on a y answer' {
            & $script:Upgrader -ConfigPath $script:Config -LockFile $script:Lock -ConfirmWith { 'y' } *>&1 | Out-Null

            Get-InstalledVersion (Join-Path $script:GameMods 'alpha_mod') | Should -Be '2.0.0'
        }

        It 'names the backup set and the game backup it made, with the commands that undo them' {
            $out = & $script:Upgrader -ConfigPath $script:Config -LockFile $script:Lock -Yes *>&1 | Out-String

            $sets = @(Get-ChildItem -LiteralPath $script:StagingBackups -Directory)
            $zips = @(Get-ChildItem -LiteralPath $script:GameBackups -Filter 'gamemods-*.zip' -File)
            $sets.Count | Should -Be 1
            $zips.Count | Should -Be 1

            $out | Should -Match ([regex]::Escape("rollback -BackupSet '$($sets[0].Name)' -Apply"))
            $out | Should -Match ([regex]::Escape("restore -BackupSet '$($zips[0].Name)' -Apply"))
        }

        It 'regenerates the lockfile from the upgraded staging' {
            & $script:Upgrader -ConfigPath $script:Config -LockFile $script:Lock -Yes *>&1 | Out-Null

            $lock = Get-Content -LiteralPath $script:Lock -Raw -Encoding UTF8 | ConvertFrom-Json
            @($lock.mods | Where-Object { $_.folder -eq 'alpha_mod' })[0].version | Should -Be '2.0.0'
        }

        It 'installs only what the plan named, not an archive that arrived while it asked' {
            $late = Join-Path $script:Downloads 'Gamma Mod-512-1-0-0-1719209901.zip'
            & $script:Upgrader -ConfigPath $script:Config -LockFile $script:Lock -ConfirmWith {
                $null = New-TestZip -Path $late -Entries @{
                    'gamma_mod/gamma_mod.mod' = 'return {}'
                    'gamma_mod/info.json'     = '{"version":"1.0.0"}'
                }
                'y'
            } *>&1 | Out-Null

            Get-InstalledVersion (Join-Path $script:Staging 'alpha_mod') | Should -Be '2.0.0'
            Test-Path -LiteralPath (Join-Path $script:Staging 'gamma_mod') | Should -BeFalse
        }

        It 'deploys a staging change that needs no update' {
            Remove-Item -LiteralPath $script:AlphaZip -Force
            Set-Content -LiteralPath (Join-Path $script:Staging 'beta_mod\extra.lua') -Value '-- edited' -Encoding UTF8

            & $script:Upgrader -ConfigPath $script:Config -LockFile $script:Lock -Yes *>&1 | Out-Null

            Test-Path -LiteralPath (Join-Path $script:GameMods 'beta_mod\extra.lua') | Should -BeTrue
            Test-Path -LiteralPath $script:StagingBackups | Should -BeFalse
        }
    }

    Context 'nothing to do' {

        BeforeEach {
            Remove-Item -LiteralPath $script:AlphaZip -Force
        }

        It 'says so and exits 0 without asking' {
            $out = & $script:Upgrader -ConfigPath $script:Config -LockFile $script:Lock `
                       -ConfirmWith { throw 'should not have asked' } *>&1 | Out-String

            $LASTEXITCODE | Should -Be 0
            $out | Should -Match 'Nothing to do'
        }

        It 'writes nothing' {
            $before = Get-AllFingerprints

            & $script:Upgrader -ConfigPath $script:Config -LockFile $script:Lock -Yes *>&1 | Out-Null

            Get-AllFingerprints | Should -Be $before
            Test-Path -LiteralPath $script:Lock | Should -BeFalse
        }

        It 'also counts an archive that is already installed as nothing to do' {
            $null = New-TestZip -Path (Join-Path $script:Downloads 'Beta Mod-448-1-0-0-1719209900.zip') -Entries @{
                'beta_mod/beta_mod.mod' = 'return {}'
                'beta_mod/info.json'    = '{"version":"1.0.0"}'
            }

            $out = & $script:Upgrader -ConfigPath $script:Config -LockFile $script:Lock `
                       -ConfirmWith { throw 'should not have asked' } *>&1 | Out-String

            $out | Should -Match 'Nothing to do'
        }
    }

    Context 'when something goes wrong' {

        It 'does not deploy when the update step fails' {
            # beta installs fine; alpha's archive passes planning but is refused at
            # install (it tries to write outside the mod folder), so update exits 1.
            Remove-Item -LiteralPath $script:AlphaZip -Force
            $null = New-TestZip -Path (Join-Path $script:Downloads 'Alpha Mod-447-2-0-0-1719209900.zip') -Entries @{
                'alpha_mod/alpha_mod.mod'       = 'return {}'
                'alpha_mod/info.json'           = '{"version":"2.0.0"}'
                'alpha_mod/../../escaped.lua'   = '-- must never land'
            }
            $null = New-TestZip -Path (Join-Path $script:Downloads 'Beta Mod-448-2-0-0-1719209900.zip') -Entries @{
                'beta_mod/beta_mod.mod' = 'return {}'
                'beta_mod/info.json'    = '{"version":"2.0.0"}'
            }
            $gameBefore = Get-TreeFingerprint -Path $script:GameMods

            $out = & $script:Upgrader -ConfigPath $script:Config -LockFile $script:Lock -Yes *>&1 | Out-String

            $LASTEXITCODE | Should -Be 1
            $out | Should -Match 'not deploying'
            Get-TreeFingerprint -Path $script:GameMods | Should -Be $gameBefore
            Test-Path -LiteralPath $script:GameBackups | Should -BeFalse
            Test-Path -LiteralPath $script:Lock | Should -BeFalse
            Get-InstalledVersion (Join-Path $script:Staging 'alpha_mod') | Should -Be '1.0.0'
        }

        It 'warns at plan time while the game is running' {
            Mock Get-Process -ParameterFilter { $Name -eq 'Darktide' } { [pscustomobject]@{ Id = 4242; Name = 'Darktide' } }

            $out = & $script:Upgrader -ConfigPath $script:Config -LockFile $script:Lock -ConfirmWith { 'n' } *>&1 |
                   Out-String

            $out | Should -Match 'Darktide\.exe is running \(PID 4242\)'
            $out | Should -Match 'alpha_mod'
        }

        It 'refuses to apply while the game is running, and writes nothing' {
            Mock Get-Process -ParameterFilter { $Name -eq 'Darktide' } { [pscustomobject]@{ Id = 4242; Name = 'Darktide' } }
            $before = Get-AllFingerprints

            { & $script:Upgrader -ConfigPath $script:Config -LockFile $script:Lock -Yes *>&1 | Out-Null } |
                Should -Throw '*Darktide.exe is running*'

            Get-AllFingerprints | Should -Be $before
            Test-Path -LiteralPath $script:Lock | Should -BeFalse
        }

        It 'refuses with an error when there is no config' {
            { & $script:Upgrader -ConfigPath (Join-Path $script:Root 'missing.json') -Yes *>&1 | Out-Null } |
                Should -Throw '*No config*'
        }
    }

    Context 'through darktide.ps1' {

        It 'refuses in a non-interactive session without -Yes, and writes nothing' {
            $before = Get-AllFingerprints

            $r = Invoke-DispatcherNonInteractive -ArgumentText "upgrade -ConfigPath '$($script:Config)'"

            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'non-interactive'
            $r.Output | Should -Match '-Yes'
            Get-AllFingerprints | Should -Be $before
        }

        It 'exits 0 without asking when there is nothing to do' {
            Remove-Item -LiteralPath $script:AlphaZip -Force

            $r = Invoke-DispatcherNonInteractive -ArgumentText "upgrade -ConfigPath '$($script:Config)'"

            $r.ExitCode | Should -Be 0
            $r.Output | Should -Match 'Nothing to do'
        }
    }
}
