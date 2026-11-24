import AppKit
import Observation
import OSLog
import MacSizeCore

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MacSize", category: "scan")

/// Owns the displayed tree and everything that reads or mutates it.
///
/// Concurrency model: the tree is owned by the main actor. Background work that *reads*
/// it (snapshot saves, `IncrementalScanner.computeRefresh`, index builds) runs as one
/// serial "tree job" at a time (`activeJob`). Every mutation (`FileNode.apply`, trash's
/// `removeFromParent`, re-sorting) happens on the main actor while no job is reading:
/// `mutateTree` runs immediately when idle, otherwise cancels an in-flight refresh
/// (its changes are re-queued) or waits for an in-flight save, then runs before
/// anything else. `generation` invalidates work for a tree that's no longer shown.
@MainActor
@Observable
final class ScanModel {
    // MARK: Scan state
    private(set) var root: FileNode?
    private(set) var rootURL: URL?
    /// A full scan (or the cache lookup before it) is in progress.
    private(set) var isScanning = false
    /// The scan in progress is still looking for a saved scan.
    private(set) var isLoadingCache = false
    private(set) var progress = ScanProgress.Snapshot()
    private(set) var unreadableCount = 0
    var errorMessage: String?

    /// How current the displayed tree is; drives the status bar.
    enum Freshness: Equatable {
        /// Fresh full scan.
        case scanned(duration: TimeInterval)
        /// Loaded from the cache; not yet brought up to date.
        case cached(scannedAt: Date)
        /// Brought up to date by an incremental refresh (`folders` nil: it had to rescan everything).
        case updated(at: Date, folders: Int?, duration: TimeInterval)
    }
    private(set) var freshness: Freshness?
    /// An incremental refresh is pending or running.
    private(set) var isRefreshing = false
    /// Folders re-listed so far by the running refresh.
    private(set) var refreshFolders = 0

    // MARK: View state
    /// Directory shown in the treemap.
    var focus: FileNode?
    var selection = Set<FileNode.ID>()
    /// Folders expanded in the file list, by path. Kept here (not in the table) because
    /// refreshes replace nodes and rebuild the table; paths survive that.
    var expandedPaths = Set<String>()
    /// Bumped whenever the tree mutates so views that cache layout can refresh.
    private(set) var revision = 0
    var pendingTrash: [FileNode] = [] {
        didSet {
            // Refreshes are paused while the confirmation is open; resume them.
            if pendingTrash.isEmpty && !oldValue.isEmpty { pump() }
        }
    }

    // MARK: Settings (persisted per user via UserDefaults)
    var metric: SizeMetric = SizeMetric(rawValue: UserDefaults.standard.string(forKey: "metric") ?? "") ?? .allocated {
        didSet {
            UserDefaults.standard.set(metric.rawValue, forKey: "metric")
            let metric = self.metric
            mutateTree { [weak self] in
                guard let self else { return }
                self.root?.sortChildren(by: metric)
                self.revision += 1
            }
        }
    }
    var stayOnFileSystem: Bool = UserDefaults.standard.bool(forKey: "stayOnFileSystem") {
        didSet { UserDefaults.standard.set(stayOnFileSystem, forKey: "stayOnFileSystem") }
    }
    /// Load and save scan snapshots so reopening a folder is instant.
    var rememberScans: Bool = UserDefaults.standard.object(forKey: Keys.rememberScans) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(rememberScans, forKey: Keys.rememberScans)
            if rememberScans && root != nil {
                needsSave = true
                pump()
            }
        }
    }
    /// Watch the scanned folder and refresh results when files change.
    var liveUpdates: Bool = UserDefaults.standard.object(forKey: Keys.liveUpdates) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(liveUpdates, forKey: Keys.liveUpdates)
            if liveUpdates {
                startWatcherIfNeeded()
            } else {
                stopWatcher()
                liveChanges = nil
                firstLiveChangeAt = nil
                liveFlushTask?.cancel()
            }
        }
    }

    private enum Keys {
        static let rememberScans = "rememberScans"
        static let liveUpdates = "liveUpdates"
    }

    @ObservationIgnored let cache = ScanCache()
    @ObservationIgnored private let cacheDirectory = RootPath.resolve(ScanCache.defaultDirectory.path)

    @ObservationIgnored private var index: [ObjectIdentifier: FileNode] = [:]
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanner: DiskScanner?

    // MARK: Tree bookkeeping
    @ObservationIgnored private var generation = 0
    /// FSEvents ID the displayed tree is current as of, and the options it was built with.
    @ObservationIgnored private var treeEventID: UInt64?
    @ObservationIgnored private var treeOptions: ScanOptions?
    @ObservationIgnored private var treeScannedAt = Date()
    /// Root shown before a scan started, restored if the scan is cancelled or fails.
    @ObservationIgnored private var previousRootURL: URL?

    // MARK: Tree jobs
    private enum JobKind { case refresh, save }
    private struct RefreshRequest: Sendable {
        var changes: ChangeSet
        /// Show the result in the status bar / report errors (Rescan, reopen), vs. a quiet live update.
        var isExplicit: Bool

        func merged(with other: RefreshRequest) -> RefreshRequest {
            RefreshRequest(changes: changes.merged(with: other.changes), isExplicit: isExplicit || other.isExplicit)
        }
    }
    @ObservationIgnored private var activeJob: (kind: JobKind, task: Task<Void, Never>)?
    @ObservationIgnored private var refreshScanner: IncrementalScanner?
    @ObservationIgnored private var pendingMutations: [@MainActor () -> Void] = []
    @ObservationIgnored private var readyRefresh: RefreshRequest?
    @ObservationIgnored private var needsSave = false
    @ObservationIgnored private var journalsInFlight = 0

    // MARK: Live updates
    @ObservationIgnored private var watcher: ChangeWatcher?
    @ObservationIgnored private var liveChanges: ChangeSet?
    @ObservationIgnored private var firstLiveChangeAt: Date?
    @ObservationIgnored private var liveFlushTask: Task<Void, Never>?
    @ObservationIgnored private var nextLiveRefreshAllowed = Date.distantPast

    /// Live-update tuning: wait for a quiet period, but never longer than `maxWait`
    /// after the first change; and keep refreshes to a small duty cycle under churn.
    private static let debounce: TimeInterval = 1.5
    private static let maxWait: TimeInterval = 8
    private static let minLiveInterval: TimeInterval = 3
    private static let liveDutyFactor: Double = 4

    // MARK: - Scanning

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder or volume to analyze"
        if panel.runModal() == .OK, let url = panel.url {
            scan(url)
        }
    }

    /// Refresh incrementally when the displayed tree can be brought up to date,
    /// otherwise scan again (using the cache if there is one).
    func rescan() {
        guard let rootURL, !isScanning else { return }
        if let root, let eventID = treeEventID, let treeOptions,
           treeOptions.fingerprint == currentOptions.fingerprint,
           root.path == RootPath.resolve(rootURL.path) {
            replayJournal(since: eventID, volumeUUID: ChangeJournal.volumeUUID(forPath: root.path), isExplicit: true)
        } else {
            scan(rootURL)
        }
    }

    /// Scan from scratch, ignoring any cached snapshot.
    func fullRescan() {
        if let rootURL, !isScanning { scan(rootURL, useCache: false) }
    }

    var canRescan: Bool { rootURL != nil && !isScanning }

    /// Lets the app be launched as `MacSize /some/path` to scan immediately.
    func scanLaunchArgumentIfPresent() {
        guard root == nil, !isScanning else { return }
        let candidates = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        guard let path = candidates.first else { return }
        var isDirectory: ObjCBool = false
        let expanded = (path as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
            scan(URL(fileURLWithPath: expanded))
        }
    }

    private var currentOptions: ScanOptions { ScanOptions(stayOnFileSystem: stayOnFileSystem) }

    func scan(_ url: URL, useCache: Bool = true) {
        cancelScan(restore: false)
        tearDownTree()
        let options = currentOptions
        let resolvedPath = RootPath.resolve(url.path)
        let useCache = useCache && rememberScans
        // Same root again: try to keep the user's place.
        let keep = root?.path == resolvedPath ? viewPlace() : nil
        if keep == nil { expandedPaths = [] }
        let cache = self.cache
        let metric = self.metric
        let gen = generation

        previousRootURL = rootURL
        rootURL = url
        isScanning = true
        isLoadingCache = useCache
        errorMessage = nil
        progress = .init()

        scanTask = Task { [weak self] in
            if useCache {
                let started = Date()
                let cached: (ScanSnapshot, TreeIndex)? = await {
                    let snapshot = await Task.detached(priority: .userInitiated) {
                        cache.load(rootPath: resolvedPath, optionsFingerprint: options.fingerprint)
                    }.value
                    guard let snapshot else { return nil }
                    // Cached trees may have been sorted by another metric.
                    return (snapshot, await TreeIndex.build(snapshot.root, sortBy: metric))
                }()
                guard let self, !Task.isCancelled, gen == self.generation else { return }
                if let (snapshot, index) = cached {
                    log.info("Cache hit for \(resolvedPath, privacy: .public) in \(Date().timeIntervalSince(started), format: .fixed(precision: 3)) s")
                    self.installCached(snapshot, index: index, options: options, keep: keep)
                    return
                }
                log.info("Cache miss for \(resolvedPath, privacy: .public)")
                self.isLoadingCache = false
            }
            await self?.runFullScan(path: url.path, options: options, generation: gen, keep: keep)
        }
    }

    private func runFullScan(path: String, options: ScanOptions, generation gen: Int, keep: ViewPlace?) async {
        let scanner = DiskScanner(options: options)
        self.scanner = scanner
        let metric = self.metric
        // Captured *before* scanning so changes made during the scan get replayed.
        let eventID = ChangeJournal.currentEventID()
        let started = Date()
        let poller = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.progress = scanner.progress.snapshot()
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
        defer { poller.cancel() }

        do {
            let root = try await scanner.scan(path: path)
            let index = await TreeIndex.build(root, sortBy: metric == .allocated ? nil : metric)
            guard !Task.isCancelled, gen == generation else { return }
            install(root, index: index, keep: keep)
            progress = scanner.progress.snapshot()
            treeEventID = eventID
            treeOptions = options
            treeScannedAt = started
            freshness = .scanned(duration: Date().timeIntervalSince(started))
            needsSave = true
            startWatcherIfNeeded()
            pump()
        } catch {
            guard gen == generation else { return }
            isScanning = false
            isLoadingCache = false
            if (error as? ScanError) != .cancelled {
                errorMessage = error.localizedDescription
            }
            resumePreviousTree()
        }
    }

    func cancelScan() {
        cancelScan(restore: true)
    }

    private func cancelScan(restore: Bool) {
        let wasScanning = isScanning
        scanner?.cancel()
        scanTask?.cancel()
        scanTask = nil
        scanner = nil
        isScanning = false
        isLoadingCache = false
        if restore && wasScanning { resumePreviousTree() }
    }

    /// After a cancelled or failed scan the previous tree is shown again; resume its services.
    private func resumePreviousTree() {
        guard root != nil else { return }
        rootURL = previousRootURL ?? rootURL
        startWatcherIfNeeded()
        pump()
    }

    private func installCached(_ snapshot: ScanSnapshot, index: TreeIndex, options: ScanOptions, keep: ViewPlace?) {
        install(snapshot.root, index: index, keep: keep)
        let metadata = snapshot.metadata
        treeEventID = metadata.eventID
        treeOptions = options
        treeScannedAt = metadata.scannedAt
        freshness = .cached(scannedAt: metadata.scannedAt)
        // The watcher starts once this catch-up refresh is done.
        replayJournal(since: metadata.eventID, volumeUUID: metadata.volumeUUID, isExplicit: true)
    }

    private func install(_ root: FileNode, index: TreeIndex, keep: ViewPlace?) {
        self.root = root
        self.index = index.nodes
        unreadableCount = index.unreadable
        focus = root
        selection = []
        if let keep { restore(keep, in: root) }
        isScanning = false
        isLoadingCache = false
        revision += 1
    }

    /// Stops everything tied to the displayed tree before switching roots.
    private func tearDownTree() {
        generation += 1
        stopWatcher()
        liveFlushTask?.cancel()
        liveFlushTask = nil
        liveChanges = nil
        firstLiveChangeAt = nil
        nextLiveRefreshAllowed = .distantPast
        if let job = activeJob, job.kind == .refresh {
            refreshScanner?.cancel()
            job.task.cancel()
        }
        // An in-flight save keeps reading the old tree in the background; nothing
        // mutates that tree any more, so it's left to finish.
        activeJob = nil
        refreshScanner = nil
        pendingMutations = []
        readyRefresh = nil
        needsSave = false
        journalsInFlight = 0
        updateRefreshIndicator()
    }

    // MARK: - Focus & selection preservation

    private struct ViewPlace {
        var focusPath: String?
        var selectedPaths: [String]
    }

    private func viewPlace() -> ViewPlace {
        ViewPlace(focusPath: focus?.path, selectedPaths: selectedNodes.map(\.path))
    }

    /// Re-find focus and selection by path; a vanished focus falls back to its nearest
    /// surviving ancestor, vanished selected items are dropped.
    private func restore(_ place: ViewPlace, in root: FileNode) {
        focus = place.focusPath.flatMap { root.deepestNode(atPath: $0) } ?? root
        if focus?.isDirectory == false { focus = focus?.parent ?? root }
        selection = Set(place.selectedPaths.prefix(1000).compactMap { root.node(atPath: $0)?.id })
    }

    // MARK: - Tree job scheduling

    /// Run `body` (which mutates the tree) on the main actor as soon as no background
    /// job is reading the tree. A running refresh is cancelled and re-queued.
    private func mutateTree(_ body: @escaping @MainActor () -> Void) {
        if let job = activeJob {
            if job.kind == .refresh {
                refreshScanner?.cancel()
                job.task.cancel()
            }
            pendingMutations.append(body)
        } else {
            body()
            pump()
        }
    }

    /// Refreshes wait while the trash confirmation is open or a scan is running.
    private var refreshesPaused: Bool { !pendingTrash.isEmpty || isScanning }

    /// Start the next tree job if none is running: mutations first, then refreshes, then saves.
    private func pump() {
        defer { updateRefreshIndicator() }
        guard activeJob == nil else { return }
        guard root != nil else {
            pendingMutations = []
            return
        }
        if !pendingMutations.isEmpty {
            let mutations = pendingMutations
            pendingMutations = []
            for mutation in mutations { mutation() }
        }
        if let request = readyRefresh, !refreshesPaused {
            readyRefresh = nil
            startRefresh(request)
        } else if needsSave {
            startSave()
        }
    }

    private func jobFinished(generation gen: Int) {
        guard gen == generation else { return }
        activeJob = nil
        refreshScanner = nil
        pump()
    }

    private func updateRefreshIndicator() {
        let refreshing = journalsInFlight > 0 || activeJob?.kind == .refresh || readyRefresh != nil
        if refreshing != isRefreshing { isRefreshing = refreshing }
        if !refreshing && refreshFolders != 0 { refreshFolders = 0 }
    }

    private func enqueueRefresh(_ request: RefreshRequest) {
        let filtered = RefreshRequest(changes: request.changes.excluding(directory: cacheDirectory),
                                      isExplicit: request.isExplicit)
        readyRefresh = readyRefresh.map { $0.merged(with: filtered) } ?? filtered
        pump()
    }

    /// Replay FSEvents history since `eventID` (blocking, so off the main actor; it doesn't
    /// read the tree, so it runs outside the job queue) and queue a refresh for it.
    private func replayJournal(since eventID: UInt64, volumeUUID: String?, isExplicit: Bool) {
        guard let rootPath = root?.path else { return }
        let gen = generation
        journalsInFlight += 1
        updateRefreshIndicator()
        Task { [weak self] in
            let changes = await Task.detached(priority: .userInitiated) {
                ChangeJournal.changes(since: eventID, under: rootPath, expectedVolumeUUID: volumeUUID)
            }.value
            guard let self, gen == self.generation else { return }
            self.journalsInFlight -= 1
            log.info("Journal since \(eventID): \(changes.directories.count) dirs, \(changes.recursiveDirectories.count) recursive, full rescan: \(changes.requiresFullRescan)")
            self.enqueueRefresh(RefreshRequest(changes: changes, isExplicit: isExplicit))
        }
    }

    private func startRefresh(_ request: RefreshRequest) {
        guard let root, let options = treeOptions else { return }
        let changes = request.changes
        let started = Date()

        if changes.isEmpty {
            // Nothing to re-list; the tree is current as of the newer event ID.
            if let eventID = treeEventID, changes.latestEventID > eventID { treeEventID = changes.latestEventID }
            if request.isExplicit {
                treeScannedAt = started
                freshness = .updated(at: Date(), folders: 0, duration: 0)
                needsSave = true
            }
            startWatcherIfNeeded()
            return pump()
        }

        let gen = generation
        let scanner = IncrementalScanner(options: options)
        refreshScanner = scanner
        refreshFolders = 0
        let task = Task { [weak self] in
            let poller = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    if let self, gen == self.generation {
                        self.refreshFolders = scanner.progress.snapshot().directories
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            let outcome: Result<RefreshResult, Error>
            do {
                outcome = .success(try await scanner.computeRefresh(for: root, changes: changes))
            } catch {
                outcome = .failure(error)
            }
            poller.cancel()
            guard let self else { return }
            guard gen == self.generation else { return }
            if Task.isCancelled {
                // Pre-empted by a tree mutation: run these changes again afterwards.
                self.readyRefresh = self.readyRefresh.map { request.merged(with: $0) } ?? request
            } else {
                switch outcome {
                case .success(let result):
                    await self.applyRefresh(result, request: request, started: started, generation: gen)
                case .failure(let error):
                    log.error("Refresh failed: \(error.localizedDescription, privacy: .public)")
                    if request.isExplicit { self.errorMessage = error.localizedDescription }
                    self.startWatcherIfNeeded()
                }
            }
            self.jobFinished(generation: gen)
        }
        activeJob = (.refresh, task)
    }

    /// Splice a computed refresh into the tree. Runs inside the refresh job, so no save
    /// or other refresh is reading the tree.
    private func applyRefresh(_ result: RefreshResult, request: RefreshRequest, started: Date, generation gen: Int) async {
        guard let oldRoot = root else { return }
        let place = viewPlace()
        let newRoot = result.isEmpty ? oldRoot : oldRoot.apply(result, metric: metric)
        treeEventID = result.eventID
        treeScannedAt = started

        if !result.isEmpty {
            // Full rebuild of the id index, off the main actor (the job still holds the
            // tree, so nothing mutates it meanwhile).
            let clock = ContinuousClock.now
            // A rebuilt root (`newRoot`) comes straight from the scanner, sorted by allocated size.
            let sort: SizeMetric? = result.newRoot != nil && metric != .allocated ? metric : nil
            let index = await TreeIndex.build(newRoot, sortBy: sort)
            log.info("Rebuilt index of \(index.nodes.count) nodes in \(ContinuousClock.now - clock, privacy: .public)")
            guard gen == generation else { return }
            root = newRoot
            self.index = index.nodes
            unreadableCount = index.unreadable
            restore(place, in: newRoot)
            needsSave = true
        } else if request.isExplicit {
            needsSave = true
        }

        let duration = Date().timeIntervalSince(started)
        if request.isExplicit || !result.isEmpty {
            freshness = .updated(at: Date(), folders: result.didFullRescan ? nil : result.directoriesRescanned,
                                 duration: duration)
        }
        if !request.isExplicit {
            // Throttle live refreshes so heavy churn (a build folder) can't keep us busy.
            nextLiveRefreshAllowed = Date().addingTimeInterval(max(Self.minLiveInterval, duration * Self.liveDutyFactor))
        }
        log.info("Refresh applied: \(result.directoriesRescanned) dirs, full: \(result.didFullRescan), \(duration, format: .fixed(precision: 3)) s")
        revision += 1
        startWatcherIfNeeded()
    }

    private func startSave() {
        needsSave = false
        guard rememberScans, let root, let eventID = treeEventID, let options = treeOptions else { return }
        let cache = self.cache
        let scannedAt = treeScannedAt
        let gen = generation
        let task = Task { [weak self] in
            let started = Date()
            await Task.detached(priority: .utility) {
                let metadata = ScanSnapshotMetadata(root: root, options: options, eventID: eventID, scannedAt: scannedAt)
                do {
                    try cache.save(ScanSnapshot(metadata: metadata, root: root))
                } catch {
                    log.error("Saving snapshot failed: \(error.localizedDescription, privacy: .public)")
                }
            }.value
            log.info("Saved snapshot of \(root.path, privacy: .public) in \(Date().timeIntervalSince(started), format: .fixed(precision: 3)) s")
            self?.jobFinished(generation: gen)
        }
        activeJob = (.save, task)
    }

    // MARK: - Live updates

    private func startWatcherIfNeeded() {
        guard watcher == nil, liveUpdates, !isScanning, journalsInFlight == 0,
              let root, let eventID = treeEventID else { return }
        let gen = generation
        let watcher = ChangeWatcher(rootPath: root.path, sinceEventID: eventID, latency: 1.0) { [weak self] changes in
            Task { @MainActor [weak self] in
                self?.receiveLiveChanges(changes, generation: gen)
            }
        }
        watcher.start()
        self.watcher = watcher
        log.info("Watching \(root.path, privacy: .public) since \(eventID)")
    }

    private func stopWatcher() {
        watcher?.stop()
        watcher = nil
    }

    private func receiveLiveChanges(_ changes: ChangeSet, generation gen: Int) {
        guard gen == generation, liveUpdates else { return }
        let changes = changes.excluding(directory: cacheDirectory)
        if changes.isEmpty {
            if let eventID = treeEventID, changes.latestEventID > eventID, liveChanges == nil, readyRefresh == nil,
               activeJob?.kind != .refresh {
                treeEventID = changes.latestEventID
            }
            return
        }
        liveChanges = liveChanges.map { $0.merged(with: changes) } ?? changes
        if firstLiveChangeAt == nil { firstLiveChangeAt = Date() }
        scheduleLiveFlush()
    }

    /// Debounce: fire after a quiet period, but no later than `maxWait` after the first
    /// change, and never before the throttle allows.
    private func scheduleLiveFlush() {
        liveFlushTask?.cancel()
        let now = Date()
        let quiet = now.addingTimeInterval(Self.debounce)
        let cap = (firstLiveChangeAt ?? now).addingTimeInterval(Self.maxWait)
        let fireAt = max(min(quiet, cap), nextLiveRefreshAllowed)
        let gen = generation
        liveFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, fireAt.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, gen == self.generation else { return }
            self.flushLiveChanges()
        }
    }

    private func flushLiveChanges() {
        guard let changes = liveChanges else { return }
        liveChanges = nil
        firstLiveChangeAt = nil
        enqueueRefresh(RefreshRequest(changes: changes, isExplicit: false))
    }

    // MARK: - Cache management (Settings)

    struct CacheUsage: Sendable {
        var count: Int
        var bytes: Int64
    }

    func cacheUsage() async -> CacheUsage {
        let cache = self.cache
        return await Task.detached(priority: .utility) {
            let entries = cache.entries()
            return CacheUsage(count: entries.count, bytes: entries.reduce(0) { $0 + $1.sizeOnDisk })
        }.value
    }

    func clearCache() async {
        let cache = self.cache
        do {
            try await Task.detached(priority: .utility) { try cache.clear() }.value
        } catch {
            errorMessage = "Couldn't clear the cache: \(error.localizedDescription)"
        }
    }

    // MARK: - Lookup & navigation

    func node(_ id: FileNode.ID) -> FileNode? { index[id] }

    func nodes(_ ids: Set<FileNode.ID>) -> [FileNode] { ids.compactMap { index[$0] } }

    var selectedNodes: [FileNode] { nodes(selection) }

    @ObservationIgnored private var selectionCameFromTreemap = false

    func selectFromTreemap(_ node: FileNode) {
        selectionCameFromTreemap = true
        selection = [node.id]
    }

    func consumeTreemapSelectionFlag() -> Bool {
        defer { selectionCameFromTreemap = false }
        return selectionCameFromTreemap
    }

    func focusParent() {
        if let parent = focus?.parent { focus = parent }
    }

    /// Show a directory in the treemap, or its parent directory for a file.
    func reveal(inTreemap node: FileNode) {
        focus = node.isDirectory ? node : (node.parent ?? node)
        selection = [node.id]
    }

    // MARK: - Finder actions

    func revealInFinder(_ nodes: [FileNode]) {
        NSWorkspace.shared.activateFileViewerSelecting(nodes.map(\.url))
    }

    func open(_ node: FileNode) {
        NSWorkspace.shared.open(node.url)
    }

    func copyPaths(_ nodes: [FileNode]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(nodes.map(\.path).joined(separator: "\n"), forType: .string)
    }

    func requestTrash(_ nodes: [FileNode]) {
        // Never offer to trash the scan root itself.
        pendingTrash = nodes.filter { $0.parent != nil }
    }

    func confirmTrash() {
        let items = pendingTrash
        var trashed: [String] = []
        var failures: [String] = []
        for node in items {
            do {
                try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
                trashed.append(node.path)
            } catch {
                failures.append("\(node.name): \(error.localizedDescription)")
            }
        }
        // Remove from the tree once nothing is reading it. Items are re-found by path:
        // a refresh may have replaced the node objects since the dialog opened, and an
        // item a refresh already dropped (it's gone from disk) must not be subtracted again.
        // The FSEvents for the move then re-list the parents, so totals come from disk.
        mutateTree { [weak self] in
            guard let self, let root = self.root else { return }
            let focusPath = self.focus?.path
            for path in trashed {
                guard let node = root.node(atPath: path), node !== root, !RootPath.exists(path) else { continue }
                var stack = [node]
                while let removed = stack.popLast() {
                    self.index[removed.id] = nil
                    stack.append(contentsOf: removed.children)
                }
                node.removeFromParent()
            }
            if let focusPath, let focus = self.focus, !focus.isDescendant(of: root) {
                self.focus = root.deepestNode(atPath: focusPath) ?? root
            }
            self.selection = []
            self.revision += 1
            self.needsSave = true
        }
        pendingTrash = []
        if !failures.isEmpty {
            errorMessage = "Some items could not be moved to the Trash:\n" + failures.joined(separator: "\n")
        }
    }

    /// Opens System Settings at Privacy & Security › Full Disk Access.
    func openFullDiskAccessSettings() {
        if !SystemSettings.openFullDiskAccess() {
            errorMessage = "Couldn't open System Settings. Open it manually and go to Privacy & Security › Full Disk Access."
        }
    }

    // MARK: - Formatting

    func sizeText(_ node: FileNode) -> String {
        SizeFormatter.string(node.size(metric))
    }

    func fractionOfParent(_ node: FileNode) -> Double {
        guard let parent = node.parent else { return 1 }
        let total = parent.size(metric)
        return total > 0 ? Double(node.size(metric)) / Double(total) : 0
    }
}
