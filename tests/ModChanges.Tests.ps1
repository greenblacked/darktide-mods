<#
    Tests for Show-ModChanges.ps1 (the `changes` verb).

    The fixture is a staging tree plus a backup set built by hand with New-TestZip,
    laid out the way update -Apply leaves it: <BackupRoot>\<yyyyMMdd-HHmmss>\<mod>.zip
    holding the mod folder's contents at the zip root. Nothing is extracted, so the
    tests also prove the script writes nothing but the -OutFile it was asked for.

    File contents go through [IO.File]::WriteAllText and New-TestZip, which both
    write UTF-8 without a byte order mark on every engine, so "the same file" really
    is byte-identical in the zip and in staging under Windows PowerShell 5.1 too.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:Dispatcher = Join-Path $script:RepoRoot 'darktide.ps1'
    $script:Changer    = Join-Path $script:RepoRoot 'Show-ModChanges.ps1'

    $script:NewestSet = '20261020-181500'
    $script:OlderSet  = '20261001-090000'

    function Set-TestFile {
        param([string] $Dir, [string] $Rel, [string] $Text)
        $path = $Dir
        foreach ($part in ($Rel -split '/')) { $path = Join-Path $path $part }
        [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $path))
        [System.IO.File]::WriteAllText($path, $Text)
    }

    function Get-SetLocalTime {
        param([string] $Name)
        return [datetime]::ParseExact($Name, 'yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
    }

    function New-ChangesFixture {
        <#
          alpha_mod  1.0.0 -> 2.0.0: scripts/old.lua removed, scripts/changed.lua
                     changed (same length, different bytes), scripts/new.lua added,
                     alpha_mod.mod and scripts/shared.lua identical.
          epsilon_mod reinstalled with identical files: UNCHANGED.
          gamma_mod  installed after the newest set, no backup: NEW.
          delta_mod  backed up, folder gone from staging: REMOVED.
          beta_mod / dmf untouched and older than every set: not reported.
        #>
        param([Parameter(Mandatory)][string] $Root)

        $game    = New-FakeGameFolder -Root $Root
        $staging = New-FakeStaging -Root $Root -Mods @('alpha_mod', 'beta_mod', 'epsilon_mod')
        $config  = New-TestConfig -Root $Root -StagingMods $staging -GamePath $game
        $backups = Join-Path $Root 'mod_backups'

        $newest = Join-Path $backups $script:NewestSet
        $older  = Join-Path $backups $script:OlderSet
        [void][System.IO.Directory]::CreateDirectory($newest)
        [void][System.IO.Directory]::CreateDirectory($older)

        # alpha_mod as it was before the update. One entry uses '\' on purpose:
        # Windows tools write either separator and the diff must not care.
        $null = New-TestZip -Path (Join-Path $newest 'alpha_mod.zip') -Entries @{
            'alpha_mod.mod'        = 'return { version = 1 }'
            'info.json'            = '{"name":"Alpha","version":"1.0.0"}'
            '.nexus-mod.json'      = '{"version":"1.0.0","installedAt":"2026-09-01T10:00:00.0000000+00:00"}'
            'scripts/old.lua'      = '-- dropped in 2.0.0'
            'scripts\shared.lua'   = '-- unchanged'
            'scripts/changed.lua'  = 'v1v1'
        }

        # alpha_mod as update -Apply left it. installedAt is built from the set's
        # local time, as the updater's is, so the fixture means the same thing in
        # every time zone.
        $alphaAt = (Get-SetLocalTime $script:NewestSet).AddSeconds(30).ToString('o')
        $alpha = Join-Path $staging 'alpha_mod'
        Set-TestFile $alpha 'alpha_mod.mod'       'return { version = 1 }'
        Set-TestFile $alpha 'info.json'           '{"name":"Alpha","version":"2.0.0"}'
        Set-TestFile $alpha '.nexus-mod.json'     ('{"version":"2.0.0","installedAt":"' + $alphaAt + '"}')
        Set-TestFile $alpha 'scripts/shared.lua'  '-- unchanged'
        Set-TestFile $alpha 'scripts/changed.lua' 'v2v2'
        Set-TestFile $alpha 'scripts/new.lua'     '-- SECRET-CONTENT-MARKER added in 2.0.0'

        # epsilon_mod: reinstalled, byte-identical.
        $eps = Join-Path $staging 'epsilon_mod'
        Set-TestFile $eps 'epsilon_mod.mod' 'return {}'
        Set-TestFile $eps 'info.json'       '{"version":"1.2.0"}'
        $null = New-TestZip -Path (Join-Path $newest 'epsilon_mod.zip') -Entries @{
            'epsilon_mod.mod' = 'return {}'
            'info.json'       = '{"version":"1.2.0"}'
        }

        # delta_mod: backed up, then gone from staging.
        $null = New-TestZip -Path (Join-Path $newest 'delta_mod.zip') -Entries @{
            'delta_mod.mod'  = 'return {}'
            'info.json'      = '{"version":"0.9.0"}'
            'lib/helper.lua' = '-- helper'
        }

        # The older set: a beta_mod backup, so selecting it is observable.
        $null = New-TestZip -Path (Join-Path $older 'beta_mod.zip') -Entries @{
            'beta_mod.mod' = 'return { run = function() end }'
            'info.json'    = '{"version":"0.5.0"}'
        }

        # Every pre-existing folder is older than both sets, so only gamma_mod is new.
        $old = Get-Date -Year 2026 -Month 1 -Day 1 -Hour 12 -Minute 0 -Second 0
        foreach ($d in @(Get-ChildItem -LiteralPath $staging -Directory)) { $d.LastWriteTime = $old }

        # gamma_mod: installed by the same run, nothing to back up. Its time comes
        # from installedAt, which is what Install-ModArchive writes.
        $gamma = Join-Path $staging 'gamma_mod'
        $installedAt = (Get-SetLocalTime $script:NewestSet).AddMinutes(1).ToString('o')
        Set-TestFile $gamma 'gamma_mod.mod'   'return {}'
        Set-TestFile $gamma 'info.json'       '{"version":"3.1.0"}'
        Set-TestFile $gamma '.nexus-mod.json' ('{"version":"3.1.0","installedAt":"' + $installedAt + '"}')
        (Get-Item -LiteralPath $gamma).LastWriteTime = $old

        return [pscustomobject]@{
            Config  = $config
            Staging = $staging
            Backups = $backups
            Game    = $game
        }
    }

    function Invoke-Changes {
        <# Runs the script, returns its console output as one string. #>
        param([hashtable] $Params)
        return (& $script:Changer @Params *>&1 | Out-String)
    }

    function Get-JsonReport {
        param([string] $Config, [hashtable] $Extra = @{})
        $out = Join-Path $script:Root 'changes.json'
        $p = @{ ConfigPath = $Config; OutFile = $out; Force = $true }
        foreach ($k in $Extra.Keys) { $p[$k] = $Extra[$k] }
        & $script:Changer @p *>&1 | Out-Null
        return (Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json)
    }

    function Get-ModRow {
        param($Report, [string] $Mod)
        return @($Report.mods | Where-Object { $_.mod -eq $Mod })
    }
}

Describe 'Show-ModChanges' {

    BeforeEach {
        $script:Root = New-TestSandbox
        $script:Fx   = New-ChangesFixture -Root $script:Root
    }

    AfterEach {
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'classification against the newest set' {

        It 'lists added, removed and changed files and leaves identical ones out' {
            $r = Get-JsonReport -Config $script:Fx.Config
            $alpha = Get-ModRow $r 'alpha_mod'
            $alpha.Count       | Should -Be 1
            $alpha[0].status   | Should -Be 'CHANGED'
            @($alpha[0].added)   | Should -Be @('scripts/new.lua')
            @($alpha[0].removed) | Should -Be @('scripts/old.lua')
            @($alpha[0].changed) | Should -Contain 'scripts/changed.lua'
            @($alpha[0].changed) | Should -Contain 'info.json'
            @($alpha[0].changed) | Should -Not -Contain 'alpha_mod.mod'
            @($alpha[0].changed) | Should -Not -Contain 'scripts/shared.lua'
        }

        It 'ignores .nexus-mod.json, which every install rewrites' {
            $r = Get-JsonReport -Config $script:Fx.Config
            $alpha = (Get-ModRow $r 'alpha_mod')[0]
            $all = @($alpha.added) + @($alpha.removed) + @($alpha.changed)
            $all | Should -Not -Contain '.nexus-mod.json'
        }

        It 'reads the old version from the zip and the new one from staging' {
            $r = Get-JsonReport -Config $script:Fx.Config
            $alpha = (Get-ModRow $r 'alpha_mod')[0]
            $alpha.oldVersion | Should -Be '1.0.0'
            $alpha.newVersion | Should -Be '2.0.0'
        }

        It 'calls a byte-identical reinstall UNCHANGED' {
            $r = Get-JsonReport -Config $script:Fx.Config
            $eps = (Get-ModRow $r 'epsilon_mod')[0]
            $eps.status | Should -Be 'UNCHANGED'
            (@($eps.added).Count + @($eps.removed).Count + @($eps.changed).Count) | Should -Be 0
        }

        It 'reports a mod installed after the set with no backup as NEW' {
            $r = Get-JsonReport -Config $script:Fx.Config
            $gamma = Get-ModRow $r 'gamma_mod'
            $gamma.Count          | Should -Be 1
            $gamma[0].status      | Should -Be 'NEW'
            $gamma[0].oldVersion  | Should -BeNullOrEmpty
            $gamma[0].newVersion  | Should -Be '3.1.0'
            @($gamma[0].added)    | Should -Contain 'gamma_mod.mod'
        }

        It 'reports a backed-up mod whose folder is gone as REMOVED' {
            $r = Get-JsonReport -Config $script:Fx.Config
            $delta = (Get-ModRow $r 'delta_mod')[0]
            $delta.status     | Should -Be 'REMOVED'
            $delta.oldVersion | Should -Be '0.9.0'
            $delta.newVersion | Should -BeNullOrEmpty
            @($delta.removed) | Should -Contain 'lib/helper.lua'
        }

        It 'does not report untouched mods, base, or anything older than the set' {
            $r = Get-JsonReport -Config $script:Fx.Config
            $names = @($r.mods | ForEach-Object { $_.mod })
            $names | Should -Not -Contain 'beta_mod'
            $names | Should -Not -Contain 'dmf'
            $names | Should -Not -Contain 'base'
            $r.summary.mods | Should -Be 4
        }

        It 'reads a mod whose name has brackets, and warns that rollback will not restore it' {
            $odd = Join-Path $script:Fx.Staging '[x]_mod'
            Set-TestFile $odd 'x.mod' 'return { version = 2 }'
            Set-TestFile $odd '.nexus-mod.json' ('{"version":"2","installedAt":"' + (Get-SetLocalTime $script:NewestSet).AddSeconds(5).ToString('o') + '"}')
            $null = New-TestZip -Path (Join-Path (Join-Path $script:Fx.Backups $script:NewestSet) '[x]_mod.zip') -Entries @{
                'x.mod' = 'return { version = 1 }'
            }

            $out = Join-Path $script:Root 'odd.json'
            $console = Invoke-Changes @{ ConfigPath = $script:Fx.Config; OutFile = $out }
            $console | Should -Match 'rollback skips these names.*\[x\]_mod'

            $r = Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json
            $row = (Get-ModRow $r '[x]_mod')[0]
            $row.status        | Should -Be 'CHANGED'
            @($row.changed)    | Should -Be @('x.mod')
        }

        It 'prints the matching rollback command' {
            $out = Invoke-Changes @{ ConfigPath = $script:Fx.Config }
            $out | Should -Match ([regex]::Escape(".\darktide.ps1 rollback -BackupSet $script:NewestSet -Apply"))
        }

        It 'prints file names but never file content' {
            $out = Invoke-Changes @{ ConfigPath = $script:Fx.Config }
            $out | Should -Match 'scripts/new\.lua'
            $out | Should -Not -Match 'SECRET-CONTENT-MARKER'
        }
    }

    Context 'choosing a backup set' {

        It 'defaults to the newest set' {
            $r = Get-JsonReport -Config $script:Fx.Config
            $r.backupSet | Should -Be $script:NewestSet
            $r.newestSet | Should -BeTrue
        }

        It 'selects a set by a unique part of its name' {
            $r = Get-JsonReport -Config $script:Fx.Config -Extra @{ BackupSet = '1001-09' }
            $r.backupSet | Should -Be $script:OlderSet
            $r.newestSet | Should -BeFalse
            $r.undo      | Should -Be ".\darktide.ps1 rollback -BackupSet $script:OlderSet -Apply"
            $beta = (Get-ModRow $r 'beta_mod')[0]
            $beta.oldVersion | Should -Be '0.5.0'
            # gamma_mod arrived after the next set was taken, so it is not this set's.
            @($r.mods | ForEach-Object { $_.mod }) | Should -Not -Contain 'gamma_mod'
        }

        It 'refuses a name that matches more than one set and names them' {
            { & $script:Changer -ConfigPath $script:Fx.Config -BackupSet '2026' *>&1 | Out-Null } |
                Should -Throw "*matches 2 backup sets*$script:NewestSet*$script:OlderSet*"
        }

        It 'refuses a name that matches nothing' {
            { & $script:Changer -ConfigPath $script:Fx.Config -BackupSet 'nope' *>&1 | Out-Null } |
                Should -Throw '*No backup set*matches*'
        }

        It 'refuses a path in place of a set name' {
            { & $script:Changer -ConfigPath $script:Fx.Config -BackupSet "..\$script:NewestSet" *>&1 | Out-Null } |
                Should -Throw '*not a path*'
        }

        It 'fails clearly when there is no backup root yet' {
            Remove-Item -LiteralPath $script:Fx.Backups -Recurse -Force
            { & $script:Changer -ConfigPath $script:Fx.Config *>&1 | Out-Null } |
                Should -Throw '*No backup root*'
        }
    }

    Context '-Only and -Skip' {

        It '-Only limits the report to the named mods' {
            $r = Get-JsonReport -Config $script:Fx.Config -Extra @{ Only = @('alpha_mod') }
            @($r.mods | ForEach-Object { $_.mod }) | Should -Be @('alpha_mod')
        }

        It '-Skip leaves the named mods out' {
            $r = Get-JsonReport -Config $script:Fx.Config -Extra @{ Skip = @('alpha_mod', 'gamma_mod') }
            $names = @($r.mods | ForEach-Object { $_.mod })
            $names | Should -Not -Contain 'alpha_mod'
            $names | Should -Not -Contain 'gamma_mod'
            $names | Should -Contain 'delta_mod'
        }
    }

    Context 'listing cap' {

        It 'caps the console at 50 lines per mod but writes every file to -OutFile' {
            $alpha = Join-Path $script:Fx.Staging 'alpha_mod'
            for ($i = 1; $i -le 60; $i++) { Set-TestFile $alpha ('bulk/file{0:D2}.lua' -f $i) "-- $i" }

            $out = Join-Path $script:Root 'all.json'
            $console = Invoke-Changes @{ ConfigPath = $script:Fx.Config; OutFile = $out }
            $console | Should -Match 'and \d+ more, listed in'
            $console | Should -Not -Match 'bulk/file60\.lua'

            $r = Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json
            @((Get-ModRow $r 'alpha_mod')[0].added).Count | Should -Be 61
        }
    }

    Context '-OutFile' {

        It 'writes JSON that parses' {
            $out = Join-Path $script:Root 'report.json'
            Invoke-Changes @{ ConfigPath = $script:Fx.Config; OutFile = $out } | Out-Null
            Test-Path -LiteralPath $out | Should -BeTrue
            { Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json } | Should -Not -Throw
            (Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json).generatedBy |
                Should -Be 'Show-ModChanges.ps1'
        }

        It 'writes markdown with the table and the file lists' {
            $out = Join-Path $script:Root 'report.md'
            Invoke-Changes @{ ConfigPath = $script:Fx.Config; OutFile = $out } | Out-Null
            $md = Get-Content -LiteralPath $out -Raw -Encoding UTF8
            $md | Should -Match '\| Mod \| Status \| Old \| New \|'
            $md | Should -Match '\| alpha_mod \| CHANGED \| 1\.0\.0 \| 2\.0\.0 \| 1 \| 1 \| 2 \|'
            $md | Should -Match 'scripts/new\.lua'
            $md | Should -Not -Match 'SECRET-CONTENT-MARKER'
        }

        It 'refuses to overwrite without -Force, and overwrites with it' {
            $out = Join-Path $script:Root 'report.json'
            Set-Content -LiteralPath $out -Value 'keep me' -Encoding UTF8
            { & $script:Changer -ConfigPath $script:Fx.Config -OutFile $out *>&1 | Out-Null } |
                Should -Throw '*already exists*-Force*'
            (Get-Content -LiteralPath $out -Raw) | Should -Match 'keep me'

            & $script:Changer -ConfigPath $script:Fx.Config -OutFile $out -Force *>&1 | Out-Null
            (Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json).backupSet |
                Should -Be $script:NewestSet
        }

        It 'refuses an extension it cannot write' {
            { & $script:Changer -ConfigPath $script:Fx.Config -OutFile (Join-Path $script:Root 'r.txt') *>&1 | Out-Null } |
                Should -Throw '*.json or .md*'
        }

        It 'refuses to write inside staging or the backup root' {
            { & $script:Changer -ConfigPath $script:Fx.Config -OutFile (Join-Path $script:Fx.Staging 'r.json') *>&1 | Out-Null } |
                Should -Throw '*inside the staging folder*'
            { & $script:Changer -ConfigPath $script:Fx.Config -OutFile (Join-Path $script:Fx.Backups 'r.json') *>&1 | Out-Null } |
                Should -Throw '*inside the backup root*'
        }
    }

    Context 'writes nothing' {

        It 'leaves staging, the backup sets and the game folder untouched' {
            $before = @{
                Staging = Get-TreeFingerprint -Path $script:Fx.Staging
                Backups = Get-TreeFingerprint -Path $script:Fx.Backups
                Game    = Get-TreeFingerprint -Path $script:Fx.Game
            }
            $rootBefore = @(Get-ChildItem -LiteralPath $script:Root -Force | ForEach-Object { $_.Name } | Sort-Object)

            Invoke-Changes @{ ConfigPath = $script:Fx.Config } | Out-Null
            Invoke-Changes @{ ConfigPath = $script:Fx.Config; BackupSet = '1001' } | Out-Null

            Get-TreeFingerprint -Path $script:Fx.Staging | Should -Be $before.Staging
            Get-TreeFingerprint -Path $script:Fx.Backups | Should -Be $before.Backups
            Get-TreeFingerprint -Path $script:Fx.Game    | Should -Be $before.Game
            @(Get-ChildItem -LiteralPath $script:Root -Force | ForEach-Object { $_.Name } | Sort-Object) |
                Should -Be $rootBefore
        }

        It 'with -OutFile, writes that file and nothing else' {
            $before = @{
                Staging = Get-TreeFingerprint -Path $script:Fx.Staging
                Backups = Get-TreeFingerprint -Path $script:Fx.Backups
            }
            $out = Join-Path $script:Root 'report.json'
            Invoke-Changes @{ ConfigPath = $script:Fx.Config; OutFile = $out } | Out-Null

            Test-Path -LiteralPath $out | Should -BeTrue
            Get-TreeFingerprint -Path $script:Fx.Staging | Should -Be $before.Staging
            Get-TreeFingerprint -Path $script:Fx.Backups | Should -Be $before.Backups
        }
    }

    Context 'through darktide.ps1' {

        It 'runs the changes verb with -BackupSet and -OutFile and writes nothing else' {
            $before = Get-TreeFingerprint -Path $script:Fx.Staging
            $out = Join-Path $script:Root 'via-dispatcher.json'

            & $script:Dispatcher changes -ConfigPath $script:Fx.Config -BackupSet '1020' -OutFile $out *>&1 | Out-Null

            $r = Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json
            $r.backupSet | Should -Be $script:NewestSet
            (Get-ModRow $r 'alpha_mod')[0].status | Should -Be 'CHANGED'
            Get-TreeFingerprint -Path $script:Fx.Staging | Should -Be $before
        }

        It 'passes -Force through so a report can be refreshed' {
            $out = Join-Path $script:Root 'via-dispatcher.json'
            Set-Content -LiteralPath $out -Value 'old' -Encoding UTF8
            { & $script:Dispatcher changes -ConfigPath $script:Fx.Config -OutFile $out *>&1 | Out-Null } |
                Should -Throw '*already exists*'
            & $script:Dispatcher changes -ConfigPath $script:Fx.Config -OutFile $out -Force *>&1 | Out-Null
            (Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json).generatedBy |
                Should -Be 'Show-ModChanges.ps1'
        }
    }
}
