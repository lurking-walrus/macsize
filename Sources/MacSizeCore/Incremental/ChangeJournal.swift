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
    ///
    /// Replays directory-level events through a temporary `FSEventStream` (`sinceWhen:
    /// eventID`) until `kFSEventStreamEventFlagHistoryDone`. Reports `requiresFullRescan`
    /// when `eventID` is 0 or in the future, the volume UUID differs from
    /// `expectedVolumeUUID`, the stream can't be created, the timeout passes, or the
    /// history says it can't be trusted (root changed, IDs wrapped, events dropped or
    /// must-scan-subdirs at or above the root). Must-scan-subdirs/dropped events below the
    /// root become `recursiveDirectories`. `latestEventID` is the newest event seen, or the
    /// current ID taken just before the replay started if that is newer.
    public static func changes(since eventID: UInt64, under rootPath: String,
                               expectedVolumeUUID: String?, timeout: TimeInterval = 10) -> ChangeSet {
        let startID = currentEventID()
        guard eventID != 0, eventID <= startID else { return .fullRescan(latestEventID: startID) }

        let root = DiskScanner.resolveRoot(rootPath)
        if let expectedVolumeUUID, volumeUUID(forPath: root) != expectedVolumeUUID {
            return .fullRescan(latestEventID: startID)
        }

        let collector = ReplayCollector(rootPath: root)
        let stream = EventStream(label: "MacSize change journal") { events in
            collector.add(events)
        }
        let flags = kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot
        guard stream.start(path: root, since: eventID, latency: 0, flags: flags) else {
            return .fullRescan(latestEventID: startID)
        }
        let finished = collector.done.wait(timeout: .now() + max(0, timeout)) == .success
        stream.stop()
        guard finished else { return .fullRescan(latestEventID: startID) }
        return collector.changeSet(fallbackEventID: startID)
    }
}

/// Thread-safe accumulator for a history replay; signals `done` on HistoryDone.
private final class ReplayCollector: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var accumulator: ChangeAccumulator
    private var signalled = false

    init(rootPath: String) {
        accumulator = ChangeAccumulator(rootPath: rootPath)
    }

    func add(_ events: [FSEvent]) {
        lock.lock()
        for event in events { accumulator.add(event) }
        let finished = accumulator.historyDone && !signalled
        if finished { signalled = true }
        lock.unlock()
        if finished { done.signal() }
    }

    func changeSet(fallbackEventID: UInt64) -> ChangeSet {
        lock.lock(); defer { lock.unlock() }
        return accumulator.makeChangeSet(fallbackEventID: fallbackEventID)
    }
}
