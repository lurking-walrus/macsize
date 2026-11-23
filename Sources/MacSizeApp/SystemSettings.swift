import AppKit

/// Opens panes of System Settings, falling back gracefully when a deep link isn't honoured.
@MainActor
enum SystemSettings {
    static let bundleIdentifier = "com.apple.systempreferences"

    /// Deep links to Privacy & Security › Full Disk Access, most specific first.
    /// The `com.apple.settings.PrivacySecurity.extension` form is the native one on macOS 13+;
    /// the legacy `com.apple.preference.security` form is still routed on current releases.
    /// The anchor-less forms land on Privacy & Security if the anchor is ever dropped.
    static let fullDiskAccessURLs: [URL] = [
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
        "x-apple.systempreferences:com.apple.preference.security",
    ].compactMap(URL.init(string:))

    /// Opens Full Disk Access settings. Returns `false` only if not even System Settings could be opened.
    @discardableResult
    static func openFullDiskAccess() -> Bool {
        // With cooperative activation (macOS 14+), System Settings can navigate to the pane
        // yet stay behind our window unless we explicitly hand activation over to it.
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: bundleIdentifier)

        for url in fullDiskAccessURLs where NSWorkspace.shared.open(url) {
            return true
        }

        // Last resort: open System Settings itself so the user can navigate there manually.
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        return true
    }
}
