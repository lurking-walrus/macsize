import CryptoKit
import Darwin
import Foundation
import Testing
@testable import MacSizeCore

// MARK: - Helpers

/// Mutable state shared with @Sendable fetcher/clock closures.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

private struct FakeNetworkError: Error {}

private let baseURL = URL(string: "https://updates.example.test/releases")!

private func manifest(_ version: String, url: String = "https://updates.example.test/releases/macsize.tar.gz",
                      sha256: String = "00", signature: String = "") -> ReleaseManifest {
    ReleaseManifest(
        version: version, build: "1", publishedAt: "2026-11-01T12:00:00Z",
        cli: .init(url: url, sha256: sha256, edSignature: signature),
        app: .init(url: "https://updates.example.test/MacSize.zip", dmgURL: nil)
    )
}

private func encode(_ manifest: ReleaseManifest) throws -> Data {
    try JSONEncoder().encode(manifest)
}

private func run(_ executable: String, _ arguments: [String], in directory: String? = nil) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

private func writeScript(_ path: String, printing output: String) throws {
    try "#!/bin/sh\necho \"\(output)\"\n".write(toFile: path, atomically: true, encoding: .utf8)
    chmod(path, 0o755)
}

private func inode(_ path: String) -> UInt64 {
    var info = stat()
    stat(path, &info)
    return UInt64(info.st_ino)
}

private func mode(_ path: String) -> mode_t {
    var info = stat()
    stat(path, &info)
    return info.st_mode & 0o7777
}

// MARK: - Versions

@Suite struct SemanticVersionTests {
    @Test func parses() {
        #expect(SemanticVersion("1.2.3") == SemanticVersion(major: 1, minor: 2, patch: 3))
        #expect(SemanticVersion("v0.2.0") == SemanticVersion(major: 0, minor: 2, patch: 0))
        #expect(SemanticVersion("1.2") == SemanticVersion(major: 1, minor: 2, patch: 0))
        #expect(SemanticVersion("1.0.0-rc.1+sha.abc")?.prerelease == ["rc", "1"])
        #expect(SemanticVersion("0.0.0-dev")?.isPrerelease == true)
        #expect(SemanticVersion("") == nil)
        #expect(SemanticVersion("1.2.3.4") == nil)
        #expect(SemanticVersion("1.x.3") == nil)
        #expect(SemanticVersion("1.2.3-") == nil)
        #expect(SemanticVersion("1.2.3-rc..1") == nil)
    }

    @Test func ordersNumericallyNotLexically() throws {
        #expect(try #require(SemanticVersion("0.9.0")) < #require(SemanticVersion("0.10.0")))
        #expect(try #require(SemanticVersion("1.9.9")) < #require(SemanticVersion("2.0.0")))
        #expect(try #require(SemanticVersion("1.2.3")) == #require(SemanticVersion("1.2.3+build.7")))
    }

    @Test func prereleasesOrderBelowTheRelease() throws {
        // The semver 2.0 example chain.
        let chain = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
                     "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"]
        let versions = try chain.map { try #require(SemanticVersion($0)) }
        for (lower, higher) in zip(versions, versions.dropFirst()) {
            #expect(lower < higher, "\(lower) < \(higher)")
            #expect(!(higher < lower))
        }
        #expect(versions.shuffled().sorted() == versions)
    }

    @Test func isNewer() {
        #expect(SemanticVersion.isNewer("0.2.0", than: "0.1.0"))
        #expect(SemanticVersion.isNewer("0.1.0", than: "0.1.0-rc.2"))
        #expect(SemanticVersion.isNewer("0.0.1", than: "0.0.0-dev"))
        #expect(!SemanticVersion.isNewer("0.1.0", than: "0.1.0"))
        #expect(!SemanticVersion.isNewer("0.1.0-rc.1", than: "0.1.0"))
        #expect(!SemanticVersion.isNewer("0.1.0", than: "0.2.0"))
        #expect(!SemanticVersion.isNewer("garbage", than: "0.1.0"))
        #expect(!SemanticVersion.isNewer("9.9.9", than: "garbage"))
    }
}

// MARK: - Manifest

@Suite struct ReleaseManifestTests {
    @Test func decodesTheReleaseContract() throws {
        let json = """
        {"version":"0.2.0","build":"57","published_at":"2026-11-20T18:30:00Z",
         "cli":{"url":"https://example.test/download/macsize-0.2.0-macos-universal.tar.gz",
                "sha256":"ab12","ed_signature":"c2lnbmF0dXJl"},
         "app":{"url":"https://example.test/download/MacSize-0.2.0.zip",
                "dmg_url":"https://example.test/download/MacSize-0.2.0.dmg"}}
        """
        let manifest = try ReleaseManifest.decode(Data(json.utf8))
        #expect(manifest.version == "0.2.0")
        #expect(manifest.build == "57")
        #expect(manifest.cli.url.hasSuffix("macsize-0.2.0-macos-universal.tar.gz"))
        #expect(manifest.cli.sha256 == "ab12")
        #expect(manifest.cli.edSignature == "c2lnbmF0dXJl")
        #expect(manifest.app?.dmgURL == "https://example.test/download/MacSize-0.2.0.dmg")
        #expect(manifest.publishedDate == ISO8601DateFormatter().date(from: "2026-11-20T18:30:00Z"))

        // Round-trips through the same snake_case keys.
        let reencoded = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(manifest)) as? [String: Any]
        #expect(reencoded?["published_at"] as? String == "2026-11-20T18:30:00Z")
        #expect((reencoded?["cli"] as? [String: Any])?["ed_signature"] as? String == "c2lnbmF0dXJl")
        #expect(try ReleaseManifest.decode(try JSONEncoder().encode(manifest)) == manifest)
    }

    @Test func toleratesNumericBuildAndMissingApp() throws {
        let json = #"{"version":"1.0.0","build":3,"cli":{"url":"x.tar.gz","sha256":"00","ed_signature":"AA=="}}"#
        let manifest = try ReleaseManifest.decode(Data(json.utf8))
        #expect(manifest.build == "3")
        #expect(manifest.app == nil)
        // Relative URLs resolve against the release base URL.
        #expect(manifest.cliURL(relativeTo: baseURL)?.absoluteString == "https://updates.example.test/releases/x.tar.gz")
    }

    @Test func rejectsMissingCLIAsset() {
        #expect(throws: (any Error).self) { try ReleaseManifest.decode(Data(#"{"version":"1.0.0","build":"1"}"#.utf8)) }
    }

    @Test func rejectsNonHTTPDownloadURLs() {
        #expect(manifest("1.0.0", url: "file:///etc/passwd").cliURL() == nil)
        #expect(manifest("1.0.0", url: "ftp://example.test/macsize.tar.gz").cliURL() == nil)
    }
}

// MARK: - Install mode

@Suite struct InstallModeTests {
    @Test(arguments: [
        ("/Applications/MacSize.app/Contents/Helpers/macsize", InstallMode.appBundle("/Applications/MacSize.app")),
        ("/Users/me/Applications/MacSize Beta.app/Contents/Helpers/macsize",
         .appBundle("/Users/me/Applications/MacSize Beta.app")),
        ("/opt/homebrew/Cellar/macsize/0.2.0/bin/macsize", .homebrew),
        ("/usr/local/Cellar/macsize/0.2.0/bin/macsize", .homebrew),
        ("/opt/homebrew/Caskroom/macsize/0.2.0/MacSize.app/Contents/MacOS/macsize", .homebrew),
        ("/opt/homebrew/bin/macsize", .homebrew),
        ("/home/linuxbrew/.linuxbrew/Cellar/macsize/1.0/bin/macsize", .homebrew),
        ("/usr/local/bin/macsize", .standalone("/usr/local/bin/macsize")),
        ("/Users/me/.local/bin/macsize", .standalone("/Users/me/.local/bin/macsize")),
        // Not in Helpers/, so not owned by the app's updater.
        ("/Applications/MacSize.app/Contents/MacOS/macsize", .standalone("/Applications/MacSize.app/Contents/MacOS/macsize")),
        ("/tmp/Helpers/macsize", .standalone("/tmp/Helpers/macsize")),
    ])
    func detects(path: String, expected: InstallMode) {
        #expect(InstallMode.detect(executablePath: path) == expected)
    }

    @Test func caskInstalledAppStillCountsAsTheApp() {
        // A cask puts the app in /Applications, so the helper inside it is the app's to update.
        #expect(InstallMode.detect(executablePath: "/opt/homebrew/Caskroom/macsize/1.0/MacSize.app/Contents/Helpers/macsize")
            == .appBundle("/opt/homebrew/Caskroom/macsize/1.0/MacSize.app"))
    }

    @Test func currentExecutableResolvesToARealPath() {
        let path = InstallMode.currentExecutablePath()
        #expect(path.hasPrefix("/"))
        #expect(FileManager.default.fileExists(atPath: path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == nil)
    }
}

// MARK: - Notice

@Suite struct UpdateNoticeTests {
    @Test func wordingDependsOnInstallMode() {
        #expect(UpdateNotice.message(current: "0.1.0", latest: "0.2.0", mode: .standalone("/usr/local/bin/macsize"))
            == "A new version of macsize is available: 0.1.0 → 0.2.0. Run `macsize update` to install.")
        #expect(UpdateNotice.message(current: "0.1.0", latest: "0.2.0", mode: .appBundle("/Applications/MacSize.app"))
            .hasSuffix("Update MacSize.app (MacSize › Check for Updates…)."))
        #expect(UpdateNotice.message(current: "0.1.0", latest: "0.2.0", mode: .homebrew)
            .hasSuffix("Run `brew upgrade macsize`."))
    }

    @Test func environmentOptOuts() {
        #expect(!UpdateNotice.isSuppressed(environment: [:]))
        #expect(UpdateNotice.isSuppressed(environment: ["CI": "true"]))
        #expect(UpdateNotice.isSuppressed(environment: ["CI": ""]))
        #expect(UpdateNotice.isSuppressed(environment: ["MACSIZE_NO_UPDATE_NOTIFIER": "1"]))
        #expect(!UpdateNotice.isSuppressed(environment: ["MACSIZE_NO_UPDATE_NOTIFIER": ""]))
    }
}

// MARK: - Checker and throttling

@Suite struct UpdateCheckerTests {
    @Test func cacheDirectoryRespectsXDG() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(UpdateChecker.defaultCacheDirectory(environment: [:], home: home).path
            == "/Users/someone/Library/Caches/macsize")
        #expect(UpdateChecker.defaultCacheDirectory(environment: ["XDG_CACHE_HOME": "/tmp/xdg"], home: home).path
            == "/tmp/xdg/macsize")
        #expect(UpdateChecker.defaultCacheDirectory(environment: ["XDG_CACHE_HOME": ""], home: home).path
            == "/Users/someone/Library/Caches/macsize")
    }

    @Test func throttlesToOncePerInterval() async throws {
        let fx = try Fixture()
        let clock = Box(Date(timeIntervalSince1970: 1_800_000_000))
        let fetches = Box(0)
        let served = Box(manifest("0.2.0"))
        let requested = Box<URL?>(nil)
        let checker = UpdateChecker(
            currentVersion: "0.1.0", baseURL: baseURL, cacheDirectory: fx.root,
            now: { clock.value },
            fetch: { url in
                fetches.value += 1
                requested.value = url
                return try encode(served.value)
            }
        )

        #expect(checker.isCheckDue())
        #expect(await checker.checkForUpdate()?.version == "0.2.0")
        #expect(fetches.value == 1)
        #expect(requested.value?.absoluteString == "https://updates.example.test/releases/latest.json")
        #expect(FileManager.default.fileExists(atPath: fx.root.appendingPathComponent("update-check.json").path))

        // Within 24h: answered from the cache, no network, even though the server moved on.
        served.value = manifest("0.3.0")
        clock.value += 23 * 3600
        #expect(!checker.isCheckDue())
        #expect(await checker.checkForUpdate()?.version == "0.2.0")
        #expect(checker.cachedUpdate()?.version == "0.2.0")
        #expect(fetches.value == 1)

        // After 24h: fetches again.
        clock.value += 2 * 3600
        #expect(checker.isCheckDue())
        #expect(await checker.checkForUpdate()?.version == "0.3.0")
        #expect(fetches.value == 2)

        // A clock that jumped backwards counts as due rather than suppressing checks forever.
        clock.value -= 48 * 3600
        #expect(checker.isCheckDue())
    }

    @Test func cacheContainsCheckedAtVersionAndManifest() async throws {
        let fx = try Fixture()
        let checker = UpdateChecker(
            currentVersion: "0.1.0", baseURL: baseURL, cacheDirectory: fx.root,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            fetch: { _ in try encode(manifest("0.2.0")) }
        )
        _ = await checker.checkForUpdate()
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: checker.cacheFile)) as? [String: Any]
        #expect(json?["checked_at"] as? String == "2027-01-15T08:00:00Z")
        #expect(json?["latest_version"] as? String == "0.2.0")
        #expect((json?["manifest"] as? [String: Any])?["version"] as? String == "0.2.0")
    }

    @Test func noNoticeWhenUpToDate() async throws {
        let fx = try Fixture()
        let checker = UpdateChecker(
            currentVersion: "0.2.0", baseURL: baseURL, cacheDirectory: fx.root,
            fetch: { _ in try encode(manifest("0.2.0")) }
        )
        #expect(await checker.checkForUpdate() == nil)
        #expect(checker.cachedUpdate() == nil)
    }

    @Test func failedCheckIsThrottledAndKeepsPreviousResult() async throws {
        let fx = try Fixture()
        let clock = Box(Date(timeIntervalSince1970: 1_800_000_000))
        let fetches = Box(0)
        let failing = Box(false)
        let checker = UpdateChecker(
            currentVersion: "0.1.0", baseURL: baseURL, cacheDirectory: fx.root, now: { clock.value },
            fetch: { _ in
                fetches.value += 1
                if failing.value { throw FakeNetworkError() }
                return try encode(manifest("0.2.0"))
            }
        )
        _ = await checker.checkForUpdate()
        failing.value = true
        clock.value += 25 * 3600
        // The fetch fails, but the previously known release is still reported…
        #expect(await checker.checkForUpdate()?.version == "0.2.0")
        #expect(fetches.value == 2)
        // …and the failure counts as an attempt, so the next run doesn't hit the network again.
        #expect(await checker.checkForUpdate()?.version == "0.2.0")
        #expect(fetches.value == 2)
    }

    @Test func ignoresCacheFromAnotherSourceAndCorruptCache() async throws {
        let fx = try Fixture()
        let other = UpdateChecker(
            currentVersion: "0.1.0", baseURL: URL(string: "http://localhost:8000")!, cacheDirectory: fx.root,
            fetch: { _ in try encode(manifest("9.9.9")) }
        )
        _ = await other.checkForUpdate()
        let checker = UpdateChecker(
            currentVersion: "0.1.0", baseURL: baseURL, cacheDirectory: fx.root,
            fetch: { _ in throw FakeNetworkError() }
        )
        #expect(checker.cachedUpdate() == nil)
        #expect(checker.isCheckDue())

        try Data("not json".utf8).write(to: checker.cacheFile)
        #expect(checker.readCache() == nil)
        #expect(await checker.checkForUpdate() == nil)
    }
}

// MARK: - Signatures

@Suite struct UpdateVerifierTests {
    let key = Curve25519.Signing.PrivateKey()
    let payload = Data("macsize release tarball bytes".utf8)
    var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

    @Test func acceptsValidSignatureAndChecksum() throws {
        let signature = try key.signature(for: payload).base64EncodedString()
        let sha = UpdateVerifier.sha256Hex(payload)
        #expect(sha.count == 64)
        try UpdateVerifier.verify(payload, sha256: sha, signature: signature, publicKey: publicKey)
        // Uppercase hex is accepted too.
        try UpdateVerifier.verify(payload, sha256: sha.uppercased(), signature: signature, publicKey: publicKey)
    }

    @Test func rejectsSignatureFromAnotherKey() throws {
        let signature = try Curve25519.Signing.PrivateKey().signature(for: payload).base64EncodedString()
        #expect(throws: UpdateError.signatureInvalid) {
            try UpdateVerifier.verify(payload, sha256: UpdateVerifier.sha256Hex(payload), signature: signature, publicKey: publicKey)
        }
    }

    @Test func rejectsTamperedBytes() throws {
        let signature = try key.signature(for: payload).base64EncodedString()
        var tampered = payload
        tampered[0] ^= 0xFF
        // Checksum catches it first…
        #expect(throws: UpdateError.checksumMismatch(expected: UpdateVerifier.sha256Hex(payload), actual: UpdateVerifier.sha256Hex(tampered))) {
            try UpdateVerifier.verify(tampered, sha256: UpdateVerifier.sha256Hex(payload), signature: signature, publicKey: publicKey)
        }
        // …and the signature catches it even if the manifest's checksum was swapped too.
        #expect(throws: UpdateError.signatureInvalid) {
            try UpdateVerifier.verify(tampered, sha256: UpdateVerifier.sha256Hex(tampered), signature: signature, publicKey: publicKey)
        }
    }

    @Test func rejectsMissingOrMalformedKeysAndSignatures() throws {
        let signature = try key.signature(for: payload).base64EncodedString()
        let sha = UpdateVerifier.sha256Hex(payload)
        #expect(throws: UpdateError.missingPublicKey) {
            try UpdateVerifier.verify(payload, sha256: sha, signature: signature, publicKey: nil)
        }
        #expect(throws: UpdateError.invalidPublicKey) {
            try UpdateVerifier.verify(payload, sha256: sha, signature: signature, publicKey: "not base64!")
        }
        #expect(throws: UpdateError.invalidPublicKey) {
            try UpdateVerifier.verify(payload, sha256: sha, signature: signature, publicKey: Data([1, 2, 3]).base64EncodedString())
        }
        #expect(throws: UpdateError.invalidSignatureEncoding) {
            try UpdateVerifier.verify(payload, sha256: sha, signature: "%%%", publicKey: publicKey)
        }
    }
}

// MARK: - End-to-end standalone update

@Suite struct SelfUpdaterTests {
    /// A release tarball whose single top-level `macsize` is a shell script printing `macsize <version>`.
    struct Release {
        let data: Data
        let manifest: ReleaseManifest
        let publicKey: String
    }

    static func makeRelease(in fx: Fixture, reportedVersion: String = "9.9.9", manifestVersion: String = "9.9.9",
                            binaryName: String = "macsize") throws -> Release {
        let staging = fx.root.appendingPathComponent("staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try writeScript(staging.appendingPathComponent(binaryName).path, printing: "macsize \(reportedVersion)")
        let tarball = fx.root.appendingPathComponent("release-\(UUID().uuidString).tar.gz")
        try run("/usr/bin/tar", ["-czf", tarball.path, "-C", staging.path, binaryName])
        let data = try Data(contentsOf: tarball)

        let key = Curve25519.Signing.PrivateKey()
        let manifest = manifest(
            manifestVersion,
            url: "https://updates.example.test/releases/macsize-\(manifestVersion)-macos-universal.tar.gz",
            sha256: UpdateVerifier.sha256Hex(data),
            signature: try key.signature(for: data).base64EncodedString()
        )
        return Release(data: data, manifest: manifest, publicKey: key.publicKey.rawRepresentation.base64EncodedString())
    }

    /// An "installed" macsize 0.1.0 in its own bin directory.
    static func makeInstall(in fx: Fixture) throws -> String {
        let bin = fx.root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let path = bin.appendingPathComponent("macsize").path
        try writeScript(path, printing: "macsize 0.1.0")
        chmod(path, 0o700)
        return path
    }

    static func updater(_ path: String, _ release: Release, publicKey: String?? = .none, data: Data? = nil,
                        requested: Box<URL?>? = nil) -> SelfUpdater {
        let served = data ?? release.data
        return SelfUpdater(
            executablePath: path, currentVersion: "0.1.0",
            publicKey: publicKey ?? release.publicKey,
            baseURL: baseURL,
            fetch: { url in
                requested?.value = url
                return served
            }
        )
    }

    @Test func replacesTheBinaryAtomically() async throws {
        let fx = try Fixture()
        let release = try Self.makeRelease(in: fx)
        let path = try Self.makeInstall(in: fx)
        let oldInode = inode(path)
        let requested = Box<URL?>(nil)

        let result = try await Self.updater(path, release, requested: requested).install(release.manifest)

        #expect(result == SelfUpdater.Result(path: path, oldVersion: "0.1.0", newVersion: "9.9.9"))
        #expect(requested.value?.lastPathComponent == "macsize-9.9.9-macos-universal.tar.gz")
        #expect(CommandLineToolManager.runVersion(executable: path) == "9.9.9")
        // rename() swaps in a new inode instead of rewriting the old file in place.
        #expect(inode(path) != oldInode)
        #expect(mode(path) == 0o755)
        // The temp directory next to the binary is cleaned up.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: (path as NSString).deletingLastPathComponent)
        #expect(leftovers == ["macsize"])
    }

    @Test func refusesTamperedDownloadAndLeavesBinaryUntouched() async throws {
        let fx = try Fixture()
        let release = try Self.makeRelease(in: fx)
        let path = try Self.makeInstall(in: fx)
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        var tampered = release.data
        tampered[tampered.count - 1] ^= 0x01

        await #expect(throws: UpdateError.self) {
            try await Self.updater(path, release, data: tampered).install(release.manifest)
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: (path as NSString).deletingLastPathComponent) == ["macsize"])
    }

    @Test func refusesWhenSignedByAnotherKey() async throws {
        let fx = try Fixture()
        let release = try Self.makeRelease(in: fx)
        let path = try Self.makeInstall(in: fx)
        let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        await #expect(throws: UpdateError.signatureInvalid) {
            try await Self.updater(path, release, publicKey: otherKey).install(release.manifest)
        }
        #expect(CommandLineToolManager.runVersion(executable: path) == "0.1.0")
    }

    @Test func refusesWithoutPublicKey() async throws {
        let fx = try Fixture()
        let release = try Self.makeRelease(in: fx)
        let path = try Self.makeInstall(in: fx)
        let fetched = Box(false)
        let updater = SelfUpdater(
            executablePath: path, currentVersion: "0.1.0", publicKey: nil,
            fetch: { _ in fetched.value = true; return release.data }
        )
        await #expect(throws: UpdateError.missingPublicKey) { try await updater.install(release.manifest) }
        #expect(!fetched.value) // refused before downloading anything
        #expect(CommandLineToolManager.runVersion(executable: path) == "0.1.0")
    }

    @Test func refusesWhenBinaryReportsAnotherVersion() async throws {
        let fx = try Fixture()
        let release = try Self.makeRelease(in: fx, reportedVersion: "9.9.8", manifestVersion: "9.9.9")
        let path = try Self.makeInstall(in: fx)
        await #expect(throws: UpdateError.versionMismatch(expected: "9.9.9", actual: "9.9.8")) {
            try await Self.updater(path, release).install(release.manifest)
        }
        #expect(CommandLineToolManager.runVersion(executable: path) == "0.1.0")
    }

    @Test func refusesArchiveWithoutMacsize() async throws {
        let fx = try Fixture()
        let release = try Self.makeRelease(in: fx, binaryName: "something-else")
        let path = try Self.makeInstall(in: fx)
        await #expect(throws: UpdateError.binaryMissing) {
            try await Self.updater(path, release).install(release.manifest)
        }
    }

    @Test func failsClearlyWhenDirectoryIsNotWritable() async throws {
        let fx = try Fixture()
        let release = try Self.makeRelease(in: fx)
        let path = try Self.makeInstall(in: fx)
        let directory = (path as NSString).deletingLastPathComponent
        chmod(directory, 0o555)
        defer { chmod(directory, 0o755) }
        guard access(directory, W_OK) != 0 else { return } // running as root; nothing to test

        let error = await #expect(throws: UpdateError.directoryNotWritable(directory)) {
            try await Self.updater(path, release).install(release.manifest)
        }
        #expect(error?.description.contains("sudo macsize update") == true)
    }
}
