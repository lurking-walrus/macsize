import SwiftUI
import TreeSizeCore

/// TreeSize-style hierarchical table: name, size bar, % of parent, file count, date.
struct OutlineTableView: View {
    @Environment(ScanModel.self) private var model
    let root: FileNode

    var body: some View {
        @Bindable var model = model
        Table(root.children, children: \.outlineChildren, selection: $model.selection) {
            TableColumn("Name") { node in
                HStack(spacing: 6) {
                    Image(systemName: icon(for: node))
                        .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
                        .frame(width: 16)
                    Text(node.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
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
            }
            .width(min: 160, ideal: 260)

            TableColumn("Size") { node in
                Text(model.sizeText(node))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 80)

            TableColumn("% of Parent") { node in
                PercentBar(fraction: model.fractionOfParent(node))
            }
            .width(min: 90, ideal: 120)

            TableColumn("Files") { node in
                Text(node.isDirectory ? SizeFormatter.grouped(node.fileCount) : "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 70)

            TableColumn("Modified") { node in
                Text(Date(timeIntervalSince1970: node.modificationTime), format: .dateTime.year().month().day())
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)
        }
        // Rebuild rows after sorting changes or items are trashed.
        .id(model.revision)
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
            Divider()
            Button("Move to Trash…", role: .destructive) { model.requestTrash(nodes) }
                .disabled(nodes.allSatisfy { $0.parent == nil })
        }
    }
}
