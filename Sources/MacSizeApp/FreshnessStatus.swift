import SwiftUI
import MacSizeCore

/// Status-bar text saying how current the results are: "Scanned in 2.1 s",
/// "Scanned 2 h ago · Updating… 14 folders", "Updated just now (3 folders rescanned in 0.2 s)".
struct FreshnessStatus: View {
    @Environment(ScanModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            switch model.freshness {
            case .scanned(let duration):
                Text(String(format: "Scanned in %.1f s", duration))
            case .cached(let scannedAt):
                RelativeAgeText(prefix: "Scanned", date: scannedAt)
            case .updated(let at, let folders, let duration):
                RelativeAgeText(prefix: "Updated", date: at,
                                suffix: " (\(Self.detail(folders: folders, duration: duration)))")
            case nil:
                EmptyView()
            }
            if model.isRefreshing {
                ProgressView().controlSize(.mini)
                Text(model.refreshFolders > 0
                     ? "Updating… \(SizeFormatter.grouped(model.refreshFolders)) folders"
                     : "Updating…")
            }
        }
    }

    private static func detail(folders: Int?, duration: TimeInterval) -> String {
        let time = String(format: "%.1f s", duration)
        guard let folders else { return "rescanned everything in \(time)" }
        return "\(SizeFormatter.grouped(folders)) \(folders == 1 ? "folder" : "folders") rescanned in \(time)"
    }
}

/// "Scanned 2 h ago", re-rendered periodically so the age stays current.
private struct RelativeAgeText: View {
    let prefix: String
    let date: Date
    var suffix = ""

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            Text("\(prefix) \(RelativeAge.string(since: date, now: context.date))\(suffix)")
        }
    }
}
