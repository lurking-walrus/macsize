import SwiftUI
import MacSizeCore

/// MacSize-style hierarchical table: name, size bar, % of parent, file count, date.
struct OutlineTableView: View {
    @Environment(ScanModel.self) private var model
    @AppStorage(CloudDisplay.showCloudOnlyKey) private var showCloudOnly = true
    @State private var cloud = CloudActions.shared
    /// Column widths/order the user set; persisted so rescans (which rebuild the table) keep them.
    @SceneStorage("outlineColumns") private var columns = TableColumnCustomization<FileNode>()
    let root: FileNode

    var body: some View {
        @Bindable var model = model
        Table(of: FileNode.self,
            selection: $model.selection,
            columnCustomization: $columns
        ) {
            TableColumn("Name") { node in
                HStack(spacing: 6) {
                    Image(systemName: icon(for: node))
                        .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
                        .frame(width: 16)
                    Text(node.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if node.isCloudOnly {
                        Image(systemName: CloudDisplay.symbol)
                            .foregroundStyle(.secondary)
                    } else if node.isDirectory && node.cloudOnlyCount > 0 {
                        Text("☁︎ \(SizeFormatter.string(node.cloudOnlySize))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if node.errorCode != 0 {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                            .help("Couldn't read: \(String(cString: strerror(node.errorCode)))")
                    } else if node.isExcluded {
                        Image(systemName: "nosign")
                            .foregroundStyle(.secondary)
                            .help("Not scanned (excluded or on another volume)")
                    }
                }
                .opacity(node.isCloudOnly ? CloudDisplay.dimmedOpacity : 1)
                .help(CloudDisplay.folderSummary(node) ?? "")
            }
            .width(min: 160, ideal: 260)
            .customizationID("name")

            TableColumn("Size") { node in
                Text(model.sizeText(node))
                    .monospacedDigit()
                    .foregroundStyle(node.isCloudOnly ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(node.isCloudOnly ? (CloudDisplay.folderSummary(node) ?? "") : "")
            }
            .width(min: 70, ideal: 80)
            .customizationID("size")

            TableColumn("% of Parent") { node in
                PercentBar(fraction: model.fractionOfParent(node))
            }
            .width(min: 90, ideal: 120)
            .customizationID("percent")

            TableColumn("Files") { node in
                Text(node.isDirectory ? SizeFormatter.grouped(node.fileCount) : "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 70)
            .customizationID("files")

            TableColumn("Modified") { node in
                Text(Date(timeIntervalSince1970: node.modificationTime), format: .dateTime.year().month().day())
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)
            .customizationID("modified")
        } rows: {
            OutlineRows(nodes: showCloudOnly ? root.children : root.children.filter { !$0.isCloudOnly },
                        showCloudOnly: showCloudOnly)
        }
        // Rebuild rows after sorting changes, items are trashed or downloads removed,
        // or cloud-only items are shown/hidden.
        .id("\(model.revision)-\(cloud.revision)-\(showCloudOnly)")
        .confirmationDialog(
            removeDownloadTitle,
            isPresented: Binding(get: { !cloud.pendingRemoval.isEmpty }, set: { if !$0 { cloud.pendingRemoval = [] } }),
            titleVisibility: .visible
        ) {
            Button("Remove Download") { cloud.confirmRemoveDownload(metric: model.metric) }
            Button("Cancel", role: .cancel) { cloud.pendingRemoval = [] }
        } message: {
            Text("The items stay in iCloud Drive and download again when you open them.\n\n"
                + cloud.pendingRemoval.map(\.path).joined(separator: "\n"))
        }
        .alert(
            "Couldn't Remove Download",
            isPresented: Binding(get: { cloud.errorMessage != nil }, set: { if !$0 { cloud.errorMessage = nil } }),
            presenting: cloud.errorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .contextMenu(forSelectionType: FileNode.ID.self) { ids in
            NodeContextMenu(nodes: model.nodes(ids))
        } primaryAction: { ids in
            guard let node = model.nodes(ids).first else { return }
            if node.isDirectory { model.reveal(inTreemap: node) } else { model.open(node) }
        }
        .onChange(of: model.selection) { _, ids in
            // Follow a table selection in the treemap (selections made in the treemap don't move it).
            if model.consumeTreemapSelectionFlag() { return }
            if ids.count == 1, let id = ids.first, let node = model.node(id),
               let target = node.isDirectory ? node : node.parent, target !== model.focus {
                model.focus = target
            }
        }
    }

    private var removeDownloadTitle: String {
        let items = cloud.pendingRemoval
        let total = items.reduce(Int64(0)) { $0 + $1.allocatedSize }
        let what = items.count == 1 ? "“\(items[0].name)”" : "\(items.count) items"
        return "Remove the download of \(what) and free \(SizeFormatter.string(total))?"
    }

    private func icon(for node: FileNode) -> String {
        switch node.kind {
        case .directory: return node.name.hasSuffix(".app") ? "app" : "folder.fill"
        case .symlink: return "arrow.turn.up.right"
        case .file, .other: return "doc"
        }
    }
}

struct PercentBar: View {
    let fraction: Double

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(Color.accentColor.gradient)
                        .frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: 6)
            Text(String(format: "%.1f%%", fraction * 100))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

struct NodeContextMenu: View {
    @Environment(ScanModel.self) private var model
    let nodes: [FileNode]

    var body: some View {
        if let first = nodes.first {
            if nodes.count == 1 {
                if first.isDirectory {
                    Button("Show in Treemap") { model.reveal(inTreemap: first) }
                }
                Button("Open") { model.open(first) }
            }
            Button("Reveal in Finder") { model.revealInFinder(nodes) }
            Button(nodes.count == 1 ? "Copy Path" : "Copy Paths") { model.copyPaths(nodes) }
            // iCloud Drive only: other providers don't let third-party apps evict their items.
            let removable = nodes.filter(CloudStorage.canRemoveDownload)
            if !removable.isEmpty {
                Button("Remove Download…") { CloudActions.shared.requestRemoveDownload(removable) }
            }
            Divider()
            Button("Move to Trash…", role: .destructive) { model.requestTrash(nodes) }
                .disabled(nodes.allSatisfy { $0.parent == nil })
        }
    }
}

extension FileNode {
    /// Outline children, optionally without cloud-only placeholders (for `Table(children:)`).
    subscript(outlineChildren showCloudOnly: Bool) -> [FileNode]? {
        guard let children = outlineChildren else { return nil }
        if showCloudOnly { return children }
        let local = children.filter { !$0.isCloudOnly }
        return local.isEmpty ? nil : local
    }
}

/// Rows for a list of sibling nodes. Folders are disclosure rows whose expansion lives in
/// `ScanModel.expandedPaths`, so it survives the table being rebuilt after a refresh.
struct OutlineRows: TableRowContent {
    @Environment(ScanModel.self) private var model
    let nodes: [FileNode]
    let showCloudOnly: Bool

    var tableRowBody: some TableRowContent<FileNode> {
        ForEach(nodes) { node in
            if let children = node[outlineChildren: showCloudOnly] {
                DisclosureTableRow(node, isExpanded: expansion(of: node)) {
                    OutlineRows(nodes: children, showCloudOnly: showCloudOnly)
                }
            } else {
                TableRow(node)
            }
        }
    }

    private func expansion(of node: FileNode) -> Binding<Bool> {
        let path = node.path
        return Binding(
            get: { model.expandedPaths.contains(path) },
            set: { expanded in
                if expanded { model.expandedPaths.insert(path) } else { model.expandedPaths.remove(path) }
            }
        )
    }
}
