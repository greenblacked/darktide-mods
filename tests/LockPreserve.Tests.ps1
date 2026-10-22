<#
    Regenerating the lockfile must not quietly throw away what the committed one says.

    Three ways it used to:

      * 'sync -Apply' regenerated with -NoHash, so every contentSha256 - the field
        that shows an installed mod has drifted - came back null;
      * neither 'sync' nor 'lock' passes -Name, so the parameter default replaced the
        loadout's own name on every run;
      * 'sync -Apply' read $LASTEXITCODE after the deploy, where robocopy leaves 1
        ('files copied') after a good deploy, so any deploy that copied something
        stopped the lockfile refresh with 'finished with problems'.

    And a regeneration printed nothing about what it changed.

    Where these run:

      * 'New-ModpackLock over an existing lockfile' needs no game folder and holds
        up off Windows.
      * 'darktide.ps1 sync and the lockfile' runs a copy of the scripts in the
        sandbox, because sync writes the lockfile beside darktide.ps1 and the
        committed one must stay untouched. Its 'the deploy's success signal' context
        swaps in a stub deployer, so it exercises the dispatcher's own logic anywhere.
        The other contexts run the real deploy, which needs Windows (robocopy, and a
        game-folder check that splits on '\'), and are skipped elsewhere. Skipped
        rather than left to fail like the rest of the suite does off Windows: this
        file matches '-Path Lock', which the Linux and macOS CI jobs run and require
        to pass.
#>

# Evaluated during discovery, which is when Pester reads the -Skip below. Same test
# as Invoke-Tests.ps1, and safe under Windows PowerShell 5.1, which has no $IsWindows.
# (-or and -and share one precedence level in PowerShell, hence the inner brackets.)
$NotWindows = -not (($PSVersionTable.PSEdition -eq 'Desktop') -or ((Test-Path Variable:IsWindows) -and $IsWindows))

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:Dispatcher = Join-Path $script:RepoRoot 'darktide.ps1'
    $script:Locker     = Join-Path $script:RepoRoot 'New-ModpackLock.ps1'
    $script:KingsName  = "King's Darktide loadout"

    function Read-Lock {
        param([Parameter(Mandatory)][string] $Path)
        Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    function Get-FileStamp {
        <# Content and write time: equal stamps mean the file was not rewritten. #>
        param([Parameter(Mandatory)][string] $Path)
        if (-not (Test-Path -LiteralPath $Path)) { return '<missing>' }
        $item = Get-Item -LiteralPath $Path
        "$((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash)|$($item.LastWriteTimeUtc.Ticks)"
    }

    function Set-InfoVersion {
        param([Parameter(Mandatory)][string] $ModFolder, [Parameter(Mandatory)][string] $Version)
        $name = Split-Path -Leaf $ModFolder
        @{ name = $name; version = $Version } | ConvertTo-Json |
            Set-Content -LiteralPath (Join-Path $ModFolder 'info.json') -Encoding UTF8
    }
}

Describe 'New-ModpackLock over an existing lockfile' {

    BeforeEach {
        $script:Root    = New-TestSandbox
        $script:Staging = New-FakeStaging -Root $script:Root -Mods @('alpha_mod', 'beta_mod')
        $script:Out     = Join-Path $script:Root 'test.lock.json'
        # Never the repository's mods-map.json: absent means an empty map.
        $script:Map     = Join-Path $script:Root 'mods-map.json'
    }

    AfterEach {
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'the loadout name' {

        It 'keeps the existing name when -Name is not passed' {
            & $script:Locker -ModsRoot $script:Staging -OutFile $script:Out -MapPath $script:Map -Name $script:KingsName *>&1 | Out-Null

            $out = & $script:Locker -ModsRoot $script:Staging -OutFile $script:Out -MapPath $script:Map *>&1 | Out-String

            (Read-Lock $script:Out).name | Should -Be $script:KingsName
            $out | Should -Match 'kept from the existing lockfile'
        }

        It 'uses -Name when it is passed' {
            & $script:Locker -ModsRoot $script:Staging -OutFile $script:Out -MapPath $script:Map -Name $script:KingsName *>&1 | Out-Null

            & $script:Locker -ModsRoot $script:Staging -OutFile $script:Out -MapPath $script:Map -Name 'Renamed loadout' *>&1 | Out-Null

            (Read-Lock $script:Out).name | Should -Be 'Renamed loadout'
        }

        It 'uses -Name even when it is the default text' {
            # Bound, not compared: passing the default on purpose is still a choice.
            & $script:Locker -ModsRoot $script:Staging -OutFile $script:Out -MapPath $script:Map -Name $script:KingsName *>&1 | Out-Null

            & $script:Locker -ModsRoot $script:Staging -OutFile $script:Out -MapPath $script:Map -Name 'Darktide loadout' *>&1 | Out-Null

            (Read-Lock $script:Out).name | Should -Be 'Darktide loadout'
        }

        It 'gives a new lockfile the default name' {
            & $script:Locker -ModsRoot $script:Staging -OutFile $script:Out -MapPath $script:Map -NoHash *>&1 | Out-Null

            (Read-Lock $script:Out).name | Should -Be 'Darktide loadout'
        }

        It 'uses the default when the existing lockfile has no usable name' {
            '{"schemaVersion":1,"name":"   ","mods":[]}' | Set-Content -LiteralPath $script:Out -Encoding UTF8

            & $script:Locker -ModsRoot $script:Staging -OutFile $script:Out -MapPath $script:Map -NoHash *>&1 | Out-Null

            (Read-Lock $script:Out).name | Should -Be 'Darktide loadout'
        }

        It 'replaces an unreadable lockfile and says so' {
            'this is { not json' | Set-Content -LiteralPath $script:Out -Encoding UTF8

            $out = & $script:Locker -ModsRoot $script:Staging -OutFile $script:Out -MapPath $script:Map -NoHash *>&1 | Out-String

            $out | Should -Match 'could not be read'
            $lock = Read-Lock $script:Out
            $lock.name     | Should -Be 'Darktide loadout'
            $lock.modCount | Should -Be 3
        }
    }

    Context 'the change summary' {

        It 'prints nothing to compare on a first write' {
            $out = & $script:Locker -ModsRoot $script:Staging -OutFile $script:Out -MapPath $script:Map -NoHash *>&1 | Out-String

            $out | Should -Not -Match 'Changes vs the existing lockfile'
        }

        It 'reports no changes when nothing changed' {
            & $script:Locker -ModsRoot $script:Staging -OutFile $script:Out -MapPath $script:Map *>&1 | Out-Null

            $out = & $script:Locker -ModsRoot $script:Staging -OutFile $script:Out -MapPath $script:Map *>&1 | Out-String

            $out | Should -Match 'Changes vs the existing lockfile: 0 added, 0 removed, 0 version changed, 0 content changed\.'
        }

        It 'counts mods added, removed and changed in version and content' {
            & $script:Locker -ModsRoot $script:Staging -OutFile $script:Out -MapPath $script:Map *>&1 | Out-Null

            Remove-Item -LiteralPath (Join-Path $script:Staging 'beta_mod') -Recurse -Force
            $gamma = Join-Path $script:Staging 'gamma_mod'
            [void][System.IO.Directory]::CreateDirectory($gamma)
            Set-InfoVersion -ModFolder $gamma -Version '1.0.0'
            Set-InfoVersion -ModFolder (Join-Path $script:Staging 'alpha_mod') -Version '2.0.0'

            $out = & $script:Locker -ModsRoot $script:Staging -OutFile $script:Out -MapPath $script:Map *>&1 | Out-String

            $out | Should -Match 'Changes vs the existing lockfile: 1 added, 1 removed, 1 version changed, 1 content changed\.'
        }

        It 'prints the summary before the lockfile is written' {
            & $script:Locker -ModsRoot $script:Staging -OutFile $script:Out -MapPath $script:Map -NoHash *>&1 | Out-Null

            $out = & $script:Locker -ModsRoot $script:Staging -OutFile $script:Out -MapPath $script:Map -NoHash *>&1 | Out-String

            $out.IndexOf('Changes vs the existing lockfile') | Should -BeGreaterThan -1
            $out.IndexOf('Changes vs the existing lockfile') | Should -BeLessThan $out.IndexOf('Wrote ')
        }

        It 'warns when -NoHash writes null over existing hashes' {
            & $script:Locker -ModsRoot $script:Staging -OutFile $script:Out -MapPath $script:Map *>&1 | Out-Null
            @((Read-Lock $script:Out).mods | Where-Object { -not $_.contentSha256 }).Count | Should -Be 0

            $out = & $script:Locker -ModsRoot $script:Staging -OutFile $script:Out -MapPath $script:Map -NoHash *>&1 | Out-String

            $out | Should -Match 'Changes vs the existing lockfile: 0 added, 0 removed, 0 version changed\.'
            $out | Should -Match '-NoHash: 3 existing contentSha256 value\(s\) will be written as null'
        }
    }
}

Describe 'darktide.ps1 sync and the lockfile' {

    BeforeEach {
        # The dispatcher is a plain [CmdletBinding()]; the scripts it calls inherit this.
        $script:PrevConfirm = $ConfirmPreference
        $ConfirmPreference  = 'None'

        $script:Root = New-TestSandbox

        # sync writes darktide-modpack.lock.json beside darktide.ps1, so run a copy.
        $script:ToolDir = Join-Path $script:Root 'tool'
        [void][System.IO.Directory]::CreateDirectory($script:ToolDir)
        foreach ($s in @(Get-ChildItem -LiteralPath $script:RepoRoot -Filter '*.ps1' -File)) {
            Copy-Item -LiteralPath $s.FullName -Destination (Join-Path $script:ToolDir $s.Name)
        }
        $script:ToolDispatcher = Join-Path $script:ToolDir 'darktide.ps1'
        $script:ToolLocker     = Join-Path $script:ToolDir 'New-ModpackLock.ps1'
        $script:LockPath       = Join-Path $script:ToolDir 'darktide-modpack.lock.json'

        $script:Game     = New-FakeGameFolder -Root $script:Root
        $script:GameMods = Join-Path $script:Game 'mods'
        $script:Staging  = New-FakeStaging -Root $script:Root -Mods @('alpha_mod', 'beta_mod')
        $script:Config   = New-TestConfig -Root $script:Root -StagingMods $script:Staging -GamePath $script:Game

        # A committed lockfile as 'sync -NoHash' used to leave it: named, hashes null.
        & $script:ToolLocker -ModsRoot $script:Staging -Name $script:KingsName -NoHash *>&1 | Out-Null
    }

    AfterEach {
        $ConfirmPreference = $script:PrevConfirm
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'starts from the copy, not the committed lockfile' {
        Test-Path -LiteralPath $script:LockPath | Should -BeTrue
        (Read-Lock $script:LockPath).name | Should -Be $script:KingsName
    }

    Context "the deploy's success signal" {

        # A stand-in for Deploy-DarktideMods.ps1 that ends the way the real one does in
        # each case, without needing a game folder or robocopy.
        BeforeAll {
            function Set-StubDeployer {
                param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Body)
                $text = @(
                    '[CmdletBinding()]'
                    'param([string] $ConfigPath, [switch] $Apply, [switch] $Mirror, [switch] $InstallLoader, [switch] $RunToggle, [switch] $Force)'
                    $Body
                ) -join "`n"
                Set-Content -LiteralPath $Path -Value $text -Encoding UTF8
            }
        }

        BeforeEach {
            $script:StubDeployer = Join-Path $script:ToolDir 'Deploy-DarktideMods.ps1'
        }

        It 'refreshes the lockfile when the deploy says Deploy OK with robocopy''s 1 still set' {
            # Exactly what a good deploy that copied files leaves behind.
            Set-StubDeployer -Path $script:StubDeployer -Body @'
$global:LASTEXITCODE = 1
Write-Host 'Deploy OK.' -ForegroundColor Green
Write-Host 'Undo this deploy:'
'@
            { & $script:ToolDispatcher sync -ConfigPath $script:Config -Apply *>&1 | Out-Null } | Should -Not -Throw

            $lock = Read-Lock $script:LockPath
            $lock.name | Should -Be $script:KingsName
            foreach ($m in @($lock.mods)) {
                $m.contentSha256 | Should -Match '^[0-9a-f]{64}$'
            }
            $LASTEXITCODE | Should -Be 0
        }

        It 'does not refresh the lockfile when the deploy ends in exit 1' {
            Set-StubDeployer -Path $script:StubDeployer -Body @'
Write-Host 'Deploy finished with problems - see above.' -ForegroundColor Red
exit 1
'@
            $before = Get-FileStamp -Path $script:LockPath

            { & $script:ToolDispatcher sync -ConfigPath $script:Config -Apply *>&1 | Out-Null } |
                Should -Throw -ExpectedMessage '*lockfile not refreshed*'

            Get-FileStamp -Path $script:LockPath | Should -Be $before
        }

        It 'does not refresh the lockfile when the deploy never says Deploy OK' {
            # Fails closed: no success line means no refresh, whatever the exit code.
            Set-StubDeployer -Path $script:StubDeployer -Body @'
$global:LASTEXITCODE = 0
Write-Host 'something else entirely'
'@
            $before = Get-FileStamp -Path $script:LockPath

            { & $script:ToolDispatcher sync -ConfigPath $script:Config -Apply *>&1 | Out-Null } |
                Should -Throw -ExpectedMessage '*lockfile not refreshed*'

            Get-FileStamp -Path $script:LockPath | Should -Be $before
        }

        It 'does not refresh the lockfile when the deploy throws' {
            Set-StubDeployer -Path $script:StubDeployer -Body "throw 'Darktide.exe is running'"
            $before = Get-FileStamp -Path $script:LockPath

            { & $script:ToolDispatcher sync -ConfigPath $script:Config -Apply *>&1 | Out-Null } |
                Should -Throw -ExpectedMessage '*Darktide.exe is running*'

            Get-FileStamp -Path $script:LockPath | Should -Be $before
        }

        It 'does not throw on a dry run that leaves robocopy''s 1 behind, and writes no lockfile' {
            Set-StubDeployer -Path $script:StubDeployer -Body @'
$global:LASTEXITCODE = 1
Write-Host 'Dry run complete. Nothing was written. Re-run with -Apply.'
'@
            $before = Get-FileStamp -Path $script:LockPath

            { & $script:ToolDispatcher sync -ConfigPath $script:Config *>&1 | Out-Null } | Should -Not -Throw

            Get-FileStamp -Path $script:LockPath | Should -Be $before
        }

        It 'does not read a stale exit code from earlier in the session as an update failure' {
            Set-StubDeployer -Path $script:StubDeployer -Body "Write-Host 'Deploy OK.'"
            $global:LASTEXITCODE = 1

            { & $script:ToolDispatcher sync -ConfigPath $script:Config -Apply *>&1 | Out-Null } | Should -Not -Throw
        }
    }

    Context 'a deploy that copies files' -Skip:$NotWindows {

        It 'completes sync -Apply without throwing' {
            Test-Path -LiteralPath $script:GameMods | Should -BeFalse
            # Left over from something earlier in the session; must not read as a failure.
            $global:LASTEXITCODE = 1

            { & $script:ToolDispatcher sync -ConfigPath $script:Config -Apply *>&1 | Out-Null } | Should -Not -Throw

            Test-Path -LiteralPath (Join-Path $script:GameMods 'alpha_mod\alpha_mod.mod') | Should -BeTrue
        }

        It 'refreshes the lockfile with a content hash for every mod' {
            & $script:ToolDispatcher sync -ConfigPath $script:Config -Apply *>&1 | Out-Null

            $lock = Read-Lock $script:LockPath
            @($lock.mods).Count | Should -Be 3
            foreach ($m in @($lock.mods)) {
                $m.contentSha256 | Should -Match '^[0-9a-f]{64}$'
            }
        }

        It 'keeps the loadout name' {
            & $script:ToolDispatcher sync -ConfigPath $script:Config -Apply *>&1 | Out-Null

            (Read-Lock $script:LockPath).name | Should -Be $script:KingsName
        }

        It 'prints the change summary for the lockfile it replaces' {
            $out = & $script:ToolDispatcher sync -ConfigPath $script:Config -Apply *>&1 | Out-String

            $out | Should -Match 'Deploy OK\.'
            $out | Should -Match 'Changes vs the existing lockfile: 0 added, 0 removed, 0 version changed'
        }

        It 'does not leave the deploy exit code behind for the caller' {
            & $script:ToolDispatcher sync -ConfigPath $script:Config -Apply *>&1 | Out-Null

            $LASTEXITCODE | Should -Be 0
        }

        It 'records a mod that update installed on the way' {
            # Windows-only in practice: installing an archive resolves '\' paths.
            $downloads = Join-Path $script:Root 'downloads'
            $null = New-TestZip -Path (Join-Path $downloads 'Alpha Mod-447-2-0-0-1719209900.zip') -Entries @{
                'alpha_mod/alpha_mod.mod'   = 'return { version = 2 }'
                'alpha_mod/info.json'       = '{"name":"Alpha Mod","version":"2.0.0"}'
                'alpha_mod/scripts/new.lua' = '-- added in 2.0.0'
            }

            $out = & $script:ToolDispatcher sync -ConfigPath $script:Config -Apply *>&1 | Out-String

            $alpha = @((Read-Lock $script:LockPath).mods | Where-Object { $_.folder -eq 'alpha_mod' })[0]
            $alpha.version       | Should -Be '2.0.0'
            $alpha.contentSha256 | Should -Match '^[0-9a-f]{64}$'
            $out | Should -Match '0 added, 0 removed, 1 version changed'
        }
    }

    Context 'a deploy that fails' -Skip:$NotWindows {

        It 'does not refresh the lockfile when the post-checks find problems' {
            # A load-order entry with no folder behind it: the deploy copies, then ends in 'exit 1'.
            Add-Content -LiteralPath (Join-Path $script:Staging 'mod_load_order.txt') -Value 'ghost_mod' -Encoding UTF8
            $before = Get-FileStamp -Path $script:LockPath

            { & $script:ToolDispatcher sync -ConfigPath $script:Config -Apply *>&1 | Out-Null } |
                Should -Throw -ExpectedMessage '*lockfile not refreshed*'

            Get-FileStamp -Path $script:LockPath | Should -Be $before
        }

        It 'does not refresh the lockfile when the deploy refuses to start' {
            $notGame = Join-Path $script:Root 'not\deep\enough_but_no_markers'
            [void][System.IO.Directory]::CreateDirectory($notGame)
            $cfg = New-TestConfig -Root $script:Root -StagingMods $script:Staging -GamePath $notGame
            $before = Get-FileStamp -Path $script:LockPath

            { & $script:ToolDispatcher sync -ConfigPath $cfg -Apply *>&1 | Out-Null } | Should -Throw

            Get-FileStamp -Path $script:LockPath | Should -Be $before
        }
    }

    Context 'an update that fails' {

        # The updater refuses before the deploy runs, so this needs no game folder.
        It 'does not deploy or refresh when the update step fails' {
            $bad = Join-Path $script:Root 'not_a_mods_folder'
            [void][System.IO.Directory]::CreateDirectory($bad)
            $cfg = New-TestConfig -Root $script:Root -StagingMods $bad -GamePath $script:Game
            $before = Get-FileStamp -Path $script:LockPath

            { & $script:ToolDispatcher sync -ConfigPath $cfg -Apply *>&1 | Out-Null } | Should -Throw

            Test-Path -LiteralPath $script:GameMods | Should -BeFalse
            Get-FileStamp -Path $script:LockPath | Should -Be $before
        }
    }

    Context 'without -Apply' -Skip:$NotWindows {

        BeforeEach {
            # Deployed once, then staging moves on, so the deploy's robocopy /L has
            # something to report and leaves 1 behind.
            & $script:ToolDispatcher deploy -ConfigPath $script:Config -Apply *>&1 | Out-Null
            Set-Content -LiteralPath (Join-Path $script:Staging 'alpha_mod\extra.lua') -Value '-- new' -Encoding UTF8
        }

        It 'does not throw when the deploy has changes pending' {
            { & $script:ToolDispatcher sync -ConfigPath $script:Config *>&1 | Out-Null } | Should -Not -Throw
        }

        It 'writes nothing to staging, the game or the lockfile' {
            $staging = Get-TreeFingerprint -Path $script:Staging
            $game    = Get-TreeFingerprint -Path $script:GameMods
            $lock    = Get-FileStamp -Path $script:LockPath

            & $script:ToolDispatcher sync -ConfigPath $script:Config *>&1 | Out-Null

            Get-TreeFingerprint -Path $script:Staging  | Should -Be $staging
            Get-TreeFingerprint -Path $script:GameMods | Should -Be $game
            Get-FileStamp -Path $script:LockPath       | Should -Be $lock
        }
    }
}
