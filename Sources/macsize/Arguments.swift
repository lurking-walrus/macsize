import Foundation
import MacSizeCore

enum Command: String {
    case scan, largest, types, bench, update, cache, help, version
}

enum CacheAction: Equatable {
    case list
    case clear
    case remove(path: String)
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Minimal, dependency-free argument parsing.
struct Arguments {
    var command: Command = .scan
    var path = "."
    var depth: Int? = 2
    var top: Int? = 20
    var count = 25
    var minimumSize: Int64 = 0
    var metric: SizeMetric = .allocated
    var binaryUnits = false
    var json = false
    var showBars = true
    var quiet = false
    var threads = ScanOptions.defaultThreadCount
    var stayOnFileSystem = false
    var excludes: [String] = []
    var systemExclusions = true
    var runs = 1
    var checkOnly = false
    var verbose = false
    /// Read and write the scan cache (`--no-cache` turns both off).
    var useCache = true
    /// Ignore the cached tree but save the new one (`--refresh` / `--full`).
    var forceFull = false
    /// `--cache-dir`; nil means `MACSIZE_CACHE_DIR` or the default location.
    var cacheDirectory: String?
    var cacheAction: CacheAction = .list

    static let usage = """
    macsize — fast disk usage analyzer for macOS

    USAGE
      macsize [scan] [PATH] [options]      Show a size-sorted tree (default command)
      macsize largest [PATH] [options]     List the largest files
      macsize types [PATH] [options]       Summarize usage by file extension
      macsize bench [PATH] [options]       Compare scan speed and totals against du(1)
      macsize update [--check]             Update macsize to the latest release
      macsize cache list [--json]          List cached scans
      macsize cache clear                  Delete all cached scans
      macsize cache remove PATH            Delete the cached scan of PATH
      macsize help | --help                Show this help
      macsize version | --version          Show version

    PATH defaults to the current directory.

    `scan`, `largest` and `types` cache each scan. The next run for the same PATH and
    options re-reads only the folders that changed since (from the FSEvents history), so
    results always match the disk. `bench` never uses the cache.

    OPTIONS
      -d, --depth N|all       Levels of the tree to print (default 2)
      -n, --top N|all         Max entries per directory (scan) (default 20)
      -c, --count N           Number of entries for `largest`/`types` (default 25)
      -m, --min-size SIZE     Hide entries smaller than SIZE, e.g. 100M, 1.5G, 512KiB
          --logical           Rank by logical size instead of size on disk (includes cloud-only files)
          --binary            Use 1024-based units (KiB, MiB, ...)
          --json              Emit JSON instead of text
          --no-bars           Don't draw percentage bars
      -q, --quiet             Don't show progress on stderr
          --verbose           Report cache use on stderr
      -j, --threads N         Worker threads (default \(ScanOptions.defaultThreadCount))
      -x, --one-file-system   Don't cross into other volumes
      -e, --exclude PATH      Don't descend into PATH (repeatable)
          --no-system-excludes
                              Also scan \(ScanOptions.systemExcludedPaths.joined(separator: ", "))
          --runs N            Repetitions for `bench` (default 1; best time reported)
          --check             With `update`: only report whether a newer version exists
          --no-cache          Don't read or write the scan cache
          --refresh, --full   Rescan everything, ignoring the cached tree (still saves it)
          --cache-dir PATH    Cache location (default ~/Library/Caches/MacSize/Scans)

    ENVIRONMENT
      MACSIZE_NO_UPDATE_NOTIFIER=1
                              Don't check for new versions in the background
      MACSIZE_CACHE_DIR=PATH  Cache location, overridden by --cache-dir
    """

    static func parse(_ raw: [String]) throws -> Arguments {
        var args = Arguments()
        var remaining = raw[...]
        // `swift run macsize -- args` forwards the separator itself; ignore a leading one.
        if remaining.first == "--" { remaining.removeFirst() }
        var positional: [String] = []

        func value(for flag: String) throws -> String {
            guard let next = remaining.popFirst() else { throw CLIError("Missing value for \(flag)") }
            return next
        }
        func integer(for flag: String, allowAll: Bool = false) throws -> Int? {
            let text = try value(for: flag)
            if allowAll && text.lowercased() == "all" { return nil }
            guard let number = Int(text), number >= 0 else { throw CLIError("Invalid number for \(flag): \(text)") }
            return number
        }

        if let first = remaining.first, let command = Command(rawValue: first) {
            args.command = command
            remaining.removeFirst()
        }

        while let arg = remaining.popFirst() {
            switch arg {
            case "-h", "--help": args.command = .help
            case "-V", "--version": args.command = .version
            case "-d", "--depth": args.depth = try integer(for: arg, allowAll: true)
            case "-n", "--top": args.top = try integer(for: arg, allowAll: true)
            case "-c", "--count": args.count = try integer(for: arg) ?? 25
            case "-m", "--min-size":
                let text = try value(for: arg)
                guard let size = SizeFormatter.parse(text) else { throw CLIError("Invalid size: \(text)") }
                args.minimumSize = size
            case "--logical": args.metric = .logical
            case "--binary": args.binaryUnits = true
            case "--json": args.json = true
            case "--no-bars": args.showBars = false
            case "-q", "--quiet": args.quiet = true
            case "-j", "--threads": args.threads = max(1, try integer(for: arg) ?? 1)
            case "-x", "--one-file-system": args.stayOnFileSystem = true
            case "-e", "--exclude": args.excludes.append(try value(for: arg))
            case "--no-system-excludes": args.systemExclusions = false
            case "--runs": args.runs = max(1, try integer(for: arg) ?? 1)
            case "--check": args.checkOnly = true
            case "--verbose": args.verbose = true
            case "--no-cache": args.useCache = false
            case "--refresh", "--full": args.forceFull = true
            case "--cache-dir":
                let path = try value(for: arg)
                guard !path.isEmpty else { throw CLIError("--cache-dir needs a non-empty PATH") }
                args.cacheDirectory = path
            case "--":
                positional.append(contentsOf: remaining)
                remaining = []
            default:
                if arg.hasPrefix("-") && arg.count > 1 { throw CLIError("Unknown option: \(arg)\nRun `macsize --help` for usage.") }
                positional.append(arg)
            }
        }

        if args.checkOnly && args.command != .update && args.command != .help {
            throw CLIError("--check is only valid with `macsize update`")
        }
        if args.command == .update && !positional.isEmpty {
            throw CLIError("`macsize update` doesn't take a PATH")
        }
        if args.command == .cache {
            switch positional.first ?? "list" {
            case "list", "ls": args.cacheAction = .list
            case "clear": args.cacheAction = .clear
            case "remove", "rm":
                guard positional.count == 2 else { throw CLIError("Usage: macsize cache remove PATH") }
                args.cacheAction = .remove(path: positional[1])
                return args
            default:
                throw CLIError("Unknown cache action: \(positional[0]). Expected list, clear or remove PATH.")
            }
            if positional.count > 1 { throw CLIError("`macsize cache \(positional[0])` doesn't take a PATH") }
            return args
        }
        if positional.count > 1 { throw CLIError("Expected a single PATH, got: \(positional.joined(separator: " "))") }
        if let path = positional.first { args.path = path }
        return args
    }

    var scanOptions: ScanOptions {
        ScanOptions(
            threadCount: threads,
            stayOnFileSystem: stayOnFileSystem,
            excludedPaths: excludes,
            applySystemExclusions: systemExclusions
        )
    }
}
