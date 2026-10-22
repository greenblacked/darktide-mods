<#
    Tests for Get-DarktideBuildState.ps1 (the 'patchcheck' verb).

    Every case builds a fake game under steamapps\common\ and, where it needs one, a
    Steam app manifest one level above 'common', which is where Steam keeps it. The
    loader's state file is written in the shape Install-DarktideLoader.ps1 records
    after a patch: an uppercase SHA-256 from Get-FileHash, plus length and times.

    The check is read-only apart from -Remember (a baseline beside staging) and
    -OutFile, so the game folder's fingerprint is asserted unchanged throughout.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:Dispatcher = Join-Path $script:RepoRoot 'darktide.ps1'
    $script:Checker    = Join-Path $script:RepoRoot 'Get-DarktideBuildState.ps1'

    Import-ScriptFunctions -Path $script:Checker -Name @('Read-SteamManifest', 'ConvertFrom-UnixTime', 'Get-ObjectField')

    function ConvertTo-UnixSeconds {
        param([Parameter(Mandatory)][datetime] $Date)
        return ([DateTimeOffset]$Date.ToUniversalTime()).ToUnixTimeSeconds()
    }

    function Write-Acf {
        <# A Steam app manifest in the shape Steam writes, with a nested depot block. #>
        param(
            [Parameter(Mandatory)][string] $Path,
            [string]   $BuildId     = '20012345',
            [string]   $TargetBuild = '20012345',
            [string]   $StateFlags  = '4',
            [datetime] $LastUpdated = [datetime]'2026-06-01T12:00:00Z'
        )
        $lines = @(
            '"AppState"',
            '{',
            "`t`"appid`"`t`t`"1361210`"",
            "`t`"Universe`"`t`t`"1`"",
            "`t`"name`"`t`t`"Warhammer 40,000: Darktide`"",
            "`t`"StateFlags`"`t`t`"$StateFlags`"",
            "`t`"installdir`"`t`t`"Warhammer 40,000 DARKTIDE`"",
            "`t`"LastUpdated`"`t`t`"$(ConvertTo-UnixSeconds -Date $LastUpdated)`"",
            "`t`"buildid`"`t`t`"$BuildId`"",
            "`t`"TargetBuildID`"`t`t`"$TargetBuild`"",
            "`t`"InstalledDepots`"",
            "`t{",
            "`t`t`"1361211`"",
            "`t`t{",
            "`t`t`t`"manifest`"`t`t`"8765432109876543210`"",
            "`t`t`t`"buildid`"`t`t`"11111111`"",
            "`t`t}",
            "`t}",
            '}'
        )
        Set-Content -LiteralPath $Path -Value $lines -Encoding ASCII
    }

    function Add-LoaderFiles {
        <# What the loader puts in the game folder, as stand-ins. #>
        param([Parameter(Mandatory)][string] $Game)
        [void][System.IO.Directory]::CreateDirectory((Join-Path $Game 'binaries\mod_loader'))
        Set-Content -LiteralPath (Join-Path $Game 'binaries\mod_loader\stub.txt') -Value 'stub' -Encoding ASCII
        [void][System.IO.Directory]::CreateDirectory((Join-Path $Game 'tools'))
        Set-Content -LiteralPath (Join-Path $Game 'tools\dtkit-patch.exe') -Value 'stub' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $Game 'bundle\9ba626afa44a3aa3.patch_999') -Value 'stub' -Encoding ASCII
    }

    function Write-LoaderState {
        <#
            .darktide-loader.json. -Sha256 is written as given (the loader writes
            Get-FileHash's uppercase); -NoBundleDb writes a pre-fingerprint record.
        #>
        param(
            [Parameter(Mandatory)][string] $Game,
            [string]   $Sha256,
            [switch]   $NoBundleDb,
            [datetime] $InstalledAt = (Get-Date)
        )
        $db = Get-Item -LiteralPath (Join-Path $Game 'bundle\bundle_database.data')
        if (-not $Sha256) { $Sha256 = (Get-FileHash -LiteralPath $db.FullName -Algorithm SHA256).Hash }
        $state = [ordered]@{
            modId       = 19
            name        = 'Darktide Mod Loader'
            version     = '1.5.0'
            source      = 'loader.zip'
            installedAt = $InstalledAt.ToString('o')
            patched     = $true
        }
        if (-not $NoBundleDb) {
            $state['bundleDb'] = [ordered]@{
                sha256           = $Sha256
                length           = [long]$db.Length
                lastWriteTimeUtc = $db.LastWriteTimeUtc.ToString('o')
                recordedAt       = (Get-Date).ToUniversalTime().ToString('o')
            }
        }
        $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Game '.darktide-loader.json') -Encoding UTF8
    }

    function Set-ModInstalledAt {
        param([Parameter(Mandatory)][string] $Mod, [Parameter(Mandatory)][datetime] $When)
        [ordered]@{ modId = 1; version = '1.0.0'; installedAt = $When.ToString('o') } | ConvertTo-Json |
            Set-Content -LiteralPath (Join-Path (Join-Path $script:Staging $Mod) '.nexus-mod.json') -Encoding UTF8
    }

    function Invoke-Check {
        <# Runs the script with the sandbox config and returns its exit code. #>
        param([hashtable] $Extra = @{})
        $p = @{ ConfigPath = $script:Cfg; MapPath = $script:Map }
        foreach ($k in $Extra.Keys) { $p[$k] = $Extra[$k] }
        & $script:Checker @p *>&1 | Out-Null
        return $LASTEXITCODE
    }

    function Get-Report {
        <# Runs the script with -OutFile json and returns the exit code and the parsed report. #>
        param([hashtable] $Extra = @{})
        $out = Join-Path $script:Root 'report.json'
        $e = @{ OutFile = $out; Force = $true }
        foreach ($k in $Extra.Keys) { $e[$k] = $Extra[$k] }
        $code = Invoke-Check -Extra $e
        $report = Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json
        return [pscustomobject]@{ Code = $code; Report = $report }
    }

    function Get-FileList {
        param([Parameter(Mandatory)][string] $Path)
        return @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force | ForEach-Object { $_.FullName } | Sort-Object)
    }
}

Describe 'Get-DarktideBuildState (patchcheck)' {

    BeforeEach {
        $script:Root    = New-TestSandbox
        $script:Game    = New-FakeGameFolder -Root $script:Root
        $script:Staging = New-FakeStaging -Root $script:Root -Mods @('alpha_mod', 'beta_mod')
        $script:Cfg     = New-TestConfig -Root $script:Root -StagingMods $script:Staging -GamePath $script:Game
        $script:Map     = Join-Path $script:Root 'mods-map.json'
        '{}' | Set-Content -LiteralPath $script:Map -Encoding UTF8
        $script:Acf      = Join-Path $script:Root 'steamapps\appmanifest_1361210.acf'
        $script:Baseline = Join-Path $script:Root '.darktide-gamestate.json'
        Write-Acf -Path $script:Acf
        Add-LoaderFiles -Game $script:Game
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'patch status' {

        It 'reports IN SYNC when the recorded uppercase hash matches the database' {
            Write-LoaderState -Game $script:Game
            $state = Get-Content -LiteralPath (Join-Path $script:Game '.darktide-loader.json') -Raw | ConvertFrom-Json
            $state.bundleDb.sha256 | Should -MatchExactly '^[0-9A-F]{64}$'

            $r = Get-Report
            $r.Code                      | Should -Be 0
            $r.Report.verdict            | Should -Be 'IN SYNC'
            $r.Report.loader.patchStatus | Should -Be 'PATCHED'
            $r.Report.loader.heuristic   | Should -BeFalse
            $r.Report.steam.status       | Should -Be 'OK'
            $r.Report.steam.buildid      | Should -Be '20012345'
        }

        It 'reports DB REPLACED, exits 1 and recommends loader -PatchOnly -Apply' {
            Write-LoaderState -Game $script:Game
            # Steam replacing the database: same path, different content.
            Set-Content -LiteralPath (Join-Path $script:Game 'bundle\bundle_database.data') -Value 'a new build' -Encoding ASCII

            $r = Get-Report
            $r.Code                      | Should -Be 1
            $r.Report.verdict            | Should -Be 'ACTION NEEDED'
            $r.Report.loader.patchStatus | Should -Be 'DB REPLACED'
            ($r.Report.next -join "`n")  | Should -Match ([regex]::Escape('loader -PatchOnly -Apply'))
        }

        It 'exits 1 and recommends loader -Apply -Force when loader files are missing' {
            Write-LoaderState -Game $script:Game
            Remove-Item -LiteralPath (Join-Path $script:Game 'tools\dtkit-patch.exe') -Force
            Remove-Item -LiteralPath (Join-Path $script:Game 'bundle\9ba626afa44a3aa3.patch_999') -Force

            $r = Get-Report
            $r.Code | Should -Be 1
            @($r.Report.loader.missingFiles) | Should -Contain 'tools\dtkit-patch.exe'
            @($r.Report.loader.missingFiles) | Should -Contain 'bundle\*.patch_999'
            ($r.Report.next -join "`n")      | Should -Match ([regex]::Escape('loader -Apply -Force'))
        }

        It 'falls back to the timestamp heuristic, and says so, when no fingerprint was recorded' {
            $db = Join-Path $script:Game 'bundle\bundle_database.data'
            Write-LoaderState -Game $script:Game -NoBundleDb -InstalledAt ([datetime]'2026-05-01T10:00:00Z')
            (Get-Item -LiteralPath $db).LastWriteTimeUtc = [datetime]'2026-06-01T12:00:00Z'

            $r = Get-Report
            $r.Code                      | Should -Be 0
            $r.Report.loader.patchStatus | Should -Be 'LIKELY UPDATED'
            $r.Report.loader.heuristic   | Should -BeTrue
            (@($r.Report.findings | ForEach-Object { $_.message }) -join "`n") | Should -Match 'heuristic'
        }

        It 'reports LIKELY PATCHED when the database predates the loader install' {
            $db = Join-Path $script:Game 'bundle\bundle_database.data'
            (Get-Item -LiteralPath $db).LastWriteTimeUtc = [datetime]'2026-01-01T00:00:00Z'
            Write-LoaderState -Game $script:Game -NoBundleDb -InstalledAt ([datetime]'2026-05-01T10:00:00Z')

            $r = Get-Report
            $r.Code                      | Should -Be 0
            $r.Report.loader.patchStatus | Should -Be 'LIKELY PATCHED'
            $r.Report.verdict            | Should -Be 'UNKNOWN'
        }

        It 'reads a state file with fields missing without failing' {
            '{ "version": "1.5.0", "bundleDb": {} }' |
                Set-Content -LiteralPath (Join-Path $script:Game '.darktide-loader.json') -Encoding UTF8

            $r = Get-Report
            $r.Code                      | Should -Be 0
            $r.Report.loader.patchStatus | Should -Be 'UNKNOWN'
            $r.Report.verdict            | Should -Be 'UNKNOWN'
        }

        It 'exits 0 with a warning when there is no loader state at all' {
            $r = Get-Report
            $r.Code                      | Should -Be 0
            $r.Report.verdict            | Should -Be 'UNKNOWN'
            @($r.Report.findings | Where-Object { $_.level -eq 'WARN' }).Count | Should -BeGreaterThan 0
        }
    }

    Context 'Steam manifest' {

        It 'reports StateFlags 1026 as pending and suggests no -Apply step, even with the database replaced' {
            Write-LoaderState -Game $script:Game
            Set-Content -LiteralPath (Join-Path $script:Game 'bundle\bundle_database.data') -Value 'half written' -Encoding ASCII
            Write-Acf -Path $script:Acf -StateFlags '1026'

            $r = Get-Report
            $r.Code                     | Should -Be 0
            $r.Report.verdict           | Should -Be 'UPDATE PENDING'
            $r.Report.steam.status      | Should -Be 'PENDING'
            ($r.Report.next -join "`n") | Should -Not -Match '-Apply'
            (@($r.Report.findings | ForEach-Object { $_.message }) -join "`n") | Should -Not -Match '-Apply'
        }

        It 'reports a target build that differs from the installed one as pending' {
            Write-LoaderState -Game $script:Game
            Write-Acf -Path $script:Acf -TargetBuild '20099999'

            $r = Get-Report
            $r.Report.verdict      | Should -Be 'UPDATE PENDING'
            $r.Report.steam.status | Should -Be 'PENDING'
        }

        It 'treats TargetBuildID 0 as no target, not as pending' {
            Write-LoaderState -Game $script:Game
            Write-Acf -Path $script:Acf -TargetBuild '0'

            (Get-Report).Report.verdict | Should -Be 'IN SYNC'
        }

        It 'degrades with a clear message when there is no manifest, and still runs the other checks' {
            Write-LoaderState -Game $script:Game
            Remove-Item -LiteralPath $script:Acf -Force

            $r = Get-Report
            $r.Code                      | Should -Be 0
            $r.Report.steam.status       | Should -Be 'MISSING'
            $r.Report.loader.patchStatus | Should -Be 'PATCHED'
            (@($r.Report.findings | ForEach-Object { $_.message }) -join "`n") |
                Should -Match 'not a Steam install or manifest not found'
        }

        It 'reads a manifest given with -ManifestPath' {
            Write-LoaderState -Game $script:Game
            Remove-Item -LiteralPath $script:Acf -Force
            $elsewhere = Join-Path $script:Root 'elsewhere.acf'
            Write-Acf -Path $elsewhere -BuildId '20055555' -TargetBuild '20055555'

            $r = Get-Report -Extra @{ ManifestPath = $elsewhere }
            $r.Report.steam.status  | Should -Be 'OK'
            $r.Report.steam.buildid | Should -Be '20055555'
        }

        It 'ignores every field of a manifest that belongs to another app' {
            Write-LoaderState -Game $script:Game
            $other = Join-Path $script:Root 'other.acf'
            Write-Acf -Path $other -BuildId '99999999' -TargetBuild '99999999'
            (Get-Content -LiteralPath $other) -replace '"1361210"', '"570"' |
                Set-Content -LiteralPath $other -Encoding ASCII

            $r = Get-Report -Extra @{ ManifestPath = $other; Remember = $true }
            $r.Report.steam.status        | Should -Be 'WRONG APP'
            $r.Report.steam.buildid       | Should -BeNullOrEmpty
            $r.Report.steam.targetBuildId | Should -BeNullOrEmpty
            $r.Report.steam.stateFlags    | Should -BeNullOrEmpty
            if (Test-Path -LiteralPath $script:Baseline) {
                (Get-Content -LiteralPath $script:Baseline -Raw | ConvertFrom-Json).buildid | Should -BeNullOrEmpty
            }
        }

        It 'takes top-level keys only, case-insensitively' {
            $acf = Read-SteamManifest -Path $script:Acf
            $acf['buildid']       | Should -Be '20012345'
            $acf['targetbuildid'] | Should -Be '20012345'
            $acf['stateflags']    | Should -Be '4'
            $acf.ContainsKey('manifest') | Should -BeFalse
        }

        It 'converts LastUpdated from unix seconds, and rejects junk' {
            (ConvertFrom-UnixTime -Seconds '1780315200').ToString('o') | Should -Be '2026-06-01T12:00:00.0000000Z'
            ConvertFrom-UnixTime -Seconds 'never' | Should -BeNullOrEmpty
            ConvertFrom-UnixTime -Seconds '0'     | Should -BeNullOrEmpty
        }

        It 'reads absent fields from empty or scalar JSON as null under StrictMode' {
            Get-ObjectField ('{}' | ConvertFrom-Json) 'sha256' | Should -BeNullOrEmpty
            Get-ObjectField 5 'sha256'                         | Should -BeNullOrEmpty
            Get-ObjectField $null 'sha256'                     | Should -BeNullOrEmpty
        }
    }

    Context 'writes' {

        It 'writes nothing anywhere without -Remember or -OutFile' {
            Write-LoaderState -Game $script:Game
            $before = Get-TreeFingerprint -Path $script:Root

            Invoke-Check | Should -Be 0

            Get-TreeFingerprint -Path $script:Root | Should -Be $before
            Test-Path -LiteralPath $script:Baseline | Should -BeFalse
        }

        It '-Remember writes the baseline beside staging and nothing else' {
            Write-LoaderState -Game $script:Game
            $gameBefore  = Get-TreeFingerprint -Path $script:Game
            $filesBefore = Get-FileList -Path $script:Root

            Invoke-Check -Extra @{ Remember = $true } | Should -Be 0

            Get-TreeFingerprint -Path $script:Game | Should -Be $gameBefore
            $added = @(Get-FileList -Path $script:Root | Where-Object { $filesBefore -notcontains $_ })
            $added.Count | Should -Be 1
            # -Force: a dot-file is hidden off Windows.
            $added[0]    | Should -Be (Get-Item -LiteralPath $script:Baseline -Force).FullName

            $b = Get-Content -LiteralPath $script:Baseline -Raw | ConvertFrom-Json
            $b.buildid         | Should -Be '20012345'
            $b.bundleDb.sha256 | Should -Not -BeNullOrEmpty
            $b.checkedAt       | Should -Not -BeNullOrEmpty
        }

        It 'compares against the remembered baseline: old build -> new build' {
            Write-LoaderState -Game $script:Game
            Invoke-Check -Extra @{ Remember = $true } | Out-Null
            Write-Acf -Path $script:Acf -BuildId '20077777' -TargetBuild '20077777'
            $baselineBefore = Get-Content -LiteralPath $script:Baseline -Raw

            $r = Get-Report
            $r.Report.baseline.found      | Should -BeTrue
            $r.Report.baseline.comparison | Should -Match 'build changed since last remembered check'
            $r.Report.baseline.comparison | Should -Match '20012345 -> 20077777'
            # Without -Remember the baseline is read, never rewritten.
            Get-Content -LiteralPath $script:Baseline -Raw | Should -Be $baselineBefore
        }

        It 'does not remember a build while Steam is still updating' {
            Write-LoaderState -Game $script:Game
            Write-Acf -Path $script:Acf -StateFlags '1026'

            Invoke-Check -Extra @{ Remember = $true } | Out-Null

            Test-Path -LiteralPath $script:Baseline | Should -BeFalse
        }

        It 'writes a JSON report that parses' {
            Write-LoaderState -Game $script:Game
            $r = Get-Report
            $r.Report.schemaVersion | Should -Be 1
            $r.Report.exitCode      | Should -Be 0
            $r.Report.bundleDb.sha256 | Should -MatchExactly '^[0-9a-f]{64}$'
        }

        It 'writes a markdown report' {
            Write-LoaderState -Game $script:Game
            $md = Join-Path $script:Root 'report.md'
            Invoke-Check -Extra @{ OutFile = $md } | Out-Null
            (Get-Content -LiteralPath $md -Raw) | Should -Match '# Darktide build state'
        }

        It 'refuses to overwrite an -OutFile without -Force, and overwrites with it' {
            $out = Join-Path $script:Root 'report.json'
            Set-Content -LiteralPath $out -Value 'keep me' -Encoding ASCII

            { & $script:Checker -ConfigPath $script:Cfg -MapPath $script:Map -OutFile $out *>&1 | Out-Null } |
                Should -Throw '*-Force*'
            (Get-Content -LiteralPath $out -Raw).Trim() | Should -Be 'keep me'

            Invoke-Check -Extra @{ OutFile = $out; Force = $true } | Out-Null
            { Get-Content -LiteralPath $out -Raw | ConvertFrom-Json } | Should -Not -Throw
        }

        It 'refuses an -OutFile inside the game folder, or with another extension' {
            { & $script:Checker -ConfigPath $script:Cfg -OutFile (Join-Path $script:Game 'r.json') *>&1 | Out-Null } |
                Should -Throw '*inside the game folder*'
            { & $script:Checker -ConfigPath $script:Cfg -OutFile (Join-Path $script:Root 'r.txt') *>&1 | Out-Null } |
                Should -Throw '*.json or .md*'
        }
    }

    Context 'staged mods vs the last game update' {

        It 'classifies PREDATES-PATCH, OK, PINNED and UNKNOWN, and skips base and dot-folders' {
            Write-LoaderState -Game $script:Game
            foreach ($m in @('gamma_mod', 'pinned_mod', '.hidden')) {
                [void][System.IO.Directory]::CreateDirectory((Join-Path $script:Staging $m))
            }
            # The manifest says the game last updated on 2026-06-01.
            Set-ModInstalledAt -Mod 'alpha_mod'  -When ([datetime]'2026-01-01T00:00:00Z')
            Set-ModInstalledAt -Mod 'beta_mod'   -When ([datetime]'2026-07-01T00:00:00Z')
            Set-ModInstalledAt -Mod 'pinned_mod' -When ([datetime]'2026-01-01T00:00:00Z')
            @{ pinned_mod = @{ modId = 5; pinned = $true }; beta_mod = @{ modId = 6; pinned = $false } } |
                ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:Map -Encoding UTF8

            $r = Get-Report
            $rows = @{}
            foreach ($row in @($r.Report.staleMods.mods)) { $rows[$row.folder] = $row.status }

            $rows['alpha_mod']  | Should -Be 'PREDATES-PATCH'
            $rows['beta_mod']   | Should -Be 'OK'
            $rows['pinned_mod'] | Should -Be 'PINNED'
            $rows['gamma_mod']  | Should -Be 'UNKNOWN'
            $rows.ContainsKey('base')    | Should -BeFalse
            $rows.ContainsKey('.hidden') | Should -BeFalse

            $r.Code | Should -Be 0
            ($r.Report.next -join "`n") | Should -Match ([regex]::Escape('links -Only alpha_mod'))
            ($r.Report.next -join "`n") | Should -Not -Match 'pinned_mod'
        }

        It 'quotes folder names that would not paste as bare words' {
            Write-LoaderState -Game $script:Game
            [void][System.IO.Directory]::CreateDirectory((Join-Path $script:Staging 'odd [name]'))
            Set-ModInstalledAt -Mod 'odd [name]' -When ([datetime]'2026-01-01T00:00:00Z')
            Set-ModInstalledAt -Mod 'alpha_mod'  -When ([datetime]'2026-01-01T00:00:00Z')

            $r = Get-Report
            ($r.Report.next -join "`n") | Should -Match ([regex]::Escape("links -Only alpha_mod,'odd [name]'"))
        }

        It 'calls it a heuristic and never says broken or newer' {
            Write-LoaderState -Game $script:Game
            Set-ModInstalledAt -Mod 'alpha_mod' -When ([datetime]'2026-01-01T00:00:00Z')

            $text = & $script:Checker -ConfigPath $script:Cfg -MapPath $script:Map *>&1 | Out-String
            $r = Get-Report
            $json = Get-Content -LiteralPath (Join-Path $script:Root 'report.json') -Raw

            $r.Report.staleMods.note | Should -Match 'Heuristic'
            $r.Report.staleMods.note | Should -Match 'installed before the game last updated'
            foreach ($t in @($text, $json)) {
                $t | Should -Not -Match 'broken'
                $t | Should -Not -Match 'newer'
            }
        }

        It 'leaves every mod UNKNOWN when the manifest gives no update time' {
            Write-LoaderState -Game $script:Game
            Remove-Item -LiteralPath $script:Acf -Force
            Set-ModInstalledAt -Mod 'alpha_mod' -When ([datetime]'2026-01-01T00:00:00Z')

            $r = Get-Report
            @($r.Report.staleMods.mods | Where-Object { $_.status -ne 'UNKNOWN' }).Count | Should -Be 0
        }
    }

    Context 'through darktide.ps1' {

        It 'patchcheck exits 0 when in sync and writes nothing' {
            Write-LoaderState -Game $script:Game
            $before = Get-TreeFingerprint -Path $script:Root

            & $script:Dispatcher patchcheck -ConfigPath $script:Cfg *>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
            Get-TreeFingerprint -Path $script:Root | Should -Be $before
        }

        It 'patchcheck passes exit 1 on when the database was replaced' {
            Write-LoaderState -Game $script:Game
            Set-Content -LiteralPath (Join-Path $script:Game 'bundle\bundle_database.data') -Value 'a new build' -Encoding ASCII

            & $script:Dispatcher patchcheck -ConfigPath $script:Cfg *>&1 | Out-Null
            $LASTEXITCODE | Should -Be 1
        }

        It 'patchcheck -Remember and -OutFile reach the script' {
            Write-LoaderState -Game $script:Game
            $out = Join-Path $script:Root 'via-dispatcher.json'

            & $script:Dispatcher patchcheck -ConfigPath $script:Cfg -Remember -OutFile $out *>&1 | Out-Null

            Test-Path -LiteralPath $script:Baseline | Should -BeTrue
            (Get-Content -LiteralPath $out -Raw | ConvertFrom-Json).baseline.remembered | Should -BeTrue
        }

        It 'patchcheck needs a config' {
            { & $script:Dispatcher patchcheck -ConfigPath (Join-Path $script:Root 'nope.json') *>&1 | Out-Null } |
                Should -Throw '*config*'
        }
    }
}
