import AppKit
import MacSizeCore
import Observation
import SwiftUI

/// Tracks whether MacSize has Full Disk Access and helps the user grant it.
@MainActor
@Observable
final class FullDiskAccessModel {
    private(set) var status: FullDiskAccess.Status = FullDiskAccess.check()
    /// Set once the user has opened Settings from here, so we can suggest a relaunch
    /// (macOS applies Full Disk Access to newly launched processes).
    private(set) var hasOpenedSettings = false

    /// The running .app, or nil for unbundled `swift run` builds (nothing to drag or relaunch).
    let appURL: URL? = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : nil

    var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "MacSize"
    }

    func refresh() {
        status = FullDiskAccess.check()
    }

    func openSettings() {
        hasOpenedSettings = true
        SystemSettings.openFullDiskAccess()
    }

    func showInFinder() {
        guard let appURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([appURL])
    }

    /// Start a fresh instance, then quit this one, so the new grant takes effect.
    func relaunch() {
        guard let appURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            guard error == nil else { return }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// Welcome-screen card: shows Full Disk Access status and, when it's missing,
/// a three-step guide with an app icon that can be dragged straight into Settings.
struct FullDiskAccessCard: View {
    @State private var model = FullDiskAccessModel()

    var body: some View {
        Group {
            if model.status == .granted {
                grantedRow
            } else {
                guide
            }
        }
        .padding(14)
        .frame(width: 480)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }

    private var grantedRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.open.fill")
                .font(.title2).foregroundStyle(.secondary).frame(width: 28)
            Text("Full Disk Access").font(.headline)
            Label("Granted", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.green)
            Spacer()
        }
    }

    private var guide: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.title2).foregroundStyle(.secondary).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Full Disk Access").font(.headline)
                        Label("Not granted", systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.orange)
                    }
                    Text("Without it, protected folders (Mail, Messages, Safari, parts of Library) are skipped and sizes look smaller than they are. macOS doesn't ask for this; you add \(model.appName) yourself.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            step(1, "Open Privacy & Security › Full Disk Access.") {
                Button("Open Settings") { model.openSettings() }
                    .buttonStyle(.borderedProminent)
            }

            step(2, model.appURL == nil
                 ? "Click + and choose \(model.appName) from Applications."
                 : "Drag this icon into the list, or click + and choose \(model.appName).") {
                if let appURL = model.appURL {
                    HStack(spacing: 8) {
                        DraggableAppIcon(appURL: appURL)
                        Button("Show in Finder") { model.showInFinder() }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            }

            step(3, "Turn on \(model.appName), then relaunch so macOS applies it.") {
                if model.appURL != nil {
                    if model.hasOpenedSettings {
                        Button("Relaunch \(model.appName)") { model.relaunch() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Relaunch \(model.appName)") { model.relaunch() }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func step<Accessory: View>(_ number: Int, _ text: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold).monospacedDigit())
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
                .padding(.leading, 4)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            accessory()
        }
    }
}

/// The app's own icon, draggable as a file so it can be dropped into the
/// Full Disk Access list in System Settings.
private struct DraggableAppIcon: View {
    let appURL: URL

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
            .resizable()
            .frame(width: 40, height: 40)
            .onDrag { NSItemProvider(object: appURL as NSURL) }
            .help("Drag into the Full Disk Access list in System Settings")
            .accessibilityLabel("App icon. Drag into the Full Disk Access list.")
    }
}
