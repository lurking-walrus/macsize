import CoreServices
import Darwin
import Foundation

/// One FSEvents event, already decoded.
struct FSEvent: Sendable {
    var path: String
    var flags: UInt32
    var id: UInt64

    func has(_ flag: Int) -> Bool { flags & UInt32(flag) != 0 }
}

/// Folds raw directory-level FSEvents into a `ChangeSet` for one scan root. Shared by
/// `ChangeJournal` (history replay) and `ChangeWatcher` (live), so both apply the same
/// path normalization and flag rules.
struct ChangeAccumulator {
    /// Symlink-resolved root (as produced by `DiskScanner.resolveRoot`).
    let rootPath: String
    private let rootPrefix: String

    private(set) var directories = Set<String>()
    private(set) var recursiveDirectories = Set<String>()
    private(set) var requiresFullRescan = false
    private(set) var maxEventID: UInt64 = 0
    private(set) var historyDone = false

    init(rootPath: String) {
        self.rootPath = rootPath
        self.rootPrefix = rootPath == "/" ? "/" : rootPath + "/"
    }

    var hasChanges: Bool { requiresFullRescan || !directories.isEmpty || !recursiveDirectories.isEmpty }

    mutating func add(_ event: FSEvent) {
        if event.has(kFSEventStreamEventFlagHistoryDone) {
            historyDone = true
            return
        }
        maxEventID = max(maxEventID, event.id)

        if event.has(kFSEventStreamEventFlagRootChanged) || event.has(kFSEventStreamEventFlagEventIdsWrapped) {
            requiresFullRescan = true
            return
        }

        let path = canonicalize(event.path)
        let isUnder = path.hasPrefix(rootPrefix) && path != "/" || path == rootPath
        let isAtOrAbove = path == rootPath || path == "/" || rootPath.hasPrefix(path + "/")

        let mustRescanSubtree = event.has(kFSEventStreamEventFlagMustScanSubDirs)
            || event.has(kFSEventStreamEventFlagUserDropped)
            || event.has(kFSEventStreamEventFlagKernelDropped)
            || event.has(kFSEventStreamEventFlagMount)
            || event.has(kFSEventStreamEventFlagUnmount)

        if mustRescanSubtree {
            if isAtOrAbove {
                requiresFullRescan = true
            } else if isUnder {
                recursiveDirectories.insert(path)
            }
            return
        }
        if isUnder { directories.insert(path) }
        // Anything else (outside the root, or an ancestor without a root-level flag) is ignored.
    }

    /// Path normalization consistent with `DiskScanner.resolveRoot`: no trailing slash,
    /// and symlinks in the *parent* resolved (the last component is never followed, like
    /// the scanner's `O_NOFOLLOW`). Paths FSEvents reports under the root are already
    /// canonical, so they skip the syscalls.
    func canonicalize(_ raw: String) -> String {
        var path = raw
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if path == rootPath || path.hasPrefix(rootPrefix) { return path }
        return Self.resolveParent(path)
    }

    static func resolveParent(_ path: String) -> String {
        guard path.hasPrefix("/"), path != "/" else { return path.isEmpty ? "/" : path }
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let resolvedParent: String
        if let resolved = realpath(parent, nil) {
            resolvedParent = String(cString: resolved)
            free(resolved)
        } else {
            resolvedParent = resolveParent(parent)
        }
        return resolvedParent == "/" ? "/" + name : resolvedParent + "/" + name
    }

    /// The coalesced result: directories covered by a recursive ancestor (or by
    /// themselves being recursive) are dropped.
    func makeChangeSet(fallbackEventID: UInt64) -> ChangeSet {
        let latest = max(maxEventID, fallbackEventID)
        if requiresFullRescan { return .fullRescan(latestEventID: latest) }
        let recursive = recursiveDirectories.filter { !Self.hasAncestor($0, in: recursiveDirectories) }
        let plain = directories.filter { !recursive.contains($0) && !Self.hasAncestor($0, in: recursive) }
        return ChangeSet(directories: plain, recursiveDirectories: recursive,
                         requiresFullRescan: false, latestEventID: latest)
    }

    /// Whether a strict ancestor of `path` is in `set`.
    static func hasAncestor(_ path: String, in set: Set<String>) -> Bool {
        guard !set.isEmpty else { return false }
        var current = path
        while current != "/" && !current.isEmpty {
            current = (current as NSString).deletingLastPathComponent
            if set.contains(current) { return true }
        }
        return false
    }
}

/// Owns one `FSEventStream` scheduled on a private serial dispatch queue and forwards
/// each callback's batch of events to `handler` (on that queue).
///
/// The stream retains this object through its context, so it stays alive until `stop()`
/// invalidates and releases the stream. Only directory-level events are requested, and
/// nothing here ever touches file contents (so cloud placeholders are never downloaded).
final class EventStream: @unchecked Sendable {
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Bool>()
    private let handler: @Sendable ([FSEvent]) -> Void
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    init(label: String, handler: @escaping @Sendable ([FSEvent]) -> Void) {
        queue = DispatchQueue(label: label)
        queue.setSpecific(key: queueKey, value: true)
        self.handler = handler
    }

    deinit { stop() }

    /// Creates and starts the stream. Returns false if FSEvents refused it.
    func start(path: String, since eventID: UInt64, latency: TimeInterval, flags: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard stream == nil else { return true }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<EventStream>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<EventStream>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let owner = Unmanaged<EventStream>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
            var events: [FSEvent] = []
            events.reserveCapacity(count)
            for index in 0..<count {
                let path = (array[index] as? String) ?? ""
                events.append(FSEvent(path: path, flags: flags[index], id: ids[index]))
            }
            owner.handler(events)
        }
        let allFlags = FSEventStreamCreateFlags(flags | kFSEventStreamCreateFlagUseCFTypes)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [path] as CFArray,
            FSEventStreamEventId(eventID), latency, allFlags
        ) else { return false }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    /// Stops, invalidates and releases the stream. Idempotent; safe from any thread,
    /// including from inside the handler. When called from elsewhere it waits for an
    /// in-flight callback to finish, so no callback runs after it returns.
    func stop() {
        lock.lock()
        let current = stream
        stream = nil
        lock.unlock()
        guard let current else { return }
        FSEventStreamStop(current)
        FSEventStreamInvalidate(current)
        if DispatchQueue.getSpecific(key: queueKey) == nil {
            queue.sync {}
        }
        FSEventStreamRelease(current)
    }
}
