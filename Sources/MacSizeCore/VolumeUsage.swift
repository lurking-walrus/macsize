import Foundation

/// How full a volume is, in the two ways macOS reports it.
///
/// APFS counts *purgeable* data as in use: local Time Machine snapshots, cached files,
/// and downloaded iCloud/File Provider files macOS can evict and fetch again. System
/// Settings and Finder treat that space as available, because macOS frees it on demand
/// when something needs room. `df` and Disk Utility count it as used.
public struct VolumeUsage: Sendable, Equatable {
    /// Capacity of the volume (for APFS, the container it lives in).
    public let total: Int64
    /// Space not allocated to anything (`df`'s "Available").
    public let free: Int64
    /// Space available once macOS purges what it can (System Settings' "available").
    public let available: Int64

    public init(total: Int64, free: Int64, available: Int64) {
        self.total = max(0, total)
        self.free = min(max(0, free), self.total)
        // Purging can only add space, never take it away.
        self.available = min(max(self.free, available), self.total)
    }

    /// Used space as System Settings and Finder report it (purgeable excluded).
    public var used: Int64 { total - available }
    /// Space macOS can reclaim on its own.
    public var purgeable: Int64 { available - free }
    /// Used space as APFS, `df` and Disk Utility report it (purgeable included).
    public var inUse: Int64 { total - free }

    /// Reads the usage of the volume containing `url`. Asking for the
    /// purgeable-aware figure can take a moment, so call it off the main thread.
    public static func read(for url: URL) -> VolumeUsage? {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let free = values.volumeAvailableCapacity else { return nil }
        // Volumes without purgeable accounting (FAT, network shares) report nil here.
        let available = values.volumeAvailableCapacityForImportantUsage ?? Int64(free)
        return VolumeUsage(total: Int64(total), free: Int64(free), available: available)
    }
}
