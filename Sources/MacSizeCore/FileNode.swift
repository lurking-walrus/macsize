import Foundation

/// The kind of filesystem object a node represents.
public enum FileKind: UInt8, Sendable, Codable {
    case file
    case directory
    case symlink
    case other
}

/// Which size measurement to use when ranking and displaying nodes.
public enum SizeMetric: String, Sendable, CaseIterable, Codable {
    /// Bytes actually allocated on disk. Accounts for APFS sparse files,
    /// compression and (per-file) clones. This is what `du` reports.
    case allocated
    /// The logical length of the file contents (what Finder calls "size").
    case logical

    public var displayName: String {
        switch self {
        case .allocated: return "Size on Disk"
        case .logical: return "Logical Size"
        }
    }
}

/// A node in the scanned filesystem tree.
///
/// The tree is built by `DiskScanner` on background threads and is treated as
/// immutable once a scan finishes, except through the explicit mutation
/// helpers below (e.g. after moving an item to the Trash).
public final class FileNode: Identifiable, @unchecked Sendable {
    /// For the root node this is the full path; for every other node it is the
    /// last path component.
    public let name: String
    public let kind: FileKind

    public internal(set) var allocatedSize: Int64
    public internal(set) var logicalSize: Int64
    /// Number of non-directory items in this subtree (1 for a file).
    public internal(set) var fileCount: Int
    /// Number of directories below this node (not counting itself).
    public internal(set) var directoryCount: Int
    /// Most recent modification time in the subtree, seconds since 1970.
    public internal(set) var modificationTime: TimeInterval
    /// Children, sorted largest-first after a scan completes.
    public internal(set) var children: [FileNode]
    public internal(set) weak var parent: FileNode?
    /// `errno` encountered while reading this item (0 if none).
    public internal(set) var errorCode: Int32 = 0
    /// True if this directory was intentionally not descended into
    /// (excluded path or a different volume).
    public internal(set) var isExcluded = false
    /// True when this item's contents aren't on this Mac: a "dataless" cloud placeholder
    /// (iCloud Drive, Google Drive, OneDrive, Dropbox… via File Provider, flag `SF_DATALESS`).
    /// A dataless directory hasn't been enumerated locally, so its children are unknown.
    public internal(set) var isCloudOnly = false
    /// Logical bytes in this subtree that live only in cloud storage (not downloaded).
    /// For a cloud-only file this is its logical size; directories aggregate it.
    public internal(set) var cloudOnlySize: Int64 = 0
    /// Number of cloud-only items in this subtree (1 for a cloud-only file or directory).
    public internal(set) var cloudOnlyCount: Int = 0

    public var id: ObjectIdentifier { ObjectIdentifier(self) }

    init(
        name: String,
        kind: FileKind,
        allocatedSize: Int64 = 0,
        logicalSize: Int64 = 0,
        modificationTime: TimeInterval = 0,
        parent: FileNode? = nil
    ) {
        self.name = name
        self.kind = kind
        self.allocatedSize = allocatedSize
        self.logicalSize = logicalSize
        self.fileCount = kind == .directory ? 0 : 1
        self.directoryCount = 0
        self.modificationTime = modificationTime
        self.children = []
        self.parent = parent
    }

    public var isDirectory: Bool { kind == .directory }

    /// Logical bytes in this subtree that are actually stored on this Mac.
    public var localLogicalSize: Int64 { max(0, logicalSize - cloudOnlySize) }

    /// Mark a node as a cloud-only placeholder (used by scanners).
    func markCloudOnly() {
        isCloudOnly = true
        cloudOnlySize = logicalSize
        cloudOnlyCount = 1
    }

    /// Full path, reconstructed by walking up to the root.
    public var path: String {
        guard let parent else { return name }
        let parentPath = parent.path
        return parentPath.hasSuffix("/") ? parentPath + name : parentPath + "/" + name
    }

    public var url: URL { URL(fileURLWithPath: path) }

    public func size(_ metric: SizeMetric) -> Int64 {
        switch metric {
        case .allocated: return allocatedSize
        case .logical: return logicalSize
        }
    }

    /// Lowercased file extension, or an empty string.
    public var fileExtension: String {
        guard kind != .directory, let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    /// Children for hierarchical list/outline views: `nil` for leaves.
    public var outlineChildren: [FileNode]? {
        kind == .directory && !children.isEmpty ? children : nil
    }

    /// Chain of nodes from the root down to (and including) this node.
    public var ancestry: [FileNode] {
        var chain: [FileNode] = [self]
        var current = parent
        while let node = current {
            chain.append(node)
            current = node.parent
        }
        return chain.reversed()
    }

    /// Whether `self` is `other` or one of its descendants.
    public func isDescendant(of other: FileNode) -> Bool {
        var current: FileNode? = self
        while let node = current {
            if node === other { return true }
            current = node.parent
        }
        return false
    }

    // MARK: - Mutation

    /// Detach this node from its parent and subtract its totals from every
    /// ancestor. Use after the item has been removed from disk.
    public func removeFromParent() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        let dirs = directoryCount + (kind == .directory ? 1 : 0)
        var current: FileNode? = parent
        while let node = current {
            node.allocatedSize -= allocatedSize
            node.logicalSize -= logicalSize
            node.fileCount -= fileCount
            node.directoryCount -= dirs
            node.cloudOnlySize -= cloudOnlySize
            node.cloudOnlyCount -= cloudOnlyCount
            current = node.parent
        }
        self.parent = nil
    }

    /// Re-sort every directory's children, largest first, by `metric`.
    public func sortChildren(by metric: SizeMetric) {
        var stack: [FileNode] = [self]
        while let node = stack.popLast() {
            guard node.kind == .directory else { continue }
            node.children.sort { $0.size(metric) > $1.size(metric) }
            stack.append(contentsOf: node.children)
        }
    }

    /// Compute aggregate totals bottom-up and sort children largest first.
    func finalize() {
        // Iterative post-order traversal so pathological depths can't blow the stack.
        var stack: [(FileNode, Bool)] = [(self, false)]
        while let (node, visited) = stack.popLast() {
            guard node.kind == .directory else { continue }
            if !visited {
                stack.append((node, true))
                for child in node.children where child.kind == .directory {
                    stack.append((child, false))
                }
                continue
            }
            var allocated: Int64 = 0
            var logical: Int64 = 0
            var files = 0
            var dirs = 0
            var newest = node.modificationTime
            var cloudSize: Int64 = 0
            var cloudCount = 0
            for child in node.children {
                cloudSize += child.cloudOnlySize
                cloudCount += child.cloudOnlyCount
                allocated += child.allocatedSize
                logical += child.logicalSize
                files += child.fileCount
                if child.kind == .directory { dirs += 1 + child.directoryCount }
                newest = max(newest, child.modificationTime)
            }
            node.allocatedSize = allocated
            node.logicalSize = logical
            node.fileCount = files
            node.directoryCount = dirs
            node.modificationTime = newest
            // A cloud-only directory wasn't enumerated locally, so its size is unknown (0);
            // it still counts as one cloud-only item.
            node.cloudOnlySize = cloudSize
            node.cloudOnlyCount = cloudCount + (node.isCloudOnly ? 1 : 0)
            node.children.sort { $0.allocatedSize > $1.allocatedSize }
        }
    }
}

// MARK: - Queries

extension FileNode {
    /// The `count` largest non-directory items in this subtree.
    public func largestFiles(count: Int, metric: SizeMetric = .allocated) -> [FileNode] {
        guard count > 0 else { return [] }
        var best: [FileNode] = []  // kept sorted descending
        var stack: [FileNode] = [self]
        while let node = stack.popLast() {
            if node.kind == .directory {
                stack.append(contentsOf: node.children)
                continue
            }
            let size = node.size(metric)
            if best.count == count, let last = best.last, size <= last.size(metric) { continue }
            let index = best.firstIndex { $0.size(metric) < size } ?? best.endIndex
            best.insert(node, at: index)
            if best.count > count { best.removeLast() }
        }
        return best
    }

    /// Aggregate sizes by file extension.
    public func fileTypeSummary(metric: SizeMetric = .allocated) -> [FileTypeStat] {
        var table: [String: FileTypeStat] = [:]
        var stack: [FileNode] = [self]
        while let node = stack.popLast() {
            if node.kind == .directory {
                stack.append(contentsOf: node.children)
                continue
            }
            let ext = node.fileExtension
            var stat = table[ext] ?? FileTypeStat(fileExtension: ext, size: 0, count: 0)
            stat.size += node.size(metric)
            stat.count += 1
            table[ext] = stat
        }
        return table.values.sorted { $0.size > $1.size }
    }
}

public struct FileTypeStat: Sendable, Hashable, Codable {
    /// Lowercased extension without the dot; empty for files with none.
    public var fileExtension: String
    public var size: Int64
    public var count: Int

    public var displayName: String { fileExtension.isEmpty ? "(no extension)" : "." + fileExtension }
}
