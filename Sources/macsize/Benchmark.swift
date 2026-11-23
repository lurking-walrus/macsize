import Foundation
import MacSizeCore

/// Times the scanner against `du -sk` on the same path and compares totals.
struct Benchmark {
    let args: Arguments

    func run() throws {
        // du has no notion of our system exclusions, so disable them for a fair comparison.
        var options = args.scanOptions
        options.applySystemExclusions = false

        var ourBest = Double.infinity
        var duBest = Double.infinity
        var ourBytes: Int64 = 0
        var ourFiles = 0
        var duBytes: Int64 = 0

        for run in 1...args.runs {
            // Alternate which tool goes first so neither always benefits from a warm cache.
            let duFirst = run % 2 == 0
            if duFirst { (duBytes, duBest) = try timeDu(best: duBest) }

            let scanner = DiskScanner(options: options)
            let start = DispatchTime.now()
            let root = try scanner.scanSynchronously(path: args.path)
            let elapsed = seconds(since: start)
            ourBest = min(ourBest, elapsed)
            ourBytes = root.allocatedSize
            ourFiles = root.fileCount

            if !duFirst { (duBytes, duBest) = try timeDu(best: duBest) }
        }

        let difference = duBytes > 0 ? Double(ourBytes - duBytes) / Double(duBytes) * 100 : 0
        let threads = "\(options.threadCount) thread" + (options.threadCount == 1 ? "" : "s")
        print("Path:      \(args.path)")
        print("Files:     \(SizeFormatter.grouped(ourFiles))")
        print("macsize:  \(String(format: "%7.3f s", ourBest))  \(SizeFormatter.string(ourBytes, binary: args.binaryUnits))  (\(threads))")
        print("du -sk:    \(String(format: "%7.3f s", duBest))  \(SizeFormatter.string(duBytes, binary: args.binaryUnits))")
        if ourBest > 0 {
            print(String(format: "Speedup:   %.2fx", duBest / ourBest))
        }
        print(String(format: "Size diff: %+.3f%%", difference))
        print("""

        Note: du also counts the blocks used by directory entries themselves and
        rounds to 1 KiB, so small differences are expected. Times are best of \(args.runs) run(s);
        run with --runs 3 or more to reduce filesystem-cache effects.
        """)
    }

    private func timeDu(best: Double) throws -> (Int64, Double) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = (args.stayOnFileSystem ? ["-skx"] : ["-sk"]) + [args.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let start = DispatchTime.now()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let elapsed = seconds(since: start)

        let text = String(decoding: data, as: UTF8.self)
        let kilobytes = text.split(whereSeparator: { $0 == "\t" || $0 == " " }).first.flatMap { Int64($0) } ?? 0
        return (kilobytes * 1024, min(best, elapsed))
    }

    private func seconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }
}
