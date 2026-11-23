import CoreGraphics
import Darwin
import Foundation
import Testing
@testable import MacSizeCore

/// Creates a throwaway directory tree under the system temp directory.
final class Fixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsize-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// Fully resolved path (FileManager's URL resolution drops /private, realpath doesn't).
    var realPath: String {
        guard let resolved = realpath(root.path, nil) else { return root.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    @discardableResult
    func file(_ relative: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    func directory(_ relative: String) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(relative), withIntermediateDirectories: true)
    }

    func allocatedSize(_ relative: String) -> Int64 {
        var info = stat()
        lstat(root.appendingPathComponent(relative).path, &info)
        return Int64(info.st_blocks) * 512
    }
}

@Suite struct ScannerTests {
    @Test func scansNestedTreeWithCorrectTotals() throws {
        let fx = try Fixture()
        try fx.file("a.txt", bytes: 1000)
        try fx.file("sub/b.bin", bytes: 50_000)
        try fx.file("sub/deeper/c.dat", bytes: 7)
        try fx.directory("empty")

        let root = try DiskScanner().scanSynchronously(path: fx.root.path)

        #expect(root.logicalSize == 51_007)
        #expect(root.fileCount == 3)
        #expect(root.directoryCount == 3)
        let expectedAllocated = fx.allocatedSize("a.txt") + fx.allocatedSize("sub/b.bin") + fx.allocatedSize("sub/deeper/c.dat")
        #expect(root.allocatedSize == expectedAllocated)

        // Children are sorted largest first, names match the filesystem.
        #expect(root.children.map(\.name) == ["sub", "a.txt", "empty"])
        let sub = try #require(root.children.first)
        #expect(sub.isDirectory)
        #expect(sub.children.map(\.name) == ["b.bin", "deeper"])
        #expect(sub.children[0].path == fx.realPath + "/sub/b.bin")
    }

    @Test func handlesManyEntriesAcrossBufferRefills() throws {
        let fx = try Fixture()
        // Enough entries with long names to need several getattrlistbulk calls.
        let count = 3000
        for i in 0..<count {
            try fx.file("many/file-with-a-fairly-long-name-to-fill-the-buffer-\(i).txt", bytes: i % 10 + 1)
        }
        let root = try DiskScanner(options: ScanOptions(threadCount: 1)).scanSynchronously(path: fx.root.path)
        let many = try #require(root.children.first)
        #expect(many.children.count == count)
        #expect(Set(many.children.map(\.name)).count == count)
        #expect(root.logicalSize == Int64((0..<count).reduce(0) { $0 + $1 % 10 + 1 }))
    }

    @Test func countsHardLinksOnce() throws {
        let fx = try Fixture()
        let original = try fx.file("original.bin", bytes: 100_000)
        try FileManager.default.linkItem(at: original, to: fx.root.appendingPathComponent("link.bin"))

        let root = try DiskScanner().scanSynchronously(path: fx.root.path)
        #expect(root.fileCount == 2)
        #expect(root.logicalSize == 100_000)
    }

    @Test func doesNotFollowSymlinks() throws {
        let fx = try Fixture()
        try fx.file("target/big.bin", bytes: 200_000)
        try FileManager.default.createSymbolicLink(
            at: fx.root.appendingPathComponent("alias"),
            withDestinationURL: fx.root.appendingPathComponent("target")
        )
        let root = try DiskScanner().scanSynchronously(path: fx.root.path)
        let alias = try #require(root.children.first { $0.name == "alias" })
        #expect(alias.kind == .symlink)
        #expect(root.logicalSize < 200_000 + 4096)
    }

    @Test func respectsExcludedPaths() throws {
        let fx = try Fixture()
        try fx.file("keep/a.bin", bytes: 10)
        try fx.file("skip/b.bin", bytes: 99_999)
        // Exclusions given via a symlinked prefix (/var -> /private/var) must still match.
        let options = ScanOptions(excludedPaths: [fx.root.path + "/skip/"])
        let root = try DiskScanner(options: options).scanSynchronously(path: fx.root.path)
        let skip = try #require(root.children.first { $0.name == "skip" })
        #expect(skip.isExcluded)
        #expect(root.logicalSize == 10)
    }

    @Test func singleFileRoot() throws {
        let fx = try Fixture()
        let url = try fx.file("only.bin", bytes: 1234)
        let root = try DiskScanner().scanSynchronously(path: url.path)
        #expect(root.kind == .file)
        #expect(root.logicalSize == 1234)
    }

    @Test func missingPathThrows() {
        #expect(throws: ScanError.self) {
            try DiskScanner().scanSynchronously(path: "/nonexistent-\(UUID().uuidString)")
        }
    }

    @Test func asyncScanMatchesSync() async throws {
        let fx = try Fixture()
        try fx.file("x/y/z.bin", bytes: 4321)
        let root = try await DiskScanner().scan(path: fx.root.path)
        #expect(root.logicalSize == 4321)
    }

    @Test func removeFromParentUpdatesAncestors() throws {
        let fx = try Fixture()
        try fx.file("a/b/big.bin", bytes: 30_000)
        try fx.file("a/small.bin", bytes: 100)
        let root = try DiskScanner().scanSynchronously(path: fx.root.path)
        let a = try #require(root.children.first)
        let b = try #require(a.children.first { $0.name == "b" })
        b.removeFromParent()
        #expect(root.logicalSize == 100)
        #expect(root.fileCount == 1)
        #expect(root.directoryCount == 1)
        #expect(b.parent == nil)
    }

    @Test func largestFilesAndTypes() throws {
        let fx = try Fixture()
        try fx.file("1.mov", bytes: 90_000)
        try fx.file("d/2.mov", bytes: 70_000)
        try fx.file("d/3.txt", bytes: 50_000)
        try fx.file("4", bytes: 10)
        let root = try DiskScanner().scanSynchronously(path: fx.root.path)

        let top = root.largestFiles(count: 2, metric: .logical)
        #expect(top.map(\.name) == ["1.mov", "2.mov"])

        let types = root.fileTypeSummary(metric: .logical)
        #expect(types.first?.fileExtension == "mov")
        #expect(types.first?.count == 2)
        #expect(types.contains { $0.fileExtension == "" && $0.count == 1 })
    }

    @Test func jsonReportRespectsDepth() throws {
        let fx = try Fixture()
        try fx.file("a/b/c.bin", bytes: 1)
        let root = try DiskScanner().scanSynchronously(path: fx.root.path)
        let report = NodeReport(node: root, maxDepth: 1)
        #expect(report.children?.count == 1)
        #expect(report.children?.first?.children == nil)
        let json = try JSONSerialization.jsonObject(with: report.jsonData()) as? [String: Any]
        #expect(json?["logicalSize"] as? Int == 1)
    }
}

@Suite struct FormatterTests {
    @Test func formatsDecimalAndBinary() {
        #expect(SizeFormatter.string(0) == "0 B")
        #expect(SizeFormatter.string(999) == "999 B")
        #expect(SizeFormatter.string(1_500) == "1.50 KB")
        #expect(SizeFormatter.string(12_345_678) == "12.3 MB")
        #expect(SizeFormatter.string(1024, binary: true) == "1.00 KiB")
        #expect(SizeFormatter.string(500 * 1_000_000_000) == "500 GB")
    }

    @Test func parsesSizes() {
        #expect(SizeFormatter.parse("100") == 100)
        #expect(SizeFormatter.parse("10K") == 10_000)
        #expect(SizeFormatter.parse("1.5MB") == 1_500_000)
        #expect(SizeFormatter.parse("2GiB") == Int64(2) << 30)
        #expect(SizeFormatter.parse("3t") == 3_000_000_000_000)
        #expect(SizeFormatter.parse("abc") == nil)
        #expect(SizeFormatter.parse("5X") == nil)
    }

    @Test func groupsDigits() {
        #expect(SizeFormatter.grouped(0) == "0")
        #expect(SizeFormatter.grouped(1234567) == "1,234,567")
    }
}

@Suite struct TreemapTests {
    @Test func areasAreProportionalAndInBounds() {
        let bounds = CGRect(x: 10, y: 20, width: 600, height: 400)
        let values: [Double] = [6, 6, 4, 3, 2, 2, 1]
        let rects = Treemap.squarify(values, in: bounds)
        let total = values.reduce(0, +)

        #expect(rects.count == values.count)
        for (value, rect) in zip(values, rects) {
            let expected = value / total * Double(bounds.width * bounds.height)
            #expect(abs(Double(rect.width * rect.height) - expected) < 0.5)
            #expect(bounds.insetBy(dx: -0.01, dy: -0.01).contains(rect))
        }
        for i in rects.indices {
            for j in rects.indices where j > i {
                let overlap = rects[i].intersection(rects[j])
                #expect(overlap.isNull || overlap.width * overlap.height < 0.01)
            }
        }
    }

    @Test func preservesInputOrderAndSkipsZeros() {
        let rects = Treemap.squarify([1, 0, 3], in: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(rects[1] == .zero)
        #expect(rects[2].width * rects[2].height > rects[0].width * rects[0].height)
    }

    @Test func emptyInputs() {
        #expect(Treemap.squarify([], in: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
        #expect(Treemap.squarify([1], in: .zero) == [.zero])
    }
}

@Suite struct CommandLineToolTests {
    /// Writes a fake `macsize` script that prints the given version.
    private func fakeTool(in directory: String, version: String) throws -> String {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = directory + "/macsize"
        try "#!/bin/sh\necho \"macsize \(version)\"\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    @Test func parsesVersionOutput() {
        #expect(CommandLineToolManager.parseVersion("macsize 1.2.3\n") == "1.2.3")
        #expect(CommandLineToolManager.parseVersion("something else") == nil)
    }

    @Test func installsSymlinkAndDetectsIt() throws {
        let fx = try Fixture()
        let source = try fakeTool(in: fx.root.path + "/App.app/Contents/Helpers", version: "9.9.9")
        let bin = fx.root.path + "/bin"
        let manager = CommandLineToolManager(pathDirectories: [bin])

        #expect(manager.findInstalls(extraDirectories: []).isEmpty)
        try manager.installSymlink(source: source, in: bin)

        let installs = manager.findInstalls(extraDirectories: [])
        let install = try #require(installs.first)
        #expect(install.isSymlink)
        #expect(!install.isBroken)
        #expect(install.isOnPath)
        #expect(install.version == "9.9.9")

        // Re-installing replaces the link rather than failing.
        try manager.installSymlink(source: source, in: bin)
        #expect(manager.findInstalls(extraDirectories: []).count == 1)
    }

    @Test func detectsBrokenLinkAndOffPathInstalls() throws {
        let fx = try Fixture()
        let source = try fakeTool(in: fx.root.path + "/gone", version: "1.0.0")
        let elsewhere = fx.root.path + "/elsewhere"
        let manager = CommandLineToolManager(pathDirectories: [fx.root.path + "/onpath"])
        try manager.installSymlink(source: source, in: elsewhere)
        try FileManager.default.removeItem(atPath: source)

        let install = try #require(manager.findInstalls(extraDirectories: [elsewhere]).first)
        #expect(install.isBroken)
        #expect(!install.isOnPath)
        #expect(install.version == nil)

        try manager.uninstall(install)
        #expect(manager.findInstalls(extraDirectories: [elsewhere]).isEmpty)
    }

    @Test func refusesToUninstallUnrelatedFile() throws {
        let fx = try Fixture()
        let bin = fx.root.path + "/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try "not a tool".write(toFile: bin + "/macsize", atomically: true, encoding: .utf8)
        let manager = CommandLineToolManager(pathDirectories: [bin])
        let install = try #require(manager.findInstalls(extraDirectories: []).first)
        #expect(throws: (any Error).self) { try manager.uninstall(install) }
        #expect(FileManager.default.fileExists(atPath: bin + "/macsize"))
    }
}

@Suite struct FullDiskAccessTests {
    @Test func readableProbeMeansGranted() throws {
        let fx = try Fixture()
        let file = try fx.file("probe.db", bytes: 4)
        #expect(FullDiskAccess.check(probePaths: [fx.root.path + "/missing", file.path]) == .granted)
    }

    @Test func permissionDeniedMeansDenied() throws {
        let fx = try Fixture()
        let file = try fx.file("locked.db", bytes: 4)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        guard getuid() != 0 else { return }  // root ignores file modes
        #expect(FullDiskAccess.check(probePaths: [file.path, fx.root.path + "/missing"]) == .denied)
    }

    @Test func missingProbesAreUnknown() {
        #expect(FullDiskAccess.check(probePaths: ["/nonexistent-\(UUID().uuidString)"]) == .unknown)
        #expect(FullDiskAccess.check(probePaths: []) == .unknown)
    }
}
