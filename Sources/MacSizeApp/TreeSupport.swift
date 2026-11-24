import Darwin
import Foundation
import MacSizeCore

/// Resolves a scan root the same way `DiskScanner` does (tilde, standardize, trailing
/// slashes, `realpath`), so cache lookups use the path the scanner will report.
enum RootPath {
    static func resolve(_ path: String) -> String {
        var normalized = ((path.isEmpty ? "." : path) as NSString).expandingTildeInPath
        if !normalized.hasPrefix("/") {
            normalized = FileManager.default.currentDirectoryPath + "/" + normalized
        }
        normalized = (normalized as NSString).standardizingPath
        while normalized.count > 1 && normalized.hasSuffix("/") { normalized.removeLast() }
        guard let resolved = realpath(normalized, nil) else { return normalized }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Whether `path` is `directory` or inside it.
    static func path(_ path: String, isWithin directory: String) -> Bool {
        path == directory || path.hasPrefix(directory.hasSuffix("/") ? directory : directory + "/")
    }

    /// `lstat` only: never reads file contents, so it can't trigger a cloud download.
    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}

extension ChangeSet {
    /// Union of two change sets (used to coalesce bursts of FSEvents).
    func merged(with other: ChangeSet) -> ChangeSet {
        ChangeSet(
            directories: directories.union(other.directories),
            recursiveDirectories: recursiveDirectories.union(other.recursiveDirectories),
            requiresFullRescan: requiresFullRescan || other.requiresFullRescan,
            latestEventID: Swift.max(latestEventID, other.latestEventID)
        )
    }

    /// Drops changes inside `directory` (the scan cache), so our own snapshot writes
    /// don't trigger a refresh → save → refresh loop when the cache lives under the root.
    func excluding(directory: String) -> ChangeSet {
        var copy = self
        copy.directories = directories.filter { !RootPath.path($0, isWithin: directory) }
        copy.recursiveDirectories = recursiveDirectories.filter { !RootPath.path($0, isWithin: directory) }
        return copy
    }
}

extension FileNode {
    /// The node at `path` in this tree, or nil.
    func node(atPath path: String) -> FileNode? {
        let (node, exact) = walk(toPath: path)
        return exact ? node : nil
    }

    /// The node at `path`, or its nearest ancestor still in this tree (nil if `path`
    /// isn't under this root at all).
    func deepestNode(atPath path: String) -> FileNode? {
        walk(toPath: path).node
    }

    private func walk(toPath target: String) -> (node: FileNode?, exact: Bool) {
        let rootPath = self.path
        if target == rootPath { return (self, true) }
        guard RootPath.path(target, isWithin: rootPath) else { return (nil, false) }
        let relative = target.dropFirst(rootPath.hasSuffix("/") ? rootPath.count : rootPath.count + 1)
        var current = self
        for component in relative.split(separator: "/") {
            guard let next = current.children.first(where: { $0.name == component }) else {
                return (current, false)
            }
            current = next
        }
        return (current, true)
    }
}

/// One off-main-thread pass over a freshly installed tree: optional re-sort and the
/// count of unreadable items. (Node lookup needs no table: `FileNode.ID` holds its node.)
struct TreeIndex: Sendable {
    var unreadable = 0

    /// Walks the tree (read-only, unless `sortBy` is given). Callers must guarantee
    /// nothing mutates the tree meanwhile.
    static func build(_ root: FileNode, sortBy metric: SizeMetric? = nil) async -> TreeIndex {
        await Task.detached(priority: .userInitiated) {
            if let metric { root.sortChildren(by: metric) }
            var index = TreeIndex()
            var stack = [root]
            while let node = stack.popLast() {
                if node.errorCode != 0 { index.unreadable += 1 }
                if node.kind == .directory { stack.append(contentsOf: node.children) }
            }
            return index
        }.value
    }
}

/// "just now", "5 min ago", "2 h ago", "3 d ago".
enum RelativeAge {
    static func string(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3600)) h ago"
        default: return "\(Int(seconds / 86_400)) d ago"
        }
    }
}
