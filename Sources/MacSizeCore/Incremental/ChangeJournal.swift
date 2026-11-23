import CoreServices
import Foundation

/// What changed under a scanned root since a given FSEvents event ID.
public struct ChangeSet: Sendable, Equatable {
    /// Directories whose *direct* entries must be re-listed (subdirectories that still
    /// exist and aren't listed elsewhere are reused from the old tree).
    public var directories: Set<String>
    /// Directories whose entire subtree must be rescanned (FSEvents MustScanSubDirs).
    public var recursiveDirectories: Set<String>
    /// History unavailable or untrustworthy (purged, wrapped, volume changed, root
    /// changed, events dropped at the root…): discard the tree and scan from scratch.
    public var requiresFullRescan: Bool
    /// Event ID to store in the refreshed snapshot.
    public var latestEventID: UInt64

    public init(directories: Set<String> = [], recursiveDirectories: Set<String> = [],
                requiresFullRescan: Bool = false, latestEventID: UInt64) {
        self.directories = directories
        self.recursiveDirectories = recursiveDirectories
        self.requiresFullRescan = requiresFullRescan
        self.latestEventID = latestEventID
    }

    public var isEmpty: Bool { directories.isEmpty && recursiveDirectories.isEmpty && !requiresFullRescan }

    public static func fullRescan(latestEventID: UInt64) -> ChangeSet {
        ChangeSet(requiresFullRescan: true, latestEventID: latestEventID)
    }
}

/// Reads the persistent FSEvents history.
///
/// FOUNDATION STUB for `changes(since:under:)`; the incremental agent implements it.
public enum ChangeJournal {
    /// Current system-wide FSEvents event ID. Capture *before* starting a full scan.
    public static func currentEventID() -> UInt64 {
        FSEventsGetCurrentEventId()
    }

    /// FSEvents UUID for the volume containing `path` (nil if unavailable).
    public static func volumeUUID(forPath path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0, let uuid = FSEventsCopyUUIDForDevice(info.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// Directories under `rootPath` changed since `eventID`. Blocks until history is replayed
    /// or `timeout` elapses (then reports a full rescan).
    public static func changes(since eventID: UInt64, under rootPath: String,
                               expectedVolumeUUID: String?, timeout: TimeInterval = 10) -> ChangeSet {
        .fullRescan(latestEventID: currentEventID())
    }
}
