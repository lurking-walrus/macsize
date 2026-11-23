import AppKit
import Observation
import TreeSizeCore

@MainActor
@Observable
final class ScanModel {
    // MARK: Scan state
    private(set) var root: FileNode?
    private(set) var rootURL: URL?
    private(set) var isScanning = false
    private(set) var progress = ScanProgress.Snapshot()
    private(set) var scanDuration: TimeInterval?
    private(set) var unreadableCount = 0
    var errorMessage: String?

    // MARK: View state
    /// Directory shown in the treemap.
    var focus: FileNode?
    var selection = Set<FileNode.ID>()
    /// Bumped whenever the tree mutates so views that cache layout can refresh.
    private(set) var revision = 0
    var pendingTrash: [FileNode] = []

    // MARK: Settings (persisted per user via UserDefaults)
    var metric: SizeMetric = SizeMetric(rawValue: UserDefaults.standard.string(forKey: "metric") ?? "") ?? .allocated {
        didSet {
            UserDefaults.standard.set(metric.rawValue, forKey: "metric")
            root?.sortChildren(by: metric)
            revision += 1
        }
    }
    var stayOnFileSystem: Bool = UserDefaults.standard.bool(forKey: "stayOnFileSystem") {
        didSet { UserDefaults.standard.set(stayOnFileSystem, forKey: "stayOnFileSystem") }
    }

    @ObservationIgnored private var index: [ObjectIdentifier: FileNode] = [:]
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanner: DiskScanner?

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

    func rescan() {
        if let rootURL { scan(rootURL) }
    }

    /// Lets the app be launched as `TreeSize /some/path` to scan immediately.
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

    func scan(_ url: URL) {
        cancelScan()
        let scanner = DiskScanner(options: ScanOptions(stayOnFileSystem: stayOnFileSystem))
        let metric = self.metric
        self.scanner = scanner
        rootURL = url
        isScanning = true
        errorMessage = nil
        progress = .init()
        let started = Date()

        scanTask = Task { [weak self] in
            let poller = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.progress = scanner.progress.snapshot()
                    try? await Task.sleep(for: .milliseconds(120))
                }
            }
            defer { poller.cancel() }

            do {
                let result = try await Self.scanAndIndex(scanner: scanner, path: url.path, metric: metric)
                guard let self, !Task.isCancelled else { return }
                self.install(result, duration: Date().timeIntervalSince(started))
            } catch ScanError.cancelled {
                self?.isScanning = false
            } catch {
                self?.isScanning = false
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func cancelScan() {
        scanner?.cancel()
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    private struct ScanResult: @unchecked Sendable {
        let root: FileNode
        let index: [ObjectIdentifier: FileNode]
        let unreadable: Int
    }

    /// Runs the scan and builds the id → node index off the main thread.
    private nonisolated static func scanAndIndex(scanner: DiskScanner, path: String, metric: SizeMetric) async throws -> ScanResult {
        let root = try await scanner.scan(path: path)
        return await Task.detached(priority: .userInitiated) {
            if metric != .allocated { root.sortChildren(by: metric) }
            var index: [ObjectIdentifier: FileNode] = [:]
            var unreadable = 0
            var stack = [root]
            while let node = stack.popLast() {
                index[node.id] = node
                if node.errorCode != 0 { unreadable += 1 }
                stack.append(contentsOf: node.children)
            }
            return ScanResult(root: root, index: index, unreadable: unreadable)
        }.value
    }

    private func install(_ result: ScanResult, duration: TimeInterval) {
        root = result.root
        index = result.index
        unreadableCount = result.unreadable
        focus = result.root
        selection = []
        scanDuration = duration
        progress = scanner?.progress.snapshot() ?? progress
        isScanning = false
        revision += 1
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
        pendingTrash = []
        var failures: [String] = []
        for node in items {
            do {
                try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
                node.removeFromParent()
            } catch {
                failures.append("\(node.name): \(error.localizedDescription)")
            }
        }
        if let focus, let root, !focus.isDescendant(of: root) {
            self.focus = root
        }
        selection = []
        revision += 1
        if !failures.isEmpty {
            errorMessage = "Some items could not be moved to the Trash:\n" + failures.joined(separator: "\n")
        }
    }

    /// Opens System Settings at Privacy & Security › Full Disk Access.
    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
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
