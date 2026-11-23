import SwiftUI
import MacSizeCore

struct ContentView: View {
    @Environment(ScanModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.isScanning {
                ScanningView()
            } else if let root = model.root {
                ResultsView(root: root)
            } else {
                WelcomeView()
            }
        }
        .navigationTitle(model.rootURL?.lastPathComponent ?? "MacSize")
        .navigationSubtitle(model.root.map { "\(SizeFormatter.string($0.size(model.metric))) · \(model.metric.displayName)" } ?? "")
        .toolbar { toolbar }
        .alert(
            "Error",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }),
            presenting: model.errorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .confirmationDialog(
            trashTitle,
            isPresented: Binding(get: { !model.pendingTrash.isEmpty }, set: { if !$0 { model.pendingTrash = [] } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { model.confirmTrash() }
            Button("Cancel", role: .cancel) { model.pendingTrash = [] }
        } message: {
            Text(model.pendingTrash.map(\.path).joined(separator: "\n"))
        }
    }

    private var trashTitle: String {
        let items = model.pendingTrash
        let total = items.reduce(Int64(0)) { $0 + $1.size(model.metric) }
        let what = items.count == 1 ? "“\(items[0].name)”" : "\(items.count) items"
        return "Move \(what) (\(SizeFormatter.string(total))) to the Trash?"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var model = model
        ToolbarItemGroup(placement: .navigation) {
            Button { model.focusParent() } label: { Label("Enclosing Folder", systemImage: "chevron.up") }
                .disabled(model.focus?.parent == nil)
                .help("Show the enclosing folder in the treemap")
        }
        ToolbarItemGroup {
            Button { model.chooseFolder() } label: { Label("Scan Folder", systemImage: "folder.badge.gearshape") }
                .help("Choose a folder or volume to scan (⌘O)")
            Button { model.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                .disabled(model.rootURL == nil || model.isScanning)
                .help("Scan the same location again (⌘R)")
            Picker("Size", selection: $model.metric) {
                ForEach(SizeMetric.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Size on disk accounts for APFS compression, sparse files and clones")
            Menu {
                Toggle("Stay on Selected Volume", isOn: $model.stayOnFileSystem)
                Divider()
                Button("Open Full Disk Access Settings…") { model.openFullDiskAccessSettings() }
            } label: {
                Label("Options", systemImage: "slider.horizontal.3")
            }
            Button(role: .destructive) { model.requestTrash(model.selectedNodes) } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .disabled(model.selection.isEmpty)
            .help("Move the selected items to the Trash")
        }
    }
}

// MARK: - Results

struct ResultsView: View {
    @Environment(ScanModel.self) private var model
    let root: FileNode

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                OutlineTableView(root: root)
                    .frame(minWidth: 360, idealWidth: 520)
                VStack(spacing: 0) {
                    BreadcrumbBar()
                    Divider()
                    TreemapView(focus: model.focus ?? root)
                }
                .frame(minWidth: 320)
            }
            Divider()
            StatusBar(root: root)
        }
    }
}

struct BreadcrumbBar: View {
    @Environment(ScanModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                if let focus = model.focus {
                    let chain = focus.ancestry
                    ForEach(Array(chain.enumerated()), id: \.element.id) { offset, node in
                        if offset > 0 {
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        Button(offset == 0 ? node.url.lastPathComponent.ifEmpty("/") : node.name) {
                            model.focus = node
                        }
                        .buttonStyle(.borderless)
                        .fontWeight(node === focus ? .semibold : .regular)
                    }
                    Text(SizeFormatter.string(focus.size(model.metric)))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}

struct StatusBar: View {
    @Environment(ScanModel.self) private var model
    let root: FileNode

    var body: some View {
        HStack(spacing: 14) {
            Text("\(SizeFormatter.grouped(root.fileCount)) files")
            Text("\(SizeFormatter.grouped(root.directoryCount)) folders")
            if let duration = model.scanDuration {
                Text(String(format: "Scanned in %.1f s", duration))
            }
            Spacer()
            if model.unreadableCount > 0 {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text("\(SizeFormatter.grouped(model.unreadableCount)) items couldn't be read")
                Button("Grant Full Disk Access…") { model.openFullDiskAccessSettings() }
                    .buttonStyle(.link)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}

// MARK: - Welcome & progress

struct WelcomeView: View {
    @Environment(ScanModel.self) private var model

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "square.grid.3x3.square")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
            Text("What would you like to analyze?")
                .font(.title2.weight(.semibold))

            VStack(spacing: 8) {
                LocationButton(
                    title: "Home Folder",
                    systemImage: "house",
                    url: FileManager.default.homeDirectoryForCurrentUser
                )
                ForEach(Self.volumes, id: \.self) { url in
                    LocationButton(title: Self.volumeName(url), systemImage: "internaldrive", url: url)
                }
                Button {
                    model.chooseFolder()
                } label: {
                    Label("Choose Folder…", systemImage: "folder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .controlSize(.large)
                .frame(width: 320)
            }

            Text("For complete results, grant Full Disk Access in System Settings › Privacy & Security.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Open Full Disk Access Settings…") { model.openFullDiskAccessSettings() }
                .buttonStyle(.link)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static var volumes: [URL] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.volumeIsBrowsableKey]).volumeIsBrowsable) ?? true }
    }

    static func volumeName(_ url: URL) -> String {
        (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? url.path
    }
}

private struct LocationButton: View {
    @Environment(ScanModel.self) private var model
    let title: String
    let systemImage: String
    let url: URL

    var body: some View {
        Button { model.scan(url) } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if let free = Self.freeSpace(url) {
                    Text("\(free) free").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .frame(width: 320)
    }

    static func freeSpace(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return SizeFormatter.string(bytes)
    }
}

struct ScanningView: View {
    @Environment(ScanModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Scanning \(model.rootURL?.path ?? "")…")
                .font(.headline)
            HStack(spacing: 20) {
                stat("Files", SizeFormatter.grouped(model.progress.files))
                stat("Folders", SizeFormatter.grouped(model.progress.directories))
                stat("Size", SizeFormatter.string(model.progress.bytes))
            }
            Text(model.progress.currentPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 520)
            Button("Cancel") { model.cancelScan() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack {
            Text(value).font(.title3.monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 90)
    }
}

extension String {
    func ifEmpty(_ replacement: String) -> String { isEmpty ? replacement : self }
}
