import Darwin
import Foundation

public struct ScanOptions: Sendable {
    /// Number of worker threads reading directories in parallel.
    public var threadCount: Int
    /// Don't descend into directories that live on a different volume than the scan root.
    public var stayOnFileSystem: Bool
    /// Absolute paths that are not descended into.
    public var excludedPaths: [String]
    /// Also exclude `ScanOptions.systemExcludedPaths` (pseudo-filesystems and
    /// the APFS Data volume mount, which would otherwise be counted twice
    /// through firmlinks when scanning `/`).
    public var applySystemExclusions: Bool

    public static let defaultThreadCount = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 16))

    /// Generic macOS locations that inflate or duplicate results when scanning `/`.
    public static let systemExcludedPaths = [
        "/dev",
        "/Volumes",
        "/Network",
        "/System/Volumes/Data",
    ]

    public init(
        threadCount: Int = ScanOptions.defaultThreadCount,
        stayOnFileSystem: Bool = false,
        excludedPaths: [String] = [],
        applySystemExclusions: Bool = true
    ) {
        self.threadCount = max(1, threadCount)
        self.stayOnFileSystem = stayOnFileSystem
        self.excludedPaths = excludedPaths
        self.applySystemExclusions = applySystemExclusions
    }

    /// Stable identifier for options that change the resulting tree. Cached scans are
    /// only reused when the fingerprint matches.
    public var fingerprint: String {
        let exclusions = effectiveExclusions.sorted().joined(separator: "\u{1F}")
        return "v1|fs=\(stayOnFileSystem ? 1 : 0)|sys=\(applySystemExclusions ? 1 : 0)|ex=\(exclusions)"
    }

    var effectiveExclusions: Set<String> {
        var paths = excludedPaths
        if applySystemExclusions { paths += Self.systemExcludedPaths }
        var result = Set<String>()
        for path in paths {
            let normalized = Self.normalize(path)
            result.insert(normalized)
            // Also match the symlink-resolved form, since the scanner walks real paths.
            if let resolved = realpath(normalized, nil) {
                result.insert(String(cString: resolved))
                free(resolved)
            }
        }
        return result
    }

    static func normalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var standardized = (expanded as NSString).standardizingPath
        while standardized.count > 1 && standardized.hasSuffix("/") { standardized.removeLast() }
        return standardized
    }
}

public enum ScanError: Error, LocalizedError, Equatable {
    case cancelled
    case cannotAccess(path: String, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "The scan was cancelled."
        case let .cannotAccess(path, code):
            return "Cannot access \(path): \(String(cString: strerror(code)))"
        }
    }
}

/// Thread-safe live counters for a running scan.
public final class ScanProgress: @unchecked Sendable {
    public struct Snapshot: Sendable, Equatable {
        public var files: Int = 0
        public var directories: Int = 0
        public var bytes: Int64 = 0
        public var errors: Int = 0
        public var currentPath: String = ""

        public init() {}
    }

    private let lock = NSLock()
    private var state = Snapshot()
    private var cancelled = false

    public init() {}

    public func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    func record(files: Int, directories: Int, bytes: Int64, errors: Int, path: String) {
        lock.lock()
        state.files += files
        state.directories += directories
        state.bytes += bytes
        state.errors += errors
        state.currentPath = path
        lock.unlock()
    }
}

/// Parallel filesystem scanner built on `getattrlistbulk(2)`.
///
/// Directories are processed by a fixed pool of worker threads pulling from a
/// shared stack. Each directory node's `children` array is written only by the
/// worker that reads that directory, so no per-node locking is needed; totals
/// are aggregated in a single pass once all workers are done.
public final class DiskScanner: @unchecked Sendable {
    public let options: ScanOptions
    public let progress: ScanProgress

    public init(options: ScanOptions = ScanOptions()) {
        self.options = options
        self.progress = ScanProgress()
    }

    /// Scanner that reports into an existing progress object (used by `IncrementalScanner`).
    init(options: ScanOptions, progress: ScanProgress) {
        self.options = options
        self.progress = progress
    }

    public func cancel() { progress.cancel() }

    /// Scan asynchronously on a dedicated thread (keeps blocking I/O off the
    /// Swift concurrency pool). Cancelling the task cancels the scan.
    public func scan(path: String) async throws -> FileNode {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<FileNode, Error>) in
                let thread = Thread { [self] in
                    do {
                        continuation.resume(returning: try scanSynchronously(path: path))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                thread.name = "MacSize scan coordinator"
                thread.stackSize = 8 << 20
                thread.start()
            }
        } onCancel: {
            self.cancel()
        }
    }

    /// Scan on the calling thread (worker threads are spawned internally).
    public func scanSynchronously(path: String) throws -> FileNode {
        CloudStorage.disableAutomaticDownloads()  // never trigger cloud downloads
        let rootPath = Self.resolveRoot(path)

        var info = stat()
        guard lstat(rootPath, &info) == 0 else {
            throw ScanError.cannotAccess(path: rootPath, errno: errno)
        }

        let modTime = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            let kind: FileKind = (info.st_mode & S_IFMT) == S_IFLNK ? .symlink : .file
            let node = FileNode(
                name: rootPath,
                kind: kind,
                allocatedSize: Int64(info.st_blocks) * 512,
                logicalSize: Int64(info.st_size),
                modificationTime: modTime
            )
            if info.st_flags & CloudStorage.datalessFlag != 0 { node.markCloudOnly() }
            return node
        }

        let root = FileNode(name: rootPath, kind: .directory, modificationTime: modTime)
        if info.st_flags & CloudStorage.datalessFlag != 0 {  // cloud-only folder: don't list it
            root.markCloudOnly(); root.finalize(); return root
        }
        let context = ScanContext(
            rootDevice: info.st_dev,
            options: options,
            progress: progress
        )
        context.scanSubtrees([WorkItem(node: root, path: rootPath)], threadCount: options.threadCount)

        if progress.isCancelled { throw ScanError.cancelled }
        if root.errorCode != 0 && root.children.isEmpty {
            throw ScanError.cannotAccess(path: rootPath, errno: root.errorCode)
        }
        root.finalize()
        return root
    }

    static func resolveRoot(_ path: String) -> String {
        let normalized = ScanOptions.normalize(path.isEmpty ? "." : path)
        let absolute = normalized.hasPrefix("/")
            ? normalized
            : ScanOptions.normalize(FileManager.default.currentDirectoryPath + "/" + normalized)
        // Resolve symlinks for the root only (e.g. /tmp -> /private/tmp) so the
        // user sees the contents they asked for.
        guard let resolved = realpath(absolute, nil) else { return absolute }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

// MARK: - Internals

struct WorkItem: @unchecked Sendable {
    let node: FileNode
    let path: String
}

/// LIFO work stack shared by the worker threads. `pending` counts items that
/// have been pushed but not yet finished; workers exit when it reaches zero.
final class WorkQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var stack: [WorkItem] = []
    private var pending = 0
    private var stopped = false

    func push(_ items: [WorkItem]) {
        guard !items.isEmpty else { return }
        condition.lock()
        stack.append(contentsOf: items)
        pending += items.count
        condition.broadcast()
        condition.unlock()
    }

    func pop() -> WorkItem? {
        condition.lock()
        defer { condition.unlock() }
        while stack.isEmpty && pending > 0 && !stopped {
            condition.wait()
        }
        if stopped { return nil }
        return stack.popLast()
    }

    func finish() {
        condition.lock()
        pending -= 1
        if pending == 0 { condition.broadcast() }
        condition.unlock()
    }

    func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
    }
}

final class ScanContext: @unchecked Sendable {
    let queue = WorkQueue()
    let rootDevice: dev_t
    let stayOnFileSystem: Bool
    let exclusions: Set<String>
    let progress: ScanProgress

    private let hardLinkLock = NSLock()
    private var seenHardLinks = Set<HardLinkKey>()

    struct HardLinkKey: Hashable {
        let device: dev_t
        let inode: UInt64
    }

    init(rootDevice: dev_t, options: ScanOptions, progress: ScanProgress) {
        self.rootDevice = rootDevice
        self.stayOnFileSystem = options.stayOnFileSystem
        self.exclusions = options.effectiveExclusions
        self.progress = progress
    }

    /// Returns true the first time a given (device, inode) pair is seen.
    func claimHardLink(device: dev_t, inode: UInt64) -> Bool {
        hardLinkLock.lock(); defer { hardLinkLock.unlock() }
        return seenHardLinks.insert(HardLinkKey(device: device, inode: inode)).inserted
    }

    /// Scans each item's directory into a complete subtree below its (fresh, childless)
    /// node, in parallel on `threadCount` workers. Blocks until done or cancelled.
    /// Totals are not aggregated: call `finalize()` on each item's node afterwards.
    /// A context's queue is single-use, so call this at most once per context.
    func scanSubtrees(_ items: [WorkItem], threadCount: Int) {
        guard !items.isEmpty else { return }
        queue.push(items)
        DispatchQueue.concurrentPerform(iterations: max(1, threadCount)) { _ in
            runWorker()
        }
    }

    func runWorker() {
        let reader = BulkDirectoryReader()
        while let item = queue.pop() {
            if progress.isCancelled {
                queue.stop()
                queue.finish()
                break
            }
            let subdirectories = listDirectory(item, reader: reader)
            queue.push(subdirectories)
            queue.finish()
        }
    }

    /// Reads the direct entries of `item.path` into fresh children of `item.node`
    /// (applying exclusions, stay-on-volume and hard-link dedupe) and returns the
    /// subdirectories that still need scanning.
    func listDirectory(_ item: WorkItem, reader: BulkDirectoryReader) -> [WorkItem] {
        let directory = item.node
        let fd = open(item.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            directory.errorCode = errno
            progress.record(files: 0, directories: 1, bytes: 0, errors: 1, path: item.path)
            return []
        }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else {
            directory.errorCode = errno
            progress.record(files: 0, directories: 1, bytes: 0, errors: 1, path: item.path)
            return []
        }
        if stayOnFileSystem && info.st_dev != rootDevice {
            directory.isExcluded = true
            progress.record(files: 0, directories: 1, bytes: 0, errors: 0, path: item.path)
            return []
        }
        let device = info.st_dev

        var subdirectories: [WorkItem] = []
        var children: [FileNode] = []
        var files = 0
        var bytes: Int64 = 0
        var errors = 0
        let prefix = item.path.hasSuffix("/") ? item.path : item.path + "/"

        let status = reader.forEachEntry(in: fd) { entry in
            if entry.error != 0 { errors += 1 }
            if entry.isDirectory {
                let child = FileNode(
                    name: entry.name,
                    kind: .directory,
                    modificationTime: entry.modificationTime,
                    parent: directory
                )
                children.append(child)
                if CloudStorage.markIfDataless(child, entry) { return }  // cloud-only: don't descend
                let childPath = prefix + entry.name
                if exclusions.contains(childPath) {
                    child.isExcluded = true
                } else {
                    subdirectories.append(WorkItem(node: child, path: childPath))
                }
                return
            }

            var allocated = entry.allocatedSize
            var logical = entry.logicalSize
            if entry.linkCount > 1 && entry.isRegular && !claimHardLink(device: device, inode: entry.fileID) {
                // Additional hard link to a file already counted: like `du`, count it once.
                allocated = 0
                logical = 0
            }
            let kind: FileKind = entry.isSymlink ? .symlink : (entry.isRegular ? .file : .other)
            let child = FileNode(
                name: entry.name,
                kind: kind,
                allocatedSize: allocated,
                logicalSize: logical,
                modificationTime: entry.modificationTime,
                parent: directory
            )
            child.errorCode = Int32(bitPattern: entry.error)
            _ = CloudStorage.markIfDataless(child, entry)  // cloud-only file (allocated ≈ 0)
            children.append(child)
            files += 1
            bytes += allocated
        }

        if status != 0 {
            directory.errorCode = status
            errors += 1
        }
        directory.children = children
        progress.record(
            files: files,
            directories: 1,
            bytes: bytes,
            errors: errors,
            path: item.path
        )
        return subdirectories
    }
}
