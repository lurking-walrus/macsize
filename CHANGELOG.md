# Changelog

All notable changes to MacSize are documented here. Versions follow
[Semantic Versioning](https://semver.org/), and each version is a
[GitHub Release](https://github.com/lurking-walrus/treesize-mac/releases).

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
