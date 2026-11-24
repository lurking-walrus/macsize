import SwiftUI
import MacSizeCore

/// How volume usage is presented.
///
/// By default MacSize matches System Settings and Finder: purgeable space (local Time
/// Machine snapshots, caches, evictable iCloud downloads) counts as available. The
/// option switches to APFS's accounting, which is what `df` and Disk Utility show.
enum VolumeDisplay {
    /// `@AppStorage` key for "Count Purgeable Space as Used" (default off).
    static let countPurgeableKey = "countPurgeableAsUsed"

    static let explanation =
        "Purgeable space is data macOS deletes on its own when it needs room: local Time Machine "
        + "snapshots, caches, and iCloud files kept on this Mac that can be downloaded again. "
        + "System Settings counts it as available; APFS and Disk Utility count it as used. "
        + "A scan adds up the files themselves, so its total includes purgeable files."

    static func summary(_ usage: VolumeUsage, countPurgeable: Bool) -> String {
        let total = SizeFormatter.string(usage.total)
        let purgeable = usage.purgeable > 0 ? " · \(SizeFormatter.string(usage.purgeable)) purgeable" : ""
        return countPurgeable
            ? "\(SizeFormatter.string(usage.inUse)) of \(total) in use\(purgeable)"
            : "\(SizeFormatter.string(usage.used)) of \(total) used\(purgeable)"
    }

    /// Short form for the status bar: "650 GB used · 296 GB purgeable".
    static func compact(_ usage: VolumeUsage, countPurgeable: Bool) -> String {
        let purgeable = usage.purgeable > 0 ? " · \(SizeFormatter.string(usage.purgeable)) purgeable" : ""
        return countPurgeable
            ? "\(SizeFormatter.string(usage.inUse)) in use\(purgeable)"
            : "\(SizeFormatter.string(usage.used)) used\(purgeable)"
    }

    static func free(_ usage: VolumeUsage, countPurgeable: Bool) -> String {
        countPurgeable
            ? "\(SizeFormatter.string(usage.free)) free"
            : "\(SizeFormatter.string(usage.available)) available"
    }
}

/// Loads `VolumeUsage` off the main thread and refreshes it while visible.
/// Attach it to a container that always exists (a `ZStack`, not a `Group`): on an
/// empty `Group` the task never starts.
private struct VolumeUsageLoader: ViewModifier {
    let url: URL
    @Binding var usage: VolumeUsage?

    func body(content: Content) -> some View {
        content.task(id: url) {
            while !Task.isCancelled {
                let target = url
                usage = await Task.detached(priority: .utility) { VolumeUsage.read(for: target) }.value
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}

/// "346 GB available" (or "51 GB free"), for the welcome screen's location buttons.
struct VolumeFreeText: View {
    let url: URL
    @AppStorage(VolumeDisplay.countPurgeableKey) private var countPurgeable = false
    @State private var usage: VolumeUsage?

    var body: some View {
        ZStack {
            if let usage {
                Text(VolumeDisplay.free(usage, countPurgeable: countPurgeable))
                    .help(VolumeDisplay.summary(usage, countPurgeable: countPurgeable))
            }
        }
        .modifier(VolumeUsageLoader(url: url, usage: $usage))
    }
}

/// A small usage bar plus "648 GB used · 296 GB purgeable" for the status bar.
struct VolumeUsageSummary: View {
    let url: URL
    @AppStorage(VolumeDisplay.countPurgeableKey) private var countPurgeable = false
    @State private var usage: VolumeUsage?

    var body: some View {
        ZStack {
            if let usage {
                HStack(spacing: 6) {
                    VolumeUsageBar(usage: usage)
                        .frame(width: 90, height: 7)
                    Text(VolumeDisplay.compact(usage, countPurgeable: countPurgeable))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
                .help("\(VolumeDisplay.summary(usage, countPurgeable: countPurgeable)), "
                      + "\(VolumeDisplay.free(usage, countPurgeable: countPurgeable)).\n\n"
                      + VolumeDisplay.explanation)
            }
        }
        .modifier(VolumeUsageLoader(url: url, usage: $usage))
    }
}

/// Used, then purgeable (lighter), then free.
struct VolumeUsageBar: View {
    let usage: VolumeUsage

    var body: some View {
        GeometryReader { geo in
            let total = max(Double(usage.total), 1)
            let usedWidth = geo.size.width * Double(usage.used) / total
            let purgeableWidth = geo.size.width * Double(usage.purgeable) / total
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                HStack(spacing: 0) {
                    Rectangle().fill(.tint).frame(width: usedWidth)
                    Rectangle().fill(.tint.opacity(0.35)).frame(width: purgeableWidth)
                }
                .clipShape(Capsule())
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Volume usage")
        .accessibilityValue("\(SizeFormatter.string(usage.used)) used, "
                            + "\(SizeFormatter.string(usage.purgeable)) purgeable, "
                            + "\(SizeFormatter.string(usage.free)) free")
    }
}

/// "Count Purgeable Space as Used" toggle for the Options menu and Settings.
struct PurgeableToggle: View {
    @AppStorage(VolumeDisplay.countPurgeableKey) private var countPurgeable = false

    var body: some View {
        Toggle("Count Purgeable Space as Used", isOn: $countPurgeable)
    }
}
