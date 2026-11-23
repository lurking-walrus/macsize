import Darwin
import Foundation
import MacSizeCore


@main
struct MacSizeCLI {
    static func main() {
        // Never let a scan download cloud (File Provider) placeholders. See CloudStorage.
        CloudStorage.disableAutomaticDownloads()
        do {
            let args = try Arguments.parse(Array(CommandLine.arguments.dropFirst()))
            // Background update check; finish() waits briefly and prints a one-line notice on stderr.
            let notifier = UpdateNotifier.start(for: args)
            try run(args)
            notifier?.finish()
        } catch let error as CLIError {
            printError(error.description)
            exit(2)
        } catch {
            printError(error.localizedDescription)
            exit(1)
        }
    }

    static func run(_ args: Arguments) throws {
        switch args.command {
        case .help:
            print(Arguments.usage)
        case .version:
            print("\(MacSizeInfo.commandName) \(MacSizeInfo.version)")
        case .scan:
            let root = try scan(args).root
            if args.json {
                let report = NodeReport(node: root, maxDepth: args.depth, limit: args.top, minimumSize: args.minimumSize, metric: args.metric)
                FileHandle.standardOutput.write(try report.jsonData())
                print()
            } else {
                TreePrinter(args: args, total: root.size(args.metric)).printTree(root)
                printSummary(root, args: args)
            }
        case .largest:
            let root = try scan(args).root
            let files = root.largestFiles(count: args.count, metric: args.metric)
                .filter { $0.size(args.metric) >= args.minimumSize }
            if args.json {
                let reports = files.map { NodeReport(node: $0, maxDepth: 0, metric: args.metric) }
                FileHandle.standardOutput.write(try encoder().encode(reports))
                print()
            } else {
                for file in files {
                    let warning = SensitivePaths.warning(for: file.path).map { "  ⚠ \($0.reason)" } ?? ""
                    print(pad(format(file.size(args.metric), args), 10) + "  " + file.path + warning)
                }
            }
        case .types:
            let root = try scan(args).root
            let stats = Array(root.fileTypeSummary(metric: args.metric).prefix(args.count))
            if args.json {
                FileHandle.standardOutput.write(try encoder().encode(stats))
                print()
            } else {
                let total = max(1, root.size(args.metric))
                for stat in stats {
                    let percent = Double(stat.size) / Double(total) * 100
                    print(
                        pad(format(stat.size, args), 10) + " "
                            + pad(String(format: "%.1f%%", percent), 7) + " "
                            + pad(SizeFormatter.grouped(stat.count), 10) + " files  "
                            + stat.displayName
                    )
                }
            }
        case .bench:
            try Benchmark(args: args).run()
        case .update:
            try UpdateCommand.run(checkOnly: args.checkOnly)
        case .cache:
            try CacheCommand(args: args).run()
        }
    }

    /// Scans `args.path`, reusing and updating the scan cache unless `--no-cache`.
    static func scan(_ args: Arguments) throws -> (root: FileNode, outcome: CachedScan.Outcome) {
        let showProgress = !args.quiet && isatty(STDERR_FILENO) != 0
        var reporter: ProgressReporter?
        defer { reporter?.stop() }

        let location = CacheLocation(args: args)
        let (root, outcome) = try CachedScan.run(
            path: args.path,
            options: args.scanOptions,
            cache: ScanCache(directory: location.directory),
            useCache: args.useCache,
            forceFull: args.forceFull,
            metric: args.metric,
            cacheDirectoryIsExplicit: location.isExplicitFlag,
            onPhase: { phase in
                guard showProgress else { return }
                reporter?.stop()
                switch phase {
                case let .refreshing(cachedAt, progress):
                    reporter = ProgressReporter(progress: progress, label: "Updating from cache (scanned \(RelativeTime.short(since: cachedAt)))…")
                case let .scanning(progress):
                    reporter = ProgressReporter(progress: progress, label: "Scanning…")
                }
                reporter?.start()
            }
        )
        reporter?.stop()
        reporter = nil

        if let error = outcome.saveError {
            printError("warning: couldn't save the scan cache in \(location.directory.path): \(error)")
        }
        if args.verbose {
            printNote(cacheReport(outcome, location: location))
        }
        return (root, outcome)
    }

    /// One line describing how the cache was used, e.g. "refreshed from cache: 3 folders rescanned in 0.04 s".
    static func cacheReport(_ outcome: CachedScan.Outcome, location: CacheLocation) -> String {
        var text: String
        switch outcome.source {
        case .uncached:
            text = String(format: "scanned without cache in %.2f s", outcome.duration)
        case .fullScan:
            text = String(format: "full scan in %.2f s (no usable cached scan)", outcome.duration)
        case .refreshed:
            if outcome.didFullRescan {
                text = String(format: "cached scan couldn't be updated incrementally; full rescan in %.2f s", outcome.duration)
            } else {
                let folders = SizeFormatter.grouped(outcome.directoriesRescanned) + (outcome.directoriesRescanned == 1 ? " folder" : " folders")
                text = String(format: "refreshed from cache: %@ rescanned in %.2f s", folders, outcome.duration)
            }
        }
        if outcome.saved {
            text += "; saved to \(location.directory.path)"
        } else if outcome.saveSkipped == .runningAsRoot {
            text += "; not saved (running as root; pass --cache-dir to save anyway)"
        }
        return text
    }

    static func printSummary(_ root: FileNode, args: Arguments) {
        var line = "\n\(format(root.size(args.metric), args)) in \(SizeFormatter.grouped(root.fileCount)) files, "
            + "\(SizeFormatter.grouped(root.directoryCount)) folders (\(args.metric.displayName.lowercased()))"
        if root.cloudOnlyCount > 0 {
            line += "\n☁︎ \(SizeFormatter.grouped(root.cloudOnlyCount)) cloud-only items "
                + "(\(format(root.cloudOnlySize, args))) are not on this Mac"
            line += args.metric == .logical
                ? "; their logical size is included above."
                : " and count as 0 bytes on disk."
        }
        let errors = countErrors(root)
        if errors > 0 {
            line += "\n\(SizeFormatter.grouped(errors)) items could not be read (permissions?). "
                + "Grant Full Disk Access to your terminal for complete results."
        }
        print(line)
    }

    static func countErrors(_ root: FileNode) -> Int {
        var count = 0
        var stack = [root]
        while let node = stack.popLast() {
            if node.errorCode != 0 { count += 1 }
            stack.append(contentsOf: node.children)
        }
        return count
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

// MARK: - Helpers

func format(_ bytes: Int64, _ args: Arguments) -> String {
    SizeFormatter.string(bytes, binary: args.binaryUnits)
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data(("macsize: " + message + "\n").utf8))
}

/// Informational line on stderr (keeps stdout clean for `--json`).
func printNote(_ message: String) {
    FileHandle.standardError.write(Data(("macsize: " + message + "\n").utf8))
}

struct TreePrinter {
    let args: Arguments
    let total: Int64

    func printTree(_ root: FileNode) {
        print(line(for: root, label: root.path + cloudNote(root) + sensitiveNote(root), prefix: ""))
        printChildren(of: root, prefix: "", depth: 1)
    }

    private func printChildren(of node: FileNode, prefix: String, depth: Int) {
        if let maxDepth = args.depth, depth > maxDepth { return }
        let visible = node.children.filter { $0.size(args.metric) >= args.minimumSize }
        let shown = args.top.map { Array(visible.prefix($0)) } ?? visible
        let hidden = visible.count - shown.count

        for (index, child) in shown.enumerated() {
            let isLast = index == shown.count - 1 && hidden == 0
            let branch = isLast ? "└── " : "├── "
            var label = child.name + (child.isDirectory ? "/" : "")
            if child.isExcluded { label += "  (not scanned)" }
            label += cloudNote(child)
            label += sensitiveNote(child)
            if child.errorCode != 0 { label += "  (\(String(cString: strerror(child.errorCode))))" }
            print(line(for: child, label: prefix + branch + label, prefix: prefix))
            if child.isDirectory {
                printChildren(of: child, prefix: prefix + (isLast ? "    " : "│   "), depth: depth + 1)
            }
        }
        if hidden > 0 {
            let rest = visible.suffix(hidden).reduce(Int64(0)) { $0 + $1.size(args.metric) }
            print(line(size: rest, label: prefix + "└── … \(hidden) more"))
        }
    }

    /// "  ⚠ reason" for important user data or system locations, so they aren't deleted by mistake.
    /// Not repeated for items inside a folder that already carries the same note.
    private func sensitiveNote(_ node: FileNode) -> String {
        guard let warning = SensitivePaths.warning(for: node.path) else { return "" }
        if let parent = node.parent, SensitivePaths.warning(for: parent.path)?.reason == warning.reason { return "" }
        return "  ⚠ \(warning.reason)"
    }

    /// "  ☁︎" for a cloud-only item; "  (☁︎ 48 GB in cloud)" for a folder with cloud-only content.
    private func cloudNote(_ node: FileNode) -> String {
        if node.isCloudOnly {
            return node.isDirectory ? "  ☁︎ (in cloud, not downloaded)" : "  ☁︎"
        }
        guard node.cloudOnlyCount > 0 else { return "" }
        return "  (☁︎ \(format(node.cloudOnlySize, args)) in cloud)"
    }

    private func line(for node: FileNode, label: String, prefix: String) -> String {
        line(size: node.size(args.metric), label: label)
    }

    private func line(size: Int64, label: String) -> String {
        let fraction = total > 0 ? Double(size) / Double(total) : 0
        var text = pad(format(size, args), 10) + " " + pad(String(format: "%.1f%%", fraction * 100), 6) + "  "
        if args.showBars { text += bar(fraction) + "  " }
        return text + label
    }

    private func bar(_ fraction: Double, width: Int = 12) -> String {
        let filled = Int((fraction * Double(width)).rounded())
        return String(repeating: "█", count: min(width, filled)) + String(repeating: "░", count: max(0, width - filled))
    }
}

/// Prints a live status line on stderr while a scan runs.
final class ProgressReporter: @unchecked Sendable {
    private let progress: ScanProgress
    private let label: String
    private let timer: DispatchSourceTimer
    private let startedAt = Date()
    private var stopped = false

    init(progress: ScanProgress, label: String = "Scanning…") {
        self.progress = progress
        self.label = label
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    }

    func start() {
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.render() }
        timer.resume()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        timer.cancel()
        FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8))
    }

    private func render() {
        let snapshot = progress.snapshot()
        let elapsed = Date().timeIntervalSince(startedAt)
        let text = String(
            format: "\r\u{1B}[2K%@ %@ files, %@ folders, %@ (%.1fs)",
            label,
            SizeFormatter.grouped(snapshot.files),
            SizeFormatter.grouped(snapshot.directories),
            SizeFormatter.string(snapshot.bytes),
            elapsed
        )
        FileHandle.standardError.write(Data(text.utf8))
    }
}
