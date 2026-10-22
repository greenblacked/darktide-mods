<#
    Tests for Backup-DarktideSettings.ps1 and the 'settings' verb.

    The settings file lives in the Windows profile. Every test passes -SettingsPath
    (or a config.json with SettingsPath) into its own sandbox, so nothing here reads
    or writes the real %APPDATA%, and -ConfigPath always points into the sandbox so a
    developer's own config.json is never picked up.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:Dispatcher = Join-Path $script:RepoRoot 'darktide.ps1'
    $script:Tool       = Join-Path $script:RepoRoot 'Backup-DarktideSettings.ps1'

    # Bytes that are not valid UTF-8 and carry CRLF, so a text round trip would show.
    $script:BytesA = [byte[]](0x2D, 0x2D, 0x20, 0x61, 0x0D, 0x0A, 0xFF, 0xFE, 0x00, 0x80, 0x41)
    $script:BytesB = [byte[]](0x2D, 0x2D, 0x20, 0x62, 0x0D, 0x0A, 0xC3, 0x28, 0x00, 0x42)

    function Invoke-Tool {
        # Every call is sandboxed: settings file, backup folder and config.
        param([hashtable] $Extra = @{})
        $params = @{
            SettingsPath = $script:Settings
            BackupDir    = $script:Backups
            ConfigPath   = $script:NoConfig
            Confirm      = $false
        }
        foreach ($k in $Extra.Keys) { $params[$k] = $Extra[$k] }
        return (& $script:Tool @params *>&1 | Out-String)
    }

    function Get-BackupFile {
        if (-not (Test-Path -LiteralPath $script:Backups)) { return @() }
        return @(Get-ChildItem -LiteralPath $script:Backups -File | Sort-Object Name)
    }

    function New-OldBackup {
        # A backup as if taken at $Stamp, with its own content.
        param([string] $Stamp, [string] $Text, [string] $Tag = '')
        [void][System.IO.Directory]::CreateDirectory($script:Backups)
        $p = Join-Path $script:Backups "user_settings-$Stamp$Tag.config"
        [System.IO.File]::WriteAllBytes($p, [System.Text.Encoding]::ASCII.GetBytes($Text))
        return $p
    }

    function Get-Bytes { param([string] $Path) return [System.IO.File]::ReadAllBytes($Path) }
}

Describe 'Backup-DarktideSettings' {

    BeforeEach {
        $script:Root     = New-TestSandbox
        $script:ProfileDir = Join-Path (Join-Path (Join-Path $script:Root 'AppData') 'Fatshark') 'Darktide'
        [void][System.IO.Directory]::CreateDirectory($script:ProfileDir)
        $script:Settings = Join-Path $script:ProfileDir 'user_settings.config'
        [System.IO.File]::WriteAllBytes($script:Settings, $script:BytesA)
        $script:Backups  = Join-Path $script:Root 'settings_backups'
        $script:NoConfig = Join-Path $script:Root 'no-config.json'
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'backing up' {

        It 'writes nothing without -Apply' {
            $before = Get-TreeFingerprint -Path $script:Root
            $out = Invoke-Tool
            Get-TreeFingerprint -Path $script:Root | Should -Be $before
            Test-Path -LiteralPath $script:Backups | Should -BeFalse
            $out | Should -Match 'Dry run complete\. Nothing was written'
            $out | Should -Match 'would copy to'
        }

        It 'takes a byte-identical copy with -Apply' {
            Invoke-Tool -Extra @{ Apply = $true } | Out-Null
            $files = @(Get-BackupFile)
            $files.Count | Should -Be 1
            $files[0].Name | Should -Match '^user_settings-\d{8}-\d{6}\.config$'
            (Get-Bytes $files[0].FullName) | Should -Be $script:BytesA
            (Get-Bytes $script:Settings) | Should -Be $script:BytesA
        }

        It 'skips a second backup when nothing changed, and says so' {
            Invoke-Tool -Extra @{ Apply = $true } | Out-Null
            $before = Get-TreeFingerprint -Path $script:Root
            $out = Invoke-Tool -Extra @{ Apply = $true }
            $out | Should -Match 'Unchanged since the newest backup'
            Get-TreeFingerprint -Path $script:Root | Should -Be $before
            @(Get-BackupFile).Count | Should -Be 1
        }

        It 'takes a new backup once the file changes, and lists it first' {
            $old = New-OldBackup -Stamp '20200101-000000' -Text 'older settings'
            [System.IO.File]::WriteAllBytes($script:Settings, $script:BytesB)
            Invoke-Tool -Extra @{ Apply = $true } | Out-Null
            $files = @(Get-BackupFile)
            $files.Count | Should -Be 2
            $new = $files | Where-Object { $_.FullName -ne $old }
            (Get-Bytes $new.FullName) | Should -Be $script:BytesB

            $out = Invoke-Tool
            $out.IndexOf($new.Name) | Should -BeLessThan $out.IndexOf((Split-Path -Leaf $old))
            $out | Should -Match ([regex]::Escape($new.Name) + '.*same as current')
        }

        It 'numbers same-second backups instead of overwriting them' {
            # Occupy the name for this second and the next two, so the run lands on a
            # taken stamp whichever second it starts in.
            $now = Get-Date
            $taken = @(0, 1, 2) | ForEach-Object {
                New-OldBackup -Stamp $now.AddSeconds($_).ToString('yyyyMMdd-HHmmss') -Text "taken $_"
            }
            Invoke-Tool -Extra @{ Apply = $true } | Out-Null

            $numbered = @(Get-BackupFile | Where-Object { $_.Name -match '-\d{6}-1\.config$' })
            $numbered.Count | Should -Be 1
            (Get-Bytes $numbered[0].FullName) | Should -Be $script:BytesA
            $i = 0
            foreach ($p in $taken) {
                [System.IO.File]::ReadAllText($p) | Should -Be "taken $i"
                $i++
            }
        }

        It 'prunes to -KeepBackups, keeping the newest' {
            foreach ($d in 1..5) { $null = New-OldBackup -Stamp "2020010$d-000000" -Text "old $d" }
            Invoke-Tool -Extra @{ Apply = $true; KeepBackups = 3 } | Out-Null
            $names = @(Get-BackupFile | ForEach-Object { $_.Name })
            $names.Count | Should -Be 3
            $names | Should -Contain 'user_settings-20200105-000000.config'
            $names | Should -Contain 'user_settings-20200104-000000.config'
            $names | Should -Not -Contain 'user_settings-20200103-000000.config'
            @($names | Where-Object { $_ -notmatch '^user_settings-2020' }).Count | Should -Be 1
        }

        It 'leaves files it did not write alone when pruning' {
            foreach ($d in 1..3) { $null = New-OldBackup -Stamp "2020010$d-000000" -Text "old $d" }
            $stranger = Join-Path $script:Backups 'notes.txt'
            Set-Content -LiteralPath $stranger -Value 'mine' -Encoding ASCII
            Invoke-Tool -Extra @{ Apply = $true; KeepBackups = 1 } | Out-Null
            Test-Path -LiteralPath $stranger | Should -BeTrue
        }

        It 'reports a missing settings file clearly and writes nothing' {
            Remove-Item -LiteralPath $script:Settings -Force
            $before = Get-TreeFingerprint -Path $script:Root

            $out = Invoke-Tool
            $out | Should -Match 'No settings file at'
            { Invoke-Tool -Extra @{ Apply = $true } } | Should -Throw '*Nothing to back up*'

            Get-TreeFingerprint -Path $script:Root | Should -Be $before
            Test-Path -LiteralPath $script:Backups | Should -BeFalse
        }

        It 'refuses to keep backups inside the repository' {
            $inRepo = Join-Path $script:RepoRoot 'settings_backups'
            $existed = Test-Path -LiteralPath $inRepo
            { Invoke-Tool -Extra @{ BackupDir = $inRepo; Apply = $true } } | Should -Throw '*inside this repository*'
            Test-Path -LiteralPath $inRepo | Should -Be $existed
        }

        It 'refuses to keep backups inside staging or the game folder' {
            $mods = Join-Path $script:Root 'mods'
            $game = Join-Path $script:Root 'game'
            $cfg = Join-Path $script:Root 'config.json'
            @{ ModsRoot = $mods; GamePath = $game } | ConvertTo-Json |
                Set-Content -LiteralPath $cfg -Encoding UTF8
            { Invoke-Tool -Extra @{ ConfigPath = $cfg; BackupDir = (Join-Path $mods 'bk') } } |
                Should -Throw '*inside staging*'
            { Invoke-Tool -Extra @{ ConfigPath = $cfg; BackupDir = (Join-Path $game 'bk') } } |
                Should -Throw '*inside the game folder*'
        }

        It 'resolves a relative -SettingsPath from the current location' {
            Push-Location -LiteralPath $script:ProfileDir
            try {
                Invoke-Tool -Extra @{ SettingsPath = 'user_settings.config'; Apply = $true } | Out-Null
            } finally { Pop-Location }
            $files = @(Get-BackupFile)
            $files.Count | Should -Be 1
            (Get-Bytes $files[0].FullName) | Should -Be $script:BytesA
        }

        It 'refuses a -SettingsPath that is a folder' {
            { Invoke-Tool -Extra @{ SettingsPath = $script:ProfileDir; Apply = $true } } | Should -Throw '*is a folder*'
            Test-Path -LiteralPath $script:Backups | Should -BeFalse
        }

        It 'defaults the backup folder to settings_backups beside staging' {
            $cfg = Join-Path $script:Root 'config.json'
            @{ ModsRoot = (Join-Path $script:Root 'mods'); SettingsPath = $script:Settings } | ConvertTo-Json |
                Set-Content -LiteralPath $cfg -Encoding UTF8
            & $script:Tool -ConfigPath $cfg -Apply -Confirm:$false *>&1 | Out-Null
            @(Get-BackupFile).Count | Should -Be 1
        }
    }

    Context 'restoring' {

        BeforeEach {
            $script:Saved = New-OldBackup -Stamp '20200101-000000' -Text 'saved settings'
            [System.IO.File]::WriteAllBytes($script:Settings, $script:BytesB)
        }

        It 'shows what would change and writes nothing without -Apply' {
            $before = Get-TreeFingerprint -Path $script:Root
            $out = Invoke-Tool -Extra @{ BackupSet = '20200101' }
            Get-TreeFingerprint -Path $script:Root | Should -Be $before
            $out | Should -Match 'restore from : user_settings-20200101-000000\.config'
            $out | Should -Match 'differs from the current file'
            $out | Should -Match 'Dry run complete\. Nothing was written'
        }

        It 'backs up the current file, then overwrites it, with -Apply' {
            Invoke-Tool -Extra @{ BackupSet = '20200101'; Apply = $true } | Out-Null

            [System.IO.File]::ReadAllText($script:Settings) | Should -Be 'saved settings'
            $pre = @(Get-BackupFile | Where-Object { $_.Name -match '-prerestore' })
            $pre.Count | Should -Be 1
            (Get-Bytes $pre[0].FullName) | Should -Be $script:BytesB
            [System.IO.File]::ReadAllText($script:Saved) | Should -Be 'saved settings'
        }

        It 'does nothing when the file already matches the backup' {
            [System.IO.File]::WriteAllText($script:Settings, 'saved settings')
            $before = Get-TreeFingerprint -Path $script:Root
            $out = Invoke-Tool -Extra @{ BackupSet = '20200101'; Apply = $true }
            $out | Should -Match 'already matches'
            Get-TreeFingerprint -Path $script:Root | Should -Be $before
        }

        It 'restores a deleted settings file without a pre-restore backup' {
            Remove-Item -LiteralPath $script:Settings -Force
            Invoke-Tool -Extra @{ BackupSet = '20200101'; Apply = $true } | Out-Null
            [System.IO.File]::ReadAllText($script:Settings) | Should -Be 'saved settings'
            @(Get-BackupFile).Count | Should -Be 1
        }

        It 'refuses an ambiguous -BackupSet and changes nothing' {
            $null = New-OldBackup -Stamp '20200102-000000' -Text 'other settings'
            $before = Get-TreeFingerprint -Path $script:Root
            { Invoke-Tool -Extra @{ BackupSet = '202001'; Apply = $true } } | Should -Throw '*matches 2 settings backups*'
            Get-TreeFingerprint -Path $script:Root | Should -Be $before
        }

        It 'lets an exact name win over a longer name that contains it' {
            $null = New-OldBackup -Stamp '20200101-000000' -Tag '-1' -Text 'second settings'
            Invoke-Tool -Extra @{ BackupSet = 'user_settings-20200101-000000.config'; Apply = $true } | Out-Null
            [System.IO.File]::ReadAllText($script:Settings) | Should -Be 'saved settings'
        }

        It 'refuses a blank -BackupSet rather than matching everything' {
            { Invoke-Tool -Extra @{ BackupSet = '  '; Apply = $true } } | Should -Throw '*blank*'
            (Get-Bytes $script:Settings) | Should -Be $script:BytesB
        }

        It 'refuses a -BackupSet that matches nothing' {
            { Invoke-Tool -Extra @{ BackupSet = 'nope'; Apply = $true } } | Should -Throw "*No settings backup matching 'nope'*"
            (Get-Bytes $script:Settings) | Should -Be $script:BytesB
        }

        It 'refuses to restore while the game is running, and writes nothing' {
            $self = (Get-Process -Id $PID).ProcessName
            $before = Get-TreeFingerprint -Path $script:Root
            { Invoke-Tool -Extra @{ BackupSet = '20200101'; Apply = $true; ProcessName = $self } } |
                Should -Throw '*Close the game first*'
            Get-TreeFingerprint -Path $script:Root | Should -Be $before
            (Get-Bytes $script:Settings) | Should -Be $script:BytesB
        }

        It 'still allows a dry-run restore while the game is running' {
            $self = (Get-Process -Id $PID).ProcessName
            { Invoke-Tool -Extra @{ BackupSet = '20200101'; ProcessName = $self } } | Should -Not -Throw
        }

        It 'keeps the backup it restored from when pruning' {
            foreach ($d in 2..6) { $null = New-OldBackup -Stamp "2020010$d-000000" -Text "newer $d" }
            Invoke-Tool -Extra @{ BackupSet = '20200101'; Apply = $true; KeepBackups = 2 } | Out-Null
            Test-Path -LiteralPath $script:Saved | Should -BeTrue
            @(Get-BackupFile | Where-Object { $_.Name -match '-prerestore' }).Count | Should -Be 1
        }
    }
}

Describe 'darktide.ps1 settings' {

    BeforeEach {
        $script:Root     = New-TestSandbox
        $script:Settings = Join-Path $script:Root 'user_settings.config'
        [System.IO.File]::WriteAllBytes($script:Settings, $script:BytesA)
        $script:Backups  = Join-Path $script:Root 'settings_backups'
        $script:Config   = Join-Path $script:Root 'config.json'
        @{
            ModsRoot     = (Join-Path $script:Root 'mods')
            SettingsPath = $script:Settings
        } | ConvertTo-Json | Set-Content -LiteralPath $script:Config -Encoding UTF8
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'writes nothing without -Apply' {
        $before = Get-TreeFingerprint -Path $script:Root
        & $script:Dispatcher settings -ConfigPath $script:Config *>&1 | Out-Null
        Get-TreeFingerprint -Path $script:Root | Should -Be $before
    }

    It 'backs up with -Apply, beside staging, using SettingsPath from config.json' {
        & $script:Dispatcher settings -ConfigPath $script:Config -Apply *>&1 | Out-Null
        $files = @(Get-ChildItem -LiteralPath $script:Backups -File)
        $files.Count | Should -Be 1
        [System.IO.File]::ReadAllBytes($files[0].FullName) | Should -Be $script:BytesA
    }

    It 'passes -BackupSet through and restores with -Apply' {
        & $script:Dispatcher settings -ConfigPath $script:Config -Apply *>&1 | Out-Null
        $name = @(Get-ChildItem -LiteralPath $script:Backups -File)[0].Name
        [System.IO.File]::WriteAllBytes($script:Settings, $script:BytesB)

        $before = Get-TreeFingerprint -Path $script:Root
        & $script:Dispatcher settings -ConfigPath $script:Config -BackupSet $name *>&1 | Out-Null
        Get-TreeFingerprint -Path $script:Root | Should -Be $before

        & $script:Dispatcher settings -ConfigPath $script:Config -BackupSet $name -Apply *>&1 | Out-Null
        [System.IO.File]::ReadAllBytes($script:Settings) | Should -Be $script:BytesA
    }
}

Describe 'settings file never leaves the machine' {

    It 'is gitignored' {
        $gi = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.gitignore') -Raw -Encoding UTF8
        $gi | Should -Match ([regex]::Escape('user_settings*.config'))
        $gi | Should -Match ([regex]::Escape('settings_backups/'))
    }

    It 'ships the script in the release package' {
        $listed = @(& (Join-Path $script:RepoRoot 'New-ReleasePackage.ps1') -ListOnly)
        $listed | Should -Contain 'Backup-DarktideSettings.ps1'
    }
}
