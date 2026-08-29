<#
    Tests for Export-DarktideLoadout.ps1 - the personal loadout backup archive.

    This is the one artefact that does contain third-party mod files, so the tests
    pin down that it is written where the user asked, never inside the folder being
    archived, and never silently over the top of an existing backup.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:Exporter = Join-Path (Split-Path -Parent $PSScriptRoot) 'Export-DarktideLoadout.ps1'

    function Get-ZipEntryNames {
        param([Parameter(Mandatory)][string] $Path)
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try { return @($zip.Entries | ForEach-Object { $_.FullName }) } finally { $zip.Dispose() }
    }
}

Describe 'Export-DarktideLoadout' {

    BeforeEach {
        $script:Root    = New-TestSandbox
        $script:Game    = New-FakeGameFolder -Root $script:Root
        $script:Staging = New-FakeStaging -Root $script:Root -Mods @('alpha_mod', 'beta_mod')
        $script:Config  = New-TestConfig -Root $script:Root -StagingMods $script:Staging -GamePath $script:Game
        $script:Out     = Join-Path $script:Root 'loadout.zip'
    }

    AfterEach {
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'building the archive' {

        BeforeEach {
            & $script:Exporter -ConfigPath $script:Config -OutFile $script:Out -Confirm:$false *>&1 | Out-Null
        }

        It 'writes the archive where it was asked to' {
            Test-Path -LiteralPath $script:Out | Should -BeTrue
            (Get-Item -LiteralPath $script:Out).Length | Should -BeGreaterThan 0
        }

        It 'contains every mod folder' {
            $names = Get-ZipEntryNames -Path $script:Out
            $names | Should -Contain 'alpha_mod/alpha_mod.mod'
            $names | Should -Contain 'beta_mod/beta_mod.mod'
            $names | Should -Contain 'base/base.mod'
            $names | Should -Contain 'dmf/dmf.mod'
        }

        It 'uses forward slashes so it opens correctly on any tool' {
            # .NET Framework's CreateFromDirectory writes backslashes, which the ZIP
            # format does not allow; 7-Zip and Linux unzip mangle such archives.
            $names = Get-ZipEntryNames -Path $script:Out
            @($names | Where-Object { $_ -like '*\*' }) | Should -BeNullOrEmpty
        }

        It 'carries the load order so the loadout can be rebuilt' {
            Get-ZipEntryNames -Path $script:Out | Should -Contain 'mod_load_order.txt'
        }

        It 'includes a restore note' {
            Get-ZipEntryNames -Path $script:Out | Should -Contain 'README.txt'
        }

        It 'round-trips: extracting it reproduces the mod files' {
            $restore = Join-Path $script:Root 'restored'
            [System.IO.Compression.ZipFile]::ExtractToDirectory($script:Out, $restore)

            Test-Path (Join-Path $restore 'alpha_mod\alpha_mod.mod') | Should -BeTrue
            $original = Get-Content -LiteralPath (Join-Path $script:Staging 'alpha_mod\info.json') -Raw
            $copy     = Get-Content -LiteralPath (Join-Path $restore  'alpha_mod\info.json') -Raw
            $copy | Should -Be $original
        }
    }

    Context 'what it leaves out' {

        It 'skips the updater half-finished staging folders' {
            $junk = Join-Path $script:Staging '.staging-alpha_mod'
            New-Item -ItemType Directory -Path $junk -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $junk 'partial.txt') -Value 'incomplete' -Encoding UTF8

            & $script:Exporter -ConfigPath $script:Config -OutFile $script:Out -Confirm:$false *>&1 | Out-Null

            $names = Get-ZipEntryNames -Path $script:Out
            @($names | Where-Object { $_ -like '.staging-*' }) | Should -BeNullOrEmpty
        }
    }

    Context 'refusing to do something destructive' {

        It 'will not overwrite an existing archive without -Force' {
            Set-Content -LiteralPath $script:Out -Value 'precious' -Encoding UTF8

            { & $script:Exporter -ConfigPath $script:Config -OutFile $script:Out -Confirm:$false } |
                Should -Throw -ExpectedMessage '*already exists*'

            Get-Content -LiteralPath $script:Out -Raw | Should -Match 'precious'
        }

        It 'overwrites when -Force is given' {
            Set-Content -LiteralPath $script:Out -Value 'precious' -Encoding UTF8

            & $script:Exporter -ConfigPath $script:Config -OutFile $script:Out -Force -Confirm:$false *>&1 | Out-Null

            Get-ZipEntryNames -Path $script:Out | Should -Contain 'alpha_mod/alpha_mod.mod'
        }

        It 'refuses to write the archive inside the folder it is archiving' {
            $inside = Join-Path $script:Staging 'loadout.zip'

            { & $script:Exporter -ConfigPath $script:Config -OutFile $inside -Confirm:$false } |
                Should -Throw -ExpectedMessage '*inside the mods folder*'
        }

        It 'refuses when the staging folder does not exist' {
            { & $script:Exporter -ConfigPath $script:Config -StagingMods (Join-Path $script:Root 'nope') `
                                 -OutFile $script:Out -Confirm:$false } |
                Should -Throw -ExpectedMessage '*does not exist*'
        }
    }

    Context 'dry run' {

        It 'writes nothing under -WhatIf' {
            & $script:Exporter -ConfigPath $script:Config -OutFile $script:Out -WhatIf -Confirm:$false *>&1 | Out-Null

            Test-Path -LiteralPath $script:Out | Should -BeFalse
        }

        It 'leaves no temporary staging directory behind' {
            & $script:Exporter -ConfigPath $script:Config -OutFile $script:Out -Confirm:$false *>&1 | Out-Null

            @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter 'dt-export-*' `
              -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
        }
    }

    Context 're-running' {

        It 'produces an archive with the same contents each time' {
            & $script:Exporter -ConfigPath $script:Config -OutFile $script:Out -Confirm:$false *>&1 | Out-Null
            $first = (Get-ZipEntryNames -Path $script:Out | Sort-Object) -join "`n"

            & $script:Exporter -ConfigPath $script:Config -OutFile $script:Out -Force -Confirm:$false *>&1 | Out-Null
            $second = (Get-ZipEntryNames -Path $script:Out | Sort-Object) -join "`n"

            $second | Should -Be $first
        }
    }
}
