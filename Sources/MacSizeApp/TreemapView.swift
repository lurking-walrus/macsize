import SwiftUI
import MacSizeCore

/// One laid-out rectangle in the treemap.
struct TreemapItem {
    let node: FileNode
    let rect: CGRect
    let depth: Int
    let color: Color
    /// Cloud-only placeholder: drawn hatched and desaturated so it's never mistaken for local data.
    var isCloudOnly = false
}

/// Reference-type cache so layout results can be stored during drawing without
/// triggering another view update.
final class TreemapLayoutCache {
    struct Key: Equatable {
        let focus: ObjectIdentifier
        let size: CGSize
        let revision: Int
        let metric: SizeMetric
        let showCloudOnly: Bool
        let cloudRevision: Int
    }

    var key: Key?
    var items: [TreemapItem] = []
}

/// Nested squarified treemap of the focused directory, drawn with `Canvas`.
///
/// Click selects, double-click zooms into a folder (or opens a file's folder).
struct TreemapView: View {
    @Environment(ScanModel.self) private var model
    let focus: FileNode

    @State private var cache = TreemapLayoutCache()
    @State private var hovered: FileNode?
    @State private var cloud = CloudActions.shared
    @AppStorage(CloudDisplay.showCloudOnlyKey) private var showCloudOnly = true

    /// Cloud-only items have no size on disk, so they only appear with Logical Size.
    private static let cloudColor = Color(hue: 0.6, saturation: 0.06, brightness: 0.8)

    private static let maxDepth = 6
    private static let maxItems = 25_000
    private static let headerHeight: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            Canvas(rendersAsynchronously: false) { context, size in
                draw(in: &context, items: layoutItems(size: size))
            }
            .onContinuousHover { phase in
                switch phase {
                case let .active(point): hovered = hit(point)?.node
                case .ended: hovered = nil
                }
            }
            .gesture(
                SpatialTapGesture(count: 2).onEnded { value in
                    guard let node = hit(value.location)?.node else { return }
                    model.reveal(inTreemap: node)
                }
                .exclusively(before: SpatialTapGesture().onEnded { value in
                    if let node = hit(value.location)?.node { model.selectFromTreemap(node) }
                })
            )
            .contextMenu {
                if let hovered {
                    NodeContextMenu(nodes: [hovered])
                }
            }
            .overlay(alignment: .bottomLeading) { hoverLabel }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    @ViewBuilder
    private var hoverLabel: some View {
        if let hovered {
            HStack(spacing: 8) {
                Text(hovered.path).lineLimit(1).truncationMode(.head)
                Text(SizeFormatter.string(hovered.size(model.metric))).fontWeight(.semibold)
                if let cloudText = CloudDisplay.folderSummary(hovered) {
                    Text(cloudText).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .padding(8)
            .allowsHitTesting(false)
        }
    }

    // MARK: Layout

    /// Layout is cached and only recomputed when focus, size, metric or tree contents change,
    /// so hover-driven redraws stay cheap.
    private func layoutItems(size: CGSize) -> [TreemapItem] {
        let key = TreemapLayoutCache.Key(
            focus: focus.id, size: size, revision: model.revision, metric: model.metric,
            showCloudOnly: showCloudOnly, cloudRevision: cloud.revision
        )
        if cache.key == key { return cache.items }
        var result: [TreemapItem] = []
        result.reserveCapacity(1024)
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
        layout(focus, in: bounds, depth: 0, hue: nil, into: &result)
        cache.key = key
        cache.items = result
        return result
    }

    private func layout(_ node: FileNode, in rect: CGRect, depth: Int, hue: Double?, into items: inout [TreemapItem]) {
        guard depth < Self.maxDepth, items.count < Self.maxItems else { return }
        let children = node.children.filter { weight($0) > 0 && (showCloudOnly || !$0.isCloudOnly) }
        guard !children.isEmpty, rect.width > 3, rect.height > 3 else { return }

        let rects = Treemap.squarify(children.map { Double(weight($0)) }, in: rect)
        for (index, (child, childRect)) in zip(children, rects).enumerated() {
            guard childRect.width >= 1.5, childRect.height >= 1.5 else { continue }
            if items.count >= Self.maxItems { return }

            // Each top-level branch gets its own hue; files are tinted by extension.
            let branchHue = hue ?? Self.goldenHue(index)
            let color: Color
            if child.isCloudOnly {
                color = Self.cloudColor
            } else if child.isDirectory {
                color = Color(hue: branchHue, saturation: 0.35, brightness: max(0.35, 0.8 - Double(depth) * 0.08))
            } else {
                color = Color(hue: Self.extensionHue(child.fileExtension, fallback: branchHue), saturation: 0.55, brightness: 0.85)
            }
            items.append(TreemapItem(node: child, rect: childRect, depth: depth, color: color, isCloudOnly: child.isCloudOnly))

            if child.isDirectory {
                var inner = childRect.insetBy(dx: 2, dy: 2)
                if inner.height > Self.headerHeight * 2.5 && inner.width > 40 {
                    inner.origin.y += Self.headerHeight
                    inner.size.height -= Self.headerHeight
                }
                layout(child, in: inner, depth: depth + 1, hue: branchHue, into: &items)
            }
        }
    }

    /// Area weight. With cloud-only items hidden, Logical Size uses only local bytes so the
    /// remaining rectangles fill their parent (displayed totals are unchanged).
    private func weight(_ node: FileNode) -> Int64 {
        if !showCloudOnly && model.metric == .logical { return node.localLogicalSize }
        return node.size(model.metric)
    }

    private func hit(_ point: CGPoint) -> TreemapItem? {
        // Children are appended after their parents, so the last match is the deepest.
        cache.items.last { $0.rect.contains(point) }
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, items: [TreemapItem]) {
        let selected = model.selection
        for item in items {
            let rect = item.rect.insetBy(dx: 0.5, dy: 0.5)
            let path = Path(rect)
            context.fill(path, with: .color(item.color))
            if item.isCloudOnly {
                drawCloudHatching(in: rect, path: path, context: &context)
            } else if item.node.isDirectory {
                context.stroke(path, with: .color(.black.opacity(0.35)), lineWidth: 1)
            } else {
                context.fill(path, with: .linearGradient(
                    Gradient(colors: [.white.opacity(0.18), .black.opacity(0.12)]),
                    startPoint: rect.origin,
                    endPoint: CGPoint(x: rect.maxX, y: rect.maxY)
                ))
                context.stroke(path, with: .color(.black.opacity(0.2)), lineWidth: 0.5)
            }
            drawLabel(for: item, in: rect, context: &context)
        }

        for item in items where selected.contains(item.node.id) || item.node === hovered {
            let isSelected = selected.contains(item.node.id)
            context.stroke(
                Path(item.rect.insetBy(dx: 1, dy: 1)),
                with: .color(isSelected ? .accentColor : .white),
                lineWidth: isSelected ? 3 : 1.5
            )
        }
    }

    /// Diagonal stripes and a dashed outline: "in the cloud, not on this Mac".
    private func drawCloudHatching(in rect: CGRect, path: Path, context: inout GraphicsContext) {
        var stripes = Path()
        let spacing: CGFloat = 6
        var x = rect.minX - rect.height
        while x < rect.maxX {
            stripes.move(to: CGPoint(x: x, y: rect.maxY))
            stripes.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        var clipped = context
        clipped.clip(to: path)
        clipped.stroke(stripes, with: .color(.black.opacity(0.16)), lineWidth: 1)
        context.stroke(path, with: .color(.black.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
    }

    private func drawLabel(for item: TreemapItem, in rect: CGRect, context: inout GraphicsContext) {
        guard rect.width > 44 else { return }
        var size = SizeFormatter.string(item.node.size(model.metric))
        if item.isCloudOnly { size = "☁︎ " + size + " in cloud" }
        if item.node.isDirectory {
            guard rect.height > Self.headerHeight * 2.5 else { return }
            let text = Text("\(item.node.name)  \(size)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.black.opacity(0.8))
            context.draw(text, in: CGRect(x: rect.minX + 4, y: rect.minY + 2, width: rect.width - 8, height: Self.headerHeight - 2))
        } else if rect.height > 28 {
            let text = Text("\(item.node.name)\n\(size)")
                .font(.system(size: 10))
                .foregroundStyle(.black.opacity(0.75))
            context.draw(text, in: rect.insetBy(dx: 4, dy: 3))
        }
    }

    // MARK: Colors

    private static func goldenHue(_ index: Int) -> Double {
        (0.58 + Double(index) * 0.618_033_988_75).truncatingRemainder(dividingBy: 1)
    }

    /// Stable hue per extension (String.hashValue is randomized per launch).
    private static func extensionHue(_ ext: String, fallback: Double) -> Double {
        guard !ext.isEmpty else { return fallback }
        var hash: UInt32 = 2_166_136_261
        for byte in ext.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Double(hash % 360) / 360
    }
}
