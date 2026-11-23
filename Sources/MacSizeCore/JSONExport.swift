import Foundation

/// A depth-limited, encodable snapshot of a `FileNode` subtree.
public struct NodeReport: Encodable, Sendable {
    public var name: String
    public var path: String?
    public var kind: FileKind
    public var allocatedSize: Int64
    public var logicalSize: Int64
    public var fileCount: Int
    public var directoryCount: Int
    public var modified: Date
    public var error: String?
    public var excluded: Bool?
    /// `true` for a cloud-only placeholder whose contents aren't on this Mac (omitted otherwise).
    public var cloudOnly: Bool?
    /// Logical bytes in this subtree that are only in the cloud (not downloaded).
    public var cloudOnlySize: Int64
    /// Number of cloud-only items in this subtree.
    public var cloudOnlyCount: Int
    public var children: [NodeReport]?

    /// - Parameters:
    ///   - maxDepth: how many levels of children to include (`nil` = unlimited).
    ///   - limit: maximum children per directory (largest first).
    ///   - minimumSize: omit children smaller than this (by `metric`).
    public init(
        node: FileNode,
        maxDepth: Int?,
        limit: Int? = nil,
        minimumSize: Int64 = 0,
        metric: SizeMetric = .allocated,
        includePath: Bool = true
    ) {
        name = node.parent == nil ? (node.name as NSString).lastPathComponent : node.name
        path = includePath ? node.path : nil
        kind = node.kind
        allocatedSize = node.allocatedSize
        logicalSize = node.logicalSize
        fileCount = node.fileCount
        directoryCount = node.directoryCount
        modified = Date(timeIntervalSince1970: node.modificationTime)
        error = node.errorCode != 0 ? String(cString: strerror(node.errorCode)) : nil
        excluded = node.isExcluded ? true : nil
        cloudOnly = node.isCloudOnly ? true : nil
        cloudOnlySize = node.cloudOnlySize
        cloudOnlyCount = node.cloudOnlyCount

        if node.isDirectory, maxDepth.map({ $0 > 0 }) ?? true {
            var kids = node.children.filter { $0.size(metric) >= minimumSize }
            if let limit { kids = Array(kids.prefix(limit)) }
            children = kids.map {
                NodeReport(
                    node: $0,
                    maxDepth: maxDepth.map { $0 - 1 },
                    limit: limit,
                    minimumSize: minimumSize,
                    metric: metric,
                    includePath: false
                )
            }
        }
    }

    public func jsonData(pretty: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
