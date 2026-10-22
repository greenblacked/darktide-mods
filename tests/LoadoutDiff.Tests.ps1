<#
    Tests for Compare-DarktideLoadout.ps1 and the 'diff' verb.

    Every lockfile here is built by hand in a sandbox, so each test states exactly
    what differs. The zip input is built at runtime with New-TestZip and holds only a
    lockfile. The 'current' side runs New-ModpackLock.ps1 for real against
    New-FakeStaging, and the repository lockfile is hashed before and after to prove
    it was never written. The git side needs git on PATH; where it is missing those
    tests are reported as skipped, not passed.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:Dispatcher = Join-Path $script:RepoRoot 'darktide.ps1'
    $script:Differ     = Join-Path $script:RepoRoot 'Compare-DarktideLoadout.ps1'
    $script:Locker     = Join-Path $script:RepoRoot 'New-ModpackLock.ps1'
    $script:RepoLock   = Join-Path $script:RepoRoot 'darktide-modpack.lock.json'
    $script:HasGit     = [bool](Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue)

    $script:TopKeys = @('schemaVersion', 'left', 'right', 'identical', 'added', 'removed', 'versionChanged',
                        'contentChanged', 'modIdChanged', 'urlChanged', 'nameChanged', 'loadOrder',
                        'nowKnown', 'nowUnknown')

    function New-Mod {
        <# One lockfile entry. Every field can be overridden, including to $null. #>
        param([Parameter(Mandatory)][string] $Folder, [hashtable] $Set = @{})

        $m = [ordered]@{
            folder        = $Folder
            name          = $Folder
            modId         = 100
            version       = '1.0.0'
            versionSource = 'info.json'
            url           = 'https://www.nexusmods.com/warhammer40kdarktide/mods/100'
            contentSha256 = ('a' * 63) + '1'
        }
        foreach ($k in $Set.Keys) { $m[$k] = $Set[$k] }
        return $m
    }

    function ConvertTo-LockJson {
        param([object[]] $Mods, [string[]] $LoadOrder, $SchemaVersion = 1)

        if ($null -eq $LoadOrder) { $LoadOrder = @($Mods | ForEach-Object { $_.folder }) }
        return ([ordered]@{
            schemaVersion = $SchemaVersion
            name          = 'test loadout'
            game          = 'warhammer40kdarktide'
            modCount      = @($Mods).Count
            loadOrder     = @($LoadOrder)
            mods          = @($Mods)
        } | ConvertTo-Json -Depth 6)
    }

    function New-LockFile {
        param([Parameter(Mandatory)][string] $Path, [object[]] $Mods = @(), [string[]] $LoadOrder, $SchemaVersion = 1)
        ConvertTo-LockJson -Mods $Mods -LoadOrder $LoadOrder -SchemaVersion $SchemaVersion |
            Set-Content -LiteralPath $Path -Encoding UTF8
        return $Path
    }

    function Invoke-Diff {
        <# Runs the script with a JSON -OutFile and returns the parsed result and the exit code. #>
        param([Parameter(Mandatory)][string] $Left, [Parameter(Mandatory)][string] $Right, [hashtable] $Extra = @{})

        $json = Join-Path $script:Root ('result-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
        & $script:Differ -Left $Left -Right $Right -OutFile $json @Extra *>&1 | Out-Null
        $code = $LASTEXITCODE
        return @{
            Code   = $code
            Result = (Get-Content -LiteralPath $json -Raw -Encoding UTF8 | ConvertFrom-Json)
        }
    }

    function Invoke-Git {
        <# git in a sandbox repo. Native stderr is discarded, never merged, and the exit code checked. #>
        param([Parameter(Mandatory)][string] $Repo, [Parameter(Mandatory)][string[]] $GitArgs)

        $eap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & git -C $Repo -c advice.detachedHead=false -c init.defaultBranch=main -c commit.gpgsign=false `
                  -c user.name=fixture -c user.email=fixture@example.invalid @GitArgs 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') exited $LASTEXITCODE" }
        } finally { $ErrorActionPreference = $eap }
    }

    function Get-Sha256 {
        param([Parameter(Mandatory)][string] $Path)
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
}

Describe 'Compare-DarktideLoadout' {

    BeforeEach {
        $script:Root  = New-TestSandbox
        $script:LeftF = Join-Path $script:Root 'left.lock.json'
        $script:RightF = Join-Path $script:Root 'right.lock.json'
    }

    AfterEach {
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'two lockfiles' {

        It 'calls identical lockfiles identical, exits 0, and still writes every key as an empty list' {
            $mods = @((New-Mod 'alpha_mod'), (New-Mod 'beta_mod'))
            New-LockFile -Path $script:LeftF  -Mods $mods | Out-Null
            New-LockFile -Path $script:RightF -Mods $mods | Out-Null

            $r = Invoke-Diff -Left $script:LeftF -Right $script:RightF

            $r.Code | Should -Be 0
            $r.Result.identical | Should -BeTrue
            @($r.Result.PSObject.Properties.Name) | Should -Be $script:TopKeys
            foreach ($k in @('added', 'removed', 'versionChanged', 'contentChanged', 'modIdChanged',
                             'urlChanged', 'nameChanged', 'nowKnown', 'nowUnknown')) {
                $r.Result.$k -is [System.Array] | Should -BeTrue -Because "'$k' must be a list even when empty"
                @($r.Result.$k).Count | Should -Be 0 -Because "'$k' should be empty"
            }
            @($r.Result.loadOrder.PSObject.Properties.Name) | Should -Be @('added', 'removed', 'moved')
            foreach ($k in @('added', 'removed', 'moved')) {
                $r.Result.loadOrder.$k -is [System.Array] | Should -BeTrue
                @($r.Result.loadOrder.$k).Count | Should -Be 0
            }
        }

        It 'reports an added mod and exits 1' {
            New-LockFile -Path $script:LeftF  -Mods @((New-Mod 'alpha_mod')) | Out-Null
            New-LockFile -Path $script:RightF -Mods @((New-Mod 'alpha_mod'), (New-Mod 'beta_mod' @{ version = '2.1' })) | Out-Null

            $r = Invoke-Diff -Left $script:LeftF -Right $script:RightF

            $r.Code | Should -Be 1
            @($r.Result.added).Count | Should -Be 1
            $r.Result.added[0].folder  | Should -Be 'beta_mod'
            $r.Result.added[0].version | Should -Be '2.1'
            @($r.Result.removed).Count | Should -Be 0
            @($r.Result.loadOrder.added | ForEach-Object { $_.folder }) | Should -Be @('beta_mod')
        }

        It 'reports a removed mod' {
            New-LockFile -Path $script:LeftF  -Mods @((New-Mod 'alpha_mod'), (New-Mod 'beta_mod')) | Out-Null
            New-LockFile -Path $script:RightF -Mods @((New-Mod 'alpha_mod')) | Out-Null

            $r = Invoke-Diff -Left $script:LeftF -Right $script:RightF

            $r.Code | Should -Be 1
            @($r.Result.removed | ForEach-Object { $_.folder }) | Should -Be @('beta_mod')
            @($r.Result.loadOrder.removed | ForEach-Object { $_.folder }) | Should -Be @('beta_mod')
        }

        It 'reports a version bump once, not also as a change in place' {
            New-LockFile -Path $script:LeftF  -Mods @((New-Mod 'alpha_mod')) | Out-Null
            New-LockFile -Path $script:RightF -Mods @((New-Mod 'alpha_mod' @{ version = '1.1.0'; contentSha256 = ('b' * 64) })) | Out-Null

            $r = Invoke-Diff -Left $script:LeftF -Right $script:RightF

            $r.Code | Should -Be 1
            @($r.Result.versionChanged).Count | Should -Be 1
            $r.Result.versionChanged[0].from | Should -Be '1.0.0'
            $r.Result.versionChanged[0].to   | Should -Be '1.1.0'
            @($r.Result.contentChanged).Count | Should -Be 0
        }

        It 'compares versions component by component, so 1.0 and v1.0.0 are the same' {
            New-LockFile -Path $script:LeftF  -Mods @((New-Mod 'alpha_mod' @{ version = '1.0' })) | Out-Null
            New-LockFile -Path $script:RightF -Mods @((New-Mod 'alpha_mod' @{ version = 'v1.0.0' })) | Out-Null

            $r = Invoke-Diff -Left $script:LeftF -Right $script:RightF

            $r.Code | Should -Be 0
            @($r.Result.versionChanged).Count | Should -Be 0
        }

        It 'does not mistake 2.1.44 for 2.14.4' {
            New-LockFile -Path $script:LeftF  -Mods @((New-Mod 'alpha_mod' @{ version = '2.14.4' })) | Out-Null
            New-LockFile -Path $script:RightF -Mods @((New-Mod 'alpha_mod' @{ version = '2.1.44' })) | Out-Null

            (Invoke-Diff -Left $script:LeftF -Right $script:RightF).Result.versionChanged.Count | Should -Be 1
        }

        It 'reports a hash-only change as changed in place, with the version known' {
            New-LockFile -Path $script:LeftF  -Mods @((New-Mod 'alpha_mod')) | Out-Null
            New-LockFile -Path $script:RightF -Mods @((New-Mod 'alpha_mod' @{ contentSha256 = ('c' * 64) })) | Out-Null

            $r = Invoke-Diff -Left $script:LeftF -Right $script:RightF

            $r.Code | Should -Be 1
            @($r.Result.contentChanged).Count | Should -Be 1
            $r.Result.contentChanged[0].folder  | Should -Be 'alpha_mod'
            $r.Result.contentChanged[0].version | Should -Be '1.0.0'
            @($r.Result.versionChanged).Count | Should -Be 0
        }

        It 'reports a hash change as changed in place when the version is unknown on both sides' {
            New-LockFile -Path $script:LeftF  -Mods @((New-Mod 'alpha_mod' @{ version = $null })) | Out-Null
            New-LockFile -Path $script:RightF -Mods @((New-Mod 'alpha_mod' @{ version = $null; contentSha256 = ('c' * 64) })) | Out-Null

            $r = Invoke-Diff -Left $script:LeftF -Right $script:RightF

            @($r.Result.contentChanged).Count | Should -Be 1
            $r.Result.contentChanged[0].version | Should -BeNullOrEmpty
        }

        It 'treats a hash that differs only in letter case as the same hash' {
            New-LockFile -Path $script:LeftF  -Mods @((New-Mod 'alpha_mod' @{ contentSha256 = ('ab' * 32) })) | Out-Null
            New-LockFile -Path $script:RightF -Mods @((New-Mod 'alpha_mod' @{ contentSha256 = ('AB' * 32) })) | Out-Null

            (Invoke-Diff -Left $script:LeftF -Right $script:RightF).Code | Should -Be 0
        }

        It 'reports a version going from null to a value as now known, not as a change' {
            New-LockFile -Path $script:LeftF  -Mods @((New-Mod 'alpha_mod' @{ version = $null })) | Out-Null
            New-LockFile -Path $script:RightF -Mods @((New-Mod 'alpha_mod' @{ version = '3.2.1' })) | Out-Null

            $r = Invoke-Diff -Left $script:LeftF -Right $script:RightF

            $r.Code | Should -Be 0
            $r.Result.identical | Should -BeTrue
            @($r.Result.versionChanged).Count | Should -Be 0
            @($r.Result.nowKnown).Count | Should -Be 1
            $r.Result.nowKnown[0].folder | Should -Be 'alpha_mod'
            $r.Result.nowKnown[0].field  | Should -Be 'version'
            $r.Result.nowKnown[0].value  | Should -Be '3.2.1'
        }

        It 'reports a version going from a value to null as now unknown, never removed or changed' {
            New-LockFile -Path $script:LeftF  -Mods @((New-Mod 'alpha_mod')) | Out-Null
            New-LockFile -Path $script:RightF -Mods @((New-Mod 'alpha_mod' @{ version = $null })) | Out-Null

            $r = Invoke-Diff -Left $script:LeftF -Right $script:RightF

            $r.Code | Should -Be 0
            @($r.Result.removed).Count        | Should -Be 0
            @($r.Result.versionChanged).Count | Should -Be 0
            $r.Result.nowUnknown[0].field | Should -Be 'version'
            $r.Result.nowUnknown[0].was   | Should -Be '1.0.0'
        }

        It 'does not call content changed when either hash is null' {
            New-LockFile -Path $script:LeftF  -Mods @((New-Mod 'alpha_mod')) | Out-Null
            New-LockFile -Path $script:RightF -Mods @((New-Mod 'alpha_mod' @{ contentSha256 = $null })) | Out-Null

            $r = Invoke-Diff -Left $script:LeftF -Right $script:RightF

            $r.Code | Should -Be 0
            @($r.Result.contentChanged).Count | Should -Be 0
            $r.Result.nowUnknown[0].field | Should -Be 'contentSha256'
        }

        It 'reports a changed Nexus id, url and display name' {
            New-LockFile -Path $script:LeftF -Mods @((New-Mod 'alpha_mod')) | Out-Null
            New-LockFile -Path $script:RightF -Mods @((New-Mod 'alpha_mod' @{
                modId = 200; url = 'https://www.nexusmods.com/warhammer40kdarktide/mods/200'; name = 'Alpha Renamed' })) | Out-Null

            $r = Invoke-Diff -Left $script:LeftF -Right $script:RightF

            $r.Code | Should -Be 1
            $r.Result.modIdChanged[0].from | Should -Be '100'
            $r.Result.modIdChanged[0].to   | Should -Be '200'
            $r.Result.urlChanged[0].to     | Should -Match 'mods/200$'
            $r.Result.nameChanged[0].from  | Should -Be 'alpha_mod'
            $r.Result.nameChanged[0].to    | Should -Be 'Alpha Renamed'
        }

        It 'treats a Nexus id that becomes known as informational' {
            New-LockFile -Path $script:LeftF  -Mods @((New-Mod 'alpha_mod' @{ modId = $null; url = $null })) | Out-Null
            New-LockFile -Path $script:RightF -Mods @((New-Mod 'alpha_mod')) | Out-Null

            $r = Invoke-Diff -Left $script:LeftF -Right $script:RightF

            $r.Code | Should -Be 0
            @($r.Result.nowKnown | ForEach-Object { $_.field }) | Should -Be @('modId', 'url')
        }
    }

    Context 'load order' {

        BeforeEach {
            $script:Mods = @('a', 'b', 'c', 'd', 'e', 'f') | ForEach-Object { New-Mod $_ }
        }

        It 'does not report later entries as moved when one entry is inserted' {
            New-LockFile -Path $script:LeftF  -Mods $script:Mods -LoadOrder @('a', 'b', 'c', 'd', 'e') | Out-Null
            New-LockFile -Path $script:RightF -Mods $script:Mods -LoadOrder @('a', 'f', 'b', 'c', 'd', 'e') | Out-Null

            $r = Invoke-Diff -Left $script:LeftF -Right $script:RightF

            @($r.Result.loadOrder.moved).Count | Should -Be 0
            @($r.Result.loadOrder.added).Count | Should -Be 1
            $r.Result.loadOrder.added[0].folder   | Should -Be 'f'
            $r.Result.loadOrder.added[0].position | Should -Be 2
        }

        It 'does not report later entries as moved when one entry is removed' {
            New-LockFile -Path $script:LeftF  -Mods $script:Mods -LoadOrder @('a', 'b', 'c', 'd', 'e') | Out-Null
            New-LockFile -Path $script:RightF -Mods $script:Mods -LoadOrder @('b', 'c', 'd', 'e') | Out-Null

            $r = Invoke-Diff -Left $script:LeftF -Right $script:RightF

            @($r.Result.loadOrder.moved).Count | Should -Be 0
            @($r.Result.loadOrder.removed | ForEach-Object { $_.folder }) | Should -Be @('a')
        }

        It 'reports exactly the one entry that moved' {
            New-LockFile -Path $script:LeftF  -Mods $script:Mods -LoadOrder @('a', 'b', 'c', 'd', 'e', 'f') | Out-Null
            New-LockFile -Path $script:RightF -Mods $script:Mods -LoadOrder @('a', 'c', 'd', 'e', 'b', 'f') | Out-Null

            $r = Invoke-Diff -Left $script:LeftF -Right $script:RightF

            $r.Code | Should -Be 1
            @($r.Result.loadOrder.moved).Count | Should -Be 1
            $r.Result.loadOrder.moved[0].folder | Should -Be 'b'
            $r.Result.loadOrder.moved[0].from   | Should -Be 2
            $r.Result.loadOrder.moved[0].to     | Should -Be 5
            @($r.Result.loadOrder.added).Count   | Should -Be 0
            @($r.Result.loadOrder.removed).Count | Should -Be 0
        }

        It 'reports a full reversal as everything but one entry moved' {
            New-LockFile -Path $script:LeftF  -Mods $script:Mods -LoadOrder @('a', 'b', 'c', 'd') | Out-Null
            New-LockFile -Path $script:RightF -Mods $script:Mods -LoadOrder @('d', 'c', 'b', 'a') | Out-Null

            @((Invoke-Diff -Left $script:LeftF -Right $script:RightF).Result.loadOrder.moved).Count | Should -Be 3
        }
    }

    Context 'a loadout zip' {

        It 'reads the lockfile out of an export zip without extracting anything' {
            $mods = @((New-Mod 'alpha_mod'), (New-Mod 'beta_mod'))
            New-LockFile -Path $script:RightF -Mods $mods | Out-Null
            $zipDir = Join-Path $script:Root 'zips'
            [void][System.IO.Directory]::CreateDirectory($zipDir)
            $zip = New-TestZip -Path (Join-Path $zipDir 'darktide-loadout-20260101.zip') -Entries @{
                'darktide-modpack.lock.json' = (ConvertTo-LockJson -Mods $mods)
                'README.txt'                 = 'backup'
                'mod_load_order.txt'         = "alpha_mod`nbeta_mod"
            }
            $before = Get-TreeFingerprint -Path $zipDir

            $r = Invoke-Diff -Left $zip -Right $script:RightF

            $r.Code | Should -Be 0
            $r.Result.left.kind | Should -Be 'zip'
            $r.Result.left.modCount | Should -Be 2
            Get-TreeFingerprint -Path $zipDir | Should -Be $before
        }

        It 'sees a difference between the zip and a lockfile' {
            $zip = New-TestZip -Path (Join-Path $script:Root 'old.zip') -Entries @{
                'darktide-modpack.lock.json' = (ConvertTo-LockJson -Mods @((New-Mod 'alpha_mod')))
            }
            New-LockFile -Path $script:RightF -Mods @((New-Mod 'alpha_mod'), (New-Mod 'beta_mod')) | Out-Null

            $r = Invoke-Diff -Left $zip -Right $script:RightF

            $r.Code | Should -Be 1
            $r.Result.added[0].folder | Should -Be 'beta_mod'
        }

        It 'refuses a zip with no lockfile at its root, even if one sits in a subfolder' {
            $zip = New-TestZip -Path (Join-Path $script:Root 'nested.zip') -Entries @{
                'sub/darktide-modpack.lock.json' = (ConvertTo-LockJson -Mods @((New-Mod 'alpha_mod')))
            }
            New-LockFile -Path $script:RightF -Mods @((New-Mod 'alpha_mod')) | Out-Null

            { & $script:Differ -Left $zip -Right $script:RightF *>&1 | Out-Null } |
                Should -Throw -ExpectedMessage '*no darktide-modpack.lock.json at its root*'
        }

        It 'does not take a traversal entry name for the lockfile' {
            $zip = New-TestZip -Path (Join-Path $script:Root 'evil.zip') -Entries @{
                '../darktide-modpack.lock.json' = (ConvertTo-LockJson -Mods @((New-Mod 'alpha_mod')))
            }
            New-LockFile -Path $script:RightF -Mods @((New-Mod 'alpha_mod')) | Out-Null

            { & $script:Differ -Left $zip -Right $script:RightF *>&1 | Out-Null } |
                Should -Throw -ExpectedMessage '*no darktide-modpack.lock.json at its root*'
            Test-Path -LiteralPath (Join-Path (Split-Path -Parent $script:Root) 'darktide-modpack.lock.json') |
                Should -BeFalse
        }

        It 'refuses an oversized lockfile inside a zip' {
            $big = '{"schemaVersion":1,"mods":[],"pad":"' + ('x' * 600KB) + '"}'
            $zip = New-TestZip -Path (Join-Path $script:Root 'big.zip') -Entries @{ 'darktide-modpack.lock.json' = $big }
            New-LockFile -Path $script:RightF -Mods @() | Out-Null

            { & $script:Differ -Left $zip -Right $script:RightF *>&1 | Out-Null } |
                Should -Throw -ExpectedMessage '*larger than 512 KB*'
        }

        It 'refuses a file that is not a zip at all' {
            $fake = Join-Path $script:Root 'not-a.zip'
            Set-Content -LiteralPath $fake -Value 'plain text' -Encoding ASCII
            New-LockFile -Path $script:RightF -Mods @() | Out-Null

            { & $script:Differ -Left $fake -Right $script:RightF *>&1 | Out-Null } |
                Should -Throw -ExpectedMessage '*not a readable zip*'
        }
    }

    Context 'untrusted input' {

        BeforeEach {
            New-LockFile -Path $script:RightF -Mods @((New-Mod 'alpha_mod')) | Out-Null
            $script:Bad = Join-Path $script:Root 'bad.lock.json'
        }

        It 'refuses <case>' -ForEach @(
            @{ case = 'malformed JSON';           text = '{ "schemaVersion": 1, "mods": [ '; msg = '*not valid JSON*' }
            @{ case = 'an empty file';            text = '   ';                               msg = '*is empty*' }
            @{ case = 'a JSON array';             text = '[1, 2, 3]';                          msg = '*not a JSON object*' }
            @{ case = 'a missing schemaVersion';  text = '{ "mods": [] }';                     msg = '*no schemaVersion*' }
            @{ case = 'schemaVersion 2';          text = '{ "schemaVersion": 2, "mods": [] }'; msg = '*only 1 is understood*' }
            @{ case = 'schemaVersion as a string'; text = '{ "schemaVersion": "1", "mods": [] }'; msg = '*only 1 is understood*' }
            @{ case = 'a missing mods array';     text = '{ "schemaVersion": 1 }';             msg = '*no mods array*' }
            @{ case = 'mods that is not an array'; text = '{ "schemaVersion": 1, "mods": {} }'; msg = '*no mods array*' }
            @{ case = 'a mod with no folder';     text = '{ "schemaVersion": 1, "mods": [ { "name": "x" } ] }'; msg = '*no folder name*' }
            @{ case = 'a mod that is a string';   text = '{ "schemaVersion": 1, "mods": [ "alpha_mod" ] }';    msg = '*not an object*' }
            @{ case = 'a duplicate folder';       text = '{ "schemaVersion": 1, "mods": [ { "folder": "a" }, { "folder": "A" } ] }'; msg = '*twice*' }
            @{ case = 'a nested version object';  text = '{ "schemaVersion": 1, "mods": [ { "folder": "a", "version": { "x": 1 } } ] }'; msg = '*not a plain value*' }
            @{ case = 'a loadOrder of objects';   text = '{ "schemaVersion": 1, "mods": [], "loadOrder": [ { "a": 1 } ] }'; msg = '*loadOrder*' }
        ) {
            Set-Content -LiteralPath $script:Bad -Value $text -Encoding UTF8

            { & $script:Differ -Left $script:Bad -Right $script:RightF *>&1 | Out-Null } |
                Should -Throw -ExpectedMessage $msg
        }

        It 'refuses a lockfile over 512 KB before parsing it' {
            $pad = 'x' * 600KB
            Set-Content -LiteralPath $script:Bad -Value ('{"schemaVersion":1,"mods":[],"pad":"' + $pad + '"}') -Encoding ASCII

            { & $script:Differ -Left $script:Bad -Right $script:RightF *>&1 | Out-Null } |
                Should -Throw -ExpectedMessage '*larger than 512 KB*'
        }

        It 'refuses a folder, and a path that does not exist' {
            { & $script:Differ -Left $script:Root -Right $script:RightF *>&1 | Out-Null } |
                Should -Throw -ExpectedMessage '*is a folder*'
            { & $script:Differ -Left (Join-Path $script:Root 'absent.json') -Right $script:RightF *>&1 | Out-Null } |
                Should -Throw -ExpectedMessage '*does not exist*'
        }

        It 'keeps control characters in names out of the console' {
            $esc = [string][char]27
            New-LockFile -Path $script:Bad -Mods @((New-Mod 'alpha_mod'), (New-Mod "evil${esc}[31mmod")) | Out-Null

            $out = & $script:Differ -Left $script:Bad -Right $script:RightF *>&1 | Out-String

            $out | Should -Not -Match ([regex]::Escape($esc))
            $out | Should -Match 'evil\?\[31mmod'
        }

        It 'reads a lockfile from a folder whose name has brackets' {
            $dir = Join-Path $script:Root '[ab]'
            [void][System.IO.Directory]::CreateDirectory($dir)
            $f = Join-Path $dir 'x.lock.json'
            New-LockFile -Path $f -Mods @((New-Mod 'alpha_mod')) | Out-Null

            (Invoke-Diff -Left $f -Right $script:RightF).Code | Should -Be 0
        }
    }

    Context '-OutFile' {

        BeforeEach {
            New-LockFile -Path $script:LeftF  -Mods @((New-Mod 'alpha_mod')) | Out-Null
            New-LockFile -Path $script:RightF -Mods @((New-Mod 'alpha_mod' @{ version = '2.0' })) | Out-Null
        }

        It 'writes a markdown table for a .md name' {
            $md = Join-Path $script:Root 'diff.md'
            & $script:Differ -Left $script:LeftF -Right $script:RightF -OutFile $md *>&1 | Out-Null

            $text = Get-Content -LiteralPath $md -Raw -Encoding UTF8
            $text | Should -Match '\| Change \| Mod \| Left \| Right \|'
            $text | Should -Match '\| version \| alpha_mod \| 1\.0\.0 \| 2\.0 \|'
            $text | Should -Match 'Result: different'
        }

        It 'refuses to overwrite without -Force, and overwrites with it' {
            $json = Join-Path $script:Root 'diff.json'
            Set-Content -LiteralPath $json -Value 'keep me' -Encoding ASCII

            { & $script:Differ -Left $script:LeftF -Right $script:RightF -OutFile $json *>&1 | Out-Null } |
                Should -Throw -ExpectedMessage '*already exists*'
            Get-Content -LiteralPath $json -Raw | Should -Match 'keep me'

            & $script:Differ -Left $script:LeftF -Right $script:RightF -OutFile $json -Force *>&1 | Out-Null
            (Get-Content -LiteralPath $json -Raw -Encoding UTF8 | ConvertFrom-Json).identical | Should -BeFalse
        }

        It 'refuses an extension it does not write' {
            { & $script:Differ -Left $script:LeftF -Right $script:RightF -OutFile (Join-Path $script:Root 'd.txt') *>&1 | Out-Null } |
                Should -Throw -ExpectedMessage '*.json or .md*'
        }

        It 'refuses to write the result over one of its inputs, even with -Force' {
            $before = Get-Sha256 -Path $script:RightF
            $copy = Join-Path $script:Root 'right-copy.json'
            Copy-Item -LiteralPath $script:RightF -Destination $copy
            { & $script:Differ -Left $script:LeftF -Right $copy -OutFile $copy *>&1 | Out-Null } |
                Should -Throw -ExpectedMessage '*one of the loadouts being compared*'
            { & $script:Differ -Left $script:LeftF -Right $script:RightF -OutFile $script:RightF -Force *>&1 | Out-Null } |
                Should -Throw -ExpectedMessage '*one of the loadouts being compared*'
            Get-Sha256 -Path $script:RightF | Should -Be $before
        }

        It 'writes nothing at all without -OutFile' {
            $before = Get-TreeFingerprint -Path $script:Root
            & $script:Differ -Left $script:LeftF -Right $script:RightF *>&1 | Out-Null
            Get-TreeFingerprint -Path $script:Root | Should -Be $before
        }
    }

    Context "the 'current' side" {

        BeforeEach {
            $script:Staging = New-FakeStaging -Root $script:Root -Mods @('alpha_mod', 'beta_mod')
            $script:Map     = Join-Path $script:Root 'mods-map.json'
            '{}' | Set-Content -LiteralPath $script:Map -Encoding UTF8
            $script:Locked  = Join-Path $script:Root 'locked.lock.json'
            & $script:Locker -ModsRoot $script:Staging -OutFile $script:Locked -MapPath $script:Map *>&1 | Out-Null
            $script:Extra   = @{ StagingMods = $script:Staging; MapPath = $script:Map }
        }

        It 'matches a lockfile generated from the same staging, writes nothing, and leaves no temp file' {
            $repoBefore    = Get-Sha256 -Path $script:RepoLock
            $stagingBefore = Get-TreeFingerprint -Path $script:Staging
            $tempBefore    = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Filter 'dt-diff-*' -File -ErrorAction SilentlyContinue).Count

            $r = Invoke-Diff -Left $script:Locked -Right 'current' -Extra $script:Extra

            $r.Code | Should -Be 0
            $r.Result.right.kind | Should -Be 'current'
            Get-Sha256 -Path $script:RepoLock          | Should -Be $repoBefore
            Get-TreeFingerprint -Path $script:Staging  | Should -Be $stagingBefore
            @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Filter 'dt-diff-*' -File -ErrorAction SilentlyContinue).Count |
                Should -Be $tempBefore
        }

        It 'sees a mod changed in place in staging' {
            Add-Content -LiteralPath (Join-Path (Join-Path $script:Staging 'beta_mod') 'beta_mod.mod') -Value '-- edited' -Encoding UTF8

            $r = Invoke-Diff -Left $script:Locked -Right 'current' -Extra $script:Extra

            $r.Code | Should -Be 1
            @($r.Result.contentChanged | ForEach-Object { $_.folder }) | Should -Be @('beta_mod')
        }

        It 'sees a mod added to staging and to its load order' {
            $dir = Join-Path $script:Staging 'gamma_mod'
            [void][System.IO.Directory]::CreateDirectory($dir)
            Set-Content -LiteralPath (Join-Path $dir 'gamma_mod.mod') -Value 'return {}' -Encoding UTF8
            Add-Content -LiteralPath (Join-Path $script:Staging 'mod_load_order.txt') -Value 'gamma_mod' -Encoding UTF8

            $r = Invoke-Diff -Left $script:Locked -Right 'current' -Extra $script:Extra

            @($r.Result.added | ForEach-Object { $_.folder }) | Should -Be @('gamma_mod')
            @($r.Result.loadOrder.added | ForEach-Object { $_.folder }) | Should -Be @('gamma_mod')
            @($r.Result.loadOrder.moved).Count | Should -Be 0
        }

        It 'reads ModsRoot from config.json when -StagingMods is not given' {
            $game = New-FakeGameFolder -Root $script:Root
            $cfg  = New-TestConfig -Root $script:Root -StagingMods $script:Staging -GamePath $game

            $r = Invoke-Diff -Left $script:Locked -Right 'current' -Extra @{ ConfigPath = $cfg; MapPath = $script:Map }

            $r.Code | Should -Be 0
        }

        It 'says what to do when there is no config for current' {
            { & $script:Differ -Left $script:Locked -Right 'current' -ConfigPath (Join-Path $script:Root 'none.json') *>&1 | Out-Null } |
                Should -Throw -ExpectedMessage '*darktide.ps1 init*'
        }
    }

    Context 'a git revision' {

        BeforeEach {
            if (-not $script:HasGit) { return }
            # A throwaway repository holding a copy of the script, because 'git:' reads
            # the lockfile beside the script. The real repository is never touched.
            $script:Repo = Join-Path $script:Root 'repo'
            [void][System.IO.Directory]::CreateDirectory($script:Repo)
            Copy-Item -LiteralPath $script:Differ -Destination (Join-Path $script:Repo 'Compare-DarktideLoadout.ps1')
            $script:RepoDiffer = Join-Path $script:Repo 'Compare-DarktideLoadout.ps1'
            $script:RepoLockF  = Join-Path $script:Repo 'darktide-modpack.lock.json'

            Invoke-Git -Repo $script:Repo -GitArgs @('init', '-q')
            New-LockFile -Path $script:RepoLockF -Mods @((New-Mod 'alpha_mod')) | Out-Null
            Invoke-Git -Repo $script:Repo -GitArgs @('add', '-A')
            Invoke-Git -Repo $script:Repo -GitArgs @('commit', '-q', '-m', 'first')
            New-LockFile -Path $script:RepoLockF -Mods @((New-Mod 'alpha_mod' @{ version = '1.5.0' })) | Out-Null
            Invoke-Git -Repo $script:Repo -GitArgs @('commit', '-q', '-a', '-m', 'second')
        }

        It 'compares two committed revisions without touching the working tree' {
            if (-not $script:HasGit) { Set-ItResult -Skipped -Because 'git is not on PATH'; return }
            New-LockFile -Path $script:RepoLockF -Mods @((New-Mod 'alpha_mod' @{ version = '9.9.9' })) | Out-Null
            $before = Get-Sha256 -Path $script:RepoLockF
            $json = Join-Path $script:Root 'git.json'

            & $script:RepoDiffer -Left 'git:HEAD~1' -Right 'git:HEAD' -OutFile $json *>&1 | Out-Null

            $LASTEXITCODE | Should -Be 1
            $r = Get-Content -LiteralPath $json -Raw -Encoding UTF8 | ConvertFrom-Json
            $r.left.kind | Should -Be 'git'
            $r.versionChanged[0].from | Should -Be '1.0.0'
            $r.versionChanged[0].to   | Should -Be '1.5.0'
            Get-Sha256 -Path $script:RepoLockF | Should -Be $before
        }

        It 'says git could not read a revision that does not exist' {
            if (-not $script:HasGit) { Set-ItResult -Skipped -Because 'git is not on PATH'; return }
            { & $script:RepoDiffer -Left 'git:no-such-branch' -Right $script:RepoLockF *>&1 | Out-Null } |
                Should -Throw -ExpectedMessage '*git could not read*'
        }
    }

    Context 'without git' {

        It 'refuses a revision that would be read as an option, before git is ever run' {
            New-LockFile -Path $script:RightF -Mods @() | Out-Null
            { & $script:Differ -Left 'git:--output=x' -Right $script:RightF *>&1 | Out-Null } |
                Should -Throw -ExpectedMessage '*does not look like a git revision*'
            { & $script:Differ -Left 'git:' -Right $script:RightF *>&1 | Out-Null } |
                Should -Throw -ExpectedMessage '*give a revision*'
        }

        It 'says git is needed when it is not on PATH' {
            New-LockFile -Path $script:RightF -Mods @() | Out-Null
            $saved = $env:PATH
            try {
                $env:PATH = $script:Root
                { & $script:Differ -Left 'git:HEAD' -Right $script:RightF *>&1 | Out-Null } |
                    Should -Throw -ExpectedMessage '*git is not on PATH*'
            } finally {
                $env:PATH = $saved
            }
        }
    }
}

Describe "darktide.ps1 diff" {

    BeforeEach {
        $script:Root    = New-TestSandbox
        $script:Game    = New-FakeGameFolder -Root $script:Root
        $script:Staging = New-FakeStaging -Root $script:Root -Mods @('alpha_mod', 'beta_mod')
        $script:Config  = New-TestConfig -Root $script:Root -StagingMods $script:Staging -GamePath $script:Game
        $script:LeftF   = Join-Path $script:Root 'left.lock.json'
        $script:RightF  = Join-Path $script:Root 'right.lock.json'
    }

    AfterEach {
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'compares two lockfiles with no config.json at all, and passes the exit code on' {
        New-LockFile -Path $script:LeftF  -Mods @((New-Mod 'alpha_mod')) | Out-Null
        New-LockFile -Path $script:RightF -Mods @((New-Mod 'alpha_mod')) | Out-Null
        $noConfig = Join-Path $script:Root 'missing-config.json'

        & $script:Dispatcher diff -Left $script:LeftF -Right $script:RightF -ConfigPath $noConfig *>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0

        New-LockFile -Path $script:RightF -Mods @((New-Mod 'alpha_mod'), (New-Mod 'beta_mod')) | Out-Null
        & $script:Dispatcher diff -Left $script:LeftF -Right $script:RightF -ConfigPath $noConfig *>&1 | Out-Null
        $LASTEXITCODE | Should -Be 1
    }

    It 'passes -OutFile and -Force through' {
        New-LockFile -Path $script:LeftF  -Mods @((New-Mod 'alpha_mod')) | Out-Null
        New-LockFile -Path $script:RightF -Mods @((New-Mod 'alpha_mod')) | Out-Null
        $json = Join-Path $script:Root 'out.json'
        Set-Content -LiteralPath $json -Value 'old' -Encoding ASCII

        & $script:Dispatcher diff -Left $script:LeftF -Right $script:RightF -OutFile $json -Force -ConfigPath $script:Config *>&1 | Out-Null

        (Get-Content -LiteralPath $json -Raw -Encoding UTF8 | ConvertFrom-Json).identical | Should -BeTrue
    }

    It 'by default compares the repository lockfile with staging, and writes neither' {
        $repoBefore    = Get-Sha256 -Path $script:RepoLock
        $stagingBefore = Get-TreeFingerprint -Path $script:Staging
        $out = Join-Path $script:Root 'default.json'

        & $script:Dispatcher diff -ConfigPath $script:Config -OutFile $out *>&1 | Out-Null

        # The fake staging holds none of the real loadout, so this is a difference.
        $LASTEXITCODE | Should -Be 1
        $r = Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json
        $r.left.kind  | Should -Be 'lockfile'
        $r.right.kind | Should -Be 'current'
        @($r.added | ForEach-Object { $_.folder }) | Should -Contain 'alpha_mod'
        Get-Sha256 -Path $script:RepoLock         | Should -Be $repoBefore
        Get-TreeFingerprint -Path $script:Staging | Should -Be $stagingBefore
    }

    It 'asks for init when the default needs staging and there is no config' {
        { & $script:Dispatcher diff -ConfigPath (Join-Path $script:Root 'missing-config.json') *>&1 | Out-Null } |
            Should -Throw -ExpectedMessage '*darktide.ps1 init*'
    }
}
