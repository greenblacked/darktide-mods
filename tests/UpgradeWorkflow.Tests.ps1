<#
    The workflow a user actually runs when a mod author publishes a new version,
    end to end and in order, through darktide.ps1 rather than the scripts underneath.

    Every script here is well covered on its own. What was not covered is the
    sequence, and the sequence is where the design lives: staging is the source of
    truth and the game folder is a derived mirror of it. That shows up as two
    properties nothing else asserts -

      * 'update -Apply' changes staging and leaves the game folder alone, so the new
        version is not live until you deploy it;
      * 'rollback -Apply' puts staging back and also leaves the game folder alone, so
        an undo is not live until you deploy either.

    Both look like bugs if you have not read the design, which is exactly why they
    are worth pinning down.

    Windows-only, like the rest of the suite: the install path resolves archive
    entries with '\' separators on purpose. See the validate-change skill.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:Dispatcher = Join-Path $script:RepoRoot 'darktide.ps1'
    $script:Locker     = Join-Path $script:RepoRoot 'New-ModpackLock.ps1'

    # The updater writes a CSV report beside itself; leave the repo as we found it.
    $script:PreExistingReports = @(Get-ChildItem -LiteralPath $script:RepoRoot -Filter 'report-*.csv' -File `
                                   -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })

    function Get-InstalledVersion {
        param([Parameter(Mandatory)][string] $ModFolder)
        $info = Join-Path $ModFolder 'info.json'
        if (-not (Test-Path -LiteralPath $info)) { return $null }
        (Get-Content -LiteralPath $info -Raw -Encoding UTF8 | ConvertFrom-Json).version
    }
}

AfterAll {
    Get-ChildItem -LiteralPath $script:RepoRoot -Filter 'report-*.csv' -File -ErrorAction SilentlyContinue |
        Where-Object { $script:PreExistingReports -notcontains $_.Name } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

Describe 'Upgrading one mod, start to finish' {

    BeforeEach {
        # darktide.ps1 declares a plain [CmdletBinding()], so it takes no -Confirm.
        # The scripts it calls do declare SupportsShouldProcess, and they inherit this
        # preference - which is how the dispatcher runs unattended.
        $script:PrevConfirm = $ConfirmPreference
        $ConfirmPreference  = 'None'

        $script:Root    = New-TestSandbox
        $script:Game    = New-FakeGameFolder -Root $script:Root
        $script:Staging = New-FakeStaging -Root $script:Root -Mods @('alpha_mod', 'beta_mod')
        $script:Config  = New-TestConfig -Root $script:Root -StagingMods $script:Staging -GamePath $script:Game
        $script:GameMods = Join-Path $script:Game 'mods'

        # The loadout is already deployed and running at 1.0.0.
        & $script:Dispatcher deploy -ConfigPath $script:Config -Apply *>&1 | Out-Null

        # The author publishes 2.0.0 and the user downloads it, keeping the stock
        # Nexus filename - that is what identifies the mod with no API key.
        $null = New-TestZip -Path (Join-Path $script:Root 'downloads/Alpha Mod-447-2-0-0-1719209900.zip') -Entries @{
            'alpha_mod/alpha_mod.mod'   = 'return { version = 2 }'
            'alpha_mod/info.json'       = '{"name":"Alpha Mod","version":"2.0.0"}'
            'alpha_mod/scripts/new.lua' = '-- added in 2.0.0'
        }

        $script:StagedMod = Join-Path $script:Staging 'alpha_mod'
        $script:LiveMod   = Join-Path $script:GameMods 'alpha_mod'
    }

    AfterEach {
        $ConfirmPreference = $script:PrevConfirm
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'starts from a deployed 1.0.0 in both staging and the game folder' {
        Get-InstalledVersion $script:StagedMod | Should -Be '1.0.0'
        Get-InstalledVersion $script:LiveMod   | Should -Be '1.0.0'
    }

    Context 'step 1 - update, without -Apply' {

        It 'reports the upgrade it would make' {
            $out = & $script:Dispatcher update -ConfigPath $script:Config *>&1 | Out-String

            $out | Should -Match 'alpha_mod'
            $out | Should -Match 'NEWER'
            $out | Should -Match '2\.0\.0'
        }

        It 'writes nothing, in staging or in the game' {
            $stagingBefore = Get-TreeFingerprint -Path $script:Staging
            $gameBefore    = Get-TreeFingerprint -Path $script:GameMods

            & $script:Dispatcher update -ConfigPath $script:Config *>&1 | Out-Null

            Get-TreeFingerprint -Path $script:Staging  | Should -Be $stagingBefore
            Get-TreeFingerprint -Path $script:GameMods | Should -Be $gameBefore
        }
    }

    Context 'step 2 - update -Apply' {

        BeforeEach {
            & $script:Dispatcher update -ConfigPath $script:Config -Apply *>&1 | Out-Null
        }

        It 'installs the new version into staging' {
            Get-InstalledVersion $script:StagedMod | Should -Be '2.0.0'
            Test-Path -LiteralPath (Join-Path $script:StagedMod 'scripts\new.lua') | Should -BeTrue
        }

        It 'backs the old version up before replacing it' {
            $sets = @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'mod_backups') -Directory)
            $sets.Count | Should -BeGreaterThan 0
            @(Get-ChildItem -LiteralPath $sets[0].FullName -Filter '*.zip' -File).Count |
                Should -BeGreaterThan 0
        }

        It 'leaves the game folder still running the old version' {
            # Not a bug. Staging is the source of truth; the game folder is a mirror
            # produced by deploy, so nothing is live until the next step.
            Get-InstalledVersion $script:LiveMod | Should -Be '1.0.0'
        }

        It 'reports the mod as already installed when run again' {
            $out = & $script:Dispatcher update -ConfigPath $script:Config *>&1 | Out-String
            $out | Should -Match 'SAME'
        }

        It 'changes nothing on a second apply' {
            $before = Get-TreeFingerprint -Path $script:Staging

            & $script:Dispatcher update -ConfigPath $script:Config -Apply *>&1 | Out-Null

            Get-TreeFingerprint -Path $script:Staging | Should -Be $before
        }
    }

    Context 'step 3 - deploy -Apply' {

        BeforeEach {
            & $script:Dispatcher update -ConfigPath $script:Config -Apply *>&1 | Out-Null
            & $script:Dispatcher deploy -ConfigPath $script:Config -Apply *>&1 | Out-Null
        }

        It 'carries the new version into the game folder' {
            Get-InstalledVersion $script:LiveMod | Should -Be '2.0.0'
            Test-Path -LiteralPath (Join-Path $script:LiveMod 'scripts\new.lua') | Should -BeTrue
        }

        It 'leaves the other mods alone' {
            Get-InstalledVersion (Join-Path $script:GameMods 'beta_mod') | Should -Be '1.0.0'
        }

        It 'takes a deploy backup that restore can undo' {
            @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'deploy_backups') -Filter '*.zip' -File).Count |
                Should -BeGreaterThan 0
        }
    }

    Context 'step 4 - lock' {

        It 'records the new version in the manifest' {
            & $script:Dispatcher update -ConfigPath $script:Config -Apply *>&1 | Out-Null

            $out = Join-Path $script:Root 'after.lock.json'
            & $script:Locker -ModsRoot $script:Staging -OutFile $out -NoHash *>&1 | Out-Null

            $lock = Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json
            $entry = @($lock.mods | Where-Object { $_.folder -eq 'alpha_mod' })[0]
            $entry.version | Should -Be '2.0.0'
        }
    }

    Context 'when the new version turns out to be bad' {

        BeforeEach {
            & $script:Dispatcher update -ConfigPath $script:Config -Apply *>&1 | Out-Null
            & $script:Dispatcher deploy -ConfigPath $script:Config -Apply *>&1 | Out-Null
        }

        It 'lists the backup set without writing when -Apply is omitted' {
            & $script:Dispatcher rollback -ConfigPath $script:Config *>&1 | Out-Null
            Get-InstalledVersion $script:StagedMod | Should -Be '2.0.0'
        }

        It 'puts staging back to the old version with -Apply' {
            & $script:Dispatcher rollback -ConfigPath $script:Config -Apply *>&1 | Out-Null
            Get-InstalledVersion $script:StagedMod | Should -Be '1.0.0'
        }

        It 'still leaves the game on the new version until it is redeployed' {
            # The mirror of step 2: rollback is a staging operation. Undoing what the
            # game is running takes a deploy, or 'restore' from the deploy backup.
            & $script:Dispatcher rollback -ConfigPath $script:Config -Apply *>&1 | Out-Null
            Get-InstalledVersion $script:LiveMod | Should -Be '2.0.0'
        }

        It 'returns the game to the old version once redeployed' {
            & $script:Dispatcher rollback -ConfigPath $script:Config -Apply *>&1 | Out-Null
            & $script:Dispatcher deploy   -ConfigPath $script:Config -Apply *>&1 | Out-Null

            Get-InstalledVersion $script:LiveMod | Should -Be '1.0.0'
        }
    }
}
