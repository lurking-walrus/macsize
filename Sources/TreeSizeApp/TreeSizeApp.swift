import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (e.g. `swift run`) rather than an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct TreeSizeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = ScanModel()

    var body: some Scene {
        WindowGroup("TreeSize") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .task { model.scanLaunchArgumentIfPresent() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Scan Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o")
                Button("Rescan") { model.rescan() }
                    .keyboardShortcut("r")
                    .disabled(model.rootURL == nil || model.isScanning)
                Button("Cancel Scan") { model.cancelScan() }
                    .keyboardShortcut(".")
                    .disabled(!model.isScanning)
            }
            CommandMenu("Navigate") {
                Button("Enclosing Folder") { model.focusParent() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(model.focus?.parent == nil)
                Button("Top Level") { model.focus = model.root }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
                    .disabled(model.root == nil)
            }
        }
    }
}
