import Foundation

/// How the running `macsize` was installed, which decides who is allowed to update it.
public enum InstallMode: Equatable, Sendable {
    /// Bundled in `MacSize.app/Contents/Helpers/`; the app's updater owns it. Carries the `.app` path.
    case appBundle(String)
    /// Installed by Homebrew (formula or cask); `brew upgrade` owns it.
    case homebrew
    /// A loose binary (e.g. from the release tarball); `macsize update` replaces it. Carries its path.
    case standalone(String)

    /// Homebrew locations checked without shelling out to `brew --prefix`.
    public static let homebrewMarkers = ["/Cellar/", "/Caskroom/"]
    public static let homebrewPrefixes = ["/opt/homebrew/", "/usr/local/Cellar/", "/usr/local/Caskroom/"]

    /// Classifies an already-resolved executable path.
    public static func detect(executablePath path: String) -> InstallMode {
        let components = (path as NSString).pathComponents
        // Innermost `X.app/Contents/Helpers/…` wins.
        if components.count >= 4 {
            for index in stride(from: components.count - 3, through: 0, by: -1)
            where components[index].hasSuffix(".app")
                && components[index + 1] == "Contents"
                && components[index + 2] == "Helpers" {
                return .appBundle(NSString.path(withComponents: Array(components[...index])))
            }
        }
        if homebrewMarkers.contains(where: path.contains) || homebrewPrefixes.contains(where: path.hasPrefix) {
            return .homebrew
        }
        return .standalone(path)
    }

    /// The mode of the running process, based on the real path of its executable.
    public static func current() -> InstallMode {
        detect(executablePath: currentExecutablePath())
    }

    /// The running executable with all symlinks resolved (so a PATH symlink into the app counts as the app).
    public static func currentExecutablePath() -> String {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        let raw: String
        if _NSGetExecutablePath(&buffer, &size) == 0 {
            raw = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        } else {
            raw = Bundle.main.executablePath ?? CommandLine.arguments[0]
        }
        return realPath(raw)
    }

    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
