import Foundation

/// Replaces a standalone `macsize` binary with a verified release.
///
/// Steps: download the tarball into a temp directory next to the binary (same volume, so the
/// final `rename()` is atomic), verify SHA-256 and the Ed25519 signature, extract with
/// `/usr/bin/tar`, check the new binary's `--version`, then rename it over the old one.
public struct SelfUpdater: Sendable {
    public struct Result: Sendable, Equatable {
        public var path: String
        public var oldVersion: String
        public var newVersion: String
    }

    /// Real path of the binary to replace.
    public var executablePath: String
    public var currentVersion: String
    /// Base64 raw Ed25519 public key; `nil` refuses every update.
    public var publicKey: String?
    /// Used to resolve a relative tarball URL in the manifest.
    public var baseURL: URL?
    public var fetch: UpdateFetcher
    /// Runs `<binary> --version` and returns the reported version.
    public var versionProbe: @Sendable (String) -> String?

    public init(
        executablePath: String,
        currentVersion: String = MacSizeInfo.version,
        publicKey: String?,
        baseURL: URL? = nil,
        fetch: @escaping UpdateFetcher,
        versionProbe: @escaping @Sendable (String) -> String? = { CommandLineToolManager.runVersion(executable: $0, timeout: 15) }
    ) {
        self.executablePath = executablePath
        self.currentVersion = currentVersion
        self.publicKey = publicKey
        self.baseURL = baseURL
        self.fetch = fetch
        self.versionProbe = versionProbe
    }

    public func install(_ manifest: ReleaseManifest) async throws -> Result {
        guard publicKey != nil else { throw UpdateError.missingPublicKey }
        guard let url = manifest.cliURL(relativeTo: baseURL) else { throw UpdateError.invalidURL(manifest.cli.url) }

        let directory = (executablePath as NSString).deletingLastPathComponent
        guard access(directory, W_OK) == 0 else { throw UpdateError.directoryNotWritable(directory) }

        let workDirectory = try Self.makeTemporaryDirectory(in: directory)
        defer { try? FileManager.default.removeItem(atPath: workDirectory) }

        let archive = try await fetch(url)
        try UpdateVerifier.verify(archive, sha256: manifest.cli.sha256, signature: manifest.cli.edSignature, publicKey: publicKey)

        let archivePath = (workDirectory as NSString).appendingPathComponent("macsize.tar.gz")
        let extractDirectory = (workDirectory as NSString).appendingPathComponent("extract")
        do {
            try archive.write(to: URL(fileURLWithPath: archivePath))
            try FileManager.default.createDirectory(atPath: extractDirectory, withIntermediateDirectories: false)
        } catch {
            throw UpdateError.extractionFailed(error.localizedDescription)
        }
        try Self.extract(archivePath, into: extractDirectory)

        let newBinary = (extractDirectory as NSString).appendingPathComponent(MacSizeInfo.commandName)
        var info = stat()
        guard lstat(newBinary, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw UpdateError.binaryMissing }
        guard chmod(newBinary, 0o755) == 0 else {
            throw UpdateError.replaceFailed(path: executablePath, reason: String(cString: strerror(errno)))
        }

        let reported = versionProbe(newBinary)
        guard let reported, Self.sameVersion(reported, manifest.version) else {
            throw UpdateError.versionMismatch(expected: manifest.version, actual: reported)
        }

        guard rename(newBinary, executablePath) == 0 else {
            throw UpdateError.replaceFailed(path: executablePath, reason: String(cString: strerror(errno)))
        }
        return Result(path: executablePath, oldVersion: currentVersion, newVersion: manifest.version)
    }

    // MARK: Helpers

    static func sameVersion(_ a: String, _ b: String) -> Bool {
        if let x = SemanticVersion(a), let y = SemanticVersion(b) { return x == y }
        return a == b
    }

    static func makeTemporaryDirectory(in directory: String) throws -> String {
        var template = Array((directory as NSString).appendingPathComponent(".macsize-update-XXXXXX").utf8CString)
        let created = template.withUnsafeMutableBufferPointer { buffer -> String? in
            guard let pointer = mkdtemp(buffer.baseAddress) else { return nil }
            return String(cString: pointer)
        }
        guard let created else { throw UpdateError.temporaryDirectoryFailed(directory) }
        return created
    }

    static func extract(_ archive: String, into directory: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        // bsdtar refuses absolute paths and `..` entries by default.
        process.arguments = ["-xzf", archive, "-C", directory]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        do { try process.run() } catch { throw UpdateError.extractionFailed(error.localizedDescription) }
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.extractionFailed(detail.isEmpty ? "tar exited with status \(process.terminationStatus)" : detail)
        }
    }
}
