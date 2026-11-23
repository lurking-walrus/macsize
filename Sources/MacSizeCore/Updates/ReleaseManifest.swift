import Foundation

/// `latest.json`, published by the release pipeline at `<BuildInfo.releaseBaseURL>/latest.json`.
///
/// ```json
/// {"version":"X.Y.Z","build":"N","published_at":"ISO8601",
///  "cli":{"url":"…/macsize-X.Y.Z-macos-universal.tar.gz","sha256":"<hex>","ed_signature":"<base64>"},
///  "app":{"url":"…/MacSize-X.Y.Z.zip","dmg_url":"…/MacSize-X.Y.Z.dmg"}}
/// ```
public struct ReleaseManifest: Codable, Sendable, Equatable {
    /// The command-line tarball: a single top-level `macsize` binary.
    public struct CLIAsset: Codable, Sendable, Equatable {
        public var url: String
        /// Lowercase hex SHA-256 of the tarball bytes.
        public var sha256: String
        /// Base64 Ed25519 signature over the raw tarball bytes.
        public var edSignature: String

        public init(url: String, sha256: String, edSignature: String) {
            self.url = url
            self.sha256 = sha256
            self.edSignature = edSignature
        }

        enum CodingKeys: String, CodingKey {
            case url, sha256
            case edSignature = "ed_signature"
        }
    }

    public struct AppAsset: Codable, Sendable, Equatable {
        public var url: String
        public var dmgURL: String?

        public init(url: String, dmgURL: String? = nil) {
            self.url = url
            self.dmgURL = dmgURL
        }

        enum CodingKeys: String, CodingKey {
            case url
            case dmgURL = "dmg_url"
        }
    }

    public var version: String
    public var build: String
    public var publishedAt: String
    public var cli: CLIAsset
    public var app: AppAsset?

    public init(version: String, build: String, publishedAt: String, cli: CLIAsset, app: AppAsset? = nil) {
        self.version = version
        self.build = build
        self.publishedAt = publishedAt
        self.cli = cli
        self.app = app
    }

    enum CodingKeys: String, CodingKey {
        case version, build, cli, app
        case publishedAt = "published_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        // Tolerate `"build": 42` as well as the documented `"build": "42"`.
        if let number = try? container.decode(Int.self, forKey: .build) {
            build = String(number)
        } else {
            build = try container.decodeIfPresent(String.self, forKey: .build) ?? ""
        }
        publishedAt = try container.decodeIfPresent(String.self, forKey: .publishedAt) ?? ""
        cli = try container.decode(CLIAsset.self, forKey: .cli)
        app = try container.decodeIfPresent(AppAsset.self, forKey: .app)
    }

    public static func decode(_ data: Data) throws -> ReleaseManifest {
        try JSONDecoder().decode(ReleaseManifest.self, from: data)
    }

    public var publishedDate: Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: publishedAt) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: publishedAt)
    }

    /// The CLI tarball URL, resolved against `baseURL` if the manifest uses a relative path.
    public func cliURL(relativeTo baseURL: URL? = nil) -> URL? {
        let base = baseURL.map { $0.absoluteString.hasSuffix("/") ? $0 : $0.appendingPathComponent("") }
        guard let url = URL(string: cli.url, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
        else { return nil }
        return url
    }
}
