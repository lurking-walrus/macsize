import Darwin

/// One directory entry as returned by `getattrlistbulk(2)`.
struct BulkEntry {
    var name: String = ""
    var objectType: UInt32 = 0
    var fileID: UInt64 = 0
    var modificationTime: Double = 0
    var linkCount: UInt32 = 1
    var logicalSize: Int64 = 0
    var allocatedSize: Int64 = 0
    var error: UInt32 = 0

    var isDirectory: Bool { objectType == VDIR.rawValue }
    var isSymlink: Bool { objectType == VLNK.rawValue }
    var isRegular: Bool { objectType == VREG.rawValue }
}

/// Reads whole directories in a handful of syscalls using `getattrlistbulk`,
/// which returns names, types and sizes for many entries at once. This is
/// considerably faster than `readdir` + `lstat` per entry.
///
/// Not thread-safe: each worker thread owns its own reader (and buffer).
final class BulkDirectoryReader {
    private let capacity: Int
    private let buffer: UnsafeMutableRawPointer
    private var attributes: attrlist

    init(bufferSize: Int = 256 * 1024) {
        capacity = bufferSize
        buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)

        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_ERROR)
            | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_MODTIME)
            | attrgroup_t(ATTR_CMN_FILEID)
        list.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT)
            | attrgroup_t(ATTR_FILE_TOTALSIZE)
            | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        attributes = list
    }

    deinit { buffer.deallocate() }

    /// Calls `body` for every entry in the open directory `fd`.
    /// Returns 0 on success or an `errno` value.
    func forEachEntry(in fd: Int32, _ body: (inout BulkEntry) -> Void) -> Int32 {
        while true {
            let count = getattrlistbulk(fd, &attributes, buffer, capacity, 0)
            if count == 0 { return 0 }
            if count < 0 { return errno }

            var entryStart = UnsafeRawPointer(buffer)
            for _ in 0..<Int(count) {
                let length = entryStart.loadUnaligned(as: UInt32.self)
                var field = entryStart + MemoryLayout<UInt32>.size
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size

                var entry = BulkEntry()
                let common = returned.commonattr
                let file = returned.fileattr

                // Fields appear in a fixed order; absent ones take no space.
                // ATTR_CMN_ERROR immediately follows the returned-attributes set.
                if common & attrgroup_t(ATTR_CMN_ERROR) != 0 {
                    entry.error = field.loadUnaligned(as: UInt32.self)
                    field += MemoryLayout<UInt32>.size
                }
                if common & attrgroup_t(ATTR_CMN_NAME) != 0 {
                    let ref = field.loadUnaligned(as: attrreference_t.self)
                    let namePointer = (field + Int(ref.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
                    entry.name = String(cString: namePointer)
                    field += MemoryLayout<attrreference_t>.size
                }
                if common & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
                    entry.objectType = field.loadUnaligned(as: UInt32.self)
                    field += MemoryLayout<UInt32>.size
                }
                if common & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
                    let time = field.loadUnaligned(as: timespec.self)
                    entry.modificationTime = Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
                    field += MemoryLayout<timespec>.size
                }
                if common & attrgroup_t(ATTR_CMN_FILEID) != 0 {
                    entry.fileID = field.loadUnaligned(as: UInt64.self)
                    field += MemoryLayout<UInt64>.size
                }
                if file & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
                    entry.linkCount = field.loadUnaligned(as: UInt32.self)
                    field += MemoryLayout<UInt32>.size
                }
                if file & attrgroup_t(ATTR_FILE_TOTALSIZE) != 0 {
                    entry.logicalSize = field.loadUnaligned(as: off_t.self)
                    field += MemoryLayout<off_t>.size
                }
                if file & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
                    entry.allocatedSize = field.loadUnaligned(as: off_t.self)
                    field += MemoryLayout<off_t>.size
                }

                body(&entry)
                entryStart += Int(length)
            }
        }
    }
}
