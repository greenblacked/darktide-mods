<#
    Tests for Install-DarktideLoader.ps1 -PatchOnly and -RestoreBackup, and for the
    bundle database fingerprint ('bundleDb' in .darktide-loader.json) that both of
    them, and a normal install, record after patching.

    As in Loader.Tests.ps1, -PatcherPath points at a stub that logs its arguments, so
    the tests can assert the loader is patched with an explicit --patch/--unpatch and
    never with the toggle. The -PatchOnly and -RestoreBackup contexts build the
    installed loader by hand rather than through an install, so they need no robocopy.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:Dispatcher = Join-Path $script:RepoRoot 'darktide.ps1'
    $script:Loaderer   = Join-Path $script:RepoRoot 'Install-DarktideLoader.ps1'

    $script:EntryName  = '9ba626afa44a3aa3.patch_999'

    function New-FakeLoaderPayload {
        <# A directory shaped like the real Darktide Mod Loader download. #>
        param([Parameter(Mandatory)][string] $Path, [string] $Tag = 'loader')

        foreach ($d in @('binaries', 'bundle', 'tools', 'mods\base\function')) {
            [void][System.IO.Directory]::CreateDirectory((Join-Path $Path $d))
        }
        Set-Content -LiteralPath (Join-Path $Path 'binaries\mod_loader') -Value "$Tag binary" -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $Path "bundle\$script:EntryName") -Value "$Tag entry bundle" -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $Path 'tools\dtkit-patch.exe') -Value 'stub' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $Path 'toggle_darktide_mods.bat') -Value '@echo off' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $Path 'mods\base\mod_manager.lua') -Value '-- base' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $Path 'mods\base\function\hook.lua') -Value '-- hook' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $Path 'mods\mod_load_order.txt') -Value @(
            '-- loader default list', 'base') -Encoding UTF8
        return $Path
    }

    function New-PatcherStub {
        <#
            Records each invocation's arguments to a log file instead of patching.
            A .cmd on Windows, as in Loader.Tests.ps1; elsewhere a shell script, so the
            contexts that need no robocopy also say something off Windows.
        #>
        param(
            [Parameter(Mandatory)][string] $Path,
            [Parameter(Mandatory)][string] $LogFile,
            [int] $ExitCode = 0
        )

        if ($env:OS -eq 'Windows_NT') {
            $file = "$Path.cmd"
            Set-Content -LiteralPath $file -Encoding ASCII -Value @(
                '@echo off',
                "echo %* >> ""$LogFile""",
                "exit /b $ExitCode"
            )
        } else {
            $file = "$Path.sh"
            Set-Content -LiteralPath $file -Encoding ASCII -Value @(
                '#!/bin/sh',
                "echo ""`$*"" >> '$LogFile'",
                "exit $ExitCode"
            )
            & chmod '+x' $file
        }
        return $file
    }

    function Set-LoaderState {
        param([Parameter(Mandatory)][string] $Folder, [Parameter(Mandatory)][System.Collections.IDictionary] $State)
        $State | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $Folder '.darktide-loader.json') -Encoding UTF8
    }

    function Get-LoaderState {
        param([Parameter(Mandatory)][string] $Folder)
        Get-Content -LiteralPath (Join-Path $Folder '.darktide-loader.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    function Add-FakeLoaderFiles {
        <#
            The loader's own files, written straight into a folder - a game folder or
            a loader backup - plus an optional state record in the pre-fingerprint
            shape (no bundleDb).
        #>
        param(
            [Parameter(Mandatory)][string] $Folder,
            [string] $Tag = 'loader',
            [string] $Version
        )
        foreach ($d in @('binaries', 'bundle', 'tools')) {
            [void][System.IO.Directory]::CreateDirectory((Join-Path $Folder $d))
        }
        Set-Content -LiteralPath (Join-Path $Folder 'binaries\mod_loader') -Value "$Tag binary" -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $Folder "bundle\$script:EntryName") -Value "$Tag entry bundle" -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $Folder 'tools\dtkit-patch.exe') -Value "$Tag patcher" -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $Folder 'toggle_darktide_mods.bat') -Value '@echo off' -Encoding ASCII
        if ($Version) {
            Set-LoaderState -Folder $Folder -State ([ordered]@{
                modId       = 19
                name        = 'Darktide Mod Loader'
                version     = $Version
                source      = "Darktide_Mod_Loader_19_$($Version -replace '\.', '_')"
                installedAt = '2026-06-24T06:07:00.0000000+00:00'
                patched     = $true
            })
        }
    }

    function Get-PatchLines {
        if (-not (Test-Path -LiteralPath $script:PatchLog)) { return @() }
        return @(Get-Content -LiteralPath $script:PatchLog | Where-Object { $_.Trim() })
    }

    function Get-DbHash {
        (Get-FileHash -LiteralPath (Join-Path $script:Game 'bundle\bundle_database.data') -Algorithm SHA256).Hash
    }

    function New-Sandbox {
        $script:Root     = New-TestSandbox
        $script:Game     = New-FakeGameFolder -Root $script:Root
        $script:Staging  = New-FakeStaging -Root $script:Root -Mods @('alpha_mod')
        $script:Config   = New-TestConfig -Root $script:Root -StagingMods $script:Staging -GamePath $script:Game
        # Loader backups sit beside staging, so under the sandbox root.
        $script:Backups  = Join-Path $script:Root 'loader_backups'
        $script:PatchLog = Join-Path $script:Root 'patch.log'
        $script:Patcher  = New-PatcherStub -Path (Join-Path $script:Root 'dtkit-patch') -LogFile $script:PatchLog
    }

    function Invoke-Loader {
        <# Runs the loader script with the sandbox config and the stub patcher. #>
        param([hashtable] $Extra = @{})
        $params = @{ ConfigPath = $script:Config; PatcherPath = $script:Patcher; Confirm = $false }
        foreach ($k in $Extra.Keys) { $params[$k] = $Extra[$k] }
        $global:LASTEXITCODE = 0
        return (& $script:Loaderer @params *>&1 | Out-String)
    }
}

Describe 'loader -PatchOnly' {

    BeforeEach {
        New-Sandbox
        Add-FakeLoaderFiles -Folder $script:Game -Version '26.06.24'
        Set-Content -LiteralPath (Join-Path $script:Game 'bundle\bundle_database.data') -Value 'database as Steam shipped it' -Encoding ASCII
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'patching' {

        It 'calls the patcher once with --patch, and never --unpatch or --toggle' {
            Invoke-Loader @{ PatchOnly = $true; Apply = $true } | Out-Null

            $lines = @(Get-PatchLines)
            $lines.Count | Should -Be 1
            $lines[0]    | Should -Match '^--patch\b'
            ($lines -join ' ') | Should -Not -Match '--unpatch'
            ($lines -join ' ') | Should -Not -Match '--toggle'
        }

        It 'records the patched bundle fingerprint and keeps every existing field' {
            Invoke-Loader @{ PatchOnly = $true; Apply = $true } | Out-Null

            $state = Get-LoaderState -Folder $script:Game
            $state.version | Should -Be '26.06.24'
            $state.modId   | Should -Be 19
            $state.source  | Should -Be 'Darktide_Mod_Loader_19_26_06_24'

            $db   = $state.bundleDb
            $item = Get-Item -LiteralPath (Join-Path $script:Game 'bundle\bundle_database.data')
            $db.sha256 | Should -Be (Get-DbHash)
            $db.length | Should -Be $item.Length
            # pwsh 7's ConvertFrom-Json turns ISO strings into dates; 5.1 leaves them.
            $written = $db.lastWriteTimeUtc
            if ($written -isnot [datetime]) {
                $written = [datetime]::Parse($written, [Globalization.CultureInfo]::InvariantCulture, 'RoundtripKind')
            }
            $written.ToUniversalTime() | Should -Be $item.LastWriteTimeUtc
            "$($db.recordedAt)" | Should -Not -BeNullOrEmpty
        }

        It 'reads a state file written before the fingerprint existed' {
            # The fixture's state has no bundleDb at all; StrictMode must not trip on it.
            $out = Invoke-Loader @{ PatchOnly = $true }
            $out | Should -Match 'not recorded'
            $LASTEXITCODE | Should -Be 0
        }

        It 'copies the bundle database to loader_backups before patching' {
            Invoke-Loader @{ PatchOnly = $true; Apply = $true } | Out-Null

            $copies = @(Get-ChildItem -LiteralPath $script:Backups -File -Filter 'bundledb-*.data')
            $copies.Count | Should -Be 1
            Get-Content -LiteralPath $copies[0].FullName -Raw | Should -Match 'database as Steam shipped it'
        }

        It 'records nothing when the patcher fails' {
            $failing = New-PatcherStub -Path (Join-Path $script:Root 'dtkit-fails') -LogFile $script:PatchLog -ExitCode 1

            { & $script:Loaderer -ConfigPath $script:Config -PatcherPath $failing -PatchOnly -Apply -Confirm:$false *>&1 | Out-Null } |
                Should -Throw -ExpectedMessage '*dtkit-patch --patch failed*'

            (Get-LoaderState -Folder $script:Game).PSObject.Properties.Name | Should -Not -Contain 'bundleDb'
        }
    }

    Context 'dry run' {

        It 'writes nothing and calls no patcher' {
            $before = Get-TreeFingerprint -Path $script:Root

            $out = Invoke-Loader @{ PatchOnly = $true }

            $out | Should -Match 'Dry run complete'
            Get-TreeFingerprint -Path $script:Root | Should -Be $before
            Test-Path -LiteralPath $script:PatchLog | Should -BeFalse
            Test-Path -LiteralPath $script:Backups  | Should -BeFalse
        }
    }

    Context 'already patched' {

        BeforeEach {
            Invoke-Loader @{ PatchOnly = $true; Apply = $true } | Out-Null
            Remove-Item -LiteralPath $script:PatchLog -Force
        }

        It 'does nothing when the database matches the recorded fingerprint' {
            $before = Get-TreeFingerprint -Path $script:Root

            $out = Invoke-Loader @{ PatchOnly = $true; Apply = $true }

            $out | Should -Match 'Already patched'
            $LASTEXITCODE | Should -Be 0
            Test-Path -LiteralPath $script:PatchLog | Should -BeFalse
            Get-TreeFingerprint -Path $script:Root | Should -Be $before
        }

        It 'patches again once a game update replaces the database' {
            Set-Content -LiteralPath (Join-Path $script:Game 'bundle\bundle_database.data') -Value 'database after a Steam update' -Encoding ASCII

            Invoke-Loader @{ PatchOnly = $true; Apply = $true } | Out-Null

            @(Get-PatchLines).Count | Should -Be 1
            (Get-LoaderState -Folder $script:Game).bundleDb.sha256 | Should -Be (Get-DbHash)
        }
    }

    Context 'backup retention' {

        It 'keeps -KeepBackups database copies, counted apart from loader folders' {
            foreach ($n in 1..3) {
                [void][System.IO.Directory]::CreateDirectory((Join-Path $script:Backups "loader-2026010$n-120000"))
            }

            foreach ($n in 1..4) {
                Set-Content -LiteralPath (Join-Path $script:Game 'bundle\bundle_database.data') -Value "database $n" -Encoding ASCII
                Invoke-Loader @{ PatchOnly = $true; Apply = $true; KeepBackups = 2 } | Out-Null
            }

            $copies = @(Get-ChildItem -LiteralPath $script:Backups -File -Filter 'bundledb-*.data')
            $copies.Count | Should -Be 2
            # The two newest survive, even when every run fell in the same second.
            $kept = @($copies | ForEach-Object { (Get-Content -LiteralPath $_.FullName -Raw).Trim() } | Sort-Object)
            $kept -join ',' | Should -Be 'database 3,database 4'

            @(Get-ChildItem -LiteralPath $script:Backups -Directory -Filter 'loader-*').Count | Should -Be 2
        }
    }

    Context 'missing loader files' {

        It 'exits 1 and writes nothing when dtkit-patch.exe is gone' {
            Remove-Item -LiteralPath (Join-Path $script:Game 'tools\dtkit-patch.exe') -Force
            $before = Get-TreeFingerprint -Path $script:Root

            $out  = Invoke-Loader @{ PatchOnly = $true; Apply = $true }
            $code = $LASTEXITCODE

            $code | Should -Be 1
            $out  | Should -Match ([regex]::Escape('loader files missing: run .\darktide.ps1 loader -Apply -Force'))
            Test-Path -LiteralPath $script:PatchLog | Should -BeFalse
            Get-TreeFingerprint -Path $script:Root | Should -Be $before
        }

        It 'exits 1 when only the game''s own patch bundles are left' {
            Remove-Item -LiteralPath (Join-Path $script:Game "bundle\$script:EntryName") -Force
            # A game patch bundle is not the loader's mod entry bundle.
            Set-Content -LiteralPath (Join-Path $script:Game 'bundle\0123456789abcdef.patch_001') -Value 'game' -Encoding ASCII

            $out  = Invoke-Loader @{ PatchOnly = $true; Apply = $true }
            $code = $LASTEXITCODE

            $code | Should -Be 1
            $out  | Should -Match 'loader files missing'
            Test-Path -LiteralPath $script:PatchLog | Should -BeFalse
        }
    }

    Context 'refusing contradictions' {

        It 'refuses -PatchOnly with -RestoreBackup' {
            { & $script:Loaderer -ConfigPath $script:Config -PatcherPath $script:Patcher -PatchOnly -RestoreBackup *>&1 | Out-Null } |
                Should -Throw -ExpectedMessage '*not both*'
        }

        It 'refuses -PatchOnly with -SkipPatch' {
            { & $script:Loaderer -ConfigPath $script:Config -PatcherPath $script:Patcher -PatchOnly -SkipPatch *>&1 | Out-Null } |
                Should -Throw -ExpectedMessage '*SkipPatch*'
        }

        It 'refuses -BackupSet without -RestoreBackup' {
            { & $script:Loaderer -ConfigPath $script:Config -PatcherPath $script:Patcher -PatchOnly -BackupSet 'x' *>&1 | Out-Null } |
                Should -Throw -ExpectedMessage '*-RestoreBackup*'
        }
    }

    Context 'through darktide.ps1' {

        It 'passes -PatchOnly through, and a dry run writes nothing' {
            $before = Get-TreeFingerprint -Path $script:Root

            $out = & $script:Dispatcher loader -ConfigPath $script:Config -PatchOnly *>&1 | Out-String

            $out | Should -Match 'Re-patching the bundle database \(dry run\)'
            $out | Should -Match '--patch'
            Get-TreeFingerprint -Path $script:Root | Should -Be $before
        }

        It 'leaves exit code 1 when loader files are missing' {
            Remove-Item -LiteralPath (Join-Path $script:Game 'tools\dtkit-patch.exe') -Force
            $global:LASTEXITCODE = 0

            & $script:Dispatcher loader -ConfigPath $script:Config -PatchOnly -Apply *>&1 | Out-Null

            $LASTEXITCODE | Should -Be 1
        }
    }
}

Describe 'loader -RestoreBackup' {

    BeforeEach {
        New-Sandbox
        # What is installed now: v2.
        Add-FakeLoaderFiles -Folder $script:Game -Tag 'v2' -Version '01.07.26'
        # A backup of v1, in the shape this version writes (state record included).
        $script:SetV1 = Join-Path $script:Backups 'loader-20260624-060700'
        Add-FakeLoaderFiles -Folder $script:SetV1 -Tag 'v1' -Version '26.06.24'
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'dry run' {

        It 'lists the backups and writes nothing' {
            $before = Get-TreeFingerprint -Path $script:Root

            $out = Invoke-Loader @{ RestoreBackup = $true }

            $out | Should -Match 'loader-20260624-060700'
            $out | Should -Match '26\.06\.24'
            $out | Should -Match 'Dry run complete'
            Get-TreeFingerprint -Path $script:Root | Should -Be $before
            Test-Path -LiteralPath $script:PatchLog | Should -BeFalse
        }

        It 'is reachable through darktide.ps1 with -BackupSet' {
            Add-FakeLoaderFiles -Folder (Join-Path $script:Backups 'loader-20260801-090000') -Tag 'v3' -Version '01.08.26'
            $before = Get-TreeFingerprint -Path $script:Root

            $out = & $script:Dispatcher loader -ConfigPath $script:Config -RestoreBackup -BackupSet '20260624' *>&1 | Out-String

            $out | Should -Match 'Restoring a mod loader backup \(dry run\)'
            $out | Should -Match 'restore loader-20260624-060700'
            Get-TreeFingerprint -Path $script:Root | Should -Be $before
        }
    }

    Context 'apply' {

        It 'puts the backed-up loader files back' {
            Invoke-Loader @{ RestoreBackup = $true; Apply = $true } | Out-Null

            Get-Content -LiteralPath (Join-Path $script:Game 'binaries\mod_loader') -Raw | Should -Match 'v1 binary'
            Get-Content -LiteralPath (Join-Path $script:Game "bundle\$script:EntryName") -Raw | Should -Match 'v1 entry bundle'
        }

        It 'unpatches before copying and patches afterwards, never the toggle' {
            Invoke-Loader @{ RestoreBackup = $true; Apply = $true } | Out-Null

            $lines = @(Get-PatchLines)
            $lines.Count | Should -Be 2
            $lines[0] | Should -Match '^--unpatch\b'
            $lines[1] | Should -Match '^--patch\b'
            ($lines -join ' ') | Should -Not -Match '--toggle'
        }

        It 'restores the version record and records the new fingerprint' {
            Invoke-Loader @{ RestoreBackup = $true; Apply = $true } | Out-Null

            $state = Get-LoaderState -Folder $script:Game
            $state.version         | Should -Be '26.06.24'
            $state.restoredFrom    | Should -Be 'loader-20260624-060700'
            $state.bundleDb.sha256 | Should -Be (Get-DbHash)
        }

        It 'backs up the current loader first, state record included' {
            Invoke-Loader @{ RestoreBackup = $true; Apply = $true } | Out-Null

            $pre = @(Get-ChildItem -LiteralPath $script:Backups -Directory -Filter 'loader-*' |
                     Where-Object { $_.Name -ne 'loader-20260624-060700' })
            $pre.Count | Should -Be 1
            Get-Content -LiteralPath (Join-Path $pre[0].FullName 'binaries\mod_loader') -Raw | Should -Match 'v2 binary'
            (Get-LoaderState -Folder $pre[0].FullName).version | Should -Be '01.07.26'
        }

        It 'never copies game files back from an older full-folder backup' {
            # Backups made before this version copied all of binaries\ and bundle\.
            Set-Content -LiteralPath (Join-Path $script:SetV1 'binaries\Darktide.exe') -Value 'OLD exe' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $script:SetV1 'bundle\bundle_database.data') -Value 'OLD database' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $script:SetV1 'bundle\0123456789abcdef.patch_001') -Value 'OLD game patch' -Encoding ASCII
            $exe = Get-Content -LiteralPath (Join-Path $script:Game 'binaries\Darktide.exe') -Raw
            $db  = Get-DbHash

            Invoke-Loader @{ RestoreBackup = $true; Apply = $true } | Out-Null

            Get-Content -LiteralPath (Join-Path $script:Game 'binaries\Darktide.exe') -Raw | Should -Be $exe
            Get-DbHash | Should -Be $db
            Test-Path -LiteralPath (Join-Path $script:Game 'bundle\0123456789abcdef.patch_001') | Should -BeFalse
        }

        It 'marks the version restored-unknown when the backup has no state record' {
            Remove-Item -LiteralPath (Join-Path $script:SetV1 '.darktide-loader.json') -Force

            Invoke-Loader @{ RestoreBackup = $true; Apply = $true } | Out-Null

            $state = Get-LoaderState -Folder $script:Game
            $state.version | Should -Be 'restored-unknown'
            $state.PSObject.Properties.Name | Should -Not -Contain 'source'
        }
    }

    Context 'choosing a backup' {

        BeforeEach {
            $script:SetV0 = Join-Path $script:Backups 'loader-20260601-080000'
            Add-FakeLoaderFiles -Folder $script:SetV0 -Tag 'v0' -Version '01.06.26'
        }

        It 'takes the newest by default' {
            Invoke-Loader @{ RestoreBackup = $true; Apply = $true } | Out-Null
            (Get-LoaderState -Folder $script:Game).version | Should -Be '26.06.24'
        }

        It 'takes the one -BackupSet names' {
            Invoke-Loader @{ RestoreBackup = $true; Apply = $true; BackupSet = '20260601' } | Out-Null
            (Get-LoaderState -Folder $script:Game).version | Should -Be '01.06.26'
            Get-Content -LiteralPath (Join-Path $script:Game 'binaries\mod_loader') -Raw | Should -Match 'v0 binary'
        }

        It 'refuses a -BackupSet that matches more than one backup, writing nothing' {
            $before = Get-TreeFingerprint -Path $script:Root

            { & $script:Loaderer -ConfigPath $script:Config -PatcherPath $script:Patcher -RestoreBackup `
                                 -BackupSet '202606' -Apply -Confirm:$false *>&1 | Out-Null } |
                Should -Throw -ExpectedMessage '*matches 2 loader backups*'

            Get-TreeFingerprint -Path $script:Root | Should -Be $before
        }

        It 'refuses a -BackupSet that matches nothing' {
            { & $script:Loaderer -ConfigPath $script:Config -PatcherPath $script:Patcher -RestoreBackup `
                                 -BackupSet 'nope' *>&1 | Out-Null } |
                Should -Throw -ExpectedMessage '*No loader backup matches*'
        }

        It 'refuses a backup that does not hold a complete loader' {
            Remove-Item -LiteralPath (Join-Path $script:SetV1 'tools\dtkit-patch.exe') -Force

            { & $script:Loaderer -ConfigPath $script:Config -PatcherPath $script:Patcher -RestoreBackup `
                                 -Apply -Confirm:$false *>&1 | Out-Null } |
                Should -Throw -ExpectedMessage '*does not hold a complete loader*'
            Test-Path -LiteralPath $script:PatchLog | Should -BeFalse
        }
    }

    Context 'no backups' {

        It 'says so instead of guessing' {
            Remove-Item -LiteralPath $script:Backups -Recurse -Force

            { & $script:Loaderer -ConfigPath $script:Config -PatcherPath $script:Patcher -RestoreBackup *>&1 | Out-Null } |
                Should -Throw -ExpectedMessage '*No loader backups*'
        }
    }
}

Describe 'install and restore round trip' {
    # These go through a real install, which copies with robocopy: Windows only.

    BeforeEach {
        New-Sandbox
        Remove-Item -LiteralPath (Join-Path $script:Game 'toggle_darktide_mods.bat') -Force -ErrorAction SilentlyContinue
        $script:V1 = New-FakeLoaderPayload -Path (Join-Path $script:Root 'Darktide_Mod_Loader_19_26_06_24_2026_06_24T06_07Z_x_1') -Tag 'v1'
        $script:V2 = New-FakeLoaderPayload -Path (Join-Path $script:Root 'Darktide_Mod_Loader_19_01_07_26_2026_07_01T00_00Z_y_1') -Tag 'v2'
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'records the bundle fingerprint on a normal install' {
        Invoke-Loader @{ Source = $script:V1; Apply = $true } | Out-Null

        $state = Get-LoaderState -Folder $script:Game
        $state.version         | Should -Be '26.06.24'
        $state.patched         | Should -BeTrue
        $state.bundleDb.sha256 | Should -Be (Get-DbHash)
        $state.bundleDb.length | Should -BeGreaterThan 0
    }

    It 'keeps fields other tools wrote to the state file' {
        Invoke-Loader @{ Source = $script:V1; Apply = $true } | Out-Null
        $state = Get-Content -LiteralPath (Join-Path $script:Game '.darktide-loader.json') -Raw | ConvertFrom-Json
        $state | Add-Member -NotePropertyName 'otherTool' -NotePropertyValue 'kept'
        $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $script:Game '.darktide-loader.json') -Encoding UTF8

        Invoke-Loader @{ Source = $script:V2; Apply = $true } | Out-Null

        $after = Get-LoaderState -Folder $script:Game
        $after.version   | Should -Be '01.07.26'
        $after.otherTool | Should -Be 'kept'
    }

    It 'does not record a fingerprint when -SkipPatch skips patching' {
        Invoke-Loader @{ Source = $script:V1; Apply = $true; SkipPatch = $true } | Out-Null

        $state = Get-LoaderState -Folder $script:Game
        $state.patched | Should -BeFalse
        $state.PSObject.Properties.Name | Should -Not -Contain 'bundleDb'
    }

    It 'backs up only loader files and the state record when updating' {
        Invoke-Loader @{ Source = $script:V1; Apply = $true } | Out-Null
        Invoke-Loader @{ Source = $script:V2; Apply = $true } | Out-Null

        $sets = @(Get-ChildItem -LiteralPath $script:Backups -Directory -Filter 'loader-*')
        $sets.Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $sets[0].FullName '.darktide-loader.json')       | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $sets[0].FullName 'binaries\mod_loader')         | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $sets[0].FullName 'binaries\Darktide.exe')       | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $sets[0].FullName 'bundle\bundle_database.data') | Should -BeFalse
    }

    It 'installs v1, updates to v2, and restores v1' {
        Invoke-Loader @{ Source = $script:V1; Apply = $true } | Out-Null
        Invoke-Loader @{ Source = $script:V2; Apply = $true } | Out-Null
        Get-Content -LiteralPath (Join-Path $script:Game 'binaries\mod_loader') -Raw | Should -Match 'v2 binary'
        Remove-Item -LiteralPath $script:PatchLog -Force

        Invoke-Loader @{ RestoreBackup = $true; Apply = $true } | Out-Null

        Get-Content -LiteralPath (Join-Path $script:Game 'binaries\mod_loader') -Raw | Should -Match 'v1 binary'
        $state = Get-LoaderState -Folder $script:Game
        $state.version         | Should -Be '26.06.24'
        $state.bundleDb.sha256 | Should -Be (Get-DbHash)

        $lines = @(Get-PatchLines)
        $lines.Count | Should -Be 2
        $lines[0] | Should -Match '^--unpatch\b'
        $lines[1] | Should -Match '^--patch\b'

        # The v2 loader it replaced is backed up, so the restore can itself be undone.
        $sets = @(Get-ChildItem -LiteralPath $script:Backups -Directory -Filter 'loader-*')
        $sets.Count | Should -Be 2
        $v2Backup = @($sets | Where-Object {
            (Get-Content -LiteralPath (Join-Path $_.FullName 'binaries\mod_loader') -Raw) -match 'v2 binary' })
        $v2Backup.Count | Should -Be 1
        (Get-LoaderState -Folder $v2Backup[0].FullName).version | Should -Be '01.07.26'
    }

    It 'treats a restored v1 as out of date for the v2 download' {
        Invoke-Loader @{ Source = $script:V1; Apply = $true } | Out-Null
        Invoke-Loader @{ Source = $script:V2; Apply = $true } | Out-Null
        Invoke-Loader @{ RestoreBackup = $true; Apply = $true } | Out-Null

        $out = Invoke-Loader @{ Source = $script:V2 }
        $out | Should -Match 'updating 26\.06\.24 -> 01\.07\.26'
    }
}
