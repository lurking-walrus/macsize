import Compression
import Darwin
import Foundation

// On-disk layout of a `.macsize-scan` file (all fixed-width integers little-endian):
//
//   Preamble (44 bytes, uncompressed)
//     0  magic              "MSZC"
//     4  formatVersion      UInt16
//     6  algorithm          UInt8   (1 = LZFSE, 2 = LZ4)
//     7  reserved           UInt8   (0)
//     8  headerLength       UInt32  (bytes of JSON that follow)
//    12  nodeCount          UInt64
//    20  compressedLength   UInt64  (bytes of compressed body after the header)
//    28  uncompressedLength UInt64
//    36  checksum           UInt64  (over the compressed body, see `BlockChecksum`)
//   Header: `ScanSnapshotMetadata` as JSON (readable without touching the body)
//   Body: the tree, compressed as one stream, in preorder. Per node:
//     flags     UInt8   bits 0-1 kind, 2 excluded, 3 has error code,
//                       4 allocated stored in 4 KiB units, 5 has children,
//                       6 allocated is zero, 7 has cloud-only data
//     name      varint tag: (len << 1) for inline UTF-8 bytes that follow,
//                           (slot << 1 | 1) for a back-reference into the name cache
//     allocated zigzag varint (absent if zero; divided by 4096 if flag 4)
//     logical   zigzag varint
//     mtime     zigzag varint of (parent's whole seconds - own whole seconds); the root
//               is relative to 0. Times are stored at whole-second resolution.
//     error     zigzag varint (only if flag 3)
//     fileCount, directoryCount  zigzag varints (only for directories)
//     cloud     (only if flag 7) UInt8 isCloudOnly (0/1), then zigzag varints
//               cloudOnlySize, cloudOnlyCount
//     childCount varint (only if flag 5)
//
// The name cache is a direct-mapped table of `nameCacheSize` slots indexed by a hash of
// the name's UTF-8 bytes. Encoder and decoder update it identically on every inline
// name, so frequent names (.DS_Store, index.js, node_modules) become 2-3 byte
// references while memory stays bounded however many unique names a tree has.

enum SnapshotCodecError: Error {
    case io(Int32)
    case compression
    case corrupt(String)
}

enum CompressionAlgorithmID: UInt8 {
    case lzfse = 1
    case lz4 = 2

    var algorithm: compression_algorithm {
        switch self {
        case .lzfse: return COMPRESSION_LZFSE
        case .lz4: return COMPRESSION_LZ4
        }
    }
}

struct SnapshotPreamble: Equatable {
    static let size = 44
    static let magic: [UInt8] = Array("MSZC".utf8)
    /// Upper bound on the JSON header, so a corrupt length can't trigger a huge read.
    static let maxHeaderLength: UInt32 = 1 << 20

    var formatVersion: UInt16
    var algorithm: UInt8
    var headerLength: UInt32
    var nodeCount: UInt64
    var compressedLength: UInt64
    var uncompressedLength: UInt64
    var checksum: UInt64

    func encoded() -> [UInt8] {
        var bytes = Self.magic
        bytes.reserveCapacity(Self.size)
        func put<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }
        put(formatVersion)
        put(algorithm)
        put(UInt8(0))
        put(headerLength)
        put(nodeCount)
        put(compressedLength)
        put(uncompressedLength)
        put(checksum)
        return bytes
    }

    /// nil if the magic is wrong or `bytes` is too short.
    init?(bytes: [UInt8]) {
        guard bytes.count >= Self.size, Array(bytes[0..<4]) == Self.magic else { return nil }
        func get<T: FixedWidthInteger>(_ offset: Int, _: T.Type) -> T {
            var value: T = 0
            for index in 0..<MemoryLayout<T>.size {
                value |= T(bytes[offset + index]) << (8 * index)
            }
            return value
        }
        formatVersion = get(4, UInt16.self)
        algorithm = get(6, UInt8.self)
        headerLength = get(8, UInt32.self)
        nodeCount = get(12, UInt64.self)
        compressedLength = get(20, UInt64.self)
        uncompressedLength = get(28, UInt64.self)
        checksum = get(36, UInt64.self)
    }

    init(formatVersion: UInt16, algorithm: UInt8, headerLength: UInt32, nodeCount: UInt64,
         compressedLength: UInt64, uncompressedLength: UInt64, checksum: UInt64) {
        self.formatVersion = formatVersion
        self.algorithm = algorithm
        self.headerLength = headerLength
        self.nodeCount = nodeCount
        self.compressedLength = compressedLength
        self.uncompressedLength = uncompressedLength
        self.checksum = checksum
    }
}

// MARK: - Low-level helpers

/// Fixed block size for compressed I/O. The checksum is defined over blocks of this size
/// (only the last may be shorter), so writer and reader must agree on it.
let snapshotIOBlockSize = 1 << 20

/// Fast non-cryptographic checksum over the compressed body, to catch corruption the
/// decompressor would happily turn into a plausible-looking tree.
struct BlockChecksum {
    private(set) var value: UInt64 = 0x6D61_6373_697A_6531

    mutating func update(_ buffer: UnsafeRawBufferPointer) {
        var h = value ^ UInt64(buffer.count)
        let words = buffer.count / 8
        var offset = 0
        for _ in 0..<words {
            let word = UInt64(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
            h = (h ^ word) &* 0x9E37_79B9_7F4A_7C15
            h ^= h >> 29
            offset += 8
        }
        while offset < buffer.count {
            h = (h ^ UInt64(buffer[offset])) &* 0x0000_0100_0000_01B3
            offset += 1
        }
        value = h ^ (h >> 32)
    }
}

@inline(__always)
func zigzag(_ value: Int64) -> UInt64 { UInt64(bitPattern: (value << 1) ^ (value >> 63)) }

@inline(__always)
func unzigzag(_ value: UInt64) -> Int64 { Int64(bitPattern: value >> 1) ^ -Int64(bitPattern: value & 1) }

/// Number of slots in the name back-reference cache (must be a power of two).
let nameCacheSize = 1 << 18

@inline(__always)
func nameSlot(_ bytes: UnsafeBufferPointer<UInt8>) -> Int {
    var h: UInt32 = 2_166_136_261
    for byte in bytes {
        h = (h ^ UInt32(byte)) &* 16_777_619
    }
    return Int((h ^ (h >> 15)) & UInt32(nameCacheSize - 1))
}

func writeAll(_ fd: Int32, _ pointer: UnsafeRawPointer, _ count: Int) throws {
    var written = 0
    while written < count {
        let result = Darwin.write(fd, pointer + written, count - written)
        if result < 0 {
            if errno == EINTR { continue }
            throw SnapshotCodecError.io(errno)
        }
        written += result
    }
}

/// Reads up to `count` bytes, returning fewer only at end of file.
func readFully(_ fd: Int32, _ pointer: UnsafeMutableRawPointer, _ count: Int) throws -> Int {
    var total = 0
    while total < count {
        let result = Darwin.read(fd, pointer + total, count - total)
        if result < 0 {
            if errno == EINTR { continue }
            throw SnapshotCodecError.io(errno)
        }
        if result == 0 { break }
        total += result
    }
    return total
}

// MARK: - Compressed output

/// Feeds bytes through a `compression_stream` and writes fixed-size blocks to a file.
final class CompressedFileWriter {
    private let fd: Int32
    private let stream: UnsafeMutablePointer<compression_stream>
    private let output: UnsafeMutablePointer<UInt8>
    private var checksum = BlockChecksum()
    private(set) var compressedLength: UInt64 = 0
    private(set) var uncompressedLength: UInt64 = 0
    private var finished = false

    init(fd: Int32, algorithm: CompressionAlgorithmID) throws {
        self.fd = fd
        stream = .allocate(capacity: 1)
        output = .allocate(capacity: snapshotIOBlockSize)
        guard compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, algorithm.algorithm) == COMPRESSION_STATUS_OK else {
            stream.deallocate()
            output.deallocate()
            throw SnapshotCodecError.compression
        }
        stream.pointee.dst_ptr = output
        stream.pointee.dst_size = snapshotIOBlockSize
    }

    deinit {
        compression_stream_destroy(stream)
        stream.deallocate()
        output.deallocate()
    }

    private func flushOutput() throws {
        let count = snapshotIOBlockSize - stream.pointee.dst_size
        guard count > 0 else { return }
        let block = UnsafeRawBufferPointer(start: output, count: count)
        checksum.update(block)
        try writeAll(fd, output, count)
        compressedLength += UInt64(count)
        stream.pointee.dst_ptr = output
        stream.pointee.dst_size = snapshotIOBlockSize
    }

    func write(_ pointer: UnsafePointer<UInt8>, count: Int) throws {
        uncompressedLength += UInt64(count)
        stream.pointee.src_ptr = pointer
        stream.pointee.src_size = count
        while stream.pointee.src_size > 0 {
            guard compression_stream_process(stream, 0) != COMPRESSION_STATUS_ERROR else {
                throw SnapshotCodecError.compression
            }
            if stream.pointee.dst_size == 0 { try flushOutput() }
        }
    }

    /// Ends the stream; returns the checksum of everything written.
    func finish() throws -> UInt64 {
        precondition(!finished)
        finished = true
        stream.pointee.src_size = 0
        while true {
            let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            if status == COMPRESSION_STATUS_ERROR { throw SnapshotCodecError.compression }
            // Only full blocks are flushed mid-stream so the checksum's block boundaries
            // match what the reader sees.
            if stream.pointee.dst_size == 0 { try flushOutput() }
            if status == COMPRESSION_STATUS_END { break }
        }
        try flushOutput()
        return checksum.value
    }
}

// MARK: - Compressed input

/// Reads fixed-size blocks from a file and decompresses them into a sliding window.
final class CompressedFileReader {
    private let fd: Int32
    private let stream: UnsafeMutablePointer<compression_stream>
    private let input: UnsafeMutablePointer<UInt8>
    private(set) var window: UnsafeMutablePointer<UInt8>
    private var capacity: Int
    /// Unconsumed bytes are `window[start..<end]`.
    var start = 0
    var end = 0
    private var remainingInput: UInt64
    private var checksum = BlockChecksum()
    private var inputExhausted = false
    private(set) var outputEnded = false

    init(fd: Int32, algorithm: CompressionAlgorithmID, compressedLength: UInt64) throws {
        self.fd = fd
        remainingInput = compressedLength
        stream = .allocate(capacity: 1)
        input = .allocate(capacity: snapshotIOBlockSize)
        capacity = 4 << 20
        window = .allocate(capacity: capacity)
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, algorithm.algorithm) == COMPRESSION_STATUS_OK else {
            stream.deallocate()
            input.deallocate()
            window.deallocate()
            throw SnapshotCodecError.compression
        }
        stream.pointee.src_size = 0
    }

    deinit {
        compression_stream_destroy(stream)
        stream.deallocate()
        input.deallocate()
        window.deallocate()
    }

    var available: Int { end - start }

    /// Makes at least `count` bytes available unless the stream ends first.
    /// Returns the number of bytes available.
    @discardableResult
    func ensure(_ count: Int) throws -> Int {
        if end - start >= count || outputEnded { return end - start }
        if start > 0 {
            let pending = end - start
            if pending > 0 { window.update(from: window + start, count: pending) }
            start = 0
            end = pending
        }
        if count > capacity {
            let bigger = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
            bigger.update(from: window, count: end)
            window.deallocate()
            window = bigger
            capacity = count
        }
        while end < count && !outputEnded {
            if stream.pointee.src_size == 0 && !inputExhausted { try readBlock() }
            stream.pointee.dst_ptr = window + end
            stream.pointee.dst_size = capacity - end
            let flags = inputExhausted && stream.pointee.src_size == 0
                ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let status = compression_stream_process(stream, flags)
            guard status != COMPRESSION_STATUS_ERROR else { throw SnapshotCodecError.compression }
            let produced = (capacity - end) - stream.pointee.dst_size
            end += produced
            if status == COMPRESSION_STATUS_END {
                outputEnded = true
            } else if produced == 0 && inputExhausted && stream.pointee.src_size == 0 && flags != 0 {
                // Finalized with no input left and no progress: the stream is truncated.
                throw SnapshotCodecError.corrupt("truncated compressed stream")
            }
        }
        return end - start
    }

    private func readBlock() throws {
        let want = Int(min(UInt64(snapshotIOBlockSize), remainingInput))
        guard want > 0 else {
            inputExhausted = true
            return
        }
        let got = try readFully(fd, input, want)
        guard got == want else { throw SnapshotCodecError.corrupt("file shorter than its header says") }
        checksum.update(UnsafeRawBufferPointer(start: input, count: got))
        remainingInput -= UInt64(got)
        if remainingInput == 0 { inputExhausted = true }
        stream.pointee.src_ptr = UnsafePointer(input)
        stream.pointee.src_size = got
    }

    /// After the tree is decoded: the stream must be fully consumed, nothing may trail
    /// it, and the checksum must match.
    func verifyEnd(expectedChecksum: UInt64) throws {
        if try ensure(1) > 0 { throw SnapshotCodecError.corrupt("trailing data") }
        guard outputEnded, inputExhausted, remainingInput == 0, stream.pointee.src_size == 0 else {
            throw SnapshotCodecError.corrupt("stream did not end where expected")
        }
        var probe: UInt8 = 0
        if try readFully(fd, &probe, 1) != 0 { throw SnapshotCodecError.corrupt("bytes after body") }
        guard checksum.value == expectedChecksum else { throw SnapshotCodecError.corrupt("checksum mismatch") }
    }
}

// MARK: - Tree encoding

enum SnapshotCodec {
    static let defaultAlgorithm: CompressionAlgorithmID = .lzfse

    private static let kindMask: UInt8 = 0b11
    private static let flagExcluded: UInt8 = 1 << 2
    private static let flagError: UInt8 = 1 << 3
    private static let flagAlloc4K: UInt8 = 1 << 4
    private static let flagChildren: UInt8 = 1 << 5
    private static let flagAllocZero: UInt8 = 1 << 6
    private static let flagCloud: UInt8 = 1 << 7

    /// Largest name accepted when decoding (root paths can be long; components can't).
    private static let maxNameLength = 1 << 16

    @inline(__always)
    static func wholeSeconds(_ time: TimeInterval) -> Int64 {
        guard time.isFinite else { return 0 }
        let floored = time.rounded(.down)
        if floored >= 9.0e18 { return Int64(9.0e18) }
        if floored <= -9.0e18 { return Int64(-9.0e18) }
        return Int64(floored)
    }

    /// Writes the complete file (preamble, header, body) to `fd`, which must be
    /// positioned at offset 0 and support `pwrite`.
    static func write(_ snapshot: ScanSnapshot, to fd: Int32, algorithm: CompressionAlgorithmID = defaultAlgorithm) throws {
        var metadata = snapshot.metadata
        metadata.formatVersion = ScanSnapshotMetadata.currentFormatVersion
        let header = try JSONEncoder().encode(metadata)
        guard header.count <= SnapshotPreamble.maxHeaderLength else { throw SnapshotCodecError.corrupt("header too large") }

        // Placeholder preamble; patched once the body's length and checksum are known.
        var preamble = SnapshotPreamble(
            formatVersion: UInt16(ScanSnapshotMetadata.currentFormatVersion), algorithm: algorithm.rawValue,
            headerLength: UInt32(header.count), nodeCount: 0, compressedLength: 0, uncompressedLength: 0, checksum: 0)
        try preamble.encoded().withUnsafeBytes { try writeAll(fd, $0.baseAddress!, $0.count) }
        try header.withUnsafeBytes { try writeAll(fd, $0.baseAddress!, $0.count) }

        let compressor = try CompressedFileWriter(fd: fd, algorithm: algorithm)
        let nodeCount = try encodeTree(snapshot.root, into: compressor)
        preamble.checksum = try compressor.finish()
        preamble.nodeCount = nodeCount
        preamble.compressedLength = compressor.compressedLength
        preamble.uncompressedLength = compressor.uncompressedLength

        let bytes = preamble.encoded()
        let result = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress!, $0.count, 0) }
        guard result == bytes.count else { throw SnapshotCodecError.io(errno) }
    }

    private static func encodeTree(_ root: FileNode, into compressor: CompressedFileWriter) throws -> UInt64 {
        let flushThreshold = 1 << 20
        let capacity = flushThreshold + (1 << 17)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        var count = 0

        @inline(__always) func putVarint(_ value: UInt64) {
            var v = value
            while v >= 0x80 {
                buffer[count] = UInt8(truncatingIfNeeded: v) | 0x80
                count += 1
                v >>= 7
            }
            buffer[count] = UInt8(v)
            count += 1
        }

        var nameCache = [String?](repeating: nil, count: nameCacheSize)
        var nodeCount: UInt64 = 0
        // (node, parent's whole-second mtime)
        var stack: [(FileNode, Int64)] = [(root, 0)]

        while let (node, parentSeconds) = stack.popLast() {
            nodeCount += 1
            let name = node.name
            var nameBytes = name
            let nameLength = name.utf8.count
            if count + nameLength + 160 > capacity || count >= flushThreshold {
                try compressor.write(buffer, count: count)
                count = 0
                if nameLength + 160 > capacity {
                    throw SnapshotCodecError.corrupt("name too long to encode")
                }
            }

            let allocated = node.allocatedSize
            let children = node.children
            var flags = node.kind.rawValue & kindMask
            if node.isExcluded { flags |= flagExcluded }
            if node.errorCode != 0 { flags |= flagError }
            if allocated == 0 {
                flags |= flagAllocZero
            } else if allocated > 0 && allocated & 4095 == 0 {
                flags |= flagAlloc4K
            }
            if !children.isEmpty { flags |= flagChildren }
            let hasCloud = node.isCloudOnly || node.cloudOnlySize != 0 || node.cloudOnlyCount != 0
            if hasCloud { flags |= flagCloud }
            buffer[count] = flags
            count += 1

            nameBytes.withUTF8 { utf8 in
                let slot = nameSlot(utf8)
                if let cached = nameCache[slot], cached.utf8.count == utf8.count,
                   cached.utf8.elementsEqual(utf8) {
                    putVarint(UInt64(slot) << 1 | 1)
                } else {
                    nameCache[slot] = name
                    putVarint(UInt64(utf8.count) << 1)
                    if utf8.count > 0 {
                        (buffer + count).update(from: utf8.baseAddress!, count: utf8.count)
                        count += utf8.count
                    }
                }
            }

            if allocated != 0 {
                putVarint(zigzag(flags & flagAlloc4K != 0 ? allocated >> 12 : allocated))
            }
            putVarint(zigzag(node.logicalSize))
            let seconds = wholeSeconds(node.modificationTime)
            putVarint(zigzag(parentSeconds &- seconds))
            if node.errorCode != 0 { putVarint(zigzag(Int64(node.errorCode))) }
            if node.kind == .directory {
                putVarint(zigzag(Int64(node.fileCount)))
                putVarint(zigzag(Int64(node.directoryCount)))
            }
            if hasCloud {
                buffer[count] = node.isCloudOnly ? 1 : 0
                count += 1
                putVarint(zigzag(node.cloudOnlySize))
                putVarint(zigzag(Int64(node.cloudOnlyCount)))
            }
            if !children.isEmpty {
                putVarint(UInt64(children.count))
                for child in children.reversed() { stack.append((child, seconds)) }
            }
        }
        if count > 0 { try compressor.write(buffer, count: count) }
        return nodeCount
    }

    // MARK: Decoding

    /// Decodes the body that follows the header. `fd` must be positioned at the body.
    static func readTree(from fd: Int32, preamble: SnapshotPreamble) throws -> FileNode {
        guard let algorithm = CompressionAlgorithmID(rawValue: preamble.algorithm) else {
            throw SnapshotCodecError.corrupt("unknown compression algorithm")
        }
        guard preamble.nodeCount > 0 else { throw SnapshotCodecError.corrupt("empty tree") }
        let reader = try CompressedFileReader(fd: fd, algorithm: algorithm, compressedLength: preamble.compressedLength)

        var nameCache = [String?](repeating: nil, count: nameCacheSize)
        let expectedNodes = preamble.nodeCount
        var decoded: UInt64 = 0
        var root: FileNode?
        // (directory, children still to read, its whole-second mtime)
        var stack: [(node: FileNode, remaining: Int, seconds: Int64)] = []

        repeat {
            guard decoded < expectedNodes else { throw SnapshotCodecError.corrupt("more nodes than declared") }
            // Every fixed field of a record fits in 160 bytes; names are ensured separately.
            try reader.ensure(160)
            var p = reader.start
            var limit = reader.end
            var window = reader.window

            @inline(__always) func readVarint() throws -> UInt64 {
                var result: UInt64 = 0
                var shift: UInt64 = 0
                while true {
                    guard p < limit else { throw SnapshotCodecError.corrupt("record overruns stream") }
                    let byte = window[p]
                    p += 1
                    if shift == 63 && byte > 1 { throw SnapshotCodecError.corrupt("varint overflow") }
                    result |= UInt64(byte & 0x7F) << shift
                    if byte < 0x80 { return result }
                    shift += 7
                    if shift > 63 { throw SnapshotCodecError.corrupt("varint too long") }
                }
            }

            guard p < limit else { throw SnapshotCodecError.corrupt("truncated before record") }
            let flags = window[p]
            p += 1
            guard let kind = FileKind(rawValue: flags & kindMask) else {
                throw SnapshotCodecError.corrupt("bad flags")
            }

            let tag = try readVarint()
            let name: String
            if tag & 1 == 1 {
                let slot = tag >> 1
                guard slot < UInt64(nameCacheSize), let cached = nameCache[Int(slot)] else {
                    throw SnapshotCodecError.corrupt("dangling name reference")
                }
                name = cached
            } else {
                let length = Int(clamping: tag >> 1)
                guard length <= maxNameLength else { throw SnapshotCodecError.corrupt("name too long") }
                if limit - p < length {
                    reader.start = p
                    guard try reader.ensure(length) >= length else { throw SnapshotCodecError.corrupt("truncated name") }
                    p = reader.start
                    limit = reader.end
                    window = reader.window
                }
                let bytes = UnsafeBufferPointer(start: window + p, count: length)
                name = String(decoding: bytes, as: UTF8.self)
                nameCache[nameSlot(bytes)] = name
                p += length
                // The rest of the record must still be available.
                if limit - p < 128 {
                    reader.start = p
                    try reader.ensure(128)
                    p = reader.start
                    limit = reader.end
                    window = reader.window
                }
            }

            var allocated: Int64 = 0
            if flags & flagAllocZero == 0 {
                allocated = unzigzag(try readVarint())
                if flags & flagAlloc4K != 0 {
                    guard allocated >= 0, allocated <= Int64.max >> 12 else { throw SnapshotCodecError.corrupt("size overflow") }
                    allocated <<= 12
                }
            }
            let logical = unzigzag(try readVarint())
            let parentSeconds = stack.last?.seconds ?? 0
            let seconds = parentSeconds &- unzigzag(try readVarint())
            let errorCode: Int32
            if flags & flagError != 0 {
                let raw = unzigzag(try readVarint())
                guard let value = Int32(exactly: raw) else { throw SnapshotCodecError.corrupt("bad error code") }
                errorCode = value
            } else {
                errorCode = 0
            }
            var fileCount = 1
            var directoryCount = 0
            if kind == .directory {
                fileCount = Int(unzigzag(try readVarint()))
                directoryCount = Int(unzigzag(try readVarint()))
            }
            var isCloudOnly = false
            var cloudOnlySize: Int64 = 0
            var cloudOnlyCount = 0
            if flags & flagCloud != 0 {
                guard p < limit else { throw SnapshotCodecError.corrupt("record overruns stream") }
                let marker = window[p]
                p += 1
                guard marker <= 1 else { throw SnapshotCodecError.corrupt("bad cloud marker") }
                isCloudOnly = marker == 1
                cloudOnlySize = unzigzag(try readVarint())
                cloudOnlyCount = Int(unzigzag(try readVarint()))
            }
            var childCount = 0
            if flags & flagChildren != 0 {
                let raw = try readVarint()
                guard raw > 0, raw <= expectedNodes - decoded - 1 else { throw SnapshotCodecError.corrupt("bad child count") }
                childCount = Int(raw)
            }
            reader.start = p

            let node = FileNode(
                name: name, kind: kind, allocatedSize: allocated, logicalSize: logical,
                modificationTime: TimeInterval(seconds), parent: stack.last?.node)
            node.fileCount = fileCount
            node.directoryCount = directoryCount
            if errorCode != 0 { node.errorCode = errorCode }
            if flags & flagExcluded != 0 { node.isExcluded = true }
            if flags & flagCloud != 0 {
                node.isCloudOnly = isCloudOnly
                node.cloudOnlySize = cloudOnlySize
                node.cloudOnlyCount = cloudOnlyCount
            }
            decoded += 1

            if stack.isEmpty {
                root = node
            } else {
                stack[stack.count - 1].node.children.append(node)
                stack[stack.count - 1].remaining -= 1
            }
            if childCount > 0 {
                node.children.reserveCapacity(childCount)
                stack.append((node, childCount, seconds))
            } else {
                while let top = stack.last, top.remaining == 0 { stack.removeLast() }
            }
        } while !stack.isEmpty

        guard decoded == expectedNodes, let root else { throw SnapshotCodecError.corrupt("node count mismatch") }
        try reader.verifyEnd(expectedChecksum: preamble.checksum)
        return root
    }
}
