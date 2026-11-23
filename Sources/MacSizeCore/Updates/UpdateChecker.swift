import Foundation

/// Downloads the bytes at a URL. Injected so tests never touch the network.
public typealias UpdateFetcher = @Sendable (URL) async throws -> Data

/// The default fetcher: an ephemeral URLSession (no cookies or URL cache) with short timeouts.
public enum URLSessionUpdateFetcher {
    public static func make(timeout: TimeInterval, resourceTimeout: TimeInterval? = nil) -> UpdateFetcher {
        { url in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = resourceTimeout ?? timeout
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpAdditionalHeaders = ["User-Agent": "\(MacSizeInfo.commandName)/\(MacSizeInfo.version)"]
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw UpdateError.httpStatus(http.statusCode, url: url.absoluteString)
            }
            return data
        }
    }
}

/// What the last check found, persisted between runs.
public struct UpdateCheckCache: Codable, Sendable, Equatable {
    /// When a check was last attempted (successful or not). Drives the throttle.
    public var checkedAt: Date
    /// Where the manifest came from; a cache written for another source is ignored.
    public var baseURL: String?
    public var latestVersion: String?
    public var manifest: ReleaseManifest?

    public init(checkedAt: Date, baseURL: String?, latestVersion: String?, manifest: ReleaseManifest?) {
        self.checkedAt = checkedAt
        self.baseURL = baseURL
        self.latestVersion = latestVersion
        self.manifest = manifest
    }

    enum CodingKeys: String, CodingKey {
        case checkedAt = "checked_at"
        case baseURL = "base_url"
        case latestVersion = "latest_version"
        case manifest
    }
}

/// Fetches `latest.json`, caches the result, and throttles background checks.
public struct UpdateChecker: Sendable {
    public static let cacheFileName = "update-check.json"
    public static let defaultCheckInterval: TimeInterval = 24 * 60 * 60

    public var currentVersion: String
    public var baseURL: URL
    public var cacheDirectory: URL
    public var checkInterval: TimeInterval
    public var now: @Sendable () -> Date
    public var fetch: UpdateFetcher

    public init(
        currentVersion: String = MacSizeInfo.version,
        baseURL: URL,
        cacheDirectory: URL = UpdateChecker.defaultCacheDirectory(),
        checkInterval: TimeInterval = UpdateChecker.defaultCheckInterval,
        now: @escaping @Sendable () -> Date = { Date() },
        fetch: @escaping UpdateFetcher
    ) {
        self.currentVersion = currentVersion
        self.baseURL = baseURL
        self.cacheDirectory = cacheDirectory
        self.checkInterval = checkInterval
        self.now = now
        self.fetch = fetch
    }

    /// `$XDG_CACHE_HOME/macsize` if set, else `~/Library/Caches/macsize`.
    public static func defaultCacheDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let xdg = environment["XDG_CACHE_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent(MacSizeInfo.commandName, isDirectory: true)
        }
        return home.appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent(MacSizeInfo.commandName, isDirectory: true)
    }

    public var manifestURL: URL { baseURL.appendingPathComponent("latest.json") }
    public var cacheFile: URL { cacheDirectory.appendingPathComponent(Self.cacheFileName) }

    // MARK: Cache

    public func readCache() -> UpdateCheckCache? {
        guard let data = try? Data(contentsOf: cacheFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let cache = try? decoder.decode(UpdateCheckCache.self, from: data),
              cache.baseURL == nil || cache.baseURL == baseURL.absoluteString
        else { return nil }
        return cache
    }

    func writeCache(_ cache: UpdateCheckCache) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(cache) else { return }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: cacheFile, options: .atomic)
    }

    /// True when no check was attempted within `checkInterval` (or the clock went backwards).
    public func isCheckDue() -> Bool {
        guard let checkedAt = readCache()?.checkedAt else { return true }
        let elapsed = now().timeIntervalSince(checkedAt)
        return elapsed < 0 || elapsed >= checkInterval
    }

    // MARK: Checking

    /// `manifest` if it's newer than the running version.
    public func newer(_ manifest: ReleaseManifest?) -> ReleaseManifest? {
        guard let manifest, SemanticVersion.isNewer(manifest.version, than: currentVersion) else { return nil }
        return manifest
    }

    /// A newer release known from the cache, without touching the network.
    public func cachedUpdate() -> ReleaseManifest? {
        newer(readCache()?.manifest)
    }

    /// Always fetches `latest.json`. On success the result is cached unless `recordInCache` is false.
    public func fetchLatest(recordInCache: Bool = true) async throws -> ReleaseManifest {
        let manifest = try ReleaseManifest.decode(try await fetch(manifestURL))
        if recordInCache {
            writeCache(UpdateCheckCache(
                checkedAt: now(), baseURL: baseURL.absoluteString,
                latestVersion: manifest.version, manifest: manifest
            ))
        }
        return manifest
    }

    /// The throttled background check: fetches at most once per `checkInterval`, otherwise answers
    /// from the cache. Returns a newer release if one is known. Never throws.
    public func checkForUpdate() async -> ReleaseManifest? {
        let cache = readCache()
        if let checkedAt = cache?.checkedAt {
            let elapsed = now().timeIntervalSince(checkedAt)
            if elapsed >= 0 && elapsed < checkInterval { return newer(cache?.manifest) }
        }
        // Record the attempt up front so a failing network doesn't trigger a check on every run.
        writeCache(UpdateCheckCache(
            checkedAt: now(), baseURL: baseURL.absoluteString,
            latestVersion: cache?.latestVersion, manifest: cache?.manifest
        ))
        do {
            return newer(try await fetchLatest())
        } catch {
            return newer(cache?.manifest)
        }
    }
}

/// Wording and suppression rules for the "new version available" line.
public enum UpdateNotice {
    /// What the user should do to update, given how macsize was installed.
    public static func instruction(for mode: InstallMode) -> String {
        switch mode {
        case .appBundle: return "Update MacSize.app (MacSize › Check for Updates…)."
        case .homebrew: return "Run `brew upgrade \(MacSizeInfo.commandName)`."
        case .standalone: return "Run `\(MacSizeInfo.commandName) update` to install."
        }
    }

    public static func message(current: String, latest: String, mode: InstallMode) -> String {
        "A new version of \(MacSizeInfo.commandName) is available: \(current) → \(latest). " + instruction(for: mode)
    }

    /// True when the environment opts out: `CI` is set, or `MACSIZE_NO_UPDATE_NOTIFIER` is non-empty.
    public static func isSuppressed(environment: [String: String]) -> Bool {
        if environment["CI"] != nil { return true }
        if let optOut = environment["MACSIZE_NO_UPDATE_NOTIFIER"], !optOut.isEmpty { return true }
        return false
    }
}
