<#
    Unit tests for the archive-handling half of Update-DarktideMods.ps1.

    These are the functions that decide what gets written to disk, so they are the
    ones worth pinning down: a wrong answer here overwrites or deletes a mod folder.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $script:Updater = Join-Path (Split-Path -Parent $PSScriptRoot) 'Update-DarktideMods.ps1'

    Import-ScriptFunctions -Path $script:Updater -Name @(
        'Get-NexusFileNameParts',
        'Get-ArchiveVersionFromName',
        'Compare-ModVersion',
        'Get-ArchiveModLayout',
        'Expand-ModArchive',
        'Get-NormalizedName',
        'Resolve-ModIds'
    )

    # Resolve-ModIds is the one function here that would talk to Nexus. Stub the three
    # calls it makes so the resolve pass runs with no key and no network: the property
    # under test is what it does to mods-map.json, not what Nexus answers.
    function global:Invoke-NexusApi { param($Path, $Key, [switch] $AllowFailure) $null = $Path, $Key, $AllowFailure; return $null }
    function global:Get-NexusMod    { param($Domain, $ModId, $Key) $null = $Domain, $ModId, $Key; return $null }
    function global:Test-RateBudget { param($Need) $null = $Need; return $false }

    # Get-ArchiveModLayout logs when it rejects an archive; the real logger needs
    # script state we deliberately are not loading.
    function global:Write-Log {
        param([string] $Message, [string] $Level = "INFO")
        $null = $Message, $Level   # stub: swallow log output during tests
    }

    $script:Sandbox = New-TestSandbox
}

AfterAll {
    if ($script:Sandbox -and (Test-Path -LiteralPath $script:Sandbox)) {
        Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-NexusFileNameParts' {

    It 'parses a stock Nexus download name' {
        $p = Get-NexusFileNameParts -FileName 'Markers Improved All-in-one-447-2-14-4-1719209900.zip'
        $p         | Should -Not -BeNullOrEmpty
        $p.ModId   | Should -Be 447
        $p.Version | Should -Be '2.14.4'
        $p.Name    | Should -Be 'Markers Improved All-in-one'
    }

    It 'tolerates the browser duplicate-download suffix' {
        $p = Get-NexusFileNameParts -FileName 'Enemies Improved-809-1-2-0-1719209900 (1).zip'
        $p.ModId   | Should -Be 809
        $p.Version | Should -Be '1.2.0'
    }

    It 'returns nothing for a name that is not a Nexus download' {
        Get-NexusFileNameParts -FileName 'my_cool_mod.zip'       | Should -BeNullOrEmpty
        Get-NexusFileNameParts -FileName 'scoreboard-latest.zip' | Should -BeNullOrEmpty
    }

    It 'requires the trailing epoch, which is what makes the id unambiguous' {
        # Without a 9+ digit timestamp this could be any hyphenated name.
        Get-NexusFileNameParts -FileName 'Some Mod-447-2-14-4.zip' | Should -BeNullOrEmpty
    }
}

Describe 'Get-ArchiveVersionFromName' {

    It 'extracts the version when the mod id is known' {
        Get-ArchiveVersionFromName -FileName 'Markers-447-2-14-4-1719209900.zip' -ModId 447 |
            Should -Be '2.14.4'
    }

    It 'falls back to full name parsing when no id is supplied' {
        Get-ArchiveVersionFromName -FileName 'Markers-447-2-14-4-1719209900.zip' -ModId 0 |
            Should -Be '2.14.4'
    }

    It 'returns nothing when the id does not appear in the name' {
        Get-ArchiveVersionFromName -FileName 'Markers-447-2-14-4-1719209900.zip' -ModId 999 |
            Should -BeNullOrEmpty
    }
}

Describe 'Compare-ModVersion' {

    It 'orders <a> against <b> as <expected>' -ForEach @(
        @{ a = '2.14.4';   b = '2.14.3';   expected =  1 }
        @{ a = '2.14.3';   b = '2.14.4';   expected = -1 }
        @{ a = '2.14.4';   b = '2.14.4';   expected =  0 }
        @{ a = '1.10.0';   b = '1.9.0';    expected =  1 }
        @{ a = '4.7.06';   b = '4.7.6';    expected =  0 }
        @{ a = 'v1.2';     b = '1.2';      expected =  0 }
        @{ a = '1.2.0';    b = '1.2';      expected =  0 }
        @{ a = '26.06.24'; b = '26.06.23'; expected =  1 }
    ) {
        Compare-ModVersion -A $a -B $b | Should -Be $expected
    }

    It 'treats a known version as newer than an unknown one' {
        Compare-ModVersion -A '1.0.0' -B ''      | Should -Be 1
        Compare-ModVersion -A ''      -B '1.0.0' | Should -Be -1
        Compare-ModVersion -A ''      -B ''      | Should -Be 0
    }
}

Describe 'Get-ArchiveModLayout' {

    It 'resolves the mod name from the .mod file, not the archive name' {
        $zip = New-TestZip -Path (Join-Path $script:Sandbox 'good.zip') -Entries @{
            'SomeFolder/true_level/true_level.mod' = 'return {}'
            'SomeFolder/true_level/info.json'      = '{"version":"1.2.3"}'
        }
        $layout = Get-ArchiveModLayout -ZipPath $zip
        $layout.ModName | Should -Be 'true_level'
        $layout.Prefix  | Should -Be 'SomeFolder/true_level/'
    }

    It 'normalises backslash entry paths the same way Expand-ModArchive does' {
        # CreateFromDirectory and some Windows zippers write '\'. Without
        # normalisation the prefix becomes empty and the extract root is wrong.
        $zip = New-TestZip -Path (Join-Path $script:Sandbox 'backslash.zip') -Entries @{
            'pack\scoreboard\scoreboard.mod' = 'return {}'
            'pack\scoreboard\info.json'      = '{"version":"1.0.0"}'
        }
        $layout = Get-ArchiveModLayout -ZipPath $zip
        $layout.ModName | Should -Be 'scoreboard'
        $layout.Prefix  | Should -Be 'pack/scoreboard/'
    }

    It 'ignores a base/ .mod file when picking the mod root' {
        $zip = New-TestZip -Path (Join-Path $script:Sandbox 'withbase.zip') -Entries @{
            'base/base.mod'             = 'return {}'
            'scoreboard/scoreboard.mod' = 'return {}'
        }
        (Get-ArchiveModLayout -ZipPath $zip).ModName | Should -Be 'scoreboard'
    }

    It 'refuses the unsafe mod name <name>' -ForEach @(
        @{ name = '..' }
        @{ name = 'base' }
        @{ name = 'mods' }
    ) {
        $suffix = [guid]::NewGuid().ToString('N').Substring(0, 6)
        $zip = New-TestZip -Path (Join-Path $script:Sandbox "unsafe-$suffix.zip") -Entries @{
            "payload/$name.mod" = 'return {}'
        }
        Get-ArchiveModLayout -ZipPath $zip | Should -BeNullOrEmpty
    }

    It 'returns nothing for an archive with no .mod file at all' {
        $zip = New-TestZip -Path (Join-Path $script:Sandbox 'nomod.zip') -Entries @{
            'readme.txt' = 'hello'
        }
        Get-ArchiveModLayout -ZipPath $zip | Should -BeNullOrEmpty
    }

    It 'returns nothing for a file that is not a zip' {
        $bogus = Join-Path $script:Sandbox 'notazip.zip'
        Set-Content -LiteralPath $bogus -Value 'this is not a zip' -Encoding ASCII
        Get-ArchiveModLayout -ZipPath $bogus | Should -BeNullOrEmpty
    }
}

Describe 'Expand-ModArchive' {

    BeforeEach {
        $script:Dest = Join-Path $script:Sandbox ('extract-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:Dest -Force | Out-Null
    }

    It 'extracts only the subtree under the prefix' {
        $zip = New-TestZip -Path (Join-Path $script:Sandbox 'sub.zip') -Entries @{
            'pack/mymod/mymod.mod'     = 'return {}'
            'pack/mymod/scripts/a.lua' = '-- a'
            'pack/README.txt'          = 'ignore me'
        }
        Expand-ModArchive -ZipPath $zip -Destination $script:Dest -Prefix 'pack/mymod/'

        Test-Path (Join-Path $script:Dest 'mymod.mod')     | Should -BeTrue
        Test-Path (Join-Path $script:Dest 'scripts\a.lua') | Should -BeTrue
        Test-Path (Join-Path $script:Dest 'README.txt')    | Should -BeFalse
    }

    It 'extracts when the zip entries use backslashes and the prefix uses slashes' {
        $zip = New-TestZip -Path (Join-Path $script:Sandbox 'sub-bs.zip') -Entries @{
            'pack\mymod\mymod.mod'     = 'return {}'
            'pack\mymod\scripts\a.lua' = '-- a'
        }
        Expand-ModArchive -ZipPath $zip -Destination $script:Dest -Prefix 'pack/mymod/'

        Test-Path (Join-Path $script:Dest 'mymod.mod')     | Should -BeTrue
        Test-Path (Join-Path $script:Dest 'scripts\a.lua') | Should -BeTrue
    }

    It 'rejects a forward-slash traversal entry' {
        $zip = New-TestZip -Path (Join-Path $script:Sandbox 'slip1.zip') -Entries @{
            'mymod/mymod.mod'      = 'return {}'
            'mymod/../../evil.txt' = 'pwned'
        }
        { Expand-ModArchive -ZipPath $zip -Destination $script:Dest -Prefix 'mymod/' } |
            Should -Throw -ExpectedMessage '*unsafe path*'
    }

    It 'rejects a backslash traversal entry' {
        # Zip entries may legally use a backslash separator, so a forward-slash-only
        # guard would be trivially bypassable.
        $back = 'mymod/..' + [char]92 + '..' + [char]92 + 'evil.txt'
        $zip = New-TestZip -Path (Join-Path $script:Sandbox 'slip2.zip') -Entries @{
            'mymod/mymod.mod' = 'return {}'
            $back             = 'pwned'
        }
        { Expand-ModArchive -ZipPath $zip -Destination $script:Dest -Prefix 'mymod/' } |
            Should -Throw -ExpectedMessage '*unsafe path*'
    }

    It 'rejects an absolute drive path entry' {
        $zip = New-TestZip -Path (Join-Path $script:Sandbox 'slip3.zip') -Entries @{
            'mymod/mymod.mod'           = 'return {}'
            'mymod/C:/Windows/evil.txt' = 'pwned'
        }
        { Expand-ModArchive -ZipPath $zip -Destination $script:Dest -Prefix 'mymod/' } |
            Should -Throw
    }

    It 'writes nothing outside the destination when it refuses an archive' {
        $outside = Join-Path $script:Sandbox 'evil.txt'
        if (Test-Path -LiteralPath $outside) { Remove-Item -LiteralPath $outside -Force }

        $zip = New-TestZip -Path (Join-Path $script:Sandbox 'slip4.zip') -Entries @{
            'mymod/../evil.txt' = 'pwned'
        }
        { Expand-ModArchive -ZipPath $zip -Destination $script:Dest -Prefix 'mymod/' } | Should -Throw
        Test-Path -LiteralPath $outside | Should -BeFalse
    }

    It 'extracts into a destination whose name contains brackets' {
        $dest = Join-Path $script:Sandbox 'mod[1]'
        [void][System.IO.Directory]::CreateDirectory($dest)
        $zip = New-TestZip -Path (Join-Path $script:Sandbox 'brackets.zip') -Entries @{
            'mymod/mymod.mod'     = 'return {}'
            'mymod/scripts/a.lua' = '-- a'
        }

        Expand-ModArchive -ZipPath $zip -Destination $dest -Prefix 'mymod/'

        Test-Path -LiteralPath (Join-Path $dest 'mymod.mod')     | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $dest 'scripts\a.lua') | Should -BeTrue
    }
}

Describe 'Resolve-ModIds and the mods-map entry' {
    # This pass rewrites the map entry around the four fields it owns. Anything else on
    # the entry was put there by hand, and losing it is silent - you find out when the
    # thing that read it stops working.

    BeforeEach {
        $script:Mods = @(
            [pscustomobject]@{ Folder = 'alpha_mod'; DisplayName = 'Alpha'; ModId = 447 }
        )
        $script:Catalog = Join-Path $script:Sandbox 'absent-catalog.json'
    }

    It 'keeps a hand-written githubRepo on an entry it fills in' {
        $map = @{ alpha_mod = [pscustomobject]@{ modId = $null; name = 'Alpha'; githubRepo = 'author/alpha' } }

        $out = Resolve-ModIds -Mods $script:Mods -Map $map -Domain 'warhammer40kdarktide' `
                              -Key '' -CatalogPath $script:Catalog

        $out['alpha_mod'].modId     | Should -Be 447
        $out['alpha_mod'].githubRepo | Should -Be 'author/alpha'
    }

    It 'keeps a pinned flag on an entry it fills in' {
        $map = @{ alpha_mod = [pscustomobject]@{ modId = $null; name = 'Alpha'; pinned = $true } }

        $out = Resolve-ModIds -Mods $script:Mods -Map $map -Domain 'warhammer40kdarktide' `
                              -Key '' -CatalogPath $script:Catalog

        $out['alpha_mod'].pinned | Should -BeTrue
    }

    It 'keeps any other field someone added by hand' {
        $map = @{ alpha_mod = [pscustomobject]@{ modId = $null; name = 'Alpha'; comment = 'ask the author first' } }

        $out = Resolve-ModIds -Mods $script:Mods -Map $map -Domain 'warhammer40kdarktide' `
                              -Key '' -CatalogPath $script:Catalog

        $out['alpha_mod'].comment | Should -Be 'ask the author first'
    }

    It 'leaves an already-mapped entry alone' {
        $map = @{ alpha_mod = [pscustomobject]@{ modId = 999; name = 'Whatever I called it'; githubRepo = 'author/alpha' } }

        $out = Resolve-ModIds -Mods $script:Mods -Map $map -Domain 'warhammer40kdarktide' `
                              -Key '' -CatalogPath $script:Catalog

        $out['alpha_mod'].modId | Should -Be 999
        $out['alpha_mod'].name  | Should -Be 'Whatever I called it'
    }

    It 'still refreshes the fields it owns' {
        $map = @{ alpha_mod = [pscustomobject]@{ modId = $null; name = 'stale name'; note = 'unresolved - ...'; githubRepo = 'author/alpha' } }

        $out = Resolve-ModIds -Mods $script:Mods -Map $map -Domain 'warhammer40kdarktide' `
                              -Key '' -CatalogPath $script:Catalog

        $out['alpha_mod'].name | Should -Be 'Alpha'
        $out['alpha_mod'].note | Should -BeNullOrEmpty
    }
}
