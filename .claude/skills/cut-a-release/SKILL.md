---
name: cut-a-release
description: How to publish a darktide-mods release safely - the preconditions, the version input and what it accepts, what the package allow-list ships and what must never leave the repo, and how to verify the published artifact. Use whenever the user wants to cut, publish, tag or ship a release, asks about the release workflow, or wants to know why a release run failed. For the wording of the notes themselves see the sepia skill; this one covers the mechanics and what is safe to ship. Reach for it before triggering the release job, because the job publishes publicly and there is no undo that unpublishes a zip someone already downloaded.
---

# Cutting a release

The release job is `workflow_dispatch`-only. Check whether it has ever actually run
(`git tag -l`, or the Releases page) before assuming this path is proven; as this was
written there were no tags at all. If yours is the first, treat it as a genuine first
run and verify each step rather than trusting it.

What *is* proven is the packaging: `New-ReleasePackage.ps1` stages and scans on every
push, and `tests/Package.Tests.ps1` covers the allow-list and plants each kind of
forbidden file to confirm the scan refuses it. Tagging, the GitHub release itself and
the notes are still unexercised.

Publishing is the one irreversible thing this repo does. A wrong lockfile can be
corrected in the next release; a mod file that escapes into a public zip cannot be
un-downloaded, and it is someone else's copyrighted work.

## Before triggering anything

1. **CI is green on the commit you are releasing.** The release job needs both the
   Windows job and the Linux guard, so it will not start otherwise. A green pair
   means the full Pester suite and the validator passed on Windows, which is what you
   are actually shipping.
2. **The lockfile is current.** Release notes are generated *from*
   `darktide-modpack.lock.json`: the mod table, the version column, the Nexus links. A
   stale lockfile produces a release that misdescribes the loadout. Regenerate with
   `New-ModpackLock.ps1 -ModsRoot <staging>` if the loadout has moved on.
3. **You are releasing from the branch you think you are.** The job checks out whatever
   ref the dispatch names.

## Triggering it

Actions → CI → Run workflow, with `task: release`.

**`version`** — optional. Leave it blank and the job derives `yyyy.MM.dd.<run-number>`,
which is a perfectly good scheme for a tool with no API contract. If you set it, it must
match:

```
^[0-9A-Za-z][0-9A-Za-z.+_-]{0,63}$
```

So `1.2.0`, `1.0.0-rc.1` and `v1_2+build3` are fine; anything with a space, a quote, a
slash or a newline is refused with a clear error. That constraint is load-bearing rather
than fussy: the value becomes a git tag, two filenames and a step output, and it used to
be interpolated straight into a PowerShell script where a quote could run arbitrary code.
Do not loosen it without understanding what it protects.

**`prerelease`** marks the GitHub release as a pre-release, which is a reasonable
setting for a first run.

The tag is `v<version>`; the job creates it, so do not tag by hand first.

## What ships, and what must never

`New-ReleasePackage.ps1` owns this, and the release job calls it rather than carrying a
copy. It copies an explicit **allow-list**: the eight `.ps1` tools plus `Test-Modpack.ps1`,
`config.example.json`, `mods-map.json`, `darktide-modpack.lock.json`, `README.md`,
`LICENSE`, plus `Invoke-Tests.ps1` and `tests/` so anyone can verify the tooling before
running it against their own game folder. Missing file → it throws rather than shipping
a partial package.

Then a second, independent check refuses to package anything with a `.mod` or `.zip`
extension or named `config.json`. Both layers should stay. The allow-list is the
mechanism; the scan is what catches a mistake in the allow-list.

Two things follow from it being a script rather than YAML. The Linux job runs
`-NoArchive` on **every push**, so a broken allow-list is a red build rather than a bad
release — this path used to run only during a real publish. And the validator asks it
`-ListOnly` instead of running a regex over the workflow file, which is what the check
used to do; that version could not see the two files the job copied outside the array it
matched, and said so in its own comment.

To check the packaging by hand without publishing anything:

```powershell
.\New-ReleasePackage.ps1 -NoArchive          # stage and scan, no zip
.\New-ReleasePackage.ps1 -Version 1.2.0      # zip plus .sha256, still local
```

**Never ships:** mod content of any kind, `config.json`, an API key, `nexus-catalog.json`,
backups, logs. The lockfile is a *manifest* — it names mods and links to each author's
Nexus page so a user downloads them from the author. That distinction is the whole legal
basis for this repo being publishable at all.

The skills directory is not in the allow-list, and that is deliberate: it is guidance for
people working *on* the repo, not part of the tool a user installs.

## Writing the notes

The job generates them: what the release is, an install snippet, and a table of every mod
with its version and Nexus link, sorted by folder. If you are adding prose on top, the
`sepia` skill's `references/domains/release-notes.md` covers the register — user impact
first, no claim without an artifact, breaking changes before nice-to-haves, and a patch
release stays three lines rather than being inflated to look substantial.

Do not describe changes you have not verified, and do not invent version numbers or
benchmark figures. Everything stated should come from the diff, the lockfile or a CI run.

## After it publishes

- The release carries the zip and a `.sha256` sidecar. Download both and confirm the hash
  matches what the job printed — that is the only end-to-end check that the artifact
  people receive is the artifact CI built.
- Expand the zip somewhere clean and confirm no mod folders, no `config.json`, no key.
- Check the tag points at the commit you meant.

If something is wrong, delete the release and the tag and cut another. A wrong release
left standing is worse than a gap in the version sequence.

## What the job cannot do here

`refresh-lock` is the other manual task and it needs a `NEXUS_API_KEY` repository
secret. This setup is run without a key, so that task is not used and is not
scheduled. It will fail on the missing-secret check if someone dispatches it.
It is unrelated to releasing — release needs no secret, only the built-in
`github.token` with `contents: write` scoped to that job alone.
