import Foundation

/// Product-wide constants shared by the app and the CLI.
public enum MacSizeInfo {
    /// Version reported by `macsize --version` and compared by the app.
    public static let version = "0.1.0"
    /// Name of the command-line executable.
    public static let commandName = "macsize"
}

/// One `macsize` executable found on disk.
public struct CommandLineToolInstall: Sendable, Equatable {
    /// Where it was found, e.g. `/usr/local/bin/macsize`.
    public var path: String
    /// Where a symlink points (fully resolved), or `path` for a regular file.
    public var resolvedPath: String
    public var isSymlink: Bool
    /// A symlink whose target no longer exists (e.g. the app was moved or deleted).
    public var isBroken: Bool
    /// Version parsed from `--version`, if it ran successfully.
    public var version: String?
    /// Whether the containing directory is on the user's shell PATH.
    public var isOnPath: Bool

    public var directory: String { (path as NSString).deletingLastPathComponent }
}

/// Finds, installs and removes the `macsize` command-line tool.
///
/// Installs are symlinks to the executable bundled inside the app, so updating
/// the app automatically updates the command.
public struct CommandLineToolManager: Sendable {
    /// System-wide location; on PATH by default on macOS via /etc/paths.
    public static let systemDirectory = "/usr/local/bin"
    /// Per-user location that doesn't need administrator rights.
    public static var userDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
    }

    /// Common install locations checked in addition to the user's PATH.
    public static var wellKnownDirectories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [systemDirectory, "/opt/homebrew/bin", userDirectory, home + "/bin"]
    }

    public var commandName: String
    /// Directories on the user's PATH, in order.
    public var pathDirectories: [String]

    public init(commandName: String = MacSizeInfo.commandName, pathDirectories: [String]) {
        self.commandName = commandName
        self.pathDirectories = pathDirectories.map(Self.standardize)
    }

    // MARK: Discovery

    /// All installs found in PATH order first, then other well-known locations.
    /// The first element is the one a shell would run (if it is on PATH).
    public func findInstalls(extraDirectories: [String] = Self.wellKnownDirectories) -> [CommandLineToolInstall] {
        var seen = Set<String>()
        var results: [CommandLineToolInstall] = []
        for directory in (pathDirectories + extraDirectories.map(Self.standardize)) where seen.insert(directory).inserted {
            if let install = inspect(directory: directory) {
                results.append(install)
            }
        }
        return results
    }

    public func inspect(directory: String) -> CommandLineToolInstall? {
        let path = (directory as NSString).appendingPathComponent(commandName)
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: path) else { return nil }
        let isSymlink = (attributes[.type] as? FileAttributeType) == .typeSymbolicLink
        let resolved = isSymlink ? Self.resolveSymlink(path) : path
        let isBroken = isSymlink && !fm.fileExists(atPath: resolved)
        let version = isBroken ? nil : Self.runVersion(executable: path)
        return CommandLineToolInstall(
            path: path,
            resolvedPath: resolved,
            isSymlink: isSymlink,
            isBroken: isBroken,
            version: version,
            isOnPath: pathDirectories.contains(Self.standardize(directory))
        )
    }

    // MARK: Install / uninstall (no privilege escalation)

    /// Create or replace `directory/commandName` as a symlink to `source`.
    /// Throws if the directory isn't writable; callers can then escalate.
    public func installSymlink(source: String, in directory: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let link = (directory as NSString).appendingPathComponent(commandName)
        if (try? fm.attributesOfItem(atPath: link)) != nil {
            try fm.removeItem(atPath: link)
        }
        try fm.createSymbolicLink(atPath: link, withDestinationPath: source)
    }

    /// Remove an install, refusing anything that doesn't look like ours.
    public func uninstall(_ install: CommandLineToolInstall) throws {
        guard install.isBroken || install.version != nil else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [
                NSLocalizedDescriptionKey: "\(install.path) doesn't look like the \(commandName) tool; not removing it.",
            ])
        }
        try FileManager.default.removeItem(atPath: install.path)
    }

    // MARK: Helpers

    /// Parse `macsize 1.2.3` → `1.2.3`.
    public static func parseVersion(_ output: String, commandName: String = MacSizeInfo.commandName) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ")
            if parts.count >= 2, parts[0] == commandName { return String(parts[1]) }
        }
        return nil
    }

    /// Run `executable --version` with a short timeout.
    public static func runVersion(executable: String, timeout: TimeInterval = 3) -> String? {
        guard let output = run(executable, arguments: ["--version"], timeout: timeout) else { return nil }
        return parseVersion(output)
    }

    /// Ask the user's login shell for its PATH (apps launched from Finder get a
    /// minimal PATH that doesn't reflect what Terminal uses).
    public static func loginShellPath(timeout: TimeInterval = 4) -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let marker = "__MACSIZE_PATH__"
        let output = run(shell, arguments: ["-ilc", "printf '\(marker)%s' \"$PATH\""], timeout: timeout) ?? ""
        let value: String
        if let range = output.range(of: marker, options: .backwards) {
            value = String(output[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            value = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        }
        return value.split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }

    static func run(_ executable: String, arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // Drain output concurrently so a chatty process can't block on a full pipe.
        let collected = OutputBuffer()
        let reader = output.fileHandleForReading
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            collected.data = reader.readDataToEndOfFile()
            done.signal()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard done.wait(timeout: .now() + 1) == .success else { return nil }
        return String(decoding: collected.data, as: UTF8.self)
    }

    private final class OutputBuffer: @unchecked Sendable {
        var data = Data()
    }

    static func resolveSymlink(_ path: String) -> String {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return path }
        let absolute = destination.hasPrefix("/")
            ? destination
            : ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(destination)
        return standardize(absolute)
    }

    static func standardize(_ path: String) -> String {
        var result = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        return result
    }
}
