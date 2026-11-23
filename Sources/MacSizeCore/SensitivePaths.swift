import Foundation

/// Locations that are easy to damage by trashing: user data and app state that isn't
/// obviously "just files". Trashing them is still allowed, but with a stronger warning.
public enum SensitivePaths {
    public struct Warning: Equatable, Sendable {
        public let path: String
        public let reason: String
    }

    /// Path (relative to the home folder) → why it matters. Matches the folder itself or anything inside.
    private static let homeRelative: [(String, String)] = [
        ("Library/Keychains", "Your saved passwords and certificates live here."),
        ("Library/Mobile Documents", "This is iCloud Drive. Trashing items here deletes them from iCloud and your other devices."),
        ("Library/CloudStorage", "These are synced cloud folders. Trashing items here deletes them from the cloud service too."),
        ("Library/Messages", "Your Messages history lives here."),
        ("Library/Mail", "Your Mail accounts and messages live here."),
        ("Library/Safari", "Your Safari bookmarks and history live here."),
        ("Library/Application Support/AddressBook", "Your Contacts live here."),
        ("Library/Calendars", "Your Calendar data lives here."),
        ("Library/Preferences", "App settings live here; apps may reset or misbehave without them."),
        ("Library/Application Support", "Apps keep their data and settings here; removing items can break them or lose data."),
        ("Library/Group Containers", "Apps keep shared data and settings here."),
        ("Library/Containers", "Sandboxed apps keep their data here."),
        (".ssh", "Your SSH keys live here; you may lose access to servers."),
        (".gnupg", "Your GPG keys live here."),
        ("Documents", "This is your Documents folder."),
        ("Desktop", "This is your Desktop folder."),
    ]

    /// Folders the user owns outright: warn only when the item *is* the folder, not for files inside.
    private static let exactHomeRelative: [(String, String)] = [
        ("Library", "Your user Library holds app data, settings and keychains."),
        ("Pictures", "This is your Pictures folder."),
        ("Music", "This is your Music folder."),
        ("Movies", "This is your Movies folder."),
        ("Downloads", "This is your Downloads folder."),
    ]

    private static let systemPrefixes: [(String, String)] = [
        ("/Applications/Utilities", "These are built-in macOS utilities."),
        ("/Library/Keychains", "System keychains and certificates live here."),
        ("/Library/Application Support", "Apps keep shared data and settings here."),
        ("/Library/Preferences", "System-wide settings live here."),
        ("/Users/Shared", "Files here are shared between all users on this Mac."),
        ("/private/var/db", "System databases live here."),
        ("/System", "This is part of macOS."),
        ("/usr", "This is part of macOS."),
        ("/bin", "This is part of macOS."),
        ("/sbin", "This is part of macOS."),
    ]

    private static let exactSystem: [(String, String)] = [
        ("/Applications", "This is your Applications folder."),
        ("/Library", "This is the system Library folder."),
        ("/Users", "This holds every user's home folder."),
    ]

    /// Why trashing `path` deserves extra care, or nil for an ordinary item.
    public static func warning(for path: String, home: String = NSHomeDirectory()) -> Warning? {
        let path = normalized(path)
        let home = normalized(home)

        if path == "/" || path == home {
            return Warning(path: path, reason: path == home ? "This is your entire home folder." : "This is the whole disk.")
        }
        for (suffix, reason) in homeRelative where contains(path, in: home + "/" + suffix) {
            return Warning(path: path, reason: reason)
        }
        for (suffix, reason) in exactHomeRelative where path == home + "/" + suffix {
            return Warning(path: path, reason: reason)
        }
        for (prefix, reason) in systemPrefixes where contains(path, in: prefix) {
            return Warning(path: path, reason: reason)
        }
        for (exact, reason) in exactSystem where path == exact {
            return Warning(path: path, reason: reason)
        }
        // Applications themselves (not what's inside bundles).
        if path.hasSuffix(".app"), path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") {
            return Warning(path: path, reason: "This is an installed app.")
        }
        // Photos / Music / TV libraries are packages that look like single files.
        for ext in [".photoslibrary", ".musiclibrary", ".tvlibrary"] where path.contains(ext) {
            return Warning(path: path, reason: "This is a media library; trashing it can delete the originals of your photos, music or videos.")
        }
        return nil
    }

    /// Warnings for a set of items, in the order given.
    public static func warnings(for paths: [String], home: String = NSHomeDirectory()) -> [Warning] {
        paths.compactMap { warning(for: $0, home: home) }
    }

    private static func contains(_ path: String, in folder: String) -> Bool {
        path == folder || path.hasPrefix(folder + "/")
    }

    private static func normalized(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        // The data volume appears under /System/Volumes/Data for firmlinked paths.
        if p.hasPrefix("/System/Volumes/Data/") { p.removeFirst("/System/Volumes/Data".count) }
        return p
    }
}
