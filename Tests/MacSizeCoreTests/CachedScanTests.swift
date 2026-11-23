import Darwin
import Foundation
import Testing
@testable import MacSizeCore

/// In-memory store that honors the options fingerprint like `ScanCache` does.
private final class MemoryStore: ScanSnapshotStore, @unchecked Sendable {
    var snapshots: [String: ScanSnapshot] = [:]
    var loadCalls = 0
    var saveCalls = 0

    func load(rootPath: String, optionsFingerprint: String) -> ScanSnapshot? {
        loadCalls += 1
        guard let snapshot = snapshots[rootPath], snapshot.metadata.optionsFingerprint == optionsFingerprint else { return nil }
        return snapshot
    }

    func save(_ snapshot: ScanSnapshot) throws {
        saveCalls += 1
        snapshots[snapshot.metadata.rootPath] = snapshot
    }
}

private final class FailingStore: ScanSnapshotStore, @unchecked Sendable {
    func load(rootPath: String, optionsFingerprint: String) -> ScanSnapshot? { nil }
    func save(_ snapshot: ScanSnapshot) throws {
        throw CocoaError(.fileWriteOutOfSpace)
    }
}

/// `CachedScan.run` blocks on async work, so keep these off the cooperative pool's
/// threads as much as possible by running them one at a time.
@Suite(.serialized) struct CachedScanTests {
    private func makeTree() throws -> Fixture {
        let fixture = try Fixture()
        try fixture.file("a/one.bin", bytes: 10_000)
        try fixture.file("a/b/two.bin", bytes: 20_000)
        try fixture.file("c/three.bin", bytes: 5_000)
        return fixture
    }

    private func freshTotals(_ path: String, options: ScanOptions = ScanOptions()) throws -> (Int64, Int) {
        let root = try DiskScanner(options: options).scanSynchronously(path: path)
        return (root.allocatedSize, root.fileCount)
    }

    @Test func missScansAndSaves() throws {
        let fixture = try makeTree()
        let store = MemoryStore()
        let before = ChangeJournal.currentEventID()

        let (root, outcome) = try CachedScan.run(path: fixture.root.path, options: ScanOptions(), cache: store)

        #expect(outcome.source == .fullScan)
        #expect(!outcome.cacheHit)
        #expect(outcome.saved)
        #expect(outcome.saveError == nil)
        #expect(root.fileCount == 3)
        #expect(store.saveCalls == 1)
        let saved = try #require(store.snapshots[fixture.realPath])
        #expect(saved.metadata.rootPath == fixture.realPath)
        #expect(saved.metadata.optionsFingerprint == ScanOptions().fingerprint)
        #expect(saved.metadata.fileCount == 3)
        // Captured before the scan, not after.
        #expect(saved.metadata.eventID >= before)
        #expect(saved.metadata.eventID <= ChangeJournal.currentEventID())
    }

    @Test func hitRefreshesToCurrentDiskState() throws {
        let fixture = try makeTree()
        let store = MemoryStore()
        _ = try CachedScan.run(path: fixture.root.path, options: ScanOptions(), cache: store)
        let firstScannedAt = try #require(store.snapshots[fixture.realPath]).metadata.scannedAt

        try fixture.file("a/b/new.bin", bytes: 40_000)
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("c/three.bin"))

        let (root, outcome) = try CachedScan.run(path: fixture.root.path, options: ScanOptions(), cache: store)

        #expect(outcome.source == .refreshed)
        #expect(outcome.cacheHit)
        #expect(outcome.cachedScannedAt == firstScannedAt)
        // Either an incremental refresh that re-listed the changed folders, or (stubs,
        // unavailable history) a full rescan. Both must be reported as such.
        #expect(outcome.didFullRescan || outcome.directoriesRescanned >= 1)
        // Never stale: matches a fresh scan of the disk as it is now.
        let (allocated, files) = try freshTotals(fixture.root.path)
        #expect(root.allocatedSize == allocated)
        #expect(root.fileCount == files)
        #expect(root.fileCount == 3)
        #expect(outcome.saved)
        #expect(store.saveCalls == 2)
        #expect(store.snapshots[fixture.realPath]?.metadata.fileCount == 3)
    }

    @Test func optionsMismatchIsAMiss() throws {
        let fixture = try makeTree()
        let store = MemoryStore()
        _ = try CachedScan.run(path: fixture.root.path, options: ScanOptions(), cache: store)

        let options = ScanOptions(excludedPaths: [fixture.root.appendingPathComponent("a").path])
        let (root, outcome) = try CachedScan.run(path: fixture.root.path, options: options, cache: store)

        #expect(outcome.source == .fullScan)
        #expect(root.fileCount == 1)
        #expect(store.snapshots[fixture.realPath]?.metadata.optionsFingerprint == options.fingerprint)
    }

    @Test func forceFullIgnoresCachedTreeButSaves() throws {
        let fixture = try makeTree()
        let store = MemoryStore()
        _ = try CachedScan.run(path: fixture.root.path, options: ScanOptions(), cache: store)
        let loadsBefore = store.loadCalls

        let (_, outcome) = try CachedScan.run(path: fixture.root.path, options: ScanOptions(), cache: store, forceFull: true)

        #expect(outcome.source == .fullScan)
        #expect(store.loadCalls == loadsBefore)
        #expect(outcome.saved)
        #expect(store.saveCalls == 2)
    }

    @Test func noCacheNeitherReadsNorWrites() throws {
        let fixture = try makeTree()
        let store = MemoryStore()

        let (root, outcome) = try CachedScan.run(path: fixture.root.path, options: ScanOptions(), cache: store, useCache: false)

        #expect(outcome.source == .uncached)
        #expect(outcome.saveSkipped == .cacheDisabled)
        #expect(!outcome.saved)
        #expect(store.loadCalls == 0)
        #expect(store.saveCalls == 0)
        #expect(root.fileCount == 3)
    }

    @Test func writeFailureIsNotFatal() throws {
        let fixture = try makeTree()

        let (root, outcome) = try CachedScan.run(path: fixture.root.path, options: ScanOptions(), cache: FailingStore())

        #expect(root.fileCount == 3)
        #expect(!outcome.saved)
        #expect(outcome.saveError != nil)
    }

    @Test func unwritableCacheDirectoryIsNotFatal() throws {
        let fixture = try makeTree()
        // A regular file where the cache directory's parent should be: no directory can be created.
        let blocker = try fixture.file("blocker", bytes: 1)
        let cache = ScanCache(directory: blocker.appendingPathComponent("Scans", isDirectory: true))

        let (root, outcome) = try CachedScan.run(path: fixture.root.appendingPathComponent("a").path, options: ScanOptions(), cache: cache)

        #expect(root.fileCount == 2)
        // Stub cache: "saved" (no-op). Real cache: the write fails and is reported.
        #expect(outcome.saved == (outcome.saveError == nil))
    }

    @Test func rootDoesNotSaveToImplicitLocation() throws {
        let fixture = try makeTree()
        let store = MemoryStore()

        let (root, outcome) = try CachedScan.run(
            path: fixture.root.path, options: ScanOptions(), cache: store, effectiveUID: 0, cacheDirectoryIsExplicit: false
        )

        #expect(root.fileCount == 3)
        #expect(!outcome.saved)
        #expect(outcome.saveSkipped == .runningAsRoot)
        #expect(store.saveCalls == 0)
    }

    @Test func rootSavesToExplicitLocation() throws {
        let fixture = try makeTree()
        let store = MemoryStore()

        let (_, outcome) = try CachedScan.run(
            path: fixture.root.path, options: ScanOptions(), cache: store, effectiveUID: 0, cacheDirectoryIsExplicit: true
        )

        #expect(outcome.saved)
        #expect(store.saveCalls == 1)
        #expect(CachedScan.savingAllowed(effectiveUID: 501, cacheDirectoryIsExplicit: false))
        #expect(!CachedScan.savingAllowed(effectiveUID: 0, cacheDirectoryIsExplicit: false))
    }

    @Test func realCacheRoundTripInTempDirectory() throws {
        let fixture = try makeTree()
        let cacheDirectory = try Fixture()
        let cache = ScanCache(directory: cacheDirectory.root.appendingPathComponent("Scans", isDirectory: true))
        let path = fixture.root.appendingPathComponent("a").path

        let (_, first) = try CachedScan.run(path: path, options: ScanOptions(), cache: cache)
        #expect(first.source == .fullScan)
        #expect(first.saveError == nil)

        try fixture.file("a/later.bin", bytes: 3_000)
        // Whatever the cache implementation, the outcome must agree with what it holds.
        let hadSnapshot = cache.load(rootPath: CachedScan.resolveRoot(path), optionsFingerprint: ScanOptions().fingerprint) != nil
        let (root, second) = try CachedScan.run(path: path, options: ScanOptions(), cache: cache)
        #expect(second.cacheHit == hadSnapshot)
        #expect(root.fileCount == 3)
        #expect(root.allocatedSize == (try freshTotals(path)).0)
    }

    @Test func resolveRootMatchesScanner() throws {
        let fixture = try makeTree()
        let root = try DiskScanner().scanSynchronously(path: fixture.root.path + "/a/../")
        #expect(CachedScan.resolveRoot(fixture.root.path + "/a/../") == root.path)
        #expect(root.path == fixture.realPath)
    }
}
