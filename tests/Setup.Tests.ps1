<#
    Tests for Initialize-DarktideConfig.ps1 - the automatic game-folder detection.

    The registry lookup itself cannot be faked in-process, so the parts that read
    the machine are tested through their inputs: a synthetic Steam library tree
    built in the sandbox, and explicit -GamePath.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $script:Initer = Join-Path (Split-Path -Parent $PSScriptRoot) 'Initialize-DarktideConfig.ps1'

    Import-ScriptFunctions -Path $script:Initer -Name @('Test-DarktideFolder', 'Get-SteamLibrary')
}

Describe 'Test-DarktideFolder' {

    BeforeEach {
        $script:Root = New-TestSandbox
    }

    AfterEach {
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'accepts a folder holding real game files' {
        $game = New-FakeGameFolder -Root $script:Root
        Test-DarktideFolder -Path $game | Should -BeTrue
    }

    It 'accepts a folder identified by any single marker' {
        $game = Join-Path $script:Root 'partial'
        New-Item -ItemType Directory -Path (Join-Path $game 'bundle') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $game 'bundle\bundle_database.data') -Value 'x' -Encoding ASCII

        Test-DarktideFolder -Path $game | Should -BeTrue
    }

    It 'rejects a folder that merely has the right name' {
        $decoy = Join-Path $script:Root 'Warhammer 40,000 DARKTIDE'
        New-Item -ItemType Directory -Path $decoy -Force | Out-Null

        Test-DarktideFolder -Path $decoy | Should -BeFalse
    }

    It 'rejects a path that does not exist' {
        Test-DarktideFolder -Path (Join-Path $script:Root 'nope') | Should -BeFalse
    }

    It 'rejects an empty path' {
        Test-DarktideFolder -Path '' | Should -BeFalse
    }
}

Describe 'Get-SteamLibrary' {

    BeforeEach {
        $script:Root  = New-TestSandbox
        $script:Steam = Join-Path $script:Root 'Steam'
        New-Item -ItemType Directory -Path (Join-Path $script:Steam 'steamapps') -Force | Out-Null

        # A second library on another "drive", which is the case that matters:
        # the game is very often not under the Steam install itself.
        $script:Second = Join-Path $script:Root 'GamesLibrary'
        New-Item -ItemType Directory -Path (Join-Path $script:Second 'steamapps') -Force | Out-Null

        # libraryfolders.vdf escapes backslashes, as Steam writes it.
        $escapedSteam  = $script:Steam  -replace '\\', '\\'
        $escapedSecond = $script:Second -replace '\\', '\\'
        @(
            '"libraryfolders"',
            '{',
            '    "0"',
            '    {',
            "        `"path`"        `"$escapedSteam`"",
            '    }',
            '    "1"',
            '    {',
            "        `"path`"        `"$escapedSecond`"",
            '    }',
            '}'
        ) | Set-Content -LiteralPath (Join-Path $script:Steam 'steamapps\libraryfolders.vdf') -Encoding UTF8
    }

    AfterEach {
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns the Steam root itself' {
        $libs = Get-SteamLibrary -SteamRoot $script:Steam
        $libs | Should -Contain $script:Steam
    }

    It 'finds a library on another drive from the vdf' {
        $libs = Get-SteamLibrary -SteamRoot $script:Steam
        $libs | Should -Contain $script:Second
    }

    It 'unescapes the doubled backslashes Steam writes' {
        $libs = Get-SteamLibrary -SteamRoot $script:Steam
        @($libs | Where-Object { $_ -like '*\\\\*' }) | Should -BeNullOrEmpty
    }

    It 'skips libraries that no longer exist on disk' {
        Remove-Item -LiteralPath $script:Second -Recurse -Force

        $libs = Get-SteamLibrary -SteamRoot $script:Steam
        $libs | Should -Not -Contain $script:Second
    }

    It 'copes with no Steam root at all' {
        { Get-SteamLibrary -SteamRoot '' } | Should -Not -Throw
    }
}

Describe 'Initialize-DarktideConfig' {

    BeforeEach {
        $script:Root   = New-TestSandbox
        $script:Game   = New-FakeGameFolder -Root $script:Root
        $script:Config = Join-Path $script:Root 'config.json'
        $script:Mods   = Join-Path $script:Root 'staging'
    }

    AfterEach {
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'writes a usable config from an explicit game path' {
        & $script:Initer -ConfigPath $script:Config -GamePath $script:Game -ModsRoot $script:Mods -Confirm:$false *>&1 | Out-Null

        Test-Path -LiteralPath $script:Config | Should -BeTrue
        $cfg = Get-Content -LiteralPath $script:Config -Raw -Encoding UTF8 | ConvertFrom-Json

        $cfg.GamePath   | Should -Be $script:Game
        $cfg.ModsRoot   | Should -Be $script:Mods
        $cfg.GameDomain | Should -Be 'warhammer40kdarktide'
        $cfg.PSObject.Properties.Name | Should -Not -Contain 'ApiKey'
    }

    It 'does not persist NEXUS_API_KEY into config.json' {
        $prev = $env:NEXUS_API_KEY
        try {
            $env:NEXUS_API_KEY = 'should-never-land-in-config'
            & $script:Initer -ConfigPath $script:Config -GamePath $script:Game -ModsRoot $script:Mods -Confirm:$false *>&1 | Out-Null

            $raw = Get-Content -LiteralPath $script:Config -Raw -Encoding UTF8
            $raw | Should -Not -Match 'ApiKey'
            $raw | Should -Not -Match 'should-never-land-in-config'
        } finally {
            if ($null -eq $prev) { Remove-Item Env:NEXUS_API_KEY -ErrorAction SilentlyContinue }
            else { $env:NEXUS_API_KEY = $prev }
        }
    }

    It 'derives both backup folders' {
        & $script:Initer -ConfigPath $script:Config -GamePath $script:Game -ModsRoot $script:Mods -Confirm:$false *>&1 | Out-Null
        $cfg = Get-Content -LiteralPath $script:Config -Raw -Encoding UTF8 | ConvertFrom-Json

        $cfg.BackupRoot       | Should -Not -BeNullOrEmpty
        $cfg.DeployBackupRoot | Should -Not -BeNullOrEmpty
        $cfg.BackupRoot       | Should -Not -Be $cfg.DeployBackupRoot
    }

    It 'creates the staging folder so status has something to report' {
        & $script:Initer -ConfigPath $script:Config -GamePath $script:Game -ModsRoot $script:Mods -Confirm:$false *>&1 | Out-Null

        Test-Path -LiteralPath $script:Mods | Should -BeTrue
    }

    It 'refuses a game path that is not Darktide' {
        $decoy = Join-Path $script:Root 'not-the-game'
        New-Item -ItemType Directory -Path $decoy -Force | Out-Null

        { & $script:Initer -ConfigPath $script:Config -GamePath $decoy -ModsRoot $script:Mods -Confirm:$false } |
            Should -Throw -ExpectedMessage '*does not look like a Darktide install*'
    }

    It 'does not overwrite an existing config' {
        Set-Content -LiteralPath $script:Config -Value '{"ModsRoot":"D:\\keep\\me"}' -Encoding UTF8

        & $script:Initer -ConfigPath $script:Config -GamePath $script:Game -ModsRoot $script:Mods -Confirm:$false *>&1 | Out-Null

        (Get-Content -LiteralPath $script:Config -Raw | ConvertFrom-Json).ModsRoot | Should -Be 'D:\keep\me'
    }

    It 'overwrites when -Force is given' {
        Set-Content -LiteralPath $script:Config -Value '{"ModsRoot":"D:\\keep\\me"}' -Encoding UTF8

        & $script:Initer -ConfigPath $script:Config -GamePath $script:Game -ModsRoot $script:Mods -Force -Confirm:$false *>&1 | Out-Null

        (Get-Content -LiteralPath $script:Config -Raw | ConvertFrom-Json).ModsRoot | Should -Be $script:Mods
    }

    It 'writes nothing under -WhatIf' {
        & $script:Initer -ConfigPath $script:Config -GamePath $script:Game -ModsRoot $script:Mods -WhatIf *>&1 | Out-Null

        Test-Path -LiteralPath $script:Config | Should -BeFalse
    }

    It 'produces a config the other tools can actually consume' {
        & $script:Initer -ConfigPath $script:Config -GamePath $script:Game -ModsRoot $script:Mods -Confirm:$false *>&1 | Out-Null

        # A deploy dry run against the generated config must get as far as its plan.
        $deployer = Join-Path (Split-Path -Parent $PSScriptRoot) 'Deploy-DarktideMods.ps1'
        New-Item -ItemType Directory -Path (Join-Path $script:Mods 'some_mod') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Mods 'mod_load_order.txt') -Value 'some_mod' -Encoding UTF8

        $out = & $deployer -ConfigPath $script:Config *>&1 | Out-String
        $out | Should -Match 'Plan'
    }
}
