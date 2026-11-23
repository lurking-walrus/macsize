import CoreServices
import Foundation

/// Live FSEvents watcher for a scanned root (used while the app is open).
///
/// Uses a directory-level `FSEventStream` (`sinceWhen` = the given event ID, or "now")
/// on a private dispatch queue. FSEvents coalesces bursts over `latency`; each delivered
/// batch is folded into one `ChangeSet` with the same normalization and flag rules as
/// `ChangeJournal`, and passed to `handler` unless it is empty. `start()` and `stop()`
/// are idempotent; restarting resumes after the last event already delivered. The
/// watcher stops itself on deinit. It only observes metadata events, so it never causes
/// cloud files to download.
public final class ChangeWatcher: @unchecked Sendable {
    public let rootPath: String
    public let latency: TimeInterval

    private let resolvedRoot: String
    private let handler: @Sendable (ChangeSet) -> Void
    private let lock = NSLock()
    private var stream: EventStream?
    private var resumeEventID: UInt64?

    /// `handler` is called on a background queue with coalesced changes.
    public init(rootPath: String, sinceEventID: UInt64? = nil, latency: TimeInterval = 1.0,
                handler: @escaping @Sendable (ChangeSet) -> Void) {
        self.rootPath = rootPath
        self.latency = latency
        self.resolvedRoot = DiskScanner.resolveRoot(rootPath)
        self.handler = handler
        self.resumeEventID = sinceEventID
    }

    deinit { stop() }

    /// Whether the watcher currently has a running stream.
    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return stream != nil
    }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard stream == nil else { return }

        let root = resolvedRoot
        let handler = handler
        // Weak, so a running stream never keeps the watcher alive (deinit stops it).
        let stream = EventStream(label: "MacSize change watcher") { [weak self] events in
            var accumulator = ChangeAccumulator(rootPath: root)
            for event in events { accumulator.add(event) }
            if accumulator.maxEventID > 0 { self?.noteDelivered(accumulator.maxEventID) }
            guard accumulator.hasChanges else { return }
            // Report the newest event actually delivered: events after it arrive in a later batch.
            let fallback = accumulator.maxEventID > 0 ? 0 : ChangeJournal.currentEventID()
            handler(accumulator.makeChangeSet(fallbackEventID: fallback))
        }
        let since = resumeEventID ?? UInt64(kFSEventStreamEventIdSinceNow)
        let flags = kFSEventStreamCreateFlagWatchRoot
        if stream.start(path: root, since: since, latency: max(0, latency), flags: flags) {
            self.stream = stream
        }
    }

    public func stop() {
        lock.lock()
        let current = stream
        stream = nil
        lock.unlock()
        current?.stop()
    }

    private func noteDelivered(_ eventID: UInt64) {
        lock.lock()
        resumeEventID = max(resumeEventID ?? 0, eventID)
        lock.unlock()
    }
}
