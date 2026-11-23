import CryptoKit
import os
import Darwin
import Foundation
import Testing
@testable import MacSizeCore

/// A cache in a private temp directory, removed on deinit.
private final class CacheFixture: Sendable {
    let directory: URL
    let cache: ScanCache

    init(maxEntries: Int = 5) {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsize-cache-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Scans", isDirectory: true)
        cache = ScanCache(directory: directory, maxEntries: maxEntries)
    }

    deinit { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    func url(for rootPath: String) -> URL { cache.fileURL(forRootPath: rootPath) }

    func exists(_ rootPath: String) -> Bool { FileManager.default.fileExists(atPath: url(for: rootPath).path) }

    func fileNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }
}

private func snapshot(_ root: FileNode, fingerprint: String = "fp", eventID: UInt64 = 42) -> ScanSnapshot {
    let metadata = ScanSnapshotMetadata(
        rootPath: root.path, volumeUUID: "TEST-VOLUME", eventID: eventID,
        scannedAt: Date(timeIntervalSince1970: 1_700_000_000), optionsFingerprint: fingerprint,
        fileCount: root.fileCount, directoryCount: root.directoryCount,
        allocatedSize: root.allocatedSize, logicalSize: root.logicalSize)
    return ScanSnapshot(metadata: metadata, root: root)
}

/// Deterministic tree with repeated and unique names, fractional mtimes and odd sizes.
private func syntheticTree(rootPath: String, nodes target: Int, seed: UInt64 = 1) -> FileNode {
    var rng = seed
    func next() -> UInt64 {
        rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return rng >> 17
    }
    let common = [".DS_Store", "index.js", "package.json", "README.md", "LICENSE", "node_modules",
                  "Info.plist", "icon.png", "main.swift", "__init__.py"]
    let root = FileNode(name: rootPath, kind: .directory, modificationTime: 1_600_000_000.25)
    var directories = [root]
    var count = 1
    while count < target {
        let parent = directories[Int(next() % UInt64(directories.count))]
        let isDirectory = next() % 8 == 0
        let roll = next() % 10
        let name: String
        if roll < 4 {
            name = isDirectory ? "node_modules" : common[Int(next() % UInt64(common.count))]
        } else {
            name = "item-\(count)-\(next() % 100_000)" + (isDirectory ? "" : ".dat")
        }
        let logical = Int64(next() % 5_000_000)
        let allocated = next() % 50 == 0 ? logical : (logical + 4095) / 4096 * 4096
        let node = FileNode(
            name: name, kind: isDirectory ? .directory : (next() % 100 == 0 ? .symlink : .file),
            allocatedSize: allocated, logicalSize: logical,
            modificationTime: 1_500_000_000 + Double(next() % 200_000_000) + Double(next() % 1000) / 1000,
            parent: parent)
        if next() % 200 == 0 { node.errorCode = EACCES }
        if isDirectory && next() % 300 == 0 { node.isExcluded = true }
        if !isDirectory && next() % 150 == 0 { node.markCloudOnly() }
        parent.children.append(node)
        if isDirectory { directories.append(node) }
        count += 1
    }
    root.finalize()
    return root
}

/// Field-for-field comparison of two trees, including child order and parent links.
private func expectSameTree(_ original: FileNode, _ decoded: FileNode) {
    #expect(decoded.parent == nil)
    var stack: [(FileNode, FileNode)] = [(original, decoded)]
    var mismatches = 0
    var compared = 0
    while let (a, b) = stack.popLast() {
        compared += 1
        let same = a.name.utf8.elementsEqual(b.name.utf8) && a.kind == b.kind
            && a.allocatedSize == b.allocatedSize && a.logicalSize == b.logicalSize
            && a.fileCount == b.fileCount && a.directoryCount == b.directoryCount
            && a.errorCode == b.errorCode && a.isExcluded == b.isExcluded
            && a.isCloudOnly == b.isCloudOnly && a.cloudOnlySize == b.cloudOnlySize
            && a.cloudOnlyCount == b.cloudOnlyCount
            && b.modificationTime == a.modificationTime.rounded(.down)
            && a.children.count == b.children.count
        if !same {
            mismatches += 1
            if mismatches <= 5 { Issue.record("Mismatch at \(a.path) vs \(b.path)") }
            continue
        }
        for (childA, childB) in zip(a.children, b.children) {
            if childB.parent !== b {
                mismatches += 1
                Issue.record("Broken parent link at \(childB.name)")
            }
            stack.append((childA, childB))
        }
    }
    #expect(mismatches == 0)
    #expect(compared > 0)
}

private func countNodes(_ root: FileNode) -> Int {
    var count = 0
    var stack = [root]
    while let node = stack.popLast() {
        count += 1
        stack.append(contentsOf: node.children)
    }
    return count
}

@Suite struct ScanCacheTests {
    @Test func roundTripsRealScannedTreeFieldForField() throws {
        let fx = try Fixture()
        try fx.file("a.txt", bytes: 1000)
        try fx.file("sub/b.bin", bytes: 50_000)
        try fx.file("sub/deeper/c.dat", bytes: 7)
        try fx.file("Ünïcödé/naïve café.txt", bytes: 300)
        try fx.file("emoji 🎉📁/🦭 walrus.md", bytes: 12_345)
        try fx.file("日本語/ファイル.txt", bytes: 10)
        try fx.file("dups/.DS_Store", bytes: 6148)
        try fx.file("dups/x/.DS_Store", bytes: 6148)
        try fx.file("dups/y/.DS_Store", bytes: 6148)
        try fx.file("cloud/big.mov", bytes: 80_000)
        try fx.file("cloud/small.txt", bytes: 900)
        try fx.directory("empty")
        let root = try DiskScanner().scanSynchronously(path: fx.root.path)

        // Exercise every optional field.
        let cloud = try #require(root.children.first { $0.name == "cloud" })
        for child in cloud.children { child.markCloudOnly() }
        let deeper = try #require(root.children.first { $0.name == "sub" }?.children.first { $0.name == "deeper" })
        deeper.errorCode = EACCES
        let empty = try #require(root.children.first { $0.name == "empty" })
        empty.isExcluded = true
        root.finalize()
        #expect(root.cloudOnlyCount == 2)

        let cf = CacheFixture()
        try cf.cache.save(snapshot(root))
        let loaded = try #require(cf.cache.load(rootPath: fx.realPath, optionsFingerprint: "fp"))
        #expect(loaded.metadata == snapshot(root).metadata)
        #expect(loaded.root.path == fx.realPath)
        expectSameTree(root, loaded.root)
        let names = Set(loaded.root.children.map(\.name))
        #expect(names.contains("emoji 🎉📁"))
        #expect(names.contains("日本語"))
    }

    @Test func roundTripsLargeSyntheticTreeAcrossBlocks() throws {
        let root = syntheticTree(rootPath: "/synthetic/root", nodes: 150_000)
        let cf = CacheFixture()
        try cf.cache.save(snapshot(root))
        let size = try #require(cf.cache.entries().first?.sizeOnDisk)
        #expect(size > Int64(snapshotIOBlockSize))  // Crosses a compressed block boundary.
        let loaded = try #require(cf.cache.load(rootPath: "/synthetic/root", optionsFingerprint: "fp"))
        expectSameTree(root, loaded.root)
    }

    @Test func fileIsNamedByHashAndDirectoryIsPrivate() throws {
        let cf = CacheFixture()
        let root = syntheticTree(rootPath: "/private/secret name", nodes: 10)
        try cf.cache.save(snapshot(root))
        let digest = SHA256.hash(data: Data("/private/secret name".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(cf.fileNames() == ["\(digest).macsize-scan"])
        let attributes = try FileManager.default.attributesOfItem(atPath: cf.directory.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o700)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: cf.url(for: "/private/secret name").path)
        #expect((fileAttributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func missingSnapshotIsNil() {
        let cf = CacheFixture()
        #expect(cf.cache.load(rootPath: "/nothing", optionsFingerprint: "fp") == nil)
        #expect(cf.cache.metadata(rootPath: "/nothing") == nil)
        #expect(cf.cache.entries().isEmpty)
    }

    @Test(arguments: ["flip", "truncate", "magic", "trailing", "empty"])
    func corruptSnapshotIsNilAndRemoved(kind: String) throws {
        let cf = CacheFixture()
        let rootPath = "/corrupt/\(kind)"
        try cf.cache.save(snapshot(syntheticTree(rootPath: rootPath, nodes: 5_000)))
        let url = cf.url(for: rootPath)
        var bytes = try [UInt8](Data(contentsOf: url))
        switch kind {
        case "flip": bytes[bytes.count - 200] ^= 0x5A
        case "truncate": bytes.removeLast(bytes.count / 3)
        case "magic": bytes[0] = UInt8(ascii: "X")
        case "trailing": bytes.append(contentsOf: [1, 2, 3])
        default: bytes = []
        }
        try Data(bytes).write(to: url)

        #expect(cf.cache.load(rootPath: rootPath, optionsFingerprint: "fp") == nil)
        #expect(!cf.exists(rootPath))
    }

    @Test func versionMismatchIsNil() throws {
        let cf = CacheFixture()
        let rootPath = "/versions"
        let root = syntheticTree(rootPath: rootPath, nodes: 100)

        func writeVersion(_ version: UInt16) throws {
            try cf.cache.save(snapshot(root))
            let url = cf.url(for: rootPath)
            var bytes = try [UInt8](Data(contentsOf: url))
            bytes[4] = UInt8(version & 0xFF)
            bytes[5] = UInt8(version >> 8)
            try Data(bytes).write(to: url)
        }

        // Older format: unusable, discarded.
        try writeVersion(0)
        #expect(cf.cache.load(rootPath: rootPath, optionsFingerprint: "fp") == nil)
        #expect(cf.cache.metadata(rootPath: rootPath) == nil)
        #expect(!cf.exists(rootPath))

        // Newer format (a newer build wrote it): ignored but left alone.
        try writeVersion(UInt16(ScanSnapshotMetadata.currentFormatVersion + 1))
        #expect(cf.cache.load(rootPath: rootPath, optionsFingerprint: "fp") == nil)
        #expect(cf.exists(rootPath))
    }

    @Test func fingerprintAndRootMismatchAreNil() throws {
        let cf = CacheFixture()
        let root = syntheticTree(rootPath: "/fingerprint", nodes: 100)
        try cf.cache.save(snapshot(root, fingerprint: "options-A"))
        #expect(cf.cache.load(rootPath: "/fingerprint", optionsFingerprint: "options-B") == nil)
        #expect(cf.exists("/fingerprint"))  // Still valid for the other options.
        #expect(cf.cache.load(rootPath: "/fingerprint", optionsFingerprint: "options-A") != nil)

        // Simulate a hash collision: another root's file under this root's name.
        try FileManager.default.copyItem(at: cf.url(for: "/fingerprint"), to: cf.url(for: "/other"))
        #expect(cf.cache.load(rootPath: "/other", optionsFingerprint: "options-A") == nil)
        #expect(cf.cache.metadata(rootPath: "/other") == nil)
    }

    @Test func evictionKeepsMostRecentlyUsed() throws {
        let cf = CacheFixture(maxEntries: 2)
        func save(_ path: String) throws {
            try cf.cache.save(snapshot(syntheticTree(rootPath: path, nodes: 50)))
            usleep(20_000)
        }
        try save("/a")
        try save("/b")
        #expect(cf.cache.load(rootPath: "/a", optionsFingerprint: "fp") != nil)  // /a is now newer than /b
        usleep(20_000)
        try save("/c")
        #expect(cf.exists("/a"))
        #expect(!cf.exists("/b"))
        #expect(cf.exists("/c"))
        #expect(cf.cache.entries().map(\.metadata.rootPath) == ["/c", "/a"])

        try cf.cache.remove(rootPath: "/a")
        try cf.cache.remove(rootPath: "/a")  // Removing a missing entry is fine.
        #expect(cf.cache.entries().map(\.metadata.rootPath) == ["/c"])
        try cf.cache.clear()
        #expect(cf.cache.entries().isEmpty)
        #expect(cf.fileNames().isEmpty)
    }

    @Test func metadataAndEntriesDontDecodeTree() throws {
        let cf = CacheFixture()
        let root = syntheticTree(rootPath: "/meta", nodes: 5_000)
        let original = snapshot(root, eventID: 777)
        try cf.cache.save(original)

        // Corrupt only the body: header readers must not notice.
        let url = cf.url(for: "/meta")
        var bytes = try [UInt8](Data(contentsOf: url))
        for index in stride(from: bytes.count - 1000, to: bytes.count, by: 7) { bytes[index] ^= 0xFF }
        try Data(bytes).write(to: url)

        #expect(cf.cache.metadata(rootPath: "/meta") == original.metadata)
        let entries = cf.cache.entries()
        #expect(entries.count == 1)
        #expect(entries.first?.metadata == original.metadata)
        #expect(entries.first?.fileURL.lastPathComponent == url.lastPathComponent)
        #expect(entries.first?.sizeOnDisk == Int64(bytes.count))
        // The full load does notice, and cleans up.
        #expect(cf.cache.load(rootPath: "/meta", optionsFingerprint: "fp") == nil)
        #expect(cf.cache.entries().isEmpty)
    }

    @Test func concurrentSavesDontCorruptEachOther() throws {
        let cf = CacheFixture(maxEntries: 10)
        let sizes = [2_000, 9_000, 4_000, 15_000, 7_000, 1_000, 12_000, 3_000]
        let trees = sizes.enumerated().map { syntheticTree(rootPath: "/shared", nodes: $1, seed: UInt64($0 + 1)) }
        let otherTrees = (0..<4).map { syntheticTree(rootPath: "/other-\($0)", nodes: 3_000, seed: 99) }
        let failures = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: trees.count + otherTrees.count) { index in
            let tree = index < trees.count ? trees[index] : otherTrees[index - trees.count]
            do { try cf.cache.save(snapshot(tree)) } catch { failures.withLock { $0 += 1 } }
        }
        #expect(failures.withLock { $0 } == 0)

        let loaded = try #require(cf.cache.load(rootPath: "/shared", optionsFingerprint: "fp"))
        let winner = try #require(trees.first { countNodes($0) == countNodes(loaded.root) })
        expectSameTree(winner, loaded.root)
        for index in 0..<4 {
            #expect(cf.cache.load(rootPath: "/other-\(index)", optionsFingerprint: "fp") != nil)
        }
        #expect(cf.fileNames().allSatisfy { $0.hasSuffix(".macsize-scan") })  // No temp files left.
        #expect(cf.fileNames().count == 5)
    }

    /// `MACSIZE_CACHE_BENCH=1 swift test -c release --filter cacheBenchmark`
    /// Optional `MACSIZE_CACHE_BENCH_PATH` adds a real scan of that folder.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACSIZE_CACHE_BENCH"] != nil))
    func cacheBenchmark() throws {
        func measure(_ label: String, _ root: FileNode) throws {
            let nodes = countNodes(root)
            for algorithm in [CompressionAlgorithmID.lzfse, .lz4] {
                let cf = CacheFixture()
                try FileManager.default.createDirectory(at: cf.directory, withIntermediateDirectories: true)
                let url = cf.url(for: root.path)
                var start = Date()
                let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
                try SnapshotCodec.write(snapshot(root), to: fd, algorithm: algorithm)
                close(fd)
                let encode = Date().timeIntervalSince(start)
                let bytes = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
                start = Date()
                let loaded = try #require(cf.cache.load(rootPath: root.path, optionsFingerprint: "fp"))
                let decode = Date().timeIntervalSince(start)
                #expect(countNodes(loaded.root) == nodes)
                print(String(format: "BENCH %@ [%@]: %d nodes, encode %.3fs, decode %.3fs (%.0f ns/node), %d bytes (%.2f B/node)",
                             label, algorithm == .lzfse ? "lzfse" : "lz4", nodes, encode, decode,
                             decode / Double(nodes) * 1e9, bytes, Double(bytes) / Double(nodes)))
            }
        }
        try measure("synthetic", syntheticTree(rootPath: "/synthetic", nodes: 2_000_000))
        if let path = ProcessInfo.processInfo.environment["MACSIZE_CACHE_BENCH_PATH"] {
            try measure(path, try DiskScanner().scanSynchronously(path: path))
        }
    }
}
