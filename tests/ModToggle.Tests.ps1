<#
    enable / disable: Set-ModState.ps1, its dispatcher verbs, and the Update-LoadOrder
    fix that keeps a disabled mod disabled when the updater installs a new version.

    The file under edit is the user's hand-maintained load order, so the main
    property is that everything not being switched survives byte for byte.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:Dispatcher = Join-Path $script:RepoRoot 'darktide.ps1'
    $script:Toggler    = Join-Path $script:RepoRoot 'Set-ModState.ps1'
    $script:Updater    = Join-Path $script:RepoRoot 'Update-DarktideMods.ps1'

    # The updater writes its CSV report next to itself; leave the repo as found.
    $script:PreExistingReports = @(Get-ChildItem -LiteralPath $script:RepoRoot -Filter 'report-*.csv' -File `
                                   -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })

    function Set-LoadOrderBytes {
        param([string] $Path, [string] $Text, [switch] $Bom)
        $body = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)
        $bytes = if ($Bom) { [byte[]](@(0xEF, 0xBB, 0xBF) + $body) } else { [byte[]]$body }
        [System.IO.File]::WriteAllBytes($Path, $bytes)
    }

    function Get-Hex {
        param([string] $Path)
        [System.BitConverter]::ToString([System.IO.File]::ReadAllBytes($Path))
    }

    function ConvertTo-Hex {
        param([string] $Text, [switch] $Bom)
        $body = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)
        $bytes = if ($Bom) { [byte[]](@(0xEF, 0xBB, 0xBF) + $body) } else { [byte[]]$body }
        [System.BitConverter]::ToString($bytes)
    }

    function Get-LoadOrderLines {
        param([string] $Path)
        @(Get-Content -LiteralPath $Path -Encoding UTF8)
    }

    # CRLF, comments, a blank line, indentation and a bracketed folder name: the
    # shapes a hand-edited load order actually has.
    $script:CrlfText = "-- Darktide mod load order`r`n-- one folder per line`r`n`r`nalpha_mod`r`n  beta_mod`r`n`r`n-- the end`r`ngamma [x]`r`n"
    # LF, a byte-order mark, and no newline at the end of the last line.
    $script:LfText   = "-- order`nalpha_mod`n`nbeta_mod`ngamma [x]"
}

AfterAll {
    Get-ChildItem -LiteralPath $script:RepoRoot -Filter 'report-*.csv' -File -ErrorAction SilentlyContinue |
        Where-Object { $script:PreExistingReports -notcontains $_.Name } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

Describe 'Set-ModState.ps1' {

    BeforeEach {
        $script:Root      = New-TestSandbox
        $script:Game      = New-FakeGameFolder -Root $script:Root
        $script:Staging   = New-FakeStaging -Root $script:Root -Mods @('alpha_mod', 'beta_mod', 'gamma [x]')
        $script:Config    = New-TestConfig -Root $script:Root -StagingMods $script:Staging -GamePath $script:Game
        $script:LoadOrder = Join-Path $script:Staging 'mod_load_order.txt'
        $script:BackupRoot = Join-Path $script:Root 'mod_backups'
        $script:LoBackups  = Join-Path $script:Root 'loadorder_backups'
        Set-LoadOrderBytes -Path $script:LoadOrder -Text $script:CrlfText
    }

    AfterEach {
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'round trip' {

        It 'disable then enable leaves a CRLF file with comments byte-identical' {
            $orig = Get-Hex -Path $script:LoadOrder

            & $script:Toggler disable -ConfigPath $script:Config -Only alpha_mod -Apply -Confirm:$false *>&1 | Out-Null
            Get-Hex -Path $script:LoadOrder |
                Should -Be (ConvertTo-Hex -Text $script:CrlfText.Replace("`r`nalpha_mod`r`n", "`r`n--alpha_mod`r`n"))

            & $script:Toggler enable -ConfigPath $script:Config -Only alpha_mod -Apply -Confirm:$false *>&1 | Out-Null
            Get-Hex -Path $script:LoadOrder | Should -Be $orig
        }

        It 'keeps a byte-order mark, LF endings and a missing final newline' {
            Set-LoadOrderBytes -Path $script:LoadOrder -Text $script:LfText -Bom
            $orig = Get-Hex -Path $script:LoadOrder

            & $script:Toggler disable -ConfigPath $script:Config -Only 'gamma [x]' -Apply -Confirm:$false *>&1 | Out-Null
            Get-Hex -Path $script:LoadOrder |
                Should -Be (ConvertTo-Hex -Text $script:LfText.Replace("`ngamma [x]", "`n--gamma [x]") -Bom)

            & $script:Toggler enable -ConfigPath $script:Config -Only 'gamma [x]' -Apply -Confirm:$false *>&1 | Out-Null
            Get-Hex -Path $script:LoadOrder | Should -Be $orig
        }

        It 'leaves bytes that are not valid UTF-8 alone' {
            # A comment saved in a legacy code page: a lone 0xE9 is not UTF-8.
            $head = [System.Text.Encoding]::ASCII.GetBytes('-- caf')
            $tail = [System.Text.Encoding]::ASCII.GetBytes("`r`nalpha_mod`r`nbeta_mod`r`n")
            [System.IO.File]::WriteAllBytes($script:LoadOrder, [byte[]]($head + @(0xE9) + $tail))
            $orig = Get-Hex -Path $script:LoadOrder

            & $script:Toggler disable -ConfigPath $script:Config -Only beta_mod -Apply -Confirm:$false *>&1 | Out-Null
            $bytes = [System.IO.File]::ReadAllBytes($script:LoadOrder)
            $bytes[6] | Should -Be 0xE9
            $bytes.Length | Should -Be ($head.Length + 1 + $tail.Length + 2)

            & $script:Toggler enable -ConfigPath $script:Config -Only beta_mod -Apply -Confirm:$false *>&1 | Out-Null
            Get-Hex -Path $script:LoadOrder | Should -Be $orig
        }

        It 'keeps the indentation of an indented entry' {
            $orig = Get-Hex -Path $script:LoadOrder

            & $script:Toggler disable -ConfigPath $script:Config -Only beta_mod -Apply -Confirm:$false *>&1 | Out-Null
            Get-LoadOrderLines -Path $script:LoadOrder | Should -Contain '  --beta_mod'

            & $script:Toggler enable -ConfigPath $script:Config -Only beta_mod -Apply -Confirm:$false *>&1 | Out-Null
            Get-Hex -Path $script:LoadOrder | Should -Be $orig
        }

        It 'switches several mods at once, given as an array or a comma list' {
            & $script:Toggler disable -ConfigPath $script:Config -Only 'alpha_mod,beta_mod' -Apply -Confirm:$false *>&1 | Out-Null
            $lines = Get-LoadOrderLines -Path $script:LoadOrder
            $lines | Should -Contain '--alpha_mod'
            $lines | Should -Contain '  --beta_mod'

            & $script:Toggler enable -ConfigPath $script:Config -Only alpha_mod, beta_mod -Apply -Confirm:$false *>&1 | Out-Null
            $lines = Get-LoadOrderLines -Path $script:LoadOrder
            $lines | Should -Contain 'alpha_mod'
            $lines | Should -Contain '  beta_mod'
        }
    }

    Context 'mods missing from the file' {

        BeforeEach {
            Set-LoadOrderBytes -Path $script:LoadOrder -Text "-- order`r`nalpha_mod`r`nbeta_mod`r`n"
        }

        It 'enable appends a staged mod that is not in the file' {
            & $script:Toggler enable -ConfigPath $script:Config -Only 'gamma [x]' -Apply -Confirm:$false *>&1 | Out-Null

            Get-Hex -Path $script:LoadOrder |
                Should -Be (ConvertTo-Hex -Text "-- order`r`nalpha_mod`r`nbeta_mod`r`ngamma [x]`r`n")
        }

        It 'disable records it as disabled so an update cannot add it back as active' {
            & $script:Toggler disable -ConfigPath $script:Config -Only 'gamma [x]' -Apply -Confirm:$false *>&1 | Out-Null

            Get-Hex -Path $script:LoadOrder |
                Should -Be (ConvertTo-Hex -Text "-- order`r`nalpha_mod`r`nbeta_mod`r`n--gamma [x]`r`n")
        }
    }

    Context 'dry run' {

        It 'writes nothing anywhere without -Apply' {
            $before = Get-TreeFingerprint -Path $script:Root

            $out = & $script:Toggler disable -ConfigPath $script:Config -Only alpha_mod *>&1 | Out-String

            $out | Should -Match 'DRY RUN'
            $out | Should -Match '--alpha_mod'
            Get-TreeFingerprint -Path $script:Root | Should -Be $before
        }

        It 'writes nothing with -Apply -WhatIf' {
            $before = Get-TreeFingerprint -Path $script:Root

            & $script:Toggler disable -ConfigPath $script:Config -Only alpha_mod -Apply -WhatIf *>&1 | Out-Null

            Get-TreeFingerprint -Path $script:Root | Should -Be $before
        }

        It 'listing the disabled mods writes nothing' {
            $before = Get-TreeFingerprint -Path $script:Root

            & $script:Toggler disable -ConfigPath $script:Config *>&1 | Out-Null

            Get-TreeFingerprint -Path $script:Root | Should -Be $before
        }
    }

    Context 'refusals' {

        It 'throws on a name that is not a staging folder and changes nothing' {
            $before = Get-TreeFingerprint -Path $script:Root

            { & $script:Toggler disable -ConfigPath $script:Config -Only no_such_mod -Apply -Confirm:$false *>&1 | Out-Null } |
                Should -Throw '*no_such_mod*'

            Get-TreeFingerprint -Path $script:Root | Should -Be $before
        }

        It 'validates every name before changing any' {
            $orig = Get-Hex -Path $script:LoadOrder

            { & $script:Toggler disable -ConfigPath $script:Config -Only alpha_mod, no_such_mod -Apply -Confirm:$false *>&1 | Out-Null } |
                Should -Throw

            Get-Hex -Path $script:LoadOrder | Should -Be $orig
        }

        It 'refuses <Name>' -TestCases @(
            @{ Name = 'base' }, @{ Name = 'dmf' }, @{ Name = 'DMF' }
        ) {
            $orig = Get-Hex -Path $script:LoadOrder

            { & $script:Toggler disable -ConfigPath $script:Config -Only $Name -Apply -Confirm:$false *>&1 | Out-Null } |
                Should -Throw '*Refusing*'

            Get-Hex -Path $script:LoadOrder | Should -Be $orig
        }

        It 'refuses a path instead of a folder name: <Name>' -TestCases @(
            @{ Name = '..' }, @{ Name = '../alpha_mod' }, @{ Name = 'alpha_mod\..\beta_mod' }, @{ Name = '.staging-alpha_mod' }
        ) {
            { & $script:Toggler disable -ConfigPath $script:Config -Only $Name -Apply -Confirm:$false *>&1 | Out-Null } |
                Should -Throw
        }

        It 'enable with no -Only throws rather than guessing' {
            { & $script:Toggler enable -ConfigPath $script:Config *>&1 | Out-Null } | Should -Throw '*-Only*'
        }

        It 'throws when staging has no mod_load_order.txt' {
            Remove-Item -LiteralPath $script:LoadOrder -Force

            { & $script:Toggler disable -ConfigPath $script:Config -Only alpha_mod -Apply -Confirm:$false *>&1 | Out-Null } |
                Should -Throw '*mod_load_order.txt*'
            Test-Path -LiteralPath $script:LoadOrder | Should -BeFalse
        }
    }

    Context 'backups' {

        It 'backs up the original file before writing' {
            $orig = Get-Hex -Path $script:LoadOrder

            & $script:Toggler disable -ConfigPath $script:Config -Only alpha_mod -Apply -Confirm:$false *>&1 | Out-Null

            $bk = @(Get-ChildItem -LiteralPath $script:LoBackups -Filter 'mod_load_order-*.txt' -File)
            $bk.Count | Should -Be 1
            Get-Hex -Path $bk[0].FullName | Should -Be $orig
        }

        It 'keeps its backups out of BackupRoot, where rollback would take them for a backup set' {
            & $script:Toggler disable -ConfigPath $script:Config -Only alpha_mod -Apply -Confirm:$false *>&1 | Out-Null

            @(Get-ChildItem -LiteralPath $script:BackupRoot -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
        }

        It 'takes no backup and writes nothing when there is nothing to change' {
            & $script:Toggler disable -ConfigPath $script:Config -Only alpha_mod -Apply -Confirm:$false *>&1 | Out-Null
            $after = Get-TreeFingerprint -Path $script:Root

            $out = & $script:Toggler disable -ConfigPath $script:Config -Only alpha_mod -Apply -Confirm:$false *>&1 | Out-String

            $out | Should -Match 'already disabled'
            Get-TreeFingerprint -Path $script:Root | Should -Be $after
        }

        It 'prunes old backups down to -KeepBackups' {
            [void][System.IO.Directory]::CreateDirectory($script:LoBackups)
            $i = 0
            foreach ($stamp in @('20200101-000000', '20200102-000000', '20200103-000000')) {
                $i++
                $p = Join-Path $script:LoBackups "mod_load_order-$stamp.txt"
                Set-Content -LiteralPath $p -Value "old $stamp" -Encoding ASCII
                (Get-Item -LiteralPath $p).LastWriteTimeUtc = [datetime]::new(2020, 1, $i, 0, 0, 0, [DateTimeKind]::Utc)
            }

            & $script:Toggler disable -ConfigPath $script:Config -Only alpha_mod -Apply -KeepBackups 2 -Confirm:$false *>&1 | Out-Null

            $left = @(Get-ChildItem -LiteralPath $script:LoBackups -File | ForEach-Object { $_.Name })
            $left.Count | Should -Be 2
            $left | Should -Contain 'mod_load_order-20200103-000000.txt'
            $left | Should -Not -Contain 'mod_load_order-20200101-000000.txt'
        }

        It 'keeps every backup with -KeepBackups 0' {
            [void][System.IO.Directory]::CreateDirectory($script:LoBackups)
            foreach ($stamp in @('20200101-000000', '20200102-000000')) {
                $p = Join-Path $script:LoBackups "mod_load_order-$stamp.txt"
                Set-Content -LiteralPath $p -Value "old $stamp" -Encoding ASCII
                (Get-Item -LiteralPath $p).LastWriteTimeUtc = [datetime]::new(2020, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
            }

            & $script:Toggler disable -ConfigPath $script:Config -Only alpha_mod -Apply -KeepBackups 0 -Confirm:$false *>&1 | Out-Null

            @(Get-ChildItem -LiteralPath $script:LoBackups -File).Count | Should -Be 3
        }

        It 'never overwrites an earlier backup' {
            & $script:Toggler disable -ConfigPath $script:Config -Only alpha_mod -Apply -Confirm:$false *>&1 | Out-Null
            & $script:Toggler enable  -ConfigPath $script:Config -Only alpha_mod -Apply -Confirm:$false *>&1 | Out-Null

            @(Get-ChildItem -LiteralPath $script:LoBackups -File).Count | Should -Be 2
        }
    }

    Context 'listing' {

        It 'disable with no -Only lists the disabled mods and only those' {
            & $script:Toggler disable -ConfigPath $script:Config -Only alpha_mod -Apply -Confirm:$false *>&1 | Out-Null

            $out = & $script:Toggler disable -ConfigPath $script:Config *>&1 | Out-String

            $out | Should -Match 'disabled \(1\)'
            $out | Should -Match 'alpha_mod'
            $out | Should -Not -Match 'beta_mod'
        }

        It 'says so when nothing is disabled' {
            $out = & $script:Toggler disable -ConfigPath $script:Config *>&1 | Out-String
            $out | Should -Match 'no mods are disabled'
        }

        It 'ends an applied change by pointing at deploy, without deploying' {
            $gameBefore = Get-TreeFingerprint -Path $script:Game

            $out = & $script:Toggler disable -ConfigPath $script:Config -Only alpha_mod -Apply -Confirm:$false *>&1 | Out-String

            $out | Should -Match ([regex]::Escape('.\darktide.ps1 deploy -Apply'))
            Get-TreeFingerprint -Path $script:Game | Should -Be $gameBefore
        }
    }
}

Describe 'Update-LoadOrder keeps disabled mods disabled' {

    BeforeAll {
        Import-ScriptFunctions -Path $script:Updater -Name @('Update-LoadOrder')
        # The real logger needs script state this test deliberately does not load.
        function global:Write-Log {
            param([string] $Message, [string] $Level = 'INFO')
            $null = $Message, $Level
        }
    }

    BeforeEach {
        $script:Root = New-TestSandbox
        $script:LoadOrder = Join-Path $script:Root 'mod_load_order.txt'
    }

    AfterEach {
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'treats <Line> as present and does not append an active entry' -TestCases @(
        @{ Line = '--alpha_mod' }, @{ Line = '-- alpha_mod' }, @{ Line = '  --alpha_mod  ' }
    ) {
        Set-LoadOrderBytes -Path $script:LoadOrder -Text "-- order`r`n$Line`r`nbeta_mod`r`n"

        Update-LoadOrder -ModsRoot $script:Root -ModNames @('alpha_mod', 'new_mod') -Confirm:$false *>&1 | Out-Null

        $lines = @(Get-LoadOrderLines -Path $script:LoadOrder | ForEach-Object { $_.Trim() })
        $lines | Should -Not -Contain 'alpha_mod'
        $lines | Should -Contain 'new_mod'
        @($lines | Where-Object { $_ -eq 'new_mod' }).Count | Should -Be 1
    }

    It 'still appends a mod that is not in the file at all' {
        Set-LoadOrderBytes -Path $script:LoadOrder -Text "-- a comment that mentions nothing`r`nbeta_mod`r`n"

        Update-LoadOrder -ModsRoot $script:Root -ModNames @('alpha_mod') -Confirm:$false *>&1 | Out-Null

        Get-LoadOrderLines -Path $script:LoadOrder | Should -Contain 'alpha_mod'
    }
}

Describe 'A disabled mod through an offline update' {

    BeforeEach {
        $script:Root      = New-TestSandbox
        $script:Game      = New-FakeGameFolder -Root $script:Root
        $script:Staging   = New-FakeStaging -Root $script:Root -Mods @('alpha_mod', 'beta_mod')
        $script:Config    = New-TestConfig -Root $script:Root -StagingMods $script:Staging -GamePath $script:Game
        $script:Downloads = Join-Path $script:Root 'downloads'
        $script:LoadOrder = Join-Path $script:Staging 'mod_load_order.txt'

        $null = New-TestZip -Path (Join-Path $script:Downloads 'Alpha Mod-447-2-0-0-1719209900.zip') -Entries @{
            'alpha_mod/alpha_mod.mod'   = 'return { version = 2 }'
            'alpha_mod/info.json'       = '{"name":"Alpha Mod","version":"2.0.0"}'
            'alpha_mod/scripts/new.lua' = '-- added in 2.0.0'
        }
    }

    AfterEach {
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'stays disabled after Update-DarktideMods.ps1 -NoApi -Apply installs a newer zip of it' {
        & $script:Toggler disable -ConfigPath $script:Config -Only alpha_mod -Apply -Confirm:$false *>&1 | Out-Null
        Get-LoadOrderLines -Path $script:LoadOrder | Should -Contain '--alpha_mod'

        & $script:Updater -ConfigPath $script:Config -NoApi -Apply -Confirm:$false *>&1 | Out-Null

        # The update really happened...
        $info = Get-Content -LiteralPath (Join-Path (Join-Path $script:Staging 'alpha_mod') 'info.json') -Raw -Encoding UTF8 |
                ConvertFrom-Json
        $info.version | Should -Be '2.0.0'
        # ...and the mod is still switched off.
        $lines = @(Get-LoadOrderLines -Path $script:LoadOrder | ForEach-Object { $_.Trim() })
        $lines | Should -Contain '--alpha_mod'
        $lines | Should -Not -Contain 'alpha_mod'
    }
}

Describe 'darktide.ps1 enable / disable' {

    BeforeEach {
        $script:Root      = New-TestSandbox
        $script:Game      = New-FakeGameFolder -Root $script:Root
        $script:Staging   = New-FakeStaging -Root $script:Root -Mods @('alpha_mod', 'beta_mod')
        $script:Config    = New-TestConfig -Root $script:Root -StagingMods $script:Staging -GamePath $script:Game
        $script:LoadOrder = Join-Path $script:Staging 'mod_load_order.txt'
    }

    AfterEach {
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'is a dry run without -Apply, writes with it, and round-trips through enable' {
        $orig   = Get-Hex -Path $script:LoadOrder
        $before = Get-TreeFingerprint -Path $script:Root

        & $script:Dispatcher disable -ConfigPath $script:Config -Only alpha_mod *>&1 | Out-Null
        Get-TreeFingerprint -Path $script:Root | Should -Be $before

        & $script:Dispatcher disable -ConfigPath $script:Config -Only alpha_mod -Apply *>&1 | Out-Null
        Get-LoadOrderLines -Path $script:LoadOrder | Should -Contain '--alpha_mod'

        $listed = & $script:Dispatcher disable -ConfigPath $script:Config *>&1 | Out-String
        $listed | Should -Match 'alpha_mod'

        & $script:Dispatcher enable -ConfigPath $script:Config -Only alpha_mod -Apply *>&1 | Out-Null
        Get-Hex -Path $script:LoadOrder | Should -Be $orig
    }
}
