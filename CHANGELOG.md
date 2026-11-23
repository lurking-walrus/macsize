# Changelog

All notable changes to MacSize are documented here. Versions follow
[Semantic Versioning](https://semver.org/), and each version is a
[GitHub Release](https://github.com/lurking-walrus/treesize-mac/releases).

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
