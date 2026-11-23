import Foundation

/// A completed scan plus everything needed to refresh it incrementally later.
public struct ScanSnapshot: @unchecked Sendable {
    public var metadata: ScanSnapshotMetadata
    /// Root of the scanned tree. Treat as owned by whoever holds the snapshot:
    /// read it from any thread, but only mutate it (e.g. `FileNode.apply(_:)`)
    /// where nothing else is reading it.
    public var root: FileNode

    public init(metadata: ScanSnapshotMetadata, root: FileNode) {
        self.metadata = metadata
        self.root = root
    }
}

public struct ScanSnapshotMetadata: Codable, Sendable, Equatable {
    /// Bumped whenever the on-disk encoding changes; older caches are discarded.
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    /// Fully resolved root path (as returned by `DiskScanner`, e.g. /private/tmp not /tmp).
    public var rootPath: String
    /// FSEvents UUID of the root's volume. A different UUID means the volume was
    /// reformatted or the event history reset, so the cache can't be refreshed incrementally.
    public var volumeUUID: String?
    /// FSEvents event ID captured *before* the scan started, so changes made during
    /// the scan are replayed on the next refresh.
    public var eventID: UInt64
    public var scannedAt: Date
    /// `ScanOptions.fingerprint` the tree was produced with; a mismatch means a full rescan.
    public var optionsFingerprint: String
    public var fileCount: Int
    public var directoryCount: Int
    public var allocatedSize: Int64
    public var logicalSize: Int64

    public init(
        formatVersion: Int = ScanSnapshotMetadata.currentFormatVersion,
        rootPath: String,
        volumeUUID: String?,
        eventID: UInt64,
        scannedAt: Date,
        optionsFingerprint: String,
        fileCount: Int,
        directoryCount: Int,
        allocatedSize: Int64,
        logicalSize: Int64
    ) {
        self.formatVersion = formatVersion
        self.rootPath = rootPath
        self.volumeUUID = volumeUUID
        self.eventID = eventID
        self.scannedAt = scannedAt
        self.optionsFingerprint = optionsFingerprint
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.allocatedSize = allocatedSize
        self.logicalSize = logicalSize
    }

    /// Metadata describing `root`, for a scan that began at `eventID`.
    public init(root: FileNode, options: ScanOptions, eventID: UInt64, scannedAt: Date = Date()) {
        self.init(
            rootPath: root.path,
            volumeUUID: ChangeJournal.volumeUUID(forPath: root.path),
            eventID: eventID,
            scannedAt: scannedAt,
            optionsFingerprint: options.fingerprint,
            fileCount: root.fileCount,
            directoryCount: root.directoryCount,
            allocatedSize: root.allocatedSize,
            logicalSize: root.logicalSize
        )
    }
}
