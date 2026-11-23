import Darwin
import Foundation
import MacSizeCore

/// Where updates come from. Release builds get these from `BuildInfo` (stamped by CI);
/// source builds have none, which disables update checks entirely.
struct UpdateConfiguration {
    var baseURL: URL
    var publicKey: String?

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> UpdateConfiguration? {
        var base = BuildInfo.releaseBaseURL
        var key = BuildInfo.updatePublicEDKey
        #if DEBUG
        // Development only (compiled out of release builds): point at a local server, e.g.
        // `python3 -m http.server` serving a hand-written latest.json. See docs/CLI-UPDATES.md.
        if let override = environment["MACSIZE_UPDATE_BASE_URL"], !override.isEmpty { base = override }
        if let override = environment["MACSIZE_UPDATE_PUBLIC_ED_KEY"], !override.isEmpty { key = override }
        #endif
        guard let base, let url = URL(string: base), url.scheme != nil, url.host != nil else { return nil }
        return UpdateConfiguration(baseURL: url, publicKey: key)
    }
}

/// gh-style "a new version is available" notice. The check runs concurrently with the command;
/// at exit we wait at most ~300 ms for it, then fall back to whatever the cache already knows.
/// Every failure is swallowed: the notifier must never slow down or break a command.
final class UpdateNotifier: @unchecked Sendable {
    static let exitWait: DispatchTimeInterval = .milliseconds(300)

    private let checker: UpdateChecker
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var fresh: ReleaseManifest?

    private init(checker: UpdateChecker) {
        self.checker = checker
    }

    static func start(for args: Arguments, environment: [String: String] = ProcessInfo.processInfo.environment) -> UpdateNotifier? {
        switch args.command {
        case .help, .version, .update, .cache: return nil
        case .scan, .largest, .types, .bench: break
        }
        guard !args.json,
              isatty(STDERR_FILENO) == 1,
              !UpdateNotice.isSuppressed(environment: environment),
              let configuration = UpdateConfiguration.resolve(environment: environment)
        else { return nil }

        let checker = UpdateChecker(
            baseURL: configuration.baseURL,
            cacheDirectory: UpdateChecker.defaultCacheDirectory(environment: environment),
            fetch: URLSessionUpdateFetcher.make(timeout: 3)
        )
        let notifier = UpdateNotifier(checker: checker)
        Task.detached(priority: .utility) {
            let result = await checker.checkForUpdate()
            notifier.lock.withLock { notifier.fresh = result }
            notifier.done.signal()
        }
        return notifier
    }

    func finish() {
        let latest: ReleaseManifest?
        if done.wait(timeout: .now() + Self.exitWait) == .success {
            latest = lock.withLock { fresh }
        } else {
            latest = checker.cachedUpdate()
        }
        guard let latest else { return }
        let line = UpdateNotice.message(current: checker.currentVersion, latest: latest.version, mode: InstallMode.current())
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

/// `macsize update [--check]`.
enum UpdateCommand {
    static func run(checkOnly: Bool) throws {
        let current = MacSizeInfo.version
        guard let configuration = UpdateConfiguration.resolve() else {
            print("""
            Update checks are disabled in source builds of \(MacSizeInfo.commandName) (\(current)).
            To update, pull the latest source and rebuild, or install a release build.
            """)
            return
        }

        let mode = InstallMode.current()
        // Under sudo, don't leave a root-owned cache file in the user's cache directory.
        let recordInCache = geteuid() != 0
        let checker = UpdateChecker(baseURL: configuration.baseURL, fetch: URLSessionUpdateFetcher.make(timeout: 15))

        if checkOnly {
            let manifest = try blocking { try await checker.fetchLatest(recordInCache: recordInCache) }
            if let newer = checker.newer(manifest) {
                print(UpdateNotice.message(current: current, latest: newer.version, mode: mode))
            } else {
                print("\(MacSizeInfo.commandName) \(current) is up to date")
            }
            return
        }

        switch mode {
        case .appBundle(let appPath):
            print("""
            This \(MacSizeInfo.commandName) is part of MacSize.app (\(appPath)).
            The app keeps its command-line tool up to date: choose MacSize › Check for Updates… in the app.
            """)
            if !openApp(at: appPath) {
                print("Couldn't open MacSize.app; open it yourself to check for updates.")
            }

        case .homebrew:
            throw CLIError("\(MacSizeInfo.commandName) was installed with Homebrew. To update it, run:\n  brew upgrade \(MacSizeInfo.commandName)")

        case .standalone(let path):
            let manifest = try blocking { try await checker.fetchLatest(recordInCache: recordInCache) }
            guard checker.newer(manifest) != nil else {
                print("\(MacSizeInfo.commandName) \(current) is up to date")
                return
            }
            guard configuration.publicKey != nil else { throw UpdateError.missingPublicKey }
            let directory = (path as NSString).deletingLastPathComponent
            guard access(directory, W_OK) == 0 else { throw UpdateError.directoryNotWritable(directory) }
            print("Updating \(MacSizeInfo.commandName) \(current) → \(manifest.version)…")
            fflush(stdout)
            let updater = SelfUpdater(
                executablePath: path,
                currentVersion: current,
                publicKey: configuration.publicKey,
                baseURL: configuration.baseURL,
                fetch: URLSessionUpdateFetcher.make(timeout: 30, resourceTimeout: 600)
            )
            let result = try blocking { try await updater.install(manifest) }
            print("Updated \(MacSizeInfo.commandName) \(result.oldVersion) → \(result.newVersion) (\(result.path))")
        }
    }

    /// `open -b <bundle id>`, falling back to the app path.
    static func openApp(at appPath: String) -> Bool {
        if let bundleIdentifier = BuildInfo.bundleIdentifier, launch("/usr/bin/open", ["-b", bundleIdentifier]) {
            return true
        }
        return launch("/usr/bin/open", [appPath])
    }

    static func launch(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

/// Runs async work from the synchronous CLI entry point.
func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let box = BlockingResult<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
        done.signal()
    }
    done.wait()
    return try box.result!.get()
}

private final class BlockingResult<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}
