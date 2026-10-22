<#
    Test-DarktideSetup.ps1 (the 'doctor' verb). It is read-only, so the properties
    that matter are: a healthy setup is clean, each broken layout is named with the
    right severity, and nothing in staging or the game folder changes while it looks.

    Every .mod file here is written at runtime inside the sandbox; none is committed.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:Dispatcher = Join-Path $script:RepoRoot 'darktide.ps1'
    $script:Doctor     = Join-Path $script:RepoRoot 'Test-DarktideSetup.ps1'
    $script:Locker     = Join-Path $script:RepoRoot 'New-ModpackLock.ps1'

    function New-HealthySetup {
        <#
            Staging, a game folder with the loader pieces, a deploy of staging into it,
            and a lockfile of staging - all inside $script:Root.
        #>
        $script:Game     = New-FakeGameFolder -Root $script:Root
        $script:Staging  = New-FakeStaging -Root $script:Root -Mods @('alpha_mod', 'beta_mod')
        $script:Config   = New-TestConfig -Root $script:Root -StagingMods $script:Staging -GamePath $script:Game
        $script:GameMods = Join-Path $script:Game 'mods'

        [void][System.IO.Directory]::CreateDirectory((Join-Path $script:Game 'tools'))
        Set-Content -LiteralPath (Join-Path $script:Game 'tools\dtkit-patch.exe') -Value 'stub' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $script:Game 'bundle\9ba626afa44a3aa3.patch_999') -Value 'stub' -Encoding ASCII
        '{"version":"26.06.24","patched":true}' |
            Set-Content -LiteralPath (Join-Path $script:Game '.darktide-loader.json') -Encoding ASCII

        Copy-Item -LiteralPath $script:Staging -Destination $script:GameMods -Recurse

        $script:Lock = Join-Path $script:Root 'lock.json'
        & $script:Locker -ModsRoot $script:Staging -OutFile $script:Lock `
            -MapPath (Join-Path $script:Root 'no-map.json') *>&1 | Out-Null

        $script:Reports = Join-Path $script:Root 'reports'
        [void][System.IO.Directory]::CreateDirectory($script:Reports)
    }

    function Invoke-Doctor {
        <#
            Runs the script with a JSON -OutFile outside staging and the game folder,
            and returns the exit code, the printed text and the parsed report.
        #>
        param([hashtable] $Extra = @{}, [switch] $NoLock)

        $report = Join-Path $script:Reports ("doctor-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
        $p = @{ ConfigPath = $script:Config; OutFile = $report }
        if (-not $NoLock) { $p['LockPath'] = $script:Lock }
        foreach ($k in $Extra.Keys) { $p[$k] = $Extra[$k] }

        $text = (& $script:Doctor @p *>&1 | ForEach-Object { "$_" }) -join "`n"
        $code = $LASTEXITCODE
        $json = Get-Content -LiteralPath $report -Raw -Encoding UTF8 | ConvertFrom-Json
        return [pscustomobject]@{ Code = $code; Text = $text; Report = $json; Results = @($json.results) }
    }

    function Get-Finding {
        param($Run, [string] $Check, [string] $Status, [string] $Location, [string] $Subject)
        # The leading comma keeps a one-element result an array, so .Count and [0] work.
        return ,@($Run.Results | Where-Object {
            $_.check -eq $Check -and
            (-not $Status   -or $_.status -eq $Status) -and
            (-not $Location -or $_.location -eq $Location) -and
            (-not $Subject  -or $_.subject -eq $Subject)
        })
    }

    function Add-StagedMod {
        <# A well-formed extra mod, listed in staging's load order. #>
        param([string] $Name, [switch] $Unlisted)
        $dir = Join-Path $script:Staging $Name
        [void][System.IO.Directory]::CreateDirectory($dir)
        Set-Content -LiteralPath (Join-Path $dir "$Name.mod") -Value 'return {}' -Encoding UTF8
        if (-not $Unlisted) {
            Add-Content -LiteralPath (Join-Path $script:Staging 'mod_load_order.txt') -Value $Name
        }
        return $dir
    }
}

Describe 'Test-DarktideSetup.ps1 (doctor)' {

    BeforeEach {
        $script:Root = New-TestSandbox
        New-HealthySetup
    }

    AfterEach {
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'healthy setup' {

        It 'exits 0 with no FAIL and no WARN' {
            $r = Invoke-Doctor
            $r.Code | Should -Be 0
            @($r.Results | Where-Object { $_.status -eq 'FAIL' }).Count | Should -Be 0
            @($r.Results | Where-Object { $_.status -eq 'WARN' }) | ForEach-Object { $_.message } | Should -BeNullOrEmpty
            $r.Report.summary.fail | Should -Be 0
        }

        It 'covers every section' {
            $r = Invoke-Doctor
            $sections = @($r.Results | ForEach-Object { $_.section } | Select-Object -Unique)
            foreach ($s in @('Config', 'Load order', 'Folder structure', 'Drift', 'Loader')) {
                $sections | Should -Contain $s
            }
        }

        It 'confirms staging matches the lockfile and the game by content' {
            $r = Invoke-Doctor
            (Get-Finding $r 'drift.lockmatch' 'PASS').Count | Should -Be 1
            (Get-Finding $r 'drift.game' 'PASS')[0].message | Should -Match 'identical'
        }

        It 'points at patchcheck rather than guessing the bundle state' {
            $r = Invoke-Doctor
            (Get-Finding $r 'loader.patchcheck' 'INFO')[0].fix | Should -Match 'darktide\.ps1 patchcheck'
        }
    }

    Context 'read-only' {

        It 'leaves staging and the game folder byte-for-byte unchanged on a healthy run' {
            $s = Get-TreeFingerprint -Path $script:Staging
            $g = Get-TreeFingerprint -Path $script:Game
            $null = Invoke-Doctor
            Get-TreeFingerprint -Path $script:Staging | Should -Be $s
            Get-TreeFingerprint -Path $script:Game    | Should -Be $g
        }

        It 'leaves them unchanged on a broken run that prints fixes' {
            Add-Content -LiteralPath (Join-Path $script:Staging 'mod_load_order.txt') -Value 'ghost_mod'
            $nest = Join-Path $script:Staging 'nested_mod\nested_mod'
            [void][System.IO.Directory]::CreateDirectory($nest)
            Set-Content -LiteralPath (Join-Path $nest 'nested_mod.mod') -Value 'return {}' -Encoding UTF8
            [void][System.IO.Directory]::CreateDirectory((Join-Path $script:Staging '.staging-alpha_mod'))
            Set-Content -LiteralPath (Join-Path $script:GameMods 'alpha_mod\info.json') -Value '{"edited":true}' -Encoding UTF8

            $s = Get-TreeFingerprint -Path $script:Staging
            $g = Get-TreeFingerprint -Path $script:Game
            $r = Invoke-Doctor
            $r.Code | Should -Be 1
            Get-TreeFingerprint -Path $script:Staging | Should -Be $s
            Get-TreeFingerprint -Path $script:Game    | Should -Be $g
        }
    }

    Context 'config' {

        It 'reports a missing config.json as FAIL with the init hint, and keeps going' {
            Remove-Item -LiteralPath $script:Config -Force
            $r = Invoke-Doctor
            $r.Code | Should -Be 1
            $f = Get-Finding $r 'config.missing' 'FAIL'
            $f.Count | Should -Be 1
            $f[0].fix | Should -Match 'darktide\.ps1 init'
            # Still ran the later sections.
            (Get-Finding $r 'drift.skipped').Count | Should -BeGreaterThan 0
            (Get-Finding $r 'loader.skipped').Count | Should -Be 1
        }

        It 'still checks staging and the game when given paths but no config' {
            Remove-Item -LiteralPath $script:Config -Force
            $r = Invoke-Doctor -Extra @{ StagingMods = $script:Staging; GamePath = $script:Game }
            $r.Code | Should -Be 1
            (Get-Finding $r 'config.missing' 'FAIL').Count | Should -Be 1
            (Get-Finding $r 'loadorder.resolves' 'PASS' 'staging').Count | Should -Be 1
            (Get-Finding $r 'loader.bundle' 'PASS').Count | Should -Be 1
        }

        It 'reports unparseable config.json as FAIL' {
            Set-Content -LiteralPath $script:Config -Value '{ "ModsRoot": ' -Encoding UTF8
            $r = Invoke-Doctor
            $r.Code | Should -Be 1
            (Get-Finding $r 'config.parse' 'FAIL').Count | Should -Be 1
        }

        It 'refuses a GamePath that does not look like Darktide' {
            $notGame = Join-Path $script:Root 'some\other\folder'
            [void][System.IO.Directory]::CreateDirectory($notGame)
            $r = Invoke-Doctor -Extra @{ GamePath = $notGame }
            $r.Code | Should -Be 1
            (Get-Finding $r 'config.gamepath' 'FAIL')[0].message | Should -Match 'does not look like Darktide'
        }

        It 'reports a ModsRoot that does not exist' {
            $r = Invoke-Doctor -Extra @{ StagingMods = (Join-Path $script:Root 'nope') }
            $r.Code | Should -Be 1
            (Get-Finding $r 'config.modsroot' 'FAIL').Count | Should -Be 1
        }
    }

    Context 'load order' {

        It 'FAILs an entry with no folder (ghost)' {
            Add-Content -LiteralPath (Join-Path $script:Staging 'mod_load_order.txt') -Value 'ghost_mod'
            $r = Invoke-Doctor
            $r.Code | Should -Be 1
            (Get-Finding $r 'loadorder.ghost' 'FAIL' 'staging' 'ghost_mod').Count | Should -Be 1
        }

        It 'FAILs a ghost in the game load order too' {
            Add-Content -LiteralPath (Join-Path $script:GameMods 'mod_load_order.txt') -Value 'ghost_mod'
            $r = Invoke-Doctor
            $r.Code | Should -Be 1
            (Get-Finding $r 'loadorder.ghost' 'FAIL' 'game' 'ghost_mod').Count | Should -Be 1
            (Get-Finding $r 'drift.loadorderfile' 'WARN').Count | Should -Be 1
        }

        It 'WARNs a folder the load order does not list, but not base, dmf or dot-folders' {
            $null = Add-StagedMod -Name 'gamma_mod' -Unlisted
            [void][System.IO.Directory]::CreateDirectory((Join-Path $script:Staging '.staging-gamma_mod'))
            $r = Invoke-Doctor
            $r.Code | Should -Be 0
            $u = @(Get-Finding $r 'loadorder.unlisted' 'WARN' 'staging')
            @($u | ForEach-Object { $_.subject }) | Should -Be @('gamma_mod')
            (Get-Finding $r 'structure.leftover' 'INFO' 'staging').Count | Should -Be 1
        }

        It 'WARNs duplicates that differ only by case and whitespace' {
            Add-Content -LiteralPath (Join-Path $script:Staging 'mod_load_order.txt') -Value '  ALPHA_mod  '
            $r = Invoke-Doctor
            $d = Get-Finding $r 'loadorder.duplicate' 'WARN' 'staging'
            $d.Count | Should -Be 1
            $d[0].message | Should -Match '2 times'
            (Get-Finding $r 'loadorder.ghost').Count | Should -Be 0
        }

        It 'lists disabled -- entries as INFO and does not call them unlisted' {
            $lo = Join-Path $script:Staging 'mod_load_order.txt'
            Set-Content -LiteralPath $lo -Value @('-- a comment, not a mod', 'alpha_mod', '--beta_mod') -Encoding ASCII
            $r = Invoke-Doctor
            $i = Get-Finding $r 'loadorder.disabled' 'INFO' 'staging'
            $i.Count | Should -Be 1
            $i[0].message | Should -Match 'beta_mod'
            $i[0].message | Should -Not -Match 'comment'
            (Get-Finding $r 'loadorder.unlisted' -Location 'staging').Count | Should -Be 0
        }

        It 'FAILs when dmf is missing from staging' {
            Remove-Item -LiteralPath (Join-Path $script:Staging 'dmf') -Recurse -Force
            $r = Invoke-Doctor
            $r.Code | Should -Be 1
            (Get-Finding $r 'loadorder.nodmf' 'FAIL' 'staging').Count | Should -Be 1
            (Get-Finding $r 'loadorder.nodmf' -Location 'game').Count | Should -Be 0
        }

        It 'FAILs when dmf is missing from the game' {
            Remove-Item -LiteralPath (Join-Path $script:GameMods 'dmf') -Recurse -Force
            $r = Invoke-Doctor
            (Get-Finding $r 'loadorder.nodmf' 'FAIL' 'game')[0].fix | Should -Match 'deploy -Apply'
        }

        It 'WARNs dmf listed but not first, and says the rule is unverified' {
            Add-Content -LiteralPath (Join-Path $script:Staging 'mod_load_order.txt') -Value 'dmf'
            $r = Invoke-Doctor
            $w = Get-Finding $r 'loadorder.dmforder' 'WARN' 'staging'
            $w.Count | Should -Be 1
            $w[0].message | Should -Match 'not verified'
        }

        It 'reports a byte-order mark and mixed line endings as INFO only' {
            $lo = Join-Path $script:Staging 'mod_load_order.txt'
            $bytes = [byte[]](0xEF, 0xBB, 0xBF) + [System.Text.Encoding]::ASCII.GetBytes("alpha_mod`r`nbeta_mod`n")
            [System.IO.File]::WriteAllBytes((Convert-Path -LiteralPath $lo), $bytes)
            $r = Invoke-Doctor
            (Get-Finding $r 'loadorder.bom' 'INFO' 'staging').Count | Should -Be 1
            (Get-Finding $r 'loadorder.lineendings' 'INFO' 'staging').Count | Should -Be 1
            (Get-Finding $r 'loadorder.ghost').Count | Should -Be 0
        }

        It 'FAILs a game folder that was never deployed' {
            Remove-Item -LiteralPath $script:GameMods -Recurse -Force
            $r = Invoke-Doctor
            $r.Code | Should -Be 1
            (Get-Finding $r 'loadorder.nogamemods' 'FAIL').Count | Should -Be 1
        }
    }

    Context 'folder structure' {

        It 'FAILs a mod extracted one level too deep, with the exact fix' {
            $nest = Join-Path $script:Staging 'gamma_mod\gamma_mod'
            [void][System.IO.Directory]::CreateDirectory($nest)
            Set-Content -LiteralPath (Join-Path $nest 'gamma_mod.mod') -Value 'return {}' -Encoding UTF8
            Add-Content -LiteralPath (Join-Path $script:Staging 'mod_load_order.txt') -Value 'gamma_mod'
            $r = Invoke-Doctor
            $r.Code | Should -Be 1
            $f = Get-Finding $r 'structure.nested' 'FAIL' 'staging' 'gamma_mod'
            $f.Count | Should -Be 1
            $f[0].fix | Should -Match 'Move-Item'
            $f[0].fix | Should -Match ([regex]::Escape((Join-Path 'gamma_mod' 'gamma_mod')))
        }

        It 'FAILs a .mod named differently from its folder, and names the rename' {
            $dir = Join-Path $script:Staging 'gamma_mod'
            [void][System.IO.Directory]::CreateDirectory($dir)
            Set-Content -LiteralPath (Join-Path $dir 'gamma.mod') -Value 'return {}' -Encoding UTF8
            Add-Content -LiteralPath (Join-Path $script:Staging 'mod_load_order.txt') -Value 'gamma_mod'
            $r = Invoke-Doctor
            $r.Code | Should -Be 1
            $f = Get-Finding $r 'structure.modname' 'FAIL' 'staging' 'gamma_mod'
            $f.Count | Should -Be 1
            $f[0].fix | Should -Match "Rename-Item .* -NewName 'gamma'"
        }

        It 'WARNs an empty mod folder' {
            [void][System.IO.Directory]::CreateDirectory((Join-Path $script:Staging 'gamma_mod'))
            Add-Content -LiteralPath (Join-Path $script:Staging 'mod_load_order.txt') -Value 'gamma_mod'
            $r = Invoke-Doctor
            (Get-Finding $r 'structure.empty' 'WARN' 'staging' 'gamma_mod').Count | Should -Be 1
            (Get-Finding $r 'structure.nomod' -Subject 'gamma_mod').Count | Should -Be 0
        }

        It 'handles a folder name with brackets' {
            $null = Add-StagedMod -Name '[x]mod'
            $r = Invoke-Doctor
            (Get-Finding $r 'loadorder.ghost').Count | Should -Be 0
            (Get-Finding $r 'structure.modname').Count | Should -Be 0
            (Get-Finding $r 'drift.extra' 'WARN' 'staging' '[x]mod').Count | Should -Be 1
        }
    }

    Context 'drift' {

        It 'reports a staged file edited after locking as CHANGED' {
            Add-Content -LiteralPath (Join-Path $script:Staging 'alpha_mod\alpha_mod.mod') -Value '-- local edit'
            $r = Invoke-Doctor
            $c = Get-Finding $r 'drift.changed' 'WARN' 'staging' 'alpha_mod'
            $c.Count | Should -Be 1
            $c[0].message | Should -Match 'CHANGED'
            (Get-Finding $r 'drift.changed' -Subject 'beta_mod').Count | Should -Be 0
        }

        It 'reports MISSING and EXTRA against the lockfile' {
            Remove-Item -LiteralPath (Join-Path $script:Staging 'beta_mod') -Recurse -Force
            $null = Add-StagedMod -Name 'gamma_mod'
            $r = Invoke-Doctor
            (Get-Finding $r 'drift.missing' 'WARN' 'staging' 'beta_mod').Count | Should -Be 1
            (Get-Finding $r 'drift.extra' 'WARN' 'staging' 'gamma_mod').Count | Should -Be 1
        }

        It 'treats a null lockfile hash as unknown, not as a change' {
            & $script:Locker -ModsRoot $script:Staging -OutFile $script:Lock -NoHash `
                -MapPath (Join-Path $script:Root 'no-map.json') *>&1 | Out-Null
            Add-Content -LiteralPath (Join-Path $script:Staging 'alpha_mod\alpha_mod.mod') -Value '-- local edit'
            $r = Invoke-Doctor
            (Get-Finding $r 'drift.changed').Count | Should -Be 0
            (Get-Finding $r 'drift.unknown' 'INFO').Count | Should -Be 1
        }

        It 'reports the lockfile load order differing from staging as INFO' {
            Set-Content -LiteralPath (Join-Path $script:Staging 'mod_load_order.txt') -Value @('beta_mod', 'alpha_mod') -Encoding ASCII
            $r = Invoke-Doctor
            (Get-Finding $r 'drift.lockorder' 'INFO').Count | Should -Be 1
        }

        It 'reports game content that differs from staging' {
            Add-Content -LiteralPath (Join-Path $script:GameMods 'beta_mod\beta_mod.mod') -Value '-- edited in the game folder'
            $r = Invoke-Doctor
            $r.Code | Should -Be 0
            $w = Get-Finding $r 'drift.gamecontent' 'WARN' 'game' 'beta_mod'
            $w.Count | Should -Be 1
            $w[0].fix | Should -Match 'deploy -Apply'
        }

        It 'reports folders only in staging or only in the game' {
            $null = Add-StagedMod -Name 'gamma_mod'
            Remove-Item -LiteralPath (Join-Path $script:GameMods 'alpha_mod') -Recurse -Force
            $r = Invoke-Doctor
            (Get-Finding $r 'drift.notdeployed' 'WARN' 'game' 'gamma_mod').Count | Should -Be 1
            (Get-Finding $r 'drift.notdeployed' 'WARN' 'game' 'alpha_mod').Count | Should -Be 1
        }

        It '-Quick skips content hashing but still compares names' {
            Add-Content -LiteralPath (Join-Path $script:Staging 'alpha_mod\alpha_mod.mod') -Value '-- local edit'
            Add-Content -LiteralPath (Join-Path $script:GameMods 'beta_mod\beta_mod.mod') -Value '-- edited in the game folder'
            Remove-Item -LiteralPath (Join-Path $script:GameMods 'alpha_mod') -Recurse -Force
            $r = Invoke-Doctor -Extra @{ Quick = $true }
            $r.Report.quick | Should -BeTrue
            (Get-Finding $r 'drift.quick' 'INFO').Count | Should -Be 1
            (Get-Finding $r 'drift.changed').Count | Should -Be 0
            (Get-Finding $r 'drift.gamecontent').Count | Should -Be 0
            (Get-Finding $r 'drift.lockmatch').Count | Should -Be 0
            (Get-Finding $r 'drift.notdeployed' 'WARN' 'game' 'alpha_mod').Count | Should -Be 1
        }

        It 'WARNs, not FAILs, when there is no lockfile' {
            $r = Invoke-Doctor -Extra @{ LockPath = (Join-Path $script:Root 'none.lock.json') }
            $r.Code | Should -Be 0
            (Get-Finding $r 'drift.nolock' 'WARN')[0].fix | Should -Match 'darktide\.ps1 lock'
        }
    }

    Context 'loader' {

        It 'FAILs when the mod entry bundle is missing' {
            Remove-Item -LiteralPath (Join-Path $script:Game 'bundle\9ba626afa44a3aa3.patch_999') -Force
            $r = Invoke-Doctor
            $r.Code | Should -Be 1
            (Get-Finding $r 'loader.bundle' 'FAIL')[0].fix | Should -Match 'loader -Apply'
        }

        It 'WARNs an install recorded as unpatched, and a missing patcher' {
            '{"version":"26.06.24","patched":false}' |
                Set-Content -LiteralPath (Join-Path $script:Game '.darktide-loader.json') -Encoding ASCII
            Remove-Item -LiteralPath (Join-Path $script:Game 'tools\dtkit-patch.exe') -Force
            $r = Invoke-Doctor
            $r.Code | Should -Be 0
            (Get-Finding $r 'loader.unpatched' 'WARN').Count | Should -Be 1
            (Get-Finding $r 'loader.patcher' 'WARN').Count | Should -Be 1
        }

        It 'WARNs when the loader state file is absent' {
            Remove-Item -LiteralPath (Join-Path $script:Game '.darktide-loader.json') -Force
            $r = Invoke-Doctor
            (Get-Finding $r 'loader.nostate' 'WARN').Count | Should -Be 1
        }
    }

    Context '-OutFile' {

        It 'writes JSON that parses, with a summary matching the results' {
            $r = Invoke-Doctor
            $r.Report.tool | Should -Be 'Test-DarktideSetup.ps1'
            $r.Report.summary.pass | Should -Be @($r.Results | Where-Object { $_.status -eq 'PASS' }).Count
            @($r.Results).Count | Should -BeGreaterThan 5
        }

        It 'writes markdown' {
            $md = Join-Path $script:Reports 'doctor.md'
            & $script:Doctor -ConfigPath $script:Config -LockPath $script:Lock -OutFile $md *>&1 | Out-Null
            $text = Get-Content -LiteralPath $md -Raw
            $text | Should -Match '# Darktide setup doctor'
            $text | Should -Match '## Load order'
        }

        It 'refuses to overwrite without -Force, and does with it' {
            $out = Join-Path $script:Reports 'doctor.json'
            Set-Content -LiteralPath $out -Value 'keep me' -Encoding ASCII
            { & $script:Doctor -ConfigPath $script:Config -LockPath $script:Lock -OutFile $out *>&1 | Out-Null } |
                Should -Throw '*-Force*'
            Get-Content -LiteralPath $out -Raw | Should -Match 'keep me'

            & $script:Doctor -ConfigPath $script:Config -LockPath $script:Lock -OutFile $out -Force *>&1 | Out-Null
            { Get-Content -LiteralPath $out -Raw | ConvertFrom-Json } | Should -Not -Throw
        }

        It 'refuses to write the report into the game folder or staging' {
            foreach ($dir in @($script:Game, $script:Staging)) {
                $inside = Join-Path $dir 'doctor.json'
                { & $script:Doctor -ConfigPath $script:Config -LockPath $script:Lock -OutFile $inside *>&1 | Out-Null } |
                    Should -Throw '*Refusing to write*'
                Test-Path -LiteralPath $inside | Should -BeFalse
            }
        }

        It 'refuses an extension it does not write' {
            { & $script:Doctor -ConfigPath $script:Config -OutFile (Join-Path $script:Reports 'doctor.txt') *>&1 | Out-Null } |
                Should -Throw '*.json or .md*'
            Test-Path -LiteralPath (Join-Path $script:Reports 'doctor.txt') | Should -BeFalse
        }
    }

    Context 'dispatcher' {

        It 'runs doctor from darktide.ps1 and exits 0 when nothing FAILs' {
            # The dispatcher compares against the repository lockfile, which names other
            # mods - that is drift (WARN), never a FAIL.
            $out = Join-Path $script:Reports 'via-dispatcher.json'
            & $script:Dispatcher doctor -ConfigPath $script:Config -Quick -OutFile $out *>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
            $rep = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
            $rep.quick | Should -BeTrue
            $rep.summary.fail | Should -Be 0
        }

        It 'runs before init: no config is a FAIL with the init hint, not a throw' {
            Remove-Item -LiteralPath $script:Config -Force
            $text = (& $script:Dispatcher doctor -ConfigPath $script:Config -Quick *>&1 | ForEach-Object { "$_" }) -join "`n"
            $LASTEXITCODE | Should -Be 1
            $text | Should -Match 'FAIL\s+No config\.json'
            $text | Should -Match 'darktide\.ps1 init'
        }

        It 'leaves staging and the game unchanged' {
            $s = Get-TreeFingerprint -Path $script:Staging
            $g = Get-TreeFingerprint -Path $script:Game
            & $script:Dispatcher doctor -ConfigPath $script:Config *>&1 | Out-Null
            Get-TreeFingerprint -Path $script:Staging | Should -Be $s
            Get-TreeFingerprint -Path $script:Game    | Should -Be $g
        }
    }
}
