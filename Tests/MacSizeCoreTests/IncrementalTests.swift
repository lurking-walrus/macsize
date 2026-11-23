import Darwin
import Foundation
import Testing
@testable import MacSizeCore

// MARK: - Helpers

/// Recursively compares two trees by name, kind, sizes, counts and flags (children
/// matched by name, so sort order doesn't matter).
func expectSameTree(_ a: FileNode, _ b: FileNode, path: String = "",
                    sourceLocation: SourceLocation = #_sourceLocation) {
    let here = path.isEmpty ? "/" : path
    #expect(a.kind == b.kind, "kind at \(here)", sourceLocation: sourceLocation)
    #expect(a.allocatedSize == b.allocatedSize, "allocatedSize at \(here)", sourceLocation: sourceLocation)
    #expect(a.logicalSize == b.logicalSize, "logicalSize at \(here)", sourceLocation: sourceLocation)
    #expect(a.fileCount == b.fileCount, "fileCount at \(here)", sourceLocation: sourceLocation)
    #expect(a.directoryCount == b.directoryCount, "directoryCount at \(here)", sourceLocation: sourceLocation)
    #expect(a.isExcluded == b.isExcluded, "isExcluded at \(here)", sourceLocation: sourceLocation)
    #expect(a.errorCode == b.errorCode, "errorCode at \(here)", sourceLocation: sourceLocation)
    #expect(a.cloudOnlySize == b.cloudOnlySize && a.cloudOnlyCount == b.cloudOnlyCount,
            "cloud totals at \(here)", sourceLocation: sourceLocation)
    let left = a.children.map(\.name).sorted()
    let right = b.children.map(\.name).sorted()
    #expect(left == right, "children of \(here)", sourceLocation: sourceLocation)
    guard left == right else { return }
    let byName = Dictionary(uniqueKeysWithValues: b.children.map { ($0.name, $0) })
    for child in a.children {
        expectSameTree(child, byName[child.name]!, path: path + "/" + child.name, sourceLocation: sourceLocation)
    }
}

/// Every directory's totals equal the sum of its children's, parent links are
/// consistent, and children are sorted by `metric`.
func expectConsistentAggregates(_ root: FileNode, metric: SizeMetric,
                                sourceLocation: SourceLocation = #_sourceLocation) {
    var stack = [root]
    while let node = stack.popLast() {
        guard node.kind == .directory else { continue }
        let children = node.children
        #expect(node.allocatedSize == children.reduce(0) { $0 + $1.allocatedSize }, "\(node.path)", sourceLocation: sourceLocation)
        #expect(node.logicalSize == children.reduce(0) { $0 + $1.logicalSize }, "\(node.path)", sourceLocation: sourceLocation)
        #expect(node.fileCount == children.reduce(0) { $0 + $1.fileCount }, "\(node.path)", sourceLocation: sourceLocation)
        #expect(node.directoryCount == children.reduce(0) { $0 + ($1.kind == .directory ? 1 + $1.directoryCount : 0) },
                "\(node.path)", sourceLocation: sourceLocation)
        #expect(node.cloudOnlySize == children.reduce(0) { $0 + $1.cloudOnlySize }, "\(node.path)", sourceLocation: sourceLocation)
        #expect(node.cloudOnlyCount == children.reduce(0) { $0 + $1.cloudOnlyCount } + (node.isCloudOnly ? 1 : 0),
                "\(node.path)", sourceLocation: sourceLocation)
        #expect(node.modificationTime >= (children.map(\.modificationTime).max() ?? 0), sourceLocation: sourceLocation)
        #expect(zip(children, children.dropFirst()).allSatisfy { $0.size(metric) >= $1.size(metric) },
                "sorted \(node.path)", sourceLocation: sourceLocation)
        for child in children {
            #expect(child.parent === node, "parent of \(child.name)", sourceLocation: sourceLocation)
            stack.append(child)
        }
    }
}

/// Waits until FSEvents has assigned IDs to everything written so far, and returns an
/// event ID at or after all of it. It writes a marker in a scratch directory *outside*
/// any fixture and replays history until that marker shows up; since fseventsd numbers
/// events in order, every earlier write then has a smaller ID.
func settledEventID(timeout: TimeInterval = 10) throws -> UInt64 {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("macsize-settle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let resolved = DiskScanner.resolveRoot(scratch.path)
    let before = ChangeJournal.currentEventID()
    try Data([1]).write(to: scratch.appendingPathComponent("marker"))

    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let changes = ChangeJournal.changes(since: before, under: resolved, expectedVolumeUUID: nil, timeout: 2)
        if changes.directories.contains(resolved) { return changes.latestEventID }
        usleep(20_000)
    }
    throw SettleTimeout()
}

struct SettleTimeout: Error {}

/// Path of `relative` in a fully resolved fixture root.
func resolvedPath(_ fx: Fixture, _ relative: String = "") -> String {
    relative.isEmpty ? fx.realPath : fx.realPath + "/" + relative
}

// MARK: - End-to-end with real FSEvents

@Suite struct IncrementalRefreshTests {
    @Test func refreshFromFSEventsMatchesFullScanAndReusesUntouchedSubtrees() async throws {
        let fx = try Fixture()
        try fx.file("a.txt", bytes: 1000)
        try fx.file("mod.txt", bytes: 100)
        try fx.file("grow.bin", bytes: 10)
        try fx.file("del.txt", bytes: 50)
        try fx.file("keep/k1.bin", bytes: 5000)
        try fx.file("keep/sub/k2.txt", bytes: 300)
        try fx.file("gone/g1.txt", bytes: 100)
        try fx.file("gone/inner/g2.txt", bytes: 200)
        try fx.file("ren/r1.txt", bytes: 400)
        try fx.file("deep/l1/l2/l3/d.txt", bytes: 10)
        try fx.file("deep/l1/side/s.txt", bytes: 33)
        try fx.file("other/o.txt", bytes: 77)

        let start = try settledEventID()
        let old = try DiskScanner().scanSynchronously(path: fx.root.path)
        let oldKeep = try #require(old.child(named: "keep"))
        let oldKeepSub = try #require(oldKeep.child(named: "sub"))
        let oldOther = try #require(old.child(named: "other"))
        let oldDeep = try #require(old.child(named: "deep"))
        let oldSide = try #require(old.descendant(atPath: resolvedPath(fx, "deep/l1/side")))
        let oldL3 = try #require(old.descendant(atPath: resolvedPath(fx, "deep/l1/l2/l3")))
        let oldTotal = old.allocatedSize

        // Files: add, modify (same size), grow, delete.
        try fx.file("new.txt", bytes: 2500)
        try Data(repeating: 0x42, count: 100).write(to: fx.root.appendingPathComponent("mod.txt"))
        try fx.file("grow.bin", bytes: 100_000)
        try FileManager.default.removeItem(at: fx.root.appendingPathComponent("del.txt"))
        // Directories: add (with nested content), delete, rename.
        try fx.file("newdir/x.bin", bytes: 4096)
        try fx.file("newdir/y/z.bin", bytes: 9000)
        try FileManager.default.removeItem(at: fx.root.appendingPathComponent("gone"))
        try FileManager.default.moveItem(at: fx.root.appendingPathComponent("ren"),
                                         to: fx.root.appendingPathComponent("ren2"))
        // Deep nested change.
        try fx.file("deep/l1/l2/l3/e.bin", bytes: 20_000)

        _ = try settledEventID()
        let changes = ChangeJournal.changes(
            since: start, under: fx.root.path,  // unresolved /var/... on purpose
            expectedVolumeUUID: ChangeJournal.volumeUUID(forPath: fx.root.path))
        #expect(!changes.requiresFullRescan)
        #expect(changes.directories.contains(resolvedPath(fx)))
        #expect(changes.directories.contains(resolvedPath(fx, "deep/l1/l2/l3")))
        #expect(changes.latestEventID >= start)

        let result = try await IncrementalScanner().computeRefresh(for: old, changes: changes)
        #expect(!result.didFullRescan)
        #expect(result.newRoot == nil)
        // The old tree is untouched until apply.
        #expect(old.allocatedSize == oldTotal)
        #expect(old.child(named: "new.txt") == nil)

        // Only the root and l3 are re-listed; gone/newdir map to the root.
        #expect(Set(result.updates.map(\.path)) == [resolvedPath(fx), resolvedPath(fx, "deep/l1/l2/l3")])
        #expect(result.updates.first?.path == resolvedPath(fx, "deep/l1/l2/l3"), "deepest first")
        // Root listing + l3 listing + newdir + newdir/y + ren2.
        #expect(result.directoriesRescanned == 5)

        let refreshed = old.apply(result)
        #expect(refreshed === old)

        let fresh = try DiskScanner().scanSynchronously(path: fx.root.path)
        expectSameTree(refreshed, fresh)
        expectConsistentAggregates(refreshed, metric: .allocated)

        // Untouched subtrees are the very same objects.
        #expect(refreshed.child(named: "keep") === oldKeep)
        #expect(oldKeep.child(named: "sub") === oldKeepSub)
        #expect(refreshed.child(named: "other") === oldOther)
        #expect(refreshed.child(named: "deep") === oldDeep)
        #expect(refreshed.descendant(atPath: resolvedPath(fx, "deep/l1/side")) === oldSide)
        #expect(refreshed.descendant(atPath: resolvedPath(fx, "deep/l1/l2/l3")) === oldL3)
        #expect(oldL3.child(named: "e.bin") != nil)
        #expect(refreshed.child(named: "gone") == nil)
        #expect(refreshed.child(named: "ren") == nil)
        #expect(refreshed.child(named: "ren2")?.child(named: "r1.txt") != nil)
    }

    @Test func noChangesSinceEventIsEmpty() async throws {
        let fx = try Fixture()
        try fx.file("a/b.txt", bytes: 10)
        let start = try settledEventID()
        let old = try DiskScanner().scanSynchronously(path: fx.root.path)
        _ = try settledEventID()

        let changes = ChangeJournal.changes(since: start, under: fx.root.path,
                                            expectedVolumeUUID: ChangeJournal.volumeUUID(forPath: fx.root.path))
        #expect(changes.isEmpty)
        let result = try await IncrementalScanner().computeRefresh(for: old, changes: changes)
        #expect(result.isEmpty)
        #expect(!result.didFullRescan)
        #expect(old.apply(result) === old)
    }

    @Test func requiresFullRescanForUntrustworthyHistory() throws {
        let fx = try Fixture()
        let uuid = ChangeJournal.volumeUUID(forPath: fx.root.path)
        #expect(uuid != nil)
        let current = ChangeJournal.currentEventID()

        let zero = ChangeJournal.changes(since: 0, under: fx.root.path, expectedVolumeUUID: uuid)
        #expect(zero.requiresFullRescan)
        #expect(zero.latestEventID >= current)

        let bogus = ChangeJournal.changes(since: current, under: fx.root.path,
                                          expectedVolumeUUID: "00000000-0000-0000-0000-000000000000")
        #expect(bogus.requiresFullRescan)

        let future = ChangeJournal.changes(since: current + 1_000_000_000, under: fx.root.path, expectedVolumeUUID: uuid)
        #expect(future.requiresFullRescan)

        let fine = ChangeJournal.changes(since: current, under: fx.root.path, expectedVolumeUUID: uuid)
        #expect(!fine.requiresFullRescan)
    }

    @Test func fullRescanChangeSetReturnsNewRoot() async throws {
        let fx = try Fixture()
        try fx.file("a.txt", bytes: 10)
        let old = try DiskScanner().scanSynchronously(path: fx.root.path)
        try fx.file("b.txt", bytes: 20)

        let result = try await IncrementalScanner().computeRefresh(for: old, changes: .fullRescan(latestEventID: 42))
        #expect(result.didFullRescan)
        #expect(result.eventID == 42)
        let root = try #require(result.newRoot)
        #expect(old.apply(result) === root)
        #expect(old.child(named: "b.txt") == nil)
        expectSameTree(root, try DiskScanner().scanSynchronously(path: fx.root.path))
    }
}

// MARK: - Deterministic refreshes (hand-built change sets)

@Suite struct IncrementalApplyTests {
    private func makeTree(_ fx: Fixture) throws {
        try fx.file("top.txt", bytes: 3000)
        try fx.file("keep/k1.bin", bytes: 5000)
        try fx.file("keep/sub/k2.txt", bytes: 300)
        try fx.file("keep/sub/sub2/k3.txt", bytes: 30)
        try fx.file("other/o.txt", bytes: 77)
        try fx.file("other/nested/o2.txt", bytes: 7)
    }

    @Test func nestedParentAndChildUpdates() throws {
        let fx = try Fixture()
        try makeTree(fx)
        let old = try DiskScanner().scanSynchronously(path: fx.root.path)
        let keep = try #require(old.child(named: "keep"))
        let sub = try #require(keep.child(named: "sub"))
        let sub2 = try #require(sub.child(named: "sub2"))

        try fx.file("top2.txt", bytes: 12_345)
        try FileManager.default.removeItem(at: fx.root.appendingPathComponent("keep/sub/k2.txt"))
        try fx.file("keep/sub/big.bin", bytes: 200_000)

        let changes = ChangeSet(directories: [resolvedPath(fx), resolvedPath(fx, "keep/sub")], latestEventID: 7)
        let result = try IncrementalScanner().computeRefreshSynchronously(for: old, changes: changes)
        #expect(result.updates.map(\.path) == [resolvedPath(fx, "keep/sub"), resolvedPath(fx)])
        #expect(result.directoriesRescanned == 2)
        #expect(result.eventID == 7)

        old.apply(result, metric: .logical)
        expectSameTree(old, try DiskScanner().scanSynchronously(path: fx.root.path))
        expectConsistentAggregates(old, metric: .logical)
        #expect(old.child(named: "keep") === keep)
        #expect(keep.child(named: "sub") === sub)
        #expect(sub.child(named: "sub2") === sub2)
        #expect(sub.child(named: "k2.txt") == nil)
    }

    @Test func recursiveDirectoryIsRescannedFromScratch() throws {
        let fx = try Fixture()
        try makeTree(fx)
        let old = try DiskScanner().scanSynchronously(path: fx.root.path)
        let keep = try #require(old.child(named: "keep"))
        let oldSub = try #require(keep.child(named: "sub"))
        let other = try #require(old.child(named: "other"))

        try fx.file("keep/sub/sub2/deeper/new.bin", bytes: 64_000)
        try fx.file("other/nested/also.txt", bytes: 5)  // covered by the recursive root below? no: sibling

        let changes = ChangeSet(
            directories: [resolvedPath(fx, "keep/sub/sub2"), resolvedPath(fx, "other/nested")],
            recursiveDirectories: [resolvedPath(fx, "keep")],
            latestEventID: 9)
        let result = try IncrementalScanner().computeRefreshSynchronously(for: old, changes: changes)
        // keep/sub/sub2 is covered by the recursive keep.
        #expect(Set(result.updates.map(\.path)) == [resolvedPath(fx, "keep"), resolvedPath(fx, "other/nested")])
        #expect(result.updates.first { $0.isRecursive }?.path == resolvedPath(fx, "keep"))

        old.apply(result)
        expectSameTree(old, try DiskScanner().scanSynchronously(path: fx.root.path))
        expectConsistentAggregates(old, metric: .allocated)
        #expect(old.child(named: "keep") === keep, "the directory node itself is kept")
        #expect(keep.child(named: "sub") !== oldSub, "its subtree is new")
        #expect(old.child(named: "other") === other)
    }

    @Test func recursiveRootMeansFullRescan() throws {
        let fx = try Fixture()
        try makeTree(fx)
        let old = try DiskScanner().scanSynchronously(path: fx.root.path)
        let result = try IncrementalScanner().computeRefreshSynchronously(
            for: old, changes: ChangeSet(recursiveDirectories: [resolvedPath(fx)], latestEventID: 1))
        #expect(result.didFullRescan)
        #expect(result.newRoot != nil)
    }

    @Test func ignoresOutsideAndExcludedPathsAndHandlesVanishedDirectories() throws {
        let fx = try Fixture()
        try makeTree(fx)
        try fx.file("skip/s.txt", bytes: 10)
        let options = ScanOptions(excludedPaths: [fx.root.appendingPathComponent("skip").path])
        let old = try DiskScanner(options: options).scanSynchronously(path: fx.root.path)
        let keep = try #require(old.child(named: "keep"))

        // Outside the root and inside an excluded directory: nothing to do.
        let ignored = try IncrementalScanner(options: options).computeRefreshSynchronously(
            for: old,
            changes: ChangeSet(directories: ["/definitely/not/here", fx.realPath + "-sibling",
                                             resolvedPath(fx, "skip")], latestEventID: 3))
        #expect(ignored.isEmpty)
        #expect(!ignored.didFullRescan)

        // A deleted directory that was in the tree, and a brand-new one that wasn't,
        // both re-list their nearest existing ancestor.
        try FileManager.default.removeItem(at: fx.root.appendingPathComponent("keep/sub"))
        try fx.file("keep/fresh/f.txt", bytes: 1234)
        let result = try IncrementalScanner(options: options).computeRefreshSynchronously(
            for: old,
            changes: ChangeSet(directories: [resolvedPath(fx, "keep/sub/sub2"), resolvedPath(fx, "keep/fresh") + "/"],
                               latestEventID: 4))
        #expect(result.updates.map(\.path) == [resolvedPath(fx, "keep")])

        old.apply(result)
        expectSameTree(old, try DiskScanner(options: options).scanSynchronously(path: fx.root.path))
        expectConsistentAggregates(old, metric: .allocated)
        #expect(old.child(named: "keep") === keep)
        #expect(old.child(named: "skip")?.isExcluded == true)
    }

    @Test func applyKeepsCloudTotalsConsistent() throws {
        let fx = try Fixture()
        try makeTree(fx)
        let old = try DiskScanner().scanSynchronously(path: fx.root.path)
        // Simulate cloud placeholders in a reused subtree (a real one needs a File Provider).
        let other = try #require(old.child(named: "other"))
        let o = try #require(other.child(named: "o.txt"))
        let nested = try #require(other.child(named: "nested"))
        o.markCloudOnly()
        nested.isCloudOnly = true
        nested.cloudOnlyCount = 1 + nested.children.reduce(0) { $0 + $1.cloudOnlyCount }
        other.reaggregate(ownModificationTime: nil, metric: .allocated)
        old.reaggregate(ownModificationTime: nil, metric: .allocated)
        #expect(old.cloudOnlyCount == 2)
        #expect(old.cloudOnlySize == 77)

        try fx.file("keep/more.bin", bytes: 8192)
        let result = try IncrementalScanner().computeRefreshSynchronously(
            for: old, changes: ChangeSet(directories: [resolvedPath(fx, "keep"), resolvedPath(fx)], latestEventID: 5))
        old.apply(result)
        expectConsistentAggregates(old, metric: .allocated)
        #expect(old.child(named: "other") === other)
        #expect(old.cloudOnlyCount == 2)
        #expect(old.cloudOnlySize == 77)
    }

    @Test func cancelledRefreshThrows() async throws {
        let fx = try Fixture()
        try makeTree(fx)
        let old = try DiskScanner().scanSynchronously(path: fx.root.path)
        let scanner = IncrementalScanner()
        scanner.cancel()
        await #expect(throws: ScanError.cancelled) {
            try await scanner.computeRefresh(for: old, changes: ChangeSet(directories: [fx.realPath], latestEventID: 1))
        }
    }
}

// MARK: - Accumulator rules

@Suite struct ChangeAccumulatorTests {
    private func event(_ path: String, _ flags: Int = 0, id: UInt64 = 10) -> FSEvent {
        FSEvent(path: path, flags: UInt32(flags), id: id)
    }

    @Test func normalizesAndCoalesces() {
        var acc = ChangeAccumulator(rootPath: "/r")
        acc.add(event("/r/a/", id: 5))
        acc.add(event("/r/b/c/"))
        acc.add(event("/r/b", kFSEventStreamEventFlagMustScanSubDirs, id: 12))
        acc.add(event("/r/b/c/d", kFSEventStreamEventFlagMustScanSubDirs))
        acc.add(event("/elsewhere/x"))
        acc.add(event("/r-sibling"))
        acc.add(event("/", kFSEventStreamEventFlagHistoryDone, id: 99))
        #expect(acc.historyDone)
        let set = acc.makeChangeSet(fallbackEventID: 1)
        #expect(set.directories == ["/r/a"])
        #expect(set.recursiveDirectories == ["/r/b"])
        #expect(!set.requiresFullRescan)
        #expect(set.latestEventID == 12)
        #expect(acc.makeChangeSet(fallbackEventID: 50).latestEventID == 50)
    }

    @Test func rootLevelFlagsForceFullRescan() {
        let full: [(String, Int)] = [
            ("/r", kFSEventStreamEventFlagMustScanSubDirs),
            ("/", kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped),
            ("/r", kFSEventStreamEventFlagKernelDropped),
            ("/r", kFSEventStreamEventFlagRootChanged),
            ("/r/x", kFSEventStreamEventFlagEventIdsWrapped),
        ]
        for (path, flags) in full {
            var acc = ChangeAccumulator(rootPath: "/r")
            acc.add(event(path, flags))
            #expect(acc.makeChangeSet(fallbackEventID: 1).requiresFullRescan, "\(path) \(flags)")
        }
        var below = ChangeAccumulator(rootPath: "/r")
        below.add(event("/r/x", kFSEventStreamEventFlagUserDropped))
        let set = below.makeChangeSet(fallbackEventID: 1)
        #expect(!set.requiresFullRescan)
        #expect(set.recursiveDirectories == ["/r/x"])
    }

    @Test func resolvesSymlinkedParents() {
        let acc = ChangeAccumulator(rootPath: "/private/tmp/r")
        #expect(acc.canonicalize("/tmp/r/x/") == "/private/tmp/r/x")
        #expect(acc.canonicalize("/private/tmp/r/") == "/private/tmp/r")
    }
}

// MARK: - Live watcher

@Suite struct ChangeWatcherTests {
    final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var sets: [ChangeSet] = []
        func add(_ set: ChangeSet) { lock.lock(); sets.append(set); lock.unlock() }
        var all: [ChangeSet] { lock.lock(); defer { lock.unlock() }; return sets }
    }

    @Test func deliversChangeAfterFileWrite() throws {
        let fx = try Fixture()
        try fx.directory("watched")
        _ = try settledEventID()

        let inbox = Inbox()
        let watcher = ChangeWatcher(rootPath: fx.root.path, latency: 0.1) { inbox.add($0) }
        watcher.start()
        watcher.start()  // idempotent
        #expect(watcher.isRunning)
        // Make sure the stream is live before writing.
        usleep(200_000)
        try fx.file("watched/hello.txt", bytes: 10)

        let target = resolvedPath(fx, "watched")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && !inbox.all.contains(where: { $0.directories.contains(target) }) {
            usleep(20_000)
        }
        #expect(inbox.all.contains { $0.directories.contains(target) })
        #expect(inbox.all.allSatisfy { !$0.requiresFullRescan && $0.latestEventID > 0 })

        watcher.stop()
        watcher.stop()  // idempotent
        #expect(!watcher.isRunning)
        let count = inbox.all.count
        try fx.file("watched/after.txt", bytes: 10)
        usleep(400_000)
        #expect(inbox.all.count == count, "no delivery after stop")
    }

    @Test func deinitStopsTheStreamAndReleasesTheWatcher() throws {
        let fx = try Fixture()
        weak var weakWatcher: ChangeWatcher?
        do {
            let watcher = ChangeWatcher(rootPath: fx.root.path, latency: 0.1) { _ in }
            watcher.start()
            weakWatcher = watcher
        }
        #expect(weakWatcher == nil)
    }
}

// MARK: - Benchmark (opt-in: MACSIZE_BENCH=1 swift test --filter IncrementalBenchmark)

@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACSIZE_BENCH"] != nil), .serialized)
struct IncrementalBenchmark {
    private func time<T>(_ body: () throws -> T) rethrows -> (T, Double) {
        let start = Date()
        let value = try body()
        return (value, Date().timeIntervalSince(start) * 1000)
    }

    private func measure(path: String, label: String, change: (() throws -> Void)?) throws {
        let start = try settledEventID()
        let (old, full) = try time { try DiskScanner().scanSynchronously(path: path) }
        try change?()
        _ = try settledEventID()
        let uuid = ChangeJournal.volumeUUID(forPath: path)
        let (changes, journal) = time { ChangeJournal.changes(since: start, under: path, expectedVolumeUUID: uuid) }
        let (result, compute) = try time { try IncrementalScanner().computeRefreshSynchronously(for: old, changes: changes) }
        let (_, apply) = time { old.apply(result) }
        print(String(format: "BENCH %@ [%@]: %d files, %d dirs | full scan %.1f ms | incremental %.1f ms (journal %.1f + compute %.1f + apply %.2f), %d dirs re-read",
                     path, label, old.fileCount, old.directoryCount, full, journal + compute + apply,
                     journal, compute, apply, result.directoriesRescanned))
    }

    @Test func syntheticTree() throws {
        let fx = try Fixture()
        // 40 x 50 directories x 10 files = 20,000 files in 2,040 directories.
        for a in 0..<40 {
            for b in 0..<50 {
                let dir = fx.root.appendingPathComponent("d\(a)/e\(b)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for c in 0..<10 {
                    try Data(count: 100 * (c + 1)).write(to: dir.appendingPathComponent("f\(c).dat"))
                }
            }
        }
        try measure(path: fx.realPath, label: "no change", change: nil)
        try measure(path: fx.realPath, label: "one change") { try fx.file("d17/e23/new.bin", bytes: 50_000) }
    }

    @Test func usrShareNoChange() throws {
        try measure(path: "/usr/share", label: "no change", change: nil)
    }
}
