# Changelog

All notable changes to MacSize are documented here. Versions follow
[Semantic Versioning](https://semver.org/), and each version is a
[GitHub Release](https://github.com/lurking-walrus/treesize-mac/releases).

**From 0.1.10 on, release notes are generated from commit messages and published on each
[GitHub Release](https://github.com/lurking-walrus/treesize-mac/releases)**; this file keeps
the earlier history. See [docs/RELEASING.md](docs/RELEASING.md).

## 0.1.9

- **Disk usage that matches System Settings**: the status bar shows how full the
  scanned volume is ("648 GB used · 296 GB purgeable") and the start screen shows
  space available. Purgeable space (local Time Machine snapshots, caches,
  downloaded iCloud files macOS can evict) counts as available, as in System
  Settings and Finder. Turn on **Count Purgeable Space as Used** (Options menu or
  Settings → General) to see the APFS figure that Disk Utility and `df` report.

## 0.1.8

- **About a third less memory**: each scanned item takes 96 bytes instead of 128,
  and the per-item lookup table the app kept alongside the tree is gone. A scan of
  ~1 million files now needs about 194 MB instead of 291 MB, and live updates no
  longer briefly hold two copies of that table.
- **Lower CPU while scanning**: scans use at most 8 worker threads. More threads
  weren't faster (folder listing is limited by the kernel) but used ~65% more CPU.

## 0.1.7

- **Truer totals**: Logical Size no longer counts cloud-only files, so it shows what
  is actually stored on this Mac (cloud-only items are still listed with ☁︎).
- **No double counting of mounted disk images**: scanning `/` now skips read-only
  mounts of disk images and cryptexes (such as the iOS Simulator runtimes under
  `/private/var/run/com.apple.security.cryptexd`), which duplicated tens of GB that
  is already counted as the image files. Existing cached scans are rebuilt once.

## 0.1.6

- **Expanded folders stay expanded**: live updates, Rescan and changing the size
  metric no longer collapse the folders you opened in the file list.

## 0.1.5

- **Extra warning for sensitive items**: moving important user data or system
  locations to the Trash (Keychains, iCloud Drive, Mail, Messages, `~/.ssh`,
  Documents, Desktop, Application Support, installed apps, media libraries and
  similar) now shows a "Careful" confirmation that explains why. You can still
  go ahead with **Move to Trash Anyway**; items stay recoverable from the Trash.
- **CLI**: `macsize` and `macsize largest` mark those same items with ⚠ and a
  short reason in their text output.

## 0.1.4

- **Layout sticks after a rescan**: the divider between the file list and the
  treemap, and the file list's column widths, no longer reset to their defaults
  when results are refreshed. The divider position is also remembered across
  launches.

## 0.1.3

- **Smart caching**: scans are saved, so reopening a folder shows results
  instantly and then refreshes only what changed (using macOS FSEvents).
  Rescan (⌘R) is incremental; Full Rescan (⇧⌘R) starts over.
- **Live updates**: results update automatically while files change
  (Settings › General to turn off).
- **Cloud storage awareness**: iCloud Drive, Google Drive, OneDrive and Dropbox
  files that are only in the cloud are marked ☁︎ and count as 0 bytes on disk.
  Folders show how much of them is cloud-only. MacSize never causes cloud files
  to download. iCloud Drive items can be un-downloaded with **Remove Download**.
- **CLI**: uses the same cache (`--no-cache`, `--refresh`,
  `macsize cache list|clear|remove`), and shows ☁︎ cloud-only items.
- Settings now has a **General** tab (live updates, remembering scans, clearing
  the cache).

## 0.1.2

- **Full Disk Access helper** on the welcome screen: shows whether access is
  granted, and if not, walks you through it with a MacSize icon you can drag
  straight into System Settings and a one-click relaunch.

## 0.1.1

- Add this changelog.
- First release delivered through auto-update: the app updates itself via
  Sparkle, and `macsize` updates with it when it's linked to the app.

## 0.1.0

First public release.

- **MacSize.app**: fast parallel scanner (`getattrlistbulk`), size-sorted
  outline, squarified treemap, Finder actions, Full Disk Access helper.
- **`macsize` CLI**: trees, `largest`, `types`, `bench` vs `du`, JSON output,
  update notice and `macsize update`.
- One-click install of the CLI from the app's welcome screen.
- Automatic updates for the app (Sparkle 2), signed and notarized with
  Developer ID.
