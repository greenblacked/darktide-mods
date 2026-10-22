<#
    Version holds: Set-ModPin.ps1 (the 'pin' verb) and the updater honouring a pin.

    A pin is a promise that 'update' will not touch a mod, -Force included. The
    first half proves the map edits are exact - every other key and the entry order
    survive, a dry run writes nothing, a typo is refused. The second half proves the
    promise: a pinned folder with a newer archive waiting is left byte-for-byte alone,
    no backup is taken, and the report says PINNED instead of dropping the row.

    Everything runs in a sandbox map pointed at through config.json's MapPath, so the
    repository's own mods-map.json is never read for pins or written.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:Dispatcher = Join-Path $script:RepoRoot 'darktide.ps1'
    $script:Pinner     = Join-Path $script:RepoRoot 'Set-ModPin.ps1'
    $script:Updater    = Join-Path $script:RepoRoot 'Update-DarktideMods.ps1'

    # The updater writes report-*.csv and report-*.json next to itself. Remember what
    # was there so the suite can leave the repo as it found it.
    $script:PreExistingReports = @(Get-ChildItem -LiteralPath $script:RepoRoot -File -ErrorAction SilentlyContinue |
                                   Where-Object { $_.Name -like 'report-*.csv' -or $_.Name -like 'report-*.json' } |
                                   ForEach-Object { $_.Name })

    $script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    function Write-MapFile {
        <# Writes the map exactly as given: LF line endings, no BOM, trailing newline. #>
        param([string] $Path, [string[]] $Lines)
        [System.IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"), $script:Utf8NoBom)
    }

    function Set-ConfigValue {
        <# New-TestConfig has no MapPath; add one so nothing reads the repo's map. #>
        param([string] $Config, [string] $Key, $Value)
        $j = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json
        $j | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force
        $j | ConvertTo-Json | Set-Content -LiteralPath $Config -Encoding UTF8
    }

    function Read-Map {
        param([string] $Path)
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    }

    function Get-LoggedPath {
        <# The path the updater printed after 'Report: ' or 'Report JSON: '. #>
        param([object[]] $Output, [string] $Label, [string] $Extension)
        foreach ($line in $Output) {
            $m = [regex]::Match("$line", "$([regex]::Escape($Label)): (?<p>.+\.$Extension)\s*$")
            if ($m.Success) { return $m.Groups['p'].Value }
        }
        return $null
    }

    $script:BaseMap = @(
        '{'
        '  "alpha_mod": {'
        '    "modId": 447,'
        '    "name": "Alpha Mod",'
        '    "note": "",'
        '    "pinned": false,'
        '    "githubRepo": "someone/alpha"'
        '  },'
        '  "beta_mod": {'
        '    "modId": null,'
        '    "name": "Beta''s \"Mod\"",'
        '    "note": "unresolved - try https://www.nexusmods.com/games/warhammer40kdarktide/mods?keyword=beta+mod&x=1",'
        '    "pinned": false'
        '  },'
        '  "gamma_mod": {'
        '    "modId": 900,'
        '    "name": "Gamma Mod",'
        '    "note": "",'
        '    "pinned": false'
        '  }'
        '}'
    )
}

AfterAll {
    Get-ChildItem -LiteralPath $script:RepoRoot -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'report-*.csv' -or $_.Name -like 'report-*.json' } |
        Where-Object { $script:PreExistingReports -notcontains $_.Name } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

Describe 'Set-ModPin' {

    BeforeEach {
        $script:Root    = New-TestSandbox
        $script:Game    = New-FakeGameFolder -Root $script:Root
        # delta_mod is staged but has no map entry; gamma_mod is mapped but not staged.
        $script:Staging = New-FakeStaging -Root $script:Root -Mods @('alpha_mod', 'beta_mod', 'delta_mod')
        $script:Config  = New-TestConfig -Root $script:Root -StagingMods $script:Staging -GamePath $script:Game
        $script:Map     = Join-Path $script:Root 'mods-map.json'
        Write-MapFile -Path $script:Map -Lines $script:BaseMap
        Set-ConfigValue -Config $script:Config -Key 'MapPath' -Value $script:Map
        $script:Original = [System.IO.File]::ReadAllBytes($script:Map)
    }

    AfterEach {
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'dry run' {

        It 'writes nothing without -Apply' {
            $before = Get-TreeFingerprint -Path $script:Root

            $out = & $script:Pinner -ConfigPath $script:Config -Only alpha_mod -Reason 'crashes on 1.4' *>&1 | Out-String

            $out | Should -Match 'DRY RUN'
            $out | Should -Match 'Nothing was written'
            Get-TreeFingerprint -Path $script:Root | Should -Be $before
            Test-Path -LiteralPath "$($script:Map).bak" | Should -BeFalse
        }

        It 'listing writes nothing either' {
            $before = Get-TreeFingerprint -Path $script:Root

            $out = & $script:Pinner -ConfigPath $script:Config *>&1 | Out-String

            $out | Should -Match 'No mods are pinned'
            Get-TreeFingerprint -Path $script:Root | Should -Be $before
        }
    }

    Context 'pinning' {

        It 'sets pinned and the three pin keys, right after pinned' {
            & $script:Pinner -ConfigPath $script:Config -Only alpha_mod -Reason 'crashes on 1.4' -Apply *>&1 | Out-Null

            $a = (Read-Map $script:Map).alpha_mod
            $a.pinned        | Should -BeTrue
            $a.pinnedVersion | Should -Be '1.0.0'
            $a.pinnedReason  | Should -Be 'crashes on 1.4'
            "$($a.pinnedAt)" | Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
            ($a.PSObject.Properties.Name -join ',') |
                Should -Be 'modId,name,note,pinned,pinnedVersion,pinnedReason,pinnedAt,githubRepo'
        }

        It 'keeps every other field and the entry order' {
            & $script:Pinner -ConfigPath $script:Config -Only alpha_mod -Apply *>&1 | Out-Null

            $map = Read-Map $script:Map
            ($map.PSObject.Properties.Name -join ',') | Should -Be 'alpha_mod,beta_mod,gamma_mod'
            $map.alpha_mod.githubRepo | Should -Be 'someone/alpha'
            $map.alpha_mod.modId      | Should -Be 447
            $map.beta_mod.name        | Should -Be 'Beta''s "Mod"'
            $map.beta_mod.note        | Should -Match 'keyword=beta\+mod&x=1$'
            $map.beta_mod.pinned      | Should -BeFalse
            $map.gamma_mod.pinned     | Should -BeFalse
        }

        It 'changes only the lines of the entry it pinned' {
            & $script:Pinner -ConfigPath $script:Config -Only beta_mod -Apply *>&1 | Out-Null

            $after = [System.IO.File]::ReadAllText($script:Map)
            # Untouched entries come back character for character - no ' for an
            # apostrophe, no re-indent - so a pin is a small diff.
            $after | Should -Match ([regex]::Escape('"name": "Beta''s \"Mod\"",'))
            $after | Should -Match ([regex]::Escape(('  "gamma_mod": {', '    "modId": 900,') -join "`n"))
            $after | Should -Not -Match '\\u0027'
            $after.EndsWith("}`n") | Should -BeTrue
        }

        It 'backs the previous map up to mods-map.json.bak' {
            & $script:Pinner -ConfigPath $script:Config -Only alpha_mod -Apply *>&1 | Out-Null

            $bak = "$($script:Map).bak"
            Test-Path -LiteralPath $bak | Should -BeTrue
            [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($bak)) |
                Should -Be ([System.Convert]::ToBase64String($script:Original))
            Test-Path -LiteralPath "$($script:Map).tmp" | Should -BeFalse
        }

        It 'records a null pinnedVersion when staging has no version for it' {
            # gamma_mod is in the map but not staged.
            & $script:Pinner -ConfigPath $script:Config -Only gamma_mod -Apply *>&1 | Out-Null

            $g = (Read-Map $script:Map).gamma_mod
            $g.pinned | Should -BeTrue
            $g.PSObject.Properties.Name | Should -Contain 'pinnedVersion'
            $g.pinnedVersion | Should -BeNullOrEmpty
            $g.pinnedReason  | Should -BeNullOrEmpty
        }

        It 'adds a staged folder that has no map entry, in sorted position' {
            & $script:Pinner -ConfigPath $script:Config -Only delta_mod -Reason 'wait for 2.0' -Apply *>&1 | Out-Null

            $map = Read-Map $script:Map
            ($map.PSObject.Properties.Name -join ',') | Should -Be 'alpha_mod,beta_mod,delta_mod,gamma_mod'
            $map.delta_mod.pinned        | Should -BeTrue
            $map.delta_mod.pinnedVersion | Should -Be '1.0.0'
            $map.delta_mod.pinnedReason  | Should -Be 'wait for 2.0'
            $map.delta_mod.PSObject.Properties.Name | Should -Contain 'modId'
        }

        It 'pins several folders given as one comma-separated string' {
            & $script:Pinner -ConfigPath $script:Config -Only 'alpha_mod,gamma_mod' -Apply *>&1 | Out-Null

            $map = Read-Map $script:Map
            $map.alpha_mod.pinned | Should -BeTrue
            $map.gamma_mod.pinned | Should -BeTrue
            $map.beta_mod.pinned  | Should -BeFalse
        }

        It 'keeps the reason when re-pinning without -Reason' {
            & $script:Pinner -ConfigPath $script:Config -Only alpha_mod -Reason 'crashes on 1.4' -Apply *>&1 | Out-Null
            & $script:Pinner -ConfigPath $script:Config -Only alpha_mod -Apply *>&1 | Out-Null

            (Read-Map $script:Map).alpha_mod.pinnedReason | Should -Be 'crashes on 1.4'
        }

        It 'lists the pin with its version, reason and date' {
            & $script:Pinner -ConfigPath $script:Config -Only alpha_mod -Reason 'crashes on 1.4' -Apply *>&1 | Out-Null

            $out = & $script:Pinner -ConfigPath $script:Config *>&1 | Out-String

            $out | Should -Match 'Pinned: 1'
            $out | Should -Match 'alpha_mod\s+1\.0\.0\s+1\.0\.0\s+crashes on 1\.4\s+\d{4}-\d{2}-\d{2}'
        }
    }

    Context 'unpinning' {

        It 'round-trips pin then unpin back to the original bytes' {
            & $script:Pinner -ConfigPath $script:Config -Only alpha_mod,beta_mod -Reason 'x' -Apply *>&1 | Out-Null
            & $script:Pinner -ConfigPath $script:Config -Only alpha_mod,beta_mod -Unpin -Apply *>&1 | Out-Null

            [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($script:Map)) |
                Should -Be ([System.Convert]::ToBase64String($script:Original))
        }

        It 'sets pinned false and removes the three pin keys' {
            & $script:Pinner -ConfigPath $script:Config -Only alpha_mod -Reason 'x' -Apply *>&1 | Out-Null
            & $script:Pinner -ConfigPath $script:Config -Only alpha_mod -Unpin -Apply *>&1 | Out-Null

            $a = (Read-Map $script:Map).alpha_mod
            $a.pinned | Should -BeFalse
            ($a.PSObject.Properties.Name -join ',') | Should -Be 'modId,name,note,pinned,githubRepo'
        }

        It 'writes nothing when the folder is not pinned' {
            $before = Get-TreeFingerprint -Path $script:Root

            $out = & $script:Pinner -ConfigPath $script:Config -Only alpha_mod -Unpin -Apply *>&1 | Out-String

            $out | Should -Match 'Nothing to change'
            Get-TreeFingerprint -Path $script:Root | Should -Be $before
        }

        It 'round-trips the shipped mods-map.json byte for byte' {
            # The real file is the one people diff. Pinning and unpinning a mod in it
            # must leave every other line exactly as it was.
            Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'mods-map.json') -Destination $script:Map -Force
            $real  = [System.IO.File]::ReadAllBytes($script:Map)
            $first = @((Read-Map $script:Map).PSObject.Properties.Name)[0]

            & $script:Pinner -ConfigPath $script:Config -Only $first -Reason 'x' -Apply *>&1 | Out-Null
            (Read-Map $script:Map).$first.pinned | Should -BeTrue
            & $script:Pinner -ConfigPath $script:Config -Only $first -Unpin -Apply *>&1 | Out-Null

            [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($script:Map)) |
                Should -Be ([System.Convert]::ToBase64String($real))
        }
    }

    Context 'refusals' {

        It 'refuses a folder that is in neither the map nor staging, and writes nothing' {
            $before = Get-TreeFingerprint -Path $script:Root

            { & $script:Pinner -ConfigPath $script:Config -Only alpha_mod,no_such_mod -Apply *>&1 | Out-Null } |
                Should -Throw '*Not a known mod folder: no_such_mod*'

            Get-TreeFingerprint -Path $script:Root | Should -Be $before
        }

        It 'refuses -Unpin without -Only' {
            { & $script:Pinner -ConfigPath $script:Config -Unpin -Apply *>&1 | Out-Null } |
                Should -Throw '*Pass -Only*'
        }

        It 'refuses -Reason together with -Unpin' {
            { & $script:Pinner -ConfigPath $script:Config -Only alpha_mod -Unpin -Reason 'x' -Apply *>&1 | Out-Null } |
                Should -Throw '*-Reason*'
        }

        It 'refuses to rewrite a map that is not valid JSON' {
            [System.IO.File]::WriteAllText($script:Map, '{ "alpha_mod": { "pinned": ', $script:Utf8NoBom)
            $before = Get-TreeFingerprint -Path $script:Root

            { & $script:Pinner -ConfigPath $script:Config -Only alpha_mod -Apply *>&1 | Out-Null } |
                Should -Throw '*not valid JSON*'

            Get-TreeFingerprint -Path $script:Root | Should -Be $before
        }
    }

    Context 'through darktide.ps1' {

        It 'pins, lists and unpins with the pin verb' {
            & $script:Dispatcher pin -ConfigPath $script:Config -Only alpha_mod -Reason 'crashes on 1.4' -Apply *>&1 | Out-Null
            (Read-Map $script:Map).alpha_mod.pinned | Should -BeTrue

            $list = & $script:Dispatcher pin -ConfigPath $script:Config *>&1 | Out-String
            $list | Should -Match 'alpha_mod'
            $list | Should -Match 'crashes on 1\.4'

            & $script:Dispatcher pin -ConfigPath $script:Config -Only alpha_mod -Unpin -Apply *>&1 | Out-Null
            [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($script:Map)) |
                Should -Be ([System.Convert]::ToBase64String($script:Original))
        }

        It 'is a dry run without -Apply' {
            $before = Get-TreeFingerprint -Path $script:Root

            & $script:Dispatcher pin -ConfigPath $script:Config -Only alpha_mod -Reason 'x' *>&1 | Out-Null

            Get-TreeFingerprint -Path $script:Root | Should -Be $before
        }

        It 'shows the pinned folders in status' {
            & $script:Dispatcher pin -ConfigPath $script:Config -Only alpha_mod,gamma_mod -Apply *>&1 | Out-Null

            $out = & $script:Dispatcher status -ConfigPath $script:Config *>&1 | Out-String

            $out | Should -Match 'pinned \(held\)\s+: 2 - alpha_mod, gamma_mod'
        }
    }
}

Describe 'Update honours pins' {

    BeforeEach {
        $script:Root      = New-TestSandbox
        $script:Game      = New-FakeGameFolder -Root $script:Root
        $script:Staging   = New-FakeStaging -Root $script:Root -Mods @('alpha_mod', 'beta_mod')
        $script:Config    = New-TestConfig -Root $script:Root -StagingMods $script:Staging -GamePath $script:Game
        $script:Downloads = Join-Path $script:Root 'downloads'
        $script:Backups   = Join-Path $script:Root 'mod_backups'
        $script:Map       = Join-Path $script:Root 'mods-map.json'

        # alpha_mod is installed and pinned; gamma_mod is pinned and NOT installed.
        Write-MapFile -Path $script:Map -Lines @(
            '{'
            '  "alpha_mod": { "modId": 447, "name": "Alpha Mod", "note": "", "pinned": true, "pinnedVersion": "1.0.0", "pinnedReason": "crashes on 1.4", "pinnedAt": "2026-10-01 12:00:00" },'
            '  "beta_mod": { "modId": 448, "name": "Beta Mod", "note": "", "pinned": false },'
            '  "gamma_mod": { "modId": 900, "name": "Gamma Mod", "note": "", "pinned": true }'
            '}'
        )
        Set-ConfigValue -Config $script:Config -Key 'MapPath' -Value $script:Map

        # Every staged mod is 1.0.0; both archives would be installed if not pinned.
        $null = New-TestZip -Path (Join-Path $script:Downloads 'Alpha Mod-447-2-0-0-1719209900.zip') -Entries @{
            'alpha_mod/alpha_mod.mod'   = 'return { version = 2 }'
            'alpha_mod/info.json'       = '{"name":"Alpha Mod","version":"2.0.0"}'
            'alpha_mod/scripts/new.lua' = '-- added in 2.0.0'
        }
        $null = New-TestZip -Path (Join-Path $script:Downloads 'Gamma Mod-900-1-0-0-1719209999.zip') -Entries @{
            'gamma_mod/gamma_mod.mod' = 'return {}'
            'gamma_mod/info.json'     = '{"name":"Gamma Mod","version":"1.0.0"}'
        }

        $script:AlphaBefore = Get-TreeFingerprint -Path (Join-Path $script:Staging 'alpha_mod')
        $script:OrderBefore = Get-Content -LiteralPath (Join-Path $script:Staging 'mod_load_order.txt') -Raw -Encoding UTF8
    }

    AfterEach {
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'offline' {

        It 'leaves a pinned folder untouched and takes no backup, even with a newer archive' {
            & $script:Updater -ConfigPath $script:Config -NoApi -Apply -Confirm:$false *>&1 | Out-Null

            Get-TreeFingerprint -Path (Join-Path $script:Staging 'alpha_mod') | Should -Be $script:AlphaBefore
            @(Get-ChildItem -LiteralPath $script:Backups -Recurse -File -ErrorAction SilentlyContinue) |
                Should -BeNullOrEmpty
        }

        It 'does the same with -Force' {
            & $script:Updater -ConfigPath $script:Config -NoApi -Apply -Force -Confirm:$false *>&1 | Out-Null

            Get-TreeFingerprint -Path (Join-Path $script:Staging 'alpha_mod') | Should -Be $script:AlphaBefore
            @(Get-ChildItem -LiteralPath $script:Backups -Recurse -File -ErrorAction SilentlyContinue) |
                Should -BeNullOrEmpty
            Test-Path -LiteralPath (Join-Path $script:Staging 'gamma_mod') | Should -BeFalse
        }

        It 'does not install a pinned folder that is not installed yet' {
            & $script:Updater -ConfigPath $script:Config -NoApi -Apply -Confirm:$false *>&1 | Out-Null

            Test-Path -LiteralPath (Join-Path $script:Staging 'gamma_mod') | Should -BeFalse
            Get-Content -LiteralPath (Join-Path $script:Staging 'mod_load_order.txt') -Raw -Encoding UTF8 |
                Should -Be $script:OrderBefore
        }

        It 'reports PINNED with the unpin command in the table and the CSV' {
            $lines = @(& $script:Updater -ConfigPath $script:Config -NoApi -Apply -Force -Confirm:$false *>&1 |
                       ForEach-Object { "$_" })
            ($lines -join "`n") | Should -Match 'PINNED'

            $csv = Get-LoggedPath -Output $lines -Label 'Report' -Extension 'csv'
            $csv | Should -Not -BeNullOrEmpty
            $rows = @(Import-Csv -LiteralPath $csv)

            $alpha = @($rows | Where-Object { $_.Mod -eq 'alpha_mod' })
            $alpha.Count     | Should -Be 1
            $alpha[0].Status | Should -Be 'PINNED'
            $alpha[0].Action | Should -Be 'held (unpin with: .\darktide.ps1 pin -Only alpha_mod -Unpin -Apply)'
            @($rows | Where-Object { $_.Mod -eq 'gamma_mod' })[0].Status | Should -Be 'PINNED'
        }

        It 'reports a pinned mod with no archive as PINNED rather than NO-ARCHIVE' {
            Get-ChildItem -LiteralPath $script:Downloads -File | Remove-Item -Force
            $null = New-TestZip -Path (Join-Path $script:Downloads 'Beta Mod-448-1-0-0-1719209999.zip') -Entries @{
                'beta_mod/beta_mod.mod' = 'return {}'
                'beta_mod/info.json'    = '{"name":"Beta Mod","version":"1.0.0"}'
            }

            $lines = @(& $script:Updater -ConfigPath $script:Config -NoApi *>&1 | ForEach-Object { "$_" })
            $rows  = @(Import-Csv -LiteralPath (Get-LoggedPath -Output $lines -Label 'Report' -Extension 'csv'))

            @($rows | Where-Object { $_.Mod -eq 'alpha_mod' })[0].Status | Should -Be 'PINNED'
        }

        It 'writes a JSON report that parses and carries the run and the PINNED row' {
            $lines = @(& $script:Updater -ConfigPath $script:Config -NoApi -Apply -Confirm:$false *>&1 |
                       ForEach-Object { "$_" })

            $csv  = Get-LoggedPath -Output $lines -Label 'Report' -Extension 'csv'
            $json = Get-LoggedPath -Output $lines -Label 'Report JSON' -Extension 'json'
            $json | Should -Not -BeNullOrEmpty
            [System.IO.Path]::GetFileNameWithoutExtension($json) |
                Should -Be ([System.IO.Path]::GetFileNameWithoutExtension($csv))
            Split-Path -Leaf $json | Should -BeLike 'report-offline-*.json'

            $doc = Get-Content -LiteralPath $json -Raw -Encoding UTF8 | ConvertFrom-Json
            ($doc.PSObject.Properties.Name -join ',') | Should -Be 'startedAt,apply,mode,backupSet,rows'
            "$($doc.startedAt)" | Should -Not -BeNullOrEmpty
            $doc.apply          | Should -BeTrue
            $doc.mode           | Should -Be 'offline'
            $doc.backupSet      | Should -BeNullOrEmpty    # nothing was replaced
            $pinned = @($doc.rows | Where-Object { $_.Mod -eq 'alpha_mod' })
            $pinned.Count     | Should -Be 1
            $pinned[0].Status | Should -Be 'PINNED'
            $pinned[0].Latest | Should -Be '2.0.0'
        }

        It 'marks a dry run as apply=false in the JSON report' {
            $lines = @(& $script:Updater -ConfigPath $script:Config -NoApi *>&1 | ForEach-Object { "$_" })

            $doc = Get-Content -LiteralPath (Get-LoggedPath -Output $lines -Label 'Report JSON' -Extension 'json') `
                       -Raw -Encoding UTF8 | ConvertFrom-Json
            $doc.apply     | Should -BeFalse
            $doc.backupSet | Should -BeNullOrEmpty
            @($doc.rows).Count | Should -BeGreaterThan 0
        }

        It 'still updates an unpinned mod beside a pinned one, and names the backup set' {
            $null = New-TestZip -Path (Join-Path $script:Downloads 'Beta Mod-448-2-0-0-1719209999.zip') -Entries @{
                'beta_mod/beta_mod.mod' = 'return { version = 2 }'
                'beta_mod/info.json'    = '{"name":"Beta Mod","version":"2.0.0"}'
            }

            $lines = @(& $script:Updater -ConfigPath $script:Config -NoApi -Apply -Confirm:$false *>&1 |
                       ForEach-Object { "$_" })

            $beta = Get-Content -LiteralPath (Join-Path $script:Staging 'beta_mod\info.json') -Raw -Encoding UTF8 |
                    ConvertFrom-Json
            $beta.version | Should -Be '2.0.0'
            Get-TreeFingerprint -Path (Join-Path $script:Staging 'alpha_mod') | Should -Be $script:AlphaBefore

            $doc = Get-Content -LiteralPath (Get-LoggedPath -Output $lines -Label 'Report JSON' -Extension 'json') `
                       -Raw -Encoding UTF8 | ConvertFrom-Json
            $sets = @(Get-ChildItem -LiteralPath $script:Backups -Directory)
            $sets.Count   | Should -Be 1
            $doc.backupSet | Should -Be $sets[0].Name
            Test-Path -LiteralPath (Join-Path $sets[0].FullName 'alpha_mod.zip') | Should -BeFalse
        }

        It 'installs normally again once unpinned' {
            & $script:Pinner -ConfigPath $script:Config -Only alpha_mod -Unpin -Apply *>&1 | Out-Null

            & $script:Updater -ConfigPath $script:Config -NoApi -Apply -Confirm:$false *>&1 | Out-Null

            $info = Get-Content -LiteralPath (Join-Path $script:Staging 'alpha_mod\info.json') -Raw -Encoding UTF8 |
                    ConvertFrom-Json
            $info.version | Should -Be '2.0.0'
        }
    }

    Context 'online (Nexus mocked)' {

        BeforeEach {
            $script:SavedKey = $env:NEXUS_API_KEY
            $env:NEXUS_API_KEY = 'test-only-key'

            Mock Invoke-WebRequest {
                $body = switch -Wildcard ($Uri) {
                    '*users/validate.json'   { '{"name":"tester","is_premium":false}' }
                    '*mods/448.json'         { '{"name":"Beta Mod","version":"1.0.0"}' }
                    '*mods/448/files.json*'  { '{"files":[]}' }
                    default                  { '{"name":"Unexpected","version":"9.9.9"}' }
                }
                [pscustomobject]@{ Content = $body; Headers = @{} }
            }
        }

        AfterEach {
            if ($null -eq $script:SavedKey) { Remove-Item Env:NEXUS_API_KEY -ErrorAction SilentlyContinue }
            else { $env:NEXUS_API_KEY = $script:SavedKey }
        }

        It 'reports a pinned mod as PINNED, spends no API call on it and installs nothing' {
            $lines = @(& $script:Updater -ConfigPath $script:Config -Apply -Confirm:$false *>&1 | ForEach-Object { "$_" })

            Should -Invoke Invoke-WebRequest -Times 0 -Exactly -ParameterFilter { $Uri -like '*/mods/447*' }
            Get-TreeFingerprint -Path (Join-Path $script:Staging 'alpha_mod') | Should -Be $script:AlphaBefore
            @(Get-ChildItem -LiteralPath $script:Backups -Recurse -File -ErrorAction SilentlyContinue) |
                Should -BeNullOrEmpty

            $csv = Get-LoggedPath -Output $lines -Label 'Report' -Extension 'csv'
            Split-Path -Leaf $csv | Should -BeLike 'report-2*.csv'
            $alpha = @(Import-Csv -LiteralPath $csv | Where-Object { $_.Mod -eq 'alpha_mod' })
            $alpha[0].Status | Should -Be 'PINNED'
            $alpha[0].ModId  | Should -Be '447'

            $doc = Get-Content -LiteralPath (Get-LoggedPath -Output $lines -Label 'Report JSON' -Extension 'json') `
                       -Raw -Encoding UTF8 | ConvertFrom-Json
            $doc.mode | Should -Be 'online'
            @($doc.rows | Where-Object { $_.Mod -eq 'alpha_mod' })[0].Status | Should -Be 'PINNED'
            (Get-Content -LiteralPath (Get-LoggedPath -Output $lines -Label 'Report JSON' -Extension 'json') -Raw) |
                Should -Not -Match 'test-only-key'
        }
    }
}
