import Darwin
import Foundation
import MacSizeCore


@main
struct MacSizeCLI {
    static func main() {
        do {
            let args = try Arguments.parse(Array(CommandLine.arguments.dropFirst()))
            try run(args)
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
            let root = try scan(args)
            if args.json {
                let report = NodeReport(node: root, maxDepth: args.depth, limit: args.top, minimumSize: args.minimumSize, metric: args.metric)
                FileHandle.standardOutput.write(try report.jsonData())
                print()
            } else {
                TreePrinter(args: args, total: root.size(args.metric)).printTree(root)
                printSummary(root, args: args)
            }
        case .largest:
            let root = try scan(args)
            let files = root.largestFiles(count: args.count, metric: args.metric)
                .filter { $0.size(args.metric) >= args.minimumSize }
            if args.json {
                let reports = files.map { NodeReport(node: $0, maxDepth: 0, metric: args.metric) }
                FileHandle.standardOutput.write(try encoder().encode(reports))
                print()
            } else {
                for file in files {
                    print(pad(format(file.size(args.metric), args), 10) + "  " + file.path)
                }
            }
        case .types:
            let root = try scan(args)
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
        }
    }

    static func scan(_ args: Arguments) throws -> FileNode {
        let scanner = DiskScanner(options: args.scanOptions)
        let reporter = (args.quiet || isatty(STDERR_FILENO) == 0) ? nil : ProgressReporter(progress: scanner.progress)
        reporter?.start()
        defer { reporter?.stop() }
        return try scanner.scanSynchronously(path: args.path)
    }

    static func printSummary(_ root: FileNode, args: Arguments) {
        var line = "\n\(format(root.size(args.metric), args)) in \(SizeFormatter.grouped(root.fileCount)) files, "
            + "\(SizeFormatter.grouped(root.directoryCount)) folders (\(args.metric.displayName.lowercased()))"
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

struct TreePrinter {
    let args: Arguments
    let total: Int64

    func printTree(_ root: FileNode) {
        print(line(for: root, label: root.path, prefix: ""))
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
    private let timer: DispatchSourceTimer
    private let startedAt = Date()

    init(progress: ScanProgress) {
        self.progress = progress
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    }

    func start() {
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.render() }
        timer.resume()
    }

    func stop() {
        timer.cancel()
        FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8))
    }

    private func render() {
        let snapshot = progress.snapshot()
        let elapsed = Date().timeIntervalSince(startedAt)
        let text = String(
            format: "\r\u{1B}[2KScanning… %@ files, %@ folders, %@ (%.1fs)",
            SizeFormatter.grouped(snapshot.files),
            SizeFormatter.grouped(snapshot.directories),
            SizeFormatter.string(snapshot.bytes),
            elapsed
        )
        FileHandle.standardError.write(Data(text.utf8))
    }
}
