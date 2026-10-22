<#
    Tests for Switch-DarktideProfile.ps1 (the 'profile' verb).

    A profile is a saved staging mod_load_order.txt. Switching rewrites that one file
    and then hands the game folder to Deploy-DarktideMods.ps1, so the properties that
    matter are: a dry run writes nothing anywhere, a refusal writes nothing anywhere,
    the old load order is backed up before it is replaced, and a deploy that worked is
    never reported as one that failed (or the other way round).

    The 'stub deployer' context copies the profile script next to a stand-in
    Deploy-DarktideMods.ps1, so the success/failure reporting is exercised the same
    way on every platform. The 'real deployer' context runs the actual deploy and, like
    the rest of the deploy tests, asserts Windows semantics.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:Dispatcher = Join-Path $script:RepoRoot 'darktide.ps1'
    $script:Profiler   = Join-Path $script:RepoRoot 'Switch-DarktideProfile.ps1'
    $script:Deployer   = Join-Path $script:RepoRoot 'Deploy-DarktideMods.ps1'

    function Set-LoadOrder {
        param([string] $Staging, [string[]] $Lines)
        Set-Content -LiteralPath (Join-Path $Staging 'mod_load_order.txt') -Value $Lines -Encoding UTF8
    }

    function Set-ProfileFile {
        param([string] $Dir, [string] $Name, [string[]] $Lines)
        [void][System.IO.Directory]::CreateDirectory($Dir)
        Set-Content -LiteralPath (Join-Path $Dir "$Name.txt") -Value $Lines -Encoding UTF8
    }

    function Get-Bytes {
        param([string] $Path)
        return [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Path))
    }

    function Get-AllFingerprint {
        <# Staging, game and profiles together: everything a profile run could touch. #>
        return (@($script:Staging, $script:Game, $script:ProfilesDir, $script:DeployBackups) |
                ForEach-Object { Get-TreeFingerprint -Path $_ }) -join "`n#`n"
    }

    function New-StubTool {
        <#
            A copy of the profile script beside a stand-in deployer. The stand-in leaves
            $LASTEXITCODE at 1 the way robocopy does after a successful copy, then
            succeeds, reports problems or throws, as stub-mode.txt says.
        #>
        param([string] $Root, [string] $Mode)

        $dir = Join-Path $Root 'tool'
        [void][System.IO.Directory]::CreateDirectory($dir)
        Copy-Item -LiteralPath $script:Profiler -Destination (Join-Path $dir 'Switch-DarktideProfile.ps1') -Force
        Set-Content -LiteralPath (Join-Path $dir 'stub-mode.txt') -Value $Mode -Encoding ASCII

        $stub = @'
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string] $ConfigPath, [string] $StagingMods, [string] $GamePath, [string] $BackupRoot,
    [switch] $Apply, [int] $KeepBackups = 10
)
$mode = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'stub-mode.txt') -Raw).Trim()
$calls = Join-Path $PSScriptRoot 'stub-calls.txt'
Add-Content -LiteralPath $calls -Value "Apply=$([bool]$Apply);KeepBackups=$KeepBackups;StagingMods=$StagingMods" -Encoding UTF8
$global:LASTEXITCODE = 1
if ($mode -eq 'ok') {
    if ($BackupRoot) {
        [void][System.IO.Directory]::CreateDirectory($BackupRoot)
        $n = @(Get-ChildItem -LiteralPath $BackupRoot -File).Count
        [System.IO.File]::WriteAllBytes((Join-Path $BackupRoot "gamemods-20990101-00000$n.zip"), [byte[]]@())
    }
    Write-Host 'Deploy OK.'
} elseif ($mode -eq 'problem') {
    Write-Host 'Deploy finished with problems - see above.'
    exit 1
} else {
    throw 'Darktide.exe is running (PID 4242). Close the game before changing mod files.'
}
'@
        Set-Content -LiteralPath (Join-Path $dir 'Deploy-DarktideMods.ps1') -Value $stub -Encoding UTF8
        return (Join-Path $dir 'Switch-DarktideProfile.ps1')
    }
}

Describe 'Switch-DarktideProfile' {

    BeforeEach {
        $script:PrevConfirm = $ConfirmPreference
        $ConfirmPreference  = 'None'

        $script:Root          = New-TestSandbox
        $script:Game          = New-FakeGameFolder -Root $script:Root
        $script:Staging       = New-FakeStaging    -Root $script:Root -Mods @('alpha_mod', 'beta_mod', 'gamma_mod')
        $script:Config        = New-TestConfig -Root $script:Root -StagingMods $script:Staging -GamePath $script:Game
        $script:ProfilesDir   = Join-Path $script:Root 'profiles'
        $script:BackupDir     = Join-Path $script:ProfilesDir 'backups'
        $script:LoadOrder     = Join-Path $script:Staging 'mod_load_order.txt'
        $script:GameMods      = Join-Path $script:Game 'mods'
        $script:DeployBackups = Join-Path $script:Root 'deploy_backups'

        Set-ProfileFile -Dir $script:ProfilesDir -Name 'minimal' -Lines @('-- minimal', 'alpha_mod')
    }

    AfterEach {
        $ConfirmPreference = $script:PrevConfirm
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'save' {

        It 'snapshots the staging load order outside the staging folder' {
            & $script:Profiler -ConfigPath $script:Config -Action save -Name full *>&1 | Out-Null

            $saved = Join-Path $script:ProfilesDir 'full.txt'
            Test-Path -LiteralPath $saved | Should -BeTrue
            Get-Bytes $saved | Should -Be (Get-Bytes $script:LoadOrder)
            Test-Path -LiteralPath (Join-Path $script:Staging 'profiles') | Should -BeFalse
            $LASTEXITCODE | Should -Be 0
        }

        It 'refuses to replace an existing profile without -Force' {
            $before = Get-Bytes (Join-Path $script:ProfilesDir 'minimal.txt')

            { & $script:Profiler -ConfigPath $script:Config -Action save -Name minimal *>&1 | Out-Null } |
                Should -Throw '*already exists*'

            Get-Bytes (Join-Path $script:ProfilesDir 'minimal.txt') | Should -Be $before
        }

        It 'replaces an existing profile with -Force' {
            & $script:Profiler -ConfigPath $script:Config -Action save -Name minimal -Force *>&1 | Out-Null

            Get-Bytes (Join-Path $script:ProfilesDir 'minimal.txt') | Should -Be (Get-Bytes $script:LoadOrder)
        }

        It 'honours ProfilesRoot from the config' {
            $elsewhere = Join-Path $script:Root 'my-profiles'
            $cfg = Get-Content -LiteralPath $script:Config -Raw | ConvertFrom-Json
            $cfg | Add-Member -NotePropertyName ProfilesRoot -NotePropertyValue $elsewhere
            $cfg | ConvertTo-Json | Set-Content -LiteralPath $script:Config -Encoding UTF8

            & $script:Profiler -ConfigPath $script:Config -Action save -Name full *>&1 | Out-Null

            Test-Path -LiteralPath (Join-Path $elsewhere 'full.txt') | Should -BeTrue
        }

        It 'refuses a ProfilesRoot inside staging, where deploy would copy it as a mod' {
            $cfg = Get-Content -LiteralPath $script:Config -Raw | ConvertFrom-Json
            $cfg | Add-Member -NotePropertyName ProfilesRoot -NotePropertyValue (Join-Path $script:Staging 'profiles')
            $cfg | ConvertTo-Json | Set-Content -LiteralPath $script:Config -Encoding UTF8
            $before = Get-TreeFingerprint -Path $script:Staging

            { & $script:Profiler -ConfigPath $script:Config -Action save -Name full *>&1 | Out-Null } |
                Should -Throw '*inside the staging folder*'

            Get-TreeFingerprint -Path $script:Staging | Should -Be $before
        }
    }

    Context 'where profiles may live' {

        It 'refuses a ProfilesRoot that is the staging BackupRoot, where rollback would read it' {
            $cfg = Get-Content -LiteralPath $script:Config -Raw | ConvertFrom-Json
            $cfg | Add-Member -NotePropertyName ProfilesRoot -NotePropertyValue $cfg.BackupRoot
            $cfg | ConvertTo-Json | Set-Content -LiteralPath $script:Config -Encoding UTF8

            { & $script:Profiler -ConfigPath $script:Config -Action save -Name full *>&1 | Out-Null } |
                Should -Throw '*staging BackupRoot*'

            Test-Path -LiteralPath $cfg.BackupRoot | Should -BeFalse
        }
    }

    Context 'list and show' {

        It 'lists every profile with its mod count and marks the one staging matches' {
            Set-ProfileFile -Dir $script:ProfilesDir -Name 'full' -Lines @('alpha_mod', 'beta_mod', 'gamma_mod')

            $out = & $script:Profiler -ConfigPath $script:Config -Action list *>&1 | Out-String

            $out | Should -Match '\*\s+full\s+3 mods'
            $out | Should -Match '(?m)^\s+minimal\s+1 mods'
            $out | Should -Not -Match '\*\s+minimal'
        }

        It 'says so when no saved profile matches staging' {
            $out = & $script:Profiler -ConfigPath $script:Config -Action list *>&1 | Out-String
            $out | Should -Match 'matches none'
        }

        It 'suggests save when there are no profiles yet' {
            Remove-Item -LiteralPath $script:ProfilesDir -Recurse -Force

            $out = & $script:Profiler -ConfigPath $script:Config -Action list *>&1 | Out-String

            $out | Should -Match 'No profiles saved yet'
            Test-Path -LiteralPath $script:ProfilesDir | Should -BeFalse
        }

        It 'shows the contents and names the mods missing from staging' {
            Set-ProfileFile -Dir $script:ProfilesDir -Name 'solo' -Lines @('alpha_mod', 'ghost_mod', '-- old_mod')

            $out = & $script:Profiler -ConfigPath $script:Config -Action show -Name solo *>&1 | Out-String

            $out | Should -Match 'ghost_mod'
            $out | Should -Match '-- old_mod'
            $out | Should -Match 'Not in staging \(1\): ghost_mod'
        }

        It 'never writes anything' {
            Set-ProfileFile -Dir $script:ProfilesDir -Name 'solo' -Lines @('alpha_mod', 'ghost_mod')
            $before = Get-AllFingerprint

            & $script:Profiler -ConfigPath $script:Config -Action list *>&1 | Out-Null
            & $script:Profiler -ConfigPath $script:Config -Action show -Name solo *>&1 | Out-Null

            Get-AllFingerprint | Should -Be $before
        }
    }

    Context 'profile names' {

        It "refuses '<BadName>' for <Verb> and writes nothing" -TestCases @(
            @{ BadName = '..';        Verb = 'save' }
            @{ BadName = 'a/b';       Verb = 'save' }
            @{ BadName = 'a\b';       Verb = 'save' }
            @{ BadName = 'x*';        Verb = 'save' }
            @{ BadName = '..\evil';   Verb = 'save' }
            @{ BadName = 'a..b';      Verb = 'save' }
            @{ BadName = '.hidden';   Verb = 'save' }
            @{ BadName = 'con';       Verb = 'save' }
            @{ BadName = ('n' * 41);  Verb = 'save' }
            @{ BadName = '..';        Verb = 'switch' }
            @{ BadName = 'a/b';       Verb = 'show' }
            @{ BadName = 'x*';        Verb = 'delete' }
        ) {
            $before = Get-AllFingerprint

            { & $script:Profiler -ConfigPath $script:Config -Action $Verb -Name $BadName -Apply *>&1 | Out-Null } |
                Should -Throw

            Get-AllFingerprint | Should -Be $before
        }

        It 'asks for a name when none is given' {
            { & $script:Profiler -ConfigPath $script:Config -Action save *>&1 | Out-Null } |
                Should -Throw '*Pass -Name*'
        }

        It 'names the saved profiles when asked for one that does not exist' {
            { & $script:Profiler -ConfigPath $script:Config -Action switch -Name nope *>&1 | Out-Null } |
                Should -Throw '*Saved profiles: minimal*'
        }
    }

    Context 'switch dry run' {

        It 'prints the plan and writes nothing to staging, the game or the profiles' {
            $before = Get-AllFingerprint

            $out = & $script:Profiler -ConfigPath $script:Config -Action switch -Name minimal *>&1 | Out-String

            Get-AllFingerprint | Should -Be $before
            $out | Should -Match 'disable\s+:\s+beta_mod, gamma_mod'
            $out | Should -Match 'Dry run complete\. Nothing was written'
            Test-Path -LiteralPath $script:GameMods | Should -BeFalse
            $LASTEXITCODE | Should -Be 0
        }

        It 'reports mods the profile would enable' {
            Set-LoadOrder -Staging $script:Staging -Lines @('alpha_mod')
            Set-ProfileFile -Dir $script:ProfilesDir -Name 'full' -Lines @('alpha_mod', 'beta_mod', 'gamma_mod')

            $out = & $script:Profiler -ConfigPath $script:Config -Action switch -Name full *>&1 | Out-String

            $out | Should -Match 'enable\s+:\s+beta_mod, gamma_mod'
        }
    }

    Context 'switch refusals' {

        It 'refuses a profile that names a mod missing from staging, and writes nothing' {
            Set-ProfileFile -Dir $script:ProfilesDir -Name 'broken' -Lines @('alpha_mod', 'ghost_mod')
            $before = Get-AllFingerprint

            { & $script:Profiler -ConfigPath $script:Config -Action switch -Name broken -Apply *>&1 | Out-Null } |
                Should -Throw '*ghost_mod*Nothing was written*'

            Get-AllFingerprint | Should -Be $before
        }

        It 'accepts a missing mod that the profile comments out with --' {
            Set-ProfileFile -Dir $script:ProfilesDir -Name 'commented' -Lines @('alpha_mod', '-- ghost_mod')

            $out = & $script:Profiler -ConfigPath $script:Config -Action switch -Name commented *>&1 | Out-String

            $out | Should -Match 'Dry run complete'
            $LASTEXITCODE | Should -Be 0
        }

        It 'refuses an entry that is a path rather than a folder name' {
            Set-ProfileFile -Dir $script:ProfilesDir -Name 'sneaky' -Lines @('alpha_mod', '..\outside')
            $before = Get-AllFingerprint

            { & $script:Profiler -ConfigPath $script:Config -Action switch -Name sneaky -Apply *>&1 | Out-Null } |
                Should -Throw '*not in staging*'

            Get-AllFingerprint | Should -Be $before
        }

        It 'refuses while Darktide is running, before staging is touched' {
            Mock Get-Process { [pscustomobject]@{ Id = 4242 } } -ParameterFilter { $Name -eq 'Darktide' }
            $before = Get-AllFingerprint

            { & $script:Profiler -ConfigPath $script:Config -Action switch -Name minimal -Apply *>&1 | Out-Null } |
                Should -Throw '*Darktide.exe is running*Nothing was written*'

            Get-AllFingerprint | Should -Be $before
        }

        It 'refuses a game folder that is not Darktide, before staging is touched' {
            $notGame = Join-Path $script:Root 'some\other\folder'
            [void][System.IO.Directory]::CreateDirectory($notGame)
            $cfg = New-TestConfig -Root $script:Root -StagingMods $script:Staging -GamePath $notGame
            $before = Get-AllFingerprint

            { & $script:Profiler -ConfigPath $cfg -Action switch -Name minimal -Apply *>&1 | Out-Null } |
                Should -Throw '*does not look like a Darktide install*'

            Get-AllFingerprint | Should -Be $before
        }

        # The deployer also refuses a drive root and a path with fewer than three
        # segments, even when the Darktide markers are there. A one-letter PSDrive
        # rooted in the sandbox produces exactly those paths ('Q:\' and 'Q:\game')
        # without writing outside it. On Windows this is the deployer's real refusal;
        # elsewhere the deployer, which splits on '\', refuses every path as shallow,
        # so the test still fails if the pre-flight lets the switch through.
        It 'refuses a GamePath the deployer rejects as <Case>, before staging is touched' -TestCases @(
            @{ Case = 'a drive root';         Sub = '';     Expect = '*drive root*Nothing was written*' }
            @{ Case = 'suspiciously shallow'; Sub = 'game'; Expect = '*suspiciously shallow*Nothing was written*' }
        ) {
            param($Sub, $Expect)

            $driveRoot = Join-Path $script:Root 'drive'
            $markerDir = if ($Sub) { Join-Path $driveRoot $Sub } else { $driveRoot }
            [void][System.IO.Directory]::CreateDirectory((Join-Path $markerDir 'binaries'))
            Set-Content -LiteralPath (Join-Path $markerDir 'binaries\Darktide.exe') -Value 'not a real exe' -Encoding ASCII

            $letter = @('Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y') |
                      Where-Object { -not (Get-PSDrive -Name $_ -ErrorAction SilentlyContinue) } |
                      Select-Object -First 1
            $letter | Should -Not -BeNullOrEmpty
            New-PSDrive -Name $letter -PSProvider FileSystem -Root $driveRoot -Scope Global | Out-Null
            try {
                $gamePath = if ($Sub) { "${letter}:\$Sub" } else { "${letter}:\" }
                $cfg = New-TestConfig -Root $script:Root -StagingMods $script:Staging -GamePath $gamePath
                $loadOrderBefore = Get-Bytes $script:LoadOrder
                $before = Get-AllFingerprint

                { & $script:Profiler -ConfigPath $cfg -Action switch -Name minimal -Apply *>&1 | Out-Null } |
                    Should -Throw $Expect

                Get-Bytes $script:LoadOrder | Should -Be $loadOrderBefore
                Test-Path -LiteralPath $script:BackupDir | Should -BeFalse
                Get-AllFingerprint | Should -Be $before
            } finally {
                Remove-PSDrive -Name $letter -Scope Global -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'switch -Apply with a stub deployer' {

        It 'reports success even though $LASTEXITCODE is 1 after the deploy' {
            $tool = New-StubTool -Root $script:Root -Mode 'ok'
            $original = Get-Bytes $script:LoadOrder

            $out = & $tool -ConfigPath $script:Config -Action switch -Name minimal -Apply *>&1 | Out-String

            $LASTEXITCODE | Should -Be 0
            $out | Should -Match "Switched to profile 'minimal'"
            $out | Should -Not -Match 'NOT updated'

            Get-Bytes $script:LoadOrder | Should -Be (Get-Bytes (Join-Path $script:ProfilesDir 'minimal.txt'))
            $backups = @(Get-ChildItem -LiteralPath $script:BackupDir -Filter 'mod_load_order-*.txt')
            $backups.Count | Should -Be 1
            Get-Bytes $backups[0].FullName | Should -Be $original

            $call = Get-Content -LiteralPath (Join-Path $script:Root 'tool\stub-calls.txt')
            @($call).Count | Should -Be 1
            $call | Should -Match 'Apply=True'
            $call | Should -Match 'KeepBackups=10'
        }

        It 'prints the undo for both sides' {
            $tool = New-StubTool -Root $script:Root -Mode 'ok'

            $out = & $tool -ConfigPath $script:Config -Action switch -Name minimal -Apply *>&1 | Out-String

            $out | Should -Match 'profile -Action switch -Name mod_load_order-\d{8}-\d{6}'
            $out | Should -Match "restore -Apply -BackupSet 'gamemods-"
        }

        It 'undoes a switch by switching to the load-order backup it names' {
            $tool = New-StubTool -Root $script:Root -Mode 'ok'
            $original = Get-Bytes $script:LoadOrder
            & $tool -ConfigPath $script:Config -Action switch -Name minimal -Apply *>&1 | Out-Null
            $backup = @(Get-ChildItem -LiteralPath $script:BackupDir -Filter 'mod_load_order-*.txt')[0]

            & $tool -ConfigPath $script:Config -Action switch -Name $backup.BaseName -Apply *>&1 | Out-Null

            $LASTEXITCODE | Should -Be 0
            Get-Bytes $script:LoadOrder | Should -Be $original
        }

        It 'reports a deploy that finished with problems as a failure, with the way back' {
            $tool = New-StubTool -Root $script:Root -Mode 'problem'

            $out = & $tool -ConfigPath $script:Config -Action switch -Name minimal -Apply *>&1 | Out-String

            $LASTEXITCODE | Should -Be 1
            $out | Should -Match "Staging WAS switched to profile 'minimal', but the game folder was NOT updated"
            $out | Should -Match 'deploy -Apply'
            $out | Should -Match 'profile -Action switch -Name mod_load_order-'
            $out | Should -Not -Match 'both use it now'
        }

        It 'reports a deploy that threw as a failure and says why' {
            $tool = New-StubTool -Root $script:Root -Mode 'throw'

            $out = & $tool -ConfigPath $script:Config -Action switch -Name minimal -Apply *>&1 | Out-String

            $LASTEXITCODE | Should -Be 1
            $out | Should -Match 'NOT updated'
            $out | Should -Match 'PID 4242'
        }

        It 'does not rewrite or back up staging when the profile is already active, but still deploys' {
            $tool = New-StubTool -Root $script:Root -Mode 'ok'
            & $tool -ConfigPath $script:Config -Action switch -Name minimal -Apply *>&1 | Out-Null
            $stagingBefore = Get-TreeFingerprint -Path $script:Staging
            $backupsBefore = Get-TreeFingerprint -Path $script:BackupDir

            $out = & $tool -ConfigPath $script:Config -Action switch -Name minimal -Apply *>&1 | Out-String

            $LASTEXITCODE | Should -Be 0
            $out | Should -Match 'already active'
            Get-TreeFingerprint -Path $script:Staging   | Should -Be $stagingBefore
            Get-TreeFingerprint -Path $script:BackupDir | Should -Be $backupsBefore
            @(Get-Content -LiteralPath (Join-Path $script:Root 'tool\stub-calls.txt')).Count | Should -Be 2
        }

        It 'prunes load-order backups to -KeepBackups' {
            $tool = New-StubTool -Root $script:Root -Mode 'ok'
            Set-ProfileFile -Dir $script:ProfilesDir -Name 'full' -Lines @('alpha_mod', 'beta_mod', 'gamma_mod')

            foreach ($p in @('minimal', 'full', 'minimal', 'full')) {
                & $tool -ConfigPath $script:Config -Action switch -Name $p -Apply -KeepBackups 2 *>&1 | Out-Null
            }

            @(Get-ChildItem -LiteralPath $script:BackupDir -Filter 'mod_load_order-*.txt').Count | Should -Be 2
            Get-Content -LiteralPath (Join-Path $script:Root 'tool\stub-calls.txt') |
                ForEach-Object { $_ | Should -Match 'KeepBackups=2' }
        }

        It 'keeps every load-order backup with -KeepBackups 0' {
            $tool = New-StubTool -Root $script:Root -Mode 'ok'
            Set-ProfileFile -Dir $script:ProfilesDir -Name 'full' -Lines @('alpha_mod', 'beta_mod', 'gamma_mod')

            foreach ($p in @('minimal', 'full', 'minimal')) {
                & $tool -ConfigPath $script:Config -Action switch -Name $p -Apply -KeepBackups 0 *>&1 | Out-Null
            }

            @(Get-ChildItem -LiteralPath $script:BackupDir -Filter 'mod_load_order-*.txt').Count | Should -Be 3
        }

        It 'does not deploy under -WhatIf' {
            $tool = New-StubTool -Root $script:Root -Mode 'ok'
            $before = Get-AllFingerprint

            & $tool -ConfigPath $script:Config -Action switch -Name minimal -Apply -WhatIf *>&1 | Out-Null

            Get-AllFingerprint | Should -Be $before
            Test-Path -LiteralPath (Join-Path $script:Root 'tool\stub-calls.txt') | Should -BeFalse
        }
    }

    Context 'switch -Apply with the real deployer' {

        BeforeEach {
            # A first deploy, so the game has a mods folder for the switch's deploy to back up.
            & $script:Deployer -ConfigPath $script:Config -Apply -Confirm:$false *>&1 | Out-Null
            & $script:Profiler -ConfigPath $script:Config -Action save -Name full *>&1 | Out-Null
        }

        It 'replaces the staging load order, backs it up, and deploys it to the game' {
            $original = Get-Bytes $script:LoadOrder

            $out = & $script:Profiler -ConfigPath $script:Config -Action switch -Name minimal -Apply *>&1 | Out-String

            $LASTEXITCODE | Should -Be 0
            $out | Should -Match "Switched to profile 'minimal'"
            $out | Should -Not -Match 'NOT updated'

            $profileFile = Join-Path $script:ProfilesDir 'minimal.txt'
            Get-Bytes $script:LoadOrder | Should -Be (Get-Bytes $profileFile)
            $backups = @(Get-ChildItem -LiteralPath $script:BackupDir -Filter 'mod_load_order-*.txt')
            $backups.Count | Should -Be 1
            Get-Bytes $backups[0].FullName | Should -Be $original

            @(Get-ChildItem -LiteralPath $script:DeployBackups -Filter 'gamemods-*.zip').Count | Should -Be 1
            Get-Bytes (Join-Path $script:GameMods 'mod_load_order.txt') | Should -Be (Get-Bytes $profileFile)
        }

        It 'switching back deploys again, and switching to the active profile is a no-op deploy' {
            & $script:Profiler -ConfigPath $script:Config -Action switch -Name minimal -Apply *>&1 | Out-Null
            & $script:Profiler -ConfigPath $script:Config -Action switch -Name full -Apply *>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
            Get-Bytes (Join-Path $script:GameMods 'mod_load_order.txt') |
                Should -Be (Get-Bytes (Join-Path $script:ProfilesDir 'full.txt'))

            $zips = @(Get-ChildItem -LiteralPath $script:DeployBackups -Filter 'gamemods-*.zip').Count
            $game = Get-TreeFingerprint -Path $script:GameMods

            $out = & $script:Profiler -ConfigPath $script:Config -Action switch -Name full -Apply *>&1 | Out-String

            $LASTEXITCODE | Should -Be 0
            $out | Should -Match 'already active'
            Get-TreeFingerprint -Path $script:GameMods | Should -Be $game
            @(Get-ChildItem -LiteralPath $script:DeployBackups -Filter 'gamemods-*.zip').Count | Should -Be $zips
        }
    }

    Context 'delete' {

        It 'needs -Apply' {
            $before = Get-AllFingerprint

            $out = & $script:Profiler -ConfigPath $script:Config -Action delete -Name minimal *>&1 | Out-String

            Get-AllFingerprint | Should -Be $before
            $out | Should -Match 'Dry run complete\. Nothing was written'
        }

        It 'deletes only the profile file with -Apply' {
            $staging = Get-TreeFingerprint -Path $script:Staging

            & $script:Profiler -ConfigPath $script:Config -Action delete -Name minimal -Apply *>&1 | Out-Null

            Test-Path -LiteralPath (Join-Path $script:ProfilesDir 'minimal.txt') | Should -BeFalse
            Get-TreeFingerprint -Path $script:Staging | Should -Be $staging
        }

        It 'refuses a profile that does not exist' {
            { & $script:Profiler -ConfigPath $script:Config -Action delete -Name nope -Apply *>&1 | Out-Null } |
                Should -Throw "*No profile named 'nope'*"
        }
    }

    Context 'dispatcher' {

        It 'saves through the profile verb' {
            & $script:Dispatcher profile -ConfigPath $script:Config -Action save -Name full *>&1 | Out-Null

            Test-Path -LiteralPath (Join-Path $script:ProfilesDir 'full.txt') | Should -BeTrue
        }

        It 'lists by default' {
            $out = & $script:Dispatcher profile -ConfigPath $script:Config *>&1 | Out-String
            $out | Should -Match 'minimal\s+1 mods'
        }

        It 'switch without -Apply writes nothing' {
            $before = Get-AllFingerprint

            $out = & $script:Dispatcher profile -ConfigPath $script:Config -Action switch -Name minimal *>&1 | Out-String

            Get-AllFingerprint | Should -Be $before
            $out | Should -Match '\(dry run\)'
        }

        It 'delete without -Apply writes nothing' {
            $before = Get-AllFingerprint

            & $script:Dispatcher profile -ConfigPath $script:Config -Action delete -Name minimal *>&1 | Out-Null

            Get-AllFingerprint | Should -Be $before
        }

        It 'passes a failed deploy on as exit code 1' {
            # No dmf in staging: the deploy copies, then its post-check reports problems.
            Remove-Item -LiteralPath (Join-Path $script:Staging 'dmf') -Recurse -Force

            & $script:Dispatcher profile -ConfigPath $script:Config -Action switch -Name minimal -Apply *>&1 | Out-Null

            $LASTEXITCODE | Should -Be 1
            Get-Bytes $script:LoadOrder | Should -Be (Get-Bytes (Join-Path $script:ProfilesDir 'minimal.txt'))
        }
    }
}
