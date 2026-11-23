# Scan caching

Scanning a large folder from scratch takes a while. MacSize keeps the result of each scan
on disk, and the next time you scan the same folder it re-reads only the folders that
changed since. Both the app and the `macsize` CLI do this, and they share one cache.

The cache only saves time. Every result you see reflects the disk as it is now, never a
saved copy of how it was.

## How a cached scan is refreshed

1. Just before a full scan starts, MacSize records the current
   [FSEvents](https://developer.apple.com/documentation/coreservices/file_system_events)
   event ID. macOS keeps a persistent, per-volume log of which folders changed, and this ID
   marks a point in that log. It's captured *before* scanning so that anything changed
   while the scan runs is picked up next time.
2. When the scan finishes, the tree is saved together with that event ID, the volume's
   FSEvents UUID, the scan options and a few totals.
3. The next scan of the same folder with the same options loads the saved tree. It then
   asks FSEvents which folders under it changed since the saved event ID, re-lists only
   those folders, and splices the results into the tree. Totals are recomputed.
4. The refreshed tree is saved again with a new event ID.

The app does the same when it opens a folder that's in the cache. While a scan is shown
it also watches the folder live and applies changes as they happen.

## When MacSize falls back to a full scan

A cached tree is never trusted blindly. MacSize discards it and scans from scratch when:

- there's no cached scan for that folder, or it was made by an older version of MacSize;
- the scan options differ (`--one-file-system`, `--exclude`, `--no-system-excludes`).
  The thread count doesn't matter;
- the FSEvents history can't vouch for the whole period. This happens when the history was
  purged or reset, the volume was reformatted or replaced (a different volume UUID), events
  were dropped, or the scanned folder itself was moved, renamed or replaced;
- reading the history takes too long, or the refresh fails for any other reason.

Each fallback is a normal full scan, so the worst case is the speed you'd get without a cache.

## Where the cache lives

`~/Library/Caches/MacSize/Scans/`. There's one file per scanned folder, and only the
5 most recently used folders are kept. macOS may delete `~/Library/Caches` content when
disk space runs low; MacSize then simply scans from scratch.

For the CLI you can choose another location with `--cache-dir PATH` or the
`MACSIZE_CACHE_DIR` environment variable. `--cache-dir` wins.

## Privacy

A cached scan holds the names, sizes and structure of everything in the scanned folder: the
same information the scan shows you. It stays on your Mac. It isn't uploaded or synced, and
it's readable only by your user account. If you scan folders whose names are sensitive, you
can turn caching off (CLI: `--no-cache`) or clear it afterwards.

Running the CLI as root (for example with `sudo`) doesn't write to the cache. That way it
never leaves root-owned files in your cache folder. Pass `--cache-dir` explicitly if you
want root to keep its own cache. `MACSIZE_CACHE_DIR` alone doesn't count, because `sudo -E`
would pass it through without you noticing.

## CLI

`scan`, `largest` and `types` use the cache by default:

```
macsize ~/Projects            # first run: full scan, saved
macsize ~/Projects            # later: updated from the cache
macsize ~/Projects --verbose  # also prints e.g. "refreshed from cache: 3 folders rescanned in 0.04 s"
```

While it runs, the progress line on stderr says `Updating from cache (scanned 2 h ago)…` or
`Scanning…`.

| Option | Effect |
| --- | --- |
| `--no-cache` | Don't read or write the cache. |
| `--refresh`, `--full` | Rescan everything, ignoring the cached tree, and save the new result. |
| `--cache-dir PATH` | Use a different cache location (also `MACSIZE_CACHE_DIR`). |
| `--verbose` | Report on stderr how the cache was used. |

`macsize bench` never uses the cache. It always measures a raw full scan.

If the cache can't be written (permissions, a full disk), macsize prints one warning on
stderr and the command still succeeds.

### Managing the cache

```
macsize cache list            # root path, size on disk, when it was scanned, file count
macsize cache list --json
macsize cache remove PATH     # forget one folder
macsize cache clear           # delete everything and report the space freed
```

The `cache` commands take `--cache-dir` too.

## Clearing the cache

- CLI: `macsize cache clear`.
- Or delete `~/Library/Caches/MacSize/Scans/` yourself. It's safe to do so at any time;
  the next scan is just a full one.
