<#
    Shared fixtures for the Pester suite.

    Every test runs against a throwaway sandbox under $env:TEMP. Nothing here ever
    touches the real staging folder, the real game install, or the network.
#>

# ZipFile lives in ...FileSystem; ZipArchive/ZipArchiveMode live in ...Compression.
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue

function Import-ScriptFunctions {
    <#
        The tools are scripts, not modules, so their functions cannot be imported
        without executing the whole file. Parse the file and re-declare just the
        functions we want to unit-test, in global scope.
    #>
    param(
        [Parameter(Mandatory)] [string]   $Path,
        [Parameter(Mandatory)] [string[]] $Name
    )

    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        throw "Cannot parse $Path : $($errors[0].Message)"
    }

    $found = @{}
    foreach ($fn in $ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        if ($Name -notcontains $fn.Name) { continue }
        $text = $fn.Extent.Text
        # Promote to global so the It blocks can see it.
        $text = [regex]::Replace($text, "^function\s+$([regex]::Escape($fn.Name))",
                                 "function global:$($fn.Name)")
        Invoke-Expression $text
        $found[$fn.Name] = $true
    }

    $missing = @($Name | Where-Object { -not $found.ContainsKey($_) })
    if ($missing) { throw "Functions not found in $Path : $($missing -join ', ')" }
}

function New-TestSandbox {
    <# A unique empty directory that the caller is responsible for removing. #>
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("dtmods-test-" + [guid]::NewGuid().ToString('N').Substring(0, 12))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function New-FakeGameFolder {
    <#
        Builds something that passes Assert-ValidGamePath: deep enough not to look
        like a drive root, and carrying a Darktide marker file.
    #>
    param([Parameter(Mandatory)][string] $Root)

    $game = Join-Path $Root 'steamapps\common\Warhammer 40,000 DARKTIDE'
    New-Item -ItemType Directory -Path (Join-Path $game 'binaries') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $game 'binaries\Darktide.exe') -Value 'not a real exe' -Encoding ASCII
    New-Item -ItemType Directory -Path (Join-Path $game 'bundle') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $game 'bundle\bundle_database.data') -Value 'stub' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $game 'toggle_darktide_mods.bat') -Value '@echo off' -Encoding ASCII
    return $game
}

function New-FakeStaging {
    <#
        A minimal but realistic staging tree: base\, dmf\, mod_load_order.txt and
        whatever extra mods the caller asks for.
    #>
    param(
        [Parameter(Mandatory)][string] $Root,
        [string[]] $Mods = @('alpha_mod', 'beta_mod')
    )

    $staging = Join-Path $Root 'mods'
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    foreach ($m in @('base', 'dmf') + $Mods) {
        $dir = Join-Path $staging $m
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir "$m.mod") -Value "return { run = function() end }" -Encoding UTF8
        @{ name = $m; version = '1.0.0' } | ConvertTo-Json |
            Set-Content -LiteralPath (Join-Path $dir 'info.json') -Encoding UTF8
    }

    $lines = @('-- test load order') + $Mods
    Set-Content -LiteralPath (Join-Path $staging 'mod_load_order.txt') -Value $lines -Encoding UTF8
    return $staging
}

function New-TestConfig {
    <# Writes a config.json the tools can consume, pointed entirely at the sandbox. #>
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $StagingMods,
        [Parameter(Mandatory)][string] $GamePath
    )

    $cfgPath = Join-Path $Root 'config.json'
    [ordered]@{
        ModsRoot         = $StagingMods
        GamePath         = $GamePath
        LoaderSource     = ''
        DownloadDir      = (Join-Path $Root 'downloads')
        BackupRoot       = (Join-Path $Root 'mod_backups')
        DeployBackupRoot = (Join-Path $Root 'deploy_backups')
        GameDomain       = 'warhammer40kdarktide'
        ApiKey           = ''
    } | ConvertTo-Json | Set-Content -LiteralPath $cfgPath -Encoding UTF8

    New-Item -ItemType Directory -Path (Join-Path $Root 'downloads') -Force | Out-Null
    return $cfgPath
}

function Get-TreeFingerprint {
    <#
        Path + size + last-write of every file under a root. Two identical
        fingerprints mean a run genuinely wrote nothing.
    #>
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { return '<missing>' }
    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName)
    if ($files.Count -eq 0) { return '<empty>' }
    return ($files | ForEach-Object {
        $rel = $_.FullName.Substring($Path.Length)
        "$rel|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)"
    }) -join "`n"
}

function New-TestZip {
    <#
        Builds a zip from a literal map of entry-name -> content. Entry names are
        written verbatim, which is what lets us test traversal payloads that no
        normal archiver would produce.
    #>
    param(
        [Parameter(Mandatory)][string]    $Path,
        [Parameter(Mandatory)][hashtable] $Entries
    )

    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew)
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($key in $Entries.Keys) {
                $entry = $zip.CreateEntry($key)
                $sw = New-Object System.IO.StreamWriter($entry.Open())
                try { $sw.Write([string]$Entries[$key]) } finally { $sw.Dispose() }
            }
        } finally { $zip.Dispose() }
    } finally { $fs.Dispose() }
    return $Path
}
