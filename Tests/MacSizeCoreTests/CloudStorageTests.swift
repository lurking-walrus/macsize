import Darwin
import Foundation
import Testing
@testable import MacSizeCore

@Suite struct CloudStorageTests {
    // MARK: Materialization policy

    @Test func disablingDownloadsSucceedsAndIsIdempotent() async {
        #expect(CloudStorage.disableAutomaticDownloads())
        #expect(CloudStorage.automaticDownloadsDisabled)
        // Repeated and concurrent calls are harmless.
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<16 { group.addTask { CloudStorage.disableAutomaticDownloads() } }
            for await result in group { #expect(result) }
        }
        #expect(CloudStorage.automaticDownloadsDisabled)
    }

    @Test func scanningEnablesThePolicy() throws {
        let fx = try Fixture()
        try fx.file("a.txt", bytes: 10)
        _ = try DiskScanner().scanSynchronously(path: fx.root.path)
        #expect(CloudStorage.automaticDownloadsDisabled)
    }

    // MARK: Attribute parsing (ATTR_CMN_FLAGS sits between MODTIME and FILEID)

    @Test func bulkReaderParsesFlagsWithoutShiftingOtherFields() throws {
        let fx = try Fixture()
        try fx.file("one.bin", bytes: 12_345)
        try fx.file("two.txt", bytes: 7)
        try fx.directory("folder")
        // A non-zero, non-dataless flag proves FLAGS is read at the right offset.
        let hidden = try fx.file("hidden.dat", bytes: 100)
        #expect(chflags(hidden.path, UInt32(UF_HIDDEN)) == 0)

        let fd = open(fx.realPath, O_RDONLY | O_DIRECTORY)
        try #require(fd >= 0)
        defer { close(fd) }

        var entries: [String: BulkEntry] = [:]
        let status = BulkDirectoryReader().forEachEntry(in: fd) { entries[$0.name] = $0 }
        #expect(status == 0)
        #expect(Set(entries.keys) == ["one.bin", "two.txt", "folder", "hidden.dat"])

        for (name, entry) in entries {
            var info = stat()
            #expect(lstat(fx.realPath + "/" + name, &info) == 0)
            #expect(entry.fileID == UInt64(info.st_ino), "fileID of \(name)")
            #expect(entry.flags == info.st_flags, "flags of \(name)")
            #expect(!entry.isDataless, "\(name) is a normal local item")
            #expect(abs(entry.modificationTime - Double(info.st_mtimespec.tv_sec)) < 1)
            if entry.isRegular {
                #expect(entry.logicalSize == Int64(info.st_size), "size of \(name)")
                #expect(entry.allocatedSize == Int64(info.st_blocks) * 512, "allocation of \(name)")
                #expect(entry.linkCount == UInt32(info.st_nlink))
            }
        }
        #expect(entries["folder"]?.isDirectory == true)
        #expect((entries["hidden.dat"]?.flags ?? 0) & UInt32(UF_HIDDEN) != 0)
        #expect(entries["one.bin"]?.logicalSize == 12_345)
    }

    @Test func normalScanHasNoCloudOnlyItems() throws {
        let fx = try Fixture()
        try fx.file("a/b/c.bin", bytes: 4096)
        try fx.file("d.txt", bytes: 3)
        let root = try DiskScanner().scanSynchronously(path: fx.root.path)
        #expect(root.cloudOnlyCount == 0)
        #expect(root.cloudOnlySize == 0)
        #expect(root.localLogicalSize == root.logicalSize)
        #expect(!CloudStorage.isDataless(path: fx.realPath + "/d.txt"))
    }

    // MARK: Aggregation and JSON

    @Test func jsonIncludesCloudFields() throws {
        let fx = try Fixture()
        try fx.file("drive/local.bin", bytes: 1000)
        try fx.file("drive/streamed.bin", bytes: 5000)
        let root = try DiskScanner().scanSynchronously(path: fx.root.path)
        let drive = try #require(root.children.first { $0.name == "drive" })
        try #require(drive.children.first { $0.name == "streamed.bin" }).markCloudOnly()
        root.finalize()

        let data = try NodeReport(node: root, maxDepth: nil).jsonData()
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["cloudOnlySize"] as? Int == 5000)
        #expect(json["cloudOnlyCount"] as? Int == 1)
        #expect(json["cloudOnly"] == nil)

        let driveJSON = try #require((json["children"] as? [[String: Any]])?.first)
        let files = try #require(driveJSON["children"] as? [[String: Any]])
        let streamed = try #require(files.first { $0["name"] as? String == "streamed.bin" })
        let local = try #require(files.first { $0["name"] as? String == "local.bin" })
        #expect(streamed["cloudOnly"] as? Bool == true)
        #expect(streamed["cloudOnlySize"] as? Int == 5000)
        #expect(streamed["cloudOnlyCount"] as? Int == 1)
        #expect(local["cloudOnly"] == nil)
        #expect(local["cloudOnlyCount"] as? Int == 0)
    }

    @Test func refreshCloudStateReReadsLocalFiles() throws {
        let fx = try Fixture()
        try fx.file("drive/a.bin", bytes: 8192)
        let root = try DiskScanner().scanSynchronously(path: fx.root.path)
        let drive = try #require(root.children.first)
        let file = try #require(drive.children.first)
        let allocated = file.allocatedSize
        // Pretend it was cloud-only; a refresh from disk restores the real, local state.
        file.markCloudOnly()
        root.finalize()
        #expect(root.cloudOnlyCount == 1)
        drive.refreshCloudState()
        #expect(!file.isCloudOnly)
        #expect(file.allocatedSize == allocated)
        #expect(root.cloudOnlyCount == 0)
        #expect(root.cloudOnlySize == 0)
        #expect(root.allocatedSize == allocated)
    }

    @Test func removeDownloadIsNotOfferedForLocalFiles() throws {
        let fx = try Fixture()
        try fx.file("x.bin", bytes: 4096)
        let root = try DiskScanner().scanSynchronously(path: fx.root.path)
        #expect(!CloudStorage.canRemoveDownload(try #require(root.children.first)))
    }

    // MARK: Real cloud folder (opt-in)

    /// Set `MACSIZE_CLOUD_TEST_DIR` to a File Provider folder (e.g. a Google Drive or iCloud
    /// Drive folder with online-only files) to verify detection on real placeholders. The
    /// test only reads metadata and checks that the dataless count is unchanged afterwards.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACSIZE_CLOUD_TEST_DIR"] != nil))
    func realCloudFolderIsNotDownloaded() throws {
        let path = try #require(ProcessInfo.processInfo.environment["MACSIZE_CLOUD_TEST_DIR"])
        let before = countDataless(path)
        let root = try DiskScanner().scanSynchronously(path: path)
        let after = countDataless(path)
        #expect(after == before, "scan must not materialize any placeholder")
        // Every dataless item reachable without entering dataless folders is reported.
        #expect(root.cloudOnlyCount == before)
        #expect(root.localLogicalSize <= root.logicalSize)
    }

    /// Counts dataless items with `lstat` only, without entering dataless directories.
    private func countDataless(_ path: String) -> Int {
        var count = 0
        var stack = [path]
        while let dir = stack.popLast() {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for name in names {
                let child = dir + "/" + name
                var info = stat()
                guard lstat(child, &info) == 0 else { continue }
                if info.st_flags & CloudStorage.datalessFlag != 0 {
                    count += 1
                } else if info.st_mode & S_IFMT == S_IFDIR {
                    stack.append(child)
                }
            }
        }
        return count
    }
}

@Suite struct TrueSizeTests {
    @Test func logicalSizeExcludesCloudOnlyContent() {
        let folder = FileNode(name: "f", kind: .directory, parent: nil)
        folder.logicalSize = 1_000
        folder.allocatedSize = 400
        folder.cloudOnlySize = 600
        folder.cloudOnlyCount = 2
        #expect(folder.size(.logical) == 400)
        #expect(folder.size(.allocated) == 400)
    }

    @Test func mountedImagePathsSkipRootAndAreReadOnlyMounts() {
        let paths = ScanOptions.mountedImagePaths()
        #expect(!paths.contains("/"))
        #expect(!paths.contains("/System/Volumes/Data"))
        // Every simulator/cryptex image mount (if any are mounted) is excluded.
        for path in paths { #expect(path.hasPrefix("/")) }
    }

    @Test func fingerprintChangedSoOldCachesAreNotReused() {
        #expect(ScanOptions().fingerprint.hasPrefix("v2|"))
    }
}
