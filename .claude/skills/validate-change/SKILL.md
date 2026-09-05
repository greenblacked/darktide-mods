---
name: validate-change
description: How to actually verify a change to the darktide-mods PowerShell tooling - which gate runs where, why the Pester suite fails en masse off Windows, and how to read the CI verdict. Use this whenever you have edited any .ps1 in this repo, or the user says "run the tests", "check this works", "is this ready to push", or asks why the test suite is failing. Reach for it before reporting that tests pass or fail, because a naive run on Linux produces ~70 failures that mean nothing.
---

# Validating a change to this repo

The tools here are Windows-only by construction. That single fact drives everything
below, and it is the thing most likely to send you down a wrong path: a test run that
looks catastrophically broken is usually just a run on the wrong operating system.

## The gates, in order

**1. `Test-Modpack.ps1` — runs anywhere, run it always.**

```powershell
pwsh -NoProfile -File ./Test-Modpack.ps1
```

Pure parsing and JSON, no execution of the tools themselves, so it works on Linux and
macOS as happily as on Windows. It AST-parses every `.ps1`, validates every `.json`,
checks the lockfile is internally consistent (`modCount` matches, no duplicate folders,
every load-order entry exists), and enforces the distribution rules: no committed mod
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

Roughly 250 tests across 13 files (250 as this was written, counted from the windows-latest job), all sandboxed under
`$env:TEMP`. They build a fake game folder, a fake staging tree and real zip archives,
and touch nothing real and nothing networked. Safe to run at any time.

Its exit codes are the thing to read, not the last line of output:

| Code | Meaning |
|---|---|
| 0 | every check asked for ran and passed |
| 1 | something ran and failed |
| 3 | nothing failed, but the Pester suite was skipped because this is not Windows |

**3 is not success.** It means the change is unverified — the validator passed and the
suite never executed. Off Windows that is the code you get by default, which is the
point: a script or a habit that treats 0-or-nothing as "green" cannot mistake it for a
passing suite.

**3. CI — the actual verdict, across three engines.**

`.github/workflows/ci.yml` runs on every push to every branch and every PR to `main`.
The `validate` job installs Pester and PSScriptAnalyzer, runs the suite with
`-SkipValidator`, then runs the validator separately. If you cannot run Pester locally,
pushing a branch and reading this job is the honest way to know whether a change works —
do that rather than reporting "tests pass" on the strength of the validator alone.

A macOS job runs the validator and the same exit-code contract on `macos-latest`.
Everything in this repo that mentions macOS - the README, `CLAUDE.md`, this skill,
`Invoke-Tests.ps1`'s own help - had never been executed on a Mac; the Linux job was
standing in for both. macOS runners are also arm64, which is the one place the two
platforms genuinely differ: `setup-test-env.sh` hardcoded a `linux-x64` download
until that job existed, so a Mac following this skill installed a binary it could
not run.

A second Windows job runs the same suite under **Windows PowerShell 5.1**, the engine
that ships with Windows and the one a user who has installed nothing will reach for
first. `Invoke-Tests.ps1` branches on `$PSVersionTable.PSEdition -eq 'Desktop'` and
nothing had ever taken that branch. It pays for itself: the validator was splitting on
`` `u{001e} ``, an escape PowerShell 7 added and 5.1 parses as a literal, so a check
was quietly reading the wrong thing. If you add syntax to a script that runs anywhere,
this is the job that will tell you it is 7-only.

**Never `2>&1` a native command.** Under 5.1 with `$ErrorActionPreference = 'Stop'`,
merging a native stderr into the success stream turns it into a *terminating error* even
when the command exited 0. pwsh 7 does not, so this is invisible everywhere else. The
scripts already handle it by setting the preference to `Continue` around the call
(`Test-Modpack.ps1`, `Install-DarktideLoader.ps1`); do the same, or redirect to `$null`
and read `$LASTEXITCODE`. A test file missed this and only failed on a `pull_request`
run, because that checkout is a detached merge ref and `git clone` then prints the
detached-HEAD advice to stderr — `git -c advice.detachedHead=false` removes the trigger
at source. The same commit was green on the push event, so if a job passes on one event
and fails on the other, look here before assuming a flake.

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
Pester run anyway, which is occasionally useful. Four suites hold up off Windows:
`Lock`, `Attribution`, `Package` and `FindUpdates`. None of them builds a game folder or
resolves a `\`-separated archive entry, so a failure in one of them is a real failure
rather than the platform, which is why the CI Linux and macOS jobs assert `-Path Lock`
specifically. Everything else in the suite is Windows-only and its Linux result means
nothing either way.

Do not build anything on the off-Windows result of `-Path Update`: its two
`Expand-ModArchive` traversal tests flake there, passing in some runs and failing in
others (observed 20-22 failures across four identical runs of the same commit). The cause
is the guard comparing `'\'`-terminated paths against POSIX ones, so the outcome depends
on the entry names rather than on anything meaningful. It has never flaked on
`windows-latest`, which is the platform it is written for. If you need a stable local
signal off Windows, use `-Path Lock` or the validator.

Resist the temptation to "fix" these failures by making the tools cross-platform. The
backslash handling is deliberate, the target platform is Windows, and the tests assert
Windows semantics on purpose.

## Setting up a machine that cannot run any of this yet

On a fresh Linux box there is usually no `pwsh` at all, and `www.powershellgallery.com`
is often blocked, so `Install-Module Pester` fails too. Rather than rediscover that each
time, run:

```bash
.claude/skills/validate-change/scripts/setup-test-env.sh          # install what is missing
.claude/skills/validate-change/scripts/setup-test-env.sh --check  # report only
```

It installs PowerShell 7, tries PSGallery first, and falls back to building Pester 5 from
source using the Roslyn assemblies inside pwsh (there is no dotnet SDK in these
environments). It is idempotent, so re-running it is safe and cheap. Exit codes: 0 ready,
1 install failed, 2 bad usage, 3 `--check` found something missing.

It picks its download from `uname`, so it works on Linux and macOS and on x64 and arm64.
`--rid` prints the build it would fetch, which is how CI asserts it without parsing the
script - both platform jobs check they get their own.
On macOS `/opt` is not writable without `sudo`, so pass a prefix you own:

```bash
PWSH_PREFIX="$HOME/.local/pwsh" .claude/skills/validate-change/scripts/setup-test-env.sh
```

`references/pester-without-psgallery.md` explains what the script does step by step and
why each step is needed — read it if the script fails or you need to adapt it, not
otherwise.

The normal path, when the gallery is reachable:

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
```

## Reporting the result

Say which gate ran and on what. "The validator passes; the Pester suite needs Windows so
I pushed the branch and CI is green" is a true and useful statement. "Tests pass" after
running only the validator is not. It skips the whole suite, which is the part that
would catch the class of bug the validator cannot see.

## Linux Docker, matching the ubuntu job

When you are not on Windows, the local command that matches the CI `cross-platform`
job is:

```bash
./run-tests-docker.sh
```

It builds `Dockerfile.test` and, in a Linux PowerShell container, runs:

1. `Test-Modpack.ps1` (including the twin-body and allow-list checks)
2. `Invoke-Tests.ps1` — expect exit **3**
3. `Invoke-Tests.ps1 -SkipValidator` — expect exit **3**
4. `Invoke-Tests.ps1 -AllowNonWindows -Path Lock -SkipValidator` — expect exit **0**

Exit 2 means docker is not on PATH. `./run-tests-docker.sh full` is the explicit
"expect ~70 environmental failures" mode. Do not treat it as a pass/fail gate, and
do not report "tests pass" from a Docker run or from `Invoke-Tests.ps1` exit 3.

If CI is red, read the failing step's log before theorising. The suite names the failing
`Describe`/`Context`/`It` path, which maps directly onto a file in `tests/`.
