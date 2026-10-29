import Foundation

/// Extra Matroska element IDs needed by the video converter (reader and writer).
extension MKV {
    static let trackUID: UInt32 = 0x73C5
    static let flagEnabled: UInt32 = 0xB9
    static let flagLacing: UInt32 = 0x9C
    static let defaultDuration: UInt32 = 0x23E383
    static let codecDelay: UInt32 = 0x56AA
    static let seekPreRoll: UInt32 = 0x56BB
    static let video: UInt32 = 0xE0
    static let pixelWidth: UInt32 = 0xB0
    static let pixelHeight: UInt32 = 0xBA
    static let displayWidth: UInt32 = 0x54B0
    static let displayHeight: UInt32 = 0x54BA
    static let displayUnit: UInt32 = 0x54B2
    static let colour: UInt32 = 0x55B0
    static let matrixCoefficients: UInt32 = 0x55B1
    static let colourRange: UInt32 = 0x55B9
    static let transferCharacteristics: UInt32 = 0x55BA
    static let primaries: UInt32 = 0x55BB
    static let maxCLL: UInt32 = 0x55BC
    static let maxFALL: UInt32 = 0x55BD
    static let masteringMetadata: UInt32 = 0x55D0
    static let primaryRX: UInt32 = 0x55D1
    static let primaryRY: UInt32 = 0x55D2
    static let primaryGX: UInt32 = 0x55D3
    static let primaryGY: UInt32 = 0x55D4
    static let primaryBX: UInt32 = 0x55D5
    static let primaryBY: UInt32 = 0x55D6
    static let whitePointX: UInt32 = 0x55D7
    static let whitePointY: UInt32 = 0x55D8
    static let luminanceMax: UInt32 = 0x55D9
    static let luminanceMin: UInt32 = 0x55DA
    static let audio: UInt32 = 0xE1
    static let samplingFrequency: UInt32 = 0xB5
    static let outputSamplingFrequency: UInt32 = 0x78B5
    static let channels: UInt32 = 0x9F
    static let bitDepth: UInt32 = 0x6264
    static let duration: UInt32 = 0x4489
    static let muxingApp: UInt32 = 0x4D80
    static let writingApp: UInt32 = 0x5741
    static let segmentUID: UInt32 = 0x73A4
    static let referenceBlock: UInt32 = 0xFB
    static let seek: UInt32 = 0x4DBB
    static let seekID: UInt32 = 0x53AB
    static let seekPosition: UInt32 = 0x53AC
    static let cuePoint: UInt32 = 0xBB
    static let cueTime: UInt32 = 0xB3
    static let cueTrackPositions: UInt32 = 0xB7
    static let cueTrack: UInt32 = 0xF7
    static let cueClusterPosition: UInt32 = 0xF1
    static let ebmlVersion: UInt32 = 0x4286
    static let ebmlReadVersion: UInt32 = 0x42F7
    static let ebmlMaxIDLength: UInt32 = 0x42F2
    static let ebmlMaxSizeLength: UInt32 = 0x42F3
    static let docType: UInt32 = 0x4282
    static let docTypeVersion: UInt32 = 0x4287
    static let docTypeReadVersion: UInt32 = 0x4285
}

/// Colour description of a video track (Matroska Colour element), ITU-T H.273 codes.
struct MatroskaColour {
    var matrixCoefficients: UInt64 = 0     // 0 = unspecified
    var range: UInt64 = 0                  // 0 unspecified, 1 limited, 2 full
    var transferCharacteristics: UInt64 = 0
    var primaries: UInt64 = 0
    var maxCLL: UInt64 = 0
    var maxFALL: UInt64 = 0
    /// Mastering display (x/y chromaticities 0..1, luminance in cd/m2), nil when absent.
    var mastering: Mastering?

    struct Mastering {
        var rx = 0.0, ry = 0.0, gx = 0.0, gy = 0.0, bx = 0.0, by = 0.0, wx = 0.0, wy = 0.0
        var lumMax = 0.0, lumMin = 0.0
    }

    var isEmpty: Bool { matrixCoefficients == 0 && range == 0 && transferCharacteristics == 0 && primaries == 0 && mastering == nil }
}

/// Any track of a Matroska file (video, audio, subtitle, ...).
struct MediaTrack {
    static let typeVideo: UInt64 = 1
    static let typeAudio: UInt64 = 2
    static let typeSubtitle: UInt64 = 17

    let number: UInt64
    let uid: UInt64
    let type: UInt64
    let codecID: String
    let codecPrivate: Data
    let defaultDurationNs: UInt64      // 0 when absent
    let language: String               // ISO 639-2 Language element ("eng"), "" if absent
    let languageIETF: String           // "" if absent
    let name: String
    let isDefault: Bool
    let isForced: Bool
    let isEnabled: Bool
    // video
    let pixelWidth: UInt64
    let pixelHeight: UInt64
    let displayWidth: UInt64
    let displayHeight: UInt64
    let displayUnit: UInt64
    let colour: MatroskaColour
    let colourRaw: Data?               // the whole Colour element (header + payload), re-emitted as is
    // audio
    let samplingFrequency: Double
    let outputSamplingFrequency: Double
    let channels: UInt64
    let bitDepth: UInt64
    // compression declared in ContentEncodings (same semantics as SubtitleTrack.compression)
    let compression: SubtitleTrack.ContentCompression?
    /// The complete TrackEntry element (header + payload) as found in the file, for bit-exact copying.
    let rawEntry: Data

    var isVideo: Bool { type == MediaTrack.typeVideo }
    var isAudio: Bool { type == MediaTrack.typeAudio }
    var isSubtitle: Bool { type == MediaTrack.typeSubtitle }
    var subtitleKind: SubtitleKind { SubtitleKind(codecID: codecID) }

    /// Language tag used for naming/matching: IETF tag when present, else the ISO code, else "und".
    var languageTag: String { languageIETF.isEmpty ? (language.isEmpty ? "und" : language) : languageIETF }

    var describe: String {
        var parts: [String] = ["#\(number)", codecID]
        if !languageTag.isEmpty { parts.append(languageTag) }
        if !name.isEmpty { parts.append("\"\(name)\"") }
        if isVideo { parts.append("\(pixelWidth)x\(pixelHeight)") }
        if isAudio { parts.append("\(channels)ch \(Int(samplingFrequency)) Hz") }
        if isForced { parts.append("forced") }
        if isDefault { parts.append("default") }
        return parts.joined(separator: " ")
    }
}

/// One frame read from a (Simple)Block. Laced blocks are split into one MatroskaBlock per frame.
struct MatroskaBlock {
    let trackNumber: UInt64
    let timestampNs: Int64
    let durationNs: Int64?          // BlockDuration when the block was in a BlockGroup
    let isKeyframe: Bool            // SimpleBlock keyframe flag, or BlockGroup without ReferenceBlock
    let payload: Data               // raw payload, as stored (header stripping / zlib NOT undone)
    let fileOffset: Int             // offset of the block in the file, for progress
}

/// Streams every track and every block of a Matroska file in file order.
/// Uses the same memory-mapped EBMLReader as MatroskaDemuxer; nothing is read ahead,
/// so 60 GB files are fine.
final class MatroskaMediaReader {
    private var reader: EBMLReader
    private(set) var timestampScale: UInt64 = 1_000_000
    private(set) var title: String = ""
    private(set) var durationNs: Int64 = 0          // from Info/Duration, 0 if absent
    private(set) var segmentUID: Data = Data()
    private(set) var tracks: [MediaTrack] = []
    /// Raw Chapters / Attachments level-1 elements (header + payload), filled while streaming blocks.
    private(set) var chaptersRaw: Data?
    private(set) var attachmentsRaw: Data?
    private var segmentDataStart = 0
    private var segmentEnd = 0

    var fileSize: Int { reader.count }
    var segmentSize: Int { max(1, segmentEnd - segmentDataStart) }

    init(url: URL) throws {
        reader = try EBMLReader(url: url)
        try readHeaders()
    }

    // MARK: - Headers

    private func readHeaders() throws {
        reader.pos = 0
        let header = try reader.readElementHeader()
        guard header.id == MKV.ebml, let hsize = header.dataSize else { throw EBMLReader.Failure.notMatroska }
        reader.pos = header.dataOffset + hsize

        let seg = try reader.readElementHeader()
        guard seg.id == MKV.segment else { throw EBMLReader.Failure.notMatroska }
        segmentDataStart = seg.dataOffset
        segmentEnd = seg.dataEnd.map { min($0, reader.count) } ?? reader.count

        var foundTracks = false
        try forEachTopLevel { e in
            switch e.id {
            case MKV.info: self.parseInfo(e)
            case MKV.tracks: self.parseTracks(e); foundTracks = true
            case MKV.chapters: if self.chaptersRaw == nil { self.chaptersRaw = self.rawBytes(e) }
            case MKV.attachments: if self.attachmentsRaw == nil { self.attachmentsRaw = self.rawBytes(e) }
            default: break
            }
            return !(foundTracks && e.id == MKV.cluster)
        }
    }

    private func rawBytes(_ e: EBMLReader.Element) -> Data? {
        guard let end = e.dataEnd, end <= reader.count else { return nil }
        return reader.slice(e.headerStart, end - e.headerStart)
    }

    private func forEachTopLevel(_ body: (EBMLReader.Element) throws -> Bool) throws {
        reader.pos = segmentDataStart
        while reader.pos < segmentEnd {
            let e: EBMLReader.Element
            do { e = try reader.readElementHeader() } catch { break }
            if try !body(e) { return }
            if let end = e.dataEnd {
                reader.pos = end
            } else {
                reader.pos = e.dataOffset
                try skipUnknownSized()
            }
        }
    }

    private func skipUnknownSized() throws {
        while reader.pos < segmentEnd {
            let save = reader.pos
            let child: EBMLReader.Element
            do { child = try reader.readElementHeader() } catch { reader.pos = segmentEnd; return }
            if MKV.level1.contains(child.id) { reader.pos = save; return }
            guard let end = child.dataEnd else { continue }
            reader.pos = end
        }
    }

    private func children(of e: EBMLReader.Element) -> [EBMLReader.Element] {
        guard let end = e.dataEnd else { return [] }
        var result: [EBMLReader.Element] = []
        var r = reader
        r.pos = e.dataOffset
        while r.pos < end {
            guard let c = try? r.readElementHeader(), let cend = c.dataEnd, cend <= end else { break }
            result.append(c)
            r.pos = cend
        }
        return result
    }

    /// EBML float: 4 bytes (Float) or 8 bytes (Double), big-endian.
    private func float(_ e: EBMLReader.Element) -> Double {
        guard let n = e.dataSize, e.dataOffset + n <= reader.count else { return 0 }
        if n == 4 {
            var bits: UInt32 = 0
            for i in 0 ..< 4 { bits = (bits << 8) | UInt32(reader.byte(at: e.dataOffset + i)) }
            return Double(Float(bitPattern: bits))
        }
        if n == 8 {
            var bits: UInt64 = 0
            for i in 0 ..< 8 { bits = (bits << 8) | UInt64(reader.byte(at: e.dataOffset + i)) }
            return Double(bitPattern: bits)
        }
        return 0
    }

    private func parseInfo(_ e: EBMLReader.Element) {
        var durationUnits = 0.0
        for c in children(of: e) {
            switch c.id {
            case MKV.timestampScale: timestampScale = max(1, reader.uint(c))
            case MKV.title: title = reader.string(c)
            case MKV.duration: durationUnits = float(c)
            case MKV.segmentUID: segmentUID = reader.binary(c)
            default: break
            }
        }
        if durationUnits > 0 { durationNs = Int64(durationUnits * Double(timestampScale)) }
    }

    private func parseTracks(_ e: EBMLReader.Element) {
        for entry in children(of: e) where entry.id == MKV.trackEntry {
            var number: UInt64 = 0, uid: UInt64 = 0, type: UInt64 = 0
            var codec = "", name = "", lang = "", langIETF = ""
            var priv = Data()
            var defaultDuration: UInt64 = 0
            var forced = false, def = true, enabled = true
            var pw: UInt64 = 0, ph: UInt64 = 0, dw: UInt64 = 0, dh: UInt64 = 0, du: UInt64 = 0
            var colour = MatroskaColour()
            var colourRaw: Data?
            var freq = 0.0, outFreq = 0.0
            var channels: UInt64 = 0, bits: UInt64 = 0
            var compression: SubtitleTrack.ContentCompression?

            for c in children(of: entry) {
                switch c.id {
                case MKV.trackNumber: number = reader.uint(c)
                case MKV.trackUID: uid = reader.uint(c)
                case MKV.trackType: type = reader.uint(c)
                case MKV.codecID: codec = reader.string(c)
                case MKV.codecPrivate: priv = reader.binary(c)
                case MKV.trackName: name = reader.string(c)
                case MKV.language: lang = reader.string(c)
                case MKV.languageIETF: langIETF = reader.string(c)
                case MKV.defaultDuration: defaultDuration = reader.uint(c)
                case MKV.flagForced: forced = reader.uint(c) != 0
                case MKV.flagDefault: def = reader.uint(c) != 0
                case MKV.flagEnabled: enabled = reader.uint(c) != 0
                case MKV.video:
                    for v in children(of: c) {
                        switch v.id {
                        case MKV.pixelWidth: pw = reader.uint(v)
                        case MKV.pixelHeight: ph = reader.uint(v)
                        case MKV.displayWidth: dw = reader.uint(v)
                        case MKV.displayHeight: dh = reader.uint(v)
                        case MKV.displayUnit: du = reader.uint(v)
                        case MKV.colour:
                            colourRaw = rawBytes(v)
                            colour = parseColour(v)
                        default: break
                        }
                    }
                case MKV.audio:
                    for a in children(of: c) {
                        switch a.id {
                        case MKV.samplingFrequency: freq = float(a)
                        case MKV.outputSamplingFrequency: outFreq = float(a)
                        case MKV.channels: channels = reader.uint(a)
                        case MKV.bitDepth: bits = reader.uint(a)
                        default: break
                        }
                    }
                case MKV.contentEncodings:
                    for enc in children(of: c) where enc.id == MKV.contentEncoding {
                        var encType: UInt64 = 0
                        var algo: UInt64 = 0
                        var settings = Data()
                        for ec in children(of: enc) {
                            switch ec.id {
                            case MKV.contentEncodingType: encType = reader.uint(ec)
                            case MKV.contentCompression:
                                for cc in children(of: ec) {
                                    if cc.id == MKV.contentCompAlgo { algo = reader.uint(cc) }
                                    if cc.id == MKV.contentCompSettings { settings = reader.binary(cc) }
                                }
                            default: break
                            }
                        }
                        if encType == 0 {
                            if algo == 0 { compression = .zlib }
                            else if algo == 3 { compression = .headerStripping(settings) }
                        }
                    }
                default: break
                }
            }

            let raw = rawBytes(entry) ?? Data()
            tracks.append(MediaTrack(number: number, uid: uid, type: type, codecID: codec, codecPrivate: priv,
                                     defaultDurationNs: defaultDuration,
                                     language: lang, languageIETF: langIETF, name: name,
                                     isDefault: def, isForced: forced, isEnabled: enabled,
                                     pixelWidth: pw, pixelHeight: ph,
                                     displayWidth: dw == 0 ? pw : dw, displayHeight: dh == 0 ? ph : dh,
                                     displayUnit: du, colour: colour, colourRaw: colourRaw,
                                     samplingFrequency: freq, outputSamplingFrequency: outFreq == 0 ? freq : outFreq,
                                     channels: channels, bitDepth: bits,
                                     compression: compression, rawEntry: raw))
        }
    }

    private func parseColour(_ e: EBMLReader.Element) -> MatroskaColour {
        var col = MatroskaColour()
        for c in children(of: e) {
            switch c.id {
            case MKV.matrixCoefficients: col.matrixCoefficients = reader.uint(c)
            case MKV.colourRange: col.range = reader.uint(c)
            case MKV.transferCharacteristics: col.transferCharacteristics = reader.uint(c)
            case MKV.primaries: col.primaries = reader.uint(c)
            case MKV.maxCLL: col.maxCLL = reader.uint(c)
            case MKV.maxFALL: col.maxFALL = reader.uint(c)
            case MKV.masteringMetadata:
                var m = MatroskaColour.Mastering()
                for mm in children(of: c) {
                    switch mm.id {
                    case MKV.primaryRX: m.rx = float(mm)
                    case MKV.primaryRY: m.ry = float(mm)
                    case MKV.primaryGX: m.gx = float(mm)
                    case MKV.primaryGY: m.gy = float(mm)
                    case MKV.primaryBX: m.bx = float(mm)
                    case MKV.primaryBY: m.by = float(mm)
                    case MKV.whitePointX: m.wx = float(mm)
                    case MKV.whitePointY: m.wy = float(mm)
                    case MKV.luminanceMax: m.lumMax = float(mm)
                    case MKV.luminanceMin: m.lumMin = float(mm)
                    default: break
                    }
                }
                col.mastering = m
            default: break
            }
        }
        return col
    }

    // MARK: - Blocks

    /// Undoes the track's ContentEncodings compression for a payload read with `forEachBlock`
    /// (header stripping / zlib). Returns nil when zlib inflation fails.
    func decompressed(_ payload: Data, track: MediaTrack) -> Data? {
        guard let comp = track.compression else { return payload }
        switch comp {
        case .headerStripping(let hdr): return hdr + payload
        case .zlib: return Zlib.inflate(payload)
        }
    }

    /// Iterates every block of every track in file order. The closure returns false to stop early.
    /// Chapters and Attachments found on the way are kept in `chaptersRaw` / `attachmentsRaw`.
    func forEachBlock(_ body: (MatroskaBlock) throws -> Bool) throws {
        var stop = false
        try forEachTopLevel { e in
            switch e.id {
            case MKV.cluster:
                try self.parseCluster(e) { block in
                    if try !body(block) { stop = true }
                    return !stop
                }
            case MKV.chapters: if self.chaptersRaw == nil { self.chaptersRaw = self.rawBytes(e) }
            case MKV.attachments: if self.attachmentsRaw == nil { self.attachmentsRaw = self.rawBytes(e) }
            default: break
            }
            return !stop
        }
    }

    private func parseCluster(_ cluster: EBMLReader.Element, _ body: (MatroskaBlock) throws -> Bool) throws {
        var clusterTs: UInt64 = 0
        let end = cluster.dataEnd ?? segmentEnd
        var r = reader
        r.pos = cluster.dataOffset

        while r.pos < end {
            let save = r.pos
            let c: EBMLReader.Element
            do { c = try r.readElementHeader() } catch { return }
            if cluster.dataSize == nil, MKV.level1.contains(c.id) { r.pos = save; return }
            guard let cend = c.dataEnd, cend <= reader.count else { return }

            switch c.id {
            case MKV.clusterTimestamp:
                clusterTs = r.uint(c)
            case MKV.simpleBlock:
                if try !parseBlock(c, in: r, clusterTs: clusterTs, duration: nil, keyframeOverride: nil, body) { return }
            case MKV.blockGroup:
                var blockEl: EBMLReader.Element?
                var duration: UInt64?
                var hasReference = false
                var rr = r
                rr.pos = c.dataOffset
                while rr.pos < cend {
                    guard let g = try? rr.readElementHeader(), let gend = g.dataEnd else { break }
                    if g.id == MKV.block { blockEl = g }
                    if g.id == MKV.blockDuration { duration = rr.uint(g) }
                    if g.id == MKV.referenceBlock { hasReference = true }
                    rr.pos = gend
                }
                if let b = blockEl {
                    if try !parseBlock(b, in: r, clusterTs: clusterTs, duration: duration, keyframeOverride: !hasReference, body) { return }
                }
            default:
                break
            }
            r.pos = cend
        }
    }

    /// Returns false when the consumer asked to stop.
    private func parseBlock(_ b: EBMLReader.Element, in base: EBMLReader, clusterTs: UInt64,
                            duration: UInt64?, keyframeOverride: Bool?,
                            _ body: (MatroskaBlock) throws -> Bool) throws -> Bool {
        guard let size = b.dataSize, size >= 4 else { return true }
        var r = base
        r.pos = b.dataOffset
        guard let tn = try? r.readVInt(keepMarker: false) else { return true }
        let end = b.dataOffset + size
        guard r.pos + 3 <= end else { return true }
        let relTs = Int16(bitPattern: UInt16(r.byte(at: r.pos)) << 8 | UInt16(r.byte(at: r.pos + 1)))
        let flags = r.byte(at: r.pos + 2)
        r.pos += 3

        let tsNs = (Int64(clusterTs) + Int64(relTs)) * Int64(timestampScale)
        let durNs = duration.map { Int64($0) * Int64(timestampScale) }
        let keyframe = keyframeOverride ?? ((flags & 0x80) != 0)

        // Lacing (same logic as MatroskaDemuxer)
        let lacing = (flags & 0x06) >> 1
        var sizes: [Int] = []
        if lacing == 0 {
            sizes = [end - r.pos]
        } else {
            guard r.pos < end else { return true }
            let frameCount = Int(r.byte(at: r.pos)) + 1
            r.pos += 1
            switch lacing {
            case 1: // Xiph
                for _ in 0 ..< frameCount - 1 {
                    var s = 0
                    while r.pos < end {
                        let v = Int(r.byte(at: r.pos)); r.pos += 1
                        s += v
                        if v != 255 { break }
                    }
                    sizes.append(s)
                }
            case 3: // EBML
                guard let first = try? r.readVInt(keepMarker: false) else { return true }
                sizes.append(Int(first.value))
                var prev = Int(first.value)
                for _ in 1 ..< max(1, frameCount - 1) {
                    guard let v = try? r.readVInt(keepMarker: false) else { return true }
                    let bias = (1 << (7 * v.length - 1)) - 1
                    let delta = Int(v.value) - bias
                    prev += delta
                    sizes.append(prev)
                }
                if frameCount == 1 { sizes = [] }
            case 2: // fixed
                let total = end - r.pos
                sizes = Array(repeating: total / frameCount, count: frameCount - 1)
            default:
                return true
            }
            let used = sizes.reduce(0, +)
            sizes.append(end - r.pos - used)
        }

        // Laced frames: spread them by the track's default duration when known.
        var perFrameNs: Int64 = 0
        if sizes.count > 1, let track = tracks.first(where: { $0.number == tn.value }), track.defaultDurationNs > 0 {
            perFrameNs = Int64(track.defaultDurationNs)
        } else if sizes.count > 1, let d = durNs {
            perFrameNs = d / Int64(sizes.count)
        }

        for (i, s) in sizes.enumerated() {
            guard s >= 0, r.pos + s <= end else { return true }
            let payload = r.slice(r.pos, s)
            let offset = r.pos
            r.pos += s
            let block = MatroskaBlock(trackNumber: tn.value,
                                      timestampNs: tsNs + Int64(i) * perFrameNs,
                                      durationNs: sizes.count > 1 ? (perFrameNs > 0 ? perFrameNs : nil) : durNs,
                                      isKeyframe: keyframe,
                                      payload: payload,
                                      fileOffset: offset)
            if try !body(block) { return false }
        }
        return true
    }
}
