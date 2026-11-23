import Darwin
import Foundation

/// Cloud-storage ("File Provider") awareness: iCloud Drive, Google Drive, OneDrive, Dropbox…
///
/// On modern macOS these providers keep "dataless" placeholder files and folders on disk
/// (flag `SF_DATALESS`). Their metadata (name, logical size, dates) is local, but their
/// contents live in the cloud until something reads them. Reading a placeholder's
/// contents, or enumerating a dataless folder, normally makes the kernel ask the provider to
/// download ("materialize") it, synchronously.
///
/// A disk analyzer must never do that: scanning a 2 TB Google Drive would try to fill
/// the disk. MacSize therefore:
/// 1. turns materialization off for the whole process (`disableAutomaticDownloads()`),
///    so any accidental access to dataless content fails with an error (typically
///    `EDEADLK`) instead of downloading, and
/// 2. reads only metadata (`getattrlistbulk`), detects placeholders via `SF_DATALESS`,
///    counts them at their allocated size (≈ 0 bytes on this Mac) and never descends
///    into dataless folders.
public enum CloudStorage {
    /// The `st_flags` bit marking a dataless (cloud-only) placeholder (`<sys/stat.h>`).
    public static let datalessFlag: UInt32 = 0x4000_0000  // SF_DATALESS

    // Swift initializes static stored properties exactly once, thread-safely
    // (dispatch_once), which makes `disableAutomaticDownloads()` idempotent and safe to call
    // from any thread, as often as wanted.
    private static let policyStatus: Int32 = {
        // IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES = 3, IOPOL_SCOPE_PROCESS = 0,
        // IOPOL_MATERIALIZE_DATALESS_FILES_OFF = 1 (<sys/resource.h>).
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0
            ? 0 : errno
    }()

    /// Prevent this process from ever triggering a cloud download.
    ///
    /// Sets the process-wide I/O policy `IOPOL_MATERIALIZE_DATALESS_FILES_OFF`. With it in
    /// place, reading the contents of a dataless file or listing a dataless directory fails
    /// with an error instead of asking the File Provider to fetch the data. Metadata (names,
    /// sizes, flags, dates) remains readable. Idempotent and thread-safe.
    ///
    /// - Returns: `true` if the policy is in effect.
    @discardableResult
    public static func disableAutomaticDownloads() -> Bool {
        policyStatus == 0
    }

    /// Whether this process currently refuses to materialize dataless files.
    public static var automaticDownloadsDisabled: Bool {
        getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS) == IOPOL_MATERIALIZE_DATALESS_FILES_OFF
    }

    /// Whether `path` is a dataless (cloud-only) placeholder. Metadata only; never downloads.
    public static func isDataless(path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_flags & datalessFlag != 0
    }

    /// Scanner hook: marks `node` as cloud-only if `entry` is a dataless placeholder.
    /// Call after the node's sizes are set. Returns `true` for a dataless entry; the caller
    /// must then not descend into it (listing a dataless folder asks the provider to fetch
    /// it, and with downloads disabled it would fail anyway).
    @inline(__always)
    static func markIfDataless(_ node: FileNode, _ entry: BulkEntry) -> Bool {
        guard entry.isDataless else { return false }
        node.markCloudOnly()
        return true
    }

    // MARK: - Remove Download (iCloud Drive only)

    /// File Provider domains (Google Drive, OneDrive, Dropbox, …) mount here.
    /// Only the provider itself can evict their items (`NSFileProviderManager` is scoped to
    /// the provider's own domains), so MacSize doesn't offer "Remove Download" for them.
    static var thirdPartyProviderRoot: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/Library/CloudStorage/"
    }

    /// Whether "Remove Download" can be offered for `node`: a downloaded (not cloud-only)
    /// iCloud Drive item that currently uses space on this Mac. Reads metadata only.
    public static func canRemoveDownload(_ node: FileNode) -> Bool {
        guard !node.isCloudOnly, node.allocatedSize > 0,
              node.kind == .file || node.kind == .directory else { return false }
        let path = node.path
        // Recent macOS mounts iCloud Drive under ~/Library/CloudStorage/iCloudDrive-…, next
        // to third-party providers; only the iCloud one supports eviction by other apps.
        if path.hasPrefix(thirdPartyProviderRoot),
           !path.dropFirst(thirdPartyProviderRoot.count).hasPrefix("iCloudDrive") { return false }
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let values = try? node.url.resourceValues(forKeys: keys), values.isUbiquitousItem == true else {
            return false
        }
        if node.kind == .file {
            return values.ubiquitousItemDownloadingStatus != .notDownloaded
        }
        return true
    }

    /// Remove the local copy of an iCloud Drive item, keeping it in iCloud
    /// (`FileManager.evictUbiquitousItem(at:)`). Never downloads anything.
    public static func removeDownload(_ node: FileNode) throws {
        try FileManager.default.evictUbiquitousItem(at: node.url)
    }
}

extension BulkEntry {
    /// True for a dataless (cloud-only) File Provider placeholder.
    var isDataless: Bool { flags & CloudStorage.datalessFlag != 0 }
}

extension FileNode {
    /// Re-read sizes and cloud-only state for this subtree from disk (metadata only, via
    /// `lstat`; never downloads), then update ancestors' totals. The set of children is
    /// kept as is. Use after an item's local copy was removed or downloaded.
    public func refreshCloudState(sortingBy metric: SizeMetric = .allocated) {
        CloudStorage.disableAutomaticDownloads()
        let before = (allocatedSize, logicalSize, cloudOnlySize, cloudOnlyCount)

        var stack: [FileNode] = [self]
        while let node = stack.popLast() {
            var info = stat()
            guard lstat(node.path, &info) == 0 else { continue }
            let dataless = info.st_flags & CloudStorage.datalessFlag != 0
            if node.kind == .directory {
                node.isCloudOnly = dataless
                stack.append(contentsOf: node.children)
                continue
            }
            // Extra hard links were counted as 0 by the scanner; keep it that way.
            let wasHardLinkDuplicate = info.st_nlink > 1 && node.allocatedSize == 0 && node.logicalSize == 0
            if !wasHardLinkDuplicate {
                node.allocatedSize = Int64(info.st_blocks) * 512
                node.logicalSize = Int64(info.st_size)
            }
            node.isCloudOnly = false
            node.cloudOnlySize = 0
            node.cloudOnlyCount = 0
            if dataless { node.markCloudOnly() }
        }
        if kind == .directory {
            finalize()
            if metric != .allocated { sortChildren(by: metric) }
        }

        let deltaAllocated = allocatedSize - before.0
        let deltaLogical = logicalSize - before.1
        let deltaCloudSize = cloudOnlySize - before.2
        let deltaCloudCount = cloudOnlyCount - before.3
        var current = parent
        while let node = current {
            node.allocatedSize += deltaAllocated
            node.logicalSize += deltaLogical
            node.cloudOnlySize += deltaCloudSize
            node.cloudOnlyCount += deltaCloudCount
            current = node.parent
        }
        parent?.children.sort { $0.size(metric) > $1.size(metric) }
    }
}
