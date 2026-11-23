import Darwin
import Foundation

/// The outcome of an incremental refresh, computed off the main thread and applied
/// with `FileNode.apply(_:)` where nothing else is reading the tree.
public struct RefreshResult: @unchecked Sendable {
    /// Set when the tree had to be rebuilt from scratch; display this instead.
    public var newRoot: FileNode?
    /// Per-directory replacements produced by `IncrementalScanner`, deepest first.
    public var updates: [DirectoryUpdate]
    /// Directories read from disk for this refresh (re-listed plus newly scanned subtrees).
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
///
/// `children` mixes detached new nodes (files, and freshly scanned subdirectories with
/// finalized totals) with *reused* subtree nodes from the old tree. Nothing in the old
/// tree is modified until `FileNode.apply(_:metric:)` reparents them.
public struct DirectoryUpdate: @unchecked Sendable {
    /// Absolute path of the directory in the tree.
    public var path: String
    /// The directory's new children, or nil to only re-aggregate its totals.
    public var children: [FileNode]?
    /// The directory's own modification time (not aggregated over its subtree);
    /// nil keeps the current value.
    public var modificationTime: TimeInterval?
    /// `errno` from reading the directory (0 if none).
    public var errorCode: Int32
    /// Whether the directory was not descended into (excluded, or another volume).
    public var isExcluded: Bool
    /// True when the whole subtree was rescanned rather than re-listed (no reuse).
    public var isRecursive: Bool
    /// Number of `children` that are reused subtrees from the old tree.
    public var reusedChildCount: Int
    /// The old node this update targets, when known (avoids a path lookup in `apply`).
    var target: FileNode?

    public init(path: String) {
        self.path = path
        self.children = nil
        self.modificationTime = nil
        self.errorCode = 0
        self.isExcluded = false
        self.isRecursive = false
        self.reusedChildCount = 0
        self.target = nil
    }
}

/// Re-scans only what changed in an existing tree.
///
/// Each changed directory is re-listed with the same code as `DiskScanner` (exclusions,
/// stay-on-volume, hard-link dedupe, cloud placeholders, error codes). Existing
/// subdirectories reuse their old subtree nodes; new subdirectories and
/// `recursiveDirectories` get a full parallel subtree scan.
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
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RefreshResult, Error>) in
                let thread = Thread { [self] in
                    do {
                        continuation.resume(returning: try computeRefreshSynchronously(for: root, changes: changes))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                thread.name = "MacSize incremental refresh"
                thread.stackSize = 8 << 20
                thread.start()
            }
        } onCancel: {
            self.cancel()
        }
    }

    /// Synchronous form of `computeRefresh(for:changes:)` (worker threads are spawned
    /// internally). Only reads `root`.
    public func computeRefreshSynchronously(for root: FileNode, changes: ChangeSet) throws -> RefreshResult {
        if progress.isCancelled { throw ScanError.cancelled }
        let rootPath = root.name
        let directoriesBefore = progress.snapshot().directories
        func rescanned() -> Int { progress.snapshot().directories - directoriesBefore }

        func fullRescan() throws -> RefreshResult {
            let fresh = try DiskScanner(options: options, progress: progress).scanSynchronously(path: rootPath)
            return RefreshResult(newRoot: fresh, directoriesRescanned: rescanned(),
                                 didFullRescan: true, eventID: changes.latestEventID)
        }

        var rootInfo = stat()
        guard !changes.requiresFullRescan,
              root.kind == .directory,
              lstat(rootPath, &rootInfo) == 0,
              (rootInfo.st_mode & S_IFMT) == S_IFDIR
        else { return try fullRescan() }

        if changes.isEmpty {
            return RefreshResult(didFullRescan: false, eventID: changes.latestEventID)
        }

        guard let targets = plan(root: root, changes: changes) else { return try fullRescan() }
        if targets.isEmpty {
            return RefreshResult(didFullRescan: false, eventID: changes.latestEventID)
        }

        let context = ScanContext(rootDevice: rootInfo.st_dev, options: options, progress: progress)
        let outcomes = relist(targets, context: context)
        if progress.isCancelled { throw ScanError.cancelled }

        // One parallel pass for every new subtree, then aggregate each (fresh nodes only).
        let subtrees = outcomes.flatMap(\.subtrees)
        context.scanSubtrees(subtrees, threadCount: options.threadCount)
        if progress.isCancelled { throw ScanError.cancelled }
        for item in subtrees { item.node.finalize() }

        let updates = outcomes.map { outcome -> DirectoryUpdate in
            var update = outcome.update
            update.children = outcome.listing.children
            update.errorCode = outcome.listing.errorCode
            update.isExcluded = outcome.listing.isExcluded
            return update
        }
        return RefreshResult(updates: updates, directoriesRescanned: rescanned(),
                             didFullRescan: false, eventID: changes.latestEventID)
    }

    // MARK: - Planning

    struct Target {
        let node: FileNode
        let path: String
        var recursive: Bool
        let depth: Int
    }

    /// Maps changed paths onto directories of the old tree. Returns nil when the root
    /// itself needs a recursive rescan. Read-only.
    func plan(root: FileNode, changes: ChangeSet) -> [Target]? {
        let rootPath = root.name
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var targets: [ObjectIdentifier: Target] = [:]

        func consider(_ rawPath: String, recursive: Bool) {
            var changed = rawPath
            while changed.count > 1 && changed.hasSuffix("/") { changed.removeLast() }
            guard changed == rootPath || changed.hasPrefix(rootPrefix) else { return }  // outside the root

            // Deepest existing directory of the old tree along the path.
            var node = root
            var path = rootPath
            var depth = 0
            var exact = true
            if changed != rootPath {
                for component in changed.dropFirst(rootPrefix.count).split(separator: "/") {
                    let name = String(component)
                    guard let child = node.child(named: name), child.kind == .directory else {
                        exact = false
                        break
                    }
                    // Changes inside excluded / other-volume directories don't count.
                    if child.isExcluded { return }
                    // A cloud placeholder has no local children: re-list its parent instead,
                    // which re-evaluates it without enumerating (downloading) it.
                    if child.isCloudOnly { exact = false; break }
                    node = child
                    path = path.hasSuffix("/") ? path + name : path + "/" + name
                    depth += 1
                }
            }
            var isRecursive = recursive && exact

            // Gone, no longer a directory, or now a cloud placeholder: re-list the parent.
            while node !== root && !Self.isLocalDirectory(path) {
                guard let parent = node.parent else { break }
                node = parent
                path = (path as NSString).deletingLastPathComponent
                depth -= 1
                isRecursive = false
            }

            let key = ObjectIdentifier(node)
            if var existing = targets[key] {
                existing.recursive = existing.recursive || isRecursive
                targets[key] = existing
            } else {
                targets[key] = Target(node: node, path: path, recursive: isRecursive, depth: depth)
            }
        }

        for path in changes.recursiveDirectories { consider(path, recursive: true) }
        for path in changes.directories { consider(path, recursive: false) }

        if targets[ObjectIdentifier(root)]?.recursive == true { return nil }

        // Drop targets inside a recursively rescanned directory.
        let recursiveNodes = Set(targets.values.filter(\.recursive).map { ObjectIdentifier($0.node) })
        let kept = targets.values.filter { target in
            var current = target.node.parent
            while let node = current {
                if recursiveNodes.contains(ObjectIdentifier(node)) { return false }
                current = node.parent
            }
            return true
        }
        return kept.sorted { $0.depth != $1.depth ? $0.depth > $1.depth : $0.path < $1.path }
    }

    /// `lstat`-only check (never opens or materializes anything).
    static func isLocalDirectory(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
        return info.st_flags & Self.datalessFlag == 0
    }

    /// `SF_DATALESS`: the item is a cloud placeholder whose contents aren't local.
    static let datalessFlag: UInt32 = 0x4000_0000

    // MARK: - Re-listing

    struct Outcome {
        var update: DirectoryUpdate
        /// Detached directory node holding the new children.
        let listing: FileNode
        /// New subdirectories that still need a full subtree scan.
        var subtrees: [WorkItem]
    }

    /// Re-lists every target in parallel. Never mutates the old tree.
    private func relist(_ targets: [Target], context: ScanContext) -> [Outcome] {
        /// Work cursor and results shared by the workers; every access holds `lock`.
        final class SharedState: @unchecked Sendable {
            let lock = NSLock()
            var nextIndex = 0
            var outcomes: [Outcome?]
            init(count: Int) { outcomes = Array(repeating: nil, count: count) }

            func claimIndex() -> Int {
                lock.lock(); defer { lock.unlock() }
                let index = nextIndex
                nextIndex += 1
                return index
            }

            func store(_ outcome: Outcome, at index: Int) {
                lock.lock(); outcomes[index] = outcome; lock.unlock()
            }
        }

        let state = SharedState(count: targets.count)
        let workers = max(1, min(options.threadCount, targets.count))

        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            let reader = BulkDirectoryReader()
            while true {
                let index = state.claimIndex()
                guard index < targets.count, !progress.isCancelled else { return }
                state.store(relist(targets[index], context: context, reader: reader), at: index)
            }
        }
        return state.outcomes.compactMap { $0 }
    }

    private func relist(_ target: Target, context: ScanContext, reader: BulkDirectoryReader) -> Outcome {
        var info = stat()
        let ownModificationTime: TimeInterval? = lstat(target.path, &info) == 0
            ? Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
            : nil

        let listing = FileNode(name: target.node.name, kind: .directory,
                               modificationTime: ownModificationTime ?? 0)
        var update = DirectoryUpdate(path: target.path)
        update.target = target.node
        update.modificationTime = ownModificationTime
        update.isRecursive = target.recursive

        let item = WorkItem(node: listing, path: target.path)
        if target.recursive {
            // The whole subtree is scanned fresh in the parallel pass.
            return Outcome(update: update, listing: listing, subtrees: [item])
        }

        // Same listing code as DiskScanner.
        let subdirectories = context.listDirectory(item, reader: reader)

        var oldDirectories: [String: FileNode] = [:]
        for child in target.node.children where child.kind == .directory {
            oldDirectories[child.name] = child
        }
        var reused: [ObjectIdentifier: FileNode] = [:]
        var subtrees: [WorkItem] = []
        for subdirectory in subdirectories {
            if let old = oldDirectories[subdirectory.node.name], !old.isExcluded, !old.isCloudOnly {
                // Unchanged (or separately updated) subdirectory: keep its subtree.
                reused[ObjectIdentifier(subdirectory.node)] = old
            } else {
                subtrees.append(subdirectory)
            }
        }
        if !reused.isEmpty {
            listing.children = listing.children.map { reused[ObjectIdentifier($0)] ?? $0 }
        }
        update.reusedChildCount = reused.count
        return Outcome(update: update, listing: listing, subtrees: subtrees)
    }
}

extension FileNode {
    /// Apply a refresh in place and return the root to display (`result.newRoot` if the
    /// tree was rebuilt, else `self`). Must run where nothing else is reading or mutating
    /// the tree (e.g. on the main actor that owns it). Re-aggregates totals and keeps
    /// children sorted by `metric`.
    ///
    /// Each update's children replace that directory's children (reparenting reused
    /// nodes); then every updated directory and its ancestors are re-aggregated
    /// bottom-up, so nested updates are handled in any order. An ancestor's
    /// modification time only ever moves forward (its own time isn't stored).
    @discardableResult
    public func apply(_ result: RefreshResult, metric: SizeMetric = .allocated) -> FileNode {
        if let newRoot = result.newRoot {
            if metric != .allocated { newRoot.sortChildren(by: metric) }
            return newRoot
        }
        guard !result.updates.isEmpty else { return self }

        // Resolve every target before mutating anything.
        var resolved: [(node: FileNode, update: DirectoryUpdate)] = []
        for update in result.updates {
            let node: FileNode?
            if let target = update.target, target.isDescendant(of: self) {
                node = target
            } else {
                node = descendant(atPath: update.path)
            }
            guard let node, node.kind == .directory else { continue }
            resolved.append((node, update))
        }

        var ownTimes: [ObjectIdentifier: TimeInterval?] = [:]
        for (node, update) in resolved {
            if let children = update.children {
                for child in children {
                    if child.parent !== node, metric != .allocated, child.kind == .directory {
                        // New subtree: finalize() sorted it by allocated size.
                        child.sortChildren(by: metric)
                    }
                    child.parent = node
                }
                node.children = children
                node.errorCode = update.errorCode
                node.isExcluded = update.isExcluded
            }
            ownTimes[ObjectIdentifier(node)] = .some(update.modificationTime)
        }

        // Updated directories plus their ancestors, re-aggregated deepest first.
        var touched: [ObjectIdentifier: (node: FileNode, depth: Int)] = [:]
        for (node, _) in resolved {
            var current: FileNode? = node
            while let item = current, touched[ObjectIdentifier(item)] == nil {
                touched[ObjectIdentifier(item)] = (item, item.ancestry.count)
                if item === self { break }
                current = item.parent
            }
        }
        for (node, _) in touched.values.sorted(by: { $0.depth > $1.depth }) {
            let own = ownTimes[ObjectIdentifier(node)] ?? nil
            node.reaggregate(ownModificationTime: own, metric: metric)
        }
        return self
    }
}
