import SwiftUI
import MacSizeCore

/// Settings > General: live updates and the scan cache.
struct GeneralSettingsView: View {
    @Environment(ScanModel.self) private var model
    @State private var usage: ScanModel.CacheUsage?
    @State private var confirmingClear = false
    @State private var isClearing = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Update results automatically when files change", isOn: $model.liveUpdates)
            }
            Section("Disk Space") {
                PurgeableToggle()
                Text("Off matches System Settings and Finder. On matches Disk Utility and df. "
                     + VolumeDisplay.explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Cache") {
                Toggle("Remember scans between launches", isOn: $model.rememberScans)
                Text("Reopening a folder shows the saved results instantly, then updates only what changed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Saved scans") {
                    if let usage {
                        Text(usage.count == 0
                             ? "None"
                             : "\(usage.count) · \(SizeFormatter.string(usage.bytes))")
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                Button("Clear Cache…") { confirmingClear = true }
                    .disabled(isClearing || usage?.count == 0)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
        .task { usage = await model.cacheUsage() }
        .confirmationDialog("Clear all saved scans?", isPresented: $confirmingClear) {
            Button("Clear Cache", role: .destructive) {
                isClearing = true
                Task {
                    await model.clearCache()
                    usage = await model.cacheUsage()
                    isClearing = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Results you have open stay on screen. Folders you reopen will be scanned from scratch.")
        }
    }
}
