import Foundation
import IOKit

/// An open MKV file read with `pread`. Shared by every reader (and thread) over the same file.
final class MKVFile {
    let fd: Int32
    let size: Int
    /// True when the file sits on a spinning disk: there, skipping ahead in small reads and
    /// reading from several places at once is slower than streaming the whole file.
    let isRotational: Bool
    /// Set when a read came back short or failed before the end of the file.
    var failed = false

    init(url: URL) throws {
        fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path]) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { close(fd); throw CocoaError(.fileReadUnknown) }
        size = Int(st.st_size)
        // We read most of the file once; keeping it out of the page cache spares the user's other apps.
        _ = fcntl(fd, F_NOCACHE, 1)
        isRotational = MKVFile.onRotationalDisk(fd: fd)
    }

    deinit { close(fd) }

    /// Reads `length` bytes at `offset` into `buffer`; returns the number read (short at EOF).
    func read(into buffer: UnsafeMutableRawPointer, offset: Int, length: Int) -> Int {
        var done = 0
        while done < length {
            let n = pread(fd, buffer + done, length - done, off_t(offset + done))
            if n > 0 { done += n } else if n < 0 && errno == EINTR { continue } else { break }
        }
        return done
    }

    /// Looks up the disk behind the file in IOKit. Unknown local disks count as rotational
    /// (the safe choice); network volumes do not, since parallel small reads hide their latency.
    private static func onRotationalDisk(fd: Int32) -> Bool {
        var fs = statfs()
        guard fstatfs(fd, &fs) == 0 else { return true }
        let from = withUnsafeBytes(of: fs.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        guard from.hasPrefix("/dev/") else { return false }
        let bsd = String(from.dropFirst("/dev/".count))
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsd))
        guard service != 0 else { return true }
        defer { IOObjectRelease(service) }
        let found = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "Device Characteristics" as CFString, nil,
                                                    IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
        guard let chars = found as? [String: Any], let medium = chars["Medium Type"] as? String else { return true }
        return medium != "Solid State"
    }
}

/// Minimal EBML reader over an `MKVFile`. It keeps one window of the file in memory and refills
/// it with a single `pread` when a read falls outside it, so walking from block header to block
/// header only reads the bytes around the headers, never the video in between.
/// Copies share the window (it is a class), so a reader and its copies must stay on one thread.
struct EBMLReader {
    let file: MKVFile
    private let window: Window
    var pos: Int = 0

    final class Window {
        let capacity: Int
        let buffer: UnsafeMutableRawPointer
        var start = 0
        var length = 0
        init(capacity: Int) {
            self.capacity = capacity
            buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 4096)
        }
        deinit { buffer.deallocate() }
    }

    init(url: URL) throws {
        try self.init(file: MKVFile(url: url))
    }

    init(file: MKVFile, windowSize: Int = 64 * 1024) {
        self.file = file
        window = Window(capacity: windowSize)
    }

    var count: Int { file.size }

    @inline(__always)
    func byte(at i: Int) -> UInt8 {
        let w = window
        if i < w.start || i >= w.start + w.length { fill(at: i) }
        return w.buffer.load(fromByteOffset: i - w.start, as: UInt8.self)
    }

    private func fill(at i: Int) {
        let w = window
        let start = i & ~4095   // page-aligned reads
        w.start = start
        w.length = file.read(into: w.buffer, offset: start, length: min(w.capacity, max(0, count - start)))
        if i >= w.start + w.length {
            // I/O error (a disk unplugged mid-read): hand back zeros, which stop the parse at the
            // next element header, and let readFrames report the failure.
            file.failed = true
            w.length = min(w.capacity, max(i - start + 1, 0))
            memset(w.buffer, 0, w.length)
        }
    }

    func slice(_ offset: Int, _ length: Int) -> Data {
        guard length > 0 else { return Data() }
        let w = window
        if offset >= w.start, offset + length <= w.start + w.length {
            return Data(bytes: w.buffer + (offset - w.start), count: length)
        }
        if length <= w.capacity / 2 {
            fill(at: offset)
            if offset + length <= w.start + w.length {
                return Data(bytes: w.buffer + (offset - w.start), count: length)
            }
        }
        var d = Data(count: length)
        let n = d.withUnsafeMutableBytes { file.read(into: $0.baseAddress!, offset: offset, length: length) }
        if n < length { d.count = max(0, n); file.failed = true }
        return d
    }

    struct Element {
        let id: UInt32          // element ID with its length marker bits kept
        let dataOffset: Int
        let dataSize: Int?      // nil = unknown size
        let headerStart: Int
        var dataEnd: Int? { dataSize.map { dataOffset + $0 } }
    }

    enum Failure: Error, LocalizedError {
        case truncated, badVInt, notMatroska, readError
        var errorDescription: String? {
            switch self {
            case .readError: return "could not read the file (was the disk disconnected?)"
            case .truncated: return "unexpected end of file"
            case .badVInt: return "corrupt EBML variable-length integer"
            case .notMatroska: return "not a Matroska (EBML) file"
            }
        }
    }

    /// Reads an EBML variable-length integer at `pos`.
    /// - keepMarker: true for element IDs (the marker bit is part of the ID)
    mutating func readVInt(keepMarker: Bool) throws -> (value: UInt64, length: Int, allOnes: Bool) {
        guard pos < count else { throw Failure.truncated }
        let first = byte(at: pos)
        guard first != 0 else { throw Failure.badVInt }
        let length = first.leadingZeroBitCount + 1
        guard length <= 8, pos + length <= count else { throw Failure.truncated }
        var value: UInt64 = keepMarker ? UInt64(first) : UInt64(first & (0xFF >> UInt8(length)))
        var allOnes = (first & (0xFF >> UInt8(length))) == (0xFF >> UInt8(length))
        for i in 1 ..< length {
            let b = byte(at: pos + i)
            value = (value << 8) | UInt64(b)
            if b != 0xFF { allOnes = false }
        }
        pos += length
        return (value, length, allOnes)
    }

    mutating func readElementHeader() throws -> Element {
        let start = pos
        let id = try readVInt(keepMarker: true)
        let size = try readVInt(keepMarker: false)
        return Element(id: UInt32(truncatingIfNeeded: id.value),
                       dataOffset: pos,
                       dataSize: size.allOnes ? nil : Int(size.value),
                       headerStart: start)
    }

    // MARK: payload decoding helpers

    func uint(_ e: Element) -> UInt64 {
        guard let n = e.dataSize, n > 0, n <= 8, e.dataOffset + n <= count else { return 0 }
        var v: UInt64 = 0
        for i in 0 ..< n { v = (v << 8) | UInt64(byte(at: e.dataOffset + i)) }
        return v
    }

    func string(_ e: Element) -> String {
        guard let n = e.dataSize, n > 0, e.dataOffset + n <= count else { return "" }
        var d = slice(e.dataOffset, n)
        while let last = d.last, last == 0 { d.removeLast() }   // strip padding NULs
        return String(decoding: d, as: UTF8.self)
    }

    func binary(_ e: Element) -> Data {
        guard let n = e.dataSize, n >= 0, e.dataOffset + n <= count else { return Data() }
        return slice(e.dataOffset, n)
    }
}

/// Matroska element IDs used here.
enum MKV {
    static let ebml: UInt32 = 0x1A45DFA3
    static let segment: UInt32 = 0x18538067
    static let seekHead: UInt32 = 0x114D9B74
    static let info: UInt32 = 0x1549A966
    static let timestampScale: UInt32 = 0x2AD7B1
    static let title: UInt32 = 0x7BA9
    static let tracks: UInt32 = 0x1654AE6B
    static let trackEntry: UInt32 = 0xAE
    static let trackNumber: UInt32 = 0xD7
    static let trackType: UInt32 = 0x83
    static let flagDefault: UInt32 = 0x88
    static let flagForced: UInt32 = 0x55AA
    static let flagHearingImpaired: UInt32 = 0x55AB
    static let flagVisualImpaired: UInt32 = 0x55AC
    static let flagTextDescriptions: UInt32 = 0x55AD
    static let flagOriginal: UInt32 = 0x55AE
    static let flagCommentary: UInt32 = 0x55AF
    static let trackName: UInt32 = 0x536E
    static let language: UInt32 = 0x22B59C
    static let languageIETF: UInt32 = 0x22B59D
    static let codecID: UInt32 = 0x86
    static let codecPrivate: UInt32 = 0x63A2
    static let contentEncodings: UInt32 = 0x6D80
    static let contentEncoding: UInt32 = 0x6240
    static let contentEncodingOrder: UInt32 = 0x5031
    static let contentEncodingType: UInt32 = 0x5033
    static let contentCompression: UInt32 = 0x5034
    static let contentCompAlgo: UInt32 = 0x4254
    static let contentCompSettings: UInt32 = 0x4255
    static let cluster: UInt32 = 0x1F43B675
    static let clusterTimestamp: UInt32 = 0xE7
    static let simpleBlock: UInt32 = 0xA3
    static let blockGroup: UInt32 = 0xA0
    static let block: UInt32 = 0xA1
    static let blockDuration: UInt32 = 0x9B
    static let cues: UInt32 = 0x1C53BB6B
    static let seek: UInt32 = 0x4DBB
    static let seekID: UInt32 = 0x53AB
    static let seekPosition: UInt32 = 0x53AC
    static let cuePoint: UInt32 = 0xBB
    static let cueTrackPositions: UInt32 = 0xB7
    static let cueClusterPosition: UInt32 = 0xF1
    static let tags: UInt32 = 0x1254C367
    static let chapters: UInt32 = 0x1043A770
    static let attachments: UInt32 = 0x1941A469
    static let void: UInt32 = 0xEC
    static let crc32: UInt32 = 0xBF

    /// Level-1 elements: used to detect the end of an unknown-sized Cluster.
    static let level1: Set<UInt32> = [seekHead, info, tracks, cluster, cues, tags, chapters, attachments]
}
