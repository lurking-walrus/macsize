import Darwin
import Foundation

/// Detects whether the current process has Full Disk Access.
///
/// macOS has no API for this, and no permission prompt: apps must be added to
/// System Settings › Privacy & Security › Full Disk Access by the user. The
/// reliable check (used by most disk utilities) is to try reading a file that
/// only FDA-enabled processes may open, such as the TCC databases. A failed
/// attempt also tends to make macOS list the app (switched off) in that pane.
public enum FullDiskAccess {
    public enum Status: Equatable, Sendable {
        case granted
        case denied
        /// None of the probe files exist or the result was inconclusive.
        case unknown
    }

    /// Files readable only with Full Disk Access, on every supported macOS version.
    public static var defaultProbePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Safari/Bookmarks.plist",
        ]
    }

    /// Checks the probes in order. The first conclusive result wins:
    /// a successful open means granted; EPERM/EACCES means denied.
    public static func check(probePaths: [String] = defaultProbePaths) -> Status {
        var sawDenial = false
        for path in probePaths {
            let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            if fd >= 0 {
                close(fd)
                return .granted
            }
            switch errno {
            case EPERM, EACCES: sawDenial = true
            default: continue  // ENOENT etc.: try the next probe
            }
        }
        return sawDenial ? .denied : .unknown
    }
}
