import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import CoreImage
import CoreGraphics

/// Thread-safe cancellation flag shared between the UI (main actor) and the converter thread.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
}

/// Converts an MKV to an MP4 with HEVC video:
///   MatroskaMediaReader -> VTDecompressionSession -> (subtitle compositing with Core Image)
///   -> VTCompressionSession (HEVC, hvc1) -> MP4Writer.
/// Every audio track is copied packet for packet (AAC, AC-3, E-AC-3, DTS, DTS-HD, TrueHD, FLAC, Opus,
/// MP3, ALAC); DTS and TrueHD tracks also get an AC-3 copy made with ffmpeg, because Apple's players
/// cannot decode them. Text subtitles become tx3g tracks, chapters a chapter track.
final class VideoConverter {

    struct Options {
        var quality: Double = 0.85          // 0...1, kVTCompressionPropertyKey_Quality
        var burnInSubtitles: Bool = true     // burn the forced subtitle track, if any
        var ac3Copies: Bool = true           // AC-3 copy of every DTS / TrueHD track (needs ffmpeg)
        /// SRT files to embed as subtitle tracks (the ones this job just extracted); when empty,
        /// the MKV's own text subtitle tracks are embedded instead.
        var extraSubtitleFiles: [URL] = []
    }

    struct Progress {
        var fraction: Double
        var fps: Double
        var etaSeconds: Double?
        var framesEncoded: Int
    }

    struct Result {
        var outputURL: URL
        var framesEncoded: Int
        var outputBytes: Int64
        var videoBitrate: Double        // bit/s of the HEVC track
        var durationSeconds: Double
        var burnedTrack: MediaTrack?
        var audioTracks: Int
        var ac3Copies: Int
        var subtitleTracks: Int
        var notes: [String]
    }

    enum Failure: Error, LocalizedError {
        case noVideoTrack
        case unsupportedCodec(String)
        case missingCodecPrivate
        case formatDescription(OSStatus)
        case decoderSetup(OSStatus)
        case encoderSetup(OSStatus)
        case decodeFailed(OSStatus)
        case encodeFailed(OSStatus)
        case sampleBuffer
        case noHVCC
        case noFrames
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "the file has no video track"
            case .unsupportedCodec(let c): return "video codec \(c) is not supported (only H.264 and HEVC sources can be converted)"
            case .missingCodecPrivate: return "the video track has no CodecPrivate (avcC/hvcC)"
            case .formatDescription(let s): return "could not describe the video stream (\(s))"
            case .decoderSetup(let s): return "could not create the video decoder (\(s))"
            case .encoderSetup(let s): return "could not create the HEVC encoder (\(s))"
            case .decodeFailed(let s): return "video decoding failed (\(s))"
            case .encodeFailed(let s): return "HEVC encoding failed (\(s))"
            case .sampleBuffer: return "could not build a sample buffer"
            case .noHVCC: return "the encoder did not provide an hvcC configuration"
            case .noFrames: return "no video frames were decoded"
            case .cancelled: return "cancelled"
            }
        }
    }

    // MARK: - Configuration

    private let source: URL
    private let options: Options
    private let log: (String) -> Void
    private let progress: (Progress) -> Void
    private let cancel: CancelToken

    // MARK: - Pipeline state (guarded by `lock` where shared between threads)

    private let lock = NSLock()
    private var decoder: VTDecompressionSession?
    private var encoder: VTCompressionSession?
    private var reorder: [(pts: Int64, buffer: CVPixelBuffer)] = []
    private var reorderDepth = 16
    private let decodeSlots = DispatchSemaphore(value: 6)     // frames submitted to the decoder, not yet out
    private let encodeSlots = DispatchSemaphore(value: 32)    // frames submitted to the encoder, not yet out
    private var pendingError: Error?
    private var overlay: SubtitleOverlayTrack?
    private var ciContext: CIContext?
    private var outputColorSpace: CGColorSpace?
    private var frameDurationNs: Int64 = 0
    private var recentPTS: [Int64] = []
    private var usedQualityProperty = true
    private var encoderWidth = 0
    private var encoderHeight = 0
    private var tenBit = false

    private var reader: MatroskaMediaReader?
    private var videoTrack: MediaTrack?
    private var writer: MP4Writer?
    private var videoIndex = 0                 // MP4Writer track index of the video
    private var videoEntryWritten = false
    private var videoTimescale: UInt32 = 90_000
    private var videoDelta: UInt32 = 0
    private var ptsPhaseNs: Int64 = 0
    private var framesEncoded = 0
    private var videoBytes = 0
    private var lastVideoPtsNs: Int64 = 0
    private var expectedFrames = 0
    private var readFraction = 0.0
    private var readingDone = false
    private var startDate = Date()
    private var lastProgressDate = Date.distantPast
    private var notes: [String] = []

    // Audio
    private var audio: [UInt64: AudioState] = [:]          // by Matroska track number
    private var unsupportedAudio: Set<UInt64> = []
    private var audioOrder: [UInt64] = []                  // Matroska audio tracks in file order
    private var ac3Workers: [AC3Worker] = []
    private var defaultAudioHandled = false

    // Subtitles and chapters
    private var textTracks: [UInt64: TextCollector] = [:]  // MKV text subtitle tracks (not burned)

    init(source: URL, options: Options, cancel: CancelToken,
         log: @escaping (String) -> Void, progress: @escaping (Progress) -> Void) {
        self.source = source
        self.options = options
        self.cancel = cancel
        self.log = log
        self.progress = progress
    }

    // MARK: - Entry point

    /// Runs the whole conversion synchronously (call from a background thread).
    static func convert(source: URL, options: Options, cancel: CancelToken,
                        log: @escaping (String) -> Void, progress: @escaping (Progress) -> Void) throws -> Result {
        let converter = VideoConverter(source: source, options: options, cancel: cancel, log: log, progress: progress)
        do {
            return try converter.run()
        } catch {
            converter.cleanupAfterFailure()
            throw error
        }
    }

    private func cleanupAfterFailure() {
        for w in ac3Workers { w.transcoder.stop() }
        if let d = decoder { VTDecompressionSessionInvalidate(d) }
        if let e = encoder { VTCompressionSessionInvalidate(e) }
        lock.lock()
        reorder.removeAll()
        lock.unlock()
        if let w = writer {
            w.abort()
            try? FileManager.default.removeItem(at: w.url)
        }
    }

    private func run() throws -> Result {
        startDate = Date()
        let reader = try MatroskaMediaReader(url: source)
        self.reader = reader
        guard let video = reader.tracks.first(where: { $0.isVideo }) else { throw Failure.noVideoTrack }
        videoTrack = video
        log("  video: \(video.describe)")
        if reader.tracks.filter({ $0.isVideo }).count > 1 {
            log("  note: only the first video track is converted; the other video tracks are dropped")
        }

        let desc = try makeFormatDescription(track: video)
        frameDurationNs = Int64(video.defaultDurationNs)
        reorderDepth = video.codecID == "V_MPEGH/ISO/HEVC" ? 8 : 16
        if frameDurationNs > 0, reader.durationNs > 0 {
            expectedFrames = Int(reader.durationNs / frameDurationNs)
        }

        // Which subtitle track to burn in.
        let burn: MediaTrack? = options.burnInSubtitles ? pickForcedTrack(reader.tracks) : nil
        if let b = burn {
            log("  burn-in: forced subtitle track \(b.describe) (\(b.subtitleKind.label))")
            overlay = SubtitleOverlayTrack(track: b, videoWidth: Int(video.pixelWidth), videoHeight: Int(video.pixelHeight))
        } else if options.burnInSubtitles {
            log("  no forced subtitle track; converting without burn-in")
        }
        audioOrder = reader.tracks.filter { $0.isAudio }.map { $0.number }
        // Text subtitle tracks go in as tx3g, unless this job already extracted SRT files (then those are used).
        if options.extraSubtitleFiles.isEmpty {
            for t in reader.tracks where t.isSubtitle && t.subtitleKind.isTextBased && t.number != burn?.number {
                textTracks[t.number] = TextCollector(track: t)
            }
        }
        for t in reader.tracks where t.isSubtitle && !t.subtitleKind.isTextBased && t.number != burn?.number {
            if options.extraSubtitleFiles.isEmpty {
                log("  \(t.subtitleKind.label) subtitle track \(t.describe) cannot go into an MP4 (not copied; extract it to SRT first)")
            }
        }

        // Output file.
        let finalURL = VideoConverter.outputURL(for: source)
        let tempURL = finalURL.deletingPathExtension().appendingPathExtension("part.mp4")
        let w = try MP4Writer(url: tempURL)
        w.title = source.deletingPathExtension().lastPathComponent
        writer = w
        log("  output: \(finalURL.lastPathComponent)")

        // The video track first, so it is track 1; its timescale and sample entry are set once the encoder runs.
        let (vLang, vExt) = MP4Language.codes(language: video.language, ietf: video.languageIETF)
        var vcfg = MP4Writer.TrackConfig(kind: .video, timescale: 90_000)
        vcfg.language = vLang
        vcfg.extendedLanguage = vExt
        vcfg.name = video.name
        vcfg.width = Double(video.displayWidth > 0 ? video.displayWidth : video.pixelWidth)
        vcfg.height = Double(video.displayHeight > 0 ? video.displayHeight : video.pixelHeight)
        vcfg.enabled = true
        videoIndex = w.addTrack(vcfg)

        if options.ac3Copies, AC3Transcoder.findFFmpeg() == nil,
           reader.tracks.contains(where: { $0.isAudio && ($0.codecID.hasPrefix("A_DTS") || $0.codecID == "A_TRUEHD" || $0.codecID == "A_MLP") }) {
            let n = "AC-3 copies skipped: ffmpeg not found (brew install ffmpeg)"
            log("  \(n)")
            notes.append(n)
        }

        decoder = try makeDecoder(desc)

        // Read the file once, in file order.
        var videoBlocks = 0
        try reader.forEachBlock { block in
            if self.cancel.isCancelled { return false }
            if let e = self.takeError() { throw e }

            if block.trackNumber == video.number {
                if self.recentPTS.count < 64 { self.recentPTS.append(block.timestampNs) }
                let dur: Int64 = self.frameDurationNs > 0 ? self.frameDurationNs : (block.durationNs ?? 0)
                guard let sb = self.makeSampleBuffer(block.payload, ptsNs: block.timestampNs, durationNs: dur, desc: desc) else {
                    throw Failure.sampleBuffer
                }
                try self.submit(sb)
                videoBlocks += 1
            } else if let ov = self.overlay, block.trackNumber == ov.track.number {
                if let payload = reader.decompressed(block.payload, track: ov.track) {
                    ov.add(payload: payload, timestampNs: block.timestampNs, durationNs: block.durationNs)
                }
            } else if let collector = self.textTracks[block.trackNumber] {
                if let payload = reader.decompressed(block.payload, track: collector.track) {
                    collector.add(payload: payload, timestampNs: block.timestampNs, durationNs: block.durationNs)
                }
            } else if let t = reader.tracks.first(where: { $0.number == block.trackNumber }), t.isAudio {
                try self.handleAudio(block, track: t)
            }
            self.readFraction = Double(block.fileOffset) / Double(max(1, reader.fileSize))
            return true
        }
        if cancel.isCancelled { throw Failure.cancelled }
        guard videoBlocks > 0 else { throw Failure.noFrames }

        // Drain the decoder, then the reorder queue, then the encoder.
        if let d = decoder {
            VTDecompressionSessionFinishDelayedFrames(d)
            VTDecompressionSessionWaitForAsynchronousFrames(d)
        }
        if let e = takeError() { throw e }
        lock.lock()
        let rest = reorder.sorted { $0.pts < $1.pts }
        reorder.removeAll()
        lock.unlock()
        for r in rest { encode(r.buffer, ptsNs: r.pts) }
        if cancel.isCancelled { throw Failure.cancelled }
        if let e = takeError() { throw e }
        guard let enc = encoder else { throw Failure.noFrames }
        VTCompressionSessionCompleteFrames(enc, untilPresentationTimeStamp: CMTime.invalid)
        if let e = takeError() { throw e }
        VTCompressionSessionInvalidate(enc)
        encoder = nil
        if let d = decoder { VTDecompressionSessionInvalidate(d) }
        decoder = nil
        lock.lock(); readingDone = true; lock.unlock()
        guard videoEntryWritten, framesEncoded > 0 else { throw Failure.noFrames }

        // Let the AC-3 helpers finish (they were throttled to the video's progress).
        for worker in ac3Workers {
            if worker.thread != nil { worker.finished.wait() }
            if let e = worker.error {
                let n = "AC-3 copy of \(worker.sourceDescribe) failed: \(e.localizedDescription)"
                log("  \(n)")
                notes.append(n)
            } else {
                log("  AC-3 copy of \(worker.sourceDescribe): \(worker.frames) frames")
            }
        }
        if cancel.isCancelled { throw Failure.cancelled }

        // Finish the audio tracks: sample entries with bitrates, start delays.
        let durationNs = max(reader.durationNs, lastVideoPtsNs + max(frameDurationNs, 0))
        var audioCount = 0
        var copies = 0
        for n in audioOrder {
            guard let a = audio[n] else { continue }
            audioCount += 1
            a.finish(writer: w)
            if a.gaps > 0 || a.overlaps > 0 {
                log("  audio \(a.track.describe): \(a.gaps) gap(s) and \(a.overlaps) overlap(s) in the source timestamps were resynced")
            }
            if let c = a.copy {
                copies += 1
                c.finish(writer: w, sourceFirstTsNs: a.firstTsNs ?? 0)
            }
        }

        // Subtitle tracks.
        let subtitleCount = try addSubtitleTracks(writer: w, video: video, durationNs: durationNs, burned: burn)

        // Chapters.
        if let raw = reader.chaptersRaw {
            let chapters = MKVChapters.parse(raw)
            if !chapters.isEmpty {
                var ccfg = MP4Writer.TrackConfig(kind: .chapters, timescale: 1000)
                ccfg.enabled = false
                ccfg.sampleEntry = MP4Writer.chapterTextEntry()
                let ci = w.addTrack(ccfg)
                let chapterID = w.trackID(ci)
                let endMs = durationNs / 1_000_000
                for (i, ch) in chapters.enumerated() {
                    let startMs = ch.startNs / 1_000_000
                    let nextMs = i + 1 < chapters.count ? chapters[i + 1].startNs / 1_000_000 : endMs
                    if i == chapters.count - 1 {
                        w.update(track: ci) { $0.defaultSampleDuration = UInt32(clamping: max(1, nextMs - startMs)) }
                    }
                    try w.add(track: ci, data: MP4Writer.chapterSample(title: ch.title), dts: startMs)
                }
                w.update(track: videoIndex) { $0.chapterTrackID = chapterID }
                for n in audioOrder {
                    guard let a = audio[n] else { continue }
                    w.update(track: a.index) { $0.chapterTrackID = chapterID }
                    if let c = a.copy { w.update(track: c.index) { $0.chapterTrackID = chapterID } }
                }
                log("  chapters: \(chapters.count)")
            }
        }

        try w.finish()

        let fm = FileManager.default
        if fm.fileExists(atPath: finalURL.path) { try fm.removeItem(at: finalURL) }
        try fm.moveItem(at: tempURL, to: finalURL)
        writer = nil

        let seconds = Double(durationNs) / 1e9
        let bitrate = seconds > 0 ? Double(videoBytes) * 8 / seconds : 0
        let size = (try? fm.attributesOfItem(atPath: finalURL.path)[.size] as? Int64) ?? Int64(w.bytesWritten)
        let elapsed = Date().timeIntervalSince(startDate)
        log(String(format: "  encoded %d frames in %.0f s (%.1f fps); video %.2f Mbit/s; output %.2f GB; %d audio track(s) (%d AC-3 cop%@), %d subtitle track(s)",
                   framesEncoded, elapsed, Double(framesEncoded) / max(1, elapsed),
                   bitrate / 1e6, Double(size) / 1e9, audioCount + copies, copies, copies == 1 ? "y" : "ies", subtitleCount))
        if !usedQualityProperty { log("  note: the encoder refused the quality setting; a bitrate target was used instead") }
        progress(Progress(fraction: 1, fps: Double(framesEncoded) / max(1, elapsed), etaSeconds: 0, framesEncoded: framesEncoded))
        return Result(outputURL: finalURL, framesEncoded: framesEncoded, outputBytes: size,
                      videoBitrate: bitrate, durationSeconds: seconds, burnedTrack: burn,
                      audioTracks: audioCount + copies, ac3Copies: copies, subtitleTracks: subtitleCount, notes: notes)
    }

    /// "<folder>/<basename>.mp4", never the source, never an existing file.
    static func outputURL(for source: URL) -> URL {
        let dir = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        var url = dir.appendingPathComponent("\(base).mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n).mp4")
            n += 1
        }
        return url
    }

    // MARK: - Track selection

    private func pickForcedTrack(_ tracks: [MediaTrack]) -> MediaTrack? {
        let forced = tracks.filter { t in
            guard t.isSubtitle, t.isForced else { return false }
            switch t.subtitleKind {
            case .pgs, .srt, .ass, .ssa, .webvtt: return true
            default: return false
            }
        }
        guard !forced.isEmpty else { return nil }
        let audio = tracks.first(where: { $0.isAudio && $0.isDefault }) ?? tracks.first(where: { $0.isAudio })
        func base(_ tag: String) -> String {
            let short = Naming.shortCode(tag)
            return short.split(separator: "-").first.map(String.init) ?? short
        }
        if let a = audio, let match = forced.first(where: { base($0.languageTag) == base(a.languageTag) }) { return match }
        if let en = forced.first(where: { base($0.languageTag) == "en" }) { return en }
        return forced[0]
    }

    // MARK: - Audio

    /// Timing and bookkeeping of one copied audio track.
    final class AudioState {
        let track: MediaTrack
        let codec: AudioCodec
        let index: Int
        var nextDts: Int64 = 0
        var firstTsNs: Int64?
        var useTimestamps = false
        var lastNominal = 0
        var tsDeltas: [Int64] = []
        var lastTsSamples: Int64 = 0
        var gaps = 0
        var overlaps = 0
        var curSecond: Int64 = -1
        var curSecondBytes = 0
        var maxSecondBytes = 0
        var copy: AC3CopyState?

        init(track: MediaTrack, codec: AudioCodec, index: Int) {
            self.track = track
            self.codec = codec
            self.index = index
        }

        func add(block: MatroskaBlock, payload: Data, writer: MP4Writer, log: (String) -> Void) throws {
            let rate = Double(codec.sampleRate)
            let units = codec.split(payload)
            for (i, unit) in units.enumerated() {
                let nominalNs = lastNominal > 0 ? Int64(Double(lastNominal) * 1e9 / rate) : 0
                let tsNs = block.timestampNs + Int64(i) * nominalNs
                if firstTsNs == nil { firstTsNs = tsNs }
                let tsSamples = Int64(((Double(tsNs - firstTsNs!)) * rate / 1e9).rounded())
                let n = codec.samples(in: unit.data)
                var dts: Int64
                if n == nil, !useTimestamps {
                    useTimestamps = true
                    log("  audio \(track.describe): packet length unknown for \(codec.describe); timing from the MKV timestamps")
                }
                if useTimestamps {
                    dts = tsSamples
                    if tsDeltas.count < 512, tsSamples > lastTsSamples { tsDeltas.append(tsSamples - lastTsSamples) }
                    lastTsSamples = tsSamples
                } else {
                    let count = n ?? lastNominal
                    dts = nextDts
                    let tol = Int64(max(count, 1)) * 3 / 2
                    if tsSamples - dts > tol { dts = tsSamples; gaps += 1 }
                    else if dts - tsSamples > tol { overlaps += 1 }
                    nextDts = dts + Int64(count)
                    lastNominal = count
                }
                let second = dts / Int64(codec.sampleRate)
                if second != curSecond {
                    maxSecondBytes = max(maxSecondBytes, curSecondBytes)
                    curSecond = second
                    curSecondBytes = 0
                }
                curSecondBytes += unit.data.count
                try writer.add(track: index, data: unit.data, dts: dts, sync: codec.marksSyncSamples ? unit.sync : true)
            }
        }

        func finish(writer: MP4Writer) {
            maxSecondBytes = max(maxSecondBytes, curSecondBytes)
            let s = writer.stats(track: index)
            let avg = s.durationSeconds > 0 ? UInt32(min(Double(UInt32.max), Double(s.bytes) * 8 / s.durationSeconds)) : 0
            let maxBr = UInt32(min(Double(UInt32.max), Double(maxSecondBytes) * 8))
            var lastDuration = lastNominal
            if useTimestamps, !tsDeltas.isEmpty {
                let sorted = tsDeltas.sorted()
                lastDuration = Int(sorted[sorted.count / 2])
            }
            let entry = codec.sampleEntry(trackID: writer.trackID(index), maxBitrate: max(maxBr, avg), avgBitrate: avg)
            let first = firstTsNs ?? 0
            writer.update(track: index) { c in
                c.sampleEntry = entry
                c.defaultSampleDuration = UInt32(clamping: max(0, lastDuration))
                c.startDelayNs = max(0, first)
            }
        }
    }

    /// The AC-3 copy of a DTS / TrueHD track: its own MP4 track, fed by an ffmpeg worker.
    final class AC3CopyState {
        let index: Int
        var nextDts: Int64 = 0
        var firstFrame: Data?
        var frames = 0
        init(index: Int) { self.index = index }

        func finish(writer: MP4Writer, sourceFirstTsNs: Int64) {
            var codec = AudioCodec.ac3(first: firstFrame, rate: 48000, channels: 0) ?? AudioCodec(family: .ac3, sampleRate: 48000, channels: 6)
            if codec.channels <= 0 { codec.channels = 6 }
            let s = writer.stats(track: index)
            let avg = s.durationSeconds > 0 ? UInt32(Double(s.bytes) * 8 / s.durationSeconds) : 0
            let entry = codec.sampleEntry(trackID: writer.trackID(index), maxBitrate: avg, avgBitrate: avg)
            writer.update(track: index) { c in
                c.sampleEntry = entry
                c.defaultSampleDuration = 1536
                c.startDelayNs = max(0, sourceFirstTsNs)
            }
        }
    }

    final class AC3Worker {
        let transcoder: AC3Transcoder
        let sourceDescribe: String
        var thread: Thread?
        let finished = DispatchSemaphore(value: 0)
        var error: Error?
        var frames = 0
        init(transcoder: AC3Transcoder, sourceDescribe: String) {
            self.transcoder = transcoder
            self.sourceDescribe = sourceDescribe
        }
    }

    private func handleAudio(_ block: MatroskaBlock, track: MediaTrack) throws {
        guard let w = writer, let reader = reader else { return }
        if unsupportedAudio.contains(track.number) { return }
        guard let payload = reader.decompressed(block.payload, track: track) else { return }

        var state = audio[track.number]
        if state == nil {
            guard let codec = AudioCodec.detect(track: track, firstPacket: payload) else {
                unsupportedAudio.insert(track.number)
                let n = "audio track \(track.describe) (\(track.codecID)) cannot go into an MP4; dropped"
                log("  \(n)")
                notes.append(n)
                return
            }
            let (lang, ext) = MP4Language.codes(language: track.language, ietf: track.languageIETF)
            var cfg = MP4Writer.TrackConfig(kind: .audio, timescale: UInt32(codec.sampleRate))
            cfg.language = lang
            cfg.extendedLanguage = ext
            cfg.alternateGroup = 1
            cfg.mediaTimeOffset = Int64(codec.preSkip)
            let langName = Naming.displayName(track.languageTag)
            cfg.name = track.name.isEmpty ? "\(langName) \(codec.describeShort)" : track.name

            // The default audio track is the one Apple players start with; when it is DTS/TrueHD and
            // gets an AC-3 copy, the copy takes that role (passthrough stays selectable).
            let wantsCopy = options.ac3Copies && !codec.appleCanPlay && AC3Transcoder.findFFmpeg() != nil
            let isDefault = (track.isDefault && !defaultAudioHandled) || (!defaultAudioHandled && audioOrder.first == track.number && !reader.tracks.contains(where: { $0.isAudio && $0.isDefault }))
            cfg.enabled = isDefault && !wantsCopy
            if isDefault { defaultAudioHandled = true }
            let idx = w.addTrack(cfg)
            let s = AudioState(track: track, codec: codec, index: idx)
            audio[track.number] = s
            state = s
            log("  audio: \(track.describe) → \(codec.describe) passthrough\(codec.appleCanPlay ? "" : " (not decodable by Apple players)")")

            if wantsCopy {
                let hasAC3Sibling = reader.tracks.contains { t in
                    t.isAudio && t.number != track.number && (t.codecID == "A_AC3" || t.codecID == "A_EAC3") && t.languageTag == track.languageTag
                }
                if hasAC3Sibling {
                    log("    an AC-3 / E-AC-3 track in \(langName) already exists; no extra copy made")
                } else {
                    var ccfg = MP4Writer.TrackConfig(kind: .audio, timescale: 48_000)
                    ccfg.language = lang
                    ccfg.extendedLanguage = ext
                    ccfg.alternateGroup = 1
                    ccfg.enabled = isDefault
                    let streamIndex = audioOrder.firstIndex(of: track.number) ?? 0
                    let transcoder = AC3Transcoder(source: source, audioStreamIndex: streamIndex, sourceChannels: codec.channels)
                    ccfg.name = "\(langName) \(transcoder.describe) (from \(codec.profile.isEmpty ? codec.family.rawValue : codec.profile))"
                    let cidx = w.addTrack(ccfg)
                    let copy = AC3CopyState(index: cidx)
                    s.copy = copy
                    let worker = AC3Worker(transcoder: transcoder, sourceDescribe: track.describe)
                    let thread = Thread { [weak self] in
                        defer { worker.finished.signal() }
                        guard let self = self else { return }
                        do {
                            let n = try transcoder.run { frame in
                                if self.cancel.isCancelled { return false }
                                if copy.firstFrame == nil { copy.firstFrame = frame }
                                self.throttle(copyPositionNs: copy.nextDts * 1_000_000_000 / 48_000)
                                do {
                                    try w.add(track: cidx, data: frame, dts: copy.nextDts)
                                } catch {
                                    self.setError(error)
                                    return false
                                }
                                copy.nextDts += 1536
                                copy.frames += 1
                                return true
                            }
                            worker.frames = n
                        } catch {
                            worker.error = error
                        }
                    }
                    thread.name = "ac3-copy-\(track.number)"
                    thread.qualityOfService = .userInitiated
                    worker.thread = thread
                    ac3Workers.append(worker)
                    thread.start()
                    log("    + AC-3 copy: \(transcoder.describe) via ffmpeg (track \"\(ccfg.name)\")")
                }
            }
        }
        try state?.add(block: block, payload: payload, writer: w, log: log)
    }

    /// Keeps an AC-3 helper from running far ahead of the video, so the chunks stay interleaved.
    private func throttle(copyPositionNs: Int64) {
        while !cancel.isCancelled {
            lock.lock()
            let done = readingDone
            let videoPos = lastVideoPtsNs
            lock.unlock()
            if done || copyPositionNs < videoPos + 20_000_000_000 { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    // MARK: - Subtitles

    /// Collects a text subtitle track's cues while the file is read.
    final class TextCollector {
        let track: MediaTrack
        private let lock = NSLock()
        private(set) var cues: [TextCue] = []
        init(track: MediaTrack) { self.track = track }

        func add(payload: Data, timestampNs: Int64, durationNs: Int64?) {
            let raw = SubtitleWriter.textOf(payload)
            var text: String
            switch track.subtitleKind {
            case .ass, .ssa:
                let fields = raw.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false).map(String.init)
                guard fields.count == 9 else { return }
                text = LocalConverter.assToSRTText(fields[8])
            case .webvtt:
                var body = raw
                if let nl = body.firstIndex(of: "\n") { body = String(body[body.index(after: nl)...]) }
                text = LocalConverter.vttToSRTText(body)
            default:
                text = raw
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            lock.lock()
            cues.append(TextCue(startNs: timestampNs, endNs: timestampNs + (durationNs ?? 3_000_000_000), text: text))
            lock.unlock()
        }
    }

    private func addSubtitleTracks(writer w: MP4Writer, video: MediaTrack, durationNs: Int64, burned: MediaTrack?) throws -> Int {
        struct Source {
            var cues: [TextCue]
            var tag: String
            var name: String
            var forced: Bool
        }
        var sources: [Source] = []
        let movie = source.deletingPathExtension().lastPathComponent

        if !options.extraSubtitleFiles.isEmpty {
            for file in options.extraSubtitleFiles where file.pathExtension.lowercased() == "srt" {
                guard let data = try? Data(contentsOf: file) else { continue }
                let d = TimedText.describe(fileName: file.lastPathComponent, movie: movie)
                let cues = TimedText.parseSRT(data)
                guard !cues.isEmpty else { continue }
                sources.append(Source(cues: cues, tag: d.tag,
                                      name: TimedText.trackName(tag: d.tag, name: d.name, forced: d.forced, sdh: d.sdh, commentary: d.commentary),
                                      forced: d.forced))
            }
        } else {
            for n in textTracks.keys.sorted() {
                guard let c = textTracks[n], !c.cues.isEmpty else { continue }
                let t = c.track
                let tag = Naming.shortCode(t.languageTag)
                let sdh = t.name.lowercased().contains("sdh")
                sources.append(Source(cues: c.cues, tag: tag,
                                      name: t.name.isEmpty ? TimedText.trackName(tag: tag, name: "", forced: t.isForced, sdh: sdh, commentary: false) : t.name,
                                      forced: t.isForced))
            }
        }

        var count = 0
        for src in sources {
            if src.forced, burned != nil { continue }   // already in the picture
            let (lang, ext) = MP4Language.codes(language: "", ietf: src.tag)
            var cfg = MP4Writer.TrackConfig(kind: .subtitle, timescale: 1000)
            cfg.language = lang
            cfg.extendedLanguage = ext
            cfg.name = src.name
            cfg.width = Double(video.displayWidth > 0 ? video.displayWidth : video.pixelWidth)
            cfg.height = Double(video.displayHeight > 0 ? video.displayHeight : video.pixelHeight)
            cfg.enabled = false
            cfg.alternateGroup = 3
            cfg.sampleEntry = MP4Writer.tx3gEntry()
            let idx = w.addTrack(cfg)

            let cues = src.cues.sorted { $0.startNs < $1.startNs }
            var cursorMs: Int64 = 0
            let endMs = max(durationNs / 1_000_000, (cues.last?.endNs ?? 0) / 1_000_000)
            for (i, cue) in cues.enumerated() {
                let startMs = max(cursorMs, cue.startNs / 1_000_000)
                var stopMs = max(cue.endNs / 1_000_000, startMs + 100)
                if i + 1 < cues.count { stopMs = min(stopMs, max(startMs + 100, cues[i + 1].startNs / 1_000_000)) }
                if startMs > cursorMs {
                    try w.add(track: idx, data: MP4Writer.tx3gSample(text: "", italicRanges: []), dts: cursorMs)
                }
                let styled = TimedText.styled(cue.text)
                try w.add(track: idx, data: MP4Writer.tx3gSample(text: styled.text, italicRanges: styled.italics), dts: startMs)
                cursorMs = stopMs
            }
            // Trailing empty sample up to the end of the movie, so the track spans the whole file.
            if cursorMs < endMs {
                try w.add(track: idx, data: MP4Writer.tx3gSample(text: "", italicRanges: []), dts: cursorMs)
                w.update(track: idx) { $0.defaultSampleDuration = UInt32(clamping: endMs - cursorMs) }
            } else {
                w.update(track: idx) { $0.defaultSampleDuration = 100 }
            }
            count += 1
            log("  subtitles: \"\(src.name)\" (\(src.tag), \(cues.count) cues) as a text track")
        }
        return count
    }

    // MARK: - Errors

    private func setError(_ error: Error) {
        lock.lock()
        if pendingError == nil { pendingError = error }
        lock.unlock()
    }

    private func takeError() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return pendingError
    }

    // MARK: - Decoder

    private func makeFormatDescription(track: MediaTrack) throws -> CMVideoFormatDescription {
        let codecType: CMVideoCodecType
        let atomKey: String
        switch track.codecID {
        case "V_MPEG4/ISO/AVC": codecType = kCMVideoCodecType_H264; atomKey = "avcC"
        case "V_MPEGH/ISO/HEVC": codecType = kCMVideoCodecType_HEVC; atomKey = "hvcC"
        default: throw Failure.unsupportedCodec(track.codecID)
        }
        guard !track.codecPrivate.isEmpty else { throw Failure.missingCodecPrivate }
        let atoms: [String: Any] = [atomKey: track.codecPrivate as NSData]
        let extensions: [String: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: atoms,
        ]
        var desc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                    codecType: codecType,
                                                    width: Int32(track.pixelWidth),
                                                    height: Int32(track.pixelHeight),
                                                    extensions: extensions as CFDictionary,
                                                    formatDescriptionOut: &desc)
        guard status == noErr, let d = desc else { throw Failure.formatDescription(status) }
        return d
    }

    private func makeDecoder(_ desc: CMVideoFormatDescription) throws -> VTDecompressionSession {
        let spec: [String: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true,
        ]
        // Let VideoToolbox pick the pixel format (420v for 8-bit, x420 for 10-bit); IOSurface-backed.
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                  formatDescription: desc,
                                                  decoderSpecification: spec as CFDictionary,
                                                  imageBufferAttributes: attrs as CFDictionary,
                                                  outputCallback: nil,
                                                  decompressionSessionOut: &session)
        guard status == noErr, let s = session else { throw Failure.decoderSetup(status) }
        return s
    }

    private func makeSampleBuffer(_ payload: Data, ptsNs: Int64, durationNs: Int64,
                                  desc: CMVideoFormatDescription) -> CMSampleBuffer? {
        let n = payload.count
        guard n > 0 else { return nil }
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                        blockLength: n, blockAllocator: kCFAllocatorDefault,
                                                        customBlockSource: nil, offsetToData: 0, dataLength: n,
                                                        flags: 0, blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let bb = blockBuffer else { return nil }
        status = payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: bb, offsetIntoDestination: 0, dataLength: n)
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(duration: durationNs > 0 ? CMTime(value: durationNs, timescale: 1_000_000_000) : CMTime.invalid,
                                        presentationTimeStamp: CMTime(value: ptsNs, timescale: 1_000_000_000),
                                        decodeTimeStamp: CMTime.invalid)
        var sampleSize = n
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: desc,
                                           sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                           sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                           sampleBufferOut: &sample)
        guard status == noErr else { return nil }
        return sample
    }

    private func submit(_ sb: CMSampleBuffer) throws {
        guard let session = decoder else { return }
        decodeSlots.wait()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb,
                                                       flags: [._EnableAsynchronousDecompression],
                                                       infoFlagsOut: nil) { [weak self] status, infoFlags, imageBuffer, pts, _ in
            self?.decoded(status: status, flags: infoFlags, image: imageBuffer, pts: pts)
        }
        if status != noErr {
            decodeSlots.signal()
            throw Failure.decodeFailed(status)
        }
    }

    /// Decoder output (decode order). Reorders by PTS with a small window and feeds the encoder.
    private func decoded(status: OSStatus, flags: VTDecodeInfoFlags, image: CVImageBuffer?, pts: CMTime) {
        decodeSlots.signal()
        if cancel.isCancelled { return }
        guard status == noErr, let pb = image else {
            if flags.contains(.frameDropped) { return }
            setError(Failure.decodeFailed(status))
            return
        }
        let ptsNs = nanoseconds(pts)
        var ready: [(pts: Int64, buffer: CVPixelBuffer)] = []
        lock.lock()
        reorder.append((pts: ptsNs, buffer: pb))
        while reorder.count > reorderDepth {
            var minIndex = 0
            for i in 1 ..< reorder.count where reorder[i].pts < reorder[minIndex].pts { minIndex = i }
            ready.append(reorder.remove(at: minIndex))
        }
        lock.unlock()
        for r in ready { encode(r.buffer, ptsNs: r.pts) }
    }

    private func nanoseconds(_ t: CMTime) -> Int64 {
        guard t.isValid else { return 0 }
        if t.timescale == 1_000_000_000 { return t.value }
        return CMTimeConvertScale(t, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value
    }

    // MARK: - Encoder

    @discardableResult
    private func set(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef) -> OSStatus {
        return VTSessionSetProperty(session, key: key, value: value)
    }

    /// The MP4 timescale for a frame duration: exact for the usual rates (24000/1001 …), nanoseconds otherwise.
    static func videoTimescale(frameDurationNs: Int64) -> (timescale: UInt32, delta: UInt32) {
        let known: [(UInt32, UInt32)] = [(24000, 1001), (24000, 1000), (25000, 1000), (30000, 1001), (30000, 1000),
                                         (48000, 1001), (48000, 1000), (50000, 1000), (60000, 1001), (60000, 1000), (120000, 1000)]
        for (ts, d) in known {
            let ns = 1e9 * Double(d) / Double(ts)
            if abs(ns - Double(frameDurationNs)) < 1000 { return (ts, d) }
        }
        return (1_000_000_000, UInt32(clamping: max(1, frameDurationNs)))
    }

    private func ensureEncoder(for pb: CVPixelBuffer) throws {
        if encoder != nil { return }
        let width = CVPixelBufferGetWidth(pb)
        let height = CVPixelBufferGetHeight(pb)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pb)
        tenBit = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            || pixelFormat == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
            || pixelFormat == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
        encoderWidth = width
        encoderHeight = height

        if frameDurationNs <= 0 {
            // No DefaultDuration in the file: median of the first PTS deltas.
            let sorted = recentPTS.sorted()
            var deltas: [Int64] = []
            for i in 1 ..< max(1, sorted.count) where sorted[i] > sorted[i - 1] { deltas.append(sorted[i] - sorted[i - 1]) }
            deltas.sort()
            frameDurationNs = deltas.isEmpty ? 41_708_333 : deltas[deltas.count / 2]
            if let r = reader, r.durationNs > 0 { expectedFrames = Int(r.durationNs / frameDurationNs) }
            log("  frame rate not declared; estimated from timestamps")
        }
        let fps = 1e9 / Double(frameDurationNs)

        // MP4 timing: an exact timescale for the frame rate, and the phase of the PTS grid so that
        // millisecond-rounded Matroska timestamps snap back onto whole frames.
        let (ts, delta) = VideoConverter.videoTimescale(frameDurationNs: frameDurationNs)
        videoTimescale = ts
        videoDelta = delta
        if !recentPTS.isEmpty {
            var sx = 0.0, sy = 0.0
            for p in recentPTS {
                let frac = Double(p % frameDurationNs) / Double(frameDurationNs)
                sx += cos(frac * 2 * .pi); sy += sin(frac * 2 * .pi)
            }
            var phase = atan2(sy, sx) / (2 * .pi)
            if phase < 0 { phase += 1 }
            ptsPhaseNs = Int64(phase * Double(frameDurationNs))
            if ptsPhaseNs > frameDurationNs / 2 { ptsPhaseNs -= frameDurationNs }
        }
        writer?.update(track: videoIndex) { c in
            c.timescale = ts
            c.defaultSampleDuration = delta
        }

        let spec: [String: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
        ]
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_HEVC,
                                                encoderSpecification: spec as CFDictionary,
                                                imageBufferAttributes: attrs as CFDictionary,
                                                compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil,
                                                compressionSessionOut: &session)
        guard status == noErr, let enc = session else { throw Failure.encoderSetup(status) }

        set(enc, kVTCompressionPropertyKey_RealTime, kCFBooleanFalse)
        set(enc, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanTrue)
        set(enc, kVTCompressionPropertyKey_ProfileLevel, tenBit ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel)
        set(enc, kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
        set(enc, kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: Int(fps * 5 + 0.5)))
        set(enc, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 5.0))
        set(enc, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanFalse)
        set(enc, kVTCompressionPropertyKey_MaximizePowerEfficiency, kCFBooleanFalse)

        let q = max(0.0, min(1.0, options.quality))
        let qStatus = set(enc, kVTCompressionPropertyKey_Quality, NSNumber(value: q))
        if qStatus == noErr {
            usedQualityProperty = true
            log(String(format: "  encoder: HEVC %@, %dx%d, %.3f fps, quality %.2f", tenBit ? "Main 10" : "Main", width, height, fps, q))
        } else {
            usedQualityProperty = false
            let pixels = width * height
            var bitrate: Double
            if pixels >= 3840 * 2160 * 9 / 10 { bitrate = 30_000_000 }
            else if pixels >= 1920 * 1080 * 9 / 10 { bitrate = 12_000_000 }
            else if pixels >= 1280 * 720 * 9 / 10 { bitrate = 6_000_000 }
            else { bitrate = 3_000_000 }
            bitrate *= max(0.5, q / 0.85)
            set(enc, kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: Int(bitrate)))
            log(String(format: "  encoder: HEVC %@, %dx%d, %.3f fps; quality setting not supported (%d), using %.1f Mbit/s average bitrate",
                       tenBit ? "Main 10" : "Main", width, height, fps, qStatus, bitrate / 1e6))
        }

        applyColour(from: pb, to: enc)

        let prep = VTCompressionSessionPrepareToEncodeFrames(enc)
        if prep != noErr { log("  warning: VTCompressionSessionPrepareToEncodeFrames returned \(prep)") }
        encoder = enc

        // Core Image context for subtitle compositing.
        if overlay != nil {
            var opts: [CIContextOption: Any] = [.cacheIntermediates: false, .useSoftwareRenderer: false]
            if tenBit { opts[.workingFormat] = CIFormat.RGBAh }
            ciContext = CIContext(options: opts)
            if let atts = CVBufferCopyAttachments(pb, .shouldPropagate),
               let cs = CVImageBufferCreateColorSpaceFromAttachments(atts) {
                outputColorSpace = cs.takeRetainedValue()
            } else {
                outputColorSpace = CGColorSpace(name: CGColorSpace.itur_709)
            }
        }
    }

    /// Copies colour primaries / transfer / matrix (and HDR static metadata) from the decoded
    /// frames, falling back to the Matroska Colour element, onto the encoder.
    private func applyColour(from pb: CVPixelBuffer, to enc: VTCompressionSession) {
        let colour = videoTrack?.colour ?? MatroskaColour()
        var primaries: CFTypeRef? = CVBufferCopyAttachment(pb, kCVImageBufferColorPrimariesKey, nil)
        var transfer: CFTypeRef? = CVBufferCopyAttachment(pb, kCVImageBufferTransferFunctionKey, nil)
        var matrix: CFTypeRef? = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil)

        if primaries == nil {
            switch colour.primaries {
            case 1: primaries = kCMFormatDescriptionColorPrimaries_ITU_R_709_2
            case 5: primaries = kCMFormatDescriptionColorPrimaries_EBU_3213
            case 6: primaries = kCMFormatDescriptionColorPrimaries_SMPTE_C
            case 9: primaries = kCMFormatDescriptionColorPrimaries_ITU_R_2020
            case 12: primaries = kCMFormatDescriptionColorPrimaries_P3_D65
            default: break
            }
        }
        if transfer == nil {
            switch colour.transferCharacteristics {
            case 1, 6, 14, 15: transfer = kCMFormatDescriptionTransferFunction_ITU_R_709_2
            case 8: transfer = kCMFormatDescriptionTransferFunction_Linear
            case 13: transfer = kCMFormatDescriptionTransferFunction_sRGB
            case 16: transfer = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
            case 18: transfer = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
            default: break
            }
        }
        if matrix == nil {
            switch colour.matrixCoefficients {
            case 1: matrix = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
            case 5, 6: matrix = kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4
            case 7: matrix = kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995
            case 9: matrix = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
            default: break
            }
        }
        var described: [String] = []
        if let p = primaries { set(enc, kVTCompressionPropertyKey_ColorPrimaries, p); described.append("primaries \(p)") }
        if let t = transfer { set(enc, kVTCompressionPropertyKey_TransferFunction, t); described.append("transfer \(t)") }
        if let m = matrix { set(enc, kVTCompressionPropertyKey_YCbCrMatrix, m); described.append("matrix \(m)") }

        // HDR10 static metadata
        var mastering: CFTypeRef? = CVBufferCopyAttachment(pb, kCVImageBufferMasteringDisplayColorVolumeKey, nil)
        if mastering == nil, let m = colour.mastering, m.lumMax > 0 {
            mastering = VideoConverter.masteringPayload(m) as NSData
        }
        var cll: CFTypeRef? = CVBufferCopyAttachment(pb, kCVImageBufferContentLightLevelInfoKey, nil)
        if cll == nil, colour.maxCLL > 0 || colour.maxFALL > 0 {
            cll = VideoConverter.contentLightLevelPayload(maxCLL: colour.maxCLL, maxFALL: colour.maxFALL) as NSData
        }
        if let m = mastering { set(enc, kVTCompressionPropertyKey_MasteringDisplayColorVolume, m); described.append("mastering display") }
        if let c = cll { set(enc, kVTCompressionPropertyKey_ContentLightLevelInfo, c); described.append("content light level") }
        if !described.isEmpty { log("  colour: " + described.joined(separator: ", ")) }
    }

    /// SEI mastering_display_colour_volume payload (G, B, R, white point in 0.00002 units; luminance in 0.0001 cd/m2).
    /// The `mdcv` box uses the same layout.
    static func masteringPayload(_ m: MatroskaColour.Mastering) -> Data {
        func u16(_ v: Double) -> [UInt8] {
            let x = UInt16(max(0, min(65535, (v * 50000).rounded())))
            return [UInt8(x >> 8), UInt8(x & 0xFF)]
        }
        func u32(_ v: Double) -> [UInt8] {
            let x = UInt32(max(0, min(4_294_967_295, (v * 10000).rounded())))
            return [UInt8(x >> 24 & 0xFF), UInt8(x >> 16 & 0xFF), UInt8(x >> 8 & 0xFF), UInt8(x & 0xFF)]
        }
        var d: [UInt8] = []
        d += u16(m.gx); d += u16(m.gy)
        d += u16(m.bx); d += u16(m.by)
        d += u16(m.rx); d += u16(m.ry)
        d += u16(m.wx); d += u16(m.wy)
        d += u32(m.lumMax); d += u32(m.lumMin)
        return Data(d)
    }

    static func contentLightLevelPayload(maxCLL: UInt64, maxFALL: UInt64) -> Data {
        let a = UInt16(truncatingIfNeeded: maxCLL), b = UInt16(truncatingIfNeeded: maxFALL)
        return Data([UInt8(a >> 8), UInt8(a & 0xFF), UInt8(b >> 8), UInt8(b & 0xFF)])
    }

    /// Feeds one decoded frame (display order) to the encoder, compositing the subtitle overlay first.
    private func encode(_ pb: CVPixelBuffer, ptsNs: Int64) {
        if cancel.isCancelled { return }
        do { try ensureEncoder(for: pb) } catch { setError(error); return }
        guard let enc = encoder else { return }

        var input: CVPixelBuffer = pb
        if let ov = overlay, let image = ov.image(at: ptsNs), let composed = composite(pb, overlay: image, encoder: enc) {
            input = composed
        }
        let duration = frameDurationNs > 0 ? CMTime(value: frameDurationNs, timescale: 1_000_000_000) : CMTime.invalid
        encodeSlots.wait()
        let status = VTCompressionSessionEncodeFrame(enc, imageBuffer: input,
                                                     presentationTimeStamp: CMTime(value: ptsNs, timescale: 1_000_000_000),
                                                     duration: duration, frameProperties: nil,
                                                     infoFlagsOut: nil) { [weak self] status, infoFlags, sample in
            guard let self = self else { return }
            self.encodeSlots.signal()
            self.encoded(status: status, flags: infoFlags, sample: sample)
        }
        if status != noErr {
            encodeSlots.signal()
            setError(Failure.encodeFailed(status))
        }
    }

    private func composite(_ src: CVPixelBuffer, overlay: CIImage, encoder enc: VTCompressionSession) -> CVPixelBuffer? {
        guard let ctx = ciContext, let pool = VTCompressionSessionGetPixelBufferPool(enc) else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess, let dst = out else { return nil }
        CVBufferPropagateAttachments(src, dst)
        let base = CIImage(cvPixelBuffer: src)
        var top = overlay
        let w = base.extent.width, h = base.extent.height
        if overlay.extent.width != w || overlay.extent.height != h, overlay.extent.width > 0, overlay.extent.height > 0 {
            top = overlay.transformed(by: CGAffineTransform(scaleX: w / overlay.extent.width, y: h / overlay.extent.height))
        }
        let composed = top.composited(over: base)
        ctx.render(composed, to: dst, bounds: base.extent, colorSpace: outputColorSpace)
        return dst
    }

    /// Encoder output (decode order): write the HEVC sample to the MP4.
    private func encoded(status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?) {
        if cancel.isCancelled { return }
        guard status == noErr, let sb = sample else {
            if flags.contains(.frameDropped) { return }
            setError(Failure.encodeFailed(status))
            return
        }
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return }
        let n = CMBlockBufferGetDataLength(bb)
        guard n > 0 else { return }
        var data = Data(count: n)
        let copyStatus = data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n, destination: base)
        }
        guard copyStatus == kCMBlockBufferNoErr else { setError(Failure.encodeFailed(copyStatus)); return }

        let ptsNs = nanoseconds(CMSampleBufferGetPresentationTimeStamp(sb))
        let keyframe = VideoConverter.isSync(sb)

        do {
            guard let w = writer else { return }
            if !videoEntryWritten {
                try writeVideoEntry(from: sb)
            }
            // Decode times are a regular grid in output order; composition times snap to the frame grid.
            let frameIndex = Int64((Double(ptsNs - ptsPhaseNs) / Double(frameDurationNs)).rounded())
            let cts = frameIndex * Int64(videoDelta)
            lock.lock()
            let dts = Int64(framesEncoded) * Int64(videoDelta)
            framesEncoded += 1
            videoBytes += n
            lastVideoPtsNs = max(lastVideoPtsNs, ptsNs)
            let count = framesEncoded
            lock.unlock()
            try w.add(track: videoIndex, data: data, dts: dts, cts: cts, sync: keyframe)
            reportProgress(frames: count)
        } catch {
            setError(error)
        }
    }

    private static func isSync(_ sb: CMSampleBuffer) -> Bool {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as NSArray?,
              let first = array.firstObject as? NSDictionary else { return true }
        if let notSync = first[kCMSampleAttachmentKey_NotSync as String] as? Bool { return !notSync }
        return true
    }

    /// Builds the hvc1 sample entry once the encoder's hvcC is known.
    private func writeVideoEntry(from sb: CMSampleBuffer) throws {
        guard let fmt = CMSampleBufferGetFormatDescription(sb) else { throw Failure.noHVCC }
        let ext = CMFormatDescriptionGetExtension(fmt, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
        guard let atoms = ext as? NSDictionary, let hvcC = atoms["hvcC"] as? Data, !hvcC.isEmpty else { throw Failure.noHVCC }
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        guard let video = videoTrack, let w = writer else { throw Failure.noFrames }

        // colr (nclx) from the Matroska Colour element, else from the encoder's format description.
        var colour: (primaries: UInt16, transfer: UInt16, matrix: UInt16, fullRange: Bool)?
        let c = video.colour
        if c.primaries > 0 || c.transferCharacteristics > 0 || c.matrixCoefficients > 0 {
            colour = (UInt16(c.primaries == 0 ? 2 : c.primaries), UInt16(c.transferCharacteristics == 0 ? 2 : c.transferCharacteristics),
                      UInt16(c.matrixCoefficients == 0 ? 2 : c.matrixCoefficients), c.range == 2)
        } else {
            func code(_ key: CFString, _ table: [(CFString, UInt16)]) -> UInt16? {
                guard let v = CMFormatDescriptionGetExtension(fmt, extensionKey: key) else { return nil }
                let s = v as! CFString
                return table.first(where: { CFEqual($0.0, s) })?.1
            }
            let p = code(kCMFormatDescriptionExtension_ColorPrimaries, [
                (kCMFormatDescriptionColorPrimaries_ITU_R_709_2, 1), (kCMFormatDescriptionColorPrimaries_EBU_3213, 5),
                (kCMFormatDescriptionColorPrimaries_SMPTE_C, 6), (kCMFormatDescriptionColorPrimaries_ITU_R_2020, 9),
                (kCMFormatDescriptionColorPrimaries_P3_D65, 12)])
            let t = code(kCMFormatDescriptionExtension_TransferFunction, [
                (kCMFormatDescriptionTransferFunction_ITU_R_709_2, 1), (kCMFormatDescriptionTransferFunction_SMPTE_240M_1995, 7),
                (kCMFormatDescriptionTransferFunction_Linear, 8), (kCMFormatDescriptionTransferFunction_sRGB, 13),
                (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ, 16), (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG, 18)])
            let m = code(kCMFormatDescriptionExtension_YCbCrMatrix, [
                (kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2, 1), (kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4, 6),
                (kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995, 7), (kCMFormatDescriptionYCbCrMatrix_ITU_R_2020, 9)])
            if p != nil || t != nil || m != nil { colour = (p ?? 2, t ?? 2, m ?? 2, false) }
        }

        var pasp: (h: UInt32, v: UInt32)?
        if video.displayUnit == 0, video.pixelWidth > 0, video.pixelHeight > 0, video.displayWidth > 0, video.displayHeight > 0 {
            var h = video.displayWidth * video.pixelHeight
            var v = video.displayHeight * video.pixelWidth
            func gcd(_ a: UInt64, _ b: UInt64) -> UInt64 { b == 0 ? a : gcd(b, a % b) }
            let g = gcd(h, v)
            if g > 0 { h /= g; v /= g }
            if h != v { pasp = (UInt32(clamping: h), UInt32(clamping: v)) }
        }
        let mastering = c.mastering.map { VideoConverter.masteringPayload($0) }
        let cll = (c.maxCLL > 0 || c.maxFALL > 0) ? VideoConverter.contentLightLevelPayload(maxCLL: c.maxCLL, maxFALL: c.maxFALL) : nil

        let entry = MP4Writer.hvc1Entry(width: Int(dims.width), height: Int(dims.height), hvcC: hvcC,
                                        colour: colour, pixelAspect: pasp,
                                        mastering: (c.mastering?.lumMax ?? 0) > 0 ? mastering : nil, contentLight: cll)
        w.update(track: videoIndex) { $0.sampleEntry = entry }
        videoEntryWritten = true
    }

    // MARK: - Progress

    private func reportProgress(frames: Int) {
        let now = Date()
        guard now.timeIntervalSince(lastProgressDate) >= 0.5 else { return }
        lastProgressDate = now
        let elapsed = now.timeIntervalSince(startDate)
        let fps = elapsed > 0 ? Double(frames) / elapsed : 0
        var fraction: Double
        if expectedFrames > 0 {
            fraction = Double(frames) / Double(expectedFrames)
        } else {
            fraction = readFraction
        }
        fraction = max(0, min(0.999, fraction))
        var eta: Double?
        if fps > 0, expectedFrames > 0 {
            eta = Double(max(0, expectedFrames - frames)) / fps
        } else if fraction > 0.01, elapsed > 5 {
            eta = elapsed * (1 - fraction) / fraction
        }
        progress(Progress(fraction: fraction, fps: fps, etaSeconds: eta, framesEncoded: frames))
    }
}

extension AudioCodec {
    /// "DTS-HD MA 5.1" without the sample rate, for track names.
    var describeShort: String {
        var name = profile.isEmpty ? family.rawValue : profile
        if let r = name.range(of: #"\s*\d+\s*kbps"#, options: .regularExpression) { name.removeSubrange(r) }
        return "\(name) \(AudioCodec.layoutName(channels: channels))"
    }
}
