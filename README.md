# treesize-mac

A fast, native disk-usage analyzer for macOS, inspired by TreeSize. It comes as
a SwiftUI desktop app and a command-line tool, both built on the same scanner engine.

- **Fast scanning.** Uses `getattrlistbulk(2)` to read names, types and sizes for
  many directory entries per syscall, with a pool of worker threads walking the tree in parallel.
- **Correct sizes.** Reports *size on disk* (allocated blocks) by default, so APFS
  compression, sparse files and clones are counted the way `du` counts them. Hard links are
  counted once. Switch to *logical size* at any time.
- **Treemap.** A nested, squarified treemap drawn with SwiftUI `Canvas`. Click to select,
  double-click to zoom in, and use the breadcrumb bar to zoom out.
- **Finder actions.** Reveal in Finder, Open, Copy Path, and Move to Trash (with confirmation).
- **CLI.** Size-sorted trees, largest files, per-extension summaries, JSON output, and a
  benchmark against `du`.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 16 or later (Swift 6 toolchain)

## Layout

```
Package.swift
Sources/
  TreeSizeCore/   Scanner engine (library): getattrlistbulk reader, parallel scanner,
                  tree model, treemap layout, JSON export, size formatting
  treesize/       Command-line tool
  TreeSizeApp/    SwiftUI app (outline table + treemap)
Tests/
  TreeSizeCoreTests/
scripts/
  build-app.sh    Wraps the app executable in a signed .app bundle
  install.sh      Installs the CLI (and optionally the app)
```

## Command-line tool

```bash
swift build -c release --product treesize
.build/release/treesize --help
```

```bash
treesize ~/Downloads                 # size-sorted tree, 2 levels deep, top 20 per folder
treesize ~ -d 1 -n 10 --min-size 1G  # one level, top 10, hide entries under 1 GB
treesize largest ~ -c 50             # 50 largest files
treesize types ~/Movies              # usage by file extension
treesize ~/Projects --json -d all    # full tree as JSON
treesize bench /Applications --runs 3
```

Example output (`treesize /usr/share -d 1 -n 4`):

```
    266 MB 100.0%  ████████████  /usr/share
   68.1 MB  25.6%  ███░░░░░░░░░  ├── tokenizer/
   46.9 MB  17.6%  ██░░░░░░░░░░  ├── firmware/
   28.3 MB  10.7%  █░░░░░░░░░░░  ├── morphun/
   24.6 MB   9.3%  █░░░░░░░░░░░  ├── vim/
   97.7 MB  36.8%  ████░░░░░░░░  └── … 39 more

266 MB in 19,288 files, 891 folders (size on disk)
```

Options include `--logical`, `--binary` (KiB/MiB), `-x/--one-file-system`, `-e/--exclude PATH`
(repeatable), `-j/--threads N`, and `-q/--quiet`. Run `treesize --help` for the full list.

When the scan root is `/`, a few system paths are skipped by default (`/dev`, `/Volumes`,
`/Network`, and `/System/Volumes/Data`, which would otherwise be counted twice through APFS
firmlinks). Pass `--no-system-excludes` to include them.

### Benchmarking against `du`

`treesize bench PATH` runs the scanner and `du -sk` on the same path, alternating which goes
first, and reports the best time and the size difference. Small differences are expected
because `du` also counts the blocks used by directories themselves.

## Desktop app

Run it straight from the package during development:

```bash
swift run TreeSizeApp                 # opens the welcome screen
swift run TreeSizeApp -- ~/Downloads  # scans a path on launch
```

Or build a proper `.app` bundle:

```bash
scripts/build-app.sh
open build/TreeSize.app
```

`build-app.sh` is configured entirely through environment variables. Nothing about any
particular machine or developer is baked in:

| Variable        | Default                | Purpose                                  |
|-----------------|------------------------|------------------------------------------|
| `APP_NAME`      | `TreeSize`             | Bundle and executable name               |
| `BUNDLE_ID`     | `com.example.treesize` | `CFBundleIdentifier`; set your own       |
| `VERSION`       | `0.1.0`                | `CFBundleShortVersionString`             |
| `BUILD_NUMBER`  | `1`                    | `CFBundleVersion`                        |
| `CONFIGURATION` | `release`              | `swift build` configuration              |
| `OUTPUT_DIR`    | `./build`              | Output directory                         |
| `SIGN_IDENTITY` | `-` (ad-hoc)           | `codesign` identity, e.g. a Developer ID |

To install:

```bash
PREFIX="$HOME/.local" APP_DEST="$HOME/Applications" scripts/install.sh
```

### Full Disk Access

macOS protects some locations (Mail, Messages, Safari data, other users' folders, and so on).
Without Full Disk Access these folders show a lock icon and are counted as empty. To grant
access, open **System Settings › Privacy & Security › Full Disk Access** and add TreeSize.app,
or add your terminal app if you use the CLI. Both the app and the CLI tell you when items
couldn't be read.

## Development

```bash
swift build      # all targets
swift test       # scanner, formatter and treemap tests
```

The tests build throwaway directory trees in the system temporary directory. They cover
nested totals, buffer refills on large directories, hard links, symlinks, exclusions, the
JSON export and treemap geometry.

## License

MIT. See [LICENSE](LICENSE).
