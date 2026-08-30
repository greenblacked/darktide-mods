---
name: validate-change
description: How to actually verify a change to the darktide-mods PowerShell tooling - which gate runs where, why the Pester suite fails en masse off Windows, and how to read the CI verdict. Use this whenever you have edited any .ps1 in this repo, or the user says "run the tests", "check this works", "is this ready to push", or asks why the test suite is failing. Reach for it before reporting that tests pass or fail, because a naive run on Linux produces ~70 failures that mean nothing.
---

# Validating a change to this repo

The tools here are Windows-only by construction. That single fact drives everything
below, and it is the thing most likely to send you down a wrong path: a test run that
looks catastrophically broken is usually just a run on the wrong operating system.

## The three gates, in order

**1. `Test-Modpack.ps1` — runs anywhere, run it always.**

```powershell
pwsh -NoProfile -File ./Test-Modpack.ps1
```

Pure parsing and JSON, no execution of the tools themselves, so it works on Linux and
macOS as happily as on Windows. It AST-parses every `.ps1`, validates every `.json`,
checks the lockfile is internally consistent (`modCount` matches, no duplicate folders,
every load-order entry exists), and enforces the distribution rules — no committed mod
folders, no leaked API key, `config.json` untracked.

Exit 0 means clean. Two warnings are expected and are not failures: the ~39 mods with no
Nexus id, and PSScriptAnalyzer being absent if you have not installed it. The first of
those is permanent here — filling in those ids is what a Nexus API key would automate,
and this setup runs without one. Treat it as informational, not as a task.

**2. The Pester suite — Windows only.**

```powershell
.\Invoke-Tests.ps1                    # suite, then the validator
.\Invoke-Tests.ps1 -Path Deploy       # one file
.\Invoke-Tests.ps1 -Output Detailed   # per-test output
```

153 tests across 8 files, all sandboxed under `$env:TEMP` — they build a fake game
folder, a fake staging tree and real zip archives, and touch nothing real and nothing
networked. Safe to run at any time.

**3. CI on `windows-latest` — the actual verdict.**

`.github/workflows/ci.yml` runs on every push to every branch and every PR to `main`.
The `validate` job installs Pester and PSScriptAnalyzer, runs the suite with
`-SkipValidator`, then runs the validator separately. If you cannot run Pester locally,
pushing a branch and reading this job is the honest way to know whether a change works —
do that rather than reporting "tests pass" on the strength of the validator alone.

The `release` and `refresh-lock` jobs are `workflow_dispatch`-gated and will show as
skipped on a normal push. That is correct, not a failure.

## Why the suite explodes off Windows

Running Pester on Linux or macOS produces roughly 70 failures. Every one of them is
environmental. Recognising the three signatures saves you from chasing phantom bugs:

| Error | Cause |
|---|---|
| `The term 'robocopy.exe' is not recognized` | `Export-DarktideLoadout.ps1:183` shells out to robocopy |
| `Cannot bind argument to parameter 'Path' because it is null` | `$env:USERPROFILE` is null, so `Join-Path` fails (`Update-DarktideMods.ps1:166`, `Initialize-DarktideConfig.ps1:239`) |
| `Archive entry '...' resolves outside the mod folder` | the zip-slip guard compares `'\'`-separated paths (`Update-DarktideMods.ps1:737`) |

`Invoke-Tests.ps1` detects a non-Windows host and says so rather than letting you draw
the wrong conclusion, then falls back to the validator. `-AllowNonWindows` forces the
Pester run anyway, which is occasionally useful — `-Path Lock` and `-Path Update`, for
instance, contain assertions that are genuinely platform-independent and do pass.

Resist the temptation to "fix" these failures by making the tools cross-platform. The
backslash handling is deliberate, the target platform is Windows, and the tests assert
Windows semantics on purpose.

## Getting Pester when PSGallery is unreachable

Sandboxed environments frequently block `www.powershellgallery.com`, which makes
`Install-Module Pester` fail. There is a way through that does not need the gallery or a
dotnet SDK — see `references/pester-without-psgallery.md`. Only go there if the normal
install is actually blocked; it is a workaround, not the recommended path.

The normal path, when the gallery is reachable:

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
```

## Reporting the result

Say which gate ran and on what. "The validator passes; the Pester suite needs Windows so
I pushed the branch and CI is green" is a true and useful statement. "Tests pass" after
running only the validator is not — it skips 153 of the checks and hides exactly the
class of bug the suite exists to catch.

If CI is red, read the failing step's log before theorising. The suite names the failing
`Describe`/`Context`/`It` path, which maps directly onto a file in `tests/`.
