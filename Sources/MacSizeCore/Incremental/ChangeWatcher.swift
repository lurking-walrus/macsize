import Foundation

/// Live FSEvents watcher for a scanned root (used while the app is open).
///
/// FOUNDATION STUB: never reports changes. The incremental agent implements it with
/// an FSEventStream (directory-level events, ~1 s latency, coalesced).
public final class ChangeWatcher: @unchecked Sendable {
    public let rootPath: String
    public let latency: TimeInterval

    /// `handler` is called on a background queue with coalesced changes.
    public init(rootPath: String, sinceEventID: UInt64? = nil, latency: TimeInterval = 1.0,
                handler: @escaping @Sendable (ChangeSet) -> Void) {
        self.rootPath = rootPath
        self.latency = latency
    }

    public func start() {}
    public func stop() {}
}
