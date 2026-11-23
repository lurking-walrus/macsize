import Foundation

/// The outcome of an incremental refresh, computed off the main thread and applied
/// with `FileNode.apply(_:)` where nothing else is reading the tree.
public struct RefreshResult: @unchecked Sendable {
    /// Set when the tree had to be rebuilt from scratch; display this instead.
    public var newRoot: FileNode?
    /// Opaque per-directory replacements produced by `IncrementalScanner`.
    /// (The incremental agent defines its contents.)
    public var updates: [DirectoryUpdate]
    public var directoriesRescanned: Int
    public var didFullRescan: Bool
    /// Event ID to store in the refreshed snapshot's metadata.
    public var eventID: UInt64

    public init(newRoot: FileNode? = nil, updates: [DirectoryUpdate] = [], directoriesRescanned: Int = 0,
                didFullRescan: Bool, eventID: UInt64) {
        self.newRoot = newRoot
        self.updates = updates
        self.directoriesRescanned = directoriesRescanned
        self.didFullRescan = didFullRescan
        self.eventID = eventID
    }

    public var isEmpty: Bool { newRoot == nil && updates.isEmpty }
}

/// A freshly re-listed directory to splice into an existing tree.
/// FOUNDATION STUB: the incremental agent fills this in.
public struct DirectoryUpdate: @unchecked Sendable {
    public var path: String
    public init(path: String) { self.path = path }
}

/// Re-scans only what changed in an existing tree.
///
/// FOUNDATION STUB: always performs a full rescan. The incremental agent replaces the
/// bodies; the public API is the contract.
public final class IncrementalScanner: @unchecked Sendable {
    public let options: ScanOptions
    public let progress = ScanProgress()

    public init(options: ScanOptions = ScanOptions()) {
        self.options = options
    }

    public func cancel() { progress.cancel() }

    /// Compute a refresh for `root` given `changes`. Only *reads* `root`, so it's safe to
    /// run while the UI is displaying the same tree. Runs blocking I/O off the
    /// cooperative pool. Cancelling the task cancels the refresh.
    public func computeRefresh(for root: FileNode, changes: ChangeSet) async throws -> RefreshResult {
        let fresh = try await DiskScanner(options: options).scan(path: root.path)
        return RefreshResult(newRoot: fresh, didFullRescan: true, eventID: changes.latestEventID)
    }
}

extension FileNode {
    /// Apply a refresh in place and return the root to display (`result.newRoot` if the
    /// tree was rebuilt, else `self`). Must run where nothing else is reading or mutating
    /// the tree (e.g. on the main actor that owns it). Re-aggregates totals and keeps
    /// children sorted by `metric`.
    @discardableResult
    public func apply(_ result: RefreshResult, metric: SizeMetric = .allocated) -> FileNode {
        result.newRoot ?? self
    }
}
