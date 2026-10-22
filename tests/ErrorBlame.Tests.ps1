<#
    Tests for Get-DarktideErrors.ps1 and the 'errors' verb.

    Every log here is synthetic and written into a sandbox: some engine noise, then
    errors that name alpha_mod by a path fragment, beta_mod by a DMF tag carrying its
    display name, and a mod whose folder name has brackets in it. Nothing reads the
    real %APPDATA%; the one test that exercises the default location points APPDATA
    at the sandbox first.

    The script is read-only, so the property that matters most after the ranking is
    that it writes nothing except the -OutFile it was asked for.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:Dispatcher = Join-Path $script:RepoRoot 'darktide.ps1'
    $script:Blamer     = Join-Path $script:RepoRoot 'Get-DarktideErrors.ps1'

    function New-ConsoleLog {
        <# A log file with a chosen last-write time. No lines means an empty file. #>
        param(
            [Parameter(Mandatory)][string] $Dir,
            [Parameter(Mandatory)][string] $Name,
            [string[]] $Lines = @(),
            [datetime] $When = (Get-Date)
        )
        $p = Join-Path $Dir $Name
        if ($Lines.Count -eq 0) {
            [System.IO.File]::WriteAllText($p, '')
        } else {
            Set-Content -LiteralPath $p -Value $Lines -Encoding UTF8
        }
        (Get-Item -LiteralPath $p).LastWriteTime = $When
        return $p
    }

    function Invoke-Blame {
        <# Runs the script against the sandbox and returns everything it printed. #>
        param([hashtable] $Extra = @{})
        $params = @{
            ConfigPath = $script:Config
            LockPath   = $script:Lock
            LogDir     = $script:Logs
        }
        foreach ($k in $Extra.Keys) { $params[$k] = $Extra[$k] }
        return (& $script:Blamer @params *>&1 | Out-String)
    }

    function Read-JsonReport {
        param([Parameter(Mandatory)][string] $Path)
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    }

    # Engine noise first, so the first line of the file is never one under test.
    $script:Noise = @(
        '12:00:00.000 [Engine] Initializing renderer'
        '12:00:00.100 [Network] connected to backend, 0 errors'
        '12:00:01.000 [Lua] [MOD][dmf][INFO] DMF loaded'
    )
    $script:MainLog = $script:Noise + @(
        '12:00:02.000 <<Lua Error>>mods/alpha_mod/scripts/mods/alpha_mod/alpha_mod.lua:12: attempt to index a nil value<</Lua Error>>'
        '12:00:02.000 <<Lua Stack>>'
        "`t[1] mods/dmf/scripts/mods/dmf/modules/core/hooks.lua:50: in function <hook>"
        "`t[2] mods/alpha_mod/scripts/mods/alpha_mod/alpha_mod.lua:12"
        '<</Lua Stack>>'
        '12:00:03.000 [Lua] spawning horde'
        '12:00:04.000 [MOD][Beta Mod][ERROR] something broke in beta'
        '12:00:05.000 Script Error: scripts/mods/alpha_mod/alpha_mod.lua:40: bad argument #1'
        'stack traceback:'
        "`t[string `"scripts/mods/beta_mod/beta_mod`"]:7: in function 'hook'"
        '12:00:06.000 <<Lua Error>>mods/[Gamma] Tweaks/scripts/mods/gamma/gamma.lua:3: oops<</Lua Error>>'
        '12:00:07.000 [Network] ERROR: backend timeout'
        '12:00:08.000 [Engine] shutting down'
    )
}

Describe 'Get-DarktideErrors' {

    BeforeEach {
        $script:SavedEnv = @{}
        foreach ($n in @('USERPROFILE', 'USERNAME', 'APPDATA')) {
            $script:SavedEnv[$n] = [Environment]::GetEnvironmentVariable($n)
        }

        $script:Root    = New-TestSandbox
        $script:OutRoot = New-TestSandbox
        $script:Game    = New-FakeGameFolder -Root $script:Root
        $script:Staging = New-FakeStaging -Root $script:Root -Mods @('alpha_mod', 'beta_mod', '[Gamma] Tweaks')
        $script:Config  = New-TestConfig -Root $script:Root -StagingMods $script:Staging -GamePath $script:Game
        $script:Logs    = Join-Path $script:Root 'console_logs'
        [void][System.IO.Directory]::CreateDirectory($script:Logs)

        $script:Lock = Join-Path $script:Root 'test.lock.json'
        [ordered]@{
            schemaVersion = 1
            game          = 'warhammer40kdarktide'
            modCount      = 3
            loadOrder     = @('alpha_mod', 'beta_mod', '[Gamma] Tweaks')
            mods          = @(
                [ordered]@{ folder = 'alpha_mod'; name = 'Alpha Mod'; modId = 447; version = '2.1.0'
                            url = 'https://www.nexusmods.com/warhammer40kdarktide/mods/447' },
                # No url: the page has to be built from the id.
                [ordered]@{ folder = 'beta_mod'; name = 'Beta Mod'; modId = 448; version = '1.3.0' },
                [ordered]@{ folder = '[Gamma] Tweaks'; name = '[Gamma] Tweaks'; modId = $null; version = $null }
            )
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:Lock -Encoding UTF8
    }

    AfterEach {
        foreach ($n in $script:SavedEnv.Keys) {
            [Environment]::SetEnvironmentVariable($n, $script:SavedEnv[$n])
        }
        foreach ($d in @($script:Root, $script:OutRoot)) {
            if ($d -and (Test-Path -LiteralPath $d)) {
                Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'ranking' {

        BeforeEach {
            $null = New-ConsoleLog -Dir $script:Logs -Name 'console-main.log' -Lines $script:MainLog
            $script:Json = Join-Path $script:OutRoot 'report.json'
            $script:Out  = Invoke-Blame -Extra @{ OutFile = $script:Json }
            $script:Report = Read-JsonReport -Path $script:Json
        }

        It 'ranks the mod with the most errors first, with its count' {
            $o = @($script:Report.offenders)
            $o[0].folder | Should -Be 'alpha_mod'
            $o[0].errors | Should -Be 2
            $o[0].rank   | Should -Be 1
        }

        It 'maps a DMF tag carrying the display name to the folder' {
            $beta = @($script:Report.offenders | Where-Object { $_.folder -eq 'beta_mod' })
            $beta.Count       | Should -Be 1
            $beta[0].errors   | Should -Be 1
            # Named in the stack of alpha_mod's Script Error, which is not its own error.
            $beta[0].alsoInStack | Should -Be 1
        }

        It 'matches a folder name that contains brackets' {
            $gamma = @($script:Report.offenders | Where-Object { $_.folder -eq '[Gamma] Tweaks' })
            $gamma.Count     | Should -Be 1
            $gamma[0].errors | Should -Be 1
            $gamma[0].known  | Should -BeTrue
        }

        It 'counts engine errors without blaming a mod for them' {
            $script:Report.errors       | Should -Be 5
            $script:Report.attributed   | Should -Be 4
            $script:Report.unattributed | Should -Be 1
            @($script:Report.unattributedSample)[0] | Should -BeLike '*backend timeout*'
        }

        It 'does not blame DMF for a hook that runs through it' {
            @($script:Report.offenders | Where-Object { $_.folder -eq 'dmf' }).Count | Should -Be 0
        }

        It 'blames the mod in the stack, not DMF, even when DMF is named first' {
            Remove-Item -LiteralPath (Join-Path $script:Logs 'console-main.log') -Force
            $null = New-ConsoleLog -Dir $script:Logs -Name 'console-dmf.log' -Lines ($script:Noise + @(
                '12:00:02.000 <<Lua Error>>mods/dmf/scripts/mods/dmf/modules/core/hooks.lua:50: attempt to call a nil value<</Lua Error>>'
                '<<Lua Stack>>'
                "`t[1] mods/dmf/scripts/mods/dmf/modules/core/hooks.lua:50: in function <hook>"
                "`t[2] mods/beta_mod/scripts/mods/beta_mod/beta_mod.lua:7: in function <cb>"
                '<</Lua Stack>>'))
            $json = Join-Path $script:OutRoot 'dmf.json'
            $null = Invoke-Blame -Extra @{ OutFile = $json }
            $o = @((Read-JsonReport -Path $json).offenders)
            $o.Count     | Should -Be 1
            $o[0].folder | Should -Be 'beta_mod'
        }

        It 'carries the version and Nexus page from the lockfile' {
            $alpha = @($script:Report.offenders | Where-Object { $_.folder -eq 'alpha_mod' })[0]
            $alpha.version | Should -Be '2.1.0'
            $alpha.url     | Should -Be 'https://www.nexusmods.com/warhammer40kdarktide/mods/447'
            $beta = @($script:Report.offenders | Where-Object { $_.folder -eq 'beta_mod' })[0]
            $beta.url      | Should -Be 'https://www.nexusmods.com/warhammer40kdarktide/mods/448'
        }

        It 'keeps the first error line for each mod' {
            $alpha = @($script:Report.offenders | Where-Object { $_.folder -eq 'alpha_mod' })[0]
            $alpha.firstError | Should -BeLike '*alpha_mod.lua:12: attempt to index a nil value*'
            $alpha.firstFile  | Should -Be 'console-main.log'
        }

        It 'says most likely, and never claims certainty' {
            $script:Out | Should -Match 'Most likely'
            $script:Out | Should -Match 'alpha_mod'
            $script:Out | Should -Not -Match '(?i)definitely|the culprit is'
        }

        It 'does not show the loader hint when mods were clearly loaded' {
            $script:Out | Should -Not -Match 'patchcheck'
            $script:Report.modLinesSeen | Should -BeTrue
        }
    }

    Context 'name matching' {

        It 'still recognises [Beta Mod] as beta_mod from the staging folder name alone' {
            $null = New-ConsoleLog -Dir $script:Logs -Name 'console.log' -Lines ($script:Noise + '12:00:04.000 [MOD][Beta Mod][ERROR] boom')
            $json = Join-Path $script:OutRoot 'r.json'
            $null = Invoke-Blame -Extra @{ LockPath = (Join-Path $script:Root 'no-such.lock.json'); OutFile = $json }
            $o = @((Read-JsonReport -Path $json).offenders)
            $o.Count     | Should -Be 1
            $o[0].folder | Should -Be 'beta_mod'
        }

        It 'maps a path whose folder is spelled differently to the same mod' {
            $null = New-ConsoleLog -Dir $script:Logs -Name 'console.log' -Lines ($script:Noise +
                '12:00:04.000 <<Lua Error>>[string "scripts/mods/BetaMod/BetaMod"]:3: boom<</Lua Error>>')
            $json = Join-Path $script:OutRoot 'r.json'
            $null = Invoke-Blame -Extra @{ OutFile = $json }
            $o = @((Read-JsonReport -Path $json).offenders)
            $o.Count     | Should -Be 1
            $o[0].folder | Should -Be 'beta_mod'
            $o[0].known  | Should -BeTrue
        }

        It 'still names a mod folder it does not know, and says so' {
            $null = New-ConsoleLog -Dir $script:Logs -Name 'console.log' -Lines ($script:Noise +
                '12:00:04.000 <<Lua Error>>mods/stray_mod/scripts/mods/stray_mod/stray_mod.lua:3: boom<</Lua Error>>')
            $json = Join-Path $script:OutRoot 'r.json'
            $out = Invoke-Blame -Extra @{ OutFile = $json }
            $o = @((Read-JsonReport -Path $json).offenders)
            $o[0].folder | Should -Be 'stray_mod'
            $o[0].known  | Should -BeFalse
            $out | Should -Match 'not in staging or the lockfile'
        }

        It 'ignores bracketed tags that name no mod you have' {
            $null = New-ConsoleLog -Dir $script:Logs -Name 'console.log' -Lines ($script:Noise + '12:00:04.000 [Renderer][ERROR] device lost')
            $json = Join-Path $script:OutRoot 'r.json'
            $null = Invoke-Blame -Extra @{ OutFile = $json }
            $r = Read-JsonReport -Path $json
            @($r.offenders).Count | Should -Be 0
            $r.unattributed       | Should -Be 1
        }
    }

    Context 'which logs are read' {

        BeforeEach {
            # Names sort the opposite way to the write times, so only a
            # LastWriteTime sort picks the right one.
            $null = New-ConsoleLog -Dir $script:Logs -Name 'console-b.log' -When (Get-Date).AddHours(-2) -Lines (
                $script:Noise + '12:00:04.000 [MOD][Beta Mod][ERROR] from the older session')
            $null = New-ConsoleLog -Dir $script:Logs -Name 'console-a.log' -When (Get-Date).AddMinutes(-5) -Lines (
                $script:Noise + '12:00:02.000 <<Lua Error>>mods/alpha_mod/scripts/mods/alpha_mod/alpha_mod.lua:1: newer<</Lua Error>>')
            $script:Json = Join-Path $script:OutRoot 'r.json'
        }

        It 'reads only the newest file by last write time by default' {
            $null = Invoke-Blame -Extra @{ OutFile = $script:Json }
            $r = Read-JsonReport -Path $script:Json
            @($r.files).Count     | Should -Be 1
            @($r.files)[0].name   | Should -Be 'console-a.log'
            @($r.offenders).folder | Should -Be @('alpha_mod')
        }

        It 'reads the newest two with -Last 2, oldest first' {
            $null = Invoke-Blame -Extra @{ Last = 2; OutFile = $script:Json }
            $r = Read-JsonReport -Path $script:Json
            @($r.files).name | Should -Be @('console-b.log', 'console-a.log')
            @($r.offenders | ForEach-Object { $_.folder } | Sort-Object) | Should -Be @('alpha_mod', 'beta_mod')
        }

        It 'warns when asked for more logs than exist, and reads what there is' {
            $out = Invoke-Blame -Extra @{ Last = 5; OutFile = $script:Json }
            $out | Should -Match 'Asked for 5 log\(s\); the folder has 2'
            @((Read-JsonReport -Path $script:Json).files).Count | Should -Be 2
        }

        It 'reads only the tail of a long log' {
            $lines = @('12:00:00.000 <<Lua Error>>mods/beta_mod/scripts/mods/beta_mod/beta_mod.lua:1: early<</Lua Error>>')
            $lines += @(1..400 | ForEach-Object { "12:00:01.000 [Engine] frame $_" })
            $lines += '12:00:09.000 <<Lua Error>>mods/alpha_mod/scripts/mods/alpha_mod/alpha_mod.lua:2: late<</Lua Error>>'
            $null = New-ConsoleLog -Dir $script:Logs -Name 'console-z.log' -Lines $lines -When (Get-Date)
            $null = Invoke-Blame -Extra @{ TailLines = 100; OutFile = $script:Json }
            $r = Read-JsonReport -Path $script:Json
            @($r.files)[0].linesRead | Should -Be 100
            @($r.files)[0].tail      | Should -BeTrue
            @($r.offenders).folder   | Should -Be @('alpha_mod')
        }
    }

    Context 'failure paths and empty logs' {

        It 'fails clearly when the log folder does not exist' {
            $missing = Join-Path $script:Root 'nowhere'
            { Invoke-Blame -Extra @{ LogDir = $missing } } | Should -Throw '*not found*-LogDir*'
        }

        It 'names the default location when nothing says otherwise' {
            $env:APPDATA = Join-Path $script:Root 'AppData'
            { & $script:Blamer -ConfigPath $script:Config -LockPath $script:Lock *>&1 | Out-Null } |
                Should -Throw '*console_logs*'
        }

        It 'uses ConsoleLogDir from config.json when -LogDir is not given' {
            $null = New-ConsoleLog -Dir $script:Logs -Name 'console.log' -Lines $script:MainLog
            $cfg = Get-Content -LiteralPath $script:Config -Raw | ConvertFrom-Json
            $cfg | Add-Member -NotePropertyName ConsoleLogDir -NotePropertyValue $script:Logs
            $cfg | ConvertTo-Json | Set-Content -LiteralPath $script:Config -Encoding UTF8
            $json = Join-Path $script:OutRoot 'r.json'
            $null = & $script:Blamer -ConfigPath $script:Config -LockPath $script:Lock -OutFile $json *>&1
            @((Read-JsonReport -Path $json).offenders)[0].folder | Should -Be 'alpha_mod'
        }

        It 'fails clearly when the folder has no logs' {
            { Invoke-Blame } | Should -Throw '*No .log or .txt files*'
        }

        It 'says no errors found for an empty log' {
            $null = New-ConsoleLog -Dir $script:Logs -Name 'console.log'
            $json = Join-Path $script:OutRoot 'r.json'
            $out = Invoke-Blame -Extra @{ OutFile = $json }
            $out | Should -Match 'No errors found'
            (Read-JsonReport -Path $json).errors | Should -Be 0
        }

        It 'points at the loader when the log has no mod lines at all' {
            $null = New-ConsoleLog -Dir $script:Logs -Name 'console.log' -Lines @(
                '12:00:00.000 [Engine] Initializing renderer'
                '12:00:05.000 [Renderer] ERROR: device lost')
            $json = Join-Path $script:OutRoot 'r.json'
            $out = Invoke-Blame -Extra @{ OutFile = $json }
            $out | Should -Match 'No mod lines at all'
            $out | Should -Match 'darktide\.ps1 patchcheck'
            (Read-JsonReport -Path $json).modLinesSeen | Should -BeFalse
        }

        It 'refuses to overwrite -OutFile without -Force, and overwrites with it' {
            $null = New-ConsoleLog -Dir $script:Logs -Name 'console.log' -Lines $script:MainLog
            $json = Join-Path $script:OutRoot 'r.json'
            Set-Content -LiteralPath $json -Value 'keep me' -Encoding UTF8
            { Invoke-Blame -Extra @{ OutFile = $json } } | Should -Throw '*already exists*-Force*'
            (Get-Content -LiteralPath $json -Raw) | Should -Match 'keep me'

            $null = Invoke-Blame -Extra @{ OutFile = $json; Force = $true }
            (Read-JsonReport -Path $json).errors | Should -Be 5
        }

        It 'refuses an -OutFile that is neither .json nor .md' {
            $null = New-ConsoleLog -Dir $script:Logs -Name 'console.log' -Lines $script:MainLog
            $txt = Join-Path $script:OutRoot 'r.txt'
            { Invoke-Blame -Extra @{ OutFile = $txt } } | Should -Throw '*.json or .md*'
            Test-Path -LiteralPath $txt | Should -BeFalse
        }

        It 'refuses to write -OutFile inside the game folder' {
            $null = New-ConsoleLog -Dir $script:Logs -Name 'console.log' -Lines $script:MainLog
            $before = Get-TreeFingerprint -Path $script:Game
            { Invoke-Blame -Extra @{ OutFile = (Join-Path $script:Game 'errors.json') } } | Should -Throw '*game folder*'
            Get-TreeFingerprint -Path $script:Game | Should -Be $before
        }
    }

    Context 'redaction and truncation' {

        It 'replaces the profile path and the user name everywhere it prints or writes' {
            $env:USERPROFILE = 'C:\Users\SomeUser'
            $env:USERNAME    = 'SomeUser'
            $null = New-ConsoleLog -Dir $script:Logs -Name 'console.log' -Lines ($script:Noise + @(
                '12:00:04.000 [MOD][Beta Mod][ERROR] cannot open C:\Users\SomeUser\AppData\Roaming\Fatshark\Darktide\user_settings.config'
                '12:00:05.000 <<Lua Error>>mods/alpha_mod/scripts/mods/alpha_mod/alpha_mod.lua:3: player SomeUser has no profile<</Lua Error>>'
                '12:00:06.000 [Network] ERROR: SomeUser disconnected'))
            $json = Join-Path $script:OutRoot 'r.json'
            $md   = Join-Path $script:OutRoot 'r.md'
            $out  = Invoke-Blame -Extra @{ OutFile = $json }
            $null = Invoke-Blame -Extra @{ OutFile = $md }
            $jsonText = Get-Content -LiteralPath $json -Raw
            $mdText   = Get-Content -LiteralPath $md -Raw

            foreach ($text in @($out, $jsonText, $mdText)) {
                $text | Should -Not -Match 'SomeUser'
                $text | Should -Match '%USERPROFILE%'
            }
            # Raw JSON is not checked for '<user>': Windows PowerShell 5.1 writes '<' as <.
            foreach ($text in @($out, $mdText)) { $text | Should -Match '<user>' }

            $report = Read-JsonReport -Path $json
            $beta  = @($report.offenders | Where-Object { $_.folder -eq 'beta_mod' })[0]
            $alpha = @($report.offenders | Where-Object { $_.folder -eq 'alpha_mod' })[0]
            $beta.firstError  | Should -BeLike '*%USERPROFILE%\AppData\Roaming\Fatshark*'
            $alpha.firstError | Should -BeLike '*player <user> has no profile*'
            @($report.unattributedSample)[0] | Should -BeLike '*<user> disconnected*'
        }

        It 'redacts a profile path from another machine, and that name on its own' {
            $env:USERPROFILE = 'C:\Users\SomeUser'
            $env:USERNAME    = 'SomeUser'
            # The bare name comes first and is printed as an unattributed sample, so it
            # is only redacted if names are collected from the whole log up front.
            $null = New-ConsoleLog -Dir $script:Logs -Name 'console.log' -Lines ($script:Noise + @(
                '12:00:03.000 [Network] ERROR: OtherPerson left the strike team'
                '12:00:04.000 [MOD][Beta Mod][ERROR] D:\Users\OtherPerson\Documents\x.lua missing'
                '12:00:05.000 [Renderer] ERROR: shader cache at C:\Users\Jane Doe\AppData\Local\cache unreadable'))
            $json = Join-Path $script:OutRoot 'r.json'
            $out = Invoke-Blame -Extra @{ OutFile = $json }
            $out | Should -Not -Match 'OtherPerson'
            $out | Should -Match '<user> left the strike team'
            $out | Should -Not -Match 'Jane|Doe'
            $out | Should -Match 'shader cache at %USERPROFILE%\\AppData'
            (Get-Content -LiteralPath $json -Raw) | Should -Not -Match 'OtherPerson|Jane|Doe'
        }

        It 'does not garble a mod folder that starts with the user name' {
            $env:USERPROFILE = 'C:\Users\alpha'
            $env:USERNAME    = 'alpha'
            $null = New-ConsoleLog -Dir $script:Logs -Name 'console.log' -Lines ($script:Noise + @(
                '12:00:02.000 <<Lua Error>>mods/alpha_mod/scripts/mods/alpha_mod/alpha_mod.lua:12: player alpha has no profile<</Lua Error>>'))
            $json = Join-Path $script:OutRoot 'r.json'
            $out  = Invoke-Blame -Extra @{ OutFile = $json }
            $out | Should -Match 'alpha_mod'
            $out | Should -Not -Match '<user>_mod'
            $first = @((Read-JsonReport -Path $json).offenders | Where-Object { $_.folder -eq 'alpha_mod' })[0].firstError
            $first | Should -BeLike '*mods/alpha_mod/*'
            $first | Should -BeLike '*player <user> has no profile*'
        }

        It 'cuts the first error line to 200 characters' {
            $long = '12:00:02.000 <<Lua Error>>mods/alpha_mod/scripts/mods/alpha_mod/alpha_mod.lua:9: ' + ('x' * 500)
            $null = New-ConsoleLog -Dir $script:Logs -Name 'console.log' -Lines ($script:Noise + $long)
            $json = Join-Path $script:OutRoot 'r.json'
            $null = Invoke-Blame -Extra @{ OutFile = $json }
            $first = @((Read-JsonReport -Path $json).offenders)[0].firstError
            $first.Length | Should -BeLessOrEqual 200
            $first        | Should -BeLike '*...'
        }

        It 'redacts before cutting, so no half of a name or profile path survives' {
            $env:USERPROFILE = 'C:\Users\SomeUser'
            $env:USERNAME    = 'SomeUser'
            # The name straddles the 200-character cut: cutting first would leave 'Some'.
            $head = '12:00:02.000 <<Lua Error>>mods/alpha_mod/scripts/mods/alpha_mod/alpha_mod.lua:9: '
            $head = $head + ('y' * (192 - $head.Length))
            $nameLine = $head + ' SomeUser ' + ('z' * 100)
            $pathLine = '12:00:03.000 <<Lua Error>>mods/beta_mod/scripts/mods/beta_mod/beta_mod.lua:1: ' +
                        ('y' * 100) + ' C:\Users\SomeUser\AppData\Local\Temp\' + ('z' * 200)
            $null = New-ConsoleLog -Dir $script:Logs -Name 'console.log' -Lines ($script:Noise + $nameLine + $pathLine)
            $json = Join-Path $script:OutRoot 'r.json'
            $null = Invoke-Blame -Extra @{ OutFile = $json }
            $o = @((Read-JsonReport -Path $json).offenders)
            foreach ($row in $o) {
                $row.firstError        | Should -Not -Match 'Some'
                $row.firstError.Length | Should -BeLessOrEqual 200
            }
            @($o | Where-Object { $_.folder -eq 'beta_mod' })[0].firstError | Should -Match '%USERPROFILE%'
        }
    }

    Context 'writes nothing else' {

        BeforeEach {
            $null = New-ConsoleLog -Dir $script:Logs -Name 'console.log' -Lines $script:MainLog
            $script:RepoFiles = @(Get-ChildItem -LiteralPath $script:RepoRoot -File | ForEach-Object { $_.Name } | Sort-Object)
        }

        It 'leaves staging, the game folder, the logs and the repo untouched without -OutFile' {
            $before = Get-TreeFingerprint -Path $script:Root
            $null = Invoke-Blame
            Get-TreeFingerprint -Path $script:Root | Should -Be $before
            Get-TreeFingerprint -Path $script:OutRoot | Should -Be '<empty>'
            @(Get-ChildItem -LiteralPath $script:RepoRoot -File | ForEach-Object { $_.Name } | Sort-Object) |
                Should -Be $script:RepoFiles
        }

        It 'writes exactly the -OutFile and nothing beside it' {
            $before = Get-TreeFingerprint -Path $script:Root
            $md = Join-Path $script:OutRoot 'errors.md'
            $null = Invoke-Blame -Extra @{ OutFile = $md }
            Get-TreeFingerprint -Path $script:Root | Should -Be $before
            @(Get-ChildItem -LiteralPath $script:OutRoot -Recurse -File).Name | Should -Be @('errors.md')
            $text = Get-Content -LiteralPath $md -Raw
            $text | Should -Match '\| 1 \| alpha_mod \| 2 \|'
            $text | Should -Match 'Most likely'
        }
    }

    Context 'darktide.ps1 errors' {

        It 'works with -LogDir and no config.json at all' {
            $null = New-ConsoleLog -Dir $script:Logs -Name 'console.log' -Lines $script:MainLog
            $noConfig = Join-Path $script:Root 'absent-config.json'
            $out = & $script:Dispatcher errors -LogDir $script:Logs -ConfigPath $noConfig *>&1 | Out-String
            $out | Should -Match 'alpha_mod'
            $out | Should -Match 'Most likely'
            Test-Path -LiteralPath $noConfig | Should -BeFalse
        }

        It 'passes -Last, -OutFile and -Force through' {
            $null = New-ConsoleLog -Dir $script:Logs -Name 'console-1.log' -Lines $script:MainLog -When (Get-Date).AddHours(-1)
            $null = New-ConsoleLog -Dir $script:Logs -Name 'console-2.log' -Lines $script:Noise -When (Get-Date)
            $json = Join-Path $script:OutRoot 'r.json'
            Set-Content -LiteralPath $json -Value 'old' -Encoding UTF8
            & $script:Dispatcher errors -ConfigPath $script:Config -LogDir $script:Logs -Last 2 -OutFile $json -Force *>&1 | Out-Null
            $r = Read-JsonReport -Path $json
            @($r.files).Count | Should -Be 2
            $r.errors         | Should -Be 5
        }

        It 'is read-only through the dispatcher too' {
            $null = New-ConsoleLog -Dir $script:Logs -Name 'console.log' -Lines $script:MainLog
            $before = Get-TreeFingerprint -Path $script:Root
            & $script:Dispatcher errors -ConfigPath $script:Config -LogDir $script:Logs *>&1 | Out-Null
            Get-TreeFingerprint -Path $script:Root | Should -Be $before
        }
    }
}
