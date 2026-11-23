import SwiftUI
import MacSizeCore

/// Cloud-storage presentation settings and shared UI state.
///
/// Cloud-only items are dataless File Provider placeholders (iCloud Drive, Google Drive,
/// OneDrive, Dropbox…). They take ~0 bytes on this Mac, so "Size on Disk" counts them as 0;
/// the UI keeps them visible (dimmed, with a cloud icon) unless the user hides them.
enum CloudDisplay {
    /// `@AppStorage` key for "Show Cloud-Only Items" (default on).
    static let showCloudOnlyKey = "showCloudOnlyItems"
    static let symbol = "icloud"
    static let dimmedOpacity = 0.5

    /// "☁︎ 48 GB in cloud, not downloaded" for a folder containing cloud-only items.
    static func folderSummary(_ node: FileNode) -> String? {
        if node.isCloudOnly {
            return node.isDirectory
                ? "☁︎ In the cloud, not downloaded. Its contents aren't listed so they aren't downloaded."
                : "☁︎ \(SizeFormatter.string(node.logicalSize)) in cloud, not downloaded (uses no space on this Mac)"
        }
        guard node.isDirectory, node.cloudOnlyCount > 0 else { return nil }
        let items = node.cloudOnlyCount == 1 ? "1 item" : "\(SizeFormatter.grouped(node.cloudOnlyCount)) items"
        return "☁︎ \(SizeFormatter.string(node.cloudOnlySize)) in cloud, not downloaded (\(items))"
    }
}

/// Shared state for cloud actions that mutate the tree outside `ScanModel`
/// (e.g. "Remove Download"), so views can refresh.
@MainActor
@Observable
final class CloudActions {
    static let shared = CloudActions()

    /// Bumped whenever a cloud action changed the tree in place.
    private(set) var revision = 0
    /// Items awaiting confirmation for "Remove Download".
    var pendingRemoval: [FileNode] = []
    var errorMessage: String?

    func requestRemoveDownload(_ nodes: [FileNode]) {
        pendingRemoval = nodes.filter(CloudStorage.canRemoveDownload)
    }

    /// Evicts the confirmed iCloud Drive items, then refreshes their sizes from disk
    /// (metadata only) once iCloud has had a moment to remove the local data.
    func confirmRemoveDownload(metric: SizeMetric) {
        let items = pendingRemoval
        pendingRemoval = []
        var failures: [String] = []
        var evicted: [FileNode] = []
        for node in items {
            do {
                try CloudStorage.removeDownload(node)
                evicted.append(node)
            } catch {
                failures.append("\(node.name): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            errorMessage = "Some downloads couldn't be removed:\n" + failures.joined(separator: "\n")
        }
        guard !evicted.isEmpty else { return }
        refresh(evicted, metric: metric)
        // Eviction completes asynchronously in iCloud; check again shortly.
        Task { [weak self] in
            for delay in [1, 4] {
                try? await Task.sleep(for: .seconds(delay))
                self?.refresh(evicted, metric: metric)
            }
        }
    }

    private func refresh(_ nodes: [FileNode], metric: SizeMetric) {
        for node in nodes {
            node.refreshCloudState(sortingBy: metric)
        }
        revision += 1
    }
}

/// Status-bar summary: "☁︎ 12,345 cloud-only items (48 GB) aren't on this Mac".
struct CloudSummaryView: View {
    let root: FileNode
    private var actions = CloudActions.shared

    init(root: FileNode) { self.root = root }

    var body: some View {
        let _ = actions.revision
        if root.cloudOnlyCount > 0 {
            let count = root.cloudOnlyCount
            let items = count == 1 ? "1 cloud-only item" : "\(SizeFormatter.grouped(count)) cloud-only items"
            let verb = count == 1 ? "isn't" : "aren't"
            HStack(spacing: 4) {
                Image(systemName: CloudDisplay.symbol)
                Text("\(items) (\(SizeFormatter.string(root.cloudOnlySize))) \(verb) on this Mac")
            }
            .help(
                "These files are stored in the cloud (iCloud Drive, Google Drive, OneDrive, Dropbox…) and "
                    + "use no space on this Mac. Size on Disk counts them as 0; Logical Size includes them. "
                    + "MacSize never downloads them."
            )
        }
    }
}

/// "Show Cloud-Only Items" toggle for the toolbar's Options menu.
struct CloudFilterToggle: View {
    @AppStorage(CloudDisplay.showCloudOnlyKey) private var showCloudOnly = true

    var body: some View {
        Toggle("Show Cloud-Only Items", isOn: $showCloudOnly)
    }
}
