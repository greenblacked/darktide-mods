# Installing Pester 5 when PSGallery is blocked

A recorded workaround for sandboxed or air-gapped environments where
`Install-Module Pester` fails because `www.powershellgallery.com` (and usually
`nuget.org`) is unreachable. This has been run end-to-end on Linux with no dotnet SDK
present and produced a working Pester 5.7.1.

Use the normal `Install-Module` path whenever it works. This is here for when it does
not.

## Why the obvious routes fail

- `Install-Module` / `Register-PSRepository -Default` need `powershellgallery.com`.
- `dotnet build` on the Pester sources needs an SDK that these environments rarely have.
- Pester 5's module genuinely requires its compiled `Pester.dll`; the `.psm1` alone is
  not enough.

The way through: compile the C# with the Roslyn assemblies that ship *inside* pwsh, then
run Pester's own `build.ps1` in its non-clean mode, which only assembles PowerShell files.

## Steps

**1. PowerShell itself**, if absent. Release tarballs on github.com are usually reachable
even when package feeds are not:

```bash
curl -sSL -o /tmp/pwsh.tar.gz \
  https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/powershell-7.4.6-linux-x64.tar.gz
mkdir -p /opt/pwsh && tar -xzf /tmp/pwsh.tar.gz -C /opt/pwsh
chmod +x /opt/pwsh/pwsh && ln -sf /opt/pwsh/pwsh /usr/local/bin/pwsh
```

**2. Clone Pester at the tag you want:**

```bash
git clone --depth 1 --branch 5.7.1 https://github.com/pester/pester /tmp/pester
```

Note the tag has no `v` prefix.

**3. Compile `Pester.dll` with pwsh's own Roslyn.** `Add-Type -OutputAssembly` does not
exist in PowerShell 7, so drive `Microsoft.CodeAnalysis` directly and emit to a
`FileStream` (there is no `Emit(string)` overload):

```powershell
$src = '/tmp/pester/src/csharp/Pester'
$out = "$src/bin/Release/netstandard2.0"
New-Item -ItemType Directory -Path $out -Force | Out-Null

Add-Type -Path '/opt/pwsh/Microsoft.CodeAnalysis.dll'
Add-Type -Path '/opt/pwsh/Microsoft.CodeAnalysis.CSharp.dll'

$trees = New-Object System.Collections.Generic.List[Microsoft.CodeAnalysis.SyntaxTree]
foreach ($f in Get-ChildItem $src -Recurse -Filter *.cs -File |
                Where-Object { $_.FullName -notmatch '/(obj|bin)/' }) {
    $opts = [Microsoft.CodeAnalysis.CSharp.CSharpParseOptions]::Default.WithLanguageVersion(
        [Microsoft.CodeAnalysis.CSharp.LanguageVersion]::Latest)
    $trees.Add([Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText(
        [IO.File]::ReadAllText($f.FullName), $opts, $f.FullName))
}

# Reference every managed assembly shipped with pwsh; the ones that are not
# metadata just throw and are skipped.
$refs = New-Object System.Collections.Generic.List[Microsoft.CodeAnalysis.MetadataReference]
foreach ($dll in Get-ChildItem '/opt/pwsh' -Filter *.dll -File) {
    try { $refs.Add([Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile($dll.FullName)) } catch { }
}

$copts = (New-Object Microsoft.CodeAnalysis.CSharp.CSharpCompilationOptions(
            [Microsoft.CodeAnalysis.OutputKind]::DynamicallyLinkedLibrary)
         ).WithOptimizationLevel([Microsoft.CodeAnalysis.OptimizationLevel]::Release)
$comp = [Microsoft.CodeAnalysis.CSharp.CSharpCompilation]::Create('Pester', $trees, $refs, $copts)

$fs = [IO.File]::Create("$out/Pester.dll")
try { $result = $comp.Emit($fs) } finally { $fs.Dispose() }
if (-not $result.Success) {
    $result.Diagnostics | Where-Object Severity -eq 'Error' | Select-Object -First 20
    throw 'compile failed'
}
```

**4. Assemble the module.** Run `build.ps1` *without* `-Clean` — the clean path is the
one that calls `dotnet`:

```bash
pwsh -NoProfile -File /tmp/pester/build.ps1
mkdir -p /tmp/pester/bin/bin/netstandard2.0
cp /tmp/pester/src/csharp/Pester/bin/Release/netstandard2.0/Pester.dll /tmp/pester/bin/bin/netstandard2.0/
cp -r /tmp/pester/src/schemas /tmp/pester/bin/
```

**5. Generate `PesterConfiguration.Format.ps1xml`.** The manifest lists it in
`FormatsToProcess`, so the import fails without it. Lift the generator out of the
`if ($Clean)` block in `build.ps1`; the only change needed is that the configuration type
lives in the global namespace, so it is `New-Object PesterConfiguration`, not
`Pester.PesterConfiguration`.

**6. Install where module discovery will find it:**

```bash
dest=~/.local/share/powershell/Modules/Pester/5.7.1
mkdir -p "$dest" && cp -r /tmp/pester/bin/. "$dest"/
pwsh -NoProfile -c 'Get-Module -ListAvailable Pester | Select-Object Name,Version'
```

## Caveat

The non-clean build produces a `.psm1` that dot-sources files from the clone, so the
clone must stay in place. The emitted assembly is version `0.0.0.0` rather than `5.7.1`,
which nothing in this repo's suite cares about. This is a throwaway build for running
tests, not something to distribute.
