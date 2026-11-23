import Combine
import Foundation
import Observation
import Sparkle
import SwiftUI

/// Thin wrapper around Sparkle's standard updater.
///
/// Sparkle only starts for official builds: the app must be running from a `.app`
/// bundle whose Info.plist has `SUFeedURL` (written by `scripts/build-app.sh` only
/// when release settings are supplied). `swift run` and source builds get an inert
/// updater, so they never check for or install updates.
@MainActor
@Observable
final class Updater {
    /// `true` when Sparkle is active for this build.
    let isAvailable: Bool
    /// Mirrors `SPUUpdater.canCheckForUpdates` for enabling the menu item.
    private(set) var canCheckForUpdates = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var cancellable: AnyCancellable?

    init(bundle: Bundle = .main) {
        let isAppBundle = bundle.bundleURL.pathExtension == "app"
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
        guard isAppBundle, let feed, !feed.isEmpty else {
            controller = nil
            isAvailable = false
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        isAvailable = true
        cancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.canCheckForUpdates = value }
            }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Download and install updates silently (installed on quit). Turning it on
    /// also turns on background checks, since one is useless without the other.
    var automaticallyDownloadsUpdates: Bool {
        get {
            access(keyPath: \.automaticallyDownloadsUpdates)
            return controller?.updater.automaticallyDownloadsUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyDownloadsUpdates) {
                guard let updater = controller?.updater else { return }
                if newValue { updater.automaticallyChecksForUpdates = true }
                updater.automaticallyDownloadsUpdates = newValue
            }
        }
    }

    /// Check for updates in the background once a day.
    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                guard let updater = controller?.updater else { return }
                updater.automaticallyChecksForUpdates = newValue
                if !newValue { updater.automaticallyDownloadsUpdates = false }
            }
        }
    }
}

/// "Check for Updates…" menu item.
struct CheckForUpdatesCommand: View {
    let updater: Updater

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}

/// Settings > Updates.
struct UpdateSettingsView: View {
    @Bindable var updater: Updater

    var body: some View {
        Form {
            if updater.isAvailable {
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
                Toggle("Automatically download and install updates",
                       isOn: $updater.automaticallyDownloadsUpdates)
                Text("Updates install when you quit MacSize.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Check Now") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            } else {
                Text("Automatic updates are available in official releases only. This build was compiled from source.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }
}
