<#
    Tests for the validator's three attribution checks.

    These checks are the only thing standing between an assistant's credit line
    and the published history, and they are the easiest checks in the repo to
    break without noticing: a check that matches nothing passes on everything,
    and a green run looks identical either way.

    That is not hypothetical. The commit-message check spent its whole life
    inert. Its list of tool names was written as

        @([char]0x57 + 'arp', [char]0x43 + 'laude', ...)

    and in PowerShell ',' binds tighter than '+', so the list parsed as a single
    addition and collapsed into one space-joined string. It matched nothing,
    passed every run, and was only caught by planting a trailer and watching it
    survive. So each case below asserts against a repository that *should* fail,
    not only against a clean one.

    Every name here is assembled from fragments for the same reason the
    validator's are: spelled out, this file would be the thing the checks report.
#>

# Evaluated during discovery, which is when Pester reads the -Skip below. A value
# assigned in BeforeAll is still $null at that point, and the whole file would skip.
$GitAvailable = [bool](Get-Command git -ErrorAction SilentlyContinue)

BeforeAll {
    $script:RepoRoot  = Split-Path -Parent $PSScriptRoot
    $script:Validator = Join-Path $script:RepoRoot 'Test-Modpack.ps1'

    $script:Agent  = [char]0x43 + 'laude'
    $script:Bot    = [char]0x43 + 'ursor'
    $script:Owner  = @{ Name = 'greenblacked'; Email = 'zolotov.98@gmail.com' }

    function New-PlantedRepo {
        <#
            A throwaway clone of this repository carrying one extra commit, with
            the working copy of the validator dropped in so the test exercises
            the file on disk rather than the last committed version of it.
        #>
        param(
            [Parameter(Mandatory)][string] $Message,
            [string] $AuthorName  = $script:Owner.Name,
            [string] $AuthorEmail = $script:Owner.Email
        )

        $path = Join-Path ([System.IO.Path]::GetTempPath()) ("dtmods-attr-" + [guid]::NewGuid().ToString('N').Substring(0, 12))
        & git clone --quiet --no-hardlinks $script:RepoRoot $path 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "could not clone the repository into $path" }

        Copy-Item -LiteralPath $script:Validator -Destination (Join-Path $path 'Test-Modpack.ps1') -Force

        & git -C $path -c "user.name=$AuthorName" -c "user.email=$AuthorEmail" `
              commit --quiet --allow-empty -m $Message 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'could not plant the commit' }

        return $path
    }

    function Get-CheckResult {
        <#
            The verdict for one named check. Deliberately not the validator's
            exit code: a planted commit trips one check, and asserting on the
            exit code alone would not notice a different check firing instead.
        #>
        param(
            [Parameter(Mandatory)][string] $Repo,
            [Parameter(Mandatory)][string] $CheckName
        )

        Push-Location $Repo
        try {
            $eap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                # '*>&1', not '2>&1': the validator reports through Write-Host, which
                # goes to the information stream. Redirecting only errors captures
                # nothing and every check then reads as missing.
                $out = & (Join-Path $Repo 'Test-Modpack.ps1') *>&1 | Out-String
            } finally { $ErrorActionPreference = $eap }
        } finally { Pop-Location }

        foreach ($line in ($out -split "`r?`n")) {
            if ($line -match "^\s+(PASS|FAIL)\s+$([regex]::Escape($CheckName))\s*$") {
                return $matches[1]
            }
        }
        return "MISSING (the check did not run at all)"
    }

    function Remove-PlantedRepo {
        param([string] $Path)
        if ($Path -and (Test-Path -LiteralPath $Path)) {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Attribution checks' -Skip:(-not $GitAvailable) {

    AfterEach {
        Remove-PlantedRepo $script:Planted
        $script:Planted = $null
    }

    Context 'a clean commit' {

        It 'passes all three checks' {
            $script:Planted = New-PlantedRepo -Message 'test: an ordinary commit'

            Get-CheckResult $script:Planted 'no agent attribution committed'          | Should -Be 'PASS'
            Get-CheckResult $script:Planted 'no agent attribution in commit messages' | Should -Be 'PASS'
            Get-CheckResult $script:Planted 'commits are authored by a person, not an agent' | Should -Be 'PASS'
        }
    }

    Context 'a co-author trailer crediting an assistant' {

        It 'fails the commit-message check' {
            $script:Planted = New-PlantedRepo -Message "test: planted trailer`n`nCo-Authored-By: $script:Agent <noreply@example.invalid>"

            Get-CheckResult $script:Planted 'no agent attribution in commit messages' | Should -Be 'FAIL'
        }

        It 'is caught for any tool, not only the first one in the list' {
            # The bug this file exists for made every name past the first
            # unreachable while the check still reported PASS.
            $script:Planted = New-PlantedRepo -Message "test: planted trailer`n`nCo-Authored-By: $script:Bot <noreply@example.invalid>"

            Get-CheckResult $script:Planted 'no agent attribution in commit messages' | Should -Be 'FAIL'
        }

        It 'does not blame the author fields for a message problem' {
            $script:Planted = New-PlantedRepo -Message "test: planted trailer`n`nCo-Authored-By: $script:Agent <noreply@example.invalid>"

            Get-CheckResult $script:Planted 'commits are authored by a person, not an agent' | Should -Be 'PASS'
        }
    }

    Context 'a generated-by footer in the message body' {

        It 'fails the commit-message check' {
            $script:Planted = New-PlantedRepo -Message "test: planted footer`n`nGenerated with $script:Agent Code"

            Get-CheckResult $script:Planted 'no agent attribution in commit messages' | Should -Be 'FAIL'
        }
    }

    Context 'a commit authored by a bot account' {

        It 'fails the identity check even though the message is spotless' {
            # This is the shape that reached the default branch: four merge
            # commits with clean messages and a bot in the author field, which
            # is the field the contributors list is built from.
            $script:Planted = New-PlantedRepo -Message 'ci: an entirely ordinary subject line' `
                                              -AuthorName "$script:Bot[bot]" `
                                              -AuthorEmail '206951365+bot@users.noreply.example.invalid'

            Get-CheckResult $script:Planted 'commits are authored by a person, not an agent' | Should -Be 'FAIL'
        }

        It 'does not blame the message checks for an identity problem' {
            $script:Planted = New-PlantedRepo -Message 'ci: an entirely ordinary subject line' `
                                              -AuthorName "$script:Bot[bot]" `
                                              -AuthorEmail '206951365+bot@users.noreply.example.invalid'

            Get-CheckResult $script:Planted 'no agent attribution in commit messages' | Should -Be 'PASS'
        }
    }
}
