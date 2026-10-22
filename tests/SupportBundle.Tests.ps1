<#
    Tests for New-SupportBundle.ps1 and the 'support' verb.

    The bundle exists to be posted publicly, so most of what is pinned down here is
    what must NOT reach it: the API key, the user's name and profile path, Steam
    ids, and any mod file. Every fixture plants those deliberately and then looks
    for them in every entry of the finished zip.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:Dispatcher = Join-Path $script:RepoRoot 'darktide.ps1'
    $script:Bundler    = Join-Path $script:RepoRoot 'New-SupportBundle.ps1'

    # Planted values. The key stays under 30 characters so the validator's secret
    # scan does not mistake this file for a leak.
    $script:PlantedKey   = 'PLANTEDKEY123'
    $script:PlantedUser  = 'SomeUser'
    $script:PlantedSteam = '76561198012345678'

    function Get-ZipEntryNames {
        param([Parameter(Mandatory)][string] $Path)
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try { return @($zip.Entries | ForEach-Object { $_.FullName }) } finally { $zip.Dispose() }
    }

    function Get-ZipTexts {
        <# entry name -> full text, for every entry. #>
        param([Parameter(Mandatory)][string] $Path)
        $map = @{}
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            foreach ($e in $zip.Entries) {
                $r = New-Object System.IO.StreamReader($e.Open())
                try { $map[$e.FullName] = $r.ReadToEnd() } finally { $r.Dispose() }
            }
        } finally { $zip.Dispose() }
        return $map
    }

    function Invoke-Bundler {
        <# Runs the script against the sandbox with hermetic log folders. #>
        param([hashtable] $Extra = @{})
        $params = @{
            ConfigPath   = $script:Config
            UpdateLogDir = $script:ToolLogs
            LogDir       = $script:ConsoleLogs
            Confirm      = $false
        }
        foreach ($k in $Extra.Keys) { $params[$k] = $Extra[$k] }
        & $script:Bundler @params *>&1 | Out-Null
    }
}

Describe 'New-SupportBundle' {

    BeforeEach {
        $script:Root    = New-TestSandbox
        $script:Game    = New-FakeGameFolder -Root $script:Root
        $script:Staging = New-FakeStaging -Root $script:Root -Mods @('alpha_mod', 'beta_mod')
        $script:Config  = New-TestConfig -Root $script:Root -StagingMods $script:Staging -GamePath $script:Game
        $script:Out     = Join-Path $script:Root 'bundle.zip'

        # A key in the config, and a path that names the user.
        $c = Get-Content -LiteralPath $script:Config -Raw | ConvertFrom-Json
        $c.ApiKey = $script:PlantedKey
        $c.DownloadDir = "C:\Users\$($script:PlantedUser)\Downloads"
        $c | ConvertTo-Json | Set-Content -LiteralPath $script:Config -Encoding UTF8

        # A deployed copy, with mod files the bundle must never pick up.
        $gameMods = Join-Path $script:Game 'mods'
        foreach ($m in @('alpha_mod', 'beta_mod')) {
            $d = Join-Path $gameMods $m
            [void][System.IO.Directory]::CreateDirectory($d)
            Set-Content -LiteralPath (Join-Path $d "$m.mod") -Value 'return {}' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $d "$m.lua") -Value '-- mod code' -Encoding UTF8
            '{"name":"x","version":"1.0.0"}' | Set-Content -LiteralPath (Join-Path $d 'info.json') -Encoding UTF8
        }
        Set-Content -LiteralPath (Join-Path $gameMods 'mod_load_order.txt') -Value @('alpha_mod', 'beta_mod') -Encoding UTF8
        '{"modId":19,"name":"Darktide Mod Loader","version":"26.06.24"}' |
            Set-Content -LiteralPath (Join-Path $script:Game '.darktide-loader.json') -Encoding UTF8

        # The updater's log and a console log, both naming the user, a Steam id and the key.
        $script:ToolLogs = Join-Path $script:Root 'toollogs'
        [void][System.IO.Directory]::CreateDirectory($script:ToolLogs)
        Set-Content -LiteralPath (Join-Path $script:ToolLogs 'update-20260101-000000.log') -Encoding UTF8 -Value @(
            '00:00:01 [INFO ] start',
            "00:00:02 [INFO ] reading C:\Users\$($script:PlantedUser)\Downloads\Alpha Mod-447-2-0-0.zip",
            "00:00:03 [INFO ] account $($script:PlantedUser) steam $($script:PlantedSteam) key $($script:PlantedKey)",
            '00:00:04 [OK   ] Installed alpha_mod 2.0.0'
        )

        $script:ConsoleLogs = Join-Path $script:Root 'console_logs'
        [void][System.IO.Directory]::CreateDirectory($script:ConsoleLogs)
        $lines = New-Object System.Collections.Generic.List[string]
        for ($i = 1; $i -le 400; $i++) { $lines.Add("console line $i") }
        $lines.Add("[Steam] signed in as $($script:PlantedSteam)")
        $lines.Add("loading C:/Users/$($script:PlantedUser)/AppData/Roaming/Fatshark/Darktide/user_settings.config")
        $lines.Add('player alpha joined with alpha_mod loaded')
        # The user name straddles the line-length cut. Redacting first means no part
        # of it survives; cutting first would leave 'C:\Users\SomeU' behind.
        $lines.Add(('x' * 1985) + " C:\Users\$($script:PlantedUser)\file.txt")
        $lines.Add('last console line')
        Set-Content -LiteralPath (Join-Path $script:ConsoleLogs 'console-2026-01-01.log') -Value $lines -Encoding UTF8
    }

    AfterEach {
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'dry run' {

        It 'writes nothing anywhere in the sandbox' {
            $before = Get-TreeFingerprint -Path $script:Root
            Invoke-Bundler
            Get-TreeFingerprint -Path $script:Root | Should -Be $before
            Test-Path -LiteralPath (Join-Path $script:Root 'support') | Should -BeFalse
        }

        It 'falls back to the scripts folder when staging lives inside the game folder' {
            $inGame = Join-Path $script:Game 'mods'
            $c = Get-Content -LiteralPath $script:Config -Raw | ConvertFrom-Json
            $c.ModsRoot = $inGame
            $c | ConvertTo-Json | Set-Content -LiteralPath $script:Config -Encoding UTF8
            $before = Get-TreeFingerprint -Path $script:Root
            $text = (& $script:Bundler -ConfigPath $script:Config -UpdateLogDir $script:ToolLogs `
                        -LogDir $script:ConsoleLogs *>&1 | Out-String)
            $text | Should -Match ('Archive : ' + [regex]::Escape((Join-Path $script:RepoRoot 'support')))
            Get-TreeFingerprint -Path $script:Root | Should -Be $before
        }

        It 'does not write -OutFile without -Apply' {
            Invoke-Bundler -Extra @{ OutFile = $script:Out }
            Test-Path -LiteralPath $script:Out | Should -BeFalse
        }

        It 'lists the entries it would write' {
            $text = (& $script:Bundler -ConfigPath $script:Config -UpdateLogDir $script:ToolLogs `
                        -LogDir $script:ConsoleLogs *>&1 | Out-String)
            $text | Should -Match 'DRY RUN'
            $text | Should -Match 'environment\.txt'
            $text | Should -Match 'config\.redacted\.json'
            $text | Should -Match 'Nothing was written'
        }
    }

    Context 'with -Apply' {

        It 'writes to a support folder beside staging by default' {
            Invoke-Bundler -Extra @{ Apply = $true }
            $made = @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'support') -Filter 'darktide-support-*.zip' -File)
            $made.Count | Should -Be 1
        }

        It 'contains the expected entries' {
            Invoke-Bundler -Extra @{ Apply = $true; OutFile = $script:Out }
            $names = Get-ZipEntryNames -Path $script:Out
            foreach ($n in @('environment.txt', 'config.redacted.json', 'staging-listing.txt', 'game-listing.txt',
                             'staging/mod_load_order.txt', 'game/mod_load_order.txt', 'loader-state.json',
                             'darktide-modpack.lock.json', 'README.txt',
                             'logs/update-20260101-000000.log', 'console/console-2026-01-01.log')) {
                $names | Should -Contain $n
            }
        }

        It 'holds no mod file, archive or backslash entry name' {
            Invoke-Bundler -Extra @{ Apply = $true; OutFile = $script:Out }
            $names = Get-ZipEntryNames -Path $script:Out
            @($names | Where-Object { $_ -match '(?i)\.(mod|lua|zip)$' }) | Should -BeNullOrEmpty
            @($names | Where-Object { $_ -like '*\*' }) | Should -BeNullOrEmpty
        }

        It 'lists mod folders and versions but no file content' {
            Invoke-Bundler -Extra @{ Apply = $true; OutFile = $script:Out }
            $texts = Get-ZipTexts -Path $script:Out
            $texts['staging-listing.txt'] | Should -Match 'alpha_mod\s+1\.0\.0'
            $texts['game-listing.txt']    | Should -Match 'beta_mod\s+1\.0\.0'
            foreach ($t in $texts.Values) { $t | Should -Not -Match 'return \{' }
        }

        It 'leaks no key, user name or Steam id into any entry' {
            Invoke-Bundler -Extra @{ Apply = $true; OutFile = $script:Out }
            $texts = Get-ZipTexts -Path $script:Out
            foreach ($name in $texts.Keys) {
                $texts[$name] | Should -Not -Match ([regex]::Escape($script:PlantedKey))   -Because "$name must not carry the key"
                $texts[$name] | Should -Not -Match ([regex]::Escape($script:PlantedUser))  -Because "$name must not carry the user name"
                $texts[$name] | Should -Not -Match ([regex]::Escape($script:PlantedSteam)) -Because "$name must not carry a Steam id"
            }
            $texts['console/console-2026-01-01.log'] | Should -Match '<steamid>'
            $texts['logs/update-20260101-000000.log'] | Should -Match '%USERPROFILE%'
        }

        It 'drops the key from the config copy and keeps the rest' {
            Invoke-Bundler -Extra @{ Apply = $true; OutFile = $script:Out }
            $cfg = (Get-ZipTexts -Path $script:Out)['config.redacted.json'] | ConvertFrom-Json
            $cfg.PSObject.Properties.Name | Should -Not -Contain 'ApiKey'
            $cfg.PSObject.Properties.Name | Should -Contain 'ModsRoot'
            $cfg.DownloadDir | Should -Be '%USERPROFILE%\Downloads'
        }

        It 'says whether NEXUS_API_KEY is set but never its value' {
            $prev = $env:NEXUS_API_KEY
            try {
                $env:NEXUS_API_KEY = 'PLANTEDENV456'
                Invoke-Bundler -Extra @{ Apply = $true; OutFile = $script:Out }
            } finally { $env:NEXUS_API_KEY = $prev }
            $texts = Get-ZipTexts -Path $script:Out
            $texts['environment.txt'] | Should -Match 'NEXUS_API_KEY\s+:\s+set'
            foreach ($t in $texts.Values) { $t | Should -Not -Match 'PLANTEDENV456' }
        }

        It 'does not garble a mod folder whose name starts with the user name' {
            Invoke-Bundler -Extra @{ Apply = $true; OutFile = $script:Out; RedactName = @('alpha') }
            $texts = Get-ZipTexts -Path $script:Out
            $texts['staging-listing.txt']        | Should -Match 'alpha_mod'
            $texts['staging/mod_load_order.txt'] | Should -Match '(?m)^alpha_mod'
            $texts['console/console-2026-01-01.log'] | Should -Match 'player <user> joined with alpha_mod loaded'
            foreach ($t in $texts.Values) { $t | Should -Not -Match '<user>_mod' }
        }

        It 'does not redact inside a placeholder another name already produced' {
            Invoke-Bundler -Extra @{ Apply = $true; OutFile = $script:Out; RedactName = @('alpha', 'user') }
            $texts = Get-ZipTexts -Path $script:Out
            foreach ($t in $texts.Values) { $t | Should -Not -Match '<<user>>' }
            $texts['logs/update-20260101-000000.log'] | Should -Match 'account <user> steam'
        }

        It 'keeps only the tail of a log, redacted before it was cut' {
            Invoke-Bundler -Extra @{ Apply = $true; OutFile = $script:Out }
            $log = (Get-ZipTexts -Path $script:Out)['console/console-2026-01-01.log']
            $lines = @($log -split '\r?\n' | Where-Object { $_ -ne '' })
            $lines.Count | Should -Be 301                     # header + 300
            $log | Should -Match 'last console line'
            $log | Should -Not -Match '(?m)^console line 1$'
            $log | Should -Not -Match 'SomeU'
        }

        It 'refuses to overwrite without -Force, and overwrites with it' {
            Invoke-Bundler -Extra @{ Apply = $true; OutFile = $script:Out }
            $first = Get-TreeFingerprint -Path $script:Root
            { & $script:Bundler -ConfigPath $script:Config -UpdateLogDir $script:ToolLogs -LogDir $script:ConsoleLogs `
                -OutFile $script:Out -Apply -Confirm:$false *>&1 | Out-Null } |
                Should -Throw -ExpectedMessage '*already exists*'
            Get-TreeFingerprint -Path $script:Root | Should -Be $first

            Start-Sleep -Milliseconds 50
            Invoke-Bundler -Extra @{ Apply = $true; OutFile = $script:Out; Force = $true }
            Get-ZipEntryNames -Path $script:Out | Should -Contain 'environment.txt'
            Test-Path -LiteralPath "$($script:Out).partial" | Should -BeFalse
        }

        It 'refuses to write inside the game folder or the staging folder' {
            foreach ($inside in @((Join-Path $script:Game 'support.zip'), (Join-Path $script:Staging 'support.zip'))) {
                { & $script:Bundler -ConfigPath $script:Config -UpdateLogDir $script:ToolLogs -LogDir $script:ConsoleLogs `
                    -OutFile $inside -Apply -Confirm:$false *>&1 | Out-Null } |
                    Should -Throw -ExpectedMessage '*Refusing*'
                Test-Path -LiteralPath $inside | Should -BeFalse
            }
        }

        It 'works when there is no console log folder' {
            Invoke-Bundler -Extra @{ Apply = $true; OutFile = $script:Out; LogDir = (Join-Path $script:Root 'no-such-dir') }
            $names = Get-ZipEntryNames -Path $script:Out
            $names | Should -Contain 'environment.txt'
            @($names | Where-Object { $_ -like 'console/*' }) | Should -BeNullOrEmpty
            (Get-ZipTexts -Path $script:Out)['environment.txt'] | Should -Match 'No Darktide console log folder'
        }

        It 'works with no config.json and says so' {
            Invoke-Bundler -Extra @{ Apply = $true; OutFile = $script:Out; ConfigPath = (Join-Path $script:Root 'missing.json') }
            $texts = Get-ZipTexts -Path $script:Out
            $texts.Keys | Should -Contain 'environment.txt'
            $texts.Keys | Should -Not -Contain 'config.redacted.json'
            $texts['environment.txt'] | Should -Match 'config\.json not found'
        }

        It 'never copies a config it cannot parse' {
            Set-Content -LiteralPath $script:Config -Value "{ `"ApiKey`": `"$($script:PlantedKey)`", broken" -Encoding UTF8
            Invoke-Bundler -Extra @{ Apply = $true; OutFile = $script:Out }
            $texts = Get-ZipTexts -Path $script:Out
            $texts.Keys | Should -Not -Contain 'config.redacted.json'
            foreach ($t in $texts.Values) { $t | Should -Not -Match $script:PlantedKey }
        }
    }

    Context 'darktide.ps1 support' {

        It 'writes nothing without -Apply' {
            $before = Get-TreeFingerprint -Path $script:Root
            & $script:Dispatcher support -ConfigPath $script:Config *>&1 | Out-Null
            Get-TreeFingerprint -Path $script:Root | Should -Be $before
        }

        It 'writes the bundle with -Apply -OutFile' {
            & $script:Dispatcher support -ConfigPath $script:Config -Apply -OutFile $script:Out *>&1 | Out-Null
            Get-ZipEntryNames -Path $script:Out | Should -Contain 'staging-listing.txt'
        }

        It 'runs without a config.json' {
            $missing = Join-Path $script:Root 'missing.json'
            { & $script:Dispatcher support -ConfigPath $missing -Apply -OutFile $script:Out *>&1 | Out-Null } |
                Should -Not -Throw
            Get-ZipEntryNames -Path $script:Out | Should -Contain 'README.txt'
        }

        It 'refuses to overwrite through the dispatcher without -Force' {
            & $script:Dispatcher support -ConfigPath $script:Config -Apply -OutFile $script:Out *>&1 | Out-Null
            { & $script:Dispatcher support -ConfigPath $script:Config -Apply -OutFile $script:Out *>&1 | Out-Null } |
                Should -Throw -ExpectedMessage '*already exists*'
        }
    }
}
