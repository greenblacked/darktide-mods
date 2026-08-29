# darktide-mods

Mod management for **Warhammer 40,000: Darktide** — update, verify, and deploy a Darktide Mod
Framework loadout from PowerShell, with backups and a one-command rollback at every step.

> **This repository contains no mods.** It ships tooling and a *manifest*
> (`darktide-modpack.lock.json`) that records which mods a loadout uses and links to each
> author's page. You download the mods yourself, from the authors, on Nexus. See
> [Why a manifest](#why-a-manifest-and-not-the-mods).

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

## Quick start

**Requires:** Windows PowerShell 5.1 (built in) or PowerShell 7+. No modules, no dependencies.

```powershell
git clone https://github.com/<you>/darktide-mods.git
cd darktide-mods

Copy-Item config.example.json config.json
notepad config.json          # set ModsRoot, GamePath, DownloadDir

Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
Get-ChildItem *.ps1 | Unblock-File

.\darktide.ps1 status
```

`status` writes nothing. It reports what's staged, what's deployed, whether the two have
drifted, and whether the mod loader is installed.

## Everyday use

```powershell
# 1. Download the mods you want from Nexus into your DownloadDir.
#    Keep the default filenames - the version is encoded in them.
# 2. Close the game.
# 3. Dry run, then go:

.\darktide.ps1 sync            # shows exactly what would happen
.\darktide.ps1 sync -Apply     # install into staging, then deploy to the game
```

Everything is a dry run until `-Apply`.

### Verbs

| Verb | What it does |
|---|---|
| `status` | Staged vs deployed, drift, loader state, backup sets. Read-only. |
| `check` | Ask Nexus what's outdated. Needs an API key. Read-only. |
| `update` | Install newer archives from your download folder into staging. |
| `deploy` | Push staging into the game folder. |
| `sync` | `update` then `deploy`, then refresh the lockfile. The everyday one. |
| `rollback` | Undo the last staging install. |
| `restore` | Undo the last deploy to the game folder. |
| `lock` | Regenerate `darktide-modpack.lock.json` from what's installed. |

### Useful switches

```powershell
.\darktide.ps1 update -Apply -Only markers_aio,scoreboard   # scope to specific mods
.\darktide.ps1 deploy -Apply -Mirror                        # also delete mods no longer staged
.\darktide.ps1 deploy -Apply -InstallLoader -RunToggle      # fresh install / after a game patch
.\darktide.ps1 update -Apply -Force -Only NumericUI         # reinstall or downgrade one mod
```

---

## Re-running is safe

Every verb is idempotent: running it twice does the same thing as running it once.

- `deploy` compares staging against the game folder first (`robocopy /L`). With nothing to
  copy it takes **no backup** and writes **nothing** — it says `Already in sync` and stops.
  `-Force` overrides that when you want a redeploy anyway.
- `update` records the installed version in each mod's `.nexus-mod.json`, so an archive you
  have already installed comes back as `SAME` and is skipped. `-Force` reinstalls.
- `mod_load_order.txt` is only ever appended to, and never with a name already in it.
- Deploy backups are pruned to the newest `-KeepBackups` archives (default 10), so repeated
  deploys cannot fill the disk.

---

## Version checking (optional)

The tooling works fully without a Nexus API key. What the key adds is one thing: telling you
that a newer version exists before you go looking.

| | No key | Free account + key | Premium + key |
|---|---|---|---|
| Read installed versions | yes | yes | yes |
| Know an update exists | **you check** | automatic | automatic |
| Download the archive | **you click** | **you click** | automatic |
| Install, backup, load order, deploy | yes | yes | yes |

Free Nexus accounts cannot get download links from the API — `/download_link.json` returns
403 — so the download click is always manual unless you're premium. That's a Nexus policy;
working around it would mean scraping, which their terms prohibit.

To enable checking:

```powershell
# https://www.nexusmods.com/users/myaccount?tab=api  ->  generate a personal key
[Environment]::SetEnvironmentVariable('NEXUS_API_KEY', '<your-key>', 'User')
# open a new PowerShell window, then:
.\darktide.ps1 check
```

Without a key, `update` runs in offline mode automatically. It reads the version out of each
archive — from the `info.json` inside the zip, or from the stock Nexus filename
(`Markers Improved All-in-one-447-2-14-4-1719209900.zip` → mod 447, version 2.14.4) — and
installs only what's genuinely newer.

### Mapping mods to Nexus IDs

`mods-map.json` maps folder names to Nexus mod IDs. Mods that ship an `info.json` are mapped
automatically; the rest need an ID before they can be version-checked.

```powershell
.\Update-DarktideMods.ps1 -BuildCatalog   # crawls the Nexus mod list; resumable
.\Update-DarktideMods.ps1 -Resolve        # matches by name, writes mods-map.json
```

Or just paste the number from the mod's URL into `mods-map.json`. Set `"pinned": true` on
anything you want left alone.

---

## After a Darktide patch

The order matters:

```powershell
# 1. Re-apply the mod loader's bundle patch (Steam replaced it)
.\darktide.ps1 deploy -Apply -InstallLoader -RunToggle

# 2. Update the framework first - most mods depend on it
.\darktide.ps1 update -Apply -Only dmf

# 3. Then the rest
.\darktide.ps1 sync -Apply

# 4. If the game crashes on load, bisect: comment out half of
#    mod_load_order.txt with '--' and restart.

# 5. If one mod is the culprit and has no update yet:
.\darktide.ps1 rollback -BackupSet '<set>'
#    then set "pinned": true on it in mods-map.json
```

Your mod **settings survive all of this** — DMF stores them in `%APPDATA%\Fatshark\Darktide\`,
not in the mod folders.

---

## Safety

This tooling deletes and replaces directories, so it is deliberately paranoid:

- **Refuses to run while `Darktide.exe` is open.**
- **Validates the game path** against `binaries\Darktide.exe`, `bundle\bundle_database.data`
  and friends before writing. Also refuses drive roots and suspiciously shallow paths.
- **Staged installs.** A mod is extracted to `.staging-<name>\` and only swapped in once the
  new copy is on disk. A corrupt archive can never leave you with a deleted mod.
- **Backs up before every write** — staging installs to `mod_backups\<timestamp>\`, deploys to
  `deploy_backups\gamemods-<timestamp>.zip`.
- **Archive contents decide the target folder**, taken from the `*.mod` file inside. If that
  doesn't match the mod being updated, the install is refused rather than guessed at.
- **Zip-slip guarded** — `../`, absolute paths, and backslash traversal are rejected, and every
  resolved path is verified to land inside the mod folder.
- **Won't downgrade silently.** An older archive sitting in Downloads is skipped, not installed.
- **`-WhatIf` everywhere.**

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

What it covers:

| Area | Checks |
|---|---|
| `tests/Deploy.Tests.ps1` | Dry run writes nothing; first deploy copies; **second deploy is a byte-identical no-op**; `-Force`; `-Mirror`; backup retention; refusal to write to a non-Darktide folder, a drive root or an empty staging set; load-order post-checks. |
| `tests/OfflineUpdate.Tests.ps1` | Upgrade installs and is recorded; **re-running installs nothing**; new mods land with a load-order entry that is not duplicated; downgrades refused without `-Force`; traversal and malformed archives rejected without destroying the installed mod. |
| `tests/Update.Tests.ps1` | Nexus filename parsing, version comparison, mod-name resolution from the `.mod` file, unsafe-name refusal, and zip-slip guards (`../`, `..\`, absolute paths). |
| `tests/Lock.Tests.ps1` | Lockfile shape, ID mapping, no mod content, stable regeneration, content hashes that move only when a mod changes. |

---

## CI

Manual only — `workflow_dispatch`, nothing fires on push.

| Task | Runs on | Does |
|---|---|---|
| `validate` | windows-latest | PSScriptAnalyzer, AST parse of every script, JSON validity, lockfile consistency, and hygiene checks (no committed mod files, no leaked API key, `config.json` untracked). |
| `release` | windows-latest | Validate, package the allow-listed files, publish a GitHub Release with a SHA-256 and a generated mod table. |
| `refresh-lock` | ubuntu-latest | Query the Nexus API for each mapped mod's current version and open a PR with the diff. Metadata only — needs the `NEXUS_API_KEY` secret; a free account is enough. |

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
| `Deploy-DarktideMods.ps1` | Staging → game folder sync, with validation and backup. |
| `New-ModpackLock.ps1` | Generates the lockfile from an installed mods folder. |
| `Test-Modpack.ps1` | Repository validator, used by CI. |
| `Invoke-Tests.ps1` | Runs the Pester suite, then the validator. |
| `tests/` | Pester tests. Sandboxed — no game, no key, no network. |
| `config.example.json` | Config template. Copy to `config.json` (gitignored). |
| `mods-map.json` | Folder → Nexus mod ID, plus `pinned` flags. |
| `darktide-modpack.lock.json` | The loadout manifest. |

---

## Caveats

- Nexus API response shapes are stable but not contractually frozen. If a call starts failing,
  check <https://api-docs.nexusmods.com/>.
- Version comparison is numeric-segment based. Authors using non-numeric version strings fall
  back to a string compare and may misreport.
- Mods distributed only via GitHub or Discord are invisible to the version checker.
- The mod loader itself is installed but not version-managed here — it patches game files,
  which is a different risk class. Update it by hand from its Nexus page.

## Licence

[MIT](LICENSE) for the tooling in this repository. It does not extend to any mod — those belong
to their authors. Warhammer 40,000: Darktide is a trademark of Games Workshop / Fatshark; this
project is unofficial and unaffiliated.
