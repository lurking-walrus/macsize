import CryptoKit
import Darwin
import Foundation

/// On-disk store of scan snapshots, shared by the app and the CLI.
///
/// One file per scanned root, named by the SHA-256 of the resolved root path, holding a
/// compact LZFSE-compressed preorder encoding of the tree (see `SnapshotCodec.swift`).
/// Writes go to a temporary file and are renamed into place, so concurrent writers
/// (the app and `macsize`) never expose a half-written snapshot. Least recently
/// used snapshots beyond `maxEntries` are evicted after each save; the file's
/// modification date records the last use.
public final class ScanCache: @unchecked Sendable {
    /// `~/Library/Caches/MacSize/Scans`, shared by MacSize.app (any build) and `macsize`.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacSize", isDirectory: true)
            .appendingPathComponent("Scans", isDirectory: true)
    }

    static let fileExtension = "macsize-scan"
    static let temporaryExtension = "tmp"
    /// Temporary files older than this are leftovers from a crashed writer.
    static let staleTemporaryAge: TimeInterval = 3600

    public let directory: URL
    /// Most snapshots kept; least recently used are evicted on save.
    public let maxEntries: Int

    public init(directory: URL = ScanCache.defaultDirectory, maxEntries: Int = 5) {
        self.directory = directory
        self.maxEntries = maxEntries
    }

    /// Summary of one cached snapshot (cheap: doesn't decode the tree).
    public struct Entry: Sendable, Equatable {
        public var metadata: ScanSnapshotMetadata
        public var fileURL: URL
        public var sizeOnDisk: Int64
    }

    /// The cached snapshot for `rootPath` (resolved, as `DiskScanner` reports it), or nil
    /// if none exists, it's unreadable/corrupt, the format version is old, or it was made
    /// with different options. Never throws for a cache miss.
    public func load(rootPath: String, optionsFingerprint: String) -> ScanSnapshot? {
        let url = fileURL(forRootPath: rootPath)
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let preamble: SnapshotPreamble
        let metadata: ScanSnapshotMetadata
        switch readHeader(fd) {
        case .ok(let p, let m):
            preamble = p
            metadata = m
        case .corrupt, .olderVersion:
            removeIfSameFile(url, fd: fd)
            return nil
        case .newerVersion:
            return nil  // Written by a newer build; leave it for that build.
        }
        guard metadata.rootPath == rootPath, metadata.optionsFingerprint == optionsFingerprint else { return nil }

        let root: FileNode
        do {
            root = try SnapshotCodec.readTree(from: fd, preamble: preamble)
        } catch {
            removeIfSameFile(url, fd: fd)
            return nil
        }
        // Record the use for LRU eviction.
        _ = utimes(url.path, nil)
        return ScanSnapshot(metadata: metadata, root: root)
    }

    /// Only the metadata for `rootPath`, without decoding the tree.
    public func metadata(rootPath: String) -> ScanSnapshotMetadata? {
        let url = fileURL(forRootPath: rootPath)
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard case .ok(_, let metadata) = readHeader(fd), metadata.rootPath == rootPath else { return nil }
        return metadata
    }

    /// Write (atomically) and evict older entries beyond `maxEntries`.
    /// Reads `snapshot.root`; don't mutate the tree concurrently.
    public func save(_ snapshot: ScanSnapshot) throws {
        try ensureDirectory()
        let finalURL = fileURL(forRootPath: snapshot.metadata.rootPath)
        let temporaryURL = directory.appendingPathComponent(
            ".\(finalURL.deletingPathExtension().lastPathComponent).\(UUID().uuidString).\(Self.temporaryExtension)")

        let fd = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            try SnapshotCodec.write(snapshot, to: fd)
            guard close(fd) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            close(fd)
            unlink(temporaryURL.path)
            throw Self.publicError(error)
        }
        guard rename(temporaryURL.path, finalURL.path) == 0 else {
            let code = errno
            unlink(temporaryURL.path)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        evict()
    }

    public func remove(rootPath: String) throws {
        try removeFile(fileURL(forRootPath: rootPath))
    }

    /// All cached snapshots, most recently used first.
    public func entries() -> [Entry] {
        snapshotFiles().compactMap { file in
            let fd = open(file.url.path, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            guard case .ok(_, let metadata) = readHeader(fd) else { return nil }
            return Entry(metadata: metadata, fileURL: file.url, sizeOnDisk: file.size)
        }
    }

    /// Removes every snapshot (and any temporary files) in `directory`.
    public func clear() throws {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where Self.isCacheFileName(name) {
            try removeFile(directory.appendingPathComponent(name))
        }
    }

    // MARK: - Files

    /// `<sha256 hex of the root path>.macsize-scan`; never contains the raw path.
    func fileURL(forRootPath rootPath: String) -> URL {
        let digest = SHA256.hash(data: Data(rootPath.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hex).appendingPathExtension(Self.fileExtension)
    }

    static func isCacheFileName(_ name: String) -> Bool {
        name.hasSuffix("." + fileExtension) || (name.hasPrefix(".") && name.hasSuffix("." + temporaryExtension))
    }

    private func ensureDirectory() throws {
        let path = directory.path
        var info = stat()
        if lstat(path, &info) != 0 {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        // Saved scans list file names, so keep the folder private even if it pre-existed.
        _ = chmod(path, 0o700)
    }

    private func removeFile(_ url: URL) throws {
        if unlink(url.path) != 0 && errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Deletes `url` only if it is still the file `fd` refers to, so a reader that found a
    /// bad file can't delete a good one another process just renamed into place.
    private func removeIfSameFile(_ url: URL, fd: Int32) {
        var opened = stat()
        var current = stat()
        guard fstat(fd, &opened) == 0, lstat(url.path, &current) == 0,
              opened.st_dev == current.st_dev, opened.st_ino == current.st_ino else { return }
        unlink(url.path)
    }

    private struct SnapshotFile {
        var url: URL
        var size: Int64
        var lastUsed: TimeInterval
    }

    /// Snapshot files with their size and last-use time, most recent first.
    private func snapshotFiles() -> [SnapshotFile] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var files: [SnapshotFile] = []
        for name in names where name.hasSuffix("." + Self.fileExtension) && !name.hasPrefix(".") {
            let url = directory.appendingPathComponent(name)
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            let time = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
            files.append(SnapshotFile(url: url, size: Int64(info.st_size), lastUsed: time))
        }
        return files.sorted { $0.lastUsed > $1.lastUsed }
    }

    /// Keeps the `maxEntries` most recently used snapshots and sweeps stale temp files.
    private func evict() {
        for file in snapshotFiles().dropFirst(max(0, maxEntries)) {
            unlink(file.url.path)
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let cutoff = Date().timeIntervalSince1970 - Self.staleTemporaryAge
        for name in names where name.hasPrefix(".") && name.hasSuffix("." + Self.temporaryExtension) {
            let path = directory.appendingPathComponent(name).path
            var info = stat()
            if lstat(path, &info) == 0, Double(info.st_mtimespec.tv_sec) < cutoff { unlink(path) }
        }
    }

    // MARK: - Header

    private enum HeaderResult {
        case ok(SnapshotPreamble, ScanSnapshotMetadata)
        case corrupt
        case olderVersion
        case newerVersion
    }

    /// Reads the preamble and JSON metadata, leaving `fd` positioned at the body.
    private func readHeader(_ fd: Int32) -> HeaderResult {
        var bytes = [UInt8](repeating: 0, count: SnapshotPreamble.size)
        let got = (try? bytes.withUnsafeMutableBytes { try readFully(fd, $0.baseAddress!, $0.count) }) ?? 0
        guard got == SnapshotPreamble.size, let preamble = SnapshotPreamble(bytes: bytes) else { return .corrupt }
        let current = ScanSnapshotMetadata.currentFormatVersion
        if Int(preamble.formatVersion) < current { return .olderVersion }
        if Int(preamble.formatVersion) > current { return .newerVersion }
        guard preamble.headerLength > 0, preamble.headerLength <= SnapshotPreamble.maxHeaderLength else { return .corrupt }

        var header = Data(count: Int(preamble.headerLength))
        let headerRead = (try? header.withUnsafeMutableBytes { try readFully(fd, $0.baseAddress!, $0.count) }) ?? 0
        guard headerRead == header.count,
              var metadata = try? JSONDecoder().decode(ScanSnapshotMetadata.self, from: header) else { return .corrupt }
        metadata.formatVersion = Int(preamble.formatVersion)
        return .ok(preamble, metadata)
    }

    static func publicError(_ error: Error) -> Error {
        switch error {
        case SnapshotCodecError.io(let code):
            return POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        case is SnapshotCodecError:
            return CocoaError(.fileWriteUnknown)
        default:
            return error
        }
    }
}
