#!/usr/bin/env bash
# Make a Linux box able to run this repo's checks: PowerShell 7, then Pester 5.
#
# Why this exists: sandboxed sessions routinely have no pwsh and no reachable
# PowerShell Gallery, which makes `Install-Module Pester` fail. Working that out
# from first principles costs ~15 minutes every time. This does it in one command.
#
# Idempotent - re-running it detects what is already present and skips it.
#
# Usage:
#   ./setup-test-env.sh              # install what is missing, then report
#   ./setup-test-env.sh --check      # report only, change nothing
#
# Override install locations (used by the self-test):
#   PWSH_PREFIX=/opt/pwsh  PS_MODULE_DIR=~/.local/share/powershell/Modules
#
# Exit codes: 0 ready, 1 install failed, 2 bad usage, 3 --check found something missing.

set -euo pipefail

PWSH_VERSION="${PWSH_VERSION:-7.4.6}"
PESTER_VERSION="${PESTER_VERSION:-5.7.1}"
PWSH_PREFIX="${PWSH_PREFIX:-/opt/pwsh}"
PS_MODULE_DIR="${PS_MODULE_DIR:-$HOME/.local/share/powershell/Modules}"
PESTER_SRC="${PESTER_SRC:-/tmp/pester-src}"

CHECK_ONLY=0
case "${1:-}" in
    --check) CHECK_ONLY=1 ;;
    "")      ;;
    *)       echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
have_pwsh()   { command -v pwsh >/dev/null 2>&1 || [ -x "$PWSH_PREFIX/pwsh" ]; }
pwsh_bin()    { command -v pwsh >/dev/null 2>&1 && { command -v pwsh; return; }; echo "$PWSH_PREFIX/pwsh"; }
have_pester() { [ -f "$PS_MODULE_DIR/Pester/$PESTER_VERSION/Pester.psd1" ]; }

install_pwsh() {
    log "installing PowerShell $PWSH_VERSION into $PWSH_PREFIX"
    local url tarball
    url="https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/powershell-${PWSH_VERSION}-linux-x64.tar.gz"
    tarball="$(mktemp -t pwsh-XXXXXX.tar.gz)"
    trap 'rm -f "$tarball"' RETURN
    # --fail so an HTML error page is never mistaken for a tarball.
    curl -sSL --fail --max-time 300 -o "$tarball" "$url"
    mkdir -p "$PWSH_PREFIX"
    tar -xzf "$tarball" -C "$PWSH_PREFIX"
    chmod +x "$PWSH_PREFIX/pwsh"
    # Link into PATH only when nothing is there yet. Never clobber an existing pwsh:
    # a stale symlink to a prefix someone later deletes breaks the command globally,
    # which is a nasty way to lose an afternoon.
    if [ -w /usr/local/bin ] && [ ! -e /usr/local/bin/pwsh ]; then
        ln -s "$PWSH_PREFIX/pwsh" /usr/local/bin/pwsh
    fi
}

install_pester() {
    local pwsh; pwsh="$(pwsh_bin)"
    log "trying PSGallery first"
    if "$pwsh" -NoProfile -c "
            \$ErrorActionPreference='Stop'
            Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck
        " >/dev/null 2>&1; then
        log "installed from PSGallery"
        return 0
    fi

    log "PSGallery unreachable - building Pester $PESTER_VERSION from source"
    if [ ! -d "$PESTER_SRC/.git" ]; then
        rm -rf "$PESTER_SRC"
        git clone --depth 1 --branch "$PESTER_VERSION" https://github.com/pester/pester "$PESTER_SRC" >/dev/null 2>&1
    fi

    # Compile the C# with the Roslyn assemblies inside pwsh - there is no dotnet SDK.
    # Emit needs a FileStream: Emit(string) is not an overload in this Roslyn version.
    "$pwsh" -NoProfile -c "
        \$ErrorActionPreference='Stop'
        \$src = '$PESTER_SRC/src/csharp/Pester'
        \$out = \"\$src/bin/Release/netstandard2.0\"
        New-Item -ItemType Directory -Path \$out -Force | Out-Null
        Add-Type -Path '$PWSH_PREFIX/Microsoft.CodeAnalysis.dll'
        Add-Type -Path '$PWSH_PREFIX/Microsoft.CodeAnalysis.CSharp.dll'
        \$trees = New-Object System.Collections.Generic.List[Microsoft.CodeAnalysis.SyntaxTree]
        foreach (\$f in Get-ChildItem \$src -Recurse -Filter *.cs -File |
                        Where-Object { \$_.FullName -notmatch '/(obj|bin)/' }) {
            \$o = [Microsoft.CodeAnalysis.CSharp.CSharpParseOptions]::Default.WithLanguageVersion(
                    [Microsoft.CodeAnalysis.CSharp.LanguageVersion]::Latest)
            \$trees.Add([Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText(
                    [IO.File]::ReadAllText(\$f.FullName), \$o, \$f.FullName))
        }
        \$refs = New-Object System.Collections.Generic.List[Microsoft.CodeAnalysis.MetadataReference]
        foreach (\$d in Get-ChildItem '$PWSH_PREFIX' -Filter *.dll -File) {
            try { \$refs.Add([Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile(\$d.FullName)) } catch { }
        }
        \$opts = (New-Object Microsoft.CodeAnalysis.CSharp.CSharpCompilationOptions(
                    [Microsoft.CodeAnalysis.OutputKind]::DynamicallyLinkedLibrary)
                 ).WithOptimizationLevel([Microsoft.CodeAnalysis.OptimizationLevel]::Release)
        \$comp = [Microsoft.CodeAnalysis.CSharp.CSharpCompilation]::Create('Pester', \$trees, \$refs, \$opts)
        \$fs = [IO.File]::Create(\"\$out/Pester.dll\")
        try { \$r = \$comp.Emit(\$fs) } finally { \$fs.Dispose() }
        if (-not \$r.Success) {
            \$r.Diagnostics | Where-Object Severity -eq 'Error' | Select-Object -First 10 | ForEach-Object { Write-Host \$_ }
            throw 'Pester C# compile failed'
        }
    "

    # build.ps1 without -Clean assembles only the PowerShell files (the -Clean path shells to dotnet).
    "$pwsh" -NoProfile -File "$PESTER_SRC/build.ps1" >/dev/null
    mkdir -p "$PESTER_SRC/bin/bin/netstandard2.0"
    cp "$PESTER_SRC/src/csharp/Pester/bin/Release/netstandard2.0/Pester.dll" "$PESTER_SRC/bin/bin/netstandard2.0/"
    cp -r "$PESTER_SRC/src/schemas" "$PESTER_SRC/bin/"

    # The manifest lists PesterConfiguration.Format.ps1xml in FormatsToProcess, so the
    # import fails without it. This is build.ps1's generator, lifted out of its -Clean block.
    # The config type is global (PesterConfiguration), not Pester.PesterConfiguration.
    "$pwsh" -NoProfile -c "
        \$ErrorActionPreference='Stop'
        \$null = [Reflection.Assembly]::LoadFrom('$PESTER_SRC/bin/bin/netstandard2.0/Pester.dll')
        \$cfg = New-Object PesterConfiguration
        \$sections = \$cfg.GetType().Assembly.GetExportedTypes() |
                     Where-Object { \$_.BaseType -eq [Pester.ConfigurationSection] }
        \$ctor = [System.Management.Automation.FormatViewDefinition].GetConstructors('Instance,NonPublic')
        \$defs = foreach (\$s in \$sections) {
            \$b = [System.Management.Automation.ListControl]::Create().StartEntry()
            \$s.GetProperties() | Where-Object { \$_.PropertyType.IsSubclassOf([Pester.Option]) } |
                ForEach-Object { \$b.AddItemProperty(\$_.Name) > \$null }
            \$v = \$ctor.Invoke((\$s.FullName, \$b.EndEntry().EndList(), [guid]::NewGuid())) -as
                 [System.Collections.Generic.List[System.Management.Automation.FormatViewDefinition]]
            New-Object System.Management.Automation.ExtendedTypeDefinition \$s.FullName, \$v
        }
        \$b = [System.Management.Automation.TableControl]::Create().StartRowDefinition()
        [Pester.Option[bool]].GetProperties() | Where-Object Name -NotIn 'IsModified' |
            ForEach-Object { \$b.AddPropertyColumn(\$_.Name, [System.Management.Automation.Alignment]::Undefined, \$null) > \$null }
        \$v = \$ctor.Invoke(('Pester.Option', \$b.EndRowDefinition().EndTable(), [guid]::NewGuid())) -as
             [System.Collections.Generic.List[System.Management.Automation.FormatViewDefinition]]
        \$defs += New-Object System.Management.Automation.ExtendedTypeDefinition 'Pester.Option', \$v
        Export-FormatData -InputObject \$defs -Path '$PESTER_SRC/bin/PesterConfiguration.Format.ps1xml'
    "

    mkdir -p "$PS_MODULE_DIR/Pester/$PESTER_VERSION"
    cp -r "$PESTER_SRC/bin/." "$PS_MODULE_DIR/Pester/$PESTER_VERSION/"
    log "built and installed Pester $PESTER_VERSION"
    log "note: this build dot-sources from $PESTER_SRC - leave that directory in place"
}

# ---- main -------------------------------------------------------------------

missing=0
have_pwsh   || missing=1
have_pester || missing=1

if [ "$CHECK_ONLY" -eq 1 ]; then
    have_pwsh   && log "pwsh:   present" || log "pwsh:   MISSING"
    have_pester && log "Pester: present" || log "Pester: MISSING"
    [ "$missing" -eq 0 ] && exit 0 || exit 3
fi

if have_pwsh; then log "pwsh already present - skipping"; else install_pwsh; fi
if have_pester; then log "Pester already present - skipping"; else install_pester; fi

pwsh="$(pwsh_bin)"
log "verifying"
# Put our module dir first, and report the resolved path: without this the check
# can pass on some *other* Pester already on the default PSModulePath, which would
# make a broken install look fine.
"$pwsh" -NoProfile -c "
    \$env:PSModulePath = '$PS_MODULE_DIR' + [IO.Path]::PathSeparator + \$env:PSModulePath
    \$v = \$PSVersionTable.PSVersion
    \$p = Get-Module -ListAvailable Pester | Where-Object { \$_.Version.Major -ge 5 } |
         Sort-Object Version -Descending | Select-Object -First 1
    if (-not \$p) { throw 'Pester 5+ not discoverable after install' }
    Import-Module \$p.Path -Force -ErrorAction Stop
    if (-not (Get-Command Invoke-Pester -ErrorAction SilentlyContinue)) {
        throw 'Pester imported but Invoke-Pester is missing'
    }
    Write-Host \"PowerShell \$v, Pester \$(\$p.Version)\"
    Write-Host \"  module: \$(\$p.Path)\"
"
log "ready - now run: pwsh -NoProfile -File ./Test-Modpack.ps1"
log "(the Pester suite still needs Windows; see the skill for why)"
