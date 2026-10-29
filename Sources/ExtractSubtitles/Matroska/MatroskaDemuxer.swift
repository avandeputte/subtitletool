import Foundation
import Compression

struct SubtitleTrack {
    let number: UInt64
    let codecID: String
    let codecPrivate: Data
    let language: String        // IETF tag when the file has one ("fr-CA"), else ISO 639-2 ("fre")
    let isoLanguage: String     // the plain ISO 639-2 Language element ("fre"), "" if absent
    let name: String
    let isForced: Bool
    let isDefault: Bool
    let isHearingImpaired: Bool // FlagHearingImpaired (SDH / closed captions)
    let isCommentary: Bool      // FlagCommentary
    let isOriginal: Bool        // FlagOriginal (original language of the film)
    let compression: ContentCompression?

    enum ContentCompression {
        case zlib
        case headerStripping(Data)
    }

    var kind: SubtitleKind { SubtitleKind(codecID: codecID) }
}

enum SubtitleKind {
    case srt, ass, ssa, webvtt, pgs, vobsub, dvb, other(String)

    init(codecID: String) {
        switch codecID {
        case "S_TEXT/UTF8", "S_TEXT/ASCII": self = .srt
        case "S_TEXT/ASS", "S_ASS": self = .ass
        case "S_TEXT/SSA", "S_SSA": self = .ssa
        case "S_TEXT/WEBVTT": self = .webvtt
        case "S_HDMV/PGS": self = .pgs
        case "S_VOBSUB": self = .vobsub
        case "S_DVBSUB": self = .dvb
        default: self = .other(codecID)
        }
    }

    var fileExtension: String {
        switch self {
        case .srt: return "srt"
        case .ass: return "ass"
        case .ssa: return "ssa"
        case .webvtt: return "vtt"
        case .pgs: return "sup"
        case .vobsub: return "sub"
        case .dvb: return "dvb"
        case .other: return "bin"
        }
    }

    /// Text formats (converted to SRT locally by stripping styling).
    var isTextBased: Bool {
        switch self {
        case .srt, .ass, .ssa, .webvtt: return true
        default: return false
        }
    }

    var isSupported: Bool {
        switch self {
        case .srt, .ass, .ssa, .webvtt, .pgs: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .srt: return "SRT"
        case .ass: return "ASS"
        case .ssa: return "SSA"
        case .webvtt: return "WebVTT"
        case .pgs: return "PGS (image)"
        case .vobsub: return "VobSub (image)"
        case .dvb: return "DVB (image)"
        case .other(let id): return id
        }
    }
}

struct SubtitleFrame {
    let timestampNs: Int64
    var durationNs: Int64?
    let payload: Data
}

final class MatroskaDemuxer {
    private var reader: EBMLReader
    private(set) var timestampScale: UInt64 = 1_000_000
    private(set) var title: String = ""
    private(set) var tracks: [SubtitleTrack] = []
    private var segmentDataStart = 0
    private var segmentEnd = 0
    private var cuesOffset: Int?

    /// Tuning for readFrames; overridable for benchmarks.
    static var parallelReaders = 16
    static var sparseWindow = 8 * 1024         // SSD / network: read only around block headers
    static var streamingWindow = 4 * 1024 * 1024 // spinning disk: one reader streaming large chunks

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
            case MKV.seekHead: self.parseSeekHead(e)
            case MKV.cues: self.cuesOffset = e.headerStart
            default: break
            }
            return !(foundTracks && self.timestampScale != 0 && e.id == MKV.cluster)
        }
    }

    /// Iterates level-1 elements of the Segment. The closure returns false to stop.
    private func forEachTopLevel(_ body: (EBMLReader.Element) throws -> Bool) throws {
        reader.pos = segmentDataStart
        while reader.pos < segmentEnd {
            let e: EBMLReader.Element
            do { e = try reader.readElementHeader() } catch { break }
            if try !body(e) { return }
            if let end = e.dataEnd {
                reader.pos = end
            } else {
                // Unknown-sized element (normally a Cluster): walk its children until
                // the next level-1 element appears.
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

    private func parseSeekHead(_ e: EBMLReader.Element) {
        for seek in children(of: e) where seek.id == MKV.seek {
            var id: UInt64 = 0, position: UInt64?
            for c in children(of: seek) {
                if c.id == MKV.seekID { id = reader.uint(c) }
                if c.id == MKV.seekPosition { position = reader.uint(c) }
            }
            if id == UInt64(MKV.cues), let p = position { cuesOffset = segmentDataStart + Int(p) }
        }
    }

    /// Cluster start offsets listed in the Cues (normally one per video keyframe), sorted.
    /// Empty when the file has no usable Cues.
    private func cueClusterOffsets() -> [Int] {
        guard let offset = cuesOffset, offset < segmentEnd else { return [] }
        var r = EBMLReader(file: reader.file, windowSize: 1024 * 1024)
        r.pos = offset
        guard let cues = try? r.readElementHeader(), cues.id == MKV.cues, let end = cues.dataEnd, end <= r.count else { return [] }
        var result = Set<Int>()
        r.pos = cues.dataOffset
        while r.pos < end {
            guard let point = try? r.readElementHeader(), let pend = point.dataEnd, pend <= end else { break }
            if point.id == MKV.cuePoint {
                r.pos = point.dataOffset
                while r.pos < pend {
                    guard let tp = try? r.readElementHeader(), let tend = tp.dataEnd, tend <= pend else { break }
                    if tp.id == MKV.cueTrackPositions {
                        r.pos = tp.dataOffset
                        while r.pos < tend {
                            guard let c = try? r.readElementHeader(), let cend = c.dataEnd, cend <= tend else { break }
                            if c.id == MKV.cueClusterPosition { result.insert(segmentDataStart + Int(r.uint(c))) }
                            r.pos = cend
                        }
                    }
                    r.pos = tend
                }
            }
            r.pos = pend
        }
        return result.filter { $0 < segmentEnd }.sorted()
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

    private func parseInfo(_ e: EBMLReader.Element) {
        for c in children(of: e) {
            switch c.id {
            case MKV.timestampScale: timestampScale = max(1, reader.uint(c))
            case MKV.title: title = reader.string(c)
            default: break
            }
        }
    }

    private func parseTracks(_ e: EBMLReader.Element) {
        for entry in children(of: e) where entry.id == MKV.trackEntry {
            var number: UInt64 = 0, type: UInt64 = 0
            var codec = "", name = "", lang = "", langIETF = ""
            var priv = Data()
            var forced = false, def = true
            var sdh = false, commentary = false, original = false
            var compression: SubtitleTrack.ContentCompression?

            for c in children(of: entry) {
                switch c.id {
                case MKV.trackNumber: number = reader.uint(c)
                case MKV.trackType: type = reader.uint(c)
                case MKV.codecID: codec = reader.string(c)
                case MKV.codecPrivate: priv = reader.binary(c)
                case MKV.trackName: name = reader.string(c)
                case MKV.language: lang = reader.string(c)
                case MKV.languageIETF: langIETF = reader.string(c)
                case MKV.flagForced: forced = reader.uint(c) != 0
                case MKV.flagDefault: def = reader.uint(c) != 0
                case MKV.flagHearingImpaired: sdh = reader.uint(c) != 0
                case MKV.flagCommentary: commentary = reader.uint(c) != 0
                case MKV.flagOriginal: original = reader.uint(c) != 0
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

            guard type == 0x11 else { continue }   // 0x11 = subtitle track
            let language = langIETF.isEmpty ? (lang.isEmpty ? "und" : lang) : langIETF
            tracks.append(SubtitleTrack(number: number, codecID: codec, codecPrivate: priv,
                                        language: language, isoLanguage: lang, name: name,
                                        isForced: forced, isDefault: def,
                                        isHearingImpaired: sdh, isCommentary: commentary, isOriginal: original,
                                        compression: compression))
        }
    }

    // MARK: - Frames

    /// Reads every frame of the given subtitle tracks, keyed by track number, in one pass.
    ///
    /// Only the bytes around block headers are read: a subtitle block is copied, every other block
    /// (video, audio) is skipped with the next read starting at the following header. On SSDs and
    /// network volumes the file is split at the cluster offsets from the Cues and read by several
    /// threads at once, which keeps enough reads in flight to saturate the drive.
    func readFrames(for wanted: [SubtitleTrack],
                    progress: ((Double) -> Void)? = nil) throws -> [UInt64: [SubtitleFrame]] {
        var frames: [UInt64: [SubtitleFrame]] = [:]
        let wantedNumbers = Set(wanted.map(\.number))
        let byNumber = Dictionary(uniqueKeysWithValues: wanted.map { ($0.number, $0) })
        for n in wantedNumbers { frames[n] = [] }
        guard !wantedNumbers.isEmpty else { return frames }

        // First cluster: where the scan starts.
        var firstCluster: Int?
        try forEachTopLevel { e in
            if e.id == MKV.cluster { firstCluster = e.headerStart; return false }
            return true
        }
        guard let scanStart = firstCluster else { progress?(1); return frames }

        let file = reader.file
        let parallel = !file.isRotational && Self.parallelReaders > 1
        var bounds = [scanStart]
        if parallel {
            // Split points: cluster offsets from the Cues, spread into ~4 pieces per reader so a
            // reader that finishes early picks up another piece.
            let offsets = cueClusterOffsets().filter { $0 > scanStart }
            let pieces = min(offsets.count, Self.parallelReaders * 4 - 1)
            if pieces > 0 {
                for k in 1 ... pieces {
                    let target = scanStart + (segmentEnd - scanStart) * k / (pieces + 1)
                    let i = offsets.firstIndex { $0 >= target } ?? offsets.count - 1
                    if offsets[i] > bounds.last! { bounds.append(offsets[i]) }
                }
            }
            // Only split at offsets that really hold a Cluster header; otherwise read it as one piece.
            var probe = EBMLReader(file: file, windowSize: 4096)
            let valid = bounds.dropFirst().allSatisfy { offset in
                probe.pos = offset
                return (try? probe.readElementHeader())?.id == MKV.cluster
            }
            if !valid { bounds = [scanStart] }
        }
        bounds.append(segmentEnd)
        let ranges = (0 ..< bounds.count - 1).map { bounds[$0] ..< bounds[$0 + 1] }

        let lock = NSLock()
        var results = [[UInt64: [SubtitleFrame]]](repeating: [:], count: ranges.count)
        var failure: Error?
        var bytesDone = 0
        var lastReport = Date.distantPast
        let total = Double(max(1, segmentEnd - scanStart))
        let report: (Int) -> Void = { bytes in
            lock.lock()
            bytesDone += bytes
            let now = Date()
            let due = now.timeIntervalSince(lastReport) > 0.2
            if due { lastReport = now }
            let fraction = Double(bytesDone) / total
            lock.unlock()
            if due { progress?(fraction) }
        }
        let windowSize = parallel ? Self.sparseWindow : Self.streamingWindow
        let next = NSLock()
        var nextPiece = 0

        DispatchQueue.concurrentPerform(iterations: min(ranges.count, parallel ? Self.parallelReaders : 1)) { _ in
            let r = EBMLReader(file: file, windowSize: windowSize)
            while true {
                next.lock()
                let piece = nextPiece
                nextPiece += 1
                next.unlock()
                guard piece < ranges.count else { return }
                var local: [UInt64: [SubtitleFrame]] = [:]
                do {
                    try self.scanClusters(in: ranges[piece], reader: r, wanted: wantedNumbers, tracks: byNumber,
                                          into: &local, report: report)
                } catch {
                    lock.lock(); failure = failure ?? error; lock.unlock()
                }
                lock.lock(); results[piece] = local; lock.unlock()
            }
        }
        if let failure { throw failure }
        if file.failed { throw EBMLReader.Failure.readError }
        for part in results {
            for (n, list) in part { frames[n, default: []].append(contentsOf: list) }
        }

        // Fill in missing durations (SimpleBlocks carry none): use the gap to the next cue.
        for (n, list) in frames {
            var fixed = list.sorted { $0.timestampNs < $1.timestampNs }
            for i in fixed.indices where fixed[i].durationNs == nil {
                if i + 1 < fixed.count {
                    fixed[i].durationNs = max(500_000_000, fixed[i + 1].timestampNs - fixed[i].timestampNs)
                } else {
                    fixed[i].durationNs = 3_000_000_000
                }
            }
            frames[n] = fixed
        }
        progress?(1)
        return frames
    }

    /// Walks the level-1 elements that start inside `range` (its lower bound is a Cluster start)
    /// and collects the wanted frames of every Cluster.
    private func scanClusters(in range: Range<Int>, reader base: EBMLReader,
                              wanted: Set<UInt64>, tracks: [UInt64: SubtitleTrack],
                              into frames: inout [UInt64: [SubtitleFrame]],
                              report: (Int) -> Void) throws {
        var r = base
        r.pos = range.lowerBound
        while r.pos < range.upperBound {
            let start = r.pos
            guard let e = try? r.readElementHeader() else { break }
            if e.id == MKV.cluster {
                r.pos = try parseCluster(e, reader: r, wanted: wanted, tracks: tracks, into: &frames)
            } else if let end = e.dataEnd {
                r.pos = end
            } else {
                break   // an unknown-sized element other than a Cluster: nothing more to find
            }
            guard r.pos > start else { break }
            report(min(r.pos, range.upperBound) - start)
        }
    }

    /// Collects the wanted frames of one Cluster and returns the offset just past it.
    private func parseCluster(_ cluster: EBMLReader.Element, reader base: EBMLReader,
                              wanted: Set<UInt64>,
                              tracks: [UInt64: SubtitleTrack],
                              into frames: inout [UInt64: [SubtitleFrame]]) throws -> Int {
        var clusterTs: UInt64 = 0
        let end = cluster.dataEnd.map { min($0, segmentEnd) } ?? segmentEnd
        var r = base
        r.pos = cluster.dataOffset

        while r.pos < end {
            let save = r.pos
            let c: EBMLReader.Element
            do { c = try r.readElementHeader() } catch { return end }
            if cluster.dataSize == nil, MKV.level1.contains(c.id) { return save }
            guard let cend = c.dataEnd, cend <= r.count else { return end }

            switch c.id {
            case MKV.clusterTimestamp:
                clusterTs = r.uint(c)
            case MKV.simpleBlock:
                parseBlock(c, in: r, clusterTs: clusterTs, duration: nil,
                           wanted: wanted, tracks: tracks, into: &frames)
            case MKV.blockGroup:
                var blockEl: EBMLReader.Element?
                var duration: UInt64?
                var rr = r
                rr.pos = c.dataOffset
                while rr.pos < cend {
                    guard let g = try? rr.readElementHeader(), let gend = g.dataEnd else { break }
                    if g.id == MKV.block { blockEl = g }
                    if g.id == MKV.blockDuration { duration = rr.uint(g) }
                    rr.pos = gend
                }
                if let b = blockEl {
                    parseBlock(b, in: r, clusterTs: clusterTs, duration: duration,
                               wanted: wanted, tracks: tracks, into: &frames)
                }
            default:
                break
            }
            r.pos = cend
        }
        return end
    }

    private func parseBlock(_ b: EBMLReader.Element, in base: EBMLReader, clusterTs: UInt64,
                            duration: UInt64?, wanted: Set<UInt64>,
                            tracks: [UInt64: SubtitleTrack],
                            into frames: inout [UInt64: [SubtitleFrame]]) {
        guard let size = b.dataSize, size >= 4 else { return }
        var r = base
        r.pos = b.dataOffset
        guard let tn = try? r.readVInt(keepMarker: false) else { return }
        guard wanted.contains(tn.value), let track = tracks[tn.value] else { return }

        let end = b.dataOffset + size
        guard r.pos + 3 <= end else { return }
        let relTs = Int16(bitPattern: UInt16(r.byte(at: r.pos)) << 8 | UInt16(r.byte(at: r.pos + 1)))
        let flags = r.byte(at: r.pos + 2)
        r.pos += 3

        let tsNs = (Int64(clusterTs) + Int64(relTs)) * Int64(timestampScale)
        let durNs = duration.map { Int64($0) * Int64(timestampScale) }

        // Lacing
        let lacing = (flags & 0x06) >> 1
        var sizes: [Int] = []
        if lacing == 0 {
            sizes = [end - r.pos]
        } else {
            guard r.pos < end else { return }
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
                guard let first = try? r.readVInt(keepMarker: false) else { return }
                sizes.append(Int(first.value))
                var prev = Int(first.value)
                for _ in 1 ..< max(1, frameCount - 1) {
                    guard let v = try? r.readVInt(keepMarker: false) else { return }
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
                return
            }
            let used = sizes.reduce(0, +)
            sizes.append(end - r.pos - used)
        }

        for s in sizes {
            guard s >= 0, r.pos + s <= end else { return }
            var payload = r.slice(r.pos, s)
            r.pos += s
            if let comp = track.compression {
                switch comp {
                case .headerStripping(let hdr):
                    payload = hdr + payload
                case .zlib:
                    guard let inflated = Zlib.inflate(payload) else { continue }
                    payload = inflated
                }
            }
            frames[tn.value, default: []].append(SubtitleFrame(timestampNs: tsNs, durationNs: durNs, payload: payload))
        }
    }
}

enum Zlib {
    /// Inflates a zlib-wrapped (RFC 1950) buffer using the Compression framework.
    static func inflate(_ input: Data) -> Data? {
        var src = input
        if src.count >= 2, src[src.startIndex] == 0x78 { src = src.dropFirst(2) }   // skip zlib header
        guard !src.isEmpty else { return Data() }

        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }
        guard compression_stream_init(streamPtr, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(streamPtr) }

        let bufSize = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { dst.deallocate() }

        var out = Data()
        let ok: Bool = src.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            streamPtr.pointee.src_ptr = base
            streamPtr.pointee.src_size = raw.count
            while true {
                streamPtr.pointee.dst_ptr = dst
                streamPtr.pointee.dst_size = bufSize
                let status = compression_stream_process(streamPtr, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufSize - streamPtr.pointee.dst_size
                if produced > 0 { out.append(dst, count: produced) }
                switch status {
                case COMPRESSION_STATUS_OK: continue
                case COMPRESSION_STATUS_END: return true
                default: return false
                }
            }
        }
        return ok ? out : nil
    }
}
