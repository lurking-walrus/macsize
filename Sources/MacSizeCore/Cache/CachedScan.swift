import Darwin
import Foundation

/// The parts of `ScanCache` that `CachedScan` needs. `ScanCache` is the real store; tests
/// inject fakes (e.g. one whose `save` always throws).
public protocol ScanSnapshotStore: AnyObject {
    func load(rootPath: String, optionsFingerprint: String) -> ScanSnapshot?
    func save(_ snapshot: ScanSnapshot) throws
}

extension ScanCache: ScanSnapshotStore {}

/// A scan that reuses the on-disk cache when it can:
///
/// - **hit** (snapshot for the resolved root with a matching options fingerprint): ask
///   FSEvents what changed since the snapshot's event ID, re-list only those folders,
///   apply the result, then save the refreshed snapshot;
/// - **miss**: capture the current event ID *before* scanning, do a full scan, then save.
///
/// The returned tree always reflects the disk as it is now, never the cached state.
/// Saving is best effort: a failed write is reported in `Outcome.saveError`, never thrown.
///
/// `run` blocks the calling thread (it bridges `IncrementalScanner`'s async API with a
/// semaphore), so call it from a plain thread, not from inside Swift concurrency.
public enum CachedScan {
    public struct Outcome: Sendable, Equatable {
        public enum Source: Sendable, Equatable {
            /// Full scan without touching the cache (`useCache == false`).
            case uncached
            /// No usable snapshot (or `forceFull`): full scan.
            case fullScan
            /// Snapshot found and refreshed from the FSEvents history.
            case refreshed
        }

        public enum SaveSkipReason: Sendable, Equatable {
            /// Cache disabled for this run.
            case cacheDisabled
            /// Running as root with the default cache location; writing there would leave
            /// root-owned files in a user's cache.
            case runningAsRoot
        }

        public var source: Source
        /// When the reused snapshot was originally scanned (hits only).
        public var cachedScannedAt: Date?
        /// Folders re-listed by the incremental refresh (hits only).
        public var directoriesRescanned: Int = 0
        /// The refresh couldn't be incremental (history unavailable, volume changed,
        /// refresh failed…) and the whole tree was rescanned.
        public var didFullRescan: Bool = false
        /// Wall time for the scan or refresh, excluding the save.
        public var duration: TimeInterval = 0
        public var saved: Bool = false
        public var saveSkipped: SaveSkipReason?
        /// Why the save failed (permissions, disk full…). Never fatal.
        public var saveError: String?

        public var cacheHit: Bool { source == .refreshed }

        public init(source: Source) { self.source = source }
    }

    /// What `run` is doing, for progress display.
    public enum Phase: @unchecked Sendable {
        /// Refreshing a snapshot made at the given date.
        case refreshing(cachedAt: Date, progress: ScanProgress)
        /// Full scan.
        case scanning(progress: ScanProgress)
    }

    /// The path `DiskScanner` reports for `path` (absolute, `realpath`-resolved). Cache
    /// entries are keyed by this.
    public static func resolveRoot(_ path: String) -> String {
        DiskScanner.resolveRoot(path)
    }

    /// Whether this process may write to the cache. Root only writes to a location the
    /// user chose explicitly (`--cache-dir`), so `sudo macsize` never leaves root-owned
    /// files in the invoking user's cache.
    public static func savingAllowed(effectiveUID: uid_t = geteuid(), cacheDirectoryIsExplicit: Bool) -> Bool {
        effectiveUID != 0 || cacheDirectoryIsExplicit
    }

    /// - Parameters:
    ///   - useCache: false = don't read or write the cache.
    ///   - forceFull: ignore any cached tree, but still save the new one.
    ///   - effectiveUID / cacheDirectoryIsExplicit: see `savingAllowed`. Injectable for tests.
    ///   - journalTimeout: passed to `ChangeJournal.changes`.
    ///   - onPhase: called (on the calling thread) when a scan or refresh starts.
    public static func run(
        path: String,
        options: ScanOptions,
        cache: ScanSnapshotStore,
        useCache: Bool = true,
        forceFull: Bool = false,
        metric: SizeMetric = .allocated,
        effectiveUID: uid_t = geteuid(),
        cacheDirectoryIsExplicit: Bool = false,
        journalTimeout: TimeInterval = 10,
        onPhase: ((Phase) -> Void)? = nil
    ) throws -> (root: FileNode, outcome: Outcome) {
        guard useCache else {
            let start = Date()
            let root = try fullScan(path: path, options: options, onPhase: onPhase)
            var outcome = Outcome(source: .uncached)
            outcome.duration = Date().timeIntervalSince(start)
            outcome.saveSkipped = .cacheDisabled
            return (root, outcome)
        }

        let rootPath = resolveRoot(path)
        let fingerprint = options.fingerprint
        let start = Date()
        var root: FileNode
        var eventID: UInt64
        var outcome: Outcome

        if !forceFull, let snapshot = cache.load(rootPath: rootPath, optionsFingerprint: fingerprint) {
            outcome = Outcome(source: .refreshed)
            outcome.cachedScannedAt = snapshot.metadata.scannedAt
            let changes = ChangeJournal.changes(
                since: snapshot.metadata.eventID,
                under: rootPath,
                expectedVolumeUUID: snapshot.metadata.volumeUUID,
                timeout: journalTimeout
            )
            let scanner = IncrementalScanner(options: options)
            onPhase?(.refreshing(cachedAt: snapshot.metadata.scannedAt, progress: scanner.progress))
            let cachedRoot = snapshot.root
            do {
                let result = try blocking { try await scanner.computeRefresh(for: cachedRoot, changes: changes) }
                root = cachedRoot.apply(result, metric: metric)
                eventID = result.eventID
                outcome.directoriesRescanned = result.directoriesRescanned
                outcome.didFullRescan = result.didFullRescan
            } catch let error as ScanError where error == .cancelled {
                throw error
            } catch {
                // The refresh couldn't complete (e.g. the root changed under us). Fall back
                // to a full scan, which reports a real error if the path is gone.
                eventID = ChangeJournal.currentEventID()
                root = try fullScan(path: path, options: options, onPhase: onPhase)
                outcome.didFullRescan = true
            }
        } else {
            outcome = Outcome(source: .fullScan)
            // Captured before scanning so changes made during the scan are replayed next time.
            eventID = ChangeJournal.currentEventID()
            root = try fullScan(path: path, options: options, onPhase: onPhase)
        }
        outcome.duration = Date().timeIntervalSince(start)

        if savingAllowed(effectiveUID: effectiveUID, cacheDirectoryIsExplicit: cacheDirectoryIsExplicit) {
            let metadata = ScanSnapshotMetadata(root: root, options: options, eventID: eventID)
            do {
                try cache.save(ScanSnapshot(metadata: metadata, root: root))
                outcome.saved = true
            } catch {
                outcome.saveError = describe(error)
            }
        } else {
            outcome.saveSkipped = .runningAsRoot
        }
        return (root, outcome)
    }

    private static func fullScan(path: String, options: ScanOptions, onPhase: ((Phase) -> Void)?) throws -> FileNode {
        let scanner = DiskScanner(options: options)
        onPhase?(.scanning(progress: scanner.progress))
        return try scanner.scanSynchronously(path: path)
    }

    private static func describe(_ error: Error) -> String {
        if let cocoa = error as? CocoaError, let underlying = cocoa.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(underlying.code)))
        }
        return error.localizedDescription
    }

    /// Runs `body` on a detached task and blocks until it finishes.
    static func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let box = BlockingResult<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.result!.get()
    }
}

private final class BlockingResult<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}
