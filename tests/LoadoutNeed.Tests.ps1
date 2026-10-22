<#
    Tests for Get-LoadoutGap.ps1 (the 'need' verb) and for 'lock -OutFile'.

    The lockfile here comes from someone else, so most of this file is about what
    a hostile one must not be able to do: name a folder outside staging, smuggle
    in a non-Nexus link, or put escape sequences on the terminal. The rest checks
    the four rows come out right, that nothing is written but the -OutFile, and
    that nothing reaches for the network.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:Dispatcher = Join-Path $script:RepoRoot 'darktide.ps1'
    $script:Gapper     = Join-Path $script:RepoRoot 'Get-LoadoutGap.ps1'
    $script:Locker     = Join-Path $script:RepoRoot 'New-ModpackLock.ps1'
    $script:RepoLock   = Join-Path $script:RepoRoot 'darktide-modpack.lock.json'

    # 'lock' through the real dispatcher defaults to the repository lockfile. If a
    # regression ever ignores -OutFile, the assertion fails - and this puts the
    # file back so the failure does not also leave the checkout dirty.
    $script:RepoLockBytes = [System.IO.File]::ReadAllBytes($script:RepoLock)

    $script:Nexus = 'https://www.nexusmods.com/warhammer40kdarktide/mods'

    function New-FriendLock {
        <# Writes a lockfile from a list of mod hashtables and returns its path. #>
        param(
            [Parameter(Mandatory)][string] $Root,
            [object[]] $Mods = @(),
            [string[]] $LoadOrder = @(),
            [string]   $Name = 'friend.lock.json',
            [object]   $SchemaVersion = 1
        )
        $lock = [ordered]@{
            schemaVersion = $SchemaVersion
            name          = "Friend's loadout"
            game          = 'warhammer40kdarktide'
            generatedBy   = 'New-ModpackLock.ps1'
            modCount      = @($Mods).Count
            loadOrder     = $LoadOrder
            mods          = @($Mods)
        }
        $p = Join-Path $Root $Name
        $lock | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $p -Encoding UTF8
        return $p
    }

    function New-Mod {
        param([string] $Folder, $ModId = $null, $Version = $null, $Url = $null, $Hash = $null, $Name = $null)
        $u = $Url
        if ($null -eq $u -and $ModId) { $u = "$script:Nexus/$ModId" }
        return [ordered]@{
            folder        = $Folder
            name          = $(if ($Name) { $Name } else { $Folder })
            modId         = $ModId
            version       = $Version
            versionSource = 'info.json'
            url           = $u
            contentSha256 = $Hash
        }
    }

    function Invoke-Gap {
        <# Runs the script, returns the parsed -OutFile json and the exit code. #>
        param([string] $LockPath, [string] $Staging, [string] $Out)
        & $script:Gapper -Path $LockPath -ModsRoot $Staging -OutFile $Out *>&1 | Out-Null
        $code = if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { 0 }
        $data = Get-Content -LiteralPath $Out -Raw -Encoding UTF8 | ConvertFrom-Json
        return @{ Data = $data; Code = $code }
    }

    function Get-Row {
        param($Data, [string] $Folder)
        return @($Data.mods | Where-Object { $_.folder -eq $Folder })
    }
}

AfterAll {
    $now = [System.IO.File]::ReadAllBytes($script:RepoLock)
    if ([Convert]::ToBase64String($now) -ne [Convert]::ToBase64String($script:RepoLockBytes)) {
        [System.IO.File]::WriteAllBytes($script:RepoLock, $script:RepoLockBytes)
    }
}

Describe 'Get-LoadoutGap (need)' {

    BeforeEach {
        $script:Root    = New-TestSandbox
        # Yours: dmf, alpha_mod, beta_mod, mine_only - each info.json at 1.0.0.
        $script:Staging = New-FakeStaging -Root $script:Root -Mods @('alpha_mod', 'beta_mod', 'mine_only')
        $script:Out     = Join-Path $script:Root 'need.json'
        $global:LASTEXITCODE = 0
    }

    AfterEach {
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'the four rows' {

        BeforeEach {
            $script:Friend = New-FriendLock -Root $script:Root -LoadOrder @('alpha_mod', 'gamma_mod', 'beta_mod', 'delta_mod', 'epsilon_mod') -Mods @(
                (New-Mod -Folder 'dmf'         -ModId 8   -Version '1.0.0'),
                (New-Mod -Folder 'alpha_mod'   -ModId 447 -Version '1.0.0'),
                (New-Mod -Folder 'beta_mod'    -ModId 448 -Version '2.0.0'),
                (New-Mod -Folder 'gamma_mod'   -ModId 500 -Version '3.1'),
                (New-Mod -Folder 'delta_mod'   -ModId $null),
                # An id but no url: the link is built from the id.
                [ordered]@{ folder = 'epsilon_mod'; name = 'Epsilon'; modId = 501; version = $null }
            )
        }

        It 'lists exactly the mods you lack, with the link from their lockfile' {
            $r = Invoke-Gap -LockPath $script:Friend -Staging $script:Staging -Out $script:Out

            $missing = @($r.Data.mods | Where-Object { $_.status -eq 'MISSING' } | ForEach-Object { $_.folder } | Sort-Object)
            $missing -join ',' | Should -Be 'delta_mod,epsilon_mod,gamma_mod'

            (Get-Row $r.Data 'gamma_mod')[0].url   | Should -Be "$script:Nexus/500"
            (Get-Row $r.Data 'epsilon_mod')[0].url | Should -Be "$script:Nexus/501"
            $r.Data.counts.missing | Should -Be 3
            $r.Code | Should -Be 0
        }

        It "says 'no Nexus id in their lockfile' when there is no id to link" {
            $r = Invoke-Gap -LockPath $script:Friend -Staging $script:Staging -Out $script:Out
            $delta = (Get-Row $r.Data 'delta_mod')[0]

            $delta.status | Should -Be 'MISSING'
            $delta.url    | Should -BeNullOrEmpty
            $delta.detail | Should -Be 'no Nexus id in their lockfile'

            $out = & $script:Gapper -Path $script:Friend -ModsRoot $script:Staging *>&1 | Out-String
            $out | Should -Match 'delta_mod\s+no Nexus id in their lockfile'
        }

        It 'marks a version difference DIFFERENT and a matching one PRESENT' {
            $r = Invoke-Gap -LockPath $script:Friend -Staging $script:Staging -Out $script:Out

            $beta = (Get-Row $r.Data 'beta_mod')[0]
            $beta.status       | Should -Be 'DIFFERENT'
            $beta.yourVersion  | Should -Be '1.0.0'
            $beta.theirVersion | Should -Be '2.0.0'
            $beta.detail       | Should -Match 'yours 1\.0\.0, theirs 2\.0\.0'

            (Get-Row $r.Data 'alpha_mod')[0].status | Should -Be 'PRESENT'
            (Get-Row $r.Data 'dmf')[0].status       | Should -Be 'PRESENT'
        }

        It 'lists your own extra mods as EXTRA and ignores base' {
            $r = Invoke-Gap -LockPath $script:Friend -Staging $script:Staging -Out $script:Out

            @($r.Data.mods | Where-Object { $_.status -eq 'EXTRA' } | ForEach-Object { $_.folder }) -join ',' |
                Should -Be 'mine_only'
            Get-Row $r.Data 'base' | Should -BeNullOrEmpty
        }

        It 'shows their load order with your missing mods marked' {
            $r = Invoke-Gap -LockPath $script:Friend -Staging $script:Staging -Out $script:Out

            $order = @($r.Data.loadOrder | ForEach-Object { "$($_.position):$($_.folder):$($_.status)" })
            $order -join ' ' | Should -Be '1:alpha_mod:PRESENT 2:gamma_mod:MISSING 3:beta_mod:DIFFERENT 4:delta_mod:MISSING 5:epsilon_mod:MISSING'

            $out = & $script:Gapper -Path $script:Friend -ModsRoot $script:Staging *>&1 | Out-String
            $out | Should -Match '2\. gamma_mod\s+<- MISSING'
        }

        It 'matches folder names case-insensitively, as Windows does' {
            $f = New-FriendLock -Root $script:Root -Name 'case.lock.json' -Mods @((New-Mod -Folder 'ALPHA_MOD' -ModId 447 -Version '1.0.0'))
            $r = Invoke-Gap -LockPath $f -Staging $script:Staging -Out $script:Out

            (Get-Row $r.Data 'ALPHA_MOD')[0].status | Should -Be 'PRESENT'
        }
    }

    Context 'DIFFERENT versus unknown' {

        It 'treats a missing version on either side as unknown, not different' {
            $f = New-FriendLock -Root $script:Root -Mods @(
                (New-Mod -Folder 'alpha_mod' -ModId 447 -Version $null),
                (New-Mod -Folder 'beta_mod'  -ModId 448 -Version '9.9.9')
            )
            # Your beta_mod has no version either.
            Remove-Item -LiteralPath (Join-Path $script:Staging 'beta_mod/info.json') -Force

            $r = Invoke-Gap -LockPath $f -Staging $script:Staging -Out $script:Out

            (Get-Row $r.Data 'alpha_mod')[0].status | Should -Be 'PRESENT'
            (Get-Row $r.Data 'alpha_mod')[0].detail | Should -Match 'nothing to compare'
            (Get-Row $r.Data 'beta_mod')[0].status  | Should -Be 'PRESENT'
            $r.Data.counts.different | Should -Be 0
        }

        It 'reads a lockfile made by New-ModpackLock from the same staging as all PRESENT' {
            # Proves the content hash here is the same algorithm as the lock generator's.
            $f = Join-Path $script:Root 'same.lock.json'
            & $script:Locker -ModsRoot $script:Staging -OutFile $f -MapPath (Join-Path $script:Root 'none.json') *>&1 | Out-Null

            $r = Invoke-Gap -LockPath $f -Staging $script:Staging -Out $script:Out

            $r.Data.counts.present   | Should -Be 4
            $r.Data.counts.different | Should -Be 0
            $r.Data.counts.missing   | Should -Be 0
            @($r.Data.mods | Where-Object { $_.detail -match 'content' }) | Should -BeNullOrEmpty
        }

        It 'marks same version but changed content DIFFERENT' {
            $f = Join-Path $script:Root 'same.lock.json'
            & $script:Locker -ModsRoot $script:Staging -OutFile $f -MapPath (Join-Path $script:Root 'none.json') *>&1 | Out-Null
            Set-Content -LiteralPath (Join-Path $script:Staging 'alpha_mod/extra.lua') -Value '-- local edit' -Encoding UTF8

            $r = Invoke-Gap -LockPath $f -Staging $script:Staging -Out $script:Out
            $alpha = (Get-Row $r.Data 'alpha_mod')[0]

            $alpha.status | Should -Be 'DIFFERENT'
            $alpha.detail | Should -Be 'content differs'
        }

        It 'with -NoHash compares versions only' {
            $f = Join-Path $script:Root 'same.lock.json'
            & $script:Locker -ModsRoot $script:Staging -OutFile $f -MapPath (Join-Path $script:Root 'none.json') *>&1 | Out-Null
            Set-Content -LiteralPath (Join-Path $script:Staging 'alpha_mod/extra.lua') -Value '-- local edit' -Encoding UTF8

            & $script:Gapper -Path $f -ModsRoot $script:Staging -OutFile $script:Out -NoHash *>&1 | Out-Null
            $data = Get-Content -LiteralPath $script:Out -Raw -Encoding UTF8 | ConvertFrom-Json

            (Get-Row $data 'alpha_mod')[0].status | Should -Be 'PRESENT'
        }
    }

    Context 'an untrusted lockfile' {

        It 'drops folder names that could reach outside staging, and reports them' {
            $f = New-FriendLock -Root $script:Root -LoadOrder @('..', 'alpha_mod') -Mods @(
                (New-Mod -Folder '..\evil' -ModId 1),
                (New-Mod -Folder '../evil' -ModId 2),
                (New-Mod -Folder 'a/b'     -ModId 3),
                (New-Mod -Folder 'a\b'     -ModId 4),
                (New-Mod -Folder 'x*'      -ModId 5),
                (New-Mod -Folder 'y?'      -ModId 6),
                (New-Mod -Folder 'C:'      -ModId 7),
                (New-Mod -Folder 'CON'     -ModId 8),
                (New-Mod -Folder "bad$([char]27)name" -ModId 9),
                (New-Mod -Folder ''        -ModId 10),
                (New-Mod -Folder 'alpha_mod' -ModId 447 -Version '1.0.0')
            )
            $before = Get-TreeFingerprint -Path $script:Root
            $parentBefore = @(Get-ChildItem -LiteralPath (Split-Path -Parent $script:Root) -Filter 'evil*' -ErrorAction SilentlyContinue).Count

            $r = Invoke-Gap -LockPath $f -Staging $script:Staging -Out $script:Out

            @($r.Data.mods | Where-Object { $_.status -ne 'EXTRA' } | ForEach-Object { $_.folder }) -join ',' |
                Should -Be 'alpha_mod'
            @($r.Data.dropped | Where-Object { $_.what -eq 'folder' }).Count | Should -Be 10
            @($r.Data.dropped | Where-Object { $_.what -eq 'load order entry' }).Count | Should -Be 1
            $r.Data.counts.dropped | Should -Be 11
            $r.Code | Should -Be 1

            # Nothing appeared next to the sandbox, and inside it only the -OutFile.
            @(Get-ChildItem -LiteralPath (Split-Path -Parent $script:Root) -Filter 'evil*' -ErrorAction SilentlyContinue).Count |
                Should -Be $parentBefore
            Remove-Item -LiteralPath $script:Out -Force
            Get-TreeFingerprint -Path $script:Root | Should -Be $before
        }

        It 'drops a url that is not a plain Nexus link, keeping a link built from a numeric id' {
            $f = New-FriendLock -Root $script:Root -Mods @(
                (New-Mod -Folder 'm1' -ModId 11  -Url 'https://evil.example.com/mods/11'),
                (New-Mod -Folder 'm2' -ModId $null -Url 'https://www.nexusmods.com.evil.example/x'),
                (New-Mod -Folder 'm3' -ModId $null -Url 'http://www.nexusmods.com/warhammer40kdarktide/mods/3'),
                (New-Mod -Folder 'm4' -ModId $null -Url 'https://www.nexusmods.com/x) [click](https://evil.example'),
                (New-Mod -Folder 'm5' -ModId $null -Url 'javascript:alert(1)')
            )

            $r = Invoke-Gap -LockPath $f -Staging $script:Staging -Out $script:Out

            (Get-Row $r.Data 'm1')[0].url | Should -Be "$script:Nexus/11"
            foreach ($m in 'm2', 'm3', 'm4', 'm5') {
                (Get-Row $r.Data $m)[0].url    | Should -BeNullOrEmpty
                (Get-Row $r.Data $m)[0].detail | Should -Be 'no Nexus id in their lockfile'
            }
            @($r.Data.dropped | Where-Object { $_.what -like 'url of *' }).Count | Should -Be 5
            $r.Code | Should -Be 1
        }

        It 'drops a modId that is not a positive whole number' {
            $f = New-FriendLock -Root $script:Root -Mods @(
                [ordered]@{ folder = 'm1'; modId = '12; rm -rf'; url = $null },
                [ordered]@{ folder = 'm2'; modId = -4;           url = $null },
                [ordered]@{ folder = 'm3'; modId = '77';         url = $null }
            )

            $r = Invoke-Gap -LockPath $f -Staging $script:Staging -Out $script:Out

            (Get-Row $r.Data 'm1')[0].url | Should -BeNullOrEmpty
            (Get-Row $r.Data 'm2')[0].url | Should -BeNullOrEmpty
            (Get-Row $r.Data 'm3')[0].url | Should -Be "$script:Nexus/77"
            @($r.Data.dropped | Where-Object { $_.what -like 'modId of *' }).Count | Should -Be 2
        }

        It 'refuses a file over 512 KB without parsing it' {
            $f = Join-Path $script:Root 'big.lock.json'
            $pad = 'x' * (520 * 1024)
            "{""schemaVersion"":1,""note"":""$pad"",""mods"":[]}" | Set-Content -LiteralPath $f -Encoding ASCII

            { & $script:Gapper -Path $f -ModsRoot $script:Staging *>&1 | Out-Null } | Should -Throw '*512*'
        }

        It 'refuses a schemaVersion other than 1' {
            $f = New-FriendLock -Root $script:Root -SchemaVersion 2 -Mods @((New-Mod -Folder 'alpha_mod'))
            { & $script:Gapper -Path $f -ModsRoot $script:Staging *>&1 | Out-Null } | Should -Throw '*schemaVersion*'
        }

        It 'refuses a file that is not JSON, or has no mods array' {
            $bad = Join-Path $script:Root 'bad.lock.json'
            'PK this is not json' | Set-Content -LiteralPath $bad -Encoding ASCII
            { & $script:Gapper -Path $bad -ModsRoot $script:Staging *>&1 | Out-Null } | Should -Throw '*not valid JSON*'

            '{"schemaVersion":1,"mods":"alpha_mod"}' | Set-Content -LiteralPath $bad -Encoding ASCII
            { & $script:Gapper -Path $bad -ModsRoot $script:Staging *>&1 | Out-Null } | Should -Throw "*no 'mods' array*"

            '[1,2,3]' | Set-Content -LiteralPath $bad -Encoding ASCII
            { & $script:Gapper -Path $bad -ModsRoot $script:Staging *>&1 | Out-Null } | Should -Throw '*not a lockfile*'
        }

        It 'replaces control characters before printing, so no escape sequence reaches the terminal' {
            $esc = [char]27
            $f = New-FriendLock -Root $script:Root -Mods @(
                (New-Mod -Folder 'gamma_mod' -ModId 500 -Version "1.0$esc[2J" -Name "Gamma$esc]0;pwned$([char]7)$([char]0x9B)31m"),
                (New-Mod -Folder 'delta_mod' -ModId 501 -Name "evil$([char]0x202E)txt.exe")
            )
            $out = & $script:Gapper -Path $f -ModsRoot $script:Staging -OutFile (Join-Path $script:Root 'n.md') *>&1 | Out-String

            $out | Should -Not -Match '[\u0000-\u0009\u000B\u000C\u000E-\u001F\u007F-\u009F]'
            $md = Get-Content -LiteralPath (Join-Path $script:Root 'n.md') -Raw -Encoding UTF8
            $md | Should -Not -Match '[\u0000-\u0009\u000B\u000C\u000E-\u001F\u007F-\u009F]'
            $md | Should -Match 'Gamma\?\\\]0;pwned\?\?31m'
            $out | Should -Not -Match '\u202E'
            $md  | Should -Match 'evil\?txt\.exe'
        }

        It 'never calls the network' {
            Mock Invoke-RestMethod { throw 'network call' }
            Mock Invoke-WebRequest { throw 'network call' }
            Mock Start-Process     { throw 'process start' }

            # The mocks do reach a script run this way; prove it, so the zero
            # counts below mean something.
            $probe = Join-Path $script:Root 'probe.ps1'
            'try { Invoke-WebRequest -Uri "https://example.invalid" } catch { }' |
                Set-Content -LiteralPath $probe -Encoding ASCII
            & $probe
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly

            $f = New-FriendLock -Root $script:Root -Mods @((New-Mod -Folder 'gamma_mod' -ModId 500))
            & $script:Gapper -Path $f -ModsRoot $script:Staging -OutFile (Join-Path $script:Root 'n.md') *>&1 | Out-Null

            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly
            Should -Invoke Start-Process     -Times 0 -Exactly
        }
    }

    Context '-OutFile' {

        BeforeEach {
            $script:Friend = New-FriendLock -Root $script:Root -LoadOrder @('alpha_mod', 'gamma_mod', 'delta_mod') -Mods @(
                (New-Mod -Folder 'alpha_mod' -ModId 447 -Version '1.0.0'),
                (New-Mod -Folder 'gamma_mod' -ModId 500 -Version '3.1' -Name 'Gamma [beta] *mod*'),
                (New-Mod -Folder 'delta_mod' -ModId $null)
            )
        }

        It 'writes a markdown checklist with a link per missing mod' {
            $md = Join-Path $script:Root 'need.md'
            & $script:Gapper -Path $script:Friend -ModsRoot $script:Staging -OutFile $md *>&1 | Out-Null
            $text = Get-Content -LiteralPath $md -Raw -Encoding UTF8

            $text | Should -Match ([regex]::Escape("- [ ] **Gamma \[beta\] \*mod\*** (gamma\_mod) - theirs 3.1 - [Nexus page]($script:Nexus/500)"))
            $text | Should -Match ([regex]::Escape('- [ ] **delta\_mod** - _no Nexus id in their lockfile_'))
            $text | Should -Match '2\. gamma\\_mod - \*\*missing\*\*'
            $text | Should -Match 'contains no mod files'
        }

        It 'writes json with every row' {
            & $script:Gapper -Path $script:Friend -ModsRoot $script:Staging -OutFile $script:Out *>&1 | Out-Null
            $data = Get-Content -LiteralPath $script:Out -Raw -Encoding UTF8 | ConvertFrom-Json

            $data.generatedBy | Should -Be 'Get-LoadoutGap.ps1'
            @($data.mods).Count | Should -Be 6   # alpha, gamma, delta, plus dmf, beta_mod, mine_only as extra
            $data.counts.missing | Should -Be 2
            $data.counts.extra   | Should -Be 3
        }

        It 'refuses to replace an existing file without -Force' {
            Set-Content -LiteralPath $script:Out -Value 'keep me' -Encoding ASCII
            { & $script:Gapper -Path $script:Friend -ModsRoot $script:Staging -OutFile $script:Out *>&1 | Out-Null } |
                Should -Throw '*-Force*'
            (Get-Content -LiteralPath $script:Out -Raw).Trim() | Should -Be 'keep me'

            & $script:Gapper -Path $script:Friend -ModsRoot $script:Staging -OutFile $script:Out -Force *>&1 | Out-Null
            (Get-Content -LiteralPath $script:Out -Raw -Encoding UTF8 | ConvertFrom-Json).generatedBy | Should -Be 'Get-LoadoutGap.ps1'
        }

        It 'refuses an extension it does not know, the input file, and a path inside staging' {
            { & $script:Gapper -Path $script:Friend -ModsRoot $script:Staging -OutFile (Join-Path $script:Root 'n.txt') *>&1 | Out-Null } |
                Should -Throw '*.md*'
            { & $script:Gapper -Path $script:Friend -ModsRoot $script:Staging -OutFile $script:Friend -Force *>&1 | Out-Null } |
                Should -Throw '*Refusing*'
            { & $script:Gapper -Path $script:Friend -ModsRoot $script:Staging -OutFile (Join-Path $script:Staging 'n.md') *>&1 | Out-Null } |
                Should -Throw '*staging*'
        }
    }

    Context 'writes nothing it was not asked to' {

        It 'leaves staging, their lockfile and the repository lockfile unchanged' {
            $f = New-FriendLock -Root $script:Root -LoadOrder @('alpha_mod', 'gamma_mod') -Mods @(
                (New-Mod -Folder 'alpha_mod' -ModId 447 -Version '1.0.0'),
                (New-Mod -Folder 'gamma_mod' -ModId 500)
            )
            $staging  = Get-TreeFingerprint -Path $script:Staging
            $sandbox  = Get-TreeFingerprint -Path $script:Root
            $theirs   = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash
            $repoLock = (Get-FileHash -LiteralPath $script:RepoLock -Algorithm SHA256).Hash

            & $script:Gapper -Path $f -ModsRoot $script:Staging *>&1 | Out-Null

            Get-TreeFingerprint -Path $script:Staging | Should -Be $staging
            Get-TreeFingerprint -Path $script:Root    | Should -Be $sandbox
            (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash | Should -Be $theirs
            (Get-FileHash -LiteralPath $script:RepoLock -Algorithm SHA256).Hash | Should -Be $repoLock
        }
    }
}

Describe 'darktide.ps1 need and lock -OutFile' {

    BeforeEach {
        $script:Root    = New-TestSandbox
        $script:Game    = New-FakeGameFolder -Root $script:Root
        $script:Staging = New-FakeStaging -Root $script:Root -Mods @('alpha_mod', 'beta_mod')
        $script:Config  = New-TestConfig -Root $script:Root -StagingMods $script:Staging -GamePath $script:Game
    }

    AfterEach {
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'need reads ModsRoot from the config and writes only the -OutFile' {
        $f = New-FriendLock -Root $script:Root -Mods @(
            (New-Mod -Folder 'alpha_mod' -ModId 447 -Version '1.0.0'),
            (New-Mod -Folder 'gamma_mod' -ModId 500)
        )
        $out = Join-Path $script:Root 'need.json'
        $staging = Get-TreeFingerprint -Path $script:Staging

        & $script:Dispatcher need -ConfigPath $script:Config -Path $f -OutFile $out *>&1 | Out-Null

        $data = Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json
        @($data.mods | Where-Object { $_.status -eq 'MISSING' } | ForEach-Object { $_.folder }) -join ',' | Should -Be 'gamma_mod'
        Get-TreeFingerprint -Path $script:Staging | Should -Be $staging
    }

    It 'need without -Path says what it wants' {
        { & $script:Dispatcher need -ConfigPath $script:Config *>&1 | Out-Null } | Should -Throw '*-Path*'
    }

    It 'need exits 1 when anything was dropped from their lockfile' {
        $f = New-FriendLock -Root $script:Root -Mods @(
            (New-Mod -Folder '..\evil'   -ModId 1),
            (New-Mod -Folder 'alpha_mod' -ModId 447 -Version '1.0.0')
        )

        $global:LASTEXITCODE = 0
        & $script:Dispatcher need -ConfigPath $script:Config -Path $f *>&1 | Out-Null
        $LASTEXITCODE | Should -Be 1

        # In-process, the child's exit code leaks through even when the dispatcher
        # drops it. Only a separate process shows what a caller of
        # 'darktide.ps1 need' actually gets back. Same engine as this run.
        $engine = (Get-Process -Id $PID).Path
        & $engine -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:Dispatcher `
            need -ConfigPath $script:Config -Path $f | Out-Null
        $LASTEXITCODE | Should -Be 1
    }

    It 'need exits 0 on a clean run even when an earlier command left a failure code behind' {
        $f = New-FriendLock -Root $script:Root -Mods @((New-Mod -Folder 'alpha_mod' -ModId 447 -Version '1.0.0'))

        $global:LASTEXITCODE = 7
        & $script:Dispatcher need -ConfigPath $script:Config -Path $f *>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    It 'lock -OutFile writes the given path and leaves the repository lockfile byte-identical' {
        $share = Join-Path $script:Root 'my-loadout.lock.json'
        $repoBefore = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($script:RepoLock))

        & $script:Dispatcher lock -ConfigPath $script:Config -OutFile $share *>&1 | Out-Null

        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($script:RepoLock)) | Should -Be $repoBefore
        $lock = Get-Content -LiteralPath $share -Raw -Encoding UTF8 | ConvertFrom-Json
        $lock.schemaVersion | Should -Be 1
        @($lock.mods | ForEach-Object { $_.folder }) -join ',' | Should -Be 'alpha_mod,beta_mod,dmf'
    }

    It 'lock -OutFile refuses to replace an existing file without -Force' {
        $share = Join-Path $script:Root 'my-loadout.lock.json'
        Set-Content -LiteralPath $share -Value 'keep me' -Encoding ASCII
        $repoBefore = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($script:RepoLock))

        { & $script:Dispatcher lock -ConfigPath $script:Config -OutFile $share *>&1 | Out-Null } | Should -Throw '*-Force*'
        (Get-Content -LiteralPath $share -Raw).Trim() | Should -Be 'keep me'

        & $script:Dispatcher lock -ConfigPath $script:Config -OutFile $share -Force *>&1 | Out-Null
        (Get-Content -LiteralPath $share -Raw -Encoding UTF8 | ConvertFrom-Json).schemaVersion | Should -Be 1
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($script:RepoLock)) | Should -Be $repoBefore
    }

    It 'a lockfile from lock -OutFile, read back by need, shows nothing missing' {
        $share = Join-Path $script:Root 'my-loadout.lock.json'
        $out   = Join-Path $script:Root 'need.json'

        & $script:Dispatcher lock -ConfigPath $script:Config -OutFile $share *>&1 | Out-Null
        & $script:Dispatcher need -ConfigPath $script:Config -Path $share -OutFile $out *>&1 | Out-Null

        $data = Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json
        $data.counts.missing   | Should -Be 0
        $data.counts.different | Should -Be 0
        $data.counts.present   | Should -Be 3
    }
}
