---
name: tooling-invariants
description: The safety properties and house conventions that every change to the darktide-mods PowerShell tooling has to preserve - the game-folder guard, dry-run defaults, backup-before-mutate, zip-slip handling, secret handling, and the no-redistribution rule. Use this before editing or reviewing any .ps1 in this repo, when adding a verb or a parameter, or when the user asks whether a change is safe. These scripts delete and overwrite files inside someone's game install, so reach for this even for changes that look small.
---

# Invariants for the darktide-mods tooling

These scripts copy, replace and delete files inside a real game installation. A
regression here does not produce a failing test in someone's CI — it produces a broken
Darktide install and a lost mod loadout. The properties below are what stand between the
code and that outcome. Preserve them; if a change genuinely requires weakening one, say
so explicitly rather than letting it erode quietly.

## The architecture that makes recovery possible

Staging (`ModsRoot`) is the source of truth. The game's `mods/` folder is a **derived,
disposable mirror** of it, produced by `Deploy-DarktideMods.ps1`. Every design decision
follows from this: the game folder can always be rebuilt, so deploying is cheap and
losing it is survivable.

Keep that direction of flow. A change that makes the game folder authoritative — editing
mods in place, treating it as the thing to back up rather than the thing to regenerate —
removes the property that makes everything else recoverable.

## Guards that must run before writing to the game folder

**`Assert-ValidGamePath`** (`Deploy-DarktideMods.ps1:109`) refuses a path that does not
exist, is a drive root, is fewer than three path segments deep, or lacks a Darktide
marker file (`binaries\Darktide.exe`, `bundle\bundle_database.data`, and friends). This
is what prevents a mistyped `GamePath` in `config.json` from turning a recursive delete
loose on `C:\`. Any new code path that writes into the game folder goes through it.

**`Assert-GameNotRunning`** refuses to mutate while `Darktide.exe` holds file locks.
Note it currently exists twice, in `Deploy-DarktideMods.ps1` and
`Update-DarktideMods.ps1`, with wording that has already drifted. If you touch both,
consider consolidating rather than adding a third copy.

## Destructive operations are opt-in

`Deploy-DarktideMods.ps1`, `Import-DarktideLoadout.ps1` and `Install-DarktideLoader.ps1`
all do nothing until given `-Apply`; without it they print what they would do and exit.
`Deploy-DarktideMods.ps1` additionally declares
`[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]` and gates each
mutation behind `$PSCmdlet.ShouldProcess(...)`.

New destructive work belongs inside those gates. The pattern to follow: compute the
whole plan, print it, then act only under `-Apply` and only inside a `ShouldProcess`
block — which also means `-WhatIf` keeps working for free.

## Back up before replacing, and bound the backups

Mod folders are zipped to a backup root before being replaced (`New-ModBackup`,
`Update-DarktideMods.ps1:812`; the deploy-side equivalent around
`Deploy-DarktideMods.ps1:284`). Retention is bounded by `-KeepBackups` (default 10) so
repeated deploys cannot silently fill a disk.

If you add a new operation that replaces user data, it needs the same two halves: a
backup, and a bound on how many backups accumulate.

## Archive extraction: normalise, then check, then re-verify

`Expand-ModArchive` (`Update-DarktideMods.ps1:730`) is the zip-slip guard, and the order
of its steps is load-bearing:

1. Replace `\` with `/` **first** — zip entries may legally use either, and a
   backslash-only traversal walks straight past a forward-slash-only pattern.
2. Reject `..` segments and absolute paths (`^([A-Za-z]:|/)`).
3. Resolve the target with `GetFullPath` and confirm it still sits under the
   destination root.

Step 3 is not redundant with step 2 — it is what catches whatever the pattern missed.
The suite covers all three (`tests/Update.Tests.ps1`), including the case where a hostile
archive must be rejected *without* destroying the mod it was meant to replace.

## Offline is the operating mode

This setup runs without a Nexus API key, and the tooling is built for that. When no key
is present, `Update-DarktideMods.ps1:1173` falls back to offline mode automatically, and
the dispatcher's everyday verbs never ask for one in the first place — `darktide.ps1`
passes `-NoApi` unconditionally for `update` (line 212) and `sync` (line 226).

What still works with no key: installing archives you downloaded yourself from Nexus,
version comparison from the archive filename, load-order maintenance, deploy, rollback,
export/import, loader install, and lockfile generation (versions come from
`.nexus-mod.json` or the author's `info.json`).

What a key would add, and which is therefore simply absent: the `check` verb telling you
what is newer on Nexus, automatic mod-id resolution into `mods-map.json`, and the CI
`refresh-lock` job, which needs a `NEXUS_API_KEY` repository secret and will fail without
one. That job is `workflow_dispatch`-only, so it never runs on a push and its absence
costs nothing day to day.

The invariant that matters here: **do not let the API become required**. Every code path
must keep working, or degrade with a clear message, when `$cfg.ApiKey` is empty. Offline
is the tested default, not a fallback nobody exercises — `tests/OfflineUpdate.Tests.ps1`
covers it directly.

If a key is ever introduced, it goes in the `NEXUS_API_KEY` environment variable
(`Update-DarktideMods.ps1:199`) and is never logged; `darktide.ps1:144` prints only
whether one is set. Avoid the two existing weak spots rather than extending them:
`-ApiKey` as a command-line parameter (`Update-DarktideMods.ps1:82`) leaks into process
listings and shell history, and `Initialize-DarktideConfig.ps1` will persist a key into
`config.json` in plaintext.

## Never redistribute mod content

The lockfile is a **manifest** — folder names, versions, load order, Nexus links. Mod
files belong to their authors and are not this repo's to ship. Three independent
mechanisms enforce this and all three should stay: `.gitignore` excludes `mods/`,
`*.mod` and loadout zips; `Test-Modpack.ps1` fails if mod folders or an API key are
committed; and the CI release job packages from an explicit allow-list, then re-scans the
staged output and refuses to publish if anything mod-shaped survived.

## Windows-only is a decision, not an oversight

`robocopy`, the Steam registry keys, `$env:USERPROFILE`, `'\'`-separated paths — these
are deliberate. Do not opportunistically "port" them; the tests assert Windows semantics
and the target platform is Windows. See the `validate-change` skill for what this means
when running the suite.

The one place cross-platform correctness does matter is `Test-Modpack.ps1`, which is
meant to run anywhere. Its `dist|out|node_modules` and `.git` exclusion regexes accept
either separator (`[\\/]`) for exactly that reason — they were backslash-only once, which
silently made them no-ops on Linux and macOS. Keep any new path pattern in that file
separator-agnostic; the rest of the codebase is free to assume `\`.

## House style

Every script opens with `Set-StrictMode -Version Latest` and
`$ErrorActionPreference = 'Stop'` — all ten do, without exception. New scripts follow.

- Parameters are PascalCase. Switches that permit something otherwise refused use an
  `Allow*` prefix (`-AllowFailure`, `-AllowNonWindows`); ones that omit work use `Skip*`
  or `No*`. `-Force` consistently means "overwrite something that already exists" — do
  not reuse it for anything else.
- Locals are camelCase (`$modsRoot`, `$loadOrder`); script-scope state is
  `$script:PascalCase`.
- Prefer `-LiteralPath` over `-Path` for filesystem calls. Mod folder names contain
  brackets and other glob metacharacters, and `-Path` will silently do the wrong thing.
- Failures are surfaced, not swallowed. There are three bare `catch { }` blocks in
  `Update-DarktideMods.ps1` (lines 107, 252, 282) and they are deliberate, narrow
  exceptions — not a pattern to copy.
- Network calls carry an explicit timeout. There is exactly one in the codebase
  (`Invoke-WebRequest ... -TimeoutSec 45`, line 276); any new one needs the same.

## Where things live

| File | Role |
|---|---|
| `darktide.ps1` | Verb dispatcher (`init`, `status`, `check`, `update`, `deploy`, `sync`, `rollback`, `restore`, `lock`, `export`, `loader`, `import`) |
| `Update-DarktideMods.ps1` | Nexus client, version compare, archive install, rollback. 1,425 lines — the one file that has outgrown its shape |
| `Deploy-DarktideMods.ps1` | Staging → game folder mirror, backups, loader patching |
| `Install-DarktideLoader.ps1` | Darktide Mod Loader install/update, `--patch`/`--unpatch` |
| `Export-/Import-DarktideLoadout.ps1` | Portable loadout archive |
| `New-ModpackLock.ps1` | Generates the lockfile manifest |
| `Test-Modpack.ps1` | Repository validator (cross-platform) |
