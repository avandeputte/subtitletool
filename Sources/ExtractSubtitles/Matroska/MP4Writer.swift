import Foundation

/// Big-endian byte building for ISO BMFF boxes.
struct BoxBuilder {
    var data = Data()

    init() {}
    init(capacity: Int) { data.reserveCapacity(capacity) }

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { data.append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xFF)]) }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func u24(_ v: UInt32) { data.append(contentsOf: [UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
    mutating func u32(_ v: UInt32) { data.append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func u64(_ v: UInt64) { u32(UInt32(v >> 32)); u32(UInt32(v & 0xFFFF_FFFF)) }
    mutating func fourcc(_ s: String) { data.append(contentsOf: Array(s.utf8.prefix(4))) }
    mutating func bytes(_ d: Data) { data.append(d) }
    mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
    mutating func zeros(_ n: Int) { data.append(Data(count: n)) }
    mutating func fixed16(_ v: Double) { u32(UInt32(max(0, min(Double(UInt32.max), (v * 65536).rounded())))) }
    /// Version + flags of a full box.
    mutating func full(_ version: UInt8 = 0, _ flags: UInt32 = 0) { u8(version); u24(flags) }
    /// A C string (NUL-terminated).
    mutating func cstring(_ s: String) { data.append(contentsOf: Array(s.utf8)); u8(0) }

    /// A box with the given type and body.
    static func box(_ type: String, _ body: Data) -> Data {
        var b = BoxBuilder(capacity: body.count + 8)
        b.u32(UInt32(body.count + 8))
        b.fourcc(type)
        b.bytes(body)
        return b.data
    }

    /// A box whose type is not plain ASCII (iTunes "©nam" = 0xA9 'n' 'a' 'm').
    static func box(typeBytes: [UInt8], _ body: Data) -> Data {
        var b = BoxBuilder(capacity: body.count + 8)
        b.u32(UInt32(body.count + 8))
        b.bytes(typeBytes)
        b.bytes(body)
        return b.data
    }

    static func box(_ type: String, _ build: (inout BoxBuilder) -> Void) -> Data {
        var b = BoxBuilder()
        build(&b)
        return box(type, b.data)
    }

    /// A full box (version/flags first).
    static func fullBox(_ type: String, version: UInt8 = 0, flags: UInt32 = 0, _ build: (inout BoxBuilder) -> Void) -> Data {
        var b = BoxBuilder()
        b.full(version, flags)
        build(&b)
        return box(type, b.data)
    }
}

/// Writes an MP4 (ISO base media) file: `ftyp`, one big `mdat` holding every sample, then the
/// `moov` with one `trak` per track. Samples are buffered per track and written as chunks of
/// about one second, so the tracks stay interleaved however they arrive. Thread safe.
///
/// Timing: every sample has a decode time (`dts`, in the track's timescale) that must not
/// decrease within a track. Video samples also carry a composition time (`cts`); the writer
/// turns the difference into a `ctts` table and an edit list, as players expect.
final class MP4Writer {

    enum Kind { case video, audio, subtitle, chapters }

    struct TrackConfig {
        var kind: Kind
        var timescale: UInt32
        /// ISO 639-2/T three-letter code ("fra"), "und" when unknown.
        var language: String = "und"
        /// Full IETF tag when there is more than the language ("fr-CA"); written as `elng`.
        var extendedLanguage: String = ""
        var name: String = ""
        /// Display size (video and subtitle tracks), in pixels.
        var width: Double = 0
        var height: Double = 0
        var enabled: Bool = true
        var alternateGroup: UInt16 = 0
        /// Full sample entry box (e.g. `hvc1`/`mp4a`/`tx3g`); may be set later, before `finish`.
        var sampleEntry: Data = Data()
        /// Duration of the last sample when no sample follows it (track timescale).
        var defaultSampleDuration: UInt32 = 0
        /// Media time where presentation starts (Opus pre-skip, encoder priming); added to the edit list.
        var mediaTimeOffset: Int64 = 0
        /// Delay before the track starts, in nanoseconds on the movie timeline (empty edit).
        var startDelayNs: Int64 = 0
        /// Track IDs referenced as chapters (`tref/chap`).
        var chapterTrackID: UInt32 = 0
    }

    enum Failure: Error, LocalizedError {
        case cannotCreate(String)
        case noSamples(String)
        case missingSampleEntry(String)
        var errorDescription: String? {
            switch self {
            case .cannotCreate(let p): return "could not create \(p)"
            case .noSamples(let t): return "track \(t) has no samples"
            case .missingSampleEntry(let t): return "track \(t) has no sample description"
            }
        }
    }

    final class Track {
        let id: UInt32
        var config: TrackConfig
        // Per-sample tables.
        var sizes: [UInt32] = []
        var dts: [Int64] = []
        var cts: [Int64] = []          // video only (same length as dts)
        var syncSamples: [UInt32] = [] // 1-based indices; video (and TrueHD)
        var allSync = true
        // Chunks.
        var chunkOffsets: [UInt64] = []
        var chunkSampleCounts: [UInt32] = []
        // Pending (not yet written) samples.
        var pendingData = Data()
        var pendingCount: UInt32 = 0
        var pendingStartDts: Int64 = 0
        var totalBytes: UInt64 = 0

        init(id: UInt32, config: TrackConfig) {
            self.id = id
            self.config = config
        }

        var sampleCount: Int { sizes.count }
        var firstDts: Int64 { dts.first ?? 0 }
        var lastDts: Int64 { dts.last ?? 0 }
        var mediaDuration: Int64 {
            guard let last = dts.last else { return 0 }
            let lastDuration: Int64
            if config.defaultSampleDuration > 0 {
                lastDuration = Int64(config.defaultSampleDuration)
            } else if dts.count >= 2 {
                lastDuration = last - dts[dts.count - 2]
            } else {
                lastDuration = 0
            }
            return last + lastDuration - firstDts
        }
    }

    static let movieTimescale: UInt32 = 1000
    static let chunkTargetSeconds = 1.0
    static let chunkTargetBytes = 4_000_000
    private static let mdatHeaderSize = 16

    let url: URL
    private let handle: FileHandle
    private let lock = NSLock()
    private var tracks: [Track] = []
    private var offset: UInt64 = 0
    private var finished = false
    private var writeBuffer = Data()
    private let writeBufferLimit = 8_000_000
    var title: String = ""

    init(url: URL) throws {
        self.url = url
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        guard fm.createFile(atPath: url.path, contents: nil) else { throw Failure.cannotCreate(url.lastPathComponent) }
        handle = try FileHandle(forWritingTo: url)
        writeBuffer.reserveCapacity(writeBufferLimit + 1_000_000)

        // ftyp
        var ftyp = BoxBuilder()
        ftyp.fourcc("isom"); ftyp.u32(0x200)
        for b in ["isom", "iso2", "mp41", "mp42", "hvc1", "dby1"] { ftyp.fourcc(b) }
        try write(BoxBuilder.box("ftyp", ftyp.data))

        // mdat with a 64-bit size, patched in finish()
        var mdat = BoxBuilder()
        mdat.u32(1); mdat.fourcc("mdat"); mdat.u64(0)
        try write(mdat.data)
    }

    var bytesWritten: UInt64 { lock.lock(); defer { lock.unlock() }; return offset + UInt64(writeBuffer.count) }

    // MARK: - Tracks

    /// Adds a track; returns its index for `add(sample:)`. Track IDs are 1-based in file order.
    @discardableResult
    func addTrack(_ config: TrackConfig) -> Int {
        lock.lock(); defer { lock.unlock() }
        let t = Track(id: UInt32(tracks.count + 1), config: config)
        tracks.append(t)
        return tracks.count - 1
    }

    func trackID(_ index: Int) -> UInt32 { lock.lock(); defer { lock.unlock() }; return tracks[index].id }

    func update(track index: Int, _ change: (inout TrackConfig) -> Void) {
        lock.lock(); defer { lock.unlock() }
        change(&tracks[index].config)
    }

    /// Bytes, samples and media duration so far (for bitrate boxes).
    func stats(track index: Int) -> (bytes: UInt64, samples: Int, durationSeconds: Double) {
        lock.lock(); defer { lock.unlock() }
        let t = tracks[index]
        return (t.totalBytes, t.sampleCount, Double(t.mediaDuration) / Double(t.config.timescale))
    }

    // MARK: - Samples

    /// Adds one sample. `dts` in the track timescale, non-decreasing; `cts` for video (presentation
    /// time in the track timescale, any origin); `sync` marks random access points.
    func add(track index: Int, data: Data, dts: Int64, cts: Int64? = nil, sync: Bool = true) throws {
        lock.lock(); defer { lock.unlock() }
        let t = tracks[index]
        var d = dts
        if let last = t.dts.last, d < last { d = last }     // never go backwards
        t.sizes.append(UInt32(data.count))
        t.dts.append(d)
        if t.config.kind == .video || t.cts.count > 0 || cts != nil {
            t.cts.append(cts ?? d)
        }
        if sync { t.syncSamples.append(UInt32(t.sizes.count)) } else { t.allSync = false }
        t.totalBytes += UInt64(data.count)

        if t.pendingCount == 0 { t.pendingStartDts = d }
        t.pendingData.append(data)
        t.pendingCount += 1
        let span = Double(d - t.pendingStartDts) / Double(t.config.timescale)
        if span >= MP4Writer.chunkTargetSeconds || t.pendingData.count >= MP4Writer.chunkTargetBytes {
            try flushChunk(t)
        }
    }

    /// Caller holds the lock.
    private func flushChunk(_ t: Track) throws {
        guard t.pendingCount > 0 else { return }
        t.chunkOffsets.append(offset + UInt64(writeBuffer.count))
        t.chunkSampleCounts.append(t.pendingCount)
        try write(t.pendingData)
        t.pendingData.removeAll(keepingCapacity: true)
        t.pendingCount = 0
    }

    // MARK: - Finish

    /// Writes the pending chunks, patches the `mdat` size and appends the `moov`.
    func finish() throws {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        for t in tracks { try flushChunk(t) }
        try flushBuffer()

        // mdat size
        let mdatStart = ftypSize
        let mdatSize = offset - UInt64(mdatStart)
        var size = BoxBuilder()
        size.u64(mdatSize)
        try handle.seek(toOffset: UInt64(mdatStart) + 8)
        try handle.write(contentsOf: size.data)
        try handle.seek(toOffset: offset)

        let moov = try buildMoov()
        try write(moov)
        try flushBuffer()
        try handle.synchronize()
        try handle.close()
    }

    /// Closes the file without finishing it (cancel / error); the caller deletes it.
    func abort() {
        lock.lock(); defer { lock.unlock() }
        finished = true
        try? handle.close()
    }

    private var ftypSize: Int {
        // ftyp: 8 + 4 (major) + 4 (minor) + 6 compatible brands * 4
        return 8 + 8 + 6 * 4
    }

    // MARK: - I/O

    private func write(_ data: Data) throws {
        writeBuffer.append(data)
        if writeBuffer.count >= writeBufferLimit { try flushBuffer() }
    }

    private func flushBuffer() throws {
        guard !writeBuffer.isEmpty else { return }
        try handle.write(contentsOf: writeBuffer)
        offset += UInt64(writeBuffer.count)
        writeBuffer.removeAll(keepingCapacity: true)
    }

    // MARK: - moov

    private func buildMoov() throws -> Data {
        let live = tracks.filter { $0.sampleCount > 0 }
        for t in tracks where t.sampleCount > 0 && t.config.sampleEntry.isEmpty {
            throw Failure.missingSampleEntry("\(t.id)")
        }
        guard !live.isEmpty else { throw Failure.noSamples("all") }

        var movieDuration: UInt64 = 0
        var traks = Data()
        for t in live {
            let (trak, duration) = buildTrak(t)
            traks.append(trak)
            movieDuration = max(movieDuration, duration)
        }

        let now = MP4Writer.mp4Time()
        var moov = BoxBuilder()
        moov.bytes(BoxBuilder.fullBox("mvhd", version: 1) { b in
            b.u64(now); b.u64(now)
            b.u32(MP4Writer.movieTimescale)
            b.u64(movieDuration)
            b.u32(0x0001_0000)      // rate 1.0
            b.u16(0x0100)           // volume 1.0
            b.zeros(2 + 8)          // reserved
            MP4Writer.identityMatrix(&b)
            b.zeros(6 * 4)          // pre_defined
            b.u32(UInt32(tracks.count + 1))   // next track ID
        })
        moov.bytes(traks)
        moov.bytes(buildUdta())
        return BoxBuilder.box("moov", moov.data)
    }

    private static func identityMatrix(_ b: inout BoxBuilder) {
        b.u32(0x0001_0000); b.u32(0); b.u32(0)
        b.u32(0); b.u32(0x0001_0000); b.u32(0)
        b.u32(0); b.u32(0); b.u32(0x4000_0000)
    }

    /// Seconds since 1904-01-01 (MP4 epoch).
    static func mp4Time() -> UInt64 {
        return UInt64(Date().timeIntervalSince1970 + 2_082_844_800)
    }

    /// Returns the trak box and the track's duration in the movie timescale (incl. its start delay).
    private func buildTrak(_ t: Track) -> (Data, UInt64) {
        let c = t.config
        let ts = Double(c.timescale)
        let now = MP4Writer.mp4Time()

        // Composition offsets and the edit-list shift for video.
        var ctoList: [Int64] = []
        var shift: Int64 = 0
        let hasCts = !t.cts.isEmpty && t.cts.count == t.dts.count
        if hasCts {
            let minCts = t.cts.min() ?? 0
            var maxNeg: Int64 = 0
            for i in 0 ..< t.dts.count {
                let rel = (t.cts[i] - minCts) - (t.dts[i] - t.firstDts)
                if -rel > maxNeg { maxNeg = -rel }
            }
            shift = maxNeg
            ctoList.reserveCapacity(t.dts.count)
            for i in 0 ..< t.dts.count {
                ctoList.append((t.cts[i] - minCts) - (t.dts[i] - t.firstDts) + shift)
            }
        }
        let mediaDuration = UInt64(max(0, t.mediaDuration))
        // Composition times run from `shift` to mediaDuration + shift; the edit maps that whole span.
        let presentedDuration = max(0, Int64(mediaDuration) - c.mediaTimeOffset)
        let movieDur = UInt64((Double(presentedDuration) * Double(MP4Writer.movieTimescale) / ts).rounded(.up))
        let delay = UInt64(max(0, Double(c.startDelayNs) * Double(MP4Writer.movieTimescale) / 1e9))

        var trak = BoxBuilder()

        // tkhd
        var flags: UInt32 = 0x2            // in movie
        if c.enabled { flags |= 0x1 }
        trak.bytes(BoxBuilder.fullBox("tkhd", version: 1, flags: flags) { b in
            b.u64(now); b.u64(now)
            b.u32(t.id)
            b.u32(0)
            b.u64(movieDur + delay)
            b.zeros(8)
            b.u16(0)                        // layer
            b.u16(c.alternateGroup)
            b.u16(c.kind == .audio ? 0x0100 : 0)   // volume
            b.u16(0)
            MP4Writer.identityMatrix(&b)
            if c.kind == .video || c.kind == .subtitle {
                b.fixed16(c.width); b.fixed16(c.height)
            } else {
                b.u32(0); b.u32(0)
            }
        })

        // edts/elst: optional empty edit (delay), then the media with its start offset.
        let mediaTime = shift + c.mediaTimeOffset
        if delay > 0 || mediaTime > 0 {
            var elst = BoxBuilder()
            elst.full(1, 0)
            elst.u32(delay > 0 ? 2 : 1)
            if delay > 0 {
                elst.u64(delay); elst.u64(UInt64(bitPattern: -1)); elst.u32(0x0001_0000)
            }
            elst.u64(movieDur); elst.u64(UInt64(mediaTime)); elst.u32(0x0001_0000)
            trak.bytes(BoxBuilder.box("edts", BoxBuilder.box("elst", elst.data)))
        }

        // tref/chap
        if c.chapterTrackID > 0 {
            trak.bytes(BoxBuilder.box("tref") { b in
                b.bytes(BoxBuilder.box("chap") { cb in cb.u32(c.chapterTrackID) })
            })
        }

        // mdia
        var mdia = BoxBuilder()
        mdia.bytes(BoxBuilder.fullBox("mdhd", version: 1) { b in
            b.u64(now); b.u64(now)
            b.u32(c.timescale)
            b.u64(mediaDuration)
            b.u16(MP4Writer.packedLanguage(c.language))
            b.u16(0)
        })
        let handlerType: String
        let handlerName: String
        switch c.kind {
        case .video: handlerType = "vide"; handlerName = c.name.isEmpty ? "VideoHandler" : c.name
        case .audio: handlerType = "soun"; handlerName = c.name.isEmpty ? "SoundHandler" : c.name
        case .subtitle: handlerType = "sbtl"; handlerName = c.name.isEmpty ? "SubtitleHandler" : c.name
        case .chapters: handlerType = "text"; handlerName = "Chapters"
        }
        mdia.bytes(BoxBuilder.fullBox("hdlr") { b in
            b.u32(0)
            b.fourcc(handlerType)
            b.zeros(12)
            b.cstring(handlerName)
        })
        if !c.extendedLanguage.isEmpty {
            mdia.bytes(BoxBuilder.fullBox("elng") { b in b.cstring(c.extendedLanguage) })
        }

        // minf
        var minf = BoxBuilder()
        switch c.kind {
        case .video:
            minf.bytes(BoxBuilder.fullBox("vmhd", flags: 1) { b in b.zeros(8) })
        case .audio:
            minf.bytes(BoxBuilder.fullBox("smhd") { b in b.u32(0) })
        case .subtitle:
            minf.bytes(BoxBuilder.fullBox("nmhd") { _ in })
        case .chapters:
            // QuickTime chapter tracks want a gmhd with this (undocumented) text atom.
            minf.bytes(BoxBuilder.box("gmhd") { b in
                b.bytes(BoxBuilder.box("gmin") { g in
                    g.u32(0); g.u16(0x40); g.u16(0x8000); g.u16(0x8000); g.u16(0x8000); g.u16(0); g.u16(0)
                })
                b.bytes(BoxBuilder.box("text") { tb in
                    tb.u16(0x01); tb.u32(0); tb.u32(0); tb.u32(0); tb.u32(0x01); tb.u32(0); tb.u32(0); tb.u32(0); tb.u32(0x4000); tb.u16(0)
                })
            })
        }
        minf.bytes(BoxBuilder.box("dinf", BoxBuilder.fullBox("dref") { b in
            b.u32(1)
            b.bytes(BoxBuilder.fullBox("url ", flags: 1) { _ in })
        }))
        minf.bytes(buildStbl(t, ctoList: ctoList))
        mdia.bytes(BoxBuilder.box("minf", minf.data))
        trak.bytes(BoxBuilder.box("mdia", mdia.data))

        // udta/name: the track title
        if !c.name.isEmpty, c.kind != .chapters {
            trak.bytes(BoxBuilder.box("udta", BoxBuilder.box("name", Data(c.name.utf8))))
        }
        return (BoxBuilder.box("trak", trak.data), movieDur + delay)
    }

    private func buildStbl(_ t: Track, ctoList: [Int64]) -> Data {
        let c = t.config
        var stbl = BoxBuilder()

        // stsd
        stbl.bytes(BoxBuilder.fullBox("stsd") { b in
            b.u32(1)
            b.bytes(c.sampleEntry)
        })

        // stts (run-length of sample deltas)
        var stts = BoxBuilder()
        stts.full()
        var runs: [(count: UInt32, delta: UInt32)] = []
        let n = t.dts.count
        for i in 0 ..< n {
            let delta: Int64
            if i + 1 < n {
                delta = t.dts[i + 1] - t.dts[i]
            } else if c.defaultSampleDuration > 0 {
                delta = Int64(c.defaultSampleDuration)
            } else if n >= 2 {
                delta = t.dts[n - 1] - t.dts[n - 2]
            } else {
                delta = 0
            }
            let d = UInt32(clamping: max(0, delta))
            if let last = runs.last, last.delta == d {
                runs[runs.count - 1].count += 1
            } else {
                runs.append((1, d))
            }
        }
        stts.u32(UInt32(runs.count))
        for r in runs { stts.u32(r.count); stts.u32(r.delta) }
        stbl.bytes(BoxBuilder.box("stts", stts.data))

        // ctts
        if !ctoList.isEmpty, ctoList.contains(where: { $0 != 0 }) {
            var ctts = BoxBuilder()
            ctts.full()
            var cruns: [(count: UInt32, offset: UInt32)] = []
            for o in ctoList {
                let v = UInt32(clamping: max(0, o))
                if let last = cruns.last, last.offset == v {
                    cruns[cruns.count - 1].count += 1
                } else {
                    cruns.append((1, v))
                }
            }
            ctts.u32(UInt32(cruns.count))
            for r in cruns { ctts.u32(r.count); ctts.u32(r.offset) }
            stbl.bytes(BoxBuilder.box("ctts", ctts.data))
        }

        // stss (only when not every sample is a sync sample)
        if !t.allSync {
            var stss = BoxBuilder()
            stss.full()
            stss.u32(UInt32(t.syncSamples.count))
            for s in t.syncSamples { stss.u32(s) }
            stbl.bytes(BoxBuilder.box("stss", stss.data))
        }

        // stsc (run-length of samples per chunk)
        var stsc = BoxBuilder()
        stsc.full()
        var scRuns: [(first: UInt32, count: UInt32)] = []
        for (i, count) in t.chunkSampleCounts.enumerated() {
            if let last = scRuns.last, last.count == count { continue }
            scRuns.append((UInt32(i + 1), count))
        }
        stsc.u32(UInt32(scRuns.count))
        for r in scRuns { stsc.u32(r.first); stsc.u32(r.count); stsc.u32(1) }
        stbl.bytes(BoxBuilder.box("stsc", stsc.data))

        // stsz
        var stsz = BoxBuilder()
        stsz.full()
        if let first = t.sizes.first, t.sizes.allSatisfy({ $0 == first }), first > 0 {
            stsz.u32(first); stsz.u32(UInt32(t.sizes.count))
        } else {
            stsz.u32(0); stsz.u32(UInt32(t.sizes.count))
            for s in t.sizes { stsz.u32(s) }
        }
        stbl.bytes(BoxBuilder.box("stsz", stsz.data))

        // co64
        var co64 = BoxBuilder()
        co64.full()
        co64.u32(UInt32(t.chunkOffsets.count))
        for o in t.chunkOffsets { co64.u64(o) }
        stbl.bytes(BoxBuilder.box("co64", co64.data))

        return BoxBuilder.box("stbl", stbl.data)
    }

    /// Movie-level metadata (iTunes style): the title.
    private func buildUdta() -> Data {
        guard !title.isEmpty else { return Data() }
        var ilst = BoxBuilder()
        ilst.bytes(BoxBuilder.box(typeBytes: [0xA9, 0x6E, 0x61, 0x6D], BoxBuilder.box("data") { b in
            b.u32(1); b.u32(0); b.bytes(Data(title.utf8))
        }))
        var meta = BoxBuilder()
        meta.full()
        meta.bytes(BoxBuilder.fullBox("hdlr") { b in
            b.u32(0); b.fourcc("mdir"); b.fourcc("appl"); b.zeros(8); b.u8(0)
        })
        meta.bytes(BoxBuilder.box("ilst", ilst.data))
        return BoxBuilder.box("udta", BoxBuilder.box("meta", meta.data))
    }

    /// ISO 639-2 code packed into 15 bits (each letter - 0x60, 5 bits).
    static func packedLanguage(_ code: String) -> UInt16 {
        var c = Array(code.lowercased().utf8)
        if c.count != 3 || c.contains(where: { $0 < 0x61 || $0 > 0x7A }) { c = Array("und".utf8) }
        return UInt16(c[0] - 0x60) << 10 | UInt16(c[1] - 0x60) << 5 | UInt16(c[2] - 0x60)
    }

    // MARK: - Sample entries

    /// `hvc1` sample entry for HEVC. `hvcC` is the raw HEVCDecoderConfigurationRecord (as VideoToolbox
    /// gives it); `colr` is (primaries, transfer, matrix, fullRange) in ITU-T H.273 codes, when known.
    static func hvc1Entry(width: Int, height: Int, hvcC: Data,
                          colour: (primaries: UInt16, transfer: UInt16, matrix: UInt16, fullRange: Bool)?,
                          pixelAspect: (h: UInt32, v: UInt32)?,
                          mastering: Data?, contentLight: Data?) -> Data {
        return BoxBuilder.box("hvc1") { b in
            b.zeros(6); b.u16(1)                    // reserved, data reference index
            b.u16(0); b.u16(0); b.zeros(12)         // pre_defined, reserved, pre_defined
            b.u16(UInt16(clamping: width)); b.u16(UInt16(clamping: height))
            b.u32(0x0048_0000); b.u32(0x0048_0000)  // 72 dpi
            b.u32(0)
            b.u16(1)                                // frame count
            let name = Array("HEVC".utf8)
            b.u8(UInt8(name.count)); b.bytes(name); b.zeros(31 - name.count)
            b.u16(0x18)                             // depth
            b.i16(-1)
            b.bytes(BoxBuilder.box("hvcC", hvcC))
            if let c = colour {
                b.bytes(BoxBuilder.box("colr") { cb in
                    cb.fourcc("nclx"); cb.u16(c.primaries); cb.u16(c.transfer); cb.u16(c.matrix); cb.u8(c.fullRange ? 0x80 : 0)
                })
            }
            if let m = mastering, m.count == 24 { b.bytes(BoxBuilder.box("mdcv", m)) }
            if let cl = contentLight, cl.count == 4 { b.bytes(BoxBuilder.box("clli", cl)) }
            if let p = pixelAspect, p.h > 0, p.v > 0, p.h != p.v {
                b.bytes(BoxBuilder.box("pasp") { pb in pb.u32(p.h); pb.u32(p.v) })
            }
        }
    }

    /// Generic audio sample entry: `type` (mp4a, ac-3, ec-3, fLaC, Opus, alac, mlpa) + the codec box(es).
    static func audioEntry(type: String, channels: Int, sampleSize: Int = 16, sampleRate: Int, extra: Data) -> Data {
        return BoxBuilder.box(type) { b in
            b.zeros(6); b.u16(1)                    // reserved, data reference index
            b.u16(0); b.u16(0); b.u32(0)            // version, revision, vendor
            b.u16(UInt16(clamping: channels))
            b.u16(UInt16(clamping: sampleSize))
            b.u16(0); b.u16(0)                      // compression id, packet size
            if type == "mlpa" {
                b.u32(UInt32(clamping: sampleRate))  // TrueHD: whole 32 bits (ffmpeg does the same)
            } else {
                b.u16(sampleRate <= 0xFFFF ? UInt16(sampleRate) : 0); b.u16(0)
            }
            b.bytes(extra)
        }
    }

    /// `esds` for mp4a: AAC (OTI 0x40 + AudioSpecificConfig), MP3 (0x6B / 0x69), DTS (0xA9).
    static func esds(objectType: UInt8, decoderSpecific: Data, maxBitrate: UInt32, avgBitrate: UInt32, trackID: UInt16) -> Data {
        func descr(_ tag: UInt8, _ size: Int, _ b: inout BoxBuilder) {
            b.u8(tag)
            b.u8(UInt8((size >> 21) & 0x7F) | 0x80)
            b.u8(UInt8((size >> 14) & 0x7F) | 0x80)
            b.u8(UInt8((size >> 7) & 0x7F) | 0x80)
            b.u8(UInt8(size & 0x7F))
        }
        let dsiLen = decoderSpecific.isEmpty ? 0 : 5 + decoderSpecific.count
        return BoxBuilder.fullBox("esds") { b in
            descr(0x03, 3 + 5 + 13 + dsiLen + 5 + 1, &b)
            b.u16(trackID); b.u8(0)
            descr(0x04, 13 + dsiLen, &b)
            b.u8(objectType)
            b.u8(0x15)                              // audio stream
            b.u24(0)                                // buffer size
            b.u32(maxBitrate); b.u32(avgBitrate)
            if !decoderSpecific.isEmpty {
                descr(0x05, decoderSpecific.count, &b)
                b.bytes(decoderSpecific)
            }
            descr(0x06, 1, &b)
            b.u8(0x02)
        }
    }

    /// `tx3g` sample entry (3GPP timed text) as players expect for subtitle tracks.
    static func tx3gEntry() -> Data {
        return BoxBuilder.box("tx3g") { b in
            b.zeros(6); b.u16(1)
            b.u32(0)                                // display flags
            b.u8(1); b.u8(0xFF)                     // horizontal centre, vertical bottom
            b.u32(0)                                // background colour (transparent)
            b.i16(0); b.i16(0); b.i16(0); b.i16(0)  // default text box
            b.u16(0); b.u16(0); b.u16(1); b.u8(0); b.u8(18); b.bytes([255, 255, 255, 255] as [UInt8])   // default style
            b.bytes(BoxBuilder.box("ftab") { f in
                f.u16(1); f.u16(1)
                let name = Array("Serif".utf8)
                f.u8(UInt8(name.count)); f.bytes(name)
            })
        }
    }

    /// `text` sample entry for a QuickTime chapter track (the stub ffmpeg and Apple tools write).
    static func chapterTextEntry() -> Data {
        return BoxBuilder.box("text") { b in
            b.zeros(6); b.u16(1)
            b.u32(1)                                // display flags
            b.u8(0); b.u8(0)                        // justification
            b.u32(0)                                // background
            b.zeros(8)                              // default text box
            b.u32(0); b.u16(1); b.u8(0); b.u8(0); b.u32(0)   // style record
            b.bytes(BoxBuilder.box("ftab") { f in f.u16(1); f.u16(1); f.u8(0) })
        }
    }

    /// A tx3g sample: UTF-8 text with optional italic ranges (as a `styl` box). Character offsets
    /// count UTF-16 code units, which is what Apple's players use.
    static func tx3gSample(text: String, italicRanges: [(start: Int, end: Int)]) -> Data {
        var b = BoxBuilder()
        let utf8 = Data(text.utf8)
        b.u16(UInt16(clamping: utf8.count))
        b.bytes(utf8)
        let ranges = italicRanges.filter { $0.end > $0.start }
        if !ranges.isEmpty {
            b.bytes(BoxBuilder.box("styl") { s in
                s.u16(UInt16(clamping: ranges.count))
                for r in ranges {
                    s.u16(UInt16(clamping: r.start)); s.u16(UInt16(clamping: r.end))
                    s.u16(1); s.u8(2); s.u8(18); s.bytes([255, 255, 255, 255])
                }
            })
        }
        return b.data
    }

    /// A chapter-track sample: the title plus the `encd` (UTF-8) marker.
    static func chapterSample(title: String) -> Data {
        var b = BoxBuilder()
        let utf8 = Data(title.utf8)
        b.u16(UInt16(clamping: utf8.count))
        b.bytes(utf8)
        b.u32(12); b.fourcc("encd"); b.u32(0x100)
        return b.data
    }
}
