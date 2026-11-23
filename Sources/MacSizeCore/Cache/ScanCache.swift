import Foundation

/// On-disk store of scan snapshots, shared by the app and the CLI.
///
/// FOUNDATION STUB: the cache agent replaces the bodies (compact compressed
/// binary encoding, atomic writes, LRU eviction). The public API is the contract.
public final class ScanCache: @unchecked Sendable {
    /// `~/Library/Caches/MacSize/Scans`, shared by MacSize.app (any build) and `macsize`.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacSize", isDirectory: true)
            .appendingPathComponent("Scans", isDirectory: true)
    }

    public let directory: URL
    /// Most snapshots kept; least recently used are evicted on save.
    public let maxEntries: Int

    public init(directory: URL = ScanCache.defaultDirectory, maxEntries: Int = 5) {
        self.directory = directory
        self.maxEntries = maxEntries
    }

    /// Summary of one cached snapshot (cheap: doesn't decode the tree).
    public struct Entry: Sendable, Equatable {
        public var metadata: ScanSnapshotMetadata
        public var fileURL: URL
        public var sizeOnDisk: Int64
    }

    /// The cached snapshot for `rootPath` (resolved, as `DiskScanner` reports it), or nil
    /// if none exists, it's unreadable/corrupt, the format version is old, or it was made
    /// with different options. Never throws for a cache miss.
    public func load(rootPath: String, optionsFingerprint: String) -> ScanSnapshot? {
        nil
    }

    /// Only the metadata for `rootPath`, without decoding the tree.
    public func metadata(rootPath: String) -> ScanSnapshotMetadata? {
        nil
    }

    /// Write (atomically) and evict older entries beyond `maxEntries`.
    /// Reads `snapshot.root`; don't mutate the tree concurrently.
    public func save(_ snapshot: ScanSnapshot) throws {}

    public func remove(rootPath: String) throws {}

    public func entries() -> [Entry] { [] }

    public func clear() throws {}
}
