import Foundation
import MacSizeCore

enum Command: String {
    case scan, largest, types, bench, help, version
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

    static let usage = """
    macsize — fast disk usage analyzer for macOS

    USAGE
      macsize [scan] [PATH] [options]      Show a size-sorted tree (default command)
      macsize largest [PATH] [options]     List the largest files
      macsize types [PATH] [options]       Summarize usage by file extension
      macsize bench [PATH] [options]       Compare scan speed and totals against du(1)
      macsize help | --help                Show this help
      macsize version | --version          Show version

    PATH defaults to the current directory.

    OPTIONS
      -d, --depth N|all       Levels of the tree to print (default 2)
      -n, --top N|all         Max entries per directory (scan) (default 20)
      -c, --count N           Number of entries for `largest`/`types` (default 25)
      -m, --min-size SIZE     Hide entries smaller than SIZE, e.g. 100M, 1.5G, 512KiB
          --logical           Rank by logical size instead of size on disk
          --binary            Use 1024-based units (KiB, MiB, ...)
          --json              Emit JSON instead of text
          --no-bars           Don't draw percentage bars
      -q, --quiet             Don't show progress on stderr
      -j, --threads N         Worker threads (default \(ScanOptions.defaultThreadCount))
      -x, --one-file-system   Don't cross into other volumes
      -e, --exclude PATH      Don't descend into PATH (repeatable)
          --no-system-excludes
                              Also scan \(ScanOptions.systemExcludedPaths.joined(separator: ", "))
          --runs N            Repetitions for `bench` (default 1; best time reported)
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
            case "--":
                positional.append(contentsOf: remaining)
                remaining = []
            default:
                if arg.hasPrefix("-") && arg.count > 1 { throw CLIError("Unknown option: \(arg)\nRun `macsize --help` for usage.") }
                positional.append(arg)
            }
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
