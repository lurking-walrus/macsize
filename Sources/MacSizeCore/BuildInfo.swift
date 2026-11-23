// Build-time values. This committed file holds development defaults.
// Release CI overwrites it via scripts/stamp-version.sh (never committed back),
// so nothing environment- or owner-specific lives in the repository.
public enum BuildInfo {
    /// Marketing version, e.g. "1.2.3". "0.0.0-dev" for source builds.
    public static let version = "0.0.0-dev"
    /// Monotonic build number (git commit count in CI).
    public static let build = "0"
    /// Base URL for release assets, e.g. "https://github.com/OWNER/REPO/releases/latest/download".
    /// `nil` disables update checks (source builds).
    public static let releaseBaseURL: String? = nil
    /// Base64 Ed25519 public key used to verify release signatures (Sparkle's SUPublicEDKey).
    /// `nil` disables self-update.
    public static let updatePublicEDKey: String? = nil
    /// App bundle identifier for official builds, used by the CLI to open the app.
    public static let bundleIdentifier: String? = nil
}
