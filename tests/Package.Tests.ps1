<#
    Tests for New-ReleasePackage.ps1.

    Publishing is the one irreversible thing this repository does: a wrong lockfile
    can be corrected in the next release, but a mod file that escapes into a public
    zip cannot be un-downloaded and is someone else's copyrighted work.

    Two layers decide what ships. The allow-list is the mechanism; the scan
    afterwards is what catches a mistake in the allow-list. So the scan is tested by
    planting exactly the mistake it exists to catch, rather than by watching a clean
    tree stay clean.

    Everything runs against a sandbox repository, never the real one: the script
    resolves what to ship from its own $PSScriptRoot, so dropping a copy of it into
    a fake tree is enough to point it somewhere harmless.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Packer   = Join-Path $script:RepoRoot 'New-ReleasePackage.ps1'

    function New-FakeRepo {
        <#
            A tree holding everything the allow-list names, and nothing else.
            Returns the path to the copy of the packaging script inside it.
        #>
        param([string] $Root)

        $packer = Join-Path $Root 'New-ReleasePackage.ps1'
        Copy-Item -LiteralPath $script:Packer -Destination $packer -Force

        foreach ($name in @(& $script:Packer -ListOnly)) {
            $target = Join-Path $Root $name
            if ($name -eq 'tests') {
                [void][System.IO.Directory]::CreateDirectory($target)
                Set-Content -LiteralPath (Join-Path $target 'Fake.Tests.ps1') -Value '# stub' -Encoding UTF8
            } else {
                Set-Content -LiteralPath $target -Value "# stub $name" -Encoding UTF8
            }
        }
        return $packer
    }
}

Describe 'New-ReleasePackage' {

    BeforeEach {
        $script:Root = New-TestSandbox
        $script:Fake = Join-Path $script:Root 'repo'
        [void][System.IO.Directory]::CreateDirectory($script:Fake)
        $script:FakePacker = New-FakeRepo -Root $script:Fake
        $script:Out = Join-Path $script:Root 'out'
    }

    AfterEach {
        if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'the allow-list' {

        It 'names the entry point, the manifest and the licence' {
            $listed = @(& $script:Packer -ListOnly)
            $listed | Should -Contain 'darktide.ps1'
            $listed | Should -Contain 'darktide-modpack.lock.json'
            $listed | Should -Contain 'LICENSE'
        }

        It 'ships the suite so a user can verify the tooling before running it' {
            $listed = @(& $script:Packer -ListOnly)
            $listed | Should -Contain 'Invoke-Tests.ps1'
            $listed | Should -Contain 'tests'
        }

        It 'does not ship the skills directory, which is for working on the repo' {
            @(& $script:Packer -ListOnly) | Should -Not -Contain '.claude'
        }

        It 'writes nothing when only listing' {
            & $script:FakePacker -ListOnly -Destination $script:Out | Out-Null
            Test-Path -LiteralPath $script:Out | Should -BeFalse
        }
    }

    Context 'staging' {

        It 'copies every allow-listed path' {
            & $script:FakePacker -Destination $script:Out -NoArchive -Confirm:$false *>&1 | Out-Null

            $staged = Join-Path $script:Out 'darktide-mods'
            foreach ($name in @(& $script:Packer -ListOnly)) {
                Test-Path -LiteralPath (Join-Path $staged $name) | Should -BeTrue -Because "$name is on the allow-list"
            }
        }

        It 'ships nothing the allow-list does not name' {
            Set-Content -LiteralPath (Join-Path $script:Fake 'secrets.txt') -Value 'private' -Encoding UTF8

            & $script:FakePacker -Destination $script:Out -NoArchive -Confirm:$false *>&1 | Out-Null

            Test-Path -LiteralPath (Join-Path $script:Out 'darktide-mods/secrets.txt') | Should -BeFalse
        }

        It 'refuses when an allow-listed file is missing rather than shipping a partial package' {
            Remove-Item -LiteralPath (Join-Path $script:Fake 'LICENSE') -Force

            { & $script:FakePacker -Destination $script:Out -NoArchive -Confirm:$false } |
                Should -Throw -ExpectedMessage '*Missing required file*'
        }
    }

    Context 'the forbidden-content scan' {
        # The layer that catches a mistake in the allow-list. Each of these arrives
        # through a directory the allow-list legitimately names, which is exactly how
        # a real leak would get in.

        It 'refuses a <_> that reached the staged tree' -ForEach @(
            'a_mod.mod', 'loadout.zip', 'config.json'
        ) {
            Set-Content -LiteralPath (Join-Path $script:Fake "tests/$_") -Value 'leak' -Encoding UTF8

            { & $script:FakePacker -Destination $script:Out -NoArchive -Confirm:$false } |
                Should -Throw -ExpectedMessage '*Refusing to package*'
        }
    }

    Context 'the archive' {

        It 'builds a zip and a checksum that matches it' {
            & $script:FakePacker -Destination $script:Out -Version '9.9.9' -Confirm:$false *>&1 | Out-Null

            $zip = Join-Path $script:Out 'darktide-mods-9.9.9.zip'
            Test-Path -LiteralPath $zip | Should -BeTrue

            $sidecar = Get-Content -LiteralPath "$zip.sha256" -Raw
            $actual  = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()

            $sidecar | Should -Match $actual
            $sidecar | Should -Match 'darktide-mods-9.9.9.zip'
        }

        It 'asks for a version rather than inventing one' {
            { & $script:FakePacker -Destination $script:Out -Confirm:$false } |
                Should -Throw -ExpectedMessage '*-Version*'
        }
    }
}
