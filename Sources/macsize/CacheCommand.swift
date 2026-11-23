import Foundation
import MacSizeCore

/// Where the scan cache lives for this run: `--cache-dir`, else `MACSIZE_CACHE_DIR`, else
/// the location shared with MacSize.app.
struct CacheLocation {
    let directory: URL
    /// True only for `--cache-dir`. Under sudo we save only to a location named on the
    /// command line, so an inherited `MACSIZE_CACHE_DIR` can't collect root-owned files.
    let isExplicitFlag: Bool

    init(args: Arguments, environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let path = args.cacheDirectory {
            directory = Self.url(path)
            isExplicitFlag = true
        } else if let path = environment["MACSIZE_CACHE_DIR"], !path.isEmpty {
            directory = Self.url(path)
            isExplicitFlag = false
        } else {
            directory = ScanCache.defaultDirectory
            isExplicitFlag = false
        }
    }

    private static func url(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }
}

/// `macsize cache list|clear|remove PATH`.
struct CacheCommand {
    let args: Arguments

    func run() throws {
        let location = CacheLocation(args: args)
        let cache = ScanCache(directory: location.directory)
        switch args.cacheAction {
        case .list: try list(cache, location: location)
        case .clear: try clear(cache, location: location)
        case .remove(let path): try remove(path, from: cache)
        }
    }

    private struct EntryReport: Encodable {
        var rootPath: String
        var sizeOnDisk: Int64
        var scannedAt: Date
        var fileCount: Int
        var directoryCount: Int
        var allocatedSize: Int64
        var logicalSize: Int64
        var file: String
    }

    private func list(_ cache: ScanCache, location: CacheLocation) throws {
        let entries = cache.entries().sorted { $0.metadata.scannedAt > $1.metadata.scannedAt }
        if args.json {
            let reports = entries.map {
                EntryReport(
                    rootPath: $0.metadata.rootPath, sizeOnDisk: $0.sizeOnDisk, scannedAt: $0.metadata.scannedAt,
                    fileCount: $0.metadata.fileCount, directoryCount: $0.metadata.directoryCount,
                    allocatedSize: $0.metadata.allocatedSize, logicalSize: $0.metadata.logicalSize,
                    file: $0.fileURL.path
                )
            }
            FileHandle.standardOutput.write(try MacSizeCLI.encoder().encode(reports))
            print()
            return
        }
        guard !entries.isEmpty else {
            print("No cached scans in \(location.directory.path)")
            return
        }
        let iso = ISO8601DateFormatter()
        print(pad("CACHE", 10) + "  " + padRight("SCANNED", 12) + "  " + padRight("AT", 20) + "  " + pad("FILES", 12) + "  PATH")
        for entry in entries {
            let meta = entry.metadata
            print(
                pad(format(entry.sizeOnDisk, args), 10) + "  "
                    + padRight(RelativeTime.short(since: meta.scannedAt), 12) + "  "
                    + padRight(iso.string(from: meta.scannedAt), 20) + "  "
                    + pad(SizeFormatter.grouped(meta.fileCount), 12) + "  "
                    + meta.rootPath
            )
        }
        let total = entries.reduce(Int64(0)) { $0 + $1.sizeOnDisk }
        print("\n\(entries.count) cached scan\(entries.count == 1 ? "" : "s"), \(format(total, args)) in \(location.directory.path)")
    }

    private func clear(_ cache: ScanCache, location: CacheLocation) throws {
        let entries = cache.entries()
        let freed = entries.reduce(Int64(0)) { $0 + $1.sizeOnDisk }
        try cache.clear()
        print("Removed \(entries.count) cached scan\(entries.count == 1 ? "" : "s"), freed \(format(freed, args)) (\(location.directory.path))")
    }

    private func remove(_ path: String, from cache: ScanCache) throws {
        let rootPath = CachedScan.resolveRoot(path)
        let existing = cache.entries().first { $0.metadata.rootPath == rootPath }
        let known = existing != nil || cache.metadata(rootPath: rootPath) != nil
        try cache.remove(rootPath: rootPath)
        if known {
            let freed = existing.map { " (freed \(format($0.sizeOnDisk, args)))" } ?? ""
            print("Removed the cached scan of \(rootPath)\(freed)")
        } else {
            print("No cached scan of \(rootPath)")
        }
    }
}

func padRight(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

/// Compact relative times: "just now", "42 s ago", "5 min ago", "2 h ago", "3 d ago".
enum RelativeTime {
    static func short(since date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<5: return "just now"
        case ..<60: return "\(seconds) s ago"
        case ..<3600: return "\(seconds / 60) min ago"
        case ..<86_400: return "\(seconds / 3600) h ago"
        default: return "\(seconds / 86_400) d ago"
        }
    }
}
