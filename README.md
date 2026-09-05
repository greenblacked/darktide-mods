# darktide-mods

[![CI](https://github.com/greenblacked/darktide-mods/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/greenblacked/darktide-mods/actions/workflows/ci.yml)
[![Tests](https://img.shields.io/badge/tests-250%20passing-brightgreen)](tests/)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-5391FE)](https://learn.microsoft.com/powershell/)
[![License: MIT](https://img.shields.io/badge/licence-MIT-blue)](LICENSE)

Mod management for **Warhammer 40,000: Darktide** — update, verify, and deploy a Darktide Mod
Framework loadout from PowerShell, with backups and a one-command rollback at every step.

> **This repository contains no mods.** It ships tooling and a *manifest*
> (`darktide-modpack.lock.json`) that records which mods a loadout uses and links to each
> author's page. You download the mods yourself, from the authors, on Nexus. See
> [Why a manifest](#why-a-manifest-and-not-the-mods).

**First week:** [docs/first-week.md](docs/first-week.md) — init, loader, sync, undo, offline.

---

## Why

Two things make modded Darktide annoying:

1. **Every game patch breaks it.** Fatshark replaces the bundle database, the mod loader
   stops working, and half your mods need new versions.
2. **Updating by hand is error-prone.** Unzip into the wrong folder, forget a
   `mod_load_order.txt` entry, and the game fails on startup with no useful message.

This does the mechanical parts and keeps a backup of everything it touches.

## How it works

```
   Nexus Mods                    staging                      game
   (you download)                D:\Darktide\mods             ...\Warhammer 40,000 DARKTIDE\mods
        |                              |                              |
        |  darktide.ps1 update         |  darktide.ps1 deploy         |
        +----------------------------->+----------------------------->+
                 backup + verify              backup + verify
```

Staging is where updates land and get checked. The game folder only ever receives a set that
already installed cleanly. Both stages back up before they write, and both have a restore verb.

---

## First-time setup, step by step

**Requires:** Windows PowerShell 5.1 (built in) or PowerShell 7+. No modules, no dependencies
for normal use. (The test suite needs Pester — see [Testing](#testing).)

### 1. Get the tooling

```powershell
git clone https://github.com/greenblacked/darktide-mods.git
cd darktide-mods
```

### 2. Allow the scripts to run

Windows blocks scripts downloaded from the internet. Both of these are per-user and reversible:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
Get-ChildItem *.ps1 | Unblock-File
```

If your workplace policy forbids changing the execution policy, run each command with an
explicit bypass instead: `powershell -ExecutionPolicy Bypass -File .\darktide.ps1 status`.

### 3. Let it find your game

```powershell
.\darktide.ps1 init
```

This works out where Darktide is installed instead of asking you. It reads Steam's install
path from the registry, walks **every** Steam library in `libraryfolders.vdf` (games are
often on a different drive from Steam itself), reads Darktide's own Steam app manifest
(`appmanifest_1361210.acf`) for the exact folder name, and verifies each candidate by
looking for real game files before writing anything.

```
Looking for Darktide...
  found: D:\Games\Steam\steamapps\common\Warhammer 40,000 DARKTIDE   [Steam app manifest]
Game folder: D:\Games\Steam\steamapps\common\Warhammer 40,000 DARKTIDE
Staging   : D:\Darktide\mods
Downloads : C:\Users\you\Downloads
Wrote config.json
```

It never overwrites an existing `config.json` without `-Force`. If the game isn't found —
a non-Steam copy, say — point at it directly:

```powershell
.\darktide.ps1 init -GamePath 'D:\Games\...\Warhammer 40,000 DARKTIDE'
```

<details>
<summary>Or write the config by hand</summary>

```powershell
Copy-Item config.example.json config.json
notepad config.json
```

</details>

| Key | What to put in it |
|---|---|
| `ModsRoot` | Your **staging** mods folder, e.g. `D:\Darktide\mods`. Not the game's. |
| `GamePath` | The game install root, e.g. `D:\Games\Steam\steamapps\common\Warhammer 40,000 DARKTIDE`. |
| `DownloadDir` | Where your browser saves Nexus archives, e.g. `C:\Users\you\Downloads`. |
| `LoaderSource` | Unzipped Darktide Mod Loader folder or its `.zip`. `init` fills this in if it finds one. |
| `BackupRoot` | Staging backups. Leave blank for `<parent of ModsRoot>\mod_backups`. |
| `DeployBackupRoot` | Game-folder backups. Leave blank for `<parent of ModsRoot>\deploy_backups`. |
| `ApiKey` | Do not set. `init` will not write this field. Use the `NEXUS_API_KEY` environment variable — see [Checking versions locally](#checking-versions-locally-step-by-step). |

`config.json` is gitignored and never leaves your machine. Use `\\` in JSON paths.

> **Don't have a staging folder yet?** Copy your existing game mods folder to it once:
> `Copy-Item '<GamePath>\mods' 'D:\Darktide\mods' -Recurse`. From then on you edit staging
> and deploy from it, never the game folder directly.

### 4. Install the mod loader

Without it, DMF mods do not load at all. It is a separate download that puts files into the
game folder and patches the bundle database:

```powershell
.\darktide.ps1 loader             # dry run - shows the version it would install
.\darktide.ps1 loader -Apply
```

Get it from
[nexusmods.com/warhammer40kdarktide/mods/19](https://www.nexusmods.com/warhammer40kdarktide/mods/19)
into your `DownloadDir` — `loader` picks up either the `.zip` or an unzipped folder on its
own. Point at one explicitly with `-Source '<path>'`.

It records the installed version in `<game>\.darktide-loader.json`, so re-running when
nothing has changed does nothing at all. See [The mod loader](#the-mod-loader).

### 5. Check it found everything

```powershell
.\darktide.ps1 status
```

`status` writes nothing at all. Expect something like:

```
== Configuration
  staging mods : D:\Darktide\mods
  game folder  : D:\Games\Steam\steamapps\common\Warhammer 40,000 DARKTIDE
  api key      : not set (offline mode)

== Staging
  mod folders        : 45
  version-tracked    : 0
  with author info   : 6

== Game folder
  deployed mods : 45
  staging and game are in sync
  mod loader present
```

`version-tracked: 0` on a first run is normal — nothing has been installed *by this tool* yet,
so no versions are recorded. The first `update -Apply` starts tracking each mod it installs.

If you see `game folder not found` or `no mods\ folder`, fix `GamePath` before going further:
the deploy step refuses to write to anything that doesn't look like a Darktide install, so a
wrong path fails loudly rather than scattering files.

---

## Everyday use, step by step

### 1. Download the mods you want

Get them from each mod's Nexus page into your `DownloadDir`. **Keep the default filenames** —
`Markers Improved All-in-one-447-2-14-4-1719209900.zip` encodes the mod id (`447`) and the
version (`2.14.4`), and that's how the tool identifies an archive without an API key.

Renamed a file? The version inside the archive's `info.json` is used instead. If neither is
available the archive is reported as `VERSION-UNKNOWN` and skipped rather than guessed at —
install it with `-Force -Only <folder>` if you're sure.

### 2. Close the game

`-Apply` refuses to write while `Darktide.exe` is open, since replacing a loaded mod file
gives you a half-updated game. Dry runs are fine with the game running — plan first, close,
then apply.

### 3. Dry run first

```powershell
.\darktide.ps1 sync
```

Nothing is written. You get the full plan: which archives were matched to which mod folders,
which are newer than what's installed, and what the deploy would copy. Read it before applying.

### 4. Apply

```powershell
.\darktide.ps1 sync -Apply
```

In order, this:

1. installs every newer archive into **staging**, backing up each mod folder it replaces;
2. adds any brand-new mod to `mod_load_order.txt`;
3. backs up the live game `mods\` folder to a zip;
4. syncs staging into the game folder;
5. re-checks that every load-order entry resolves to a real folder;
6. refreshes `darktide-modpack.lock.json`.

If the update step fails, deploy does not run. If deploy finishes with problems, the
lockfile is not refreshed. Either way the exit code is non-zero.

Everything is a dry run until `-Apply`, except `lock`, which always rewrites the
manifest. `status` and `check` never write. Running it again when nothing has changed doesnothing at all — see [Re-running is safe](#re-running-is-safe).

### 5. Start the game and confirm

If the game crashes on load, you have two undo paths and neither needs a re-download:

```powershell
.\darktide.ps1 restore -Apply     # newest game-folder backup (undoes the deploy)
.\darktide.ps1 rollback -Apply    # undoes the last staging install
.\darktide.ps1 deploy -Apply      # ...then push the rolled-back staging out
```

### Verbs

| Verb | What it does |
|---|---|
| `init` | Find your Darktide install automatically and write `config.json`. |
| `loader` | Install or update the Darktide Mod Loader and patch the bundle. |
| `status` | Staged vs deployed, drift, loader state, backup sets. Read-only. |
| `check` | Ask Nexus what's outdated. Needs an API key. Read-only. |
| `links` | Where to look when you have no key: the Nexus page for every mod, plus the latest GitHub release tag for any mod mapped to a repository. Read-only. |
| `update` | Install newer archives from your download folder into staging. |
| `deploy` | Push staging into the game folder. |
| `sync` | `update` then `deploy`, then refresh the lockfile. Stops if a step fails. |
| `rollback` | Undo the last staging install. Dry run until `-Apply`. |
| `restore` | Undo the last deploy to the game folder. Dry run until `-Apply`. |
| `lock` | Regenerate `darktide-modpack.lock.json` from what's installed. |
| `lock -SyncIdsFromMap` | Copy non-null Nexus ids (and urls) from `mods-map.json` into the existing lockfile. No `ModsRoot` needed; versions and hashes stay put. |
| `export` | Zip your whole loadout into one file, as a personal backup. |
| `import` | Restore a loadout zip into staging and deploy it, in one step. |

### Useful switches

```powershell
.\darktide.ps1 update -Apply -Only markers_aio,scoreboard   # scope to specific mods
.\darktide.ps1 deploy -Apply -Mirror                        # also delete mods no longer staged
.\darktide.ps1 deploy -Apply -InstallLoader               # fresh install / after a game patch
# -InstallLoader calls Install-DarktideLoader.ps1 (copy + dtkit-patch). Do not also pass
# -RunToggle on that run: the toggle bat flips state and would undo the patch.
.\darktide.ps1 deploy -Apply -RunToggle                   # re-patch only, loader already present
.\darktide.ps1 update -Apply -Force -Only NumericUI         # reinstall or downgrade one mod
.\darktide.ps1 lock -SyncIdsFromMap                        # push mods-map ids into the lockfile
.\darktide.ps1 links -OutFile updates.md                   # the check-by-hand list, as markdown
.\darktide.ps1 links -CheckGitHub                          # ...and ask GitHub for release tags
```

---

## The mod loader

The [Darktide Mod Loader](https://www.nexusmods.com/warhammer40kdarktide/mods/19) is what
makes DMF mods load. It isn't a normal mod — it writes into the game folder itself and
patches the bundle database — so it has its own verb rather than going through staging.

```powershell
.\darktide.ps1 loader             # what is installed vs what you have downloaded
.\darktide.ps1 loader -Apply      # install or update, then patch
.\darktide.ps1 loader -Apply -Force   # reinstall the same version
```

What it puts where:

| From the loader download | Goes to |
|---|---|
| `binaries\mod_loader` | game folder |
| `bundle\<hash>.patch_999` | game folder — the mod entry bundle |
| `tools\dtkit-patch.exe` | game folder |
| `toggle_darktide_mods.bat` | game folder |
| `mods\base\` | **staging**, so a normal `deploy` carries it |

Your `mod_load_order.txt` is never overwritten — the loader ships its own, and replacing
yours would wipe your mod list.

**Updating follows the loader's own instructions:** unpatch the bundle database, copy the new
files, re-patch. The previous loader is zipped to `loader_backups\` first.

> **Never run `toggle_darktide_mods.bat` twice.** It *toggles*: once patches, twice unpatches
> and every mod silently stops loading. This tooling always calls `dtkit-patch` with an
> explicit `--patch` / `--unpatch`, so re-running `loader -Apply` can't flip you off.

The installed version is recorded in `<game>\.darktide-loader.json` and shown by `status`.
Re-running with the same version does nothing and doesn't touch the bundle at all.

---

## Moving your loadout to another machine

Two commands on the old machine, two on the new one. Nothing is moved by hand, and the game
folder is found for you.

**On the machine that has the loadout:**

```powershell
.\darktide.ps1 sync -Apply           # make sure staging holds the newest versions
.\darktide.ps1 export -Apply         # -> D:\Darktide\darktide-loadout-<date>.zip
```

Copy that one zip to the new machine (USB, network share, your own cloud storage).

**On the new machine:**

```powershell
git clone https://github.com/greenblacked/darktide-mods.git
cd darktide-mods
Get-ChildItem *.ps1 | Unblock-File

.\darktide.ps1 init                                      # finds the game by itself
.\darktide.ps1 import -Path 'E:\darktide-loadout-20260829.zip' -Apply
```

`import` unpacks into staging and deploys to the game folder in the same run — you never
move a folder yourself. It extracts to a temporary directory first and refuses any archive
entry that tries to escape the destination, so a tampered zip can't write outside your mods
folder. Add `-Mirror` to also remove mods on the target that aren't in the archive.

Check it with `.\darktide.ps1 status`, then launch the game.

> **Why an archive, and not "download all the mods automatically"?**
> A Nexus **free** account cannot get download links from the API — `download_link.json`
> returns HTTP 403, premium only — and scraping the site would breach their terms. So no tool
> can legitimately fetch 45 mods for you on a free account, and this repo can't ship the mod
> files either: they're their authors' work to distribute. Your own export zip is the way to
> get a one-command restore, and it's the only part that has to travel with you.
>
> With Nexus Premium you'd still download in the browser here; what an API key buys you is
> `check` telling you *which* mods are outdated. See [Checking versions locally](#checking-versions-locally-step-by-step).

---

## Re-running is safe

Every verb is idempotent: running it twice does the same thing as running it once.

- `deploy` compares staging against the game folder first (`robocopy /L`). With nothing to
  copy it takes **no backup** and writes **nothing** — it says `Already in sync` and stops.
  `-Force` overrides that when you want a redeploy anyway.
- `update` records the installed version in each mod's `.nexus-mod.json`, so an archive you
  have already installed comes back as `SAME` and is skipped. `-Force` reinstalls.
- `mod_load_order.txt` is only ever appended to, and never with a name already in it.
- `loader` compares the version you have against `<game>\.darktide-loader.json` and stops if
  they match — it doesn't even touch the bundle database, so it can't toggle your mods off.
- Staging, deploy, and loader backups are each pruned to the newest `-KeepBackups`
  archives (default 10), so repeated runs cannot fill the disk.

---

## Checking versions locally, step by step

Without an API key the tool does not talk to Nexus. It compares zips already sitting in
`DownloadDir` against the versions recorded in staging. That is enough to decide what to
install. `check` is the command that queries Nexus, and it is unused here.

Installs always come from your `DownloadDir`. This tooling has no Nexus auto-download path,
premium or otherwise — free accounts get HTTP 403 on `/download_link.json`, and scraping
would breach their terms, so the browser click stays yours either way.

### 1. Keep the default Nexus filenames

A stock download looks like
`Markers Improved All-in-one-447-2-14-4-1719209900.zip`. The `447` is the Nexus id and
`2-14-4` is version `2.14.4`. That is how `update` identifies an archive with no key.

If you renamed the file, the version inside the zip's `info.json` is used instead. If
neither is present the archive is reported as `VERSION-UNKNOWN` and skipped — it is not
guessed at.

### 2. Close the game

`update` and `deploy` refuse to run while `Darktide.exe` is open.

### 3. Dry-run first

```powershell
.\darktide.ps1 update
```

Nothing is written. Each archive is matched to a folder and compared to the version in
that folder's `.nexus-mod.json` (created the first time this tool installed the mod).

```powershell
.\darktide.ps1 update -Verbose
.\darktide.ps1 sync
```

`sync` is the same comparison plus what deploy would copy. Read the plan before `-Apply`.

### 4. Read the statuses

| Status | Meaning |
|---|---|
| `NEWER` | The zip is newer than staging. This is the one you apply. |
| `SAME` | Already installed. Skipped. |
| `OLDER` | The zip is older than staging. Skipped, so a leftover download cannot downgrade you. |
| `NO-ARCHIVE` | That folder has no matching zip in `DownloadDir`. Not an error. |
| `VERSION-UNKNOWN` | Renamed zip and no `info.json`. Skipped. |

A first run often shows `version-tracked: 0` in `status`. Nothing has been installed *by
this tool* yet, so there is no recorded version to compare. The first `update -Apply`
starts tracking.

### 5. Apply only what is newer

```powershell
.\darktide.ps1 update -Apply
.\darktide.ps1 sync -Apply
```

`update -Apply` installs into staging. `sync -Apply` does that and then deploys.

One folder only:

```powershell
.\darktide.ps1 update -Apply -Only dmf
.\darktide.ps1 update -Apply -Force -Only NumericUI
```

`-Force` is the deliberate reinstall or downgrade. Without it, older zips stay skipped.

### 6. When you want to look on Nexus yourself

Local check cannot see a version you never downloaded. `links` turns the lockfile into
the list of pages to open, so checking by hand is 45 links rather than 45 searches:

```powershell
.\darktide.ps1 links                        # print the list
.\darktide.ps1 links -OutFile updates.md    # ...and keep it as markdown
```

It touches nothing and needs no key. Each row is the version this tool last installed
and the author's page. Open the page, download if Nexus shows newer, leave the filename
alone, run `update` again. A mod with no `modId` in the lockfile says so rather than
getting a guessed link.

#### The one upstream that answers with no key at all

Some mods are also published on GitHub, and the release endpoint there is public. Put
the repository on the mod's `mods-map.json` entry:

```json
"some_mod": { "modId": 447, "githubRepo": "author/some-mod" }
```

and `links -CheckGitHub` will fetch the latest release tag for it:

```powershell
.\darktide.ps1 links -CheckGitHub
```

Nothing is populated out of the box — a wrong repository is worse than no repository,
and only you can confirm that a given mod's GitHub project is really the same thing as
its Nexus page. Add them as you verify them.

The status column says `same` or `differs`, never “newer”. A GitHub tag and a Nexus
version string are not guaranteed to share a scheme for the same mod — the tag may be
`v2.15.0` where Nexus says `2.15`, or the release may lag the Nexus upload entirely —
so it shows you both and you decide. Unauthenticated GitHub allows 60 requests an hour
per address; set `GITHUB_TOKEN` in the environment to raise that. Like `NEXUS_API_KEY`
it is read from the environment only, never a parameter.

This still does not download anything. Nothing in this repository can — see the note on
`/download_link.json` above.

After a game patch the same local path applies: get the new loader and DMF zips first,
then:

```powershell
.\darktide.ps1 loader -Apply -Force
.\darktide.ps1 update -Apply -Only dmf
.\darktide.ps1 sync -Apply
```

### Optional: ask Nexus from the command line

A key only adds `check` — “Nexus has a file you do not have yet.” A free account still
cannot fetch the file through the API (`/download_link.json` returns 403). You click
either way.

Do not put a key in `config.json` (`init` will not write one). If you do generate a key, put it in the
environment:

```powershell
# https://www.nexusmods.com/users/myaccount?tab=api
[Environment]::SetEnvironmentVariable('NEXUS_API_KEY', '<your-key>', 'User')
# new PowerShell window, then:
.\darktide.ps1 check
```

`mods-map.json` maps folder names to Nexus ids. Mods that ship `info.json` are mapped
on install; the rest need the number from the mod URL pasted in. Set `"pinned": true`
on anything `update` should leave alone.

After editing the map, push those ids into the lockfile without regenerating it:

```powershell
.\darktide.ps1 lock -SyncIdsFromMap
# or:
.\New-ModpackLock.ps1 -SyncIdsFromMap
```

That copies only non-null `modId` values (and the matching Nexus `url`). Folders the
map still leaves at `null` stay untouched. Versions, `versionSource`, content hashes,
load order, and entry count are not rewritten — `refresh-lock` owns fetching versions
from Nexus. A lock entry with a `modId` and a null `version` is valid; `check` /
`update` read versions from the installed mod folders, not from the lockfile, and treat
a missing local version as `UNKNOWN-LOCAL` rather than inventing one.

```powershell
.\Update-DarktideMods.ps1 -BuildCatalog   # needs a key; crawls the Nexus list
.\Update-DarktideMods.ps1 -Resolve
```

`-BuildCatalog` and `-Resolve` are unused on a no-key setup. Paste ids by hand if a
folder is unmapped.

---

## After a Darktide patch

The order matters:

```powershell
# 1. Re-apply the mod loader's bundle patch (Steam replaced it)
.\darktide.ps1 loader -Apply -Force

# 2. Update the framework first - most mods depend on it
.\darktide.ps1 update -Apply -Only dmf

# 3. Then the rest
.\darktide.ps1 sync -Apply

# 4. If the game crashes on load, bisect: comment out half of
#    mod_load_order.txt with '--' and restart.

# 5. If one mod is the culprit and has no update yet:
.\darktide.ps1 rollback -Apply -BackupSet '<set>'
#    then set "pinned": true on it in mods-map.json
```

Your mod **settings survive all of this** — DMF stores them in `%APPDATA%\Fatshark\Darktide\`,
not in the mod folders.

---

## Safety

This tooling deletes and replaces directories, so it is deliberately paranoid:

- **Refuses to write while `Darktide.exe` is open.** Dry runs still work with the game
  running, so you can plan an update mid-mission.
- **Validates the game path** against `binaries\Darktide.exe`, `bundle\bundle_database.data`
  and friends before writing. Also refuses drive roots and suspiciously shallow paths.
  `restore` goes through the same check: it lives on `Deploy-DarktideMods.ps1 -Restore`,
  so there is one implementation rather than a copy in the dispatcher.
- **Staged installs.** A mod is extracted to `.staging-<name>\` and only swapped in once the
  new copy is on disk. A corrupt archive can never leave you with a deleted mod.
- **Backs up before every write** — staging installs to `mod_backups\<timestamp>\`, deploys to
  `deploy_backups\gamemods-<timestamp>.zip`, loader updates to `loader_backups\`. Retention is
  capped (default 10) so repeated runs cannot fill the disk.
- **Archive contents decide the target folder**, taken from the `*.mod` file inside. If that
  doesn't match the mod being updated, the install is refused rather than guessed at.
- **Zip-slip guarded** — `../`, absolute paths, and backslash traversal are rejected, and every
  resolved path is verified to land inside the destination.
- **Won't downgrade silently.** An older archive sitting in Downloads is skipped, not installed.
- **Dry run until `-Apply`.** Including `rollback` and `restore`.

---

## Why a manifest, and not the mods

Darktide mods are their authors' work, published under the Nexus Mods terms. Re-hosting them —
in a git repo, in a release artifact, anywhere — is redistribution without permission, and it
also cuts the author out of their own download counts, endorsements, and comments.

So this repo does what Nexus Collections and Wabbajack do: it ships a **lockfile** describing
the loadout, and you fetch each mod from its author.

```json
{
  "folder": "markers_aio",
  "name": "Markers Improved All-in-one",
  "modId": 447,
  "version": "2.14.4",
  "url": "https://www.nexusmods.com/warhammer40kdarktide/mods/447",
  "contentSha256": "9bb6fc60..."
}
```

`contentSha256` hashes the installed folder's contents, so you can tell whether an install has
drifted from what was locked.

The CI packaging step uses an explicit allow-list and hard-fails if anything mod-shaped ends up
in the artifact.

---

## Testing

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force

.\Invoke-Tests.ps1                      # whole suite, then the repo validator
.\Invoke-Tests.ps1 -Path Deploy         # one file
.\Invoke-Tests.ps1 -Output Detailed     # per-test output
```

Every test builds its own staging folder, fake game install and mod archives under
`$env:TEMP`. Nothing touches your real mods, your real game folder, or the network,
so the suite is safe to run at any time.

The suite needs **Windows**: the tools shell out to `robocopy`, read `$env:USERPROFILE`
and the Steam registry keys, and build `\`-separated paths, and the tests assert exactly
that. On Linux or macOS `Invoke-Tests.ps1` says so and runs the cross-platform repository
validator instead; `-AllowNonWindows` forces the Pester run if you want to see it fail.

The local Linux command that matches the ubuntu CI job is:

```bash
./run-tests-docker.sh
```

That runs `Test-Modpack.ps1`, asserts `Invoke-Tests.ps1` exits `3` twice, then runs the
Lock slice (exit `0`). It is not a Windows Pester pass. `./run-tests-docker.sh full`
will show ~70 environmental failures; that is expected, not a bug.

`Invoke-Tests.ps1` exit codes, so a script can tell a passing suite from a skipped one:

| Code | Meaning |
|---|---|
| `0` | every check that was asked for ran and passed |
| `1` | something ran and failed |
| `3` | nothing failed, but the Pester suite was skipped because this is not Windows |

**`3` is not success** — it means the change is unverified. It is what you get by default
off Windows, where only the validator can run. `Test-Modpack.ps1` on its own is the usual
0 for clean, non-zero for a failure.

What it covers:

| Area | Checks |
|---|---|
| `tests/Deploy.Tests.ps1` | Dry run writes nothing; first deploy copies; **second deploy is a byte-identical no-op**; `-Force`; `-Mirror`; backup retention; `-Restore` dry-run and apply; traversal backups refused without deleting `mods\`; refusal to write to a non-Darktide folder, a drive root or an empty staging set; load-order post-checks. |
| `tests/OfflineUpdate.Tests.ps1` | Upgrade installs and is recorded; **re-running installs nothing**; new mods land with a load-order entry that is not duplicated; downgrades refused without `-Force`; traversal and malformed archives rejected without destroying the installed mod; rollback dry-run vs `-Apply`; hostile backup zips refused; extra backup-set dirs pruned. |
| `tests/Update.Tests.ps1` | Nexus filename parsing, version comparison, mod-name resolution from the `.mod` file, unsafe-name refusal, zip-slip guards (`../`, `..\`, absolute paths), and extract into a folder whose name contains `[]`. |
| `tests/Lock.Tests.ps1` | Lockfile shape, ID mapping, no mod content, stable regeneration, content hashes that move only when a mod changes. |
| `tests/Setup.Tests.ps1` | Game detection: real game files vs a folder that only has the right name, multi-drive Steam libraries parsed from `libraryfolders.vdf`, and a generated config the other tools can consume. |
| `tests/Loader.Tests.ps1` | Loader version parsing, payload validation, install/update, base into staging, your load order preserved, backups, backup retention, hostile loader zips refused, and — against a stub patcher — that it uses `--patch`/`--unpatch` in the right order and never the toggle. |
| `tests/Export.Tests.ps1` | The loadout archive: every mod included, forward-slash entry names so it opens on any tool, no overwrite without `-Force`, never written inside the folder it's archiving. |
| `tests/Import.Tests.ps1` | Export → import round trip onto an empty machine, replacing an existing install without merging stale files, traversal archives refused, and restore-plus-deploy in one run. |
| `tests/Dispatcher.Tests.ps1` | `rollback` / `restore` without `-Apply` write nothing; with `-Apply` they reach the updater and deployer; `sync` does not deploy when update fails. |
| `tests/UpgradeWorkflow.Tests.ps1` | The whole upgrade, in order, through `darktide.ps1`: dry run, `update -Apply` into staging only, `deploy -Apply` to make it live, `lock`, then rollback — including the two properties that look like bugs until you know staging is the source of truth. |
| `tests/FindUpdates.Tests.ps1` | The `links` list: a page for every mod with an id, a built one where the lockfile has no `url`, `no Nexus id` rather than a guess, `-Only` / `-Skip` / `-OutFile`, a malformed `githubRepo` reported and ignored, `same` vs `differs` (never “newer”), and a mocked GitHub call whose failures stay distinguishable. |
| `tests/Attribution.Tests.ps1` | The validator's attribution checks actually fire — proven by feeding them content that must fail, so a check cannot rot into a no-op unnoticed. |
| `tests/Package.Tests.ps1` | The release package: only allow-listed files, no mod content or config, the archive builds and its manifest matches `-ListOnly`. |

---

## CI

`validate` runs **automatically on every push** (any branch) and on pull requests to `main`.
The two jobs that publish something stay manual — they are gated on the event being a
`workflow_dispatch`, not merely on the task input, so a push can never trigger a release.

| Task | Trigger | Runs on | Does |
|---|---|---|---|
| `validate` | push, PR, manual | windows-latest | The Pester suite under pwsh 7, then PSScriptAnalyzer, AST parse of every script, JSON validity, lockfile consistency, and hygiene checks (no committed mod files, no leaked API key, `config.json` untracked). |
| `windows-powershell` | push, PR | windows-latest | The same suite under **Windows PowerShell 5.1**, the engine that ships with Windows. It asserts it really is Desktop edition first, so it cannot quietly become a copy of the job above. |
| `cross-platform` | push, PR | ubuntu-latest | The validator on Linux, the `Invoke-Tests.ps1` exit-code contract, the release package build, and shellcheck on the setup script — the checks a Windows-only job cannot see. |
| `macos` | push, PR | macos-latest | The same validator and exit-code contract on macOS, which is arm64. The README and the scripts have always claimed macOS works; this is what makes that a checked statement. |
| `release` | manual only | windows-latest | Validate, package the allow-listed files, publish a GitHub Release with a SHA-256 and a generated mod table. |
| `refresh-lock` | manual only | ubuntu-latest | Query the Nexus API for each mapped mod's current version and open a PR with the diff. Metadata only — needs the `NEXUS_API_KEY` secret; a free account is enough. |
| `prune-branches` | manual only | ubuntu-latest | Delete branches whose work is already on `main`, each against an explicit rule. Dry run unless `apply` is ticked. |

The test count is deliberately not quoted here. It has been wrong twice.

Both publishing tasks wait on `validate`, `cross-platform` **and** `macos`, so a red check
on any platform stops a release or a lockfile PR before it starts.

Pushing again while a run is in flight cancels the older one (`concurrency`), so only the
newest commit on a branch is checked. Manual runs are never cancelled — a half-finished
release is worse than a wasted minute.

```powershell
gh workflow run CI -f task=release -f version=1.0.0   # the manual ones
```

Run the validator locally the same way CI does:

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser
.\Test-Modpack.ps1
```

---

## Files

| File | Purpose |
|---|---|
| `darktide.ps1` | Entry point. All the verbs above. |
| `Update-DarktideMods.ps1` | Version checking and installing into staging. |
| `Deploy-DarktideMods.ps1` | Staging → game folder sync, with validation and backup. `-Restore` unpacks a deploy backup. |
| `New-ModpackLock.ps1` | Generates the lockfile from an installed mods folder, or (`-SyncIdsFromMap`) copies Nexus ids from `mods-map.json` into an existing lockfile. |
| `Initialize-DarktideConfig.ps1` | Finds the game via Steam and writes `config.json`. |
| `Install-DarktideLoader.ps1` | Installs/updates the mod loader, manages the bundle patch. |
| `Export-DarktideLoadout.ps1` | Packs your loadout into one zip (local backup). |
| `Import-DarktideLoadout.ps1` | Restores a loadout zip and deploys it. |
| `Find-ModUpdates.ps1` | The `links` verb: Nexus pages for every mod, and GitHub release tags for mods mapped to a repository. No key, no writes. |
| `Test-Modpack.ps1` | Repository validator, used by CI. |
| `Invoke-Tests.ps1` | Runs the Pester suite, then the validator. |
| `tests/` | Pester tests. Sandboxed — no game, no key, no network. |
| `.claude/skills/` | Repo skills for coding agents: how to validate a change, the safety invariants, and a script that sets up a test environment from scratch. |
| `config.example.json` | Config template. Copy to `config.json` (gitignored). |
| `mods-map.json` | Folder → Nexus mod ID, plus `pinned` flags and an optional `githubRepo`. |
| `darktide-modpack.lock.json` | The loadout manifest. |

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `cannot be loaded because running scripts is disabled` | Execution policy. `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`, then `Get-ChildItem *.ps1 \| Unblock-File`. |
| `does not look like a Darktide install` | `GamePath` is wrong. It must be the folder containing `binaries\Darktide.exe` or `bundle\bundle_database.data` — not the Steam library root, not the `mods\` folder inside it. |
| `is not a mods folder (no mod_load_order.txt, no base\)` | `ModsRoot` points somewhere that isn't a DMF mods folder. See step 3's note on creating staging. |
| `Darktide.exe is running` | You passed `-Apply` with the game open. Close it, or drop `-Apply` for a dry run. Hung process: `Get-Process Darktide`. |
| `Nothing to do. Download mod archives...` | No `.zip` files in `DownloadDir`. Check the path in `config.json` and that your browser didn't save `.zip.crdownload`. |
| Archive shows as `VERSION-UNKNOWN` | The filename was changed and the zip has no `info.json`. Install it deliberately: `.\darktide.ps1 update -Apply -Force -Only <folder>`. |
| Archive shows as `NO-ARCHIVE` | That mod has no matching zip in `DownloadDir` — nothing is wrong, there's just nothing to install for it. |
| `Skipping '<file>': no *.mod file inside` | Not a DMF mod archive (a texture pack, a readme bundle, or a nested zip). Ignored on purpose. |
| Deploy says `Already in sync` when you expected work | Staging really does match the game folder. If you edited the game folder directly, that edit is what `-Mirror` or `-Force` is for. |
| Game crashes on load after an update | `.\darktide.ps1 restore -Apply`, then bisect: comment out half of `mod_load_order.txt` with `--` and restart. See [After a Darktide patch](#after-a-darktide-patch). |
| Mods silently stop loading after a game update | Steam replaced the patched bundle. `.\darktide.ps1 loader -Apply` or `.\darktide.ps1 deploy -Apply -RunToggle`. |
| `HTTP 403 ... premium users only` | Expected on a free Nexus account. Version *checking* works on free; downloading through the API does not. Download in the browser. |
| `HTTP 429` / rate limited | Nexus allows 100 requests/hour, 2500/day. Wait it out, or use `-NoApi`. |

### Getting more detail

```powershell
.\darktide.ps1 update -Verbose          # per-decision logging
Get-Content .\logs\update-*.log | Select-Object -Last 50
Import-Csv (Get-ChildItem .\report-*.csv | Select-Object -Last 1) | Format-Table
```

Every run writes a timestamped log to `logs\` and a CSV report next to the scripts. Both are
gitignored; logs older than 30 days are pruned automatically.

### Verifying the tooling itself

```powershell
.\Invoke-Tests.ps1
```

Runs 153 sandboxed tests plus the repository validator. It touches nothing real — see
[Testing](#testing).

---

## Caveats

- Nexus API response shapes are stable but not contractually frozen. If a call starts failing,
  check <https://api-docs.nexusmods.com/>.
- Version comparison is numeric-segment based. Authors using non-numeric version strings fall
  back to a string compare and may misreport.
- Mods distributed only via GitHub or Discord are invisible to the version checker.
- The mod loader is version-tracked by name only. It ships no version file, so the version
  comes from the download's filename; rename it and the version reads as unknown.

## Licence

[MIT](LICENSE) for the tooling in this repository. It does not extend to any mod — those belong
to their authors. Warhammer 40,000: Darktide is a trademark of Games Workshop / Fatshark; this
project is unofficial and unaffiliated.
