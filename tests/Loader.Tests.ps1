<#
    Tests for Install-DarktideLoader.ps1.

    The real dtkit-patch.exe rewrites the game's bundle database, so the tests point
    -PatcherPath at a stub that records the arguments it was called with. That lets us
    assert the thing that actually matters: the loader is patched with an explicit
    --patch/--unpatch, never with the toggle, because toggling twice turns mods off.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $script:Loaderer = Join-Path (Split-Path -Parent $PSScriptRoot) 'Install-DarktideLoader.ps1'
    Import-ScriptFunctions -Path $script:Loaderer -Name @('Get-LoaderVersionFromName', 'Test-LoaderSource')

    function New-FakeLoaderPayload {
        <# A directory shaped like the real Darktide Mod Loader download. #>
        param([Parameter(Mandatory)][string] $Path)

        New-Item -ItemType Directory -Path (Join-Path $Path 'binaries')  -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $Path 'bundle')    -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $Path 'tools')     -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $Path 'mods\base\function') -Force | Out-Null

        Set-Content -LiteralPath (Join-Path $Path 'binaries\mod_loader') -Value 'loader binary' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $Path 'bundle\9ba626afa44a3aa3.patch_999') -Value 'mod entry bundle' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $Path 'tools\dtkit-patch.exe') -Value 'stub' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $Path 'toggle_darktide_mods.bat') -Value '@echo off' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $Path 'mods\base\mod_manager.lua') -Value '-- base' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $Path 'mods\base\function\hook.lua') -Value '-- hook' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $Path 'mods\mod_load_order.txt') -Value @(
            '-- loader default list', 'base') -Encoding UTF8
        return $Path
    }

    function New-PatcherStub {
        <# Records each invocation's arguments to a log file instead of patching. #>
        param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $LogFile)

        $cmd = @(
            '@echo off',
            "echo %* >> ""$LogFile""",
            'exit /b 0'
        )
        Set-Content -LiteralPath $Path -Value $cmd -Encoding ASCII
        return $Path
    }
}

Describe 'Get-LoaderVersionFromName' {

    It 'reads the version from the extracted folder name' {
        # This is the real shape: mod id 19, version 26.06.24, then an ISO timestamp
        # the browser appended - which must not be swallowed into the version.
        Get-LoaderVersionFromName -Name 'Darktide_Mod_Loader_19_26_06_24_2026_06_24T06_07Z_ndQ1md9gG_1' |
            Should -Be '26.06.24'
    }

    It 'reads the version from a stock Nexus archive name' {
        Get-LoaderVersionFromName -Name 'Darktide Mod Loader-19-26-06-24-1719209900.zip' |
            Should -Be '26.06.24'
    }

    It 'stops before a Nexus epoch suffix' {
        Get-LoaderVersionFromName -Name 'Darktide Mod Loader-19-2-14-4-1719209900.zip' |
            Should -Be '2.14.4'
    }

    It 'returns nothing when there is no version in the name' {
        Get-LoaderVersionFromName -Name 'mod_loader.zip' | Should -BeNullOrEmpty
        Get-LoaderVersionFromName -Name ''               | Should -BeNullOrEmpty
    }
}

Describe 'Test-LoaderSource' {

    BeforeEach { $script:Root = New-TestSandbox }
    AfterEach {
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'accepts a real loader payload' {
        $p = New-FakeLoaderPayload -Path (Join-Path $script:Root 'loader')
        Test-LoaderSource -Path $p | Should -BeTrue
    }

    It 'rejects a folder missing the patcher' {
        $p = New-FakeLoaderPayload -Path (Join-Path $script:Root 'loader')
        Remove-Item -LiteralPath (Join-Path $p 'tools\dtkit-patch.exe') -Force

        Test-LoaderSource -Path $p | Should -BeFalse
    }

    It 'rejects a folder missing the mod entry bundle' {
        $p = New-FakeLoaderPayload -Path (Join-Path $script:Root 'loader')
        Remove-Item -LiteralPath (Join-Path $p 'bundle\9ba626afa44a3aa3.patch_999') -Force

        Test-LoaderSource -Path $p | Should -BeFalse
    }

    It 'rejects an unrelated folder' {
        $p = Join-Path $script:Root 'random'
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        Test-LoaderSource -Path $p | Should -BeFalse
    }
}

Describe 'Install-DarktideLoader' {

    BeforeEach {
        $script:Root    = New-TestSandbox
        $script:Game    = New-FakeGameFolder -Root $script:Root
        $script:Staging = New-FakeStaging -Root $script:Root -Mods @('alpha_mod')
        $script:Config  = New-TestConfig -Root $script:Root -StagingMods $script:Staging -GamePath $script:Game

        # A payload whose folder name carries version 26.06.24.
        $script:Payload = New-FakeLoaderPayload -Path (Join-Path $script:Root 'Darktide_Mod_Loader_19_26_06_24_2026_06_24T06_07Z_x_1')

        $script:PatchLog = Join-Path $script:Root 'patch.log'
        $script:Patcher  = New-PatcherStub -Path (Join-Path $script:Root 'dtkit-patch.cmd') -LogFile $script:PatchLog

        # The fixture's game folder has no loader yet.
        Remove-Item -LiteralPath (Join-Path $script:Game 'toggle_darktide_mods.bat') -Force -ErrorAction SilentlyContinue
    }

    AfterEach {
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'dry run' {

        It 'writes nothing without -Apply' {
            & $script:Loaderer -ConfigPath $script:Config -Source $script:Payload -PatcherPath $script:Patcher *>&1 | Out-Null

            Test-Path (Join-Path $script:Game 'toggle_darktide_mods.bat') | Should -BeFalse
            Test-Path (Join-Path $script:Game '.darktide-loader.json')    | Should -BeFalse
            Test-Path -LiteralPath $script:PatchLog                       | Should -BeFalse
        }

        It 'reports the version it would install' {
            $out = & $script:Loaderer -ConfigPath $script:Config -Source $script:Payload -PatcherPath $script:Patcher *>&1 | Out-String
            $out | Should -Match '26\.06\.24'
        }
    }

    Context 'first install' {

        BeforeEach {
            & $script:Loaderer -ConfigPath $script:Config -Source $script:Payload `
                               -PatcherPath $script:Patcher -Apply -Confirm:$false *>&1 | Out-Null
        }

        It 'installs every loader file into the game folder' {
            Test-Path (Join-Path $script:Game 'toggle_darktide_mods.bat')            | Should -BeTrue
            Test-Path (Join-Path $script:Game 'binaries\mod_loader')                 | Should -BeTrue
            Test-Path (Join-Path $script:Game 'tools\dtkit-patch.exe')               | Should -BeTrue
            Test-Path (Join-Path $script:Game 'bundle\9ba626afa44a3aa3.patch_999')   | Should -BeTrue
        }

        It 'puts the DMF base mod into staging, not straight into the game' {
            Test-Path (Join-Path $script:Staging 'base\mod_manager.lua')        | Should -BeTrue
            Test-Path (Join-Path $script:Staging 'base\function\hook.lua')      | Should -BeTrue
        }

        It 'records the version' {
            $statePath = Join-Path $script:Game '.darktide-loader.json'
            Test-Path -LiteralPath $statePath | Should -BeTrue

            $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $state.version | Should -Be '26.06.24'
            $state.modId   | Should -Be 19
        }

        It 'patches with an explicit --patch, never the toggle' {
            $log = Get-Content -LiteralPath $script:PatchLog -Raw
            $log | Should -Match '--patch'
            $log | Should -Not -Match '--toggle'
        }

        It 'does not overwrite an existing mod_load_order.txt' {
            # The fixture's staging list must survive - it is the user's mod list.
            $order = Get-Content -LiteralPath (Join-Path $script:Staging 'mod_load_order.txt') -Raw
            $order | Should -Match 'alpha_mod'
            $order | Should -Not -Match 'loader default list'
        }
    }

    Context 'idempotency' {

        BeforeEach {
            & $script:Loaderer -ConfigPath $script:Config -Source $script:Payload `
                               -PatcherPath $script:Patcher -Apply -Confirm:$false *>&1 | Out-Null
            $script:AfterFirst = Get-TreeFingerprint -Path (Join-Path $script:Game 'binaries')
            Remove-Item -LiteralPath $script:PatchLog -Force -ErrorAction SilentlyContinue
        }

        It 'does nothing when the same version is already installed' {
            $out = & $script:Loaderer -ConfigPath $script:Config -Source $script:Payload `
                                      -PatcherPath $script:Patcher -Apply -Confirm:$false *>&1 | Out-String

            $out | Should -Match 'already up to date|is current'
            Get-TreeFingerprint -Path (Join-Path $script:Game 'binaries') | Should -Be $script:AfterFirst
        }

        It 'does not touch the bundle database on a no-op run' {
            & $script:Loaderer -ConfigPath $script:Config -Source $script:Payload `
                               -PatcherPath $script:Patcher -Apply -Confirm:$false *>&1 | Out-Null

            # No patcher call at all - so mods cannot be toggled off by re-running.
            Test-Path -LiteralPath $script:PatchLog | Should -BeFalse
        }

        It 'reinstalls when -Force is given' {
            & $script:Loaderer -ConfigPath $script:Config -Source $script:Payload `
                               -PatcherPath $script:Patcher -Apply -Force -Confirm:$false *>&1 | Out-Null

            Test-Path -LiteralPath $script:PatchLog | Should -BeTrue
        }
    }

    Context 'updating an older install' {

        BeforeEach {
            & $script:Loaderer -ConfigPath $script:Config -Source $script:Payload `
                               -PatcherPath $script:Patcher -Apply -Confirm:$false *>&1 | Out-Null
            Remove-Item -LiteralPath $script:PatchLog -Force -ErrorAction SilentlyContinue

            # A newer payload, version 01.07.26.
            $script:Newer = New-FakeLoaderPayload -Path (Join-Path $script:Root 'Darktide_Mod_Loader_19_01_07_26_2026_07_01T00_00Z_y_1')
            Set-Content -LiteralPath (Join-Path $script:Newer 'binaries\mod_loader') -Value 'NEWER loader binary' -Encoding ASCII
        }

        It 'replaces the loader files' {
            & $script:Loaderer -ConfigPath $script:Config -Source $script:Newer `
                               -PatcherPath $script:Patcher -Apply -Confirm:$false *>&1 | Out-Null

            Get-Content -LiteralPath (Join-Path $script:Game 'binaries\mod_loader') -Raw |
                Should -Match 'NEWER'
        }

        It 'records the new version' {
            & $script:Loaderer -ConfigPath $script:Config -Source $script:Newer `
                               -PatcherPath $script:Patcher -Apply -Confirm:$false *>&1 | Out-Null

            $state = Get-Content -LiteralPath (Join-Path $script:Game '.darktide-loader.json') -Raw | ConvertFrom-Json
            $state.version | Should -Be '01.07.26'
        }

        It 'unpatches before copying and re-patches afterwards' {
            # The loader's own instructions require this order; copying over a patched
            # database and only then re-patching is what corrupts installs.
            & $script:Loaderer -ConfigPath $script:Config -Source $script:Newer `
                               -PatcherPath $script:Patcher -Apply -Confirm:$false *>&1 | Out-Null

            $log = @(Get-Content -LiteralPath $script:PatchLog)
            ($log -join ' ') | Should -Match '--unpatch'
            ($log -join ' ') | Should -Match '--patch'

            $unpatchAt = ($log | Select-String -Pattern '--unpatch' | Select-Object -First 1).LineNumber
            $patchAt   = ($log | Select-String -Pattern '--patch(?!_)' | Where-Object { $_.Line -notmatch '--unpatch' } |
                          Select-Object -First 1).LineNumber
            $unpatchAt | Should -BeLessThan $patchAt
        }

        It 'backs up the loader it is replacing' {
            & $script:Loaderer -ConfigPath $script:Config -Source $script:Newer `
                               -PatcherPath $script:Patcher -Apply -Confirm:$false *>&1 | Out-Null

            $backups = @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'loader_backups') `
                         -Directory -ErrorAction SilentlyContinue)
            $backups.Count | Should -BeGreaterThan 0
        }
    }

    Context 'refusing bad input' {

        It 'refuses a game folder that is not Darktide' {
            $decoy = Join-Path $script:Root 'not-the-game'
            New-Item -ItemType Directory -Path $decoy -Force | Out-Null

            { & $script:Loaderer -ConfigPath $script:Config -GamePath $decoy -Source $script:Payload `
                                 -PatcherPath $script:Patcher -Apply -Confirm:$false } |
                Should -Throw -ExpectedMessage '*does not look like a Darktide install*'
        }

        It 'refuses a source that is not a loader payload' {
            $decoy = Join-Path $script:Root 'random-folder'
            New-Item -ItemType Directory -Path $decoy -Force | Out-Null

            { & $script:Loaderer -ConfigPath $script:Config -Source $decoy `
                                 -PatcherPath $script:Patcher -Apply -Confirm:$false } |
                Should -Throw -ExpectedMessage '*not a Darktide Mod Loader payload*'
        }

        It 'skips patching entirely with -SkipPatch' {
            & $script:Loaderer -ConfigPath $script:Config -Source $script:Payload `
                               -PatcherPath $script:Patcher -Apply -SkipPatch -Confirm:$false *>&1 | Out-Null

            Test-Path (Join-Path $script:Game 'toggle_darktide_mods.bat') | Should -BeTrue
            Test-Path -LiteralPath $script:PatchLog                       | Should -BeFalse
        }
    }

    Context 'installing from a zip' {

        It 'unpacks an archive and installs from it' {
            $zip = Join-Path $script:Root 'Darktide Mod Loader-19-26-06-24-1719209900.zip'
            [System.IO.Compression.ZipFile]::CreateFromDirectory($script:Payload, $zip)

            & $script:Loaderer -ConfigPath $script:Config -Source $zip `
                               -PatcherPath $script:Patcher -Apply -Confirm:$false *>&1 | Out-Null

            Test-Path (Join-Path $script:Game 'toggle_darktide_mods.bat') | Should -BeTrue
            $state = Get-Content -LiteralPath (Join-Path $script:Game '.darktide-loader.json') -Raw | ConvertFrom-Json
            $state.version | Should -Be '26.06.24'
        }

        It 'leaves no temporary extract folder behind' {
            $zip = Join-Path $script:Root 'Darktide Mod Loader-19-26-06-24-1719209900.zip'
            [System.IO.Compression.ZipFile]::CreateFromDirectory($script:Payload, $zip)

            & $script:Loaderer -ConfigPath $script:Config -Source $zip `
                               -PatcherPath $script:Patcher -Apply -Confirm:$false *>&1 | Out-Null

            @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter 'dt-loader-*' `
              -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
        }

        It 'rejects a traversal archive without writing loader files' {
            $zip = Join-Path $script:Root 'Darktide Mod Loader-19-26-06-24-1719209900.zip'
            $null = New-TestZip -Path $zip -Entries @{
                'toggle_darktide_mods.bat' = '@echo off'
                '../escaped.txt'           = 'pwned'
            }

            { & $script:Loaderer -ConfigPath $script:Config -Source $zip `
                                 -PatcherPath $script:Patcher -Apply -Confirm:$false } |
                Should -Throw -ExpectedMessage '*unsafe path*'

            Test-Path (Join-Path $script:Game 'toggle_darktide_mods.bat') | Should -BeFalse
            Test-Path (Join-Path $script:Root 'escaped.txt') | Should -BeFalse
        }
    }

    Context 'backup retention' {

        It 'keeps only the newest -KeepBackups loader folders' {
            & $script:Loaderer -ConfigPath $script:Config -Source $script:Payload `
                               -PatcherPath $script:Patcher -Apply -Confirm:$false *>&1 | Out-Null

            1..4 | ForEach-Object {
                & $script:Loaderer -ConfigPath $script:Config -Source $script:Payload `
                                   -PatcherPath $script:Patcher -Apply -Force -KeepBackups 2 `
                                   -Confirm:$false *>&1 | Out-Null
            }

            $backups = @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'loader_backups') `
                         -Directory -ErrorAction SilentlyContinue)
            $backups.Count | Should -BeLessOrEqual 2
        }
    }
}
