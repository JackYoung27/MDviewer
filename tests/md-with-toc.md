# Mac Backup

Backs up `$HOME` into a **mountable disk image** that can be opened in Finder,
browsed, and restored from piece by piece.

---

## Contents

- [1. Overview](#1-overview)
  - [What's inside a mounted image](#whats-inside-a-mounted-image)
  - [Two design choices worth knowing](#two-design-choices-worth-knowing)
- [2. How to use](#2-how-to-use)
  - [2.1 Scheduled execution](#21-scheduled-execution)
  - [2.2 On demand execution](#22-on-demand-execution)
  - [2.3 Sealing images](#23-sealing-images)
  - [2.4 Export to OneDrive](#24-export-to-onedrive)
- [3. Caveats](#3-caveats)
  - [Safari bookmarks are not backed up](#safari-bookmarks-are-not-backed-up)
  - [Other things deliberately left out](#other-things-deliberately-left-out)
  - [Browsers should be closed for a perfect copy](#browsers-should-be-closed-for-a-perfect-copy)
  - [Files being written during a run](#files-being-written-during-a-run)
  - [Don't point two Macs at the same OneDrive folder](#dont-point-two-macs-at-the-same-onedrive-folder)
- [4. Technical details](#4-technical-details)
  - [File layout](#file-layout)
  - [Notable design points](#notable-design-points)
  - [Verifying an image manually](#verifying-an-image-manually)
  - [Environment overrides](#environment-overrides)
  - [Known quirk: forced detach](#known-quirk-forced-detach)
  - [The previous backup system](#the-previous-backup-system)

**Quick reference**

| Task | Section |
|---|---|
| Understand what this does | [1. Overview](#1-overview) |
| Run a backup right now | [2.2 On demand execution](#22-on-demand-execution) |
| Set up or check the schedule | [2.1 Scheduled execution](#21-scheduled-execution) |
| Freeze a copy before an OS upgrade | [2.3 Sealing images](#23-sealing-images) |
| Restore files | [`image-backup.d/RESTORE.md`](image-backup.d/RESTORE.md) |
| See what is *not* backed up | [3. Caveats](#3-caveats) |
| Change what gets excluded | [`image-backup.d/README.md`](image-backup.d/README.md) |

---

## 1. Overview

The goal is simple: **restore onto a new Mac with everything needed already
present**, without re-downloading or rebuilding anything the backup should have
carried.

Two things are kept:

| | What it is | Where |
|---|---|---|
| **Live image** | `live.sparsebundle`, refreshed every run. Always current. | `~/Local/Backups/` + OneDrive |
| **Sealed images** | `sealed-YYYY-MM-DD.dmg` — frozen, compressed, checksum-verified. A fixed number are kept. | `~/Local/Backups/sealed/` + OneDrive |

Either one mounts as an ordinary folder tree. Restoring can be as simple as
dragging files out in Finder — no scripts required.

A run normally takes seconds, because only changed files are copied. The image is
a small fraction of the size of a naive copy of `$HOME`: build artifacts, caches,
re-downloadable browser components, and previous backups are all left out. For
current size and file count, run `./image-backup.command --dry-run`.

### What's inside a mounted image

```
mirror/                 backed-up files, laid out exactly as under ~/
repos.tsv               every git repo: remote URL, branch, commit, dirty state
git-work/               local commits and stashes the remotes don't have
bookmarks/              bookmark exports (JSON + HTML)
manifests/              a record, per run, of exactly what existed
secrets-inventory.txt   what was deliberately NOT copied, for manual recreation
RESTORE.md              step-by-step restore instructions
policy/                 the exclusion rules that produced this image
unreadable-files.txt    any files that couldn't be read (only if there were some)
```

### Two design choices worth knowing

**Git repositories are recorded, not copied wholesale.** `.git` folders are
redundant with the remotes, so they're excluded. Instead `repos.tsv` records each
repo's remote URL, branch and exact commit, and anything a remote *doesn't* have —
local-only commits, stashes, branches with no upstream — is saved as a git bundle
in `git-work/`. Working files, including uncommitted and untracked ones, are in
`mirror/` as normal. Restoring is clone → reset to the recorded commit → copy the
working files back. This keeps the backup small while making a restore mechanical
rather than detective work.

**Whole browser profiles are backed up, not just bookmarks.** Pinned tabs and tab
groups aren't stored in the bookmarks file — they live in `Preferences`,
`Sessions/` and `Local State`. Backing up only bookmarks loses them, so the full
profile is kept (minus caches).

---

## 2. How to use

Everything runs from:

```
~/Local/MacConfigBackup/
```

### 2.1 Scheduled execution

**Default schedule: Monday–Friday at 12:00.**

If the Mac is asleep or off at that time, the run is **skipped, not caught up
later**. This is deliberate — a catch-up run firing at login would slow startup
and compete for the network while it connects. A skipped run costs nothing; the
next weekday continues from where things left off.

**Create the schedule:**

```bash
~/Local/MacConfigBackup/image-backup.command --install-agent
```

This writes `~/Library/LaunchAgents/com.macconfigbackup.image-backup.plist` and
prints the activation command. A newly written schedule takes effect at the next
login, or immediately with:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.macconfigbackup.image-backup.plist
```

Re-run `--install-agent` after a username change. The schedule file must contain
an absolute path, so it is regenerated rather than hand-edited.

**Review the current schedule:**

```bash
launchctl print gui/$(id -u)/com.macconfigbackup.image-backup
```

Useful lines in that output: `state` (whether it is running), `runs` (how many
times it has fired), and `last exit code`.

For a quick yes/no:

```bash
launchctl list | grep image-backup
```

A line like `-  0  com.macconfigbackup.image-backup` means it is registered, and
the middle number is the **last exit code** — `0` good, `3` ran but something was
unreadable, anything else a failure. No output means no schedule is active.

**See the configured times:**

```bash
plutil -p ~/Library/LaunchAgents/com.macconfigbackup.image-backup.plist
```

**Read the logs from scheduled runs:**

```bash
tail -40 ~/Local/Backups/logs/image-backup.out.log
tail -40 ~/Local/Backups/logs/image-backup.err.log
```

**Change the schedule.** Edit these near the top of `image-backup.command`, then
re-run `--install-agent`. The script's own guard and the schedule file are
generated from the same values, so they can't drift apart:

```sh
SCHEDULE_HOUR=12
SCHEDULE_WEEKDAY_MIN=1   # Monday
SCHEDULE_WEEKDAY_MAX=5   # Friday
```

**Turn the schedule off:**

```bash
~/Local/MacConfigBackup/image-backup.command --uninstall-agent
```

### 2.2 On demand execution

Run a backup immediately:

```bash
~/Local/MacConfigBackup/image-backup.command
```

Manual runs ignore the scheduled time window — that restriction applies only to
runs started by the scheduler.

| Command | What it does |
|---|---|
| `./image-backup.command` | Normal backup |
| `./image-backup.command --dry-run` | Show what *would* be backed up, and its size. **Writes nothing.** |
| `./image-backup.command --list` | Print every file that would be included |
| `./image-backup.command --checksum` | Compare file *contents* rather than size and timestamp. Slower, but catches a file that changed without its size or date changing. |
| `./image-backup.command --no-onedrive` | Local only; skip the OneDrive copy |
| `./image-backup.command --seal` | Seal now (see 2.3) |
| `./image-backup.command --help` | All options |

`--dry-run` is the safe way to check the effect of an exclusion change before
committing to it.

**What the exit code means:**

| Code | Meaning |
|---|---|
| `0` | Success |
| `3` | Image was written, but **some files couldn't be read**. Usable but knowingly incomplete — see `unreadable-files.txt` inside the image. |
| anything else | Failure |

### 2.3 Sealing images

Sealing freezes the current backup into a compressed, read-only `.dmg` that never
changes again. It is a **read-only operation** on the live image, so it cannot
damage it. Sealed images compress substantially compared with the live image.

**Automatically:** the first run of each calendar month seals. If the Mac is off
for the first week of a month, the seal happens on the first run that does occur,
so a month can't be missed entirely.

**Manually, before anything risky** — an OS upgrade, hardware swap, reimage, or
handing the laptop back:

```bash
~/Local/MacConfigBackup/image-backup.command --seal
```

Sealing always runs a full checksum comparison first, so the frozen copy is
verified rather than assumed. It takes noticeably longer than a normal run
because of the compression.

**Retention:** the newest few sealed images are kept and older ones deleted
automatically. To change how many, edit near the top of `image-backup.command`:

```sh
SEALED_RETENTION_COUNT=3
```

**List retained sealed images:**

```bash
ls -lh ~/Local/Backups/sealed/
```

### 2.4 Export to OneDrive

OneDrive is the **off-machine copy**. Both the live and sealed images are copied
there on every run:

```
~/Library/CloudStorage/OneDrive-UHG/MacBackup/
    live.sparsebundle/      current backup
    sealed/                 retained sealed images
```

This happens automatically, and **nothing about it depends on the network**. The
backup completes entirely offline, then writes into the local OneDrive folder;
OneDrive uploads on its own schedule whenever it is signed in and connected. A
disconnected or signed-out OneDrive cannot cause a backup to fail.

Only changed pieces upload. The image is stored as many small chunks rather than
one large file, so a typical run rewrites a handful of them instead of re-sending
the whole image.

**Check what was copied on the last run:**

```bash
du -sh ~/Library/CloudStorage/OneDrive-UHG/MacBackup/live.sparsebundle
tail -5 ~/Local/Backups/work/onedrive-transfer.log
```

**Skip it for one run:**

```bash
./image-backup.command --no-onedrive
```

**Change the destination** with an environment variable, which overrides the
default:

```bash
IMAGE_BACKUP_ONEDRIVE=/path/to/elsewhere ./image-backup.command
```

> **Restoring from OneDrive:** download the whole `live.sparsebundle` folder before
> opening it. OneDrive can leave pieces as cloud-only placeholders, and an image
> with missing pieces will not mount. Right-click it in Finder → *Always Keep on
> This Device* and wait for it to finish. Sealed `.dmg` files are single files, so
> they need only one download.

---

## 3. Caveats

### Safari bookmarks are not backed up

Safari stores bookmarks in a location macOS protects, which requires **Full Disk
Access** to read. macOS will not grant that to a `.command` script: the picker in
System Settings → Privacy & Security → Full Disk Access greys shell scripts out,
accepting only application bundles and binaries.

The same protection covers a few `com.apple.*` preference files (HomeKit,
iMessage, Messages, Contacts). These are application *settings*, not data, and
together amount to a few kilobytes.

Chrome and Edge bookmarks are **not** affected and are backed up in full — both as
their raw files and as importable HTML. Since those are where the real bookmarks
live, the protected files are excluded by policy so that runs finish cleanly with
exit `0`.

That exclusion is deliberate rather than incidental. Were these files left in,
every run would end with a red `INCOMPLETE BACKUP` warning over a few kilobytes of
settings — and a warning that appears every single time stops being read. With them
excluded, the warning appears only when something unexpected is genuinely
unreadable.

**Should Safari or Messages come into use on this machine**, the Full Disk Access
section of [`image-backup.d/README.md`](image-backup.d/README.md) covers reversing
this: remove the exclusions, grant access via `/bin/zsh` or an app wrapper, and
delete `~/Local/Backups/work/mirror-unreadable.txt` so previously skipped files are
retried.

### Other things deliberately left out

Restoring these is manual by design. `secrets-inventory.txt` inside each image
lists what existed, so nothing is a surprise on a new machine.

- **Keys and credentials** — `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/certs`, and any
  `.pem` / `.key` / `.p12` / `.pfx` file. Never copied.
- **The login keychain** — never copied.
- **Saved browser passwords** — encrypted with a key that does not survive the move
  to a new Mac, so they would be unusable anyway.
- **Build artifacts** — `node_modules`, `.venv`, `target`, `dist`, `build` and
  similar. Re-run the relevant package manager.
- **`.git` folders** — redundant with the remotes; `repos.tsv` and `git-work/`
  replace them at a fraction of the size.
- **Application plugins** — `~/.claude/plugins` and `~/.codex/plugins` are
  re-installable. Conversation history and settings in those folders **are**
  backed up.
- **Large imported media** — `Documents/Video Edit`, `Documents/Robert Photos`,
  `Local/Robert - Bike Photos`, `Local/Wallpaper`. Originals live elsewhere.

The authoritative list is the four policy files in `image-backup.d/`, and a copy
of them travels inside every image under `policy/`.

### Browsers should be closed for a perfect copy

A running browser writes constantly. Files copied mid-write may be slightly stale.
Bookmarks and settings are fine in practice, but for an exact profile snapshot —
before a machine migration, say — quit Chrome and Edge first.

### Files being written during a run

Anything actively changing while the backup runs is captured as it was at that
instant, which may be moments before it changed again. This is normal for any
backup, and worth remembering when comparing a restore against a live original.

### Don't point two Macs at the same OneDrive folder

Both would write to the same image and corrupt it. Give each machine its own
destination via `IMAGE_BACKUP_ONEDRIVE`.

---

## 4. Technical details

For the exclusion policy, design rationale, and the places the implementation
deviates from its original plan, see:

- **`image-backup.d/README.md`** — how the include/exclude layers work, why Time
  Machine's hardlink model was rejected, the detach-and-verify design, and Full
  Disk Access specifics
- **`image-backup.d/RESTORE.md`** — the restore runbook, also copied into every
  image

### File layout

```
~/Local/MacConfigBackup/
    image-backup.command              the backup
    clone-bookmarks-to-edge.command   copy Chrome's bookmarks over Edge's (manual)
    README.md                         this file
    image-backup.d/
        README.md                     policy and design notes
        RESTORE.md                    restore runbook
        exclude-user-root.txt         excluded relative to ~/ only
        exclude-artifacts.txt         caches and build output, at any depth
        exclude-sensitive.txt         keys and credentials, never copied
        include-library.txt           ~/Library subpaths to keep
        bookmarks-to-html.py          bookmark format converter

~/Local/Backups/
    live.sparsebundle                 current backup
    sealed/                           retained sealed images
    logs/                             output from scheduled runs
    work/                             manifests, transfer logs, diagnostics
```

### Notable design points

**Inclusion is the default.** A file is backed up unless a rule excludes it.
Nothing is judged by name or location — `~/dev` contains directories that aren't
repositories, and `~/mac-config` is a repository outside `~/dev`, so any
location-based assumption would be wrong in both directions. Git repositories are
detected per-directory at run time.

**Every run self-checks.** A set of assertions confirms nothing forbidden got in
(credentials, `node_modules`, previous backup output) and that required things are
present (agent conversation history, browser tab-group files). A failure stops the
run rather than producing a quietly wrong image.

**Images are verified, not assumed.** After each run the image is re-mounted
read-only and its file count compared against the manifest. Nothing is copied to
OneDrive until that check passes.

**History without hardlinks.** Instead of Time Machine-style snapshots there is
one mirror, plus sealed images, plus a manifest per run. That still gives a full
record of what existed at every run, without the fragility of a hardlink tree —
which breaks if ever copied by a tool that doesn't preserve hardlinks.

### Verifying an image manually

```bash
# Check a sealed image's checksum
hdiutil verify ~/Local/Backups/sealed/sealed-YYYY-MM-DD.dmg

# Open it and look around
hdiutil attach ~/Local/Backups/sealed/sealed-YYYY-MM-DD.dmg -readonly -mountpoint /tmp/check
ls /tmp/check
open /tmp/check          # browse in Finder
hdiutil detach /tmp/check
```

### Environment overrides

| Variable | Overrides |
|---|---|
| `IMAGE_BACKUP_ROOT` | Where the live image, sealed images, logs and work files live |
| `IMAGE_BACKUP_ONEDRIVE` | The off-machine destination |

### Known quirk: forced detach

Runs may report *"Detached with -force (volume was busy)"*. Something on this
machine — most likely a security agent scanning newly written files — can hold the
disk image briefly after a run, with no visible process responsible for it.

This is harmless. Pending writes are flushed before detaching, and the image is
verified afterwards by re-mounting it, so a forced detach cannot leave a damaged
image undetected. If verification ever fails, the run reports a clear error and
nothing is copied to OneDrive.

### The previous backup system

`backup_all.command` and `backup.d/` are the earlier tarball-based backup, kept
in place and untouched so the two can be compared. It writes to a destination
path from before the account rename and no longer functions. Both it and its
output in OneDrive (`working-folders.tar.gz` and the loose config files beside it)
can be removed once this system has proven itself.
