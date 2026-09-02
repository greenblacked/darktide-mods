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
2. Close the game (`-Apply` refuses while `Darktide.exe` is running).
3. Dry run, then apply:

```powershell
.\darktide.ps1 sync
.\darktide.ps1 sync -Apply
```

`sync` is `update` then `deploy`, then a lockfile refresh. If update fails, deploy does not run. If deploy finishes with problems, the lockfile is not refreshed. Either way the exit code is non-zero.

## Undo

Both are dry runs until `-Apply`:

```powershell
.\darktide.ps1 restore -Apply     # newest game-folder backup
.\darktide.ps1 rollback -Apply    # last staging install
.\darktide.ps1 deploy -Apply      # push rolled-back staging out again
```

## Offline and downloads

No API key → offline mode. Archives in `DownloadDir` are enough for `update` / `sync`.

Version *checking* with a Nexus API key is optional. Free accounts get HTTP 403 on Nexus download links, so this tool never auto-downloads archives. Premium does not change that here — you still download in the browser.
