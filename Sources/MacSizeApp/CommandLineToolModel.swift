import AppKit
import MacSizeCore
import Observation

/// Drives the "Command-Line Tool" card: detects whether `macsize` is
/// installed and installs/updates/removes it as a symlink to the copy bundled
/// inside the app (like VS Code's "Install 'code' command in PATH").
@MainActor
@Observable
final class CommandLineToolModel {
    enum Status: Equatable {
        case checking
        /// No install found anywhere.
        case notInstalled
        /// Found, but it's a broken link, an older version, or not on PATH.
        case needsAttention(CommandLineToolInstall, reason: String)
        case installed(CommandLineToolInstall)
    }

    private(set) var status: Status = .checking
    private(set) var isWorking = false
    var errorMessage: String?
    private(set) var pathDirectories: [String] = []

    /// The CLI executable shipped with this copy of the app, if any.
    let bundledExecutable: String? = CommandLineToolModel.locateBundledExecutable()

    var canInstall: Bool { bundledExecutable != nil }

    // MARK: Refresh

    func refresh() {
        status = .checking
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> ([String], [CommandLineToolInstall]) in
                let path = CommandLineToolManager.loginShellPath()
                let installs = CommandLineToolManager(pathDirectories: path).findInstalls()
                return (path, installs)
            }.value
            pathDirectories = result.0
            status = Self.status(for: result.1)
        }
    }

    private static func status(for installs: [CommandLineToolInstall]) -> Status {
        // Prefer the copy a shell would actually run.
        guard let primary = installs.first(where: \.isOnPath) ?? installs.first else { return .notInstalled }
        if primary.isBroken {
            return .needsAttention(primary, reason: "The link is broken (was the app moved?).")
        }
        guard let version = primary.version else {
            return .needsAttention(primary, reason: "It couldn't be run.")
        }
        if version != MacSizeInfo.version {
            return .needsAttention(primary, reason: "Version \(version) is installed; this app includes \(MacSizeInfo.version).")
        }
        if !primary.isOnPath {
            return .needsAttention(primary, reason: "\(primary.directory) isn't on your shell's PATH.")
        }
        return .installed(primary)
    }

    // MARK: Actions

    /// Install system-wide in /usr/local/bin (asks for an administrator password if needed).
    func installSystemWide() {
        install(in: CommandLineToolManager.systemDirectory)
    }

    /// Install for the current user in ~/.local/bin (never needs a password).
    func installForCurrentUser() {
        install(in: CommandLineToolManager.userDirectory)
    }

    /// Replace an existing install in place (fixes broken links and old versions).
    func reinstall(_ existing: CommandLineToolInstall) {
        install(in: existing.directory)
    }

    func uninstall(_ install: CommandLineToolInstall) {
        perform {
            let manager = CommandLineToolManager(pathDirectories: [])
            do {
                try manager.uninstall(install)
            } catch where Self.isPermissionError(error) {
                try Self.runPrivileged(["/bin/rm", "-f", install.path])
            }
        }
    }

    private func install(in directory: String) {
        guard let source = bundledExecutable else {
            errorMessage = "This copy of MacSize doesn't include the command-line tool. Build the app with scripts/build-app.sh."
            return
        }
        perform {
            let manager = CommandLineToolManager(pathDirectories: [])
            do {
                try manager.installSymlink(source: source, in: directory)
            } catch where Self.isPermissionError(error) {
                let link = (directory as NSString).appendingPathComponent(MacSizeInfo.commandName)
                try Self.runPrivileged(["/bin/mkdir", "-p", directory], ["/bin/ln", "-sfn", source, link])
            }
        }
    }

    private func perform(_ work: @escaping @Sendable () throws -> Void) {
        isWorking = true
        errorMessage = nil
        Task {
            let failure: String? = await Task.detached(priority: .userInitiated) {
                do {
                    try work()
                    return nil
                } catch CocoaError.userCancelled {
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            isWorking = false
            if let failure { errorMessage = failure }
            refresh()
        }
    }

    func copyPathExport(_ directory: String) {
        let line = "export PATH=\"\(directory):$PATH\""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line, forType: .string)
    }

    // MARK: Helpers

    private nonisolated static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           [NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError].contains(nsError.code) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, [Int(EACCES), Int(EPERM)].contains(underlying.code) {
            return true
        }
        return nsError.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(nsError.code)
    }

    /// Run commands as root via the standard macOS administrator prompt.
    /// Arguments are passed through `argv` and quoted by AppleScript, never
    /// interpolated into the script text.
    private nonisolated static func runPrivileged(_ commands: [String]...) throws {
        var script = ["on run argv", "set cmd to \"\""]
        var argv: [String] = []
        for (index, command) in commands.enumerated() {
            if index > 0 { script.append("set cmd to cmd & \" && \"") }
            for (position, argument) in command.enumerated() {
                argv.append(argument)
                let separator = position == 0 ? "" : " & \" \""
                script.append("set cmd to cmd\(separator) & quoted form of item \(argv.count) of argv")
            }
        }
        script.append("do shell script cmd with administrator privileges")
        script.append("end run")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = script.flatMap { ["-e", $0] } + argv
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if message.contains("-128") {  // User pressed Cancel.
                throw CocoaError(.userCancelled)
            }
            throw CocoaError(.fileWriteNoPermission, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't get administrator access: \(message.trimmingCharacters(in: .whitespacesAndNewlines))",
            ])
        }
    }

    private static func locateBundledExecutable() -> String? {
        let fm = FileManager.default
        var candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(MacSizeInfo.commandName)").path,
        ]
        // `swift run MacSizeApp`: the CLI is built next to the app executable. Only for
        // unbundled runs: inside a .app, MacOS/macsize would case-insensitively match the app binary.
        if Bundle.main.bundleURL.pathExtension != "app", let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent(MacSizeInfo.commandName).path)
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }
}
