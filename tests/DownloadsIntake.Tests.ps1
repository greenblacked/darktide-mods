<#
    Tests for Test-DownloadedMods.ps1, the 'intake' verb.

    Every case runs the script for real against a sandbox: a staging folder, a
    download folder of zips built at runtime with New-TestZip, and a lockfile and
    mods-map written inline. The real lockfile and mods-map are never read, except
    by the dispatcher test, which cannot pass -LockPath and so asserts only what
    holds whatever the committed lockfile contains.

    The script is read-only, so the property that matters most after the statuses
    is that the download and staging trees are byte-for-byte untouched.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:Dispatcher = Join-Path $script:RepoRoot 'darktide.ps1'
    $script:Intake     = Join-Path $script:RepoRoot 'Test-DownloadedMods.ps1'

    function Set-StagedState {
        <# What the updater writes after an install: the Nexus id and version it put there. #>
        param([string] $Staging, [string] $Mod, [int] $ModId, [string] $Version)
        @{ modId = $ModId; version = $Version; name = $Mod } | ConvertTo-Json |
            Set-Content -LiteralPath (Join-Path (Join-Path $Staging $Mod) '.nexus-mod.json') -Encoding UTF8
    }

    function New-ModZip {
        <# A DMF mod archive: <mod>/<mod>.mod, plus info.json when a version is given. #>
        param([string] $Dir, [string] $Name, [string] $Mod, [string] $Version)
        $entries = @{ "$Mod/$Mod.mod" = 'return {}' }
        if ($Version) { $entries["$Mod/info.json"] = (@{ name = $Mod; version = $Version } | ConvertTo-Json) }
        return New-TestZip -Path (Join-Path $Dir $Name) -Entries $entries
    }

    function Invoke-Intake {
        <# Runs the script, swallowing its host output; returns the exit code. #>
        param([hashtable] $Extra = @{})
        $splat = @{ ConfigPath = $script:Config; LockPath = $script:Lock; MapPath = $script:Map }
        foreach ($k in $Extra.Keys) { $splat[$k] = $Extra[$k] }
        $global:LASTEXITCODE = 0
        & $script:Intake @splat *>&1 | Out-Null
        return $LASTEXITCODE
    }

    function Get-IntakeJson {
        param([hashtable] $Extra = @{})
        $out = Join-Path $script:Root 'intake.json'
        if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
        $all = @{ OutFile = $out }
        foreach ($k in $Extra.Keys) { $all[$k] = $Extra[$k] }
        $code = Invoke-Intake -Extra $all
        $doc = Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json
        return @{ Code = $code; Doc = $doc }
    }

    function Get-Row {
        param($Doc, [string] $File)
        $hit = @($Doc.archives | Where-Object { $_.file -eq $File })
        if ($hit.Count -ne 1) { throw "expected exactly one row for '$File', got $($hit.Count)" }
        return $hit[0]
    }
}

Describe 'Test-DownloadedMods (intake)' {

    BeforeEach {
        $script:Root      = New-TestSandbox
        $script:Game      = New-FakeGameFolder -Root $script:Root
        $script:Staging   = New-FakeStaging -Root $script:Root -Mods @('alpha_mod', 'beta_mod', 'gamma_mod', 'delta_mod', 'idle_mod')
        $script:Config    = New-TestConfig -Root $script:Root -StagingMods $script:Staging -GamePath $script:Game
        $script:Downloads = Join-Path $script:Root 'downloads'

        # Every staged mod is 1.0.0 (New-FakeStaging). delta_mod was installed from
        # Nexus mod 700, which is what the impostor below has to be compared with.
        Set-StagedState -Staging $script:Staging -Mod 'delta_mod' -ModId 700 -Version '1.0.0'

        $lock = [ordered]@{
            schemaVersion = 1
            game          = 'warhammer40kdarktide'
            modCount      = 9
            loadOrder     = @()
            mods          = @(
                [ordered]@{ folder = 'alpha_mod';   name = 'Alpha';   modId = 447; version = '1.0.0'
                            url = 'https://www.nexusmods.com/warhammer40kdarktide/mods/447' },
                [ordered]@{ folder = 'beta_mod';    name = 'Beta';    modId = 500; version = '1.0.0' },
                [ordered]@{ folder = 'gamma_mod';   name = 'Gamma';   modId = 600; version = '1.0.0' },
                [ordered]@{ folder = 'delta_mod';   name = 'Delta';   modId = 700; version = '1.0.0' },
                [ordered]@{ folder = 'idle_mod';    name = 'Idle';    modId = 710; version = '1.0.0' },
                [ordered]@{ folder = 'new_mod';     name = 'New';     modId = 800; version = '1.1.0' },
                [ordered]@{ folder = 'epsilon_mod'; name = 'Epsilon'; modId = 321; version = '1.0.0' },
                [ordered]@{ folder = 'missing_mod'; name = 'Missing'; modId = 900; version = '3.2.1' },
                [ordered]@{ folder = 'noid_mod';    name = 'No id';   modId = $null; version = '0.1' }
            )
        }
        $script:Lock = Join-Path $script:Root 'test.lock.json'
        $script:Map  = Join-Path $script:Root 'test.map.json'
        $lock | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:Lock -Encoding UTF8
        @{ gamma_mod = @{ modId = 600; pinned = $false } } | ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath $script:Map -Encoding UTF8

        $d = $script:Downloads
        $null = New-ModZip -Dir $d -Name 'Alpha Mod-447-2-0-0-1719209900.zip' -Mod 'alpha_mod' -Version '2.0.0'
        $null = New-ModZip -Dir $d -Name 'Beta Mod-500-1-0-0-1719209900.zip'  -Mod 'beta_mod'  -Version '1.0.0'
        $null = New-ModZip -Dir $d -Name 'Gamma Mod-600-0-9-0-1719209900.zip' -Mod 'gamma_mod' -Version '0.9.0'
        $null = New-ModZip -Dir $d -Name 'Stranger-1234-1-0-0-1719209900.zip' -Mod 'stranger_mod' -Version '1.0.0'
        # Nexus mod 999 that happens to ship a folder called delta_mod.
        $null = New-ModZip -Dir $d -Name 'Impostor-999-3-0-0-1719209900.zip'  -Mod 'delta_mod' -Version '3.0.0'
        $null = New-TestZip -Path (Join-Path $d 'readme-pack.zip') -Entries @{ 'readme.txt' = 'not a mod' }
        Set-Content -LiteralPath (Join-Path $d 'Epsilon Mod-321-1-0-0-1719209900.7z') -Value 'not really 7z' -Encoding ASCII
        # Renamed, and no info.json inside: nothing to read a version from.
        $null = New-ModZip -Dir $d -Name 'zeta.zip' -Mod 'zeta_mod' -Version ''
        # Two versions of one mod. The older one is also the newer file on disk, so
        # the winner has to be picked by version and not by mtime.
        $older = New-ModZip -Dir $d -Name 'New Mod-800-1-0-0-1719209900.zip' -Mod 'new_mod' -Version '1.0.0'
        $newer = New-ModZip -Dir $d -Name 'New Mod-800-1-1-0-1719209999.zip' -Mod 'new_mod' -Version '1.1.0'
        (Get-Item -LiteralPath $newer).LastWriteTime = (Get-Date).AddHours(-2)
        (Get-Item -LiteralPath $older).LastWriteTime = (Get-Date).AddHours(-1)
        Set-Content -LiteralPath (Join-Path $d 'notes.txt') -Value 'not an archive' -Encoding ASCII
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'classification' {

        BeforeEach {
            $script:Result = Get-IntakeJson
            $script:Doc    = $script:Result.Doc
        }

        It 'marks a Nexus-named zip newer than staging as UPGRADE' {
            $r = Get-Row $script:Doc 'Alpha Mod-447-2-0-0-1719209900.zip'
            $r.status         | Should -Be 'UPGRADE'
            $r.mod            | Should -Be 'alpha_mod'
            $r.archiveVersion | Should -Be '2.0.0'
            $r.stagedVersion  | Should -Be '1.0.0'
        }

        It 'marks the same version as SAME and an older one as OLDER' {
            (Get-Row $script:Doc 'Beta Mod-500-1-0-0-1719209900.zip').status  | Should -Be 'SAME'
            (Get-Row $script:Doc 'Gamma Mod-600-0-9-0-1719209900.zip').status | Should -Be 'OLDER'
        }

        It 'warns that an unlocked DMF mod would install as new' {
            $r = Get-Row $script:Doc 'Stranger-1234-1-0-0-1719209900.zip'
            $r.status | Should -Be 'NOT-IN-LOCK'
            $r.mod    | Should -Be 'stranger_mod'
            $r.note   | Should -Match 'NEW'
        }

        It 'flags a zip whose filename id differs from the staged .nexus-mod.json' {
            $r = Get-Row $script:Doc 'Impostor-999-3-0-0-1719209900.zip'
            $r.status        | Should -Be 'ID-MISMATCH'
            $r.mod           | Should -Be 'delta_mod'
            $r.nexusModId    | Should -Be 999
            $r.expectedModId | Should -Be 700
            $r.note          | Should -Match '\.nexus-mod\.json'
        }

        It 'reports a zip with no .mod inside as NOT-DMF' {
            $r = Get-Row $script:Doc 'readme-pack.zip'
            $r.status | Should -Be 'NOT-DMF'
            $r.mod    | Should -BeNullOrEmpty
        }

        It 'reports a .7z as UNSUPPORTED-FORMAT and ties it to its mod by Nexus id' {
            $r = Get-Row $script:Doc 'Epsilon Mod-321-1-0-0-1719209900.7z'
            $r.status         | Should -Be 'UNSUPPORTED-FORMAT'
            $r.mod            | Should -Be 'epsilon_mod'
            $r.archiveVersion | Should -Be '1.0.0'
        }

        It 'reports a renamed zip with no info.json as VERSION-UNKNOWN' {
            $r = Get-Row $script:Doc 'zeta.zip'
            $r.status | Should -Be 'VERSION-UNKNOWN'
            $r.mod    | Should -Be 'zeta_mod'
        }

        It 'picks the higher version of two zips and calls the other SUPERSEDED' {
            $win  = Get-Row $script:Doc 'New Mod-800-1-1-0-1719209999.zip'
            $lose = Get-Row $script:Doc 'New Mod-800-1-0-0-1719209900.zip'
            $win.status  | Should -Be 'NEW-IN-LOCK'
            $lose.status | Should -Be 'SUPERSEDED'
            $lose.note   | Should -Match ([regex]::Escape('New Mod-800-1-1-0-1719209999.zip'))
            $lose.note   | Should -Match 'delete'
        }

        It 'lists locked mods that are neither staged nor downloaded, with their page' {
            $names = @($script:Doc.missing | ForEach-Object { $_.mod })
            $names | Should -Be @('missing_mod', 'noid_mod')
            $m = @($script:Doc.missing | Where-Object { $_.mod -eq 'missing_mod' })[0]
            $m.url | Should -Be 'https://www.nexusmods.com/warhammer40kdarktide/mods/900'
            @($script:Doc.missing | Where-Object { $_.mod -eq 'noid_mod' })[0].url | Should -BeNullOrEmpty
        }

        It 'does not call a mod missing when its only archive is a .7z' {
            @($script:Doc.missing | ForEach-Object { $_.mod }) | Should -Not -Contain 'epsilon_mod'
        }

        It 'counts staged mods that have no archive instead of listing them' {
            # idle_mod is the only locked, staged mod with no archive in downloads.
            $script:Doc.stagedWithoutArchive | Should -Be 1
        }

        It 'ignores files that are not archives, and says how many' {
            @($script:Doc.archives | Where-Object { $_.file -eq 'notes.txt' }).Count | Should -Be 0
            $script:Doc.ignoredFiles | Should -Be 1
        }

        It 'exits 1 when an ID-MISMATCH is present' {
            $script:Result.Code | Should -Be 1
        }
    }

    Context 'exit codes and selection' {

        It 'exits 0 when nothing carries a mismatched id' {
            Remove-Item -LiteralPath (Join-Path $script:Downloads 'Impostor-999-3-0-0-1719209900.zip') -Force
            Invoke-Intake | Should -Be 0
        }

        It 'checks the lockfile id when the staged copy has none' {
            Remove-Item -LiteralPath (Join-Path (Join-Path $script:Staging 'delta_mod') '.nexus-mod.json') -Force
            $res = Get-IntakeJson
            $r = Get-Row $res.Doc 'Impostor-999-3-0-0-1719209900.zip'
            $r.status        | Should -Be 'ID-MISMATCH'
            $r.expectedModId | Should -Be 700
            $res.Code        | Should -Be 1
        }

        It '-Skip leaves out the mismatched mod, and the exit code follows' {
            $res = Get-IntakeJson -Extra @{ Skip = @('delta_mod') }
            $res.Code | Should -Be 0
            @($res.Doc.archives | Where-Object { $_.mod -eq 'delta_mod' }).Count | Should -Be 0
            # Archives with no folder are not 'delta_mod', so -Skip keeps them.
            @($res.Doc.archives | Where-Object { $_.file -eq 'readme-pack.zip' }).Count | Should -Be 1
        }

        It '-Only narrows archives and the missing list to those folders' {
            $res = Get-IntakeJson -Extra @{ Only = @('alpha_mod', 'missing_mod') }
            @($res.Doc.archives | ForEach-Object { $_.file }) | Should -Be @('Alpha Mod-447-2-0-0-1719209900.zip')
            @($res.Doc.missing  | ForEach-Object { $_.mod })  | Should -Be @('missing_mod')
            $res.Code | Should -Be 0
        }

        It 'notes a pinned staged mod, because update will leave it alone' {
            @{ alpha_mod = @{ modId = 447; pinned = $true } } | ConvertTo-Json -Depth 4 |
                Set-Content -LiteralPath $script:Map -Encoding UTF8
            $r = Get-Row (Get-IntakeJson).Doc 'Alpha Mod-447-2-0-0-1719209900.zip'
            $r.status | Should -Be 'UPGRADE'
            $r.note   | Should -Match 'pinned'
        }

        It 'tolerates side files that are valid but empty JSON' {
            Remove-Item -LiteralPath (Join-Path $script:Downloads 'Impostor-999-3-0-0-1719209900.zip') -Force
            Set-Content -LiteralPath (Join-Path (Join-Path $script:Staging 'alpha_mod') 'info.json') -Value '{}' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path (Join-Path $script:Staging 'delta_mod') '.nexus-mod.json') -Value '{}' -Encoding ASCII
            Set-Content -LiteralPath $script:Map -Value '{ "alpha_mod": {} }' -Encoding ASCII
            $res = Get-IntakeJson
            $res.Code | Should -Be 0
            (Get-Row $res.Doc 'Alpha Mod-447-2-0-0-1719209900.zip').mod | Should -Be 'alpha_mod'
        }

        It 'does not call the legitimate zip safe to delete when an impostor outranks it' {
            $null = New-ModZip -Dir $script:Downloads -Name 'Delta-700-1-0-0-1719209900.zip' -Mod 'delta_mod' -Version '1.0.0'
            $res = Get-IntakeJson
            $r = Get-Row $res.Doc 'Delta-700-1-0-0-1719209900.zip'
            $r.status | Should -Be 'SUPERSEDED'
            $r.note   | Should -Not -Match 'Safe to delete'
            $r.note   | Should -Match 'Keep this one'
            $res.Code | Should -Be 1
        }

        It 'says update skips both when two zips of one mod have no version' {
            $null = New-ModZip -Dir $script:Downloads -Name 'zeta-copy.zip' -Mod 'zeta_mod' -Version ''
            $rows = @((Get-IntakeJson).Doc.archives | Where-Object { $_.mod -eq 'zeta_mod' })
            $rows.Count | Should -Be 2
            $lose = @($rows | Where-Object { $_.status -eq 'SUPERSEDED' })
            $lose.Count   | Should -Be 1
            $lose[0].note | Should -Match 'skips both'
            $lose[0].note | Should -Not -Match 'update uses'
        }
    }

    Context 'read-only' {

        It 'leaves the download and staging folders exactly as they were' {
            $before = (Get-TreeFingerprint -Path $script:Downloads) + "`n--`n" + (Get-TreeFingerprint -Path $script:Staging)
            $rootBefore = @(Get-ChildItem -LiteralPath $script:RepoRoot -Force | ForEach-Object { $_.Name }) -join ','

            Invoke-Intake | Out-Null
            $null = Get-IntakeJson

            $after = (Get-TreeFingerprint -Path $script:Downloads) + "`n--`n" + (Get-TreeFingerprint -Path $script:Staging)
            $after | Should -Be $before
            # No log folder or report dropped beside the script either.
            (@(Get-ChildItem -LiteralPath $script:RepoRoot -Force | ForEach-Object { $_.Name }) -join ',') |
                Should -Be $rootBefore
        }

        It 'writes a markdown report when -OutFile ends in .md' {
            $md = Join-Path $script:Root 'intake.md'
            Invoke-Intake -Extra @{ OutFile = $md } | Out-Null
            $text = Get-Content -LiteralPath $md -Raw -Encoding UTF8
            $text | Should -Match '# Download intake'
            $text | Should -Match 'ID-MISMATCH'
            $text | Should -Match ([regex]::Escape('[Nexus](https://www.nexusmods.com/warhammer40kdarktide/mods/900)'))
        }
    }

    Context 'refusals' {

        It 'will not overwrite -OutFile without -Force' {
            $out = Join-Path $script:Root 'intake.json'
            Set-Content -LiteralPath $out -Value 'keep me' -Encoding ASCII
            { & $script:Intake -ConfigPath $script:Config -LockPath $script:Lock -MapPath $script:Map -OutFile $out *>&1 | Out-Null } |
                Should -Throw '*already exists*'
            (Get-Content -LiteralPath $out -Raw).Trim() | Should -Be 'keep me'

            Invoke-Intake -Extra @{ OutFile = $out; Force = $true } | Out-Null
            { Get-Content -LiteralPath $out -Raw | ConvertFrom-Json } | Should -Not -Throw
        }

        It 'refuses an -OutFile that is neither .json nor .md' {
            { & $script:Intake -ConfigPath $script:Config -LockPath $script:Lock -MapPath $script:Map `
                  -OutFile (Join-Path $script:Root 'intake.txt') *>&1 | Out-Null } | Should -Throw '*.json or .md*'
        }

        It 'refuses an -OutFile inside the staging folder' {
            $inside = Join-Path $script:Staging 'intake.md'
            { & $script:Intake -ConfigPath $script:Config -LockPath $script:Lock -MapPath $script:Map `
                  -OutFile $inside *>&1 | Out-Null } | Should -Throw '*staging folder*'
            Test-Path -LiteralPath $inside | Should -BeFalse
        }

        It 'stops when the download folder does not exist' {
            Remove-Item -LiteralPath $script:Downloads -Recurse -Force
            { & $script:Intake -ConfigPath $script:Config -LockPath $script:Lock -MapPath $script:Map *>&1 | Out-Null } |
                Should -Throw '*DownloadDir*'
        }

        It 'stops when there is no config and no paths were given' {
            { & $script:Intake -ConfigPath (Join-Path $script:Root 'nope.json') -LockPath $script:Lock *>&1 | Out-Null } |
                Should -Throw '*No config*'
        }

        It 'stops when the lockfile is missing' {
            { & $script:Intake -ConfigPath $script:Config -LockPath (Join-Path $script:Root 'none.lock.json') *>&1 | Out-Null } |
                Should -Throw '*No lockfile*'
        }
    }

    Context 'darktide.ps1 intake' {

        # The dispatcher cannot be pointed at a sandbox lockfile, so these cases
        # build archives whose status does not depend on what the committed
        # lockfile lists: alpha_mod and the others are test names, not real mods.

        It 'runs the intake and passes -OutFile through' {
            Remove-Item -LiteralPath (Join-Path $script:Downloads 'Impostor-999-3-0-0-1719209900.zip') -Force
            $out = Join-Path $script:Root 'via-dispatcher.json'
            $before = Get-TreeFingerprint -Path $script:Staging

            $global:LASTEXITCODE = 0
            & $script:Dispatcher intake -ConfigPath $script:Config -OutFile $out *>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0

            $doc = Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json
            (Get-Row $doc 'readme-pack.zip').status | Should -Be 'NOT-DMF'
            (Get-Row $doc 'Alpha Mod-447-2-0-0-1719209900.zip').mod | Should -Be 'alpha_mod'
            Get-TreeFingerprint -Path $script:Staging | Should -Be $before
        }

        It 'exits 1 through the dispatcher when an id mismatches' {
            # delta_mod's staged .nexus-mod.json says 700; the zip says 999. Staging
            # is consulted before the lockfile, so this holds whatever it contains.
            $global:LASTEXITCODE = 0
            & $script:Dispatcher intake -ConfigPath $script:Config -Only delta_mod *>&1 | Out-Null
            $LASTEXITCODE | Should -Be 1
        }
    }
}
