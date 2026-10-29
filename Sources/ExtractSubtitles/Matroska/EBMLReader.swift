import Foundation

/// Minimal EBML reader over a memory-mapped file.
struct EBMLReader {
    let data: Data
    var pos: Int = 0

    init(url: URL) throws {
        data = try Data(contentsOf: url, options: [.alwaysMapped])
    }

    var count: Int { data.count }

    @inline(__always)
    func byte(at i: Int) -> UInt8 { data[data.startIndex + i] }

    func slice(_ offset: Int, _ length: Int) -> Data {
        let s = data.startIndex + offset
        return data.subdata(in: s ..< s + length)
    }

    struct Element {
        let id: UInt32          // element ID with its length marker bits kept
        let dataOffset: Int
        let dataSize: Int?      // nil = unknown size
        let headerStart: Int
        var dataEnd: Int? { dataSize.map { dataOffset + $0 } }
    }

    enum Failure: Error, LocalizedError {
        case truncated, badVInt, notMatroska
        var errorDescription: String? {
            switch self {
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
    static let tags: UInt32 = 0x1254C367
    static let chapters: UInt32 = 0x1043A770
    static let attachments: UInt32 = 0x1941A469
    static let void: UInt32 = 0xEC
    static let crc32: UInt32 = 0xBF

    /// Level-1 elements: used to detect the end of an unknown-sized Cluster.
    static let level1: Set<UInt32> = [seekHead, info, tracks, cluster, cues, tags, chapters, attachments]
}
