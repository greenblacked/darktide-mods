# First week

Skim this once. The long form is in the [README](../README.md).

## First run

```powershell
.\darktide.ps1 init
.\darktide.ps1 loader -Apply
.\darktide.ps1 status
```

`init` writes `config.json`. `loader` is a dry run until `-Apply`. `status` only reads.

Get the Mod Loader from
[nexusmods.com/warhammer40kdarktide/mods/19](https://www.nexusmods.com/warhammer40kdarktide/mods/19)
into your `DownloadDir` before `loader -Apply`.

## Everyday update

1. Download mod archives from Nexus into `DownloadDir`. Keep the default filenames.
2. Close the game (applying is refused while `Darktide.exe` is running).
3. Upgrade:

```powershell
.\darktide.ps1 upgrade
```

It shows one plan (which mods change in staging, whether the game folder changes) and asks `Apply this plan? [y/N]` once. A no writes nothing. A yes updates staging, deploys, refreshes the lockfile, and prints the backup names with the exact `restore` / `rollback` commands that undo it. Nothing to do means no question and exit code 0. Add `-Yes` to skip the question; a non-interactive session needs it.

The same work as two commands, if you want to read the dry run on its own first:

```powershell
.\darktide.ps1 sync
.\darktide.ps1 sync -Apply
```

`sync` is `update` then `deploy`, then a lockfile refresh. If update fails, deploy does not run. If deploy finishes with problems, the lockfile is not refreshed. Either way the exit code is non-zero. `upgrade` stops at the same points.

## Undo

Both are dry runs until `-Apply`:

```powershell
.\darktide.ps1 restore -Apply     # newest game-folder backup
.\darktide.ps1 rollback -Apply    # last staging install
.\darktide.ps1 deploy -Apply      # push rolled-back staging out again
```

## After a game patch

Run `.\darktide.ps1 patchcheck` before anything else. It reads only, and says whether Steam replaced the patched bundle database,
which loader files are missing, and the exact command to run next. Exit `1` means something needs doing.
Details: [After a Darktide patch](../README.md#after-a-darktide-patch).

## Offline and downloads

No API key → offline mode. Archives in `DownloadDir` are enough for `update` / `sync` / `upgrade`.

Version *checking* with a Nexus API key is optional. Free accounts get HTTP 403 on Nexus download links, so this tool never auto-downloads archives. Premium does not change that here — you still download in the browser.

With no key at all, `.\darktide.ps1 links` turns the lockfile into the list of pages to open, so the manual check is a list of links rather than a search per mod. Add `-CheckGitHub` and it will also read the latest release tag for any mod given a `githubRepo` in `mods-map.json` — the one upstream that answers without a key.
